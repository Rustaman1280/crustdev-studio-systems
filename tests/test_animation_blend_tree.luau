local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
_G.Vector3 = Vector3
_G.CFrame = CFrame

local AnimationBlendTree = require("../src/ReplicatedStorage/Animation/AnimationBlendTree")

local EPSILON = 1e-3

-- Mock clip generator: returns static or phase-animated transforms for key bones
local function createMockClip(posOffset: Vector3, rotOffset: CFrame)
  return function(phase: number)
    return {
      Root = { Position = Vector3.new(0, 3, 0) + posOffset * phase, Rotation = rotOffset },
      UpperTorso = { Position = Vector3.new(0, 4.5, 0), Rotation = rotOffset },
      RightArm = { Position = Vector3.new(1.5, 4.5, 0) + posOffset, Rotation = rotOffset },
      LeftArm = { Position = Vector3.new(-1.5, 4.5, 0), Rotation = rotOffset },
      RightLeg = { Position = Vector3.new(0.5, 1.5, 0) + posOffset * math.sin(phase * math.pi * 2), Rotation = CFrame.identity },
      LeftLeg = { Position = Vector3.new(-0.5, 1.5, 0) - posOffset * math.sin(phase * math.pi * 2), Rotation = CFrame.identity },
    }
  end
end

-- Test 1: 1D Blend Space linear interpolation
do
  local idlePose = createMockClip(Vector3.new(0, 0, 0), CFrame.identity)
  local runPose = createMockClip(Vector3.new(0, 0, 2), CFrame.Angles(0.2, 0, 0))

  local space1D = AnimationBlendTree.CreateBlendSpace1D({
    { Value = 0, Duration = 2.0, SamplePose = idlePose },
    { Value = 10, Duration = 0.8, SamplePose = runPose },
  })

  -- Test at Value = 0 (exact match idle)
  local p0 = AnimationBlendTree.EvaluateBlendSpace1D(space1D, 0, 0)
  assert((p0.Root.Position - Vector3.new(0, 3, 0)).Magnitude < EPSILON, "Root position at value 0 should match idle")

  -- Test at Value = 5 (50% blend midpoint)
  local p5 = AnimationBlendTree.EvaluateBlendSpace1D(space1D, 5, 0)
  -- Interpolated RightArm pos: midpoint between (1.5, 4.5, 0) and (1.5, 4.5, 2) is (1.5, 4.5, 1)
  assert(math.abs(p5.RightArm.Position.Z - 1.0) < EPSILON, "RightArm Z position should be 1.0 at 50% blend")

  -- Test phase progression
  local initialPhase = space1D.CurrentPhase
  AnimationBlendTree.EvaluateBlendSpace1D(space1D, 5, 0.1)
  assert(space1D.CurrentPhase > initialPhase, "Phase should advance forward over dt")
end

-- Test 2: 2D Directional Blend Space interpolation
do
  local idle = createMockClip(Vector3.new(0, 0, 0), CFrame.identity)
  local fwd = createMockClip(Vector3.new(0, 0, 2), CFrame.Angles(0.3, 0, 0))
  local back = createMockClip(Vector3.new(0, 0, -2), CFrame.Angles(-0.3, 0, 0))
  local right = createMockClip(Vector3.new(2, 0, 0), CFrame.Angles(0, 0, -0.3))
  local left = createMockClip(Vector3.new(-2, 0, 0), CFrame.Angles(0, 0, 0.3))

  local space2D = AnimationBlendTree.CreateBlendSpace2D({
    { X = 0, Y = 0, Duration = 1.0, SamplePose = idle },
    { X = 0, Y = 1, Duration = 0.8, SamplePose = fwd },
    { X = 0, Y = -1, Duration = 0.8, SamplePose = back },
    { X = 1, Y = 0, Duration = 0.8, SamplePose = right },
    { X = -1, Y = 0, Duration = 0.8, SamplePose = left },
  })

  -- Exact match Forward (0, 1)
  local pFwd = AnimationBlendTree.EvaluateBlendSpace2D(space2D, 0, 1, 0)
  assert(math.abs(pFwd.RightArm.Position.Z - 2.0) < EPSILON, "Forward pose should match forward clip Z offset")

  -- Diagonal Strafe (0.707, 0.707)
  local pDiag = AnimationBlendTree.EvaluateBlendSpace2D(space2D, 0.707, 0.707, 0)
  -- Should have positive X and positive Z displacement
  assert(pDiag.RightArm.Position.X > 1.5, "RightArm should be biased to the right")
  assert(pDiag.RightArm.Position.Z > 0.5, "RightArm should be biased forward")
end

-- Test 3: Skeletal Bone Masking and Layered Additive Blending
do
  local tree = AnimationBlendTree.new()

  -- Base locomotion node (Idle)
  local baseNode = {
    Type = "Clip",
    Duration = 1.0,
    SamplePose = createMockClip(Vector3.new(0, 0, 0), CFrame.identity),
  }
  tree:RegisterNode("BaseLocomotion", baseNode)

  -- Additive aiming overlay (RightArm raised up by +3 studs)
  local aimNode = {
    Type = "Clip",
    Duration = 1.0,
    SamplePose = function(_phase: number)
      return {
        RightArm = { Position = Vector3.new(1.5, 7.5, 0), Rotation = CFrame.Angles(1.2, 0, 0) },
        LeftArm = { Position = Vector3.new(-1.5, 7.5, 0), Rotation = CFrame.Angles(1.2, 0, 0) },
      }
    end,
  }
  tree:RegisterNode("AimOverlay", aimNode)

  -- Mask applying 100% to RightArm, but 0% to legs
  local boneMask = {
    RightArm = 1.0,
    RightLeg = 0.0,
    LeftLeg = 0.0,
  }

  tree:AddLayer("Aiming", "AimOverlay", 0.5, boneMask)

  local pose = tree:Update(0.016)
  -- RightArm was (1.5, 4.5, 0), aiming overlay is (1.5, 7.5, 0).
  -- At alpha 0.5 with mask 1.0: Y should be 4.5 + 0.5 * (7.5 - 4.5) = 6.0
  assert(math.abs(pose.RightArm.Position.Y - 6.0) < EPSILON, "RightArm Y should blend to 6.0")

  -- RightLeg should be untouched by mask
  assert(pose.RightLeg ~= nil, "RightLeg should remain present from base pose")
end

-- Test 4: Cross-Fading state transitions
do
  local tree = AnimationBlendTree.new()

  local nodeA = {
    Type = "Clip",
    Duration = 1.0,
    SamplePose = createMockClip(Vector3.new(0, 0, 0), CFrame.identity),
  }
  local nodeB = {
    Type = "Clip",
    Duration = 1.0,
    SamplePose = createMockClip(Vector3.new(10, 0, 0), CFrame.identity),
  }

  tree:RegisterNode("StateA", nodeA)
  tree:RegisterNode("StateB", nodeB)
  tree:SetActiveState("StateA")

  -- Initial state is 100% StateA
  local poseInit = tree:Update(0)
  assert(math.abs(poseInit.RightArm.Position.X - 1.5) < EPSILON, "Initial pose must match StateA")

  -- Initiate cross-fade to StateB over 0.5s
  tree:CrossFade("StateB", 0.5, "Linear")

  -- Advance 0.25s (50% progress)
  local poseMid = tree:Update(0.25)
  -- RightArm X was 1.5 in StateA, 11.5 in StateB -> at 50% it should be 6.5
  assert(math.abs(poseMid.RightArm.Position.X - 6.5) < 0.1, string.format("Midpoint X should be ~6.5, got %f", poseMid.RightArm.Position.X))

  -- Advance remaining 0.3s (exceeding 0.5s duration)
  local poseFinal = tree:Update(0.3)
  assert(math.abs(poseFinal.RightArm.Position.X - 11.5) < 0.1, "Final pose must match StateB")
  assert(tree._activeState == "StateB", "Active state should automatically become StateB")
  assert(tree._transitionTarget == nil, "Transition target should clear upon completion")
end

print("test_animation_blend_tree: all tests passed successfully!")
return true