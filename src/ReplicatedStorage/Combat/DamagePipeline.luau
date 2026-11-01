--!strict
--[[
  DamagePipeline.luau
  crustdev studio systems - ReplicatedStorage/Combat/DamagePipeline

  Deterministic multi-stage combat damage calculation pipeline with:
  - Hyperbolic armor mitigation and armor penetration formulas
  - Elemental affinities and resistance multipliers (-100% to +90%)
  - True damage bypass semantics
  - Multi-layered shield and barrier absorption with bleedthrough
  - Deterministic pseudo-random critical hit rolling for netcode sync
  - Lifesteal, thorns/reflection calculation, and lethal threshold auditing

  Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

export type DamageType = "Physical" | "Fire" | "Frost" | "Shock" | "Toxic" | "True"

export type ShieldLayer = {
  id: string,
  amount: number,
  maxAmount: number,
  absorptionRatio: number, -- 0.0 to 1.0 (e.g. 1.0 absorbs 100% until depleted)
}

export type TargetDefense = {
  armor: number,
  resistances: { [DamageType]: number }?,
  shields: { ShieldLayer }?,
  flatDamageReduction: number?,
  currentHealth: number,
  maxHealth: number,
}

export type DamagePayload = {
  attackerId: string?,
  targetId: string,
  rawAmount: number,
  damageType: DamageType,
  isCrit: boolean?,
  critMultiplier: number?,
  armorPenetrationFlat: number?,
  armorPenetrationPercent: number?,
  tags: { [string]: boolean }?,
}

export type PipelineOptions = {
  armorCoefficient: number?, -- Default k = 100 in: mitigated = raw * (k / (k + effectiveArmor))
  attackerLifeStealPercent: number?, -- 0.0 to 1.0
  targetReflectPercent: number?, -- 0.0 to 1.0
  allowShieldBleedthrough: boolean?,
}

export type DamageResult = {
  attackerId: string?,
  targetId: string,
  damageType: DamageType,
  initialRawDamage: number,
  effectiveRawDamage: number,
  isCrit: boolean,
  mitigatedByArmor: number,
  mitigatedByResistance: number,
  mitigatedByFlat: number,
  absorbedByShields: number,
  finalHealthDamage: number,
  targetRemainingHealth: number,
  isLethal: boolean,
  lifeStealAmount: number,
  reflectedDamageAmount: number,
  remainingShields: { ShieldLayer },
}

local DamagePipeline = {}
DamagePipeline.__index = DamagePipeline

local DEFAULT_ARMOR_COEFFICIENT = 100
local MAX_RESISTANCE_CAP = 0.90 -- Max 90% resistance
local MIN_RESISTANCE_CAP = -1.00 -- Max 100% vulnerability (2x damage)

-- Deterministic PRNG for crit resolution
function DamagePipeline.RollCrit(critChance: number, seed: number, sequenceIndex: number): boolean
  if critChance <= 0 then
    return false
  end
  if critChance >= 1.0 then
    return true
  end

  -- 32-bit integer LCG hash
  local state = (seed * 1664525 + sequenceIndex * 1013904223) % 4294967296
  state = bit32.bxor(state, bit32.rshift(state, 16))
  state = (state * 2246822519) % 4294967296
  local normalized = (state % 100000) / 100000

  return normalized < critChance
end

-- Calculates effective armor and hyperbolic mitigation
function DamagePipeline.CalculateArmorMitigation(
  rawDamage: number,
  armor: number,
  k: number?,
  flatPen: number?,
  pctPen: number?
): (number, number)
  local coefficient = k or DEFAULT_ARMOR_COEFFICIENT
  local flat = math.max(0, flatPen or 0)
  local pct = math.clamp(pctPen or 0, 0, 1)

  -- Apply penetration: flat penetration first, then percentage penetration
  local effectiveArmor = math.max(0, (armor - flat) * (1 - pct))

  if effectiveArmor <= 0 then
    return rawDamage, 0
  end

  local multiplier = coefficient / (coefficient + effectiveArmor)
  local postArmor = rawDamage * multiplier
  local mitigated = rawDamage - postArmor

  return postArmor, mitigated
end

-- Evaluates elemental resistance modifier
function DamagePipeline.CalculateResistanceMitigation(
  rawDamage: number,
  resistance: number?
): (number, number)
  if not resistance or resistance == 0 then
    return rawDamage, 0
  end

  local clampedRes = math.clamp(resistance, MIN_RESISTANCE_CAP, MAX_RESISTANCE_CAP)
  local postResDamage = rawDamage * (1 - clampedRes)
  local mitigated = rawDamage - postResDamage

  return postResDamage, mitigated
end

-- Full end-to-end pipeline execution
function DamagePipeline.ProcessDamage(
  payload: DamagePayload,
  defense: TargetDefense,
  options: PipelineOptions?
): DamageResult
  local opts = options or {}
  local k = opts.armorCoefficient or DEFAULT_ARMOR_COEFFICIENT
  local lifeStealRate = math.clamp(opts.attackerLifeStealPercent or 0, 0, 1)
  local reflectRate = math.clamp(opts.targetReflectPercent or 0, 0, 1)

  local isCrit = payload.isCrit or false
  local critMult = payload.critMultiplier or 1.5
  local effectiveRaw = payload.rawAmount

  if isCrit then
    effectiveRaw = payload.rawAmount * math.max(1, critMult)
  end

  local currentDamage = effectiveRaw
  local mitigatedByArmor = 0
  local mitigatedByRes = 0
  local mitigatedByFlat = 0
  local absorbedByShields = 0

  -- 1. True damage bypasses armor, resistance, flat reductions, and shields
  if payload.damageType == "True" then
    local finalDamage = currentDamage
    local remainingHealth = math.max(0, defense.currentHealth - finalDamage)
    local isLethal = remainingHealth <= 0

    local copiedShields: { ShieldLayer } = {}
    if defense.shields then
      for _, s in ipairs(defense.shields) do
        table.insert(copiedShields, {
          id = s.id,
          amount = s.amount,
          maxAmount = s.maxAmount,
          absorptionRatio = s.absorptionRatio,
        })
      end
    end

    return {
      attackerId = payload.attackerId,
      targetId = payload.targetId,
      damageType = payload.damageType,
      initialRawDamage = payload.rawAmount,
      effectiveRawDamage = effectiveRaw,
      isCrit = isCrit,
      mitigatedByArmor = 0,
      mitigatedByResistance = 0,
      mitigatedByFlat = 0,
      absorbedByShields = 0,
      finalHealthDamage = finalDamage,
      targetRemainingHealth = remainingHealth,
      isLethal = isLethal,
      lifeStealAmount = finalDamage * lifeStealRate,
      reflectedDamageAmount = finalDamage * reflectRate,
      remainingShields = copiedShields,
    }
  end

  -- 2. Armor mitigation (applies to Physical damage)
  if payload.damageType == "Physical" and defense.armor > 0 then
    local postArmor, armorMit = DamagePipeline.CalculateArmorMitigation(
      currentDamage,
      defense.armor,
      k,
      payload.armorPenetrationFlat,
      payload.armorPenetrationPercent
    )
    currentDamage = postArmor
    mitigatedByArmor = armorMit
  end

  -- 3. Elemental resistances
  if defense.resistances and defense.resistances[payload.damageType] then
    local res = defense.resistances[payload.damageType]
    local postRes, resMit = DamagePipeline.CalculateResistanceMitigation(currentDamage, res)
    currentDamage = postRes
    mitigatedByRes = resMit
  end

  -- 4. Flat damage reduction
  if defense.flatDamageReduction and defense.flatDamageReduction > 0 then
    local reduction = math.min(currentDamage, defense.flatDamageReduction)
    currentDamage = math.max(0, currentDamage - reduction)
    mitigatedByFlat = reduction
  end

  -- 5. Shield absorption layers (first-fit order)
  local updatedShields: { ShieldLayer } = {}
  if defense.shields and #defense.shields > 0 then
    for _, shield in ipairs(defense.shields) do
      local sAmount = shield.amount
      local sMax = shield.maxAmount
      local sRatio = math.clamp(shield.absorptionRatio or 1.0, 0, 1)

      if sAmount > 0 and currentDamage > 0 then
        local portionToAbsorb = currentDamage * sRatio
        local absorbable = math.min(portionToAbsorb, sAmount)
        local remainingPortion = currentDamage - absorbable

        absorbedByShields += absorbable
        sAmount -= absorbable
        currentDamage = remainingPortion
      end

      table.insert(updatedShields, {
        id = shield.id,
        amount = math.max(0, sAmount),
        maxAmount = sMax,
        absorptionRatio = sRatio,
      })
    end
  end

  -- 6. Health reduction and lethality check
  local finalHealthDamage = math.max(0, currentDamage)
  local remainingHealth = math.max(0, defense.currentHealth - finalHealthDamage)
  local isLethal = remainingHealth <= 0

  -- 7. Life steal and damage reflection
  local lifeSteal = finalHealthDamage * lifeStealRate
  local reflected = finalHealthDamage * reflectRate

  return {
    attackerId = payload.attackerId,
    targetId = payload.targetId,
    damageType = payload.damageType,
    initialRawDamage = payload.rawAmount,
    effectiveRawDamage = effectiveRaw,
    isCrit = isCrit,
    mitigatedByArmor = mitigatedByArmor,
    mitigatedByResistance = mitigatedByRes,
    mitigatedByFlat = mitigatedByFlat,
    absorbedByShields = absorbedByShields,
    finalHealthDamage = finalHealthDamage,
    targetRemainingHealth = remainingHealth,
    isLethal = isLethal,
    lifeStealAmount = lifeSteal,
    reflectedDamageAmount = reflected,
    remainingShields = updatedShields,
  }
end

return DamagePipeline
