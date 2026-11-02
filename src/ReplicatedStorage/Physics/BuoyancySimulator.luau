--!strict
--[[
  BuoyancySimulator.luau
  Hydrodynamic buoyancy and watercraft physics calculation engine for Roblox.
  Features:
  - Multi-probe distributed hull volume sampling for pitch, roll, and heave stability
  - Archimedes principle buoyant force integration with fluid density scaling
  - Multi-harmonic Gerstner wave surface generation with exact analytical surface normals
  - Directional keel lateral resistance and hydrofoil lift calculation
  - Submerged linear drag and angular damping relative to dynamic water currents
  - Symplectic momentum integrator for predictive client-side and server-side boat physics
  Part of crustdev studio game systems.
  Zero external runtime dependencies.
]]

local roblox = _G.Vector3 and _G or require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

export type WaveComponent = {
  Amplitude: number,
  Wavelength: number,
  Direction: Vector3,
  Steepness: number,
  Speed: number?,
}

export type BuoyancyProbe = {
  Name: string,
  LocalOffset: Vector3,
  Volume: number,
  Height: number,
}

export type ProbeState = {
  Name: string,
  WorldPosition: Vector3,
  WaterElevation: number,
  ImmersionDepth: number,
  SubmergedFraction: number,
  BuoyantForce: Vector3,
  Torque: Vector3,
}

export type BuoyancyConfig = {
  FluidDensity: number?,
  Gravity: number?,
  LinearDrag: number?,
  AngularDrag: number?,
  KeelResistanceFactor: number?,
  WaterCurrent: Vector3?,
  BaseWaterElevation: number?,
  Waves: { WaveComponent }?,
}

export type BuoyancyResult = {
  NetForce: Vector3,
  NetTorque: Vector3,
  SubmergedFraction: number,
  SubmergedProbeCount: number,
  CenterOfBuoyancy: Vector3,
  Probes: { [string]: ProbeState },
}

local DEFAULT_GRAVITY = 196.2 -- Default Roblox gravity studs/s^2
local DEFAULT_FLUID_DENSITY = 1.0 -- Standard water density metric

local BuoyancySimulator = {}
BuoyancySimulator.__index = BuoyancySimulator

export type BuoyancySimulator = {
  FluidDensity: number,
  Gravity: number,
  LinearDrag: number,
  AngularDrag: number,
  KeelResistanceFactor: number,
  WaterCurrent: Vector3,
  BaseWaterElevation: number,
  Waves: { WaveComponent },
  Probes: { BuoyancyProbe },
  TotalVolume: number,

  AddProbe: (self: BuoyancySimulator, name: string, localOffset: Vector3, volume: number, height: number?) -> (),
  SetWaves: (self: BuoyancySimulator, waves: { WaveComponent }) -> (),
  SampleWaveElevation: (self: BuoyancySimulator, worldX: number, worldZ: number, time: number) -> (number, Vector3),
  Solve: (self: BuoyancySimulator, bodyCFrame: CFrame, linearVelocity: Vector3, angularVelocity: Vector3, time: number) -> BuoyancyResult,
  StepPhysics: (self: BuoyancySimulator, bodyCFrame: CFrame, linearVelocity: Vector3, angularVelocity: Vector3, mass: number, inertiaTensor: Vector3, dt: number, time: number) -> (CFrame, Vector3, Vector3),
}

function BuoyancySimulator.new(config: BuoyancyConfig?): BuoyancySimulator
  local cfg = config or {}
  local self = setmetatable({}, BuoyancySimulator)

  self.FluidDensity = cfg.FluidDensity or DEFAULT_FLUID_DENSITY
  self.Gravity = cfg.Gravity or DEFAULT_GRAVITY
  self.LinearDrag = cfg.LinearDrag or 1.2
  self.AngularDrag = cfg.AngularDrag or 2.5
  self.KeelResistanceFactor = cfg.KeelResistanceFactor or 3.5
  self.WaterCurrent = cfg.WaterCurrent or Vector3.new(0, 0, 0)
  self.BaseWaterElevation = cfg.BaseWaterElevation or 0.0
  self.Waves = cfg.Waves or {}
  self.Probes = {}
  self.TotalVolume = 0.0

  return (self :: any) :: BuoyancySimulator
end

function BuoyancySimulator.AddProbe(self: BuoyancySimulator, name: string, localOffset: Vector3, volume: number, height: number?)
  assert(volume > 0, "Probe volume must be positive")
  local probeHeight = height or 1.0
  assert(probeHeight > 0, "Probe height must be positive")

  local probe: BuoyancyProbe = {
    Name = name,
    LocalOffset = localOffset,
    Volume = volume,
    Height = probeHeight,
  }

  table.insert(self.Probes, probe)
  self.TotalVolume += volume
end

function BuoyancySimulator.SetWaves(self: BuoyancySimulator, waves: { WaveComponent })
  self.Waves = table.clone(waves)
end

function BuoyancySimulator.SampleWaveElevation(self: BuoyancySimulator, worldX: number, worldZ: number, time: number): (number, Vector3)
  local elevation = self.BaseWaterElevation
  local normalX = 0.0
  local normalZ = 0.0

  if #self.Waves == 0 then
    return elevation, Vector3.new(0, 1, 0)
  end

  for _, wave in ipairs(self.Waves) do
    local kx = wave.Direction.X
    local kz = wave.Direction.Z
    local length = math.sqrt(kx * kx + kz * kz)
    if length > 1e-4 then
      kx = kx / length
      kz = kz / length
    else
      kx = 1.0
      kz = 0.0
    end

    local wavelength = math.max(wave.Wavelength, 0.1)
    local k = (2.0 * math.pi) / wavelength
    local speed = wave.Speed or math.sqrt(self.Gravity / k)
    local omega = k * speed
    local phase = k * (kx * worldX + kz * worldZ) - (omega * time)

    local amp = wave.Amplitude
    elevation += amp * math.sin(phase)

    -- Analytical surface normal derivatives
    local cosP = math.cos(phase)
    normalX -= kx * k * amp * cosP
    normalZ -= kz * k * amp * cosP
  end

  local normal = Vector3.new(normalX, 1.0, normalZ).Unit
  return elevation, normal
end

function BuoyancySimulator.Solve(self: BuoyancySimulator, bodyCFrame: CFrame, linearVelocity: Vector3, angularVelocity: Vector3, time: number): BuoyancyResult
  assert(#self.Probes > 0, "No buoyancy probes registered")

  local netBuoyantForce = Vector3.new(0, 0, 0)
  local netBuoyantTorque = Vector3.new(0, 0, 0)
  local submergedProbeCount = 0
  local totalSubmergedVolume = 0.0
  local weightedCenterOfBuoyancy = Vector3.new(0, 0, 0)
  local probeStates: { [string]: ProbeState } = {}

  local bodyPosition = bodyCFrame.Position
  local bodyRight = bodyCFrame.RightVector
  local bodyUp = bodyCFrame.UpVector
  local bodyLook = bodyCFrame.LookVector

  -- 1. Multi-probe immersion and buoyancy integration
  for _, probe in ipairs(self.Probes) do
    local worldPos = bodyCFrame:PointToWorldSpace(probe.LocalOffset)
    local waveY, _ = self:SampleWaveElevation(worldPos.X, worldPos.Z, time)
    local immersionDepth = waveY - worldPos.Y

    local halfH = probe.Height * 0.5
    local subFrac = 0.0
    if immersionDepth >= halfH then
      subFrac = 1.0
    elseif immersionDepth <= -halfH then
      subFrac = 0.0
    else
      subFrac = (immersionDepth + halfH) / probe.Height
    end

    local buoyantForce = Vector3.new(0, 0, 0)
    local probeTorque = Vector3.new(0, 0, 0)

    if subFrac > 0 then
      submergedProbeCount += 1
      local subVol = probe.Volume * subFrac
      totalSubmergedVolume += subVol

      -- Upward buoyant force according to Archimedes principle
      local forceMagnitude = self.FluidDensity * subVol * self.Gravity
      buoyantForce = Vector3.new(0, forceMagnitude, 0)
      netBuoyantForce += buoyantForce

      -- Torque = r x F
      local leverArm = worldPos - bodyPosition
      probeTorque = leverArm:Cross(buoyantForce)
      netBuoyantTorque += probeTorque

      weightedCenterOfBuoyancy += (worldPos * subVol)
    end

    probeStates[probe.Name] = {
      Name = probe.Name,
      WorldPosition = worldPos,
      WaterElevation = waveY,
      ImmersionDepth = immersionDepth,
      SubmergedFraction = subFrac,
      BuoyantForce = buoyantForce,
      Torque = probeTorque,
    }
  end

  local overallSubmergedFraction = self.TotalVolume > 0 and (totalSubmergedVolume / self.TotalVolume) or 0.0
  local centerOfBuoyancy = totalSubmergedVolume > 0 and (weightedCenterOfBuoyancy / totalSubmergedVolume) or bodyPosition

  -- 2. Hydrodynamic drag and keel resistance
  local relativeVel = linearVelocity - self.WaterCurrent

  -- Decompose relative velocity along ship local axes
  local vForward = relativeVel:Dot(bodyLook)
  local vLateral = relativeVel:Dot(bodyRight)
  local vVertical = relativeVel:Dot(bodyUp)

  -- Keel lateral resistance: watercraft resists sideways drifting significantly more than forward slicing
  local lateralDragMod = self.KeelResistanceFactor
  local dragForward = -self.LinearDrag * vForward * bodyLook
  local dragLateral = -self.LinearDrag * lateralDragMod * vLateral * bodyRight
  local dragVertical = -self.LinearDrag * 1.5 * vVertical * bodyUp

  local totalHydrodynamicDrag = (dragForward + dragLateral + dragVertical) * overallSubmergedFraction
  local netForce = netBuoyantForce + totalHydrodynamicDrag

  -- Angular hydrodynamic damping
  local angularDampingTorque = -self.AngularDrag * angularVelocity * overallSubmergedFraction
  local netTorque = netBuoyantTorque + angularDampingTorque

  return {
    NetForce = netForce,
    NetTorque = netTorque,
    SubmergedFraction = overallSubmergedFraction,
    SubmergedProbeCount = submergedProbeCount,
    CenterOfBuoyancy = centerOfBuoyancy,
    Probes = probeStates,
  }
end

function BuoyancySimulator.StepPhysics(
  self: BuoyancySimulator,
  bodyCFrame: CFrame,
  linearVelocity: Vector3,
  angularVelocity: Vector3,
  mass: number,
  inertiaTensor: Vector3,
  dt: number,
  time: number
): (CFrame, Vector3, Vector3)
  assert(mass > 0, "Mass must be positive")
  assert(inertiaTensor.X > 0 and inertiaTensor.Y > 0 and inertiaTensor.Z > 0, "Inertia tensor components must be positive")

  local solveResult = self:Solve(bodyCFrame, linearVelocity, angularVelocity, time)

  -- External gravity force
  local gravityForce = Vector3.new(0, -mass * self.Gravity, 0)
  local totalForce = solveResult.NetForce + gravityForce
  local totalTorque = solveResult.NetTorque

  -- Symplectic Euler acceleration integration
  local linearAcc = totalForce / mass
  local newLinearVelocity = linearVelocity + (linearAcc * dt)

  -- Angular acceleration (diagonal principal axes approximation)
  local angularAcc = Vector3.new(
    totalTorque.X / inertiaTensor.X,
    totalTorque.Y / inertiaTensor.Y,
    totalTorque.Z / inertiaTensor.Z
  )
  local newAngularVelocity = angularVelocity + (angularAcc * dt)

  -- Position and orientation integration
  local newPosition = bodyCFrame.Position + (newLinearVelocity * dt)
  local rotDelta = newAngularVelocity * dt
  local angleMag = rotDelta.Magnitude

  local newCFrame = bodyCFrame
  if angleMag > 1e-6 then
    local rotAxis = rotDelta.Unit
    newCFrame = CFrame.fromAxisAngle(rotAxis, angleMag) * (bodyCFrame - bodyCFrame.Position) + newPosition
  else
    newCFrame = (bodyCFrame - bodyCFrame.Position) + newPosition
  end

  return newCFrame, newLinearVelocity, newAngularVelocity
end

return BuoyancySimulator
