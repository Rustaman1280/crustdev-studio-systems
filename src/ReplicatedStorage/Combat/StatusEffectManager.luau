--!strict
--[[
  StatusEffectManager.luau
  Production-grade authoritative buff, debuff, DoT, and crowd control management engine.
  Supports configurable stacking policies (Refresh, Stack, Extend, Independent),
  compound stat modifiers (Flat, Additive, Multiplicative), crowd-control flags,
  and delta-time accumulated periodic tick processing.
  Part of crustdev studio game systems (Aetheria: Fractured Realms).
]]

export type EffectType = "Buff" | "Debuff" | "CrowdControl" | "Neutral"

export type StackPolicy = "Refresh" | "Stack" | "Extend" | "Independent"

export type ModifierType = "Flat" | "Additive" | "Multiplicative"

export type StatModifier = {
  Type: ModifierType,
  Value: number,
}

export type EffectDefinition = {
  Id: string,
  Name: string,
  Type: EffectType,
  StackPolicy: StackPolicy,
  MaxStacks: number,
  BaseDuration: number,
  TickInterval: number?,
  Modifiers: { [string]: StatModifier }?,
  Flags: { [string]: boolean }?,
}

export type IndependentInstance = {
  RemainingDuration: number,
  SourceEntityId: string?,
  CustomData: { [string]: any }?,
}

export type ActiveEffect = {
  Definition: EffectDefinition,
  Stacks: number,
  RemainingDuration: number,
  TimeSinceLastTick: number,
  SourceEntityId: string?,
  CustomData: { [string]: any }?,
  IndependentInstances: { IndependentInstance }?,
}

export type TickEvent = {
  EffectId: string,
  Stacks: number,
  TickInterval: number,
  SourceEntityId: string?,
  CustomData: { [string]: any }?,
}

export type StepResult = {
  TickEvents: { TickEvent },
  ExpiredEffects: { string },
}

local StatusEffectManager = {}
StatusEffectManager.__index = StatusEffectManager

export type StatusEffectManagerInstance = typeof(setmetatable({} :: {
  OwnerId: string?,
  ActiveEffects: { [string]: ActiveEffect },
}, StatusEffectManager))

function StatusEffectManager.new(ownerId: string?): StatusEffectManagerInstance
  local self = setmetatable({}, StatusEffectManager)
  self.OwnerId = ownerId
  self.ActiveEffects = {} :: { [string]: ActiveEffect }
  return self
end

-- Apply or reapply a status effect following its defined StackPolicy
function StatusEffectManager:ApplyEffect(
  definition: EffectDefinition,
  sourceEntityId: string?,
  customData: { [string]: any }?
): (boolean, ActiveEffect)
  local effectId = definition.Id
  local existing = self.ActiveEffects[effectId]

  if not existing then
    local newEffect: ActiveEffect = {
      Definition = definition,
      Stacks = 1,
      RemainingDuration = definition.BaseDuration,
      TimeSinceLastTick = 0,
      SourceEntityId = sourceEntityId,
      CustomData = customData,
      IndependentInstances = nil,
    }

    if definition.StackPolicy == "Independent" then
      newEffect.IndependentInstances = {
        {
          RemainingDuration = definition.BaseDuration,
          SourceEntityId = sourceEntityId,
          CustomData = customData,
        },
      }
    end

    self.ActiveEffects[effectId] = newEffect
    return true, newEffect
  end

  -- Existing effect modification based on policy
  if definition.StackPolicy == "Refresh" then
    existing.RemainingDuration = definition.BaseDuration
    existing.SourceEntityId = sourceEntityId or existing.SourceEntityId
    existing.CustomData = customData or existing.CustomData
  elseif definition.StackPolicy == "Stack" then
    local currentStacks = existing.Stacks
    existing.Stacks = math.min(definition.MaxStacks, currentStacks + 1)
    existing.RemainingDuration = definition.BaseDuration
    existing.SourceEntityId = sourceEntityId or existing.SourceEntityId
    existing.CustomData = customData or existing.CustomData
  elseif definition.StackPolicy == "Extend" then
    local maxDurationCap = definition.BaseDuration * definition.MaxStacks
    existing.RemainingDuration = math.min(maxDurationCap, existing.RemainingDuration + definition.BaseDuration)
    existing.SourceEntityId = sourceEntityId or existing.SourceEntityId
    existing.CustomData = customData or existing.CustomData
  elseif definition.StackPolicy == "Independent" then
    local instances = existing.IndependentInstances or {}
    if #instances < definition.MaxStacks then
      table.insert(instances, {
        RemainingDuration = definition.BaseDuration,
        SourceEntityId = sourceEntityId,
        CustomData = customData,
      })
    else
      -- Replace or refresh the instance closest to expiring
      local minIdx = 1
      local minDur = math.huge
      for idx, inst in ipairs(instances) do
        if inst.RemainingDuration < minDur then
          minDur = inst.RemainingDuration
          minIdx = idx
        end
      end
      instances[minIdx].RemainingDuration = definition.BaseDuration
      instances[minIdx].SourceEntityId = sourceEntityId
      instances[minIdx].CustomData = customData
    end
    existing.IndependentInstances = instances
    existing.Stacks = #instances

    -- Overall remaining duration reflects longest active stack
    local maxDur = 0
    for _, inst in ipairs(instances) do
      if inst.RemainingDuration > maxDur then
        maxDur = inst.RemainingDuration
      end
    end
    existing.RemainingDuration = maxDur
  end

  return false, existing
end

-- Immediately remove an effect by ID
function StatusEffectManager:RemoveEffect(effectId: string): boolean
  if self.ActiveEffects[effectId] ~= nil then
    self.ActiveEffects[effectId] = nil
    return true
  end
  return false
end

-- Query presence of an active effect
function StatusEffectManager:HasEffect(effectId: string): boolean
  return self.ActiveEffects[effectId] ~= nil
end

-- Retrieve active effect object
function StatusEffectManager:GetEffect(effectId: string): ActiveEffect?
  return self.ActiveEffects[effectId]
end

-- Retrieve current stack count (0 if not active)
function StatusEffectManager:GetStackCount(effectId: string): number
  local effect = self.ActiveEffects[effectId]
  if not effect then
    return 0
  end
  return effect.Stacks
end

-- Check if any active status imparts a crowd-control flag (e.g. "IsStunned", "IsSilenced", "IsRooted")
function StatusEffectManager:HasFlag(flagName: string): boolean
  for _, effect in pairs(self.ActiveEffects) do
    local flags = effect.Definition.Flags
    if flags and flags[flagName] == true then
      return true
    end
  end
  return false
end

-- Compute modified stat value:
-- Final = (Base + sum(Flat * Stacks)) * (1 + sum(Additive * Stacks)) * prod((1 + Multiplicative) ^ Stacks)
function StatusEffectManager:ComputeStat(statName: string, baseValue: number): number
  local flatBonus = 0
  local additiveSum = 0
  local multiplicativeFactor = 1.0

  for _, effect in pairs(self.ActiveEffects) do
    local modifiers = effect.Definition.Modifiers
    if modifiers and modifiers[statName] then
      local mod = modifiers[statName]
      local stacks = effect.Stacks
      if mod.Type == "Flat" then
        flatBonus += mod.Value * stacks
      elseif mod.Type == "Additive" then
        additiveSum += mod.Value * stacks
      elseif mod.Type == "Multiplicative" then
        multiplicativeFactor *= ((1.0 + mod.Value) ^ stacks)
      end
    end
  end

  local baseAndFlat = baseValue + flatBonus
  local finalValue = baseAndFlat * (1.0 + additiveSum) * multiplicativeFactor
  return finalValue
end

-- Step active effects forward in time by dt seconds.
-- Emits periodic tick events and collects expired effect IDs.
function StatusEffectManager:Step(dt: number): StepResult
  local tickEvents: { TickEvent } = {}
  local expiredEffects: { string } = {}

  for effectId, effect in pairs(self.ActiveEffects) do
    local def = effect.Definition

    -- Handle duration decay
    if def.StackPolicy == "Independent" and effect.IndependentInstances then
      local instances = effect.IndependentInstances
      for i = #instances, 1, -1 do
        instances[i].RemainingDuration -= dt
        if instances[i].RemainingDuration <= 0 then
          table.remove(instances, i)
        end
      end
      effect.Stacks = #instances
      if #instances == 0 then
        table.insert(expiredEffects, effectId)
      else
        local maxDur = 0
        for _, inst in ipairs(instances) do
          if inst.RemainingDuration > maxDur then
            maxDur = inst.RemainingDuration
          end
        end
        effect.RemainingDuration = maxDur
      end
    else
      effect.RemainingDuration -= dt
      if effect.RemainingDuration <= 0 then
        table.insert(expiredEffects, effectId)
      end
    end

    -- Process periodic tick events if still alive or on final step
    local tickInterval = def.TickInterval
    if tickInterval and tickInterval > 0 and effect.Stacks > 0 then
      effect.TimeSinceLastTick += dt
      while effect.TimeSinceLastTick >= tickInterval do
        effect.TimeSinceLastTick -= tickInterval
        table.insert(tickEvents, {
          EffectId = effectId,
          Stacks = effect.Stacks,
          TickInterval = tickInterval,
          SourceEntityId = effect.SourceEntityId,
          CustomData = effect.CustomData,
        })
      end
    end
  end

  -- Remove expired effects
  for _, id in ipairs(expiredEffects) do
    self.ActiveEffects[id] = nil
  end

  return {
    TickEvents = tickEvents,
    ExpiredEffects = expiredEffects,
  }
end

-- Clear all active effects
function StatusEffectManager:Clear(): ()
  table.clear(self.ActiveEffects)
end

-- Export lightweight snapshot for client-server state replication
function StatusEffectManager:GetReplicationSnapshot(): { [string]: { Stacks: number, RemainingDuration: number } }
  local snapshot: { [string]: { Stacks: number, RemainingDuration: number } } = {}
  for id, effect in pairs(self.ActiveEffects) do
    snapshot[id] = {
      Stacks = effect.Stacks,
      RemainingDuration = effect.RemainingDuration,
    }
  end
  return snapshot
end

return StatusEffectManager
