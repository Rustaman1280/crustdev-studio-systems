local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

local RollbackBuffer = require("../src/ServerScriptService/Services/RollbackBuffer")

local buffer = RollbackBuffer.new(1001)
assert(buffer.EntityId == 1001, "EntityId should be initialized")
assert(buffer.Count == 0, "Count should be 0")

-- Record three successive snapshots with simulated timestamps
local t0 = os.clock()
buffer:RecordSnapshot(Vector3.new(0, 0, 0), Vector3.new(4, 5, 4), 1)
-- Manually adjust clock for deterministic interpolation test
buffer.Snapshots[1].ServerClock = t0

buffer:RecordSnapshot(Vector3.new(10, 0, 0), Vector3.new(4, 5, 4), 2)
buffer.Snapshots[2].ServerClock = t0 + 0.1

buffer:RecordSnapshot(Vector3.new(20, 0, 0), Vector3.new(4, 5, 4), 3)
buffer.Snapshots[3].ServerClock = t0 + 0.2

assert(buffer.Count == 3, "Count should be 3")

-- Test 1: Sample at midpoint between tick 1 and 2 (t0 + 0.05)
local midPos = buffer:SampleHistoricalPosition(t0 + 0.05)
assert(midPos ~= nil, "Midpoint sample should return Vector3")
assert(math.abs(midPos.X - 5.0) < 0.001, "Interpolated X should be 5.0, got " .. tostring(midPos.X))

-- Test 2: Sample at newest tick
local newestPos = buffer:SampleHistoricalPosition(t0 + 0.2)
assert(newestPos ~= nil, "Newest sample should return Vector3")
assert(math.abs(newestPos.X - 20.0) < 0.001, "X should be 20.0")

-- Test 3: Lag compensated hit validation
-- Shooter at (5, 0, -10) shooting along +Z direction (0, 0, 1) at time t0 + 0.05
-- Target was at (5, 0, 0) at that time!
local rayOrigin = Vector3.new(5, 0, -10)
local rayDir = Vector3.new(0, 0, 1)
local hitValid = buffer:ValidateLagCompensatedHit(
  rayOrigin,
  rayDir,
  50.0,
  t0 + 0.05,
  2.5 -- tolerance radius
)
assert(hitValid, "Lag-compensated ray aiming directly at historical position should validate hit")

-- Ray aiming away at (50, 0, 0) should miss
local missRayOrigin = Vector3.new(50, 0, -10)
local hitMiss = buffer:ValidateLagCompensatedHit(
  missRayOrigin,
  rayDir,
  50.0,
  t0 + 0.05,
  2.5
)
assert(not hitMiss, "Ray aiming far away should not validate hit")

print("PASS: RollbackBuffer tests (RecordSnapshot, SampleHistoricalPosition, ValidateLagCompensatedHit) passed cleanly!")
