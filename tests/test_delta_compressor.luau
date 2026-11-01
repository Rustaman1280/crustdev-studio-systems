--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local DeltaCompressor = require("../src/ReplicatedStorage/Net/DeltaCompressor")

-- 1. Test Angle Quantization Roundtrips
local testAngles = { 0, math.pi * 0.25, math.pi * 0.5, math.pi, math.pi * 1.5 }
for _, ang in ipairs(testAngles) do
  local q = DeltaCompressor.QuantizeYaw(ang)
  local deq = DeltaCompressor.DequantizeYaw(q)
  assert(math.abs(deq - ang) < 0.03, string.format("Yaw quantization roundtrip drift too high: %.4f vs %.4f", deq, ang))
end

local testPitches = { -math.pi * 0.45, -math.pi * 0.2, 0, math.pi * 0.2, math.pi * 0.45 }
for _, p in ipairs(testPitches) do
  local q = DeltaCompressor.QuantizePitch(p)
  local deq = DeltaCompressor.DequantizePitch(q)
  assert(math.abs(deq - p) < 0.03, string.format("Pitch quantization roundtrip drift too high: %.4f vs %.4f", deq, p))
end

-- 2. Test Dirty Mask Computation
local entityA = {
  EntityId = 101,
  Position = Vector3.new(10, 5, 20),
  Velocity = Vector3.new(0, 0, 0),
  Yaw = 1.57,
  Pitch = 0,
  Health = 100,
  MaxHealth = 100,
  StateFlags = 1,
  AnimationId = 42,
}

local unchangedMask = DeltaCompressor.ComputeDirtyMask(entityA, entityA)
assert(unchangedMask == 0, "Unchanged entity must produce dirty mask 0")

local movedEntity = {
  EntityId = 101,
  Position = Vector3.new(12, 5, 20), -- moved 2 studs
  Velocity = Vector3.new(0, 0, 0),
  Yaw = 1.57,
  Pitch = 0,
  Health = 85, -- damaged
  MaxHealth = 100,
  StateFlags = 1,
  AnimationId = 42,
}

local changedMask = DeltaCompressor.ComputeDirtyMask(entityA, movedEntity)
assert(bit32.btest(changedMask, DeltaCompressor.Flags.DIRTY_POSITION), "Should flag DIRTY_POSITION")
assert(bit32.btest(changedMask, DeltaCompressor.Flags.DIRTY_HEALTH), "Should flag DIRTY_HEALTH")
assert(not bit32.btest(changedMask, DeltaCompressor.Flags.DIRTY_VELOCITY), "Should NOT flag DIRTY_VELOCITY")
assert(not bit32.btest(changedMask, DeltaCompressor.Flags.DIRTY_ANIMATION_ID), "Should NOT flag DIRTY_ANIMATION_ID")

-- 3. Test Full Keyframe Serialization & Deserialization
local entities = { entityA, movedEntity }
local keyframeBuf = DeltaCompressor.SerializeSnapshot(1, 0, entities, nil, true)
assert(keyframeBuf ~= nil, "Keyframe buffer should not be nil")

local seq, ackSeq, decoded = DeltaCompressor.DeserializeSnapshot(keyframeBuf, nil)
assert(seq == 1, "Sequence must match")
assert(ackSeq == 0, "AckSequence must match")
assert(#decoded == 2, "Decoded count must match")

local d1 = decoded[1]
assert(d1.EntityId == 101, "EntityId should match")
assert((d1.Position - entityA.Position).Magnitude < 0.06, "Position within quantization bounds")
assert(d1.Health == entityA.Health, "Health should match")
assert(d1.AnimationId == entityA.AnimationId, "AnimationId should match")

-- 4. Test Delta Compression Efficiency
local baselines = {
  [101] = entityA,
}
local currentEntities = { movedEntity }

local deltaBuf = DeltaCompressor.SerializeSnapshot(2, 1, currentEntities, baselines, false)
local keyframeSize = buffer.len(keyframeBuf)
local deltaSize = buffer.len(deltaBuf)

assert(deltaSize < keyframeSize, string.format("Delta size (%d) should be smaller than keyframe size (%d)", deltaSize, keyframeSize))

-- Verify baseline merge restoration on client
local dSeq, dAck, deltaDecoded = DeltaCompressor.DeserializeSnapshot(deltaBuf, baselines)
assert(dSeq == 2, "Delta sequence should be 2")
assert(#deltaDecoded == 1, "Should have 1 entity")
local restored = deltaDecoded[1]
assert(restored.EntityId == 101, "Restored id match")
assert((restored.Position - movedEntity.Position).Magnitude < 0.06, "Restored position matches new state")
assert(restored.Health == 85, "Restored health matches new state")
assert(restored.AnimationId == 42, "Preserved baseline animation id")
assert(restored.MaxHealth == 100, "Preserved baseline max health")

-- 5. Batch Performance Test (100 entities)
local batch = {}
for i = 1, 100 do
  table.insert(batch, {
    EntityId = i,
    Position = Vector3.new(i * 2, 0, i * 3),
    Velocity = Vector3.new(0, 0, 5),
    Yaw = 0.5,
    Pitch = 0,
    Health = 100,
    MaxHealth = 100,
    StateFlags = 1,
    AnimationId = 10,
  })
end

local batchBuf = DeltaCompressor.SerializeSnapshot(100, 99, batch, nil, true)
local bSeq, bAck, bDecoded = DeltaCompressor.DeserializeSnapshot(batchBuf, nil)
assert(#bDecoded == 100, "All 100 entities must deserialize accurately")
assert(bDecoded[50].EntityId == 50, "Entity 50 id match")

print("PASS: DeltaCompressor tests (Yaw/Pitch quantization, Dirty masks, Keyframe serialization, Delta buffer efficiency, Baseline merging, Batch serialization) passed cleanly!")
