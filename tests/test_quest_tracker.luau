local QuestTracker = require("../src/ReplicatedStorage/Narrative/QuestTracker")

local tracker = QuestTracker.new()

-- Test 1: Registration and input guarding
assert(tracker:RegisterQuest({ id = "", objectives = {} } :: any) == false, "Empty quest ID must be rejected")
assert(tracker:RegisterQuest({ id = "quest_no_obj", objectives = {} } :: any) == false, "Quest without objectives must be rejected")

local quest1 = {
  id = "intro_gathering",
  title = "Gathering Resources",
  description = "Collect essential minerals for the crust core.",
  objectives = {
    { id = "gather_ore", description = "Gather 5 Iron Ore", objectiveType = "counter", requiredCount = 5 },
    { id = "talk_blacksmith", description = "Report to Blacksmith", objectiveType = "boolean" },
  },
  rewards = { xp = 150, gold = 50 },
}

local regOk = tracker:RegisterQuest(quest1)
assert(regOk == true, "Valid quest registration failed")

-- Test 2: Level gate and prerequisite validation
local quest2 = {
  id = "deep_mantle_expedition",
  title = "Deep Mantle Expedition",
  description = "Explore the subterranean mantle zone.",
  requiredLevel = 10,
  prerequisites = { "intro_gathering" },
  objectives = {
    { id = "reach_depth", description = "Reach Mantle Zone 3", objectiveType = "boolean" },
  },
  rewards = { xp = 1000 },
}
tracker:RegisterQuest(quest2)

local canStart2, reason2 = tracker:CanStartQuest("deep_mantle_expedition", 5)
assert(canStart2 == false, "Should fail start due to level gate (player lvl 5 < required 10)")
assert(string.find(reason2 or "", "Level 10 required") ~= nil, "Reason should mention required level")

local canStart2Lvl10, reason2Lvl10 = tracker:CanStartQuest("deep_mantle_expedition", 10)
assert(canStart2Lvl10 == false, "Should fail start due to unfinished prerequisite 'intro_gathering'")
assert(string.find(reason2Lvl10 or "", "Prerequisite quest") ~= nil, "Reason should mention prerequisite")

-- Test 3: Starting quest and initial state
local startOk, startErr = tracker:StartQuest("intro_gathering", 1)
assert(startOk == true, "Failed to start intro_gathering: " .. tostring(startErr))

local activeState = tracker:GetQuestState("intro_gathering")
assert(activeState ~= nil, "Active quest state should exist")
assert(activeState.objectives["gather_ore"].currentCount == 0, "Initial counter must be 0")
assert(activeState.objectives["gather_ore"].requiredCount == 5, "Required counter must be 5")
assert(activeState.objectives["gather_ore"].isCompleted == false, "Should not be completed initially")

-- Test 4: Objective progress and observer signals
local hookFired = false
local lastCount = 0
tracker:OnObjectiveUpdated(function(qId, objId, prog)
  if qId == "intro_gathering" and objId == "gather_ore" then
    hookFired = true
    lastCount = prog.currentCount
  end
end)

tracker:AdvanceObjective("intro_gathering", "gather_ore", 3)
assert(hookFired == true, "OnObjectiveUpdated hook must fire")
assert(lastCount == 3, "Progress count must equal 3")

local compFired = false
local rewardedXp = 0
tracker:OnQuestCompleted(function(qId, rewards)
  if qId == "intro_gathering" then
    compFired = true
    rewardedXp = rewards and rewards.xp or 0
  end
end)

-- Complete remaining objectives
tracker:AdvanceObjective("intro_gathering", "gather_ore", 2) -- reaches 5/5
assert(tracker:GetQuestState("intro_gathering").objectives["gather_ore"].isCompleted == true, "Counter objective should complete")

tracker:CompleteObjective("intro_gathering", "talk_blacksmith")

assert(compFired == true, "OnQuestCompleted hook must fire upon all objectives completed")
assert(rewardedXp == 150, "Completed quest should pass rewards payload (xp: 150)")
assert(tracker:IsQuestCompleted("intro_gathering") == true, "Quest status must be completed")
assert(tracker:GetQuestState("intro_gathering") == nil, "Active quest state should be cleared on completion")

-- Test 5: Prerequisite quest unblocked after completion
local canStartNow, _ = tracker:CanStartQuest("deep_mantle_expedition", 10)
assert(canStartNow == true, "Deep mantle expedition should now be available for player level 10")

-- Test 6: Serialization and Deserialization roundtrip
local serialized = tracker:Serialize()
assert(#serialized.completedQuestIds == 1, "Serialized completed count must be 1")
assert(serialized.completedQuestIds[1] == "intro_gathering", "Serialized completed ID mismatch")

local newTracker = QuestTracker.new()
newTracker:RegisterQuest(quest1)
newTracker:RegisterQuest(quest2)
local desOk = newTracker:Deserialize(serialized)
assert(desOk == true, "Deserialization failed")
assert(newTracker:IsQuestCompleted("intro_gathering") == true, "Restored tracker must recognize completed quest")

local canStartRestored, _ = newTracker:CanStartQuest("deep_mantle_expedition", 10)
assert(canStartRestored == true, "Restored tracker must respect completed prerequisite")

-- Test 7: Fail and Abandonment
local quest3 = {
  id = "timed_defense",
  title = "Timed Defense",
  description = "Defend the core without letting health fall to 0.",
  objectives = {
    { id = "hold_line", description = "Hold line for 30s", objectiveType = "timer", requiredCount = 30 },
  },
}
tracker:RegisterQuest(quest3)
tracker:StartQuest("timed_defense", 1)

local failFired = false
local failReasonMsg = ""
tracker:OnQuestFailed(function(qId, reason)
  if qId == "timed_defense" then
    failFired = true
    failReasonMsg = reason
  end
end)

tracker:FailQuest("timed_defense", "Core overwhelmed by hostiles")
assert(failFired == true, "OnQuestFailed hook must fire")
assert(failReasonMsg == "Core overwhelmed by hostiles", "Fail reason must match")
assert(tracker:GetQuestState("timed_defense") == nil, "Failed quest must not be active")

print("PASS: QuestTracker tests (Register, LevelGate, PrereqChain, Advance, AutoComplete, Serialize, Deserialization, FailQuest) passed cleanly!")
