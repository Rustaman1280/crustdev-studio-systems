local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local MotionMatchingDatabase = require("../src/ReplicatedStorage/Animation/MotionMatchingDatabase")

-- Helper to make a dummy pose
local function makePose(leftPos: Vector3, rightPos: Vector3, rootVel: Vector3, rootAngVel: number)
  return {
    leftFootPosition = leftPos,
    leftFootVelocity = Vector3.new(0, 0, 0),
    rightFootPosition = rightPos,
    rightFootVelocity = Vector3.new(0, 0, 0),
    rootVelocity = rootVel,
    rootAngularVelocity = rootAngVel,
  }
end

-- Test 1: Database Initialization & Frame Storage
local mm = MotionMatchingDatabase.new({
  trajectoryPosition = 1.0,
  trajectoryFacing = 1.0,
  continuityHysteresis = 0.4,
})

assert(mm:GetFrameCount() == 0, "Initial frame count must be 0")

-- Add Idle frame
mm:AddFrame({
  clipName = "idle",
  frameIndex = 1,
  time = 0.0,
  trajectory = {
    { timeOffset = 0.2, position = Vector3.new(0, 0, 0), facingAngle = 0 },
    { timeOffset = 0.5, position = Vector3.new(0, 0, 0), facingAngle = 0 },
    { timeOffset = 1.0, position = Vector3.new(0, 0, 0), facingAngle = 0 },
  },
  pose = makePose(Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 0, 0), 0),
  tags = { idle = true, locomotion = true },
  canTransition = true,
})

-- Add Walk Forward frame
mm:AddFrame({
  clipName = "walk_fwd",
  frameIndex = 1,
  time = 0.0,
  trajectory = {
    { timeOffset = 0.2, position = Vector3.new(0, 0, -2), facingAngle = 0 },
    { timeOffset = 0.5, position = Vector3.new(0, 0, -5), facingAngle = 0 },
    { timeOffset = 1.0, position = Vector3.new(0, 0, -10), facingAngle = 0 },
  },
  pose = makePose(Vector3.new(-1, 0, -1), Vector3.new(1, 0, 1), Vector3.new(0, 0, -10), 0),
  tags = { walk = true, locomotion = true },
  canTransition = true,
})

-- Add Walk Forward frame 2 (sequential)
mm:AddFrame({
  clipName = "walk_fwd",
  frameIndex = 2,
  time = 0.033,
  trajectory = {
    { timeOffset = 0.2, position = Vector3.new(0, 0, -2.2), facingAngle = 0 },
    { timeOffset = 0.5, position = Vector3.new(0, 0, -5.2), facingAngle = 0 },
    { timeOffset = 1.0, position = Vector3.new(0, 0, -10.2), facingAngle = 0 },
  },
  pose = makePose(Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 0, -10), 0),
  tags = { walk = true, locomotion = true },
  canTransition = true,
})

-- Add Sprint frame
mm:AddFrame({
  clipName = "sprint_fwd",
  frameIndex = 1,
  time = 0.0,
  trajectory = {
    { timeOffset = 0.2, position = Vector3.new(0, 0, -4), facingAngle = 0 },
    { timeOffset = 0.5, position = Vector3.new(0, 0, -11), facingAngle = 0 },
    { timeOffset = 1.0, position = Vector3.new(0, 0, -24), facingAngle = 0 },
  },
  pose = makePose(Vector3.new(-1.2, 0.5, -2), Vector3.new(1.2, 0, 2), Vector3.new(0, 0, -24), 0),
  tags = { sprint = true, locomotion = true },
  canTransition = true,
})

-- Add Sharp Turn Left frame
mm:AddFrame({
  clipName = "turn_left",
  frameIndex = 1,
  time = 0.0,
  trajectory = {
    { timeOffset = 0.2, position = Vector3.new(-2, 0, -1), facingAngle = math.rad(30) },
    { timeOffset = 0.5, position = Vector3.new(-5, 0, -2), facingAngle = math.rad(60) },
    { timeOffset = 1.0, position = Vector3.new(-10, 0, -3), facingAngle = math.rad(90) },
  },
  pose = makePose(Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(-8, 0, -3), 1.5),
  tags = { turn = true, locomotion = true },
  canTransition = true,
})

assert(mm:GetFrameCount() == 5, "Frame count should be 5")

-- Test 2: Analytical Trajectory Prediction
local predictedTraj = mm:PredictTrajectory(
  Vector3.new(0, 0, -5),
  Vector3.new(0, 0, -1),
  16.0,
  4.0,
  { 0.2, 0.5, 1.0 }
)

assert(#predictedTraj == 3, "Predicted trajectory must yield 3 points")
assert(predictedTraj[1].position.Z < 0, "Trajectory position should project forward (-Z)")
assert(predictedTraj[3].position.Z < predictedTraj[1].position.Z, "Further horizon must be farther ahead")

-- Test 3: Search Best Match for Idle Query
local idleQuery = {
  desiredTrajectory = {
    { timeOffset = 0.2, position = Vector3.new(0, 0, 0), facingAngle = 0 },
    { timeOffset = 0.5, position = Vector3.new(0, 0, 0), facingAngle = 0 },
    { timeOffset = 1.0, position = Vector3.new(0, 0, 0), facingAngle = 0 },
  },
  currentPose = makePose(Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 0, 0), 0),
}

local idleMatch = mm:SearchBestMatch(idleQuery)
assert(idleMatch ~= nil, "Idle query must return a match")
assert(idleMatch.frame.clipName == "idle", string.format("Expected idle clip, got %s", idleMatch.frame.clipName))

-- Test 4: Search Best Match for High Speed (Sprint)
local sprintQuery = {
  desiredTrajectory = {
    { timeOffset = 0.2, position = Vector3.new(0, 0, -4), facingAngle = 0 },
    { timeOffset = 0.5, position = Vector3.new(0, 0, -11), facingAngle = 0 },
    { timeOffset = 1.0, position = Vector3.new(0, 0, -24), facingAngle = 0 },
  },
  currentPose = makePose(Vector3.new(-1.2, 0.5, -2), Vector3.new(1.2, 0, 2), Vector3.new(0, 0, -24), 0),
}

local sprintMatch = mm:SearchBestMatch(sprintQuery)
assert(sprintMatch ~= nil, "Sprint query must return a match")
assert(sprintMatch.frame.clipName == "sprint_fwd", string.format("Expected sprint clip, got %s", sprintMatch.frame.clipName))

-- Test 5: Tag Filtering
local tagQuery = {
  desiredTrajectory = idleQuery.desiredTrajectory,
  currentPose = idleQuery.currentPose,
  requiredTag = "sprint", -- Must select sprint despite idle query
}
local tagMatch = mm:SearchBestMatch(tagQuery)
assert(tagMatch ~= nil, "Tag filtered query should match")
assert(tagMatch.frame.clipName == "sprint_fwd", "Must match sprint clip due to requiredTag filter")

-- Test 6: Continuity Hysteresis
local seqQuery = {
  desiredTrajectory = {
    { timeOffset = 0.2, position = Vector3.new(0, 0, -2.1), facingAngle = 0 },
    { timeOffset = 0.5, position = Vector3.new(0, 0, -5.1), facingAngle = 0 },
    { timeOffset = 1.0, position = Vector3.new(0, 0, -10.1), facingAngle = 0 },
  },
  currentPose = makePose(Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 0, -10), 0),
  currentClipName = "walk_fwd",
  currentFrameIndex = 1,
}
local seqMatch = mm:SearchBestMatch(seqQuery)
assert(seqMatch ~= nil, "Sequential query should return match")
assert(seqMatch.frame.clipName == "walk_fwd" and seqMatch.frame.frameIndex == 2, "Continuity hysteresis should favor sequential next frame")
assert(seqMatch.isSequentialContinuity == true, "Should flag isSequentialContinuity true")

-- Test 7: Inertialization Blend Solver
local state = mm:CreateInertializer(
  Vector3.new(10, 5, 0),
  Vector3.new(12, 5, 0),
  Vector3.new(2, 0, 0),
  Vector3.new(1, 0, 0),
  0.25 -- 250ms blend
)

assert(state.remainingTime == 0.25, "Initial duration must be 0.25")
local offset1, done1 = mm:UpdateInertializer(state, 0.1)
assert(not done1, "Should not be done after 0.1s")
assert(offset1.Magnitude > 0, "Offset should be non-zero during blend")

local offsetFinal, doneFinal = mm:UpdateInertializer(state, 0.2)
assert(doneFinal, "Should be complete after full duration")
assert(offsetFinal.Magnitude < 1e-4, "Final offset should decay to zero")

print("PASS: MotionMatchingDatabase tests (Storage, TrajectoryPrediction, QueryMatching, TagFiltering, ContinuityHysteresis, Inertializer) passed cleanly!")
return true