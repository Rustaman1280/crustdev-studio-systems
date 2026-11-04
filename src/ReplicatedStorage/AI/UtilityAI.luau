--!strict
--[[
  UtilityAI.luau
  crustdev studio systems - ReplicatedStorage/AI/UtilityAI

  Production-grade Utility-Based AI decision system for autonomous NPCs and game agents:
  - Flexible mathematical response curves: Linear, Polynomial, Logistic/Sigmoid, Exponential, SmoothStep, Threshold.
  - Consideration normalization with clamp, invert, and weight parameters.
  - Dave Mark compensation factor to preserve utility scores across varying consideration counts.
  - Dual momentum and hysteresis damping to prevent behavioral rapid oscillation/thrashing.
  - Multi-tier action selection with TopScore and Softmax probabilistic modes.
  - Stateful action cooldown, lockout timers, and execution context tracking.
  - Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3

export type CurveKind =
  "Linear"
  | "Polynomial"
  | "Logistic"
  | "Exponential"
  | "SmoothStep"
  | "Threshold"

export type ConsiderationConfig = {
  name: string,
  minInput: number,
  maxInput: number,
  curve: CurveKind?,
  curveExponent: number?, -- Exponent for polynomial or steepness for logistic/exponential
  curveMidpoint: number?, -- Midpoint (x0) for logistic curve
  threshold: number?, -- Cutoff value for threshold curve
  weight: number?, -- Relative weight scalar (default 1.0)
  invert: boolean?, -- Invert output: 1.0 - score
}

export type ConsiderationEvaluator = (context: { [string]: any }) -> number

export type Consideration = {
  config: ConsiderationConfig,
  evaluator: ConsiderationEvaluator,
}

export type ActionConfig = {
  id: string,
  name: string,
  tier: number?, -- Priority tier (tier 1 evaluated first; higher tiers only if lower fails)
  baseScore: number?, -- Base score added prior to considerations (default 0.0)
  weight: number?, -- Action multiplier (default 1.0)
  cooldown: number?, -- Minimum interval in seconds between executions
  hysteresisBonus: number?, -- Extra score bonus if this action was chosen on previous tick
  minScoreThreshold: number?, -- Minimum score required to be considered valid (default 0.05)
}

export type Action = {
  config: ActionConfig,
  considerations: { Consideration },
}

export type SelectionMode = "TopScore" | "Softmax"

export type EvaluatedAction = {
  actionId: string,
  name: string,
  tier: number,
  rawScore: number,
  finalScore: number,
  isPreviousAction: boolean,
  onCooldown: boolean,
  considerationScores: { [string]: number },
}

export type UtilityAIState = {
  activeActionId: string?,
  previousActionId: string?,
  actionCooldowns: { [string]: number },
  lastEvaluation: { EvaluatedAction },
}

export type UtilityAI = {
  RegisterAction: (self: UtilityAI, config: ActionConfig) -> (),
  AddConsideration: (
    self: UtilityAI,
    actionId: string,
    config: ConsiderationConfig,
    evaluator: ConsiderationEvaluator
  ) -> (),
  Evaluate: (
    self: UtilityAI,
    context: { [string]: any },
    selectionMode: SelectionMode?,
    temperature: number?
  ) -> EvaluatedAction?,
  Step: (
    self: UtilityAI,
    dt: number,
    context: { [string]: any },
    selectionMode: SelectionMode?,
    temperature: number?
  ) -> EvaluatedAction?,
  TriggerAction: (self: UtilityAI, actionId: string) -> (),
  SetActionCooldown: (self: UtilityAI, actionId: string, cooldownTime: number) -> (),
  IsOnCooldown: (self: UtilityAI, actionId: string) -> boolean,
  GetState: (self: UtilityAI) -> UtilityAIState,
  Reset: (self: UtilityAI) -> (),
}

local UtilityAIImpl = {}
UtilityAIImpl.__index = UtilityAIImpl

--[[ Helper Functions for Mathematical Curves ]]
local function Clamp01(x: number): number
  if x < 0 then
    return 0
  elseif x > 1 then
    return 1
  end
  return x
end

local function EvaluateCurve(
  normalizedX: number,
  curve: CurveKind,
  exponent: number?,
  midpoint: number?,
  threshold: number?
): number
  local x = Clamp01(normalizedX)

  if curve == "Linear" then
    return x
  elseif curve == "Polynomial" then
    local p = exponent or 2.0
    return math.pow(x, p)
  elseif curve == "Logistic" then
    local k = exponent or 10.0
    local x0 = midpoint or 0.5
    local raw = 1.0 / (1.0 + math.exp(-k * (x - x0)))
    -- Normalize between f(0) and f(1)
    local minVal = 1.0 / (1.0 + math.exp(-k * (0 - x0)))
    local maxVal = 1.0 / (1.0 + math.exp(-k * (1 - x0)))
    if maxVal - minVal < 1e-6 then
      return raw
    end
    return Clamp01((raw - minVal) / (maxVal - minVal))
  elseif curve == "Exponential" then
    local k = exponent or 3.0
    local raw = (math.exp(k * x) - 1.0) / (math.exp(k) - 1.0)
    return Clamp01(raw)
  elseif curve == "SmoothStep" then
    return x * x * (3.0 - 2.0 * x)
  elseif curve == "Threshold" then
    local cut = threshold or 0.5
    return if x >= cut then 1.0 else 0.0
  end

  return x
end

--[[ Dave Mark Compensation Factor ]]
-- Compensates for score dilution when combining N considerations multiplicatively
local function ApplyCompensationFactor(productScore: number, numConsiderations: number): number
  if numConsiderations <= 1 then
    return productScore
  end
  local modFactor = 1.0 - (1.0 / numConsiderations)
  local makeUp = (1.0 - productScore) * modFactor
  return productScore + (makeUp * productScore)
end

function UtilityAIImpl.New(): UtilityAI
  local self = setmetatable({}, UtilityAIImpl)

  local actions: { [string]: Action } = {}
  local actionOrder: { string } = {}
  local cooldowns: { [string]: number } = {}
  local activeActionId: string? = nil
  local previousActionId: string? = nil
  local lastEvaluations: { EvaluatedAction } = {}

  function self:RegisterAction(config: ActionConfig): ()
    assert(config.id ~= nil and config.id ~= "", "Action id must be valid non-empty string")
    actions[config.id] = {
      config = {
        id = config.id,
        name = config.name or config.id,
        tier = config.tier or 1,
        baseScore = config.baseScore or 0.0,
        weight = config.weight or 1.0,
        cooldown = config.cooldown or 0.0,
        hysteresisBonus = config.hysteresisBonus or 0.0,
        minScoreThreshold = config.minScoreThreshold or 0.05,
      },
      considerations = {},
    }
    table.insert(actionOrder, config.id)
    cooldowns[config.id] = 0
  end

  function self:AddConsideration(
    actionId: string,
    config: ConsiderationConfig,
    evaluator: ConsiderationEvaluator
  ): ()
    local act = actions[actionId]
    assert(act ~= nil, string.format("Action %s does not exist", actionId))
    assert(config.name ~= nil and config.name ~= "", "Consideration name must be valid")
    assert(type(evaluator) == "function", "Evaluator must be a function")

    table.insert(act.considerations, {
      config = {
        name = config.name,
        minInput = config.minInput,
        maxInput = config.maxInput,
        curve = config.curve or "Linear",
        curveExponent = config.curveExponent,
        curveMidpoint = config.curveMidpoint,
        threshold = config.threshold,
        weight = config.weight or 1.0,
        invert = config.invert or false,
      },
      evaluator = evaluator,
    })
  end

  function self:IsOnCooldown(actionId: string): boolean
    local rem = cooldowns[actionId] or 0
    return rem > 0
  end

  function self:SetActionCooldown(actionId: string, cooldownTime: number): ()
    cooldowns[actionId] = math.max(0, cooldownTime)
  end

  function self:TriggerAction(actionId: string): ()
    local act = actions[actionId]
    if act ~= nil and (act.config.cooldown or 0) > 0 then
      cooldowns[actionId] = act.config.cooldown or 0
    end
    previousActionId = activeActionId
    activeActionId = actionId
  end

  local function EvaluateSingleAction(
    act: Action,
    context: { [string]: any }
  ): EvaluatedAction
    local id = act.config.id
    local onCooldown = (cooldowns[id] or 0) > 0
    local isCurrent = (activeActionId == id)

    if onCooldown then
      return {
        actionId = id,
        name = act.config.name,
        tier = act.config.tier or 1,
        rawScore = 0.0,
        finalScore = 0.0,
        isPreviousAction = isCurrent,
        onCooldown = true,
        considerationScores = {},
      }
    end

    local numConsiderations = #act.considerations
    local considerationScores: { [string]: number } = {}
    local scoreProduct = 1.0

    if numConsiderations == 0 then
      scoreProduct = 1.0
    else
      for _, cons in ipairs(act.considerations) do
        local rawInput = cons.evaluator(context)
        local range = cons.config.maxInput - cons.config.minInput
        local normalized = 0.0
        if math.abs(range) > 1e-6 then
          normalized = (rawInput - cons.config.minInput) / range
        end

        local curveScore = EvaluateCurve(
          normalized,
          cons.config.curve or "Linear",
          cons.config.curveExponent,
          cons.config.curveMidpoint,
          cons.config.threshold
        )

        if cons.config.invert then
          curveScore = 1.0 - curveScore
        end

        local weightedScore = Clamp01(curveScore * (cons.config.weight or 1.0))
        considerationScores[cons.config.name] = weightedScore
        scoreProduct = scoreProduct * weightedScore

        -- Short-circuit on complete zero utility
        if scoreProduct <= 0 then
          scoreProduct = 0
          break
        end
      end
    end

    -- Dave Mark Compensation
    local compensatedScore = ApplyCompensationFactor(scoreProduct, numConsiderations)

    -- Apply base score and action weight
    local rawScore = (compensatedScore + (act.config.baseScore or 0.0)) * (act.config.weight or 1.0)

    -- Apply hysteresis / momentum bonus if this was chosen on previous evaluation
    local finalScore = rawScore
    if isCurrent and act.config.hysteresisBonus and act.config.hysteresisBonus > 0 then
      finalScore = finalScore + act.config.hysteresisBonus
    end

    return {
      actionId = id,
      name = act.config.name,
      tier = act.config.tier or 1,
      rawScore = rawScore,
      finalScore = finalScore,
      isPreviousAction = isCurrent,
      onCooldown = false,
      considerationScores = considerationScores,
    }
  end

  function self:Evaluate(
    context: { [string]: any },
    selectionMode: SelectionMode?,
    temperature: number?
  ): EvaluatedAction?
    local mode = selectionMode or "TopScore"
    local temp = temperature or 1.0

    -- Group evaluated actions by tier
    local tierMap: { [number]: { EvaluatedAction } } = {}
    local allEvaluated: { EvaluatedAction } = {}

    for _, id in ipairs(actionOrder) do
      local act = actions[id]
      if act ~= nil then
        local eval = EvaluateSingleAction(act, context)
        table.insert(allEvaluated, eval)

        local t = eval.tier
        if not tierMap[t] then
          tierMap[t] = {}
        end
        table.insert(tierMap[t], eval)
      end
    end

    lastEvaluations = allEvaluated

    -- Sort tier keys in ascending order (tier 1 is highest priority)
    local tiers: { number } = {}
    for t in pairs(tierMap) do
      table.insert(tiers, t)
    end
    table.sort(tiers)

    for _, t in ipairs(tiers) do
      local tierActions = tierMap[t]
      local candidates: { EvaluatedAction } = {}

      for _, ev in ipairs(tierActions) do
        local minThresh = actions[ev.actionId].config.minScoreThreshold or 0.05
        if not ev.onCooldown and ev.finalScore >= minThresh then
          table.insert(candidates, ev)
        end
      end

      if #candidates > 0 then
        if mode == "TopScore" then
          local best: EvaluatedAction = candidates[1]
          for i = 2, #candidates do
            if candidates[i].finalScore > best.finalScore then
              best = candidates[i]
            end
          end
          return best
        elseif mode == "Softmax" then
          -- Softmax probability distribution
          local expScores: { number } = {}
          local expSum = 0.0
          local maxScore = -math.huge
          for _, c in ipairs(candidates) do
            if c.finalScore > maxScore then
              maxScore = c.finalScore
            end
          end

          for _, c in ipairs(candidates) do
            local e = math.exp((c.finalScore - maxScore) / math.max(0.01, temp))
            table.insert(expScores, e)
            expSum = expSum + e
          end

          local roll = math.random() * expSum
          local running = 0.0
          for idx, c in ipairs(candidates) do
            running = running + expScores[idx]
            if roll <= running then
              return c
            end
          end
          return candidates[#candidates]
        end
      end
    end

    return nil
  end

  function self:Step(
    dt: number,
    context: { [string]: any },
    selectionMode: SelectionMode?,
    temperature: number?
  ): EvaluatedAction?
    -- Update cooldowns
    for id, rem in pairs(cooldowns) do
      if rem > 0 then
        cooldowns[id] = math.max(0, rem - dt)
      end
    end

    local chosen = self:Evaluate(context, selectionMode, temperature)
    if chosen ~= nil then
      self:TriggerAction(chosen.actionId)
    else
      previousActionId = activeActionId
      activeActionId = nil
    end

    return chosen
  end

  function self:GetState(): UtilityAIState
    return {
      activeActionId = activeActionId,
      previousActionId = previousActionId,
      actionCooldowns = cooldowns,
      lastEvaluation = lastEvaluations,
    }
  end

  function self:Reset(): ()
    for id in pairs(cooldowns) do
      cooldowns[id] = 0
    end
    activeActionId = nil
    previousActionId = nil
    lastEvaluations = {}
  end

  return self
end

return {
  new = UtilityAIImpl.New,
  Clamp01 = Clamp01,
  EvaluateCurve = EvaluateCurve,
  ApplyCompensationFactor = ApplyCompensationFactor,
}
