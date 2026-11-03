--!strict
--[[
  ComboGraph.luau
  Directed Action Combo Graph & Frame-Window Execution Pipeline for Luau.
  Engineered for crustdev studio action combat (Aetheria: Fractured Realms).

  Features:
  - Directed acyclic and looping combo nodes (Light, Heavy, Special, Aerial, GuardCancel).
  - Explicit frame windows: Startup, Active (Hitbox), Cancel/Branch, and Recovery.
  - Input buffer queue with expiration timeout.
  - Hit confirmation gating (e.g., finisher moves only unlock on verified impact).
  - Diminishing returns scaling on damage and hitstun duration per combo chain count.
  - Multi-condition transitions (grounded vs airborne, stamina / energy gate).
  - Visual ASCII tree formatting for combo debugging and balancing.
]]

export type WindowTiming = {
  StartupDuration: number,     -- Time in seconds before hitbox becomes active
  ActiveDuration: number,      -- Time in seconds hitbox remains active
  CancelWindowDuration: number,-- Time in seconds when transitions/cancel can occur
  RecoveryDuration: number,    -- Lingering cooldown if no follow-up transition is made
}

export type AttackHitboxSpec = {
  Radius: number,
  Offset: Vector3,
  BaseDamage: number,
  HitstunDuration: number,
  KnockbackVector: Vector3,
}

export type ComboTransition = {
  TargetNodeId: string,
  RequiredTrigger: string,     -- e.g. "Light", "Heavy", "Special", "Dodge"
  AirborneCondition: string?,  -- "Any" | "GroundedOnly" | "AirborneOnly" (default: "Any")
  StaminaCost: number?,        -- Default 0
  RequiresHitConfirm: boolean?,-- If true, requires at least one hit registered in active window
}

export type AttackNode = {
  Id: string,
  Name: string,
  Timing: WindowTiming,
  Hitbox: AttackHitboxSpec,
  StaminaCost: number,
  Transitions: { ComboTransition },
}

export type ComboGraphDef = {
  EntryNodes: { [string]: string }, -- Mapping trigger (e.g. "Light") to starting AttackNodeId
  Nodes: { [string]: AttackNode },
}

export type ExecutionPhase = "Idle" | "Startup" | "Active" | "CancelWindow" | "Recovery"

export type ActiveComboState = {
  CurrentNode: AttackNode?,
  CurrentPhase: ExecutionPhase,
  PhaseElapsedTime: number,
  TotalComboElapsedTime: number,
  ComboHitCount: number,
  HitConfirmed: boolean,
  DamageMultiplier: number,
  HitstunMultiplier: number,
  BufferedTrigger: string?,
  BufferedTime: number,
}

local ComboGraph = {}

-- Damage decay multiplier curve: 1.0 -> 0.9 -> 0.8 -> 0.7 ... min 0.25
function ComboGraph.CalculateDamageMultiplier(hitCount: number): number
  if hitCount <= 1 then
    return 1.0
  end
  local scaled = 1.0 - (hitCount - 1) * 0.10
  return math.max(0.25, scaled)
end

-- Hitstun decay multiplier to avoid infinite vortex lock: min 0.30
function ComboGraph.CalculateHitstunMultiplier(hitCount: number): number
  if hitCount <= 1 then
    return 1.0
  end
  local scaled = 1.0 - (hitCount - 1) * 0.12
  return math.max(0.30, scaled)
end

function ComboGraph.CreateGraph(): ComboGraphDef
  return {
    EntryNodes = {},
    Nodes = {},
  }
end

function ComboGraph.AddNode(
  graph: ComboGraphDef,
  id: string,
  name: string,
  timing: WindowTiming,
  hitbox: AttackHitboxSpec,
  staminaCost: number?
): AttackNode
  local node: AttackNode = {
    Id = id,
    Name = name,
    Timing = timing,
    Hitbox = hitbox,
    StaminaCost = staminaCost or 0,
    Transitions = {},
  }
  graph.Nodes[id] = node
  return node
end

function ComboGraph.SetEntryNode(graph: ComboGraphDef, trigger: string, nodeId: string)
  assert(graph.Nodes[nodeId], "Entry nodeId must exist in graph: " .. nodeId)
  graph.EntryNodes[trigger] = nodeId
end

function ComboGraph.AddTransition(
  graph: ComboGraphDef,
  sourceNodeId: string,
  transition: ComboTransition
)
  local sourceNode = graph.Nodes[sourceNodeId]
  assert(sourceNode, "Source node does not exist: " .. sourceNodeId)
  assert(graph.Nodes[transition.TargetNodeId], "Target node does not exist: " .. transition.TargetNodeId)
  table.insert(sourceNode.Transitions, transition)
end

export type ComboTracker = {
  Graph: ComboGraphDef,
  State: ActiveComboState,
  InputBufferTimeout: number,
  StartCombo: (self: ComboTracker, trigger: string, isAirborne: boolean, currentStamina: number) -> boolean,
  ProcessInput: (self: ComboTracker, trigger: string, isAirborne: boolean, currentStamina: number) -> boolean,
  ConfirmHit: (self: ComboTracker) -> (),
  Step: (self: ComboTracker, deltaTime: number, isAirborne: boolean, currentStamina: number) -> (),
  GetState: (self: ComboTracker) -> ActiveComboState,
  Reset: (self: ComboTracker) -> (),
}

function ComboGraph.CreateTracker(graph: ComboGraphDef, bufferTimeout: number?): ComboTracker
  local tracker: any = {}
  tracker.Graph = graph
  tracker.InputBufferTimeout = bufferTimeout or 0.25

  local state: ActiveComboState = {
    CurrentNode = nil,
    CurrentPhase = "Idle",
    PhaseElapsedTime = 0.0,
    TotalComboElapsedTime = 0.0,
    ComboHitCount = 0,
    HitConfirmed = false,
    DamageMultiplier = 1.0,
    HitstunMultiplier = 1.0,
    BufferedTrigger = nil,
    BufferedTime = 0.0,
  }
  tracker.State = state

  local function TransitionToNode(targetNode: AttackNode)
    state.CurrentNode = targetNode
    state.CurrentPhase = "Startup"
    state.PhaseElapsedTime = 0.0
    state.HitConfirmed = false
    state.ComboHitCount += 1
    state.DamageMultiplier = ComboGraph.CalculateDamageMultiplier(state.ComboHitCount)
    state.HitstunMultiplier = ComboGraph.CalculateHitstunMultiplier(state.ComboHitCount)
    state.BufferedTrigger = nil
    state.BufferedTime = 0.0
  end

  local function CheckTransitionCondition(
    trans: ComboTransition,
    isAirborne: boolean,
    currentStamina: number
  ): boolean
    local cond = trans.AirborneCondition or "Any"
    if cond == "GroundedOnly" and isAirborne then
      return false
    end
    if cond == "AirborneOnly" and not isAirborne then
      return false
    end
    if trans.RequiresHitConfirm and not state.HitConfirmed then
      return false
    end
    if trans.StaminaCost and currentStamina < trans.StaminaCost then
      return false
    end
    return true
  end

  function tracker:StartCombo(trigger: string, isAirborne: boolean, currentStamina: number): boolean
    if state.CurrentPhase ~= "Idle" then
      return self:ProcessInput(trigger, isAirborne, currentStamina)
    end

    local entryId = graph.EntryNodes[trigger]
    if not entryId then
      return false
    end

    local targetNode = graph.Nodes[entryId]
    if not targetNode then
      return false
    end

    if currentStamina < targetNode.StaminaCost then
      return false
    end

    state.TotalComboElapsedTime = 0.0
    state.ComboHitCount = 0
    TransitionToNode(targetNode)
    return true
  end

  function tracker:ConfirmHit()
    state.HitConfirmed = true
  end

  function tracker:ProcessInput(trigger: string, isAirborne: boolean, currentStamina: number): boolean
    if state.CurrentPhase == "Idle" then
      return self:StartCombo(trigger, isAirborne, currentStamina)
    end

    -- If in cancel window, evaluate immediate transition
    if state.CurrentPhase == "CancelWindow" and state.CurrentNode then
      for _, trans in ipairs(state.CurrentNode.Transitions) do
        if trans.RequiredTrigger == trigger then
          if CheckTransitionCondition(trans, isAirborne, currentStamina) then
            local targetNode = graph.Nodes[trans.TargetNodeId]
            if targetNode then
              TransitionToNode(targetNode)
              return true
            end
          end
        end
      end
    end

    -- If in startup or active phase, buffer the input
    if state.CurrentPhase == "Startup" or state.CurrentPhase == "Active" then
      state.BufferedTrigger = trigger
      state.BufferedTime = 0.0
      return true
    end

    return false
  end

  function tracker:Step(deltaTime: number, isAirborne: boolean, currentStamina: number)
    if state.CurrentPhase == "Idle" or not state.CurrentNode then
      return
    end

    local dt = math.max(0.0, deltaTime)
    state.TotalComboElapsedTime += dt

    -- Manage input buffer decay
    if state.BufferedTrigger then
      state.BufferedTime += dt
      if state.BufferedTime > tracker.InputBufferTimeout then
        state.BufferedTrigger = nil
        state.BufferedTime = 0.0
      end
    end

    -- Process phase transitions through available dt budget
    while dt > 0 and state.CurrentPhase ~= "Idle" and state.CurrentNode do
      local timing = state.CurrentNode.Timing

      if state.CurrentPhase == "Startup" then
        local timeNeeded = timing.StartupDuration - state.PhaseElapsedTime
        if dt >= timeNeeded then
          dt -= timeNeeded
          state.CurrentPhase = "Active"
          state.PhaseElapsedTime = 0.0
        else
          state.PhaseElapsedTime += dt
          dt = 0
        end
      elseif state.CurrentPhase == "Active" then
        local timeNeeded = timing.ActiveDuration - state.PhaseElapsedTime
        if dt >= timeNeeded then
          dt -= timeNeeded
          state.CurrentPhase = "CancelWindow"
          state.PhaseElapsedTime = 0.0

          -- Check buffered input on entering CancelWindow
          if state.BufferedTrigger then
            local trigger = state.BufferedTrigger
            state.BufferedTrigger = nil
            local transitioned = false
            for _, trans in ipairs(state.CurrentNode.Transitions) do
              if trans.RequiredTrigger == trigger and CheckTransitionCondition(trans, isAirborne, currentStamina) then
                local targetNode = graph.Nodes[trans.TargetNodeId]
                if targetNode then
                  TransitionToNode(targetNode)
                  transitioned = true
                  break
                end
              end
            end
            if transitioned then
              -- Remaining dt applies to new node startup
              continue
            end
          end
        else
          state.PhaseElapsedTime += dt
          dt = 0
        end
      elseif state.CurrentPhase == "CancelWindow" then
        -- Also check buffered trigger if one exists during CancelWindow
        if state.BufferedTrigger then
          local trigger = state.BufferedTrigger
          state.BufferedTrigger = nil
          local transitioned = false
          for _, trans in ipairs(state.CurrentNode.Transitions) do
            if trans.RequiredTrigger == trigger and CheckTransitionCondition(trans, isAirborne, currentStamina) then
              local targetNode = graph.Nodes[trans.TargetNodeId]
              if targetNode then
                TransitionToNode(targetNode)
                transitioned = true
                break
              end
            end
          end
          if transitioned then
            continue
          end
        end

        local timeNeeded = timing.CancelWindowDuration - state.PhaseElapsedTime
        if dt >= timeNeeded then
          dt -= timeNeeded
          state.CurrentPhase = "Recovery"
          state.PhaseElapsedTime = 0.0
        else
          state.PhaseElapsedTime += dt
          dt = 0
        end
      elseif state.CurrentPhase == "Recovery" then
        local timeNeeded = timing.RecoveryDuration - state.PhaseElapsedTime
        if dt >= timeNeeded then
          self:Reset()
          dt = 0
        else
          state.PhaseElapsedTime += dt
          dt = 0
        end
      end
    end
  end

  function tracker:GetState(): ActiveComboState
    return table.clone(state)
  end

  function tracker:Reset()
    state.CurrentNode = nil
    state.CurrentPhase = "Idle"
    state.PhaseElapsedTime = 0.0
    state.TotalComboElapsedTime = 0.0
    state.ComboHitCount = 0
    state.HitConfirmed = false
    state.DamageMultiplier = 1.0
    state.HitstunMultiplier = 1.0
    state.BufferedTrigger = nil
    state.BufferedTime = 0.0
  end

  return tracker
end

-- Generates structured ASCII tree text representation for debugging
function ComboGraph.ToAscii(graph: ComboGraphDef): string
  local lines = {}
  table.insert(lines, "=== ComboGraph Architecture Tree ===")
  table.insert(lines, "Entry Triggers:")
  for trigger, nodeId in pairs(graph.EntryNodes) do
    table.insert(lines, string.format("  [%s] -> Node: %s", trigger, nodeId))
  end
  table.insert(lines, "Registered Attack Nodes:")
  for id, node in pairs(graph.Nodes) do
    table.insert(lines, string.format("  Node [%s] '%s' (Dmg: %.1f, Stamina: %d):", id, node.Name, node.Hitbox.BaseDamage, node.StaminaCost))
    table.insert(lines, string.format("    Timing: Startup=%.2fs | Active=%.2fs | Cancel=%.2fs | Recv=%.2fs",
      node.Timing.StartupDuration, node.Timing.ActiveDuration, node.Timing.CancelWindowDuration, node.Timing.RecoveryDuration))
    if #node.Transitions == 0 then
      table.insert(lines, "    Transitions: (Terminal Finisher / Reset)")
    else
      for _, trans in ipairs(node.Transitions) do
        local extras = {}
        if trans.AirborneCondition and trans.AirborneCondition ~= "Any" then
          table.insert(extras, trans.AirborneCondition)
        end
        if trans.RequiresHitConfirm then
          table.insert(extras, "HitConfirmReq")
        end
        if trans.StaminaCost and trans.StaminaCost > 0 then
          table.insert(extras, string.format("Cost:%d", trans.StaminaCost))
        end
        local extraStr = #extras > 0 and (" [" .. table.concat(extras, ", ") .. "]") or ""
        table.insert(lines, string.format("    --(%s)--> [%s]%s", trans.RequiredTrigger, trans.TargetNodeId, extraStr))
      end
    end
  end
  return table.concat(lines, "\n")
end

return ComboGraph
