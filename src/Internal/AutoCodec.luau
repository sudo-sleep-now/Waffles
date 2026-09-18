--!strict

local Tags = require(script.Parent.Tags)

type Writer = any
type Reader = any
type Config = {[string]: any}
type Converter = {
	Id: number,
	Name: string,
	CanSerialize: (value: any) -> boolean,
	Serialize: (writer: Writer, value: any) -> (),
	Deserialize: (reader: Reader) -> any,
}

type EncodeContext = {
	config: Config,
	strings: {[string]: number},
	stringCount: number,
	layouts: {[string]: number},
	layoutCount: number,
	active: {[any]: boolean},
	commonKeyIds: {[string]: number},
	converters: {Converter},
	hasConverters: boolean,
	-- Schema encoding reuses the same context object but keeps a separate
	-- tagless string table and (when requested) an inline validation stack.
	schemaStrings: {[any]: any},
	schemaStringCount: number,
	compactStringCacheMin: number,
	schemaValidationEnabled: boolean?,
	schemaActive: {[any]: boolean}?,
	schemaPath: {string}?,
	schemaPathDepth: number?,
}

type DecodeContext = {
	config: Config,
	strings: {string},
	schemaStrings: {string},
	layouts: {{string}},
	commonKeys: {string},
	convertersById: {[number]: Converter},
	compactStringCacheMin: number,
}

local AutoCodec = {}
local floatScratch = buffer.create(4)
local mathAbs = math.abs
local mathFloor = math.floor
local bufferWriteF32 = buffer.writef32
local bufferReadF32 = buffer.readf32
local bufferReadU8 = buffer.readu8
local bufferReadF64 = buffer.readf64
local bufferReadString = buffer.readstring
local bit32Band = bit32.band
local encodeContextPool: {EncodeContext} = {}
local decodeContextPool: {DecodeContext} = {}
local MAX_CONTEXT_POOL = 16

local function checkDepth(config: Config, depth: number)
	if depth > config.maxDepth then
		error(string.format("[Waffles] Maximum nesting depth of %d exceeded", config.maxDepth), 3)
	end
end

local function writeCachedString(writer: Writer, value: string, context: EncodeContext, isKey: boolean)
	if isKey then
		local commonId = context.commonKeyIds[value]
		if commonId then
			writer:WriteU8(Tags.CommonKey)
			writer:WriteVarUInt(commonId)
			return
		end
	end

	local reference = context.strings[value]
	if reference then
		writer:WriteU8(Tags.StringReference)
		writer:WriteVarUInt(reference)
		return
	end

	writer:WriteU8(Tags.String)
	writer:WriteString(value)
	if #value >= context.config.stringCacheMinLength then
		context.stringCount += 1
		context.strings[value] = context.stringCount
	end
end

local function readCachedString(reader: Reader, context: DecodeContext, tag: number): string
	if tag == Tags.String then
		local value = reader:ReadString(context.config.maxStringBytes, "string")
		if #value >= context.config.stringCacheMinLength then
			table.insert(context.strings, value)
		end
		return value
	elseif tag == Tags.StringReference then
		local id = reader:ReadVarUInt("string reference")
		local value = context.strings[id]
		if value == nil then
			error(string.format("[Waffles] Invalid string reference: %d", id), 3)
		end
		return value
	elseif tag == Tags.CommonKey then
		local id = reader:ReadVarUInt("common-key reference")
		local value = context.commonKeys[id]
		if value == nil then
			error(string.format("[Waffles] Invalid common-key reference: %d", id), 3)
		end
		return value
	end
	error(string.format("[Waffles] Invalid string tag: %d", tag), 3)
end

local function isArray(value: {[any]: any}): (boolean, number)
	local count = 0
	local maximum = 0
	local array = true
	for key in value do
		count += 1
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			array = false
		elseif key > maximum then
			maximum = key
		end
	end
	return array and maximum == count, count
end

local function keyRank(value: any): number
	local kind = type(value)
	if kind == "boolean" then
		return 1
	elseif kind == "number" then
		return 2
	elseif kind == "string" then
		return 3
	end
	return 99
end

local function compareKeys(a: any, b: any): boolean
	local rankA = keyRank(a)
	local rankB = keyRank(b)
	if rankA ~= rankB then
		return rankA < rankB
	end
	if rankA == 1 then
		return a == false and b == true
	elseif rankA == 2 or rankA == 3 then
		return a < b
	end
	return false
end

local sortedKeyCache: {[any]: {keys: {any}, allStrings: boolean, count: number}} = setmetatable({}, {__mode = "k"}) :: any

local function sortedKeys(value: {[any]: any}, count: number, config: Config): ({any}, boolean)
	if config.sortedKeysCacheEnabled then
		local cached = sortedKeyCache[value]
		if cached and cached.count == count then
			if config.sortedKeysCacheTrustMode then
				local withinStringLimit = true
				for _, key in cached.keys do
					if type(key) == "string" and #key > config.maxStringBytes then
						withinStringLimit = false
						break
					end
				end
				if withinStringLimit then return cached.keys, cached.allStrings end
			end
			local valid = true
			for _, key in cached.keys do
				if value[key] == nil or (type(key) == "string" and #key > config.maxStringBytes) then valid = false; break end
			end
			if valid then return cached.keys, cached.allStrings end
		end
	end
	local keys = table.create(count)
	local allStrings = true
	for key in value do
		if keyRank(key) == 99 then
			error("[Waffles] Dictionary keys must be booleans, numbers, or strings", 3)
		end
		if type(key) ~= "string" then
			allStrings = false
		elseif #key > config.maxStringBytes then
			error(string.format("[Waffles] Dictionary key length %d exceeds limit %d", #key, config.maxStringBytes), 3)
		end
		keys[#keys + 1] = key
	end
	table.sort(keys, compareKeys)
	if config.sortedKeysCacheEnabled then
		sortedKeyCache[value] = {keys = keys, allStrings = allStrings, count = count}
	end
	return keys, allStrings
end

local function layoutSignature(keys: {any}, maximumBytes: number): string?
	local pieces = table.create(#keys)
	local totalBytes = 0
	for index, key in keys do
		local text = key :: string
		if #text > maximumBytes then return nil end
		local piece = tostring(#text) .. ":" .. text
		totalBytes += #piece + 1
		if totalBytes > maximumBytes then return nil end
		pieces[index] = piece
	end
	return table.concat(pieces, "|")
end

local function varUIntSize(value: number): number
	local size = 1
	while value >= 128 do
		value = math.floor(value / 128)
		size += 1
	end
	return size
end

local function tryWriteRle(writer: Writer, value: buffer, threshold: number): boolean
	local length = buffer.len(value)
	if length < 8 then
		return false
	end
	local runs = 0
	local encodedBytes = 0
	local cursor = 0
	while cursor < length do
		local byte = buffer.readu8(value, cursor)
		local runLength = 1
		while cursor + runLength < length and buffer.readu8(value, cursor + runLength) == byte do
			runLength += 1
		end
		runs += 1
		encodedBytes += varUIntSize(runLength) + 1
		cursor += runLength
	end
	if encodedBytes + varUIntSize(runs) >= length * (1 - threshold) then
		return false
	end

	writer:WriteU8(Tags.BufferRle)
	writer:WriteVarUInt(length)
	writer:WriteVarUInt(runs)
	cursor = 0
	while cursor < length do
		local byte = buffer.readu8(value, cursor)
		local runLength = 1
		while cursor + runLength < length and buffer.readu8(value, cursor + runLength) == byte do
			runLength += 1
		end
		writer:WriteVarUInt(runLength)
		writer:WriteU8(byte)
		cursor += runLength
	end
	return true
end

local writeValue: (Writer, any, EncodeContext, number, boolean?) -> ()
local readValue: (Reader, DecodeContext, number) -> any

-- A very common automatic payload is an array of records with one stable set
-- of string keys (inventories, player lists, replicated entities, ...).  The
-- regular recursive path has to classify and sort every record.  Once the
-- array is known to be homogeneous, write the already-sorted layout directly
-- while retaining the exact v1 LayoutDefinition/LayoutReference format.
local function homogeneousLayout(value: {[any]: any}, count: number, config: Config): {any}?
	if count < 2 then
		return nil
	end
	local first = value[1]
	if typeof(first) ~= "table" then
		return nil
	end
	local firstArray, firstCount = isArray(first)
	if firstArray then
		return nil
	end
	local keys, allStrings = sortedKeys(first, firstCount, config)
	if not allStrings then
		return nil
	end
	local keyCount = #keys
	for index = 2, count do
		local item = value[index]
		if typeof(item) ~= "table" then
			return nil
		end
		local itemCount = 0
		for key in item do
			if type(key) ~= "string" then
				return nil
			end
			itemCount += 1
		end
		if itemCount ~= keyCount then
			return nil
		end
		for _, key in keys do
			if item[key] == nil then
				return nil
			end
		end
	end
	if layoutSignature(keys, math.min(config.maxPayloadBytes, 65536)) == nil then
		return nil
	end
	return keys
end

local function writeLayoutValues(writer: Writer, value: {[any]: any}, keys: {any}, context: EncodeContext, depth: number)
	if context.active[value] then
		error("[Waffles] Cyclic tables are not supported", 2)
	end
	context.active[value] = true
	for _, key in keys do
		writeValue(writer, value[key], context, depth + 1)
	end
	context.active[value] = nil
end

local function writeLayoutHeader(writer: Writer, keys: {any}, context: EncodeContext, depth: number, knownSignature: string?): number
	local signature = knownSignature or layoutSignature(keys, math.min(context.config.maxPayloadBytes, 65536))
	if signature == nil then
		return 0
	end
	local layoutId = context.layouts[signature]
	if layoutId then
		writer:WriteU8(Tags.LayoutReference)
		writer:WriteVarUInt(layoutId)
		return layoutId
	end
	context.layoutCount += 1
	layoutId = context.layoutCount
	context.layouts[signature] = layoutId
	writer:WriteU8(Tags.LayoutDefinition)
	writer:WriteVarUInt(#keys)
	for _, key in keys do
		writeValue(writer, key, context, depth + 1, true)
	end
	return layoutId
end

local COMPACT_STRING_REFERENCE_BASE = 2147483648
local COMPACT_STRING_CACHE_MIN = 4

local COMPACT_STRING = 1
local COMPACT_BOOLEAN = 2
local COMPACT_INTEGER = 3
local COMPACT_FLOAT32 = 4
local COMPACT_FLOAT64 = 5
-- String descriptors 1/129 remain readable for old payloads (where every
-- long string entered the dictionary).  New descriptors use a mode bit so a
-- column can explicitly opt out of caching one-off values such as unique ids.
local COMPACT_STRING_MODE = 32
local COMPACT_STRING_FAST = 16
local COMPACT_STRING_CACHE = 64

type CompactRecordPlan = {
	keys: {string},
	keyIndices: {[string]: number},
	kinds: {number},
	optional: {boolean},
	stringCached: {boolean},
	requiredCount: number,
}

local compactPlanCache: {[any]: {count: number, plan: CompactRecordPlan}} = setmetatable({}, {__mode = "k"}) :: any

local function writeCompactString(
	writer: Writer,
	value: string,
	context: EncodeContext,
	writeU8: (Writer, number) -> (),
	writeVarUInt: (Writer, number) -> (),
	writeRawString: (Writer, string) -> (),
	cacheEnabled: boolean,
	fastFraming: boolean
)
	if #value > context.config.maxStringBytes then
		error(string.format("[Waffles] String length %d exceeds limit %d", #value, context.config.maxStringBytes), 2)
	end
	local strings = context.schemaStrings
	if cacheEnabled then
		local reference = strings[value]
		if reference then
			if fastFraming then
				-- 254 is reserved for a compact dictionary reference.  Encoding the
				-- small id directly avoids the five-byte 2^31-based varint used by
				-- the legacy framing.
				writeU8(writer, 254)
				writeVarUInt(writer, reference)
			else
				writeVarUInt(writer, COMPACT_STRING_REFERENCE_BASE + reference)
			end
			return
		end
	end
	local length = #value
	if fastFraming then
		if length < 254 then
			writeU8(writer, length)
		else
			writeU8(writer, 255)
			writeVarUInt(writer, length)
		end
	else
		writeVarUInt(writer, length)
	end
	if length > 0 then writeRawString(writer, value) end
	if cacheEnabled and length >= context.compactStringCacheMin then
		context.schemaStringCount += 1
		strings[value] = context.schemaStringCount
	end
end

local function readCompactString(
	reader: Reader,
	context: DecodeContext,
	readU8: (Reader, string?) -> number,
	readVarUInt: (Reader, string?) -> number,
	readRawString: (Reader, number, string?) -> string,
	cacheEnabled: boolean,
	fastFraming: boolean
): string
	local code: number
	if fastFraming then
		local first = readU8(reader, "compact string length")
		if first == 254 then
			if not cacheEnabled then error("[Waffles] Unexpected compact string reference in uncached column", 3) end
			local id = readVarUInt(reader, "compact string reference")
			local value = context.schemaStrings[id]
			if value == nil then error(string.format("[Waffles] Invalid compact string reference: %d", id), 3) end
			return value
		elseif first == 255 then
			code = readVarUInt(reader, "compact string length")
		else
			code = first
		end
	else
		code = readVarUInt(reader, "compact string length")
	end
	if code >= COMPACT_STRING_REFERENCE_BASE then
		if fastFraming or not cacheEnabled then error("[Waffles] Unexpected compact string reference in uncached column", 3) end
		local id = code - COMPACT_STRING_REFERENCE_BASE
		-- Compact record strings use their own table.  Mixing it with automatic
		-- String tags would let equal numeric ids resolve to the wrong spelling.
		local value = context.schemaStrings[id]
		if value == nil then error(string.format("[Waffles] Invalid compact string reference: %d", id), 3) end
		return value
	end
	if code > context.config.maxStringBytes then
		error(string.format("[Waffles] Declared compact string length %d exceeds limit %d", code, context.config.maxStringBytes), 2)
	end
	local value = readRawString(reader, code, "compact string")
	if cacheEnabled and #value >= context.compactStringCacheMin then
		local strings = (context :: any).schemaStrings
		strings[#strings + 1] = value
	end
	return value
end

local function compactNumberKind(value: any): number?
	if type(value) ~= "number" then return nil end
	if value % 1 == 0 and mathAbs(value) <= 4503599627370495
		and not (value == 0 and 1 / value == -math.huge) then
		return COMPACT_INTEGER
	end
	bufferWriteF32(floatScratch, 0, value)
	if bufferReadF32(floatScratch, 0) == value then return COMPACT_FLOAT32 end
	return COMPACT_FLOAT64
end

local function compactFieldKind(value: any): number?
	local valueType = type(value)
	if valueType == "string" then return COMPACT_STRING end
	if valueType == "boolean" then return COMPACT_BOOLEAN end
	if valueType == "number" then return compactNumberKind(value) end
	return nil
end

local function buildCompactRecordPlan(values: {[any]: any}, count: number, config: Config): CompactRecordPlan?
	if count < 2 then return nil end
	-- Infer each column while discovering the union of row keys.  The previous
	-- implementation walked every row once to collect keys and then once per
	-- field to infer kinds; keeping the small per-field accumulator here makes a
	-- cold plan build one pass over the records instead of two.
	local infos: {[string]: any} = {}
	local keys: {string} = {}
	for rowIndex = 1, count do
		local row = values[rowIndex]
		if type(row) ~= "table" then return nil end
		for key, item in row do
			if type(key) ~= "string" then return nil end
			if #key > config.maxStringBytes then return nil end
			local info = infos[key]
			if info == nil then
				if #keys >= config.maxRecordFields then return nil end
				info = {present = 0, kind = nil, valid = true, seen = nil, repeated = false}
				infos[key] = info
				keys[#keys + 1] = key
			end
			info.present += 1
			local itemKind = compactFieldKind(item)
			if itemKind == nil then return nil end
			if itemKind == COMPACT_STRING and #item > config.maxStringBytes then return nil end
			if itemKind == COMPACT_STRING then
				local seen = info.seen
				if seen == nil then
					seen = {}
					info.seen = seen
				end
				if seen[item] then info.repeated = true else seen[item] = true end
			end
			local sampleKind = info.kind
			if sampleKind == nil then
				info.kind = itemKind
			elseif itemKind ~= sampleKind then
				-- Integer and floating values can share a lossless f64 column;
				-- other kind changes make the record dynamic.
				if (sampleKind == COMPACT_INTEGER or sampleKind == COMPACT_FLOAT32 or sampleKind == COMPACT_FLOAT64)
					and (itemKind == COMPACT_INTEGER or itemKind == COMPACT_FLOAT32 or itemKind == COMPACT_FLOAT64) then
					info.kind = COMPACT_FLOAT64
				else
					info.valid = false
				end
			end
		end
	end
	if #keys == 0 then return nil end
	table.sort(keys)
	local keyIndices: {[string]: number} = {}
	local kinds = table.create(#keys)
	local optional = table.create(#keys, false)
	local stringCached = table.create(#keys, false)
	local requiredCount = 0
	for fieldIndex, key in keys do
		local info = infos[key]
		if not info.valid or info.kind == nil then return nil end
		keyIndices[key] = fieldIndex
		kinds[fieldIndex] = info.kind
		local isOptional = info.present ~= count
		optional[fieldIndex] = isOptional
		stringCached[fieldIndex] = info.kind == COMPACT_STRING and info.repeated
		if not isOptional then requiredCount += 1 end
	end
	return {keys = keys, keyIndices = keyIndices, kinds = kinds, optional = optional, stringCached = stringCached, requiredCount = requiredCount}
end

local function compactNumberMatches(value: any, kind: number): boolean
	if type(value) ~= "number" then return false end
	if kind == COMPACT_INTEGER then
		return value % 1 == 0 and mathAbs(value) <= 4503599627370495
			and not (value == 0 and 1 / value == -math.huge)
	end
	if kind == COMPACT_FLOAT32 then
		bufferWriteF32(floatScratch, 0, value)
		return bufferReadF32(floatScratch, 0) == value
	end
	return true
end

-- Check the cached record shape in one pass over each row.  The key-index map
-- rejects additions/type changes while requiredCount catches missing required
-- fields; optional presence is read directly when the columns are emitted.
local function compactPlanMatches(values: {[any]: any}, count: number, plan: CompactRecordPlan, config: Config): boolean
	local keyIndices, kinds, optional = plan.keyIndices, plan.kinds, plan.optional
	if #plan.keys > config.maxRecordFields then return false end
	for _, key in plan.keys do
		if #key > config.maxStringBytes then return false end
	end
	for rowIndex = 1, count do
		local row = values[rowIndex]
		if type(row) ~= "table" then return false end
		-- A table cannot contain duplicate keys.  Validate the fields that are
		-- actually present in one pass; requiredSeen catches missing required
		-- fields without a second expected-key traversal or temporary `seen` table.
		local requiredSeen = 0
		for key, fieldValue in row do
			local fieldIndex = keyIndices[key]
			if fieldIndex == nil then return false end
			if not optional[fieldIndex] then requiredSeen += 1 end
			local kind = kinds[fieldIndex]
			if kind == COMPACT_STRING and type(fieldValue) ~= "string" then return false end
			if kind == COMPACT_STRING and #fieldValue > config.maxStringBytes then return false end
			if kind == COMPACT_BOOLEAN and type(fieldValue) ~= "boolean" then return false end
			if kind >= COMPACT_INTEGER and not compactNumberMatches(fieldValue, kind) then return false end
		end
		if requiredSeen ~= plan.requiredCount then return false end
	end
	return true
end

local function tryWriteCompactRecordArray(writer: Writer, values: {[any]: any}, count: number, context: EncodeContext): boolean
	local cached = compactPlanCache[values]
	local plan = if cached and cached.count == count and compactPlanMatches(values, count, cached.plan, context.config)
		then cached.plan else buildCompactRecordPlan(values, count, context.config)
	if plan == nil then return false end
	if #plan.keys > context.config.maxRecordFields
		or count > math.floor(context.config.maxRecordCells / #plan.keys) then
		-- Keep the aggregate limit symmetric with the decoder. The generic array
		-- representation remains available for callers that deliberately choose a
		-- larger shape, while a compact payload can never self-reject.
		return false
	end
	if cached == nil or cached.plan ~= plan then compactPlanCache[values] = {count = count, plan = plan} end
	local fastWriter = (writer :: any)._fast
	local writeTarget: any = writer
	local writeU8: any
	local writeVarUInt: any
	local writeF32: any
	local writeF64: any
	local writeRawString: any
	if fastWriter ~= nil then
		fastWriter.Begin()
		writeTarget = fastWriter
		writeU8 = fastWriter.WriteU8
		-- All compact lengths, counts, references, and integer columns have
		-- already been range-checked while building/matching the plan.
		writeVarUInt = fastWriter.WriteVarUIntUnchecked
		writeF32 = fastWriter.WriteF32
		writeF64 = fastWriter.WriteF64
		writeRawString = fastWriter.WriteRawString
	else
		writeU8 = writer.WriteU8
		writeVarUInt = writer.WriteVarUInt
		writeF32 = writer.WriteF32
		writeF64 = writer.WriteF64
		writeRawString = writer.WriteRawString
	end
	writeU8(writeTarget, Tags.TypedRecordArray)
	writeVarUInt(writeTarget, count)
	writeVarUInt(writeTarget, #plan.keys)
	for index, key in plan.keys do
		if #key > context.config.maxStringBytes then
			error(string.format("[Waffles] Dictionary key length %d exceeds limit %d", #key, context.config.maxStringBytes), 2)
		end
		writeVarUInt(writeTarget, #key)
		writeRawString(writeTarget, key)
		local kind = plan.kinds[index]
		if kind == COMPACT_STRING then
			kind += COMPACT_STRING_MODE + COMPACT_STRING_FAST
			if plan.stringCached[index] then kind += COMPACT_STRING_CACHE end
		end
		writeU8(writeTarget, kind + (plan.optional[index] and 128 or 0))
	end
	-- Optional columns use one presence bit per record instead of one marker
	-- byte per value.  Values themselves are written column-wise, improving
	-- cache locality in both directions.
	for fieldIndex, isOptional in plan.optional do
		if isOptional then
			local bits, bit = 0, 0
			for rowIndex = 1, count do
				if values[rowIndex][plan.keys[fieldIndex]] ~= nil then bits += 2 ^ bit end
				bit += 1
				if bit == 8 or rowIndex == count then
					writeU8(writeTarget, bits)
					bits, bit = 0, 0
				end
			end
		end
	end
	for fieldIndex, key in plan.keys do
		local kind = plan.kinds[fieldIndex]
		local isOptional = plan.optional[fieldIndex]
		-- Keep the kind branch outside the row loop.  A compact column is
		-- homogeneous by construction, so testing it for every value only adds
		-- dispatch overhead on large arrays.
		if kind == COMPACT_STRING then
			for rowIndex = 1, count do
				local fieldValue = values[rowIndex][key]
				if not isOptional or fieldValue ~= nil then
					writeCompactString(writeTarget, fieldValue, context, writeU8, writeVarUInt, writeRawString, plan.stringCached[fieldIndex], true)
				end
			end
		elseif kind == COMPACT_BOOLEAN then
			for rowIndex = 1, count do
				local fieldValue = values[rowIndex][key]
				if not isOptional or fieldValue ~= nil then writeU8(writeTarget, if fieldValue then 1 else 0) end
			end
		elseif kind == COMPACT_INTEGER then
			for rowIndex = 1, count do
				local fieldValue = values[rowIndex][key]
				if not isOptional or fieldValue ~= nil then
					local zigzag = if fieldValue >= 0 then fieldValue * 2 else -fieldValue * 2 - 1
					writeVarUInt(writeTarget, zigzag)
				end
			end
		elseif kind == COMPACT_FLOAT32 then
			for rowIndex = 1, count do
				local fieldValue = values[rowIndex][key]
				if not isOptional or fieldValue ~= nil then writeF32(writeTarget, fieldValue) end
			end
		else
			for rowIndex = 1, count do
				local fieldValue = values[rowIndex][key]
				if not isOptional or fieldValue ~= nil then writeF64(writeTarget, fieldValue) end
			end
		end
	end
	if fastWriter ~= nil then fastWriter.Finish() end
	return true
end

local function writeRoblox(writer: Writer, value: any, valueType: string, context: EncodeContext): boolean
	if valueType == "Vector2" then
		writer:WriteU8(Tags.Vector2)
		writer:WriteF32(value.X)
		writer:WriteF32(value.Y)
	elseif valueType == "Vector3" then
		writer:WriteU8(Tags.Vector3)
		writer:WriteF32(value.X)
		writer:WriteF32(value.Y)
		writer:WriteF32(value.Z)
	elseif valueType == "Vector2int16" then
		writer:WriteU8(Tags.Vector2int16)
		writer:WriteI16(value.X)
		writer:WriteI16(value.Y)
	elseif valueType == "Vector3int16" then
		writer:WriteU8(Tags.Vector3int16)
		writer:WriteI16(value.X)
		writer:WriteI16(value.Y)
		writer:WriteI16(value.Z)
	elseif valueType == "CFrame" then
		writer:WriteU8(Tags.CFrame)
		local components = {value:GetComponents()}
		for index = 1, 12 do
			writer:WriteF64(components[index])
		end
	elseif valueType == "Color3" then
		writer:WriteU8(Tags.Color3)
		writer:WriteF32(value.R)
		writer:WriteF32(value.G)
		writer:WriteF32(value.B)
	elseif valueType == "BrickColor" then
		writer:WriteU8(Tags.BrickColor)
		writer:WriteU16(value.Number)
	elseif valueType == "UDim" then
		writer:WriteU8(Tags.UDim)
		writer:WriteF32(value.Scale)
		writer:WriteVarInt(value.Offset)
	elseif valueType == "UDim2" then
		writer:WriteU8(Tags.UDim2)
		writer:WriteF32(value.X.Scale)
		writer:WriteVarInt(value.X.Offset)
		writer:WriteF32(value.Y.Scale)
		writer:WriteVarInt(value.Y.Offset)
	elseif valueType == "Rect" then
		writer:WriteU8(Tags.Rect)
		writer:WriteF32(value.Min.X)
		writer:WriteF32(value.Min.Y)
		writer:WriteF32(value.Max.X)
		writer:WriteF32(value.Max.Y)
	elseif valueType == "Ray" then
		writer:WriteU8(Tags.Ray)
		writer:WriteF32(value.Origin.X)
		writer:WriteF32(value.Origin.Y)
		writer:WriteF32(value.Origin.Z)
		writer:WriteF32(value.Direction.X)
		writer:WriteF32(value.Direction.Y)
		writer:WriteF32(value.Direction.Z)
	elseif valueType == "NumberRange" then
		writer:WriteU8(Tags.NumberRange)
		writer:WriteF32(value.Min)
		writer:WriteF32(value.Max)
	elseif valueType == "NumberSequenceKeypoint" then
		writer:WriteU8(Tags.NumberSequenceKeypoint)
		writer:WriteF32(value.Time)
		writer:WriteF32(value.Value)
		writer:WriteF32(value.Envelope)
	elseif valueType == "NumberSequence" then
		writer:WriteU8(Tags.NumberSequence)
		local points = value.Keypoints
		if #points > context.config.maxCollectionCount then error("[Waffles] NumberSequence has too many keypoints", 2) end
		writer:WriteVarUInt(#points)
		for _, point in points do
			writer:WriteF32(point.Time)
			writer:WriteF32(point.Value)
			writer:WriteF32(point.Envelope)
		end
	elseif valueType == "ColorSequenceKeypoint" then
		writer:WriteU8(Tags.ColorSequenceKeypoint)
		writer:WriteF32(value.Time)
		writer:WriteF32(value.Value.R)
		writer:WriteF32(value.Value.G)
		writer:WriteF32(value.Value.B)
	elseif valueType == "ColorSequence" then
		writer:WriteU8(Tags.ColorSequence)
		local points = value.Keypoints
		if #points > context.config.maxCollectionCount then error("[Waffles] ColorSequence has too many keypoints", 2) end
		writer:WriteVarUInt(#points)
		for _, point in points do
			writer:WriteF32(point.Time)
			writer:WriteF32(point.Value.R)
			writer:WriteF32(point.Value.G)
			writer:WriteF32(point.Value.B)
		end
	elseif valueType == "DateTime" then
		writer:WriteU8(Tags.DateTime)
		writer:WriteVarInt(value.UnixTimestampMillis)
	elseif valueType == "Font" then
		writer:WriteU8(Tags.Font)
		writeCachedString(writer, value.Family, context, false)
		writeCachedString(writer, value.Weight.Name, context, false)
		writeCachedString(writer, value.Style.Name, context, false)
	elseif valueType == "EnumItem" then
		writer:WriteU8(Tags.EnumItem)
		local enumText = tostring(value.EnumType)
		local enumTypeName = string.match(enumText, "^Enum%.(.+)$") or enumText
		if enumTypeName == "" or enumTypeName == "Enum" then
			error("[Waffles] Unable to identify EnumItem type", 2)
		end
		writeCachedString(writer, enumTypeName, context, false)
		writeCachedString(writer, value.Name, context, false)
	else
		return false
	end
	return true
end

writeValue = function(writer: Writer, value: any, context: EncodeContext, depth: number, isKey: boolean?)
	checkDepth(context.config, depth)

	if context.hasConverters then
		for _, converter in context.converters do
			if converter.CanSerialize(value) then
				writer:WriteU8(Tags.Custom)
				writer:WriteVarUInt(converter.Id)
				converter.Serialize(writer, value)
				return
			end
	end
	end

	local valueType = typeof(value)
	if value == nil then
		writer:WriteU8(Tags.Nil)
	elseif valueType == "boolean" then
		writer:WriteU8(if value then Tags.True else Tags.False)
	elseif valueType == "number" then
		if value ~= value then
			writer:WriteU8(Tags.Float64)
			writer:WriteF64(value)
		elseif value % 1 == 0 and math.abs(value) <= 4503599627370495 and not (value == 0 and 1 / value == -math.huge) then
			writer:WriteU8(Tags.Integer)
			writer:WriteVarInt(value)
		else
			buffer.writef32(floatScratch, 0, value)
			if buffer.readf32(floatScratch, 0) == value then
				writer:WriteU8(Tags.Float32)
				writer:WriteF32(value)
			else
				writer:WriteU8(Tags.Float64)
				writer:WriteF64(value)
			end
		end
	elseif valueType == "string" then
		if #value > context.config.maxStringBytes then
			error(string.format("[Waffles] String length %d exceeds limit %d", #value, context.config.maxStringBytes), 2)
		end
		writeCachedString(writer, value, context, isKey == true)
	elseif valueType == "buffer" then
		local length = buffer.len(value)
		if length > context.config.maxBufferBytes then
			error(string.format("[Waffles] Buffer length %d exceeds limit %d", length, context.config.maxBufferBytes), 2)
		end
		if not tryWriteRle(writer, value, context.config.rleThreshold) then
			writer:WriteU8(Tags.Buffer)
			writer:WriteBuffer(value)
		end
	elseif valueType == "table" then
		if context.active[value] then
			error("[Waffles] Cyclic tables are not supported", 2)
		end
		context.active[value] = true
		local array, count = isArray(value)
		if count > context.config.maxCollectionCount then
			context.active[value] = nil
			error(string.format("[Waffles] Table element count %d exceeds limit %d", count, context.config.maxCollectionCount), 2)
		end
		if array then
			if tryWriteCompactRecordArray(writer, value, count, context) then
				context.active[value] = nil
				return
			end
			writer:WriteU8(Tags.Array)
			writer:WriteVarUInt(count)
			local layoutKeys = homogeneousLayout(value, count, context.config)
			if layoutKeys then
				local signature = layoutSignature(layoutKeys, math.min(context.config.maxPayloadBytes, 65536))
				for index = 1, count do
					writeLayoutHeader(writer, layoutKeys, context, depth + 1, signature)
					writeLayoutValues(writer, value[index], layoutKeys, context, depth + 1)
				end
			else
				for index = 1, count do
					writeValue(writer, value[index], context, depth + 1)
				end
			end
		else
			local keys, allStrings = sortedKeys(value, count, context.config)
			local signature = if allStrings then layoutSignature(keys, math.min(context.config.maxPayloadBytes, 65536)) else nil
			if signature then
				writeLayoutHeader(writer, keys, context, depth, signature)
				-- The table is already marked active by the caller.  Keep this loop
				-- inline so maps do not pay an extra helper/table lookup.
				for _, key in keys do
					writeValue(writer, value[key], context, depth + 1)
				end
			else
				writer:WriteU8(Tags.Map)
				writer:WriteVarUInt(count)
				for _, key in keys do
					writeValue(writer, key, context, depth + 1, true)
					writeValue(writer, value[key], context, depth + 1)
				end
			end
		end
		context.active[value] = nil
	elseif not writeRoblox(writer, value, valueType, context) then
		error("[Waffles] Unsupported value type: " .. valueType, 2)
	end
end

local function checkedCount(reader: Reader, context: DecodeContext, label: string, minimumBytesPerItem: number): number
	local count = reader:ReadVarUInt(label .. " count")
	if count > context.config.maxCollectionCount then
		error(string.format("[Waffles] Declared %s count %d exceeds limit %d", label, count, context.config.maxCollectionCount), 3)
	end
	if count * minimumBytesPerItem > reader:Remaining() then
		error(string.format("[Waffles] Impossible %s count %d for remaining payload", label, count), 3)
	end
	return count
end

local function readCompactRecordArray(reader: Reader, context: DecodeContext): {any}
	local readU8 = reader.ReadU8
	local readString = reader.ReadString
	local count = checkedCount(reader, context, "typed record", 1)
	if count < 2 then error("[Waffles] Typed record array must contain at least two records", 2) end
	local fieldCount = checkedCount(reader, context, "typed record field", 2)
	if fieldCount == 0 then error("[Waffles] Typed record array has no fields", 2) end
	if fieldCount > context.config.maxRecordFields then
		error(string.format("[Waffles] Declared typed record field count %d exceeds limit %d", fieldCount, context.config.maxRecordFields), 2)
	end
	if count > math.floor(context.config.maxRecordCells / fieldCount) then
		error(string.format("[Waffles] Typed record has too many cells (%d x %d exceeds limit %d)", count, fieldCount, context.config.maxRecordCells), 2)
	end
	local keys = table.create(fieldCount)
	local kinds = table.create(fieldCount)
	local optional = table.create(fieldCount, false)
	local stringCached = table.create(fieldCount, false)
	local stringFast = table.create(fieldCount, false)
	local seenKeys: {[string]: boolean} = {}
	local hasLegacyString = false
	for index = 1, fieldCount do
		local key = readString(reader, context.config.maxStringBytes, "typed record field name")
		if seenKeys[key] then error("[Waffles] Duplicate typed record field name", 2) end
		seenKeys[key] = true
		keys[index] = key
		local encodedKind = readU8(reader, "typed record field kind")
		optional[index] = encodedKind >= 128
		local rawKind = encodedKind - (optional[index] and 128 or 0)
		local cacheEnabled = true -- legacy descriptors cached every long string
		local fastFraming = false
		if rawKind >= COMPACT_STRING_MODE then
			rawKind -= COMPACT_STRING_MODE
			fastFraming = rawKind >= COMPACT_STRING_FAST
			if fastFraming then rawKind -= COMPACT_STRING_FAST end
			cacheEnabled = rawKind >= COMPACT_STRING_CACHE
			if cacheEnabled then rawKind -= COMPACT_STRING_CACHE end
		end
		local kind = rawKind
		if kind < COMPACT_STRING or kind > COMPACT_FLOAT64 then
			error("[Waffles] Invalid typed record field kind", 2)
		end
		kinds[index] = kind
		stringCached[index] = kind == COMPACT_STRING and cacheEnabled
		stringFast[index] = kind == COMPACT_STRING and fastFraming
		if kind == COMPACT_STRING and not fastFraming then hasLegacyString = true end
	end
	local fastReader = (reader :: any)._fast
	if fastReader == nil then error("[Waffles] Internal fast reader unavailable", 2) end
	local useFastAccessors = not hasLegacyString
	-- The checked fast facade keeps a local cursor too, so mixed legacy columns
	-- can retain bounds/error checks without falling back to receiver-heavy reads.
	fastReader.Begin()
	local readTarget: any = fastReader
	local readLegacyU8: any = fastReader.ReadU8
	local readLegacyVarUInt: any = fastReader.ReadVarUInt
	local readLegacyRawString: any = fastReader.ReadRawString
	local readU8Wire: () -> number = if useFastAccessors
		then fastReader.ReadU8Unchecked
		else function(): number return fastReader.ReadU8(fastReader, "typed record value") end
	local readVarUIntWire: () -> number = if useFastAccessors
		then fastReader.ReadVarUIntUnchecked
		else function(): number return fastReader.ReadVarUInt(fastReader, "typed record value") end
	local readF32Wire: () -> number = if useFastAccessors
		then fastReader.ReadF32Unchecked
		else function(): number return fastReader.ReadF32(fastReader, "typed record value") end
	local readF64Wire: () -> number = if useFastAccessors
		then fastReader.ReadF64Unchecked
		else function(): number return fastReader.ReadF64(fastReader, "typed record value") end
	local readRawStringWire: (number) -> string = if useFastAccessors
		then fastReader.ReadRawStringUnchecked
		else function(length: number): string return fastReader.ReadRawString(fastReader, length, "compact string") end
	local maskBytes = math.floor((count + 7) / 8)
	local optionalFieldCount = 0
	for fieldIndex = 1, fieldCount do
		if optional[fieldIndex] then optionalFieldCount += 1 end
	end
	local presenceOffsets = table.create(fieldCount, -1)
	local presence: buffer? = if optionalFieldCount > 0 then buffer.create(optionalFieldCount * maskBytes) else nil
	local optionalOrdinal = 0
	for fieldIndex = 1, fieldCount do
		if optional[fieldIndex] then
			optionalOrdinal += 1
			local offset = (optionalOrdinal - 1) * maskBytes
			presenceOffsets[fieldIndex] = offset
			for maskIndex = 0, maskBytes - 1 do
				buffer.writeu8(presence :: buffer, offset + maskIndex, readU8Wire())
			end
		end
	end
	local result = table.create(count)
	for rowIndex = 1, count do result[rowIndex] = {} end
	local schemaStrings = context.schemaStrings
	local compactCacheMin = context.compactStringCacheMin
	local maxStringBytes = context.config.maxStringBytes
	for fieldIndex = 1, fieldCount do
		local key, kind = keys[fieldIndex], kinds[fieldIndex]
		local isOptional = optional[fieldIndex]
		local presenceOffset = presenceOffsets[fieldIndex]
		if kind == COMPACT_STRING then
			local cacheEnabled = stringCached[fieldIndex]
			if stringFast[fieldIndex] then
				local maskIndex, bitMask = 0, 1
				for rowIndex = 1, count do
					local presentValue = true
					if isOptional then
							presentValue = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
						bitMask *= 2
						if bitMask == 256 then maskIndex += 1; bitMask = 1 end
					end
					if presentValue then
						local first = readU8Wire()
						if first == 254 then
							if not cacheEnabled then error("[Waffles] Unexpected compact string reference in uncached column", 3) end
							local id = readVarUIntWire()
							local value = schemaStrings[id]
							if value == nil then error(string.format("[Waffles] Invalid compact string reference: %d", id), 3) end
							result[rowIndex][key] = value
						else
							local length = if first == 255 then readVarUIntWire() else first
							if length > maxStringBytes then
								error(string.format("[Waffles] Declared compact string length %d exceeds limit %d", length, maxStringBytes), 2)
							end
							local value = readRawStringWire(length)
							if cacheEnabled and length >= compactCacheMin then schemaStrings[#schemaStrings + 1] = value end
							result[rowIndex][key] = value
						end
					end
				end
			else
				local maskIndex, bitMask = 0, 1
				for rowIndex = 1, count do
					local presentValue = true
					if isOptional then
							presentValue = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
						bitMask *= 2
						if bitMask == 256 then maskIndex += 1; bitMask = 1 end
					end
					if presentValue then
						result[rowIndex][key] = readCompactString(readTarget, context, readLegacyU8, readLegacyVarUInt, readLegacyRawString, cacheEnabled, false)
					end
				end
				end
		elseif kind == COMPACT_BOOLEAN then
			local maskIndex, bitMask = 0, 1
			for rowIndex = 1, count do
				local presentValue = true
				if isOptional then
					presentValue = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
					bitMask *= 2
					if bitMask == 256 then maskIndex += 1; bitMask = 1 end
				end
				if presentValue then
						local byte = readU8Wire()
					if byte > 1 then error("[Waffles] Invalid typed record boolean", 2) end
					result[rowIndex][key] = byte == 1
				end
			end
		elseif kind == COMPACT_INTEGER then
			local maskIndex, bitMask = 0, 1
			for rowIndex = 1, count do
				local presentValue = true
				if isOptional then
					presentValue = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
					bitMask *= 2
					if bitMask == 256 then maskIndex += 1; bitMask = 1 end
				end
				if presentValue then
						local zigzag = readVarUIntWire()
					if zigzag > 9007199254740990 then error("[Waffles] Signed variable-length integer overflow", 2) end
					result[rowIndex][key] = if zigzag % 2 == 0 then zigzag / 2 else -(zigzag + 1) / 2
				end
			end
		elseif kind == COMPACT_FLOAT32 then
			local maskIndex, bitMask = 0, 1
			for rowIndex = 1, count do
				local presentValue = true
				if isOptional then
					presentValue = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
					bitMask *= 2
					if bitMask == 256 then maskIndex += 1; bitMask = 1 end
				end
				if presentValue then
					result[rowIndex][key] = readF32Wire()
				end
			end
		else
			local maskIndex, bitMask = 0, 1
			for rowIndex = 1, count do
				local presentValue = true
				if isOptional then
					presentValue = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
					bitMask *= 2
					if bitMask == 256 then maskIndex += 1; bitMask = 1 end
				end
				if presentValue then
					result[rowIndex][key] = readF64Wire()
				end
			end
		end
	end
	fastReader.Finish()
	return result
end

local function enumItem(enumTypeName: string, itemName: string): any
	local okType, enumType = pcall(function()
		return (Enum :: any)[enumTypeName]
	end)
	if not okType or enumType == nil then
		error("[Waffles] Invalid enum metadata: " .. enumTypeName, 3)
	end
	local okItem, item = pcall(function()
		return enumType[itemName]
	end)
	if not okItem or item == nil then
		error("[Waffles] Invalid enum metadata: " .. enumTypeName .. "." .. itemName, 3)
	end
	return item
end

readValue = function(reader: Reader, context: DecodeContext, depth: number): any
	checkDepth(context.config, depth)
	local tag = reader:ReadU8("type tag")
	if tag == Tags.Nil then
		return nil
	elseif tag == Tags.False then
		return false
	elseif tag == Tags.True then
		return true
	elseif tag == Tags.Integer then
		return reader:ReadVarInt("integer")
	elseif tag == Tags.Float32 then
		return reader:ReadF32("number")
	elseif tag == Tags.Float64 then
		return reader:ReadF64("number")
	elseif tag == Tags.String or tag == Tags.StringReference or tag == Tags.CommonKey then
		return readCachedString(reader, context, tag)
	elseif tag == Tags.Buffer then
		return reader:ReadBuffer(context.config.maxBufferBytes, "buffer")
	elseif tag == Tags.BufferRle then
		local length = reader:ReadVarUInt("RLE output length")
		if length > context.config.maxBufferBytes then
			error(string.format("[Waffles] Declared RLE buffer length %d exceeds limit %d", length, context.config.maxBufferBytes), 2)
		end
		local runCount = checkedCount(reader, context, "RLE run", 2)
		local runLengths = table.create(runCount)
		local runBytes = table.create(runCount)
		local totalLength = 0
		for index = 1, runCount do
			local runLength = reader:ReadVarUInt("RLE run length")
			local byte = reader:ReadU8("RLE byte")
			if runLength == 0 or totalLength + runLength > length then
				error("[Waffles] Invalid RLE run length", 2)
			end
			runLengths[index] = runLength
			runBytes[index] = byte
			totalLength += runLength
		end
		if totalLength ~= length then
			error("[Waffles] RLE data does not fill its declared output", 2)
		end
		local output = buffer.create(length)
		local cursor = 0
		for index = 1, runCount do
			local runLength = runLengths[index]
			buffer.fill(output, cursor, runBytes[index], runLength)
			cursor += runLength
		end
		return output
	elseif tag == Tags.Array then
		local count = checkedCount(reader, context, "array", 1)
		local result = table.create(count)
		for index = 1, count do
			result[index] = readValue(reader, context, depth + 1)
		end
		return result
	elseif tag == Tags.TypedRecordArray then
		return readCompactRecordArray(reader, context)
	elseif tag == Tags.Map then
		local count = checkedCount(reader, context, "map", 2)
		local result = {}
		local seen = {}
		for _ = 1, count do
			local key = readValue(reader, context, depth + 1)
			local keyType = type(key)
			if key == nil or (keyType ~= "boolean" and keyType ~= "number" and keyType ~= "string") or (keyType == "number" and key ~= key) then
				error("[Waffles] Invalid dictionary key in payload", 2)
			end
			if seen[key] then error("[Waffles] Duplicate dictionary key in payload", 2) end
			seen[key] = true
			result[key] = readValue(reader, context, depth + 1)
		end
		return result
	elseif tag == Tags.LayoutDefinition then
		local count = checkedCount(reader, context, "layout", 2)
		local keys = table.create(count)
		local seen = {}
		for index = 1, count do
			local key = readValue(reader, context, depth + 1)
			if type(key) ~= "string" or seen[key] then
				error("[Waffles] Invalid or duplicate layout key", 2)
			end
			seen[key] = true
			keys[index] = key
		end
		table.insert(context.layouts, keys)
		local result = {}
		for _, key in keys do
			result[key] = readValue(reader, context, depth + 1)
		end
		return result
	elseif tag == Tags.LayoutReference then
		local id = reader:ReadVarUInt("layout reference")
		local keys = context.layouts[id]
		if keys == nil then
			error(string.format("[Waffles] Invalid layout reference: %d", id), 2)
		end
		if #keys > reader:Remaining() then
			error("[Waffles] Layout value count exceeds remaining payload", 2)
		end
		local result = {}
		for _, key in keys do
			result[key] = readValue(reader, context, depth + 1)
		end
		return result
	elseif tag == Tags.Vector2 then
		return Vector2.new(reader:ReadF32("Vector2.X"), reader:ReadF32("Vector2.Y"))
	elseif tag == Tags.Vector3 then
		return Vector3.new(reader:ReadF32("Vector3.X"), reader:ReadF32("Vector3.Y"), reader:ReadF32("Vector3.Z"))
	elseif tag == Tags.Vector2int16 then
		return Vector2int16.new(reader:ReadI16("Vector2int16.X"), reader:ReadI16("Vector2int16.Y"))
	elseif tag == Tags.Vector3int16 then
		return Vector3int16.new(reader:ReadI16("Vector3int16.X"), reader:ReadI16("Vector3int16.Y"), reader:ReadI16("Vector3int16.Z"))
	elseif tag == Tags.CFrame then
		local c = table.create(12)
		for index = 1, 12 do
			c[index] = reader:ReadF64("CFrame component")
		end
		return CFrame.new(table.unpack(c, 1, 12))
	elseif tag == Tags.Color3 then
		return Color3.new(reader:ReadF32("Color3.R"), reader:ReadF32("Color3.G"), reader:ReadF32("Color3.B"))
	elseif tag == Tags.BrickColor then
		local number = reader:ReadU16("BrickColor number")
		local ok, value = pcall(BrickColor.new, number)
		if not ok or value.Number ~= number then
			error("[Waffles] Invalid BrickColor number", 2)
		end
		return value
	elseif tag == Tags.UDim then
		return UDim.new(reader:ReadF32("UDim scale"), reader:ReadVarInt("UDim offset"))
	elseif tag == Tags.UDim2 then
		return UDim2.new(reader:ReadF32("UDim2 X scale"), reader:ReadVarInt("UDim2 X offset"), reader:ReadF32("UDim2 Y scale"), reader:ReadVarInt("UDim2 Y offset"))
	elseif tag == Tags.Rect then
		return Rect.new(reader:ReadF32("Rect Min.X"), reader:ReadF32("Rect Min.Y"), reader:ReadF32("Rect Max.X"), reader:ReadF32("Rect Max.Y"))
	elseif tag == Tags.Ray then
		local origin = Vector3.new(reader:ReadF32("Ray Origin.X"), reader:ReadF32("Ray Origin.Y"), reader:ReadF32("Ray Origin.Z"))
		local direction = Vector3.new(reader:ReadF32("Ray Direction.X"), reader:ReadF32("Ray Direction.Y"), reader:ReadF32("Ray Direction.Z"))
		return Ray.new(origin, direction)
	elseif tag == Tags.NumberRange then
		return NumberRange.new(reader:ReadF32("NumberRange.Min"), reader:ReadF32("NumberRange.Max"))
	elseif tag == Tags.NumberSequenceKeypoint then
		return NumberSequenceKeypoint.new(reader:ReadF32("keypoint time"), reader:ReadF32("keypoint value"), reader:ReadF32("keypoint envelope"))
	elseif tag == Tags.NumberSequence then
		local count = checkedCount(reader, context, "NumberSequence keypoint", 12)
		local points = table.create(count)
		for index = 1, count do
			points[index] = NumberSequenceKeypoint.new(reader:ReadF32("keypoint time"), reader:ReadF32("keypoint value"), reader:ReadF32("keypoint envelope"))
		end
		local ok, result = pcall(NumberSequence.new, points)
		if not ok then error("[Waffles] Invalid NumberSequence payload", 2) end
		return result
	elseif tag == Tags.ColorSequenceKeypoint then
		local time = reader:ReadF32("keypoint time")
		return ColorSequenceKeypoint.new(time, Color3.new(reader:ReadF32("keypoint R"), reader:ReadF32("keypoint G"), reader:ReadF32("keypoint B")))
	elseif tag == Tags.ColorSequence then
		local count = checkedCount(reader, context, "ColorSequence keypoint", 16)
		local points = table.create(count)
		for index = 1, count do
			local time = reader:ReadF32("keypoint time")
			points[index] = ColorSequenceKeypoint.new(time, Color3.new(reader:ReadF32("keypoint R"), reader:ReadF32("keypoint G"), reader:ReadF32("keypoint B")))
		end
		local ok, result = pcall(ColorSequence.new, points)
		if not ok then error("[Waffles] Invalid ColorSequence payload", 2) end
		return result
	elseif tag == Tags.DateTime then
		local ok, result = pcall(DateTime.fromUnixTimestampMillis, reader:ReadVarInt("DateTime milliseconds"))
		if not ok then error("[Waffles] Invalid DateTime payload", 2) end
		return result
	elseif tag == Tags.Font then
		local family = readValue(reader, context, depth + 1)
		local weightName = readValue(reader, context, depth + 1)
		local styleName = readValue(reader, context, depth + 1)
		if type(family) ~= "string" or type(weightName) ~= "string" or type(styleName) ~= "string" then
			error("[Waffles] Invalid Font metadata", 2)
		end
		local weight = enumItem("FontWeight", weightName)
		local style = enumItem("FontStyle", styleName)
		local ok, result = pcall(Font.new, family, weight, style)
		if not ok then error("[Waffles] Invalid Font payload", 2) end
		return result
	elseif tag == Tags.EnumItem then
		local enumTypeName = readValue(reader, context, depth + 1)
		local itemName = readValue(reader, context, depth + 1)
		if type(enumTypeName) ~= "string" or type(itemName) ~= "string" then
			error("[Waffles] Invalid enum metadata", 2)
		end
		return enumItem(enumTypeName, itemName)
	elseif tag == Tags.Custom then
		local id = reader:ReadVarUInt("converter identifier")
		local converter = context.convertersById[id]
		if converter == nil then
			error(string.format("[Waffles] Unknown converter identifier: %d", id), 2)
		end
		return converter.Deserialize(reader)
	end
	error(string.format("[Waffles] Invalid type tag: %d", tag), 2)
end

function AutoCodec.newEncodeContext(config: Config, commonKeyIds: {[string]: number}, converters: {Converter}): EncodeContext
	local poolIndex = #encodeContextPool
	local context: EncodeContext
	if poolIndex > 0 then
		context = encodeContextPool[poolIndex]
		encodeContextPool[poolIndex] = nil
		table.clear(context.strings)
		table.clear(context.schemaStrings)
		table.clear(context.layouts)
		table.clear(context.active)
		context.stringCount = 0
		context.schemaStringCount = 0
		context.layoutCount = 0
	else
		context = {
			config = config,
			strings = {},
			stringCount = 0,
			schemaStrings = {},
			schemaStringCount = 0,
			compactStringCacheMin = 0,
			layouts = {},
			layoutCount = 0,
			active = {},
			commonKeyIds = commonKeyIds,
			converters = converters,
			hasConverters = false,
		}
	end
	context.config = config
	context.compactStringCacheMin = math.max(COMPACT_STRING_CACHE_MIN, config.stringCacheMinLength)
	context.commonKeyIds = commonKeyIds
	context.converters = converters
	context.hasConverters = #converters > 0
	context.schemaValidationEnabled = nil
	context.schemaActive = nil
	context.schemaPath = nil
	context.schemaPathDepth = nil
	return context
end

function AutoCodec.releaseEncodeContext(context: EncodeContext)
	-- Context tables contain only payload-local state.  Clearing them before
	-- pooling keeps the next call allocation-free without retaining user data.
	if #encodeContextPool >= MAX_CONTEXT_POOL then return end
	table.clear(context.strings)
	table.clear(context.schemaStrings)
	table.clear(context.layouts)
	table.clear(context.active)
	context.schemaActive = nil
	context.schemaPath = nil
	context.schemaPathDepth = nil
	encodeContextPool[#encodeContextPool + 1] = context
end

function AutoCodec.newDecodeContext(config: Config, commonKeys: {string}, convertersById: {[number]: Converter}): DecodeContext
	local poolIndex = #decodeContextPool
	local context: DecodeContext
	if poolIndex > 0 then
		context = decodeContextPool[poolIndex]
		decodeContextPool[poolIndex] = nil
		table.clear(context.strings)
		table.clear(context.schemaStrings)
		table.clear(context.layouts)
	else
		context = {
			config = config,
			strings = {},
			schemaStrings = {},
			layouts = {},
			commonKeys = commonKeys,
			convertersById = convertersById,
			compactStringCacheMin = 0,
		}
	end
	context.config = config
	context.commonKeys = commonKeys
	context.convertersById = convertersById
	context.compactStringCacheMin = math.max(COMPACT_STRING_CACHE_MIN, config.stringCacheMinLength)
	return context
end

function AutoCodec.releaseDecodeContext(context: DecodeContext)
	if #decodeContextPool >= MAX_CONTEXT_POOL then return end
	table.clear(context.strings)
	table.clear(context.schemaStrings)
	table.clear(context.layouts)
	decodeContextPool[#decodeContextPool + 1] = context
end

AutoCodec.writeValue = writeValue
AutoCodec.readValue = readValue

return AutoCodec
