local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame
Vector3 = roblox.Vector3
CFrame = roblox.CFrame

local ComboGraph = require("../src/ReplicatedStorage/Combat/ComboGraph")

-- Build a test graph for Aetheria action combat
local graph = ComboGraph.CreateGraph()

local l1Timing = {
  StartupDuration = 0.10,
  ActiveDuration = 0.15,
  CancelWindowDuration = 0.20,
  RecoveryDuration = 0.25,
}

local l1Hitbox = {
  Radius = 3.5,
  Offset = Vector3.new(0, 0, -3),
  BaseDamage = 25.0,
  HitstunDuration = 0.4,
  KnockbackVector = Vector3.new(0, 0, -5),
}

ComboGraph.AddNode(graph, "L1", "Light Slash 1", l1Timing, l1Hitbox, 10)
ComboGraph.SetEntryNode(graph, "Light", "L1")

local l2Timing = {
  StartupDuration = 0.08,
  ActiveDuration = 0.12,
  CancelWindowDuration = 0.20,
  RecoveryDuration = 0.30,
}
ComboGraph.AddNode(graph, "L2", "Light Slash 2", l2Timing, l1Hitbox, 15)

local finisherTiming = {
  StartupDuration = 0.15,
  ActiveDuration = 0.20,
  CancelWindowDuration = 0.10,
  RecoveryDuration = 0.40,
}
local finisherHitbox = {
  Radius = 5.0,
  Offset = Vector3.new(0, 0, -4),
  BaseDamage = 60.0,
  HitstunDuration = 0.8,
  KnockbackVector = Vector3.new(0, 8, -12),
}
ComboGraph.AddNode(graph, "L3_Finisher", "Spinning Vortex", finisherTiming, finisherHitbox, 30)

local aerialTiming = {
  StartupDuration = 0.10,
  ActiveDuration = 0.25,
  CancelWindowDuration = 0.15,
  RecoveryDuration = 0.35,
}
ComboGraph.AddNode(graph, "Aerial_Slam", "Skyfall Impact", aerialTiming, finisherHitbox, 25)

-- Add transitions
ComboGraph.AddTransition(graph, "L1", {
  TargetNodeId = "L2",
  RequiredTrigger = "Light",
  AirborneCondition = "GroundedOnly",
  StaminaCost = 15,
})

ComboGraph.AddTransition(graph, "L2", {
  TargetNodeId = "L3_Finisher",
  RequiredTrigger = "Heavy",
  RequiresHitConfirm = true,
  StaminaCost = 30,
})

ComboGraph.AddTransition(graph, "L2", {
  TargetNodeId = "Aerial_Slam",
  RequiredTrigger = "Special",
  AirborneCondition = "AirborneOnly",
  StaminaCost = 25,
})

-- Test 1: Start Combo and Phase Advancements
local tracker = ComboGraph.CreateTracker(graph, 0.30)
assert(tracker:GetState().CurrentPhase == "Idle", "Initial state must be Idle")

local started = tracker:StartCombo("Light", false, 100)
assert(started, "StartCombo with valid trigger should succeed")
assert(tracker:GetState().CurrentNode.Id == "L1", "Current node should be L1")
assert(tracker:GetState().CurrentPhase == "Startup", "Should enter Startup phase")
assert(tracker:GetState().ComboHitCount == 1, "Hit count should be 1")
assert(tracker:GetState().DamageMultiplier == 1.0, "First hit damage multiplier must be 1.0")

-- Step past startup into active
tracker:Step(0.11, false, 100)
assert(tracker:GetState().CurrentPhase == "Active", "Should advance to Active phase")

-- Test 2: Input Buffering during Active Phase
-- Pressing "Light" during active phase buffers the follow-up
local buffered = tracker:ProcessInput("Light", false, 100)
assert(buffered, "Input during active should be buffered")
assert(tracker:GetState().BufferedTrigger == "Light", "Buffered trigger must be stored")

-- Step past active into cancel window -> should immediately trigger L2!
tracker:Step(0.16, false, 100)
assert(tracker:GetState().CurrentNode.Id == "L2", "Buffered input should execute L2 transition upon cancel window entry")
assert(tracker:GetState().CurrentPhase == "Startup", "L2 should begin in Startup")
assert(tracker:GetState().ComboHitCount == 2, "Combo count should increment to 2")
assert(tracker:GetState().DamageMultiplier == 0.90, "Hit 2 damage multiplier should be 0.90")

-- Test 3: Hit Confirmation Gating for Finisher
-- Step through L2 startup and active into cancel window
tracker:Step(0.09, false, 100) -- past startup
tracker:Step(0.13, false, 100) -- past active into cancel window
assert(tracker:GetState().CurrentPhase == "CancelWindow", "Should be in CancelWindow")

-- Try heavy finisher WITHOUT hit confirmation -> should fail
local heavyAttempt = tracker:ProcessInput("Heavy", false, 100)
assert(not heavyAttempt, "Finisher requiring hit confirm must fail if no hit confirmed")

-- Confirm hit and try again
tracker:ConfirmHit()
local heavyConfirmed = tracker:ProcessInput("Heavy", false, 100)
assert(heavyConfirmed, "Finisher should succeed after hit confirmation")
assert(tracker:GetState().CurrentNode.Id == "L3_Finisher", "Should transition to L3_Finisher")
assert(tracker:GetState().ComboHitCount == 3, "Combo hit count should be 3")
assert(tracker:GetState().DamageMultiplier == 0.80, "Hit 3 damage multiplier should scale to 0.80")

-- Test 4: Airborne Conditions
tracker:Reset()
tracker:StartCombo("Light", false, 100)
tracker:Step(0.26, false, 100) -- into cancel window
tracker:ProcessInput("Light", false, 100) -- into L2
tracker:Step(0.22, false, 100) -- into L2 cancel window

-- Trying Aerial_Slam while Grounded should fail
local groundedAerial = tracker:ProcessInput("Special", false, 100)
assert(not groundedAerial, "AirborneOnly attack must fail when grounded")

-- Trying Aerial_Slam while Airborne should succeed
local airborneAerial = tracker:ProcessInput("Special", true, 100)
assert(airborneAerial, "AirborneOnly attack must succeed when airborne")
assert(tracker:GetState().CurrentNode.Id == "Aerial_Slam", "Must be Aerial_Slam")

-- Test 5: Recovery and Reset on Missed Timing
tracker:Reset()
tracker:StartCombo("Light", false, 100)
-- Step all the way past recovery without any inputs
tracker:Step(1.0, false, 100)
assert(tracker:GetState().CurrentPhase == "Idle", "Should reset to Idle after full recovery elapsed")
assert(tracker:GetState().CurrentNode == nil, "Node should be nil after reset")

-- Test 6: Ascii Tree Output
local asciiTree = ComboGraph.ToAscii(graph)
assert(string.find(asciiTree, "L1") ~= nil, "ASCII output must contain L1")
assert(string.find(asciiTree, "L3_Finisher") ~= nil, "ASCII output must contain L3_Finisher")

print("PASS: ComboGraph tests (Nodes, Startup/Active/Cancel Phases, Buffering, HitConfirm, Airborne Gates, Diminishing Multipliers, ASCII Tree) passed cleanly!")
