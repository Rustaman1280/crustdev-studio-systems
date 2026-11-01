--!strict
--[[
  CameraSpring.luau
  crustdev studio systems - ReplicatedStorage/Camera/CameraSpring

  Closed-form analytical spring system and 6-DOF camera impulse controller:
  - Exact second-order harmonic oscillator ODE integration (critically damped, underdamped, overdamped)
  - Immune to variable frame-rate explosion, drift, or numerical instability
  - 3D positional and rotational spring solving for weapon recoil and viewmodel kick
  - Non-linear camera trauma system with cubic power falloff for explosions and impacts
  - FOV spring smoother for high-speed sprinting, dashing, and zoom transitions

  Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

export type SpringConfig = {
  frequency: number, -- Natural frequency in rad/s (speed of return, e.g. 15 to 30)
  dampingRatio: number, -- 1.0 = critical, < 1.0 = underdamped/bouncy, > 1.0 = overdamped
  traumaDecayRate: number?, -- Trauma dissipation per second (default 1.2)
  maxTraumaPitch: number?, -- Max angular kick in degrees (default 10)
  maxTraumaYaw: number?, -- Max angular kick in degrees (default 8)
  maxTraumaRoll: number?, -- Max angular kick in degrees (default 12)
}

export type CameraSpringInstance = {
  Position: Vector3,
  Velocity: Vector3,
  Target: Vector3,
  Config: SpringConfig,
  Trauma: number,
  TraumaTime: number,

  -- Scalar FOV spring state
  FovPosition: number,
  FovVelocity: number,
  FovTarget: number,

  SetTarget: (self: CameraSpringInstance, newTarget: Vector3) -> (),
  SetFovTarget: (self: CameraSpringInstance, newTargetFov: number) -> (),
  Impulse: (self: CameraSpringInstance, velocityKick: Vector3) -> (),
  ImpulseFov: (self: CameraSpringInstance, fovKick: number) -> (),
  AddTrauma: (self: CameraSpringInstance, amount: number) -> (),
  SnapTo: (self: CameraSpringInstance, position: Vector3) -> (),
  SnapFov: (self: CameraSpringInstance, fov: number) -> (),
  Step: (self: CameraSpringInstance, dt: number) -> (Vector3, number, Vector3),
  GetTraumaAngles: (self: CameraSpringInstance) -> Vector3,
  Reset: (self: CameraSpringInstance) -> (),
}

local CameraSpring = {}
CameraSpring.__index = CameraSpring

local EPSILON = 1e-5

local function solve1D(
  pos: number,
  vel: number,
  target: number,
  dt: number,
  omega: number,
  zeta: number
): (number, number)
  if dt <= 0 then
    return pos, vel
  end

  local x0 = pos - target
  local v0 = vel

  if math.abs(zeta - 1.0) < EPSILON then
    -- Critically damped: zeta == 1
    local expTerm = math.exp(-omega * dt)
    local c1 = x0
    local c2 = v0 + omega * x0
    local newX = (c1 + c2 * dt) * expTerm
    local newV = (c2 - omega * (c1 + c2 * dt)) * expTerm
    return target + newX, newV
  elseif zeta < 1.0 then
    -- Underdamped: zeta < 1
    local omegaD = omega * math.sqrt(1.0 - zeta * zeta)
    local expTerm = math.exp(-zeta * omega * dt)
    local cosTerm = math.cos(omegaD * dt)
    local sinTerm = math.sin(omegaD * dt)

    local c1 = x0
    local c2 = (v0 + zeta * omega * x0) / omegaD

    local newX = expTerm * (c1 * cosTerm + c2 * sinTerm)
    local newV = expTerm * (
      (-zeta * omega * (c1 * cosTerm + c2 * sinTerm))
      + (-c1 * omegaD * sinTerm + c2 * omegaD * cosTerm)
    )
    return target + newX, newV
  else
    -- Overdamped: zeta > 1
    local alpha = omega * math.sqrt(zeta * zeta - 1.0)
    local zOmega = zeta * omega
    local r1 = -zOmega + alpha
    local r2 = -zOmega - alpha

    local exp1 = math.exp(r1 * dt)
    local exp2 = math.exp(r2 * dt)

    -- Solve for constants c1 and c2: c1 + c2 = x0; r1*c1 + r2*c2 = v0
    local c2 = (v0 - r1 * x0) / (r2 - r1)
    local c1 = x0 - c2

    local newX = c1 * exp1 + c2 * exp2
    local newV = c1 * r1 * exp1 + c2 * r2 * exp2
    return target + newX, newV
  end
end

function CameraSpring.new(config: SpringConfig?): CameraSpringInstance
  local cfg: SpringConfig = config or {
    frequency = 25,
    dampingRatio = 1.0,
    traumaDecayRate = 1.2,
    maxTraumaPitch = 10,
    maxTraumaYaw = 8,
    maxTraumaRoll = 12,
  }

  local self = setmetatable({}, CameraSpring) :: any

  self.Position = Vector3.zero
  self.Velocity = Vector3.zero
  self.Target = Vector3.zero
  self.Config = cfg
  self.Trauma = 0
  self.TraumaTime = 0

  self.FovPosition = 70
  self.FovVelocity = 0
  self.FovTarget = 70

  return self
end

function CameraSpring:SetTarget(newTarget: Vector3)
  self.Target = newTarget
end

function CameraSpring:SetFovTarget(newTargetFov: number)
  self.FovTarget = newTargetFov
end

function CameraSpring:Impulse(velocityKick: Vector3)
  self.Velocity = self.Velocity + velocityKick
end

function CameraSpring:ImpulseFov(fovKick: number)
  self.FovVelocity = self.FovVelocity + fovKick
end

function CameraSpring:AddTrauma(amount: number)
  self.Trauma = math.clamp(self.Trauma + amount, 0, 1)
end

function CameraSpring:SnapTo(position: Vector3)
  self.Position = position
  self.Target = position
  self.Velocity = Vector3.zero
end

function CameraSpring:SnapFov(fov: number)
  self.FovPosition = fov
  self.FovTarget = fov
  self.FovVelocity = 0
end

function CameraSpring:GetTraumaAngles(): Vector3
  if self.Trauma <= 0 then
    return Vector3.zero
  end

  -- Non-linear cubic power curve for trauma perception
  local shake = self.Trauma * self.Trauma * self.Trauma
  local t = self.TraumaTime * 25

  -- Harmonics for smooth camera rotational shake
  local pitch = math.rad(self.Config.maxTraumaPitch or 10) * shake * math.sin(t * 1.3)
  local yaw = math.rad(self.Config.maxTraumaYaw or 8) * shake * math.cos(t * 1.7)
  local roll = math.rad(self.Config.maxTraumaRoll or 12) * shake * math.sin(t * 2.1)

  return Vector3.new(pitch, yaw, roll)
end

function CameraSpring:Step(dt: number): (Vector3, number, Vector3)
  local omega = math.max(0.01, self.Config.frequency)
  local zeta = math.max(0, self.Config.dampingRatio)

  -- 1. Advance Vector3 spring
  local px, vx = solve1D(self.Position.X, self.Velocity.X, self.Target.X, dt, omega, zeta)
  local py, vy = solve1D(self.Position.Y, self.Velocity.Y, self.Target.Y, dt, omega, zeta)
  local pz, vz = solve1D(self.Position.Z, self.Velocity.Z, self.Target.Z, dt, omega, zeta)

  self.Position = Vector3.new(px, py, pz)
  self.Velocity = Vector3.new(vx, vy, vz)

  -- 2. Advance scalar FOV spring
  local fovP, fovV = solve1D(self.FovPosition, self.FovVelocity, self.FovTarget, dt, omega, zeta)
  self.FovPosition = fovP
  self.FovVelocity = fovV

  -- 3. Dissipate camera trauma
  if self.Trauma > 0 then
    local decay = self.Config.traumaDecayRate or 1.2
    self.Trauma = math.max(0, self.Trauma - decay * dt)
    self.TraumaTime += dt
  else
    self.TraumaTime = 0
  end

  local traumaAngles = self:GetTraumaAngles()

  return self.Position, self.FovPosition, traumaAngles
end

function CameraSpring:Reset()
  self.Position = Vector3.zero
  self.Velocity = Vector3.zero
  self.Target = Vector3.zero
  self.Trauma = 0
  self.TraumaTime = 0
  self.FovPosition = 70
  self.FovVelocity = 0
  self.FovTarget = 70
end

return CameraSpring
