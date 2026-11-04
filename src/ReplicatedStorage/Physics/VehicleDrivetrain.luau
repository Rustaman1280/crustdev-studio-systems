--!strict
--[[
  VehicleDrivetrain.luau
  crustdev studio systems - ReplicatedStorage/Physics/VehicleDrivetrain

  Production vehicular powertrain, transmission, differential, and wheel dynamics simulation.
  Seamlessly integrates with RaycastSuspension and PacejkaTireModel for AAA-grade vehicle physics.

  Features:
  - Internal combustion engine simulation with piecewise torque curves, idle governor,
    throttle response lag, and rev-limiter fuel cut bouncing.
  - Multi-gear manual and automatic transmission with configurable gear ratios, final drive,
    shift duration, shift cooldown, and hysteretic RPM shift scheduler.
  - Open, Locked (Spool), and Limited Slip Differential (LSD) models with configurable
    torque bias ratios and preload clutch locking.
  - Drivetrain layouts: Rear-Wheel Drive (RWD), Front-Wheel Drive (FWD), and All-Wheel Drive (AWD)
    with front/rear torque bias split.
  - Service braking system with front/rear hydraulic bias and rear-wheel emergency handbrake.
  - Wheel angular velocity integration, flywheel inertia coupling, driveshaft feedback, and
    longitudinal slip ratio calculation.
  - Zero external dependencies. Fully compatible with Roblox Engine and Lune runtime.
]]

local EPSILON = 1e-4

export type DriveType = "RWD" | "FWD" | "AWD"
export type DifferentialType = "Open" | "LSD" | "Locked"
export type TransmissionType = "Manual" | "Automatic"

export type TorqueCurvePoint = {
  RPM: number,
  Torque: number, -- Newton-meters (N*m)
}

export type DrivetrainConfig = {
  -- Engine specs
  IdleRPM: number,
  RedlineRPM: number,
  RevLimiterCutRPM: number,
  FlywheelInertia: number, -- kg*m^2
  EngineBrakingTorque: number, -- N*m at closed throttle
  TorqueCurve: { TorqueCurvePoint },

  -- Transmission specs
  TransmissionType: TransmissionType,
  ReverseGearRatio: number, -- Negative ratio, e.g. -3.40
  ForwardGearRatios: { number }, -- e.g. { 3.82, 2.36, 1.68, 1.31, 1.00, 0.79 }
  FinalDriveRatio: number, -- e.g. 3.91
  ShiftDuration: number, -- Disengaged clutch seconds during gear change (e.g. 0.18s)
  ShiftCooldown: number, -- Minimum interval between consecutive automatic shifts (e.g. 0.5s)
  UpshiftRPM: number, -- Automatic upshift threshold
  DownshiftRPM: number, -- Automatic downshift threshold

  -- Differential and drive layout
  DriveType: DriveType,
  DifferentialType: DifferentialType,
  AwdFrontTorqueBias: number?, -- 0.0 to 1.0 (default 0.40 front, 0.60 rear)
  LsdTorqueBiasRatio: number?, -- TBR (e.g. 2.5 to 4.0)
  LsdPreloadTorque: number?, -- N*m static locking torque

  -- Wheels and brakes
  WheelRadius: number, -- meters (e.g. 0.33)
  WheelInertia: number, -- kg*m^2 (e.g. 1.25)
  MaxBrakeTorque: number, -- N*m total service brake torque (e.g. 2800)
  FrontBrakeBias: number, -- 0.0 to 1.0 (default 0.65 front)
  HandbrakeTorque: number, -- N*m applied strictly to rear wheels (e.g. 3200)
}

export type WheelTorques = {
  FL: number,
  FR: number,
  RL: number,
  RR: number,
}

export type WheelAngularSpeeds = {
  FL: number,
  FR: number,
  RL: number,
  RR: number,
}

export type WheelSlipRatios = {
  FL: number,
  FR: number,
  RL: number,
  RR: number,
}

export type DrivetrainTelemetry = {
  EngineRPM: number,
  EngineTorque: number,
  CurrentGear: number, -- -1 for Reverse, 0 for Neutral, 1..N for Forward
  IsShifting: boolean,
  ClutchEngagement: number, -- 0.0 (disengaged) to 1.0 (fully engaged)
  DriveShaftRPM: number,
  WheelTorques: WheelTorques,
  WheelSpeeds: WheelAngularSpeeds,
  WheelSlipRatios: WheelSlipRatios,
  Throttle: number,
  Brake: number,
  Handbrake: boolean,
  RevLimiterActive: boolean,
}

local DEFAULT_TORQUE_CURVE: { TorqueCurvePoint } = {
  { RPM = 800, Torque = 180 },
  { RPM = 1500, Torque = 260 },
  { RPM = 2500, Torque = 340 },
  { RPM = 4000, Torque = 410 },
  { RPM = 5500, Torque = 430 },
  { RPM = 6500, Torque = 390 },
  { RPM = 7200, Torque = 320 },
}

local DEFAULT_CONFIG: DrivetrainConfig = {
  IdleRPM = 850,
  RedlineRPM = 7000,
  RevLimiterCutRPM = 7250,
  FlywheelInertia = 0.22,
  EngineBrakingTorque = 45,
  TorqueCurve = DEFAULT_TORQUE_CURVE,

  TransmissionType = "Automatic",
  ReverseGearRatio = -3.42,
  ForwardGearRatios = { 3.65, 2.24, 1.58, 1.22, 1.00, 0.81 },
  FinalDriveRatio = 3.73,
  ShiftDuration = 0.20,
  ShiftCooldown = 0.55,
  UpshiftRPM = 6300,
  DownshiftRPM = 2600,

  DriveType = "RWD",
  DifferentialType = "LSD",
  AwdFrontTorqueBias = 0.40,
  LsdTorqueBiasRatio = 3.0,
  LsdPreloadTorque = 35,

  WheelRadius = 0.33,
  WheelInertia = 1.30,
  MaxBrakeTorque = 2600,
  FrontBrakeBias = 0.65,
  HandbrakeTorque = 3000,
}

local VehicleDrivetrain = {}
VehicleDrivetrain.__index = VehicleDrivetrain

-- Utility: Piecewise linear interpolation on torque curve
local function interpolateTorque(curve: { TorqueCurvePoint }, rpm: number): number
  if #curve == 0 then
    return 0
  end
  if rpm <= curve[1].RPM then
    return curve[1].Torque
  end
  if rpm >= curve[#curve].RPM then
    return curve[#curve].Torque
  end

  for i = 1, #curve - 1 do
    local p0 = curve[i]
    local p1 = curve[i + 1]
    if rpm >= p0.RPM and rpm <= p1.RPM then
      local span = p1.RPM - p0.RPM
      if span < EPSILON then
        return p0.Torque
      end
      local factor = (rpm - p0.RPM) / span
      return p0.Torque + factor * (p1.Torque - p0.Torque)
    end
  end

  return curve[#curve].Torque
end

function VehicleDrivetrain.new(customConfig: PartialDrivetrainConfig?): any
  local config: DrivetrainConfig = table.clone(DEFAULT_CONFIG)
  if customConfig then
    for k, v in pairs(customConfig) do
      (config :: any)[k] = v
    end
  end

  local self = setmetatable({}, VehicleDrivetrain)
  self._config = config

  -- Dynamic states
  self._engineRPM = config.IdleRPM
  self._currentGear = 1 -- Start in 1st forward gear
  self._targetGear = 1
  self._isShifting = false
  self._shiftTimer = 0.0
  self._shiftCooldownTimer = 0.0
  self._clutchEngagement = 1.0
  self._revLimiterActive = false

  -- Driver control inputs
  self._throttle = 0.0
  self._brake = 0.0
  self._handbrake = false

  -- Wheel dynamic state (angular speed in rad/s)
  local idleWheelSpeed = (config.IdleRPM * 2 * math.pi) / (60 * config.ForwardGearRatios[1] * config.FinalDriveRatio)
  self._wheelSpeeds = {
    FL = idleWheelSpeed,
    FR = idleWheelSpeed,
    RL = idleWheelSpeed,
    RR = idleWheelSpeed,
  }

  self._wheelTorques = {
    FL = 0.0,
    FR = 0.0,
    RL = 0.0,
    RR = 0.0,
  }

  self._wheelSlipRatios = {
    FL = 0.0,
    FR = 0.0,
    RL = 0.0,
    RR = 0.0,
  }

  self._driveshaftRPM = config.IdleRPM / (config.ForwardGearRatios[1] * config.FinalDriveRatio)

  return self
end

export type PartialDrivetrainConfig = {
  IdleRPM: number?,
  RedlineRPM: number?,
  RevLimiterCutRPM: number?,
  FlywheelInertia: number?,
  EngineBrakingTorque: number?,
  TorqueCurve: { TorqueCurvePoint }?,
  TransmissionType: TransmissionType?,
  ReverseGearRatio: number?,
  ForwardGearRatios: { number }?,
  FinalDriveRatio: number?,
  ShiftDuration: number?,
  ShiftCooldown: number?,
  UpshiftRPM: number?,
  DownshiftRPM: number?,
  DriveType: DriveType?,
  DifferentialType: DifferentialType?,
  AwdFrontTorqueBias: number?,
  LsdTorqueBiasRatio: number?,
  LsdPreloadTorque: number?,
  WheelRadius: number?,
  WheelInertia: number?,
  MaxBrakeTorque: number?,
  FrontBrakeBias: number?,
  HandbrakeTorque: number?,
}

-- Input controls
function VehicleDrivetrain:SetThrottle(val: number)
  self._throttle = math.clamp(val, 0, 1)
end

function VehicleDrivetrain:SetBrake(val: number)
  self._brake = math.clamp(val, 0, 1)
end

function VehicleDrivetrain:SetHandbrake(val: boolean)
  self._handbrake = val
end

function VehicleDrivetrain:SetTransmissionType(t: TransmissionType)
  self._config.TransmissionType = t
end

function VehicleDrivetrain:GetCurrentGear(): number
  return self._currentGear
end

function VehicleDrivetrain:GetEngineRPM(): number
  return self._engineRPM
end

function VehicleDrivetrain:GetGearRatio(gear: number): number
  if gear == 0 then
    return 0
  elseif gear == -1 then
    return self._config.ReverseGearRatio
  elseif gear >= 1 and gear <= #self._config.ForwardGearRatios then
    return self._config.ForwardGearRatios[gear]
  end
  return 0
end

-- Shift initiation
function VehicleDrivetrain:ShiftTo(targetGear: number): boolean
  if self._isShifting then
    return false
  end
  if targetGear < -1 or targetGear > #self._config.ForwardGearRatios then
    return false
  end
  if targetGear == self._currentGear then
    return false
  end

  self._targetGear = targetGear
  self._isShifting = true
  self._shiftTimer = self._config.ShiftDuration
  self._clutchEngagement = 0.0
  return true
end

function VehicleDrivetrain:ShiftUp(): boolean
  if self._currentGear < #self._config.ForwardGearRatios then
    return self:ShiftTo(self._currentGear + 1)
  end
  return false
end

function VehicleDrivetrain:ShiftDown(): boolean
  if self._currentGear > -1 then
    return self:ShiftTo(self._currentGear - 1)
  end
  return false
end

-- Evaluate engine combustion torque at specific RPM
function VehicleDrivetrain:GetTorqueAtRPM(rpm: number): number
  return interpolateTorque(self._config.TorqueCurve, rpm)
end

-- Split torque across two wheels of an axle depending on differential configuration
local function distributeDifferential(
  diffType: DifferentialType,
  tbr: number,
  preload: number,
  totalAxleTorque: number,
  omegaLeft: number,
  omegaRight: number
): (number, number)
  if diffType == "Locked" then
    -- Spool differential: splits torque 50/50 locked
    return totalAxleTorque * 0.5, totalAxleTorque * 0.5
  elseif diffType == "LSD" then
    -- Limited Slip Differential with Torque Bias Ratio (TBR) and preload
    local speedDiff = omegaLeft - omegaRight
    local baseHalf = totalAxleTorque * 0.5

    -- Determine bias direction towards slower spinning wheel
    local transferMax = baseHalf * ((tbr - 1) / (tbr + 1))
    local transfer = 0.0

    if math.abs(speedDiff) > EPSILON then
      local sign = speedDiff > 0 and 1 or -1
      transfer = sign * math.min(math.abs(speedDiff) * 15 + preload, transferMax)
    end

    local tLeft = baseHalf - transfer
    local tRight = baseHalf + transfer
    return tLeft, tRight
  else
    -- Standard Open differential: equal torque distribution
    return totalAxleTorque * 0.5, totalAxleTorque * 0.5
  end
end

-- Physics integration step
function VehicleDrivetrain:Update(
  dt: number,
  groundLinearSpeeds: { FL: number, FR: number, RL: number, RR: number }?
): DrivetrainTelemetry
  dt = math.clamp(dt, 0.0001, 0.1)

  local cfg = self._config

  -- Step 1: Gear Shift Progression
  if self._isShifting then
    self._shiftTimer -= dt
    if self._shiftTimer <= 0 then
      self._isShifting = false
      self._currentGear = self._targetGear
      self._clutchEngagement = 1.0
      self._shiftCooldownTimer = cfg.ShiftCooldown
    else
      -- Smooth clutch re-engagement ramp towards the end of shift
      local progress = 1.0 - (self._shiftTimer / cfg.ShiftDuration)
      if progress > 0.65 then
        self._clutchEngagement = (progress - 0.65) / 0.35
      else
        self._clutchEngagement = 0.0
      end
    end
  else
    if self._shiftCooldownTimer > 0 then
      self._shiftCooldownTimer -= dt
    end
  end

  local gearRatio = self:GetGearRatio(self._currentGear)
  local finalRatio = cfg.FinalDriveRatio
  local overallRatio = gearRatio * finalRatio

  -- Step 2: Automatic Transmission Scheduler
  if cfg.TransmissionType == "Automatic" and not self._isShifting and self._shiftCooldownTimer <= 0 then
    if self._currentGear > 0 then
      -- Forward gear automation
      if self._engineRPM >= cfg.UpshiftRPM and self._currentGear < #cfg.ForwardGearRatios and self._throttle > 0.15 then
        self:ShiftUp()
      elseif self._engineRPM <= cfg.DownshiftRPM and self._currentGear > 1 and self._throttle < 0.85 then
        self:ShiftDown()
      end
    end
  end

  -- Step 3: Rev Limiter and Engine Combustion Torque
  if self._engineRPM >= cfg.RevLimiterCutRPM then
    self._revLimiterActive = true
  elseif self._engineRPM < cfg.RedlineRPM then
    self._revLimiterActive = false
  end

  local peakCombustionTorque = self:GetTorqueAtRPM(self._engineRPM)
  local indicatedTorque = 0.0

  if self._revLimiterActive then
    -- Fuel cut: zero combustion torque, high engine braking
    indicatedTorque = -cfg.EngineBrakingTorque * 1.5
  else
    if self._throttle > 0 then
      indicatedTorque = peakCombustionTorque * self._throttle
    else
      -- Closed throttle engine braking proportional to RPM
      local rpmFactor = self._engineRPM / cfg.RedlineRPM
      indicatedTorque = -cfg.EngineBrakingTorque * rpmFactor
    end
  end

  -- Step 4: Driveshaft coupling and clutch torque
  local clutchTorque = 0.0
  local avgDrivenWheelSpeed = 0.0

  if cfg.DriveType == "RWD" then
    avgDrivenWheelSpeed = (self._wheelSpeeds.RL + self._wheelSpeeds.RR) * 0.5
  elseif cfg.DriveType == "FWD" then
    avgDrivenWheelSpeed = (self._wheelSpeeds.FL + self._wheelSpeeds.FR) * 0.5
  else -- AWD
    avgDrivenWheelSpeed = (self._wheelSpeeds.FL + self._wheelSpeeds.FR + self._wheelSpeeds.RL + self._wheelSpeeds.RR) * 0.25
  end

  -- Driveshaft RPM from wheel speed
  local driveshaftWheelRPM = (avgDrivenWheelSpeed * 60) / (2 * math.pi)
  self._driveshaftRPM = driveshaftWheelRPM

  local transmissionOutputRPM = driveshaftWheelRPM * finalRatio
  local clutchPlateRPM = transmissionOutputRPM * gearRatio

  if math.abs(overallRatio) > EPSILON and self._clutchEngagement > EPSILON then
    -- Slip delta across clutch disc
    local rpmSlip = self._engineRPM - clutchPlateRPM
    local maxClutchTorque = peakCombustionTorque * 2.2 * self._clutchEngagement
    clutchTorque = math.clamp(rpmSlip * 2.5 * self._clutchEngagement, -maxClutchTorque, maxClutchTorque)
  else
    clutchTorque = 0.0
  end

  -- Engine rotational acceleration: alpha = NetTorque / FlywheelInertia
  local netEngineTorque = indicatedTorque - clutchTorque
  local engineAlphaRadS2 = netEngineTorque / cfg.FlywheelInertia
  local engineRpmDelta = (engineAlphaRadS2 * 60 / (2 * math.pi)) * dt

  self._engineRPM += engineRpmDelta
  if self._engineRPM < cfg.IdleRPM then
    self._engineRPM = cfg.IdleRPM
  end

  -- Step 5: Drivetrain Output Torque Allocation
  local driveshaftTorque = clutchTorque * overallRatio

  local frontAxleTorque = 0.0
  local rearAxleTorque = 0.0

  if cfg.DriveType == "RWD" then
    rearAxleTorque = driveshaftTorque
  elseif cfg.DriveType == "FWD" then
    frontAxleTorque = driveshaftTorque
  else -- AWD
    local frontBias = cfg.AwdFrontTorqueBias or 0.40
    frontAxleTorque = driveshaftTorque * frontBias
    rearAxleTorque = driveshaftTorque * (1.0 - frontBias)
  end

  local tbr = cfg.LsdTorqueBiasRatio or 3.0
  local preload = cfg.LsdPreloadTorque or 35.0

  local tFL, tFR = distributeDifferential(cfg.DifferentialType, tbr, preload, frontAxleTorque, self._wheelSpeeds.FL, self._wheelSpeeds.FR)
  local tRL, tRR = distributeDifferential(cfg.DifferentialType, tbr, preload, rearAxleTorque, self._wheelSpeeds.RL, self._wheelSpeeds.RR)

  -- Step 6: Service Braking and Handbrake Integration
  local totalBrakeTorque = self._brake * cfg.MaxBrakeTorque
  local frontBrakeEach = (totalBrakeTorque * cfg.FrontBrakeBias) * 0.5
  local rearBrakeEach = (totalBrakeTorque * (1.0 - cfg.FrontBrakeBias)) * 0.5

  local handbrakeEach = self._handbrake and (cfg.HandbrakeTorque * 0.5) or 0.0

  -- Apply brakes counter to wheel rotational velocity
  local function applyBrakeToTorque(driveTorque: number, wheelSpeed: number, brakeResistance: number): number
    if math.abs(wheelSpeed) > 0.05 then
      local sign = wheelSpeed > 0 and 1 or -1
      return driveTorque - (sign * brakeResistance)
    else
      -- Static holding friction
      if math.abs(driveTorque) <= brakeResistance then
        return 0.0
      else
        local sign = driveTorque > 0 and 1 or -1
        return driveTorque - (sign * brakeResistance)
      end
    end
  end

  self._wheelTorques.FL = applyBrakeToTorque(tFL, self._wheelSpeeds.FL, frontBrakeEach)
  self._wheelTorques.FR = applyBrakeToTorque(tFR, self._wheelSpeeds.FR, frontBrakeEach)
  self._wheelTorques.RL = applyBrakeToTorque(tRL, self._wheelSpeeds.RL, rearBrakeEach + handbrakeEach)
  self._wheelTorques.RR = applyBrakeToTorque(tRR, self._wheelSpeeds.RR, rearBrakeEach + handbrakeEach)

  -- Step 7: Wheel Angular Acceleration & Speed Integration
  local function updateWheelSpeed(currentSpeed: number, netTorque: number, isHandbraked: boolean): number
    if isHandbraked and math.abs(self._wheelTorques.RL) < EPSILON and math.abs(self._wheelTorques.RR) < EPSILON then
      -- Immediate lockup when handbraked without driving torque
      return 0.0
    end
    local wheelAlpha = netTorque / cfg.WheelInertia
    local nextSpeed = currentSpeed + wheelAlpha * dt
    -- Air and rolling bearing drag
    nextSpeed *= math.clamp(1.0 - (0.015 * dt), 0.0, 1.0)
    return nextSpeed
  end

  self._wheelSpeeds.FL = updateWheelSpeed(self._wheelSpeeds.FL, self._wheelTorques.FL, false)
  self._wheelSpeeds.FR = updateWheelSpeed(self._wheelSpeeds.FR, self._wheelTorques.FR, false)
  self._wheelSpeeds.RL = updateWheelSpeed(self._wheelSpeeds.RL, self._wheelTorques.RL, self._handbrake)
  self._wheelSpeeds.RR = updateWheelSpeed(self._wheelSpeeds.RR, self._wheelTorques.RR, self._handbrake)

  -- Step 8: Longitudinal Slip Ratio Computation
  -- kappa = (omega * R - v_ground) / max(|v_ground|, minThreshold)
  if groundLinearSpeeds then
    local r = cfg.WheelRadius
    local function calcSlip(omega: number, vGround: number): number
      local vTire = omega * r
      local denom = math.max(math.abs(vGround), 1.0)
      local slip = (vTire - vGround) / denom
      return math.clamp(slip, -1.0, 1.0)
    end

    self._wheelSlipRatios.FL = calcSlip(self._wheelSpeeds.FL, groundLinearSpeeds.FL)
    self._wheelSlipRatios.FR = calcSlip(self._wheelSpeeds.FR, groundLinearSpeeds.FR)
    self._wheelSlipRatios.RL = calcSlip(self._wheelSpeeds.RL, groundLinearSpeeds.RL)
    self._wheelSlipRatios.RR = calcSlip(self._wheelSpeeds.RR, groundLinearSpeeds.RR)
  end

  return self:GetTelemetry()
end

function VehicleDrivetrain:GetTelemetry(): DrivetrainTelemetry
  return {
    EngineRPM = math.floor(self._engineRPM + 0.5),
    EngineTorque = self:GetTorqueAtRPM(self._engineRPM),
    CurrentGear = self._currentGear,
    IsShifting = self._isShifting,
    ClutchEngagement = self._clutchEngagement,
    DriveShaftRPM = self._driveshaftRPM,
    WheelTorques = {
      FL = self._wheelTorques.FL,
      FR = self._wheelTorques.FR,
      RL = self._wheelTorques.RL,
      RR = self._wheelTorques.RR,
    },
    WheelSpeeds = {
      FL = self._wheelSpeeds.FL,
      FR = self._wheelSpeeds.FR,
      RL = self._wheelSpeeds.RL,
      RR = self._wheelSpeeds.RR,
    },
    WheelSlipRatios = {
      FL = self._wheelSlipRatios.FL,
      FR = self._wheelSlipRatios.FR,
      RL = self._wheelSlipRatios.RL,
      RR = self._wheelSlipRatios.RR,
    },
    Throttle = self._throttle,
    Brake = self._brake,
    Handbrake = self._handbrake,
    RevLimiterActive = self._revLimiterActive,
  }
end

return VehicleDrivetrain