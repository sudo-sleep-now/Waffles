--!strict

local BufferUtil = {}

function BufferUtil.Concat(...: buffer): buffer
	local parts = {...}
	local total = 0
	for _, part in parts do
		total += buffer.len(part)
	end
	local output = buffer.create(total)
	local cursor = 0
	for _, part in parts do
		local length = buffer.len(part)
		if length > 0 then
			buffer.copy(output, cursor, part, 0, length)
		end
		cursor += length
	end
	return output
end

function BufferUtil.Slice(data: buffer, first: number?, last: number?): buffer
	local length = buffer.len(data)
	local startIndex = first or 0
	local endIndex = last or length
	if startIndex < 0 or endIndex < startIndex or endIndex > length then
		error("[Waffles] Buffer.Slice indices are out of bounds", 2)
	end
	local output = buffer.create(endIndex - startIndex)
	if endIndex > startIndex then
		buffer.copy(output, 0, data, startIndex, endIndex - startIndex)
	end
	return output
end

function BufferUtil.Equals(a: buffer, b: buffer): boolean
	local length = buffer.len(a)
	if length ~= buffer.len(b) then
		return false
	end
	for index = 0, length - 1 do
		if buffer.readu8(a, index) ~= buffer.readu8(b, index) then
			return false
		end
	end
	return true
end

local HEX = "0123456789abcdef"

function BufferUtil.ToHex(data: buffer): string
	local result = table.create(buffer.len(data))
	for index = 0, buffer.len(data) - 1 do
		local byte = buffer.readu8(data, index)
		local high = math.floor(byte / 16) + 1
		local low = byte % 16 + 1
		result[index + 1] = string.sub(HEX, high, high) .. string.sub(HEX, low, low)
	end
	return table.concat(result)
end

local function hexDigit(character: string): number?
	local byte = string.byte(character)
	if byte >= 48 and byte <= 57 then
		return byte - 48
	elseif byte >= 65 and byte <= 70 then
		return byte - 55
	elseif byte >= 97 and byte <= 102 then
		return byte - 87
	end
	return nil
end

function BufferUtil.FromHex(text: string): buffer
	if #text % 2 ~= 0 then
		error("[Waffles] Hex text must contain an even number of characters", 2)
	end
	local output = buffer.create(#text / 2)
	for index = 1, #text, 2 do
		local high = hexDigit(string.sub(text, index, index))
		local low = hexDigit(string.sub(text, index + 1, index + 1))
		if high == nil or low == nil then
			error(string.format("[Waffles] Invalid hex character at position %d", index), 2)
		end
		buffer.writeu8(output, (index - 1) / 2, high * 16 + low)
	end
	return output
end

return table.freeze(BufferUtil)
