local JitterBuffer = require("../src/ReplicatedStorage/Net/JitterBuffer")

-- Test 1: Initialization and Defaults
local jb = JitterBuffer.new({
  targetDelayMs = 50,
  minDelayMs = 20,
  maxDelayMs = 200,
  jitterMultiplier = 2.0,
  maxCapacity = 32,
  sequenceBitDepth = 16,
  enableConcealment = true,
})

local stats = jb:GetStats()
assert(stats.packetsReceived == 0, "Initial packets received must be 0")
assert(stats.packetsPlayout == 0, "Initial packets playout must be 0")
assert(stats.bufferDepth == 0, "Buffer depth must be 0")
assert(jb:GetBufferDepth() == 0, "GetBufferDepth must be 0")

-- Test 2: In-Order Packet Insertion and Playout Timing
local t0 = 100.0
local ok1, err1 = jb:PushPacket({ sequenceNumber = 1, sendTimestamp = t0, payload = "p1" }, t0 + 0.01)
assert(ok1 == true and err1 == nil, "Packet 1 push must succeed")

local ok2, err2 = jb:PushPacket({ sequenceNumber = 2, sendTimestamp = t0 + 0.02, payload = "p2" }, t0 + 0.03)
assert(ok2 == true and err2 == nil, "Packet 2 push must succeed")

assert(jb:GetBufferDepth() == 2, "Buffer depth should be 2")

-- Immediate pop at t0 + 0.02 should yield nothing because target delay is 50ms (scheduled at t0 + 0.05)
local earlyPop = jb:PopPlayout(t0 + 0.02)
assert(#earlyPop == 0, "Early pop should yield 0 packets")

-- Pop at t0 + 0.06 should yield Packet 1 (scheduled at t0 + 0.05) but not Packet 2 (scheduled at t0 + 0.07)
local pop1 = jb:PopPlayout(t0 + 0.06)
assert(#pop1 == 1, "Should pop exactly 1 packet, got " .. tostring(#pop1))
assert(pop1[1].sequenceNumber == 1, "Popped packet sequence must be 1")
assert(pop1[1].isConcealed == false, "Packet must not be concealed")
assert(pop1[1].payload == "p1", "Payload must match p1")

-- Pop at t0 + 0.08 should yield Packet 2
local pop2 = jb:PopPlayout(t0 + 0.08)
assert(#pop2 == 1, "Should pop packet 2")
assert(pop2[1].sequenceNumber == 2, "Popped packet sequence must be 2")

-- Test 3: Out-of-Order Packet Insertion and Reordering
-- Push sequence 5, then sequence 3, then sequence 4
local tBase = 200.0
jb:PushPacket({ sequenceNumber = 5, sendTimestamp = tBase + 0.04, payload = "p5" }, tBase + 0.05)
jb:PushPacket({ sequenceNumber = 3, sendTimestamp = tBase, payload = "p3" }, tBase + 0.02)
jb:PushPacket({ sequenceNumber = 4, sendTimestamp = tBase + 0.02, payload = "p4" }, tBase + 0.03)

assert(jb:GetBufferDepth() == 3, "Buffer depth should be 3")

-- Playout order should be strictly sorted: 3, 4, 5
local popAll = jb:PopPlayout(tBase + 0.20)
assert(#popAll == 3, "Should pop 3 packets, got " .. tostring(#popAll))
assert(popAll[1].sequenceNumber == 3, "First packet must be 3")
assert(popAll[2].sequenceNumber == 4, "Second packet must be 4")
assert(popAll[3].sequenceNumber == 5, "Third packet must be 5")

-- Test 4: Duplicate Packet Detection
local dupPush, dupErr = jb:PushPacket({ sequenceNumber = 5, sendTimestamp = tBase + 0.04, payload = "p5_dup" }, tBase + 0.21)
assert(dupPush == false, "Duplicate packet must be rejected")
assert(dupErr == "LatePacket" or dupErr == "DuplicatePacket", "Error should indicate duplicate or late")
assert(jb:GetStats().lateDropped > 0 or jb:GetStats().duplicatesDropped > 0, "Stats must record duplicate/late drop")

-- Test 5: Late Packet Detection (Arriving after playout cursor has passed)
-- Last played sequence is 5; pushing sequence 4 should be dropped as late
local latePush, lateErr = jb:PushPacket({ sequenceNumber = 4, sendTimestamp = tBase + 0.02, payload = "stale" }, tBase + 0.22)
assert(latePush == false, "Stale packet must be rejected")
assert(lateErr == "LatePacket", "Error should be LatePacket")

-- Test 6: Sequence Number Wrap-Around (16-bit uint: 65534 -> 65535 -> 0 -> 1)
local wrapJb = JitterBuffer.new({ sequenceBitDepth = 16, targetDelayMs = 20, minDelayMs = 10, enableConcealment = false })
local tWrap = 300.0
wrapJb:PushPacket({ sequenceNumber = 65534, sendTimestamp = tWrap, payload = "pre_wrap1" }, tWrap + 0.01)
wrapJb:PushPacket({ sequenceNumber = 65535, sendTimestamp = tWrap + 0.01, payload = "pre_wrap2" }, tWrap + 0.02)
wrapJb:PushPacket({ sequenceNumber = 0, sendTimestamp = tWrap + 0.02, payload = "zero_wrap" }, tWrap + 0.03)
wrapJb:PushPacket({ sequenceNumber = 1, sendTimestamp = tWrap + 0.03, payload = "post_wrap" }, tWrap + 0.04)

local wrapItems = wrapJb:PopPlayout(tWrap + 0.1)
assert(#wrapItems == 4, "All 4 wrapped packets should pop, got " .. tostring(#wrapItems))
assert(wrapItems[1].sequenceNumber == 65534, "Seq 1 should be 65534")
assert(wrapItems[2].sequenceNumber == 65535, "Seq 2 should be 65535")
assert(wrapItems[3].sequenceNumber == 0, "Seq 3 should wrap to 0")
assert(wrapItems[4].sequenceNumber == 1, "Seq 4 should be 1")

-- Test 7: RFC 3550 Statistical Transit Jitter Calculation
local jitterJb = JitterBuffer.new({ targetDelayMs = 50, minDelayMs = 20, maxDelayMs = 300, jitterMultiplier = 2.0 })
local tJ = 400.0
-- Normal transit delay: 20ms
jitterJb:PushPacket({ sequenceNumber = 100, sendTimestamp = tJ, payload = "j1" }, tJ + 0.020)
-- Jittery packet: transit delay 70ms (difference of 50ms)
jitterJb:PushPacket({ sequenceNumber = 101, sendTimestamp = tJ + 0.030, payload = "j2" }, tJ + 0.100)

local jStats = jitterJb:GetStats()
assert(jStats.currentJitterMs > 0, "Jitter estimate should increase with transit variation, got " .. tostring(jStats.currentJitterMs))
assert(jStats.currentPlayoutDelayMs >= 50, "Adaptive playout delay should expand with jitter")

-- Test 8: Packet Loss Concealment (PLC) Trigger
local plcJb = JitterBuffer.new({ targetDelayMs = 30, minDelayMs = 10, enableConcealment = true })
local tPlc = 500.0
plcJb:PushPacket({ sequenceNumber = 10, sendTimestamp = tPlc, payload = "p10" }, tPlc + 0.01)
-- Skip sequence 11 and 12, push sequence 13
plcJb:PushPacket({ sequenceNumber = 13, sendTimestamp = tPlc + 0.06, payload = "p13" }, tPlc + 0.07)

-- Pop first packet
local plcPop1 = plcJb:PopPlayout(tPlc + 0.04)
assert(#plcPop1 == 1, "Should pop p10")
assert(plcPop1[1].sequenceNumber == 10 and not plcPop1[1].isConcealed, "p10 should not be concealed")

-- Pop at tPlc + 0.12: should detect missing 11 and 12 and emit concealment frames
local plcPop2 = plcJb:PopPlayout(tPlc + 0.12)
-- Expecting: concealed seq 11, concealed seq 12, normal seq 13
assert(#plcPop2 == 3, "Expected 3 items (2 concealed + 1 normal), got " .. tostring(#plcPop2))
assert(plcPop2[1].sequenceNumber == 11 and plcPop2[1].isConcealed == true, "First emitted frame should be concealed 11")
assert(plcPop2[2].sequenceNumber == 12 and plcPop2[2].isConcealed == true, "Second emitted frame should be concealed 12")
assert(plcPop2[3].sequenceNumber == 13 and plcPop2[3].isConcealed == false, "Third frame should be normal 13")
assert(plcJb:GetStats().concealmentFramesEmitted == 2, "Stats should record 2 concealment frames")

-- Test 9: Time Stretching Factor Evaluation
local stretchJb = JitterBuffer.new({ targetDelayMs = 60, timeStretchEnabled = true, maxTimeStretchRatio = 0.05 })
assert(math.abs(stretchJb:GetTimeStretchFactor() - 1.0) < 1e-4, "Empty buffer time stretch should be 1.0")

-- Push lots of packets to create buffer backlog
local tS = 600.0
for i = 1, 15 do
  stretchJb:PushPacket({ sequenceNumber = i, sendTimestamp = tS + (i * 0.01), payload = i }, tS + (i * 0.01) + 0.005)
end
assert(stretchJb:GetTimeStretchFactor() > 1.0, "Backlogged buffer should speed up time (> 1.0)")

-- Test 10: Flush and Reset
stretchJb:Reset()
local resetStats = stretchJb:GetStats()
assert(resetStats.packetsReceived == 0, "Reset should clear packets received")
assert(resetStats.bufferDepth == 0, "Reset should clear queue")
assert(resetStats.concealmentFramesEmitted == 0, "Reset should clear concealment count")

print("PASS: JitterBuffer tests (Init, InOrder, OutOfOrder, Duplicates, LateDrops, WrapAround, RFC3550, PLC, TimeStretch, Reset) passed cleanly!")
