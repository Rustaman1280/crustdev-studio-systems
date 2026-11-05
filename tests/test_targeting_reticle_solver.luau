local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local TargetingReticleSolver = require("../src/ReplicatedStorage/Combat/TargetingReticleSolver")

local function assertEqual(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "Assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assertAlmostEqual(actual, expected, tol, msg)
  local t = tol or 0.001
  if math.abs(actual - expected) > t then
    error(string.format("%s: expected ~%s (+/-%s), got %s", msg or "Assertion failed", tostring(expected), tostring(t), tostring(actual)))
  end
end

local function assertTrue(condition, msg)
  if not condition then
    error(msg or "Condition expected to be true")
  end
end

-- Test 1: Stationary Target Ballistic Lead
do
  local origin = Vector3.new(0, 0, 0)
  local targetPos = Vector3.new(0, 0, -100)
  local targetVel = Vector3.new(0, 0, 0)
  local projParams = {
    Speed = 200,
    Gravity = Vector3.new(0, 0, 0),
  }

  local sol = TargetingReticleSolver.SolveBallisticLead(origin, targetPos, targetVel, projParams)
  assertTrue(sol.CanHit, "Stationary target should be hit")
  assertAlmostEqual(sol.TimeToImpact, 0.5, 0.01, "Transit time for 100 studs at 200 studs/s")
  assertAlmostEqual(sol.InterceptPoint.Z, -100, 0.01, "Stationary intercept point")
  assertAlmostEqual(sol.AimDirection.Z, -1.0, 0.01, "Aim direction towards negative Z")
  assertTrue(sol.Confidence > 0.8, "High confidence for stationary close target")
end

-- Test 2: Moving Target Perpendicular Crossing
do
  local origin = Vector3.new(0, 0, 0)
  local targetPos = Vector3.new(0, 0, -100)
  -- Target moving right (+X) at 20 studs/s
  local targetVel = Vector3.new(20, 0, 0)
  local projParams = {
    Speed = 100,
    Gravity = Vector3.new(0, 0, 0),
  }

  local sol = TargetingReticleSolver.SolveBallisticLead(origin, targetPos, targetVel, projParams)
  assertTrue(sol.CanHit, "Target crossing perpendicular should be intercepted")
  -- In 1 second, target moves from X=0 to X=20, dist to (20, 0, -100) is sqrt(400 + 10000) ~ 101.98
  -- With proj speed 100, t ~ 1.04 s
  assertTrue(sol.TimeToImpact > 1.0 and sol.TimeToImpact < 1.1, "Transit time between 1.0 and 1.1 s")
  assertTrue(sol.InterceptPoint.X > 20.0, "Intercept X position leads target")
  assertTrue(sol.AimDirection.X > 0.1, "Aim vector leads towards positive X")
end

-- Test 3: Ballistic Lead with Gravity Arc Compensation
do
  local origin = Vector3.new(0, 5, 0)
  local targetPos = Vector3.new(0, 5, -150)
  local targetVel = Vector3.new(0, 0, 0)
  local gravity = Vector3.new(0, -196.2, 0) -- Standard Roblox gravity
  local projParams = {
    Speed = 300,
    Gravity = gravity,
  }

  local sol = TargetingReticleSolver.SolveBallisticLead(origin, targetPos, targetVel, projParams)
  assertTrue(sol.CanHit, "Target under gravity should be intercepted")
  -- Due to gravity drop, projectile must launch with upward (+Y) pitch angle
  assertTrue(sol.AimDirection.Y > 0.1, "Launch angle must pitch upward to compensate gravity")
  assertAlmostEqual(sol.InterceptPoint.Z, -150, 0.1, "Intercept Z coordinate")
end

-- Test 4: Impossible Intercept (Target Escaping Faster Than Projectile)
do
  local origin = Vector3.new(0, 0, 0)
  local targetPos = Vector3.new(0, 0, -50)
  -- Target fleeing at 250 studs/s, projectile only 100 studs/s
  local targetVel = Vector3.new(0, 0, -250)
  local projParams = {
    Speed = 100,
    Gravity = Vector3.new(0, 0, 0),
  }

  local sol = TargetingReticleSolver.SolveBallisticLead(origin, targetPos, targetVel, projParams)
  assertTrue(not sol.CanHit, "Escaping target faster than projectile cannot be intercepted")
  assertEqual(sol.Confidence, 0, "Zero confidence for impossible intercept")
end

-- Test 5: Target Acquisition inside Aim Assist Cone
do
  local cameraPos = Vector3.new(0, 5, 0)
  local cameraLook = Vector3.new(0, 0, -1)
  local targets = {
    {
      Id = "far_off_target",
      Position = Vector3.new(100, 5, -50), -- ~63 degrees off center
      Velocity = Vector3.new(0, 0, 0),
      Radius = 2,
      Priority = 1,
    },
    {
      Id = "valid_target_a",
      Position = Vector3.new(5, 5, -50), -- ~5.7 degrees off center
      Velocity = Vector3.new(0, 0, 0),
      Radius = 2,
      Priority = 1,
    },
    {
      Id = "valid_target_b_high_priority",
      Position = Vector3.new(8, 5, -50), -- ~9 degrees off center, but high priority
      Velocity = Vector3.new(0, 0, 0),
      Radius = 2,
      Priority = 5,
    },
  }

  local acquired = TargetingReticleSolver.AcquireBestTarget(cameraPos, cameraLook, targets, nil)
  assertTrue(acquired ~= nil, "Should acquire a valid target inside cone")
  assertTrue(acquired.Target.Id == "valid_target_b_high_priority" or acquired.Target.Id == "valid_target_a", "Acquired valid target")
  assertTrue(acquired.AngleDeg < 25.0, "Target angle is inside maximum angle cone")
end

-- Test 6: Target Acquisition Ignores Out of Range Targets
do
  local cameraPos = Vector3.new(0, 0, 0)
  local cameraLook = Vector3.new(0, 0, -1)
  local targets = {
    {
      Id = "beyond_range",
      Position = Vector3.new(0, 0, -1000), -- 1000 studs away (default max 500)
      Velocity = Vector3.new(0, 0, 0),
      Radius = 2,
    },
  }

  local acquired = TargetingReticleSolver.AcquireBestTarget(cameraPos, cameraLook, targets, nil)
  assertTrue(acquired == nil, "Out of range target should not be acquired")
end

-- Test 7: Aim Assist Friction and Magnetism Calculation
do
  local cameraPos = Vector3.new(0, 0, 0)
  local cameraLook = Vector3.new(0, 0, -1)
  local target = {
    Id = "boss",
    Position = Vector3.new(2, 0, -50), -- ~2.3 degrees off center
    Velocity = Vector3.new(0, 0, 0),
    Radius = 3,
  }

  local result = TargetingReticleSolver.CalculateAimAssist(cameraPos, cameraLook, target, nil)
  assertTrue(result.FrictionApplied, "Friction should apply within 12 degrees")
  assertTrue(result.FrictionDamping < 1.0, "Crosshair velocity should be damped")
  assertTrue(result.MagnetismApplied, "Magnetism should apply within 6 degrees")
  assertTrue(result.ModifiedLookVector.X > 0, "Modified look vector pulls towards target (+X)")
end

-- Test 8: Hit Probability Estimation
do
  local targetNonEvading = {
    Id = "slow",
    Position = Vector3.new(0, 0, -50),
    Velocity = Vector3.new(0, 0, 0),
    Acceleration = Vector3.new(0, 0, 0),
    Radius = 3.0,
  }
  local probHigh = TargetingReticleSolver.CalculateHitProbability(targetNonEvading, 200, 0.5)

  local targetEvading = {
    Id = "dodger",
    Position = Vector3.new(0, 0, -50),
    Velocity = Vector3.new(0, 0, 0),
    Acceleration = Vector3.new(50, 0, 0), -- High lateral dodging acceleration
    Radius = 1.0,
  }
  local probLow = TargetingReticleSolver.CalculateHitProbability(targetEvading, 200, 2.0)

  assertTrue(probHigh > probLow, "Non-evading close target has higher hit probability than dodging far target")
  assertTrue(probHigh > 0.8, "High probability for close static target")
  assertTrue(probLow < 0.4, "Lower probability for high-acceleration target at long flight time")
end

print("TargetingReticleSolver tests passed successfully!")