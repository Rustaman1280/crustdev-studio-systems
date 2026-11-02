local WeightedLootTable = require("../src/ReplicatedStorage/Economy/WeightedLootTable")

-- Test 1: Deterministic PRNG Rolls
local table1 = WeightedLootTable.new({
  { id = "iron_sword", weight = 60, tier = "Common" },
  { id = "silver_sword", weight = 30, tier = "Uncommon" },
  { id = "gold_sword", weight = 10, tier = "Rare" },
})

local resA = table1:Roll({ rolls = 5, seed = 424242 })
local resB = table1:Roll({ rolls = 5, seed = 424242 })

assert(#resA.drops == 5, "Should return 5 drops")
assert(#resB.drops == 5, "Should return 5 drops")
for i = 1, 5 do
  assert(resA.drops[i].id == resB.drops[i].id, "Deterministic rolls must produce identical IDs")
  assert(resA.drops[i].quantity == resB.drops[i].quantity, "Quantities must match identically")
end

-- Test 2: Guaranteed Drops
local tableGuaranteed = WeightedLootTable.new({
  { id = "gold_coins", weight = 0, guaranteed = true, minQuantity = 50, maxQuantity = 50 },
  { id = "potion", weight = 100, tier = "Common" },
})

local resG = tableGuaranteed:Roll({ rolls = 1, seed = 123 })
assert(#resG.drops == 2, "Should return 2 drops (1 guaranteed + 1 rolled)")
assert(resG.drops[1].id == "gold_coins", "First drop should be guaranteed gold")
assert(resG.drops[1].isGuaranteed == true, "Drop must be flagged as guaranteed")
assert(resG.drops[1].quantity == 50, "Gold quantity must be 50")
assert(resG.drops[2].id == "potion", "Second drop must be potion")
assert(resG.drops[2].isGuaranteed == false, "Potion must not be guaranteed")

-- Test 3: Luck Multiplier Effect
local tableLuck = WeightedLootTable.new({
  { id = "common_rock", weight = 100, tier = "Common" },
  { id = "mythic_crystal", weight = 5, tier = "Mythic" },
})

-- Base total weight: 100 + 5 = 105
assert(tableLuck:GetTotalWeight(1.0) == 105, "Base total weight must be 105")
-- With 3.0 luck: mythic weight = 5 * (1 + (3 - 1) * 2.0) = 5 * (1 + 4) = 25 -> Total = 125
local luckWeight = tableLuck:GetTotalWeight(3.0)
assert(luckWeight == 125, "Luck 3.0 weight must be 125")

-- Test 4: Pity Mechanics
local pityTable = WeightedLootTable.new({
  { id = "wood_scrap", weight = 99, tier = "Common" },
  { id = "phoenix_feather", weight = 1, tier = "Legendary" },
})

-- Without pity rule, legendary is unlikely in 1 roll
local resPityPre = pityTable:Roll({
  rolls = 1,
  seed = 9999,
  pityRules = {
    Legendary = { tier = "Legendary", maxThreshold = 10, currentCounter = 5 },
  },
})
assert(resPityPre.updatedPity.Legendary == 6, "Pity counter should increment from 5 to 6 on non-legendary roll")

-- When threshold is reached (10), pity MUST trigger
local resPityTrigger = pityTable:Roll({
  rolls = 1,
  seed = 9999,
  pityRules = {
    Legendary = { tier = "Legendary", maxThreshold = 10, currentCounter = 10 },
  },
})
assert(#resPityTrigger.drops == 1, "Should drop 1 item")
assert(resPityTrigger.drops[1].id == "phoenix_feather", "Pity threshold must guarantee legendary item")
assert(resPityTrigger.drops[1].pityTriggered == true, "Drop must flag pityTriggered = true")
assert(resPityTrigger.updatedPity.Legendary == 0, "Pity counter must reset to 0 after trigger")

-- Test 5: Without Replacement Rolls
local tableNoReplace = WeightedLootTable.new({
  { id = "item_1", weight = 10, tier = "Common" },
  { id = "item_2", weight = 10, tier = "Common" },
  { id = "item_3", weight = 10, tier = "Common" },
})

local resNoReplace = tableNoReplace:Roll({
  rolls = 3,
  seed = 777,
  withReplacement = false,
})
assert(#resNoReplace.drops == 3, "Should return 3 drops")
local seen = {}
for _, d in ipairs(resNoReplace.drops) do
  assert(seen[d.id] == nil, "Each item must be unique when rolling without replacement")
  seen[d.id] = true
end

-- Test 6: Nested Sub-Tables
local weaponSubTable = WeightedLootTable.new({
  { id = "dagger", weight = 50, tier = "Common" },
  { id = "broadsword", weight = 50, tier = "Common" },
})

local chestTable = WeightedLootTable.new({
  { id = "weapon_chest", weight = 100, subTable = weaponSubTable },
})

local resNested = chestTable:Roll({ rolls = 1, seed = 555 })
assert(#resNested.drops == 1, "Nested table should produce drop from child table")
assert(resNested.drops[1].id == "dagger" or resNested.drops[1].id == "broadsword", "Nested drop must be from child pool")

-- Test 7: Add and Remove Entry
local dynTable = WeightedLootTable.new()
dynTable:AddEntry({ id = "gem", weight = 50, tier = "Rare" })
assert(dynTable:GetTotalWeight() == 50, "Weight should be 50 after add")
local removed = dynTable:RemoveEntry("gem")
assert(removed == true, "RemoveEntry should succeed")
assert(dynTable:GetTotalWeight() == 0, "Weight should be 0 after remove")
assert(dynTable:RemoveEntry("non_existent") == false, "Removing non-existent entry returns false")

print("PASS: WeightedLootTable tests (Determinism, Guaranteed, Luck, Pity, Without-Replacement, Nested, Dynamic) passed cleanly!")
