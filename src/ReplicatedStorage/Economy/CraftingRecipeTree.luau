--!strict
--[[
  CraftingRecipeTree.luau
  crustdev studio systems - ReplicatedStorage/Economy/CraftingRecipeTree

  Directed Acyclic Graph (DAG) recipe progression engine, multi-station requirements,
  dynamic ingredient tag substitution, recursive raw material breakdown, and quality tier inheritance.

  Features:
  - Directed Acyclic Graph (DAG) dependency graph with DFS cycle and recursion loop detection.
  - Flexible ingredient specifications: exact ItemId matches, generic Tag substitutions, and minimum quality gates.
  - Multi-tier crafting station prerequisites and player skill level gates.
  - Atomic batch crafting calculations with exact leftover remainder tracking.
  - Reusable catalyst and mold support (consumed vs retained crafting components).
  - Output quality progression algorithms: Fixed, Average Ingredient Quality, and Skill-Weighted rolls.
  - Recursive raw material tree resolution: decomposes complex multi-stage items into base harvestable reagents.
  - Pure Luau / Lune compatible with zero external dependencies.
  - Zero Em-Dash Policy compliant.
]]

export type QualityTier = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary"

export type IngredientSpec = {
  ItemId: string?,
  Tag: string?,
  Quantity: number,
  MinQuality: QualityTier?,
  ConsumeOnCraft: boolean?, -- Defaults to true; false for catalytic tools or reusable molds
}

export type QualityCalculationModel = "Fixed" | "AverageIngredients" | "WeightedSkill"

export type OutputSpec = {
  ItemId: string,
  BaseQuantity: number,
  QualityModel: QualityCalculationModel?,
  FixedQuality: QualityTier?,
  BonusRollChance: number?, -- Probability [0..1] of producing +1 extra bonus unit
}

export type Recipe = {
  Id: string,
  Name: string,
  Category: string,
  Ingredients: { IngredientSpec },
  Outputs: { OutputSpec },
  RequiredStation: string?,
  MinStationTier: number?,
  RequiredSkill: string?,
  MinSkillLevel: number?,
  CraftTimeSeconds: number?,
  UnlockedByDefault: boolean?,
}

export type InventoryItem = {
  SlotId: string,
  ItemId: string,
  Quantity: number,
  Quality: QualityTier?,
  Tags: { [string]: boolean }?,
}

export type PlayerCraftContext = {
  Inventory: { [string]: InventoryItem },
  StationType: string?,
  StationTier: number?,
  SkillLevels: { [string]: number }?,
  UnlockedRecipes: { [string]: boolean }?,
}

export type CraftValidationResult = {
  CanCraft: boolean,
  Reason: string?,
  MaxCraftableBatches: number,
  MissingIngredients: { [string]: number }?,
}

export type ProducedItem = {
  ItemId: string,
  Quantity: number,
  Quality: QualityTier,
}

export type ConsumedItem = {
  SlotId: string,
  ItemId: string,
  Quantity: number,
}

export type CraftExecutionResult = {
  Success: boolean,
  BatchesCrafted: number,
  ProducedItems: { ProducedItem },
  ConsumedItems: { ConsumedItem },
  Error: string?,
}

export type MaterialBill = {
  RawMaterials: { [string]: number },
  IntermediateSteps: { { RecipeId: string, Batches: number } },
}

local QualityValues: { [QualityTier]: number } = {
  Common = 1,
  Uncommon = 2,
  Rare = 3,
  Epic = 4,
  Legendary = 5,
}

local QualityFromValue: { [number]: QualityTier } = {
  [1] = "Common",
  [2] = "Uncommon",
  [3] = "Rare",
  [4] = "Epic",
  [5] = "Legendary",
}

local CraftingRecipeTree = {}
CraftingRecipeTree.__index = CraftingRecipeTree

export type CraftingRecipeTreeInstance = {
  Recipes: { [string]: Recipe },
  OutputToRecipes: { [string]: { string } }, -- ItemId -> list of RecipeIds that produce it
  RegisterRecipe: (self: CraftingRecipeTreeInstance, recipe: Recipe) -> boolean,
  GetRecipe: (self: CraftingRecipeTreeInstance, recipeId: string) -> Recipe?,
  DetectCycles: (self: CraftingRecipeTreeInstance) -> { HasCycle: boolean, CyclePath: { string }? },
  ValidateCraft: (
    self: CraftingRecipeTreeInstance,
    recipeId: string,
    context: PlayerCraftContext
  ) -> CraftValidationResult,
  ExecuteCraft: (
    self: CraftingRecipeTreeInstance,
    recipeId: string,
    batches: number,
    context: PlayerCraftContext
  ) -> CraftExecutionResult,
  ResolveRawMaterialTree: (
    self: CraftingRecipeTreeInstance,
    targetItemId: string,
    desiredQuantity: number
  ) -> MaterialBill,
}

function CraftingRecipeTree.new(): CraftingRecipeTreeInstance
  local self = setmetatable({
    Recipes = {},
    OutputToRecipes = {},
  }, CraftingRecipeTree)
  return (self :: any) :: CraftingRecipeTreeInstance
end

function CraftingRecipeTree:RegisterRecipe(recipe: Recipe): boolean
  if self.Recipes[recipe.Id] then
    return false -- Duplicate ID
  end

  self.Recipes[recipe.Id] = recipe

  for _, output in ipairs(recipe.Outputs) do
    local list = self.OutputToRecipes[output.ItemId]
    if not list then
      list = {}
      self.OutputToRecipes[output.ItemId] = list
    end
    table.insert(list, recipe.Id)
  end

  return true
end

function CraftingRecipeTree:GetRecipe(recipeId: string): Recipe?
  return self.Recipes[recipeId]
end

-- DFS cycle detection on recipe dependencies
function CraftingRecipeTree:DetectCycles(): { HasCycle: boolean, CyclePath: { string }? }
  local visited: { [string]: boolean } = {}
  local recursionStack: { [string]: boolean } = {}
  local currentPath: { string } = {}

  local function dfs(recipeId: string): boolean
    visited[recipeId] = true
    recursionStack[recipeId] = true
    table.insert(currentPath, recipeId)

    local recipe = self.Recipes[recipeId]
    if recipe then
      for _, ingredient in ipairs(recipe.Ingredients) do
        local requiredItemId = ingredient.ItemId
        if requiredItemId and self.OutputToRecipes[requiredItemId] then
          for _, parentRecipeId in ipairs(self.OutputToRecipes[requiredItemId]) do
            if not visited[parentRecipeId] then
              if dfs(parentRecipeId) then
                return true
              end
            elseif recursionStack[parentRecipeId] then
              table.insert(currentPath, parentRecipeId)
              return true
            end
          end
        end
      end
    end

    recursionStack[recipeId] = false
    table.remove(currentPath)
    return false
  end

  for recipeId, _ in pairs(self.Recipes) do
    if not visited[recipeId] then
      if dfs(recipeId) then
        return { HasCycle = true, CyclePath = currentPath }
      end
    end
  end

  return { HasCycle = false, CyclePath = nil }
end

local function itemMatchesIngredient(item: InventoryItem, spec: IngredientSpec): boolean
  if spec.ItemId and item.ItemId ~= spec.ItemId then
    return false
  end

  if spec.Tag and (not item.Tags or not item.Tags[spec.Tag]) then
    return false
  end

  if spec.MinQuality then
    local itemVal = QualityValues[item.Quality or "Common"] or 1
    local minVal = QualityValues[spec.MinQuality] or 1
    if itemVal < minVal then
      return false
    end
  end

  return true
end

function CraftingRecipeTree:ValidateCraft(
  recipeId: string,
  context: PlayerCraftContext
): CraftValidationResult
  local recipe = self.Recipes[recipeId]
  if not recipe then
    return {
      CanCraft = false,
      Reason = "Recipe not found",
      MaxCraftableBatches = 0,
    }
  end

  -- Unlock gate check
  if recipe.UnlockedByDefault == false then
    local isUnlocked = context.UnlockedRecipes and context.UnlockedRecipes[recipeId]
    if not isUnlocked then
      return {
        CanCraft = false,
        Reason = "Recipe is locked",
        MaxCraftableBatches = 0,
      }
    end
  end

  -- Station requirement check
  if recipe.RequiredStation then
    if context.StationType ~= recipe.RequiredStation then
      return {
        CanCraft = false,
        Reason = string.format("Requires station: %s", recipe.RequiredStation),
        MaxCraftableBatches = 0,
      }
    end
    local playerStationTier = context.StationTier or 1
    local minTier = recipe.MinStationTier or 1
    if playerStationTier < minTier then
      return {
        CanCraft = false,
        Reason = string.format("Station tier too low: have %d, need %d", playerStationTier, minTier),
        MaxCraftableBatches = 0,
      }
    end
  end

  -- Skill level check
  if recipe.RequiredSkill and recipe.MinSkillLevel then
    local playerSkill = (context.SkillLevels and context.SkillLevels[recipe.RequiredSkill]) or 0
    if playerSkill < recipe.MinSkillLevel then
      return {
        CanCraft = false,
        Reason = string.format("Skill %s too low: have %d, need %d", recipe.RequiredSkill, playerSkill, recipe.MinSkillLevel),
        MaxCraftableBatches = 0,
      }
    end
  end

  -- Ingredient availability check
  local missing: { [string]: number } = {}
  local maxBatches = math.huge

  for _, spec in ipairs(recipe.Ingredients) do
    local availableCount = 0
    local label = spec.ItemId or (spec.Tag and ("#" .. spec.Tag)) or "UnknownReagent"

    for _, item in pairs(context.Inventory) do
      if itemMatchesIngredient(item, spec) then
        availableCount += item.Quantity
      end
    end

    if availableCount < spec.Quantity then
      missing[label] = spec.Quantity - availableCount
    end

    if spec.ConsumeOnCraft == false then
      if availableCount < spec.Quantity then
        maxBatches = 0
      end
    else
      local batchesForThis = math.floor(availableCount / spec.Quantity)
      if batchesForThis < maxBatches then
        maxBatches = batchesForThis
      end
    end
  end

  if next(missing) ~= nil then
    return {
      CanCraft = false,
      Reason = "Missing required ingredients",
      MaxCraftableBatches = 0,
      MissingIngredients = missing,
    }
  end

  return {
    CanCraft = true,
    Reason = nil,
    MaxCraftableBatches = if maxBatches == math.huge then 0 else maxBatches,
    MissingIngredients = nil,
  }
end

function CraftingRecipeTree:ExecuteCraft(
  recipeId: string,
  batches: number,
  context: PlayerCraftContext
): CraftExecutionResult
  if batches <= 0 then
    return {
      Success = false,
      BatchesCrafted = 0,
      ProducedItems = {},
      ConsumedItems = {},
      Error = "Batches must be positive",
    }
  end

  local val = self:ValidateCraft(recipeId, context)
  if not val.CanCraft then
    return {
      Success = false,
      BatchesCrafted = 0,
      ProducedItems = {},
      ConsumedItems = {},
      Error = val.Reason or "Validation failed",
    }
  end

  if batches > val.MaxCraftableBatches then
    return {
      Success = false,
      BatchesCrafted = 0,
      ProducedItems = {},
      ConsumedItems = {},
      Error = string.format("Insufficient resources: requested %d batches, max is %d", batches, val.MaxCraftableBatches),
    }
  end

  local recipe = self.Recipes[recipeId]
  local consumedItems: { ConsumedItem } = {}
  local ingredientQualitySum = 0
  local totalIngredientCount = 0

  -- Deduct ingredients from inventory slots
  for _, spec in ipairs(recipe.Ingredients) do
    local needed = spec.Quantity * batches
    local shouldConsume = if spec.ConsumeOnCraft ~= nil then spec.ConsumeOnCraft else true

    for slotId, item in pairs(context.Inventory) do
      if needed <= 0 then
        break
      end

      if itemMatchesIngredient(item, spec) then
        local take = math.min(item.Quantity, needed)
        local qVal = QualityValues[item.Quality or "Common"] or 1
        ingredientQualitySum += (qVal * take)
        totalIngredientCount += take

        if shouldConsume then
          item.Quantity -= take
          table.insert(consumedItems, {
            SlotId = slotId,
            ItemId = item.ItemId,
            Quantity = take,
          })

          if item.Quantity <= 0 then
            context.Inventory[slotId] = nil
          end
        end

        needed -= take
      end
    end
  end

  -- Determine output quality
  local avgQualityVal = if totalIngredientCount > 0 then math.round(ingredientQualitySum / totalIngredientCount) else 1
  avgQualityVal = math.clamp(avgQualityVal, 1, 5)

  local producedItems: { ProducedItem } = {}

  for _, outSpec in ipairs(recipe.Outputs) do
    local totalProduced = outSpec.BaseQuantity * batches

    -- Extra bonus roll
    if outSpec.BonusRollChance and outSpec.BonusRollChance > 0 then
      for _ = 1, batches do
        if math.random() <= outSpec.BonusRollChance then
          totalProduced += 1
        end
      end
    end

    local finalQuality: QualityTier = "Common"
    local model = outSpec.QualityModel or "Fixed"

    if model == "Fixed" then
      finalQuality = outSpec.FixedQuality or "Common"
    elseif model == "AverageIngredients" then
      finalQuality = QualityFromValue[avgQualityVal] or "Common"
    elseif model == "WeightedSkill" then
      local skillBonus = 0
      if recipe.RequiredSkill and context.SkillLevels then
        local skillLvl = context.SkillLevels[recipe.RequiredSkill] or 0
        skillBonus = math.floor(skillLvl / 25) -- +1 tier for every 25 skill points
      end
      local rolledVal = math.clamp(avgQualityVal + skillBonus, 1, 5)
      finalQuality = QualityFromValue[rolledVal] or "Common"
    end

    table.insert(producedItems, {
      ItemId = outSpec.ItemId,
      Quantity = totalProduced,
      Quality = finalQuality,
    })
  end

  return {
    Success = true,
    BatchesCrafted = batches,
    ProducedItems = producedItems,
    ConsumedItems = consumedItems,
    Error = nil,
  }
end

-- Resolves total raw materials required for an item tree
function CraftingRecipeTree:ResolveRawMaterialTree(
  targetItemId: string,
  desiredQuantity: number
): MaterialBill
  local rawMaterials: { [string]: number } = {}
  local intermediateSteps: { { RecipeId: string, Batches: number } } = {}

  local function resolveRecursive(itemId: string, quantityNeeded: number)
    local candidateRecipes = self.OutputToRecipes[itemId]

    if not candidateRecipes or #candidateRecipes == 0 then
      -- Raw base reagent (no recipe creates this item)
      rawMaterials[itemId] = (rawMaterials[itemId] or 0) + quantityNeeded
      return
    end

    -- Use first available recipe to produce this item
    local recipeId = candidateRecipes[1]
    local recipe = self.Recipes[recipeId]

    local outputAmountPerBatch = 1
    for _, outSpec in ipairs(recipe.Outputs) do
      if outSpec.ItemId == itemId then
        outputAmountPerBatch = outSpec.BaseQuantity
        break
      end
    end

    local batchesNeeded = math.ceil(quantityNeeded / outputAmountPerBatch)
    table.insert(intermediateSteps, { RecipeId = recipeId, Batches = batchesNeeded })

    for _, ing in ipairs(recipe.Ingredients) do
      local subItem = ing.ItemId or (ing.Tag and ("tag:" .. ing.Tag)) or "unknown"
      local totalReagentNeeded = ing.Quantity * batchesNeeded
      resolveRecursive(subItem, totalReagentNeeded)
    end
  end

  resolveRecursive(targetItemId, desiredQuantity)

  return {
    RawMaterials = rawMaterials,
    IntermediateSteps = intermediateSteps,
  }
end

return CraftingRecipeTree