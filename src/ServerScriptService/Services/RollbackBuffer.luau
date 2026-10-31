--!strict
--[[
  RollbackBuffer.luau
  Authoritative server snapshot ring buffer for lag-compensated hit reconciliation.
  Part of crustdev studio game systems.
]]

export type EntitySnapshot = {
  EntityId: number,
  Position: Vector3,
  HitboxSize: Vector3,
  ServerClock: number,
  TickNumber: number,
}

local RollbackBuffer = {}
RollbackBuffer.__index = RollbackBuffer

local BUFFER_CAPACITY = 120 -- Stores last 120 server ticks (~2 seconds at 60Hz)

function RollbackBuffer.new(entityId: number): RollbackBufferInstance
  local self = setmetatable({}, RollbackBuffer)
  self.EntityId = entityId
  self.Snapshots = table.create(BUFFER_CAPACITY) :: { EntitySnapshot }
  self.Head = 1
  self.Count = 0
  return self
end

export type RollbackBufferInstance = typeof(setmetatable({} :: {
  EntityId: number,
  Snapshots: { EntitySnapshot },
  Head: number,
  Count: number,
}, RollbackBuffer))

-- Record server authoritative position for the current tick
function RollbackBuffer:RecordSnapshot(position: Vector3, hitboxSize: Vector3, tickNumber: number): ()
  local snapshot: EntitySnapshot = {
    EntityId = self.EntityId,
    Position = position,
    HitboxSize = hitboxSize,
    ServerClock = os.clock(),
    TickNumber = tickNumber,
  }

  self.Snapshots[self.Head] = snapshot
  self.Head = (self.Head % BUFFER_CAPACITY) + 1
  if self.Count < BUFFER_CAPACITY then
    self.Count += 1
  end
end

-- Reconstruct historical bounding box at past client timestamp with linear interpolation
function RollbackBuffer:SampleHistoricalPosition(targetTimestamp: number): Vector3?
  if self.Count == 0 then
    return nil
  end

  local newestIdx = self.Head - 1
  if newestIdx < 1 then
    newestIdx = BUFFER_CAPACITY
  end

  local newest = self.Snapshots[newestIdx]
  if not newest then
    return nil
  end

  -- Target is current or in future
  if targetTimestamp >= newest.ServerClock then
    return newest.Position
  end

  -- Search historical window backwards
  local prevSnap: EntitySnapshot? = nil
  local nextSnap: EntitySnapshot? = newest

  local idx = newestIdx
  for _ = 1, self.Count do
    local snap = self.Snapshots[idx]
    if snap then
      if snap.ServerClock <= targetTimestamp then
        prevSnap = snap
        break
      end
      nextSnap = snap
    end

    idx -= 1
    if idx < 1 then
      idx = BUFFER_CAPACITY
    end
  end

  if not prevSnap or not nextSnap then
    -- Return oldest recorded state if target is older than buffer history
    return if prevSnap then prevSnap.Position else if nextSnap then nextSnap.Position else nil
  end

  local dt = nextSnap.ServerClock - prevSnap.ServerClock
  if dt <= 0.0001 then
    return prevSnap.Position
  end

  local alpha = math.clamp((targetTimestamp - prevSnap.ServerClock) / dt, 0, 1)
  return prevSnap.Position:Lerp(nextSnap.Position, alpha)
end

-- Validate ray intersection against lag-compensated target hitbox
function RollbackBuffer:ValidateLagCompensatedHit(
  rayOrigin: Vector3,
  rayDirection: Vector3,
  maxDistance: number,
  clientTimestamp: number,
  hitboxTolerance: number
): boolean
  local historicalPos = self:SampleHistoricalPosition(clientTimestamp)
  if not historicalPos then
    return false
  end

  -- Calculate closest point on ray to the historical center
  local toCenter = historicalPos - rayOrigin
  local projection = toCenter:Dot(rayDirection)

  if projection < 0 or projection > maxDistance then
    return false
  end

  local closestPoint = rayOrigin + rayDirection * projection
  local distanceToCenter = (historicalPos - closestPoint).Magnitude

  -- Verify distance within sphere radius + tolerance
  return distanceToCenter <= (hitboxTolerance)
end

return RollbackBuffer
