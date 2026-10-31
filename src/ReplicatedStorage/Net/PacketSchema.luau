--!strict
--[[
  PacketSchema.luau
  Strict typed packet serialization and verification contracts for Roblox multiplayer netcode.
  Part of crustdev studio game systems.
]]

export type PacketHeader = {
  Sequence: number,
  Timestamp: number,
  Channel: string,
}

export type TransformSnapshot = {
  Position: Vector3,
  Velocity: Vector3,
  OrientationY: number,
  Tick: number,
}

export type HitIntentPacket = {
  Header: PacketHeader,
  TargetId: number,
  ClientOrigin: Vector3,
  HitDirection: Vector3,
  WeaponId: string,
  ClientEstimatedLag: number,
}

local PacketSchema = {}

local MAX_ALLOWED_VELOCITY = 250.0 -- studs per second
local MAX_TIMESTAMP_DRIFT = 1.5 -- seconds

function PacketSchema.CreateHeader(sequence: number, channel: string): PacketHeader
  return {
    Sequence = sequence,
    Timestamp = os.clock(),
    Channel = channel,
  }
end

-- Validate client hit packet for anti-exploit sanitization
function PacketSchema.ValidateHitIntent(packet: any): (boolean, string?)
  if type(packet) ~= "table" then
    return false, "Malformed packet: expected table"
  end

  local header = packet.Header
  if type(header) ~= "table" then
    return false, "Missing packet header"
  end

  if type(header.Sequence) ~= "number" or header.Sequence < 0 then
    return false, "Invalid packet sequence number"
  end

  if type(header.Timestamp) ~= "number" then
    return false, "Invalid timestamp"
  end

  local timeDrift = math.abs(os.clock() - header.Timestamp)
  if timeDrift > MAX_TIMESTAMP_DRIFT then
    return false, string.format("Timestamp drift exceeded limit: %.3fs", timeDrift)
  end

  if type(packet.TargetId) ~= "number" then
    return false, "Invalid TargetId"
  end

  if typeof(packet.ClientOrigin) ~= "Vector3" then
    return false, "ClientOrigin must be Vector3"
  end

  if typeof(packet.HitDirection) ~= "Vector3" then
    return false, "HitDirection must be Vector3"
  end

  local dirMagnitude = packet.HitDirection.Magnitude
  if math.abs(dirMagnitude - 1.0) > 0.05 then
    return false, "HitDirection must be normalized unit vector"
  end

  if type(packet.WeaponId) ~= "string" or #packet.WeaponId == 0 or #packet.WeaponId > 64 then
    return false, "Invalid WeaponId string length"
  end

  return true, nil
end

-- Quantize Vector3 coordinates for efficient network serialization (0.01 stud precision)
function PacketSchema.CompressVector3(v: Vector3): (number, number, number)
  local qx = math.round(v.X * 100)
  local qy = math.round(v.Y * 100)
  local qz = math.round(v.Z * 100)
  return qx, qy, qz
end

function PacketSchema.DecompressVector3(qx: number, qy: number, qz: number): Vector3
  return Vector3.new(qx / 100.0, qy / 100.0, qz / 100.0)
end

return PacketSchema
