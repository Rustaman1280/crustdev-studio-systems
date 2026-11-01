--!strict
--[[
  ClockSync.luau
  Client-server clock synchronization engine based on Cristian's algorithm with outlier rejection,
  minimum-RTT window filtering, and monotonic clock progression.
  Part of crustdev studio game systems.
  Zero dependencies, pure Luau execution.
]]

export type SyncSample = {
  T0: number,        -- Client request dispatch timestamp (local clock)
  TServer: number,   -- Server receive/respond timestamp (server clock)
  T1: number,        -- Client response arrival timestamp (local clock)
  RTT: number,       -- Round-trip time (T1 - T0)
  RawOffset: number, -- Calculated clock offset: TServer - (T0 + RTT / 2)
}

export type ClockSyncConfig = {
  SampleCapacity: number?,
  MinSamplesForSync: number?,
  OutlierThreshold: number?,
  EMAAlpha: number?,
}

export type ClockSync = {
  SampleCapacity: number,
  MinSamplesForSync: number,
  OutlierThreshold: number,
  EMAAlpha: number,
  Samples: { SyncSample },
  SmoothedOffset: number,
  SmoothedRTT: number,
  BestRTT: number,
  LastSampleTime: number,
  LastReportedServerTime: number,
  IsSynchronized: boolean,

  -- Methods
  ProcessSample: (self: ClockSync, t0: number, tServer: number, t1: number) -> (boolean, number),
  GetServerTime: (self: ClockSync, localTime: number?) -> number,
  LocalToServerTime: (self: ClockSync, localTime: number) -> number,
  ServerToLocalTime: (self: ClockSync, serverTime: number) -> number,
  GetEstimatedPing: (self: ClockSync) -> number,
  GetRoundTripTime: (self: ClockSync) -> number,
  GetSampleCount: (self: ClockSync) -> number,
  Reset: (self: ClockSync) -> (),
}

local ClockSyncImpl = {}
ClockSyncImpl.__index = ClockSyncImpl

local DEFAULT_SAMPLE_CAPACITY = 20
local DEFAULT_MIN_SAMPLES = 5
local DEFAULT_OUTLIER_THRESHOLD = 2.0
local DEFAULT_EMA_ALPHA = 0.25
local MIN_RTT_EPSILON = 0.0001

-- Create a new ClockSync coordinator instance
function ClockSyncImpl.new(config: ClockSyncConfig?): ClockSync
  local cfg = config or {}
  local capacity = cfg.SampleCapacity or DEFAULT_SAMPLE_CAPACITY
  local minSamples = cfg.MinSamplesForSync or DEFAULT_MIN_SAMPLES
  local outlierThreshold = cfg.OutlierThreshold or DEFAULT_OUTLIER_THRESHOLD
  local emaAlpha = cfg.EMAAlpha or DEFAULT_EMA_ALPHA

  if capacity < 3 then
    capacity = 3
  end
  if minSamples < 2 then
    minSamples = 2
  end

  local self = setmetatable({
    SampleCapacity = capacity,
    MinSamplesForSync = minSamples,
    OutlierThreshold = outlierThreshold,
    EMAAlpha = emaAlpha,
    Samples = {},
    SmoothedOffset = 0.0,
    SmoothedRTT = 0.0,
    BestRTT = math.huge,
    LastSampleTime = 0.0,
    LastReportedServerTime = -math.huge,
    IsSynchronized = false,
  }, ClockSyncImpl)

  return (self :: any) :: ClockSync
end

-- Process a network round-trip ping sample: (t0, tServer, t1)
function ClockSyncImpl:ProcessSample(t0: number, tServer: number, t1: number): (boolean, number)
  local rtt = t1 - t0
  if rtt < 0 then
    rtt = MIN_RTT_EPSILON
  elseif rtt < MIN_RTT_EPSILON then
    rtt = MIN_RTT_EPSILON
  end

  local rawOffset = tServer - (t0 + rtt * 0.5)

  -- Outlier detection: if we have sufficient samples, reject spikes caused by frame hitches or bufferbloat
  if #self.Samples >= self.MinSamplesForSync then
    -- Compute median RTT across historical samples
    local rttCopy: { number } = table.create(#self.Samples)
    for i, s in ipairs(self.Samples) do
      rttCopy[i] = s.RTT
    end
    table.sort(rttCopy)
    local medianRTT = rttCopy[math.ceil(#rttCopy * 0.5)]

    -- If RTT exceeds outlier threshold relative to median and best, reject sample
    if rtt > (medianRTT * self.OutlierThreshold) and rtt > (self.BestRTT * 2.2) then
      return false, self.SmoothedOffset
    end
  end

  -- Record sample in ring buffer
  local sample: SyncSample = {
    T0 = t0,
    TServer = tServer,
    T1 = t1,
    RTT = rtt,
    RawOffset = rawOffset,
  }

  if #self.Samples >= self.SampleCapacity then
    table.remove(self.Samples, 1)
  end
  table.insert(self.Samples, sample)

  if rtt < self.BestRTT then
    self.BestRTT = rtt
  end

  self.LastSampleTime = t1

  -- Calculate weighted offset favoring lowest RTT samples (minimum queue delay)
  local sampleCount = #self.Samples
  if sampleCount < self.MinSamplesForSync then
    -- Initial warm-up: standard exponential moving average
    if sampleCount == 1 then
      self.SmoothedOffset = rawOffset
      self.SmoothedRTT = rtt
    else
      self.SmoothedOffset = self.SmoothedOffset * (1 - self.EMAAlpha) + rawOffset * self.EMAAlpha
      self.SmoothedRTT = self.SmoothedRTT * (1 - self.EMAAlpha) + rtt * self.EMAAlpha
    end
    self.IsSynchronized = false
  else
    -- Multi-sample window: sort by RTT and take the lowest 50% quartile
    local sorted: { SyncSample } = table.clone(self.Samples)
    table.sort(sorted, function(a, b)
      return a.RTT < b.RTT
    end)

    local bestHalfCount = math.max(1, math.floor(sampleCount * 0.5))
    local weightedOffsetSum = 0.0
    local totalWeight = 0.0
    local rttSum = 0.0

    for i = 1, bestHalfCount do
      local s = sorted[i]
      -- Weight inversely proportional to RTT
      local weight = 1.0 / math.max(s.RTT, 0.001)
      weightedOffsetSum += s.RawOffset * weight
      totalWeight += weight
      rttSum += s.RTT
    end

    local estimatedBestOffset = weightedOffsetSum / totalWeight
    local averageBestRTT = rttSum / bestHalfCount

    -- Smooth estimated offset with previous value to prevent jarring time warps
    self.SmoothedOffset = self.SmoothedOffset * (1 - self.EMAAlpha) + estimatedBestOffset * self.EMAAlpha
    self.SmoothedRTT = self.SmoothedRTT * (1 - self.EMAAlpha) + averageBestRTT * self.EMAAlpha
    self.IsSynchronized = true
  end

  return true, self.SmoothedOffset
end

-- Get current monotonic server time estimated from local client clock
function ClockSyncImpl:GetServerTime(localTime: number?): number
  local now = localTime or os.clock()
  local estimatedServerTime = now + self.SmoothedOffset

  -- Strict monotonic progression guarantee: never allow server time to step backward
  if estimatedServerTime < self.LastReportedServerTime then
    estimatedServerTime = self.LastReportedServerTime
  else
    self.LastReportedServerTime = estimatedServerTime
  end

  return estimatedServerTime
end

-- Convert local client timestamp to server timestamp
function ClockSyncImpl:LocalToServerTime(localTime: number): number
  return localTime + self.SmoothedOffset
end

-- Convert server timestamp to local client timestamp
function ClockSyncImpl:ServerToLocalTime(serverTime: number): number
  return serverTime - self.SmoothedOffset
end

-- Get estimated one-way network latency in seconds (ping)
function ClockSyncImpl:GetEstimatedPing(): number
  return self.SmoothedRTT * 0.5
end

-- Get estimated full round-trip network time in seconds
function ClockSyncImpl:GetRoundTripTime(): number
  return self.SmoothedRTT
end

-- Get count of active samples in buffer
function ClockSyncImpl:GetSampleCount(): number
  return #self.Samples
end

-- Reset state
function ClockSyncImpl:Reset(): ()
  table.clear(self.Samples)
  self.SmoothedOffset = 0.0
  self.SmoothedRTT = 0.0
  self.BestRTT = math.huge
  self.LastSampleTime = 0.0
  self.LastReportedServerTime = -math.huge
  self.IsSynchronized = false
end

return ClockSyncImpl
