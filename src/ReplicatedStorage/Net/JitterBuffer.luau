--!strict
--[[
  JitterBuffer.luau
  crustdev studio systems - ReplicatedStorage/Net/JitterBuffer

  Enterprise-grade Adaptive Network Packet Jitter Buffer for multiplayer physics,
  action netcode, and state replication in Luau.

  Features:
  - Sequence number wrap-around handling (16-bit [0..65535] and 32-bit [0..4294967295]
    using modular arithmetic distance).
  - RFC 3550 statistical transit delay jitter estimation:
      D(i, j) = (recvTime - sendTime) - (prevRecvTime - prevSendTime)
      Jitter = Jitter + (|D| - Jitter) / 16
  - Adaptive playout target calculation with safety margins and dynamic bounds.
  - Sorted ring buffer / priority insertion for handling out-of-order packet delivery.
  - Stale and duplicate packet detection and rejection.
  - Packet Loss Concealment (PLC) trigger: emits concealment markers when an expected
    sequence frame has not arrived by its scheduled playout deadline.
  - Playout clock drift compensation via subtle time stretching (speedup / slowdown factors)
    to eliminate buffer starvation or overflow without audio or motion popping.
  - Comprehensive telemetry: packet counts, late drops, duplicate drops, jitter metrics,
    concealment frames, and buffer depth.
  - Zero external dependencies. Fully compatible with Roblox Engine and Lune runtime.
]]

export type Packet = {
  sequenceNumber: number,
  sendTimestamp: number, -- Seconds or milliseconds (must be consistent)
  receiveTimestamp: number?, -- Recorded upon buffer push if nil
  payload: any,
}

export type PlayoutItem = {
  isConcealed: boolean,
  sequenceNumber: number,
  sendTimestamp: number,
  playoutTimestamp: number,
  payload: any,
}

export type JitterBufferConfig = {
  targetDelayMs: number?, -- Baseline target playout delay in ms (default: 60)
  minDelayMs: number?, -- Minimum playout delay clamp in ms (default: 20)
  maxDelayMs: number?, -- Maximum playout delay clamp in ms (default: 350)
  jitterMultiplier: number?, -- Multiplier applied to jitter for target delay (default: 2.5)
  maxCapacity: number?, -- Maximum packet slots in buffer (default: 64)
  sequenceBitDepth: number?, -- 16 or 32 bit sequence numbers (default: 16)
  timeStretchEnabled: boolean?, -- Enable playout clock rate adjustments (default: true)
  maxTimeStretchRatio: number?, -- Max speed adjustment, e.g. 0.05 = [0.95x .. 1.05x] (default: 0.05)
  enableConcealment: boolean?, -- Emit placeholder frames for missed sequence items (default: true)
}

export type JitterBufferStats = {
  packetsReceived: number,
  packetsPlayout: number,
  duplicatesDropped: number,
  lateDropped: number,
  capacityDropped: number,
  concealmentFramesEmitted: number,
  currentJitterMs: number,
  currentPlayoutDelayMs: number,
  bufferDepth: number,
  lastPlayoutSequence: number?,
}

export type JitterBufferInterface = {
  PushPacket: (self: JitterBufferInterface, packet: Packet, currentTimeSeconds: number) -> (boolean, string?),
  PopPlayout: (self: JitterBufferInterface, currentTimeSeconds: number) -> { PlayoutItem },
  Peek: (self: JitterBufferInterface) -> Packet?,
  GetTimeStretchFactor: (self: JitterBufferInterface) -> number,
  GetStats: (self: JitterBufferInterface) -> JitterBufferStats,
  GetBufferDepth: (self: JitterBufferInterface) -> number,
  Flush: (self: JitterBufferInterface) -> (),
  Reset: (self: JitterBufferInterface) -> (),
}

local JitterBuffer = {}
JitterBuffer.__index = JitterBuffer

local DEFAULT_CONFIG: JitterBufferConfig = {
  targetDelayMs = 60,
  minDelayMs = 20,
  maxDelayMs = 350,
  jitterMultiplier = 2.5,
  maxCapacity = 64,
  sequenceBitDepth = 16,
  timeStretchEnabled = true,
  maxTimeStretchRatio = 0.05,
  enableConcealment = true,
}

--[[
  Compute modular sequence distance: returns (seqB - seqA) taking into account
  modular integer wrap-around. A positive result means seqB is ahead of seqA.
]]
local function sequenceDistance(seqA: number, seqB: number, maxSeq: number): number
  local halfMax = maxSeq / 2
  local diff = (seqB - seqA) % maxSeq
  if diff >= halfMax then
    return diff - maxSeq
  else
    return diff
  end
end

function JitterBuffer.new(customConfig: JitterBufferConfig?): JitterBufferInterface
  local cfg: JitterBufferConfig = {}
  for k, v in pairs(DEFAULT_CONFIG) do
    (cfg :: any)[k] = v
  end
  if customConfig then
    for k, v in pairs(customConfig) do
      (cfg :: any)[k] = v
    end
  end

  local bitDepth = cfg.sequenceBitDepth or 16
  local maxSeq = if bitDepth == 32 then 4294967296 else 65536

  local self = setmetatable({
    _config = cfg,
    _maxSeq = maxSeq,
    _queue = {} :: { Packet },

    -- Telemetry
    _packetsReceived = 0,
    _packetsPlayout = 0,
    _duplicatesDropped = 0,
    _lateDropped = 0,
    _capacityDropped = 0,
    _concealmentFrames = 0,

    -- RFC 3550 Jitter Estimation
    _jitterMs = 0,
    _prevTransitDelayMs = nil :: number?,
    _adaptiveDelayMs = cfg.targetDelayMs or 60,

    -- Playout Cursor Tracking
    _lastPlayoutSequence = nil :: number?,
    _playoutBaseTime = nil :: number?, -- Anchor for scheduled playback
    _expectedNextSequence = nil :: number?,
  }, JitterBuffer)

  return (self :: any) :: JitterBufferInterface
end

-- Push a newly received packet into the jitter buffer
function JitterBuffer:PushPacket(packet: Packet, currentTimeSeconds: number): (boolean, string?)
  local seq = packet.sequenceNumber
  local recvTime = packet.receiveTimestamp or currentTimeSeconds
  packet.receiveTimestamp = recvTime

  self._packetsReceived += 1

  -- Check if packet is stale/late relative to last played sequence
  if self._lastPlayoutSequence ~= nil then
    local distFromLast = sequenceDistance(self._lastPlayoutSequence, seq, self._maxSeq)
    if distFromLast <= 0 then
      self._lateDropped += 1
      return false, "LatePacket"
    end
  end

  -- RFC 3550 Jitter Computation
  -- Transit time difference: D(i, j) = (R_j - S_j) - (R_i - S_i)
  local transitDelayMs = (recvTime - packet.sendTimestamp) * 1000
  if self._prevTransitDelayMs ~= nil then
    local delayDiff = transitDelayMs - self._prevTransitDelayMs
    local absDiff = math.abs(delayDiff)
    -- RFC 3550 EWMA formula with gain 1/16
    self._jitterMs = self._jitterMs + (absDiff - self._jitterMs) * 0.0625
  end
  self._prevTransitDelayMs = transitDelayMs

  -- Dynamically adapt target playout delay based on smoothed jitter
  local cfg = self._config
  local targetWithJitter = (cfg.targetDelayMs or 60) + (self._jitterMs * (cfg.jitterMultiplier or 2.5))
  self._adaptiveDelayMs = math.clamp(targetWithJitter, cfg.minDelayMs or 20, cfg.maxDelayMs or 350)

  -- Check for duplicates and find sorted insertion index
  local queue: { Packet } = self._queue
  local insertIndex = #queue + 1

  for i, queuedPacket in ipairs(queue) do
    local dist = sequenceDistance(queuedPacket.sequenceNumber, seq, self._maxSeq)
    if dist == 0 then
      self._duplicatesDropped += 1
      return false, "DuplicatePacket"
    elseif dist < 0 then
      -- queuedPacket is ahead of incoming packet (incoming is older); insert before it
      insertIndex = i
      break
    end
  end

  -- Check capacity limits
  if #queue >= (cfg.maxCapacity or 64) then
    -- Drop lowest priority: if inserting at back, drop incoming; otherwise drop oldest
    if insertIndex > #queue then
      self._capacityDropped += 1
      return false, "BufferFull"
    else
      table.remove(queue, 1)
      self._capacityDropped += 1
      insertIndex = math.max(1, insertIndex - 1)
    end
  end

  table.insert(queue, insertIndex, packet)
  return true, nil
end

-- Pop all packets ready for playout up to currentTimeSeconds
function JitterBuffer:PopPlayout(currentTimeSeconds: number): { PlayoutItem }
  local readyItems: { PlayoutItem } = {}
  local queue: { Packet } = self._queue
  local playoutDelaySec = self._adaptiveDelayMs / 1000

  while #queue > 0 do
    local nextPacket = queue[1]
    local scheduledPlayoutTime = nextPacket.sendTimestamp + playoutDelaySec

    if scheduledPlayoutTime > currentTimeSeconds then
      -- Next packet is not yet scheduled for playout
      break
    end

    -- Packet is ready for playback!
    table.remove(queue, 1)

    -- Check for missing sequence numbers (Packet Loss Concealment)
    if self._config.enableConcealment and self._expectedNextSequence ~= nil then
      local gap = sequenceDistance(self._expectedNextSequence, nextPacket.sequenceNumber, self._maxSeq)
      if gap > 0 then
        -- We have a sequence gap: emit concealment frames for the missing packets
        for missingSeqOffset = 0, gap - 1 do
          local missingSeq = (self._expectedNextSequence + missingSeqOffset) % self._maxSeq
          self._concealmentFrames += 1
          local concealedItem: PlayoutItem = {
            isConcealed = true,
            sequenceNumber = missingSeq,
            sendTimestamp = nextPacket.sendTimestamp - (playoutDelaySec * (gap - missingSeqOffset) / gap),
            playoutTimestamp = currentTimeSeconds,
            payload = nil,
          }
          table.insert(readyItems, concealedItem)
        end
      end
    end

    local item: PlayoutItem = {
      isConcealed = false,
      sequenceNumber = nextPacket.sequenceNumber,
      sendTimestamp = nextPacket.sendTimestamp,
      playoutTimestamp = scheduledPlayoutTime,
      payload = nextPacket.payload,
    }

    table.insert(readyItems, item)
    self._packetsPlayout += 1
    self._lastPlayoutSequence = nextPacket.sequenceNumber
    self._expectedNextSequence = (nextPacket.sequenceNumber + 1) % self._maxSeq
  end

  return readyItems
end

function JitterBuffer:Peek(): Packet?
  return self._queue[1]
end

--[[
  Calculates adaptive time stretch multiplier for game clock / simulation rate.
  - If buffer is overflowing, speed up slightly (e.g. 1.05x).
  - If buffer is starving, slow down slightly (e.g. 0.95x).
]]
function JitterBuffer:GetTimeStretchFactor(): number
  if not self._config.timeStretchEnabled then
    return 1.0
  end

  local depth = #self._queue
  local targetDepth = math.ceil(self._adaptiveDelayMs / 20) -- Nominal expected frames
  local maxStretch = self._config.maxTimeStretchRatio or 0.05

  if depth > targetDepth * 1.5 then
    -- Buffer filling up: speed up playout
    return 1.0 + maxStretch
  elseif depth < targetDepth * 0.5 and depth > 0 then
    -- Buffer draining: slow down playout
    return 1.0 - maxStretch
  else
    return 1.0
  end
end

function JitterBuffer:GetBufferDepth(): number
  return #self._queue
end

function JitterBuffer:GetStats(): JitterBufferStats
  return {
    packetsReceived = self._packetsReceived,
    packetsPlayout = self._packetsPlayout,
    duplicatesDropped = self._duplicatesDropped,
    lateDropped = self._lateDropped,
    capacityDropped = self._capacityDropped,
    concealmentFramesEmitted = self._concealmentFrames,
    currentJitterMs = math.floor(self._jitterMs * 100) / 100,
    currentPlayoutDelayMs = math.floor(self._adaptiveDelayMs * 100) / 100,
    bufferDepth = #self._queue,
    lastPlayoutSequence = self._lastPlayoutSequence,
  }
end

function JitterBuffer:Flush(): ()
  table.clear(self._queue)
end

function JitterBuffer:Reset(): ()
  table.clear(self._queue)
  self._packetsReceived = 0
  self._packetsPlayout = 0
  self._duplicatesDropped = 0
  self._lateDropped = 0
  self._capacityDropped = 0
  self._concealmentFrames = 0
  self._jitterMs = 0
  self._prevTransitDelayMs = nil
  self._lastPlayoutSequence = nil
  self._expectedNextSequence = nil
  self._adaptiveDelayMs = self._config.targetDelayMs or 60
end

return JitterBuffer
