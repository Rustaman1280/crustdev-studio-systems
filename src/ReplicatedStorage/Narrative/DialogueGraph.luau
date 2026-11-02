--!strict
--[[
  DialogueGraph.luau
  crustdev studio systems - ReplicatedStorage/Narrative/DialogueGraph

  Production-grade narrative state machine and branching dialogue tree engine:
  - Flexible dialogue graph with conditional node gates, choice prerequisites, and action hooks
  - State variable evaluation (comparisons, numeric thresholds, inventory tag presence)
  - OnEnter/OnExit node lifecycles and choice selection triggers
  - Visited node tracking with per-node visit counters (for repeatable vs first-time dialogue)
  - Custom event dispatching for game-engine integrations (cutscenes, rewards, quests)
  - Complete state serialization and restoration for cross-session persistence

  Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

export type ComparisonOperator = "==" | "!=" | ">" | ">=" | "<" | "<=" | "has" | "lacks"

export type DialogueCondition = {
  variable: string,
  operator: ComparisonOperator,
  value: any,
}

export type ActionType = "set" | "increment" | "toggle" | "event"

export type DialogueAction = {
  actionType: ActionType,
  variable: string?,
  value: any?,
  eventName: string?,
  payload: any?,
}

export type DialogueChoice = {
  id: string,
  text: string,
  targetNodeId: string,
  conditions: { DialogueCondition }?,
  actions: { DialogueAction }?,
  metadata: { [string]: any }?,
}

export type DialogueNode = {
  id: string,
  speaker: string,
  text: string,
  title: string?,
  choices: { DialogueChoice }?,
  conditions: { DialogueCondition }?,
  onEnterActions: { DialogueAction }?,
  onExitActions: { DialogueAction }?,
  nextNodeId: string?,
  metadata: { [string]: any }?,
}

export type DialogueSessionSnapshot = {
  currentNodeId: string?,
  variables: { [string]: any },
  visitedNodes: { [string]: number },
  history: { string },
  isFinished: boolean,
}

export type DialogueEventListener = (eventName: string, payload: any) -> ()

export type DialogueSession = {
  GetCurrentNode: (self: DialogueSession) -> DialogueNode?,
  GetAvailableChoices: (self: DialogueSession) -> { DialogueChoice },
  SelectChoice: (self: DialogueSession, choiceId: string) -> (DialogueNode?, boolean),
  Advance: (self: DialogueSession) -> (DialogueNode?, boolean),
  GetVariable: (self: DialogueSession, name: string) -> any,
  SetVariable: (self: DialogueSession, name: string, value: any) -> (),
  IncrementVariable: (self: DialogueSession, name: string, delta: number) -> number,
  HasVisited: (self: DialogueSession, nodeId: string) -> boolean,
  GetVisitCount: (self: DialogueSession, nodeId: string) -> number,
  GetHistory: (self: DialogueSession) -> { string },
  IsFinished: (self: DialogueSession) -> boolean,
  OnEvent: (self: DialogueSession, listener: DialogueEventListener) -> () -> (),
  Serialize: (self: DialogueSession) -> DialogueSessionSnapshot,
  Restore: (self: DialogueSession, snapshot: DialogueSessionSnapshot) -> (),
}

export type DialogueGraph = {
  AddNode: (self: DialogueGraph, node: DialogueNode) -> DialogueGraph,
  GetNode: (self: DialogueGraph, id: string) -> DialogueNode?,
  RemoveNode: (self: DialogueGraph, id: string) -> boolean,
  GetAllNodeIds: (self: DialogueGraph) -> { string },
  Validate: (self: DialogueGraph) -> (boolean, { string }),
  CreateSession: (self: DialogueGraph, startNodeId: string, initialVariables: { [string]: any }?) -> DialogueSession,
}

local DialogueGraphModule = {}

-- Utility: evaluate a single condition against variable context
local function evaluateCondition(condition: DialogueCondition, variables: { [string]: any }): boolean
  local varValue = variables[condition.variable]
  local op = condition.operator
  local target = condition.value

  if op == "==" then
    return varValue == target
  elseif op == "!=" then
    return varValue ~= target
  elseif op == ">" then
    if typeof(varValue) == "number" and typeof(target) == "number" then
      return varValue > target
    end
    return false
  elseif op == ">=" then
    if typeof(varValue) == "number" and typeof(target) == "number" then
      return varValue >= target
    end
    return false
  elseif op == "<" then
    if typeof(varValue) == "number" and typeof(target) == "number" then
      return varValue < target
    end
    return false
  elseif op == "<=" then
    if typeof(varValue) == "number" and typeof(target) == "number" then
      return varValue <= target
    end
    return false
  elseif op == "has" then
    if typeof(varValue) == "table" then
      for _, v in ipairs(varValue) do
        if v == target then
          return true
        end
      end
      return (varValue :: any)[target] ~= nil
    end
    return false
  elseif op == "lacks" then
    if typeof(varValue) == "table" then
      for _, v in ipairs(varValue) do
        if v == target then
          return false
        end
      end
      return (varValue :: any)[target] == nil
    end
    return true
  end

  return false
end

-- Utility: evaluate list of conditions (conjunction AND)
local function evaluateAllConditions(conditions: { DialogueCondition }?, variables: { [string]: any }): boolean
  if not conditions or #conditions == 0 then
    return true
  end

  for _, cond in ipairs(conditions) do
    if not evaluateCondition(cond, variables) then
      return false
    end
  end

  return true
end

-- Utility: execute a list of actions
local function executeActions(
  actions: { DialogueAction }?,
  variables: { [string]: any },
  listeners: { DialogueEventListener }
)
  if not actions then
    return
  end

  for _, act in ipairs(actions) do
    if act.actionType == "set" and act.variable then
      variables[act.variable] = act.value
    elseif act.actionType == "increment" and act.variable then
      local current = variables[act.variable]
      local num = if typeof(current) == "number" then current else 0
      local delta = if typeof(act.value) == "number" then act.value else 1
      variables[act.variable] = num + delta
    elseif act.actionType == "toggle" and act.variable then
      variables[act.variable] = not (variables[act.variable] == true)
    elseif act.actionType == "event" and act.eventName then
      for _, listener in ipairs(listeners) do
        local ok, err = pcall(listener, act.eventName :: string, act.payload)
        if not ok then
          warn(string.format("[DialogueGraph] Error in event listener '%s': %s", act.eventName, tostring(err)))
        end
      end
    end
  end
end

-- Construct a new DialogueGraph
function DialogueGraphModule.new(): DialogueGraph
  local nodes: { [string]: DialogueNode } = {}

  local self = {} :: DialogueGraph

  function self:AddNode(node: DialogueNode): DialogueGraph
    assert(node.id and node.id ~= "", "Node must have a valid non-empty id")
    assert(node.speaker and node.text, "Node must have speaker and text")
    nodes[node.id] = node
    return self
  end

  function self:GetNode(id: string): DialogueNode?
    return nodes[id]
  end

  function self:RemoveNode(id: string): boolean
    if nodes[id] then
      nodes[id] = nil
      return true
    end
    return false
  end

  function self:GetAllNodeIds(): { string }
    local ids = {}
    for id in pairs(nodes) do
      table.insert(ids, id)
    end
    return ids
  end

  -- Validate graph integrity: check for dangling choice references or unreachable targets
  function self:Validate(): (boolean, { string })
    local errors = {}

    for id, node in pairs(nodes) do
      if node.choices then
        for _, choice in ipairs(node.choices) do
          if not nodes[choice.targetNodeId] then
            table.insert(
              errors,
              string.format("Node '%s' choice '%s' references missing target '%s'", id, choice.id, choice.targetNodeId)
            )
          end
        end
      end

      if node.nextNodeId and not nodes[node.nextNodeId] then
        table.insert(
          errors,
          string.format("Node '%s' nextNodeId references missing target '%s'", id, node.nextNodeId)
        )
      end
    end

    return #errors == 0, errors
  end

  -- Create an active playback session for this graph
  function self:CreateSession(startNodeId: string, initialVariables: { [string]: any }?): DialogueSession
    local startNode = nodes[startNodeId]
    assert(startNode, string.format("Start node '%s' does not exist in graph", startNodeId))

    local variables: { [string]: any } = {}
    if initialVariables then
      for k, v in pairs(initialVariables) do
        variables[k] = v
      end
    end

    local visitedNodes: { [string]: number } = {}
    local history: { string } = {}
    local listeners: { DialogueEventListener } = {}
    local currentNode: DialogueNode? = startNode
    local isFinished = false

    local session = {} :: DialogueSession

    local function enterNode(node: DialogueNode)
      currentNode = node
      visitedNodes[node.id] = (visitedNodes[node.id] or 0) + 1
      table.insert(history, node.id)
      executeActions(node.onEnterActions, variables, listeners)
    end

    local function exitCurrentNode()
      if currentNode then
        executeActions(currentNode.onExitActions, variables, listeners)
      end
    end

    -- Trigger entry for start node
    enterNode(startNode)

    function session:GetCurrentNode(): DialogueNode?
      return currentNode
    end

    function session:GetAvailableChoices(): { DialogueChoice }
      if not currentNode or not currentNode.choices then
        return {}
      end

      local available = {}
      for _, choice in ipairs(currentNode.choices) do
        if evaluateAllConditions(choice.conditions, variables) then
          table.insert(available, choice)
        end
      end
      return available
    end

    function session:SelectChoice(choiceId: string): (DialogueNode?, boolean)
      if isFinished or not currentNode then
        return nil, false
      end

      local selectedChoice: DialogueChoice? = nil
      if currentNode.choices then
        for _, choice in ipairs(currentNode.choices) do
          if choice.id == choiceId then
            selectedChoice = choice
            break
          end
        end
      end

      if not selectedChoice then
        return nil, false
      end

      -- Verify conditions for the chosen option
      if not evaluateAllConditions(selectedChoice.conditions, variables) then
        return nil, false
      end

      -- Execute choice actions and exit current node
      executeActions(selectedChoice.actions, variables, listeners)
      exitCurrentNode()

      local nextNode = nodes[selectedChoice.targetNodeId]
      if nextNode then
        enterNode(nextNode)
        return nextNode, true
      else
        isFinished = true
        currentNode = nil
        return nil, true
      end
    end

    function session:Advance(): (DialogueNode?, boolean)
      if isFinished or not currentNode then
        return nil, false
      end

      -- If node has choices, advance cannot be performed automatically
      if currentNode.choices and #currentNode.choices > 0 then
        return nil, false
      end

      exitCurrentNode()

      if currentNode.nextNodeId then
        local nextNode = nodes[currentNode.nextNodeId]
        if nextNode then
          enterNode(nextNode)
          return nextNode, true
        end
      end

      -- End of dialogue line reached
      isFinished = true
      currentNode = nil
      return nil, true
    end

    function session:GetVariable(name: string): any
      return variables[name]
    end

    function session:SetVariable(name: string, value: any)
      variables[name] = value
    end

    function session:IncrementVariable(name: string, delta: number): number
      local cur = variables[name]
      local base = if typeof(cur) == "number" then cur else 0
      local newVal = base + delta
      variables[name] = newVal
      return newVal
    end

    function session:HasVisited(nodeId: string): boolean
      return (visitedNodes[nodeId] or 0) > 0
    end

    function session:GetVisitCount(nodeId: string): number
      return visitedNodes[nodeId] or 0
    end

    function session:GetHistory(): { string }
      local copy = {}
      for i, v in ipairs(history) do
        copy[i] = v
      end
      return copy
    end

    function session:IsFinished(): boolean
      return isFinished
    end

    function session:OnEvent(listener: DialogueEventListener): () -> ()
      table.insert(listeners, listener)
      return function()
        local idx = table.find(listeners, listener)
        if idx then
          table.remove(listeners, idx)
        end
      end
    end

    function session:Serialize(): DialogueSessionSnapshot
      local varsCopy = {}
      for k, v in pairs(variables) do
        varsCopy[k] = v
      end

      local visitedCopy = {}
      for k, v in pairs(visitedNodes) do
        visitedCopy[k] = v
      end

      local histCopy = {}
      for i, v in ipairs(history) do
        histCopy[i] = v
      end

      return {
        currentNodeId = if currentNode then currentNode.id else nil,
        variables = varsCopy,
        visitedNodes = visitedCopy,
        history = histCopy,
        isFinished = isFinished,
      }
    end

    function session:Restore(snapshot: DialogueSessionSnapshot)
      variables = {}
      for k, v in pairs(snapshot.variables) do
        variables[k] = v
      end

      visitedNodes = {}
      for k, v in pairs(snapshot.visitedNodes) do
        visitedNodes[k] = v
      end

      history = {}
      for i, v in ipairs(snapshot.history) do
        history[i] = v
      end

      isFinished = snapshot.isFinished
      if snapshot.currentNodeId then
        currentNode = nodes[snapshot.currentNodeId]
      else
        currentNode = nil
      end
    end

    return session
  end

  return self
end

return DialogueGraphModule
