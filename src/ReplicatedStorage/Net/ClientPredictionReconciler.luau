--!strict
--[[
  ClientPredictionReconciler.luau
  Client-side prediction, command buffer sequencing, and authoritative server reconciliation engine.
  Features:
  - Sequence-indexed user command ring buffer with bounded history
  - Deterministic forward simulation stepping with configurable physics integrators
  - Server state reconciliation with drift detection and misprediction triggers
  - Fast-forward rollback replay for pending unacknowledged commands
  - Visual error dampening with exponential decay (anti-jitter / rubberband smoothing)
  - Telemetry counters: misprediction rate, max drift magnitude, total replays
  Part of crustdev studio game systems.
  Zero external runtime dependencies.
]]

local roblox = _G.Vector3 and _G or require("@lune/roblox")
local Vector3 = roblox.Vector3

export type StateSnapshot = {
  Position: Vector3,
  Velocity: Vector3,
  Yaw: number,
  Flags: number,
}

export type UserCommand = {
  Sequence: number,
  Timestamp: number,
  Dt: number,
  MoveVector: Vector3,
  LookYaw: number,
  Actions: number,
  PredictedState: StateSnapshot?,
}

export type ServerConfirmation = {
  LastProcessedSequence: number,
  AuthoritativeState: StateSnapshot,
  ServerTimestamp: number,
}

export type StepCallback = (currentState: StateSnapshot, command: UserCommand, dt: number) -> StateSnapshot

export type ReconcilerConfig = {
  BufferCapacity: number?,
  DriftThreshold: number?,
  VelocityThreshold: number?,
  ErrorDecayRate: number?,
  MoveSpeed: number?,
  StepSimulation: StepCallback?,
}

export type ReconcilerMetrics = {
  TotalCommandsSent: number,
  TotalConfirmations: number,
  MispredictionCount: number,
  TotalReplaySteps: number,
  MaxDrift: number,
  LastDrift: number,
}

export type ClientPredictionReconciler = {
  BufferCapacity: number,
  DriftThreshold: number,
  VelocityThreshold: number,
  ErrorDecayRate: number,
  MoveSpeed: number,
  StepSimulation: StepCallback,

  CurrentSequence: number,
  LastAcknowledgedSequence: number,
  PredictedState: StateSnapshot,
  VisualError: Vector3,
  CommandBuffer: { UserCommand },
  Metrics: ReconcilerMetrics,

  -- Methods
  PredictCommand: (self: ClientPredictionReconciler, moveVector: Vector3, lookYaw: number, actions: number, dt: number, timestamp: number) -> (UserCommand, StateSnapshot),
  Reconcile: (self: ClientPredictionReconciler, confirmation: ServerConfirmation) -> (boolean, number),
  UpdateVisualSmoothing: (self: ClientPredictionReconciler, dt: number) -> Vector3,
  GetVisualPosition: (self: ClientPredictionReconciler) -> Vector3,
  GetPredictedState: (self: ClientPredictionReconciler) -> StateSnapshot,
  GetPendingCommandCount: (self: ClientPredictionReconciler) -> number,
  GetMetrics: (self: ClientPredictionReconciler) -> ReconcilerMetrics,
  Reset: (self: ClientPredictionReconciler, newState: StateSnapshot) -> (),
}

local ClientPredictionReconcilerImpl = {}
ClientPredictionReconcilerImpl.__index = ClientPredictionReconcilerImpl

local DEFAULT_BUFFER_CAPACITY = 128
local DEFAULT_DRIFT_THRESHOLD = 0.05 -- studs
local DEFAULT_VELOCITY_THRESHOLD = 0.10 -- studs/s
local DEFAULT_ERROR_DECAY_RATE = 15.0 -- 1/s exponential decay
local DEFAULT_MOVE_SPEED = 16.0 -- default Roblox walkspeed

-- Helper: clone snapshot
local function cloneState(s: StateSnapshot): StateSnapshot
  return {
    Position = s.Position,
    Velocity = s.Velocity,
    Yaw = s.Yaw,
    Flags = s.Flags,
  }
end

-- Default physics integrator step (kinematic walk with acceleration and drag)
local function defaultStepSimulation(currentState: StateSnapshot, command: UserCommand, dt: number): StateSnapshot
  local moveDir = command.MoveVector
  local targetVel = Vector3.zero
  if moveDir.Magnitude > 0.001 then
    targetVel = moveDir.Unit * DEFAULT_MOVE_SPEED
  end

  -- Velocity lerp towards target
  local accelRate = 18.0
  local alpha = math.clamp(accelRate * dt, 0, 1)
  local newVel = currentState.Velocity:Lerp(targetVel, alpha)

  -- Euler displacement
  local newPos = currentState.Position + newVel * dt

  return {
    Position = newPos,
    Velocity = newVel,
    Yaw = command.LookYaw,
    Flags = command.Actions,
  }
end

function ClientPredictionReconcilerImpl.new(
  initialState: StateSnapshot?,
  config: ReconcilerConfig?
): ClientPredictionReconciler
  local cfg = config or {}
  local bufferCapacity = cfg.BufferCapacity or DEFAULT_BUFFER_CAPACITY
  local driftThreshold = cfg.DriftThreshold or DEFAULT_DRIFT_THRESHOLD
  local velocityThreshold = cfg.VelocityThreshold or DEFAULT_VELOCITY_THRESHOLD
  local decayRate = cfg.ErrorDecayRate or DEFAULT_ERROR_DECAY_RATE
  local moveSpeed = cfg.MoveSpeed or DEFAULT_MOVE_SPEED
  local stepSim = cfg.StepSimulation or defaultStepSimulation

  local startState: StateSnapshot = initialState or {
    Position = Vector3.zero,
    Velocity = Vector3.zero,
    Yaw = 0,
    Flags = 0,
  }

  local self = setmetatable({
    BufferCapacity = bufferCapacity,
    DriftThreshold = driftThreshold,
    VelocityThreshold = velocityThreshold,
    ErrorDecayRate = decayRate,
    MoveSpeed = moveSpeed,
    StepSimulation = stepSim,

    CurrentSequence = 0,
    LastAcknowledgedSequence = 0,
    PredictedState = cloneState(startState),
    VisualError = Vector3.zero,
    CommandBuffer = {},
    Metrics = {
      TotalCommandsSent = 0,
      TotalConfirmations = 0,
      MispredictionCount = 0,
      TotalReplaySteps = 0,
      MaxDrift = 0,
      LastDrift = 0,
    },
  }, ClientPredictionReconcilerImpl)

  return (self :: any) :: ClientPredictionReconciler
end

-- Predicts local motion for a new user input command, pushes to buffer, advances local predicted state
function ClientPredictionReconcilerImpl:PredictCommand(
  moveVector: Vector3,
  lookYaw: number,
  actions: number,
  dt: number,
  timestamp: number
): (UserCommand, StateSnapshot)
  self.CurrentSequence += 1
  local seq = self.CurrentSequence

  local command: UserCommand = {
    Sequence = seq,
    Timestamp = timestamp,
    Dt = dt,
    MoveVector = moveVector,
    LookYaw = lookYaw,
    Actions = actions,
    PredictedState = nil,
  }

  -- Step simulation forward
  local nextState = self.StepSimulation(self.PredictedState, command, dt)
  command.PredictedState = cloneState(nextState)
  self.PredictedState = nextState

  table.insert(self.CommandBuffer, command)

  -- Ring buffer capacity guard
  if #self.CommandBuffer > self.BufferCapacity then
    table.remove(self.CommandBuffer, 1)
  end

  self.Metrics.TotalCommandsSent += 1

  return command, cloneState(self.PredictedState)
end

-- Reconciles client prediction against an incoming authoritative server frame
function ClientPredictionReconcilerImpl:Reconcile(confirmation: ServerConfirmation): (boolean, number)
  local ackSeq = confirmation.LastProcessedSequence
  if ackSeq <= self.LastAcknowledgedSequence then
    -- Stale or duplicate acknowledgement
    return false, 0
  end

  self.LastAcknowledgedSequence = ackSeq
  self.Metrics.TotalConfirmations += 1

  -- Locate corresponding historical command in buffer
  local targetIndex = nil
  for i, cmd in ipairs(self.CommandBuffer) do
    if cmd.Sequence == ackSeq then
      targetIndex = i
      break
    elseif cmd.Sequence > ackSeq then
      break
    end
  end

  if not targetIndex then
    -- Acknowledged sequence is outside active history buffer (already pruned)
    -- Snap directly to server authoritative state
    self.PredictedState = cloneState(confirmation.AuthoritativeState)
    return false, 0
  end

  local ackCommand = self.CommandBuffer[targetIndex]
  local predictedAtAck = ackCommand.PredictedState
  local authPos = confirmation.AuthoritativeState.Position
  local authVel = confirmation.AuthoritativeState.Velocity

  local drift = 0
  local velDrift = 0
  if predictedAtAck then
    drift = (predictedAtAck.Position - authPos).Magnitude
    velDrift = (predictedAtAck.Velocity - authVel).Magnitude
  else
    drift = 100.0
  end

  if drift > self.Metrics.MaxDrift then
    self.Metrics.MaxDrift = drift
  end
  self.Metrics.LastDrift = drift

  local mispredicted = (drift > self.DriftThreshold) or (velDrift > self.VelocityThreshold)

  if mispredicted then
    self.Metrics.MispredictionCount += 1

    -- Calculate visual error offset to suppress visual pops
    -- Visual offset is the difference between where the client thought it was vs server true position
    if predictedAtAck then
      local errorDelta = predictedAtAck.Position - authPos
      self.VisualError = self.VisualError + errorDelta
    end

    -- Prune acknowledged commands up to targetIndex
    for _ = 1, targetIndex do
      table.remove(self.CommandBuffer, 1)
    end

    -- Reset simulation state to authoritative server snapshot
    local replayedState = cloneState(confirmation.AuthoritativeState)

    -- Replay all remaining unacknowledged inputs forward
    for _, remainingCmd in ipairs(self.CommandBuffer) do
      replayedState = self.StepSimulation(replayedState, remainingCmd, remainingCmd.Dt)
      remainingCmd.PredictedState = cloneState(replayedState)
      self.Metrics.TotalReplaySteps += 1
    end

    self.PredictedState = replayedState
    return true, drift
  else
    -- Prediction was correct: prune confirmed commands up to targetIndex without replay
    for _ = 1, targetIndex do
      table.remove(self.CommandBuffer, 1)
    end
    return false, drift
  end
end

-- Exponential decay update for visual error smoothing (call in RenderStepped)
function ClientPredictionReconcilerImpl:UpdateVisualSmoothing(dt: number): Vector3
  if self.VisualError.Magnitude < 0.001 then
    self.VisualError = Vector3.zero
    return Vector3.zero
  end

  local decay = math.exp(-self.ErrorDecayRate * dt)
  self.VisualError = self.VisualError * decay

  if self.VisualError.Magnitude < 0.001 then
    self.VisualError = Vector3.zero
  end

  return self.VisualError
end

-- Returns render position (smoothed predicted position)
function ClientPredictionReconcilerImpl:GetVisualPosition(): Vector3
  return self.PredictedState.Position + self.VisualError
end

-- Returns latest predicted state snapshot
function ClientPredictionReconcilerImpl:GetPredictedState(): StateSnapshot
  return cloneState(self.PredictedState)
end

-- Returns number of commands awaiting server acknowledgement
function ClientPredictionReconcilerImpl:GetPendingCommandCount(): number
  return #self.CommandBuffer
end

-- Returns telemetry metrics
function ClientPredictionReconcilerImpl:GetMetrics(): ReconcilerMetrics
  local m = self.Metrics
  return {
    TotalCommandsSent = m.TotalCommandsSent,
    TotalConfirmations = m.TotalConfirmations,
    MispredictionCount = m.MispredictionCount,
    TotalReplaySteps = m.TotalReplaySteps,
    MaxDrift = m.MaxDrift,
    LastDrift = m.LastDrift,
  }
end

-- Hard resets state and clears pending buffer
function ClientPredictionReconcilerImpl:Reset(newState: StateSnapshot)
  self.CurrentSequence = 0
  self.LastAcknowledgedSequence = 0
  self.PredictedState = cloneState(newState)
  self.VisualError = Vector3.zero
  table.clear(self.CommandBuffer)
end

return ClientPredictionReconcilerImpl
