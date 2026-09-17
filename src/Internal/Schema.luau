--!strict

type TypeDefinition = {
	_wafflesType: boolean,
	kind: string,
	name: string,
	[string]: any,
}

export type SchemaObject = {
	Serialize: (self: SchemaObject, value: any) -> buffer,
	Deserialize: (self: SchemaObject, data: buffer) -> any,
	Validate: (self: SchemaObject, value: any) -> (boolean, string?),
	Definition: TypeDefinition,
	Hash: number,
}

type Runtime = {
	serialize: (schema: any, value: any) -> buffer,
	deserialize: (schema: any, data: buffer) -> any,
	writeAny: (writer: any, value: any, context: any, depth: number) -> (),
	readAny: (reader: any, context: any, depth: number) -> any,
}

local SchemaModule = {}
local runtime: Runtime? = nil

local function primitive(kind: string, name: string): TypeDefinition
	return table.freeze({
		_wafflesType = true,
		kind = kind,
		name = name,
	}) :: any
end

local Types: {[string]: any} = {
	Any = primitive("any", "any supported value"),
	Nil = primitive("nil", "nil"),
	Boolean = primitive("boolean", "boolean"),
	String = primitive("string", "string"),
	Number = primitive("number", "number"),
	Integer = primitive("integer", "integer"),
	Buffer = primitive("buffer", "buffer"),
	Vector2 = primitive("Vector2", "Vector2"),
	Vector3 = primitive("Vector3", "Vector3"),
	Vector2int16 = primitive("Vector2int16", "Vector2int16"),
	Vector3int16 = primitive("Vector3int16", "Vector3int16"),
	CFrame = primitive("CFrame", "CFrame"),
	Color3 = primitive("Color3", "Color3"),
	BrickColor = primitive("BrickColor", "BrickColor"),
	UDim = primitive("UDim", "UDim"),
	UDim2 = primitive("UDim2", "UDim2"),
	Rect = primitive("Rect", "Rect"),
	Ray = primitive("Ray", "Ray"),
	NumberRange = primitive("NumberRange", "NumberRange"),
	NumberSequence = primitive("NumberSequence", "NumberSequence"),
	NumberSequenceKeypoint = primitive("NumberSequenceKeypoint", "NumberSequenceKeypoint"),
	ColorSequence = primitive("ColorSequence", "ColorSequence"),
	ColorSequenceKeypoint = primitive("ColorSequenceKeypoint", "ColorSequenceKeypoint"),
	DateTime = primitive("DateTime", "DateTime"),
	Font = primitive("Font", "Font"),
	EnumItem = primitive("EnumItem", "EnumItem"),
}

local function assertTypeDefinition(definition: any, argumentName: string): TypeDefinition
	if type(definition) ~= "table" or definition._wafflesType ~= true then
		error("[Waffles] " .. argumentName .. " must be a Waffles type definition", 3)
	end
	return definition
end

local function minimumBytes(definition: TypeDefinition): number
	local kind = definition.kind
	if kind == "nil" then return 0 end
	if kind == "struct" then
		local total = 0
		for _, name in definition.names do total += minimumBytes(definition.fields[name]) end
		return total
	end
	if kind == "tuple" then
		local total = 0
		for _, item in definition.items do total += minimumBytes(item) end
		return total
	end
	return 1
end

function Types.Array(element: TypeDefinition): TypeDefinition
	assertTypeDefinition(element, "Array element")
	if minimumBytes(element) == 0 then
		error("[Waffles] Array elements must encode at least one byte", 2)
	end
	return table.freeze({
		_wafflesType = true,
		kind = "array",
		name = "array<" .. assertTypeDefinition(element, "Array element").name .. ">",
		element = element,
	}) :: any
end

function Types.Optional(inner: TypeDefinition): TypeDefinition
	return table.freeze({
		_wafflesType = true,
		kind = "optional",
		name = "optional<" .. assertTypeDefinition(inner, "Optional value").name .. ">",
		inner = inner,
	}) :: any
end

function Types.Map(key: TypeDefinition, value: TypeDefinition): TypeDefinition
	assertTypeDefinition(key, "Map key")
	assertTypeDefinition(value, "Map value")
	local keyKind = key.kind
	if keyKind ~= "boolean" and keyKind ~= "string" and keyKind ~= "number" and keyKind ~= "integer" and keyKind ~= "enum" then
		error("[Waffles] Map keys must use Boolean, String, Number, Integer, or Enum", 2)
	end
	return table.freeze({
		_wafflesType = true,
		kind = "map",
		name = "map<" .. key.name .. ", " .. value.name .. ">",
		key = key,
		value = value,
	}) :: any
end

function Types.Struct(fields: {[string]: TypeDefinition}): TypeDefinition
	if type(fields) ~= "table" then
		error("[Waffles] Struct fields must be a table", 2)
	end
	local names = {}
	local copied = {}
	for name, definition in fields do
		if type(name) ~= "string" then
			error("[Waffles] Struct field names must be strings", 2)
		end
		copied[name] = assertTypeDefinition(definition, "Struct field " .. name)
		table.insert(names, name)
	end
	table.sort(names)
	return table.freeze({
		_wafflesType = true,
		kind = "struct",
		name = "struct",
		fields = table.freeze(copied),
		names = table.freeze(names),
	}) :: any
end

function Types.Tuple(...: TypeDefinition): TypeDefinition
	local items = {...}
	for index, definition in items do
		assertTypeDefinition(definition, "Tuple item " .. tostring(index))
	end
	return table.freeze({
		_wafflesType = true,
		kind = "tuple",
		name = "tuple",
		items = table.freeze(items),
	}) :: any
end

function Types.Enum(...: any): TypeDefinition
	local values = {...}
	if #values == 1 and type(values[1]) == "table" then
		values = table.clone(values[1])
	end
	if #values == 0 then
		error("[Waffles] Types.Enum requires at least one value", 2)
	end
	local lookup = {}
	for index, value in values do
		local kind = type(value)
		if kind ~= "string" and kind ~= "number" then
			error("[Waffles] Types.Enum values must be strings or numbers", 2)
		end
		if kind == "number" and value ~= value then
			error("[Waffles] Types.Enum values cannot be NaN", 2)
		end
		if lookup[value] ~= nil then
			error("[Waffles] Types.Enum values must be unique", 2)
		end
		lookup[value] = index
	end
	return table.freeze({
		_wafflesType = true,
		kind = "enum",
		name = "enum",
		values = table.freeze(values),
		lookup = table.freeze(lookup),
	}) :: any
end

local function received(value: any): string
	local kind = typeof(value)
	if kind == "string" then
		return string.format("string %q", value)
	elseif kind == "number" or kind == "boolean" or value == nil then
		return kind .. " " .. tostring(value)
	end
	return kind
end

local function fail(path: string, expected: string, value: any): (boolean, string)
	return false, string.format("[Waffles] Schema validation failed at %s: expected %s, received %s", path, expected, received(value))
end

local function validate(definition: TypeDefinition, value: any, path: string, depth: number, active: {[any]: boolean}): (boolean, string?)
	if depth > 64 then
		return false, "[Waffles] Schema validation exceeded maximum nesting depth at " .. path
	end
	local kind = definition.kind
	if kind == "any" then
		return true
	elseif kind == "nil" then
		if value ~= nil then return fail(path, definition.name, value) end
		return true
	elseif kind == "boolean" or kind == "string" or kind == "number" then
		if typeof(value) ~= kind then return fail(path, definition.name, value) end
		return true
	elseif kind == "integer" then
		if typeof(value) ~= "number" or value % 1 ~= 0 or math.abs(value) > 4503599627370495 then
			return fail(path, definition.name, value)
		end
		return true
	elseif kind == "optional" then
		if value == nil then return true end
		return validate(definition.inner, value, path, depth + 1, active)
	elseif kind == "array" or kind == "tuple" or kind == "map" or kind == "struct" then
		if typeof(value) ~= "table" then return fail(path, definition.name, value) end
		if active[value] then
			return false, "[Waffles] Schema validation failed at " .. path .. ": cyclic tables are not supported"
		end
		active[value] = true
		if kind == "array" then
			local elementCount = 0
			local maximumIndex = 0
			for key in value do
				if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then active[value] = nil; return fail(path, definition.name, value) end
				elementCount += 1
				maximumIndex = math.max(maximumIndex, key)
			end
			if maximumIndex ~= elementCount then active[value] = nil; return fail(path, "a contiguous " .. definition.name, value) end
			for index = 1, elementCount do
				local ok, message = validate(definition.element, value[index], string.format("%s[%d]", path, index), depth + 1, active)
				if not ok then active[value] = nil; return false, message end
			end
		elseif kind == "tuple" then
			for index, itemDefinition in definition.items do
				local ok, message = validate(itemDefinition, value[index], string.format("%s[%d]", path, index), depth + 1, active)
				if not ok then active[value] = nil; return false, message end
			end
		elseif kind == "map" then
			for key, item in value do
				local keyPath = path .. "[key]"
				local okKey, keyMessage = validate(definition.key, key, keyPath, depth + 1, active)
				if not okKey then active[value] = nil; return false, keyMessage end
				local itemPath = if type(key) == "string" then path .. "." .. key else path .. "[" .. tostring(key) .. "]"
				local okValue, valueMessage = validate(definition.value, item, itemPath, depth + 1, active)
				if not okValue then active[value] = nil; return false, valueMessage end
			end
		else
			for _, fieldName in definition.names do
				local fieldDefinition = definition.fields[fieldName]
				local ok, message = validate(fieldDefinition, value[fieldName], path .. "." .. fieldName, depth + 1, active)
				if not ok then active[value] = nil; return false, message end
			end
		end
		active[value] = nil
		return true
	elseif kind == "enum" then
		if definition.lookup[value] == nil then return fail(path, "one of the schema enum values", value) end
		return true
	elseif kind == "buffer" then
		if typeof(value) ~= "buffer" then return fail(path, definition.name, value) end
		return true
	else
		if typeof(value) ~= kind then return fail(path, definition.name, value) end
		return true
	end
end

local function schemaKeyRank(value: any): number
	local kind = type(value)
	if kind == "boolean" then return 1 end
	if kind == "number" then return 2 end
	if kind == "string" then return 3 end
	return 99
end

local function sortedMapKeys(value: {[any]: any}): {any}
	local keys = {}
	for key in value do table.insert(keys, key) end
	table.sort(keys, function(a, b)
		local rankA, rankB = schemaKeyRank(a), schemaKeyRank(b)
		if rankA ~= rankB then return rankA < rankB end
		if rankA == 1 then return a == false end
		return a < b
	end)
	return keys
end

local write: (TypeDefinition, any, any, any, number) -> ()
local read: (TypeDefinition, any, any, number) -> any

write = function(definition: TypeDefinition, writer: any, value: any, autoContext: any, depth: number)
	if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
	local kind = definition.kind
	if kind == "any" then
		(runtime :: Runtime).writeAny(writer, value, autoContext, depth)
	elseif kind == "nil" then
		return
	elseif kind == "boolean" then
		writer:WriteU8(if value then 1 else 0)
	elseif kind == "string" then
		if #value > autoContext.config.maxStringBytes then error("[Waffles] Schema string exceeds configured length limit", 2) end
		writer:WriteString(value)
	elseif kind == "number" then
		writer:WriteF64(value)
	elseif kind == "integer" then
		writer:WriteVarInt(value)
	elseif kind == "buffer" then
		if buffer.len(value) > autoContext.config.maxBufferBytes then error("[Waffles] Schema buffer exceeds configured length limit", 2) end
		writer:WriteBuffer(value)
	elseif kind == "optional" then
		if value == nil then writer:WriteU8(0) else writer:WriteU8(1); write(definition.inner, writer, value, autoContext, depth + 1) end
	elseif kind == "array" then
		if #value > autoContext.config.maxCollectionCount then error("[Waffles] Schema array exceeds configured count limit", 2) end
		writer:WriteVarUInt(#value)
		for index = 1, #value do write(definition.element, writer, value[index], autoContext, depth + 1) end
	elseif kind == "map" then
		local keys = sortedMapKeys(value)
		if #keys > autoContext.config.maxCollectionCount then error("[Waffles] Schema map exceeds configured count limit", 2) end
		writer:WriteVarUInt(#keys)
		for _, key in keys do
			write(definition.key, writer, key, autoContext, depth + 1)
			write(definition.value, writer, value[key], autoContext, depth + 1)
		end
	elseif kind == "struct" then
		for _, name in definition.names do write(definition.fields[name], writer, value[name], autoContext, depth + 1) end
	elseif kind == "tuple" then
		for index, itemDefinition in definition.items do write(itemDefinition, writer, value[index], autoContext, depth + 1) end
	elseif kind == "enum" then
		writer:WriteVarUInt(definition.lookup[value] - 1)
	elseif kind == "Vector2" then
		writer:WriteF32(value.X); writer:WriteF32(value.Y)
	elseif kind == "Vector3" then
		writer:WriteF32(value.X); writer:WriteF32(value.Y); writer:WriteF32(value.Z)
	elseif kind == "Vector2int16" then
		writer:WriteI16(value.X); writer:WriteI16(value.Y)
	elseif kind == "Vector3int16" then
		writer:WriteI16(value.X); writer:WriteI16(value.Y); writer:WriteI16(value.Z)
	elseif kind == "CFrame" then
		local c = {value:GetComponents()}; for index = 1, 12 do writer:WriteF64(c[index]) end
	elseif kind == "Color3" then
		writer:WriteF32(value.R); writer:WriteF32(value.G); writer:WriteF32(value.B)
	elseif kind == "BrickColor" then
		writer:WriteU16(value.Number)
	elseif kind == "UDim" then
		writer:WriteF32(value.Scale); writer:WriteVarInt(value.Offset)
	elseif kind == "UDim2" then
		writer:WriteF32(value.X.Scale); writer:WriteVarInt(value.X.Offset); writer:WriteF32(value.Y.Scale); writer:WriteVarInt(value.Y.Offset)
	elseif kind == "Rect" then
		writer:WriteF32(value.Min.X); writer:WriteF32(value.Min.Y); writer:WriteF32(value.Max.X); writer:WriteF32(value.Max.Y)
	elseif kind == "Ray" then
		writer:WriteF32(value.Origin.X); writer:WriteF32(value.Origin.Y); writer:WriteF32(value.Origin.Z); writer:WriteF32(value.Direction.X); writer:WriteF32(value.Direction.Y); writer:WriteF32(value.Direction.Z)
	elseif kind == "NumberRange" then
		writer:WriteF32(value.Min); writer:WriteF32(value.Max)
	elseif kind == "DateTime" then
		writer:WriteVarInt(value.UnixTimestampMillis)
	else
		-- Less common schema datatypes use the automatic codec. They retain one
		-- compact tag, while the common primitives above remain completely tagless.
		(runtime :: Runtime).writeAny(writer, value, autoContext, depth)
	end
end

local function checkedSchemaCount(reader: any, context: any, label: string): number
	local count = reader:ReadVarUInt(label .. " count")
	if count > context.config.maxCollectionCount or count > reader:Remaining() then
		error("[Waffles] Invalid or excessive schema " .. label .. " count", 3)
	end
	return count
end

read = function(definition: TypeDefinition, reader: any, autoContext: any, depth: number): any
	local kind = definition.kind
	if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
	if kind == "any" then
		return (runtime :: Runtime).readAny(reader, autoContext, depth)
	elseif kind == "nil" then
		return nil
	elseif kind == "boolean" then
		local byte = reader:ReadU8("schema boolean")
		if byte > 1 then error("[Waffles] Invalid schema boolean", 2) end
		return byte == 1
	elseif kind == "string" then
		return reader:ReadString(autoContext.config.maxStringBytes, "schema string")
	elseif kind == "number" then
		return reader:ReadF64("schema number")
	elseif kind == "integer" then
		return reader:ReadVarInt("schema integer")
	elseif kind == "buffer" then
		return reader:ReadBuffer(autoContext.config.maxBufferBytes, "schema buffer")
	elseif kind == "optional" then
		local present = reader:ReadU8("optional marker")
		if present == 0 then return nil elseif present ~= 1 then error("[Waffles] Invalid optional marker", 2) end
		return read(definition.inner, reader, autoContext, depth + 1)
	elseif kind == "array" then
		local count = checkedSchemaCount(reader, autoContext, "array")
		local result = table.create(count)
		for index = 1, count do result[index] = read(definition.element, reader, autoContext, depth + 1) end
		return result
	elseif kind == "map" then
		local count = checkedSchemaCount(reader, autoContext, "map")
		local result = {}
		local seen = {}
		for _ = 1, count do
			local key = read(definition.key, reader, autoContext, depth + 1)
			if key == nil or (type(key) == "number" and key ~= key) then error("[Waffles] Invalid schema map key", 2) end
			if seen[key] then error("[Waffles] Duplicate schema map key", 2) end
			seen[key] = true
			result[key] = read(definition.value, reader, autoContext, depth + 1)
		end
		return result
	elseif kind == "struct" then
		local result = {}
		for _, name in definition.names do result[name] = read(definition.fields[name], reader, autoContext, depth + 1) end
		return result
	elseif kind == "tuple" then
		local result = table.create(#definition.items)
		for index, itemDefinition in definition.items do result[index] = read(itemDefinition, reader, autoContext, depth + 1) end
		return result
	elseif kind == "enum" then
		local index = reader:ReadVarUInt("schema enum") + 1
		local value = definition.values[index]
		if value == nil then error("[Waffles] Invalid schema enum identifier", 2) end
		return value
	elseif kind == "Vector2" then
		return Vector2.new(reader:ReadF32("Vector2.X"), reader:ReadF32("Vector2.Y"))
	elseif kind == "Vector3" then
		return Vector3.new(reader:ReadF32("Vector3.X"), reader:ReadF32("Vector3.Y"), reader:ReadF32("Vector3.Z"))
	elseif kind == "Vector2int16" then
		return Vector2int16.new(reader:ReadI16("Vector2int16.X"), reader:ReadI16("Vector2int16.Y"))
	elseif kind == "Vector3int16" then
		return Vector3int16.new(reader:ReadI16("Vector3int16.X"), reader:ReadI16("Vector3int16.Y"), reader:ReadI16("Vector3int16.Z"))
	elseif kind == "CFrame" then
		local c = table.create(12); for index = 1, 12 do c[index] = reader:ReadF64("CFrame component") end
		return CFrame.new(table.unpack(c, 1, 12))
	elseif kind == "Color3" then
		return Color3.new(reader:ReadF32("Color3.R"), reader:ReadF32("Color3.G"), reader:ReadF32("Color3.B"))
	elseif kind == "BrickColor" then
		local number = reader:ReadU16("BrickColor number")
		local value = BrickColor.new(number)
		if value.Number ~= number then error("[Waffles] Invalid BrickColor number", 2) end
		return value
	elseif kind == "UDim" then
		return UDim.new(reader:ReadF32("UDim scale"), reader:ReadVarInt("UDim offset"))
	elseif kind == "UDim2" then
		return UDim2.new(reader:ReadF32("UDim2 X scale"), reader:ReadVarInt("UDim2 X offset"), reader:ReadF32("UDim2 Y scale"), reader:ReadVarInt("UDim2 Y offset"))
	elseif kind == "Rect" then
		return Rect.new(reader:ReadF32("Rect Min.X"), reader:ReadF32("Rect Min.Y"), reader:ReadF32("Rect Max.X"), reader:ReadF32("Rect Max.Y"))
	elseif kind == "Ray" then
		local origin = Vector3.new(reader:ReadF32("Ray Origin.X"), reader:ReadF32("Ray Origin.Y"), reader:ReadF32("Ray Origin.Z"))
		local direction = Vector3.new(reader:ReadF32("Ray Direction.X"), reader:ReadF32("Ray Direction.Y"), reader:ReadF32("Ray Direction.Z"))
		return Ray.new(origin, direction)
	elseif kind == "NumberRange" then
		return NumberRange.new(reader:ReadF32("NumberRange.Min"), reader:ReadF32("NumberRange.Max"))
	elseif kind == "DateTime" then
		return DateTime.fromUnixTimestampMillis(reader:ReadVarInt("DateTime milliseconds"))
	end
	return (runtime :: Runtime).readAny(reader, autoContext, depth)
end

local function descriptorText(definition: TypeDefinition): string
	local kind = definition.kind
	if kind == "array" then return "array(" .. descriptorText(definition.element) .. ")" end
	if kind == "optional" then return "optional(" .. descriptorText(definition.inner) .. ")" end
	if kind == "map" then return "map(" .. descriptorText(definition.key) .. "," .. descriptorText(definition.value) .. ")" end
	if kind == "tuple" then
		local parts = {}; for _, item in definition.items do table.insert(parts, descriptorText(item)) end
		return "tuple(" .. table.concat(parts, ",") .. ")"
	end
	if kind == "struct" then
		local parts = {}; for _, name in definition.names do table.insert(parts, #name .. ":" .. name .. "=" .. descriptorText(definition.fields[name])) end
		return "struct(" .. table.concat(parts, ",") .. ")"
	end
	if kind == "enum" then
		local parts = {}; for _, value in definition.values do local text = tostring(value); table.insert(parts, type(value) .. ":" .. #text .. ":" .. text) end
		return "enum(" .. table.concat(parts, ",") .. ")"
	end
	return kind
end

local function hashDefinition(definition: TypeDefinition): number
	local hash = 5381
	local text = descriptorText(definition)
	for index = 1, #text do
		hash = (hash * 33 + string.byte(text, index)) % 4294967296
	end
	return hash
end

local SchemaMethods = {}
SchemaMethods.__index = SchemaMethods

function SchemaMethods.Serialize(self: any, value: any): buffer
	return (runtime :: Runtime).serialize(self, value)
end

function SchemaMethods.Deserialize(self: any, data: buffer): any
	return (runtime :: Runtime).deserialize(self, data)
end

function SchemaMethods.Validate(self: any, value: any): (boolean, string?)
	return validate(self.Definition, value, "value", 0, {})
end

function SchemaModule.create(definitionOrFields: any): SchemaObject
	local definition: TypeDefinition
	if type(definitionOrFields) == "table" and definitionOrFields._wafflesType == true then
		definition = definitionOrFields
	else
		definition = Types.Struct(definitionOrFields)
	end
	return table.freeze(setmetatable({
		Definition = definition,
		Hash = hashDefinition(definition),
	}, SchemaMethods)) :: any
end

local function sameDefinition(a: TypeDefinition, b: TypeDefinition): boolean
	return descriptorText(a) == descriptorText(b)
end

local function infer(value: any, depth: number, active: {[any]: boolean}): TypeDefinition
	if depth > 64 then error("[Waffles] SmartSchema example exceeds maximum nesting depth", 3) end
	local kind = typeof(value)
	if value == nil then return Types.Optional(Types.Any) end
	if kind == "boolean" then return Types.Boolean end
	if kind == "string" then return Types.String end
	if kind == "number" then return if value % 1 == 0 and math.abs(value) <= 4503599627370495 and not (value == 0 and 1 / value == -math.huge) then Types.Integer else Types.Number end
	if kind == "buffer" then return Types.Buffer end
	if kind ~= "table" then
		local known = Types[kind]
		if known then return known end
		return Types.Any
	end
	if active[value] then error("[Waffles] SmartSchema cannot infer a cyclic table", 3) end
	active[value] = true
	local count, max, allIndices, allStrings = 0, 0, true, true
	for key in value do
		count += 1
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then allIndices = false else max = math.max(max, key) end
		if type(key) ~= "string" then allStrings = false end
	end
	local result: TypeDefinition
	if allIndices and max == count then
		local element = Types.Any
		if count > 0 then
			element = infer(value[1], depth + 1, active)
			for index = 2, count do
				local nextDefinition = infer(value[index], depth + 1, active)
				if not sameDefinition(element, nextDefinition) then element = Types.Any; break end
			end
		end
		result = Types.Array(element)
	elseif allStrings then
		local fields = {}
		for key, item in value do fields[key] = infer(item, depth + 1, active) end
		result = Types.Struct(fields)
	else
		local keyDefinition: TypeDefinition? = nil
		local valueDefinition: TypeDefinition? = nil
		for key, item in value do
			local inferredKey = infer(key, depth + 1, active)
			local inferredValue = infer(item, depth + 1, active)
			if keyDefinition == nil then keyDefinition = inferredKey elseif not sameDefinition(keyDefinition, inferredKey) then keyDefinition = Types.Any end
			if valueDefinition == nil then valueDefinition = inferredValue elseif not sameDefinition(valueDefinition, inferredValue) then valueDefinition = Types.Any end
		end
		local finalKey = keyDefinition or Types.Any
		if finalKey.kind == "boolean" or finalKey.kind == "string" or finalKey.kind == "number" or finalKey.kind == "integer" or finalKey.kind == "enum" then
			result = Types.Map(finalKey, valueDefinition or Types.Any)
		else
			result = Types.Any
		end
	end
	active[value] = nil
	return result
end

function SchemaModule.smart(example: any): SchemaObject
	return SchemaModule.create(infer(example, 0, {}))
end

function SchemaModule.setRuntime(value: Runtime)
	runtime = value
end

function SchemaModule.writeDefinition(definition: TypeDefinition, writer: any, value: any, autoContext: any)
	write(definition, writer, value, autoContext, 0)
end

function SchemaModule.readDefinition(definition: TypeDefinition, reader: any, autoContext: any): any
	return read(definition, reader, autoContext, 0)
end

SchemaModule.Types = table.freeze(Types)

return SchemaModule
