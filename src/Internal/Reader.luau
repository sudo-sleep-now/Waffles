--!strict

local MAX_SAFE_INTEGER = 9007199254740991
local mathFloor = math.floor
local bufferCreate = buffer.create
local bufferCopy = buffer.copy
local bufferLen = buffer.len
local bufferReadU8 = buffer.readu8
local bufferReadU16 = buffer.readu16
local bufferReadU32 = buffer.readu32
local bufferReadI16 = buffer.readi16
local bufferReadI32 = buffer.readi32
local bufferReadF32 = buffer.readf32
local bufferReadF64 = buffer.readf64
local bufferReadString = buffer.readstring

export type Reader = {
	_data: buffer,
	_cursor: number,
	_length: number,
	_maxVarintBytes: number,
	ReadU8: (self: Reader, context: string?) -> number,
	ReadU16: (self: Reader, context: string?) -> number,
	ReadU32: (self: Reader, context: string?) -> number,
	ReadI16: (self: Reader, context: string?) -> number,
	ReadI32: (self: Reader, context: string?) -> number,
	ReadF32: (self: Reader, context: string?) -> number,
	ReadF64: (self: Reader, context: string?) -> number,
	ReadVarUInt: (self: Reader, context: string?) -> number,
	ReadVarInt: (self: Reader, context: string?) -> number,
	ReadString: (self: Reader, maxLength: number, context: string?) -> string,
	ReadRawString: (self: Reader, length: number, context: string?) -> string,
	ReadBuffer: (self: Reader, maxLength: number, context: string?) -> buffer,
	ReadRawBuffer: (self: Reader, length: number, context: string?) -> buffer,
	Remaining: (self: Reader) -> number,
	Position: (self: Reader) -> number,
	_fast: any,
}

local ReaderMethods = {}
ReaderMethods.__index = ReaderMethods

-- See Writer's fast facade: compact columns are decoded through closures that
-- keep the buffer cursor in locals, while the regular methods retain their
-- defensive public API for converter code.
local function makeFastReader(reader: Reader): any
	local data: buffer = reader._data
	local cursor = 0
	local length = 0
	local maxVarintBytes = 0

	local function begin()
		data = reader._data
		cursor = reader._cursor
		length = reader._length
		maxVarintBytes = reader._maxVarintBytes
	end

	local function readU8(_self: any, context: string?): number
		if cursor + 1 > length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
		local value = bufferReadU8(data, cursor)
		cursor += 1
		return value
	end

	local function readF32(_self: any, context: string?): number
		if cursor + 4 > length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
		local value = bufferReadF32(data, cursor)
		cursor += 4
		return value
	end

	local function readF64(_self: any, context: string?): number
		if cursor + 8 > length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
		local value = bufferReadF64(data, cursor)
		cursor += 8
		return value
	end

	local function readVarUInt(_self: any, context: string?): number
		local label = context or "variable-length integer"
		if cursor + 1 > length then error("[Waffles] Unexpected end of buffer while reading " .. label, 3) end
		local first = bufferReadU8(data, cursor)
		cursor += 1
		if first < 128 then return first end
		local result = first % 128
		local multiplier = 128
		for byteIndex = 2, maxVarintBytes do
			if cursor + 1 > length then error("[Waffles] Unexpected end of buffer while reading " .. label, 3) end
			local byte = bufferReadU8(data, cursor)
			cursor += 1
			local digit = byte % 128
			if digit > mathFloor((MAX_SAFE_INTEGER - result) / multiplier) then
				error("[Waffles] Variable-length integer overflow", 2)
			end
			result += digit * multiplier
			if byte < 128 then
				if digit == 0 then error("[Waffles] Malformed variable-length integer: non-canonical encoding", 2) end
				return result
			end
			multiplier *= 128
		end
		error("[Waffles] Malformed variable-length integer: too many continuation bytes", 2)
	end

	local function readVarInt(_self: any, context: string?): number
		local zigzag = readVarUInt(nil, context)
		if zigzag > 9007199254740990 then error("[Waffles] Signed variable-length integer overflow", 2) end
		if zigzag % 2 == 0 then return zigzag / 2 end
		return -(zigzag + 1) / 2
	end

	local function readRawString(_self: any, readLength: number, context: string?): string
		if readLength < 0 or cursor + readLength > length then
			error("[Waffles] Unexpected end of buffer while reading " .. (context or "string"), 3)
		end
		local value = bufferReadString(data, cursor, readLength)
		cursor += readLength
		return value
	end

	-- Compact primitive columns validate their declared counts and string
	-- lengths before entering the hot loop. These accessors retain the buffer's
	-- native bounds checks for malformed/truncated input while avoiding the
	-- receiver/context arguments and repeated Lua-side bounds branches on every
	-- scalar read. The surrounding pcall still normalizes native failures.
	local function readU8Unchecked(): number
		local value = bufferReadU8(data, cursor)
		cursor += 1
		return value
	end

	local function readF32Unchecked(): number
		local value = bufferReadF32(data, cursor)
		cursor += 4
		return value
	end

	local function readF64Unchecked(): number
		local value = bufferReadF64(data, cursor)
		cursor += 8
		return value
	end

	local function readVarUIntUnchecked(): number
		local first = bufferReadU8(data, cursor)
		cursor += 1
		if first < 128 then return first end
		local result = first % 128
		local multiplier = 128
		for byteIndex = 2, maxVarintBytes do
			local byte = bufferReadU8(data, cursor)
			cursor += 1
			local digit = byte % 128
			if digit > mathFloor((MAX_SAFE_INTEGER - result) / multiplier) then
				error("[Waffles] Variable-length integer overflow", 2)
			end
			result += digit * multiplier
			if byte < 128 then
				if digit == 0 then error("[Waffles] Malformed variable-length integer: non-canonical encoding", 2) end
				return result
			end
			multiplier *= 128
		end
		error("[Waffles] Malformed variable-length integer: too many continuation bytes", 2)
	end

	local function readRawStringUnchecked(readLength: number): string
		local value = bufferReadString(data, cursor, readLength)
		cursor += readLength
		return value
	end

	local function readString(_self: any, maxLength: number, context: string?): string
		local readLength = readVarUInt(nil, "string length")
		if readLength > maxLength then
			error(string.format("[Waffles] Declared string length %d exceeds limit %d", readLength, maxLength), 2)
		end
		return readRawString(nil, readLength, context or "string")
	end

	local function finish()
		reader._cursor = cursor
	end

	return {
		Begin = begin,
		Finish = finish,
		ReadU8 = readU8,
		ReadF32 = readF32,
		ReadF64 = readF64,
		ReadVarUInt = readVarUInt,
		ReadVarInt = readVarInt,
		ReadString = readString,
		ReadRawString = readRawString,
		ReadU8Unchecked = readU8Unchecked,
		ReadF32Unchecked = readF32Unchecked,
		ReadF64Unchecked = readF64Unchecked,
		ReadVarUIntUnchecked = readVarUIntUnchecked,
		ReadRawStringUnchecked = readRawStringUnchecked,
		Remaining = function() return length - cursor end,
	}
end

function ReaderMethods.ReadU8(self: Reader, context: string?): number
	local cursor = self._cursor
	if cursor + 1 > self._length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
	local value = bufferReadU8(self._data, cursor)
	self._cursor = cursor + 1
	return value
end

function ReaderMethods.ReadU16(self: Reader, context: string?): number
	local cursor = self._cursor
	if cursor + 2 > self._length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
	local value = bufferReadU16(self._data, cursor)
	self._cursor = cursor + 2
	return value
end

function ReaderMethods.ReadU32(self: Reader, context: string?): number
	local cursor = self._cursor
	if cursor + 4 > self._length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
	local value = bufferReadU32(self._data, cursor)
	self._cursor = cursor + 4
	return value
end

function ReaderMethods.ReadI16(self: Reader, context: string?): number
	local cursor = self._cursor
	if cursor + 2 > self._length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
	local value = bufferReadI16(self._data, cursor)
	self._cursor = cursor + 2
	return value
end

function ReaderMethods.ReadI32(self: Reader, context: string?): number
	local cursor = self._cursor
	if cursor + 4 > self._length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
	local value = bufferReadI32(self._data, cursor)
	self._cursor = cursor + 4
	return value
end

function ReaderMethods.ReadF32(self: Reader, context: string?): number
	local cursor = self._cursor
	if cursor + 4 > self._length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
	local value = bufferReadF32(self._data, cursor)
	self._cursor = cursor + 4
	return value
end

function ReaderMethods.ReadF64(self: Reader, context: string?): number
	local cursor = self._cursor
	if cursor + 8 > self._length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3) end
	local value = bufferReadF64(self._data, cursor)
	self._cursor = cursor + 8
	return value
end

function ReaderMethods.ReadVarUInt(self: Reader, context: string?): number
	local label = context or "variable-length integer"
	local cursor = self._cursor
	if cursor + 1 > self._length then error("[Waffles] Unexpected end of buffer while reading " .. label, 3) end
	local first = bufferReadU8(self._data, cursor)
	cursor += 1
	if first < 128 then
		self._cursor = cursor
		return first
	end
	local result = first % 128
	local multiplier = 128
	for byteIndex = 2, self._maxVarintBytes do
		if cursor + 1 > self._length then error("[Waffles] Unexpected end of buffer while reading " .. label, 3) end
		local byte = bufferReadU8(self._data, cursor)
		cursor += 1
		local digit = byte % 128
		if digit > mathFloor((MAX_SAFE_INTEGER - result) / multiplier) then
			error("[Waffles] Variable-length integer overflow", 2)
		end
		result += digit * multiplier
		if byte < 128 then
			if digit == 0 then
				error("[Waffles] Malformed variable-length integer: non-canonical encoding", 2)
			end
			self._cursor = cursor
			return result
		end
		multiplier *= 128
	end
	error("[Waffles] Malformed variable-length integer: too many continuation bytes", 2)
end

function ReaderMethods.ReadVarInt(self: Reader, context: string?): number
	local zigzag = ReaderMethods.ReadVarUInt(self, context)
	if zigzag > 9007199254740990 then
		error("[Waffles] Signed variable-length integer overflow", 2)
	end
	if zigzag % 2 == 0 then
		return zigzag / 2
	end
	return -(zigzag + 1) / 2
end

function ReaderMethods.ReadRawString(self: Reader, length: number, context: string?): string
	local cursor = self._cursor
	if length < 0 or cursor + length > self._length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "string"), 3) end
	local value = bufferReadString(self._data, cursor, length)
	self._cursor = cursor + length
	return value
end

function ReaderMethods.ReadString(self: Reader, maxLength: number, context: string?): string
	local length = ReaderMethods.ReadVarUInt(self, "string length")
	if length > maxLength then
		error(string.format("[Waffles] Declared string length %d exceeds limit %d", length, maxLength), 2)
	end
	return self:ReadRawString(length, context or "string")
end

function ReaderMethods.ReadRawBuffer(self: Reader, length: number, context: string?): buffer
	local cursor = self._cursor
	if length < 0 or cursor + length > self._length then error("[Waffles] Unexpected end of buffer while reading " .. (context or "buffer"), 3) end
	local value = bufferCreate(length)
	if length > 0 then
		bufferCopy(value, 0, self._data, cursor, length)
	end
	self._cursor = cursor + length
	return value
end

function ReaderMethods.ReadBuffer(self: Reader, maxLength: number, context: string?): buffer
	local length = ReaderMethods.ReadVarUInt(self, "buffer length")
	if length > maxLength then
		error(string.format("[Waffles] Declared buffer length %d exceeds limit %d", length, maxLength), 2)
	end
	return self:ReadRawBuffer(length, context or "buffer")
end

function ReaderMethods.Remaining(self: Reader): number
	return self._length - self._cursor
end

function ReaderMethods.Position(self: Reader): number
	return self._cursor
end

local pool: {Reader} = {}
local EMPTY_BUFFER = buffer.create(0)
local ReaderModule = {}

function ReaderModule.acquire(data: buffer, maxVarintBytes: number, poolingEnabled: boolean): Reader
	if poolingEnabled and #pool > 0 then
		local poolIndex = #pool
		local reader = pool[poolIndex] :: Reader
		pool[poolIndex] = nil
		reader._data = data
		reader._cursor = 0
		reader._length = bufferLen(data)
		reader._maxVarintBytes = maxVarintBytes
		return reader
	end
	local reader = setmetatable({
		_data = data,
		_cursor = 0,
		_length = bufferLen(data),
		_maxVarintBytes = maxVarintBytes,
	}, ReaderMethods) :: any
	reader._fast = makeFastReader(reader)
	return reader
end

function ReaderModule.release(reader: Reader, poolingEnabled: boolean, maxReaders: number)
	if poolingEnabled and #pool < maxReaders then
		-- Keep no reference to the caller's payload, but avoid allocating a new
		-- zero-length buffer for every decode.
		reader._data = EMPTY_BUFFER
		reader._cursor = 0
		reader._length = 0
		pool[#pool + 1] = reader
	end
end

return ReaderModule
