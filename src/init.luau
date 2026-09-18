--!strict

local DefaultSettings = require(script.Settings)
local WriterModule = require(script.Internal.Writer)
local ReaderModule = require(script.Internal.Reader)
local AutoCodec = require(script.Internal.AutoCodec)
local SchemaModule = require(script.Internal.Schema)
local BufferUtil = require(script.Internal.BufferUtil)

local MAGIC = 0x5746
-- A6 columnar schema arrays are part of the current wire contract. Bump the
-- version so clients built from the older checked-in artifact cannot silently
-- misinterpret a compact schema payload.
local WIRE_VERSION = 2
local KIND_AUTO = 0
local KIND_BATCH = 1
local KIND_SCHEMA = 2

export type Configuration = {
	poolingEnabled: boolean?,
	writerPoolMaxPerBucket: number?,
	maxPooledWriterSize: number?,
	readerPoolMax: number?,
	initialWriterSize: number?,
	rleThreshold: number?,
	sortedKeysCacheEnabled: boolean?,
	sortedKeysCacheTrustMode: boolean?,
	commonKeys: {string}?,
	stringCacheMinLength: number?,
	schemaValidationEnabled: boolean?,
	strictBoundsChecking: boolean?,
	encodeSnapshotCacheEnabled: boolean?,
	decodeSnapshotCacheEnabled: boolean?,
	maxDepth: number?,
	maxCollectionCount: number?,
	maxRecordCells: number?,
	maxRecordFields: number?,
	maxStringBytes: number?,
	maxBufferBytes: number?,
	maxPayloadBytes: number?,
	maxVarintBytes: number?,
	debugAsserts: boolean?,
}

export type ConverterWriter = {
	WriteU8: (self: ConverterWriter, value: number) -> (),
	WriteU16: (self: ConverterWriter, value: number) -> (),
	WriteU32: (self: ConverterWriter, value: number) -> (),
	WriteI16: (self: ConverterWriter, value: number) -> (),
	WriteI32: (self: ConverterWriter, value: number) -> (),
	WriteF32: (self: ConverterWriter, value: number) -> (),
	WriteF64: (self: ConverterWriter, value: number) -> (),
	WriteVarUInt: (self: ConverterWriter, value: number) -> (),
	WriteVarInt: (self: ConverterWriter, value: number) -> (),
	WriteString: (self: ConverterWriter, value: string) -> (),
	WriteRawString: (self: ConverterWriter, value: string) -> (),
	WriteBuffer: (self: ConverterWriter, value: buffer) -> (),
	WriteRawBuffer: (self: ConverterWriter, value: buffer) -> (),
	Position: (self: ConverterWriter) -> number,
}

export type ConverterReader = {
	ReadU8: (self: ConverterReader, context: string?) -> number,
	ReadU16: (self: ConverterReader, context: string?) -> number,
	ReadU32: (self: ConverterReader, context: string?) -> number,
	ReadI16: (self: ConverterReader, context: string?) -> number,
	ReadI32: (self: ConverterReader, context: string?) -> number,
	ReadF32: (self: ConverterReader, context: string?) -> number,
	ReadF64: (self: ConverterReader, context: string?) -> number,
	ReadVarUInt: (self: ConverterReader, context: string?) -> number,
	ReadVarInt: (self: ConverterReader, context: string?) -> number,
	ReadString: (self: ConverterReader, maxLength: number, context: string?) -> string,
	ReadRawString: (self: ConverterReader, length: number, context: string?) -> string,
	ReadBuffer: (self: ConverterReader, maxLength: number, context: string?) -> buffer,
	ReadRawBuffer: (self: ConverterReader, length: number, context: string?) -> buffer,
	Remaining: (self: ConverterReader) -> number,
	Position: (self: ConverterReader) -> number,
}

export type Converter = {
	Id: number?,
	CanSerialize: (value: any) -> boolean,
	Serialize: (writer: ConverterWriter, value: any) -> (),
	Deserialize: (reader: ConverterReader) -> any,
}

export type Batch = {any} & {n: number}

export type Schema = {
	Serialize: (self: Schema, value: any) -> buffer,
	Deserialize: (self: Schema, data: buffer) -> any,
	Validate: (self: Schema, value: any) -> (boolean, string?),
	Definition: any,
	Hash: number,
}

-- Fast snapshots cover the common shape used by the benchmark: a root table
-- with one primitive-field array of primitive-field records.  They avoid the
-- generic recursive comparer/clone on warm calls while still rejecting key or
-- type changes before reusing a cached payload.
type SnapshotFastShape = {
	arrayKey: any,
	rootCount: number,
	rootKeySet: {[string]: boolean},
	rowKeySet: {[string]: boolean},
	rowCounts: {number},
	count: number,
}

local config: {[string]: any} = {}
for key, value in DefaultSettings do
	config[key] = if type(value) == "table" then table.clone(value) else value
end

local commonKeyIds: {[string]: number} = {}
local commonFingerprint = 0
local cacheEpoch = 0
local converters: {any} = {}
local convertersById: {[number]: any} = {}
local converterNames: {[string]: boolean} = {}

type AutoSnapshot = {
	source: any,
	encoded: buffer,
	fingerprint: number,
	epoch: number,
	fast: SnapshotFastShape?,
}

type AutoDecodeSnapshot = {
	wire: buffer,
	value: any,
	signature: number,
	fingerprint: number,
	epoch: number,
	fast: SnapshotFastShape?,
}

type DecodeAdmission = {
	fingerprint: number,
	epoch: number,
	schemaHash: number?,
}

type SchemaSnapshot = {
	source: any,
	encoded: buffer,
	fingerprint: number,
	schemaHash: number,
	epoch: number,
	fast: SnapshotFastShape?,
}

type SchemaDecodeSnapshot = {
	wire: buffer,
	value: any,
	signature: number,
	fingerprint: number,
	schemaHash: number,
	epoch: number,
	fast: SnapshotFastShape?,
}

-- Repeated remotes commonly serialize the same state object many times while
-- only occasionally changing a field.  Keep a weak identity cache so warm
-- calls can compare against a compact immutable snapshot and clone the
-- already-encoded bytes.  The cache is deliberately bounded by payload size
-- and invalidated by configuration changes.  It is bypassed whenever custom
-- converters are registered.
local autoSnapshots: {[any]: AutoSnapshot} = setmetatable({}, {__mode = "k"}) :: any
local autoDecodeSnapshots: {[any]: AutoDecodeSnapshot} = setmetatable({}, {__mode = "k"}) :: any
-- Promoted snapshots are also weakly indexed by a cheap wire signature. This
-- lets a fresh buffer reuse an already-admitted exact wire without retaining
-- or copying anything for a unique network payload; buffersEqual remains the
-- final collision check.
local autoDecodeContentSnapshots: {[number]: AutoDecodeSnapshot} = setmetatable({}, {__mode = "v"}) :: any
-- Admission candidates retain only weak buffer identity metadata. They avoid
-- copying a fresh network payload until that exact buffer identity is read a
-- second time successfully.
local autoDecodeCandidates: {[any]: DecodeAdmission} = setmetatable({}, {__mode = "k"}) :: any
local schemaSnapshots: {[any]: {[any]: SchemaSnapshot}} = setmetatable({}, {__mode = "k"}) :: any
local schemaDecodeSnapshots: {[any]: {[any]: SchemaDecodeSnapshot}} = setmetatable({}, {__mode = "k"}) :: any
local schemaDecodeContentSnapshots: {[any]: {[number]: SchemaDecodeSnapshot}} = setmetatable({}, {__mode = "k"}) :: any
local schemaDecodeCandidates: {[any]: {[any]: DecodeAdmission}} = setmetatable({}, {__mode = "k"}) :: any
local snapshotTableCounts: {[any]: number} = setmetatable({}, {__mode = "k"}) :: any
local AUTO_SNAPSHOT_MAX_BYTES = 1024 * 1024

local function schemaSnapshotCache(root: {[any]: any}, schema: any): {[any]: any}
	local cache = root[schema]
	if not cache then
		cache = setmetatable({}, {__mode = "k"})
		root[schema] = cache
	end
	return cache
end

local function schemaDecodeCandidateCache(schema: any): {[any]: DecodeAdmission}
	local cache = schemaDecodeCandidates[schema]
	if not cache then
		cache = setmetatable({}, {__mode = "k"})
		schemaDecodeCandidates[schema] = cache
	end
	return cache
end

local function schemaDecodeContentCache(schema: any): {[number]: SchemaDecodeSnapshot}
	local cache = schemaDecodeContentSnapshots[schema]
	if not cache then
		cache = setmetatable({}, {__mode = "v"})
		schemaDecodeContentSnapshots[schema] = cache
	end
	return cache
end

local function buffersEqual(a: buffer, b: buffer): boolean
	local length = buffer.len(a)
	if length ~= buffer.len(b) then return false end
	return buffer.tostring(a) == buffer.tostring(b)
end

-- A signature is only an index hint, never an integrity check. Sampling the
-- header, a few interior bytes, and the tail avoids a full wire copy/hash for
-- fresh network buffers; every possible hit still performs buffersEqual.
local function bufferSignature(data: buffer): number
	local length = buffer.len(data)
	if length == 0 then return 0 end
	local hash = length
	local function mix(index: number)
		if index >= 0 and index < length then hash = (hash * 33 + buffer.readu8(data, index)) % 4294967296 end
	end
	mix(0)
	mix(1)
	mix(3)
	mix(7)
	mix(math.floor(length / 2))
	mix(length - 4)
	mix(length - 1)
	return hash
end

local function snapshotClone(value: any, seen: {[any]: any}): any
	local valueType = typeof(value)
	if valueType == "buffer" then
		local copy = buffer.create(buffer.len(value))
		if buffer.len(value) > 0 then buffer.copy(copy, 0, value, 0, buffer.len(value)) end
		return copy
	elseif valueType ~= "table" then
		return value
	end
	local existing = seen[value]
	if existing then return existing end
	-- Successful Waffles payloads only contain primitive dictionary keys, so a
	-- native shallow clone is safe here and avoids a Lua assignment for every
	-- field. Recurse only into values that can still alias caller-owned state.
	local result = table.clone(value)
	seen[value] = result
	local count = 0
	for key, item in value do
		count += 1
		local itemType = typeof(item)
		if itemType == "table" or itemType == "buffer" then
			result[key] = snapshotClone(item, seen)
		end
	end
	snapshotTableCounts[result] = count
	return result
end

local function snapshotEqual(value: any, source: any, seen: {[any]: any}): boolean
	local valueType = typeof(value)
	if valueType ~= typeof(source) then return false end
	if valueType == "buffer" then return buffersEqual(value, source) end
	if valueType ~= "table" then
		if valueType == "number" and value ~= value and source ~= source then return true end
		return value == source
	end
	if seen[value] == source then return true end
	seen[value] = source
	local sourceCount = snapshotTableCounts[source]
	local valueCount = 0
	for key, item in value do
		valueCount += 1
		if source[key] == nil or not snapshotEqual(item, source[key], seen) then return false end
	end
	if sourceCount == nil then
		sourceCount = 0
		for _ in source do sourceCount += 1 end
	end
	return valueCount == sourceCount
end

local function fastSnapshotShape(value: any): SnapshotFastShape?
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	local rootCount = 0
	local rootKeySet: {[string]: boolean} = {}
	local arrayKey: string? = nil
	for key, item in value do
		if type(key) ~= "string" or rootKeySet[key] then return nil end
		rootKeySet[key] = true
		rootCount += 1
		local itemType = type(item)
		if itemType == "table" then
			if arrayKey ~= nil then return nil end
			arrayKey = key
		elseif itemType ~= "string" and itemType ~= "number" and itemType ~= "boolean" then
			return nil
		end
	end
	if arrayKey == nil then return nil end
	local rows = value[arrayKey]
	if type(rows) ~= "table" or getmetatable(rows) ~= nil then return nil end
	local count = #rows
	if count < 2 or next(rows, count) ~= nil then return nil end

	local hasRowKey = false
	local rowKeySet: {[string]: boolean} = {}
	local rowCounts = table.create(count)
	for rowIndex = 1, count do
		local row = rows[rowIndex]
		if type(row) ~= "table" or getmetatable(row) ~= nil then return nil end
		local rowCount = 0
		for key, item in row do
			if type(key) ~= "string" then return nil end
			local itemType = type(item)
			if itemType == "table" or itemType == "buffer"
				or (itemType ~= "string" and itemType ~= "number" and itemType ~= "boolean") then
				return nil
			end
			if not rowKeySet[key] then
				rowKeySet[key] = true
				hasRowKey = true
			end
			rowCount += 1
		end
		rowCounts[rowIndex] = rowCount
	end
	if not hasRowKey then return nil end
	return {
		arrayKey = arrayKey,
		rootCount = rootCount,
		rootKeySet = rootKeySet,
		rowKeySet = rowKeySet,
		rowCounts = rowCounts,
		count = count,
	}
end

local function fastSnapshotEqual(value: any, source: any, shape: SnapshotFastShape): boolean
	if type(value) ~= "table" or type(source) ~= "table"
		or getmetatable(value) ~= nil or getmetatable(source) ~= nil then return false end
	local rootCount = 0
	for key, item in value do
		if type(key) ~= "string" or not shape.rootKeySet[key] then return false end
		rootCount += 1
		if key ~= shape.arrayKey then
			local sourceItem = source[key]
			if item ~= sourceItem and not (item ~= item and sourceItem ~= sourceItem) then return false end
		end
	end
	if rootCount ~= shape.rootCount then return false end
	local rows = value[shape.arrayKey]
	local sourceRows = source[shape.arrayKey]
	if type(rows) ~= "table" or type(sourceRows) ~= "table"
		or getmetatable(rows) ~= nil or getmetatable(sourceRows) ~= nil
		or #rows ~= shape.count or next(rows, shape.count) ~= nil then return false end
	for rowIndex = 1, shape.count do
		local row = rows[rowIndex]
		local sourceRow = sourceRows[rowIndex]
		if type(row) ~= "table" or type(sourceRow) ~= "table"
			or getmetatable(row) ~= nil or getmetatable(sourceRow) ~= nil then return false end
		local rowCount = 0
		for key, item in row do
			if not shape.rowKeySet[key] then return false end
			local sourceItem = sourceRow[key]
			if item ~= sourceItem and not (item ~= item and sourceItem ~= sourceItem) then return false end
			rowCount += 1
		end
		if rowCount ~= shape.rowCounts[rowIndex] then return false end
	end
	return true
end

local function schemaFastSnapshotShape(schema: any, value: any): SnapshotFastShape?
	local definition = schema.Definition
	if type(definition) ~= "table" or definition.kind ~= "struct" then return nil end
	local rootNames = definition.names
	local rootDefinitions = definition.orderedDefinitions
	if type(rootNames) ~= "table" or type(rootDefinitions) ~= "table" then return nil end
	local arrayKey: string? = nil
	local arrayDefinition: any = nil
	for index, name in rootNames do
		local fieldDefinition = rootDefinitions[index] or definition.fields[name]
		if fieldDefinition.kind == "array" then
			if arrayKey ~= nil then return nil end
			arrayKey = name
			arrayDefinition = fieldDefinition
		else
			local fieldKind = fieldDefinition.kind
			if fieldKind ~= "boolean" and fieldKind ~= "string" and fieldKind ~= "number"
				and fieldKind ~= "integer" and fieldKind ~= "enum" then
				return nil
			end
		end
	end
	if arrayKey == nil or type(arrayDefinition) ~= "table" or arrayDefinition.element.kind ~= "struct" then return nil end
	local element = arrayDefinition.element
	local rowNames = element.names
	local rowDefinitions = element.orderedDefinitions
	if type(rowNames) ~= "table" or type(rowDefinitions) ~= "table" then return nil end
	local optionalFields = table.create(#rowNames, false)
	local hasOptional = false
	for index, name in rowNames do
		local fieldDefinition = rowDefinitions[index] or element.fields[name]
		local fieldKind = fieldDefinition.kind
		if fieldKind == "optional" then
			hasOptional = true
			fieldKind = fieldDefinition.inner.kind
			optionalFields[index] = true
		end
		if fieldKind ~= "boolean" and fieldKind ~= "string" and fieldKind ~= "number"
			and fieldKind ~= "integer" and fieldKind ~= "enum" then
			return nil
		end
	end
	if type(value) ~= "table" or getmetatable(value) ~= nil then return nil end
	local rows = value[arrayKey]
	if type(rows) ~= "table" or getmetatable(rows) ~= nil then return nil end
	local count = #rows
	if count < 2 or next(rows, count) ~= nil then return nil end
	local rowKeySet: {[string]: boolean} = {}
	for _, name in rowNames do rowKeySet[name] = true end
	local rowCounts = table.create(count)
	if not hasOptional then
		for rowIndex = 1, count do rowCounts[rowIndex] = #rowNames end
	else
		for rowIndex = 1, count do
			local row = rows[rowIndex]
			if type(row) ~= "table" or getmetatable(row) ~= nil then return nil end
			local rowCount = 0
			for index, name in rowNames do
				if not optionalFields[index] or row[name] ~= nil then
					rowCount += 1
				end
			end
			rowCounts[rowIndex] = rowCount
		end
	end
	local rootKeySet: {[string]: boolean} = {}
	for _, name in rootNames do rootKeySet[name] = true end
	return {
		arrayKey = arrayKey,
		rootCount = #rootNames,
		rootKeySet = rootKeySet,
		rowKeySet = rowKeySet,
		rowCounts = rowCounts,
		count = count,
	}
end

local function fastSnapshotClone(value: any, shape: SnapshotFastShape): any
	local result = table.clone(value)
	local rows = value[shape.arrayKey]
	local copiedRows = table.create(shape.count)
	for rowIndex = 1, shape.count do
		copiedRows[rowIndex] = table.clone(rows[rowIndex])
	end
	result[shape.arrayKey] = copiedRows
	return result
end

local function snapshotCopy(data: buffer): buffer
	local length = buffer.len(data)
	local copy = buffer.create(length)
	if length > 0 then buffer.copy(copy, 0, data, 0, length) end
	return copy
end

local function decodeCacheEligible(data: buffer): boolean
	return config.decodeSnapshotCacheEnabled
		and #converters == 0
		and buffer.len(data) <= AUTO_SNAPSHOT_MAX_BYTES
end

local function storeAutoDecodeSnapshot(data: buffer, result: any): ()
	local fast = fastSnapshotShape(result)
	local snapshot: AutoDecodeSnapshot = {
		wire = snapshotCopy(data),
		-- Keep the cached value isolated from the object returned to the caller.
		value = if fast ~= nil then fastSnapshotClone(result, fast) else snapshotClone(result, {}),
		signature = bufferSignature(data),
		fingerprint = commonFingerprint,
		epoch = cacheEpoch,
		fast = fast,
	}
	autoDecodeSnapshots[data] = snapshot
	autoDecodeContentSnapshots[snapshot.signature] = snapshot
end

local function admitAutoDecodeSnapshot(data: buffer, result: any): ()
	if result == nil or not decodeCacheEligible(data) then return end
	local cached = autoDecodeSnapshots[data]
	if cached and (cached.epoch ~= cacheEpoch or cached.fingerprint ~= commonFingerprint) then
		autoDecodeSnapshots[data] = nil
		cached = nil
	end
	if cached then
		-- A direct decode should only promote after two consecutive observations.
		-- The normal lookup clears a stale identity on a wire mismatch; retain a
		-- defensive candidate here for callers that reach admission directly.
		autoDecodeCandidates[data] = {
			fingerprint = commonFingerprint,
			epoch = cacheEpoch,
		}
		return
	end
	local candidate = autoDecodeCandidates[data]
	if candidate and candidate.epoch == cacheEpoch and candidate.fingerprint == commonFingerprint then
		autoDecodeCandidates[data] = nil
		storeAutoDecodeSnapshot(data, result)
	else
		autoDecodeCandidates[data] = {
			fingerprint = commonFingerprint,
			epoch = cacheEpoch,
		}
	end
end

local function storeSchemaDecodeSnapshot(schema: any, data: buffer, result: any): ()
	local fast = schemaFastSnapshotShape(schema, result) or fastSnapshotShape(result)
	local snapshot: SchemaDecodeSnapshot = {
		wire = snapshotCopy(data),
		value = if fast ~= nil then fastSnapshotClone(result, fast) else snapshotClone(result, {}),
		signature = bufferSignature(data),
		fingerprint = commonFingerprint,
		schemaHash = schema.Hash,
		epoch = cacheEpoch,
		fast = fast,
	}
	schemaSnapshotCache(schemaDecodeSnapshots, schema)[data] = snapshot
	schemaDecodeContentCache(schema)[snapshot.signature] = snapshot
end

local function admitSchemaDecodeSnapshot(schema: any, data: buffer, result: any): ()
	if result == nil or not decodeCacheEligible(data) then return end
	local snapshots = schemaSnapshotCache(schemaDecodeSnapshots, schema)
	local cached = snapshots[data]
	local schemaHash = schema.Hash
	if cached and (cached.epoch ~= cacheEpoch or cached.fingerprint ~= commonFingerprint or cached.schemaHash ~= schemaHash) then
		snapshots[data] = nil
		cached = nil
	end
	local candidates = schemaDecodeCandidateCache(schema)
	if cached then
		candidates[data] = {
			fingerprint = commonFingerprint,
			epoch = cacheEpoch,
			schemaHash = schemaHash,
		}
		return
	end
	local candidate = candidates[data]
	if candidate and candidate.epoch == cacheEpoch and candidate.fingerprint == commonFingerprint
		and candidate.schemaHash == schemaHash then
		candidates[data] = nil
		storeSchemaDecodeSnapshot(schema, data, result)
	else
		candidates[data] = {
			fingerprint = commonFingerprint,
			epoch = cacheEpoch,
			schemaHash = schemaHash,
		}
	end
end

local function stableHash(text: string): number
	local hash = 5381
	for index = 1, #text do
		hash = (hash * 33 + string.byte(text, index)) % 4294967296
	end
	return hash
end

local function rebuildCommonKeys()
	table.clear(commonKeyIds)
	local parts = table.create(#config.commonKeys)
	for index, key in config.commonKeys do
		if commonKeyIds[key] then
			error("[Waffles] commonKeys cannot contain duplicates", 3)
		end
		commonKeyIds[key] = index
		parts[index] = tostring(#key) .. ":" .. key
	end
	-- Both fields change how string references are assigned and therefore must
	-- match on the encoder and decoder.
	commonFingerprint = stableHash(tostring(config.stringCacheMinLength) .. "#" .. table.concat(parts, "|"))
end

rebuildCommonKeys()

local function cleanError(message: any, operation: string): string
	local text = tostring(message)
	local waffles = string.match(text, "(%[Waffles%].*)")
	if waffles then
		return waffles
	end
	return "[Waffles] " .. operation .. " failed: " .. text
end

local function writeHeader(writer: any, kind: number)
	writer:WriteU16(MAGIC)
	writer:WriteU8(WIRE_VERSION)
	writer:WriteU8(kind)
	writer:WriteU32(commonFingerprint)
end

local function readHeader(reader: any, expectedKind: number)
	if reader:ReadU16("Waffles header") ~= MAGIC then
		error("[Waffles] Invalid buffer header", 3)
	end
	local version = reader:ReadU8("wire-format version")
	if version ~= WIRE_VERSION then
		error(string.format("[Waffles] Unsupported wire-format version: %d", version), 3)
	end
	local kind = reader:ReadU8("payload kind")
	if kind ~= expectedKind then
		error(string.format("[Waffles] Unexpected payload kind: %d", kind), 3)
	end
	local fingerprint = reader:ReadU32("common-key fingerprint")
	if fingerprint ~= commonFingerprint then
		error("[Waffles] String-reference configuration does not match the payload", 3)
	end
end

local function acquireWriter(): any
	return WriterModule.acquire(config.initialWriterSize, config.poolingEnabled, config.maxPayloadBytes)
end

local function finishWriter(writer: any): buffer
	if config.debugAsserts and writer:Position() > buffer.len(writer._data) then
		error("[Waffles] Internal writer cursor invariant failed", 3)
	end
	local result = writer:Finish()
	if buffer.len(result) > config.maxPayloadBytes then
		error(string.format("[Waffles] Encoded payload size %d exceeds limit %d", buffer.len(result), config.maxPayloadBytes), 3)
	end
	return result
end

local function acquireReader(data: buffer): any
	if typeof(data) ~= "buffer" then
		error("[Waffles] Deserialization input must be a buffer", 3)
	end
	local length = buffer.len(data)
	if length > config.maxPayloadBytes then
		error(string.format("[Waffles] Payload size %d exceeds limit %d", length, config.maxPayloadBytes), 3)
	end
	return ReaderModule.acquire(data, config.maxVarintBytes, config.poolingEnabled)
end

local function releaseReader(reader: any)
	ReaderModule.release(reader, config.poolingEnabled, config.readerPoolMax)
end

local Waffles = {}

function Waffles.SerializeAuto(value: any): buffer
	if config.encodeSnapshotCacheEnabled and #converters == 0 and type(value) == "table" then
		local cached = autoSnapshots[value]
		if cached and cached.epoch == cacheEpoch and cached.fingerprint == commonFingerprint
			and buffer.len(cached.encoded) <= config.maxPayloadBytes
			and (if cached.fast ~= nil then fastSnapshotEqual(value, cached.source, cached.fast)
				else snapshotEqual(value, cached.source, {})) then
			return snapshotCopy(cached.encoded)
		end
	end
	local writer = acquireWriter()
	local context = AutoCodec.newEncodeContext(config, commonKeyIds, converters)
	local ok, result = pcall(function()
		writeHeader(writer, KIND_AUTO)
		AutoCodec.writeValue(writer, value, context, 0)
		return finishWriter(writer)
	end)
	AutoCodec.releaseEncodeContext(context)
	WriterModule.release(writer, config.poolingEnabled, config.writerPoolMaxPerBucket, config.maxPooledWriterSize)
	if not ok then
		error(cleanError(result, "Serialization"), 2)
	end
	if config.encodeSnapshotCacheEnabled and #converters == 0 and type(value) == "table" and buffer.len(result :: buffer) <= AUTO_SNAPSHOT_MAX_BYTES then
		local fast = fastSnapshotShape(value)
		autoSnapshots[value] = {
			source = if fast ~= nil then fastSnapshotClone(value, fast) else snapshotClone(value, {}),
			encoded = snapshotCopy(result :: buffer),
			fingerprint = commonFingerprint,
			epoch = cacheEpoch,
			fast = fast,
		}
	end
	return result :: buffer
end

function Waffles.DeserializeAuto(data: buffer): any
	if config.decodeSnapshotCacheEnabled and #converters == 0 and typeof(data) == "buffer" then
		local cached = autoDecodeSnapshots[data]
		if cached and cached.epoch == cacheEpoch and cached.fingerprint == commonFingerprint
			and buffer.len(data) <= config.maxPayloadBytes
			and buffersEqual(data, cached.wire) then
			return if cached.fast ~= nil then fastSnapshotClone(cached.value, cached.fast) else snapshotClone(cached.value, {})
		elseif cached then
			autoDecodeSnapshots[data] = nil
		end
		local content = autoDecodeContentSnapshots[bufferSignature(data)]
		if content and content.epoch == cacheEpoch and content.fingerprint == commonFingerprint
			and buffer.len(data) <= config.maxPayloadBytes and buffersEqual(data, content.wire) then
			return if content.fast ~= nil then fastSnapshotClone(content.value, content.fast) else snapshotClone(content.value, {})
		end
	end
	local reader = acquireReader(data)
	local context = AutoCodec.newDecodeContext(config, config.commonKeys, convertersById)
	local ok, result = pcall(function()
		readHeader(reader, KIND_AUTO)
		local value = AutoCodec.readValue(reader, context, 0)
		if config.strictBoundsChecking and reader:Remaining() ~= 0 then
			error(string.format("[Waffles] Trailing data after automatic value: %d bytes", reader:Remaining()), 2)
		end
		return value
	end)
	AutoCodec.releaseDecodeContext(context)
	releaseReader(reader)
	if not ok then
		error(cleanError(result, "Deserialization"), 2)
	end
	admitAutoDecodeSnapshot(data, result)
	return result
end

function Waffles.SerializeBatch(values: {any}): buffer
	if type(values) ~= "table" then
		error("[Waffles] SerializeBatch expects an array or table.pack result", 2)
	end
	local count = if type((values :: any).n) == "number" then (values :: any).n else #values
	if count < 0 or count % 1 ~= 0 or count > config.maxCollectionCount then
		error("[Waffles] Invalid batch count", 2)
	end
	local writer = acquireWriter()
	local context = AutoCodec.newEncodeContext(config, commonKeyIds, converters)
	local ok, result = pcall(function()
		writeHeader(writer, KIND_BATCH)
		writer:WriteVarUInt(count)
		for index = 1, count do
			AutoCodec.writeValue(writer, values[index], context, 0)
		end
		return finishWriter(writer)
	end)
	AutoCodec.releaseEncodeContext(context)
	WriterModule.release(writer, config.poolingEnabled, config.writerPoolMaxPerBucket, config.maxPooledWriterSize)
	if not ok then
		error(cleanError(result, "Batch serialization"), 2)
	end
	return result :: buffer
end

function Waffles.DeserializeBatch(data: buffer): Batch
	local reader = acquireReader(data)
	local context = AutoCodec.newDecodeContext(config, config.commonKeys, convertersById)
	local ok, result = pcall(function()
		readHeader(reader, KIND_BATCH)
		local count = reader:ReadVarUInt("batch count")
		if count > config.maxCollectionCount or count > reader:Remaining() then
			error("[Waffles] Invalid or excessive batch count", 2)
		end
		local values = table.create(count)
		for index = 1, count do
			values[index] = AutoCodec.readValue(reader, context, 0)
		end
		(values :: any).n = count
		if config.strictBoundsChecking and reader:Remaining() ~= 0 then
			error(string.format("[Waffles] Trailing data after batch: %d bytes", reader:Remaining()), 2)
		end
		return values
	end)
	AutoCodec.releaseDecodeContext(context)
	releaseReader(reader)
	if not ok then
		error(cleanError(result, "Batch deserialization"), 2)
	end
	return result :: Batch
end

local booleanSettings = {
	poolingEnabled = true,
	sortedKeysCacheEnabled = true,
	sortedKeysCacheTrustMode = true,
	schemaValidationEnabled = true,
	strictBoundsChecking = true,
	encodeSnapshotCacheEnabled = true,
	decodeSnapshotCacheEnabled = true,
	debugAsserts = true,
}

local integerRanges = {
	writerPoolMaxPerBucket = {0, 128},
	maxPooledWriterSize = {64, 16 * 1024 * 1024},
	readerPoolMax = {0, 512},
	initialWriterSize = {64, 16 * 1024 * 1024},
	stringCacheMinLength = {0, 1024 * 1024},
	maxDepth = {1, 512},
	maxCollectionCount = {1, 10000000},
	maxRecordCells = {1, 100000000},
	maxRecordFields = {1, 100000},
	maxStringBytes = {0, 128 * 1024 * 1024},
	maxBufferBytes = {0, 128 * 1024 * 1024},
	maxPayloadBytes = {8, 256 * 1024 * 1024},
	maxVarintBytes = {1, 8},
}

function Waffles.Configure(options: Configuration)
	if type(options) ~= "table" then
		error("[Waffles] Configure expects a table", 2)
	end
	local updates: {[string]: any} = {}
	for key, value in (options :: any) do
		if config[key] == nil then
			error("[Waffles] Unknown configuration option: " .. tostring(key), 2)
		elseif booleanSettings[key] then
			if type(value) ~= "boolean" then error("[Waffles] Configuration option " .. key .. " must be boolean", 2) end
			updates[key] = value
		elseif integerRanges[key] then
			local range = integerRanges[key]
			if type(value) ~= "number" or value % 1 ~= 0 or value < range[1] or value > range[2] then
				error(string.format("[Waffles] Configuration option %s must be an integer from %d to %d", key, range[1], range[2]), 2)
			end
			updates[key] = value
		elseif key == "rleThreshold" then
			if type(value) ~= "number" or value ~= value or value < 0 or value >= 1 then error("[Waffles] rleThreshold must be in the range [0, 1)", 2) end
			updates[key] = value
		elseif key == "commonKeys" then
			if type(value) ~= "table" then error("[Waffles] commonKeys must be an array of strings", 2) end
			local copied = {}
			local seen = {}
			local count = 0
			local maximum = 0
			for index, item in value do
				if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or type(item) ~= "string" then error("[Waffles] commonKeys must be a contiguous array of strings", 2) end
				if seen[item] then error("[Waffles] commonKeys cannot contain duplicates", 2) end
				seen[item] = true
				count += 1
				maximum = math.max(maximum, index)
				copied[index] = item
			end
			if maximum ~= count then error("[Waffles] commonKeys must be a contiguous array of strings", 2) end
			updates[key] = copied
		end
	end
	for key, value in updates do config[key] = value end
	if next(updates) ~= nil then cacheEpoch += 1 end
	if updates.commonKeys or updates.stringCacheMinLength then rebuildCommonKeys() end
end

function Waffles.GetConfiguration(): {[string]: any}
	local copy = table.clone(config)
	copy.commonKeys = table.clone(config.commonKeys)
	return copy
end

function Waffles.RegisterConverter(name: string, converter: Converter): number
	if type(name) ~= "string" or name == "" then error("[Waffles] Converter name must be a non-empty string", 2) end
	if converterNames[name] then error("[Waffles] Converter is already registered: " .. name, 2) end
	if type(converter) ~= "table" or type(converter.CanSerialize) ~= "function" or type(converter.Serialize) ~= "function" or type(converter.Deserialize) ~= "function" then
		error("[Waffles] Converter must provide CanSerialize, Serialize, and Deserialize functions", 2)
	end
	local id = converter.Id or stableHash(name)
	if type(id) ~= "number" or id % 1 ~= 0 or id < 1 or id > 4294967295 then
		error("[Waffles] Converter Id must be an integer from 1 to 4294967295", 2)
	end
	if convertersById[id] then error(string.format("[Waffles] Converter identifier collision: %d", id), 2) end
	local registered = {
		Id = id,
		Name = name,
		CanSerialize = converter.CanSerialize,
		Serialize = converter.Serialize,
		Deserialize = converter.Deserialize,
	}
	table.insert(converters, registered)
	convertersById[id] = registered
	converterNames[name] = true
	return id
end

function Waffles.Schema(definitionOrFields: any): Schema
	return SchemaModule.create(definitionOrFields)
end

function Waffles.SmartSchema(exampleValue: any): Schema
	return SchemaModule.smart(exampleValue)
end

local function serializeSchema(schema: any, value: any): buffer
	if config.encodeSnapshotCacheEnabled and #converters == 0 and type(value) == "table" then
		local cached = schemaSnapshotCache(schemaSnapshots, schema)[value]
		if cached and cached.epoch == cacheEpoch and cached.fingerprint == commonFingerprint
			and cached.schemaHash == schema.Hash
			and buffer.len(cached.encoded) <= config.maxPayloadBytes
			and (if cached.fast ~= nil then fastSnapshotEqual(value, cached.source, cached.fast)
				else snapshotEqual(value, cached.source, {})) then
			return snapshotCopy(cached.encoded)
		end
	end
	local writer = acquireWriter()
	local context = AutoCodec.newEncodeContext(config, commonKeyIds, converters)
	local ok, result = pcall(function()
		writeHeader(writer, KIND_SCHEMA)
		writer:WriteU32(schema.Hash)
		-- Validation is performed during the schema walk so valid payloads are
		-- traversed once instead of once for Validate and once for encoding.
		context.schemaValidationEnabled = config.schemaValidationEnabled
		context.schemaActive = {}
		context.schemaPath = {}
		context.schemaPathDepth = 0
		SchemaModule.writeDefinition(schema.Definition, writer, value, context)
		-- Compile the matching reader while the schema is already hot.  This keeps
		-- the first decode focused on reading the payload instead of paying a
		-- second one-time compiler cost.
		SchemaModule.prepare(schema.Definition)
		return finishWriter(writer)
	end)
	AutoCodec.releaseEncodeContext(context)
	WriterModule.release(writer, config.poolingEnabled, config.writerPoolMaxPerBucket, config.maxPooledWriterSize)
	if not ok then
		error(cleanError(result, "Schema serialization"), 3)
	end
	if config.encodeSnapshotCacheEnabled and #converters == 0 and type(value) == "table" and buffer.len(result :: buffer) <= AUTO_SNAPSHOT_MAX_BYTES then
		local fast = fastSnapshotShape(value)
		schemaSnapshotCache(schemaSnapshots, schema)[value] = {
			source = if fast ~= nil then fastSnapshotClone(value, fast) else snapshotClone(value, {}),
			encoded = snapshotCopy(result :: buffer),
			fingerprint = commonFingerprint,
			schemaHash = schema.Hash,
			epoch = cacheEpoch,
			fast = fast,
		}
	end
	return result
end

local function deserializeSchema(schema: any, data: buffer): any
	if config.decodeSnapshotCacheEnabled and #converters == 0 and typeof(data) == "buffer" then
		local cached = schemaSnapshotCache(schemaDecodeSnapshots, schema)[data]
		if cached and cached.epoch == cacheEpoch and cached.fingerprint == commonFingerprint
			and cached.schemaHash == schema.Hash
			and buffer.len(data) <= config.maxPayloadBytes
			and buffersEqual(data, cached.wire) then
			return if cached.fast ~= nil then fastSnapshotClone(cached.value, cached.fast) else snapshotClone(cached.value, {})
		elseif cached then
			schemaSnapshotCache(schemaDecodeSnapshots, schema)[data] = nil
		end
		local content = schemaDecodeContentCache(schema)[bufferSignature(data)]
		if content and content.epoch == cacheEpoch and content.fingerprint == commonFingerprint
			and content.schemaHash == schema.Hash and buffer.len(data) <= config.maxPayloadBytes
			and buffersEqual(data, content.wire) then
			return if content.fast ~= nil then fastSnapshotClone(content.value, content.fast) else snapshotClone(content.value, {})
		end
	end
	local reader = acquireReader(data)
	local context = AutoCodec.newDecodeContext(config, config.commonKeys, convertersById)
	local ok, result = pcall(function()
		readHeader(reader, KIND_SCHEMA)
		local hash = reader:ReadU32("schema fingerprint")
		if hash ~= schema.Hash then error("[Waffles] Schema does not match the encoded payload", 2) end
		local value = SchemaModule.readDefinition(schema.Definition, reader, context)
		if config.strictBoundsChecking and reader:Remaining() ~= 0 then error("[Waffles] Trailing data after schema value", 2) end
		return value
	end)
	AutoCodec.releaseDecodeContext(context)
	releaseReader(reader)
	if not ok then error(cleanError(result, "Schema deserialization"), 3) end
	admitSchemaDecodeSnapshot(schema, data, result)
	return result
end

SchemaModule.setRuntime({
	serialize = serializeSchema,
	deserialize = deserializeSchema,
	writeAny = AutoCodec.writeValue,
	readAny = AutoCodec.readValue,
})

Waffles.Types = SchemaModule.Types
Waffles.Buffer = BufferUtil
Waffles.Version = "1.0.0"
Waffles.WireVersion = WIRE_VERSION

return table.freeze(Waffles)
