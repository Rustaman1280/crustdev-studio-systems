--!strict
--[[
  AdaptiveSoundtrackManager.luau
  Dynamic multi-stem audio director and adaptive acoustic manager.
  Bridges crustdev studio game engines with crustdev records stem productions.
  Features:
    - Multi-stem track layering (Ambient, Rhythm, Bass, Lead, Accent).
    - Continuous intensity slew interpolation with distinct attack and decay rates.
    - Stem gain curves (linear, quadratic, or exponential crossfading).
    - Beat and bar quantization calculation for rhythmic downbeat transitions.
    - Dynamic priority-based ducking channel (dialogue, explosions, critical UI).
    - Raycast acoustic occlusion filter calculation (low-pass frequency cutoff).
]]

export type GainCurve = "Linear" | "Quadratic" | "Exponential"

export type StemConfig = {
  Name: string,
  MinIntensity: number,       -- Threshold [0.0 - 1.0] where stem begins to fade in
  PeakIntensity: number,      -- Threshold [0.0 - 1.0] where stem reaches max volume
  MaxVolume: number,          -- Maximum volume scalar [0.0 - 1.0] (default 1.0)
  Curve: GainCurve?,          -- Volume curve shape (default "Linear")
}

export type TrackMetadata = {
  TrackId: string,
  Bpm: number,                -- Beats per minute (e.g. 128.0)
  TimeSignature: number,      -- Beats per bar (e.g. 4 for 4/4)
  Stems: { [string]: StemConfig },
}

export type DuckingProfile = {
  TargetGain: number,         -- Target attenuation gain (e.g. 0.25)
  AttackTime: number,         -- Fade-down duration in seconds
  HoldTime: number,           -- Duration at reduced gain in seconds
  ReleaseTime: number,        -- Fade-up duration in seconds
}

export type AdaptiveSoundtrackState = {
  CurrentIntensity: number,
  SmoothedIntensity: number,
  StemGains: { [string]: number },
  MasterVolume: number,
  DuckingGain: number,
  CutoffFrequency: number,    -- LPF Cutoff frequency in Hz (250 to 20000)
}

export type AdaptiveSoundtrackManager = {
  SetTrack: (self: AdaptiveSoundtrackManager, track: TrackMetadata) -> (),
  SetTargetIntensity: (self: AdaptiveSoundtrackManager, intensity: number) -> (),
  SetMasterVolume: (self: AdaptiveSoundtrackManager, volume: number) -> (),
  TriggerDucking: (self: AdaptiveSoundtrackManager, profile: DuckingProfile) -> (),
  SetOcclusion: (self: AdaptiveSoundtrackManager, obstacleCount: number, averageDensity: number) -> (),
  Update: (self: AdaptiveSoundtrackManager, dt: number) -> AdaptiveSoundtrackState,
  GetNextQuantizedTime: (self: AdaptiveSoundtrackManager, currentTime: number, quantizeType: "Beat" | "Bar") -> number,
  GetState: (self: AdaptiveSoundtrackManager) -> AdaptiveSoundtrackState,
}

type DuckingPhase = "Idle" | "Attack" | "Hold" | "Release"

type InternalManager = AdaptiveSoundtrackManager & {
  _track: TrackMetadata?,
  _targetIntensity: number,
  _smoothedIntensity: number,
  _attackRate: number,
  _decayRate: number,
  _masterVolume: number,
  _duckingProfile: DuckingProfile?,
  _duckingPhase: DuckingPhase,
  _duckingTimer: number,
  _duckingGain: number,
  _cutoffFrequency: number,
  _stemGains: { [string]: number },
}

local AdaptiveSoundtrackManager = {}
AdaptiveSoundtrackManager.__index = AdaptiveSoundtrackManager

function AdaptiveSoundtrackManager.new(attackRate: number?, decayRate: number?): AdaptiveSoundtrackManager
  local self = setmetatable({
    _track = nil,
    _targetIntensity = 0.0,
    _smoothedIntensity = 0.0,
    _attackRate = attackRate or 0.8,
    _decayRate = decayRate or 0.4,
    _masterVolume = 1.0,
    _duckingProfile = nil,
    _duckingPhase = "Idle" :: DuckingPhase,
    _duckingTimer = 0.0,
    _duckingGain = 1.0,
    _cutoffFrequency = 20000.0,
    _stemGains = {},
  }, AdaptiveSoundtrackManager)

  return (self :: any) :: AdaptiveSoundtrackManager
end

function AdaptiveSoundtrackManager.SetTrack(self: AdaptiveSoundtrackManager, track: TrackMetadata)
  local internal = self :: InternalManager
  internal._track = track
  internal._stemGains = {}
  for stemName, _ in pairs(track.Stems) do
    internal._stemGains[stemName] = 0.0
  end
end

function AdaptiveSoundtrackManager.SetTargetIntensity(self: AdaptiveSoundtrackManager, intensity: number)
  local internal = self :: InternalManager
  internal._targetIntensity = math.clamp(intensity, 0.0, 1.0)
end

function AdaptiveSoundtrackManager.SetMasterVolume(self: AdaptiveSoundtrackManager, volume: number)
  local internal = self :: InternalManager
  internal._masterVolume = math.clamp(volume, 0.0, 1.0)
end

function AdaptiveSoundtrackManager.TriggerDucking(self: AdaptiveSoundtrackManager, profile: DuckingProfile)
  local internal = self :: InternalManager
  internal._duckingProfile = profile
  internal._duckingPhase = "Attack"
  internal._duckingTimer = 0.0
end

function AdaptiveSoundtrackManager.SetOcclusion(self: AdaptiveSoundtrackManager, obstacleCount: number, averageDensity: number)
  local internal = self :: InternalManager
  if obstacleCount <= 0 or averageDensity <= 0 then
    internal._cutoffFrequency = 20000.0
  else
    local attenuationFactor = obstacleCount * math.clamp(averageDensity, 0.1, 2.0)
    local calculatedCutoff = 20000.0 * math.exp(-0.85 * attenuationFactor)
    internal._cutoffFrequency = math.clamp(calculatedCutoff, 250.0, 20000.0)
  end
end

local function computeCurveGain(t: number, curve: GainCurve?): number
  local clampedT = math.clamp(t, 0.0, 1.0)
  if curve == "Quadratic" then
    return clampedT * clampedT
  elseif curve == "Exponential" then
    return (math.exp(clampedT * 2.0) - 1.0) / (math.exp(2.0) - 1.0)
  else
    return clampedT
  end
end

function AdaptiveSoundtrackManager.Update(self: AdaptiveSoundtrackManager, dt: number): AdaptiveSoundtrackState
  local internal = self :: InternalManager

  -- 1. Intensity slew rate filtering
  if internal._targetIntensity > internal._smoothedIntensity then
    internal._smoothedIntensity = math.min(
      internal._targetIntensity,
      internal._smoothedIntensity + internal._attackRate * dt
    )
  elseif internal._targetIntensity < internal._smoothedIntensity then
    internal._smoothedIntensity = math.max(
      internal._targetIntensity,
      internal._smoothedIntensity - internal._decayRate * dt
    )
  end

  -- 2. Ducking envelope state machine
  if internal._duckingProfile and internal._duckingPhase ~= "Idle" then
    local p = internal._duckingProfile
    internal._duckingTimer += dt

    if internal._duckingPhase == "Attack" then
      if p.AttackTime <= 0.001 then
        internal._duckingGain = p.TargetGain
        internal._duckingPhase = "Hold"
        internal._duckingTimer = 0.0
      else
        local progress = math.clamp(internal._duckingTimer / p.AttackTime, 0.0, 1.0)
        internal._duckingGain = 1.0 - (1.0 - p.TargetGain) * progress
        if progress >= 1.0 then
          internal._duckingPhase = "Hold"
          internal._duckingTimer = 0.0
        end
      end
    elseif internal._duckingPhase == "Hold" then
      internal._duckingGain = p.TargetGain
      if internal._duckingTimer >= p.HoldTime then
        internal._duckingPhase = "Release"
        internal._duckingTimer = 0.0
      end
    elseif internal._duckingPhase == "Release" then
      if p.ReleaseTime <= 0.001 then
        internal._duckingGain = 1.0
        internal._duckingPhase = "Idle"
        internal._duckingTimer = 0.0
      else
        local progress = math.clamp(internal._duckingTimer / p.ReleaseTime, 0.0, 1.0)
        internal._duckingGain = p.TargetGain + (1.0 - p.TargetGain) * progress
        if progress >= 1.0 then
          internal._duckingGain = 1.0
          internal._duckingPhase = "Idle"
          internal._duckingTimer = 0.0
        end
      end
    end
  else
    internal._duckingGain = 1.0
  end

  -- 3. Calculate stem gains based on smoothed intensity
  if internal._track then
    for stemName, stem in pairs(internal._track.Stems) do
      local rawGain = 0.0
      if internal._smoothedIntensity <= stem.MinIntensity then
        rawGain = 0.0
      elseif internal._smoothedIntensity >= stem.PeakIntensity then
        rawGain = stem.MaxVolume
      else
        local span = stem.PeakIntensity - stem.MinIntensity
        local t = if span > 0.0001 then (internal._smoothedIntensity - stem.MinIntensity) / span else 1.0
        rawGain = computeCurveGain(t, stem.Curve) * stem.MaxVolume
      end

      -- Modulate with ducking and master volume
      internal._stemGains[stemName] = rawGain * internal._duckingGain * internal._masterVolume
    end
  end

  return self:GetState()
end

function AdaptiveSoundtrackManager.GetNextQuantizedTime(
  self: AdaptiveSoundtrackManager,
  currentTime: number,
  quantizeType: "Beat" | "Bar"
): number
  local internal = self :: InternalManager
  local track = internal._track
  if not track or track.Bpm <= 0 then
    return currentTime
  end

  local secondsPerBeat = 60.0 / track.Bpm
  if quantizeType == "Beat" then
    local nextBeatIndex = math.ceil(currentTime / secondsPerBeat)
    return nextBeatIndex * secondsPerBeat
  else
    local secondsPerBar = secondsPerBeat * (track.TimeSignature or 4)
    local nextBarIndex = math.ceil(currentTime / secondsPerBar)
    return nextBarIndex * secondsPerBar
  end
end

function AdaptiveSoundtrackManager.GetState(self: AdaptiveSoundtrackManager): AdaptiveSoundtrackState
  local internal = self :: InternalManager
  local gainsCopy = {}
  for k, v in pairs(internal._stemGains) do
    gainsCopy[k] = v
  end

  return {
    CurrentIntensity = internal._targetIntensity,
    SmoothedIntensity = internal._smoothedIntensity,
    StemGains = gainsCopy,
    MasterVolume = internal._masterVolume,
    DuckingGain = internal._duckingGain,
    CutoffFrequency = internal._cutoffFrequency,
  }
end

return AdaptiveSoundtrackManager