--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
_G.Vector3 = Vector3
_G.CFrame = CFrame

local ExplosionImpulseSolver = require("../src/ReplicatedStorage/Combat/ExplosionImpulseSolver")

local function assertApprox(a: number, b: number, eps: number?, msg: string?)
  local epsilon = eps or 1e-4
  if math.abs(a - b) > epsilon then
    error(string.format("%s: expected approx %f, got %f (diff: %f)", msg or "assertApprox", b, a, math.abs(a - b)))
  end
end

local solver = ExplosionImpulseSolver.new()

-- 1. Linear Falloff & Damage/Impulse verification
do
  local blast = {
    Position = Vector3.new(0, 0, 0),
    Radius = 50,
    BaseDamage = 100,
    MaxImpulse = 1000,
    Falloff = "Linear" :: "Linear",
  }

  local targetCenter = {
    Id = "target_center",
    Position = Vector3.new(0, 0, 0),
  }
  local resCenter = solver:SolveTarget(blast, targetCenter)
  assert(resCenter.InRange, "Target at center must be in range")
  assertApprox(resCenter.RawDamage, 100, 1e-3, "Center damage should be 100")
  assertApprox(resCenter.FinalDamage, 100, 1e-3, "Center final damage should be 100")
  assertApprox(resCenter.ImpulseVector.Magnitude, 1000, 1e-3, "Center impulse magnitude should be 1000")

  local targetMid = {
    Id = "target_mid",
    Position = Vector3.new(25, 0, 0),
  }
  local resMid = solver:SolveTarget(blast, targetMid)
  assert(resMid.InRange, "Target at midpoint must be in range")
  assertApprox(resMid.RawDamage, 50, 1e-3, "Midpoint damage should be 50 with linear falloff")
  assertApprox(resMid.ImpulseVector.Magnitude, 500, 1e-3, "Midpoint impulse magnitude should be 500")

  local targetEdge = {
    Id = "target_edge",
    Position = Vector3.new(50, 0, 0),
  }
  local resEdge = solver:SolveTarget(blast, targetEdge)
  assert(resEdge.InRange, "Target at edge must be in range")
  assertApprox(resEdge.RawDamage, 0, 1e-3, "Edge damage should be 0")

  local targetOutside = {
    Id = "target_out",
    Position = Vector3.new(51, 0, 0),
  }
  local resOut = solver:SolveTarget(blast, targetOutside)
  assert(not resOut.InRange, "Target outside radius must not be in range")
end

-- 2. Quadratic and Smoothstep Falloffs
do
  local blastQuad = {
    Position = Vector3.new(0, 0, 0),
    Radius = 20,
    BaseDamage = 100,
    MaxImpulse = 500,
    Falloff = "Quadratic" :: "Quadratic",
  }
  local targetMid = {
    Id = "t_quad_mid",
    Position = Vector3.new(10, 0, 0),
  }
  local resQuad = solver:SolveTarget(blastQuad, targetMid)
  -- normalized distance 0.5 -> factor 0.5 -> 0.5^2 = 0.25
  assertApprox(resQuad.RawDamage, 25, 1e-3, "Quadratic falloff at 0.5 distance should be 25%")

  local blastSmooth = {
    Position = Vector3.new(0, 0, 0),
    Radius = 20,
    BaseDamage = 100,
    MaxImpulse = 500,
    Falloff = "Smoothstep" :: "Smoothstep",
  }
  local resSmooth = solver:SolveTarget(blastSmooth, targetMid)
  -- normalized dist 0.5 -> factor 0.5 -> 0.25 * (3 - 1) = 0.50
  assertApprox(resSmooth.RawDamage, 50, 1e-3, "Smoothstep falloff at 0.5 distance should be 50%")
end

-- 3. Directional Shaped Charge (Cone)
do
  local shapedBlast = {
    Position = Vector3.new(0, 0, 0),
    Radius = 30,
    BaseDamage = 200,
    MaxImpulse = 1500,
    DirectionalCone = {
      Direction = Vector3.new(0, 0, 1), -- pointing +Z
      SpreadAngleRad = math.rad(45),
    },
  }

  local targetInCone = {
    Id = "t_in_cone",
    Position = Vector3.new(0, 0, 15), -- directly forward +Z
  }
  local resIn = solver:SolveTarget(shapedBlast, targetInCone)
  assert(resIn.InRange, "Target in front of shaped blast must be in range")
  assert(resIn.FinalDamage > 0, "Target in cone should receive damage")

  local targetBehindCone = {
    Id = "t_behind",
    Position = Vector3.new(0, 0, -15), -- behind charge
  }
  local resBehind = solver:SolveTarget(shapedBlast, targetBehindCone)
  assert(not resBehind.InRange, "Target behind shaped charge must be out of range")

  local targetFlankCone = {
    Id = "t_flank",
    Position = Vector3.new(20, 0, 0), -- 90 degrees to side
  }
  local resFlank = solver:SolveTarget(shapedBlast, targetFlankCone)
  assert(not resFlank.InRange, "Target 90 degrees to side must be outside 45-deg cone")
end

-- 4. Armor, Resistance, and Occlusion Cover
do
  local blast = {
    Position = Vector3.new(0, 0, 0),
    Radius = 20,
    BaseDamage = 100,
    MaxImpulse = 400,
    Falloff = "Constant" :: "Constant",
  }

  local targetCovered = {
    Id = "t_cover",
    Position = Vector3.new(5, 0, 0),
    OcclusionFraction = 0.5, -- 50% cover behind wall
  }
  local resCover = solver:SolveTarget(blast, targetCovered)
  assertApprox(resCover.RawDamage, 50, 1e-3, "50% occlusion should reduce raw damage by half")
  assertApprox(resCover.ImpulseVector.Magnitude, 200, 1e-3, "50% occlusion should halve impulse")

  local targetArmored = {
    Id = "t_armored",
    Position = Vector3.new(5, 0, 0),
    Armor = 20,
    BlastResistance = 0.25, -- 25% blast absorption
  }
  local resArmor = solver:SolveTarget(blast, targetArmored)
  -- Raw = 100 -> post armor = 80 -> post resistance (1 - 0.25) = 60
  assertApprox(resArmor.FinalDamage, 60, 1e-3, "Armor and blast resistance calculations must match")
end

-- 5. Off-Center Torque Dynamics
do
  local blast = {
    Position = Vector3.new(0, 0, 0),
    Radius = 20,
    BaseDamage = 100,
    MaxImpulse = 1000,
    Falloff = "Constant" :: "Constant",
  }

  local targetWithCOM = {
    Id = "t_com",
    Position = Vector3.new(10, 2, 0), -- Hit point is 2 units above center of mass
    CenterOfMass = Vector3.new(10, 0, 0),
  }
  local resTorque = solver:SolveTarget(blast, targetWithCOM)
  assert(resTorque.TorqueVector.Magnitude > 0, "Off-center hit must produce rotational torque")
  -- Lever arm is (0, 2, 0). Impulse points along +X (approx). Lever:Cross(Impulse) should point in -Z.
  assertApprox(resTorque.TorqueVector.Z, -2000, 100, "Torque vector Z component check")
end

-- 6. Batch Solving and Sorting
do
  local blast = {
    Position = Vector3.new(0, 0, 0),
    Radius = 100,
    BaseDamage = 100,
    MaxImpulse = 500,
    Falloff = "Linear" :: "Linear",
  }

  local targets = {
    { Id = "far", Position = Vector3.new(80, 0, 0) },
    { Id = "close", Position = Vector3.new(10, 0, 0) },
    { Id = "mid", Position = Vector3.new(40, 0, 0) },
    { Id = "out", Position = Vector3.new(150, 0, 0) },
  }

  local byDist = solver:SolveBatch(blast, targets, "Distance")
  assert(#byDist == 3, "Out of range target should be filtered out")
  assert(byDist[1].TargetId == "close", "Closest target should be first")
  assert(byDist[2].TargetId == "mid", "Mid target should be second")
  assert(byDist[3].TargetId == "far", "Far target should be third")

  local byDmg = solver:SolveBatch(blast, targets, "Damage")
  assert(byDmg[1].TargetId == "close", "Highest damage target should be first")
  assert(byDmg[3].TargetId == "far", "Lowest damage target should be third")
end

print("ExplosionImpulseSolver unit tests passed successfully!")
