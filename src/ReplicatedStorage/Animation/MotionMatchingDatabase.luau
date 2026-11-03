--!strict
--[[
  MotionMatchingDatabase.luau
  crustdev studio systems - ReplicatedStorage/Animation/MotionMatchingDatabase

  Production-grade animation synthesis database using Motion Matching:
  - Trajectory feature matching: projected future root positions and facing orientations across multiple time horizons.
  - Pose feature matching: character-space bone locations (feet/hands) and velocities for continuity and anti-foot-sliding.
  - Configurable multi-dimensional metric weight normalization and continuity hysteresis bias to prevent frame flickering.
  - Analytical trajectory prediction generator modeling user stick input, acceleration, and angular turn rates.
  - Inertialization blend solver: seamless pop-free pose transitions via polynomial decay without expensive dual-tree evaluation.
  - Tag gating and query filtering for dynamic locomotion modes (idle, walk, run, sprint, combat stance).
  - Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local ZERO_VECTOR = Vector3.new(0, 0, 0)

export type TrajectoryPoint = {
  timeOffset: number,
  position: Vector3, -- Character local coordinates
  facingAngle: number, -- Local facing yaw in radians
}

export type PoseFeature = {
  leftFootPosition: Vector3,
  leftFootVelocity: Vector3,
  rightFootPosition: Vector3,
  rightFootVelocity: Vector3,
  rootVelocity: Vector3,
  rootAngularVelocity: number,
}

export type MotionFrame = {
  clipName: string,
  frameIndex: number,
  time: number,
  trajectory: { TrajectoryPoint },
  pose: PoseFeature,
  tags: { [string]: boolean },
  canTransition: boolean,
}

export type FeatureWeights = {
  trajectoryPosition: number,
  trajectoryFacing: number,
  posePosition: number,
  poseVelocity: number,
  rootVelocity: number,
  rootAngularVelocity: number,
  continuityHysteresis: number, -- Cost discount for sequential next frame
}

export type QueryContext = {
  desiredTrajectory: { TrajectoryPoint },
  currentPose: PoseFeature,
  requiredTag: string?,
  currentClipName: string?,
  currentFrameIndex: number?,
}

export type MatchResult = {
  frame: MotionFrame,
  cost: number,
  isSequentialContinuity: boolean,
}

export type InertializerState = {
  positionOffset: Vector3,
  velocityOffset: Vector3,
  remainingTime: number,
  totalDuration: number,
}

export type MotionMatchingDatabaseInstance = {
  Frames: { MotionFrame },
  Weights: FeatureWeights,

  AddFrame: (self: MotionMatchingDatabaseInstance, frame: MotionFrame) -> number,
  GetFrameCount: (self: MotionMatchingDatabaseInstance) -> number,
  GetFrame: (self: MotionMatchingDatabaseInstance, index: number) -> MotionFrame?,
  SetWeights: (self: MotionMatchingDatabaseInstance, weights: PartialFeatureWeights) -> (),
  SearchBestMatch: (self: MotionMatchingDatabaseInstance, query: QueryContext) -> MatchResult?,
  PredictTrajectory: (
    self: MotionMatchingDatabaseInstance,
    currentVelocity: Vector3,
    desiredInputDirection: Vector3,
    desiredSpeed: number,
    turnRate: number,
    sampleHorizons: { number }
  ) -> { TrajectoryPoint },
  CreateInertializer: (
    self: MotionMatchingDatabaseInstance,
    currentPos: Vector3,
    targetPos: Vector3,
    currentVel: Vector3,
    targetVel: Vector3,
    duration: number
  ) -> InertializerState,
  UpdateInertializer: (
    self: MotionMatchingDatabaseInstance,
    state: InertializerState,
    dt: number
  ) -> (Vector3, boolean),
  Clear: (self: MotionMatchingDatabaseInstance) -> (),
}

export type PartialFeatureWeights = {
  trajectoryPosition: number?,
  trajectoryFacing: number?,
  posePosition: number?,
  poseVelocity: number?,
  rootVelocity: number?,
  rootAngularVelocity: number?,
  continuityHysteresis: number?,
}

local MotionMatchingDatabase = {}
MotionMatchingDatabase.__index = MotionMatchingDatabase

local DEFAULT_WEIGHTS: FeatureWeights = {
  trajectoryPosition = 1.0,
  trajectoryFacing = 1.5,
  posePosition = 0.8,
  poseVelocity = 0.4,
  rootVelocity = 1.0,
  rootAngularVelocity = 0.5,
  continuityHysteresis = 0.35, -- 35% discount for continuing current animation seamlessly
}

-- Normalize angle difference to [-pi, pi]
local function normalizeAngle(angle: number): number
  local twoPi = math.pi * 2
  local wrapped = (angle + math.pi) % twoPi - math.pi
  return wrapped
end

function MotionMatchingDatabase.new(weights: PartialFeatureWeights?): MotionMatchingDatabaseInstance
  local self = setmetatable({}, MotionMatchingDatabase) :: any
  self.Frames = {}

  local mergedWeights: FeatureWeights = table.clone(DEFAULT_WEIGHTS)
  if weights then
    for k, v in pairs(weights) do
      (mergedWeights :: any)[k] = v
    end
  end
  self.Weights = mergedWeights

  return self
end

function MotionMatchingDatabase:AddFrame(frame: MotionFrame): number
  table.insert(self.Frames, frame)
  return #self.Frames
end

function MotionMatchingDatabase:GetFrameCount(): number
  return #self.Frames
end

function MotionMatchingDatabase:GetFrame(index: number): MotionFrame?
  return self.Frames[index]
end

function MotionMatchingDatabase:SetWeights(weights: PartialFeatureWeights)
  for k, v in pairs(weights) do
    (self.Weights :: any)[k] = v
  end
end

function MotionMatchingDatabase:Clear()
  table.clear(self.Frames)
end

function MotionMatchingDatabase:SearchBestMatch(query: QueryContext): MatchResult?
  if #self.Frames == 0 then
    return nil
  end

  local bestFrame: MotionFrame? = nil
  local bestCost = math.huge
  local isSequential = false

  local w = self.Weights
  local wTrajPos = w.trajectoryPosition
  local wTrajFace = w.trajectoryFacing
  local wPosePos = w.posePosition
  local wPoseVel = w.poseVelocity
  local wRootVel = w.rootVelocity
  local wRootAng = w.rootAngularVelocity
  local hysteresis = w.continuityHysteresis

  local reqTag = query.requiredTag
  local currClip = query.currentClipName
  local currFrameIdx = query.currentFrameIndex
  local queryTraj = query.desiredTrajectory
  local queryPose = query.currentPose

  for _, frame in ipairs(self.Frames) do
    -- Tag filtering
    if reqTag and not frame.tags[reqTag] then
      continue
    end

    -- Check if frame allows transitions
    local isNextInSequence = (currClip ~= nil and currFrameIdx ~= nil and
      frame.clipName == currClip and frame.frameIndex == currFrameIdx + 1)

    if not frame.canTransition and not isNextInSequence then
      continue
    end

    local cost = 0

    -- 1. Trajectory cost
    local trajCount = math.min(#queryTraj, #frame.trajectory)
    for i = 1, trajCount do
      local qPt = queryTraj[i]
      local fPt = frame.trajectory[i]

      local posDiff = (qPt.position - fPt.position).Magnitude
      cost += wTrajPos * (posDiff * posDiff)

      local angleDiff = normalizeAngle(qPt.facingAngle - fPt.facingAngle)
      cost += wTrajFace * (angleDiff * angleDiff)
    end

    -- 2. Pose feature cost
    local leftPosDiff = (queryPose.leftFootPosition - frame.pose.leftFootPosition).Magnitude
    local rightPosDiff = (queryPose.rightFootPosition - frame.pose.rightFootPosition).Magnitude
    cost += wPosePos * (leftPosDiff * leftPosDiff + rightPosDiff * rightPosDiff)

    local leftVelDiff = (queryPose.leftFootVelocity - frame.pose.leftFootVelocity).Magnitude
    local rightVelDiff = (queryPose.rightFootVelocity - frame.pose.rightFootVelocity).Magnitude
    cost += wPoseVel * (leftVelDiff * leftVelDiff + rightVelDiff * rightVelDiff)

    local rootVelDiff = (queryPose.rootVelocity - frame.pose.rootVelocity).Magnitude
    cost += wRootVel * (rootVelDiff * rootVelDiff)

    local rootAngDiff = queryPose.rootAngularVelocity - frame.pose.rootAngularVelocity
    cost += wRootAng * (rootAngDiff * rootAngDiff)

    -- Continuity discount
    if isNextInSequence then
      cost = cost * (1.0 - hysteresis)
    end

    if cost < bestCost then
      bestCost = cost
      bestFrame = frame
      isSequential = isNextInSequence
    end
  end

  if not bestFrame then
    return nil
  end

  return {
    frame = bestFrame,
    cost = bestCost,
    isSequentialContinuity = isSequential,
  }
end

function MotionMatchingDatabase:PredictTrajectory(
  currentVelocity: Vector3,
  desiredInputDirection: Vector3,
  desiredSpeed: number,
  turnRate: number,
  sampleHorizons: { number }
): { TrajectoryPoint }
  local points: { TrajectoryPoint } = {}

  local inputMag = desiredInputDirection.Magnitude
  local normInput = inputMag > 1e-4 and (desiredInputDirection / inputMag) or ZERO_VECTOR
  local targetVelocity = normInput * (desiredSpeed * math.clamp(inputMag, 0, 1))

  -- Simulating trajectory in local space (root starts at origin with facing angle 0)
  for _, horizon in ipairs(sampleHorizons) do
    if horizon <= 0 then
      table.insert(points, {
        timeOffset = horizon,
        position = ZERO_VECTOR,
        facingAngle = 0,
      })
    else
      -- Exponential velocity approach towards target velocity: v(t) = target + (current - target) * exp(-halflife * t)
      local blendAlpha = 1.0 - math.exp(-turnRate * horizon)
      local predictedVel = currentVelocity:Lerp(targetVelocity, blendAlpha)

      -- Integral of position approximation
      local predictedPos = (currentVelocity + predictedVel) * 0.5 * horizon

      -- Facing direction aligned towards predicted movement
      local facing = 0
      if predictedVel.Magnitude > 0.05 then
        facing = math.atan2(-predictedVel.X, -predictedVel.Z)
      end

      table.insert(points, {
        timeOffset = horizon,
        position = predictedPos,
        facingAngle = facing,
      })
    end
  end

  return points
end

function MotionMatchingDatabase:CreateInertializer(
  currentPos: Vector3,
  targetPos: Vector3,
  currentVel: Vector3,
  targetVel: Vector3,
  duration: number
): InertializerState
  local dur = math.max(0.01, duration)
  return {
    positionOffset = currentPos - targetPos,
    velocityOffset = currentVel - targetVel,
    remainingTime = dur,
    totalDuration = dur,
  }
end

function MotionMatchingDatabase:UpdateInertializer(
  state: InertializerState,
  dt: number
): (Vector3, boolean)
  if state.remainingTime <= 0 then
    return ZERO_VECTOR, true
  end

  state.remainingTime = math.max(0, state.remainingTime - dt)
  local t = state.remainingTime / state.totalDuration

  -- Quintic smooth decay: (1 - (1 - t)^3) or direct hermite decay: t^3 * (t * (6t - 15) + 10)
  -- Here we use smooth cubic polynomial decay: f(t) = t * t * (3 - 2t)
  local decay = t * t * (3 - 2 * t)
  local offset = state.positionOffset * decay

  local isComplete = state.remainingTime <= 0
  return offset, isComplete
end

return MotionMatchingDatabase