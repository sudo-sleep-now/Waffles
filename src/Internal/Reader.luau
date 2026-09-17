--!strict

local MAX_SAFE_INTEGER = 9007199254740991

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
}

local ReaderMethods = {}
ReaderMethods.__index = ReaderMethods

local function need(self: Reader, byteCount: number, context: string?)
	if byteCount < 0 or self._cursor + byteCount > self._length then
		error("[Waffles] Unexpected end of buffer while reading " .. (context or "value"), 3)
	end
end

function ReaderMethods.ReadU8(self: Reader, context: string?): number
	need(self, 1, context)
	local value = buffer.readu8(self._data, self._cursor)
	self._cursor += 1
	return value
end

function ReaderMethods.ReadU16(self: Reader, context: string?): number
	need(self, 2, context)
	local value = buffer.readu16(self._data, self._cursor)
	self._cursor += 2
	return value
end

function ReaderMethods.ReadU32(self: Reader, context: string?): number
	need(self, 4, context)
	local value = buffer.readu32(self._data, self._cursor)
	self._cursor += 4
	return value
end

function ReaderMethods.ReadI16(self: Reader, context: string?): number
	need(self, 2, context)
	local value = buffer.readi16(self._data, self._cursor)
	self._cursor += 2
	return value
end

function ReaderMethods.ReadI32(self: Reader, context: string?): number
	need(self, 4, context)
	local value = buffer.readi32(self._data, self._cursor)
	self._cursor += 4
	return value
end

function ReaderMethods.ReadF32(self: Reader, context: string?): number
	need(self, 4, context)
	local value = buffer.readf32(self._data, self._cursor)
	self._cursor += 4
	return value
end

function ReaderMethods.ReadF64(self: Reader, context: string?): number
	need(self, 8, context)
	local value = buffer.readf64(self._data, self._cursor)
	self._cursor += 8
	return value
end

function ReaderMethods.ReadVarUInt(self: Reader, context: string?): number
	local result = 0
	local multiplier = 1
	for byteIndex = 1, self._maxVarintBytes do
		local byte = self:ReadU8(context or "variable-length integer")
		local digit = byte % 128
		if digit > math.floor((MAX_SAFE_INTEGER - result) / multiplier) then
			error("[Waffles] Variable-length integer overflow", 2)
		end
		result += digit * multiplier
		if byte < 128 then
			if byteIndex > 1 and digit == 0 then
				error("[Waffles] Malformed variable-length integer: non-canonical encoding", 2)
			end
			return result
		end
		multiplier *= 128
	end
	error("[Waffles] Malformed variable-length integer: too many continuation bytes", 2)
end

function ReaderMethods.ReadVarInt(self: Reader, context: string?): number
	local zigzag = self:ReadVarUInt(context)
	if zigzag > 9007199254740990 then
		error("[Waffles] Signed variable-length integer overflow", 2)
	end
	if zigzag % 2 == 0 then
		return zigzag / 2
	end
	return -(zigzag + 1) / 2
end

function ReaderMethods.ReadRawString(self: Reader, length: number, context: string?): string
	need(self, length, context or "string")
	local value = buffer.readstring(self._data, self._cursor, length)
	self._cursor += length
	return value
end

function ReaderMethods.ReadString(self: Reader, maxLength: number, context: string?): string
	local length = self:ReadVarUInt("string length")
	if length > maxLength then
		error(string.format("[Waffles] Declared string length %d exceeds limit %d", length, maxLength), 2)
	end
	return self:ReadRawString(length, context or "string")
end

function ReaderMethods.ReadRawBuffer(self: Reader, length: number, context: string?): buffer
	need(self, length, context or "buffer")
	local value = buffer.create(length)
	if length > 0 then
		buffer.copy(value, 0, self._data, self._cursor, length)
	end
	self._cursor += length
	return value
end

function ReaderMethods.ReadBuffer(self: Reader, maxLength: number, context: string?): buffer
	local length = self:ReadVarUInt("buffer length")
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
local ReaderModule = {}

function ReaderModule.acquire(data: buffer, maxVarintBytes: number, poolingEnabled: boolean): Reader
	if poolingEnabled and #pool > 0 then
		local reader = table.remove(pool) :: Reader
		reader._data = data
		reader._cursor = 0
		reader._length = buffer.len(data)
		reader._maxVarintBytes = maxVarintBytes
		return reader
	end
	return setmetatable({
		_data = data,
		_cursor = 0,
		_length = buffer.len(data),
		_maxVarintBytes = maxVarintBytes,
	}, ReaderMethods) :: any
end

function ReaderModule.release(reader: Reader, poolingEnabled: boolean, maxReaders: number)
	if poolingEnabled and #pool < maxReaders then
		reader._data = buffer.create(0)
		reader._cursor = 0
		reader._length = 0
		table.insert(pool, reader)
	end
end

return ReaderModule
