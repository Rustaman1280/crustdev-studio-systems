--!strict
--[[
  BitBuffer.luau
  crustdev studio systems - ReplicatedStorage/Utility/BitBuffer

  Compact bit-level stream serializer and deserializer for high-throughput
  Roblox and Lune networking pipelines:
  - Big-endian bit packing with arbitrary bit-width integers (1 to 32 bits).
  - Signed integer encoding with two's complement arithmetic.
  - Floating-point normalization and quantization over arbitrary ranges.
  - Variable-length boolean and ASCII/UTF-8 string stream encoding.
  - Hexadecimal and raw byte stream export/import for persistence.
  - Zero heap fragmentation and defensive bounds validation.

  Part of crustdev studio game systems.
]]

export type BitBuffer = {
  _bytes: { number },
  _bitLength: number,
  _readCursor: number,

  -- Writers
  WriteBit: (self: BitBuffer, bit: number) -> BitBuffer,
  WriteBool: (self: BitBuffer, value: boolean) -> BitBuffer,
  WriteUInt: (self: BitBuffer, value: number, bits: number) -> BitBuffer,
  WriteInt: (self: BitBuffer, value: number, bits: number) -> BitBuffer,
  WriteFloat: (self: BitBuffer, value: number, min: number, max: number, bits: number) -> BitBuffer,
  WriteString: (self: BitBuffer, str: string) -> BitBuffer,

  -- Readers
  ReadBit: (self: BitBuffer) -> number,
  ReadBool: (self: BitBuffer) -> boolean,
  ReadUInt: (self: BitBuffer, bits: number) -> number,
  ReadInt: (self: BitBuffer, bits: number) -> number,
  ReadFloat: (self: BitBuffer, min: number, max: number, bits: number) -> number,
  ReadString: (self: BitBuffer) -> string,

  -- Cursor and Capacity
  GetBitLength: (self: BitBuffer) -> number,
  GetByteLength: (self: BitBuffer) -> number,
  GetReadCursor: (self: BitBuffer) -> number,
  SeekBit: (self: BitBuffer, bitOffset: number) -> (),
  ResetReadCursor: (self: BitBuffer) -> (),
  Clear: (self: BitBuffer) -> (),

  -- Serialization
  DumpBytes: (self: BitBuffer) -> { number },
  ToHex: (self: BitBuffer) -> string,
  ToBinaryString: (self: BitBuffer) -> string,
}

local BitBuffer = {}
BitBuffer.__index = BitBuffer

function BitBuffer.new(): BitBuffer
  local self = setmetatable({
    _bytes = {},
    _bitLength = 0,
    _readCursor = 0,
  }, BitBuffer)
  return (self :: any) :: BitBuffer
end

function BitBuffer.fromBytes(bytes: { number }, bitLength: number?): BitBuffer
  local buf = BitBuffer.new()
  local totalBytes = #bytes
  for i = 1, totalBytes do
    buf._bytes[i] = bit32.band(bytes[i], 0xFF)
  end
  buf._bitLength = bitLength or (totalBytes * 8)
  return buf
end

function BitBuffer.fromHex(hex: string): BitBuffer
  assert(#hex % 2 == 0, "Hex string length must be an even number")
  local bytes = {}
  local byteCount = #hex / 2
  for i = 1, byteCount do
    local sub = string.sub(hex, (i - 1) * 2 + 1, i * 2)
    local val = tonumber(sub, 16)
    assert(val ~= nil, "Invalid hexadecimal character sequence: " .. sub)
    bytes[i] = val
  end
  return BitBuffer.fromBytes(bytes)
end

function BitBuffer.WriteBit(self: BitBuffer, bit: number): BitBuffer
  local b = bit32.band(bit, 1)
  local byteIdx = math.floor(self._bitLength / 8) + 1
  local bitPos = 7 - (self._bitLength % 8)

  local cur = self._bytes[byteIdx] or 0
  if b == 1 then
    self._bytes[byteIdx] = bit32.bor(cur, bit32.lshift(1, bitPos))
  else
    self._bytes[byteIdx] = cur
  end
  self._bitLength += 1
  return self
end

function BitBuffer.WriteBool(self: BitBuffer, value: boolean): BitBuffer
  return self:WriteBit(if value then 1 else 0)
end

function BitBuffer.WriteUInt(self: BitBuffer, value: number, bits: number): BitBuffer
  assert(bits >= 1 and bits <= 32, "Bit width must be between 1 and 32")
  local rounded = math.floor(value + 0.5)
  for i = bits - 1, 0, -1 do
    local bit = bit32.band(bit32.rshift(rounded, i), 1)
    self:WriteBit(bit)
  end
  return self
end

function BitBuffer.WriteInt(self: BitBuffer, value: number, bits: number): BitBuffer
  assert(bits >= 2 and bits <= 32, "Signed bit width must be between 2 and 32")
  local rounded = math.floor(value + 0.5)
  local maxVal = 2 ^ (bits - 1) - 1
  local minVal = -(2 ^ (bits - 1))
  assert(rounded >= minVal and rounded <= maxVal, "Signed integer value out of range for bit width")

  local unsignedVal = rounded
  if unsignedVal < 0 then
    unsignedVal = unsignedVal + (2 ^ bits)
  end
  return self:WriteUInt(unsignedVal, bits)
end

function BitBuffer.WriteFloat(self: BitBuffer, value: number, min: number, max: number, bits: number): BitBuffer
  assert(max > min, "Maximum range must be strictly greater than minimum range")
  assert(bits >= 2 and bits <= 32, "Float precision bits must be between 2 and 32")
  local alpha = math.clamp((value - min) / (max - min), 0, 1)
  local maxSteps = (2 ^ bits) - 1
  local quantized = math.floor(alpha * maxSteps + 0.5)
  return self:WriteUInt(quantized, bits)
end

function BitBuffer.WriteString(self: BitBuffer, str: string): BitBuffer
  local len = #str
  assert(len <= 65535, "String length exceeds 16-bit prefix limit (65535)")
  self:WriteUInt(len, 16)
  for i = 1, len do
    local byteVal = string.byte(str, i)
    self:WriteUInt(byteVal, 8)
  end
  return self
end

function BitBuffer.ReadBit(self: BitBuffer): number
  assert(self._readCursor < self._bitLength, "End of bit stream reached during ReadBit")
  local byteIdx = math.floor(self._readCursor / 8) + 1
  local bitPos = 7 - (self._readCursor % 8)
  self._readCursor += 1
  local byteVal = self._bytes[byteIdx] or 0
  return bit32.band(bit32.rshift(byteVal, bitPos), 1)
end

function BitBuffer.ReadBool(self: BitBuffer): boolean
  return self:ReadBit() == 1
end

function BitBuffer.ReadUInt(self: BitBuffer, bits: number): number
  assert(bits >= 1 and bits <= 32, "Bit width must be between 1 and 32")
  local val = 0
  for _ = 1, bits do
    val = bit32.bor(bit32.lshift(val, 1), self:ReadBit())
  end
  return val
end

function BitBuffer.ReadInt(self: BitBuffer, bits: number): number
  assert(bits >= 2 and bits <= 32, "Signed bit width must be between 2 and 32")
  local unsignedVal = self:ReadUInt(bits)
  local signBit = bit32.lshift(1, bits - 1)
  if bit32.btest(unsignedVal, signBit) then
    return unsignedVal - (2 ^ bits)
  end
  return unsignedVal
end

function BitBuffer.ReadFloat(self: BitBuffer, min: number, max: number, bits: number): number
  assert(max > min, "Maximum range must be strictly greater than minimum range")
  local maxSteps = (2 ^ bits) - 1
  local quantized = self:ReadUInt(bits)
  local alpha = quantized / maxSteps
  return min + alpha * (max - min)
end

function BitBuffer.ReadString(self: BitBuffer): string
  local len = self:ReadUInt(16)
  local chars = table.create(len)
  for i = 1, len do
    chars[i] = string.char(self:ReadUInt(8))
  end
  return table.concat(chars)
end

function BitBuffer.GetBitLength(self: BitBuffer): number
  return self._bitLength
end

function BitBuffer.GetByteLength(self: BitBuffer): number
  return math.ceil(self._bitLength / 8)
end

function BitBuffer.GetReadCursor(self: BitBuffer): number
  return self._readCursor
end

function BitBuffer.SeekBit(self: BitBuffer, bitOffset: number): ()
  assert(bitOffset >= 0 and bitOffset <= self._bitLength, "Seek offset out of bit buffer bounds")
  self._readCursor = bitOffset
end

function BitBuffer.ResetReadCursor(self: BitBuffer): ()
  self._readCursor = 0
end

function BitBuffer.Clear(self: BitBuffer): ()
  table.clear(self._bytes)
  self._bitLength = 0
  self._readCursor = 0
end

function BitBuffer.DumpBytes(self: BitBuffer): { number }
  local totalBytes = self:GetByteLength()
  local copy = table.create(totalBytes)
  for i = 1, totalBytes do
    copy[i] = self._bytes[i] or 0
  end
  return copy
end

function BitBuffer.ToHex(self: BitBuffer): string
  local totalBytes = self:GetByteLength()
  local hexParts = table.create(totalBytes)
  for i = 1, totalBytes do
    hexParts[i] = string.format("%02x", self._bytes[i] or 0)
  end
  return table.concat(hexParts)
end

function BitBuffer.ToBinaryString(self: BitBuffer): string
  local totalBytes = self:GetByteLength()
  local byteChars = table.create(totalBytes)
  for i = 1, totalBytes do
    byteChars[i] = string.char(self._bytes[i] or 0)
  end
  return table.concat(byteChars)
end

return BitBuffer
