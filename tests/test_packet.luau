local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

local PacketSchema = require("../src/ReplicatedStorage/Net/PacketSchema")

-- Test 1: CreateHeader
local header = PacketSchema.CreateHeader(101, "combat")
assert(header.Sequence == 101, "Sequence should match")
assert(header.Channel == "combat", "Channel should match")
assert(type(header.Timestamp) == "number", "Timestamp should be a number")

-- Test 2: ValidateHitIntent - Valid packet
local validPacket = {
  Header = header,
  TargetId = 42,
  ClientOrigin = Vector3.new(0, 5, 0),
  HitDirection = Vector3.new(1, 0, 0), -- unit vector
  WeaponId = "plasma_rifle_mk1",
  ClientEstimatedLag = 0.045,
}

local ok, err = PacketSchema.ValidateHitIntent(validPacket)
assert(ok, "Valid packet should pass: " .. tostring(err))

-- Test 3: ValidateHitIntent - Unnormalized direction
local invalidDirPacket = {
  Header = header,
  TargetId = 42,
  ClientOrigin = Vector3.new(0, 5, 0),
  HitDirection = Vector3.new(10, 0, 0), -- not unit vector!
  WeaponId = "plasma_rifle_mk1",
  ClientEstimatedLag = 0.045,
}
local badDirOk, badDirErr = PacketSchema.ValidateHitIntent(invalidDirPacket)
assert(not badDirOk, "Unnormalized direction should fail")
assert(string.find(badDirErr or "", "normalized unit vector"), "Error message should mention unit vector")

-- Test 4: ValidateHitIntent - Empty WeaponId
local badWeaponPacket = {
  Header = header,
  TargetId = 42,
  ClientOrigin = Vector3.new(0, 5, 0),
  HitDirection = Vector3.new(1, 0, 0),
  WeaponId = "",
  ClientEstimatedLag = 0.045,
}
local badWeapOk, badWeapErr = PacketSchema.ValidateHitIntent(badWeaponPacket)
assert(not badWeapOk, "Empty WeaponId should fail")

-- Test 5: Vector3 Compression and Decompression
local originalVec = Vector3.new(12.3456, -45.6789, 100.001)
local qx, qy, qz = PacketSchema.CompressVector3(originalVec)
local decompressedVec = PacketSchema.DecompressVector3(qx, qy, qz)

assert(math.abs(decompressedVec.X - 12.35) < 0.01, "X should decompress with 0.01 precision")
assert(math.abs(decompressedVec.Y - (-45.68)) < 0.01, "Y should decompress with 0.01 precision")
assert(math.abs(decompressedVec.Z - 100.0) < 0.01, "Z should decompress with 0.01 precision")

print("PASS: PacketSchema tests (CreateHeader, ValidateHitIntent, Vector3 Compression) passed cleanly!")
