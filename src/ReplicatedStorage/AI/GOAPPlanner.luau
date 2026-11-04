--!strict
--[[
  GOAPPlanner.luau
  crustdev studio systems - ReplicatedStorage/AI/GOAPPlanner

  High-performance Goal-Oriented Action Planning (GOAP) architecture for autonomous
  NPCs, squad tactics, companion AI, and emergent behavior synthesis in Roblox.

  Features:
  - WorldState representation with boolean, numeric, and string state variables.
  - Action definitions with preconditions, mutations/effects, and procedural or static costs.
  - A* forward search with admissible and consistent unmet-condition heuristic.
  - Cycle detection and state memoization via canonical state hashing.
  - Bounded iteration cutoff protecting against pathological/unsolvable graphs.
  - Plan validation, execution stepping, and plan introspection helpers.
  - Zero external dependencies. Fully compatible with Roblox Engine and Lune runtime.
]]

local EPSILON = 1e-6

export type StateValue = boolean | number | string

export type WorldState = { [string]: StateValue }

export type ActionCostFn = (state: WorldState) -> number

export type Action = {
  Name: string,
  Cost: number | ActionCostFn,
  Preconditions: WorldState,
  Effects: WorldState,
  Description: string?,
}

export type PlanResult = {
  Plan: { Action },
  TotalCost: number,
  Iterations: number,
}

type Node = {
  State: WorldState,
  G: number, -- Cumulative cost from start
  H: number, -- Heuristic cost to goal
  F: number, -- Total estimated cost (G + H)
  Action: Action?,
  Parent: Node?,
}

local GOAPPlanner = {}
GOAPPlanner.__index = GOAPPlanner

-- Utility: Deep clone a world state table
local function cloneState(state: WorldState): WorldState
  local copy: WorldState = {}
  for k, v in pairs(state) do
    copy[k] = v
  end
  return copy
end

-- Utility: Generate a canonical string hash for a world state
local function hashState(state: WorldState): string
  local keys = {}
  for k in pairs(state) do
    table.insert(keys, k)
  end
  table.sort(keys)

  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, string.format("%s=%s", tostring(k), tostring(state[k])))
  end
  return table.concat(parts, ";")
end

-- Utility: Check whether currentState satisfies all conditions in targetState
local function satisfiesConditions(currentState: WorldState, targetState: WorldState): boolean
  for k, requiredVal in pairs(targetState) do
    local currentVal = currentState[k]
    if currentVal == nil or currentVal ~= requiredVal then
      return false
    end
  end
  return true
end

-- Utility: Compute admissible heuristic (count of unmet goal conditions)
local function computeHeuristic(state: WorldState, goalState: WorldState): number
  local unmet = 0
  for k, targetVal in pairs(goalState) do
    if state[k] ~= targetVal then
      unmet += 1
    end
  end
  return unmet
end

-- Utility: Apply action effects to produce a new state
local function applyEffects(state: WorldState, effects: WorldState): WorldState
  local nextState = cloneState(state)
  for k, v in pairs(effects) do
    nextState[k] = v
  end
  return nextState
end

-- Utility: Resolve cost of an action (scalar or callback)
local function resolveCost(action: Action, state: WorldState): number
  if type(action.Cost) == "function" then
    local cost = (action.Cost :: ActionCostFn)(state)
    return math.max(EPSILON, cost)
  else
    return math.max(EPSILON, (action.Cost :: number) or 1)
  end
end

-- Constructor: Create a new GOAP planner
function GOAPPlanner.new(actions: { Action }?)
  local self = setmetatable({}, GOAPPlanner)
  self._actions = {} :: { Action }
  if actions then
    for _, action in ipairs(actions) do
      self:AddAction(action)
    end
  end
  return self
end

-- Register an action into the planner
function GOAPPlanner:AddAction(action: Action): ()
  assert(action.Name and #action.Name > 0, "Action must have a valid Name")
  assert(action.Preconditions, "Action must define Preconditions table")
  assert(action.Effects, "Action must define Effects table")
  table.insert(self._actions, action)
end

-- Clear all registered actions
function GOAPPlanner:ClearActions(): ()
  table.clear(self._actions)
end

-- Retrieve registered actions
function GOAPPlanner:GetActions(): { Action }
  return self._actions
end

-- Find the optimal action plan from startState to goalState using A* search
function GOAPPlanner:Plan(startState: WorldState, goalState: WorldState, maxIterations: number?): PlanResult?
  local limit = maxIterations or 1000

  -- If goal is already met at start, return empty plan with 0 cost
  if satisfiesConditions(startState, goalState) then
    return {
      Plan = {},
      TotalCost = 0,
      Iterations = 0,
    }
  end

  local initialNode: Node = {
    State = cloneState(startState),
    G = 0,
    H = computeHeuristic(startState, goalState),
    F = computeHeuristic(startState, goalState),
    Action = nil,
    Parent = nil,
  }

  local openList: { Node } = { initialNode }
  local closedScores: { [string]: number } = {}
  local iterations = 0

  while #openList > 0 and iterations < limit do
    iterations += 1

    -- Find node with lowest F score in openList (linear scan maintains zero-dependency portability)
    local bestIdx = 1
    local bestNode = openList[1]
    for i = 2, #openList do
      local node = openList[i]
      if node.F < bestNode.F or (node.F == bestNode.F and node.H < bestNode.H) then
        bestIdx = i
        bestNode = node
      end
    end

    -- Pop best node
    table.remove(openList, bestIdx)

    -- Check if goal state is satisfied
    if satisfiesConditions(bestNode.State, goalState) then
      -- Reconstruct path
      local plan: { Action } = {}
      local curr: Node? = bestNode
      while curr and curr.Action do
        table.insert(plan, 1, curr.Action)
        curr = curr.Parent
      end

      return {
        Plan = plan,
        TotalCost = bestNode.G,
        Iterations = iterations,
      }
    end

    -- Hash current state
    local stateKey = hashState(bestNode.State)
    if closedScores[stateKey] and closedScores[stateKey] <= bestNode.G then
      continue
    end
    closedScores[stateKey] = bestNode.G

    -- Expand applicable actions
    for _, action in ipairs(self._actions) do
      if satisfiesConditions(bestNode.State, action.Preconditions) then
        local nextState = applyEffects(bestNode.State, action.Effects)
        local nextKey = hashState(nextState)

        local actionCost = resolveCost(action, bestNode.State)
        local tentativeG = bestNode.G + actionCost

        if closedScores[nextKey] and closedScores[nextKey] <= tentativeG then
          continue
        end

        local h = computeHeuristic(nextState, goalState)
        local childNode: Node = {
          State = nextState,
          G = tentativeG,
          H = h,
          F = tentativeG + h,
          Action = action,
          Parent = bestNode,
        }

        -- Check if an open node already exists with equal or better G
        local skip = false
        for _, openNode in ipairs(openList) do
          if hashState(openNode.State) == nextKey and openNode.G <= tentativeG then
            skip = true
            break
          end
        end

        if not skip then
          table.insert(openList, childNode)
        end
      end
    end
  end

  -- No valid plan found within search boundary
  return nil
end

-- Validate whether a plan executed sequentially from initialState satisfies goalState
function GOAPPlanner:ValidatePlan(initialState: WorldState, plan: { Action }, goalState: WorldState): (boolean, string?)
  local current = cloneState(initialState)

  for i, action in ipairs(plan) do
    if not satisfiesConditions(current, action.Preconditions) then
      return false, string.format("Step %d (%s) failed: preconditions not met", i, action.Name)
    end
    current = applyEffects(current, action.Effects)
  end

  if not satisfiesConditions(current, goalState) then
    return false, "Final plan state does not satisfy target goal conditions"
  end

  return true, nil
end

-- Human-readable explanation of plan sequence
function GOAPPlanner:ExplainPlan(plan: { Action }): string
  if #plan == 0 then
    return "Empty plan (goal already satisfied or no actions required)"
  end

  local lines = { string.format("Plan Sequence (%d actions):", #plan) }
  for i, action in ipairs(plan) do
    local costStr = type(action.Cost) == "function" and "dynamic" or tostring(action.Cost)
    table.insert(lines, string.format("  %d. %s [cost: %s]", i, action.Name, costStr))
  end
  return table.concat(lines, "\n")
end

return GOAPPlanner
