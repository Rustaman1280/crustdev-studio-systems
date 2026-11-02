--!strict
local TokenBucket = require("../src/ReplicatedStorage/Net/TokenBucket")

-- Test 1: Initial Capacity and Basic Consumption
local limiter = TokenBucket.new({
  capacity = 10,
  refillRate = 5, -- 5 tokens per second
  defaultCost = 1,
  violationThreshold = 3,
  penaltyCooldownBase = 4,
  maxPenaltyCooldown = 20,
  idleTtl = 60,
})

local t0 = 1000.0
assert(limiter:GetBucketCount() == 0, "Bucket count should initially be 0")

-- Consume 4 tokens
local allowed, rem, retryAfter = limiter:Consume("player_1", 4, t0)
assert(allowed == true, "Request 1 should be allowed")
assert(rem == 6, "Remaining tokens should be 6")
assert(retryAfter == 0, "RetryAfter should be 0 on success")
assert(limiter:GetBucketCount() == 1, "Active bucket count should be 1")

-- Peek available tokens
assert(limiter:Peek("player_1", t0) == 6, "Peek should return 6 tokens")

-- Test 2: Exhaustion and Retry Calculation
local allowed2, rem2, retryAfter2 = limiter:Consume("player_1", 6, t0)
assert(allowed2 == true, "Request 2 should consume remaining 6 tokens")
assert(rem2 == 0, "Remaining tokens should be 0")

-- Immediate request when empty -> rejected
local allowed3, rem3, retryAfter3 = limiter:Consume("player_1", 2, t0)
assert(allowed3 == false, "Request 3 should be rejected due to empty bucket")
assert(rem3 == 0, "Remaining tokens should still be 0")
assert(math.abs(retryAfter3 - 0.4) < 0.001, "RetryAfter should be 2 / 5 = 0.4s")

-- Test 3: Simulated Time Refill
local t1 = t0 + 1.0 -- 1 second later -> +5 tokens
local allowed4, rem4, retryAfter4 = limiter:Consume("player_1", 3, t1)
assert(allowed4 == true, "Request 4 should succeed after refill")
assert(math.abs(rem4 - 2.0) < 0.001, "Remaining tokens should be 2.0 (5 - 3)")

-- Test 4: Violation Threshold & Penalty Escalation
-- Cause violations up to threshold
local t2 = t1 + 0.01
limiter:Consume("player_1", 10, t2) -- violation 1
limiter:Consume("player_1", 10, t2) -- violation 2
local allowedV3, _, retryAfterV3 = limiter:Consume("player_1", 10, t2) -- violation 3 (threshold reached!)

assert(allowedV3 == false, "Violation 3 should be rejected")
assert(retryAfterV3 >= 4, "Penalty cooldown base should be at least 4s")

local isPenalized, penRem = limiter:IsPenalized("player_1", t2)
assert(isPenalized == true, "Player should be under active penalty lockout")
assert(penRem > 0, "Penalty remaining should be positive")

-- Request during penalty lockout is rejected
local allowedPen, _, _ = limiter:Consume("player_1", 1, t2 + 1.0)
assert(allowedPen == false, "Request during penalty must be rejected")

-- Reset clears penalty
limiter:Reset("player_1", t2 + 1.0)
local isPenalizedAfterReset, _ = limiter:IsPenalized("player_1", t2 + 1.0)
assert(isPenalizedAfterReset == false, "Player should no longer be penalized after Reset")
assert(limiter:Peek("player_1", t2 + 1.0) == 10, "Tokens should be reset to full capacity")

-- Test 5: Tier Multiplier
limiter:SetTierMultiplier("vip_player", 2.5, t0) -- 2.5x capacity (25) and refill (12.5/s)
local allowedVip, remVip, _ = limiter:Consume("vip_player", 20, t0)
assert(allowedVip == true, "VIP should be able to burst consume 20 tokens")
assert(math.abs(remVip - 5) < 0.001, "VIP remaining tokens should be 5")

-- Test 6: Memory Cleanup & Idle Pruning
local tPrune = t0 + 200.0 -- past idleTtl (60s)
local prunedCount = limiter:PruneIdle(tPrune)
assert(prunedCount >= 2, "PruneIdle should prune inactive buckets")
assert(limiter:GetBucketCount() == 0, "Bucket count should be 0 after full prune")

-- Test 7: Stats Verification
local stats = limiter:GetStats()
assert(stats.totalRequests > 0, "Total requests should be tracked")
assert(stats.totalAllowed > 0, "Total allowed should be tracked")
assert(stats.totalRejected > 0, "Total rejected should be tracked")
assert(stats.totalPenalized > 0, "Total penalized should be tracked")

print("PASS: TokenBucket tests (Capacity, Refill, Violations, Penalty, TierMultiplier, Pruning, Stats) passed cleanly!")
return true
