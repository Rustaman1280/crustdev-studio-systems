--!strict
--[[
  InterestManager.luau
  Production-grade spatial Area of Interest (AOI) replication management engine.
  Computes tiered observer horizons (Immediate, Near, Far, Culled) with dynamic
  replication frequencies, delta-tracking (Entered, Updated, TierChanged, Exited),
  and per-tick bandwidth budgeting for high-performance multiplayer Roblox servers.
  Part of crustdev studio game systems (Aetheria: Fractured Realms).
]]

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

export type InterestTier = "Immediate" | "Near" | "Far" | "Culled"

export type TierConfig = {
  ImmediateRadius: number,
  NearRadius: number,
  FarRadius: number,
  ImmediateInterval: number,
  NearInterval: number,
  FarInterval: number,
}

export type EntityEntry = {
  Id: string,
  Position: typeof(Vector3.new(0, 0, 0)),
  Priority: number,
  RadiusOverride: number?,
  Tags: { [string]: boolean }?,
}

export type ObserverEntry = {
  Id: string,
  Position: typeof(Vector3.new(0, 0, 0)),
  MaxEntitiesPerTick: number,
  KnownTiers: { [string]: InterestTier },
  EntityLastTicked: { [string]: number },
}

export type ReplicationDelta = {
  Entered: { string },
  Updated: { string },
  TierChanged: { { EntityId: string, OldTier: InterestTier, NewTier: InterestTier } },
  Exited: { string },
}

local DEFAULT_CONFIG: TierConfig = {
  ImmediateRadius = 80,
  NearRadius = 250,
  FarRadius = 600,
  ImmediateInterval = 1,  -- Replicate every tick
  NearInterval = 3,       -- Replicate every 3 ticks
  FarInterval = 10,       -- Replicate every 10 ticks
}

local InterestManager = {}
InterestManager.__index = InterestManager

export type InterestManagerInstance = typeof(setmetatable({} :: {
  Config: TierConfig,
  CurrentTick: number,
  Entities: { [string]: EntityEntry },
  Observers: { [string]: ObserverEntry },
}, InterestManager))

function InterestManager.new(customConfig: TierConfig?): InterestManagerInstance
  local config = customConfig or DEFAULT_CONFIG
  local self = {
    Config = config,
    CurrentTick = 0,
    Entities = {},
    Observers = {},
  }
  return setmetatable(self, InterestManager)
end

function InterestManager:RegisterEntity(id: string, position: typeof(Vector3.new(0, 0, 0)), priority: number?, radiusOverride: number?): ()
  self.Entities[id] = {
    Id = id,
    Position = position,
    Priority = priority or 1,
    RadiusOverride = radiusOverride,
    Tags = {},
  }
end

function InterestManager:UpdateEntityPosition(id: string, position: typeof(Vector3.new(0, 0, 0))): ()
  local entity = self.Entities[id]
  if entity then
    entity.Position = position
  end
end

function InterestManager:UnregisterEntity(id: string): ()
  self.Entities[id] = nil
end

function InterestManager:RegisterObserver(id: string, position: typeof(Vector3.new(0, 0, 0)), maxEntitiesPerTick: number?): ()
  self.Observers[id] = {
    Id = id,
    Position = position,
    MaxEntitiesPerTick = maxEntitiesPerTick or 64,
    KnownTiers = {},
    EntityLastTicked = {},
  }
end

function InterestManager:UpdateObserverPosition(id: string, position: typeof(Vector3.new(0, 0, 0))): ()
  local obs = self.Observers[id]
  if obs then
    obs.Position = position
  end
end

function InterestManager:UnregisterObserver(id: string): ()
  self.Observers[id] = nil
end

function InterestManager:GetTierForDistance(distance: number, radiusMultiplier: number?): InterestTier
  local mult = radiusMultiplier or 1.0
  local imm = self.Config.ImmediateRadius * mult
  local near = self.Config.NearRadius * mult
  local far = self.Config.FarRadius * mult

  if distance <= imm then
    return "Immediate"
  elseif distance <= near then
    return "Near"
  elseif distance <= far then
    return "Far"
  else
    return "Culled"
  end
end

local function getIntervalForTier(config: TierConfig, tier: InterestTier): number
  if tier == "Immediate" then
    return config.ImmediateInterval
  elseif tier == "Near" then
    return config.NearInterval
  elseif tier == "Far" then
    return config.FarInterval
  else
    return 999999
  end
end

local function getTierWeight(tier: InterestTier): number
  if tier == "Immediate" then
    return 1000
  elseif tier == "Near" then
    return 100
  elseif tier == "Far" then
    return 10
  else
    return 0
  end
end

--[[
  Step: advances the simulation tick and calculates replication deltas for all registered observers.
  Enforces per-observer bandwidth budgets and priority sorting.
]]
function InterestManager:Step(): { [string]: ReplicationDelta }
  self.CurrentTick += 1
  local currentTick = self.CurrentTick
  local results: { [string]: ReplicationDelta } = {}

  for obsId, observer in pairs(self.Observers) do
    local entered: { string } = {}
    local updatedCandidates: { { EntityId: string, Score: number } } = {}
    local tierChanged: { { EntityId: string, OldTier: InterestTier, NewTier: InterestTier } } = {}
    local exited: { string } = {}

    local currentVisibleEntities: { [string]: boolean } = {}

    -- Evaluate all entities relative to observer position
    for entityId, entity in pairs(self.Entities) do
      local dist = (entity.Position - observer.Position).Magnitude
      local mult = if entity.RadiusOverride then (entity.RadiusOverride / self.Config.FarRadius) else 1.0
      local currentTier = self:GetTierForDistance(dist, mult)
      local previousTier = observer.KnownTiers[entityId]

      if currentTier ~= "Culled" then
        currentVisibleEntities[entityId] = true

        if previousTier == nil or previousTier == "Culled" then
          table.insert(entered, entityId)
          observer.KnownTiers[entityId] = currentTier
          observer.EntityLastTicked[entityId] = currentTick

          local score = getTierWeight(currentTier) + entity.Priority
          table.insert(updatedCandidates, { EntityId = entityId, Score = score })
        else
          if previousTier ~= currentTier then
            table.insert(tierChanged, { EntityId = entityId, OldTier = previousTier, NewTier = currentTier })
            observer.KnownTiers[entityId] = currentTier
          end

          local interval = getIntervalForTier(self.Config, currentTier)
          local lastTick = observer.EntityLastTicked[entityId] or 0
          if (currentTick - lastTick) >= interval then
            local score = getTierWeight(currentTier) + entity.Priority
            table.insert(updatedCandidates, { EntityId = entityId, Score = score })
          end
        end
      else
        -- Entity is currently Culled
        if previousTier ~= nil and previousTier ~= "Culled" then
          table.insert(exited, entityId)
          observer.KnownTiers[entityId] = nil
          observer.EntityLastTicked[entityId] = nil
        end
      end
    end

    -- Check for entities that previously existed but were unregistered
    for knownId, _ in pairs(observer.KnownTiers) do
      if not self.Entities[knownId] and not currentVisibleEntities[knownId] then
        table.insert(exited, knownId)
        observer.KnownTiers[knownId] = nil
        observer.EntityLastTicked[knownId] = nil
      end
    end

    -- Budget & sort updated candidates
    table.sort(updatedCandidates, function(a, b)
      return a.Score > b.Score
    end)

    local updated: { string } = {}
    local budget = observer.MaxEntitiesPerTick
    local count = 0

    for _, candidate in ipairs(updatedCandidates) do
      if count >= budget then
        break
      end
      table.insert(updated, candidate.EntityId)
      observer.EntityLastTicked[candidate.EntityId] = currentTick
      count += 1
    end

    results[obsId] = {
      Entered = entered,
      Updated = updated,
      TierChanged = tierChanged,
      Exited = exited,
    }
  end

  return results
end

return InterestManager
