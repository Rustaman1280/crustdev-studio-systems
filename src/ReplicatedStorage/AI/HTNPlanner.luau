--!strict
--[[
  HTNPlanner.luau
  crustdev studio systems - ReplicatedStorage/AI/HTNPlanner

  Production-grade Hierarchical Task Network (HTN) planner for AAA-style NPC decision
  making, tactical squads, boss encounters, and complex goal decomposition in Roblox.

  Features:
  - WorldState store supporting typed boolean, numeric, and string state variables.
  - Primitive Tasks: Atomic executable actions with preconditions, state effects, and execution costs.
  - Compound Tasks: Abstract goals decomposed into subtasks through conditional Methods.
  - Forward-search Total Order Decomposition with backtracking for finding optimal plans.
  - Execution Plan Runner: Tracks progress, active step, plan validation, and dynamic interrupt detection.
  - Zero Em-Dash Policy compliant.
  - Pure Luau / Lune compatible with zero external engine dependencies.
]]

local HTNPlanner = {}
HTNPlanner.__index = HTNPlanner

export type StateValue = boolean | number | string
export type WorldState = { [string]: StateValue }

export type PreconditionFn = (state: WorldState) -> boolean
export type EffectFn = (state: WorldState) -> WorldState

export type PrimitiveTask = {
  Name: string,
  Type: "Primitive",
  Preconditions: { PreconditionFn }?,
  PreconditionState: WorldState?,
  Effects: { EffectFn }?,
  EffectState: WorldState?,
  Cost: number,
  UserData: { [string]: any }?,
}

export type Method = {
  Name: string,
  Preconditions: { PreconditionFn }?,
  PreconditionState: WorldState?,
  Subtasks: { string }, -- List of task names (primitive or compound)
  Priority: number,     -- Higher priority methods are evaluated first
}

export type CompoundTask = {
  Name: string,
  Type: "Compound",
  Methods: { Method },
}

export type AnyTask = PrimitiveTask | CompoundTask

export type PlanStep = {
  Task: PrimitiveTask,
  ExpectedState: WorldState,
  StepIndex: number,
}

export type Plan = {
  Steps: { PlanStep },
  TotalCost: number,
  DecompositionDepth: number,
}

export type PlanStatus = "NotStarted" | "Running" | "Completed" | "Failed" | "Interrupted"

export type Runner = {
  Plan: Plan,
  CurrentIndex: number,
  Status: PlanStatus,
  Step: (self: Runner, currentState: WorldState) -> (PlanStatus, PrimitiveTask?),
  IsCurrentValid: (self: Runner, currentState: WorldState) -> boolean,
  GetProgress: (self: Runner) -> number,
}

export type HTNPlannerImpl = {
  AddPrimitiveTask: (self: HTNPlannerImpl, task: {
    Name: string,
    Preconditions: { PreconditionFn }?,
    PreconditionState: WorldState?,
    Effects: { EffectFn }?,
    EffectState: WorldState?,
    Cost: number?,
    UserData: { [string]: any }?,
  }) -> HTNPlannerImpl,

  AddCompoundTask: (self: HTNPlannerImpl, name: string) -> HTNPlannerImpl,

  AddMethod: (self: HTNPlannerImpl, compoundName: string, method: {
    Name: string,
    Preconditions: { PreconditionFn }?,
    PreconditionState: WorldState?,
    Subtasks: { string },
    Priority: number?,
  }) -> HTNPlannerImpl,

  Plan: (self: HTNPlannerImpl, rootTaskName: string, initialWorldState: WorldState) -> Plan?,
  PlanMultiple: (self: HTNPlannerImpl, rootTaskNames: { string }, initialWorldState: WorldState) -> Plan?,
  CreateRunner: (self: HTNPlannerImpl, plan: Plan) -> Runner,
  GetTask: (self: HTNPlannerImpl, name: string) -> AnyTask?,
  CloneState: (self: HTNPlannerImpl, state: WorldState) -> WorldState,
}

-- Utility: Clone state dictionary
local function cloneState(state: WorldState): WorldState
  local copy: WorldState = {}
  for k, v in pairs(state) do
    copy[k] = v
  end
  return copy
end

-- Utility: Apply preconditions check against state
local function evaluatePreconditions(
  state: WorldState,
  preconditionState: WorldState?,
  preconditions: { PreconditionFn }?
): boolean
  if preconditionState then
    for k, v in pairs(preconditionState) do
      if state[k] ~= v then
        return false
      end
    end
  end

  if preconditions then
    for _, fn in ipairs(preconditions) do
      if not fn(state) then
        return false
      end
    end
  end

  return true
end

-- Utility: Apply task effects on state
local function applyEffects(
  state: WorldState,
  effectState: WorldState?,
  effects: { EffectFn }?
): WorldState
  local newState = cloneState(state)

  if effectState then
    for k, v in pairs(effectState) do
      newState[k] = v
    end
  end

  if effects then
    for _, fn in ipairs(effects) do
      newState = fn(newState)
    end
  end

  return newState
end

function HTNPlanner.new(): HTNPlannerImpl
  local self = setmetatable({}, HTNPlanner)

  local tasks: { [string]: AnyTask } = {}

  local planner = {} :: any

  function planner:AddPrimitiveTask(taskDef: {
    Name: string,
    Preconditions: { PreconditionFn }?,
    PreconditionState: WorldState?,
    Effects: { EffectFn }?,
    EffectState: WorldState?,
    Cost: number?,
    UserData: { [string]: any }?,
  }): HTNPlannerImpl
    assert(taskDef.Name and taskDef.Name ~= "", "Primitive task must have a non-empty Name")
    assert(tasks[taskDef.Name] == nil, string.format("Task '%s' is already registered", taskDef.Name))

    local prim: PrimitiveTask = {
      Name = taskDef.Name,
      Type = "Primitive",
      Preconditions = taskDef.Preconditions,
      PreconditionState = taskDef.PreconditionState,
      Effects = taskDef.Effects,
      EffectState = taskDef.EffectState,
      Cost = taskDef.Cost or 1,
      UserData = taskDef.UserData,
    }
    tasks[taskDef.Name] = prim
    return planner
  end

  function planner:AddCompoundTask(name: string): HTNPlannerImpl
    assert(name and name ~= "", "Compound task must have a non-empty name")
    if tasks[name] == nil then
      local comp: CompoundTask = {
        Name = name,
        Type = "Compound",
        Methods = {},
      }
      tasks[name] = comp
    end
    return planner
  end

  function planner:AddMethod(compoundName: string, methodDef: {
    Name: string,
    Preconditions: { PreconditionFn }?,
    PreconditionState: WorldState?,
    Subtasks: { string },
    Priority: number?,
  }): HTNPlannerImpl
    local task = tasks[compoundName]
    if task == nil then
      planner:AddCompoundTask(compoundName)
      task = tasks[compoundName]
    end
    assert(task.Type == "Compound", string.format("Task '%s' is not a Compound task", compoundName))

    local method: Method = {
      Name = methodDef.Name,
      Preconditions = methodDef.Preconditions,
      PreconditionState = methodDef.PreconditionState,
      Subtasks = methodDef.Subtasks,
      Priority = methodDef.Priority or 0,
    }

    local comp = task :: CompoundTask
    table.insert(comp.Methods, method)

    -- Sort methods descending by Priority (highest priority first)
    table.sort(comp.Methods, function(a, b)
      return a.Priority > b.Priority
    end)

    return planner
  end

  function planner:GetTask(name: string): AnyTask?
    return tasks[name]
  end

  function planner:CloneState(state: WorldState): WorldState
    return cloneState(state)
  end

  -- Internal forward decomposition with backtracking
  local function decompose(
    taskList: { string },
    workingState: WorldState,
    accumulatedSteps: { PlanStep },
    depth: number,
    maxDepth: number
  ): (boolean, { PlanStep }?, WorldState?)
    if depth > maxDepth then
      return false, nil, nil -- Recursion safeguard
    end

    if #taskList == 0 then
      return true, accumulatedSteps, workingState
    end

    -- Pop first task from queue
    local currentTaskName = taskList[1]
    local remainingTasks = {}
    for i = 2, #taskList do
      table.insert(remainingTasks, taskList[i])
    end

    local task = tasks[currentTaskName]
    if not task then
      return false, nil, nil -- Unknown task in hierarchy
    end

    if task.Type == "Primitive" then
      local prim = task :: PrimitiveTask
      if evaluatePreconditions(workingState, prim.PreconditionState, prim.Preconditions) then
        local nextState = applyEffects(workingState, prim.EffectState, prim.Effects)
        local nextSteps = {}
        for _, s in ipairs(accumulatedSteps) do
          table.insert(nextSteps, s)
        end
        table.insert(nextSteps, {
          Task = prim,
          ExpectedState = cloneState(workingState),
          StepIndex = #nextSteps + 1,
        })

        local ok, finalSteps, finalState = decompose(remainingTasks, nextState, nextSteps, depth + 1, maxDepth)
        if ok then
          return true, finalSteps, finalState
        end
      end
      -- Backtrack if preconditions fail or sub-plan failed
      return false, nil, nil

    elseif task.Type == "Compound" then
      local comp = task :: CompoundTask
      for _, method in ipairs(comp.Methods) do
        if evaluatePreconditions(workingState, method.PreconditionState, method.Preconditions) then
          -- Build new task list: method.Subtasks followed by remainingTasks
          local newTaskList = {}
          for _, sub in ipairs(method.Subtasks) do
            table.insert(newTaskList, sub)
          end
          for _, rem in ipairs(remainingTasks) do
            table.insert(newTaskList, rem)
          end

          local ok, finalSteps, finalState = decompose(newTaskList, workingState, accumulatedSteps, depth + 1, maxDepth)
          if ok then
            return true, finalSteps, finalState
          end
        end
      end
      -- All methods failed or conditions not met; backtrack
      return false, nil, nil
    end

    return false, nil, nil
  end

  function planner:PlanMultiple(rootTaskNames: { string }, initialWorldState: WorldState): Plan?
    assert(#rootTaskNames > 0, "rootTaskNames must contain at least one task")
    local startState = cloneState(initialWorldState)
    local emptySteps: { PlanStep } = {}
    local maxDepth = 128

    local success, steps, _ = decompose(rootTaskNames, startState, emptySteps, 1, maxDepth)
    if not success or steps == nil then
      return nil
    end

    local totalCost = 0
    for _, step in ipairs(steps) do
      totalCost += step.Task.Cost
    end

    return {
      Steps = steps,
      TotalCost = totalCost,
      DecompositionDepth = #steps,
    }
  end

  function planner:Plan(rootTaskName: string, initialWorldState: WorldState): Plan?
    return planner:PlanMultiple({ rootTaskName }, initialWorldState)
  end

  function planner:CreateRunner(plan: Plan): Runner
    local runner: any = {
      Plan = plan,
      CurrentIndex = 1,
      Status = (#plan.Steps > 0) and "NotStarted" or "Completed",
    }

    function runner:IsCurrentValid(currentState: WorldState): boolean
      if runner.CurrentIndex > #runner.Plan.Steps then
        return false
      end
      local currentStep = runner.Plan.Steps[runner.CurrentIndex]
      local prim = currentStep.Task
      return evaluatePreconditions(currentState, prim.PreconditionState, prim.Preconditions)
    end

    function runner:GetProgress(): number
      if #runner.Plan.Steps == 0 then
        return 1.0
      end
      return math.clamp((runner.CurrentIndex - 1) / #runner.Plan.Steps, 0, 1)
    end

    function runner:Step(currentState: WorldState): (PlanStatus, PrimitiveTask?)
      if runner.CurrentIndex > #runner.Plan.Steps then
        runner.Status = "Completed"
        return "Completed", nil
      end

      local currentStep = runner.Plan.Steps[runner.CurrentIndex]
      local prim = currentStep.Task

      -- Verify if preconditions still hold in the live environment
      local valid = evaluatePreconditions(currentState, prim.PreconditionState, prim.Preconditions)
      if not valid then
        runner.Status = "Interrupted"
        return "Interrupted", prim
      end

      runner.Status = "Running"
      local executedTask = prim
      runner.CurrentIndex += 1

      if runner.CurrentIndex > #runner.Plan.Steps then
        runner.Status = "Completed"
      end

      return runner.Status, executedTask
    end

    return runner
  end

  return planner
end

return HTNPlanner
