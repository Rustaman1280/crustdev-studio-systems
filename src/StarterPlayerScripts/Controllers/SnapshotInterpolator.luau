--!strict
--[[
  SnapshotInterpolator.luau
  Client-side entity transform interpolation with cubic Hermite curves and RTT jitter compensation.
  Part of crustdev studio game systems.
  Zero dependencies, pure Luau execution.
]]

export type EntitySnapshot = {
  Position: Vector3,
  Velocity: Vector3,
  OrientationY: number,
  Timestamp: number,
}

export type Interpolator = {
  EntityId: string | number,
  Buffer: { EntitySnapshot },
  InterpolationDelay: number,
  MaxExtrapolationTime: number,
}

local SnapshotInterpolator = {}
SnapshotInterpolator.__index = SnapshotInterpolator

local DEFAULT_INTERPOLATION_DELAY = 0.10 -- 100ms buffer
local MAX_EXTRAPOLATION_TIME = 0.15 -- 150ms maximum dead-reckoning extrapolation
local MAX_BUFFER_CAPACITY = 64

-- Normalizes angle in radians to [-pi, pi]
local function normalizeAngle(angle: number): number
  local twoPi = math.pi * 2
  angle = angle % twoPi
  if angle > math.pi then
    angle -= twoPi
  elseif angle < -math.pi then
    angle += twoPi
  end
  return angle
end

-- Shortest-path angular interpolation
local function lerpAngle(a: number, b: number, t: number): number
  local diff = normalizeAngle(b - a)
  return a + diff * t
end

-- Hermite cubic spline interpolation with velocity tangents
local function hermiteCubic(p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, dt: number, t: number): Vector3
  local t2 = t * t
  local t3 = t2 * t

  local h00 = 2 * t3 - 3 * t2 + 1
  local h10 = t3 - 2 * t2 + t
  local h01 = -2 * t3 + 3 * t2
  local h11 = t3 - t2

  -- Scale velocity derivatives by interval dt
  local m0 = v0 * dt
  local m1 = v1 * dt

  return p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11
end

function SnapshotInterpolator.new(entityId: string | number, interpolationDelay: number?): Interpolator
  local delay = interpolationDelay or DEFAULT_INTERPOLATION_DELAY
  if delay <= 0 then
    delay = DEFAULT_INTERPOLATION_DELAY
  end

  local self: Interpolator = {
    EntityId = entityId,
    Buffer = {},
    InterpolationDelay = delay,
    MaxExtrapolationTime = MAX_EXTRAPOLATION_TIME,
  }

  return setmetatable(self :: any, SnapshotInterpolator) :: any
end

function SnapshotInterpolator.PushSnapshot(
  self: Interpolator,
  position: Vector3,
  velocity: Vector3,
  orientationY: number,
  serverTimestamp: number
)
  local snapshot: EntitySnapshot = {
    Position = position,
    Velocity = velocity,
    OrientationY = orientationY,
    Timestamp = serverTimestamp,
  }

  local buf = self.Buffer
  local count = #buf

  -- Insert sorted by timestamp
  if count == 0 or serverTimestamp >= buf[count].Timestamp then
    table.insert(buf, snapshot)
  else
    local insertIdx = count
    for i = count, 1, -1 do
      if serverTimestamp >= buf[i].Timestamp then
        insertIdx = i + 1
        break
      elseif i == 1 then
        insertIdx = 1
      end
    end
    table.insert(buf, insertIdx, snapshot)
  end

  -- Prune old snapshots exceeding maximum buffer capacity
  while #buf > MAX_BUFFER_CAPACITY do
    table.remove(buf, 1)
  end
end

function SnapshotInterpolator.Sample(
  self: Interpolator,
  currentClock: number
): (Vector3?, number?, boolean)
  local buf = self.Buffer
  local count = #buf

  if count == 0 then
    return nil, nil, false
  end

  local renderTime = currentClock - self.InterpolationDelay

  -- Case 1: Only 1 snapshot available
  if count == 1 then
    local s = buf[1]
    local dt = math.clamp(renderTime - s.Timestamp, 0, self.MaxExtrapolationTime)
    local extrapolatedPos = s.Position + s.Velocity * dt
    return extrapolatedPos, s.OrientationY, false
  end

  -- Case 2: Render time is older than oldest snapshot
  if renderTime <= buf[1].Timestamp then
    local s = buf[1]
    return s.Position, s.OrientationY, true
  end

  -- Case 3: Render time is beyond newest snapshot (extrapolation)
  local latest = buf[count]
  if renderTime >= latest.Timestamp then
    local dt = renderTime - latest.Timestamp
    if dt > self.MaxExtrapolationTime then
      dt = self.MaxExtrapolationTime
    end
    -- Damped extrapolation: decelerate velocity over extrapolation window
    local damping = 1.0 - (dt / self.MaxExtrapolationTime) * 0.5
    local extrapolatedPos = latest.Position + (latest.Velocity * damping) * dt
    return extrapolatedPos, latest.OrientationY, false
  end

  -- Case 4: Interpolate between two surrounding snapshots
  for i = 1, count - 1 do
    local s0 = buf[i]
    local s1 = buf[i + 1]

    if s0.Timestamp <= renderTime and renderTime <= s1.Timestamp then
      local interval = s1.Timestamp - s0.Timestamp
      if interval <= 0.0001 then
        return s1.Position, s1.OrientationY, true
      end

      local alpha = (renderTime - s0.Timestamp) / interval
      local pos = hermiteCubic(s0.Position, s0.Velocity, s1.Position, s1.Velocity, interval, alpha)
      local rotY = lerpAngle(s0.OrientationY, s1.OrientationY, alpha)

      -- Prune snapshots older than s0 to keep buffer light
      if i > 2 then
        for _ = 1, i - 1 do
          table.remove(buf, 1)
        end
      end

      return pos, rotY, true
    end
  end

  return latest.Position, latest.OrientationY, false
end

function SnapshotInterpolator.Clear(self: Interpolator)
  table.clear(self.Buffer)
end

return SnapshotInterpolator