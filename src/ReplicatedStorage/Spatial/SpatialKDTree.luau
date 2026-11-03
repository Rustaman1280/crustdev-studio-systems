--!strict
--[[
  SpatialKDTree.luau
  crustdev studio systems - ReplicatedStorage/Spatial/SpatialKDTree

  High-performance 3-dimensional K-D Tree (k-d tree) spatial partitioning structure.
  Provides logarithmic O(log N) nearest-neighbor search, k-nearest neighbors (k-NN),
  spherical radius queries, and axis-aligned bounding box (AABB) volume queries in 3D.

  Features:
  - Exact 3D space partitioning cycling through X, Y, and Z axes.
  - Median-cut balanced tree construction for optimal search performance.
  - Dynamic incremental insertion and deletion with ID tracking.
  - Nearest Neighbor (NN) search with branch pruning.
  - K-Nearest Neighbors (k-NN) with bounded priority tracking.
  - Spherical radius search and AABB range search.
  - Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3

export type KDPoint = {
  Position: Vector3,
  Data: any,
  Id: string?,
}

export type SearchResult = {
  Position: Vector3,
  Data: any,
  Distance: number,
  Id: string?,
}

type KDNode = {
  Position: Vector3,
  Data: any,
  Id: string?,
  Axis: number, -- 1=X, 2=Y, 3=Z
  Left: KDNode?,
  Right: KDNode?,
}

export type SpatialKDTreeImpl = {
  __index: SpatialKDTreeImpl,
  new: (points: { KDPoint }?) -> SpatialKDTree,
  build: (points: { KDPoint }) -> SpatialKDTree,
  Insert: (self: SpatialKDTree, position: Vector3, data: any, id: string?) -> string,
  Remove: (self: SpatialKDTree, id: string) -> boolean,
  FindNearest: (self: SpatialKDTree, targetPos: Vector3, maxRadius: number?) -> (Vector3?, any, number?),
  FindKNearest: (self: SpatialKDTree, targetPos: Vector3, k: number, maxRadius: number?) -> { SearchResult },
  FindInRadius: (self: SpatialKDTree, centerPos: Vector3, radius: number) -> { SearchResult },
  FindInBox: (self: SpatialKDTree, minCorner: Vector3, maxCorner: Vector3) -> { SearchResult },
  GetCount: (self: SpatialKDTree) -> number,
  GetDepth: (self: SpatialKDTree) -> number,
  IsEmpty: (self: SpatialKDTree) -> boolean,
  Clear: (self: SpatialKDTree) -> (),
}

export type SpatialKDTree = typeof(setmetatable({} :: {
  _root: KDNode?,
  _count: number,
  _idMap: { [string]: KDNode },
  _idCounter: number,
}, {} :: SpatialKDTreeImpl))

local SpatialKDTree = {} :: SpatialKDTreeImpl
SpatialKDTree.__index = SpatialKDTree

local function getAxisCoord(pos: Vector3, axis: number): number
  if axis == 1 then
    return pos.X
  elseif axis == 2 then
    return pos.Y
  else
    return pos.Z
  end
end

local function nextAxis(axis: number): number
  if axis == 3 then
    return 1
  end
  return axis + 1
end

local function distSq(a: Vector3, b: Vector3): number
  local dx = a.X - b.X
  local dy = a.Y - b.Y
  local dz = a.Z - b.Z
  return dx * dx + dy * dy + dz * dz
end

-- Recursive median partition build
local function buildRecursive(points: { KDPoint }, depth: number, idMap: { [string]: KDNode }): KDNode?
  local count = #points
  if count == 0 then
    return nil
  end

  local axis = (depth % 3) + 1

  table.sort(points, function(a, b)
    return getAxisCoord(a.Position, axis) < getAxisCoord(b.Position, axis)
  end)

  local medianIndex = math.floor((count + 1) / 2)
  local medianPoint = points[medianIndex]

  local node: KDNode = {
    Position = medianPoint.Position,
    Data = medianPoint.Data,
    Id = medianPoint.Id,
    Axis = axis,
    Left = nil,
    Right = nil,
  }

  if node.Id then
    idMap[node.Id] = node
  end

  local leftPoints: { KDPoint } = {}
  for i = 1, medianIndex - 1 do
    table.insert(leftPoints, points[i])
  end

  local rightPoints: { KDPoint } = {}
  for i = medianIndex + 1, count do
    table.insert(rightPoints, points[i])
  end

  node.Left = buildRecursive(leftPoints, depth + 1, idMap)
  node.Right = buildRecursive(rightPoints, depth + 1, idMap)

  return node
end

function SpatialKDTree.new(points: { KDPoint }?): SpatialKDTree
  local self = setmetatable({
    _root = nil,
    _count = 0,
    _idMap = {},
    _idCounter = 0,
  }, SpatialKDTree)

  if points and #points > 0 then
    local pointCopies = {}
    for i, p in ipairs(points) do
      local assignedId = p.Id or string.format("node_%d", i)
      table.insert(pointCopies, {
        Position = p.Position,
        Data = p.Data,
        Id = assignedId,
      })
    end
    self._root = buildRecursive(pointCopies, 0, self._idMap)
    self._count = #pointCopies
    self._idCounter = #pointCopies
  end

  return self
end

function SpatialKDTree.build(points: { KDPoint }): SpatialKDTree
  return SpatialKDTree.new(points)
end

function SpatialKDTree:Insert(position: Vector3, data: any, id: string?): string
  self._idCounter += 1
  local assignedId = id or string.format("node_%d", self._idCounter)

  local newNode: KDNode = {
    Position = position,
    Data = data,
    Id = assignedId,
    Axis = 1,
    Left = nil,
    Right = nil,
  }

  self._idMap[assignedId] = newNode
  self._count += 1

  if not self._root then
    newNode.Axis = 1
    self._root = newNode
    return assignedId
  end

  local current = self._root
  local axis = 1

  while true do
    local currentCoord = getAxisCoord(current.Position, axis)
    local insertCoord = getAxisCoord(position, axis)
    local nAxis = nextAxis(axis)

    if insertCoord < currentCoord then
      if current.Left == nil then
        newNode.Axis = nAxis
        current.Left = newNode
        break
      else
        current = current.Left
        axis = nAxis
      end
    else
      if current.Right == nil then
        newNode.Axis = nAxis
        current.Right = newNode
        break
      else
        current = current.Right
        axis = nAxis
      end
    end
  end

  return assignedId
end

-- Find minimum node along target dimension
local function findMin(node: KDNode?, targetDim: number, currentDim: number): KDNode?
  if not node then
    return nil
  end

  local nextDim = nextAxis(currentDim)

  if currentDim == targetDim then
    if not node.Left then
      return node
    end
    return findMin(node.Left, targetDim, nextDim)
  end

  local leftMin = findMin(node.Left, targetDim, nextDim)
  local rightMin = findMin(node.Right, targetDim, nextDim)
  local minNode = node

  if leftMin and getAxisCoord(leftMin.Position, targetDim) < getAxisCoord(minNode.Position, targetDim) then
    minNode = leftMin
  end
  if rightMin and getAxisCoord(rightMin.Position, targetDim) < getAxisCoord(minNode.Position, targetDim) then
    minNode = rightMin
  end

  return minNode
end

-- Recursive node removal
local function deleteRecursive(node: KDNode?, targetId: string, currentDim: number): (KDNode?, boolean)
  if not node then
    return nil, false
  end

  local nextDim = nextAxis(currentDim)

  if node.Id == targetId then
    if node.Right then
      local minRight = findMin(node.Right, currentDim, nextDim)
      if minRight then
        node.Position = minRight.Position
        node.Data = minRight.Data
        node.Id = minRight.Id
        local newRight, _ = deleteRecursive(node.Right, minRight.Id :: string, nextDim)
        node.Right = newRight
        return node, true
      end
    elseif node.Left then
      local minLeft = findMin(node.Left, currentDim, nextDim)
      if minLeft then
        node.Position = minLeft.Position
        node.Data = minLeft.Data
        node.Id = minLeft.Id
        local newRight, _ = deleteRecursive(node.Left, minLeft.Id :: string, nextDim)
        node.Right = newRight
        node.Left = nil
        return node, true
      end
    else
      return nil, true
    end
  end

  local leftChild, leftRemoved = deleteRecursive(node.Left, targetId, nextDim)
  if leftRemoved then
    node.Left = leftChild
    return node, true
  end

  local rightChild, rightRemoved = deleteRecursive(node.Right, targetId, nextDim)
  if rightRemoved then
    node.Right = rightChild
    return node, true
  end

  return node, false
end

function SpatialKDTree:Remove(id: string): boolean
  if not self._idMap[id] or not self._root then
    return false
  end

  local newRoot, removed = deleteRecursive(self._root, id, 1)
  if removed then
    self._root = newRoot
    self._idMap[id] = nil
    self._count -= 1
    return true
  end

  return false
end

function SpatialKDTree:FindNearest(targetPos: Vector3, maxRadius: number?): (Vector3?, any, number?)
  if not self._root then
    return nil, nil, nil
  end

  local maxDistSq = maxRadius and (maxRadius * maxRadius) or math.huge
  local bestNode: KDNode? = nil
  local bestDistSq = maxDistSq

  local function searchNearest(node: KDNode?, currentDim: number)
    if not node then
      return
    end

    local dSq = distSq(node.Position, targetPos)
    if dSq < bestDistSq then
      bestDistSq = dSq
      bestNode = node
    end

    local nextDim = nextAxis(currentDim)
    local axisDiff = getAxisCoord(targetPos, currentDim) - getAxisCoord(node.Position, currentDim)
    local axisDiffSq = axisDiff * axisDiff

    local nearChild = if axisDiff < 0 then node.Left else node.Right
    local farChild = if axisDiff < 0 then node.Right else node.Left

    searchNearest(nearChild, nextDim)

    if axisDiffSq < bestDistSq then
      searchNearest(farChild, nextDim)
    end
  end

  searchNearest(self._root, 1)

  if bestNode then
    return bestNode.Position, bestNode.Data, math.sqrt(bestDistSq)
  end

  return nil, nil, nil
end

function SpatialKDTree:FindKNearest(targetPos: Vector3, k: number, maxRadius: number?): { SearchResult }
  if not self._root or k <= 0 then
    return {}
  end

  local maxDistSq = maxRadius and (maxRadius * maxRadius) or math.huge
  local heap: { { node: KDNode, distSq: number } } = {}

  local function insertHeap(node: KDNode, dSq: number)
    if #heap < k then
      table.insert(heap, { node = node, distSq = dSq })
      table.sort(heap, function(a, b)
        return a.distSq < b.distSq
      end)
    else
      if dSq < heap[#heap].distSq then
        heap[#heap] = { node = node, distSq = dSq }
        table.sort(heap, function(a, b)
          return a.distSq < b.distSq
        end)
      end
    end
  end

  local function searchK(node: KDNode?, currentDim: number)
    if not node then
      return
    end

    local dSq = distSq(node.Position, targetPos)
    if dSq <= maxDistSq then
      if #heap < k or dSq < heap[#heap].distSq then
        insertHeap(node, dSq)
      end
    end

    local nextDim = nextAxis(currentDim)
    local axisDiff = getAxisCoord(targetPos, currentDim) - getAxisCoord(node.Position, currentDim)
    local axisDiffSq = axisDiff * axisDiff

    local nearChild = if axisDiff < 0 then node.Left else node.Right
    local farChild = if axisDiff < 0 then node.Right else node.Left

    searchK(nearChild, nextDim)

    local currentWorstDistSq = if #heap >= k then heap[#heap].distSq else maxDistSq
    if axisDiffSq < currentWorstDistSq then
      searchK(farChild, nextDim)
    end
  end

  searchK(self._root, 1)

  local results: { SearchResult } = {}
  for _, entry in ipairs(heap) do
    table.insert(results, {
      Position = entry.node.Position,
      Data = entry.node.Data,
      Distance = math.sqrt(entry.distSq),
      Id = entry.node.Id,
    })
  end

  return results
end

function SpatialKDTree:FindInRadius(centerPos: Vector3, radius: number): { SearchResult }
  if not self._root or radius < 0 then
    return {}
  end

  local radSq = radius * radius
  local results: { SearchResult } = {}

  local function searchRadius(node: KDNode?, currentDim: number)
    if not node then
      return
    end

    local dSq = distSq(node.Position, centerPos)
    if dSq <= radSq then
      table.insert(results, {
        Position = node.Position,
        Data = node.Data,
        Distance = math.sqrt(dSq),
        Id = node.Id,
      })
    end

    local nextDim = nextAxis(currentDim)
    local axisDiff = getAxisCoord(centerPos, currentDim) - getAxisCoord(node.Position, currentDim)

    if axisDiff - radius <= 0 then
      searchRadius(node.Left, nextDim)
    end
    if axisDiff + radius >= 0 then
      searchRadius(node.Right, nextDim)
    end
  end

  searchRadius(self._root, 1)

  table.sort(results, function(a, b)
    return a.Distance < b.Distance
  end)

  return results
end

function SpatialKDTree:FindInBox(minCorner: Vector3, maxCorner: Vector3): { SearchResult }
  if not self._root then
    return {}
  end

  local minX = math.min(minCorner.X, maxCorner.X)
  local maxX = math.max(minCorner.X, maxCorner.X)
  local minY = math.min(minCorner.Y, maxCorner.Y)
  local maxY = math.max(minCorner.Y, maxCorner.Y)
  local minZ = math.min(minCorner.Z, maxCorner.Z)
  local maxZ = math.max(minCorner.Z, maxCorner.Z)

  local results: { SearchResult } = {}

  local function searchBox(node: KDNode?, currentDim: number)
    if not node then
      return
    end

    local px = node.Position.X
    local py = node.Position.Y
    local pz = node.Position.Z

    if px >= minX and px <= maxX and py >= minY and py <= maxY and pz >= minZ and pz <= maxZ then
      table.insert(results, {
        Position = node.Position,
        Data = node.Data,
        Distance = 0,
        Id = node.Id,
      })
    end

    local nextDim = nextAxis(currentDim)
    local coord = getAxisCoord(node.Position, currentDim)
    local minCoord = if currentDim == 1 then minX elseif currentDim == 2 then minY else minZ
    local maxCoord = if currentDim == 1 then maxX elseif currentDim == 2 then maxY else maxZ

    if minCoord <= coord then
      searchBox(node.Left, nextDim)
    end
    if maxCoord >= coord then
      searchBox(node.Right, nextDim)
    end
  end

  searchBox(self._root, 1)
  return results
end

function SpatialKDTree:GetCount(): number
  return self._count
end

local function computeDepth(node: KDNode?): number
  if not node then
    return 0
  end
  local ld = computeDepth(node.Left)
  local rd = computeDepth(node.Right)
  return 1 + math.max(ld, rd)
end

function SpatialKDTree:GetDepth(): number
  return computeDepth(self._root)
end

function SpatialKDTree:IsEmpty(): boolean
  return self._count == 0
end

function SpatialKDTree:Clear()
  self._root = nil
  self._count = 0
  self._idMap = {}
  self._idCounter = 0
end

return SpatialKDTree
