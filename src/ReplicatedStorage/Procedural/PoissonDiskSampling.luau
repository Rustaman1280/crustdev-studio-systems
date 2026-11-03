--!strict
--[[
  PoissonDiskSampling.luau
  Fast O(N) Bridson Poisson-Disk sampling algorithm for 2D and 3D spatial domains.
  Features:
  - Blue noise point distributions where all points maintain a minimum separation distance r
  - Deterministic pseudo-random number generation (SplitMix32 PRNG)
  - Accelerated uniform spatial grid for constant-time O(1) neighbor candidate checks
  - Annular candidate point sampling between r and 2r surrounding active points
  - Configurable rejection limit k (default 30 samples per active point)
  - Variable-distance sampling via optional DistanceSampler callback
  - Probabilistic thinning via optional ThinningSampler callback
  - 2D planar (X, Y) and 3D volumetric (X, Y, Z) sampling modes
  - Arbitrary domain bounding boxes with min/max coordinate ranges
  - Spatial exclusion circles and bounding zones for obstacle clearance
  - Point cloud validation utilities to verify separation invariants
  Part of crustdev studio game systems.
  Zero external runtime dependencies.
]]

export type Point2D = {
  X: number,
  Y: number,
}

export type Point3D = {
  X: number,
  Y: number,
  Z: number,
}

export type ExclusionZone2D = {
  Center: Point2D,
  Radius: number,
}

export type ExclusionZone3D = {
  Center: Point3D,
  Radius: number,
}

export type Sampler2DConfig = {
  MinX: number,
  MaxX: number,
  MinY: number,
  MaxY: number,
  MinDistance: number,
  MaxCandidates: number?,
  Seed: number?,
  DistanceSampler: ((point: Point2D) -> number)?,
  ThinningSampler: ((point: Point2D) -> number)?,
}

export type Sampler3DConfig = {
  MinX: number,
  MaxX: number,
  MinY: number,
  MaxY: number,
  MinZ: number,
  MaxZ: number,
  MinDistance: number,
  MaxCandidates: number?,
  Seed: number?,
  DistanceSampler: ((point: Point3D) -> number)?,
  ThinningSampler: ((point: Point3D) -> number)?,
}

-- SplitMix32 PRNG for deterministic results
local function CreatePRNG(seed: number)
  local state = seed % 4294967296
  if state == 0 then
    state = 123456789
  end

  local function NextU32(): number
    state = (state + 0x9E3779B9) % 4294967296
    local z = state
    z = bit32.bxor(z, bit32.rshift(z, 16))
    z = (z * 0x85EBCA6B) % 4294967296
    z = bit32.bxor(z, bit32.rshift(z, 13))
    z = (z * 0xC2B2AE35) % 4294967296
    return bit32.bxor(z, bit32.rshift(z, 16))
  end

  local function NextNumber(): number
    return NextU32() / 4294967296
  end

  local function RangeNumber(minVal: number, maxVal: number): number
    return minVal + NextNumber() * (maxVal - minVal)
  end

  return {
    NextNumber = NextNumber,
    RangeNumber = RangeNumber,
  }
end

local PoissonDiskSampling = {}
PoissonDiskSampling.__index = PoissonDiskSampling

--[[
  Generate a 2D Poisson-disk point cloud within a rectangular region.
]]
function PoissonDiskSampling.Sample2D(config: Sampler2DConfig, exclusions: { ExclusionZone2D }?): { Point2D }
  assert(config.MaxX > config.MinX, "MaxX must be greater than MinX")
  assert(config.MaxY > config.MinY, "MaxY must be greater than MinY")
  assert(config.MinDistance > 0, "MinDistance must be greater than 0")

  local minX = config.MinX
  local maxX = config.MaxX
  local minY = config.MinY
  local maxY = config.MaxY
  local baseR = config.MinDistance
  local k = config.MaxCandidates or 30
  local seed = config.Seed or 1337
  local prng = CreatePRNG(seed)
  local distSampler = config.DistanceSampler
  local thinSampler = config.ThinningSampler

  -- Spatial grid setup: cell size based on base minimum distance
  local cellSize = baseR / math.sqrt(2)
  local gridWidth = math.ceil((maxX - minX) / cellSize)
  local gridHeight = math.ceil((maxY - minY) / cellSize)
  local grid: { [number]: number } = {} -- maps cell index -> point index in points array

  local function GetCellCoord(p: Point2D): (number, number)
    local cx = math.floor((p.X - minX) / cellSize)
    local cy = math.floor((p.Y - minY) / cellSize)
    return cx, cy
  end

  local function GetGridIndex(cx: number, cy: number): number
    return cy * gridWidth + cx
  end

  local points: { Point2D } = {}
  local pointDistances: { number } = {}
  local activeList: { number } = {}

  local function IsInExclusion(p: Point2D): boolean
    if not exclusions then
      return false
    end
    for _, zone in ipairs(exclusions) do
      local dx = p.X - zone.Center.X
      local dy = p.Y - zone.Center.Y
      if (dx * dx + dy * dy) < (zone.Radius * zone.Radius) then
        return true
      end
    end
    return false
  end

  local function GetRequiredDistance(p: Point2D): number
    if distSampler then
      return math.max(baseR, distSampler(p))
    end
    return baseR
  end

  local function IsValidPoint(candidate: Point2D, candReqDist: number): boolean
    if candidate.X < minX or candidate.X >= maxX or candidate.Y < minY or candidate.Y >= maxY then
      return false
    end

    if IsInExclusion(candidate) then
      return false
    end

    local cx, cy = GetCellCoord(candidate)
    local cellRadius = math.ceil(candReqDist / cellSize)
    local minCX = math.max(0, cx - cellRadius)
    local maxCX = math.min(gridWidth - 1, cx + cellRadius)
    local minCY = math.max(0, cy - cellRadius)
    local maxCY = math.min(gridHeight - 1, cy + cellRadius)

    for checkY = minCY, maxCY do
      for checkX = minCX, maxCX do
        local gIdx = GetGridIndex(checkX, checkY)
        local neighborIdx = grid[gIdx]
        if neighborIdx then
          local neighbor = points[neighborIdx]
          local neighborDist = pointDistances[neighborIdx]
          local requiredDist = math.max(candReqDist, neighborDist)
          local dx = candidate.X - neighbor.X
          local dy = candidate.Y - neighbor.Y
          if (dx * dx + dy * dy) < (requiredDist * requiredDist) then
            return false
          end
        end
      end
    end

    return true
  end

  -- Initial sample selection
  local initialPoint: Point2D = {
    X = prng.RangeNumber(minX, maxX),
    Y = prng.RangeNumber(minY, maxY),
  }
  local initialDist = GetRequiredDistance(initialPoint)

  local maxAttempts = 100
  local attempt = 0
  while not IsValidPoint(initialPoint, initialDist) and attempt < maxAttempts do
    attempt += 1
    initialPoint = {
      X = prng.RangeNumber(minX, maxX),
      Y = prng.RangeNumber(minY, maxY),
    }
    initialDist = GetRequiredDistance(initialPoint)
  end

  if attempt >= maxAttempts and not IsValidPoint(initialPoint, initialDist) then
    return {}
  end

  table.insert(points, initialPoint)
  table.insert(pointDistances, initialDist)
  local initialIdx = #points
  table.insert(activeList, initialIdx)

  local initCX, initCY = GetCellCoord(initialPoint)
  grid[GetGridIndex(initCX, initCY)] = initialIdx

  -- Main sampling loop
  while #activeList > 0 do
    local randomActiveIdx = math.floor(prng.RangeNumber(1, #activeList + 0.9999))
    local pointIdx = activeList[randomActiveIdx]
    local basePoint = points[pointIdx]
    local baseDist = pointDistances[pointIdx]
    local foundCandidate = false

    for _ = 1, k do
      local angle = prng.RangeNumber(0, math.pi * 2)
      local dist = prng.RangeNumber(baseDist, 2 * baseDist)
      local candidate: Point2D = {
        X = basePoint.X + math.cos(angle) * dist,
        Y = basePoint.Y + math.sin(angle) * dist,
      }
      local candDist = GetRequiredDistance(candidate)

      if IsValidPoint(candidate, candDist) then
        table.insert(points, candidate)
        table.insert(pointDistances, candDist)
        local newIdx = #points
        table.insert(activeList, newIdx)

        local cx, cy = GetCellCoord(candidate)
        grid[GetGridIndex(cx, cy)] = newIdx

        foundCandidate = true
        break
      end
    end

    if not foundCandidate then
      table.remove(activeList, randomActiveIdx)
    end
  end

  -- Optional post-generation thinning filter
  if thinSampler then
    local filteredPoints: { Point2D } = {}
    for _, p in ipairs(points) do
      local chance = math.clamp(thinSampler(p), 0, 1)
      if prng.NextNumber() <= chance then
        table.insert(filteredPoints, p)
      end
    end
    return filteredPoints
  end

  return points
end

--[[
  Generate a 3D Poisson-disk point cloud within an axis-aligned bounding volume.
]]
function PoissonDiskSampling.Sample3D(config: Sampler3DConfig, exclusions: { ExclusionZone3D }?): { Point3D }
  assert(config.MaxX > config.MinX, "MaxX must be greater than MinX")
  assert(config.MaxY > config.MinY, "MaxY must be greater than MinY")
  assert(config.MaxZ > config.MinZ, "MaxZ must be greater than MinZ")
  assert(config.MinDistance > 0, "MinDistance must be greater than 0")

  local minX = config.MinX
  local maxX = config.MaxX
  local minY = config.MinY
  local maxY = config.MaxY
  local minZ = config.MinZ
  local maxZ = config.MaxZ
  local baseR = config.MinDistance
  local k = config.MaxCandidates or 30
  local seed = config.Seed or 1337
  local prng = CreatePRNG(seed)
  local distSampler = config.DistanceSampler
  local thinSampler = config.ThinningSampler

  -- Spatial grid setup: cell size ensures at most one sample per cell in 3D
  local cellSize = baseR / math.sqrt(3)
  local gridWidth = math.ceil((maxX - minX) / cellSize)
  local gridHeight = math.ceil((maxY - minY) / cellSize)
  local gridDepth = math.ceil((maxZ - minZ) / cellSize)
  local grid: { [number]: number } = {}

  local function GetCellCoord(p: Point3D): (number, number, number)
    local cx = math.floor((p.X - minX) / cellSize)
    local cy = math.floor((p.Y - minY) / cellSize)
    local cz = math.floor((p.Z - minZ) / cellSize)
    return cx, cy, cz
  end

  local function GetGridIndex(cx: number, cy: number, cz: number): number
    return (cz * gridHeight + cy) * gridWidth + cx
  end

  local points: { Point3D } = {}
  local pointDistances: { number } = {}
  local activeList: { number } = {}

  local function IsInExclusion(p: Point3D): boolean
    if not exclusions then
      return false
    end
    for _, zone in ipairs(exclusions) do
      local dx = p.X - zone.Center.X
      local dy = p.Y - zone.Center.Y
      local dz = p.Z - zone.Center.Z
      if (dx * dx + dy * dy + dz * dz) < (zone.Radius * zone.Radius) then
        return true
      end
    end
    return false
  end

  local function GetRequiredDistance(p: Point3D): number
    if distSampler then
      return math.max(baseR, distSampler(p))
    end
    return baseR
  end

  local function IsValidPoint(candidate: Point3D, candReqDist: number): boolean
    if candidate.X < minX or candidate.X >= maxX or
       candidate.Y < minY or candidate.Y >= maxY or
       candidate.Z < minZ or candidate.Z >= maxZ then
      return false
    end

    if IsInExclusion(candidate) then
      return false
    end

    local cx, cy, cz = GetCellCoord(candidate)
    local cellRadius = math.ceil(candReqDist / cellSize)
    local minCX = math.max(0, cx - cellRadius)
    local maxCX = math.min(gridWidth - 1, cx + cellRadius)
    local minCY = math.max(0, cy - cellRadius)
    local maxCY = math.min(gridHeight - 1, cy + cellRadius)
    local minCZ = math.max(0, cz - cellRadius)
    local maxCZ = math.min(gridDepth - 1, cz + cellRadius)

    for checkZ = minCZ, maxCZ do
      for checkY = minCY, maxCY do
        for checkX = minCX, maxCX do
          local gIdx = GetGridIndex(checkX, checkY, checkZ)
          local neighborIdx = grid[gIdx]
          if neighborIdx then
            local neighbor = points[neighborIdx]
            local neighborDist = pointDistances[neighborIdx]
            local requiredDist = math.max(candReqDist, neighborDist)
            local dx = candidate.X - neighbor.X
            local dy = candidate.Y - neighbor.Y
            local dz = candidate.Z - neighbor.Z
            if (dx * dx + dy * dy + dz * dz) < (requiredDist * requiredDist) then
              return false
            end
          end
        end
      end
    end

    return true
  end

  -- Initial sample selection
  local initialPoint: Point3D = {
    X = prng.RangeNumber(minX, maxX),
    Y = prng.RangeNumber(minY, maxY),
    Z = prng.RangeNumber(minZ, maxZ),
  }
  local initialDist = GetRequiredDistance(initialPoint)

  local maxAttempts = 100
  local attempt = 0
  while not IsValidPoint(initialPoint, initialDist) and attempt < maxAttempts do
    attempt += 1
    initialPoint = {
      X = prng.RangeNumber(minX, maxX),
      Y = prng.RangeNumber(minY, maxY),
      Z = prng.RangeNumber(minZ, maxZ),
    }
    initialDist = GetRequiredDistance(initialPoint)
  end

  if attempt >= maxAttempts and not IsValidPoint(initialPoint, initialDist) then
    return {}
  end

  table.insert(points, initialPoint)
  table.insert(pointDistances, initialDist)
  local initialIdx = #points
  table.insert(activeList, initialIdx)

  local initCX, initCY, initCZ = GetCellCoord(initialPoint)
  grid[GetGridIndex(initCX, initCY, initCZ)] = initialIdx

  -- Main sampling loop in 3D
  while #activeList > 0 do
    local randomActiveIdx = math.floor(prng.RangeNumber(1, #activeList + 0.9999))
    local pointIdx = activeList[randomActiveIdx]
    local basePoint = points[pointIdx]
    local baseDist = pointDistances[pointIdx]
    local foundCandidate = false

    for _ = 1, k do
      local u = prng.RangeNumber(0, 1)
      local v = prng.RangeNumber(0, 1)
      local theta = u * 2.0 * math.pi
      local phi = math.acos(2.0 * v - 1.0)
      local sinPhi = math.sin(phi)

      local dirX = sinPhi * math.cos(theta)
      local dirY = sinPhi * math.sin(theta)
      local dirZ = math.cos(phi)

      local dist = prng.RangeNumber(baseDist, 2 * baseDist)
      local candidate: Point3D = {
        X = basePoint.X + dirX * dist,
        Y = basePoint.Y + dirY * dist,
        Z = basePoint.Z + dirZ * dist,
      }
      local candDist = GetRequiredDistance(candidate)

      if IsValidPoint(candidate, candDist) then
        table.insert(points, candidate)
        table.insert(pointDistances, candDist)
        local newIdx = #points
        table.insert(activeList, newIdx)

        local cx, cy, cz = GetCellCoord(candidate)
        grid[GetGridIndex(cx, cy, cz)] = newIdx

        foundCandidate = true
        break
      end
    end

    if not foundCandidate then
      table.remove(activeList, randomActiveIdx)
    end
  end

  -- Optional thinning filter in 3D
  if thinSampler then
    local filteredPoints: { Point3D } = {}
    for _, p in ipairs(points) do
      local chance = math.clamp(thinSampler(p), 0, 1)
      if prng.NextNumber() <= chance then
        table.insert(filteredPoints, p)
      end
    end
    return filteredPoints
  end

  return points
end

--[[
  Verification helper: confirms that no pair of points is closer than tolerance * MinDistance.
]]
function PoissonDiskSampling.ValidateSeparation2D(points: { Point2D }, minDistance: number, tolerance: number?): (boolean, number)
  local tol = tolerance or 0.999
  local thresholdSq = (minDistance * tol) * (minDistance * tol)
  local minFoundSq = math.huge

  for i = 1, #points do
    for j = i + 1, #points do
      local dx = points[i].X - points[j].X
      local dy = points[i].Y - points[j].Y
      local dSq = dx * dx + dy * dy
      if dSq < minFoundSq then
        minFoundSq = dSq
      end
      if dSq < thresholdSq then
        return false, math.sqrt(dSq)
      end
    end
  end

  return true, math.sqrt(minFoundSq)
end

--[[
  Verification helper for 3D point clouds.
]]
function PoissonDiskSampling.ValidateSeparation3D(points: { Point3D }, minDistance: number, tolerance: number?): (boolean, number)
  local tol = tolerance or 0.999
  local thresholdSq = (minDistance * tol) * (minDistance * tol)
  local minFoundSq = math.huge

  for i = 1, #points do
    for j = i + 1, #points do
      local dx = points[i].X - points[j].X
      local dy = points[i].Y - points[j].Y
      local dz = points[i].Z - points[j].Z
      local dSq = dx * dx + dy * dy + dz * dz
      if dSq < minFoundSq then
        minFoundSq = dSq
      end
      if dSq < thresholdSq then
        return false, math.sqrt(dSq)
      end
    end
  end

  return true, math.sqrt(minFoundSq)
end

return PoissonDiskSampling