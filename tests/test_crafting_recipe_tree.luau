local CraftingRecipeTree = require("../src/ReplicatedStorage/Economy/CraftingRecipeTree")

local function assertEqual(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "Assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assertTrue(condition, msg)
  if not condition then
    error(msg or "Condition expected to be true")
  end
end

-- Test 1: Recipe Registration and Lookup
do
  local tree = CraftingRecipeTree.new()
  local recipe = {
    Id = "iron_ingot",
    Name = "Iron Ingot",
    Category = "Smelting",
    Ingredients = {
      { ItemId = "iron_ore", Quantity = 2 },
      { ItemId = "coal", Quantity = 1 },
    },
    Outputs = {
      { ItemId = "iron_ingot", BaseQuantity = 1, QualityModel = "Fixed", FixedQuality = "Common" },
    },
    RequiredStation = "Furnace",
    MinStationTier = 1,
    UnlockedByDefault = true,
  }

  local registered = tree:RegisterRecipe(recipe)
  assertTrue(registered, "Recipe should register successfully")

  local fetched = tree:GetRecipe("iron_ingot")
  assertTrue(fetched ~= nil, "Fetched recipe should not be nil")
  assertEqual(fetched.Name, "Iron Ingot", "Recipe name matches")
end

-- Test 2: Cycle Detection in Recipe DAG
do
  local treeValid = CraftingRecipeTree.new()
  treeValid:RegisterRecipe({
    Id = "r1",
    Name = "R1",
    Category = "Craft",
    Ingredients = { { ItemId = "raw_wood", Quantity = 1 } },
    Outputs = { { ItemId = "plank", BaseQuantity = 4 } },
  })
  treeValid:RegisterRecipe({
    Id = "r2",
    Name = "R2",
    Category = "Craft",
    Ingredients = { { ItemId = "plank", Quantity = 2 } },
    Outputs = { { ItemId = "stick", BaseQuantity = 4 } },
  })

  local cycleCheckValid = treeValid:DetectCycles()
  assertTrue(not cycleCheckValid.HasCycle, "Valid acyclic tree should not report cycles")

  -- Now test cycle detection
  local treeCycle = CraftingRecipeTree.new()
  treeCycle:RegisterRecipe({
    Id = "cycle_a",
    Name = "Cycle A",
    Category = "Craft",
    Ingredients = { { ItemId = "item_b", Quantity = 1 } },
    Outputs = { { ItemId = "item_a", BaseQuantity = 1 } },
  })
  treeCycle:RegisterRecipe({
    Id = "cycle_b",
    Name = "Cycle B",
    Category = "Craft",
    Ingredients = { { ItemId = "item_a", Quantity = 1 } },
    Outputs = { { ItemId = "item_b", BaseQuantity = 1 } },
  })

  local cycleCheckInvalid = treeCycle:DetectCycles()
  assertTrue(cycleCheckInvalid.HasCycle, "Cyclic recipe dependencies must be detected")
end

-- Test 3: Craft Validation Gating (Locked, Station, Skill, Missing Ingredients)
do
  local tree = CraftingRecipeTree.new()
  tree:RegisterRecipe({
    Id = "master_sword",
    Name = "Master Sword",
    Category = "Weapons",
    Ingredients = {
      { ItemId = "mithril_ingot", Quantity = 5, MinQuality = "Rare" },
      { ItemId = "dragon_core", Quantity = 1 },
    },
    Outputs = {
      { ItemId = "master_sword", BaseQuantity = 1, QualityModel = "WeightedSkill" },
    },
    RequiredStation = "MythicAnvil",
    MinStationTier = 3,
    RequiredSkill = "Blacksmithing",
    MinSkillLevel = 75,
    UnlockedByDefault = false,
  })

  local contextLocked = {
    Inventory = {},
    StationType = "MythicAnvil",
    StationTier = 3,
    SkillLevels = { Blacksmithing = 80 },
    UnlockedRecipes = {},
  }
  local valLocked = tree:ValidateCraft("master_sword", contextLocked)
  assertTrue(not valLocked.CanCraft, "Locked recipe must fail validation")
  assertEqual(valLocked.Reason, "Recipe is locked")

  local contextWrongStation = {
    Inventory = {},
    StationType = "BasicAnvil",
    StationTier = 1,
    SkillLevels = { Blacksmithing = 80 },
    UnlockedRecipes = { master_sword = true },
  }
  local valStation = tree:ValidateCraft("master_sword", contextWrongStation)
  assertTrue(not valStation.CanCraft, "Wrong station type must fail validation")

  local contextLowSkill = {
    Inventory = {},
    StationType = "MythicAnvil",
    StationTier = 3,
    SkillLevels = { Blacksmithing = 50 }, -- Needs 75
    UnlockedRecipes = { master_sword = true },
  }
  local valSkill = tree:ValidateCraft("master_sword", contextLowSkill)
  assertTrue(not valSkill.CanCraft, "Low skill level must fail validation")

  local contextMissingMats = {
    Inventory = {
      slot1 = { SlotId = "slot1", ItemId = "mithril_ingot", Quantity = 2, Quality = "Rare" }, -- Needs 5
    },
    StationType = "MythicAnvil",
    StationTier = 3,
    SkillLevels = { Blacksmithing = 80 },
    UnlockedRecipes = { master_sword = true },
  }
  local valMats = tree:ValidateCraft("master_sword", contextMissingMats)
  assertTrue(not valMats.CanCraft, "Missing ingredients must fail validation")
  assertTrue(valMats.MissingIngredients ~= nil, "Missing ingredients dict returned")
end

-- Test 4: Craft Execution with Reusable Catalyst and Tag Substitution
do
  local tree = CraftingRecipeTree.new()
  tree:RegisterRecipe({
    Id = "leather_armor",
    Name = "Leather Armor",
    Category = "Armor",
    Ingredients = {
      { ItemId = "leather_hide", Quantity = 4 },
      { ItemId = "steel_needle", Quantity = 1, ConsumeOnCraft = false }, -- Reusable catalyst tool
      { Tag = "thread", Quantity = 2 }, -- Generic thread tag
    },
    Outputs = {
      { ItemId = "leather_armor", BaseQuantity = 1, QualityModel = "AverageIngredients" },
    },
    UnlockedByDefault = true,
  })

  local inventory = {
    s1 = { SlotId = "s1", ItemId = "leather_hide", Quantity = 10, Quality = "Uncommon" },
    s2 = { SlotId = "s2", ItemId = "steel_needle", Quantity = 1, Quality = "Rare" },
    s3 = { SlotId = "s3", ItemId = "silk_thread", Quantity = 6, Quality = "Uncommon", Tags = { thread = true } },
  }

  local ctx = {
    Inventory = inventory,
  }

  local val = tree:ValidateCraft("leather_armor", ctx)
  assertTrue(val.CanCraft, "Craft should validate successfully")
  assertEqual(val.MaxCraftableBatches, 2, "Max craftable batches is 2 (limited by 10/4 = 2 batches)")

  local exec = tree:ExecuteCraft("leather_armor", 2, ctx)
  assertTrue(exec.Success, "Craft execution should succeed")
  assertEqual(exec.BatchesCrafted, 2, "2 batches crafted")
  assertEqual(#exec.ProducedItems, 1, "1 produced item type")
  assertEqual(exec.ProducedItems[1].Quantity, 2, "2 leather armors produced")
  assertEqual(exec.ProducedItems[1].Quality, "Uncommon", "Inherits average ingredient quality")

  -- Check inventory deductions
  assertEqual(inventory.s1.Quantity, 2, "Remaining leather hide is 10 - 8 = 2")
  assertEqual(inventory.s2.Quantity, 1, "Reusable steel needle tool was not consumed")
  assertEqual(inventory.s3.Quantity, 2, "Remaining thread is 6 - 4 = 2")
end

-- Test 5: Recursive Raw Material Tree Resolution
do
  local tree = CraftingRecipeTree.new()
  -- Recipe 1: Iron Ingot (needs 2x iron_ore + 1x coal)
  tree:RegisterRecipe({
    Id = "smelt_iron",
    Name = "Smelt Iron Ingot",
    Category = "Smelting",
    Ingredients = {
      { ItemId = "iron_ore", Quantity = 2 },
      { ItemId = "coal", Quantity = 1 },
    },
    Outputs = {
      { ItemId = "iron_ingot", BaseQuantity = 1 },
    },
  })

  -- Recipe 2: Steel Ingot (needs 2x iron_ingot + 1x coal)
  tree:RegisterRecipe({
    Id = "smelt_steel",
    Name = "Smelt Steel Ingot",
    Category = "Smelting",
    Ingredients = {
      { ItemId = "iron_ingot", Quantity = 2 },
      { ItemId = "coal", Quantity = 1 },
    },
    Outputs = {
      { ItemId = "steel_ingot", BaseQuantity = 1 },
    },
  })

  -- Recipe 3: Steel Sword (needs 2x steel_ingot + 1x wooden_hilt)
  tree:RegisterRecipe({
    Id = "forge_steel_sword",
    Name = "Forge Steel Sword",
    Category = "Smithing",
    Ingredients = {
      { ItemId = "steel_ingot", Quantity = 2 },
      { ItemId = "wooden_hilt", Quantity = 1 },
    },
    Outputs = {
      { ItemId = "steel_sword", BaseQuantity = 1 },
    },
  })

  -- To craft 1 Steel Sword:
  -- needs 2 Steel Ingot + 1 wooden_hilt
  -- 2 Steel Ingot needs 4 Iron Ingot + 2 Coal
  -- 4 Iron Ingot needs 8 Iron Ore + 4 Coal
  -- Total Raw Materials:
  -- Iron Ore: 8
  -- Coal: 2 (from steel) + 4 (from iron) = 6
  -- wooden_hilt: 1
  local bill = tree:ResolveRawMaterialTree("steel_sword", 1)
  assertEqual(bill.RawMaterials["iron_ore"], 8, "Needs 8 raw iron ore")
  assertEqual(bill.RawMaterials["coal"], 6, "Needs 6 raw coal")
  assertEqual(bill.RawMaterials["wooden_hilt"], 1, "Needs 1 wooden hilt")
  assertTrue(#bill.IntermediateSteps >= 3, "Contains all 3 intermediate crafting steps")
end

print("CraftingRecipeTree tests passed successfully!")