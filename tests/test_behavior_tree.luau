--!strict
local BehaviorTree = require("../src/ReplicatedStorage/AI/BehaviorTree")

-- Helper assertion
local function assertEqual(actual: any, expected: any, msg: string?)
  if actual ~= expected then
    error(string.format("Assertion failed: expected '%s', got '%s'. %s", tostring(expected), tostring(actual), msg or ""))
  end
end

local function assertTrue(val: boolean, msg: string?)
  if not val then
    error(string.format("Assertion failed: expected true. %s", msg or ""))
  end
end

-- 1. Blackboard Operations
do
  local bb = BehaviorTree.NewBlackboard()
  assertEqual(bb:Get("health", 100), 100, "Default value on missing key")
  assertEqual(bb:Has("health"), false, "Has should be false before set")

  bb:Set("health", 85)
  assertEqual(bb:Has("health"), true, "Has should be true after set")
  assertEqual(bb:Get("health"), 85, "Get should return assigned value")

  bb:Set("targetId", "npc_wolf_01")
  local all = bb:GetAll()
  assertEqual(all["health"], 85, "GetAll contains health")
  assertEqual(all["targetId"], "npc_wolf_01", "GetAll contains targetId")

  bb:Remove("targetId")
  assertEqual(bb:Has("targetId"), false, "Has targetId should be false after remove")

  bb:Clear()
  assertEqual(bb:Has("health"), false, "Clear removes all entries")
end

-- 2. Action and Condition Leaf Nodes
do
  local bb = BehaviorTree.NewBlackboard()
  local context = { RunningIndices = {}, StepCounts = {} }

  local actionCalled = false
  local receivedDt = 0
  local actionNode = BehaviorTree.Action(function(b, dt)
    actionCalled = true
    receivedDt = dt
    b:Set("actionRan", true)
    return "SUCCESS"
  end)

  local status = actionNode:Tick(bb, context, 0.016)
  assertEqual(status, "SUCCESS", "Action node returns SUCCESS")
  assertTrue(actionCalled, "Action callback was called")
  assertEqual(receivedDt, 0.016, "Action received delta time")
  assertEqual(bb:Get("actionRan"), true, "Action modified blackboard")

  local condTrue = BehaviorTree.Condition(function(b)
    return b:Get("actionRan") == true
  end)
  assertEqual(condTrue:Tick(bb, context, 0.016), "SUCCESS", "Condition true yields SUCCESS")

  local condFalse = BehaviorTree.Condition(function(b)
    return b:Get("actionRan") == false
  end)
  assertEqual(condFalse:Tick(bb, context, 0.016), "FAILURE", "Condition false yields FAILURE")
end

-- 3. Sequence Composite (and Memory / Resume)
do
  local tree = BehaviorTree.CreateTree(
    BehaviorTree.Sequence({
      BehaviorTree.Action(function(bb, _dt)
        bb:Set("step1", true)
        return "SUCCESS"
      end),
      BehaviorTree.Action(function(bb, _dt)
        local count = bb:Get("step2_ticks", 0) + 1
        bb:Set("step2_ticks", count)
        if count < 2 then
          return "RUNNING"
        end
        return "SUCCESS"
      end),
      BehaviorTree.Action(function(bb, _dt)
        bb:Set("step3", true)
        return "SUCCESS"
      end),
    })
  )

  -- Tick 1: step1 succeeds, step2 returns RUNNING
  local s1 = tree:Tick(0.016)
  assertEqual(s1, "RUNNING", "Sequence tick 1 returns RUNNING")
  assertEqual(tree.Blackboard:Get("step1"), true, "Step 1 executed")
  assertEqual(tree.Blackboard:Get("step2_ticks"), 1, "Step 2 ticked once")
  assertEqual(tree.Blackboard:Get("step3"), nil, "Step 3 not yet executed")

  -- Tick 2: resumes directly at step2 (step1 not rerun!)
  tree.Blackboard:Set("step1", "untouched")
  local s2 = tree:Tick(0.016)
  assertEqual(s2, "SUCCESS", "Sequence tick 2 returns SUCCESS")
  assertEqual(tree.Blackboard:Get("step1"), "untouched", "Step 1 was not re-evaluated")
  assertEqual(tree.Blackboard:Get("step2_ticks"), 2, "Step 2 reached target count")
  assertEqual(tree.Blackboard:Get("step3"), true, "Step 3 completed successfully")

  -- Failure propagation
  local failTree = BehaviorTree.CreateTree(
    BehaviorTree.Sequence({
      BehaviorTree.Action(function() return "SUCCESS" end),
      BehaviorTree.Action(function() return "FAILURE" end),
      BehaviorTree.Action(function() error("Should not reach child 3") end),
    })
  )
  assertEqual(failTree:Tick(0.016), "FAILURE", "Sequence fails on first FAILURE")
end

-- 4. Selector Composite (Fallback)
do
  local bb = BehaviorTree.NewBlackboard()
  bb:Set("hasAmmo", false)
  bb:Set("hasMelee", true)

  local tree = BehaviorTree.CreateTree(
    BehaviorTree.Selector({
      BehaviorTree.Sequence({
        BehaviorTree.Condition(function(b) return b:Get("hasAmmo") == true end),
        BehaviorTree.Action(function(b) b:Set("attackType", "ranged"); return "SUCCESS" end),
      }),
      BehaviorTree.Sequence({
        BehaviorTree.Condition(function(b) return b:Get("hasMelee") == true end),
        BehaviorTree.Action(function(b) b:Set("attackType", "melee"); return "SUCCESS" end),
      }),
      BehaviorTree.Action(function(b) b:Set("attackType", "flee"); return "SUCCESS" end),
    }),
    bb
  )

  local s = tree:Tick(0.016)
  assertEqual(s, "SUCCESS", "Selector falls back and succeeds")
  assertEqual(tree.Blackboard:Get("attackType"), "melee", "Melee branch executed")
end

-- 5. Parallel Composite
do
  local childA_ticks = 0
  local childB_ticks = 0

  local parallelNode = BehaviorTree.Parallel({
    BehaviorTree.Action(function()
      childA_ticks += 1
      return if childA_ticks >= 2 then "SUCCESS" else "RUNNING"
    end),
    BehaviorTree.Action(function()
      childB_ticks += 1
      return "SUCCESS"
    end),
  }, "RequireAll")

  local tree = BehaviorTree.CreateTree(parallelNode)
  local t1 = tree:Tick(0.016)
  assertEqual(t1, "RUNNING", "Parallel RequireAll returns RUNNING when any child is RUNNING")

  local t2 = tree:Tick(0.016)
  assertEqual(t2, "SUCCESS", "Parallel RequireAll returns SUCCESS when all complete")
  assertEqual(childA_ticks, 2, "Child A ticked twice")
  assertEqual(childB_ticks, 2, "Child B ticked twice")
end

-- 6. Decorators: Inverter, Succeeder, Repeater
do
  local bb = BehaviorTree.NewBlackboard()
  local context = { RunningIndices = {}, StepCounts = {} }

  local inverterSuccess = BehaviorTree.Inverter(BehaviorTree.Action(function() return "SUCCESS" end))
  assertEqual(inverterSuccess:Tick(bb, context, 0.016), "FAILURE", "Inverter inverts SUCCESS to FAILURE")

  local inverterFail = BehaviorTree.Inverter(BehaviorTree.Action(function() return "FAILURE" end))
  assertEqual(inverterFail:Tick(bb, context, 0.016), "SUCCESS", "Inverter inverts FAILURE to SUCCESS")

  local succeeder = BehaviorTree.Succeeder(BehaviorTree.Action(function() return "FAILURE" end))
  assertEqual(succeeder:Tick(bb, context, 0.016), "SUCCESS", "Succeeder maps FAILURE to SUCCESS")

  local loopCounter = 0
  local repeater = BehaviorTree.Repeater(
    BehaviorTree.Action(function()
      loopCounter += 1
      return "SUCCESS"
    end),
    3
  )
  assertEqual(repeater:Tick(bb, context, 0.016), "SUCCESS", "Repeater completes N iterations")
  assertEqual(loopCounter, 3, "Repeater executed exactly 3 times")
end

print("PASS: BehaviorTree tests (Blackboard, Actions, Conditions, Sequence, Selector, Parallel, Decorators) passed cleanly!")
