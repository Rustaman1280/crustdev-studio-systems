--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local ClientPredictionReconciler = require("../src/ReplicatedStorage/Net/ClientPredictionReconciler")

-- 1. Test Initialization
local startState = {
  Position = Vector3.new(0, 0, 0),
  Velocity = Vector3.new(0, 0, 0),
  Yaw = 0,
  Flags = 0,
}

local reconciler = ClientPredictionReconciler.new(startState, {
  BufferCapacity = 32,
  DriftThreshold = 0.1,
  ErrorDecayRate = 10.0,
})

assert(reconciler:GetPendingCommandCount() == 0, "Initial pending commands must be 0")
local initialPos = reconciler:GetPredictedState().Position
assert(initialPos.X == 0 and initialPos.Y == 0 and initialPos.Z == 0, "Initial position must match")

-- 2. Test Command Prediction
local cmd1, state1 = reconciler:PredictCommand(Vector3.new(0, 0, 1), 0, 0, 0.05, 100.0)
assert(cmd1.Sequence == 1, "First command sequence must be 1")
assert(state1.Position.Z > 0, "Predicted position should move along positive Z")
assert(reconciler:GetPendingCommandCount() == 1, "Pending command count should be 1")

local cmd2, state2 = reconciler:PredictCommand(Vector3.new(0, 0, 1), 0, 0, 0.05, 100.05)
local cmd3, state3 = reconciler:PredictCommand(Vector3.new(0, 0, 1), 0, 0, 0.05, 100.10)
local cmd4, state4 = reconciler:PredictCommand(Vector3.new(0, 0, 1), 0, 0, 0.05, 100.15)
assert(reconciler:GetPendingCommandCount() == 4, "Pending commands must be 4")
assert(state4.Position.Z > state3.Position.Z, "Monotonic forward motion")

-- 3. Test Accurate Server Confirmation (No Misprediction)
-- Server confirms command 2 with exact predicted state
local serverAckExact = {
  LastProcessedSequence = 2,
  AuthoritativeState = {
    Position = state2.Position,
    Velocity = state2.Velocity,
    Yaw = state2.Yaw,
    Flags = state2.Flags,
  },
  ServerTimestamp = 100.05,
}

local mispredicted, drift = reconciler:Reconcile(serverAckExact)
assert(mispredicted == false, "Accurate prediction must not flag misprediction")
assert(drift < 0.001, "Drift must be near zero for exact confirmation")
assert(reconciler:GetPendingCommandCount() == 2, "Commands 1 and 2 should be pruned, leaving 3 and 4")
local metrics = reconciler:GetMetrics()
assert(metrics.MispredictionCount == 0, "Misprediction count must remain 0")
assert(metrics.TotalConfirmations == 1, "Confirmations count should be 1")

-- 4. Test Stale or Duplicate Confirmation Rejection
local staleAck = {
  LastProcessedSequence = 1,
  AuthoritativeState = {
    Position = Vector3.new(99, 99, 99),
    Velocity = Vector3.zero,
    Yaw = 0,
    Flags = 0,
  },
  ServerTimestamp = 99.0,
}
local staleMispred, staleDrift = reconciler:Reconcile(staleAck)
assert(staleMispred == false and staleDrift == 0, "Stale ack must be rejected cleanly")

-- 5. Test Misprediction & Server Reconciliation Replay
-- Issue commands 5, 6, 7
local cmd5, _ = reconciler:PredictCommand(Vector3.new(1, 0, 0), 0, 0, 0.05, 100.20)
local cmd6, _ = reconciler:PredictCommand(Vector3.new(1, 0, 0), 0, 0, 0.05, 100.25)
local cmd7, state7 = reconciler:PredictCommand(Vector3.new(1, 0, 0), 0, 0, 0.05, 100.30)

-- Server informs us that at sequence 5, an external explosion knocked the player back to Z = -5, X = 0
local serverDivergentAck = {
  LastProcessedSequence = 5,
  AuthoritativeState = {
    Position = Vector3.new(0, 0, -5.0),
    Velocity = Vector3.new(0, 0, 0),
    Yaw = 0,
    Flags = 0,
  },
  ServerTimestamp = 100.20,
}

local hadMispredict, mispredictDrift = reconciler:Reconcile(serverDivergentAck)
assert(hadMispredict == true, "Divergent state must trigger misprediction")
assert(mispredictDrift > 4.0, "Drift should reflect the major deviation")

-- Verify pending commands 6 and 7 were replayed
local postReplayState = reconciler:GetPredictedState()
assert(postReplayState.Position.Z == -5.0, "Z should remain at server knocked-back origin")
assert(postReplayState.Position.X > 0, "Replayed commands 6 and 7 moved player along positive X")

local updatedMetrics = reconciler:GetMetrics()
assert(updatedMetrics.MispredictionCount == 1, "Misprediction counter must increment to 1")
assert(updatedMetrics.TotalReplaySteps >= 2, "Must have replayed commands 6 and 7")

-- 6. Test Visual Error Smoothing & Exponential Decay
-- After misprediction, VisualError was created to prevent visual snap
local visualOffset = reconciler:UpdateVisualSmoothing(0.0)
assert(visualOffset.Magnitude > 0, "Visual error offset must be present after misprediction")

local visualPos = reconciler:GetVisualPosition()
assert((visualPos - postReplayState.Position).Magnitude > 0, "Visual position includes smoothing dampening")

-- Advance visual smoothing over several frames (e.g. 0.5s total with decay rate 10)
for _ = 1, 10 do
  reconciler:UpdateVisualSmoothing(0.05)
end

local finalVisualOffset = reconciler:UpdateVisualSmoothing(0.5)
assert(finalVisualOffset.Magnitude == 0, "Visual error must fully decay to zero over time")
assert(reconciler:GetVisualPosition() == reconciler:GetPredictedState().Position, "Visual position snaps cleanly to true position once settled")

-- 7. Test Reset
reconciler:Reset({
  Position = Vector3.new(100, 50, 100),
  Velocity = Vector3.zero,
  Yaw = 3.14,
  Flags = 0,
})
assert(reconciler:GetPendingCommandCount() == 0, "Reset must empty buffer")
assert(reconciler:GetPredictedState().Position.X == 100, "Reset must apply new position")

print("PASS: ClientPredictionReconciler tests (Initialization, Prediction, Reconciliation, Replay, Visual Smoothing, Reset) passed cleanly!")
