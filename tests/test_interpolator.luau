local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

local SnapshotInterpolator = require("../src/StarterPlayerScripts/Controllers/SnapshotInterpolator")

local interp = SnapshotInterpolator.new("entity_42", 0.10)

-- Test 1: Empty sample
local pNil, oNil, okNil = interp:Sample(10.0)
assert(pNil == nil and oNil == nil and okNil == false, "Empty buffer sample should return nil")

-- Test 2: Push snapshots
-- Server ticks at t=1.0, 1.1, 1.2
interp:PushSnapshot(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), 0, 1.0)
interp:PushSnapshot(Vector3.new(1, 0, 0), Vector3.new(10, 0, 0), math.pi / 4, 1.1)
interp:PushSnapshot(Vector3.new(2, 0, 0), Vector3.new(10, 0, 0), math.pi / 2, 1.2)

-- Sample at client clock 1.25 -> renderTime = 1.25 - 0.10 = 1.15 (exactly halfway between 1.1 and 1.2)
local pos, rotY, isInterpolated = interp:Sample(1.25)
assert(pos ~= nil, "Sample should return position")
assert(isInterpolated == true, "Should be interpolated")
assert(math.abs(pos.X - 1.5) < 0.1, "Position X should be near 1.5, got " .. tostring(pos.X))
assert(math.abs(rotY - (3 * math.pi / 8)) < 0.05, "Rotation Y should be interpolated")

-- Test 3: Extrapolation beyond newest snapshot
-- Sample at client clock 1.40 -> renderTime = 1.30 (latest snapshot was at 1.20)
local extPos, extRot, extOk = interp:Sample(1.40)
assert(extPos ~= nil, "Extrapolated sample should return position")
assert(extOk == false, "Extrapolation should have isInterpolated == false")
assert(extPos.X > 2.0, "Extrapolated position should have advanced past latest snapshot (2.0)")

-- Test 4: Clear
interp:Clear()
local clearPos = interp:Sample(1.40)
assert(clearPos == nil, "Cleared buffer sample should be nil")

print("PASS: SnapshotInterpolator tests (Empty, Push, Sample Hermite interpolation, Extrapolation, Clear) passed cleanly!")
