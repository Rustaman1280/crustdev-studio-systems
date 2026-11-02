--!strict
--[[
  VoxelFloodFill.luau
  crustdev studio systems - ReplicatedStorage/Spatial/VoxelFloodFill

  High-performance 3D discrete voxel flood fill, cavity detector, and connected
  component analysis engine for procedural worlds and voxel destruction systems.

  Features:
  - Orthogonal (6-way / face) and Omnidirectional (26-way / Moore) neighbor topology.
  - Pointer-based queue O(1) BFS traversal with step limits and bounding box clipping.
  - Connected component partitioning: segments disconnected voxel clusters into isolated bodies.
  - Sealed cavity extraction: identifies enclosed underground caves and air pockets sealed by solid voxels.
  - Spatial metric helpers: volume calculation, discrete center of mass, and axis-aligned bounding boxes.

  Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local ZERO_VECTOR = Vector3.new(0, 0, 0)

export type Connectivity = "face6" | "all26"
export type VoxelPredicate = (voxel: Vector3) -> boolean

export type FloodFillOptions = {
  start: Vector3,
  predicate: VoxelPredicate,
  connectivity: Connectivity?,
  maxSteps: number?,
  boundsMin: Vector3?,
  boundsMax: Vector3?,
  onVisit: ((voxel: Vector3, distance: number) -> ())?,
}

export type FloodFillResult = {
  voxels: { Vector3 },
  count: number,
  reachedLimit: boolean,
  touchesBounds: boolean,
}

local NEIGHBORS_6 = {
  Vector3.new(1, 0, 0),
  Vector3.new(-1, 0, 0),
  Vector3.new(0, 1, 0),
  Vector3.new(0, -1, 0),
  Vector3.new(0, 0, 1),
  Vector3.new(0, 0, -1),
}

local NEIGHBORS_26 = {}
for x = -1, 1 do
  for y = -1, 1 do
    for z = -1, 1 do
      if not (x == 0 and y == 0 and z == 0) then
        table.insert(NEIGHBORS_26, Vector3.new(x, y, z))
      end
    end
  end
end

local function keyFromCoord(v: Vector3): string
  return v.X .. "," .. v.Y .. "," .. v.Z
end

local function isInsideBounds(v: Vector3, bMin: Vector3?, bMax: Vector3?): boolean
  if bMin and (v.X < bMin.X or v.Y < bMin.Y or v.Z < bMin.Z) then
    return false
  end
  if bMax and (v.X > bMax.X or v.Y > bMax.Y or v.Z > bMax.Z) then
    return false
  end
  return true
end

local function isAtBoundsEdge(v: Vector3, bMin: Vector3?, bMax: Vector3?): boolean
  if bMin and (v.X == bMin.X or v.Y == bMin.Y or v.Z == bMin.Z) then
    return true
  end
  if bMax and (v.X == bMax.X or v.Y == bMax.Y or v.Z == bMax.Z) then
    return true
  end
  return false
end

local VoxelFloodFill = {}
VoxelFloodFill.__index = VoxelFloodFill

-- Returns table of neighbor offsets based on connectivity type
function VoxelFloodFill.GetNeighborOffsets(connectivity: Connectivity?): { Vector3 }
  if connectivity == "all26" then
    return NEIGHBORS_26
  end
  return NEIGHBORS_6
end

-- Executes breadth-first search flood fill from a single seed voxel
function VoxelFloodFill.FloodFill(options: FloodFillOptions): FloodFillResult
  local start = options.start
  local predicate = options.predicate
  local connectivity = options.connectivity or "face6"
  local maxSteps = options.maxSteps or 100000
  local bMin = options.boundsMin
  local bMax = options.boundsMax
  local onVisit = options.onVisit

  local offsets = VoxelFloodFill.GetNeighborOffsets(connectivity)
  local visited: { [string]: boolean } = {}
  local results: { Vector3 } = {}
  local touchesBounds = false
  local reachedLimit = false

  -- Validate start voxel
  if not isInsideBounds(start, bMin, bMax) or not predicate(start) then
    return {
      voxels = {},
      count = 0,
      reachedLimit = false,
      touchesBounds = false,
    }
  end

  -- Pointer-based queue for O(1) push and pop operations
  local queue: { Vector3 } = { start }
  local queueDist: { number } = { 0 }
  local head = 1

  visited[keyFromCoord(start)] = true
  table.insert(results, start)

  if isAtBoundsEdge(start, bMin, bMax) then
    touchesBounds = true
  end

  if onVisit then
    onVisit(start, 0)
  end

  while head <= #queue do
    if #results >= maxSteps then
      reachedLimit = true
      break
    end

    local current = queue[head]
    local dist = queueDist[head]
    head += 1

    for _, offset in ipairs(offsets) do
      local neighbor = Vector3.new(current.X + offset.X, current.Y + offset.Y, current.Z + offset.Z)
      local k = keyFromCoord(neighbor)

      if not visited[k] then
        visited[k] = true

        if isInsideBounds(neighbor, bMin, bMax) then
          if isAtBoundsEdge(neighbor, bMin, bMax) then
            touchesBounds = true
          end

          if predicate(neighbor) then
            table.insert(results, neighbor)
            table.insert(queue, neighbor)
            table.insert(queueDist, dist + 1)

            if onVisit then
              onVisit(neighbor, dist + 1)
            end

            if #results >= maxSteps then
              reachedLimit = true
              break
            end
          end
        else
          touchesBounds = true
        end
      end
    end
  end

  return {
    voxels = results,
    count = #results,
    reachedLimit = reachedLimit,
    touchesBounds = touchesBounds,
  }
end

-- Identifies isolated connected components among a given set of seed voxels
function VoxelFloodFill.FindConnectedComponents(
  seeds: { Vector3 },
  predicate: VoxelPredicate,
  connectivity: Connectivity?
): { { Vector3 } }
  local offsets = VoxelFloodFill.GetNeighborOffsets(connectivity or "face6")
  local globallyVisited: { [string]: boolean } = {}
  local components: { { Vector3 } } = {}

  for _, seed in ipairs(seeds) do
    local seedKey = keyFromCoord(seed)
    if not globallyVisited[seedKey] and predicate(seed) then
      local component: { Vector3 } = {}
      local queue: { Vector3 } = { seed }
      local head = 1
      globallyVisited[seedKey] = true
      table.insert(component, seed)

      while head <= #queue do
        local curr = queue[head]
        head += 1

        for _, offset in ipairs(offsets) do
          local neighbor = Vector3.new(curr.X + offset.X, curr.Y + offset.Y, curr.Z + offset.Z)
          local nk = keyFromCoord(neighbor)

          if not globallyVisited[nk] then
            if predicate(neighbor) then
              globallyVisited[nk] = true
              table.insert(component, neighbor)
              table.insert(queue, neighbor)
            end
          end
        end
      end

      table.insert(components, component)
    end
  end

  return components
end

-- Detects enclosed hollow air cavities sealed within solid structures
function VoxelFloodFill.DetectEnclosedCavities(
  boundsMin: Vector3,
  boundsMax: Vector3,
  isSolidPredicate: VoxelPredicate,
  connectivity: Connectivity?
): { { Vector3 } }
  local conn = connectivity or "face6"
  local offsets = VoxelFloodFill.GetNeighborOffsets(conn)
  local outsideAir: { [string]: boolean } = {}
  local queue: { Vector3 } = {}
  local head = 1

  -- Seed queue with all non-solid boundary voxels on outer shell
  for x = boundsMin.X, boundsMax.X do
    for y = boundsMin.Y, boundsMax.Y do
      for z = boundsMin.Z, boundsMax.Z do
        local isPerimeter = (x == boundsMin.X or x == boundsMax.X or
                             y == boundsMin.Y or y == boundsMax.Y or
                             z == boundsMin.Z or z == boundsMax.Z)
        if isPerimeter then
          local pt = Vector3.new(x, y, z)
          if not isSolidPredicate(pt) then
            local k = keyFromCoord(pt)
            if not outsideAir[k] then
              outsideAir[k] = true
              table.insert(queue, pt)
            end
          end
        end
      end
    end
  end

  -- Propagate outside air through entire non-solid volume
  while head <= #queue do
    local curr = queue[head]
    head += 1

    for _, offset in ipairs(offsets) do
      local neighbor = Vector3.new(curr.X + offset.X, curr.Y + offset.Y, curr.Z + offset.Z)
      if isInsideBounds(neighbor, boundsMin, boundsMax) then
        local nk = keyFromCoord(neighbor)
        if not outsideAir[nk] and not isSolidPredicate(neighbor) then
          outsideAir[nk] = true
          table.insert(queue, neighbor)
        end
      end
    end
  end

  -- Collect all air voxels within bounds that outside air could not reach
  local cavityVoxels: { Vector3 } = {}
  for x = boundsMin.X, boundsMax.X do
    for y = boundsMin.Y, boundsMax.Y do
      for z = boundsMin.Z, boundsMax.Z do
        local pt = Vector3.new(x, y, z)
        local k = keyFromCoord(pt)
        if not outsideAir[k] and not isSolidPredicate(pt) then
          table.insert(cavityVoxels, pt)
        end
      end
    end
  end

  -- Partition enclosed cavity voxels into individual connected pockets
  local isCavityVoxel = function(v: Vector3): boolean
    local k = keyFromCoord(v)
    return not outsideAir[k] and not isSolidPredicate(v) and isInsideBounds(v, boundsMin, boundsMax)
  end

  return VoxelFloodFill.FindConnectedComponents(cavityVoxels, isCavityVoxel, conn)
end

-- Calculates total physical volume represented by a set of voxels
function VoxelFloodFill.CalculateVolume(voxels: { Vector3 }, voxelSize: number?): number
  local size = voxelSize or 1
  return #voxels * (size * size * size)
end

-- Computes center of mass coordinate (mean position) of voxel collection
function VoxelFloodFill.CalculateCenterOfMass(voxels: { Vector3 }): Vector3
  if #voxels == 0 then
    return ZERO_VECTOR
  end

  local sumX = 0
  local sumY = 0
  local sumZ = 0

  for _, v in ipairs(voxels) do
    sumX += v.X
    sumY += v.Y
    sumZ += v.Z
  end

  local n = #voxels
  return Vector3.new(sumX / n, sumY / n, sumZ / n)
end

-- Computes minimum and maximum axis-aligned bounding box coordinates
function VoxelFloodFill.ComputeBoundingBox(voxels: { Vector3 }): (Vector3, Vector3)
  if #voxels == 0 then
    return ZERO_VECTOR, ZERO_VECTOR
  end

  local minX, minY, minZ = math.huge, math.huge, math.huge
  local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge

  for _, v in ipairs(voxels) do
    if v.X < minX then minX = v.X end
    if v.Y < minY then minY = v.Y end
    if v.Z < minZ then minZ = v.Z end
    if v.X > maxX then maxX = v.X end
    if v.Y > maxY then maxY = v.Y end
    if v.Z > maxZ then maxZ = v.Z end
  end

  return Vector3.new(minX, minY, minZ), Vector3.new(maxX, maxY, maxZ)
end

return VoxelFloodFill
