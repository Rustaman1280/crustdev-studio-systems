--!strict
local HTNPlanner = require("../src/ReplicatedStorage/AI/HTNPlanner")

-- Test 1: Instantiation and basic registration
do
  local planner = HTNPlanner.new()
  planner:AddPrimitiveTask({
    Name = "WalkToDoor",
    Cost = 1,
  })
  planner:AddCompoundTask("OpenDoorRoutine")
  planner:AddMethod("OpenDoorRoutine", {
    Name = "DirectOpen",
    Subtasks = { "WalkToDoor" },
    Priority = 10,
  })

  local task = planner:GetTask("WalkToDoor")
  assert(task ~= nil, "Task should exist")
  assert(task.Type == "Primitive", "Task should be primitive")

  local plan = planner:Plan("OpenDoorRoutine", {})
  assert(plan ~= nil, "Plan should succeed")
  assert(#plan.Steps == 1, "Should have 1 step")
  assert(plan.Steps[1].Task.Name == "WalkToDoor", "First step should be WalkToDoor")
  assert(plan.TotalCost == 1, "Total cost should match")
end

-- Test 2: Priority-based method selection and condition gating
do
  local planner = HTNPlanner.new()

  planner:AddPrimitiveTask({
    Name = "UseKeycard",
    PreconditionState = { HasKeycard = true },
    EffectState = { DoorOpen = true },
    Cost = 2,
  })

  planner:AddPrimitiveTask({
    Name = "HackTerminal",
    PreconditionState = { TerminalPower = true, CybertrixSkill = true },
    EffectState = { DoorOpen = true },
    Cost = 8,
  })

  planner:AddPrimitiveTask({
    Name = "BreachDoor",
    PreconditionState = { HasC4 = true },
    EffectState = { DoorOpen = true, AlarmTriggered = true },
    Cost = 15,
  })

  planner:AddCompoundTask("UnlockSecurityDoor")

  -- Method 1 (highest priority): Use Keycard
  planner:AddMethod("UnlockSecurityDoor", {
    Name = "KeycardMethod",
    PreconditionState = { HasKeycard = true },
    Subtasks = { "UseKeycard" },
    Priority = 100,
  })

  -- Method 2 (medium priority): Hack Terminal
  planner:AddMethod("UnlockSecurityDoor", {
    Name = "HackingMethod",
    PreconditionState = { TerminalPower = true, CybertrixSkill = true },
    Subtasks = { "HackTerminal" },
    Priority = 50,
  })

  -- Method 3 (lowest priority): C4 Breach
  planner:AddMethod("UnlockSecurityDoor", {
    Name = "BreachMethod",
    PreconditionState = { HasC4 = true },
    Subtasks = { "BreachDoor" },
    Priority = 10,
  })

  -- Scenario A: Agent has Keycard -> Chooses KeycardMethod
  local stateA = { HasKeycard = true, TerminalPower = true, CybertrixSkill = true, HasC4 = true }
  local planA = planner:Plan("UnlockSecurityDoor", stateA)
  assert(planA ~= nil, "Plan A should succeed")
  assert(#planA.Steps == 1)
  assert(planA.Steps[1].Task.Name == "UseKeycard")
  assert(planA.TotalCost == 2)

  -- Scenario B: No Keycard, but can hack -> Chooses HackingMethod
  local stateB = { HasKeycard = false, TerminalPower = true, CybertrixSkill = true, HasC4 = true }
  local planB = planner:Plan("UnlockSecurityDoor", stateB)
  assert(planB ~= nil, "Plan B should succeed")
  assert(planB.Steps[1].Task.Name == "HackTerminal")
  assert(planB.TotalCost == 8)

  -- Scenario C: Only C4 available -> Chooses BreachMethod
  local stateC = { HasKeycard = false, TerminalPower = false, CybertrixSkill = false, HasC4 = true }
  local planC = planner:Plan("UnlockSecurityDoor", stateC)
  assert(planC ~= nil, "Plan C should succeed")
  assert(planC.Steps[1].Task.Name == "BreachDoor")
  assert(planC.TotalCost == 15)

  -- Scenario D: Nothing available -> Plan fails
  local stateD = { HasKeycard = false, TerminalPower = false, CybertrixSkill = false, HasC4 = false }
  local planD = planner:Plan("UnlockSecurityDoor", stateD)
  assert(planD == nil, "Plan D should fail when no method is valid")
end

-- Test 3: Deep hierarchical decomposition and backtracking
do
  local planner = HTNPlanner.new()

  -- Primitives
  planner:AddPrimitiveTask({
    Name = "CraftLockpick",
    PreconditionState = { IronScraps = true },
    EffectState = { HasLockpick = true },
    Cost = 3,
  })

  planner:AddPrimitiveTask({
    Name = "PickLock",
    PreconditionState = { HasLockpick = true },
    EffectState = { ChestUnlocked = true },
    Cost = 2,
  })

  planner:AddPrimitiveTask({
    Name = "SmashLockWithHammer",
    PreconditionState = { HasHammer = true },
    EffectState = { ChestUnlocked = true },
    Cost = 7,
  })

  planner:AddPrimitiveTask({
    Name = "LootTreasure",
    PreconditionState = { ChestUnlocked = true },
    EffectState = { HasTreasure = true },
    Cost = 1,
  })

  -- Compound tasks
  planner:AddCompoundTask("OpenChest")
  planner:AddCompoundTask("AcquireLoot")

  -- OpenChest Method A: Pick Lock (requires CraftLockpick if needed)
  planner:AddCompoundTask("EnsureLockpick")
  planner:AddMethod("EnsureLockpick", {
    Name = "AlreadyHaveLockpick",
    PreconditionState = { HasLockpick = true },
    Subtasks = {},
    Priority = 10,
  })
  planner:AddMethod("EnsureLockpick", {
    Name = "CraftNewLockpick",
    PreconditionState = { IronScraps = true },
    Subtasks = { "CraftLockpick" },
    Priority = 5,
  })

  planner:AddMethod("OpenChest", {
    Name = "FinesseOpen",
    Subtasks = { "EnsureLockpick", "PickLock" },
    Priority = 20,
  })

  planner:AddMethod("OpenChest", {
    Name = "BruteForceOpen",
    PreconditionState = { HasHammer = true },
    Subtasks = { "SmashLockWithHammer" },
    Priority = 10,
  })

  planner:AddMethod("AcquireLoot", {
    Name = "FullHeist",
    Subtasks = { "OpenChest", "LootTreasure" },
    Priority = 1,
  })

  -- Test Case 1: Has IronScraps -> Crafts lockpick, picks lock, loots treasure
  local state1 = { HasLockpick = false, IronScraps = true, HasHammer = false, ChestUnlocked = false }
  local plan1 = planner:Plan("AcquireLoot", state1)
  assert(plan1 ~= nil, "Plan 1 should succeed")
  assert(#plan1.Steps == 3, "Plan should have 3 steps")
  assert(plan1.Steps[1].Task.Name == "CraftLockpick")
  assert(plan1.Steps[2].Task.Name == "PickLock")
  assert(plan1.Steps[3].Task.Name == "LootTreasure")
  assert(plan1.TotalCost == 3 + 2 + 1)

  -- Test Case 2: No scraps, but has hammer -> Falls back to smash with hammer
  local state2 = { HasLockpick = false, IronScraps = false, HasHammer = true, ChestUnlocked = false }
  local plan2 = planner:Plan("AcquireLoot", state2)
  assert(plan2 ~= nil, "Plan 2 should succeed via brute force fallback")
  assert(#plan2.Steps == 2)
  assert(plan2.Steps[1].Task.Name == "SmashLockWithHammer")
  assert(plan2.Steps[2].Task.Name == "LootTreasure")
  assert(plan2.TotalCost == 7 + 1)
end

-- Test 4: Execution Runner, step lifecycle, and live interruption
do
  local planner = HTNPlanner.new()

  planner:AddPrimitiveTask({
    Name = "AimAtTarget",
    PreconditionState = { TargetVisible = true },
    EffectState = { TargetAimed = true },
    Cost = 1,
  })

  planner:AddPrimitiveTask({
    Name = "FireWeapon",
    PreconditionState = { TargetAimed = true, AmmoCount = 5 },
    EffectState = { TargetNeutralized = true },
    Cost = 1,
  })

  planner:AddCompoundTask("AttackSequence")
  planner:AddMethod("AttackSequence", {
    Name = "DirectAttack",
    Subtasks = { "AimAtTarget", "FireWeapon" },
    Priority = 1,
  })

  local initialState = { TargetVisible = true, TargetAimed = false, AmmoCount = 5 }
  local plan = planner:Plan("AttackSequence", initialState)
  assert(plan ~= nil)

  local runner = planner:CreateRunner(plan)
  assert(runner.Status == "NotStarted")
  assert(runner:GetProgress() == 0)

  -- Step 1 execution
  local liveState = { TargetVisible = true, TargetAimed = false, AmmoCount = 5 }
  local status1, task1 = runner:Step(liveState)
  assert(status1 == "Running")
  assert(task1 ~= nil and task1.Name == "AimAtTarget")
  assert(runner:GetProgress() == 0.5)

  -- Simulate external environment interruption: Ammo suddenly became 0 before step 2!
  liveState.TargetAimed = true
  liveState.AmmoCount = 0 -- depleted!

  local status2, task2 = runner:Step(liveState)
  assert(status2 == "Interrupted", "Runner should report Interrupted when precondition violated")
  assert(task2 ~= nil and task2.Name == "FireWeapon")

  -- Reset runner on a successful flow
  local runnerClean = planner:CreateRunner(plan)
  local stateClean = { TargetVisible = true, TargetAimed = false, AmmoCount = 5 }
  runnerClean:Step(stateClean)
  stateClean.TargetAimed = true
  local statusCleanEnd, _ = runnerClean:Step(stateClean)
  assert(statusCleanEnd == "Completed")
  assert(runnerClean:GetProgress() == 1.0)
end

-- Test 5: Dynamic functional preconditions and effects
do
  local planner = HTNPlanner.new()

  planner:AddPrimitiveTask({
    Name = "ConsumeManaPotion",
    Preconditions = {
      function(st) return (st["Mana"] :: number) < 50 end,
      function(st) return (st["PotionCount"] :: number) > 0 end,
    },
    Effects = {
      function(st)
        local n = { Mana = (st["Mana"] :: number) + 40, PotionCount = (st["PotionCount"] :: number) - 1 }
        return n
      end,
    },
    Cost = 1,
  })

  planner:AddCompoundTask("ReplenishResources")
  planner:AddMethod("ReplenishResources", {
    Name = "PotionMethod",
    Preconditions = {
      function(st) return (st["Mana"] :: number) < 50 and (st["PotionCount"] :: number) > 0 end,
    },
    Subtasks = { "ConsumeManaPotion" },
  })

  local plan = planner:Plan("ReplenishResources", { Mana = 20, PotionCount = 3 })
  assert(plan ~= nil)
  assert(#plan.Steps == 1)
  assert(plan.Steps[1].Task.Name == "ConsumeManaPotion")

  -- When mana is already high, plan should fail cleanly
  local planHigh = planner:Plan("ReplenishResources", { Mana = 90, PotionCount = 3 })
  assert(planHigh == nil)
end

print("test_htn_planner: all tests passed successfully!")
