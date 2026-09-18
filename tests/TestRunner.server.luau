--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestService = game:GetService("TestService")
local Waffles = require(ReplicatedStorage.Waffles)

local passed = 0
local failed = 0

local function equivalent(a: any, b: any, seen: {[any]: boolean}?): boolean
	if typeof(a) ~= typeof(b) then return false end
	if typeof(a) == "number" and a ~= a and b ~= b then return true end
	if typeof(a) == "buffer" then return Waffles.Buffer.Equals(a, b) end
	if typeof(a) ~= "table" then return a == b end
	seen = seen or {}
	if seen[a] then return true end
	seen[a] = true
	for key, value in a do
		if not equivalent(value, b[key], seen) then return false end
	end
	for key in b do
		if a[key] == nil then return false end
	end
	return true
end

local function expect(condition: boolean, message: string?)
	if not condition then error(message or "expectation failed", 2) end
end

local function expectError(callback: () -> (), contains: string?)
	local ok, message = pcall(callback)
	expect(not ok, "expected an error")
	expect(string.find(tostring(message), "[Waffles]", 1, true) ~= nil, "error did not have Waffles prefix")
	if contains then expect(string.find(tostring(message), contains, 1, true) ~= nil, "error did not contain " .. contains) end
end

local function test(name: string, callback: () -> ())
	local ok, message = pcall(callback)
	if ok then
		passed += 1
		print("[Waffles test] PASS " .. name)
	else
		failed += 1
		TestService:Error("[Waffles test] FAIL " .. name .. ": " .. tostring(message))
	end
end

local function roundTrip(value: any): any
	local decoded = Waffles.DeserializeAuto(Waffles.SerializeAuto(value))
	expect(equivalent(value, decoded), "round trip mismatch for " .. typeof(value))
	return decoded
end

test("primitive round trips", function()
	roundTrip(nil)
	for _, value in {false, true, 0, 1, -1, 63, 64, 127, 128, -128, 2 ^ 31, 4503599627370495, -4503599627370495, math.pi, math.huge, -math.huge, 0 / 0, "", "hello", "héllø 🌍"} do
		roundTrip(value)
	end
end)

test("buffers and buffer helpers", function()
	local a = buffer.fromstring("abc")
	local b = buffer.fromstring("def")
	roundTrip(a)
	expect(buffer.tostring(Waffles.Buffer.Concat(a, b)) == "abcdef")
	expect(buffer.tostring(Waffles.Buffer.Slice(Waffles.Buffer.Concat(a, b), 1, 5)) == "bcde")
	local hex = Waffles.Buffer.ToHex(a)
	expect(hex == "616263")
	expect(Waffles.Buffer.Equals(a, Waffles.Buffer.FromHex(hex)))
	expectError(function() Waffles.Buffer.FromHex("xyz") end, "Hex")
end)

test("large and Unicode strings", function()
	roundTrip(string.rep("0123456789abcdef", 65536))
	roundTrip(string.rep("🧇", 4096))
end)

test("arrays dictionaries and nested values", function()
	roundTrip({})
	roundTrip({1, 2, 3, {name = "nested", enabled = true}})
	roundTrip({[false] = "no", [true] = "yes", [10] = "ten", alpha = 1, nested = {x = 2}})
end)

test("repeated strings layouts and RLE", function()
	local repeated = string.rep("waffle", 20)
	local compressed = buffer.create(1024)
	buffer.fill(compressed, 0, 7, 1024)
	roundTrip({{name = repeated, score = 1}, {name = repeated, score = 2}, raw = compressed})
end)

test("compact records preserve negative zero", function()
	local negativeZero = -1 / math.huge
	local decoded = Waffles.DeserializeAuto(Waffles.SerializeAuto({
		{value = negativeZero},
		{value = negativeZero},
	}))
	expect(1 / decoded[1].value == -math.huge and 1 / decoded[2].value == -math.huge, "compact record lost negative zero")
end)

test("compact string limits apply to cached plans", function()
	local value = {
		{label = "long"},
		{label = "long"},
	}
	Waffles.SerializeAuto(value)
	Waffles.Configure({maxStringBytes = 3})
	expectError(function() Waffles.SerializeAuto(value) end, "length")
	Waffles.Configure({maxStringBytes = 8 * 1024 * 1024})
end)

test("compact record allocation limits", function()
	local value = {
		{first = 1, second = 2},
		{first = 3, second = 4},
	}
	local encoded = Waffles.SerializeAuto(value)
	Waffles.Configure({maxRecordCells = 3})
	expectError(function() Waffles.DeserializeAuto(encoded) end, "cells")
	Waffles.Configure({maxRecordCells = 8000000})
end)

test("compact record field limits", function()
	local value = {
		{first = 1, second = 2},
		{first = 3, second = 4},
	}
	local encoded = Waffles.SerializeAuto(value)
	Waffles.Configure({maxRecordFields = 1})
	expectError(function() Waffles.DeserializeAuto(encoded) end, "field count")
	Waffles.Configure({maxRecordFields = 1024})
end)

test("Roblox datatypes", function()
	local values = {
		Vector2.new(1.25, -2.5),
		Vector3.new(1, 2, 3),
		Vector2int16.new(-12, 34),
		Vector3int16.new(-1, 2, 32767),
		CFrame.new(1, 2, 3) * CFrame.Angles(0.2, 0.4, 0.6),
		Color3.fromRGB(12, 34, 56),
		BrickColor.new("Bright red"),
		UDim.new(0.5, -12),
		UDim2.new(0.25, 4, 0.75, -8),
		Rect.new(-1, -2, 3, 4),
		Ray.new(Vector3.new(1, 2, 3), Vector3.new(4, 5, 6)),
		NumberRange.new(-2, 5),
		NumberSequenceKeypoint.new(0.5, 2, 0.25),
		NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 2)}),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(10, 20, 30)),
		ColorSequence.new(Color3.new(0, 0, 0), Color3.new(1, 1, 1)),
		DateTime.fromUnixTimestampMillis(1700000000123),
		Font.new("rbxasset://fonts/families/Arial.json", Enum.FontWeight.Bold, Enum.FontStyle.Italic),
		Enum.Material.Slate,
	}
	for _, value in values do roundTrip(value) end
end)

test("explicit schemas", function()
	local schema = Waffles.Schema({
		alive = Waffles.Types.Boolean,
		inventory = Waffles.Types.Array(Waffles.Types.Struct({
			id = Waffles.Types.Integer,
			label = Waffles.Types.String,
		})),
		metadata = Waffles.Types.Map(Waffles.Types.String, Waffles.Types.Number),
		position = Waffles.Types.Vector3,
		nickname = Waffles.Types.Optional(Waffles.Types.String),
		role = Waffles.Types.Enum("admin", "member", "guest"),
		tuple = Waffles.Types.Tuple(Waffles.Types.Integer, Waffles.Types.String),
	})
	local value = {
		alive = true,
		inventory = {{id = 1, label = "Syrup"}, {id = 2, label = "Butter"}},
		metadata = {speed = 2.5},
		position = Vector3.new(1, 2, 3),
		nickname = nil,
		role = "member",
		tuple = {42, "answer"},
	}
	local decoded = schema:Deserialize(schema:Serialize(value))
	expect(equivalent(value, decoded))
	local otherSchema = Waffles.Schema({alive = Waffles.Types.Boolean})
	expectError(function() otherSchema:Deserialize(schema:Serialize(value)) end, "Schema does not match")
	expectError(function()
		schema:Serialize({alive = true, inventory = {{id = "bad", label = "x"}}})
	end, "inventory[1].id")
end)

test("struct definitions snapshot caller fields", function()
	local fields = {value = Waffles.Types.Integer}
	local definition = Waffles.Types.Struct(fields)
	fields.value = Waffles.Types.String
	local schema = Waffles.Schema(definition)
	local decoded = schema:Deserialize(schema:Serialize({value = 7}))
	expect(decoded.value == 7, "struct changed after caller mutation")
end)

test("schema compact record limits and truncation", function()
	local schema = Waffles.Schema(Waffles.Types.Array(Waffles.Types.Struct({
		id = Waffles.Types.Integer,
		label = Waffles.Types.String,
	})))
	local value = {{id = 1, label = "a"}, {id = 2, label = "b"}}
	local encoded = schema:Serialize(value)
	Waffles.Configure({maxRecordCells = 3})
	expectError(function() schema:Deserialize(encoded) end, "cells")
	Waffles.Configure({maxRecordCells = 8000000})
	Waffles.Configure({maxRecordFields = 1})
	expectError(function() schema:Deserialize(encoded) end, "field count")
	Waffles.Configure({maxRecordFields = 1024})
	for length = 0, buffer.len(encoded) - 1 do
		expectError(function() schema:Deserialize(Waffles.Buffer.Slice(encoded, 0, length)) end)
	end
end)

test("legacy A5 schema record arrays remain readable", function()
	local schema = Waffles.Schema(Waffles.Types.Array(Waffles.Types.Struct({
		id = Waffles.Types.Integer,
		payload = Waffles.Types.Buffer,
		note = Waffles.Types.Optional(Waffles.Types.String),
	})))
	local value = {
		{id = 1, payload = buffer.fromstring("a")},
		{id = 2, payload = buffer.fromstring("b"), note = "kept"},
	}
	expect(equivalent(value, schema:Deserialize(schema:Serialize(value))))
end)

test("A6 schema strings use compact framing", function()
	local schema = Waffles.Schema(Waffles.Types.Array(Waffles.Types.Struct({
		label = Waffles.Types.String,
	})))
	local repeated = string.rep("x", 300)
	local value = {{label = repeated}, {label = repeated}}
	expect(equivalent(value, schema:Deserialize(schema:Serialize(value))))
end)

test("smart schemas", function()
	local value = {userId = 1234, username = "Player", active = true, scores = {1, 2, 3}}
	local schema = Waffles.SmartSchema(value)
	expect(equivalent(value, schema:Deserialize(schema:Serialize(value))))
end)

test("decode cache admits on the second hit", function()
	local value = {items = {{id = "a"}, {id = "b"}}}
	local schema = Waffles.Schema({items = Waffles.Types.Array(Waffles.Types.Struct({id = Waffles.Types.String}))})
	local autoData = Waffles.SerializeAuto(value)
	local schemaData = schema:Serialize(value)
	local firstAuto = Waffles.DeserializeAuto(autoData)
	local firstSchema = schema:Deserialize(schemaData)
	firstAuto.items[1].id = "direct-mutation"
	firstSchema.items[1].id = "direct-mutation"
	local secondAuto = Waffles.DeserializeAuto(autoData)
	local secondSchema = schema:Deserialize(schemaData)
	secondAuto.items[1].id = "promotion-mutation"
	secondSchema.items[1].id = "promotion-mutation"
	local thirdAuto = Waffles.DeserializeAuto(autoData)
	local thirdSchema = schema:Deserialize(schemaData)
	expect(thirdAuto.items[1].id == "a" and thirdSchema.items[1].id == "a", "promoted snapshots must clone results")
	buffer.writeu8(autoData, 0, 0)
	expectError(function() Waffles.DeserializeAuto(autoData) end, "header")
end)

test("custom converters", function()
	local marker = {}
	Waffles.RegisterConverter("TestPoint", {
		Id = 424242,
		CanSerialize = function(value)
			return type(value) == "table" and value._marker == marker
		end,
		Serialize = function(writer, value)
			writer:WriteVarInt(value.x)
			writer:WriteVarInt(value.y)
		end,
		Deserialize = function(reader)
			return {_marker = marker, x = reader:ReadVarInt("x"), y = reader:ReadVarInt("y")}
		end,
	})
	local encoded = Waffles.SerializeAuto({_marker = marker, x = -7, y = 9})
	local decoded = Waffles.DeserializeAuto(encoded)
	decoded.x = 99
	local decodedAgain = Waffles.DeserializeAuto(encoded)
	expect(decodedAgain.x == -7 and decodedAgain.y == 9, "converter payload should bypass decode snapshots")
end)

test("batch including nil slots", function()
	local values = table.pack(1, nil, "three", {four = true})
	local decoded = Waffles.DeserializeBatch(Waffles.SerializeBatch(values))
	expect((decoded :: any).n == 4 and decoded[1] == 1 and decoded[2] == nil and decoded[3] == "three" and decoded[4].four)
end)

test("deterministic map ordering", function()
	local a = {}; a.z = 1; a.a = 2; a.m = 3
	local b = {}; b.m = 3; b.z = 1; b.a = 2
	expect(Waffles.Buffer.Equals(Waffles.SerializeAuto(a), Waffles.SerializeAuto(b)))
end)

test("warm snapshot caches stay isolated", function()
	expect(Waffles.GetConfiguration().decodeSnapshotCacheEnabled == true, "decode snapshot cache should default to enabled")
	local value = {coins = 1250, items = {{uid = "item-a", id = "Honey", amount = 12}, {uid = "item-b", id = "Wax", amount = 4, nickname = "Keep"}}}
	local schema = Waffles.Schema({
		coins = Waffles.Types.Integer,
		items = Waffles.Types.Array(Waffles.Types.Struct({
			uid = Waffles.Types.String,
			id = Waffles.Types.String,
			amount = Waffles.Types.Integer,
			nickname = Waffles.Types.Optional(Waffles.Types.String),
		})),
	})
	local autoData = Waffles.SerializeAuto(value)
	local schemaData = schema:Serialize(value)
	local autoDecoded = Waffles.DeserializeAuto(autoData)
	local schemaDecoded = schema:Deserialize(schemaData)
	autoDecoded.items[1].id = "changed"
	schemaDecoded.items[1].id = "changed"
	-- The first two decodes are direct. Promotion happens only after the
	-- second unchanged identity, so mutating either direct result must not
	-- affect the third (clone-isolated) decode.
	local autoPromoted = Waffles.DeserializeAuto(autoData)
	local schemaPromoted = schema:Deserialize(schemaData)
	autoPromoted.items[1].id = "changed-again"
	schemaPromoted.items[1].id = "changed-again"
	expect(Waffles.DeserializeAuto(autoData).items[1].id == "Honey")
	expect(schema:Deserialize(schemaData).items[1].id == "Honey")
	buffer.writeu8(autoData, 0, 0)
	expectError(function() Waffles.DeserializeAuto(autoData) end)
	expect(not Waffles.Buffer.Equals(Waffles.SerializeAuto(value), autoData))
end)

test("configuration and common-key fingerprint", function()
	Waffles.Configure({commonKeys = {"name", "position"}, stringCacheMinLength = 4})
	local encoded = Waffles.SerializeAuto({name = "Player", position = Vector3.new(1, 2, 3)})
	roundTrip({name = "Player", position = Vector3.new(1, 2, 3)})
	Waffles.Configure({commonKeys = {}})
	expectError(function() Waffles.DeserializeAuto(encoded) end, "configuration does not match")
	Waffles.Configure({stringCacheMinLength = 16})
	expectError(function() Waffles.Configure({doesNotExist = true} :: any) end, "Unknown")
end)

test("truncation rejected at every byte offset", function()
	local encoded = Waffles.SerializeAuto({name = string.rep("x", 100), items = {1, 2, 3}, active = true})
	for length = 0, buffer.len(encoded) - 1 do
		local truncated = Waffles.Buffer.Slice(encoded, 0, length)
		expectError(function() Waffles.DeserializeAuto(truncated) end)
	end
end)

test("bad tags malformed varints and absurd counts", function()
	local badTag = Waffles.SerializeAuto(true)
	buffer.writeu8(badTag, 8, 255)
	expectError(function() Waffles.DeserializeAuto(badTag) end, "type tag")

	local header = Waffles.Buffer.Slice(Waffles.SerializeAuto(true), 0, 8)
	local malformed = buffer.create(10)
	buffer.fill(malformed, 0, 0x80, 10)
	expectError(function() Waffles.DeserializeAuto(Waffles.Buffer.Concat(header, Waffles.Buffer.FromHex("03"), malformed)) end, "variable-length")

	local excessive = Waffles.Buffer.Concat(header, Waffles.Buffer.FromHex("0affff7f"))
	expectError(function() Waffles.DeserializeAuto(excessive) end)

	local badStringReference = Waffles.Buffer.Concat(header, Waffles.Buffer.FromHex("0701"))
	expectError(function() Waffles.DeserializeAuto(badStringReference) end, "string reference")
	local badLayoutReference = Waffles.Buffer.Concat(header, Waffles.Buffer.FromHex("0d01"))
	expectError(function() Waffles.DeserializeAuto(badLayoutReference) end, "layout reference")
	local badRle = Waffles.Buffer.Concat(header, Waffles.Buffer.FromHex("090a010bff"))
	expectError(function() Waffles.DeserializeAuto(badRle) end, "RLE")
end)

test("recursion limits and cycles", function()
	local cyclic = {}
	cyclic.self = cyclic
	expectError(function() Waffles.SerializeAuto(cyclic) end, "Cyclic")

	local root = {}
	local cursor = root
	for _ = 1, 70 do
		local nextValue = {}
		cursor[1] = nextValue
		cursor = nextValue
	end
	expectError(function() Waffles.SerializeAuto(root) end, "depth")
end)

local function randomValue(random: Random, depth: number): any
	local choice = random:NextInteger(1, if depth > 3 then 5 else 8)
	if choice == 1 then return nil end
	if choice == 2 then return random:NextInteger(-100000, 100000) end
	if choice == 3 then return random:NextNumber(-1000, 1000) end
	if choice == 4 then return random:NextInteger(0, 1) == 1 end
	if choice == 5 then return string.rep(string.char(random:NextInteger(32, 126)), random:NextInteger(0, 24)) end
	if choice == 6 then
		local result = {}
		for index = 1, random:NextInteger(0, 8) do result[index] = randomValue(random, depth + 1) end
		return result
	end
	if choice == 7 then return {a = randomValue(random, depth + 1), b = randomValue(random, depth + 1)} end
	return Vector3.new(random:NextNumber(), random:NextNumber(), random:NextNumber())
end

test("randomized automatic round trips", function()
	local random = Random.new(0x57414646)
	for _ = 1, 500 do roundTrip(randomValue(random, 0)) end
end)

print(string.format("[Waffles test] %d passed, %d failed", passed, failed))
if failed > 0 then error(string.format("[Waffles] Test run failed: %d failures", failed)) end
