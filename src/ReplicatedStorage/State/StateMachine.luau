--!strict
--[[
  StateMachine.luau
  Production-grade Hierarchical Finite State Machine (HFSM) for Roblox.
  Features:
  - Hierarchical parent/child state nesting with automatic ancestor traversal
  - Strict lifecycle hooks: OnEnter, OnUpdate, OnExit, OnEvent
  - Guarded transition rules with event triggers
  - State stack push/pop mechanism for interrupts, stuns, and sub-modes
  - Lineage state querying (IsInState with ancestor inheritance check)
  - Event bubbling from leaf state up through ancestor chain
  Part of crustdev studio game systems (Aetheria: Fractured Realms).
  Zero external runtime dependencies.
]]

export type StateCallback = (machine: StateMachine, ...any) -> ()
export type EventCallback = (machine: StateMachine, eventName: string, ...any) -> boolean
export type TransitionGuard = (machine: StateMachine, ...any) -> boolean

export type StateDefinition = {
  Name: string,
  Parent: string?,
  OnEnter: ((machine: StateMachine, fromState: string, ...any) -> ())?,
  OnExit: ((machine: StateMachine, toState: string) -> ())?,
  OnUpdate: ((machine: StateMachine, dt: number) -> ())?,
  OnEvent: EventCallback?,
}

export type TransitionRule = {
  From: string,
  To: string,
  Event: string?,
  Guard: TransitionGuard?,
}

export type StateMachine = {
  States: { [string]: StateDefinition },
  Transitions: { TransitionRule },
  ActiveState: string?,
  Stack: { string },
  Blackboard: { [string]: any },
  TimeInState: number,

  -- Registration
  AddState: (self: StateMachine, def: StateDefinition) -> StateMachine,
  AddTransition: (self: StateMachine, fromState: string, toState: string, event: string?, guard: TransitionGuard?) -> StateMachine,

  -- Execution & Transitions
  SetInitialState: (self: StateMachine, stateName: string, ...any) -> boolean,
  Transition: (self: StateMachine, targetState: string, ...any) -> boolean,
  PushState: (self: StateMachine, targetState: string, ...any) -> boolean,
  PopState: (self: StateMachine, ...any) -> boolean,
  Update: (self: StateMachine, dt: number) -> (),
  FireEvent: (self: StateMachine, eventName: string, ...any) -> boolean,

  -- Queries & Data
  GetActiveState: (self: StateMachine) -> string?,
  IsInState: (self: StateMachine, stateName: string, includeAncestors: boolean?) -> boolean,
  GetStateLineage: (self: StateMachine, stateName: string?) -> { string },
  SetData: (self: StateMachine, key: string, value: any) -> (),
  GetData: (self: StateMachine, key: string, defaultVal: any?) -> any,
  Clear: (self: StateMachine) -> (),
}

local StateMachineImpl = {}
StateMachineImpl.__index = StateMachineImpl

function StateMachineImpl:AddState(def: StateDefinition): StateMachine
  assert(def.Name ~= nil and type(def.Name) == "string", "State name must be a string")
  self.States[def.Name] = def
  return self
end

function StateMachineImpl:AddTransition(fromState: string, toState: string, event: string?, guard: TransitionGuard?): StateMachine
  table.insert(self.Transitions, {
    From = fromState,
    To = toState,
    Event = event,
    Guard = guard,
  })
  return self
end

function StateMachineImpl:GetStateLineage(stateName: string?): { string }
  local target = stateName or self.ActiveState
  if not target or not self.States[target] then
    return {}
  end

  local lineage: { string } = {}
  local curr: string? = target

  while curr ~= nil do
    table.insert(lineage, 1, curr)
    local def = self.States[curr]
    curr = def and def.Parent or nil
  end

  return lineage
end

local function FindLowestCommonAncestor(lineageA: { string }, lineageB: { string }): (number, number)
  local i = 1
  while i <= #lineageA and i <= #lineageB and lineageA[i] == lineageB[i] do
    i += 1
  end
  -- i - 1 is the last shared ancestor index
  return i, i
end

function StateMachineImpl:SetInitialState(stateName: string, ...: any): boolean
  local targetDef = self.States[stateName]
  if not targetDef then return false end

  self.ActiveState = stateName
  self.TimeInState = 0
  self.Stack = {}

  local targetLineage = self:GetStateLineage(stateName)
  for _, stName in ipairs(targetLineage) do
    local def = self.States[stName]
    if def and def.OnEnter then
      def.OnEnter(self, "", ...)
    end
  end

  return true
end

function StateMachineImpl:Transition(targetState: string, ...: any): boolean
  if not self.ActiveState then
    return self:SetInitialState(targetState, ...)
  end

  if self.ActiveState == targetState then
    return false
  end

  local targetDef = self.States[targetState]
  if not targetDef then return false end

  local fromState = self.ActiveState
  local oldLineage = self:GetStateLineage(fromState)
  local newLineage = self:GetStateLineage(targetState)

  local exitIdx, enterIdx = FindLowestCommonAncestor(oldLineage, newLineage)

  -- Exit leaves up to LCA (reverse order: deepest leaf first)
  for i = #oldLineage, exitIdx, -1 do
    local def = self.States[oldLineage[i]]
    if def and def.OnExit then
      def.OnExit(self, targetState)
    end
  end

  self.ActiveState = targetState
  self.TimeInState = 0

  -- Enter new branch from LCA down to new leaf
  for i = enterIdx, #newLineage do
    local def = self.States[newLineage[i]]
    if def and def.OnEnter then
      def.OnEnter(self, fromState, ...)
    end
  end

  return true
end

function StateMachineImpl:PushState(targetState: string, ...: any): boolean
  if not self.ActiveState then
    return self:SetInitialState(targetState, ...)
  end

  table.insert(self.Stack, self.ActiveState)
  return self:Transition(targetState, ...)
end

function StateMachineImpl:PopState(...: any): boolean
  local count = #self.Stack
  if count == 0 then
    return false
  end

  local prevState = self.Stack[count]
  self.Stack[count] = nil
  return self:Transition(prevState, ...)
end

function StateMachineImpl:Update(dt: number)
  if not self.ActiveState then return end

  self.TimeInState += dt

  -- Evaluate automatic transitions (transitions with no event trigger)
  for _, rule in ipairs(self.Transitions) do
    if (rule.From == "*" or rule.From == self.ActiveState or self:IsInState(rule.From, true)) and rule.Event == nil then
      local allowed = true
      if rule.Guard then
        allowed = rule.Guard(self)
      end
      if allowed then
        self:Transition(rule.To)
        return
      end
    end
  end

  -- Run OnUpdate for full active lineage (ancestors first, then leaf)
  local lineage = self:GetStateLineage(self.ActiveState)
  for _, stateName in ipairs(lineage) do
    local def = self.States[stateName]
    if def and def.OnUpdate then
      def.OnUpdate(self, dt)
    end
  end
end

function StateMachineImpl:FireEvent(eventName: string, ...: any): boolean
  if not self.ActiveState then return false end

  -- 1. Check guarded transition rules registered for this event
  for _, rule in ipairs(self.Transitions) do
    if rule.Event == eventName then
      if rule.From == "*" or rule.From == self.ActiveState or self:IsInState(rule.From, true) then
        local allowed = true
        if rule.Guard then
          allowed = rule.Guard(self, ...)
        end
        if allowed then
          self:Transition(rule.To, ...)
          return true
        end
      end
    end
  end

  -- 2. Bubble event through active hierarchy (leaf to root)
  local lineage = self:GetStateLineage(self.ActiveState)
  for i = #lineage, 1, -1 do
    local def = self.States[lineage[i]]
    if def and def.OnEvent then
      local handled = def.OnEvent(self, eventName, ...)
      if handled then
        return true
      end
    end
  end

  return false
end

function StateMachineImpl:GetActiveState(): string?
  return self.ActiveState
end

function StateMachineImpl:IsInState(stateName: string, includeAncestors: boolean?): boolean
  if not self.ActiveState then return false end
  if self.ActiveState == stateName then return true end

  if includeAncestors ~= false then
    local lineage = self:GetStateLineage(self.ActiveState)
    for _, st in ipairs(lineage) do
      if st == stateName then
        return true
      end
    end
  end

  return false
end

function StateMachineImpl:SetData(key: string, value: any)
  self.Blackboard[key] = value
end

function StateMachineImpl:GetData(key: string, defaultVal: any?): any
  local val = self.Blackboard[key]
  if val == nil then
    return defaultVal
  end
  return val
end

function StateMachineImpl:Clear()
  if self.ActiveState then
    local lineage = self:GetStateLineage(self.ActiveState)
    for i = #lineage, 1, -1 do
      local def = self.States[lineage[i]]
      if def and def.OnExit then
        def.OnExit(self, "")
      end
    end
  end
  self.ActiveState = nil
  self.Stack = {}
  self.Transitions = {}
  self.States = {}
  self.Blackboard = {}
  self.TimeInState = 0
end

local StateMachine = {}

function StateMachine.new(): StateMachine
  local self = setmetatable({}, StateMachineImpl)
  self.States = {}
  self.Transitions = {}
  self.ActiveState = nil
  self.Stack = {}
  self.Blackboard = {}
  self.TimeInState = 0
  return self
end

return StateMachine
