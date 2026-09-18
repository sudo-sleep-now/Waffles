--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local requireStarted = os.clock()
local Waffles = require(ReplicatedStorage.Waffles)
local requireUs = (os.clock() - requireStarted) * 1000000

-- Studio-side companion to the process-isolated Pancakes comparison. The
-- external runner records one fresh process per case; this script exposes the
-- same phases when a Roblox host is available.
local ITERATIONS = 5000
local WARMUP = 128

type Codec = {
	label: string,
	encode: (value: any) -> buffer,
	decode: (data: buffer) -> any,
}

local function makeInventory(count: number, coins: number?): any
	local items = table.create(count)
	for index = 1, count do
		items[index] = {
			uid = "item-" .. tostring(index),
			id = if index % 3 == 0 then "Honey" else "Wax",
			amount = (index % 7) + 1,
			nickname = if index % 5 == 0 then "Keep" else nil,
		}
	end
	return {coins = coins or 1250, items = items}
end

local schemaStarted = os.clock()
local itemSchema = Waffles.Types.Struct({
	uid = Waffles.Types.String,
	id = Waffles.Types.String,
	amount = Waffles.Types.Integer,
	nickname = Waffles.Types.Optional(Waffles.Types.String),
})

local inventorySchema = Waffles.Schema({
	coins = Waffles.Types.Integer,
	items = Waffles.Types.Array(itemSchema),
})
local schemaSetupUs = (os.clock() - schemaStarted) * 1000000

local codecs: {Codec} = {
	{
		label = "auto",
		encode = Waffles.SerializeAuto,
		decode = Waffles.DeserializeAuto,
	},
	{
		label = "schema",
		encode = function(value) return inventorySchema:Serialize(value) end,
		decode = function(data) return inventorySchema:Deserialize(data) end,
	},
}

local function copyBuffer(data: buffer): buffer
	local copy = buffer.create(buffer.len(data))
	if buffer.len(data) > 0 then buffer.copy(copy, 0, data, 0, buffer.len(data)) end
	return copy
end

local function assertDecoded(value: any, count: number)
	if type(value) ~= "table" or type(value.items) ~= "table" or #value.items ~= count then
		error("benchmark decoder returned an unexpected value")
	end
end

local function measure(codec: Codec, count: number): {[string]: any}
	local payload = makeInventory(count)
	local started = os.clock()
	local encoded = codec.encode(payload)
	local coldEncode = (os.clock() - started) * 1000000
	started = os.clock()
	local decoded = codec.decode(encoded)
	local coldDecode = (os.clock() - started) * 1000000
	assertDecoded(decoded, count)
	for _ = 1, WARMUP do
		encoded = codec.encode(payload)
		decoded = codec.decode(encoded)
	end
	local iterations = if count == 40 then ITERATIONS else math.floor(ITERATIONS / 2)
	started = os.clock()
	for _ = 1, iterations do encoded = codec.encode(payload) end
	local warmEncode = (os.clock() - started) * 1000000 / iterations
	local sameBuffer = encoded
	started = os.clock()
	for _ = 1, iterations do decoded = codec.decode(sameBuffer) end
	local warmDecodeSame = (os.clock() - started) * 1000000 / iterations
	started = os.clock()
	for _ = 1, iterations do decoded = codec.decode(copyBuffer(sameBuffer)) end
	local warmDecodeFresh = (os.clock() - started) * 1000000 / iterations
	assertDecoded(decoded, count)

	local changing = makeInventory(count)
	local changingBuffers = table.create(iterations)
	started = os.clock()
	for index = 1, iterations do
		changing.coins = 1250 + index
		changingBuffers[index] = codec.encode(changing)
	end
	local changingEncode = (os.clock() - started) * 1000000 / iterations
	started = os.clock()
	for index = 1, iterations do decoded = codec.decode(changingBuffers[index]) end
	local changingDecode = (os.clock() - started) * 1000000 / iterations
	assertDecoded(decoded, count)
	return {
		requireUs = requireUs,
		schemaSetupUs = schemaSetupUs,
		bytes = buffer.len(encoded),
		coldEncode = coldEncode,
		coldDecode = coldDecode,
		warmEncode = warmEncode,
		warmDecodeSame = warmDecodeSame,
		warmDecodeFresh = warmDecodeFresh,
		changingEncode = changingEncode,
		changingDecode = changingDecode,
	}
end

for _, count in {40, 120} do
	for _, codec in codecs do
		local result = measure(codec, count)
		print(string.format(
			"RESULT target=waffles kind=%s case=%d require_us=%.3f schema_setup_us=%.3f bytes=%d cold_encode_us=%.3f cold_decode_us=%.3f warm_encode_us=%.3f warm_decode_same_us=%.3f warm_decode_fresh_us=%.3f changing_encode_us=%.3f changing_decode_us=%.3f",
			codec.label,
			count,
			result.requireUs,
			result.schemaSetupUs,
			result.bytes,
			result.coldEncode,
			result.coldDecode,
			result.warmEncode,
			result.warmDecodeSame,
			result.warmDecodeFresh,
			result.changingEncode,
			result.changingDecode
		))
	end
end
