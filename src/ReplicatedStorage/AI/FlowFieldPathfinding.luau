--!strict
--[[
  FlowFieldPathfinding.luau
  crustdev studio systems - ReplicatedStorage/AI/FlowFieldPathfinding

  Production-grade 2D/3D-projected Flow Field (Vector Field) pathfinding system.
  Computes global integration and directional flow fields to route hundreds or
  thousands of autonomous agents (swarms, hordes, NPCs) towards single or
  multiple dynamic targets with O(1) steering lookup time per agent.

  Features:
  - Configurable 2D grid projected onto X-Z plane with customizable world origin and cellSize.
  - Cost field supporting arbitrary terrain weights (1 = normal, >1 = rough, 255 = impassable).
  - Wavefront Dijkstra integration with 8-directional propagation and corner-cutting avoidance.
  - Multi-destination target integration (convergence to multiple exits/goals simultaneously).
  - Directional vector field calculation along steepest integration descent.
  - Continuous bilinear interpolation sampling to eliminate boundary jitter and snapping.
  - Dynamic obstacle registration (point and rectangular bounding areas).
  - ASCII visualization renderer for automated testing and server diagnostics.
  - Zero external dependencies. Fully compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local ZERO_VECTOR = Vector3.new(0, 0, 0)
local OBSTACLE_COST = 255
local SQRT_TWO = 1.4142135623730951

export type CellCoord = {
  x: number,
  z: number,
}

export type GridConfig = {
  origin: Vector3?,
  cellSize: number?,
  width: number,
  height: number,
  defaultCost: number?,
}

export type FlowFieldPathfindingImpl = {
  __index: FlowFieldPathfindingImpl,
  new: (config: GridConfig) -> FlowField,
  GetDimensions: (self: FlowField) -> (number, number),
  GetOrigin: (self: FlowField) -> Vector3,
  GetCellSize: (self: FlowField) -> number,
  IsValidCell: (self: FlowField, gx: number, gz: number) -> boolean,
  GetCellIndex: (self: FlowField, gx: number, gz: number) -> number,
  IndexToCell: (self: FlowField, index: number) -> (number, number),
  WorldToGrid: (self: FlowField, worldPos: Vector3) -> (number, number),
  GridToWorld: (self: FlowField, gx: number, gz: number) -> Vector3,
  GetCost: (self: FlowField, gx: number, gz: number) -> number,
  SetCost: (self: FlowField, gx: number, gz: number, cost: number) -> (),
  SetObstacle: (self: FlowField, gx: number, gz: number, isObstacle: boolean) -> (),
  SetRectObstacle: (self: FlowField, minGX: number, minGZ: number, maxGX: number, maxGZ: number, isObstacle: boolean) -> (),
  IsWalkable: (self: FlowField, gx: number, gz: number) -> boolean,
  SetDestination: (self: FlowField, gx: number, gz: number) -> (),
  SetDestinations: (self: FlowField, targets: { CellCoord }) -> (),
  ClearDestinations: (self: FlowField) -> (),
  UpdateField: (self: FlowField) -> boolean,
  GetIntegrationDistance: (self: FlowField, gx: number, gz: number) -> number,
  GetFlowVector: (self: FlowField, gx: number, gz: number) -> Vector3,
  SampleDirection: (self: FlowField, worldPos: Vector3) -> Vector3,
  SampleVelocity: (self: FlowField, worldPos: Vector3, desiredSpeed: number) -> Vector3,
  Reset: (self: FlowField) -> (),
  RenderASCII: (self: FlowField) -> string,
}

export type FlowField = typeof(setmetatable({} :: {
  _origin: Vector3,
  _cellSize: number,
  _width: number,
  _height: number,
  _totalCells: number,
  _defaultCost: number,
  _costField: { number },
  _integrationField: { number },
  _vectorField: { Vector3 },
  _destinations: { CellCoord },
  _isDirty: boolean,
}, {} :: FlowFieldPathfindingImpl))

local FlowFieldPathfinding = {} :: FlowFieldPathfindingImpl
FlowFieldPathfinding.__index = FlowFieldPathfinding

-- 8-directional neighbor relative offsets: dx, dz, base distance
local NEIGHBORS = {
  { dx = 0, dz = 1, cost = 1.0 },       -- North
  { dx = 1, dz = 0, cost = 1.0 },       -- East
  { dx = 0, dz = -1, cost = 1.0 },      -- South
  { dx = -1, dz = 0, cost = 1.0 },      -- West
  { dx = 1, dz = 1, cost = SQRT_TWO },  -- North-East
  { dx = -1, dz = 1, cost = SQRT_TWO }, -- North-West
  { dx = 1, dz = -1, cost = SQRT_TWO }, -- South-East
  { dx = -1, dz = -1, cost = SQRT_TWO },-- South-West
}

-- Min-Heap for Dijkstra integration propagation
type MinHeap = {
  elements: { number },
  distances: { number },
}

local function heapPush(heap: MinHeap, cellIdx: number)
  local elems = heap.elements
  local dists = heap.distances
  local idx = #elems + 1
  elems[idx] = cellIdx

  while idx > 1 do
    local parentIdx = math.floor(idx / 2)
    local parentCell = elems[parentIdx]
    if dists[cellIdx] < dists[parentCell] then
      elems[idx] = parentCell
      elems[parentIdx] = cellIdx
      idx = parentIdx
    else
      break
    end
  end
end

local function heapPop(heap: MinHeap): number?
  local elems = heap.elements
  local dists = heap.distances
  local n = #elems
  if n == 0 then return nil end

  local top = elems[1]
  local last = elems[n]
  elems[n] = nil :: any
  n = n - 1

  if n > 0 then
    elems[1] = last
    local idx = 1
    while true do
      local left = idx * 2
      local right = left + 1
      local smallest = idx

      if left <= n and dists[elems[left]] < dists[elems[smallest]] then
        smallest = left
      end
      if right <= n and dists[elems[right]] < dists[elems[smallest]] then
        smallest = right
      end

      if smallest ~= idx then
        local temp = elems[idx]
        elems[idx] = elems[smallest]
        elems[smallest] = temp
        idx = smallest
      else
        break
      end
    end
  end

  return top
end

function FlowFieldPathfinding.new(config: GridConfig): FlowField
  assert(config.width > 0, "Grid width must be positive")
  assert(config.height > 0, "Grid height must be positive")

  local totalCells = config.width * config.height
  local origin = config.origin or Vector3.new(0, 0, 0)
  local cellSize = config.cellSize or 4.0
  local defaultCost = config.defaultCost or 1.0

  local costField = table.create(totalCells, defaultCost)
  local integrationField = table.create(totalCells, math.huge)
  local vectorField = table.create(totalCells, ZERO_VECTOR)

  local self = setmetatable({
    _origin = origin,
    _cellSize = cellSize,
    _width = config.width,
    _height = config.height,
    _totalCells = totalCells,
    _defaultCost = defaultCost,
    _costField = costField,
    _integrationField = integrationField,
    _vectorField = vectorField,
    _destinations = {},
    _isDirty = true,
  }, FlowFieldPathfinding)

  return self
end

function FlowFieldPathfinding:GetDimensions(): (number, number)
  return self._width, self._height
end

function FlowFieldPathfinding:GetOrigin(): Vector3
  return self._origin
end

function FlowFieldPathfinding:GetCellSize(): number
  return self._cellSize
end

function FlowFieldPathfinding:IsValidCell(gx: number, gz: number): boolean
  return gx >= 1 and gx <= self._width and gz >= 1 and gz <= self._height
end

function FlowFieldPathfinding:GetCellIndex(gx: number, gz: number): number
  return (gz - 1) * self._width + gx
end

function FlowFieldPathfinding:IndexToCell(index: number): (number, number)
  local zeroBased = index - 1
  local gz = math.floor(zeroBased / self._width) + 1
  local gx = (zeroBased % self._width) + 1
  return gx, gz
end

function FlowFieldPathfinding:WorldToGrid(worldPos: Vector3): (number, number)
  local relX = worldPos.X - self._origin.X
  local relZ = worldPos.Z - self._origin.Z

  local gx = math.floor(relX / self._cellSize) + 1
  local gz = math.floor(relZ / self._cellSize) + 1

  return gx, gz
end

function FlowFieldPathfinding:GridToWorld(gx: number, gz: number): Vector3
  local worldX = self._origin.X + (gx - 0.5) * self._cellSize
  local worldZ = self._origin.Z + (gz - 0.5) * self._cellSize
  return Vector3.new(worldX, self._origin.Y, worldZ)
end

function FlowFieldPathfinding:GetCost(gx: number, gz: number): number
  if not self:IsValidCell(gx, gz) then return OBSTACLE_COST end
  return self._costField[self:GetCellIndex(gx, gz)]
end

function FlowFieldPathfinding:SetCost(gx: number, gz: number, cost: number)
  if not self:IsValidCell(gx, gz) then return end
  local clampedCost = math.clamp(cost, 1, OBSTACLE_COST)
  local idx = self:GetCellIndex(gx, gz)
  if self._costField[idx] ~= clampedCost then
    self._costField[idx] = clampedCost
    self._isDirty = true
  end
end

function FlowFieldPathfinding:SetObstacle(gx: number, gz: number, isObstacle: boolean)
  self:SetCost(gx, gz, if isObstacle then OBSTACLE_COST else self._defaultCost)
end

function FlowFieldPathfinding:SetRectObstacle(minGX: number, minGZ: number, maxGX: number, maxGZ: number, isObstacle: boolean)
  local startX = math.max(1, math.min(minGX, maxGX))
  local endX = math.min(self._width, math.max(minGX, maxGX))
  local startZ = math.max(1, math.min(minGZ, maxGZ))
  local endZ = math.min(self._height, math.max(minGZ, maxGZ))
  local cost = if isObstacle then OBSTACLE_COST else self._defaultCost

  for gz = startZ, endZ do
    for gx = startX, endX do
      local idx = self:GetCellIndex(gx, gz)
      if self._costField[idx] ~= cost then
        self._costField[idx] = cost
        self._isDirty = true
      end
    end
  end
end

function FlowFieldPathfinding:IsWalkable(gx: number, gz: number): boolean
  if not self:IsValidCell(gx, gz) then return false end
  return self._costField[self:GetCellIndex(gx, gz)] < OBSTACLE_COST
end

function FlowFieldPathfinding:SetDestination(gx: number, gz: number)
  self:SetDestinations({ { x = gx, z = gz } })
end

function FlowFieldPathfinding:SetDestinations(targets: { CellCoord })
  self._destinations = {}
  for _, target in ipairs(targets) do
    if self:IsValidCell(target.x, target.z) and self:IsWalkable(target.x, target.z) then
      table.insert(self._destinations, { x = target.x, z = target.z })
    end
  end
  self._isDirty = true
end

function FlowFieldPathfinding:ClearDestinations()
  self._destinations = {}
  self._isDirty = true
end

function FlowFieldPathfinding:UpdateField(): boolean
  if #self._destinations == 0 then
    for i = 1, self._totalCells do
      self._integrationField[i] = math.huge
      self._vectorField[i] = ZERO_VECTOR
    end
    self._isDirty = false
    return false
  end

  -- Phase 1: Reset integration field to infinity
  local intField = self._integrationField
  local costField = self._costField
  local w = self._width
  local h = self._height

  for i = 1, self._totalCells do
    intField[i] = math.huge
  end

  local heap: MinHeap = {
    elements = {},
    distances = intField,
  }

  -- Initialize target cells with distance 0 and push onto open queue
  for _, dest in ipairs(self._destinations) do
    local idx = self:GetCellIndex(dest.x, dest.z)
    intField[idx] = 0
    heapPush(heap, idx)
  end

  -- Phase 2: Dijkstra wavefront propagation across grid
  while true do
    local currentIdx = heapPop(heap)
    if not currentIdx then break end

    local currentDist = intField[currentIdx]
    local cx, cz = self:IndexToCell(currentIdx)

    for _, n in ipairs(NEIGHBORS) do
      local nx = cx + n.dx
      local nz = cz + n.dz

      if nx >= 1 and nx <= w and nz >= 1 and nz <= h then
        local nIdx = (nz - 1) * w + nx
        local nCost = costField[nIdx]

        if nCost < OBSTACLE_COST then
          -- Diagonal corner-cutting protection:
          -- Prevent moving diagonally if adjacent cardinal cells are impenetrable obstacles
          local canTraverse = true
          if n.dx ~= 0 and n.dz ~= 0 then
            local cardXCost = costField[(cz - 1) * w + nx]
            local cardZCost = costField[(nz - 1) * w + cx]
            if cardXCost >= OBSTACLE_COST or cardZCost >= OBSTACLE_COST then
              canTraverse = false
            end
          end

          if canTraverse then
            local newDist = currentDist + (nCost * n.cost)
            if newDist < intField[nIdx] then
              intField[nIdx] = newDist
              heapPush(heap, nIdx)
            end
          end
        end
      end
    end
  end

  -- Phase 3: Vector field derivation along steepest descent
  local vecField = self._vectorField
  for gz = 1, h do
    for gx = 1, w do
      local cellIdx = (gz - 1) * w + gx
      local currentDist = intField[cellIdx]

      if currentDist == 0 then
        -- Destination cell has zero flow vector
        vecField[cellIdx] = ZERO_VECTOR
      elseif currentDist == math.huge or costField[cellIdx] >= OBSTACLE_COST then
        -- Impassable or unreachable cell
        vecField[cellIdx] = ZERO_VECTOR
      else
        local bestNeighborDist = currentDist
        local bestDX = 0
        local bestDZ = 0

        for _, n in ipairs(NEIGHBORS) do
          local nx = gx + n.dx
          local nz = gz + n.dz

          if nx >= 1 and nx <= w and nz >= 1 and nz <= h then
            local nIdx = (nz - 1) * w + nx
            local nDist = intField[nIdx]

            -- Validate corner cutting for diagonal vectors
            local allowed = true
            if n.dx ~= 0 and n.dz ~= 0 then
              local cardXCost = costField[(gz - 1) * w + nx]
              local cardZCost = costField[(nz - 1) * w + gx]
              if cardXCost >= OBSTACLE_COST or cardZCost >= OBSTACLE_COST then
                allowed = false
              end
            end

            if allowed and nDist < bestNeighborDist then
              bestNeighborDist = nDist
              bestDX = n.dx
              bestDZ = n.dz
            end
          end
        end

        if bestDX ~= 0 or bestDZ ~= 0 then
          local dir = Vector3.new(bestDX, 0, bestDZ)
          vecField[cellIdx] = dir.Unit
        else
          vecField[cellIdx] = ZERO_VECTOR
        end
      end
    end
  end

  self._isDirty = false
  return true
end

function FlowFieldPathfinding:GetIntegrationDistance(gx: number, gz: number): number
  if not self:IsValidCell(gx, gz) then return math.huge end
  if self._isDirty then self:UpdateField() end
  return self._integrationField[self:GetCellIndex(gx, gz)]
end

function FlowFieldPathfinding:GetFlowVector(gx: number, gz: number): Vector3
  if not self:IsValidCell(gx, gz) then return ZERO_VECTOR end
  if self._isDirty then self:UpdateField() end
  return self._vectorField[self:GetCellIndex(gx, gz)]
end

function FlowFieldPathfinding:SampleDirection(worldPos: Vector3): Vector3
  if self._isDirty then self:UpdateField() end

  local relX = (worldPos.X - self._origin.X) / self._cellSize
  local relZ = (worldPos.Z - self._origin.Z) / self._cellSize

  -- Center of cell (gx, gz) is located at (gx - 0.5, gz - 0.5) in continuous cell space
  local contX = relX + 0.5
  local contZ = relZ + 0.5

  local x0 = math.clamp(math.floor(contX), 1, self._width)
  local z0 = math.clamp(math.floor(contZ), 1, self._height)
  local x1 = math.clamp(x0 + 1, 1, self._width)
  local z1 = math.clamp(z0 + 1, 1, self._height)

  local tx = math.clamp(contX - x0, 0, 1)
  local tz = math.clamp(contZ - z0, 0, 1)

  local v00 = self:GetFlowVector(x0, z0)
  local v10 = self:GetFlowVector(x1, z0)
  local v01 = self:GetFlowVector(x0, z1)
  local v11 = self:GetFlowVector(x1, z1)

  -- Bilinear vector interpolation
  local vxTop = v00.X * (1 - tx) + v10.X * tx
  local vzTop = v00.Z * (1 - tx) + v10.Z * tx

  local vxBottom = v01.X * (1 - tx) + v11.X * tx
  local vzBottom = v01.Z * (1 - tx) + v11.Z * tx

  local finalX = vxTop * (1 - tz) + vxBottom * tz
  local finalZ = vzTop * (1 - tz) + vzBottom * tz

  local blended = Vector3.new(finalX, 0, finalZ)
  if blended.Magnitude > 0.001 then
    return blended.Unit
  end

  -- Fallback to nearest discrete grid cell vector if blended vector cancels out
  local nearestGX = math.clamp(math.floor(relX) + 1, 1, self._width)
  local nearestGZ = math.clamp(math.floor(relZ) + 1, 1, self._height)
  return self:GetFlowVector(nearestGX, nearestGZ)
end

function FlowFieldPathfinding:SampleVelocity(worldPos: Vector3, desiredSpeed: number): Vector3
  local dir = self:SampleDirection(worldPos)
  return dir * desiredSpeed
end

function FlowFieldPathfinding:Reset()
  for i = 1, self._totalCells do
    self._costField[i] = self._defaultCost
    self._integrationField[i] = math.huge
    self._vectorField[i] = ZERO_VECTOR
  end
  self._destinations = {}
  self._isDirty = true
end

function FlowFieldPathfinding:RenderASCII(): string
  if self._isDirty then self:UpdateField() end

  local lines = {}
  local header = string.format("FlowField [%d x %d, cell=%d studs]", self._width, self._height, self._cellSize)
  table.insert(lines, header)

  for gz = self._height, 1, -1 do
    local row = {}
    for gx = 1, self._width do
      local idx = self:GetCellIndex(gx, gz)
      local cost = self._costField[idx]

      if cost >= OBSTACLE_COST then
        table.insert(row, "#")
      else
        local isDest = false
        for _, dest in ipairs(self._destinations) do
          if dest.x == gx and dest.z == gz then
            isDest = true
            break
          end
        end

        if isDest then
          table.insert(row, "*")
        else
          local v = self._vectorField[idx]
          if v.Magnitude < 0.001 then
            table.insert(row, ".")
          else
            -- Map direction vector to ASCII glyph
            local angle = math.atan2(v.Z, v.X) -- radians from -pi to pi
            local deg = math.deg(angle)
            if deg < 0 then deg = deg + 360 end

            if deg >= 337.5 or deg < 22.5 then
              table.insert(row, ">") -- East
            elseif deg >= 22.5 and deg < 67.5 then
              table.insert(row, "/") -- North-East
            elseif deg >= 67.5 and deg < 112.5 then
              table.insert(row, "^") -- North
            elseif deg >= 112.5 and deg < 157.5 then
              table.insert(row, "\\") -- North-West
            elseif deg >= 157.5 and deg < 202.5 then
              table.insert(row, "<") -- West
            elseif deg >= 202.5 and deg < 247.5 then
              table.insert(row, "/") -- South-West
            elseif deg >= 247.5 and deg < 292.5 then
              table.insert(row, "v") -- South
            else
              table.insert(row, "\\") -- South-East
            end
          end
        end
      end
    end
    table.insert(lines, table.concat(row, " "))
  end

  return table.concat(lines, "\n")
end

return FlowFieldPathfinding
