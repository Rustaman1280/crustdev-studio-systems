--!strict
local ClockSync = require("../src/ReplicatedStorage/Net/ClockSync")

local EPSILON = 0.05

-- 1. Test initialization
local sync = ClockSync.new({
  SampleCapacity = 10,
  MinSamplesForSync = 4,
  OutlierThreshold = 2.0,
  EMAAlpha = 0.3,
})

assert(sync ~= nil, "ClockSync instance must not be nil")
assert(sync:GetSampleCount() == 0, "Initial sample count must be 0")
assert(sync.IsSynchronized == false, "Must not be synchronized initially")

-- 2. Test warm-up progression before minSamples
-- Simulate server clock ahead by +10.0 seconds with steady 40ms RTT (0.04s)
local baseClientTime = 100.0
local trueServerOffset = 10.0
local trueRTT = 0.040

for i = 1, 3 do
  local t0 = baseClientTime + (i * 0.5)
  local t1 = t0 + trueRTT
  local tServer = t0 + (trueRTT * 0.5) + trueServerOffset
  local accepted, _ = sync:ProcessSample(t0, tServer, t1)
  assert(accepted == true, string.format("Sample %d should be accepted", i))
  assert(sync.IsSynchronized == false, "Should not be synchronized before minSamples")
end

assert(sync:GetSampleCount() == 3, "Should have 3 samples recorded")

-- 3. Test reaching synchronization state
local t0_4 = baseClientTime + 2.0
local t1_4 = t0_4 + trueRTT
local tServer_4 = t0_4 + (trueRTT * 0.5) + trueServerOffset
local accepted4, offset4 = sync:ProcessSample(t0_4, tServer_4, t1_4)

assert(accepted4 == true, "Sample 4 should be accepted")
assert(sync.IsSynchronized == true, "Must become synchronized once minSamples reached")
assert(math.abs(offset4 - trueServerOffset) < EPSILON, string.format("Offset should be near +10.0, got %.4f", offset4))

local estimatedPing = sync:GetEstimatedPing()
assert(math.abs(estimatedPing - (trueRTT * 0.5)) < 0.01, string.format("Ping should be near 0.02s, got %.4f", estimatedPing))

local estimatedRTT = sync:GetRoundTripTime()
assert(math.abs(estimatedRTT - trueRTT) < 0.02, string.format("RTT should be near 0.04s, got %.4f", estimatedRTT))

-- 4. Test outlier / jitter rejection
-- Inject an extreme network lag hitch (RTT = 0.800s, 20x higher than normal)
local lagT0 = baseClientTime + 3.0
local lagT1 = lagT0 + 0.800
local lagTServer = lagT0 + (0.800 * 0.5) + trueServerOffset + 2.0 -- artificial skewed offset

local acceptedLag, offsetAfterLag = sync:ProcessSample(lagT0, lagTServer, lagT1)
assert(acceptedLag == false, "Lag spike sample must be rejected as an outlier")
assert(math.abs(offsetAfterLag - trueServerOffset) < EPSILON, "Offset must remain stable despite lag spike")

-- 5. Test strict monotonic server time progression
local st1 = sync:GetServerTime(105.0)
local st2 = sync:GetServerTime(105.001)
local st3 = sync:GetServerTime(104.999) -- simulated clock hitch or backward jump

assert(st2 >= st1, "Server time must not decrease on forward time")
assert(st3 >= st2, "Server time must never step backward even if local input retrogrades")

-- 6. Test timestamp conversions
local testLocal = 150.0
local convertedServer = sync:LocalToServerTime(testLocal)
local convertedBack = sync:ServerToLocalTime(convertedServer)
assert(math.abs(convertedBack - testLocal) < 0.0001, "Local <-> Server time conversion must round-trip cleanly")

-- 7. Test sample ring buffer capacity enforcement
for i = 5, 25 do
  local t0 = baseClientTime + (i * 0.2)
  local t1 = t0 + trueRTT
  local tServer = t0 + (trueRTT * 0.5) + trueServerOffset
  sync:ProcessSample(t0, tServer, t1)
end

assert(sync:GetSampleCount() == 10, string.format("Sample count must be capped at capacity 10, got %d", sync:GetSampleCount()))

-- 8. Test reset
sync:Reset()
assert(sync:GetSampleCount() == 0, "Sample count must be 0 after reset")
assert(sync.IsSynchronized == false, "Synchronized flag must be reset")
assert(sync.SmoothedOffset == 0.0, "Smoothed offset must be reset")

print("PASS: ClockSync tests (Warmup, Sync, Outlier rejection, Monotonicity, Conversion, Capacity, Reset) passed cleanly!")
