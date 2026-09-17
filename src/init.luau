--!strict

local DefaultSettings = require(script.Settings)
local WriterModule = require(script.Internal.Writer)
local ReaderModule = require(script.Internal.Reader)
local AutoCodec = require(script.Internal.AutoCodec)
local SchemaModule = require(script.Internal.Schema)
local BufferUtil = require(script.Internal.BufferUtil)

local MAGIC = 0x5746
local WIRE_VERSION = 1
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
	maxDepth: number?,
	maxCollectionCount: number?,
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

local config: {[string]: any} = {}
for key, value in DefaultSettings do
	config[key] = if type(value) == "table" then table.clone(value) else value
end

local commonKeyIds: {[string]: number} = {}
local commonFingerprint = 0
local converters: {any} = {}
local convertersById: {[number]: any} = {}
local converterNames: {[string]: boolean} = {}

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
	local writer = acquireWriter()
	local ok, result = pcall(function()
		writeHeader(writer, KIND_AUTO)
		local context = AutoCodec.newEncodeContext(config, commonKeyIds, converters)
		AutoCodec.writeValue(writer, value, context, 0)
		return finishWriter(writer)
	end)
	WriterModule.release(writer, config.poolingEnabled, config.writerPoolMaxPerBucket, config.maxPooledWriterSize)
	if not ok then
		error(cleanError(result, "Serialization"), 2)
	end
	return result :: buffer
end

function Waffles.DeserializeAuto(data: buffer): any
	local reader = acquireReader(data)
	local ok, result = pcall(function()
		readHeader(reader, KIND_AUTO)
		local context = AutoCodec.newDecodeContext(config, config.commonKeys, convertersById)
		local value = AutoCodec.readValue(reader, context, 0)
		if config.strictBoundsChecking and reader:Remaining() ~= 0 then
			error(string.format("[Waffles] Trailing data after automatic value: %d bytes", reader:Remaining()), 2)
		end
		return value
	end)
	releaseReader(reader)
	if not ok then
		error(cleanError(result, "Deserialization"), 2)
	end
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
	local ok, result = pcall(function()
		writeHeader(writer, KIND_BATCH)
		writer:WriteVarUInt(count)
		local context = AutoCodec.newEncodeContext(config, commonKeyIds, converters)
		for index = 1, count do
			AutoCodec.writeValue(writer, values[index], context, 0)
		end
		return finishWriter(writer)
	end)
	WriterModule.release(writer, config.poolingEnabled, config.writerPoolMaxPerBucket, config.maxPooledWriterSize)
	if not ok then
		error(cleanError(result, "Batch serialization"), 2)
	end
	return result :: buffer
end

function Waffles.DeserializeBatch(data: buffer): Batch
	local reader = acquireReader(data)
	local ok, result = pcall(function()
		readHeader(reader, KIND_BATCH)
		local count = reader:ReadVarUInt("batch count")
		if count > config.maxCollectionCount or count > reader:Remaining() then
			error("[Waffles] Invalid or excessive batch count", 2)
		end
		local values = table.create(count)
		local context = AutoCodec.newDecodeContext(config, config.commonKeys, convertersById)
		for index = 1, count do
			values[index] = AutoCodec.readValue(reader, context, 0)
		end
		(values :: any).n = count
		if config.strictBoundsChecking and reader:Remaining() ~= 0 then
			error(string.format("[Waffles] Trailing data after batch: %d bytes", reader:Remaining()), 2)
		end
		return values
	end)
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
	if config.schemaValidationEnabled then
		local valid, message = schema:Validate(value)
		if not valid then error(message, 3) end
	end
	local writer = acquireWriter()
	local ok, result = pcall(function()
		writeHeader(writer, KIND_SCHEMA)
		writer:WriteU32(schema.Hash)
		local context = AutoCodec.newEncodeContext(config, commonKeyIds, converters)
		SchemaModule.writeDefinition(schema.Definition, writer, value, context)
		return finishWriter(writer)
	end)
	WriterModule.release(writer, config.poolingEnabled, config.writerPoolMaxPerBucket, config.maxPooledWriterSize)
	if not ok then
		error(cleanError(result, "Schema serialization"), 3)
	end
	return result
end

local function deserializeSchema(schema: any, data: buffer): any
	local reader = acquireReader(data)
	local ok, result = pcall(function()
		readHeader(reader, KIND_SCHEMA)
		local hash = reader:ReadU32("schema fingerprint")
		if hash ~= schema.Hash then error("[Waffles] Schema does not match the encoded payload", 2) end
		local context = AutoCodec.newDecodeContext(config, config.commonKeys, convertersById)
		local value = SchemaModule.readDefinition(schema.Definition, reader, context)
		if config.strictBoundsChecking and reader:Remaining() ~= 0 then error("[Waffles] Trailing data after schema value", 2) end
		return value
	end)
	releaseReader(reader)
	if not ok then error(cleanError(result, "Schema deserialization"), 3) end
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
