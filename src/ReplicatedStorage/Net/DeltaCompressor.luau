--!strict
--[[
  DeltaCompressor.luau
  Production-grade delta-compressed network state serialization engine.
  Features bitmasked dirty-property tracking, fixed-point integer quantization,
  8-bit orientation packing, and binary buffer encoding for high-cadence
  multiplayer state replication with minimal network payload overhead.
  Part of crustdev studio game systems (Aetheria: Fractured Realms).
]]

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

export type EntityNetworkState = {
  EntityId: number,
  Position: typeof(Vector3.new(0, 0, 0)),
  Velocity: typeof(Vector3.new(0, 0, 0)),
  Yaw: number, -- Radians [0, 2*pi]
  Pitch: number, -- Radians [-pi/2, pi/2]
  Health: number, -- Unsigned integer [0, 65535]
  MaxHealth: number, -- Unsigned integer [0, 65535]
  StateFlags: number, -- 8-bit mask (Grounded, Sprinting, Crouching, etc.)
  AnimationId: number, -- 16-bit integer
}

export type SnapshotPacket = {
  Sequence: number,
  AckSequence: number,
  Entities: { EntityNetworkState },
}

local DIRTY_POSITION = 0x0001
local DIRTY_VELOCITY = 0x0002
local DIRTY_ORIENTATION = 0x0004
local DIRTY_HEALTH = 0x0008
local DIRTY_MAX_HEALTH = 0x0010
local DIRTY_STATE_FLAGS = 0x0020
local DIRTY_ANIMATION_ID = 0x0040

local POS_SCALE = 20 -- 0.05 stud resolution (1/20)
local VEL_SCALE = 10 -- 0.1 stud/s resolution (1/10)
local TWO_PI = math.pi * 2

local DeltaCompressor = {}
DeltaCompressor.__index = DeltaCompressor

DeltaCompressor.Flags = {
  DIRTY_POSITION = DIRTY_POSITION,
  DIRTY_VELOCITY = DIRTY_VELOCITY,
  DIRTY_ORIENTATION = DIRTY_ORIENTATION,
  DIRTY_HEALTH = DIRTY_HEALTH,
  DIRTY_MAX_HEALTH = DIRTY_MAX_HEALTH,
  DIRTY_STATE_FLAGS = DIRTY_STATE_FLAGS,
  DIRTY_ANIMATION_ID = DIRTY_ANIMATION_ID,
  ALL_DIRTY = 0x007F,
}

--[[
  Quantize float radians to unsigned 8-bit integer [0, 255]
]]
function DeltaCompressor.QuantizeYaw(yaw: number): number
  local norm = (yaw % TWO_PI + TWO_PI) % TWO_PI
  return math.floor((norm / TWO_PI) * 255 + 0.5) % 256
end

function DeltaCompressor.DequantizeYaw(u8: number): number
  return (u8 / 255) * TWO_PI
end

--[[
  Quantize pitch radians [-pi/2, pi/2] to signed 8-bit integer [-128, 127]
]]
function DeltaCompressor.QuantizePitch(pitch: number): number
  local halfPi = math.pi * 0.5
  local clamped = math.clamp(pitch, -halfPi, halfPi)
  local norm = clamped / halfPi -- [-1, 1]
  return math.clamp(math.floor(norm * 127 + 0.5), -128, 127)
end

function DeltaCompressor.DequantizePitch(i8: number): number
  return (i8 / 127) * (math.pi * 0.5)
end

--[[
  Compute dirty bitmask between baseline state and current state.
]]
function DeltaCompressor.ComputeDirtyMask(
  base: EntityNetworkState?,
  current: EntityNetworkState,
  forceAll: boolean?
): number
  if base == nil or forceAll == true then
    return DeltaCompressor.Flags.ALL_DIRTY
  end

  local mask = 0

  -- Check position delta (threshold 0.02 studs)
  if (current.Position - base.Position).Magnitude > 0.02 then
    mask = bit32.bor(mask, DIRTY_POSITION)
  end

  -- Check velocity delta (threshold 0.05 studs/s)
  if (current.Velocity - base.Velocity).Magnitude > 0.05 then
    mask = bit32.bor(mask, DIRTY_VELOCITY)
  end

  -- Check orientation delta
  local dyaw = math.abs(current.Yaw - base.Yaw)
  local dpitch = math.abs(current.Pitch - base.Pitch)
  if dyaw > 0.03 or dpitch > 0.03 then
    mask = bit32.bor(mask, DIRTY_ORIENTATION)
  end

  if current.Health ~= base.Health then
    mask = bit32.bor(mask, DIRTY_HEALTH)
  end

  if current.MaxHealth ~= base.MaxHealth then
    mask = bit32.bor(mask, DIRTY_MAX_HEALTH)
  end

  if current.StateFlags ~= base.StateFlags then
    mask = bit32.bor(mask, DIRTY_STATE_FLAGS)
  end

  if current.AnimationId ~= base.AnimationId then
    mask = bit32.bor(mask, DIRTY_ANIMATION_ID)
  end

  return mask
end

--[[
  Serialize a batch of entities against an optional table of baseline states.
  Returns a raw binary buffer with header and variable-length payload.
]]
function DeltaCompressor.SerializeSnapshot(
  seq: number,
  ackSeq: number,
  entities: { EntityNetworkState },
  baselines: { [number]: EntityNetworkState }?,
  forceKeyframe: boolean?
): any
  local baseLookup = baselines or {}
  -- Maximum possible size per entity is 2 (id) + 2 (mask) + 6 (pos) + 6 (vel) + 2 (rot) + 2 (hp) + 2 (maxhp) + 1 (flags) + 2 (anim) = 25 bytes
  -- Header: 2 (seq) + 2 (ack) + 2 (count) = 6 bytes
  local maxBufSize = 6 + (#entities * 25)
  local buf = buffer.create(maxBufSize)

  buffer.writeu16(buf, 0, seq % 65536)
  buffer.writeu16(buf, 2, ackSeq % 65536)
  buffer.writeu16(buf, 4, #entities)

  local cursor = 6

  for _, ent in ipairs(entities) do
    local base = baseLookup[ent.EntityId]
    local dirtyMask = DeltaCompressor.ComputeDirtyMask(base, ent, forceKeyframe)

    buffer.writeu16(buf, cursor, ent.EntityId)
    buffer.writeu16(buf, cursor + 2, dirtyMask)
    cursor += 4

    if bit32.btest(dirtyMask, DIRTY_POSITION) then
      buffer.writei16(buf, cursor, math.clamp(math.floor(ent.Position.X * POS_SCALE + 0.5), -32768, 32767))
      buffer.writei16(buf, cursor + 2, math.clamp(math.floor(ent.Position.Y * POS_SCALE + 0.5), -32768, 32767))
      buffer.writei16(buf, cursor + 4, math.clamp(math.floor(ent.Position.Z * POS_SCALE + 0.5), -32768, 32767))
      cursor += 6
    end

    if bit32.btest(dirtyMask, DIRTY_VELOCITY) then
      buffer.writei16(buf, cursor, math.clamp(math.floor(ent.Velocity.X * VEL_SCALE + 0.5), -32768, 32767))
      buffer.writei16(buf, cursor + 2, math.clamp(math.floor(ent.Velocity.Y * VEL_SCALE + 0.5), -32768, 32767))
      buffer.writei16(buf, cursor + 4, math.clamp(math.floor(ent.Velocity.Z * VEL_SCALE + 0.5), -32768, 32767))
      cursor += 6
    end

    if bit32.btest(dirtyMask, DIRTY_ORIENTATION) then
      local y8 = DeltaCompressor.QuantizeYaw(ent.Yaw)
      local p8 = DeltaCompressor.QuantizePitch(ent.Pitch)
      buffer.writeu8(buf, cursor, y8)
      buffer.writei8(buf, cursor + 1, p8)
      cursor += 2
    end

    if bit32.btest(dirtyMask, DIRTY_HEALTH) then
      buffer.writeu16(buf, cursor, math.clamp(ent.Health, 0, 65535))
      cursor += 2
    end

    if bit32.btest(dirtyMask, DIRTY_MAX_HEALTH) then
      buffer.writeu16(buf, cursor, math.clamp(ent.MaxHealth, 0, 65535))
      cursor += 2
    end

    if bit32.btest(dirtyMask, DIRTY_STATE_FLAGS) then
      buffer.writeu8(buf, cursor, bit32.band(ent.StateFlags, 0xFF))
      cursor += 1
    end

    if bit32.btest(dirtyMask, DIRTY_ANIMATION_ID) then
      buffer.writeu16(buf, cursor, math.clamp(ent.AnimationId, 0, 65535))
      cursor += 2
    end
  end

  -- Shrink buffer to actual serialized size
  local finalBuf = buffer.create(cursor)
  buffer.copy(finalBuf, 0, buf, 0, cursor)
  return finalBuf
end

--[[
  Deserialize buffer into updated entity states merged against client baselines.
]]
function DeltaCompressor.DeserializeSnapshot(
  buf: any,
  baselines: { [number]: EntityNetworkState }?
): (number, number, { EntityNetworkState })
  local baseLookup = baselines or {}
  local seq = buffer.readu16(buf, 0)
  local ackSeq = buffer.readu16(buf, 2)
  local count = buffer.readu16(buf, 4)

  local results = table.create(count)
  local cursor = 6

  for i = 1, count do
    local entityId = buffer.readu16(buf, cursor)
    local dirtyMask = buffer.readu16(buf, cursor + 2)
    cursor += 4

    local base = baseLookup[entityId]
    local state: EntityNetworkState = {
      EntityId = entityId,
      Position = if base then base.Position else Vector3.new(0, 0, 0),
      Velocity = if base then base.Velocity else Vector3.new(0, 0, 0),
      Yaw = if base then base.Yaw else 0,
      Pitch = if base then base.Pitch else 0,
      Health = if base then base.Health else 100,
      MaxHealth = if base then base.MaxHealth else 100,
      StateFlags = if base then base.StateFlags else 0,
      AnimationId = if base then base.AnimationId else 0,
    }

    if bit32.btest(dirtyMask, DIRTY_POSITION) then
      local qx = buffer.readi16(buf, cursor) / POS_SCALE
      local qy = buffer.readi16(buf, cursor + 2) / POS_SCALE
      local qz = buffer.readi16(buf, cursor + 4) / POS_SCALE
      state.Position = Vector3.new(qx, qy, qz)
      cursor += 6
    end

    if bit32.btest(dirtyMask, DIRTY_VELOCITY) then
      local vx = buffer.readi16(buf, cursor) / VEL_SCALE
      local vy = buffer.readi16(buf, cursor + 2) / VEL_SCALE
      local vz = buffer.readi16(buf, cursor + 4) / VEL_SCALE
      state.Velocity = Vector3.new(vx, vy, vz)
      cursor += 6
    end

    if bit32.btest(dirtyMask, DIRTY_ORIENTATION) then
      local y8 = buffer.readu8(buf, cursor)
      local p8 = buffer.readi8(buf, cursor + 1)
      state.Yaw = DeltaCompressor.DequantizeYaw(y8)
      state.Pitch = DeltaCompressor.DequantizePitch(p8)
      cursor += 2
    end

    if bit32.btest(dirtyMask, DIRTY_HEALTH) then
      state.Health = buffer.readu16(buf, cursor)
      cursor += 2
    end

    if bit32.btest(dirtyMask, DIRTY_MAX_HEALTH) then
      state.MaxHealth = buffer.readu16(buf, cursor)
      cursor += 2
    end

    if bit32.btest(dirtyMask, DIRTY_STATE_FLAGS) then
      state.StateFlags = buffer.readu8(buf, cursor)
      cursor += 1
    end

    if bit32.btest(dirtyMask, DIRTY_ANIMATION_ID) then
      state.AnimationId = buffer.readu16(buf, cursor)
      cursor += 2
    end

    results[i] = state
  end

  return seq, ackSeq, results
end

return DeltaCompressor
