--!strict
local StateMachine = require("../src/ReplicatedStorage/State/StateMachine")

-- 1. Test Initialization
local sm = StateMachine.new()
assert(sm ~= nil, "StateMachine instance must not be nil")
assert(sm:GetActiveState() == nil, "ActiveState should initially be nil")

-- 2. Test Flat State Registration and Lifecycle
local enterLog: { string } = {}
local exitLog: { string } = {}
local updateTicks = 0

sm:AddState({
  Name = "Idle",
  OnEnter = function(_, fromState)
    table.insert(enterLog, "Idle from " .. fromState)
  end,
  OnExit = function(_, toState)
    table.insert(exitLog, "Idle to " .. toState)
  end,
  OnUpdate = function(_, dt)
    updateTicks += 1
  end,
})

sm:AddState({
  Name = "Moving",
  OnEnter = function(_, fromState)
    table.insert(enterLog, "Moving from " .. fromState)
  end,
  OnExit = function(_, toState)
    table.insert(exitLog, "Moving to " .. toState)
  end,
})

sm:SetInitialState("Idle")
assert(sm:GetActiveState() == "Idle", "Active state must be Idle")
assert(#enterLog == 1 and enterLog[1] == "Idle from ", "Idle OnEnter should have triggered")

sm:Update(0.1)
assert(updateTicks == 1, "Idle OnUpdate should have incremented updateTicks")

sm:Transition("Moving")
assert(sm:GetActiveState() == "Moving", "Active state must be Moving")
assert(#exitLog == 1 and exitLog[1] == "Idle to Moving", "Idle OnExit should have recorded")
assert(#enterLog == 2 and enterLog[2] == "Moving from Idle", "Moving OnEnter should have recorded")

-- 3. Test Hierarchical State Transitions
local hsm = StateMachine.new()
local hierarchyEvents: { string } = {}

-- Root hierarchy:
-- Root -> Grounded -> Idle
-- Grounded -> Running
-- Airborne -> Falling
hsm:AddState({
  Name = "Grounded",
  OnEnter = function() table.insert(hierarchyEvents, "Enter Grounded") end,
  OnExit = function() table.insert(hierarchyEvents, "Exit Grounded") end,
  OnUpdate = function() table.insert(hierarchyEvents, "Update Grounded") end,
})

hsm:AddState({
  Name = "Grounded_Idle",
  Parent = "Grounded",
  OnEnter = function() table.insert(hierarchyEvents, "Enter Grounded_Idle") end,
  OnExit = function() table.insert(hierarchyEvents, "Exit Grounded_Idle") end,
  OnUpdate = function() table.insert(hierarchyEvents, "Update Grounded_Idle") end,
})

hsm:AddState({
  Name = "Grounded_Running",
  Parent = "Grounded",
  OnEnter = function() table.insert(hierarchyEvents, "Enter Grounded_Running") end,
  OnExit = function() table.insert(hierarchyEvents, "Exit Grounded_Running") end,
})

hsm:AddState({
  Name = "Airborne",
  OnEnter = function() table.insert(hierarchyEvents, "Enter Airborne") end,
  OnExit = function() table.insert(hierarchyEvents, "Exit Airborne") end,
})

-- Initialize to Grounded_Idle (should enter Grounded then Grounded_Idle)
hsm:SetInitialState("Grounded_Idle")
assert(hsm:GetActiveState() == "Grounded_Idle", "Active should be Grounded_Idle")
assert(#hierarchyEvents == 2, "Should have 2 enter events")
assert(hierarchyEvents[1] == "Enter Grounded", "Parent should enter first")
assert(hierarchyEvents[2] == "Enter Grounded_Idle", "Child should enter second")

-- Ancestor query check
assert(hsm:IsInState("Grounded_Idle") == true, "Must be in Grounded_Idle")
assert(hsm:IsInState("Grounded", true) == true, "Must report true for parent Grounded")
assert(hsm:IsInState("Airborne", true) == false, "Must report false for Airborne")

-- Update should execute parent then child
hierarchyEvents = {}
hsm:Update(0.016)
assert(#hierarchyEvents == 2, "Update should trigger both parent and child")
assert(hierarchyEvents[1] == "Update Grounded", "Parent should update first")
assert(hierarchyEvents[2] == "Update Grounded_Idle", "Child should update second")

-- Transition between siblings (Grounded_Idle -> Grounded_Running)
-- Grounded should NOT exit or re-enter!
hierarchyEvents = {}
hsm:Transition("Grounded_Running")
assert(hsm:GetActiveState() == "Grounded_Running", "Should be Grounded_Running")
assert(#hierarchyEvents == 2, "Sibling transition should only touch siblings")
assert(hierarchyEvents[1] == "Exit Grounded_Idle", "Old child should exit")
assert(hierarchyEvents[2] == "Enter Grounded_Running", "New child should enter")

-- Transition to different branch (Grounded_Running -> Airborne)
-- Should exit Grounded_Running, then exit Grounded, then enter Airborne
hierarchyEvents = {}
hsm:Transition("Airborne")
assert(hsm:GetActiveState() == "Airborne", "Should be Airborne")
assert(#hierarchyEvents == 3, "Branch transition should exit child, parent, then enter target")
assert(hierarchyEvents[1] == "Exit Grounded_Running", "Child should exit first")
assert(hierarchyEvents[2] == "Exit Grounded", "Parent should exit second")
assert(hierarchyEvents[3] == "Enter Airborne", "Target should enter")

-- 4. Test Guarded Transitions with Events
local combatSm = StateMachine.new()
combatSm:AddState({ Name = "Neutral" })
combatSm:AddState({ Name = "Attacking" })
combatSm:AddState({ Name = "Parrying" })

local hasStamina = false
combatSm:AddTransition("Neutral", "Attacking", "AttackInput", function()
  return hasStamina
end)

combatSm:SetInitialState("Neutral")

-- Event with failing guard
local handledFail = combatSm:FireEvent("AttackInput")
assert(handledFail == false, "Event should fail guard")
assert(combatSm:GetActiveState() == "Neutral", "State should remain Neutral")

-- Event with passing guard
hasStamina = true
local handledSuccess = combatSm:FireEvent("AttackInput")
assert(handledSuccess == true, "Event should pass guard")
assert(combatSm:GetActiveState() == "Attacking", "State should transition to Attacking")

-- 5. Test State Stack (Push / Pop) for Interrupts
combatSm:AddState({ Name = "Stunned" })
combatSm:PushState("Stunned")
assert(combatSm:GetActiveState() == "Stunned", "Active state should be Stunned after Push")
assert(#combatSm.Stack == 1 and combatSm.Stack[1] == "Attacking", "Stack should hold Attacking")

combatSm:PopState()
assert(combatSm:GetActiveState() == "Attacking", "Active state should restore to Attacking after Pop")
assert(#combatSm.Stack == 0, "Stack should be empty")

-- 6. Test Event Bubbling
local bubbleSm = StateMachine.new()
local bubbleHandledBy: string? = nil

bubbleSm:AddState({
  Name = "ParentState",
  OnEvent = function(_, evName)
    if evName == "GenericCancel" then
      bubbleHandledBy = "Parent"
      return true
    end
    return false
  end,
})

bubbleSm:AddState({
  Name = "ChildState",
  Parent = "ParentState",
  OnEvent = function(_, evName)
    if evName == "ChildSpecific" then
      bubbleHandledBy = "Child"
      return true
    end
    return false -- bubble other events
  end,
})

bubbleSm:SetInitialState("ChildState")

-- Child-specific event
bubbleSm:FireEvent("ChildSpecific")
assert(bubbleHandledBy == "Child", "ChildSpecific should be handled by Child")

-- Bubbled event
bubbleSm:FireEvent("GenericCancel")
assert(bubbleHandledBy == "Parent", "GenericCancel should bubble to and be handled by Parent")

-- Unhandled event
local unhandled = bubbleSm:FireEvent("UnknownEvent")
assert(unhandled == false, "Unknown event should return false")

print("PASS: StateMachine tests (Flat, Hierarchical, Ancestors, Guarded, Push/Pop, Bubbling) passed cleanly!")
