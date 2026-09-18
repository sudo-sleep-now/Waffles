-- Run from a flat benchmark staging directory:
--   luau -O2 benchmark-cli.luau -a waffles auto 40
-- The companion run-pancakes-vs-waffles.sh creates this staging directory.

local target = select(1, ...)
local mode = select(2, ...)
local requestedCount = tonumber(select(3, ...))
if target ~= "pancakes" and target ~= "waffles" then error("target must be pancakes or waffles") end
if mode ~= "auto" and mode ~= "schema" then error("mode must be auto or schema") end
if requestedCount ~= 40 and requestedCount ~= 120 then error("count must be 40 or 120") end

local isPancakes = target == "pancakes"
local requireStarted = os.clock()
local Library = if isPancakes then require("./Pancakes/main") else require("./Waffles/main")
local requireUs = (os.clock() - requireStarted) * 1000000

local function makeInventory(count: number): any
	local items = table.create(count)
	for index = 1, count do
		items[index] = {
			uid = "item-" .. tostring(index),
			id = if index % 3 == 0 then "Honey" else "Wax",
			amount = (index % 7) + 1,
			nickname = if index % 5 == 0 then "Keep" else nil,
		}
	end
	return {coins = 1250, items = items}
end

local encodeAuto = Library.SerializeAuto
local decodeAuto = Library.DeserializeAuto
local encodeSchema: (any) -> buffer
local decodeSchema: (buffer) -> any
local schemaSetupStarted = os.clock()
if isPancakes then
	local Field = Library.Field
	local itemSchema = {
		Field.String("uid"),
		Field.String("id"),
		Field.AdaptiveNumber("amount"),
		Field.Optional(Field.String("nickname")),
	}
	local schema = {
		Field.AdaptiveNumber("coins"),
		Field.Array("items", Field.Table("item", itemSchema)),
	}
	encodeSchema = function(value: any): buffer return Library.SerializeSchema(value, schema) end
	decodeSchema = function(data: buffer): any return Library.DeserializeSchema(data, schema) end
else
	local Types = Library.Types
	local itemSchema = Types.Struct({
		uid = Types.String,
		id = Types.String,
		amount = Types.Integer,
		nickname = Types.Optional(Types.String),
	})
	local schema = Library.Schema({coins = Types.Integer, items = Types.Array(itemSchema)})
	encodeSchema = function(value: any): buffer return schema:Serialize(value) end
	decodeSchema = function(data: buffer): any return schema:Deserialize(data) end
end
local schemaSetupUs = (os.clock() - schemaSetupStarted) * 1000000

local function assertDecoded(value: any, count: number)
	if type(value) ~= "table" or type(value.items) ~= "table" or #value.items ~= count then
		error("benchmark decoder returned an unexpected value")
	end
end

local function copyBuffer(data: buffer): buffer
	local copy = buffer.create(buffer.len(data))
	if buffer.len(data) > 0 then buffer.copy(copy, 0, data, 0, buffer.len(data)) end
	return copy
end

local function measure(label: string, encode: (any) -> buffer, decode: (buffer) -> any, count: number)
	local payload = makeInventory(count)
	local started = os.clock()
	local encoded = encode(payload)
	local coldEncode = (os.clock() - started) * 1000000
	started = os.clock()
	local decoded = decode(encoded)
	local coldDecode = (os.clock() - started) * 1000000
	assertDecoded(decoded, count)
	for _ = 1, 128 do
		encoded = encode(payload)
		decoded = decode(encoded)
	end
	local iterations = if count == 40 then 5000 else 2500
	started = os.clock()
	for _ = 1, iterations do encoded = encode(payload) end
	local warmEncode = (os.clock() - started) * 1000000 / iterations
	local sameBuffer = encoded
	started = os.clock()
	for _ = 1, iterations do decoded = decode(sameBuffer) end
	local warmDecodeSame = (os.clock() - started) * 1000000 / iterations
	started = os.clock()
	for _ = 1, iterations do decoded = decode(copyBuffer(sameBuffer)) end
	local warmDecodeFresh = (os.clock() - started) * 1000000 / iterations
	assertDecoded(decoded, count)

	local changing = makeInventory(count)
	if isPancakes then
		Library.Configure({sortedKeysCacheEnabled = false})
		setmetatable(changing, {})
	else
		Library.RegisterConverter("BenchmarkNoop", {
			Id = 999999,
			CanSerialize = function(_value: any): boolean return false end,
			Serialize = function(_writer: any, _value: any) end,
			Deserialize = function(_reader: any): any return nil end,
		})
	end
	local changingBuffers = table.create(iterations)
	started = os.clock()
	for index = 1, iterations do
		changing.coins = 1250 + index
		changingBuffers[index] = encode(changing)
	end
	local changingEncode = (os.clock() - started) * 1000000 / iterations
	started = os.clock()
	for index = 1, iterations do decoded = decode(changingBuffers[index]) end
	local changingDecode = (os.clock() - started) * 1000000 / iterations
	assertDecoded(decoded, count)
	print(string.format(
		"RESULT target=%s cache=hybrid case=%d kind=%s bytes=%d require_us=%.3f schema_setup_us=%.3f cold_encode_us=%.3f cold_decode_us=%.3f warm_encode_us=%.3f warm_decode_same_us=%.3f warm_decode_fresh_us=%.3f changing_encode_us=%.3f changing_decode_us=%.3f",
		target, count, label, buffer.len(encoded), requireUs, schemaSetupUs, coldEncode, coldDecode,
		warmEncode, warmDecodeSame, warmDecodeFresh, changingEncode, changingDecode
	))
end

if mode == "auto" then
	measure("auto", encodeAuto, decodeAuto, requestedCount)
else
	measure("schema", encodeSchema, decodeSchema, requestedCount)
end
