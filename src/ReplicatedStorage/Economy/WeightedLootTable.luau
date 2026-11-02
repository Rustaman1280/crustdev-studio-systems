--!strict
--[[
  WeightedLootTable.luau
  crustdev studio systems - ReplicatedStorage/Economy/WeightedLootTable

  Deterministic, weighted game drop engine featuring:
  - Weighted distribution sampling with cumulative prefix sums
  - Tiered classification: Common, Uncommon, Rare, Epic, Legendary, Mythic
  - Luck coefficient scaling: dynamically boost high-tier weights without distorting base tables
  - Pity tracking mechanism: cumulative roll counters guarantee high-tier drops upon threshold
  - Guaranteed drops: distinct items awarded unconditionally alongside random rolls
  - Deterministic PRNG seeding: perfectly reproducible drops for netcode validation
  - With/Without replacement rolling semantics
  - Nested sub-tables for hierarchical loot trees

  Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

export type LootTier = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic"

export type LootEntry = {
  id: string,
  weight: number,
  tier: LootTier?,
  minQuantity: number?,
  maxQuantity: number?,
  guaranteed: boolean?,
  subTable: any?, -- Recursive LootTable if entry spawns sub-pool
  metadata: { [string]: any }?,
}

export type LootDrop = {
  id: string,
  tier: LootTier,
  quantity: number,
  isGuaranteed: boolean,
  pityTriggered: boolean,
  metadata: { [string]: any }?,
}

export type PityRule = {
  tier: LootTier,
  maxThreshold: number, -- rolls without tier before guarantee
  currentCounter: number,
}

export type RollOptions = {
  rolls: number?,
  seed: number?,
  luck: number?, -- default 1.0; values > 1.0 boost Rare, Epic, Legendary, Mythic
  withReplacement: boolean?,
  pityRules: { [LootTier]: PityRule }?,
}

export type LootTableResult = {
  drops: { LootDrop },
  updatedPity: { [LootTier]: number },
}

export type LootTable = {
  AddEntry: (self: LootTable, entry: LootEntry) -> (),
  RemoveEntry: (self: LootTable, id: string) -> boolean,
  GetTotalWeight: (self: LootTable, luck: number?) -> number,
  Roll: (self: LootTable, options: RollOptions?) -> LootTableResult,
  GetEntries: (self: LootTable) -> { LootEntry },
}

type InternalLootTable = LootTable & {
  _entries: { LootEntry },
  _idMap: { [string]: LootEntry },
}

local TIER_LUCK_WEIGHTS: { [LootTier]: number } = {
  Common = 0.0,
  Uncommon = 0.25,
  Rare = 0.65,
  Epic = 1.0,
  Legendary = 1.5,
  Mythic = 2.0,
}

-- Fast deterministic Linear Congruential Generator for reproducible drops
local function createPrng(seed: number)
  local state = math.abs(math.floor(seed)) % 2147483647
  if state == 0 then
    state = 123456789
  end

  return function(): number
    state = (state * 16807) % 2147483647
    return (state - 1) / 2147483646
  end
end

local WeightedLootTable = {}
WeightedLootTable.__index = WeightedLootTable

-- Creates a new WeightedLootTable instance
function WeightedLootTable.new(initialEntries: { LootEntry }?): LootTable
  local self = setmetatable({
    _entries = {} :: { LootEntry },
    _idMap = {} :: { [string]: LootEntry },
  }, WeightedLootTable) :: any

  if initialEntries then
    for _, entry in ipairs(initialEntries) do
      self:AddEntry(entry)
    end
  end

  return self
end

-- Adds an entry to the table
function WeightedLootTable.AddEntry(self: InternalLootTable, entry: LootEntry): ()
  assert(type(entry) == "table", "LootEntry must be a table")
  assert(type(entry.id) == "string" and #entry.id > 0, "LootEntry must have a valid string id")
  assert(type(entry.weight) == "number" and entry.weight >= 0, "LootEntry weight must be non-negative")

  if self._idMap[entry.id] then
    self:RemoveEntry(entry.id)
  end

  local cleanEntry: LootEntry = {
    id = entry.id,
    weight = entry.weight,
    tier = entry.tier or "Common",
    minQuantity = math.max(1, math.floor(entry.minQuantity or 1)),
    maxQuantity = math.max(math.floor(entry.minQuantity or 1), math.floor(entry.maxQuantity or 1)),
    guaranteed = entry.guaranteed or false,
    subTable = entry.subTable,
    metadata = entry.metadata,
  }

  table.insert(self._entries, cleanEntry)
  self._idMap[cleanEntry.id] = cleanEntry
end

-- Removes an entry by ID. Returns true if removed, false if not found.
function WeightedLootTable.RemoveEntry(self: InternalLootTable, id: string): boolean
  if not self._idMap[id] then
    return false
  end

  self._idMap[id] = nil
  for i, e in ipairs(self._entries) do
    if e.id == id then
      table.remove(self._entries, i)
      break
    end
  end
  return true
end

-- Computes effective weight applying luck multiplier to tier affinity
local function calculateEffectiveWeight(entry: LootEntry, luck: number): number
  if entry.guaranteed then
    return 0 -- Guaranteed items are excluded from weighted pool rolls
  end

  local baseWeight = entry.weight
  if baseWeight <= 0 then
    return 0
  end

  local tier = entry.tier or "Common"
  local tierFactor = TIER_LUCK_WEIGHTS[tier] or 0.0

  if tierFactor == 0.0 or luck == 1.0 then
    return baseWeight
  end

  -- Luck scaling formula: weight * (1 + (luck - 1) * tierFactor)
  local multiplier = 1 + (luck - 1) * tierFactor
  return math.max(0.0001, baseWeight * multiplier)
end

-- Returns sum of all active pool weights
function WeightedLootTable.GetTotalWeight(self: InternalLootTable, luck: number?): number
  local luckCoeff = luck or 1.0
  local sum = 0
  for _, entry in ipairs(self._entries) do
    sum += calculateEffectiveWeight(entry, luckCoeff)
  end
  return sum
end

-- Returns shallow copy of all registered entries
function WeightedLootTable.GetEntries(self: InternalLootTable): { LootEntry }
  local list: { LootEntry } = {}
  for _, e in ipairs(self._entries) do
    table.insert(list, e)
  end
  return list
end

-- Evaluates drops across requested rolls and configurations
function WeightedLootTable.Roll(self: InternalLootTable, options: RollOptions?): LootTableResult
  local opts = options or {}
  local rollCount = math.max(1, math.floor(opts.rolls or 1))
  local luck = math.max(0.0, opts.luck or 1.0)
  local withReplacement = if opts.withReplacement ~= nil then opts.withReplacement else true
  local prng = createPrng(opts.seed or os.time())

  local drops: { LootDrop } = {}
  local updatedPity: { [LootTier]: number } = {}

  -- Initialize pity counters
  if opts.pityRules then
    for tier, rule in pairs(opts.pityRules) do
      updatedPity[tier] = rule.currentCounter
    end
  end

  -- 1. Award Guaranteed Drops first
  for _, entry in ipairs(self._entries) do
    if entry.guaranteed then
      local minQ = entry.minQuantity or 1
      local maxQ = entry.maxQuantity or 1
      local qty = minQ
      if maxQ > minQ then
        qty = minQ + math.floor(prng() * (maxQ - minQ + 1))
      end

      table.insert(drops, {
        id = entry.id,
        tier = entry.tier or "Common",
        quantity = qty,
        isGuaranteed = true,
        pityTriggered = false,
        metadata = entry.metadata,
      })
    end
  end

  -- 2. Build candidate pool for weighted rolls
  local candidatePool: { LootEntry } = {}
  for _, entry in ipairs(self._entries) do
    if not entry.guaranteed and entry.weight > 0 then
      table.insert(candidatePool, entry)
    end
  end

  if #candidatePool == 0 then
    return {
      drops = drops,
      updatedPity = updatedPity,
    }
  end

  -- Helper to pick an entry by weight
  local function pickWeighted(pool: { LootEntry }): (LootEntry?, number)
    local totalWeight = 0
    for _, e in ipairs(pool) do
      totalWeight += calculateEffectiveWeight(e, luck)
    end

    if totalWeight <= 0 then
      return nil, 0
    end

    local target = prng() * totalWeight
    local accum = 0

    for idx, e in ipairs(pool) do
      accum += calculateEffectiveWeight(e, luck)
      if target <= accum then
        return e, idx
      end
    end

    return pool[#pool], #pool
  end

  -- 3. Execute weighted rolls
  for _ = 1, rollCount do
    if #candidatePool == 0 then
      break
    end

    -- Check if any pity rule threshold is reached
    local pityAwardedTier: LootTier? = nil
    if opts.pityRules then
      for tier, rule in pairs(opts.pityRules) do
        local count = updatedPity[tier] or 0
        if count >= rule.maxThreshold then
          pityAwardedTier = tier
          break
        end
      end
    end

    local chosenEntry: LootEntry? = nil
    local chosenIndex: number = 0
    local isPity = false

    if pityAwardedTier then
      -- Find candidate matching pity tier
      local tierCandidates: { { entry: LootEntry, index: number } } = {}
      for idx, e in ipairs(candidatePool) do
        if e.tier == pityAwardedTier then
          table.insert(tierCandidates, { entry = e, index = idx })
        end
      end

      if #tierCandidates > 0 then
        local pickIdx = 1 + math.floor(prng() * #tierCandidates)
        chosenEntry = tierCandidates[pickIdx].entry
        chosenIndex = tierCandidates[pickIdx].index
        isPity = true
        updatedPity[pityAwardedTier] = 0
      end
    end

    -- Regular weighted selection if pity did not trigger or had no candidate
    if not chosenEntry then
      chosenEntry, chosenIndex = pickWeighted(candidatePool)
    end

    if chosenEntry then
      local tier = chosenEntry.tier or "Common"

      -- If regular roll hit the tier, reset its pity counter; otherwise increment
      if opts.pityRules then
        for pTier, _ in pairs(opts.pityRules) do
          if pTier == tier then
            updatedPity[pTier] = 0
          elseif not isPity then
            updatedPity[pTier] = (updatedPity[pTier] or 0) + 1
          end
        end
      end

      local minQ = chosenEntry.minQuantity or 1
      local maxQ = chosenEntry.maxQuantity or 1
      local qty = minQ
      if maxQ > minQ then
        qty = minQ + math.floor(prng() * (maxQ - minQ + 1))
      end

      -- If this entry defines a recursive subTable, roll child table
      if chosenEntry.subTable and type(chosenEntry.subTable.Roll) == "function" then
        local subResult = chosenEntry.subTable:Roll({
          rolls = qty,
          seed = math.floor(prng() * 1000000),
          luck = luck,
        })
        for _, subDrop in ipairs(subResult.drops) do
          table.insert(drops, subDrop)
        end
      else
        table.insert(drops, {
          id = chosenEntry.id,
          tier = tier,
          quantity = qty,
          isGuaranteed = false,
          pityTriggered = isPity,
          metadata = chosenEntry.metadata,
        })
      end

      -- Without replacement semantics
      if not withReplacement then
        table.remove(candidatePool, chosenIndex)
      end
    end
  end

  return {
    drops = drops,
    updatedPity = updatedPity,
  }
end

return WeightedLootTable
