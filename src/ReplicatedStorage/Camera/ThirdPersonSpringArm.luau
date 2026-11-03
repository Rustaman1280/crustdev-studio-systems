--!strict
--[[
  ThirdPersonSpringArm.luau
  crustdev studio systems - ReplicatedStorage/Camera/ThirdPersonSpringArm

  Production-grade third-person camera spring arm and orbital boom controller:
  - 6-DOF orbital orientation (Pitch, Yaw, Roll) with configurable pitch clamping and continuous yaw wrapping.
  - Target-relative pivot offset (head/torso pivot) and camera-relative socket offset (over-the-shoulder shooter framing).
  - Predictive occlusion detection via customizable raycast/spherecast collision callback.
  - Asymmetric arm length dynamics: rapid pullback on geometry collision, smooth damped recovery on clearance.
  - Independent positional and rotational camera lag filters for cinematic weight and fluid motion.
  - Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local CFrame = _G.CFrame or CFrame

export type CollisionQueryResult = {
  hasHit: boolean,
  hitPoint: Vector3?,
  hitNormal: Vector3?,
  distance: number?,
}

export type CollisionCallback = (
  origin: Vector3,
  direction: Vector3,
  maxDistance: number,
  probeRadius: number
) -> (boolean, Vector3?, Vector3?)

export type SpringArmConfig = {
  targetArmLength: number?,
  minArmLength: number?,
  maxArmLength: number?,
  targetOffset: Vector3?,
  socketOffset: Vector3?,
  probeRadius: number?,
  minPitch: number?,
  maxPitch: number?,
  pullbackSpeed: number?,
  returnSpeed: number?,
  enableCameraLag: boolean?,
  cameraLagSpeed: number?,
  enableRotationLag: boolean?,
  cameraRotationLagSpeed: number?,
  collisionCallback: CollisionCallback?,
}

export type ThirdPersonSpringArmInstance = {
  TargetPosition: Vector3,
  TargetOffset: Vector3,
  SocketOffset: Vector3,
  TargetArmLength: number,
  CurrentArmLength: number,
  MinArmLength: number,
  MaxArmLength: number,
  ProbeRadius: number,
  MinPitch: number,
  MaxPitch: number,
  PullbackSpeed: number,
  ReturnSpeed: number,
  EnableCameraLag: boolean,
  CameraLagSpeed: number,
  EnableRotationLag: boolean,
  CameraRotationLagSpeed: number,

  Pitch: number,
  Yaw: number,
  Roll: number,

  LaggedPivot: Vector3,
  LaggedPitch: number,
  LaggedYaw: number,
  LaggedRoll: number,

  IsObstructed: boolean,
  CollisionCallback: CollisionCallback?,

  SetTargetPosition: (self: ThirdPersonSpringArmInstance, pos: Vector3) -> (),
  SetArmLength: (self: ThirdPersonSpringArmInstance, length: number) -> (),
  SetRotation: (self: ThirdPersonSpringArmInstance, pitch: number, yaw: number, roll: number?) -> (),
  AddRotation: (self: ThirdPersonSpringArmInstance, deltaPitch: number, deltaYaw: number, deltaRoll: number?) -> (),
  SetCollisionCallback: (self: ThirdPersonSpringArmInstance, callback: CollisionCallback?) -> (),
  SetSocketOffset: (self: ThirdPersonSpringArmInstance, offset: Vector3) -> (),
  SetTargetOffset: (self: ThirdPersonSpringArmInstance, offset: Vector3) -> (),
  Step: (self: ThirdPersonSpringArmInstance, dt: number) -> (CFrame, number, boolean),
  GetFocusPoint: (self: ThirdPersonSpringArmInstance) -> Vector3,
  GetLookVector: (self: ThirdPersonSpringArmInstance) -> Vector3,
  Reset: (self: ThirdPersonSpringArmInstance, targetPosition: Vector3?) -> (),
}

local ThirdPersonSpringArm = {}
ThirdPersonSpringArm.__index = ThirdPersonSpringArm

local function normalizeAngle(angleDeg: number): number
  local a = angleDeg % 360
  if a > 180 then
    a = a - 360
  elseif a <= -180 then
    a = a + 360
  end
  return a
end

local function angleDifference(targetDeg: number, currentDeg: number): number
  local diff = (targetDeg - currentDeg) % 360
  if diff > 180 then
    diff = diff - 360
  elseif diff <= -180 then
    diff = diff + 360
  end
  return diff
end

function ThirdPersonSpringArm.new(initialTarget: Vector3, config: SpringArmConfig?): ThirdPersonSpringArmInstance
  local cfg = config or {}

  local targetArmLen = cfg.targetArmLength or 12.0
  local minArmLen = cfg.minArmLength or 1.0
  local maxArmLen = cfg.maxArmLength or 40.0
  local tgtOffset = cfg.targetOffset or Vector3.new(0, 3, 0)
  local sockOffset = cfg.socketOffset or Vector3.new(0, 0, 0)
  local probeRad = cfg.probeRadius or 0.4
  local minP = cfg.minPitch or -80.0
  local maxP = cfg.maxPitch or 80.0
  local pullSpeed = cfg.pullbackSpeed or 35.0
  local retSpeed = cfg.returnSpeed or 8.0
  local lagPos = if cfg.enableCameraLag ~= nil then cfg.enableCameraLag else false
  local lagPosSpeed = cfg.cameraLagSpeed or 12.0
  local lagRot = if cfg.enableRotationLag ~= nil then cfg.enableRotationLag else false
  local lagRotSpeed = cfg.cameraRotationLagSpeed or 14.0

  local initialPivot = initialTarget + tgtOffset

  local self = setmetatable({
    TargetPosition = initialTarget,
    TargetOffset = tgtOffset,
    SocketOffset = sockOffset,
    TargetArmLength = targetArmLen,
    CurrentArmLength = targetArmLen,
    MinArmLength = minArmLen,
    MaxArmLength = maxArmLen,
    ProbeRadius = probeRad,
    MinPitch = minP,
    MaxPitch = maxP,
    PullbackSpeed = pullSpeed,
    ReturnSpeed = retSpeed,
    EnableCameraLag = lagPos,
    CameraLagSpeed = lagPosSpeed,
    EnableRotationLag = lagRot,
    CameraRotationLagSpeed = lagRotSpeed,

    Pitch = 0.0,
    Yaw = 0.0,
    Roll = 0.0,

    LaggedPivot = initialPivot,
    LaggedPitch = 0.0,
    LaggedYaw = 0.0,
    LaggedRoll = 0.0,

    IsObstructed = false,
    CollisionCallback = cfg.collisionCallback,
  }, ThirdPersonSpringArm)

  return (self :: any) :: ThirdPersonSpringArmInstance
end

function ThirdPersonSpringArm:SetTargetPosition(pos: Vector3)
  self.TargetPosition = pos
end

function ThirdPersonSpringArm:SetArmLength(length: number)
  self.TargetArmLength = math.clamp(length, self.MinArmLength, self.MaxArmLength)
end

function ThirdPersonSpringArm:SetRotation(pitch: number, yaw: number, roll: number?)
  self.Pitch = math.clamp(pitch, self.MinPitch, self.MaxPitch)
  self.Yaw = normalizeAngle(yaw)
  self.Roll = if roll ~= nil then roll else 0.0
end

function ThirdPersonSpringArm:AddRotation(deltaPitch: number, deltaYaw: number, deltaRoll: number?)
  self.Pitch = math.clamp(self.Pitch + deltaPitch, self.MinPitch, self.MaxPitch)
  self.Yaw = normalizeAngle(self.Yaw + deltaYaw)
  if deltaRoll ~= nil then
    self.Roll = self.Roll + deltaRoll
  end
end

function ThirdPersonSpringArm:SetCollisionCallback(callback: CollisionCallback?)
  self.CollisionCallback = callback
end

function ThirdPersonSpringArm:SetSocketOffset(offset: Vector3)
  self.SocketOffset = offset
end

function ThirdPersonSpringArm:SetTargetOffset(offset: Vector3)
  self.TargetOffset = offset
end

function ThirdPersonSpringArm:GetFocusPoint(): Vector3
  return self.TargetPosition + self.TargetOffset
end

function ThirdPersonSpringArm:GetLookVector(): Vector3
  local radYaw = math.rad(self.Yaw)
  local radPitch = math.rad(self.Pitch)
  local cosPitch = math.cos(radPitch)
  local sinPitch = math.sin(radPitch)
  local sinYaw = math.sin(radYaw)
  local cosYaw = math.cos(radYaw)

  return Vector3.new(-sinYaw * cosPitch, sinPitch, -cosYaw * cosPitch)
end

function ThirdPersonSpringArm:Reset(targetPosition: Vector3?)
  if targetPosition then
    self.TargetPosition = targetPosition
  end
  self.LaggedPivot = self.TargetPosition + self.TargetOffset
  self.CurrentArmLength = self.TargetArmLength
  self.LaggedPitch = self.Pitch
  self.LaggedYaw = self.Yaw
  self.LaggedRoll = self.Roll
  self.IsObstructed = false
end

function ThirdPersonSpringArm:Step(dt: number): (CFrame, number, boolean)
  local effectiveDt = math.clamp(dt, 1e-4, 0.1)
  local currentPivot = self.TargetPosition + self.TargetOffset

  -- 1. Positional Lag Interpolation
  if self.EnableCameraLag then
    local lagAlpha = 1.0 - math.exp(-self.CameraLagSpeed * effectiveDt)
    self.LaggedPivot = self.LaggedPivot + (currentPivot - self.LaggedPivot) * lagAlpha
  else
    self.LaggedPivot = currentPivot
  end

  -- 2. Rotational Lag Interpolation
  local evalPitch = self.Pitch
  local evalYaw = self.Yaw
  local evalRoll = self.Roll

  if self.EnableRotationLag then
    local rotAlpha = 1.0 - math.exp(-self.CameraRotationLagSpeed * effectiveDt)
    self.LaggedPitch = self.LaggedPitch + (self.Pitch - self.LaggedPitch) * rotAlpha
    local yawDiff = angleDifference(self.Yaw, self.LaggedYaw)
    self.LaggedYaw = normalizeAngle(self.LaggedYaw + yawDiff * rotAlpha)
    self.LaggedRoll = self.LaggedRoll + (self.Roll - self.LaggedRoll) * rotAlpha

    evalPitch = self.LaggedPitch
    evalYaw = self.LaggedYaw
    evalRoll = self.LaggedRoll
  else
    self.LaggedPitch = self.Pitch
    self.LaggedYaw = self.Yaw
    self.LaggedRoll = self.Roll
  end

  -- 3. Rotation CFrame calculation
  local rotCFrame = CFrame.Angles(0, math.rad(evalYaw), 0)
    * CFrame.Angles(math.rad(evalPitch), 0, 0)
    * CFrame.Angles(0, 0, math.rad(evalRoll))

  -- In Roblox coordinate space, negative Z is forward (look vector), positive Z is backward
  local backwardUnit = rotCFrame.LookVector * -1.0

  -- 4. Collision and Occlusion Test
  local desiredDistance = self.TargetArmLength
  local collisionOccurred = false

  if self.CollisionCallback ~= nil then
    local rayOrigin = self.LaggedPivot
    local rayDir = backwardUnit
    local queryDistance = self.TargetArmLength + self.ProbeRadius

    local hit, hitPos, hitNorm = self.CollisionCallback(
      rayOrigin,
      rayDir,
      queryDistance,
      self.ProbeRadius
    )

    if hit and hitPos ~= nil then
      local hitDist = (hitPos - rayOrigin).Magnitude
      local allowedDist = math.max(self.MinArmLength, hitDist - self.ProbeRadius)
      if allowedDist < desiredDistance then
        desiredDistance = allowedDist
        collisionOccurred = true
      end
    end
  end

  self.IsObstructed = collisionOccurred

  -- 5. Asymmetric Arm Length Smoothing
  -- Rapid pullback when obstructed to prevent camera wall-clipping; smooth damped recovery when clearing
  if desiredDistance < self.CurrentArmLength then
    local pullAlpha = 1.0 - math.exp(-self.PullbackSpeed * effectiveDt)
    self.CurrentArmLength = self.CurrentArmLength + (desiredDistance - self.CurrentArmLength) * pullAlpha
  else
    local returnAlpha = 1.0 - math.exp(-self.ReturnSpeed * effectiveDt)
    self.CurrentArmLength = self.CurrentArmLength + (desiredDistance - self.CurrentArmLength) * returnAlpha
  end

  self.CurrentArmLength = math.clamp(self.CurrentArmLength, self.MinArmLength, self.MaxArmLength)

  -- 6. Final Camera Placement
  local boomOffset = backwardUnit * self.CurrentArmLength
  local worldSocketOffset = rotCFrame:VectorToWorldSpace(self.SocketOffset)
  local finalPosition = self.LaggedPivot + boomOffset + worldSocketOffset

  local finalCFrame = CFrame.new(finalPosition) * rotCFrame

  return finalCFrame, self.CurrentArmLength, self.IsObstructed
end

return ThirdPersonSpringArm