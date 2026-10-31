--!strict
--[[
  SpatialHashGrid.luau
  O(1) uniform spatial hashing grid for broadphase proximity queries and collision acceleration.
  Part of crustdev studio game systems.
  Zero dependencies, pure Luau execution.
]]

export type SpatialEntity<T> = {
  Id: string | number,
  Position: Vector3,
  Radius: number,
  Data: T?,
}

export type GridCell<T> = {
  Entities: { [string | number]: SpatialEntity<T> },
  Count: number,
}

export type HashGrid<T> = {
  CellSize: number,
  Cells: { [string]: GridCell<T> },
  EntityMap: { [string | number]: { Entity: SpatialEntity<T>, CellKey: string } },
  TotalEntities: number,
}

local SpatialHashGrid = {}
SpatialHashGrid.__index = SpatialHashGrid

local DEFAULT_CELL_SIZE = 32.0 -- studs per bucket

local function computeCellCoord(val: number, cellSize: number): number
  return math.floor(val / cellSize)
end

local function cellKey(cx: number, cy: number, cz: number): string
  return string.format("%d:%d:%d", cx, cy, cz)
end

function SpatialHashGrid.new<T>(cellSize: number?): HashGrid<T>
  local size = cellSize or DEFAULT_CELL_SIZE
  if size <= 0 then
    size = DEFAULT_CELL_SIZE
  end

  local self: HashGrid<T> = {
    CellSize = size,
    Cells = {},
    EntityMap = {},
    TotalEntities = 0,
  }

  return setmetatable(self :: any, SpatialHashGrid) :: any
end

function SpatialHashGrid.Insert<T>(self: HashGrid<T>, id: string | number, position: Vector3, radius: number?, data: T?): boolean
  if self.EntityMap[id] ~= nil then
    return false -- already registered, use Update
  end

  local cx = computeCellCoord(position.X, self.CellSize)
  local cy = computeCellCoord(position.Y, self.CellSize)
  local cz = computeCellCoord(position.Z, self.CellSize)
  local key = cellKey(cx, cy, cz)

  local cell = self.Cells[key]
  if not cell then
    cell = {
      Entities = {},
      Count = 0,
    }
    self.Cells[key] = cell
  end

  local entity: SpatialEntity<T> = {
    Id = id,
    Position = position,
    Radius = radius or 0.0,
    Data = data,
  }

  cell.Entities[id] = entity
  cell.Count += 1

  self.EntityMap[id] = {
    Entity = entity,
    CellKey = key,
  }
  self.TotalEntities += 1

  return true
end

function SpatialHashGrid.Update<T>(self: HashGrid<T>, id: string | number, newPosition: Vector3, newRadius: number?, newData: T?): boolean
  local entry = self.EntityMap[id]
  if not entry then
    return false
  end

  local cx = computeCellCoord(newPosition.X, self.CellSize)
  local cy = computeCellCoord(newPosition.Y, self.CellSize)
  local cz = computeCellCoord(newPosition.Z, self.CellSize)
  local targetKey = cellKey(cx, cy, cz)

  entry.Entity.Position = newPosition
  if newRadius ~= nil then
    entry.Entity.Radius = newRadius
  end
  if newData ~= nil then
    entry.Entity.Data = newData
  end

  if entry.CellKey ~= targetKey then
    -- Transfer to new cell
    local oldCell = self.Cells[entry.CellKey]
    if oldCell then
      oldCell.Entities[id] = nil
      oldCell.Count -= 1
      if oldCell.Count <= 0 then
        self.Cells[entry.CellKey] = nil
      end
    end

    local newCell = self.Cells[targetKey]
    if not newCell then
      newCell = {
        Entities = {},
        Count = 0,
      }
      self.Cells[targetKey] = newCell
    end

    newCell.Entities[id] = entry.Entity
    newCell.Count += 1
    entry.CellKey = targetKey
  end

  return true
end

function SpatialHashGrid.Remove<T>(self: HashGrid<T>, id: string | number): boolean
  local entry = self.EntityMap[id]
  if not entry then
    return false
  end

  local cell = self.Cells[entry.CellKey]
  if cell then
    cell.Entities[id] = nil
    cell.Count -= 1
    if cell.Count <= 0 then
      self.Cells[entry.CellKey] = nil
    end
  end

  self.EntityMap[id] = nil
  self.TotalEntities -= 1
  return true
end

function SpatialHashGrid.QueryRadius<T>(self: HashGrid<T>, center: Vector3, queryRadius: number): { SpatialEntity<T> }
  local results: { SpatialEntity<T> } = {}
  local queryRadiusSq = queryRadius * queryRadius

  local minX = computeCellCoord(center.X - queryRadius, self.CellSize)
  local maxX = computeCellCoord(center.X + queryRadius, self.CellSize)
  local minY = computeCellCoord(center.Y - queryRadius, self.CellSize)
  local maxY = computeCellCoord(center.Y + queryRadius, self.CellSize)
  local minZ = computeCellCoord(center.Z - queryRadius, self.CellSize)
  local maxZ = computeCellCoord(center.Z + queryRadius, self.CellSize)

  for cx = minX, maxX do
    for cy = minY, maxY do
      for cz = minZ, maxZ do
        local key = cellKey(cx, cy, cz)
        local cell = self.Cells[key]
        if cell then
          for _, entity in pairs(cell.Entities) do
            local dx = entity.Position.X - center.X
            local dy = entity.Position.Y - center.Y
            local dz = entity.Position.Z - center.Z
            local distSq = dx * dx + dy * dy + dz * dz
            local effectiveRadius = queryRadius + entity.Radius
            if distSq <= effectiveRadius * effectiveRadius then
              table.insert(results, entity)
            end
          end
        end
      end
    end
  end

  return results
end

function SpatialHashGrid.QueryAABB<T>(self: HashGrid<T>, minBound: Vector3, maxBound: Vector3): { SpatialEntity<T> }
  local results: { SpatialEntity<T> } = {}

  local minX = computeCellCoord(minBound.X, self.CellSize)
  local maxX = computeCellCoord(maxBound.X, self.CellSize)
  local minY = computeCellCoord(minBound.Y, self.CellSize)
  local maxY = computeCellCoord(maxBound.Y, self.CellSize)
  local minZ = computeCellCoord(minBound.Z, self.CellSize)
  local maxZ = computeCellCoord(maxBound.Z, self.CellSize)

  for cx = minX, maxX do
    for cy = minY, maxY do
      for cz = minZ, maxZ do
        local key = cellKey(cx, cy, cz)
        local cell = self.Cells[key]
        if cell then
          for _, entity in pairs(cell.Entities) do
            local p = entity.Position
            local r = entity.Radius
            if (p.X + r >= minBound.X and p.X - r <= maxBound.X)
              and (p.Y + r >= minBound.Y and p.Y - r <= maxBound.Y)
              and (p.Z + r >= minBound.Z and p.Z - r <= maxBound.Z) then
              table.insert(results, entity)
            end
          end
        end
      end
    end
  end

  return results
end

function SpatialHashGrid.Clear<T>(self: HashGrid<T>)
  table.clear(self.Cells)
  table.clear(self.EntityMap)
  self.TotalEntities = 0
end

return SpatialHashGrid