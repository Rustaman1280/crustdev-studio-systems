local GOAPPlanner = require("../src/ReplicatedStorage/AI/GOAPPlanner")

-- Test 1: Empty plan when goal is already satisfied
do
  local planner = GOAPPlanner.new()
  local startState = { HasKey = true, DoorOpen = true }
  local goalState = { DoorOpen = true }

  local res = planner:Plan(startState, goalState)
  assert(res ~= nil, "Should return a plan result")
  assert(#res.Plan == 0, "Plan should be empty when goal already satisfied")
  assert(res.TotalCost == 0, "Cost should be 0")
end

-- Test 2: Multi-step survival craft progression
do
  local planner = GOAPPlanner.new()

  planner:AddAction({
    Name = "GatherBranches",
    Cost = 2,
    Preconditions = { HasBranches = false },
    Effects = { HasBranches = true },
  })

  planner:AddAction({
    Name = "GatherFlint",
    Cost = 3,
    Preconditions = { HasFlint = false },
    Effects = { HasFlint = true },
  })

  planner:AddAction({
    Name = "CraftAxe",
    Cost = 1,
    Preconditions = { HasBranches = true, HasFlint = true, HasAxe = false },
    Effects = { HasAxe = true },
  })

  planner:AddAction({
    Name = "ChopLumber",
    Cost = 4,
    Preconditions = { HasAxe = true, HasLumber = false },
    Effects = { HasLumber = true },
  })

  planner:AddAction({
    Name = "BuildShelter",
    Cost = 5,
    Preconditions = { HasLumber = true, HasShelter = false },
    Effects = { HasShelter = true },
  })

  local startState = {
    HasBranches = false,
    HasFlint = false,
    HasAxe = false,
    HasLumber = false,
    HasShelter = false,
  }

  local goalState = { HasShelter = true }

  local res = planner:Plan(startState, goalState)
  assert(res ~= nil, "Plan should be found")
  assert(#res.Plan == 5, "Should have 5 steps: branches, flint, axe, lumber, shelter")
  assert(res.Plan[#res.Plan].Name == "BuildShelter", "Final step must be BuildShelter")
  assert(res.TotalCost == 2 + 3 + 1 + 4 + 5, "Total cost should equal sum of action costs (15)")

  local ok, err = planner:ValidatePlan(startState, res.Plan, goalState)
  assert(ok == true, "ValidatePlan must succeed: " .. tostring(err))

  local explanation = planner:ExplainPlan(res.Plan)
  assert(string.find(explanation, "Plan Sequence (5 actions):", 1, true) ~= nil, "Explanation should include header")
end

-- Test 3: Branching path optimization (Cost evaluation)
do
  local planner = GOAPPlanner.new()

  -- Option A: Buy bridge pass (expensive, 1 step)
  planner:AddAction({
    Name = "BuyBridgePass",
    Cost = 20,
    Preconditions = { AtRiver = true, HasCoin = true },
    Effects = { AcrossRiver = true },
  })

  -- Option B: Find ford and swim (cheap, 2 steps: FindFord cost 3 + SwimRiver cost 4 = 7)
  planner:AddAction({
    Name = "FindFord",
    Cost = 3,
    Preconditions = { AtRiver = true, KnownFord = false },
    Effects = { KnownFord = true },
  })

  planner:AddAction({
    Name = "SwimRiver",
    Cost = 4,
    Preconditions = { AtRiver = true, KnownFord = true },
    Effects = { AcrossRiver = true },
  })

  local startState = { AtRiver = true, HasCoin = true, KnownFord = false, AcrossRiver = false }
  local goalState = { AcrossRiver = true }

  local res = planner:Plan(startState, goalState)
  assert(res ~= nil, "Plan should be found")
  assert(res.TotalCost == 7, "A* should choose the lower-cost route (total cost 7 instead of 20)")
  assert(#res.Plan == 2, "Lower cost route has 2 actions")
  assert(res.Plan[1].Name == "FindFord", "Step 1 should be FindFord")
  assert(res.Plan[2].Name == "SwimRiver", "Step 2 should be SwimRiver")
end

-- Test 4: Dynamic procedural cost callback
do
  local planner = GOAPPlanner.new()

  planner:AddAction({
    Name = "SneakPastGuard",
    Cost = function(state)
      -- Sneaking is very costly if stealth skill is low
      return state.StealthSkill > 50 and 5 or 50
    end,
    Preconditions = { InCombat = false, GuardAlerted = false },
    Effects = { InTreasury = true },
  })

  planner:AddAction({
    Name = "BribeGuard",
    Cost = 15,
    Preconditions = { GuardAlerted = false },
    Effects = { InTreasury = true },
  })

  -- Case A: Low stealth -> BribeGuard is cheaper (15 vs 50)
  local stateLowStealth = { InCombat = false, GuardAlerted = false, StealthSkill = 10, InTreasury = false }
  local resA = planner:Plan(stateLowStealth, { InTreasury = true })
  assert(resA ~= nil and #resA.Plan == 1, "Should find plan")
  assert(resA.Plan[1].Name == "BribeGuard", "Low stealth should choose BribeGuard")
  assert(resA.TotalCost == 15, "Cost should be 15")

  -- Case B: High stealth -> SneakPastGuard is cheaper (5 vs 15)
  local stateHighStealth = { InCombat = false, GuardAlerted = false, StealthSkill = 80, InTreasury = false }
  local resB = planner:Plan(stateHighStealth, { InTreasury = true })
  assert(resB ~= nil and #resB.Plan == 1, "Should find plan")
  assert(resB.Plan[1].Name == "SneakPastGuard", "High stealth should choose SneakPastGuard")
  assert(resB.TotalCost == 5, "Cost should be 5")
end

-- Test 5: Unsolvable goal returns nil within limit
do
  local planner = GOAPPlanner.new()

  planner:AddAction({
    Name = "Rest",
    Cost = 1,
    Preconditions = { Tired = true },
    Effects = { Tired = false },
  })

  local start = { Tired = false }
  local goal = { HasGold = true } -- No actions exist to acquire gold

  local res = planner:Plan(start, goal, 50)
  assert(res == nil, "Unsolvable goal must return nil")
end

print("GOAPPlanner unit tests passed successfully!")
