--!strict
--[[
  CombatPredictor.luau
  Client-side predictive hit detection controller with local lag estimation.
  Part of crustdev studio game systems (Aetheria: Fractured Realms).
]]

export type LocalHitForecast = {
  TargetId: number,
  PredictedOrigin: Vector3,
  PredictedDirection: Vector3,
  LocalClock: number,
  Confirmed: boolean,
}

local CombatPredictor = {}
CombatPredictor.__index = CombatPredictor

function CombatPredictor.new(): CombatPredictorInstance
  local self = setmetatable({}, CombatPredictor)
  self.PendingForecasts = {} :: { [number]: LocalHitForecast }
  self.SequenceCounter = 0
  self.EstimatedPing = 0.05 -- 50ms default estimate
  return self
end

export type CombatPredictorInstance = typeof(setmetatable({} :: {
  PendingForecasts: { [number]: LocalHitForecast },
  SequenceCounter: number,
  EstimatedPing: number,
}, CombatPredictor))

-- Update client round-trip time estimator using exponential moving average
function CombatPredictor:UpdateRTT(sampleRttSeconds: number): ()
  local alpha = 0.15
  self.EstimatedPing = (1 - alpha) * self.EstimatedPing + alpha * (sampleRttSeconds / 2.0)
end

-- Generate client predicted strike
function CombatPredictor:PredictHit(
  targetId: number,
  characterOrigin: Vector3,
  aimDirection: Vector3,
  weaponId: string
): (number, any)
  self.SequenceCounter += 1
  local seq = self.SequenceCounter

  local forecast: LocalHitForecast = {
    TargetId = targetId,
    PredictedOrigin = characterOrigin,
    PredictedDirection = aimDirection.Unit,
    LocalClock = os.clock(),
    Confirmed = false,
  }

  self.PendingForecasts[seq] = forecast

  local payload = {
    Header = {
      Sequence = seq,
      Timestamp = os.clock(),
      Channel = "CombatPrimary",
    },
    TargetId = targetId,
    ClientOrigin = characterOrigin,
    HitDirection = aimDirection.Unit,
    WeaponId = weaponId,
    ClientEstimatedLag = self.EstimatedPing,
  }

  return seq, payload
end

-- Server acknowledgement reconciliation
function CombatPredictor:HandleServerAcknowledge(sequence: number, approved: boolean, serverClock: number): ()
  local forecast = self.PendingForecasts[sequence]
  if not forecast then
    return
  end

  if approved then
    forecast.Confirmed = true
  end

  -- Clean up forecast record
  self.PendingForecasts[sequence] = nil
end

return CombatPredictor
