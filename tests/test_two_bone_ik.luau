--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local TwoBoneIK = require("../src/ReplicatedStorage/Animation/TwoBoneIK")

local EPSILON = 0.01

-- 1. Test basic reachable two-bone chain
local rootPos = Vector3.new(0, 10, 0)
local targetPos = Vector3.new(0, 5, 2)
local polePos = Vector3.new(0, 7.5, 5) -- forward bend
local upperLen = 3.0
local lowerLen = 3.0

local sol = TwoBoneIK.Solve(rootPos, targetPos, polePos, upperLen, lowerLen)

assert(sol ~= nil, "Solution should not be nil")
assert(sol.IsOverextended == false, "Target should be within reach")
assert(sol.ReachRatio < 1.0, "Reach ratio should be under 1.0")

local upperDist = (sol.JointPosition - rootPos).Magnitude
local lowerDist = (targetPos - sol.JointPosition).Magnitude

assert(math.abs(upperDist - upperLen) < EPSILON, string.format("Upper bone length mismatch: got %.4f expected %.4f", upperDist, upperLen))
assert(math.abs(lowerDist - lowerLen) < EPSILON, string.format("Lower bone length mismatch: got %.4f expected %.4f", lowerDist, lowerLen))
assert(sol.JointPosition.Z > 0, "Knee joint should bend forward towards pole vector")

-- 2. Test overextended limb reach clamp
local farTarget = Vector3.new(0, 10, 20) -- 20 studs away, max reach is 6.0
local farSol = TwoBoneIK.Solve(rootPos, farTarget, polePos, upperLen, lowerLen)

assert(farSol.IsOverextended == true, "Far target should be flagged as overextended")
assert(farSol.ReachRatio > 1.0, "Reach ratio should exceed 1.0")
local effectiveReach = (farSol.EffectorCFrame.Position - rootPos).Magnitude
assert(math.abs(effectiveReach - (upperLen + lowerLen)) < EPSILON, "Effector should clamp to max reach")

-- 3. Test minimum reach handling (target very close to root)
local closeTarget = Vector3.new(0, 9.99, 0)
local closeSol = TwoBoneIK.Solve(rootPos, closeTarget, polePos, upperLen, lowerLen)
assert(closeSol ~= nil, "Close target should solve without NaN")
assert(not (closeSol.JointPosition.X ~= closeSol.JointPosition.X), "Joint position must not contain NaN")

-- 4. Test foot normal alignment
local baseFootCF = CFrame.new(0, 0, 0)
local groundNormal = Vector3.new(0, 0.7071, 0.7071).Unit -- 45-degree slope
local alignedCF = TwoBoneIK.AlignFoot(baseFootCF, groundNormal, math.rad(60))

local upDot = alignedCF.UpVector:Dot(groundNormal)
assert(math.abs(upDot - 1.0) < 0.05, "Aligned foot up vector should match ground normal")

-- 5. Test pelvic drop calculation
local rootCF = CFrame.new(0, 10, 0)
local legs = {
  {
    HipOffset = Vector3.new(-1, 0, 0),
    UpperLength = 3.0,
    LowerLength = 3.0,
    HitTarget = Vector3.new(-1, 4.5, 0), -- 5.5 studs down (within 6.0 reach)
  },
  {
    HipOffset = Vector3.new(1, 0, 0),
    UpperLength = 3.0,
    LowerLength = 3.0,
    HitTarget = Vector3.new(1, 3.5, 0), -- 6.5 studs down (exceeds 5.7 stud 95% threshold)
  },
}

local pelvicDrop = TwoBoneIK.CalculatePelvicDrop(rootCF, legs, 2.5)
assert(pelvicDrop < 0, "Pelvic drop should be negative to lower the root")
assert(math.abs(pelvicDrop) <= 2.5, "Pelvic drop should not exceed max drop limit")

-- 6. Test foot target prediction during locomotion
local hipPos = Vector3.new(0, 8, 0)
local velocity = Vector3.new(0, 0, 16) -- moving 16 studs/sec forward
local pred = TwoBoneIK.PredictTarget(hipPos, velocity, 6.0, 3.0, 0.15)

assert(pred.Z > hipPos.Z, "Predicted foot target should lead in direction of velocity")
assert(pred.Y == 3.0, "Predicted target should match ground plane Y")

print("PASS: TwoBoneIK tests (Analytical solve, Pole vector, Overextension clamp, NaN resistance, Normal alignment, Pelvic drop, Stride prediction) passed cleanly!")
