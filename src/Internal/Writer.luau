--!strict

local MAX_SAFE_INTEGER = 9007199254740991
local MIN_CAPACITY = 64

export type Writer = {
	_data: buffer,
	_cursor: number,
	_bucket: number,
	_maxCapacity: number,
	WriteU8: (self: Writer, value: number) -> (),
	WriteU16: (self: Writer, value: number) -> (),
	WriteU32: (self: Writer, value: number) -> (),
	WriteI16: (self: Writer, value: number) -> (),
	WriteI32: (self: Writer, value: number) -> (),
	WriteF32: (self: Writer, value: number) -> (),
	WriteF64: (self: Writer, value: number) -> (),
	WriteVarUInt: (self: Writer, value: number) -> (),
	WriteVarInt: (self: Writer, value: number) -> (),
	WriteString: (self: Writer, value: string) -> (),
	WriteRawString: (self: Writer, value: string) -> (),
	WriteBuffer: (self: Writer, value: buffer) -> (),
	WriteRawBuffer: (self: Writer, value: buffer) -> (),
	Position: (self: Writer) -> number,
	Finish: (self: Writer) -> buffer,
}

local WriterMethods = {}
WriterMethods.__index = WriterMethods

local function nextPowerOfTwo(value: number): number
	local capacity = MIN_CAPACITY
	while capacity < value do
		capacity *= 2
	end
	return capacity
end

local function ensure(self: Writer, byteCount: number)
	local required = self._cursor + byteCount
	if required > self._maxCapacity then
		error(string.format("[Waffles] Encoded payload exceeds limit %d", self._maxCapacity), 3)
	end
	local current = buffer.len(self._data)
	if required <= current then
		return
	end
	local capacity = nextPowerOfTwo(required)
	local grown = buffer.create(capacity)
	buffer.copy(grown, 0, self._data, 0, self._cursor)
	self._data = grown
	self._bucket = capacity
end

function WriterMethods.WriteU8(self: Writer, value: number)
	ensure(self, 1)
	buffer.writeu8(self._data, self._cursor, value)
	self._cursor += 1
end

function WriterMethods.WriteU16(self: Writer, value: number)
	ensure(self, 2)
	buffer.writeu16(self._data, self._cursor, value)
	self._cursor += 2
end

function WriterMethods.WriteU32(self: Writer, value: number)
	ensure(self, 4)
	buffer.writeu32(self._data, self._cursor, value)
	self._cursor += 4
end

function WriterMethods.WriteI16(self: Writer, value: number)
	ensure(self, 2)
	buffer.writei16(self._data, self._cursor, value)
	self._cursor += 2
end

function WriterMethods.WriteI32(self: Writer, value: number)
	ensure(self, 4)
	buffer.writei32(self._data, self._cursor, value)
	self._cursor += 4
end

function WriterMethods.WriteF32(self: Writer, value: number)
	ensure(self, 4)
	buffer.writef32(self._data, self._cursor, value)
	self._cursor += 4
end

function WriterMethods.WriteF64(self: Writer, value: number)
	ensure(self, 8)
	buffer.writef64(self._data, self._cursor, value)
	self._cursor += 8
end

function WriterMethods.WriteVarUInt(self: Writer, value: number)
	if value < 0 or value > MAX_SAFE_INTEGER or value % 1 ~= 0 then
		error("[Waffles] VarUInt value must be a non-negative safe integer", 2)
	end
	repeat
		local byte = value % 128
		value = math.floor(value / 128)
		if value ~= 0 then
			byte += 128
		end
		self:WriteU8(byte)
	until value == 0
end

function WriterMethods.WriteVarInt(self: Writer, value: number)
	if value % 1 ~= 0 or math.abs(value) > 4503599627370495 then
		error("[Waffles] VarInt value is outside the supported safe range", 2)
	end
	local zigzag = if value >= 0 then value * 2 else -value * 2 - 1
	self:WriteVarUInt(zigzag)
end

function WriterMethods.WriteRawString(self: Writer, value: string)
	local length = #value
	ensure(self, length)
	buffer.writestring(self._data, self._cursor, value)
	self._cursor += length
end

function WriterMethods.WriteString(self: Writer, value: string)
	self:WriteVarUInt(#value)
	self:WriteRawString(value)
end

function WriterMethods.WriteRawBuffer(self: Writer, value: buffer)
	local length = buffer.len(value)
	ensure(self, length)
	buffer.copy(self._data, self._cursor, value, 0, length)
	self._cursor += length
end

function WriterMethods.WriteBuffer(self: Writer, value: buffer)
	self:WriteVarUInt(buffer.len(value))
	self:WriteRawBuffer(value)
end

function WriterMethods.Position(self: Writer): number
	return self._cursor
end

function WriterMethods.Finish(self: Writer): buffer
	local result = buffer.create(self._cursor)
	if self._cursor > 0 then
		buffer.copy(result, 0, self._data, 0, self._cursor)
	end
	return result
end

local pools: {[number]: {Writer}} = {}

local WriterModule = {}

function WriterModule.acquire(initialSize: number, poolingEnabled: boolean, maxCapacity: number): Writer
	local bucket = nextPowerOfTwo(math.max(initialSize, MIN_CAPACITY))
	if poolingEnabled then
		local pool = pools[bucket]
		if pool and #pool > 0 then
			local writer = table.remove(pool) :: Writer
			writer._cursor = 0
			writer._maxCapacity = maxCapacity
			return writer
		end
	end
	return setmetatable({
		_data = buffer.create(bucket),
		_cursor = 0,
		_bucket = bucket,
		_maxCapacity = maxCapacity,
	}, WriterMethods) :: any
end

function WriterModule.release(writer: Writer, poolingEnabled: boolean, maxPerBucket: number, maxPooledSize: number)
	if not poolingEnabled or writer._bucket > maxPooledSize then
		return
	end
	if writer._cursor > 0 then
		buffer.fill(writer._data, 0, 0, writer._cursor)
	end
	writer._cursor = 0
	local bucket = writer._bucket
	local pool = pools[bucket]
	if not pool then
		pool = {}
		pools[bucket] = pool
	end
	if #pool < maxPerBucket then
		table.insert(pool, writer)
	end
end

return WriterModule
