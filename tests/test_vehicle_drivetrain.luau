local roblox = require("@lune/roblox")

local VehicleDrivetrain = require("../src/ReplicatedStorage/Physics/VehicleDrivetrain")

local EPSILON = 1e-2

-- Test 1: Instantiation, baseline telemetry, and idle RPM
do
  local dt = VehicleDrivetrain.new()
  local telem = dt:GetTelemetry()

  assert(telem.EngineRPM >= 850, "Initial engine RPM must be at least idle RPM")
  assert(telem.CurrentGear == 1, "Default starting gear should be 1")
  assert(telem.ClutchEngagement == 1.0, "Clutch should be fully engaged initially")
  assert(not telem.IsShifting, "Should not be shifting initially")
  assert(not telem.Handbrake, "Handbrake should be off initially")
  assert(telem.Throttle == 0, "Throttle should be 0")
end

-- Test 2: Torque curve piecewise interpolation
do
  local dt = VehicleDrivetrain.new()
  local t800 = dt:GetTorqueAtRPM(800)
  local t4000 = dt:GetTorqueAtRPM(4000)
  local t2000 = dt:GetTorqueAtRPM(2000)

  assert(math.abs(t800 - 180) < EPSILON, "Torque at 800 RPM should match 180 Nm")
  assert(math.abs(t4000 - 410) < EPSILON, "Torque at 4000 RPM should match 410 Nm")
  -- Midpoint between 1500 (260) and 2500 (340) is 2000 (300)
  assert(math.abs(t2000 - 300) < 1.0, string.format("Torque at 2000 RPM should interpolate to ~300 Nm, got %f", t2000))
end

-- Test 3: Throttle acceleration and engine RPM increase
do
  local dt = VehicleDrivetrain.new({
    TransmissionType = "Manual",
  })

  dt:SetThrottle(1.0)
  local initialRPM = dt:GetEngineRPM()

  -- Run 10 physics ticks at 60 FPS (0.016s)
  for _ = 1, 15 do
    dt:Update(0.016, { FL = 5, FR = 5, RL = 5, RR = 5 })
  end

  local acceleratedRPM = dt:GetEngineRPM()
  assert(acceleratedRPM > initialRPM, string.format("RPM should increase under full throttle (initial: %f, now: %f)", initialRPM, acceleratedRPM))
end

-- Test 4: Gear shifting and clutch transition
do
  local dt = VehicleDrivetrain.new({
    TransmissionType = "Manual",
    ShiftDuration = 0.20,
  })

  assert(dt:GetCurrentGear() == 1, "Should start in gear 1")
  local shiftSuccess = dt:ShiftUp()
  assert(shiftSuccess, "ShiftUp should succeed")

  local telemShifting = dt:GetTelemetry()
  assert(telemShifting.IsShifting, "Should be in shifting state")
  assert(telemShifting.ClutchEngagement == 0.0, "Clutch should be disengaged during early shift")

  -- Advance time past shift duration (0.20s) in standard physics delta steps
  for _ = 1, 3 do
    dt:Update(0.1)
  end
  local telemAfter = dt:GetTelemetry()
  assert(not telemAfter.IsShifting, "Should no longer be shifting")
  assert(dt:GetCurrentGear() == 2, "Current gear should now be 2")
  assert(telemAfter.ClutchEngagement == 1.0, "Clutch should be fully engaged after shift completion")
end

-- Test 5: Drivetrain layouts (RWD vs FWD vs AWD) torque distribution
do
  -- RWD Test
  local rwd = VehicleDrivetrain.new({
    DriveType = "RWD",
    DifferentialType = "Open",
  })
  rwd:SetThrottle(1.0)
  rwd:Update(0.02)
  local telemRWD = rwd:GetTelemetry()
  assert(telemRWD.WheelTorques.RL > 0 and telemRWD.WheelTorques.RR > 0, "RWD must supply torque to rear wheels")
  assert(math.abs(telemRWD.WheelTorques.FL) < EPSILON and math.abs(telemRWD.WheelTorques.FR) < EPSILON, "RWD must supply zero drive torque to front wheels")

  -- FWD Test
  local fwd = VehicleDrivetrain.new({
    DriveType = "FWD",
    DifferentialType = "Open",
  })
  fwd:SetThrottle(1.0)
  fwd:Update(0.02)
  local telemFWD = fwd:GetTelemetry()
  assert(telemFWD.WheelTorques.FL > 0 and telemFWD.WheelTorques.FR > 0, "FWD must supply torque to front wheels")
  assert(math.abs(telemFWD.WheelTorques.RL) < EPSILON and math.abs(telemFWD.WheelTorques.RR) < EPSILON, "FWD must supply zero drive torque to rear wheels")

  -- AWD Test
  local awd = VehicleDrivetrain.new({
    DriveType = "AWD",
    AwdFrontTorqueBias = 0.40,
    DifferentialType = "Open",
  })
  awd:SetThrottle(1.0)
  awd:Update(0.02)
  local telemAWD = awd:GetTelemetry()
  assert(telemAWD.WheelTorques.FL > 0 and telemAWD.WheelTorques.FR > 0, "AWD must supply torque to front")
  assert(telemAWD.WheelTorques.RL > 0 and telemAWD.WheelTorques.RR > 0, "AWD must supply torque to rear")
  -- Front torque (FL+FR = 40%) should be less than rear torque (RL+RR = 60%)
  local frontTotal = telemAWD.WheelTorques.FL + telemAWD.WheelTorques.FR
  local rearTotal = telemAWD.WheelTorques.RL + telemAWD.WheelTorques.RR
  assert(rearTotal > frontTotal, "AWD rear torque should exceed front torque when bias is 0.40")
end

-- Test 6: Differential locking and torque bias (LSD vs Open)
do
  local lsd = VehicleDrivetrain.new({
    DriveType = "RWD",
    DifferentialType = "LSD",
    LsdTorqueBiasRatio = 3.0,
    LsdPreloadTorque = 50,
  })

  -- Simulate engine revved up with right wheel spinning faster (slipping on ice)
  lsd._engineRPM = 4500
  lsd._wheelSpeeds.RL = 10.0
  lsd._wheelSpeeds.RR = 30.0
  lsd:SetThrottle(0.8)
  lsd:Update(0.016)

  local telem = lsd:GetTelemetry()
  -- LSD should transfer torque to slower wheel (RL)
  assert(telem.WheelTorques.RL > telem.WheelTorques.RR, "LSD should bias torque towards slower gripping wheel (RL)")
end

-- Test 7: Service braking and handbrake application
do
  local dt = VehicleDrivetrain.new({
    DriveType = "RWD",
    MaxBrakeTorque = 3000,
    FrontBrakeBias = 0.70,
  })

  dt:SetBrake(1.0)
  dt:Update(0.016)
  local telemBrake = dt:GetTelemetry()
  -- Front brake torque should be higher than rear brake torque due to 70% front bias
  assert(math.abs(telemBrake.WheelTorques.FL) > math.abs(telemBrake.WheelTorques.RL), "Front brake torque must exceed rear with 70% front bias")

  -- Handbrake test
  local dtHandbrake = VehicleDrivetrain.new({
    DriveType = "RWD",
    HandbrakeTorque = 4000,
  })
  dtHandbrake:SetHandbrake(true)
  dtHandbrake:Update(0.016)
  local telemHB = dtHandbrake:GetTelemetry()
  assert(telemHB.Handbrake, "Handbrake state should be true in telemetry")
  assert(math.abs(telemHB.WheelTorques.RL) > 0 and math.abs(telemHB.WheelTorques.RR) > 0, "Handbrake must clamp rear wheels")
  assert(math.abs(telemHB.WheelTorques.FL) < EPSILON, "Handbrake should not clamp front wheels")
end

-- Test 8: Longitudinal slip ratio calculation
do
  local dt = VehicleDrivetrain.new({
    WheelRadius = 0.5,
  })

  -- Omega = 20 rad/s -> Wheel linear speed = 20 * 0.5 = 10 m/s
  dt._wheelSpeeds.FL = 20.0
  dt._wheelSpeeds.FR = 20.0
  dt._wheelSpeeds.RL = 20.0
  dt._wheelSpeeds.RR = 20.0

  -- Ground speed = 10 m/s -> Slip ratio should be ~0.0
  dt:Update(0.016, { FL = 10.0, FR = 10.0, RL = 10.0, RR = 10.0 })
  local telemMatch = dt:GetTelemetry()
  assert(math.abs(telemMatch.WheelSlipRatios.FL) < 0.05, "Slip ratio should be near 0 when tire speed matches ground speed")

  -- Ground speed = 5 m/s -> Tire spinning faster -> Positive slip ratio
  dt:Update(0.016, { FL = 5.0, FR = 5.0, RL = 5.0, RR = 5.0 })
  local telemSpin = dt:GetTelemetry()
  assert(telemSpin.WheelSlipRatios.FL > 0.4, "Slip ratio should be significantly positive during wheel spin")
end

-- Test 9: Rev limiter trigger
do
  local dt = VehicleDrivetrain.new({
    RedlineRPM = 6800,
    RevLimiterCutRPM = 7000,
  })

  dt._engineRPM = 7100
  dt:Update(0.016)
  local telem = dt:GetTelemetry()
  assert(telem.RevLimiterActive, "Rev limiter should be active above RevLimiterCutRPM")
end

print("test_vehicle_drivetrain: all tests passed successfully!")
return true