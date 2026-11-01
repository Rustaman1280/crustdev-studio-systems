--!strict
--[[
  BehaviorTree.luau
  Production-grade composable Behavior Tree engine for AI decision making in Roblox.
  Supports Sequence, Selector, Parallel, Decorators (Inverter, Repeater, Succeeder),
  leaf Actions, Conditions, stateful running node memory, and Blackboard data sharing.
  Part of crustdev studio game systems (Aetheria: Fractured Realms).
]]

export type NodeStatus = "SUCCESS" | "FAILURE" | "RUNNING"

export type Blackboard = {
  Get: (self: Blackboard, key: string, defaultValue: any?) -> any,
  Set: (self: Blackboard, key: string, value: any) -> (),
  Has: (self: Blackboard, key: string) -> boolean,
  Remove: (self: Blackboard, key: string) -> (),
  Clear: (self: Blackboard) -> (),
  GetAll: (self: Blackboard) -> { [string]: any },
}

export type ActionCallback = (blackboard: Blackboard, dt: number) -> NodeStatus
export type ConditionCallback = (blackboard: Blackboard) -> boolean

export type NodeContext = {
  RunningIndices: { [any]: number },
  StepCounts: { [any]: number },
}

export type BTNode = {
  Type: string,
  Tick: (self: BTNode, blackboard: Blackboard, context: NodeContext, dt: number) -> NodeStatus,
  Reset: (self: BTNode, context: NodeContext) -> (),
}

export type TreeInstance = {
  RootNode: BTNode,
  Blackboard: Blackboard,
  Context: NodeContext,
  Tick: (self: TreeInstance, dt: number) -> NodeStatus,
  Reset: (self: TreeInstance) -> (),
}

local BehaviorTree = {}
BehaviorTree.__index = BehaviorTree

--[[ Blackboard Implementation ]]
local BlackboardImpl = {}
BlackboardImpl.__index = BlackboardImpl

function BehaviorTree.NewBlackboard(): Blackboard
  local data: { [string]: any } = {}
  local self = setmetatable({}, BlackboardImpl)

  function self:Get(key: string, defaultValue: any?): any
    local val = data[key]
    if val == nil then
      return defaultValue
    end
    return val
  end

  function self:Set(key: string, value: any): ()
    data[key] = value
  end

  function self:Has(key: string): boolean
    return data[key] ~= nil
  end

  function self:Remove(key: string): ()
    data[key] = nil
  end

  function self:Clear(): ()
    table.clear(data)
  end

  function self:GetAll(): { [string]: any }
    local copy: { [string]: any } = {}
    for k, v in pairs(data) do
      copy[k] = v
    end
    return copy
  end

  return (self :: any) :: Blackboard
end

--[[ Context Initialization ]]
local function createNodeContext(): NodeContext
  return {
    RunningIndices = {},
    StepCounts = {},
  }
end

--[[ Node Constructors ]]

-- Action Leaf Node: executes user callback
function BehaviorTree.Action(callback: ActionCallback): BTNode
  local node: BTNode = {
    Type = "Action",
    Tick = function(_self: BTNode, blackboard: Blackboard, _context: NodeContext, dt: number): NodeStatus
      return callback(blackboard, dt)
    end,
    Reset = function(_self: BTNode, _context: NodeContext) end,
  }
  return node
end

-- Condition Leaf Node: returns SUCCESS if true, FAILURE if false
function BehaviorTree.Condition(predicate: ConditionCallback): BTNode
  local node: BTNode = {
    Type = "Condition",
    Tick = function(_self: BTNode, blackboard: Blackboard, _context: NodeContext, _dt: number): NodeStatus
      local result = predicate(blackboard)
      return if result then "SUCCESS" else "FAILURE"
    end,
    Reset = function(_self: BTNode, _context: NodeContext) end,
  }
  return node
end

-- Sequence Composite: evaluates children sequentially. Fails on first FAILURE, resumes from RUNNING child.
function BehaviorTree.Sequence(children: { BTNode }): BTNode
  assert(#children > 0, "Sequence requires at least one child")
  local node: BTNode
  node = {
    Type = "Sequence",
    Tick = function(_self: BTNode, blackboard: Blackboard, context: NodeContext, dt: number): NodeStatus
      local startIndex = context.RunningIndices[node] or 1

      for i = startIndex, #children do
        local child = children[i]
        local status = child:Tick(blackboard, context, dt)

        if status == "RUNNING" then
          context.RunningIndices[node] = i
          return "RUNNING"
        elseif status == "FAILURE" then
          context.RunningIndices[node] = nil
          -- Reset subsequent children that may have run
          for j = i, #children do
            children[j]:Reset(context)
          end
          return "FAILURE"
        end
      end

      context.RunningIndices[node] = nil
      return "SUCCESS"
    end,
    Reset = function(_self: BTNode, context: NodeContext)
      context.RunningIndices[node] = nil
      for _, child in ipairs(children) do
        child:Reset(context)
      end
    end,
  }
  return node
end

-- Selector Composite (Fallback): evaluates children in order. Succeeds on first SUCCESS, resumes from RUNNING child.
function BehaviorTree.Selector(children: { BTNode }): BTNode
  assert(#children > 0, "Selector requires at least one child")
  local node: BTNode
  node = {
    Type = "Selector",
    Tick = function(_self: BTNode, blackboard: Blackboard, context: NodeContext, dt: number): NodeStatus
      local startIndex = context.RunningIndices[node] or 1

      for i = startIndex, #children do
        local child = children[i]
        local status = child:Tick(blackboard, context, dt)

        if status == "RUNNING" then
          context.RunningIndices[node] = i
          return "RUNNING"
        elseif status == "SUCCESS" then
          context.RunningIndices[node] = nil
          for j = i, #children do
            children[j]:Reset(context)
          end
          return "SUCCESS"
        end
      end

      context.RunningIndices[node] = nil
      return "FAILURE"
    end,
    Reset = function(_self: BTNode, context: NodeContext)
      context.RunningIndices[node] = nil
      for _, child in ipairs(children) do
        child:Reset(context)
      end
    end,
  }
  return node
end

-- Parallel Composite: runs all children concurrently each tick.
-- Policy: "RequireAll" (default: all must succeed) or "RequireOne" (one success suffices).
function BehaviorTree.Parallel(children: { BTNode }, successPolicy: ("RequireAll" | "RequireOne")?): BTNode
  assert(#children > 0, "Parallel requires at least one child")
  local policy = successPolicy or "RequireAll"

  local node: BTNode = {
    Type = "Parallel",
    Tick = function(_self: BTNode, blackboard: Blackboard, context: NodeContext, dt: number): NodeStatus
      local anyRunning = false
      local anySuccess = false
      local failureCount = 0

      for _, child in ipairs(children) do
        local status = child:Tick(blackboard, context, dt)
        if status == "RUNNING" then
          anyRunning = true
        elseif status == "SUCCESS" then
          anySuccess = true
        elseif status == "FAILURE" then
          failureCount += 1
        end
      end

      if policy == "RequireOne" then
        if anySuccess then
          return "SUCCESS"
        elseif anyRunning then
          return "RUNNING"
        else
          return "FAILURE"
        end
      else -- RequireAll
        if failureCount > 0 then
          return "FAILURE"
        elseif anyRunning then
          return "RUNNING"
        else
          return "SUCCESS"
        end
      end
    end,
    Reset = function(_self: BTNode, context: NodeContext)
      for _, child in ipairs(children) do
        child:Reset(context)
      end
    end,
  }
  return node
end

-- Inverter Decorator: inverts SUCCESS <-> FAILURE. RUNNING persists.
function BehaviorTree.Inverter(child: BTNode): BTNode
  local node: BTNode = {
    Type = "Inverter",
    Tick = function(_self: BTNode, blackboard: Blackboard, context: NodeContext, dt: number): NodeStatus
      local status = child:Tick(blackboard, context, dt)
      if status == "SUCCESS" then
        return "FAILURE"
      elseif status == "FAILURE" then
        return "SUCCESS"
      end
      return "RUNNING"
    end,
    Reset = function(_self: BTNode, context: NodeContext)
      child:Reset(context)
    end,
  }
  return node
end

-- Succeeder Decorator: always yields SUCCESS once complete (maps FAILURE -> SUCCESS). RUNNING persists.
function BehaviorTree.Succeeder(child: BTNode): BTNode
  local node: BTNode = {
    Type = "Succeeder",
    Tick = function(_self: BTNode, blackboard: Blackboard, context: NodeContext, dt: number): NodeStatus
      local status = child:Tick(blackboard, context, dt)
      if status == "RUNNING" then
        return "RUNNING"
      end
      return "SUCCESS"
    end,
    Reset = function(_self: BTNode, context: NodeContext)
      child:Reset(context)
    end,
  }
  return node
end

-- Repeater Decorator: repeats child execution N times (or until failure if untilFailure=true).
function BehaviorTree.Repeater(child: BTNode, repeatCount: number, untilFailure: boolean?): BTNode
  local node: BTNode
  node = {
    Type = "Repeater",
    Tick = function(_self: BTNode, blackboard: Blackboard, context: NodeContext, dt: number): NodeStatus
      local currentCount = context.StepCounts[node] or 0

      while currentCount < repeatCount do
        local status = child:Tick(blackboard, context, dt)
        if status == "RUNNING" then
          context.StepCounts[node] = currentCount
          return "RUNNING"
        elseif status == "FAILURE" and untilFailure then
          context.StepCounts[node] = nil
          child:Reset(context)
          return "SUCCESS"
        elseif status == "FAILURE" then
          context.StepCounts[node] = nil
          child:Reset(context)
          return "FAILURE"
        end

        currentCount += 1
        child:Reset(context)
      end

      context.StepCounts[node] = nil
      return "SUCCESS"
    end,
    Reset = function(_self: BTNode, context: NodeContext)
      context.StepCounts[node] = nil
      child:Reset(context)
    end,
  }
  return node
end

--[[ Tree Instance Construction ]]
function BehaviorTree.CreateTree(rootNode: BTNode, sharedBlackboard: Blackboard?): TreeInstance
  local blackboard = sharedBlackboard or BehaviorTree.NewBlackboard()
  local context = createNodeContext()

  local tree: TreeInstance = {
    RootNode = rootNode,
    Blackboard = blackboard,
    Context = context,
    Tick = function(self: TreeInstance, dt: number): NodeStatus
      return self.RootNode:Tick(self.Blackboard, self.Context, dt)
    end,
    Reset = function(self: TreeInstance)
      self.RootNode:Reset(self.Context)
    end,
  }

  return tree
end

return BehaviorTree
