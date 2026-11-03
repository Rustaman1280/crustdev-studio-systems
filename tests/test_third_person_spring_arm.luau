--!strict
local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame
Vector3 = roblox.Vector3
CFrame = roblox.CFrame

local ThirdPersonSpringArm = require("../src/ReplicatedStorage/Camera/ThirdPersonSpringArm")

local function assertApprox(a: number, b: number, eps: number?, msg: string?)
  local epsilon = eps or 1e-3
  if math.abs(a - b) > epsilon then
    error(string.format("%s: expected approx %f, got %f (diff: %f)", msg or "assertApprox", b, a, math.abs(a - b)))
  end
end

-- Test 1: Initialization & Unobstructed Stationary State
do
  local target = Vector3.new(0, 0, 0)
  local arm = ThirdPersonSpringArm.new(target, {
    targetArmLength = 10,
    targetOffset = Vector3.new(0, 3, 0),
    enableCameraLag = false,
    enableRotationLag = false,
  })

  assert(arm.TargetArmLength == 10, "Target arm length should be 10")
  assert(arm.CurrentArmLength == 10, "Current arm length should initialize to 10")
  assertApprox(arm:GetFocusPoint().Y, 3, 1e-3, "Focus point Y should include target offset")

  -- Step with no rotation (Yaw = 0, Pitch = 0)
  -- Backward unit is (0, 0, 1), camera position should be (0, 3, 10)
  local camCF, curLen, obstructed = arm:Step(0.016)
  assert(not obstructed, "Should not be obstructed")
  assertApprox(curLen, 10, 1e-3, "Arm length should remain 10")
  assertApprox(camCF.Position.X, 0, 1e-3, "Camera X")
  assertApprox(camCF.Position.Y, 3, 1e-3, "Camera Y")
  assertApprox(camCF.Position.Z, 10, 1e-3, "Camera Z")
end

-- Test 2: Pitch Clamping and Yaw Normalization
do
  local target = Vector3.new(0, 0, 0)
  local arm = ThirdPersonSpringArm.new(target, {
    minPitch = -60,
    maxPitch = 60,
  })

  arm:SetRotation(80, 400)
  assertApprox(arm.Pitch, 60, 1e-3, "Pitch should clamp to maxPitch 60")
  assertApprox(arm.Yaw, 40, 1e-3, "Yaw 400 deg should normalize to 40 deg")

  arm:SetRotation(-90, -370)
  assertApprox(arm.Pitch, -60, 1e-3, "Pitch should clamp to minPitch -60")
  assertApprox(arm.Yaw, -10, 1e-3, "Yaw -370 deg should normalize to -10 deg")
end

-- Test 3: Camera Positional Lag
do
  local initialTarget = Vector3.new(0, 0, 0)
  local arm = ThirdPersonSpringArm.new(initialTarget, {
    targetArmLength = 10,
    targetOffset = Vector3.new(0, 0, 0),
    enableCameraLag = true,
    cameraLagSpeed = 5.0,
  })

  -- Move target far away abruptly
  arm:SetTargetPosition(Vector3.new(100, 0, 0))

  -- Small step (16ms)
  local camCF1, _, _ = arm:Step(0.016)
  -- Lagged pivot should have moved partially towards 100, not instantaneously 100
  assert(arm.LaggedPivot.X > 0 and arm.LaggedPivot.X < 20, "Lagged pivot should interpolate smoothly")

  -- Run multiple steps to converge
  for _ = 1, 100 do
    arm:Step(0.033)
  end
  assertApprox(arm.LaggedPivot.X, 100, 0.5, "Lagged pivot should eventually converge to target")
end

-- Test 4: Collision Pullback Dynamics
do
  local target = Vector3.new(0, 0, 0)
  local obstacleDistance = 4.0

  -- Mock collision callback: wall at distance 4 studs along camera ray
  local function mockRaycast(origin: any, direction: any, maxDist: number, radius: number)
    if maxDist >= obstacleDistance then
      local hitPoint = origin + direction * obstacleDistance
      local hitNormal = direction * -1
      return true, hitPoint, hitNormal
    end
    return false, nil, nil
  end

  local arm = ThirdPersonSpringArm.new(target, {
    targetArmLength = 15,
    probeRadius = 0.5,
    minArmLength = 1.0,
    pullbackSpeed = 40.0,
    collisionCallback = mockRaycast,
  })

  -- Run simulation step
  local camCF, curLen, obstructed = arm:Step(0.05)
  assert(obstructed == true, "Arm should detect obstruction")
  assert(curLen < 15, "Arm length must pull in towards obstacle")

  -- Step a few more frames to reach pullback equilibrium
  for _ = 1, 10 do
    arm:Step(0.05)
  end
  -- Desired allowed distance is obstacleDistance (4.0) - probeRadius (0.5) = 3.5
  assertApprox(arm.CurrentArmLength, 3.5, 0.2, "Arm should settle near wall boundary")
end

-- Test 5: Asymmetric Damped Return
do
  local target = Vector3.new(0, 0, 0)
  local isBlocked = true

  local function mockDynamicRaycast(origin: any, direction: any, maxDist: number, radius: number)
    if isBlocked then
      return true, origin + direction * 3.0, direction * -1
    end
    return false, nil, nil
  end

  local arm = ThirdPersonSpringArm.new(target, {
    targetArmLength = 12,
    probeRadius = 0.0,
    pullbackSpeed = 50.0,
    returnSpeed = 4.0, -- Slow smooth recovery
    collisionCallback = mockDynamicRaycast,
  })

  -- Block and settle arm at 3.0
  for _ = 1, 20 do
    arm:Step(0.05)
  end
  assertApprox(arm.CurrentArmLength, 3.0, 0.1, "Arm pulled back to 3.0")

  -- Unblock obstacle
  isBlocked = false

  -- In next single frame (16ms), it should not jump back to 12.0 instantly
  local _, lenAfter1Frame, obstructed = arm:Step(0.016)
  assert(not obstructed, "Obstruction cleared")
  assert(lenAfter1Frame > 3.0 and lenAfter1Frame < 5.0, "Arm must recover smoothly, not snap instantaneously")

  -- Fully recover over time
  for _ = 1, 60 do
    arm:Step(0.05)
  end
  assertApprox(arm.CurrentArmLength, 12.0, 0.2, "Arm must eventually return to targetArmLength")
end

-- Test 6: Socket Offset (Over-The-Shoulder Framing)
do
  local target = Vector3.new(0, 0, 0)
  local arm = ThirdPersonSpringArm.new(target, {
    targetArmLength = 10,
    targetOffset = Vector3.new(0, 3, 0),
    socketOffset = Vector3.new(2, 0.5, 0), -- 2 studs to right, 0.5 studs up
  })

  local camCF, _, _ = arm:Step(0.016)
  -- With Yaw=0, Pitch=0: Right is +X, Up is +Y
  assertApprox(camCF.Position.X, 2, 1e-3, "Socket offset X (right shoulder)")
  assertApprox(camCF.Position.Y, 3.5, 1e-3, "TargetOffset Y (3) + SocketOffset Y (0.5)")
  assertApprox(camCF.Position.Z, 10, 1e-3, "ArmLength Z (10)")
end

print("PASS: ThirdPersonSpringArm tests (Init, PitchClamp, Lag, Collision, AsymmetricReturn, SocketOffset) passed cleanly!")
return true