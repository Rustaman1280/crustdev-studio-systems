local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame
Vector3 = roblox.Vector3
CFrame = roblox.CFrame

local PacejkaTireModel = require("../src/ReplicatedStorage/Physics/PacejkaTireModel")

-- Test 1: Config and Zero Load/Slip Boundary
local config = PacejkaTireModel.CreateConfig()
local state = PacejkaTireModel.CreateState()

assert(config.NominalLoad == 4000.0, "Default nominal load must be 4000 N")
assert(state.CurrentSlipRatio == 0.0, "Initial slip ratio must be 0")

local zeroFx = PacejkaTireModel.ComputeLongitudinalForce(config, 0.0, 4000.0)
assert(math.abs(zeroFx) < 1e-4, "Zero slip must yield zero longitudinal force")

local zeroFy = PacejkaTireModel.ComputeLateralForce(config, 0.0, 4000.0, 0.0)
assert(math.abs(zeroFy) < 1e-4, "Zero slip and camber must yield zero lateral force")

local zeroLoadFx = PacejkaTireModel.ComputeLongitudinalForce(config, 0.15, 0.0)
assert(zeroLoadFx == 0.0, "Zero normal load must produce zero force")

-- Test 2: Peak Slip Dynamics (Longitudinal)
-- As slip increases from 0 to 0.15, force rises monotonically, then peaks and falls slightly
local fx005 = PacejkaTireModel.ComputeLongitudinalForce(config, 0.05, 4000.0)
local fx015 = PacejkaTireModel.ComputeLongitudinalForce(config, 0.15, 4000.0)
local fx050 = PacejkaTireModel.ComputeLongitudinalForce(config, 0.50, 4000.0)

assert(fx005 > 0, "Positive slip ratio must generate positive tractive force")
assert(fx015 > fx005, "Peak slip (0.15) must exceed partial slip (0.05)")
assert(fx015 >= fx050, "Force at excessive spinning slip (0.50) must not exceed peak")

-- Symmetry check: negative slip ratio (braking) produces equal magnitude negative force
local fxBraking = PacejkaTireModel.ComputeLongitudinalForce(config, -0.15, 4000.0)
assert(math.abs(fxBraking + fx015) < 1e-3, "Longitudinal force must be odd symmetric")

-- Test 3: Lateral Cornering & Camber Thrust
local fySmall = PacejkaTireModel.ComputeLateralForce(config, 0.04, 4000.0, 0.0)
local fyPeak = PacejkaTireModel.ComputeLateralForce(config, 0.12, 4000.0, 0.0)
assert(fySmall > 0 and fyPeak > fySmall, "Cornering force must rise towards peak slip angle")

-- Camber thrust test: positive camber adds lateral force
local fyCamber = PacejkaTireModel.ComputeLateralForce(config, 0.04, 4000.0, 0.05) -- ~2.8 deg camber
assert(fyCamber > fySmall, "Positive camber must increase lateral thrust")

-- Test 4: Pneumatic Trail & Self-Aligning Torque (Mz)
local mzSmall, trailSmall = PacejkaTireModel.ComputeSelfAligningTorque(config, fySmall, 0.04)
local mzDrift, trailDrift = PacejkaTireModel.ComputeSelfAligningTorque(config, fyPeak, 0.50)

assert(trailSmall > 0, "Pneumatic trail must be positive at small slip angles")
assert(mzSmall < 0, "Self-aligning torque opposes cornering force direction (restoring torque)")
assert(trailDrift < trailSmall, "Pneumatic trail must decay at severe drift angles")

-- Test 5: Friction Circle / Combined Slip Limits
-- Under combined extreme acceleration and cornering, resultant force must never violate friction circle
local resCombined = PacejkaTireModel.ComputeCombinedSlipForces(
  config,
  state,
  0.25, -- high longitudinal slip
  0.20, -- high cornering angle
  4000.0,
  0.0
)

assert(resCombined.TotalForceMagnitude <= resCombined.MaxAvailableTraction + 1e-3,
  string.format("Total force (%.2f) must respect friction circle cap (%.2f)",
    resCombined.TotalForceMagnitude, resCombined.MaxAvailableTraction))
assert(resCombined.ResultantGripRatio <= 1.0001, "Grip ratio cannot exceed 1.0")
assert(resCombined.LongitudinalForce > 0, "Longitudinal force present in combined slip")
assert(resCombined.LateralForce > 0, "Lateral force present in combined slip")

-- Test 6: Transient Lag Step
local startState = PacejkaTireModel.CreateState()
local dt = 0.016 -- 60 Hz frame
local vForward = 25.0 -- 25 m/s (~90 km/h)
local targetKappa = 0.20
local targetAlpha = 0.15

local step1Kappa, step1Alpha = PacejkaTireModel.StepTransientLag(config, startState, targetKappa, targetAlpha, vForward, dt)
assert(step1Kappa > 0 and step1Kappa < targetKappa, "Transient kappa must smoothly approach target without instantaneous snap")
assert(step1Alpha > 0 and step1Alpha < targetAlpha, "Transient alpha must smoothly approach target")

-- Step multiple frames until settled
for _ = 1, 60 do
  PacejkaTireModel.StepTransientLag(config, startState, targetKappa, targetAlpha, vForward, dt)
end
assert(math.abs(startState.CurrentSlipRatio - targetKappa) < 1e-3, "Transient state must converge to target after relaxation")
assert(math.abs(startState.CurrentSlipAngle - targetAlpha) < 1e-3, "Transient state must converge to target after relaxation")

print("PASS: PacejkaTireModel tests (Config, Peak Curves, Camber Thrust, Self-Aligning Torque, Friction Circle, Transient Lag) passed cleanly!")
