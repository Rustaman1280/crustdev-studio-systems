local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
_G.Vector3 = Vector3
_G.CFrame = CFrame

local SpringBonePhysics = require("../src/ReplicatedStorage/Physics/SpringBonePhysics")

local EPSILON = 1e-3

-- Test 1: Basic bone chain construction and rest pose
do
  local rootCF = CFrame.new(Vector3.new(0, 10, 0))
  local sim = SpringBonePhysics.new(rootCF)
  sim:SetGravity(Vector3.new(0, 0, 0)) -- Zero gravity for clean rest pose test

  -- Add bone 1: hangs down by 2 studs
  local b1 = sim:AddBone(nil, Vector3.new(0, -2, 0), {
    Stiffness = 50,
    Damping = 5,
    Drag = 1,
    Radius = 0.5,
  })

  -- Add bone 2: hangs down from bone 1 by another 2 studs
  local b2 = sim:AddBone(b1, Vector3.new(0, -2, 0), {
    Stiffness = 50,
    Damping = 5,
    Drag = 1,
    Radius = 0.5,
  })

  assert(sim:GetBoneCount() == 2, "Bone count must be 2")

  local p1 = sim:GetBonePosition(b1)
  local p2 = sim:GetBonePosition(b2)
  assert(p1 ~= nil and p2 ~= nil, "Bone positions must exist")

  -- Bone 1 rest pos should be (0, 8, 0)
  assert((p1 - Vector3.new(0, 8, 0)).Magnitude < EPSILON, "Bone 1 rest position should be (0, 8, 0)")
  -- Bone 2 rest pos should be (0, 6, 0)
  assert((p2 - Vector3.new(0, 6, 0)).Magnitude < EPSILON, "Bone 2 rest position should be (0, 6, 0)")
end

-- Test 2: Invariant bone length preservation across simulation steps
do
  local rootCF = CFrame.new(Vector3.new(0, 10, 0))
  local sim = SpringBonePhysics.new(rootCF)
  sim:SetGravity(Vector3.new(0, -20, 0))

  local b1 = sim:AddBone(nil, Vector3.new(0, -3, 0))
  local b2 = sim:AddBone(b1, Vector3.new(0, -2.5, 0))

  -- Apply erratic external impulse
  local impulse = Vector3.new(15, 5, -8)

  for step = 1, 60 do
    sim:Step(1 / 60, rootCF, step == 1 and impulse or Vector3.new(0, 0, 0))

    local p1 = sim:GetBonePosition(b1) :: Vector3
    local p2 = sim:GetBonePosition(b2) :: Vector3

    local len1 = (p1 - rootCF.Position).Magnitude
    local len2 = (p2 - p1).Magnitude

    assert(math.abs(len1 - 3.0) < EPSILON, string.format("Bone 1 length must stay invariant 3.0 (got %.5f)", len1))
    assert(math.abs(len2 - 2.5) < EPSILON, string.format("Bone 2 length must stay invariant 2.5 (got %.5f)", len2))
  end
end

-- Test 3: Damped settling back to equilibrium
do
  local rootCF = CFrame.new(Vector3.new(0, 10, 0))
  local sim = SpringBonePhysics.new(rootCF)
  sim:SetGravity(Vector3.new(0, 0, 0)) -- Zero gravity to test pure rest return

  local b1 = sim:AddBone(nil, Vector3.new(0, -4, 0), {
    Stiffness = 80,
    Damping = 12,
    Drag = 2,
  })

  -- Inject strong sideways impulse
  sim:Step(1 / 60, rootCF, Vector3.new(50, 0, 0))

  -- Step simulation forward 3 seconds (180 frames)
  for _ = 1, 180 do
    sim:Step(1 / 60, rootCF)
  end

  local settledPos = sim:GetBonePosition(b1) :: Vector3
  local restPos = Vector3.new(0, 6, 0)
  local distToRest = (settledPos - restPos).Magnitude

  assert(distToRest < 0.05, string.format("Bone must damp back to rest pose within 0.05 studs (got %.5f)", distToRest))
end

-- Test 4: Sphere collider collision push-out
do
  local rootCF = CFrame.new(Vector3.new(0, 10, 0))
  local sim = SpringBonePhysics.new(rootCF)
  sim:SetGravity(Vector3.new(0, -10, 0))

  -- Bone hangs straight down to (0, 7, 0)
  local boneRadius = 0.5
  local b1 = sim:AddBone(nil, Vector3.new(0, -3, 0), {
    Radius = boneRadius,
    Stiffness = 20,
    Damping = 5,
  })

  -- Place a sphere collider directly at (0, 7.2, 0) with radius 1.5
  local colCenter = Vector3.new(0, 7.2, 0)
  local colRadius = 1.5
  sim:AddSphereCollider(colCenter, colRadius)

  -- Run simulation
  for _ = 1, 60 do
    sim:Step(1 / 60, rootCF)
    local pos = sim:GetBonePosition(b1) :: Vector3
    local distToCol = (pos - colCenter).Magnitude

    -- Bone must not penetrate inside collider surface (dist >= colRadius + boneRadius - tolerance)
    assert(distToCol >= (colRadius + boneRadius) - 0.05,
      string.format("Bone must not penetrate collider: dist %.4f < min %.4f", distToCol, colRadius + boneRadius))
  end
end

-- Test 5: Angle limit constraint
do
  local rootCF = CFrame.new(Vector3.new(0, 10, 0))
  local sim = SpringBonePhysics.new(rootCF)
  sim:SetGravity(Vector3.new(0, 0, 0))

  local maxAngleRad = math.rad(30)
  local b1 = sim:AddBone(nil, Vector3.new(0, -4, 0), {
    AngleLimitRad = maxAngleRad,
    Stiffness = 10,
    Damping = 2,
  })

  -- Apply massive lateral force that would push bone 90 degrees without constraint
  for _ = 1, 30 do
    sim:Step(1 / 60, rootCF, Vector3.new(200, 0, 0))
    local pos = sim:GetBonePosition(b1) :: Vector3
    local dir = (pos - rootCF.Position).Unit
    local restDir = Vector3.new(0, -1, 0)
    local dot = math.clamp(dir:Dot(restDir), -1, 1)
    local angle = math.acos(dot)

    assert(angle <= maxAngleRad + 0.02,
      string.format("Angle %.4f rad must not exceed limit %.4f rad", angle, maxAngleRad))
  end
end

-- Test 6: Reset restores rest positions
do
  local rootCF = CFrame.new(Vector3.new(0, 10, 0))
  local sim = SpringBonePhysics.new(rootCF)
  local b1 = sim:AddBone(nil, Vector3.new(0, -5, 0))

  sim:Step(1 / 60, rootCF, Vector3.new(50, 20, 0))
  sim:Reset(rootCF)

  local pos = sim:GetBonePosition(b1) :: Vector3
  assert((pos - Vector3.new(0, 5, 0)).Magnitude < EPSILON, "Reset must immediately return bone to rest pose")
end

print("SpringBonePhysics unit tests passed successfully!")
