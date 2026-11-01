--!strict
--[[
  SparseOctree.luau
  3D hierarchical dynamic octree spatial acceleration structure for volumetric entity queries,
  subterranean cave indexing, and collision culling.
  Part of crustdev studio game systems.
  Zero dependencies, pure Luau execution.
]]

local roblox = _G.Vector3 and _G or require("@lune/roblox")
local Vector3 = roblox.Vector3

export type OctreeEntity<T> = {
  Id: string | number,
  Position: Vector3,
  Radius: number,
  Data: T?,
}

export type OctreeNode<T> = {
  Center: Vector3,
  HalfSize: Vector3,
  MinBound: Vector3,
  MaxBound: Vector3,
  Depth: number,
  Entities: { OctreeEntity<T> },
  Children: { OctreeNode<T> }?,
  TotalSubtreeCount: number,
}

export type Octree<T> = {
  Root: OctreeNode<T>,
  MaxDepth: number,
  MaxEntitiesPerNode: number,
  EntityMap: { [string | number]: { Entity: OctreeEntity<T>, Node: OctreeNode<T> } },
  TotalEntities: number,

  -- Methods
  Insert: (self: Octree<T>, id: string | number, position: Vector3, radius: number?, data: T?) -> boolean,
  QueryRadius: (self: Octree<T>, center: Vector3, radius: number) -> { OctreeEntity<T> },
  QueryAABB: (self: Octree<T>, minBound: Vector3, maxBound: Vector3) -> { OctreeEntity<T> },
  Raycast: (self: Octree<T>, origin: Vector3, direction: Vector3, maxDistance: number?) -> { Entity: OctreeEntity<T>, Distance: number, HitPoint: Vector3 }?,
  Update: (self: Octree<T>, id: string | number, newPosition: Vector3, newRadius: number?) -> boolean,
  Remove: (self: Octree<T>, id: string | number) -> boolean,
  Clear: (self: Octree<T>) -> (),
  Count: (self: Octree<T>) -> number,
}

local SparseOctreeImpl = {}
SparseOctreeImpl.__index = SparseOctreeImpl

local DEFAULT_HALF_SIZE = Vector3.new(2048, 2048, 2048)
local DEFAULT_MAX_DEPTH = 6
local DEFAULT_MAX_ENTITIES = 8

local function createNode<T>(center: Vector3, halfSize: Vector3, depth: number): OctreeNode<T>
  return {
    Center = center,
    HalfSize = halfSize,
    MinBound = center - halfSize,
    MaxBound = center + halfSize,
    Depth = depth,
    Entities = {},
    Children = nil,
    TotalSubtreeCount = 0,
  }
end

local function aabbIntersectsSphere(minBound: Vector3, maxBound: Vector3, center: Vector3, radius: number): boolean
  local cx = math.clamp(center.X, minBound.X, maxBound.X)
  local cy = math.clamp(center.Y, minBound.Y, maxBound.Y)
  local cz = math.clamp(center.Z, minBound.Z, maxBound.Z)

  local dx = center.X - cx
  local dy = center.Y - cy
  local dz = center.Z - cz

  return (dx * dx + dy * dy + dz * dz) <= (radius * radius)
end

local function aabbIntersectsAABB(minA: Vector3, maxA: Vector3, minB: Vector3, maxB: Vector3): boolean
  return (minA.X <= maxB.X and maxA.X >= minB.X) and
         (minA.Y <= maxB.Y and maxA.Y >= minB.Y) and
         (minA.Z <= maxB.Z and maxA.Z >= minB.Z)
end

local function containsPoint(minBound: Vector3, maxBound: Vector3, p: Vector3): boolean
  return p.X >= minBound.X and p.X <= maxBound.X and
         p.Y >= minBound.Y and p.Y <= maxBound.Y and
         p.Z >= minBound.Z and p.Z <= maxBound.Z
end

-- Subdivide an octree node into 8 octants
local function subdivideNode<T>(node: OctreeNode<T>): ()
  local quarterSize = node.HalfSize * 0.5
  local depth = node.Depth + 1
  local c = node.Center
  local qs = quarterSize

  node.Children = {
    -- Bottom octants (-Y)
    createNode(Vector3.new(c.X - qs.X, c.Y - qs.Y, c.Z - qs.Z), quarterSize, depth), -- 1: (-,-,-)
    createNode(Vector3.new(c.X + qs.X, c.Y - qs.Y, c.Z - qs.Z), quarterSize, depth), -- 2: (+,-,-)
    createNode(Vector3.new(c.X - qs.X, c.Y - qs.Y, c.Z + qs.Z), quarterSize, depth), -- 3: (-,+,+)
    createNode(Vector3.new(c.X + qs.X, c.Y - qs.Y, c.Z + qs.Z), quarterSize, depth), -- 4: (+,-,+)
    -- Top octants (+Y)
    createNode(Vector3.new(c.X - qs.X, c.Y + qs.Y, c.Z - qs.Z), quarterSize, depth), -- 5: (-,+,-)
    createNode(Vector3.new(c.X + qs.X, c.Y + qs.Y, c.Z - qs.Z), quarterSize, depth), -- 6: (+,+,-)
    createNode(Vector3.new(c.X - qs.X, c.Y + qs.Y, c.Z + qs.Z), quarterSize, depth), -- 7: (-,+,+)
    createNode(Vector3.new(c.X + qs.X, c.Y + qs.Y, c.Z + qs.Z), quarterSize, depth), -- 8: (+,+,+)
  }
end

-- Determine which child octant index (1..8) a position belongs to
local function getChildIndex(node: OctreeNode<any>, p: Vector3): number
  local c = node.Center
  local ix = if p.X >= c.X then 1 else 0
  local iy = if p.Y >= c.Y then 4 else 0
  local iz = if p.Z >= c.Z then 2 else 0
  return 1 + ix + iz + iy
end

-- Constructor for SparseOctree
function SparseOctreeImpl.new<T>(center: Vector3?, halfSize: Vector3?, maxDepth: number?, maxEntitiesPerNode: number?): Octree<T>
  local c = center or Vector3.new(0, 0, 0)
  local hs = halfSize or DEFAULT_HALF_SIZE
  local md = maxDepth or DEFAULT_MAX_DEPTH
  local me = maxEntitiesPerNode or DEFAULT_MAX_ENTITIES

  if md < 1 then md = 1 end
  if me < 1 then me = 1 end

  local self = setmetatable({
    Root = createNode(c, hs, 0),
    MaxDepth = md,
    MaxEntitiesPerNode = me,
    EntityMap = {},
    TotalEntities = 0,
  }, SparseOctreeImpl)

  return (self :: any) :: Octree<T>
end

-- Insert an entity into the octree hierarchy
function SparseOctreeImpl:Insert(id: string | number, position: Vector3, radius: number?, data: any): boolean
  if self.EntityMap[id] then
    self:Remove(id)
  end

  local rad = radius or 0.0
  if rad < 0 then rad = 0 end

  local entity: OctreeEntity<any> = {
    Id = id,
    Position = position,
    Radius = rad,
    Data = data,
  }

  local targetNode: OctreeNode<any> = self.Root

  while true do
    targetNode.TotalSubtreeCount += 1

    if targetNode.Children == nil then
      -- Leaf node: check capacity
      if #targetNode.Entities < self.MaxEntitiesPerNode or targetNode.Depth >= self.MaxDepth then
        table.insert(targetNode.Entities, entity)
        self.EntityMap[id] = { Entity = entity, Node = targetNode }
        self.TotalEntities += 1
        return true
      else
        -- Split node into 8 octants
        subdivideNode(targetNode)

        -- Re-insert existing entities into child octants
        local existing = targetNode.Entities
        targetNode.Entities = {}

        for _, e in ipairs(existing) do
          local childIdx = getChildIndex(targetNode, e.Position)
          local child = targetNode.Children[childIdx]
          table.insert(child.Entities, e)
          child.TotalSubtreeCount += 1
          self.EntityMap[e.Id].Node = child
        end

        -- Move downward for the new entity
        local nextChildIdx = getChildIndex(targetNode, position)
        targetNode = targetNode.Children[nextChildIdx]
      end
    else
      -- Interior node: descend into matching child octant
      local childIdx = getChildIndex(targetNode, position)
      targetNode = targetNode.Children[childIdx]
    end
  end
end

-- Hierarchical sphere range query
function SparseOctreeImpl:QueryRadius(center: Vector3, radius: number): { OctreeEntity<any> }
  local results: { OctreeEntity<any> } = {}
  local queryRadiusSq = radius * radius

  local stack: { OctreeNode<any> } = { self.Root }
  local stackPtr = 1

  while stackPtr > 0 do
    local node = stack[stackPtr]
    stackPtr -= 1

    if aabbIntersectsSphere(node.MinBound, node.MaxBound, center, radius) then
      if node.Children ~= nil then
        for i = 1, 8 do
          stackPtr += 1
          stack[stackPtr] = node.Children[i]
        end
      else
        for _, entity in ipairs(node.Entities) do
          local dx = entity.Position.X - center.X
          local dy = entity.Position.Y - center.Y
          local dz = entity.Position.Z - center.Z
          local distSq = dx * dx + dy * dy + dz * dz
          local maxRange = radius + entity.Radius
          if distSq <= (maxRange * maxRange) then
            table.insert(results, entity)
          end
        end
      end
    end
  end

  return results
end

-- Hierarchical 3D Axis-Aligned Bounding Box (AABB) query
function SparseOctreeImpl:QueryAABB(minBound: Vector3, maxBound: Vector3): { OctreeEntity<any> }
  local results: { OctreeEntity<any> } = {}

  local stack: { OctreeNode<any> } = { self.Root }
  local stackPtr = 1

  while stackPtr > 0 do
    local node = stack[stackPtr]
    stackPtr -= 1

    if aabbIntersectsAABB(node.MinBound, node.MaxBound, minBound, maxBound) then
      if node.Children ~= nil then
        for i = 1, 8 do
          stackPtr += 1
          stack[stackPtr] = node.Children[i]
        end
      else
        for _, entity in ipairs(node.Entities) do
          local p = entity.Position
          local r = entity.Radius
          if (p.X + r >= minBound.X and p.X - r <= maxBound.X) and
             (p.Y + r >= minBound.Y and p.Y - r <= maxBound.Y) and
             (p.Z + r >= minBound.Z and p.Z - r <= maxBound.Z) then
            table.insert(results, entity)
          end
        end
      end
    end
  end

  return results
end

-- Raycast query finding closest entity sphere hit
function SparseOctreeImpl:Raycast(origin: Vector3, direction: Vector3, maxDistance: number?): { Entity: OctreeEntity<any>, Distance: number, HitPoint: Vector3 }?
  local maxDist = maxDistance or 1000.0
  local dirLen = direction.Magnitude
  if dirLen < 0.0001 then
    return nil
  end
  local dir = direction / dirLen

  local closestHit: { Entity: OctreeEntity<any>, Distance: number, HitPoint: Vector3 }? = nil
  local closestDist = maxDist

  local stack: { OctreeNode<any> } = { self.Root }
  local stackPtr = 1

  while stackPtr > 0 do
    local node = stack[stackPtr]
    stackPtr -= 1

    -- Bounding box proximity check
    local nodeCenter = node.Center
    local toCenter = nodeCenter - origin
    local projDist = toCenter.X * dir.X + toCenter.Y * dir.Y + toCenter.Z * dir.Z

    -- Only prune if bounding box is entirely behind ray origin and outside bounds
    if projDist >= -node.HalfSize.Magnitude and (projDist - node.HalfSize.Magnitude) <= closestDist then
      if node.Children ~= nil then
        for i = 1, 8 do
          stackPtr += 1
          stack[stackPtr] = node.Children[i]
        end
      else
        for _, entity in ipairs(node.Entities) do
          local v = entity.Position - origin
          local tca = v.X * dir.X + v.Y * dir.Y + v.Z * dir.Z
          if tca >= 0 and tca <= closestDist + entity.Radius then
            local d2 = (v.X * v.X + v.Y * v.Y + v.Z * v.Z) - (tca * tca)
            local r = math.max(entity.Radius, 0.5)
            if d2 <= (r * r) then
              local thc = math.sqrt(math.max(0, (r * r) - d2))
              local t0 = tca - thc
              if t0 >= 0 and t0 < closestDist then
                closestDist = t0
                closestHit = {
                  Entity = entity,
                  Distance = t0,
                  HitPoint = origin + dir * t0,
                }
              end
            end
          end
        end
      end
    end
  end

  return closestHit
end

-- Update an entity's position and re-index if it crosses node boundaries
function SparseOctreeImpl:Update(id: string | number, newPosition: Vector3, newRadius: number?): boolean
  local record = self.EntityMap[id]
  if not record then
    return false
  end

  local rad = newRadius or record.Entity.Radius

  -- Check if entity still lies comfortably within its current leaf node
  local node = record.Node
  if containsPoint(node.MinBound, node.MaxBound, newPosition) then
    record.Entity.Position = newPosition
    record.Entity.Radius = rad
    return true
  end

  -- Entity crossed node boundary: re-insert into tree
  local data = record.Entity.Data
  self:Remove(id)
  return self:Insert(id, newPosition, rad, data)
end

-- Remove an entity by id
function SparseOctreeImpl:Remove(id: string | number): boolean
  local record = self.EntityMap[id]
  if not record then
    return false
  end

  local node = record.Node
  local targetEntity = record.Entity

  -- Remove from leaf node
  for i, entity in ipairs(node.Entities) do
    if entity.Id == id then
      table.remove(node.Entities, i)
      break
    end
  end

  self.EntityMap[id] = nil
  self.TotalEntities -= 1

  -- Decrement subtree counts along parent path
  local curr: OctreeNode<any>? = self.Root
  while curr ~= nil do
    curr.TotalSubtreeCount = math.max(0, curr.TotalSubtreeCount - 1)
    if curr.Children ~= nil then
      local idx = getChildIndex(curr, targetEntity.Position)
      curr = curr.Children[idx]
    else
      break
    end
  end

  return true
end

-- Clear all entities from octree
function SparseOctreeImpl:Clear(): ()
  table.clear(self.EntityMap)
  self.TotalEntities = 0
  self.Root.Entities = {}
  self.Root.Children = nil
  self.Root.TotalSubtreeCount = 0
end

-- Return total count of indexed entities
function SparseOctreeImpl:Count(): number
  return self.TotalEntities
end

return SparseOctreeImpl
