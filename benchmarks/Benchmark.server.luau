--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Waffles = require(ReplicatedStorage.Waffles)

local ITERATIONS = 10000

local function benchmark(name: string, iterations: number, callback: () -> buffer?)
	local beforeKb = collectgarbage("count")
	local started = os.clock()
	local last: buffer? = nil
	for _ = 1, iterations do last = callback() end
	local elapsed = os.clock() - started
	local afterKb = collectgarbage("count")
	local size = if last then buffer.len(last) else 0
	print(string.format("[Waffles benchmark] %-28s %8.2f ms  %8.0f ops/s  %7d bytes  %+8.1f KiB", name, elapsed * 1000, iterations / elapsed, size, afterKb - beforeKb))
end

local player = {
	userId = 123456789,
	username = "WafflePlayer",
	position = Vector3.new(128.5, 10, -44.25),
	alive = true,
	inventory = {
		{id = 1001, name = "Maple Syrup", quantity = 3},
		{id = 1002, name = "Butter", quantity = 1},
	},
}

local schema = Waffles.Schema({
	userId = Waffles.Types.Integer,
	username = Waffles.Types.String,
	position = Waffles.Types.Vector3,
	alive = Waffles.Types.Boolean,
	inventory = Waffles.Types.Array(Waffles.Types.Struct({
		id = Waffles.Types.Integer,
		name = Waffles.Types.String,
		quantity = Waffles.Types.Integer,
	})),
})

local automatic = Waffles.SerializeAuto(player)
local schemaData = schema:Serialize(player)

benchmark("automatic encode", ITERATIONS, function() return Waffles.SerializeAuto(player) end)
benchmark("automatic decode", ITERATIONS, function() Waffles.DeserializeAuto(automatic); return automatic end)
benchmark("schema encode", ITERATIONS, function() return schema:Serialize(player) end)
benchmark("schema decode", ITERATIONS, function() schema:Deserialize(schemaData); return schemaData end)

local repeated = table.create(200)
for index = 1, 200 do repeated[index] = {id = index, name = "Repeated layout", active = index % 2 == 0} end
local repeatedData = Waffles.SerializeAuto(repeated)
benchmark("repeated structures encode", 1000, function() return Waffles.SerializeAuto(repeated) end)
benchmark("repeated structures decode", 1000, function() Waffles.DeserializeAuto(repeatedData); return repeatedData end)

local largeArray = table.create(10000)
for index = 1, 10000 do largeArray[index] = index end
local largeArrayData = Waffles.SerializeAuto(largeArray)
benchmark("large array encode", 100, function() return Waffles.SerializeAuto(largeArray) end)
benchmark("large array decode", 100, function() Waffles.DeserializeAuto(largeArrayData); return largeArrayData end)

local stringHeavy = table.create(1000)
for index = 1, 1000 do stringHeavy[index] = "the same relatively long Waffles string" end
local stringData = Waffles.SerializeAuto(stringHeavy)
benchmark("string-heavy encode", 500, function() return Waffles.SerializeAuto(stringHeavy) end)
benchmark("string-heavy decode", 500, function() Waffles.DeserializeAuto(stringData); return stringData end)

local deep: any = {value = true}
for _ = 1, 48 do deep = {next = deep} end
local deepData = Waffles.SerializeAuto(deep)
benchmark("deep payload encode", 2000, function() return Waffles.SerializeAuto(deep) end)
benchmark("deep payload decode", 2000, function() Waffles.DeserializeAuto(deepData); return deepData end)
