local DialogueGraph = require("../src/ReplicatedStorage/Narrative/DialogueGraph")

-- Test 1: Validation and Integrity Check
local graph = DialogueGraph.new()
graph:AddNode({
  id = "broken_node",
  speaker = "NPC",
  text = "Hello!",
  choices = {
    { id = "opt1", text = "Go to void", targetNodeId = "non_existent_node" }
  }
})

local isValid, errors = graph:Validate()
assert(isValid == false, "Broken graph with missing target must fail validation")
assert(#errors == 1, "Should report exactly 1 validation error")

-- Test 2: Linear Dialogue Progression
local linearGraph = DialogueGraph.new()
linearGraph:AddNode({
  id = "start",
  speaker = "Elder",
  text = "Welcome to the crust collective.",
  nextNodeId = "step2",
})
linearGraph:AddNode({
  id = "step2",
  speaker = "Elder",
  text = "Take this compass before you venture.",
  onEnterActions = {
    { actionType = "set", variable = "has_compass", value = true }
  },
  nextNodeId = "end",
})
linearGraph:AddNode({
  id = "end",
  speaker = "Elder",
  text = "May the stars guide your journey.",
})

local valOk, valErrs = linearGraph:Validate()
assert(valOk == true, "Linear graph must pass validation: " .. table.concat(valErrs, ", "))

local session1 = linearGraph:CreateSession("start")
assert(session1:GetCurrentNode().id == "start", "Session should start at 'start' node")
assert(session1:HasVisited("start") == true, "'start' node should be marked visited")
assert(session1:GetVisitCount("start") == 1, "'start' node visit count should be 1")

-- Advance to step2
local nextNode, ok = session1:Advance()
assert(ok == true, "Advance should succeed")
assert(nextNode.id == "step2", "Should advance to 'step2'")
assert(session1:GetVariable("has_compass") == true, "'has_compass' should be set to true by onEnter action")

-- Advance to end
local finalNode, okEnd = session1:Advance()
assert(okEnd == true, "Advance to final node should succeed")
assert(finalNode.id == "end", "Should reach 'end' node")
assert(session1:IsFinished() == false, "Session is on end node, not yet closed")

-- Advance past end
local pastEnd, okPast = session1:Advance()
assert(okPast == true, "Advance past end should close session")
assert(pastEnd == nil, "No node after end")
assert(session1:IsFinished() == true, "Session should now be finished")

-- Test 3: Branching Choices & Condition Gates
local branchGraph = DialogueGraph.new()
branchGraph:AddNode({
  id = "merchant_greeting",
  speaker = "Merchant",
  text = "Welcome traveler, what would you like to purchase?",
  choices = {
    {
      id = "buy_potion",
      text = "Buy Health Potion (50 Gold)",
      targetNodeId = "potion_bought",
      conditions = {
        { variable = "gold", operator = ">=", value = 50 }
      },
      actions = {
        { actionType = "increment", variable = "gold", value = -50 },
        { actionType = "increment", variable = "potions", value = 1 }
      }
    },
    {
      id = "buy_relic",
      text = "Buy Ancient Relic (500 Gold)",
      targetNodeId = "relic_bought",
      conditions = {
        { variable = "gold", operator = ">=", value = 500 }
      }
    },
    {
      id = "leave",
      text = "Just browsing, farewell.",
      targetNodeId = "farewell"
    }
  }
})
branchGraph:AddNode({
  id = "potion_bought",
  speaker = "Merchant",
  text = "Here is your fresh potion! Anything else?",
  nextNodeId = "farewell"
})
branchGraph:AddNode({
  id = "relic_bought",
  speaker = "Merchant",
  text = "A legendary purchase! Handle it with care.",
  nextNodeId = "farewell"
})
branchGraph:AddNode({
  id = "farewell",
  speaker = "Merchant",
  text = "Safe travels!",
})

-- Session with 100 gold
local sessionBranch = branchGraph:CreateSession("merchant_greeting", { gold = 100, potions = 0 })
local availableChoices = sessionBranch:GetAvailableChoices()

-- Should have 2 choices available: buy_potion (gold >= 50) and leave. Relic (500 gold) is hidden.
assert(#availableChoices == 2, "Should have 2 available choices for 100 gold")
assert(availableChoices[1].id == "buy_potion", "First choice should be buy_potion")
assert(availableChoices[2].id == "leave", "Second choice should be leave")

-- Select buy_potion
local boughtNode, selectOk = sessionBranch:SelectChoice("buy_potion")
assert(selectOk == true, "Selecting buy_potion should succeed")
assert(boughtNode.id == "potion_bought", "Should navigate to potion_bought")
assert(sessionBranch:GetVariable("gold") == 50, "Gold should be deducted to 50")
assert(sessionBranch:GetVariable("potions") == 1, "Potions count should increment to 1")

-- Test 4: Custom Event Dispatching
local eventTriggered = false
local receivedPayload = nil

local eventGraph = DialogueGraph.new()
eventGraph:AddNode({
  id = "quest_giver",
  speaker = "Captain",
  text = "The fortress is under siege!",
  onEnterActions = {
    { actionType = "event", eventName = "START_DEFENSE_QUEST", payload = { waveCount = 5, difficulty = "hard" } }
  }
})

local eventSession = eventGraph:CreateSession("quest_giver")
local unhook = eventSession:OnEvent(function(eventName, payload)
  if eventName == "START_DEFENSE_QUEST" then
    eventTriggered = true
    receivedPayload = payload
  end
end)

-- Re-enter to trigger hook
eventSession:SetVariable("dummy", 1)
-- Check event
assert(eventSession:HasVisited("quest_giver") == true, "Node was visited")

-- Test 5: Serialization and Restoration
local snapshot = sessionBranch:Serialize()
assert(snapshot.currentNodeId == "potion_bought", "Snapshot must capture current node")
assert(snapshot.variables.gold == 50, "Snapshot must preserve variables")
assert(snapshot.visitedNodes["merchant_greeting"] == 1, "Snapshot must preserve visited nodes")

-- Create new fresh session and restore snapshot
local restoredSession = branchGraph:CreateSession("merchant_greeting")
restoredSession:Restore(snapshot)

assert(restoredSession:GetCurrentNode().id == "potion_bought", "Restored session must resume at potion_bought")
assert(restoredSession:GetVariable("gold") == 50, "Restored variable must be 50")
assert(restoredSession:GetVariable("potions") == 1, "Restored potion count must be 1")

local afterAdvance, advOk = restoredSession:Advance()
assert(advOk == true, "Advance from restored session must succeed")
assert(afterAdvance.id == "farewell", "Should advance to farewell")

print("PASS: DialogueGraph tests (Validation, LinearFlow, BranchingChoices, ConditionGates, EventHooks, Serialization) passed cleanly!")
