local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame
Vector3 = roblox.Vector3
CFrame = roblox.CFrame

local FABRIKSolver = require("../src/ReplicatedStorage/Animation/FABRIKSolver")

-- Test 1: Initialization and Chain Invariants
local chain = FABRIKSolver.new({
  Vector3.new(0, 0, 0),
  Vector3.new(0, 5, 0),
  Vector3.new(0, 10, 0),
  Vector3.new(0, 15, 0),
})

assert(chain:GetJointCount() == 4, "Chain must have 4 joints")
assert(math.abs(chain:GetTotalLength() - 15.0) < 0.001, "Total length must be 15 studs")
assert(math.abs(chain:GetBoneLength(1) - 5.0) < 0.001, "Bone 1 length must be 5")
assert(math.abs(chain:GetBoneLength(2) - 5.0) < 0.001, "Bone 2 length must be 5")
assert(math.abs(chain:GetBoneLength(3) - 5.0) < 0.001, "Bone 3 length must be 5")

-- Test fromBoneLengths constructor
local chain2 = FABRIKSolver.fromBoneLengths(Vector3.new(1, 2, 3), Vector3.new(1, 0, 0), { 4, 6, 8 })
assert(chain2:GetJointCount() == 4, "Constructed chain must have 4 joints")
assert(math.abs(chain2:GetTotalLength() - 18.0) < 0.001, "Constructed chain total length must be 18")
local pEnd = chain2:GetJointPosition(4)
assert(math.abs(pEnd.X - 19) < 0.001 and math.abs(pEnd.Y - 2) < 0.001, "End joint must be at (19, 2, 3)")

-- Test 2: Unreachable Target (Target beyond max extension)
local unreachableTarget = Vector3.new(0, 30, 0) -- Dist is 30, max chain length is 15
local resUnreachable = chain:Solve(unreachableTarget)
assert(resUnreachable.isReachable == false, "Target at dist 30 must be marked unreachable")
assert(resUnreachable.iterations == 0, "Unreachable solve should use 0 iterations (analytical straight reach)")
assert(math.abs(resUnreachable.errorDistance - 15.0) < 0.01, "Error distance should be 30 - 15 = 15")
local endPos = chain:GetJointPosition(4)
assert(math.abs(endPos.Y - 15.0) < 0.01, "End position Y must be extended to 15.0")

-- Test 3: Reachable Target 2-Bone Arm/Leg
local twoBone = FABRIKSolver.fromBoneLengths(Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), { 5, 5 })
local target2B = Vector3.new(3, 4, 0) -- Distance sqrt(9 + 16) = 5 <= 10
local sol2B = twoBone:Solve(target2B, { tolerance = 0.001 })
assert(sol2B.isReachable == true, "Target (3, 4, 0) must be reachable")
assert(sol2B.errorDistance < 0.001, "Final effector error distance must be < 0.001 studs")
assert(sol2B.iterations <= 10, "Should converge rapidly within 10 iterations")

-- Invariant: Bone lengths must be strictly preserved
local bone1Len = (twoBone:GetJointPosition(2) - twoBone:GetJointPosition(1)).Magnitude
local bone2Len = (twoBone:GetJointPosition(3) - twoBone:GetJointPosition(2)).Magnitude
assert(math.abs(bone1Len - 5.0) < 0.001, "Bone 1 length must remain 5.0")
assert(math.abs(bone2Len - 5.0) < 0.001, "Bone 2 length must remain 5.0")

-- Test 4: Multi-Bone Tentacle / Spine Chain (5 segments, 6 joints)
local tentacle = FABRIKSolver.fromBoneLengths(Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), { 3, 3, 3, 3, 3 })
assert(tentacle:GetJointCount() == 6, "Tentacle must have 6 joints")
assert(math.abs(tentacle:GetTotalLength() - 15.0) < 0.001, "Tentacle total length must be 15")

local tentacleTarget = Vector3.new(6, 6, 4) -- Distance sqrt(36 + 36 + 16) = sqrt(88) approx 9.38 < 15
local solTentacle = tentacle:Solve(tentacleTarget, { tolerance = 0.001, maxIterations = 20 })
assert(solTentacle.isReachable == true, "Tentacle target should be reachable")
assert(solTentacle.errorDistance < 0.001, "Tentacle end-effector error must be < 0.001")

-- Check every bone length in the 5-segment tentacle
for b = 1, 5 do
  local curLen = (tentacle:GetJointPosition(b + 1) - tentacle:GetJointPosition(b)).Magnitude
  assert(math.abs(curLen - 3.0) < 0.01, string.format("Tentacle bone %d length must remain 3.0", b))
end

-- Test 5: Pole Vector Alignment
local armWithPole = FABRIKSolver.fromBoneLengths(Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), { 6, 6 })
local poleTarget = Vector3.new(0, 4, 10) -- Pull elbow forward in +Z direction
local solPole = armWithPole:Solve(Vector3.new(0, 8, 0), {
  tolerance = 0.001,
  poleTarget = poleTarget,
  poleJointIndex = 2,
})
assert(solPole.isReachable == true, "Arm with pole target should solve")
local elbowPos = armWithPole:GetJointPosition(2)
-- Elbow should have positive Z component due to pole target at Z = 10
assert(elbowPos.Z > 0.5, "Elbow joint must be biased forward towards pole target in +Z")

-- Test 6: Root Position Shifting & Reset
local movableChain = FABRIKSolver.new({
  Vector3.new(0, 0, 0),
  Vector3.new(0, 4, 0),
  Vector3.new(0, 8, 0),
})
movableChain:SetRootPosition(Vector3.new(10, 0, 0))
assert(math.abs(movableChain:GetJointPosition(1).X - 10) < 0.001, "Root joint X should be 10")
assert(math.abs(movableChain:GetJointPosition(3).X - 10) < 0.001, "End joint X should be 10")

movableChain:Reset()
assert(math.abs(movableChain:GetJointPosition(1).X - 0) < 0.001, "Reset must restore original position 0")

-- Test 7: CFrames Generation
local cframes = movableChain:GetJointCFrames()
assert(#cframes == 3, "Must return 3 CFrames for 3 joints")
for idx, cf in ipairs(cframes) do
  assert(cf ~= nil, string.format("CFrame at joint %d must not be nil", idx))
  -- Check no NaN values
  local x, y, z = cf.X, cf.Y, cf.Z
  assert(x == x and y == y and z == z, "CFrame position components must not be NaN")
end

print("PASS: FABRIKSolver tests (Init, Invariants, Unreachable, Reachable, MultiBone, PoleVector, RootShift, Reset, CFrames) passed cleanly!")
