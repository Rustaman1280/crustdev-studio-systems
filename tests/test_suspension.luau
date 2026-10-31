local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame
Vector3 = roblox.Vector3
CFrame = roblox.CFrame

local RaycastSuspension = require("../src/ServerScriptService/Services/RaycastSuspension")

-- Test 1: Config and Initial State
local config = RaycastSuspension.CreateDefaultConfig()
assert(config.RestLength == 2.4, "Default RestLength should be 2.4")
assert(config.SpringStiffness == 32000.0, "Default SpringStiffness should be 32000")

local state = RaycastSuspension.CreateInitialState(config)
assert(state.PreviousLength == 2.4, "PreviousLength should match RestLength")
assert(state.IsGrounded == false, "Initial state must not be grounded")
assert(state.CompressionRatio == 0.0, "Initial compression ratio must be 0")

-- Test 2: Ungrounded (Airborne) Wheel
local chassisCF = CFrame.new(0, 10, 0)
local zeroVel = Vector3.zero
local attachmentOffset = Vector3.new(1.5, -0.5, 2.0)

local forceAir, stateAir = RaycastSuspension.ComputeWheelForces(
  config, state, chassisCF, zeroVel, attachmentOffset, nil, 1/60, 0.0, 0.0
)
assert(forceAir == Vector3.zero, "Airborne suspension force should be Vector3.zero")
assert(stateAir.IsGrounded == false, "Airborne wheel must not be grounded")
assert(stateAir.ContactPoint == nil, "Airborne wheel contact point must be nil")

-- Test 3: Grounded Compressed Wheel
-- RestLength = 2.4, WheelRadius = 1.2
-- Hit distance = 2.0 -> Current length = clamp(2.0 - 1.2, 0.1, 2.4) = 0.8
-- Compression = 2.4 - 0.8 = 1.6
local mockHit = {
  Distance = 2.0,
  Position = Vector3.new(1.5, 8.0, 2.0),
  Normal = Vector3.new(0, 1, 0),
}

local forceGround, stateGround = RaycastSuspension.ComputeWheelForces(
  config, state, chassisCF, zeroVel, attachmentOffset, mockHit, 1/60, 0.0, 0.0
)

assert(stateGround.IsGrounded == true, "Grounded wheel should report IsGrounded true")
assert(stateGround.ContactPoint == mockHit.Position, "ContactPoint should match hit position")
assert(stateGround.CompressionRatio > 0.6, "Compression ratio should be ~0.66")
assert(forceGround.Y > 0, "Upward suspension force should push chassis up (positive Y)")

-- Test 4: Lateral slide damping and drive force
local slidingVel = Vector3.new(15, 0, 0)
local forceSlide, _ = RaycastSuspension.ComputeWheelForces(
  config, stateGround, chassisCF, slidingVel, attachmentOffset, mockHit, 1/60, 1.0, 0.0
)
-- Slide in positive X should be resisted by lateral grip force in negative X
assert(forceSlide.X < 0, "Lateral grip must resist positive X slide")
-- Throttle = 1.0 should generate forward force along LookVector (-Z in default CFrame orientation)
assert(forceSlide.Z < 0, "Forward throttle must apply drive force along LookVector")

print("PASS: RaycastSuspension tests (Default config, Airborne physics, Grounded compression, Lateral grip) passed cleanly!")
