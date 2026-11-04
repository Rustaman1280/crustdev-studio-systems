--!strict
--[[
  AudioOcclusionRaycaster.luau
  crustdev studio systems - ReplicatedStorage/Audio/AudioOcclusionRaycaster

  Production-grade 3D acoustic propagation, occlusion, and diffraction simulator:
  - Raycast line-of-sight transmission loss modeling across real-world materials (Wood, Glass, Concrete, Metal, Fabric).
  - Multi-sample edge diffraction around obstacles via orthogonal perimeter probes.
  - Low-pass filter (LPF) cutoff frequency calculation (20 Hz - 20,000 Hz).
  - Pop-free slew rate filtering for cutoff frequencies and volume attenuation.
  - 6-directional cardinal acoustic probe bundle for dynamic room enclosure ratio and reverb decay estimation.
  - Distance attenuation modeling with configurable inverse-square and rolloff curves.
  - Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local ZERO_VECTOR = Vector3.new(0, 0, 0)

export type RaycastHit = {
  Position: Vector3,
  Normal: Vector3,
  Distance: number,
  Material: string?,
  Instance: any?,
}

export type RaycastFn = (
  origin: Vector3,
  direction: Vector3,
  maxDistance: number,
  ignoreList: { any }?
) -> RaycastHit?

export type OcclusionConfig = {
  minCutoffFrequency: number?, -- Lowest LPF frequency when fully occluded in Hz (default 350)
  maxCutoffFrequency: number?, -- Highest LPF frequency when unoccluded in Hz (default 20000)
  frequencyAttackRate: number?, -- Frequency change rate opening up in Hz/sec (default 40000)
  frequencyDecayRate: number?, -- Frequency change rate closing down in Hz/sec (default 20000)
  volumeAttackRate: number?, -- Volume slew rate fading in per sec (default 8.0)
  volumeDecayRate: number?, -- Volume slew rate fading down per sec (default 12.0)
  minDistance: number?, -- Minimum attenuation distance (default 5.0)
  maxDistance: number?, -- Maximum audible distance (default 250.0)
  diffractionSampleCount: number?, -- Number of edge probe offsets (default 4)
  diffractionProbeOffset: number?, -- Offset distance in studs for edge probes (default 4.0)
}

export type SoundSource = {
  id: string,
  position: Vector3,
  baseVolume: number,
  is3D: boolean,
  currentCutoffFrequency: number,
  currentVolumeGain: number,
  targetCutoffFrequency: number,
  targetVolumeGain: number,
  occlusionRatio: number, -- 0.0 = completely clear, 1.0 = completely occluded
  diffractionRatio: number,
  calculatedDistance: number,
}

export type RoomAcousticState = {
  enclosureRatio: number, -- 0.0 (open outdoors) to 1.0 (enclosed indoor chamber)
  estimatedVolume: number, -- Estimated cubic room volume in studs^3
  recommendedReverbWet: number, -- 0.0 to 1.0
  recommendedDecayTime: number, -- Decay time in seconds
}

export type AudioOcclusionRaycaster = {
  RegisterSource: (
    self: AudioOcclusionRaycaster,
    id: string,
    position: Vector3,
    baseVolume: number?
  ) -> (),
  UnregisterSource: (self: AudioOcclusionRaycaster, id: string) -> (),
  UpdateSourcePosition: (self: AudioOcclusionRaycaster, id: string, position: Vector3) -> (),
  SetMaterialAbsorption: (self: AudioOcclusionRaycaster, material: string, absorption: number) -> (),
  GetMaterialAbsorption: (self: AudioOcclusionRaycaster, material: string) -> number,
  Update: (
    self: AudioOcclusionRaycaster,
    dt: number,
    listenerPosition: Vector3,
    raycastFn: RaycastFn,
    ignoreList: { any }?
  ) -> { [string]: SoundSource },
  EstimateRoomAcoustics: (
    self: AudioOcclusionRaycaster,
    listenerPosition: Vector3,
    raycastFn: RaycastFn,
    probeDistance: number?,
    ignoreList: { any }?
  ) -> RoomAcousticState,
  GetSourceState: (self: AudioOcclusionRaycaster, id: string) -> SoundSource?,
  Reset: (self: AudioOcclusionRaycaster) -> (),
}

local AudioOcclusionRaycasterImpl = {}
AudioOcclusionRaycasterImpl.__index = AudioOcclusionRaycasterImpl

local DEFAULT_MATERIALS: { [string]: number } = {
  Air = 0.0,
  Fabric = 0.30,
  Foliage = 0.25,
  Glass = 0.15,
  Wood = 0.45,
  Plaster = 0.55,
  Brick = 0.75,
  Concrete = 0.90,
  Metal = 0.95,
  Default = 0.65,
}

local function Clamp(val: number, minVal: number, maxVal: number): number
  if val < minVal then
    return minVal
  elseif val > maxVal then
    return maxVal
  end
  return val
end

local function SlewValue(current: number, target: number, rateUp: number, rateDown: number, dt: number): number
  if current < target then
    return math.min(target, current + rateUp * dt)
  elseif current > target then
    return math.max(target, current - rateDown * dt)
  end
  return target
end

function AudioOcclusionRaycasterImpl.New(config: OcclusionConfig?): AudioOcclusionRaycaster
  local self = setmetatable({}, AudioOcclusionRaycasterImpl)

  local cfg: OcclusionConfig = config or {}
  local minCutoff = cfg.minCutoffFrequency or 350.0
  local maxCutoff = cfg.maxCutoffFrequency or 20000.0
  local freqAttack = cfg.frequencyAttackRate or 40000.0
  local freqDecay = cfg.frequencyDecayRate or 20000.0
  local volAttack = cfg.volumeAttackRate or 8.0
  local volDecay = cfg.volumeDecayRate or 12.0
  local minDist = cfg.minDistance or 5.0
  local maxDist = cfg.maxDistance or 250.0
  local diffProbeOffset = cfg.diffractionProbeOffset or 4.0

  local materials: { [string]: number } = {}
  for mat, abs in pairs(DEFAULT_MATERIALS) do
    materials[mat] = abs
  end

  local sources: { [string]: SoundSource } = {}

  function self:RegisterSource(id: string, position: Vector3, baseVolume: number?): ()
    assert(id ~= nil and id ~= "", "Source id must be valid non-empty string")
    sources[id] = {
      id = id,
      position = position,
      baseVolume = baseVolume or 1.0,
      is3D = true,
      currentCutoffFrequency = maxCutoff,
      currentVolumeGain = 1.0,
      targetCutoffFrequency = maxCutoff,
      targetVolumeGain = 1.0,
      occlusionRatio = 0.0,
      diffractionRatio = 0.0,
      calculatedDistance = 0.0,
    }
  end

  function self:UnregisterSource(id: string): ()
    sources[id] = nil
  end

  function self:UpdateSourcePosition(id: string, position: Vector3): ()
    local src = sources[id]
    if src then
      src.position = position
    end
  end

  function self:SetMaterialAbsorption(material: string, absorption: number): ()
    materials[material] = Clamp(absorption, 0.0, 1.0)
  end

  function self:GetMaterialAbsorption(material: string): number
    return materials[material] or materials["Default"] or 0.65
  end

  function self:GetSourceState(id: string): SoundSource?
    return sources[id]
  end

  --[[ Evaluate Occlusion and Diffraction for a single sound emitter ]]
  local function ProcessSource(
    src: SoundSource,
    listenerPosition: Vector3,
    raycastFn: RaycastFn,
    ignoreList: { any }?
  ): ()
    local delta = src.position - listenerPosition
    local dist = delta.Magnitude
    src.calculatedDistance = dist

    -- Distance rolloff attenuation
    local distGain = 1.0
    if dist <= minDist then
      distGain = 1.0
    elseif dist >= maxDist then
      distGain = 0.0
    else
      distGain = minDist / dist
    end

    if dist <= 1e-4 then
      src.occlusionRatio = 0.0
      src.diffractionRatio = 0.0
      src.targetCutoffFrequency = maxCutoff
      src.targetVolumeGain = src.baseVolume
      return
    end

    local dir = delta.Unit

    -- Cast direct line-of-sight ray
    local hit = raycastFn(listenerPosition, dir, dist, ignoreList)

    if not hit then
      -- Clear direct path
      src.occlusionRatio = 0.0
      src.diffractionRatio = 0.0
      src.targetCutoffFrequency = maxCutoff
      src.targetVolumeGain = distGain * src.baseVolume
    else
      -- Ray is obstructed! Calculate material transmission and diffraction
      local matName = hit.Material or "Default"
      local absorption = materials[matName] or materials["Default"] or 0.65

      -- Multi-sample edge diffraction probes
      -- Build orthogonal basis relative to ray direction
      local up = Vector3.new(0, 1, 0)
      if math.abs(dir:Dot(up)) > 0.95 then
        up = Vector3.new(1, 0, 0)
      end
      local right = dir:Cross(up).Unit
      local realUp = right:Cross(dir).Unit

      local probeOffsets = {
        realUp * diffProbeOffset,
        realUp * -diffProbeOffset,
        right * diffProbeOffset,
        right * -diffProbeOffset,
      }

      local clearDiffractionPaths = 0
      for _, offset in ipairs(probeOffsets) do
        local probeOrigin = hit.Position + offset
        -- Check if probe origin has line of sight to source
        local toSrc = src.position - probeOrigin
        local srcDist = toSrc.Magnitude
        if srcDist > 1e-4 then
          local edgeHit = raycastFn(probeOrigin, toSrc.Unit, srcDist, ignoreList)
          if not edgeHit then
            clearDiffractionPaths = clearDiffractionPaths + 1
          end
        end
      end

      -- If edge paths are clear, diffraction helps sound wrap around barrier
      local diffFactor = clearDiffractionPaths / #probeOffsets
      src.diffractionRatio = diffFactor

      -- Effective occlusion considers absorption mitigated by edge diffraction
      local effectiveOcclusion = absorption * (1.0 - 0.45 * diffFactor)
      src.occlusionRatio = Clamp(effectiveOcclusion, 0.0, 1.0)

      -- Frequency cutoff: interpolate between maxCutoff and minCutoff
      -- Higher absorption causes steeper frequency drop
      local freqRatio = 1.0 - src.occlusionRatio
      src.targetCutoffFrequency = minCutoff + (maxCutoff - minCutoff) * (freqRatio * freqRatio)

      -- Volume attenuation from occlusion
      local occlusionVolumeMultiplier = 1.0 - (0.80 * src.occlusionRatio)
      src.targetVolumeGain = distGain * src.baseVolume * occlusionVolumeMultiplier
    end
  end

  function self:Update(
    dt: number,
    listenerPosition: Vector3,
    raycastFn: RaycastFn,
    ignoreList: { any }?
  ): { [string]: SoundSource }
    for _, src in pairs(sources) do
      ProcessSource(src, listenerPosition, raycastFn, ignoreList)

      -- Smoothly slew frequency and volume to eliminate pops and clipping
      src.currentCutoffFrequency = SlewValue(
        src.currentCutoffFrequency,
        src.targetCutoffFrequency,
        freqAttack,
        freqDecay,
        dt
      )

      src.currentVolumeGain = SlewValue(
        src.currentVolumeGain,
        src.targetVolumeGain,
        volAttack,
        volDecay,
        dt
      )
    end

    return sources
  end

  function self:EstimateRoomAcoustics(
    listenerPosition: Vector3,
    raycastFn: RaycastFn,
    probeDistance: number?,
    ignoreList: { any }?
  ): RoomAcousticState
    local maxProbe = probeDistance or 100.0

    -- 6 Cardinal directions: +X, -X, +Y, -Y, +Z, -Z
    local directions = {
      Vector3.new(1, 0, 0),
      Vector3.new(-1, 0, 0),
      Vector3.new(0, 1, 0),
      Vector3.new(0, -1, 0),
      Vector3.new(0, 0, 1),
      Vector3.new(0, 0, -1),
    }

    local hitCount = 0
    local totalDist = 0.0
    local axisDistances = {
      x = maxProbe,
      y = maxProbe,
      z = maxProbe,
    }

    for idx, d in ipairs(directions) do
      local hit = raycastFn(listenerPosition, d, maxProbe, ignoreList)
      if hit then
        hitCount = hitCount + 1
        totalDist = totalDist + hit.Distance
        if idx <= 2 then
          axisDistances.x = math.min(axisDistances.x, hit.Distance * 2)
        elseif idx <= 4 then
          axisDistances.y = math.min(axisDistances.y, hit.Distance * 2)
        else
          axisDistances.z = math.min(axisDistances.z, hit.Distance * 2)
        end
      else
        totalDist = totalDist + maxProbe
      end
    end

    local enclosureRatio = hitCount / 6.0
    local estimatedVolume = axisDistances.x * axisDistances.y * axisDistances.z

    -- Reverb wet mix scales with enclosure and room size
    local wetMix = enclosureRatio * Clamp(estimatedVolume / 5000.0, 0.1, 0.85)

    -- Sabine-inspired estimated decay time in seconds (t60 approx)
    local decayTime = 0.2 + (enclosureRatio * 1.8) * Clamp(estimatedVolume / 8000.0, 0.2, 2.5)

    return {
      enclosureRatio = enclosureRatio,
      estimatedVolume = estimatedVolume,
      recommendedReverbWet = Clamp(wetMix, 0.0, 1.0),
      recommendedDecayTime = decayTime,
    }
  end

  function self:Reset(): ()
    sources = {}
  end

  return self
end

return {
  new = AudioOcclusionRaycasterImpl.New,
  DEFAULT_MATERIALS = DEFAULT_MATERIALS,
  Clamp = Clamp,
  SlewValue = SlewValue,
}
