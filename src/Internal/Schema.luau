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
local mathAbs = math.abs
local bit32Band = bit32.band
local mathFloor = math.floor
local bufferReadU8 = buffer.readu8
local bufferReadF64 = buffer.readf64
local bufferReadString = buffer.readstring
local PRESENCE_BITS = {1, 2, 4, 8, 16, 32, 64, 128}
local HASH_MODULUS = 4294967296

local function hashBytes(hash: number, text: string): number
	for index = 1, #text do hash = (hash * 33 + string.byte(text, index)) % HASH_MODULUS end
	return hash
end

local function hashDefinitionPart(hash: number, value: number): number
	return (hash * 33 + value) % HASH_MODULUS
end

local function primitiveHash(kind: string): number
	return hashBytes(5381, kind)
end

local function primitive(kind: string, name: string): TypeDefinition
	return table.freeze({
		_wafflesType = true,
		kind = kind,
		name = name,
		_hash = primitiveHash(kind),
		_minimumBytes = if kind == "nil" then 0 else 1,
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

local materializeStruct: (TypeDefinition) -> ()
local materializeOptional: (TypeDefinition) -> ()
local materializeArray: (TypeDefinition) -> ()
local hashDefinition: (TypeDefinition) -> number

local function minimumBytes(definition: TypeDefinition): number
	if definition._lazy == true then
		if definition.kind == "struct" then materializeStruct(definition)
		elseif definition.kind == "optional" then materializeOptional(definition)
		elseif definition.kind == "array" then materializeArray(definition)
		end
	end
	local cached = definition._minimumBytes
	if type(cached) == "number" then return cached end
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

materializeStruct = function(definition: TypeDefinition)
	if definition._lazy ~= true then return end
	local input = definition._lazyFields
	local names = {}
	local copied = {}
	for name, fieldDefinition in input do
		if type(name) ~= "string" then
			error("[Waffles] Struct field names must be strings", 2)
		end
		copied[name] = assertTypeDefinition(fieldDefinition, "Struct field " .. name)
		names[#names + 1] = name
	end
	table.sort(names)
	local orderedDefinitions = table.create(#names)
	for index, name in names do orderedDefinitions[index] = copied[name] end
	local hash = primitiveHash("struct")
	local minimum = 0
	for index, name in names do
		hash = hashDefinitionPart(hash, #name)
		hash = hashBytes(hash, name)
		hash = hashDefinitionPart(hash, hashDefinition(orderedDefinitions[index]))
		minimum += minimumBytes(orderedDefinitions[index])
	end
	rawset(definition, "fields", table.freeze(copied))
	rawset(definition, "names", table.freeze(names))
	rawset(definition, "orderedDefinitions", table.freeze(orderedDefinitions))
	rawset(definition, "_hash", hash)
	rawset(definition, "_minimumBytes", minimum)
	rawset(definition, "_lazyFields", nil)
	rawset(definition, "_lazy", false)
	table.freeze(definition)
end

local function makeLazyStruct(fields: any): TypeDefinition
	if type(fields) ~= "table" then
		error("[Waffles] Struct fields must be a table", 2)
	end
	return {
		_wafflesType = true,
		kind = "struct",
		name = "struct",
		_lazy = true,
		_lazyFields = fields,
	} :: any
end

local function makeLazyOptional(inner: TypeDefinition): TypeDefinition
	return {
		_wafflesType = true,
		kind = "optional",
		name = "optional",
		inner = inner,
		_lazy = true,
		_minimumBytes = 1,
	} :: any
end

materializeOptional = function(definition: TypeDefinition)
	if definition._lazy ~= true then return end
	rawset(definition, "name", "optional<" .. definition.inner.name .. ">")
	rawset(definition, "_hash", hashDefinitionPart(primitiveHash("optional"), hashDefinition(definition.inner)))
	rawset(definition, "_lazy", false)
	table.freeze(definition)
end

local function makeLazyArray(element: TypeDefinition): TypeDefinition
	return {
		_wafflesType = true,
		kind = "array",
		name = "array",
		element = element,
		_lazy = true,
		_minimumBytes = 1,
	} :: any
end

materializeArray = function(definition: TypeDefinition)
	if definition._lazy ~= true then return end
	local checkedElement = assertTypeDefinition(definition.element, "Array element")
	local minimum = minimumBytes(checkedElement)
	if minimum == 0 then error("[Waffles] Array elements must encode at least one byte", 2) end
	rawset(definition, "name", "array<" .. checkedElement.name .. ">")
	rawset(definition, "_hash", hashDefinitionPart(hashDefinitionPart(primitiveHash("array"), hashDefinition(checkedElement)), minimum))
	rawset(definition, "_lazy", false)
	table.freeze(definition)
end

function Types.Array(element: TypeDefinition): TypeDefinition
	local checkedElement = assertTypeDefinition(element, "Array element")
	return makeLazyArray(checkedElement)
end

function Types.Optional(inner: TypeDefinition): TypeDefinition
	local checkedInner = assertTypeDefinition(inner, "Optional value")
	return makeLazyOptional(checkedInner)
end

function Types.Map(key: TypeDefinition, value: TypeDefinition): TypeDefinition
	assertTypeDefinition(key, "Map key")
	assertTypeDefinition(value, "Map value")
	local keyKind = key.kind
	if keyKind ~= "boolean" and keyKind ~= "string" and keyKind ~= "number" and keyKind ~= "integer" and keyKind ~= "enum" then
		error("[Waffles] Map keys must use Boolean, String, Number, Integer, or Enum", 2)
	end
	local hash = if type(key._hash) == "number" and type(value._hash) == "number"
		then hashDefinitionPart(hashDefinitionPart(primitiveHash("map"), key._hash), value._hash)
		else nil
	return table.freeze({
		_wafflesType = true,
		kind = "map",
		name = "map<" .. key.name .. ", " .. value.name .. ">",
		key = key,
		value = value,
		_hash = hash,
		_minimumBytes = 1,
	}) :: any
end

function Types.Struct(fields: {[string]: TypeDefinition}): TypeDefinition
	-- Keep lazy materialization, but detach the caller's table immediately. A
	-- later mutation must not change the definition of an already-created schema.
	return makeLazyStruct(table.clone(fields))
end

function Types.Tuple(...: TypeDefinition): TypeDefinition
	local items = {...}
	for index, definition in items do
		assertTypeDefinition(definition, "Tuple item " .. tostring(index))
	end
	local hash: number? = primitiveHash("tuple")
	local minimum = 0
	for index, definition in items do
		if hash ~= nil and type(definition._hash) == "number" then
			hash = hashDefinitionPart(hashDefinitionPart(hash, index), definition._hash)
		else
			hash = nil
		end
		minimum += minimumBytes(definition)
	end
	return table.freeze({
		_wafflesType = true,
		kind = "tuple",
		name = "tuple",
		items = table.freeze(items),
		_hash = hash,
		_minimumBytes = minimum,
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
	local hash = primitiveHash("enum")
	for index, value in values do
		local text = tostring(value)
		hash = hashDefinitionPart(hash, index)
		hash = hashBytes(hash, type(value))
		hash = hashDefinitionPart(hash, #text)
		hash = hashBytes(hash, text)
	end
	return table.freeze({
		_wafflesType = true,
		kind = "enum",
		name = "enum",
		values = table.freeze(values),
		lookup = table.freeze(lookup),
		_hash = hash,
		_minimumBytes = 1,
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
		if typeof(value) ~= "number" or value % 1 ~= 0 or mathAbs(value) > 4503599627370495 then
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
			for index, fieldName in definition.names do
				local fieldDefinition = (definition.orderedDefinitions and definition.orderedDefinitions[index]) or definition.fields[fieldName]
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
	for key in value do keys[#keys + 1] = key end
	table.sort(keys, function(a, b)
		local rankA, rankB = schemaKeyRank(a), schemaKeyRank(b)
		if rankA ~= rankB then return rankA < rankB end
		if rankA == 1 then return a == false end
		return a < b
	end)
	return keys
end

-- Schema strings are known to be strings at both ends, so they do not need an
-- automatic type tag for references. A5 uses the high varint range below;
-- A6's primitive columnar framing uses one-byte descriptors further below.
local SCHEMA_STRING_REFERENCE_BASE = 2147483648
-- A6 columnar strings are already framed by a primitive-only schema format,
-- so reserve two one-byte descriptors for references and extended lengths.
-- This keeps the common reference case to two bytes instead of a five-byte
-- 2^31-based varint while leaving A5 decoding unchanged.
local SCHEMA_COMPACT_STRING_REFERENCE = 254
local SCHEMA_COMPACT_STRING_EXTENDED = 255

local function writeSchemaString(writer: any, value: string, autoContext: any)
	local reference = autoContext.schemaStrings[value]
	if reference then
		writer:WriteVarUInt(SCHEMA_STRING_REFERENCE_BASE + reference)
		return
	end
	writer:WriteString(value)
	if #value >= autoContext.config.stringCacheMinLength then
		autoContext.schemaStringCount += 1
		autoContext.schemaStrings[value] = autoContext.schemaStringCount
	end
end

local function readSchemaString(reader: any, autoContext: any): string
	local code = reader:ReadVarUInt("schema string length")
	if code >= SCHEMA_STRING_REFERENCE_BASE then
		local id = code - SCHEMA_STRING_REFERENCE_BASE
		local value = autoContext.schemaStrings[id]
		if value == nil then error(string.format("[Waffles] Invalid schema string reference: %d", id), 2) end
		return value
	end
	if code > autoContext.config.maxStringBytes then
		error(string.format("[Waffles] Declared schema string length %d exceeds limit %d", code, autoContext.config.maxStringBytes), 2)
	end
	local value = reader:ReadRawString(code, "schema string")
	if #value >= autoContext.config.stringCacheMinLength then
		autoContext.schemaStrings[#autoContext.schemaStrings + 1] = value
	end
	return value
end

local function validationPath(autoContext: any): string
	local path = "value"
	local parts = autoContext.schemaPath
	for index = 1, autoContext.schemaPathDepth do
		local part = parts[index]
		if type(part) == "number" then
			path ..= "[" .. tostring(part) .. "]"
		else
			path ..= part
		end
	end
	return path
end

local function validationFailure(autoContext: any, expected: string, value: any): never
	local kind = typeof(value)
	local received: string
	if kind == "string" then
		received = string.format("string %q", value)
	elseif kind == "number" or kind == "boolean" or value == nil then
		received = kind .. " " .. tostring(value)
	else
		received = kind
	end
	error(string.format("[Waffles] Schema validation failed at %s: expected %s, received %s", validationPath(autoContext), expected, received), 2)
end

local function pushSchemaPath(autoContext: any, part: any)
	local depth = autoContext.schemaPathDepth + 1
	autoContext.schemaPathDepth = depth
	autoContext.schemaPath[depth] = part
end

local function popSchemaPath(autoContext: any)
	local depth = autoContext.schemaPathDepth
	autoContext.schemaPath[depth] = nil
	autoContext.schemaPathDepth = depth - 1
end

local function checkSchemaValue(definition: TypeDefinition, value: any, autoContext: any)
	if not autoContext.schemaValidationEnabled then
		return
	end
	local kind = definition.kind
	if kind == "any" then
		return
	elseif kind == "nil" then
		if value ~= nil then validationFailure(autoContext, definition.name, value) end
	elseif kind == "boolean" or kind == "string" or kind == "number" then
		if typeof(value) ~= kind then validationFailure(autoContext, definition.name, value) end
	elseif kind == "integer" then
		if typeof(value) ~= "number" or value % 1 ~= 0 or mathAbs(value) > 4503599627370495 then
			validationFailure(autoContext, definition.name, value)
		end
	elseif kind == "optional" then
		return
	elseif kind == "enum" then
		if definition.lookup[value] == nil then validationFailure(autoContext, "one of the schema enum values", value) end
	elseif kind == "buffer" then
		if typeof(value) ~= "buffer" then validationFailure(autoContext, definition.name, value) end
	elseif typeof(value) ~= "table" and (kind == "array" or kind == "tuple" or kind == "map" or kind == "struct") then
		validationFailure(autoContext, definition.name, value)
	elseif kind ~= "array" and kind ~= "tuple" and kind ~= "map" and kind ~= "struct" then
		if typeof(value) ~= kind then validationFailure(autoContext, definition.name, value) end
	end
end

local write: (TypeDefinition, any, any, any, number) -> ()
local read: (TypeDefinition, any, any, number) -> any

write = function(definition: TypeDefinition, writer: any, value: any, autoContext: any, depth: number)
	if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
	local kind = definition.kind
	checkSchemaValue(definition, value, autoContext)
	local tracksTable = autoContext.schemaValidationEnabled and (kind == "array" or kind == "tuple" or kind == "map" or kind == "struct")
	if tracksTable then
		local active = autoContext.schemaActive
		if active[value] then
			validationFailure(autoContext, definition.name, value)
		end
		active[value] = true
	end
	if kind == "any" then
		(runtime :: Runtime).writeAny(writer, value, autoContext, depth)
	elseif kind == "nil" then
		return
	elseif kind == "boolean" then
		writer:WriteU8(if value then 1 else 0)
	elseif kind == "string" then
		if #value > autoContext.config.maxStringBytes then error("[Waffles] Schema string exceeds configured length limit", 2) end
		writeSchemaString(writer, value, autoContext)
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
		local count = #value
		if count > autoContext.config.maxCollectionCount then error("[Waffles] Schema array exceeds configured count limit", 2) end
		if autoContext.schemaValidationEnabled then
			local elementCount, maximumIndex = 0, 0
			for key in value do
				if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
					validationFailure(autoContext, definition.name, value)
				end
				elementCount += 1
				if key > maximumIndex then maximumIndex = key end
			end
			if maximumIndex ~= elementCount then
				validationFailure(autoContext, "a contiguous " .. definition.name, value)
			end
		end
		writer:WriteVarUInt(count)
			for index = 1, count do
				pushSchemaPath(autoContext, index)
				write(definition.element, writer, value[index], autoContext, depth + 1)
				popSchemaPath(autoContext)
		end
	elseif kind == "map" then
		local keys = sortedMapKeys(value)
		if #keys > autoContext.config.maxCollectionCount then error("[Waffles] Schema map exceeds configured count limit", 2) end
		writer:WriteVarUInt(#keys)
		for _, key in keys do
			pushSchemaPath(autoContext, "[key]")
			write(definition.key, writer, key, autoContext, depth + 1)
			popSchemaPath(autoContext)
			local valuePath = if type(key) == "string" then "." .. key else "[" .. tostring(key) .. "]"
			pushSchemaPath(autoContext, valuePath)
			write(definition.value, writer, value[key], autoContext, depth + 1)
			popSchemaPath(autoContext)
		end
	elseif kind == "struct" then
		for index, name in definition.names do
			pushSchemaPath(autoContext, "." .. name)
			write((definition.orderedDefinitions and definition.orderedDefinitions[index]) or definition.fields[name], writer, value[name], autoContext, depth + 1)
			popSchemaPath(autoContext)
		end
	elseif kind == "tuple" then
			for index, itemDefinition in definition.items do
				pushSchemaPath(autoContext, index)
			write(itemDefinition, writer, value[index], autoContext, depth + 1)
			popSchemaPath(autoContext)
		end
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
	if tracksTable then autoContext.schemaActive[value] = nil end
end

-- Compile a schema definition into a small closure graph once.  The old
-- encoder re-dispatched on definition.kind for every field of every record;
-- stable schemas can instead jump straight to the operation for each field.
local compiledWriters: {[any]: any} = setmetatable({}, {__mode = "k"})
local compileWriter: (TypeDefinition) -> any

-- A compact struct row only needs an active-table guard when one of its
-- fields can itself contain a table.  Primitive-only rows cannot recurse, so
-- avoiding the per-row set/clear pair keeps validation intact while trimming
-- the hot nested-record path.
local function definitionMayContainTable(definition: TypeDefinition): boolean
	local kind = definition.kind
	if kind == "any" then return true end
	if kind == "optional" then return definitionMayContainTable(definition.inner) end
	if kind == "array" or kind == "tuple" or kind == "map" or kind == "struct" then return true end
	-- Unknown/custom kinds are routed through the automatic codec and may
	-- contain tables, so keep the conservative guard for them.
	if kind == "nil" or kind == "boolean" or kind == "string" or kind == "number" or kind == "integer" or kind == "buffer" or kind == "enum"
		or kind == "Vector2" or kind == "Vector3" or kind == "Vector2int16" or kind == "Vector3int16" or kind == "CFrame" or kind == "Color3" or kind == "BrickColor"
		or kind == "UDim" or kind == "UDim2" or kind == "Rect" or kind == "Ray" or kind == "NumberRange" or kind == "NumberSequence"
		or kind == "NumberSequenceKeypoint" or kind == "ColorSequence" or kind == "ColorSequenceKeypoint" or kind == "DateTime" or kind == "Font" or kind == "EnumItem" then
		return false
	end
	return true
end

local function compiledBegin(definition: TypeDefinition, value: any, autoContext: any, depth: number): boolean
	if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
	checkSchemaValue(definition, value, autoContext)
	local kind = definition.kind
	local tracksTable = autoContext.schemaValidationEnabled and (kind == "array" or kind == "tuple" or kind == "map" or kind == "struct")
	if tracksTable then
		local active = autoContext.schemaActive
		if active[value] then validationFailure(autoContext, definition.name, value) end
		active[value] = true
	end
	return tracksTable
end

local function compiledFinish(value: any, autoContext: any, tracksTable: boolean)
	if tracksTable then autoContext.schemaActive[value] = nil end
end

compileWriter = function(definition: TypeDefinition): any
	local cached = compiledWriters[definition]
	if cached then return cached end
	local kind = definition.kind
	local fn: any
	if kind == "any" then
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			(runtime :: Runtime).writeAny(writer, value, autoContext, depth)
		end
	elseif kind == "nil" then
		fn = function(_writer: any, value: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			checkSchemaValue(definition, value, autoContext)
		end
	elseif kind == "boolean" then
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			checkSchemaValue(definition, value, autoContext); writer:WriteU8(if value then 1 else 0)
		end
	elseif kind == "string" then
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			checkSchemaValue(definition, value, autoContext)
			if #value > autoContext.config.maxStringBytes then error("[Waffles] Schema string exceeds configured length limit", 2) end
			writeSchemaString(writer, value, autoContext)
		end
	elseif kind == "number" then
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			checkSchemaValue(definition, value, autoContext); writer:WriteF64(value)
		end
	elseif kind == "integer" then
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			checkSchemaValue(definition, value, autoContext); writer:WriteVarInt(value)
		end
	elseif kind == "buffer" then
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			checkSchemaValue(definition, value, autoContext)
			if buffer.len(value) > autoContext.config.maxBufferBytes then error("[Waffles] Schema buffer exceeds configured length limit", 2) end
			writer:WriteBuffer(value)
		end
	elseif kind == "optional" then
		local child = compileWriter(definition.inner)
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			checkSchemaValue(definition, value, autoContext)
			if value == nil then
				writer:WriteU8(0)
			else
				writer:WriteU8(1)
				if autoContext.schemaValidationEnabled then pushSchemaPath(autoContext, "") end
				child(writer, value, autoContext, depth + 1)
				if autoContext.schemaValidationEnabled then popSchemaPath(autoContext) end
			end
		end
	elseif kind == "array" then
		local child = compileWriter(definition.element)
		local elementDefinition = definition.element
		local compactStruct = elementDefinition.kind == "struct"
		local compactNames: {string}? = nil
		local compactWriters: {any}? = nil
		local compactOptional: {boolean}? = nil
		local compactPaths: {string}? = nil
		local compactDefinitions: {TypeDefinition}? = nil
		local compactKinds: {string}? = nil
		local compactNeedsCycleGuard = false
		local compactFastSafe = true
		if compactStruct then
			local names = elementDefinition.names
			local writers = table.create(#names)
			local optionalFields = table.create(#names, false)
			local fieldPaths = table.create(#names)
			local definitions = table.create(#names)
			local kinds = table.create(#names)
			for index, name in names do
				local fieldDefinition = (elementDefinition.orderedDefinitions and elementDefinition.orderedDefinitions[index]) or elementDefinition.fields[name]
				if not compactNeedsCycleGuard and definitionMayContainTable(fieldDefinition) then compactNeedsCycleGuard = true end
				local fastKind = fieldDefinition.kind
				if fastKind == "optional" then fastKind = fieldDefinition.inner.kind end
				if fastKind ~= "boolean" and fastKind ~= "string" and fastKind ~= "number" and fastKind ~= "integer" and fastKind ~= "enum" then
					compactFastSafe = false
				end
				fieldPaths[index] = "." .. name
				if fieldDefinition.kind == "optional" then
					optionalFields[index] = true
					writers[index] = compileWriter(fieldDefinition.inner)
					definitions[index] = fieldDefinition.inner
					kinds[index] = fieldDefinition.inner.kind
				else
					writers[index] = compileWriter(fieldDefinition)
					definitions[index] = fieldDefinition
					kinds[index] = fieldDefinition.kind
				end
			end
			compactNames, compactWriters, compactOptional, compactPaths = names, writers, optionalFields, fieldPaths
			compactDefinitions, compactKinds = definitions, kinds
		end
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			local tracks = compiledBegin(definition, value, autoContext, depth)
			local count = #value
			local compactFieldCount = if compactNames ~= nil then #(compactNames :: {string}) else 0
			if count > autoContext.config.maxCollectionCount then error("[Waffles] Schema array exceeds configured count limit", 2) end
			if autoContext.schemaValidationEnabled then
				local elementCount, maximumIndex = 0, 0
				for key in value do
					if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then validationFailure(autoContext, definition.name, value) end
					elementCount += 1; if key > maximumIndex then maximumIndex = key end
				end
				if maximumIndex ~= elementCount then validationFailure(autoContext, "a contiguous " .. definition.name, value) end
			end
			if compactStruct and count >= 2
				and compactFieldCount > 0
				and compactFieldCount <= autoContext.config.maxRecordFields
				and count <= math.floor(autoContext.config.maxRecordCells / compactFieldCount) then
				local fastWriter = if compactFastSafe then (writer :: any)._fast else nil
				local writeTarget: any = writer
				if fastWriter ~= nil then
					fastWriter.Begin()
					writeTarget = fastWriter
				end
				local writeU8 = writeTarget.WriteU8
				local writeVarUInt = if fastWriter ~= nil then fastWriter.WriteVarUIntUnchecked else writeTarget.WriteVarUInt
				-- Marker + format byte distinguish the compact array body from the
				-- original count-first representation.  A6 is the columnar primitive
				-- form; A5 remains readable for payloads produced by older Waffles
				-- versions and for nested/non-primitive rows.
				writeU8(writeTarget, 255)
				writeU8(writeTarget, if compactFastSafe then 0xA6 else 0xA5)
				writeVarUInt(writeTarget, count)
					if compactFastSafe and autoContext.schemaValidationEnabled then
						for index = 1, count do
							local row = value[index]
							if type(row) ~= "table" then
								pushSchemaPath(autoContext, index)
								validationFailure(autoContext, elementDefinition.name, row)
							end
						end
					end
					local presenceBits = PRESENCE_BITS
					for fieldIndex, isOptional in (compactOptional :: {boolean}) do
					if isOptional then
						local bits, bit = 0, 0
						for rowIndex = 1, count do
							local row = value[rowIndex]
							if row[(compactNames :: {string})[fieldIndex]] ~= nil then bits += presenceBits[bit + 1] end
							bit += 1
							if bit == 8 or rowIndex == count then
								writeU8(writeTarget, bits); bits, bit = 0, 0
							end
						end
					end
				end
				local names, writers, optionals = compactNames :: {string}, compactWriters :: {any}, compactOptional :: {boolean}
				if compactFastSafe then
					-- Primitive-only rows use a columnar body.  Keeping the field kind
					-- outside the row loop mirrors the automatic codec and lets the
					-- string/integer writers stay on their tightest path.
					local definitions, kinds = compactDefinitions :: {TypeDefinition}, compactKinds :: {string}
					local validating = autoContext.schemaValidationEnabled
					local maxDepth = autoContext.config.maxDepth
						local writeF64 = writeTarget.WriteF64
					local writeRawString = writeTarget.WriteRawString
					local schemaStrings = autoContext.schemaStrings
					local schemaStringCount = autoContext.schemaStringCount
					local schemaStringMin = autoContext.config.stringCacheMinLength
					local maxStringBytes = autoContext.config.maxStringBytes
					if depth + 2 > maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
						for fieldIndex, name in names do
						local fieldDefinition = definitions[fieldIndex]
						local fieldKind = kinds[fieldIndex]
						local isOptional = optionals[fieldIndex]
								if fieldKind == "string" then
									for index = 1, count do
										local fieldValue = value[index][name]
								if not isOptional or fieldValue ~= nil then
										if validating and type(fieldValue) ~= "string" then
										pushSchemaPath(autoContext, index); pushSchemaPath(autoContext, (compactPaths :: {string})[fieldIndex])
										validationFailure(autoContext, fieldDefinition.name, fieldValue)
									end
									if #fieldValue > maxStringBytes then error("[Waffles] Schema string exceeds configured length limit", 2) end
										local reference = schemaStrings[fieldValue]
										if reference then
											writeU8(writeTarget, SCHEMA_COMPACT_STRING_REFERENCE)
											writeVarUInt(writeTarget, reference)
										else
											local length = #fieldValue
											if length < SCHEMA_COMPACT_STRING_REFERENCE then
												writeU8(writeTarget, length)
											else
												writeU8(writeTarget, SCHEMA_COMPACT_STRING_EXTENDED)
												writeVarUInt(writeTarget, length)
											end
											if length > 0 then writeRawString(writeTarget, fieldValue) end
											if length >= schemaStringMin then schemaStringCount += 1; schemaStrings[fieldValue] = schemaStringCount end
										end
								end
							end
					elseif fieldKind == "boolean" then
							for index = 1, count do
								local fieldValue = value[index][name]
								if not isOptional or fieldValue ~= nil then
										if validating and type(fieldValue) ~= "boolean" then
										pushSchemaPath(autoContext, index); pushSchemaPath(autoContext, (compactPaths :: {string})[fieldIndex])
										validationFailure(autoContext, fieldDefinition.name, fieldValue)
									end
									writeU8(writeTarget, if fieldValue then 1 else 0)
								end
							end
						elseif fieldKind == "number" then
							for index = 1, count do
								local fieldValue = value[index][name]
								if not isOptional or fieldValue ~= nil then
										if validating and type(fieldValue) ~= "number" then
										pushSchemaPath(autoContext, index); pushSchemaPath(autoContext, (compactPaths :: {string})[fieldIndex])
										validationFailure(autoContext, fieldDefinition.name, fieldValue)
									end
									writeF64(writeTarget, fieldValue)
								end
							end
						elseif fieldKind == "integer" then
							for index = 1, count do
								local fieldValue = value[index][name]
								if not isOptional or fieldValue ~= nil then
										if validating and (type(fieldValue) ~= "number" or fieldValue % 1 ~= 0 or mathAbs(fieldValue) > 4503599627370495) then
										pushSchemaPath(autoContext, index); pushSchemaPath(autoContext, (compactPaths :: {string})[fieldIndex])
										validationFailure(autoContext, fieldDefinition.name, fieldValue)
									end
									local zigzag = if fieldValue >= 0 then fieldValue * 2 else -fieldValue * 2 - 1
									writeVarUInt(writeTarget, zigzag)
								end
							end
						else
							for index = 1, count do
								local fieldValue = value[index][name]
								if not isOptional or fieldValue ~= nil then
									if validating and fieldDefinition.lookup[fieldValue] == nil then
										pushSchemaPath(autoContext, index); pushSchemaPath(autoContext, (compactPaths :: {string})[fieldIndex])
										validationFailure(autoContext, fieldDefinition.name, fieldValue)
									end
									writeVarUInt(writeTarget, fieldDefinition.lookup[fieldValue] - 1)
								end
							end
						end
					end
					autoContext.schemaStringCount = schemaStringCount
				else
					for index = 1, count do
						local row = value[index]
						if autoContext.schemaValidationEnabled then pushSchemaPath(autoContext, index) end
						local rowTracks = false
						if compactNeedsCycleGuard then
							rowTracks = compiledBegin(elementDefinition, row, autoContext, depth + 1)
						elseif depth + 1 > autoContext.config.maxDepth then
							error("[Waffles] Maximum schema nesting depth exceeded", 2)
						elseif autoContext.schemaValidationEnabled then
							if typeof(row) ~= "table" then validationFailure(autoContext, elementDefinition.name, row) end
							if autoContext.schemaActive[row] then validationFailure(autoContext, elementDefinition.name, row) end
						end
						for fieldIndex, name in names do
							local fieldValue = row[name]
							if not optionals[fieldIndex] or fieldValue ~= nil then
								if autoContext.schemaValidationEnabled then pushSchemaPath(autoContext, (compactPaths :: {string})[fieldIndex]) end
								writers[fieldIndex](writeTarget, fieldValue, autoContext, depth + 2)
								if autoContext.schemaValidationEnabled then popSchemaPath(autoContext) end
							end
						end
						if rowTracks then compiledFinish(row, autoContext, true) end
						if autoContext.schemaValidationEnabled then popSchemaPath(autoContext) end
					end
				end
				if fastWriter ~= nil then fastWriter.Finish() end
			else
				writer:WriteVarUInt(count)
				for index = 1, count do
					if autoContext.schemaValidationEnabled then pushSchemaPath(autoContext, index) end
					child(writer, value[index], autoContext, depth + 1)
					if autoContext.schemaValidationEnabled then popSchemaPath(autoContext) end
				end
			end
			compiledFinish(value, autoContext, tracks)
		end
	elseif kind == "map" then
		local keyWriter = compileWriter(definition.key)
		local valueWriter = compileWriter(definition.value)
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			local tracks = compiledBegin(definition, value, autoContext, depth)
			local keys = sortedMapKeys(value)
			if #keys > autoContext.config.maxCollectionCount then error("[Waffles] Schema map exceeds configured count limit", 2) end
			writer:WriteVarUInt(#keys)
			for _, key in keys do
				if autoContext.schemaValidationEnabled then pushSchemaPath(autoContext, "[key]") end
				keyWriter(writer, key, autoContext, depth + 1)
				if autoContext.schemaValidationEnabled then popSchemaPath(autoContext) end
				if autoContext.schemaValidationEnabled then pushSchemaPath(autoContext, if type(key) == "string" then "." .. key else "[" .. tostring(key) .. "]") end
				valueWriter(writer, value[key], autoContext, depth + 1)
				if autoContext.schemaValidationEnabled then popSchemaPath(autoContext) end
			end
			compiledFinish(value, autoContext, tracks)
		end
	elseif kind == "struct" then
		local childWriters = table.create(#definition.names)
		local childPaths = table.create(#definition.names)
		for index, name in definition.names do
			childWriters[index] = compileWriter((definition.orderedDefinitions and definition.orderedDefinitions[index]) or definition.fields[name])
			childPaths[index] = "." .. name
		end
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			local tracks = compiledBegin(definition, value, autoContext, depth)
			for index, name in definition.names do
				if autoContext.schemaValidationEnabled then pushSchemaPath(autoContext, childPaths[index]) end
				childWriters[index](writer, value[name], autoContext, depth + 1)
				if autoContext.schemaValidationEnabled then popSchemaPath(autoContext) end
			end
			compiledFinish(value, autoContext, tracks)
		end
	elseif kind == "tuple" then
		local childWriters = table.create(#definition.items)
		for index, item in definition.items do childWriters[index] = compileWriter(item) end
			fn = function(writer: any, value: any, autoContext: any, depth: number)
				local tracks = compiledBegin(definition, value, autoContext, depth)
				for index = 1, #childWriters do
					if autoContext.schemaValidationEnabled then pushSchemaPath(autoContext, index) end
				childWriters[index](writer, value[index], autoContext, depth + 1)
				if autoContext.schemaValidationEnabled then popSchemaPath(autoContext) end
			end
			compiledFinish(value, autoContext, tracks)
		end
	elseif kind == "enum" then
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			checkSchemaValue(definition, value, autoContext); writer:WriteVarUInt(definition.lookup[value] - 1)
		end
	else
		-- Keep the less common Roblox branches in one place; they are not part
		-- of the hot nested-record benchmark and the generic implementation is
		-- still fully bounds checked.
		fn = function(writer: any, value: any, autoContext: any, depth: number)
			write(definition, writer, value, autoContext, depth)
		end
	end
	compiledWriters[definition] = fn
	return fn
end

local function checkedSchemaCount(reader: any, context: any, label: string): number
	local count = reader:ReadVarUInt(label .. " count")
	if count > context.config.maxCollectionCount or count > reader:Remaining() then
		error("[Waffles] Invalid or excessive schema " .. label .. " count", 3)
	end
	return count
end

local function checkedRecordCells(context: any, count: number, fieldCount: number, label: string)
	if fieldCount > context.config.maxRecordFields then
		error(string.format("[Waffles] Declared %s field count %d exceeds limit %d", label, fieldCount, context.config.maxRecordFields), 2)
	end
	if fieldCount > 0 and count > math.floor(context.config.maxRecordCells / fieldCount) then
		error(string.format("[Waffles] %s has too many cells (%d x %d exceeds limit %d)", label, count, fieldCount, context.config.maxRecordCells), 2)
	end
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
		return readSchemaString(reader, autoContext)
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
		local first = reader:ReadU8("schema array prefix")
		local compact = false
		if first == 255 then
			local format = reader:ReadU8("schema array format")
			-- Only struct arrays have a compact body.  Restricting the marker to
			-- that definition also keeps a large regular primitive-array count
			-- (whose varint may begin with 0xFF, 0xA5) unambiguous.
			if format == 0xA5 and definition.element.kind == "struct" then
				compact = true
			else
				reader._cursor -= 2
			end
		else
			reader._cursor -= 1
		end
		local count = checkedSchemaCount(reader, autoContext, "array")
		if compact then
			local element = definition.element
			if element.kind ~= "struct" then error("[Waffles] Invalid compact schema array element", 2) end
			local names = element.names
			local fields = element.orderedDefinitions
			checkedRecordCells(autoContext, count, #names, "compact schema record array")
			local maskBytes = math.floor((count + 7) / 8)
			local optionalFieldCount = 0
			for fieldIndex, _name in names do
				local fieldDefinition = fields[fieldIndex] or element.fields[names[fieldIndex]]
				if fieldDefinition.kind == "optional" then optionalFieldCount += 1 end
			end
			local presenceOffsets = table.create(#names, -1)
			local presence: buffer? = if optionalFieldCount > 0 then buffer.create(optionalFieldCount * maskBytes) else nil
			local optionalOrdinal = 0
			for fieldIndex, name in names do
				local fieldDefinition = fields[fieldIndex] or element.fields[name]
				if fieldDefinition.kind == "optional" then
					optionalOrdinal += 1
					local offset = (optionalOrdinal - 1) * maskBytes
					presenceOffsets[fieldIndex] = offset
					for maskIndex = 0, maskBytes - 1 do
						buffer.writeu8(presence :: buffer, offset + maskIndex, reader:ReadU8("schema optional presence"))
					end
				end
			end
			local result = table.create(count)
			for rowIndex = 1, count do
				local row = {}
				for fieldIndex, name in names do
					local fieldDefinition = fields[fieldIndex] or element.fields[name]
					if fieldDefinition.kind == "optional" then
						local maskIndex = math.floor((rowIndex - 1) / 8)
						local bitMask = PRESENCE_BITS[((rowIndex - 1) % 8) + 1]
						if bit32Band(buffer.readu8(presence :: buffer, presenceOffsets[fieldIndex] + maskIndex), bitMask) ~= 0 then
							row[name] = read(fieldDefinition.inner, reader, autoContext, depth + 2)
						end
					else
						row[name] = read(fieldDefinition, reader, autoContext, depth + 2)
					end
				end
				result[rowIndex] = row
			end
			return result
		end
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
		for index, name in definition.names do result[name] = read((definition.orderedDefinitions and definition.orderedDefinitions[index]) or definition.fields[name], reader, autoContext, depth + 1) end
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

-- Compile the schema reader as well as the writer.  A schema is immutable, so
-- the per-definition dispatch can be paid once and the hot array-of-struct
-- path can call the primitive readers directly.
local compiledReaders: {[any]: any} = setmetatable({}, {__mode = "k"})
local compileReader: (TypeDefinition) -> any

compileReader = function(definition: TypeDefinition): any
	local cached = compiledReaders[definition]
	if cached then return cached end
	local kind = definition.kind
	local fn: any
	if kind == "any" then
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			return (runtime :: Runtime).readAny(reader, autoContext, depth)
		end
	elseif kind == "nil" then
		fn = function(_reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			return nil
		end
	elseif kind == "boolean" then
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			local byte = reader:ReadU8("schema boolean")
			if byte > 1 then error("[Waffles] Invalid schema boolean", 2) end
			return byte == 1
		end
	elseif kind == "string" then
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			return readSchemaString(reader, autoContext)
		end
	elseif kind == "number" then
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			return reader:ReadF64("schema number")
		end
	elseif kind == "integer" then
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			return reader:ReadVarInt("schema integer")
		end
	elseif kind == "buffer" then
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			return reader:ReadBuffer(autoContext.config.maxBufferBytes, "schema buffer")
		end
	elseif kind == "optional" then
		local child = compileReader(definition.inner)
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			local present = reader:ReadU8("optional marker")
			if present == 0 then return nil end
			if present ~= 1 then error("[Waffles] Invalid optional marker", 2) end
			return child(reader, autoContext, depth + 1)
		end
	elseif kind == "array" then
		-- The common compact struct-array format reads primitive columns inline,
		-- so compiling the recursive row reader eagerly only adds cold-start work.
		-- Build it lazily for legacy/non-compact arrays instead.
		local child: any = nil
		local childReady = false
		local function ensureChild(): any
			if not childReady then
				child = compileReader(definition.element)
				childReady = true
			end
			return child
		end
		local element = definition.element
		local compactStruct = element.kind == "struct"
		local compactNames: {string}? = nil
		local compactReaders: {any}? = nil
		local compactOptional: {boolean}? = nil
		local compactDefinitions: {TypeDefinition}? = nil
		local compactKinds: {string}? = nil
		local compactFastSafe = true
		local compactReadersReady = false
		if compactStruct then
			local names = element.names
			local readers = table.create(#names)
			local optionalFields = table.create(#names, false)
			local definitions = table.create(#names)
			local kinds = table.create(#names)
			for index, name in names do
				local fieldDefinition = (element.orderedDefinitions and element.orderedDefinitions[index]) or element.fields[name]
				if fieldDefinition.kind == "optional" then
					optionalFields[index] = true
					definitions[index] = fieldDefinition.inner
					kinds[index] = fieldDefinition.inner.kind
				else
					definitions[index] = fieldDefinition
					kinds[index] = fieldDefinition.kind
				end
				local fastKind = if fieldDefinition.kind == "optional" then fieldDefinition.inner.kind else fieldDefinition.kind
				if fastKind ~= "boolean" and fastKind ~= "string" and fastKind ~= "number" and fastKind ~= "integer" and fastKind ~= "enum" then
					compactFastSafe = false
				end
			end
			compactNames, compactReaders, compactOptional = names, readers, optionalFields
			compactDefinitions, compactKinds = definitions, kinds
		end
		local function ensureCompactReaders()
			if compactReadersReady or not compactStruct then return end
			local names = compactNames :: {string}
			local element = definition.element
			local readers = compactReaders :: {any}
			for index, name in names do
				local fieldDefinition = (element.orderedDefinitions and element.orderedDefinitions[index]) or element.fields[name]
				readers[index] = compileReader(if fieldDefinition.kind == "optional" then fieldDefinition.inner else fieldDefinition)
			end
			compactReadersReady = true
		end
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			local first = reader:ReadU8("schema array prefix")
			local compact = false
			local compactColumnar = false
			if first == 255 then
				local format = reader:ReadU8("schema array format")
				if format == 0xA6 and compactStruct then
					compact = true
					compactColumnar = true
				elseif format == 0xA5 and compactStruct then
					compact = true
				else
					reader._cursor -= 2
				end
			else
				reader._cursor -= 1
			end
			local count = checkedSchemaCount(reader, autoContext, "array")
		if compact then
			local names, readers, optionals = compactNames :: {string}, compactReaders :: {any}, compactOptional :: {boolean}
			checkedRecordCells(autoContext, count, #names, "compact schema record array")
			if not compactColumnar or not compactFastSafe then ensureCompactReaders() end
				local fastReader = if compactFastSafe then (reader :: any)._fast else nil
				local readTarget: any = reader
				if fastReader ~= nil then
					fastReader.Begin()
					readTarget = fastReader
				end
					local maskBytes = math.floor((count + 7) / 8)
					local optionalFieldCount = 0
					for fieldIndex, _name in names do
						if optionals[fieldIndex] then optionalFieldCount += 1 end
					end
					local presenceOffsets = table.create(#names, -1)
					local presence: buffer? = if optionalFieldCount > 0 then buffer.create(optionalFieldCount * maskBytes) else nil
					local optionalOrdinal = 0
					local readU8 = readTarget.ReadU8
					local data: buffer = reader._data
					local cursor = reader._cursor
					local readU8Fast: (() -> number)? = nil
					local readF64Fast: (() -> number)? = nil
					local readVarUIntFast: (() -> number)? = nil
					local readRawStringFast: ((number) -> string)? = nil
					if compactColumnar then
						if fastReader == nil then error("[Waffles] Internal fast reader unavailable", 2) end
						readU8Fast = fastReader.ReadU8Unchecked
						readF64Fast = fastReader.ReadF64Unchecked
						readVarUIntFast = fastReader.ReadVarUIntUnchecked
						readRawStringFast = fastReader.ReadRawStringUnchecked
					end
					for fieldIndex, _name in names do
						if optionals[fieldIndex] then
							optionalOrdinal += 1
							local offset = (optionalOrdinal - 1) * maskBytes
							presenceOffsets[fieldIndex] = offset
							for maskIndex = 0, maskBytes - 1 do
								if compactColumnar then
									buffer.writeu8(presence :: buffer, offset + maskIndex, (readU8Fast :: (() -> number))())
								else
									buffer.writeu8(presence :: buffer, offset + maskIndex, readU8(readTarget, "schema optional presence"))
								end
							end
						end
					end
					local result = table.create(count)
					for rowIndex = 1, count do result[rowIndex] = {} end
					if compactColumnar then
						local definitions, kinds = compactDefinitions :: {TypeDefinition}, compactKinds :: {string}
						local schemaStrings = autoContext.schemaStrings
						local schemaStringMin = autoContext.config.stringCacheMinLength
						local maxStringBytes = autoContext.config.maxStringBytes
						for fieldIndex, name in names do
							local fieldDefinition = definitions[fieldIndex]
							local fieldKind = kinds[fieldIndex]
							local isOptional = optionals[fieldIndex]
								local presenceOffset = presenceOffsets[fieldIndex]
								local maskIndex, bitMask = 0, 1
							if fieldKind == "string" then
								for rowIndex = 1, count do
									local present = not isOptional
									if isOptional then
										present = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
										bitMask *= 2
										if bitMask == 256 then maskIndex += 1; bitMask = 1 end
									end
									if present then
										local first = (readU8Fast :: (() -> number))()
										local value: string
										if first == SCHEMA_COMPACT_STRING_REFERENCE then
											local id = (readVarUIntFast :: (() -> number))()
											value = schemaStrings[id]
											if value == nil then error(string.format("[Waffles] Invalid schema string reference: %d", id), 2) end
										else
											local length = if first == SCHEMA_COMPACT_STRING_EXTENDED then (readVarUIntFast :: (() -> number))() else first
											if length > maxStringBytes then error(string.format("[Waffles] Declared schema string length %d exceeds limit %d", length, maxStringBytes), 2) end
											value = (readRawStringFast :: ((number) -> string))(length)
											if length >= schemaStringMin then schemaStrings[#schemaStrings + 1] = value end
										end
										result[rowIndex][name] = value
									end
								end
							elseif fieldKind == "boolean" then
								for rowIndex = 1, count do
									local present = not isOptional
									if isOptional then
										present = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
										bitMask *= 2
										if bitMask == 256 then maskIndex += 1; bitMask = 1 end
									end
									if present then
										local byte = (readU8Fast :: (() -> number))()
										if byte > 1 then error("[Waffles] Invalid schema boolean", 2) end
										result[rowIndex][name] = byte == 1
									end
								end
							elseif fieldKind == "number" then
								for rowIndex = 1, count do
									local present = not isOptional
									if isOptional then
										present = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
										bitMask *= 2
										if bitMask == 256 then maskIndex += 1; bitMask = 1 end
									end
									if present then
										result[rowIndex][name] = (readF64Fast :: (() -> number))()
									end
								end
							elseif fieldKind == "integer" then
								for rowIndex = 1, count do
									local present = not isOptional
									if isOptional then
										present = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
										bitMask *= 2
										if bitMask == 256 then maskIndex += 1; bitMask = 1 end
									end
									if present then
										local zigzag = (readVarUIntFast :: (() -> number))()
										if zigzag > 9007199254740990 then error("[Waffles] Signed variable-length integer overflow", 2) end
										result[rowIndex][name] = if zigzag % 2 == 0 then zigzag / 2 else -(zigzag + 1) / 2
									end
								end
							else
								for rowIndex = 1, count do

									local present = not isOptional
									if isOptional then
										present = bit32Band(bufferReadU8(presence :: buffer, presenceOffset + maskIndex), bitMask) ~= 0
										bitMask *= 2
										if bitMask == 256 then maskIndex += 1; bitMask = 1 end
									end
									if present then
										local index = (readVarUIntFast :: (() -> number))() + 1
										local value = fieldDefinition.lookup[index]
										if value == nil then error("[Waffles] Invalid schema enum identifier", 2) end
										result[rowIndex][name] = value
									end
								end
							end
						end
					else
						for rowIndex = 1, count do
							local row = result[rowIndex]
							for fieldIndex, name in names do
								if not optionals[fieldIndex] then
									row[name] = readers[fieldIndex](readTarget, autoContext, depth + 2)
								else
									local zeroBasedRow = rowIndex - 1
									local maskIndex = math.floor(zeroBasedRow / 8)
									local bitMask = PRESENCE_BITS[(zeroBasedRow % 8) + 1]
									if bit32Band(buffer.readu8(presence :: buffer, presenceOffsets[fieldIndex] + maskIndex), bitMask) ~= 0 then
										row[name] = readers[fieldIndex](readTarget, autoContext, depth + 2)
									end
								end
						end
					end
				end
				if compactColumnar then
					(fastReader :: any).Finish()
				elseif fastReader ~= nil then
					fastReader.Finish()
				end
				return result
			end
			local result = table.create(count)
			local readChild = ensureChild()
			for index = 1, count do result[index] = readChild(reader, autoContext, depth + 1) end
			return result
		end
	elseif kind == "map" then
		local keyReader = compileReader(definition.key)
		local valueReader = compileReader(definition.value)
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			local count = checkedSchemaCount(reader, autoContext, "map")
			local result = {}
			local seen = {}
			for _ = 1, count do
				local key = keyReader(reader, autoContext, depth + 1)
				if key == nil or (type(key) == "number" and key ~= key) then error("[Waffles] Invalid schema map key", 2) end
				if seen[key] then error("[Waffles] Duplicate schema map key", 2) end
				seen[key] = true
				result[key] = valueReader(reader, autoContext, depth + 1)
			end
			return result
		end
	elseif kind == "struct" then
		local names = definition.names
		local readers = table.create(#names)
		for index, name in names do readers[index] = compileReader((definition.orderedDefinitions and definition.orderedDefinitions[index]) or definition.fields[name]) end
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			local result = {}
			for index, name in names do result[name] = readers[index](reader, autoContext, depth + 1) end
			return result
		end
	elseif kind == "tuple" then
		local readers = table.create(#definition.items)
		for index, item in definition.items do readers[index] = compileReader(item) end
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			local result = table.create(#readers)
			for index = 1, #readers do result[index] = readers[index](reader, autoContext, depth + 1) end
			return result
		end
	elseif kind == "enum" then
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			local index = reader:ReadVarUInt("schema enum") + 1
			local value = definition.values[index]
			if value == nil then error("[Waffles] Invalid schema enum identifier", 2) end
			return value
		end
	else
		fn = function(reader: any, autoContext: any, depth: number)
			if depth > autoContext.config.maxDepth then error("[Waffles] Maximum schema nesting depth exceeded", 2) end
			return read(definition, reader, autoContext, depth)
		end
	end
	compiledReaders[definition] = fn
	return fn
end

local function descriptorText(definition: TypeDefinition): string
	if definition._lazy == true then
		if definition.kind == "struct" then materializeStruct(definition)
		elseif definition.kind == "optional" then materializeOptional(definition)
		elseif definition.kind == "array" then materializeArray(definition)
		end
	end
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

hashDefinition = function(definition: TypeDefinition): number
	if definition._lazy == true then
		if definition.kind == "struct" then materializeStruct(definition)
		elseif definition.kind == "optional" then materializeOptional(definition)
		elseif definition.kind == "array" then materializeArray(definition)
		end
	end
	if type(definition._hash) == "number" then return definition._hash end
	local hash = 5381
	local text = descriptorText(definition)
	for index = 1, #text do
		hash = (hash * 33 + string.byte(text, index)) % HASH_MODULUS
	end
	return hash
end

local schemaHashes: {[any]: number} = setmetatable({}, {__mode = "k"}) :: any
local SchemaMethods = {}

local function schemaHash(schema: any): number
	local cached = schemaHashes[schema]
	if cached ~= nil then return cached end
	local hash = hashDefinition(schema.Definition)
	schemaHashes[schema] = hash
	return hash
end

local SchemaMetatable = {
	__index = function(self: any, key: any): any
		if key == "Hash" then return schemaHash(self) end
		return SchemaMethods[key]
	end,
}

function SchemaMethods.Serialize(self: any, value: any): buffer
	return (runtime :: Runtime).serialize(self, value)
end

function SchemaMethods.Deserialize(self: any, data: buffer): any
	return (runtime :: Runtime).deserialize(self, data)
end

function SchemaMethods.Validate(self: any, value: any): (boolean, string?)
	if self.Definition._lazy == true then hashDefinition(self.Definition) end
	return validate(self.Definition, value, "value", 0, {})
end

function SchemaModule.create(definitionOrFields: any): SchemaObject
	local definition: TypeDefinition
	if type(definitionOrFields) == "table" and definitionOrFields._wafflesType == true then
		definition = definitionOrFields
	else
		definition = Types.Struct(definitionOrFields)
	end
	-- Keep the hot methods directly on the schema object.  The metatable is only
	-- needed for the lazily computed Hash property; routing Serialize/Deserialize
	-- through __index adds avoidable work to the first-call benchmark and every
	-- wrapper invocation.
	return table.freeze(setmetatable({
		Definition = definition,
		Serialize = SchemaMethods.Serialize,
		Deserialize = SchemaMethods.Deserialize,
		Validate = SchemaMethods.Validate,
	}, SchemaMetatable)) :: any
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
	if kind == "number" then return if value % 1 == 0 and mathAbs(value) <= 4503599627370495 and not (value == 0 and 1 / value == -math.huge) then Types.Integer else Types.Number end
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
	compileWriter(definition)(writer, value, autoContext, 0)
end

function SchemaModule.readDefinition(definition: TypeDefinition, reader: any, autoContext: any): any
	return compileReader(definition)(reader, autoContext, 0)
end

-- Prepare both directions together after the first successful schema encode.
-- Keeping this lazy preserves lightweight schema construction while moving the
-- small reader compiler cost out of the separately measured first decode.
function SchemaModule.prepare(definition: TypeDefinition)
	compileWriter(definition)
	compileReader(definition)
end

SchemaModule.Types = table.freeze(Types)

return SchemaModule
