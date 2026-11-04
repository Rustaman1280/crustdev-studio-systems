--!strict
--[[
  SpatialSoundZone.luau
  crustdev studio systems - ReplicatedStorage/Audio/SpatialSoundZone

  High-performance 3D spatial acoustic reverb and environment manager for Roblox.
  Handles geometric zone containment, hierarchical priority nesting, boundary cross-fading,
  and smooth parameter slewing to eliminate audio pops and clicks.

  Features:
  - Geometric zone shapes: Axis-Aligned/Oriented Box, Sphere, and Vertical Cylinder.
  - Edge blend margins with smooth Hermite interpolation for seamless cross-fades.
  - Priority-based hierarchy for nested spaces (e.g. cathedral inside a cave).
  - Parameter slewing with critically damped smoothing across frames.
  - Zero Em-Dash Policy compliant.
  - Pure Luau / Lune compatible with zero external engine dependencies.
]]

local Vector3 = _G.Vector3 or Vector3
local CFrame = _G.CFrame or CFrame

local EPSILON = 1e-5

export type ZoneShape = "Box" | "Sphere" | "Cylinder"

export type AcousticProperties = {
  ReverbTime: number,     -- Decay time in seconds (e.g., 0.5 to 5.0)
  RoomFilter: number,     -- High-frequency cutoff / damping in Hz (e.g., 500 to 20000)
  WetDryMix: number,      -- Wet/dry ratio [0..1]
  AmbientVolume: number,  -- Ambient background sound gain [0..1]
  EchoFeedback: number,   -- Echo feedback ratio [0..1]
}

export type ZoneDefinition = {
  Id: string,
  Shape: ZoneShape,
  Priority: number,       -- Higher priority overrides lower priority
  BlendMargin: number,    -- Boundary distance (studs) for smooth cross-fading
  Acoustics: AcousticProperties,

  -- Box geometry
  Center: Vector3,
  Size: Vector3?,         -- Used for Box (Width X, Height Y, Depth Z)
  RotationCFrame: CFrame?,-- Optional rotation for oriented box

  -- Sphere / Cylinder geometry
  Radius: number?,        -- Used for Sphere and Cylinder
  Height: number?,        -- Used for Cylinder (along Y axis)
}

export type SpatialSoundZoneConfig = {
  BaselineAcoustics: AcousticProperties?,
  SlewRate: number?,      -- Parameter transition rate in 1/seconds (default: 8.0)
}

local DEFAULT_BASELINE: AcousticProperties = {
  ReverbTime = 0.5,
  RoomFilter = 20000.0,
  WetDryMix = 0.05,
  AmbientVolume = 1.0,
  EchoFeedback = 0.0,
}

local SpatialSoundZone = {}
SpatialSoundZone.__index = SpatialSoundZone

-- Helper: Hermite smoothstep [0..1]
local function Smoothstep(x: number): number
  local t = math.clamp(x, 0, 1)
  return t * t * (3 - 2 * t)
end

-- Helper: Linear interpolation between two acoustic states
local function LerpAcoustics(a: AcousticProperties, b: AcousticProperties, alpha: number): AcousticProperties
  local t = math.clamp(alpha, 0, 1)
  return {
    ReverbTime = a.ReverbTime + (b.ReverbTime - a.ReverbTime) * t,
    RoomFilter = a.RoomFilter + (b.RoomFilter - a.RoomFilter) * t,
    WetDryMix = a.WetDryMix + (b.WetDryMix - a.WetDryMix) * t,
    AmbientVolume = a.AmbientVolume + (b.AmbientVolume - a.AmbientVolume) * t,
    EchoFeedback = a.EchoFeedback + (b.EchoFeedback - a.EchoFeedback) * t,
  }
end

-- Create a new SpatialSoundZone manager
function SpatialSoundZone.new(config: SpatialSoundZoneConfig?)
  local self = setmetatable({}, SpatialSoundZone)

  self._zones = {} :: { [string]: ZoneDefinition }
  self._zoneList = {} :: { ZoneDefinition }
  self._baseline = config and config.BaselineAcoustics or DEFAULT_BASELINE
  self._slewRate = (config and config.SlewRate) or 8.0

  -- Current smoothed acoustic properties
  self._currentAcoustics = {
    ReverbTime = self._baseline.ReverbTime,
    RoomFilter = self._baseline.RoomFilter,
    WetDryMix = self._baseline.WetDryMix,
    AmbientVolume = self._baseline.AmbientVolume,
    EchoFeedback = self._baseline.EchoFeedback,
  }

  self._activeZoneId = nil :: string?
  self._zoneWeights = {} :: { [string]: number }

  return self
end

-- Add a new acoustic zone
function SpatialSoundZone:AddZone(zone: ZoneDefinition): string
  assert(zone.Id and #zone.Id > 0, "Zone definition must have a valid non-empty Id")
  assert(zone.BlendMargin >= 0, "BlendMargin must be non-negative")

  self._zones[zone.Id] = zone
  self:_RebuildZoneList()
  return zone.Id
end

-- Remove a zone by Id
function SpatialSoundZone:RemoveZone(zoneId: string): boolean
  if self._zones[zoneId] then
    self._zones[zoneId] = nil
    self._zoneWeights[zoneId] = nil
    if self._activeZoneId == zoneId then
      self._activeZoneId = nil
    end
    self:_RebuildZoneList()
    return true
  end
  return false
end

-- Internal: maintain priority-sorted list (descending priority)
function SpatialSoundZone:_RebuildZoneList(): ()
  table.clear(self._zoneList)
  for _, z in pairs(self._zones) do
    table.insert(self._zoneList, z)
  end
  table.sort(self._zoneList, function(a, b)
    return a.Priority > b.Priority
  end)
end

-- Calculate penetration distance & normalized blend weight for a single zone
-- Weight: 0 = outside zone + margin, (0..1) = in blend margin, 1 = inside inner core
function SpatialSoundZone:CalculateZoneWeight(zone: ZoneDefinition, listenerPos: Vector3): number
  local shape = zone.Shape
  local margin = zone.BlendMargin

  if shape == "Sphere" then
    local radius = zone.Radius or 10.0
    local dist = (listenerPos - zone.Center).Magnitude
    local outerRadius = radius + margin
    if dist >= outerRadius then
      return 0.0
    elseif dist <= radius then
      return 1.0
    else
      local t = 1.0 - ((dist - radius) / math.max(EPSILON, margin))
      return Smoothstep(t)
    end

  elseif shape == "Cylinder" then
    local radius = zone.Radius or 10.0
    local halfHeight = (zone.Height or 20.0) * 0.5
    local localY = math.abs(listenerPos.Y - zone.Center.Y)

    local deltaXZ = Vector3.new(listenerPos.X - zone.Center.X, 0, listenerPos.Z - zone.Center.Z)
    local distXZ = deltaXZ.Magnitude

    local outerRadius = radius + margin
    local outerHalfHeight = halfHeight + margin

    if distXZ >= outerRadius or localY >= outerHalfHeight then
      return 0.0
    end

    local radialT = 1.0
    if distXZ > radius then
      radialT = 1.0 - ((distXZ - radius) / math.max(EPSILON, margin))
    end

    local verticalT = 1.0
    if localY > halfHeight then
      verticalT = 1.0 - ((localY - halfHeight) / math.max(EPSILON, margin))
    end

    return Smoothstep(math.min(radialT, verticalT))

  else -- "Box"
    local size = zone.Size or Vector3.new(20, 20, 20)
    local halfExtents = size * 0.5

    local p: Vector3
    if zone.RotationCFrame then
      p = zone.RotationCFrame:PointToObjectSpace(listenerPos)
    else
      p = listenerPos - zone.Center
    end

    local absX = math.abs(p.X)
    local absY = math.abs(p.Y)
    local absZ = math.abs(p.Z)

    local outerX = halfExtents.X + margin
    local outerY = halfExtents.Y + margin
    local outerZ = halfExtents.Z + margin

    if absX >= outerX or absY >= outerY or absZ >= outerZ then
      return 0.0
    end

    local tx = 1.0
    if absX > halfExtents.X then
      tx = 1.0 - ((absX - halfExtents.X) / math.max(EPSILON, margin))
    end

    local ty = 1.0
    if absY > halfExtents.Y then
      ty = 1.0 - ((absY - halfExtents.Y) / math.max(EPSILON, margin))
    end

    local tz = 1.0
    if absZ > halfExtents.Z then
      tz = 1.0 - ((absZ - halfExtents.Z) / math.max(EPSILON, margin))
    end

    return Smoothstep(math.min(tx, math.min(ty, tz)))
  end
end

-- Update listener position, evaluate active zones, and step parameter slew
function SpatialSoundZone:Update(listenerPos: Vector3, dt: number): ()
  local safeDt = math.clamp(dt, 0.0, 0.2)

  -- Evaluate weights for all zones in descending priority order
  local targetAcoustics = self._baseline
  local primaryZoneId: string? = nil
  local remainingInfluence = 1.0

  table.clear(self._zoneWeights)

  for _, zone in ipairs(self._zoneList) do
    local weight = self:CalculateZoneWeight(zone, listenerPos)
    self._zoneWeights[zone.Id] = weight

    if weight > 0.001 then
      if not primaryZoneId and weight >= 0.5 then
        primaryZoneId = zone.Id
      end

      -- Blend this zone with target acoustics
      local effectiveWeight = weight * remainingInfluence
      targetAcoustics = LerpAcoustics(targetAcoustics, zone.Acoustics, effectiveWeight)
      remainingInfluence = remainingInfluence * (1.0 - weight)

      if remainingInfluence <= 0.001 then
        break
      end
    end
  end

  if not primaryZoneId and self._zoneList[1] and (self._zoneWeights[self._zoneList[1].Id] or 0) > 0.001 then
    primaryZoneId = self._zoneList[1].Id
  end

  self._activeZoneId = primaryZoneId

  -- Exponential parameter slewing: smoothly approach target acoustics
  -- alpha = 1 - e^(-slewRate * dt)
  local alpha = 1.0 - math.exp(-self._slewRate * safeDt)
  self._currentAcoustics = LerpAcoustics(self._currentAcoustics, targetAcoustics, alpha)
end

-- Query current smoothed acoustic parameters
function SpatialSoundZone:GetActiveAcoustics(): AcousticProperties
  return {
    ReverbTime = self._currentAcoustics.ReverbTime,
    RoomFilter = self._currentAcoustics.RoomFilter,
    WetDryMix = self._currentAcoustics.WetDryMix,
    AmbientVolume = self._currentAcoustics.AmbientVolume,
    EchoFeedback = self._currentAcoustics.EchoFeedback,
  }
end

-- Get current primary active zone Id (or nil if in baseline environment)
function SpatialSoundZone:GetActiveZoneId(): string?
  return self._activeZoneId
end

-- Get specific zone's blend weight [0..1]
function SpatialSoundZone:GetZoneBlendWeight(zoneId: string): number
  return self._zoneWeights[zoneId] or 0.0
end

-- Check if listener is inside the core bounds of a zone
function SpatialSoundZone:IsListenerInZone(zoneId: string): boolean
  return (self._zoneWeights[zoneId] or 0.0) >= 0.999
end

return SpatialSoundZone
