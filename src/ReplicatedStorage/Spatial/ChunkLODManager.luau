--!strict
--[[
  ChunkLODManager.luau
  crustdev studio systems - ReplicatedStorage/Spatial/ChunkLODManager

  High-performance Chunk Level of Detail (LOD) and streaming manager for open-world
  procedural terrains, voxel systems, streaming cityscapes, and vast environments in Roblox.

  Features:
  - Multi-tier continuous LOD distance scheduling (LOD0 ultra-close to LOD_N far/impostor).
  - Hysteresis deadband filtering to eliminate boundary oscillation and mesh thrashing.
  - Frame budget throttling with priority scheduling (closest high-detail chunks processed first).
  - Observer velocity lead prediction for fast vehicles, flight, and dynamic cameras.
  - Neighbor LOD differential calculation for watertight seam-stitching and skirts.
  - Supports both 2D planar (XZ streaming) and full 3D volumetric (XYZ streaming) modes.
  - Zero Em-Dash Policy compliant.
  - Pure Luau / Lune compatible with zero external engine dependencies.
]]

local ChunkLODManager = {}
ChunkLODManager.__index = ChunkLODManager

export type LODTier = {
  Level: number,       -- 0 is highest detail
  MaxDistance: number, -- Cutoff distance for this tier
}

export type ChunkConfig = {
  ChunkSize: number,              -- World units per chunk edge (e.g., 64 studs)
  Is3D: boolean?,                 -- If true, chunks are evaluated in 3D (XYZ); if false, 2D (XZ)
  Tiers: { LODTier },             -- Must be sorted by MaxDistance ascending
  Hysteresis: number?,            -- Deadband buffer to prevent boundary thrashing (default: 16 studs)
  BudgetPerFrame: number?,        -- Maximum transitions executed per Update tick (default: 8)
  VelocityLeadTime: number?,      -- Seconds to project observer position forward (default: 0.5s)
}

export type ChunkCoord = {
  cx: number,
  cy: number,
  cz: number,
}

export type ChunkRecord = {
  Key: string,
  Coord: ChunkCoord,
  CurrentLOD: number,             -- Active LOD level
  Center: { X: number, Y: number, Z: number },
  DistanceToObserver: number,
}

type TransitionOp = {
  Type: "Load" | "Change" | "Unload",
  Key: string,
  Coord: ChunkCoord,
  OldLOD: number?,
  NewLOD: number?,
  Priority: number,               -- Lower value = higher priority (sorted ascending)
}

export type ChunkLODManagerImpl = {
  Config: ChunkConfig,
  ActiveChunks: { [string]: ChunkRecord },
  PendingTransitions: { TransitionOp },

  WorldToChunkCoord: (self: ChunkLODManagerImpl, x: number, y: number, z: number) -> (number, number, number),
  ChunkCoordToCenter: (self: ChunkLODManagerImpl, cx: number, cy: number, cz: number) -> (number, number, number),
  GetChunkKey: (self: ChunkLODManagerImpl, cx: number, cy: number, cz: number) -> string,

  Update: (
    self: ChunkLODManagerImpl,
    obsPos: { X: number, Y: number, Z: number },
    obsVel: { X: number, Y: number, Z: number }?
  ) -> {
    Loaded: { { Key: string, LOD: number } },
    Changed: { { Key: string, OldLOD: number, NewLOD: number } },
    Unloaded: { { Key: string } },
  },

  FlushAll: (self: ChunkLODManagerImpl) -> (),
  GetChunk: (self: ChunkLODManagerImpl, key: string) -> ChunkRecord?,
  GetNeighborLODDelta: (self: ChunkLODManagerImpl, cx: number, cy: number, cz: number) -> { [string]: number },
  GetActiveChunkCount: (self: ChunkLODManagerImpl) -> number,
  SetCallbacks: (self: ChunkLODManagerImpl, callbacks: {
    OnLoad: ((key: string, coord: ChunkCoord, lod: number) -> ())?,
    OnChange: ((key: string, coord: ChunkCoord, oldLod: number, newLod: number) -> ())?,
    OnUnload: ((key: string, coord: ChunkCoord) -> ())?,
  }) -> (),
}

-- Utility: Distance calculation
local function distanceSq(
  x1: number, y1: number, z1: number,
  x2: number, y2: number, z2: number,
  is3D: boolean
): number
  local dx = x1 - x2
  local dz = z1 - z2
  if is3D then
    local dy = y1 - y2
    return dx * dx + dy * dy + dz * dz
  else
    return dx * dx + dz * dz
  end
end

function ChunkLODManager.new(config: ChunkConfig): ChunkLODManagerImpl
  assert(config.ChunkSize > 0, "ChunkSize must be greater than zero")
  assert(config.Tiers and #config.Tiers > 0, "Tiers must contain at least one LOD tier")

  -- Verify sorted tiers
  for i = 1, #config.Tiers - 1 do
    assert(
      config.Tiers[i].MaxDistance < config.Tiers[i + 1].MaxDistance,
      "Tiers must be strictly ordered by MaxDistance ascending"
    )
  end

  local self = setmetatable({}, ChunkLODManager) :: any
  self.Config = {
    ChunkSize = config.ChunkSize,
    Is3D = config.Is3D or false,
    Tiers = config.Tiers,
    Hysteresis = config.Hysteresis or 16,
    BudgetPerFrame = config.BudgetPerFrame or 8,
    VelocityLeadTime = config.VelocityLeadTime or 0.5,
  }

  self.ActiveChunks = {}
  self.PendingTransitions = {}
  self.Callbacks = {}

  function self:WorldToChunkCoord(x: number, y: number, z: number): (number, number, number)
    local cs = self.Config.ChunkSize
    local cx = math.floor(x / cs)
    local cy = self.Config.Is3D and math.floor(y / cs) or 0
    local cz = math.floor(z / cs)
    return cx, cy, cz
  end

  function self:ChunkCoordToCenter(cx: number, cy: number, cz: number): (number, number, number)
    local cs = self.Config.ChunkSize
    local half = cs * 0.5
    local wx = cx * cs + half
    local wy = self.Config.Is3D and (cy * cs + half) or 0
    local wz = cz * cs + half
    return wx, wy, wz
  end

  function self:GetChunkKey(cx: number, cy: number, cz: number): string
    if self.Config.Is3D then
      return string.format("%d:%d:%d", cx, cy, cz)
    else
      return string.format("%d:%d", cx, cz)
    end
  end

  function self:SetCallbacks(callbacks: {
    OnLoad: ((key: string, coord: ChunkCoord, lod: number) -> ())?,
    OnChange: ((key: string, coord: ChunkCoord, oldLod: number, newLod: number) -> ())?,
    OnUnload: ((key: string, coord: ChunkCoord) -> ())?,
  })
    self.Callbacks = callbacks
  end

  -- Helper to determine target LOD level for a given distance, accounting for hysteresis
  local function resolveTargetLOD(
    dist: number,
    currentLOD: number?,
    tiers: { LODTier },
    hysteresis: number
  ): number?
    local maxCullDist = tiers[#tiers].MaxDistance

    -- Check culling boundary with hysteresis
    if currentLOD ~= nil then
      if dist > maxCullDist + hysteresis then
        return nil -- Out of bounds, cull/unload
      end
    else
      if dist > maxCullDist then
        return nil -- Beyond range for newly loaded chunk
      end
    end

    -- If chunk is already active at currentLOD, evaluate hysteresis transitions
    if currentLOD ~= nil then
      local tierInfo = tiers[currentLOD + 1] -- 1-indexed table mapping to Level (0-indexed)
      if tierInfo then
        local lowerBound = (currentLOD > 0) and (tiers[currentLOD].MaxDistance - hysteresis) or 0
        local upperBound = tierInfo.MaxDistance + hysteresis

        -- If distance remains comfortably within hysteresis bounds, keep current LOD
        if dist >= lowerBound and dist <= upperBound then
          return currentLOD
        end
      end
    end

    -- Direct tier mapping
    for _, tier in ipairs(tiers) do
      if dist <= tier.MaxDistance then
        return tier.Level
      end
    end

    return nil
  end

  function self:Update(
    obsPos: { X: number, Y: number, Z: number },
    obsVel: { X: number, Y: number, Z: number }?
  ): {
    Loaded: { { Key: string, LOD: number } },
    Changed: { { Key: string, OldLOD: number, NewLOD: number } },
    Unloaded: { { Key: string } },
  }
    local cs = self.Config.ChunkSize
    local is3D = self.Config.Is3D
    local tiers = self.Config.Tiers
    local maxDist = tiers[#tiers].MaxDistance
    local hysteresis = self.Config.Hysteresis
    local budget = self.Config.BudgetPerFrame

    -- Velocity lead projection
    local effX = obsPos.X
    local effY = obsPos.Y
    local effZ = obsPos.Z
    if obsVel and self.Config.VelocityLeadTime > 0 then
      local lt = self.Config.VelocityLeadTime
      effX += obsVel.X * lt
      effY += obsVel.Y * lt
      effZ += obsVel.Z * lt
    end

    -- Determine chunk search radius
    local chunkRadius = math.ceil((maxDist + hysteresis) / cs)
    local centerCx, centerCy, centerCz = self:WorldToChunkCoord(effX, effY, effZ)

    local visitedKeys: { [string]: boolean } = {}
    local candidateOps: { TransitionOp } = {}

    local minY = is3D and (centerCy - chunkRadius) or 0
    local maxY = is3D and (centerCy + chunkRadius) or 0

    -- Scan potential chunk coordinates within bounding box
    for cx = centerCx - chunkRadius, centerCx + chunkRadius do
      for cz = centerCz - chunkRadius, centerCz + chunkRadius do
        for cy = minY, maxY do
          local key = self:GetChunkKey(cx, cy, cz)
          visitedKeys[key] = true

          local wx, wy, wz = self:ChunkCoordToCenter(cx, cy, cz)
          local dSq = distanceSq(effX, effY, effZ, wx, wy, wz, is3D)
          local dist = math.sqrt(dSq)

          local activeRecord = self.ActiveChunks[key]
          local currentLOD = activeRecord and activeRecord.CurrentLOD or nil
          local targetLOD = resolveTargetLOD(dist, currentLOD, tiers, hysteresis)

          if targetLOD ~= nil then
            if currentLOD == nil then
              -- New chunk load
              table.insert(candidateOps, {
                Type = "Load",
                Key = key,
                Coord = { cx = cx, cy = cy, cz = cz },
                NewLOD = targetLOD,
                Priority = dist, -- Closer chunks load first
              })
            elseif currentLOD ~= targetLOD then
              -- LOD shift
              table.insert(candidateOps, {
                Type = "Change",
                Key = key,
                Coord = { cx = cx, cy = cy, cz = cz },
                OldLOD = currentLOD,
                NewLOD = targetLOD,
                Priority = dist,
              })
            else
              -- Maintain and update distance
              if activeRecord then
                activeRecord.DistanceToObserver = dist
              end
            end
          else
            if currentLOD ~= nil then
              -- Chunk must be unloaded
              table.insert(candidateOps, {
                Type = "Unload",
                Key = key,
                Coord = { cx = cx, cy = cy, cz = cz },
                OldLOD = currentLOD,
                Priority = 100000 - dist, -- Farther chunks unload first
              })
            end
          end
        end
      end
    end

    -- Check any active chunks that fell entirely outside our search bounding box
    for key, activeRecord in pairs(self.ActiveChunks) do
      if not visitedKeys[key] then
        local wx, wy, wz = self:ChunkCoordToCenter(activeRecord.Coord.cx, activeRecord.Coord.cy, activeRecord.Coord.cz)
        local dSq = distanceSq(effX, effY, effZ, wx, wy, wz, is3D)
        local dist = math.sqrt(dSq)
        table.insert(candidateOps, {
          Type = "Unload",
          Key = key,
          Coord = activeRecord.Coord,
          OldLOD = activeRecord.CurrentLOD,
          Priority = 100000 - dist,
        })
      end
    end

    -- Sort candidate operations by Priority ascending
    table.sort(candidateOps, function(a, b)
      return a.Priority < b.Priority
    end)

    -- Execute operations up to budget
    local result = {
      Loaded = {} :: { { Key: string, LOD: number } },
      Changed = {} :: { { Key: string, OldLOD: number, NewLOD: number } },
      Unloaded = {} :: { { Key: string } },
    }

    local executedCount = 0
    for _, op in ipairs(candidateOps) do
      if executedCount >= budget then
        break
      end

      if op.Type == "Load" then
        local wx, wy, wz = self:ChunkCoordToCenter(op.Coord.cx, op.Coord.cy, op.Coord.cz)
        local dist = math.sqrt(distanceSq(effX, effY, effZ, wx, wy, wz, is3D))
        self.ActiveChunks[op.Key] = {
          Key = op.Key,
          Coord = op.Coord,
          CurrentLOD = op.NewLOD :: number,
          Center = { X = wx, Y = wy, Z = wz },
          DistanceToObserver = dist,
        }
        table.insert(result.Loaded, { Key = op.Key, LOD = op.NewLOD :: number })
        if self.Callbacks.OnLoad then
          self.Callbacks.OnLoad(op.Key, op.Coord, op.NewLOD :: number)
        end
        executedCount += 1

      elseif op.Type == "Change" then
        local record = self.ActiveChunks[op.Key]
        if record then
          record.CurrentLOD = op.NewLOD :: number
          table.insert(result.Changed, {
            Key = op.Key,
            OldLOD = op.OldLOD :: number,
            NewLOD = op.NewLOD :: number,
          })
          if self.Callbacks.OnChange then
            self.Callbacks.OnChange(op.Key, op.Coord, op.OldLOD :: number, op.NewLOD :: number)
          end
          executedCount += 1
        end

      elseif op.Type == "Unload" then
        if self.ActiveChunks[op.Key] then
          self.ActiveChunks[op.Key] = nil
          table.insert(result.Unloaded, { Key = op.Key })
          if self.Callbacks.OnUnload then
            self.Callbacks.OnUnload(op.Key, op.Coord)
          end
          executedCount += 1
        end
      end
    end

    return result
  end

  function self:GetChunk(key: string): ChunkRecord?
    return self.ActiveChunks[key]
  end

  function self:GetActiveChunkCount(): number
    local count = 0
    for _ in pairs(self.ActiveChunks) do
      count += 1
    end
    return count
  end

  function self:FlushAll()
    for key, record in pairs(self.ActiveChunks) do
      if self.Callbacks.OnUnload then
        self.Callbacks.OnUnload(key, record.Coord)
      end
    end
    self.ActiveChunks = {}
  end

  -- Seam stitching helper: returns delta LOD for cardinal neighbors
  function self:GetNeighborLODDelta(cx: number, cy: number, cz: number): { [string]: number }
    local thisKey = self:GetChunkKey(cx, cy, cz)
    local thisRecord = self.ActiveChunks[thisKey]
    if not thisRecord then
      return {}
    end

    local deltas: { [string]: number } = {}
    local offsets = {
      North = { dx = 0, dz = 1, dy = 0 },
      South = { dx = 0, dz = -1, dy = 0 },
      East  = { dx = 1, dz = 0, dy = 0 },
      West  = { dx = -1, dz = 0, dy = 0 },
    }

    if self.Config.Is3D then
      offsets.Top = { dx = 0, dz = 0, dy = 1 }
      offsets.Bottom = { dx = 0, dz = 0, dy = -1 }
    end

    for name, offset in pairs(offsets) do
      local neighborKey = self:GetChunkKey(cx + offset.dx, cy + offset.dy, cz + offset.dz)
      local neighborRecord = self.ActiveChunks[neighborKey]
      if neighborRecord then
        deltas[name] = neighborRecord.CurrentLOD - thisRecord.CurrentLOD
      else
        deltas[name] = 999 -- Unloaded boundary seam
      end
    end

    return deltas
  end

  return self
end

return ChunkLODManager
