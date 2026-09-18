--!strict

local MAX_SAFE_INTEGER = 9007199254740991
local MIN_CAPACITY = 64
local mathAbs = math.abs
local mathFloor = math.floor
local mathMax = math.max
local mathMin = math.min
local bufferCreate = buffer.create
local bufferCopy = buffer.copy
local bufferLen = buffer.len
local bufferWriteU8 = buffer.writeu8
local bufferWriteU16 = buffer.writeu16
local bufferWriteU32 = buffer.writeu32
local bufferWriteI16 = buffer.writei16
local bufferWriteI32 = buffer.writei32
local bufferWriteF32 = buffer.writef32
local bufferWriteF64 = buffer.writef64
local bufferWriteString = buffer.writestring

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
	_fast: any,
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
	-- _bucket is kept in sync with _data's capacity.  Calling buffer.len for
	-- every scalar write is surprisingly expensive on large records.
	if required <= self._bucket then
		return
	end
	local current = bufferLen(self._data)
	if required <= current then
		self._bucket = mathMin(current, self._maxCapacity)
		return
	end
	local capacity = mathMin(nextPowerOfTwo(required), self._maxCapacity)
	local grown = bufferCreate(capacity)
	bufferCopy(grown, 0, self._data, 0, self._cursor)
	self._data = grown
	self._bucket = capacity
end

-- Compact record columns are deliberately written through a small closure
-- facade.  The regular Writer methods are part of the public converter API
-- and therefore keep their defensive table-backed state; the facade snapshots
-- that state once and keeps the cursor/buffer in locals for the duration of a
-- homogeneous column write.  This removes several hash lookups per scalar
-- without changing the wire format or public methods.
local function makeFastWriter(writer: Writer): any
	local data: buffer = writer._data
	local cursor = 0
	local bucket = 0
	local maxCapacity = 0

	local function begin()
		data = writer._data
		cursor = writer._cursor
		bucket = writer._bucket
		maxCapacity = writer._maxCapacity
	end

	local function grow(byteCount: number)
		local required = cursor + byteCount
		if required > maxCapacity then
			error(string.format("[Waffles] Encoded payload exceeds limit %d", maxCapacity), 3)
		end
		if required <= bucket then return end
		local current = bufferLen(data)
		if required <= current then
			bucket = mathMin(current, maxCapacity)
			return
		end
		local capacity = mathMin(nextPowerOfTwo(required), maxCapacity)
		local grown = bufferCreate(capacity)
		bufferCopy(grown, 0, data, 0, cursor)
		data = grown
		bucket = capacity
	end

	local function writeU8Value(value: number)
		if cursor + 1 > bucket then grow(1) end
		bufferWriteU8(data, cursor, value)
		cursor += 1
	end
	local function writeU8(_self: any, value: number) writeU8Value(value) end

	local function writeF32(_self: any, value: number)
		if cursor + 4 > bucket then grow(4) end
		bufferWriteF32(data, cursor, value)
		cursor += 4
	end

	local function writeF64(_self: any, value: number)
		if cursor + 8 > bucket then grow(8) end
		bufferWriteF64(data, cursor, value)
		cursor += 8
	end

	local function writeVarUInt(_self: any, value: number)
		if value < 0 or value > MAX_SAFE_INTEGER or value % 1 ~= 0 then
			error("[Waffles] VarUInt value must be a non-negative safe integer", 2)
		end
		if value < 128 then
			writeU8Value(value)
			return
		end
		repeat
			local byte = value % 128
			value = mathFloor(value / 128)
			if value ~= 0 then byte += 128 end
			writeU8Value(byte)
		until value == 0
	end

	local function writeVarUIntUnchecked(_self: any, value: number)
		if value < 128 then
			writeU8Value(value)
			return
		end
		repeat
			local byte = value % 128
			value = mathFloor(value / 128)
			if value ~= 0 then byte += 128 end
			writeU8Value(byte)
		until value == 0
	end

	local function writeVarInt(_self: any, value: number)
		if value % 1 ~= 0 or mathAbs(value) > 4503599627370495 then
			error("[Waffles] VarInt value is outside the supported safe range", 2)
		end
		local zigzag = if value >= 0 then value * 2 else -value * 2 - 1
		writeVarUIntUnchecked(nil, zigzag)
	end

	local function writeString(_self: any, value: string)
		local length = #value
		writeVarUIntUnchecked(nil, length)
		if length > 0 then
			if cursor + length > bucket then grow(length) end
			bufferWriteString(data, cursor, value)
			cursor += length
		end
	end

	local function writeRawString(_self: any, value: string)
		local length = #value
		if cursor + length > bucket then grow(length) end
		if length > 0 then bufferWriteString(data, cursor, value) end
		cursor += length
	end

	local function finish()
		writer._data = data
		writer._cursor = cursor
		writer._bucket = bucket
	end

	return {
		Begin = begin,
		Finish = finish,
		WriteU8 = writeU8,
		WriteF32 = writeF32,
		WriteF64 = writeF64,
		WriteVarUInt = writeVarUInt,
		WriteVarUIntUnchecked = writeVarUIntUnchecked,
		WriteVarInt = writeVarInt,
		WriteString = writeString,
		WriteRawString = writeRawString,
	}
end

function WriterMethods.WriteU8(self: Writer, value: number)
	if self._cursor + 1 > self._bucket then ensure(self, 1) end
	bufferWriteU8(self._data, self._cursor, value)
	self._cursor += 1
end

function WriterMethods.WriteU16(self: Writer, value: number)
	if self._cursor + 2 > self._bucket then ensure(self, 2) end
	bufferWriteU16(self._data, self._cursor, value)
	self._cursor += 2
end

function WriterMethods.WriteU32(self: Writer, value: number)
	if self._cursor + 4 > self._bucket then ensure(self, 4) end
	bufferWriteU32(self._data, self._cursor, value)
	self._cursor += 4
end

function WriterMethods.WriteI16(self: Writer, value: number)
	if self._cursor + 2 > self._bucket then ensure(self, 2) end
	bufferWriteI16(self._data, self._cursor, value)
	self._cursor += 2
end

function WriterMethods.WriteI32(self: Writer, value: number)
	if self._cursor + 4 > self._bucket then ensure(self, 4) end
	bufferWriteI32(self._data, self._cursor, value)
	self._cursor += 4
end

function WriterMethods.WriteF32(self: Writer, value: number)
	if self._cursor + 4 > self._bucket then ensure(self, 4) end
	bufferWriteF32(self._data, self._cursor, value)
	self._cursor += 4
end

function WriterMethods.WriteF64(self: Writer, value: number)
	if self._cursor + 8 > self._bucket then ensure(self, 8) end
	bufferWriteF64(self._data, self._cursor, value)
	self._cursor += 8
end

function WriterMethods.WriteVarUInt(self: Writer, value: number)
	if value < 0 or value > MAX_SAFE_INTEGER or value % 1 ~= 0 then
		error("[Waffles] VarUInt value must be a non-negative safe integer", 2)
	end
	if value < 128 then
		if self._cursor + 1 > self._bucket then ensure(self, 1) end
		bufferWriteU8(self._data, self._cursor, value)
		self._cursor += 1
		return
	end
	repeat
		local byte = value % 128
		value = mathFloor(value / 128)
		if value ~= 0 then
			byte += 128
		end
		if self._cursor + 1 > self._bucket then ensure(self, 1) end
		bufferWriteU8(self._data, self._cursor, byte)
		self._cursor += 1
	until value == 0
end

function WriterMethods.WriteVarInt(self: Writer, value: number)
	if value % 1 ~= 0 or mathAbs(value) > 4503599627370495 then
		error("[Waffles] VarInt value is outside the supported safe range", 2)
	end
	local zigzag = if value >= 0 then value * 2 else -value * 2 - 1
	WriterMethods.WriteVarUInt(self, zigzag)
end

function WriterMethods.WriteRawString(self: Writer, value: string)
	local length = #value
	if self._cursor + length > self._bucket then ensure(self, length) end
	bufferWriteString(self._data, self._cursor, value)
	self._cursor += length
end

function WriterMethods.WriteString(self: Writer, value: string)
	local length = #value
	WriterMethods.WriteVarUInt(self, length)
	if length > 0 then
		if self._cursor + length > self._bucket then ensure(self, length) end
		bufferWriteString(self._data, self._cursor, value)
		self._cursor += length
	end
end

function WriterMethods.WriteRawBuffer(self: Writer, value: buffer)
	local length = bufferLen(value)
	if self._cursor + length > self._bucket then ensure(self, length) end
	bufferCopy(self._data, self._cursor, value, 0, length)
	self._cursor += length
end

function WriterMethods.WriteBuffer(self: Writer, value: buffer)
	local length = bufferLen(value)
	WriterMethods.WriteVarUInt(self, length)
	if length > 0 then
		if self._cursor + length > self._bucket then ensure(self, length) end
		bufferCopy(self._data, self._cursor, value, 0, length)
		self._cursor += length
	end
end

function WriterMethods.Position(self: Writer): number
	return self._cursor
end

function WriterMethods.Finish(self: Writer): buffer
	local result = bufferCreate(self._cursor)
	if self._cursor > 0 then
		bufferCopy(result, 0, self._data, 0, self._cursor)
	end
	return result
end

local pools: {[number]: {Writer}} = {}

local WriterModule = {}

function WriterModule.acquire(initialSize: number, poolingEnabled: boolean, maxCapacity: number): Writer
	local bucket = mathMin(nextPowerOfTwo(mathMax(initialSize, MIN_CAPACITY)), maxCapacity)
	if poolingEnabled then
		local pool = pools[bucket]
		if pool and #pool > 0 then
			local poolIndex = #pool
			local writer = pool[poolIndex] :: Writer
			pool[poolIndex] = nil
			writer._cursor = 0
			writer._maxCapacity = maxCapacity
			writer._bucket = mathMin(writer._bucket, maxCapacity)
			return writer
		end
	end
	local writer = setmetatable({
		_data = bufferCreate(bucket),
		_cursor = 0,
		_bucket = bucket,
		_maxCapacity = maxCapacity,
	}, WriterMethods) :: any
	writer._fast = makeFastWriter(writer)
	return writer
end

function WriterModule.release(writer: Writer, poolingEnabled: boolean, maxPerBucket: number, maxPooledSize: number)
	if not poolingEnabled or writer._bucket > maxPooledSize then
		return
	end
	-- The cursor makes all previous bytes unreachable to the next payload.  Do
	-- not clear the buffer here: zeroing a multi-kilobyte writer on every call
	-- dominated the benchmark while providing no correctness or security
	-- benefit (the finished buffer is a separate copy).
	writer._cursor = 0
	local bucket = writer._bucket
	local pool = pools[bucket]
	if not pool then
		pool = {}
		pools[bucket] = pool
	end
	if #pool < maxPerBucket then
		pool[#pool + 1] = writer
	end
end

return WriterModule
