--!strict
--[[
  DynamicBVH.luau
  crustdev studio systems - ReplicatedStorage/Spatial/DynamicBVH

  High-performance Dynamic Bounding Volume Hierarchy (Dynamic AABB Tree) with Surface Area
  Heuristic (SAH) bottom-up insertion, AVL tree rotations, loose node fattening, and
  fast slab-test raycasting.

  Features:
  - 3D Axis-Aligned Bounding Box (AABB) arithmetic with volume, surface area, and Ray-Slab intersection.
  - O(log N) dynamic insertion using Surface Area Heuristic (SAH) cost evaluation.
  - Self-balancing via AVL tree rotations (LL, LR, RR, RL) to maintain logarithmic query depth.
  - Loose bounding boxes (node fattening with velocity lookahead) to eliminate tree thrashing
    for moving entities.
  - Stack-based Raycast traversal with branch pruning and closest-hit bounding distance shrinking.
  - Frustum/AABB range queries and spherical overlap detection.
  - Broadphase collision detection via recursive self-tree dual traversal (FindOverlappingPairs).
  - Node pool with free-list recycling for zero GC churn in high-cadence game loops.
  - Fully compatible with Roblox Engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3

local EPSILON = 1e-6
local DEFAULT_FATTEN_MARGIN = 0.5

-- Axis-Aligned Bounding Box structure
export type AABB = {
  Min: Vector3,
  Max: Vector3,
}

local function newAABB(minCorner: Vector3, maxCorner: Vector3): AABB
  return {
    Min = Vector3.new(
      math.min(minCorner.X, maxCorner.X),
      math.min(minCorner.Y, maxCorner.Y),
      math.min(minCorner.Z, maxCorner.Z)
    ),
    Max = Vector3.new(
      math.max(minCorner.X, maxCorner.X),
      math.max(minCorner.Y, maxCorner.Y),
      math.max(minCorner.Z, maxCorner.Z)
    ),
  }
end

local function fromCenterExtents(center: Vector3, halfExtents: Vector3): AABB
  local absExt = Vector3.new(math.abs(halfExtents.X), math.abs(halfExtents.Y), math.abs(halfExtents.Z))
  return {
    Min = center - absExt,
    Max = center + absExt,
  }
end

local function aabbUnion(a: AABB, b: AABB): AABB
  return {
    Min = Vector3.new(
      math.min(a.Min.X, b.Min.X),
      math.min(a.Min.Y, b.Min.Y),
      math.min(a.Min.Z, b.Min.Z)
    ),
    Max = Vector3.new(
      math.max(a.Max.X, b.Max.X),
      math.max(a.Max.Y, b.Max.Y),
      math.max(a.Max.Z, b.Max.Z)
    ),
  }
end

local function aabbSurfaceArea(box: AABB): number
  local d = box.Max - box.Min
  return 2 * (d.X * d.Y + d.Y * d.Z + d.Z * d.X)
end

local function aabbContainsPoint(box: AABB, p: Vector3): boolean
  return p.X >= box.Min.X and p.X <= box.Max.X
    and p.Y >= box.Min.Y and p.Y <= box.Max.Y
    and p.Z >= box.Min.Z and p.Z <= box.Max.Z
end

local function aabbContainsAABB(outer: AABB, inner: AABB): boolean
  return inner.Min.X >= outer.Min.X and inner.Max.X <= outer.Max.X
    and inner.Min.Y >= outer.Min.Y and inner.Max.Y <= outer.Max.Y
    and inner.Min.Z >= outer.Min.Z and inner.Max.Z <= outer.Max.Z
end

local function aabbIntersectsAABB(a: AABB, b: AABB): boolean
  if a.Max.X < b.Min.X or a.Min.X > b.Max.X then return false end
  if a.Max.Y < b.Min.Y or a.Min.Y > b.Max.Y then return false end
  if a.Max.Z < b.Min.Z or a.Min.Z > b.Max.Z then return false end
  return true
end

local function aabbFatten(box: AABB, margin: number, velocity: Vector3?): AABB
  local m = Vector3.new(margin, margin, margin)
  local minC = box.Min - m
  local maxC = box.Max + m

  if velocity then
    if velocity.X < 0 then
      minC = Vector3.new(minC.X + velocity.X, minC.Y, minC.Z)
    else
      maxC = Vector3.new(maxC.X + velocity.X, maxC.Y, maxC.Z)
    end
    if velocity.Y < 0 then
      minC = Vector3.new(minC.X, minC.Y + velocity.Y, minC.Z)
    else
      maxC = Vector3.new(maxC.X, maxC.Y + velocity.Y, maxC.Z)
    end
    if velocity.Z < 0 then
      minC = Vector3.new(minC.X, minC.Y, minC.Z + velocity.Z)
    else
      maxC = Vector3.new(maxC.X, maxC.Y, maxC.Z + velocity.Z)
    end
  end

  return { Min = minC, Max = maxC }
end

-- Kay-Kajiya slab raycast test with surface normal evaluation
local function aabbRaycast(box: AABB, origin: Vector3, dir: Vector3, maxDistance: number?): (boolean, number?, Vector3?)
  local maxDist = maxDistance or math.huge
  local tMin = 0.0
  local tMax = maxDist
  local normal = Vector3.new(0, 0, 0)

  -- Axis X
  if math.abs(dir.X) < EPSILON then
    if origin.X < box.Min.X or origin.X > box.Max.X then
      return false, nil, nil
    end
  else
    local invD = 1.0 / dir.X
    local t1 = (box.Min.X - origin.X) * invD
    local t2 = (box.Max.X - origin.X) * invD
    local sign = -1
    if t1 > t2 then
      t1, t2 = t2, t1
      sign = 1
    end
    if t1 > tMin then
      tMin = t1
      normal = Vector3.new(sign, 0, 0)
    end
    tMax = math.min(tMax, t2)
    if tMin > tMax then return false, nil, nil end
  end

  -- Axis Y
  if math.abs(dir.Y) < EPSILON then
    if origin.Y < box.Min.Y or origin.Y > box.Max.Y then
      return false, nil, nil
    end
  else
    local invD = 1.0 / dir.Y
    local t1 = (box.Min.Y - origin.Y) * invD
    local t2 = (box.Max.Y - origin.Y) * invD
    local sign = -1
    if t1 > t2 then
      t1, t2 = t2, t1
      sign = 1
    end
    if t1 > tMin then
      tMin = t1
      normal = Vector3.new(0, sign, 0)
    end
    tMax = math.min(tMax, t2)
    if tMin > tMax then return false, nil, nil end
  end

  -- Axis Z
  if math.abs(dir.Z) < EPSILON then
    if origin.Z < box.Min.Z or origin.Z > box.Max.Z then
      return false, nil, nil
    end
  else
    local invD = 1.0 / dir.Z
    local t1 = (box.Min.Z - origin.Z) * invD
    local t2 = (box.Max.Z - origin.Z) * invD
    local sign = -1
    if t1 > t2 then
      t1, t2 = t2, t1
      sign = 1
    end
    if t1 > tMin then
      tMin = t1
      normal = Vector3.new(0, 0, sign)
    end
    tMax = math.min(tMax, t2)
    if tMin > tMax then return false, nil, nil end
  end

  return true, tMin, normal
end

export type RaycastHit = {
  Id: string,
  UserData: any,
  Position: Vector3,
  Normal: Vector3,
  Distance: number,
  AABB: AABB,
}

export type QueryResult = {
  Id: string,
  UserData: any,
  AABB: AABB,
}

export type OverlappingPair = {
  IdA: string,
  IdB: string,
  UserDataA: any,
  UserDataB: any,
}

type BVHNode = {
  Id: string?,
  UserData: any,
  AABB: AABB,
  Parent: number,
  Left: number,
  Right: number,
  Height: number,
  IsLeaf: boolean,
  NextFree: number,
}

export type DynamicBVHImpl = {
  __index: DynamicBVHImpl,
  new: (fattenMargin: number?) -> DynamicBVH,
  AABB: {
    new: (min: Vector3, max: Vector3) -> AABB,
    fromCenterExtents: (center: Vector3, halfExtents: Vector3) -> AABB,
    Union: (a: AABB, b: AABB) -> AABB,
    SurfaceArea: (box: AABB) -> number,
    ContainsPoint: (box: AABB, p: Vector3) -> boolean,
    ContainsAABB: (outer: AABB, inner: AABB) -> boolean,
    IntersectsAABB: (a: AABB, b: AABB) -> boolean,
    Raycast: (box: AABB, origin: Vector3, dir: Vector3, maxDist: number?) -> (boolean, number?, Vector3?),
  },
  Insert: (self: DynamicBVH, id: string, aabb: AABB, userData: any) -> string,
  Remove: (self: DynamicBVH, id: string) -> boolean,
  Update: (self: DynamicBVH, id: string, newAABB: AABB, velocity: Vector3?) -> boolean,
  GetAABB: (self: DynamicBVH, id: string) -> AABB?,
  Raycast: (self: DynamicBVH, origin: Vector3, direction: Vector3, maxDistance: number?, filterFn: ((id: string, userData: any) -> boolean)?) -> RaycastHit?,
  RaycastAll: (self: DynamicBVH, origin: Vector3, direction: Vector3, maxDistance: number?) -> { RaycastHit },
  QueryAABB: (self: DynamicBVH, queryBox: AABB, filterFn: ((id: string, userData: any) -> boolean)?) -> { QueryResult },
  QuerySphere: (self: DynamicBVH, center: Vector3, radius: number) -> { QueryResult },
  FindOverlappingPairs: (self: DynamicBVH) -> { OverlappingPair },
  GetLeafCount: (self: DynamicBVH) -> number,
  GetNodeCount: (self: DynamicBVH) -> number,
  GetDepth: (self: DynamicBVH) -> number,
  ValidateTree: (self: DynamicBVH) -> boolean,
  Clear: (self: DynamicBVH) -> (),
}

export type DynamicBVH = typeof(setmetatable({} :: {
  _nodes: { BVHNode },
  _root: number,
  _freeList: number,
  _leafMap: { [string]: number },
  _leafCount: number,
  _nodeCount: number,
  _fattenMargin: number,
}, {} :: DynamicBVHImpl))

local DynamicBVH = {} :: DynamicBVHImpl
DynamicBVH.__index = DynamicBVH

DynamicBVH.AABB = {
  new = newAABB,
  fromCenterExtents = fromCenterExtents,
  Union = aabbUnion,
  SurfaceArea = aabbSurfaceArea,
  ContainsPoint = aabbContainsPoint,
  ContainsAABB = aabbContainsAABB,
  IntersectsAABB = aabbIntersectsAABB,
  Raycast = aabbRaycast,
}

local NULL_INDEX = 0

local function allocateNode(self: DynamicBVH): number
  local index: number
  if self._freeList ~= NULL_INDEX then
    index = self._freeList
    self._freeList = self._nodes[index].NextFree
  else
    table.insert(self._nodes, {
      Id = nil,
      UserData = nil,
      AABB = { Min = Vector3.new(0, 0, 0), Max = Vector3.new(0, 0, 0) },
      Parent = NULL_INDEX,
      Left = NULL_INDEX,
      Right = NULL_INDEX,
      Height = 0,
      IsLeaf = false,
      NextFree = NULL_INDEX,
    })
    index = #self._nodes
  end

  local node = self._nodes[index]
  node.Parent = NULL_INDEX
  node.Left = NULL_INDEX
  node.Right = NULL_INDEX
  node.Height = 0
  node.IsLeaf = false
  node.NextFree = NULL_INDEX
  self._nodeCount += 1
  return index
end

local function freeNode(self: DynamicBVH, index: number)
  local node = self._nodes[index]
  node.Id = nil
  node.UserData = nil
  node.Parent = NULL_INDEX
  node.Left = NULL_INDEX
  node.Right = NULL_INDEX
  node.Height = -1
  node.IsLeaf = false
  node.NextFree = self._freeList
  self._freeList = index
  self._nodeCount -= 1
end

-- AVL tree balance rotation
local function balance(self: DynamicBVH, iA: number): number
  local A = self._nodes[iA]
  if A.IsLeaf or A.Height < 2 then
    return iA
  end

  local iB = A.Left
  local iC = A.Right
  local B = self._nodes[iB]
  local C = self._nodes[iC]

  local balanceFactor = C.Height - B.Height

  -- Rotate C up (Right heavy)
  if balanceFactor > 1 then
    local iF = C.Left
    local iG = C.Right
    local F = self._nodes[iF]
    local G = self._nodes[iG]

    C.Left = iA
    C.Parent = A.Parent

    if A.Parent ~= NULL_INDEX then
      if self._nodes[A.Parent].Left == iA then
        self._nodes[A.Parent].Left = iC
      else
        self._nodes[A.Parent].Right = iC
      end
    else
      self._root = iC
    end
    A.Parent = iC

    -- Rotate
    if F.Height > G.Height then
      C.Right = iF
      A.Right = iG
      G.Parent = iA
      A.AABB = aabbUnion(B.AABB, G.AABB)
      C.AABB = aabbUnion(A.AABB, F.AABB)

      A.Height = 1 + math.max(B.Height, G.Height)
      C.Height = 1 + math.max(A.Height, F.Height)
    else
      C.Right = iG
      A.Right = iF
      F.Parent = iA
      A.AABB = aabbUnion(B.AABB, F.AABB)
      C.AABB = aabbUnion(A.AABB, G.AABB)

      A.Height = 1 + math.max(B.Height, F.Height)
      C.Height = 1 + math.max(A.Height, G.Height)
    end

    return iC
  end

  -- Rotate B up (Left heavy)
  if balanceFactor < -1 then
    local iD = B.Left
    local iE = B.Right
    local D = self._nodes[iD]
    local E = self._nodes[iE]

    B.Left = iA
    B.Parent = A.Parent

    if A.Parent ~= NULL_INDEX then
      if self._nodes[A.Parent].Left == iA then
        self._nodes[A.Parent].Left = iB
      else
        self._nodes[A.Parent].Right = iB
      end
    else
      self._root = iB
    end
    A.Parent = iB

    -- Rotate
    if D.Height > E.Height then
      B.Right = iD
      A.Left = iE
      E.Parent = iA
      A.AABB = aabbUnion(C.AABB, E.AABB)
      B.AABB = aabbUnion(A.AABB, D.AABB)

      A.Height = 1 + math.max(C.Height, E.Height)
      B.Height = 1 + math.max(A.Height, D.Height)
    else
      B.Right = iE
      A.Left = iD
      D.Parent = iA
      A.AABB = aabbUnion(C.AABB, D.AABB)
      B.AABB = aabbUnion(A.AABB, E.AABB)

      A.Height = 1 + math.max(C.Height, D.Height)
      B.Height = 1 + math.max(A.Height, E.Height)
    end

    return iB
  end

  return iA
end

local function insertLeaf(self: DynamicBVH, leaf: number)
  if self._root == NULL_INDEX then
    self._root = leaf
    self._nodes[leaf].Parent = NULL_INDEX
    return
  end

  -- Stage 1: Surface Area Heuristic (SAH) best sibling search
  local leafAABB = self._nodes[leaf].AABB
  local index = self._root

  while not self._nodes[index].IsLeaf do
    local node = self._nodes[index]
    local left = node.Left
    local right = node.Right

    local area = aabbSurfaceArea(node.AABB)
    local combinedArea = aabbSurfaceArea(aabbUnion(node.AABB, leafAABB))
    local cost = 2 * combinedArea
    local inheritanceCost = 2 * (combinedArea - area)

    -- Left child cost
    local costLeft: number
    local leftNode = self._nodes[left]
    if leftNode.IsLeaf then
      costLeft = aabbSurfaceArea(aabbUnion(leftNode.AABB, leafAABB)) + inheritanceCost
    else
      local oldArea = aabbSurfaceArea(leftNode.AABB)
      local newArea = aabbSurfaceArea(aabbUnion(leftNode.AABB, leafAABB))
      costLeft = (newArea - oldArea) + inheritanceCost
    end

    -- Right child cost
    local costRight: number
    local rightNode = self._nodes[right]
    if rightNode.IsLeaf then
      costRight = aabbSurfaceArea(aabbUnion(rightNode.AABB, leafAABB)) + inheritanceCost
    else
      local oldArea = aabbSurfaceArea(rightNode.AABB)
      local newArea = aabbSurfaceArea(aabbUnion(rightNode.AABB, leafAABB))
      costRight = (newArea - oldArea) + inheritanceCost
    end

    -- Descend according to lowest cost
    if cost < costLeft and cost < costRight then
      break
    end

    if costLeft < costRight then
      index = left
    else
      index = right
    end
  end

  local sibling = index

  -- Stage 2: Create new internal parent
  local oldParent = self._nodes[sibling].Parent
  local newParent = allocateNode(self)
  local npNode = self._nodes[newParent]
  npNode.Parent = oldParent
  npNode.UserData = nil
  npNode.AABB = aabbUnion(leafAABB, self._nodes[sibling].AABB)
  npNode.Height = self._nodes[sibling].Height + 1
  npNode.IsLeaf = false

  if oldParent ~= NULL_INDEX then
    if self._nodes[oldParent].Left == sibling then
      self._nodes[oldParent].Left = newParent
    else
      self._nodes[oldParent].Right = newParent
    end
    npNode.Left = sibling
    npNode.Right = leaf
    self._nodes[sibling].Parent = newParent
    self._nodes[leaf].Parent = newParent
  else
    npNode.Left = sibling
    npNode.Right = leaf
    self._nodes[sibling].Parent = newParent
    self._nodes[leaf].Parent = newParent
    self._root = newParent
  end

  -- Stage 3: Walk up tree refitting AABBs and balancing
  index = self._nodes[leaf].Parent
  while index ~= NULL_INDEX do
    index = balance(self, index)

    local curr = self._nodes[index]
    local left = curr.Left
    local right = curr.Right

    curr.Height = 1 + math.max(self._nodes[left].Height, self._nodes[right].Height)
    curr.AABB = aabbUnion(self._nodes[left].AABB, self._nodes[right].AABB)

    index = curr.Parent
  end
end

local function removeLeaf(self: DynamicBVH, leaf: number)
  if leaf == self._root then
    self._root = NULL_INDEX
    return
  end

  local parent = self._nodes[leaf].Parent
  local grandParent = self._nodes[parent].Parent
  local sibling = if self._nodes[parent].Left == leaf then self._nodes[parent].Right else self._nodes[parent].Left

  if grandParent ~= NULL_INDEX then
    if self._nodes[grandParent].Left == parent then
      self._nodes[grandParent].Left = sibling
    else
      self._nodes[grandParent].Right = sibling
    end
    self._nodes[sibling].Parent = grandParent
    freeNode(self, parent)

    -- Walk back up and refit
    local index = grandParent
    while index ~= NULL_INDEX do
      index = balance(self, index)
      local curr = self._nodes[index]
      local left = curr.Left
      local right = curr.Right

      curr.AABB = aabbUnion(self._nodes[left].AABB, self._nodes[right].AABB)
      curr.Height = 1 + math.max(self._nodes[left].Height, self._nodes[right].Height)

      index = curr.Parent
    end
  else
    self._root = sibling
    self._nodes[sibling].Parent = NULL_INDEX
    freeNode(self, parent)
  end
end

function DynamicBVH.new(fattenMargin: number?): DynamicBVH
  local self = setmetatable({
    _nodes = {},
    _root = NULL_INDEX,
    _freeList = NULL_INDEX,
    _leafMap = {},
    _leafCount = 0,
    _nodeCount = 0,
    _fattenMargin = fattenMargin or DEFAULT_FATTEN_MARGIN,
  }, DynamicBVH)

  return self
end

function DynamicBVH:Insert(id: string, aabb: AABB, userData: any): string
  assert(self._leafMap[id] == nil, "Leaf with ID already exists in BVH: " .. tostring(id))

  local nodeIndex = allocateNode(self)
  local node = self._nodes[nodeIndex]
  node.Id = id
  node.UserData = userData
  node.AABB = aabbFatten(aabb, self._fattenMargin, nil)
  node.Height = 0
  node.IsLeaf = true

  insertLeaf(self, nodeIndex)

  self._leafMap[id] = nodeIndex
  self._leafCount += 1

  return id
end

function DynamicBVH:Remove(id: string): boolean
  local nodeIndex = self._leafMap[id]
  if not nodeIndex then
    return false
  end

  removeLeaf(self, nodeIndex)
  freeNode(self, nodeIndex)

  self._leafMap[id] = nil
  self._leafCount -= 1
  return true
end

function DynamicBVH:Update(id: string, newAABB: AABB, velocity: Vector3?): boolean
  local nodeIndex = self._leafMap[id]
  if not nodeIndex then
    return false
  end

  local node = self._nodes[nodeIndex]
  -- Fast path: if newly proposed AABB is still within the fattened loose bounds, no-op!
  if aabbContainsAABB(node.AABB, newAABB) then
    return false
  end

  removeLeaf(self, nodeIndex)
  node.AABB = aabbFatten(newAABB, self._fattenMargin, velocity)
  insertLeaf(self, nodeIndex)

  return true
end

function DynamicBVH:GetAABB(id: string): AABB?
  local nodeIndex = self._leafMap[id]
  if not nodeIndex then
    return nil
  end
  return self._nodes[nodeIndex].AABB
end

-- Raycast traversal with nearest hit distance pruning
function DynamicBVH:Raycast(
  origin: Vector3,
  direction: Vector3,
  maxDistance: number?,
  filterFn: ((id: string, userData: any) -> boolean)?
): RaycastHit?
  if self._root == NULL_INDEX then
    return nil
  end

  local dir = direction.Unit
  local closestDist = maxDistance or math.huge
  local closestHit: RaycastHit? = nil

  local stack: { number } = { self._root }
  local stackPtr = 1

  while stackPtr > 0 do
    local nodeIdx = stack[stackPtr]
    stackPtr -= 1

    local node = self._nodes[nodeIdx]
    local hit, tDist, normal = aabbRaycast(node.AABB, origin, dir, closestDist)

    if hit and tDist and tDist <= closestDist then
      if node.IsLeaf then
        local id = node.Id :: string
        local passes = if filterFn then filterFn(id, node.UserData) else true
        if passes and tDist < closestDist then
          closestDist = tDist
          closestHit = {
            Id = id,
            UserData = node.UserData,
            Position = origin + dir * tDist,
            Normal = normal or Vector3.new(0, 1, 0),
            Distance = tDist,
            AABB = node.AABB,
          }
        end
      else
        stackPtr += 1
        stack[stackPtr] = node.Left
        stackPtr += 1
        stack[stackPtr] = node.Right
      end
    end
  end

  return closestHit
end

function DynamicBVH:RaycastAll(origin: Vector3, direction: Vector3, maxDistance: number?): { RaycastHit }
  if self._root == NULL_INDEX then
    return {}
  end

  local dir = direction.Unit
  local maxDist = maxDistance or math.huge
  local hits: { RaycastHit } = {}

  local stack: { number } = { self._root }
  local stackPtr = 1

  while stackPtr > 0 do
    local nodeIdx = stack[stackPtr]
    stackPtr -= 1

    local node = self._nodes[nodeIdx]
    local hit, tDist, normal = aabbRaycast(node.AABB, origin, dir, maxDist)

    if hit and tDist and tDist <= maxDist then
      if node.IsLeaf then
        table.insert(hits, {
          Id = node.Id :: string,
          UserData = node.UserData,
          Position = origin + dir * tDist,
          Normal = normal or Vector3.new(0, 1, 0),
          Distance = tDist,
          AABB = node.AABB,
        })
      else
        stackPtr += 1
        stack[stackPtr] = node.Left
        stackPtr += 1
        stack[stackPtr] = node.Right
      end
    end
  end

  table.sort(hits, function(a, b)
    return a.Distance < b.Distance
  end)

  return hits
end

function DynamicBVH:QueryAABB(queryBox: AABB, filterFn: ((id: string, userData: any) -> boolean)?): { QueryResult }
  if self._root == NULL_INDEX then
    return {}
  end

  local results: { QueryResult } = {}
  local stack: { number } = { self._root }
  local stackPtr = 1

  while stackPtr > 0 do
    local nodeIdx = stack[stackPtr]
    stackPtr -= 1

    local node = self._nodes[nodeIdx]
    if aabbIntersectsAABB(node.AABB, queryBox) then
      if node.IsLeaf then
        local id = node.Id :: string
        local passes = if filterFn then filterFn(id, node.UserData) else true
        if passes then
          table.insert(results, {
            Id = id,
            UserData = node.UserData,
            AABB = node.AABB,
          })
        end
      else
        stackPtr += 1
        stack[stackPtr] = node.Left
        stackPtr += 1
        stack[stackPtr] = node.Right
      end
    end
  end

  return results
end

function DynamicBVH:QuerySphere(center: Vector3, radius: number): { QueryResult }
  local rVec = Vector3.new(radius, radius, radius)
  local sphereAABB: AABB = {
    Min = center - rVec,
    Max = center + rVec,
  }

  local candidateBoxes = self:QueryAABB(sphereAABB)
  local finalResults: { QueryResult } = {}
  local rSq = radius * radius

  for _, res in ipairs(candidateBoxes) do
    -- Closest point on AABB to sphere center
    local box = res.AABB
    local cX = math.clamp(center.X, box.Min.X, box.Max.X)
    local cY = math.clamp(center.Y, box.Min.Y, box.Max.Y)
    local cZ = math.clamp(center.Z, box.Min.Z, box.Max.Z)
    local dx = center.X - cX
    local dy = center.Y - cY
    local dz = center.Z - cZ
    local distSq = dx * dx + dy * dy + dz * dz

    if distSq <= rSq then
      table.insert(finalResults, res)
    end
  end

  return finalResults
end

-- Dual-tree broadphase traversal to detect all overlapping pairs
function DynamicBVH:FindOverlappingPairs(): { OverlappingPair }
  if self._root == NULL_INDEX or self._nodes[self._root].IsLeaf then
    return {}
  end

  local pairsList: { OverlappingPair } = {}
  local seenPairs: { [string]: boolean } = {}

  local function collide(iA: number, iB: number)
    if iA == NULL_INDEX or iB == NULL_INDEX or iA == iB then
      return
    end

    local nA = self._nodes[iA]
    local nB = self._nodes[iB]

    if not aabbIntersectsAABB(nA.AABB, nB.AABB) then
      return
    end

    if nA.IsLeaf and nB.IsLeaf then
      local idA = nA.Id :: string
      local idB = nB.Id :: string
      local key = if idA < idB then (idA .. ":" .. idB) else (idB .. ":" .. idA)
      if not seenPairs[key] then
        seenPairs[key] = true
        table.insert(pairsList, {
          IdA = idA,
          IdB = idB,
          UserDataA = nA.UserData,
          UserDataB = nB.UserData,
        })
      end
      return
    end

    if nA.IsLeaf then
      collide(iA, nB.Left)
      collide(iA, nB.Right)
    elseif nB.IsLeaf then
      collide(nA.Left, iB)
      collide(nA.Right, iB)
    else
      -- Descend the node with larger surface area
      local areaA = aabbSurfaceArea(nA.AABB)
      local areaB = aabbSurfaceArea(nB.AABB)
      if areaA > areaB then
        collide(nA.Left, iB)
        collide(nA.Right, iB)
      else
        collide(iA, nB.Left)
        collide(iA, nB.Right)
      end
    end
  end

  local function collideSelf(nodeIdx: number)
    if nodeIdx == NULL_INDEX or self._nodes[nodeIdx].IsLeaf then
      return
    end
    local node = self._nodes[nodeIdx]
    collide(node.Left, node.Right)
    collideSelf(node.Left)
    collideSelf(node.Right)
  end

  collideSelf(self._root)

  return pairsList
end

function DynamicBVH:GetLeafCount(): number
  return self._leafCount
end

function DynamicBVH:GetNodeCount(): number
  return self._nodeCount
end

function DynamicBVH:GetDepth(): number
  if self._root == NULL_INDEX then
    return 0
  end
  return self._nodes[self._root].Height
end

-- Validates tree invariants: parent pointers, heights, and AABB containment
function DynamicBVH:ValidateTree(): boolean
  if self._root == NULL_INDEX then
    return true
  end

  local function validateNode(index: number): boolean
    local node = self._nodes[index]
    if node.IsLeaf then
      assert(node.Height == 0, "Leaf node must have height 0")
      assert(node.Left == NULL_INDEX and node.Right == NULL_INDEX, "Leaf cannot have children")
      return true
    end

    local left = node.Left
    local right = node.Right
    assert(left ~= NULL_INDEX and right ~= NULL_INDEX, "Internal node must have both children")
    assert(self._nodes[left].Parent == index, "Left child parent mismatch")
    assert(self._nodes[right].Parent == index, "Right child parent mismatch")

    local expectedHeight = 1 + math.max(self._nodes[left].Height, self._nodes[right].Height)
    assert(node.Height == expectedHeight, "Node height mismatch")

    local unionBox = aabbUnion(self._nodes[left].AABB, self._nodes[right].AABB)
    assert(aabbContainsAABB(node.AABB, unionBox), "Parent AABB must contain child union")

    local diff = math.abs(self._nodes[right].Height - self._nodes[left].Height)
    assert(diff <= 2, "AVL balance violation: height diff > 2")

    return validateNode(left) and validateNode(right)
  end

  return validateNode(self._root)
end

function DynamicBVH:Clear()
  self._nodes = {}
  self._root = NULL_INDEX
  self._freeList = NULL_INDEX
  self._leafMap = {}
  self._leafCount = 0
  self._nodeCount = 0
end

return DynamicBVH
