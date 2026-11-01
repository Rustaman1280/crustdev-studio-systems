local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local CameraSpring = require("../src/ReplicatedStorage/Camera/CameraSpring")

-- Test 1: Initialization and Defaults
local spring = CameraSpring.new()
assert(spring.Position == Vector3.zero, "Position should initialize to zero")
assert(spring.Velocity == Vector3.zero, "Velocity should initialize to zero")
assert(spring.Target == Vector3.zero, "Target should initialize to zero")
assert(spring.FovPosition == 70, "Default FOV should be 70")
assert(spring.Trauma == 0, "Trauma should start at zero")

-- Test 2: Critical Damping Motion & Non-Overshoot
local critSpring = CameraSpring.new({
  frequency = 20,
  dampingRatio = 1.0, -- Critically damped
})
critSpring:SetTarget(Vector3.new(10, 0, 0))

local maxPos = 0
for _ = 1, 100 do
  local pos, _, _ = critSpring:Step(0.016)
  if pos.X > maxPos then
    maxPos = pos.X
  end
end
assert(maxPos <= 10.0001, "Critically damped spring must not overshoot target 10")
assert(math.abs(critSpring.Position.X - 10) < 0.01, "Spring should settle near target 10")

-- Test 3: Underdamped Spring Overshoot
local bouncySpring = CameraSpring.new({
  frequency = 15,
  dampingRatio = 0.3, -- Underdamped / bouncy
})
bouncySpring:SetTarget(Vector3.new(10, 0, 0))

local bouncedOver = false
for _ = 1, 100 do
  local pos, _, _ = bouncySpring:Step(0.016)
  if pos.X > 10.05 then
    bouncedOver = true
    break
  end
end
assert(bouncedOver == true, "Underdamped spring must oscillate past target position")

-- Test 4: Impulse Recoil
local recoilSpring = CameraSpring.new({ frequency = 25, dampingRatio = 1.0 })
recoilSpring:Impulse(Vector3.new(0, 50, -20))
assert(recoilSpring.Velocity.Y == 50, "Impulse should immediately apply to Velocity.Y")
assert(recoilSpring.Velocity.Z == -20, "Impulse should immediately apply to Velocity.Z")

local kickedPos, _, _ = recoilSpring:Step(0.016)
assert(kickedPos.Y > 0, "Position should displace upward following impulse")
assert(kickedPos.Z < 0, "Position should displace backward following impulse")

-- Test 5: Trauma Screenshake & Cubic Dissipation
local traumaSpring = CameraSpring.new({
  frequency = 25,
  dampingRatio = 1.0,
  traumaDecayRate = 2.0, -- Dissipates in 0.5s from 1.0
  maxTraumaPitch = 15,
  maxTraumaYaw = 10,
  maxTraumaRoll = 20,
})

traumaSpring:AddTrauma(0.8)
assert(traumaSpring.Trauma == 0.8, "Trauma must register at 0.8")
traumaSpring:Step(0.01) -- Step to advance trauma time
local angles = traumaSpring:GetTraumaAngles()
assert(angles.Magnitude > 0, "Trauma angles must be non-zero while trauma > 0")

-- Step past decay time (0.8 / 2.0 = 0.4s)
for _ = 1, 40 do
  traumaSpring:Step(0.016)
end
assert(traumaSpring.Trauma == 0, "Trauma should fully decay to 0")
assert(traumaSpring:GetTraumaAngles() == Vector3.zero, "Angles should be zero when trauma is gone")

-- Test 6: FOV Spring Transitions & Impulse
local fovSpring = CameraSpring.new({ frequency = 20, dampingRatio = 1.0 })
fovSpring:SetFovTarget(90)
for _ = 1, 60 do
  fovSpring:Step(0.016)
end
assert(math.abs(fovSpring.FovPosition - 90) < 0.1, "FOV should transition to 90")

fovSpring:ImpulseFov(100)
assert(math.abs(fovSpring.FovVelocity - 100) < 0.05, "FOV velocity should jump by 100")
local _, newFov, _ = fovSpring:Step(0.016)
assert(newFov > 90, "FOV position should surge higher after impulse")

-- Test 7: Numerical Stability under Variable & Extreme Timesteps
local stressSpring = CameraSpring.new({ frequency = 30, dampingRatio = 1.0 })
stressSpring:SetTarget(Vector3.new(100, -50, 25))
stressSpring:Impulse(Vector3.new(500, 500, 500))

-- Large timesteps (e.g. lag spikes of 0.25s)
for _ = 1, 10 do
  stressSpring:Step(0.25)
end
assert(not (stressSpring.Position.X ~= stressSpring.Position.X), "X must not be NaN")
assert(not (stressSpring.Position.Y ~= stressSpring.Position.Y), "Y must not be NaN")
assert(not (stressSpring.Position.Z ~= stressSpring.Position.Z), "Z must not be NaN")
assert(math.abs(stressSpring.Position.X - 100) < 0.01, "Position should converge cleanly without NaN/inf")

-- Test 8: Reset & SnapTo
stressSpring:SnapTo(Vector3.new(5, 5, 5))
assert(stressSpring.Position == Vector3.new(5, 5, 5), "SnapTo must set position directly")
assert(stressSpring.Velocity == Vector3.zero, "SnapTo must reset velocity")

stressSpring:Reset()
assert(stressSpring.Position == Vector3.zero, "Reset must restore zero state")
assert(stressSpring.FovPosition == 70, "Reset must restore 70 FOV")

print("PASS: CameraSpring tests (Analytical ODE, Critical, Underdamped, Recoil, Trauma, FOV, Stability) passed cleanly!")
