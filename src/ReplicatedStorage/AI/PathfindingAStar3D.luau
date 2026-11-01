--!strict
--[[
  PathfindingAStar3D.luau
  Production-grade 3D A* navigation graph and volumetric pathfinder for Roblox.
  Features:
  - Binary min-heap priority queue for O(log N) node extraction
  - 3D spatial heuristics (Euclidean, Manhattan, Octile)
  - Asymmetric vertical constraints (climb height vs drop height limits)
  - Dynamic node penalties and walkability flags
  - Tick budget protection via MaxExpansions limit with optional partial path recovery
  - Raycast/line-of-sight path smoothing (string-pulling shortcutting)
  - Volumetric 3D grid generator helper for terrain and structures
  Part of crustdev studio game systems.
  Zero external runtime dependencies.
]]

local roblox = _G.Vector3 and _G or require("@lune/roblox")
local Vector3 = roblox.Vector3

export type NodeId = string | number

export type WaypointNode = {
  Id: NodeId,
  Position: Vector3,
  Neighbors: { [NodeId]: number },
  Walkable: boolean,
  Penalty: number,
  Metadata: any?,
}

export type HeuristicType = "Euclidean" | "Manhattan" | "Octile"

export type PathfindingOptions = {
  MaxExpansions: number?,
  HeuristicWeight: number?,
  AllowPartialPath: boolean?,
  MaxClimbHeight: number?,
  MaxDropHeight: number?,
  Heuristic: HeuristicType?,
}

export type PathResult = {
  Success: boolean,
  Partial: boolean,
  Waypoints: { Vector3 },
  NodeIds: { NodeId },
  Cost: number,
  Expansions: number,
}

export type LineOfSightChecker = (fromPos: Vector3, toPos: Vector3) -> boolean

export type NavGraph = {
  Nodes: { [NodeId]: WaypointNode },
  NodeCount: number,

  AddNode: (self: NavGraph, id: NodeId, position: Vector3, metadata: any?) -> WaypointNode,
  RemoveNode: (self: NavGraph, id: NodeId) -> boolean,
  GetNode: (self: NavGraph, id: NodeId) -> WaypointNode?,
  AddEdge: (self: NavGraph, fromId: NodeId, toId: NodeId, bidirectional: boolean?, customCost: number?) -> boolean,
  RemoveEdge: (self: NavGraph, fromId: NodeId, toId: NodeId, bidirectional: boolean?) -> boolean,
  SetNodeWalkable: (self: NavGraph, id: NodeId, walkable: boolean) -> boolean,
  SetNodePenalty: (self: NavGraph, id: NodeId, penalty: number) -> boolean,
  GetNearestNode: (self: NavGraph, position: Vector3, maxDistance: number?) -> WaypointNode?,
  FindPath: (self: NavGraph, startIdOrPos: NodeId | Vector3, goalIdOrPos: NodeId | Vector3, options: PathfindingOptions?) -> PathResult,
  SmoothPath: (self: NavGraph, path: { Vector3 }, losChecker: LineOfSightChecker) -> { Vector3 },
  GenerateGrid3D: (self: NavGraph, origin: Vector3, countX: number, countY: number, countZ: number, spacing: number, connectDiagonals: boolean?) -> number,
  Clear: (self: NavGraph) -> (),
}

-- Binary Min-Heap Priority Queue for Open Set
type HeapItem = {
  Id: NodeId,
  FScore: number,
}

type MinHeap = {
  Items: { HeapItem },
  Push: (self: MinHeap, id: NodeId, fScore: number) -> (),
  Pop: (self: MinHeap) -> HeapItem?,
  IsEmpty: (self: MinHeap) -> boolean,
}

local function CreateMinHeap(): MinHeap
  local items: { HeapItem } = {}
  local heap = { Items = items }

  function heap:Push(id: NodeId, fScore: number)
    local item = { Id = id, FScore = fScore }
    table.insert(items, item)
    local idx = #items
    while idx > 1 do
      local parentIdx = math.floor(idx / 2)
      if items[idx].FScore < items[parentIdx].FScore then
        items[idx], items[parentIdx] = items[parentIdx], items[idx]
        idx = parentIdx
      else
        break
      end
    end
  end

  function heap:Pop(): HeapItem?
    local count = #items
    if count == 0 then return nil end
    local min = items[1]
    local last = items[count]
    items[count] = nil
    if count > 1 then
      items[1] = last
      local idx = 1
      local limit = count - 1
      while true do
        local leftIdx = idx * 2
        local rightIdx = leftIdx + 1
        local smallest = idx

        if leftIdx <= limit and items[leftIdx].FScore < items[smallest].FScore then
          smallest = leftIdx
        end
        if rightIdx <= limit and items[rightIdx].FScore < items[smallest].FScore then
          smallest = rightIdx
        end

        if smallest ~= idx then
          items[idx], items[smallest] = items[smallest], items[idx]
          idx = smallest
        else
          break
        end
      end
    end
    return min
  end

  function heap:IsEmpty(): boolean
    return #items == 0
  end

  return heap
end

-- Heuristic Calculations
local SQRT_2 = math.sqrt(2)
local SQRT_3 = math.sqrt(3)

local function CalculateHeuristic(p1: Vector3, p2: Vector3, hType: HeuristicType): number
  local dx = math.abs(p1.X - p2.X)
  local dy = math.abs(p1.Y - p2.Y)
  local dz = math.abs(p1.Z - p2.Z)

  if hType == "Manhattan" then
    return dx + dy + dz
  elseif hType == "Octile" then
    -- 3D Octile distance metric
    local minCoord = math.min(dx, math.min(dy, dz))
    local maxCoord = math.max(dx, math.max(dy, dz))
    local midCoord = (dx + dy + dz) - minCoord - maxCoord
    return minCoord * SQRT_3 + (midCoord - minCoord) * SQRT_2 + (maxCoord - midCoord)
  else
    -- Default: Euclidean distance
    return (p1 - p2).Magnitude
  end
end

local NavGraphImpl = {}
NavGraphImpl.__index = NavGraphImpl

function NavGraphImpl:AddNode(id: NodeId, position: Vector3, metadata: any?): WaypointNode
  local existing = self.Nodes[id]
  if existing then
    existing.Position = position
    existing.Metadata = metadata or existing.Metadata
    return existing
  end

  local node: WaypointNode = {
    Id = id,
    Position = position,
    Neighbors = {},
    Walkable = true,
    Penalty = 0,
    Metadata = metadata,
  }
  self.Nodes[id] = node
  self.NodeCount += 1
  return node
end

function NavGraphImpl:RemoveNode(id: NodeId): boolean
  local node = self.Nodes[id]
  if not node then return false end

  -- Remove incoming references from neighbors
  for neighborId in pairs(node.Neighbors) do
    local nNode = self.Nodes[neighborId]
    if nNode then
      nNode.Neighbors[id] = nil
    end
  end

  self.Nodes[id] = nil
  self.NodeCount -= 1
  return true
end

function NavGraphImpl:GetNode(id: NodeId): WaypointNode?
  return self.Nodes[id]
end

function NavGraphImpl:AddEdge(fromId: NodeId, toId: NodeId, bidirectional: boolean?, customCost: number?): boolean
  local n1 = self.Nodes[fromId]
  local n2 = self.Nodes[toId]
  if not n1 or not n2 then return false end

  local cost = customCost or (n1.Position - n2.Position).Magnitude
  n1.Neighbors[toId] = cost

  if bidirectional ~= false then
    n2.Neighbors[fromId] = cost
  end
  return true
end

function NavGraphImpl:RemoveEdge(fromId: NodeId, toId: NodeId, bidirectional: boolean?): boolean
  local n1 = self.Nodes[fromId]
  local n2 = self.Nodes[toId]
  if not n1 then return false end

  n1.Neighbors[toId] = nil
  if bidirectional ~= false and n2 then
    n2.Neighbors[fromId] = nil
  end
  return true
end

function NavGraphImpl:SetNodeWalkable(id: NodeId, walkable: boolean): boolean
  local node = self.Nodes[id]
  if not node then return false end
  node.Walkable = walkable
  return true
end

function NavGraphImpl:SetNodePenalty(id: NodeId, penalty: number): boolean
  local node = self.Nodes[id]
  if not node then return false end
  node.Penalty = math.max(0, penalty)
  return true
end

function NavGraphImpl:GetNearestNode(position: Vector3, maxDistance: number?): WaypointNode?
  local closest: WaypointNode? = nil
  local minSqDist = (maxDistance and (maxDistance * maxDistance)) or math.huge

  for _, node in pairs(self.Nodes) do
    local offset = node.Position - position
    local sqDist = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z
    if sqDist < minSqDist then
      minSqDist = sqDist
      closest = node
    end
  end

  return closest
end

function NavGraphImpl:FindPath(startIdOrPos: NodeId | Vector3, goalIdOrPos: NodeId | Vector3, options: PathfindingOptions?): PathResult
  local opts = options or {}
  local maxExpansions = opts.MaxExpansions or 2000
  local heuristicWeight = opts.HeuristicWeight or 1.0
  local allowPartial = if opts.AllowPartialPath ~= nil then opts.AllowPartialPath else true
  local hType = opts.Heuristic or "Euclidean"
  local maxClimb = opts.MaxClimbHeight or 6.0
  local maxDrop = opts.MaxDropHeight or 18.0

  -- Resolve start node
  local startNode: WaypointNode?
  if typeof(startIdOrPos) == "Vector3" then
    startNode = self:GetNearestNode(startIdOrPos, 50.0)
  else
    startNode = self.Nodes[startIdOrPos]
  end

  -- Resolve goal node
  local goalNode: WaypointNode?
  if typeof(goalIdOrPos) == "Vector3" then
    goalNode = self:GetNearestNode(goalIdOrPos, 50.0)
  else
    goalNode = self.Nodes[goalIdOrPos]
  end

  local emptyResult: PathResult = {
    Success = false,
    Partial = false,
    Waypoints = {},
    NodeIds = {},
    Cost = 0,
    Expansions = 0,
  }

  if not startNode or not goalNode then
    return emptyResult
  end

  if startNode.Id == goalNode.Id then
    return {
      Success = true,
      Partial = false,
      Waypoints = { startNode.Position },
      NodeIds = { startNode.Id },
      Cost = 0,
      Expansions = 0,
    }
  end

  if not startNode.Walkable or not goalNode.Walkable then
    return emptyResult
  end

  local openSet = CreateMinHeap()
  local gScore: { [NodeId]: number } = {}
  local cameFrom: { [NodeId]: NodeId } = {}
  local closedSet: { [NodeId]: boolean } = {}

  gScore[startNode.Id] = 0
  local initialH = CalculateHeuristic(startNode.Position, goalNode.Position, hType) * heuristicWeight
  openSet:Push(startNode.Id, initialH)

  local expansions = 0
  local closestVisitedId: NodeId = startNode.Id
  local closestDistance = initialH

  while not openSet:IsEmpty() do
    local currentItem = openSet:Pop()
    if not currentItem then break end
    local currentId = currentItem.Id

    if currentId == goalNode.Id then
      -- Reconstruct path
      local pathNodes: { NodeId } = {}
      local waypoints: { Vector3 } = {}
      local curr: NodeId? = currentId

      while curr ~= nil do
        table.insert(pathNodes, 1, curr)
        local n = self.Nodes[curr]
        if n then
          table.insert(waypoints, 1, n.Position)
        end
        curr = cameFrom[curr]
      end

      return {
        Success = true,
        Partial = false,
        Waypoints = waypoints,
        NodeIds = pathNodes,
        Cost = gScore[currentId] or 0,
        Expansions = expansions,
      }
    end

    if closedSet[currentId] then
      continue
    end
    closedSet[currentId] = true
    expansions += 1

    if expansions >= maxExpansions then
      break
    end

    local currentNode = self.Nodes[currentId]
    if not currentNode then continue end

    local currentG = gScore[currentId] or math.huge

    for neighborId, baseEdgeCost in pairs(currentNode.Neighbors) do
      if closedSet[neighborId] then
        continue
      end

      local neighborNode = self.Nodes[neighborId]
      if not neighborNode or not neighborNode.Walkable then
        continue
      end

      -- Vertical climb / drop limits
      local dy = neighborNode.Position.Y - currentNode.Position.Y
      if dy > 0 and dy > maxClimb then
        continue
      elseif dy < 0 and (-dy) > maxDrop then
        continue
      end

      -- Edge cost + node penalty
      local stepCost = baseEdgeCost + neighborNode.Penalty
      -- Extra steep incline cost scaling
      if dy > 0.5 then
        stepCost += dy * 1.5
      end

      local tentativeG = currentG + stepCost
      local neighborG = gScore[neighborId] or math.huge

      if tentativeG < neighborG then
        cameFrom[neighborId] = currentId
        gScore[neighborId] = tentativeG
        local h = CalculateHeuristic(neighborNode.Position, goalNode.Position, hType) * heuristicWeight
        local f = tentativeG + h
        openSet:Push(neighborId, f)

        if h < closestDistance then
          closestDistance = h
          closestVisitedId = neighborId
        end
      end
    end
  end

  -- Goal was not reached within expansion budget or disconnected
  if allowPartial and closestVisitedId ~= startNode.Id then
    local pathNodes: { NodeId } = {}
    local waypoints: { Vector3 } = {}
    local curr: NodeId? = closestVisitedId

    while curr ~= nil do
      table.insert(pathNodes, 1, curr)
      local n = self.Nodes[curr]
      if n then
        table.insert(waypoints, 1, n.Position)
      end
      curr = cameFrom[curr]
    end

    return {
      Success = false,
      Partial = true,
      Waypoints = waypoints,
      NodeIds = pathNodes,
      Cost = gScore[closestVisitedId] or 0,
      Expansions = expansions,
    }
  end

  return {
    Success = false,
    Partial = false,
    Waypoints = {},
    NodeIds = {},
    Cost = 0,
    Expansions = expansions,
  }
end

function NavGraphImpl:SmoothPath(path: { Vector3 }, losChecker: LineOfSightChecker): { Vector3 }
  local count = #path
  if count <= 2 then
    return path
  end

  local smoothed: { Vector3 } = { path[1] }
  local currentIndex = 1

  while currentIndex < count do
    local farthestVisible = currentIndex + 1
    -- Look ahead as far as possible
    for testIndex = count, currentIndex + 2, -1 do
      if losChecker(path[currentIndex], path[testIndex]) then
        farthestVisible = testIndex
        break
      end
    end

    table.insert(smoothed, path[farthestVisible])
    currentIndex = farthestVisible
  end

  return smoothed
end

function NavGraphImpl:GenerateGrid3D(origin: Vector3, countX: number, countY: number, countZ: number, spacing: number, connectDiagonals: boolean?): number
  local diagonals = if connectDiagonals ~= nil then connectDiagonals else false
  local created = 0

  local function GetKey(x: number, y: number, z: number): string
    return string.format("grid_%d_%d_%d", x, y, z)
  end

  -- Create nodes
  for gx = 0, countX - 1 do
    for gy = 0, countY - 1 do
      for gz = 0, countZ - 1 do
        local pos = origin + Vector3.new(gx * spacing, gy * spacing, gz * spacing)
        self:AddNode(GetKey(gx, gy, gz), pos, { GridPos = { X = gx, Y = gy, Z = gz } })
        created += 1
      end
    end
  end

  -- Connect adjacent neighbors
  for gx = 0, countX - 1 do
    for gy = 0, countY - 1 do
      for gz = 0, countZ - 1 do
        local fromId = GetKey(gx, gy, gz)
        for dx = -1, 1 do
          for dy = -1, 1 do
            for dz = -1, 1 do
              if dx == 0 and dy == 0 and dz == 0 then continue end
              local nx, ny, nz = gx + dx, gy + dy, gz + dz
              if nx >= 0 and nx < countX and ny >= 0 and ny < countY and nz >= 0 and nz < countZ then
                local isDiagonal = (math.abs(dx) + math.abs(dy) + math.abs(dz)) > 1
                if not isDiagonal or diagonals then
                  local toId = GetKey(nx, ny, nz)
                  self:AddEdge(fromId, toId, false)
                end
              end
            end
          end
        end
      end
    end
  end

  return created
end

function NavGraphImpl:Clear()
  self.Nodes = {}
  self.NodeCount = 0
end

local PathfindingAStar3D = {}

function PathfindingAStar3D.new(): NavGraph
  local self = setmetatable({}, NavGraphImpl)
  self.Nodes = {}
  self.NodeCount = 0
  return self
end

return PathfindingAStar3D
