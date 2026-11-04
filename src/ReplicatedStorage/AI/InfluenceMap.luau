--!strict
--[[
  InfluenceMap.luau
  crustdev studio systems - ReplicatedStorage/AI/InfluenceMap

  High-performance tactical influence mapping and spatial reasoning for AI agents:
  - Discretized 2D grid partitioned on the XZ world plane with continuous coordinate mapping.
  - Multi-layer influence channels (e.g. Threat, Friendly, Cover, Tension, Custom).
  - Continuous point and line influence emitters with Linear, Quadratic, and Gaussian falloffs.
  - Time-stepped dynamics: configurable linear/exponential decay and momentum diffusion.
  - Bilinear interpolation for smooth continuous sub-cell influence sampling.
  - Spatial gradient calculation (df/dx, df/dz) for threat repulsion and objective attraction.
  - Tactical query solvers: optimal position evaluation, tension frontlines, peak hotspots.
  - Zero external dependencies. Compatible with Roblox engine and Lune runtime.
  - Zero Em-Dash Policy compliant.
]]

local Vector3 = _G.Vector3 or Vector3

export type FalloffType = "Linear" | "Quadratic" | "Gaussian" | "Constant"
export type DecayType = "Linear" | "Exponential"

export type LayerConfig = {
  decayRate: number, -- Rate of decay per second (multiplier for Exponential, flat deduction for Linear)
  diffusionRate: number, -- Diffusion coefficient to adjacent cells [0..1]
  minValue: number, -- Minimum clamped cell value (default: 0)
  maxValue: number, -- Maximum clamped cell value (default: 100)
  decayType: DecayType?, -- Decay formula (default: "Exponential")
}

export type GridConfig = {
  origin: Vector3, -- World coordinates of the bottom-left corner (min X, min Z)
  sizeX: number, -- Number of grid cells along X axis
  sizeZ: number, -- Number of grid cells along Z axis
  cellSize: number, -- Studs per cell
  defaultLayers: { string }?, -- Initial layer names to instantiate
}

export type OptimalQueryConfig = {
  center: Vector3, -- Center world position of query
  radius: number, -- Radius in studs to evaluate candidate cells
  weights: { [string]: number }, -- Weight multiplier per layer (e.g. Threat: -1.5, Cover: 1.0)
  filter: ((pos: Vector3, score: number) -> boolean)?, -- Optional filter predicate
}

local EPSILON = 1e-6

local InfluenceMap = {}
InfluenceMap.__index = InfluenceMap

export type InfluenceMapInstance = typeof(setmetatable({} :: {
  _origin: Vector3,
  _sizeX: number,
  _sizeZ: number,
  _cellSize: number,
  _layers: { [string]: { [number]: { [number]: number } } },
  _configs: { [string]: LayerConfig },
}, InfluenceMap))

-- Helper: create a zeroed 2D grid table
local function createGrid(sizeX: number, sizeZ: number): { [number]: { [number]: number } }
  local grid: { [number]: { [number]: number } } = {}
  for x = 1, sizeX do
    local row: { [number]: number } = table.create(sizeZ, 0)
    for z = 1, sizeZ do
      row[z] = 0
    end
    grid[x] = row
  end
  return grid
end

function InfluenceMap.new(config: GridConfig): InfluenceMapInstance
  assert(config.sizeX > 0 and config.sizeZ > 0, "Grid dimensions must be positive integers")
  assert(config.cellSize > 0, "Cell size must be greater than zero")

  local self = setmetatable({
    _origin = config.origin or Vector3.new(0, 0, 0),
    _sizeX = math.floor(config.sizeX),
    _sizeZ = math.floor(config.sizeZ),
    _cellSize = config.cellSize,
    _layers = {},
    _configs = {},
  }, InfluenceMap)

  -- Default layers
  local defaultLayers = config.defaultLayers or { "Threat", "Friendly", "Cover", "Interest" }
  for _, layerName in ipairs(defaultLayers) do
    self:RegisterLayer(layerName)
  end

  return self
end

-- Register a new influence layer with custom decay and diffusion properties
function InfluenceMap.RegisterLayer(self: InfluenceMapInstance, layerName: string, layerConfig: LayerConfig?)
  local cfg: LayerConfig = layerConfig or {
    decayRate = 0.5,
    diffusionRate = 0.1,
    minValue = 0,
    maxValue = 100,
    decayType = "Exponential",
  }

  self._configs[layerName] = {
    decayRate = cfg.decayRate or 0.5,
    diffusionRate = math.clamp(cfg.diffusionRate or 0, 0, 0.5),
    minValue = cfg.minValue or 0,
    maxValue = cfg.maxValue or 100,
    decayType = cfg.decayType or "Exponential",
  }

  self._layers[layerName] = createGrid(self._sizeX, self._sizeZ)
end

-- Convert world position (Vector3) to 1-based grid coordinates
function InfluenceMap.WorldToGrid(self: InfluenceMapInstance, worldPos: Vector3): (number, number)
  local relX = worldPos.X - self._origin.X
  local relZ = worldPos.Z - self._origin.Z
  local gx = math.floor(relX / self._cellSize) + 1
  local gz = math.floor(relZ / self._cellSize) + 1
  return gx, gz
end

-- Convert 1-based grid coordinates to world center position of the cell
function InfluenceMap.GridToWorld(self: InfluenceMapInstance, gx: number, gz: number): Vector3
  local worldX = self._origin.X + (gx - 0.5) * self._cellSize
  local worldZ = self._origin.Z + (gz - 0.5) * self._cellSize
  return Vector3.new(worldX, self._origin.Y, worldZ)
end

-- Check if grid coordinate is within valid bounds
function InfluenceMap.IsInBounds(self: InfluenceMapInstance, gx: number, gz: number): boolean
  return gx >= 1 and gx <= self._sizeX and gz >= 1 and gz <= self._sizeZ
end

-- Set direct value of a specific cell
function InfluenceMap.SetCell(self: InfluenceMapInstance, layerName: string, gx: number, gz: number, value: number)
  local grid = self._layers[layerName]
  local cfg = self._configs[layerName]
  if not grid or not cfg then return end

  if self:IsInBounds(gx, gz) then
    grid[gx][gz] = math.clamp(value, cfg.minValue, cfg.maxValue)
  end
end

-- Get discrete value of a specific cell
function InfluenceMap.GetCell(self: InfluenceMapInstance, layerName: string, gx: number, gz: number): number
  local grid = self._layers[layerName]
  if not grid or not self:IsInBounds(gx, gz) then return 0 end
  return grid[gx][gz]
end

-- Add point influence source with falloff
function InfluenceMap.AddInfluencePoint(
  self: InfluenceMapInstance,
  layerName: string,
  worldPos: Vector3,
  strength: number,
  radius: number,
  falloff: FalloffType?
)
  local grid = self._layers[layerName]
  local cfg = self._configs[layerName]
  if not grid or not cfg then return end
  if radius <= 0 then return end

  local fType: FalloffType = falloff or "Linear"
  local centerGx, centerGz = self:WorldToGrid(worldPos)
  local cellRadius = math.ceil(radius / self._cellSize)

  local minGx = math.clamp(centerGx - cellRadius, 1, self._sizeX)
  local maxGx = math.clamp(centerGx + cellRadius, 1, self._sizeX)
  local minGz = math.clamp(centerGz - cellRadius, 1, self._sizeZ)
  local maxGz = math.clamp(centerGz + cellRadius, 1, self._sizeZ)

  for gx = minGx, maxGx do
    for gz = minGz, maxGz do
      local cellWorld = self:GridToWorld(gx, gz)
      local dist = math.sqrt((cellWorld.X - worldPos.X)^2 + (cellWorld.Z - worldPos.Z)^2)
      if dist <= radius then
        local factor = 0
        local normDist = dist / radius

        if fType == "Constant" then
          factor = 1
        elseif fType == "Linear" then
          factor = 1 - normDist
        elseif fType == "Quadratic" then
          factor = (1 - normDist)^2
        elseif fType == "Gaussian" then
          factor = math.exp(-3 * normDist * normDist)
        end

        local added = strength * factor
        grid[gx][gz] = math.clamp(grid[gx][gz] + added, cfg.minValue, cfg.maxValue)
      end
    end
  end
end

-- Add line influence source (e.g. line of fire, barrier, road)
function InfluenceMap.AddInfluenceLine(
  self: InfluenceMapInstance,
  layerName: string,
  startPos: Vector3,
  endPos: Vector3,
  strength: number,
  radius: number,
  falloff: FalloffType?
)
  local grid = self._layers[layerName]
  local cfg = self._configs[layerName]
  if not grid or not cfg then return end

  local segVec = Vector3.new(endPos.X - startPos.X, 0, endPos.Z - startPos.Z)
  local segLenSq = segVec.X^2 + segVec.Z^2
  local fType: FalloffType = falloff or "Linear"

  local minWorldX = math.min(startPos.X, endPos.X) - radius
  local maxWorldX = math.max(startPos.X, endPos.X) + radius
  local minWorldZ = math.min(startPos.Z, endPos.Z) - radius
  local maxWorldZ = math.max(startPos.Z, endPos.Z) + radius

  local minGx, minGz = self:WorldToGrid(Vector3.new(minWorldX, 0, minWorldZ))
  local maxGx, maxGz = self:WorldToGrid(Vector3.new(maxWorldX, 0, maxWorldZ))

  minGx = math.clamp(minGx, 1, self._sizeX)
  maxGx = math.clamp(maxGx, 1, self._sizeX)
  minGz = math.clamp(minGz, 1, self._sizeZ)
  maxGz = math.clamp(maxGz, 1, self._sizeZ)

  for gx = minGx, maxGx do
    for gz = minGz, maxGz do
      local cellWorld = self:GridToWorld(gx, gz)
      local ptVec = Vector3.new(cellWorld.X - startPos.X, 0, cellWorld.Z - startPos.Z)

      local t = 0
      if segLenSq > EPSILON then
        t = math.clamp((ptVec.X * segVec.X + ptVec.Z * segVec.Z) / segLenSq, 0, 1)
      end

      local projX = startPos.X + t * segVec.X
      local projZ = startPos.Z + t * segVec.Z
      local dist = math.sqrt((cellWorld.X - projX)^2 + (cellWorld.Z - projZ)^2)

      if dist <= radius then
        local factor = 0
        local normDist = dist / radius
        if fType == "Constant" then
          factor = 1
        elseif fType == "Linear" then
          factor = 1 - normDist
        elseif fType == "Quadratic" then
          factor = (1 - normDist)^2
        elseif fType == "Gaussian" then
          factor = math.exp(-3 * normDist * normDist)
        end

        local added = strength * factor
        grid[gx][gz] = math.clamp(grid[gx][gz] + added, cfg.minValue, cfg.maxValue)
      end
    end
  end
end

-- Sample continuous influence via bilinear interpolation
function InfluenceMap.GetInfluence(self: InfluenceMapInstance, layerName: string, worldPos: Vector3): number
  local grid = self._layers[layerName]
  if not grid then return 0 end

  -- Shift by 0.5 so that integer coordinates correspond to cell centers
  local contX = (worldPos.X - self._origin.X) / self._cellSize + 0.5
  local contZ = (worldPos.Z - self._origin.Z) / self._cellSize + 0.5

  local gx0 = math.floor(contX)
  local gz0 = math.floor(contZ)
  local gx1 = gx0 + 1
  local gz1 = gz0 + 1

  local tx = contX - gx0
  local tz = contZ - gz0

  local function sample(x: number, z: number): number
    local cx = math.clamp(x, 1, self._sizeX)
    local cz = math.clamp(z, 1, self._sizeZ)
    return grid[cx][cz]
  end

  local v00 = sample(gx0, gz0)
  local v10 = sample(gx1, gz0)
  local v01 = sample(gx0, gz1)
  local v11 = sample(gx1, gz1)

  local top = v00 * (1 - tx) + v10 * tx
  local bottom = v01 * (1 - tx) + v11 * tx
  return top * (1 - tz) + bottom * tz
end

-- Calculate 2D spatial gradient (df/dx, df/dz) using central differences
function InfluenceMap.GetGradient(self: InfluenceMapInstance, layerName: string, worldPos: Vector3): Vector3
  local h = self._cellSize * 0.5
  local valRight = self:GetInfluence(layerName, worldPos + Vector3.new(h, 0, 0))
  local valLeft = self:GetInfluence(layerName, worldPos - Vector3.new(h, 0, 0))
  local valForward = self:GetInfluence(layerName, worldPos + Vector3.new(0, 0, h))
  local valBack = self:GetInfluence(layerName, worldPos - Vector3.new(0, 0, h))

  local dfdx = (valRight - valLeft) / (2 * h)
  local dfdz = (valForward - valBack) / (2 * h)
  return Vector3.new(dfdx, 0, dfdz)
end

-- Step simulation: apply decay and neighbor diffusion to registered layers
function InfluenceMap.Update(self: InfluenceMapInstance, dt: number)
  if dt <= 0 then return end

  for layerName, grid in pairs(self._layers) do
    local cfg = self._configs[layerName]
    local decayRate = cfg.decayRate
    local diffusionRate = cfg.diffusionRate
    local decayType = cfg.decayType or "Exponential"

    -- Temporary buffer for diffusion
    local buffer = createGrid(self._sizeX, self._sizeZ)

    for x = 1, self._sizeX do
      for z = 1, self._sizeZ do
        local val = grid[x][z]

        -- Apply decay
        if decayType == "Exponential" then
          val = val * math.exp(-decayRate * dt)
        else
          val = math.max(cfg.minValue, val - decayRate * dt)
        end

        if val < EPSILON then
          val = cfg.minValue
        end

        buffer[x][z] = val
      end
    end

    -- Apply diffusion step if enabled
    if diffusionRate > 0 then
      local diffFactor = math.clamp(diffusionRate * dt, 0, 0.2)
      for x = 1, self._sizeX do
        for z = 1, self._sizeZ do
          local centerVal = buffer[x][z]
          local neighborSum = 0
          local neighborCount = 0

          if x > 1 then neighborSum += buffer[x - 1][z]; neighborCount += 1 end
          if x < self._sizeX then neighborSum += buffer[x + 1][z]; neighborCount += 1 end
          if z > 1 then neighborSum += buffer[x][z - 1]; neighborCount += 1 end
          if z < self._sizeZ then neighborSum += buffer[x][z + 1]; neighborCount += 1 end

          if neighborCount > 0 then
            local avgNeighbor = neighborSum / neighborCount
            local diffused = centerVal + (avgNeighbor - centerVal) * diffFactor
            grid[x][z] = math.clamp(diffused, cfg.minValue, cfg.maxValue)
          else
            grid[x][z] = math.clamp(centerVal, cfg.minValue, cfg.maxValue)
          end
        end
      end
    else
      for x = 1, self._sizeX do
        for z = 1, self._sizeZ do
          grid[x][z] = math.clamp(buffer[x][z], cfg.minValue, cfg.maxValue)
        end
      end
    end
  end
end

-- Find optimal position based on weighted multi-layer evaluation within a query circle
function InfluenceMap.FindOptimalPosition(self: InfluenceMapInstance, query: OptimalQueryConfig): (Vector3?, number)
  local center = query.center
  local radius = query.radius
  local weights = query.weights
  local filter = query.filter

  local centerGx, centerGz = self:WorldToGrid(center)
  local cellRadius = math.ceil(radius / self._cellSize)

  local minGx = math.clamp(centerGx - cellRadius, 1, self._sizeX)
  local maxGx = math.clamp(centerGx + cellRadius, 1, self._sizeX)
  local minGz = math.clamp(centerGz - cellRadius, 1, self._sizeZ)
  local maxGz = math.clamp(centerGz + cellRadius, 1, self._sizeZ)

  local bestPos: Vector3? = nil
  local bestScore = -math.huge

  for gx = minGx, maxGx do
    for gz = minGz, maxGz do
      local cellWorld = self:GridToWorld(gx, gz)
      local dist = math.sqrt((cellWorld.X - center.X)^2 + (cellWorld.Z - center.Z)^2)

      if dist <= radius then
        local score = 0
        for layerName, weight in pairs(weights) do
          local grid = self._layers[layerName]
          if grid then
            score += grid[gx][gz] * weight
          end
        end

        if not filter or filter(cellWorld, score) then
          if score > bestScore then
            bestScore = score
            bestPos = cellWorld
          end
        end
      end
    end
  end

  return bestPos, bestScore
end

-- Find extreme cell (maximum or minimum) in a layer
function InfluenceMap.GetExtremeCell(self: InfluenceMapInstance, layerName: string, findMax: boolean?): (Vector3, number)
  local grid = self._layers[layerName]
  local isMax = if findMax == nil then true else findMax
  local extremeVal = if isMax then -math.huge else math.huge
  local extremeGx = 1
  local extremeGz = 1

  if grid then
    for x = 1, self._sizeX do
      for z = 1, self._sizeZ do
        local val = grid[x][z]
        if isMax then
          if val > extremeVal then
            extremeVal = val
            extremeGx = x
            extremeGz = z
          end
        else
          if val < extremeVal then
            extremeVal = val
            extremeGx = x
            extremeGz = z
          end
        end
      end
    end
  else
    extremeVal = 0
  end

  return self:GridToWorld(extremeGx, extremeGz), extremeVal
end

-- Calculate frontline tension map where Threat and Friendly presence collide
function InfluenceMap.ComputeTension(
  self: InfluenceMapInstance,
  threatLayer: string?,
  friendlyLayer: string?
): { [number]: { [number]: number } }
  local tName = threatLayer or "Threat"
  local fName = friendlyLayer or "Friendly"
  local tGrid = self._layers[tName]
  local fGrid = self._layers[fName]

  local tension = createGrid(self._sizeX, self._sizeZ)
  if not tGrid or not fGrid then return tension end

  for x = 1, self._sizeX do
    for z = 1, self._sizeZ do
      -- Tension is highest where both opposing forces have high presence
      tension[x][z] = math.sqrt(tGrid[x][z] * fGrid[x][z])
    end
  end

  return tension
end

-- Reset a specific layer or all layers to their minimum values
function InfluenceMap.Clear(self: InfluenceMapInstance, layerName: string?)
  if layerName then
    local grid = self._layers[layerName]
    local cfg = self._configs[layerName]
    if grid and cfg then
      for x = 1, self._sizeX do
        for z = 1, self._sizeZ do
          grid[x][z] = cfg.minValue
        end
      end
    end
  else
    for lName, grid in pairs(self._layers) do
      local cfg = self._configs[lName]
      for x = 1, self._sizeX do
        for z = 1, self._sizeZ do
          grid[x][z] = cfg.minValue
        end
      end
    end
  end
end

-- Read-only getters
function InfluenceMap.GetGridDimensions(self: InfluenceMapInstance): (number, number, number)
  return self._sizeX, self._sizeZ, self._cellSize
end

function InfluenceMap.GetOrigin(self: InfluenceMapInstance): Vector3
  return self._origin
end

return InfluenceMap
