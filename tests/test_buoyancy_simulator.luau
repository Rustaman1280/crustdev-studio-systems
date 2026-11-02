local roblox = _G.Vector3 and _G or require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local BuoyancySimulator = require("../src/ReplicatedStorage/Physics/BuoyancySimulator")

-- Test 1: Initialization
local sim = BuoyancySimulator.new({
  FluidDensity = 1.0,
  Gravity = 100.0,
  LinearDrag = 2.0,
  AngularDrag = 3.0,
  KeelResistanceFactor = 4.0,
  BaseWaterElevation = 0.0,
})

assert(sim.FluidDensity == 1.0, "Fluid density mismatch")
assert(sim.Gravity == 100.0, "Gravity mismatch")
assert(sim.TotalVolume == 0.0, "Initial volume should be 0")

-- Test 2: Multi-Probe Hull Configuration
-- A catamaran or box hull with 4 corner probes and 1 keel center probe
sim:AddProbe("BowPort", Vector3.new(-2, 0, -4), 10.0, 2.0)
sim:AddProbe("BowStarboard", Vector3.new(2, 0, -4), 10.0, 2.0)
sim:AddProbe("SternPort", Vector3.new(-2, 0, 4), 10.0, 2.0)
sim:AddProbe("SternStarboard", Vector3.new(2, 0, 4), 10.0, 2.0)
sim:AddProbe("KeelCenter", Vector3.new(0, -1, 0), 20.0, 2.0)

assert(#sim.Probes == 5, "Should have 5 probes")
assert(sim.TotalVolume == 60.0, "Total volume should be 60.0")

-- Test 3: Airborne Object (Zero Submersion)
local airborneCF = CFrame.new(0, 50, 0)
local airResult = sim:Solve(airborneCF, Vector3.new(0, 0, 0), Vector3.new(0, 0, 0), 0)
assert(airResult.SubmergedProbeCount == 0, "Airborne object should have 0 submerged probes")
assert(airResult.SubmergedFraction == 0.0, "Airborne submerged fraction must be 0")
assert(airResult.NetForce.Magnitude == 0.0, "Airborne net buoyant force must be 0")

-- Test 4: Fully Submerged Object
local submergedCF = CFrame.new(0, -10, 0)
local subResult = sim:Solve(submergedCF, Vector3.new(0, 0, 0), Vector3.new(0, 0, 0), 0)
assert(subResult.SubmergedProbeCount == 5, "Fully submerged object should have 5 submerged probes")
assert(subResult.SubmergedFraction == 1.0, "Fully submerged fraction must be 1.0")

-- Expected force: density * totalVolume * gravity = 1.0 * 60.0 * 100.0 = 6000.0
local expectedForceY = 6000.0
assert(math.abs(subResult.NetForce.Y - expectedForceY) < 1e-3, "Buoyant force must match Archimedes formula")

-- Test 5: Restoring Metacentric Righting Torque
-- Tilt the boat around Z-axis (positive roll around Z)
-- In Roblox coordinates (+X is starboard/right, +Y is up, -Z is forward):
-- Positive rotation around Z tilts +X up and -X down
-- Port side (-X) plunges deeper into water, Starboard side (+X) lifts up
-- Deeper port side generates higher buoyant force, exerting negative restoring torque (-Z torque)
local rollCFrame = CFrame.Angles(0, 0, math.rad(15)) * CFrame.new(0, 0, 0)
local rollResult = sim:Solve(rollCFrame, Vector3.new(0, 0, 0), Vector3.new(0, 0, 0), 0)

assert(rollResult.Probes["BowPort"].SubmergedFraction > rollResult.Probes["BowStarboard"].SubmergedFraction,
  "Port probe (-X) must be more submerged than Starboard probe (+X) during positive Z roll")
assert(rollResult.NetTorque.Z < -1.0,
  "Restoring buoyant torque must push back against the positive roll perturbation")

-- Test 6: Dynamic Gerstner Waves
sim:SetWaves({
  {
    Amplitude = 3.0,
    Wavelength = 40.0,
    Direction = Vector3.new(0, 0, 1),
    Steepness = 0.5,
    Speed = 10.0,
  },
})

local waveElev1, waveNorm1 = sim:SampleWaveElevation(0, 0, 0)
assert(waveElev1 == 0.0, "Sine wave at origin phase 0 should be 0")
assert(math.abs(waveNorm1.Magnitude - 1.0) < 1e-4, "Surface normal must be unit vector")

-- At quarter wavelength (z = 10), phase = 2*pi/40 * 10 = pi/2 -> sine = 1.0 -> elevation = 3.0
local waveElev2, waveNorm2 = sim:SampleWaveElevation(0, 10, 0)
assert(math.abs(waveElev2 - 3.0) < 1e-3, "Wave crest elevation should be 3.0")
assert(math.abs(waveNorm2.Magnitude - 1.0) < 1e-4, "Crest normal must be unit vector")

-- Test 7: Keel Resistance Anisotropy
-- Moving forward (Z velocity) vs moving sideways (X velocity)
local forwardVel = Vector3.new(0, 0, -10)
local sidewaysVel = Vector3.new(10, 0, 0)
local levelCF = CFrame.new(0, -1, 0)

local fwdResult = sim:Solve(levelCF, forwardVel, Vector3.new(0, 0, 0), 0)
local sideResult = sim:Solve(levelCF, sidewaysVel, Vector3.new(0, 0, 0), 0)

-- Sideways drag should be amplified by KeelResistanceFactor (4.0)
local dragFwdMag = math.abs(fwdResult.NetForce.Z)
local dragSideMag = math.abs(sideResult.NetForce.X)
assert(dragSideMag > dragFwdMag * 2.5, "Lateral keel resistance must significantly exceed longitudinal drag")

-- Test 8: Symplectic Physics Step
local mass = 50.0
local inertia = Vector3.new(200, 300, 200)
local dt = 1 / 60
local cf = CFrame.new(0, 1, 0)
local linVel = Vector3.new(0, 0, 0)
local angVel = Vector3.new(0, 0, 0)

-- Step 10 frames
for f = 1, 10 do
  cf, linVel, angVel = sim:StepPhysics(cf, linVel, angVel, mass, inertia, dt, f * dt)
  assert(cf.Position.Y == cf.Position.Y, "Position Y must not be NaN")
  assert(linVel.Y == linVel.Y, "Velocity Y must not be NaN")
end

print("PASS: BuoyancySimulator tests (Init, Probes, Airborne, Submerged, RestoringTorque, GerstnerWaves, KeelResistance, SymplecticStep) passed cleanly!")
