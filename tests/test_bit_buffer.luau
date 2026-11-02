--!strict
local BitBuffer = require("../src/ReplicatedStorage/Utility/BitBuffer")

-- Test 1: Bit and Boolean Writing and Reading
local b1 = BitBuffer.new()
b1:WriteBit(1)
b1:WriteBit(0)
b1:WriteBool(true)
b1:WriteBool(false)
b1:WriteBit(1)

assert(b1:GetBitLength() == 5, "Bit length should be 5")
assert(b1:GetByteLength() == 1, "Byte length should be 1")

assert(b1:ReadBit() == 1, "Bit 1 mismatch")
assert(b1:ReadBit() == 0, "Bit 2 mismatch")
assert(b1:ReadBool() == true, "Bool 1 mismatch")
assert(b1:ReadBool() == false, "Bool 2 mismatch")
assert(b1:ReadBit() == 1, "Bit 3 mismatch")
assert(b1:GetReadCursor() == 5, "Read cursor should be at 5")

-- Test 2: Arbitrary width Unsigned Integers
local b2 = BitBuffer.new()
b2:WriteUInt(15, 4) -- 1111 (4 bits)
b2:WriteUInt(200, 8) -- 8 bits
b2:WriteUInt(4095, 12) -- 12 bits
b2:WriteUInt(4294967295, 32) -- max 32-bit unsigned

assert(b2:GetBitLength() == 4 + 8 + 12 + 32, "Bit length calculation failed")
assert(b2:ReadUInt(4) == 15, "UInt 4-bit mismatch")
assert(b2:ReadUInt(8) == 200, "UInt 8-bit mismatch")
assert(b2:ReadUInt(12) == 4095, "UInt 12-bit mismatch")
assert(b2:ReadUInt(32) == 4294967295, "UInt 32-bit mismatch")

-- Test 3: Signed Integers with Two's Complement
local b3 = BitBuffer.new()
b3:WriteInt(-1, 8)
b3:WriteInt(-128, 8)
b3:WriteInt(127, 8)
b3:WriteInt(-32768, 16)
b3:WriteInt(32767, 16)
b3:WriteInt(0, 4)

assert(b3:ReadInt(8) == -1, "Signed -1 mismatch")
assert(b3:ReadInt(8) == -128, "Signed -128 mismatch")
assert(b3:ReadInt(8) == 127, "Signed 127 mismatch")
assert(b3:ReadInt(16) == -32768, "Signed -32768 mismatch")
assert(b3:ReadInt(16) == 32767, "Signed 32767 mismatch")
assert(b3:ReadInt(4) == 0, "Signed 0 mismatch")

-- Test 4: Quantized Floats
local b4 = BitBuffer.new()
-- Quantize elevation in [-100, 500] with 16 bits (65535 steps => ~0.009 stud error)
local originalFloat1 = 123.456
local originalFloat2 = -89.123
b4:WriteFloat(originalFloat1, -100, 500, 16)
b4:WriteFloat(originalFloat2, -100, 500, 16)

local recovered1 = b4:ReadFloat(-100, 500, 16)
local recovered2 = b4:ReadFloat(-100, 500, 16)
assert(math.abs(recovered1 - originalFloat1) < 0.02, "Float recovery 1 exceeds error tolerance")
assert(math.abs(recovered2 - originalFloat2) < 0.02, "Float recovery 2 exceeds error tolerance")

-- Test 5: String Packing
local b5 = BitBuffer.new()
local testStr = "CrustDev Studio Engine 2026"
b5:WriteString(testStr)
b5:WriteString("") -- empty string test

assert(b5:ReadString() == testStr, "String unpacking mismatch")
assert(b5:ReadString() == "", "Empty string unpacking mismatch")

-- Test 6: Mixed Stream Packing & Hex Deserialization
local b6 = BitBuffer.new()
b6:WriteBool(true)
b6:WriteUInt(7, 3)
b6:WriteInt(-42, 8)
b6:WriteString("RPC_CALL")
b6:WriteFloat(3.14159, 0, 10, 12)

local hex = b6:ToHex()
assert(typeof(hex) == "string" and #hex > 0, "Hex conversion failed")

-- Load from hex into new buffer
local bHex = BitBuffer.fromHex(hex)
assert(bHex:ReadBool() == true, "Hex read bool failed")
assert(bHex:ReadUInt(3) == 7, "Hex read uint failed")
assert(bHex:ReadInt(8) == -42, "Hex read int failed")
assert(bHex:ReadString() == "RPC_CALL", "Hex read string failed")
local recoveredPi = bHex:ReadFloat(0, 10, 12)
assert(math.abs(recoveredPi - 3.14159) < 0.01, "Hex read float failed")

-- Test 7: Cursor Seeking & Rewind
b6:ResetReadCursor()
assert(b6:GetReadCursor() == 0, "Reset read cursor failed")
assert(b6:ReadBool() == true, "Post-reset read failed")

b6:SeekBit(4)
assert(b6:ReadInt(8) == -42, "Seek bit failed")

print("PASS: BitBuffer tests (Bits, UInt, Int, Float, String, Hex, Seek, Mixed) passed cleanly!")
return true
