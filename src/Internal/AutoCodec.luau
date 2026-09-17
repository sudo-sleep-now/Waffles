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
}

type DecodeContext = {
	config: Config,
	strings: {string},
	layouts: {{string}},
	commonKeys: {string},
	convertersById: {[number]: Converter},
}

local AutoCodec = {}
local floatScratch = buffer.create(4)

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
				return cached.keys, cached.allStrings
			end
			local valid = true
			for _, key in cached.keys do
				if value[key] == nil then valid = false; break end
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
		table.insert(keys, key)
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

	for _, converter in context.converters do
		if converter.CanSerialize(value) then
			writer:WriteU8(Tags.Custom)
			writer:WriteVarUInt(converter.Id)
			converter.Serialize(writer, value)
			return
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
			writer:WriteU8(Tags.Array)
			writer:WriteVarUInt(count)
			for index = 1, count do
				writeValue(writer, value[index], context, depth + 1)
			end
		else
			local keys, allStrings = sortedKeys(value, count, context.config)
			local signature = if allStrings then layoutSignature(keys, math.min(context.config.maxPayloadBytes, 65536)) else nil
			if signature then
				local layoutId = context.layouts[signature]
				if layoutId then
					writer:WriteU8(Tags.LayoutReference)
					writer:WriteVarUInt(layoutId)
				else
					context.layoutCount += 1
					layoutId = context.layoutCount
					context.layouts[signature] = layoutId
					writer:WriteU8(Tags.LayoutDefinition)
					writer:WriteVarUInt(count)
					for _, key in keys do
						writeValue(writer, key, context, depth + 1, true)
					end
				end
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
	return {
		config = config,
		strings = {},
		stringCount = 0,
		layouts = {},
		layoutCount = 0,
		active = {},
		commonKeyIds = commonKeyIds,
		converters = converters,
	}
end

function AutoCodec.newDecodeContext(config: Config, commonKeys: {string}, convertersById: {[number]: Converter}): DecodeContext
	return {
		config = config,
		strings = {},
		layouts = {},
		commonKeys = commonKeys,
		convertersById = convertersById,
	}
end

AutoCodec.writeValue = writeValue
AutoCodec.readValue = readValue

return AutoCodec
