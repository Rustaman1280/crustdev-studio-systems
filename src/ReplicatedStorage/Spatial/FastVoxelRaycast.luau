--!strict
--[[
  FastVoxelRaycast.luau
  crustdev studio systems - ReplicatedStorage/Spatial/FastVoxelRaycast

  High-performance 3D discrete voxel ray traversal algorithm based on Amanatides and Woo (1987).
  Traverses discrete voxel grids in exact O(N) step increments without missing cells or
  relying on imprecise continuous step raymarching.

  Features:
  - Precise boundary crossing: accurately resolves voxel step directions, tMax, and tDelta.
  - Axis alignment support: correctly handles rays parallel to X, Y, or Z axes without division by zero.
  - Configurable grid geometry: supports custom voxel cellSize and spatial origin offset.
  - Rich hit inspection: returns voxel coordinates, contact world point, normal entry vector, and distance.
  - Traversal visitor API: step-by-step visitor callback for multi-hit piercing, field-of-view, or voxel edits.
  - Zero allocation in traversal loop: optimized for high-cadence Roblox game systems and Lune.

  Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local ZERO_VECTOR = Vector3.new(0, 0, 0)
local EPSILON = 1e-8

export type HitResult = {
  hit: boolean,
  voxel: Vector3,
  position: Vector3,
  normal: Vector3,
  distance: number,
  stepsTaken: number,
}

export type VoxelPredicate = (voxel: Vector3) -> boolean
export type StepVisitor = (voxel: Vector3, normal: Vector3, distance: number) -> boolean

local FastVoxelRaycast = {}
FastVoxelRaycast.__index = FastVoxelRaycast

local function floorCoordinate(val: number): number
  return math.floor(val)
end

-- Converts continuous world coordinate into integer voxel grid index
function FastVoxelRaycast.WorldToVoxel(worldPos: Vector3, cellSize: number?, originOffset: Vector3?): Vector3
  local size = cellSize or 1
  local offset = originOffset or ZERO_VECTOR
  local relX = (worldPos.X - offset.X) / size
  local relY = (worldPos.Y - offset.Y) / size
  local relZ = (worldPos.Z - offset.Z) / size
  return Vector3.new(floorCoordinate(relX), floorCoordinate(relY), floorCoordinate(relZ))
end

-- Converts integer voxel coordinate to lower-bound world position
function FastVoxelRaycast.VoxelToWorld(voxelPos: Vector3, cellSize: number?, originOffset: Vector3?): Vector3
  local size = cellSize or 1
  local offset = originOffset or ZERO_VECTOR
  return Vector3.new(
    voxelPos.X * size + offset.X,
    voxelPos.Y * size + offset.Y,
    voxelPos.Z * size + offset.Z
  )
end

-- Converts integer voxel coordinate to cell center world position
function FastVoxelRaycast.VoxelToWorldCenter(voxelPos: Vector3, cellSize: number?, originOffset: Vector3?): Vector3
  local size = cellSize or 1
  local half = size * 0.5
  local offset = originOffset or ZERO_VECTOR
  return Vector3.new(
    voxelPos.X * size + offset.X + half,
    voxelPos.Y * size + offset.Y + half,
    voxelPos.Z * size + offset.Z + half
  )
end

--[[
  Performs Amanatides and Woo fast voxel traversal along ray.
  Stops immediately when isSolidPredicate returns true or maxDistance is reached.
]]
function FastVoxelRaycast.Raycast(
  origin: Vector3,
  direction: Vector3,
  maxDistance: number,
  isSolidPredicate: VoxelPredicate,
  cellSize: number?,
  originOffset: Vector3?
): HitResult?
  local dirMag = direction.Magnitude
  if dirMag < EPSILON or maxDistance <= 0 then
    return nil
  end

  local unitDir = direction / dirMag
  local size = (cellSize and cellSize > 0) and cellSize or 1
  local offset = originOffset or ZERO_VECTOR

  -- Transform continuous origin into grid space
  local ox = (origin.X - offset.X) / size
  local oy = (origin.Y - offset.Y) / size
  local oz = (origin.Z - offset.Z) / size

  local vx = floorCoordinate(ox)
  local vy = floorCoordinate(oy)
  local vz = floorCoordinate(oz)

  -- Check if initial starting voxel is solid
  local currentVoxel = Vector3.new(vx, vy, vz)
  if isSolidPredicate(currentVoxel) then
    return {
      hit = true,
      voxel = currentVoxel,
      position = origin,
      normal = -unitDir,
      distance = 0,
      stepsTaken = 0,
    }
  end

  local dx = unitDir.X
  local dy = unitDir.Y
  local dz = unitDir.Z

  local stepX = if dx > 0 then 1 elseif dx < 0 then -1 else 0
  local stepY = if dy > 0 then 1 elseif dy < 0 then -1 else 0
  local stepZ = if dz > 0 then 1 elseif dz < 0 then -1 else 0

  local tDeltaX = if stepX ~= 0 then math.abs(1 / dx) else math.huge
  local tDeltaY = if stepY ~= 0 then math.abs(1 / dy) else math.huge
  local tDeltaZ = if stepZ ~= 0 then math.abs(1 / dz) else math.huge

  -- Distance in grid space units to next boundary
  local tMaxX: number
  if stepX > 0 then
    tMaxX = (vx + 1 - ox) / dx
  elseif stepX < 0 then
    tMaxX = (vx - ox) / dx
  else
    tMaxX = math.huge
  end

  local tMaxY: number
  if stepY > 0 then
    tMaxY = (vy + 1 - oy) / dy
  elseif stepY < 0 then
    tMaxY = (vy - oy) / dy
  else
    tMaxY = math.huge
  end

  local tMaxZ: number
  if stepZ > 0 then
    tMaxZ = (vz + 1 - oz) / dz
  elseif stepZ < 0 then
    tMaxZ = (vz - oz) / dz
  else
    tMaxZ = math.huge
  end

  local maxGridDist = maxDistance / size
  local currentGridDist = 0
  local lastNormal = ZERO_VECTOR
  local steps = 0
  local MAX_STEPS = 4096

  while currentGridDist <= maxGridDist and steps < MAX_STEPS do
    steps += 1

    if tMaxX < tMaxY and tMaxX < tMaxZ then
      vx += stepX
      currentGridDist = tMaxX
      tMaxX += tDeltaX
      lastNormal = Vector3.new(-stepX, 0, 0)
    elseif tMaxY < tMaxZ then
      vy += stepY
      currentGridDist = tMaxY
      tMaxY += tDeltaY
      lastNormal = Vector3.new(0, -stepY, 0)
    else
      vz += stepZ
      currentGridDist = tMaxZ
      tMaxZ += tDeltaZ
      lastNormal = Vector3.new(0, 0, -stepZ)
    end

    local worldDist = currentGridDist * size
    if worldDist > maxDistance then
      break
    end

    currentVoxel = Vector3.new(vx, vy, vz)
    if isSolidPredicate(currentVoxel) then
      local hitPos = origin + (unitDir * worldDist)
      return {
        hit = true,
        voxel = currentVoxel,
        position = hitPos,
        normal = lastNormal,
        distance = worldDist,
        stepsTaken = steps,
      }
    end
  end

  return nil
end

--[[
  Traverses each voxel step along the ray and invokes visitor(voxel, normal, distance).
  If visitor returns true, traversal terminates early.
  Returns total number of steps traversed.
]]
function FastVoxelRaycast.Traverse(
  origin: Vector3,
  direction: Vector3,
  maxDistance: number,
  visitor: StepVisitor,
  cellSize: number?,
  originOffset: Vector3?
): number
  local dirMag = direction.Magnitude
  if dirMag < EPSILON or maxDistance <= 0 then
    return 0
  end

  local unitDir = direction / dirMag
  local size = (cellSize and cellSize > 0) and cellSize or 1
  local offset = originOffset or ZERO_VECTOR

  local ox = (origin.X - offset.X) / size
  local oy = (origin.Y - offset.Y) / size
  local oz = (origin.Z - offset.Z) / size

  local vx = floorCoordinate(ox)
  local vy = floorCoordinate(oy)
  local vz = floorCoordinate(oz)

  local initialVoxel = Vector3.new(vx, vy, vz)
  if visitor(initialVoxel, ZERO_VECTOR, 0) == true then
    return 1
  end

  local dx = unitDir.X
  local dy = unitDir.Y
  local dz = unitDir.Z

  local stepX = if dx > 0 then 1 elseif dx < 0 then -1 else 0
  local stepY = if dy > 0 then 1 elseif dy < 0 then -1 else 0
  local stepZ = if dz > 0 then 1 elseif dz < 0 then -1 else 0

  local tDeltaX = if stepX ~= 0 then math.abs(1 / dx) else math.huge
  local tDeltaY = if stepY ~= 0 then math.abs(1 / dy) else math.huge
  local tDeltaZ = if stepZ ~= 0 then math.abs(1 / dz) else math.huge

  local tMaxX: number = if stepX > 0 then (vx + 1 - ox) / dx elseif stepX < 0 then (vx - ox) / dx else math.huge
  local tMaxY: number = if stepY > 0 then (vy + 1 - oy) / dy elseif stepY < 0 then (vy - oy) / dy else math.huge
  local tMaxZ: number = if stepZ > 0 then (vz + 1 - oz) / dz elseif stepZ < 0 then (vz - oz) / dz else math.huge

  local maxGridDist = maxDistance / size
  local currentGridDist = 0
  local lastNormal = ZERO_VECTOR
  local steps = 1
  local MAX_STEPS = 4096

  while currentGridDist <= maxGridDist and steps < MAX_STEPS do
    steps += 1

    if tMaxX < tMaxY and tMaxX < tMaxZ then
      vx += stepX
      currentGridDist = tMaxX
      tMaxX += tDeltaX
      lastNormal = Vector3.new(-stepX, 0, 0)
    elseif tMaxY < tMaxZ then
      vy += stepY
      currentGridDist = tMaxY
      tMaxY += tDeltaY
      lastNormal = Vector3.new(0, -stepY, 0)
    else
      vz += stepZ
      currentGridDist = tMaxZ
      tMaxZ += tDeltaZ
      lastNormal = Vector3.new(0, 0, -stepZ)
    end

    local worldDist = currentGridDist * size
    if worldDist > maxDistance then
      break
    end

    local currentVoxel = Vector3.new(vx, vy, vz)
    local shouldStop = visitor(currentVoxel, lastNormal, worldDist)
    if shouldStop == true then
      break
    end
  end

  return steps
end

return FastVoxelRaycast
