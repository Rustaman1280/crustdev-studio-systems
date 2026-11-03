--!strict
--[[
  PacejkaTireModel.luau
  Pacejka 'Magic Formula' tire slip, cornering dynamics, and friction circle engine.
  Engineered for crustdev studio racing physics (Neon Velocity Drift).

  Features:
  - Longitudinal tractive and braking force (Fx) vs slip ratio (kappa).
  - Lateral cornering force (Fy) vs slip angle (alpha) with camber thrust.
  - Coupled combined slip traction ellipse (friction circle limit enforcement).
  - Pneumatic trail decay and self-aligning torque (Mz) calculation for steering feedback.
  - First-order transient lag relaxation modeling to eliminate discrete force spikes.
  - Normal load sensitivity scaling (coefficient of friction reduction at high vertical load).
]]

export type PacejkaCoefficients = {
  B: number, -- Stiffness factor
  C: number, -- Shape factor
  D: number, -- Peak friction coefficient multiplier
  E: number, -- Curvature factor
}

export type TireConfig = {
  NominalLoad: number,          -- Normal load (Fz) in Newtons at baseline (default: 4000 N)
  PeakFrictionCoeff: number,    -- Base mu peak (default: 1.25)
  LoadSensitivity: number,      -- Coeff drop per Newton of excess load (default: 0.000035)
  Longitudinal: PacejkaCoefficients,
  Lateral: PacejkaCoefficients,
  CamberStiffness: number,      -- Force per radian per Newton of load (default: 0.015)
  PneumaticTrail: number,       -- Baseline pneumatic trail in meters (default: 0.038)
  RelaxationLength: number,     -- Tire carcass relaxation distance in meters (default: 0.18)
  MinVelocityThreshold: number, -- Low speed cutoff for slip singularity (default: 0.5 m/s)
}

export type TireState = {
  CurrentSlipRatio: number,  -- Filtered transient kappa
  CurrentSlipAngle: number,  -- Filtered transient alpha (radians)
  PneumaticTrail: number,    -- Instantaneous trail
  AligningTorque: number,    -- Mz in N*m
  LongitudinalForce: number, -- Fx in N
  LateralForce: number,      -- Fy in N
  ResultantGripRatio: number,-- Total force / Available max traction (0 to 1)
}

export type CombinedForceResult = {
  LongitudinalForce: number,
  LateralForce: number,
  AligningTorque: number,
  ResultantGripRatio: number,
  TotalForceMagnitude: number,
  MaxAvailableTraction: number,
}

local PacejkaTireModel = {}

local DEFAULT_CONFIG: TireConfig = {
  NominalLoad = 4000.0,
  PeakFrictionCoeff = 1.25,
  LoadSensitivity = 0.000035,
  Longitudinal = {
    B = 10.5,
    C = 1.65,
    D = 1.0,
    E = -0.5,
  },
  Lateral = {
    B = 9.2,
    C = 1.35,
    D = 1.0,
    E = -1.2,
  },
  CamberStiffness = 0.015,
  PneumaticTrail = 0.038,
  RelaxationLength = 0.18,
  MinVelocityThreshold = 0.5,
}

function PacejkaTireModel.CreateConfig(overrides: { [string]: any }?): TireConfig
  local cfg = table.clone(DEFAULT_CONFIG)
  cfg.Longitudinal = table.clone(DEFAULT_CONFIG.Longitudinal)
  cfg.Lateral = table.clone(DEFAULT_CONFIG.Lateral)

  if overrides then
    for k, v in pairs(overrides) do
      if k == "Longitudinal" and type(v) == "table" then
        for lk, lv in pairs(v) do
          (cfg.Longitudinal :: any)[lk] = lv
        end
      elseif k == "Lateral" and type(v) == "table" then
        for lk, lv in pairs(v) do
          (cfg.Lateral :: any)[lk] = lv
        end
      else
        (cfg :: any)[k] = v
      end
    end
  end

  return cfg
end

function PacejkaTireModel.CreateState(): TireState
  return {
    CurrentSlipRatio = 0.0,
    CurrentSlipAngle = 0.0,
    PneumaticTrail = 0.0,
    AligningTorque = 0.0,
    LongitudinalForce = 0.0,
    LateralForce = 0.0,
    ResultantGripRatio = 0.0,
  }
end

-- Core Pacejka Magic Formula curve evaluation:
-- F(slip) = D * sin( C * atan( B * slip - E * (B * slip - atan(B * slip)) ) )
local function EvaluateMagicFormula(slip: number, B: number, C: number, D: number, E: number): number
  local B_slip = B * slip
  local inner = B_slip - E * (B_slip - math.atan(B_slip))
  return D * math.sin(C * math.atan(inner))
end

-- Calculates effective friction coefficient taking normal load sensitivity into account
function PacejkaTireModel.ComputeEffectiveMu(config: TireConfig, normalLoad: number): number
  local clampedLoad = math.max(0, normalLoad)
  local loadDelta = clampedLoad - config.NominalLoad
  local mu = config.PeakFrictionCoeff * (1.0 - config.LoadSensitivity * loadDelta)
  return math.max(0.1, mu)
end

-- Pure longitudinal force calculation (Fx)
function PacejkaTireModel.ComputeLongitudinalForce(
  config: TireConfig,
  slipRatio: number,
  normalLoad: number
): number
  if normalLoad <= 1.0 then
    return 0.0
  end

  local mu = PacejkaTireModel.ComputeEffectiveMu(config, normalLoad)
  local D = mu * normalLoad * config.Longitudinal.D
  local force = EvaluateMagicFormula(
    slipRatio,
    config.Longitudinal.B,
    config.Longitudinal.C,
    D,
    config.Longitudinal.E
  )
  return force
end

-- Pure lateral cornering force calculation (Fy) including camber thrust
function PacejkaTireModel.ComputeLateralForce(
  config: TireConfig,
  slipAngle: number,
  normalLoad: number,
  camberAngleRad: number?
): number
  if normalLoad <= 1.0 then
    return 0.0
  end

  local mu = PacejkaTireModel.ComputeEffectiveMu(config, normalLoad)
  local D = mu * normalLoad * config.Lateral.D
  local corneringForce = EvaluateMagicFormula(
    slipAngle,
    config.Lateral.B,
    config.Lateral.C,
    D,
    config.Lateral.E
  )

  local camber = camberAngleRad or 0.0
  local camberThrust = config.CamberStiffness * camber * normalLoad

  return corneringForce + camberThrust
end

-- Pneumatic trail decay with slip angle: t(alpha) = t0 * cos(alpha) * (1 - tanh(3.5 * |alpha|))
function PacejkaTireModel.ComputePneumaticTrail(
  config: TireConfig,
  slipAngle: number
): number
  local absAlpha = math.abs(slipAngle)
  local trail = config.PneumaticTrail * math.cos(slipAngle) * (1.0 - math.tanh(3.5 * absAlpha))
  return math.max(0.0, trail)
end

-- Self-aligning torque Mz = -t * Fy
function PacejkaTireModel.ComputeSelfAligningTorque(
  config: TireConfig,
  lateralForce: number,
  slipAngle: number
): (number, number)
  local trail = PacejkaTireModel.ComputePneumaticTrail(config, slipAngle)
  local aligningTorque = -trail * lateralForce
  return aligningTorque, trail
end

-- Kinematic slip calculations from wheel velocity vectors
function PacejkaTireModel.CalculateSlipQuantities(
  config: TireConfig,
  wheelForwardSpeed: number,
  wheelLateralSpeed: number,
  wheelAngularVelocity: number,
  wheelEffectiveRadius: number
): (number, number)
  local absSpeed = math.abs(wheelForwardSpeed)
  local effectiveSpeed = math.max(absSpeed, config.MinVelocityThreshold)

  -- Slip ratio: kappa = (omega * r - Vx) / max(|Vx|, threshold)
  local linearWheelSpeed = wheelAngularVelocity * wheelEffectiveRadius
  local slipRatio = (linearWheelSpeed - wheelForwardSpeed) / effectiveSpeed
  slipRatio = math.clamp(slipRatio, -3.0, 3.0)

  -- Slip angle: alpha = -atan2(Vy, |Vx|)
  local slipAngle = -math.atan2(wheelLateralSpeed, effectiveSpeed)
  slipAngle = math.clamp(slipAngle, -math.pi / 2, math.pi / 2)

  return slipRatio, slipAngle
end

-- Step transient tire relaxation to simulate carcass compliance
function PacejkaTireModel.StepTransientLag(
  config: TireConfig,
  state: TireState,
  targetSlipRatio: number,
  targetSlipAngle: number,
  forwardSpeed: number,
  deltaTime: number
): (number, number)
  local speed = math.max(math.abs(forwardSpeed), config.MinVelocityThreshold)
  local dt = math.max(deltaTime, 0.0001)

  -- Analytical exponential integration: d(slip)/dt = (v / sigma) * (target - slip)
  local decay = math.exp(-(speed / config.RelaxationLength) * dt)

  local newKappa = targetSlipRatio + (state.CurrentSlipRatio - targetSlipRatio) * decay
  local newAlpha = targetSlipAngle + (state.CurrentSlipAngle - targetSlipAngle) * decay

  state.CurrentSlipRatio = newKappa
  state.CurrentSlipAngle = newAlpha

  return newKappa, newAlpha
end

-- Full coupled combined slip calculation using friction ellipse limitation
function PacejkaTireModel.ComputeCombinedSlipForces(
  config: TireConfig,
  state: TireState,
  slipRatio: number,
  slipAngle: number,
  normalLoad: number,
  camberAngleRad: number?
): CombinedForceResult
  if normalLoad <= 1.0 then
    state.LongitudinalForce = 0.0
    state.LateralForce = 0.0
    state.AligningTorque = 0.0
    state.PneumaticTrail = 0.0
    state.ResultantGripRatio = 0.0
    return {
      LongitudinalForce = 0.0,
      LateralForce = 0.0,
      AligningTorque = 0.0,
      ResultantGripRatio = 0.0,
      TotalForceMagnitude = 0.0,
      MaxAvailableTraction = 0.0,
    }
  end

  local mu = PacejkaTireModel.ComputeEffectiveMu(config, normalLoad)
  local maxAvailableTraction = mu * normalLoad

  -- Pure components
  local pureFx = PacejkaTireModel.ComputeLongitudinalForce(config, slipRatio, normalLoad)
  local pureFy = PacejkaTireModel.ComputeLateralForce(config, slipAngle, normalLoad, camberAngleRad)

  -- Peak slip points (roughly 0.15 for ratio, ~0.10 rad for angle in standard setup)
  local peakKappa = 0.15
  local peakAlpha = 0.10

  local normKappa = math.abs(slipRatio) / peakKappa
  local normAlpha = math.abs(slipAngle) / peakAlpha
  local totalNormSlip = math.sqrt(normKappa * normKappa + normAlpha * normAlpha)

  local combinedFx = pureFx
  local combinedFy = pureFy

  if totalNormSlip > 0.0001 then
    -- Elliptical weighting projection
    local weightX = normKappa / totalNormSlip
    local weightY = normAlpha / totalNormSlip

    -- Modify forces according to combined slip interaction
    combinedFx = pureFx * math.cos(math.atan(normAlpha / (normKappa + 0.0001)))
    combinedFy = pureFy * math.cos(math.atan(normKappa / (normAlpha + 0.0001)))
  end

  -- Strict friction circle / ellipse clamping: sqrt((Fx/maxFx)^2 + (Fy/maxFy)^2) <= 1
  local totalForceMag = math.sqrt(combinedFx * combinedFx + combinedFy * combinedFy)
  local gripRatio = totalForceMag / math.max(maxAvailableTraction, 0.001)

  if totalForceMag > maxAvailableTraction then
    local clampScale = maxAvailableTraction / totalForceMag
    combinedFx *= clampScale
    combinedFy *= clampScale
    totalForceMag = maxAvailableTraction
    gripRatio = 1.0
  end

  local mz, trail = PacejkaTireModel.ComputeSelfAligningTorque(config, combinedFy, slipAngle)

  state.LongitudinalForce = combinedFx
  state.LateralForce = combinedFy
  state.AligningTorque = mz
  state.PneumaticTrail = trail
  state.ResultantGripRatio = gripRatio

  return {
    LongitudinalForce = combinedFx,
    LateralForce = combinedFy,
    AligningTorque = mz,
    ResultantGripRatio = gripRatio,
    TotalForceMagnitude = totalForceMag,
    MaxAvailableTraction = maxAvailableTraction,
  }
end

return PacejkaTireModel
