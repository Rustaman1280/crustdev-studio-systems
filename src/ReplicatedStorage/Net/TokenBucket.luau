--!strict
--[[
  TokenBucket.luau
  crustdev studio systems - ReplicatedStorage/Net/TokenBucket

  Production-grade network and remote event rate limiter:
  - Token bucket algorithm supporting burst capacity and continuous refill.
  - Granular per-player, per-remote, or per-action keying.
  - Escalating penalty cooldowns for abusive callers violating thresholds.
  - Tier multipliers for role-based throughput scaling (VIP, admin, batch jobs).
  - High-performance memory management with automatic idle bucket pruning.
  - Zero external dependencies. Fully typed under Luau strict mode.

  Part of crustdev studio game systems.
]]

export type TokenBucketConfig = {
  capacity: number,
  refillRate: number,
  defaultCost: number?,
  violationThreshold: number?,
  penaltyCooldownBase: number?,
  maxPenaltyCooldown: number?,
  idleTtl: number?,
}

export type BucketRecord = {
  tokens: number,
  lastRefillTime: number,
  violations: number,
  penaltyUntil: number,
  multiplier: number,
}

export type TokenBucketStats = {
  activeBuckets: number,
  totalRequests: number,
  totalAllowed: number,
  totalRejected: number,
  totalPenalized: number,
}

export type TokenBucket = {
  _config: {
    capacity: number,
    refillRate: number,
    defaultCost: number,
    violationThreshold: number,
    penaltyCooldownBase: number,
    maxPenaltyCooldown: number,
    idleTtl: number,
  },
  _buckets: { [string]: BucketRecord },
  _stats: TokenBucketStats,

  -- Core Methods
  Consume: (self: TokenBucket, key: string, cost: number?, currentTime: number?) -> (boolean, number, number),
  Peek: (self: TokenBucket, key: string, currentTime: number?) -> number,
  Reset: (self: TokenBucket, key: string, currentTime: number?) -> (),
  Remove: (self: TokenBucket, key: string) -> boolean,
  SetTierMultiplier: (self: TokenBucket, key: string, multiplier: number, currentTime: number?) -> (),
  IsPenalized: (self: TokenBucket, key: string, currentTime: number?) -> (boolean, number),
  PruneIdle: (self: TokenBucket, currentTime: number?) -> number,
  GetStats: (self: TokenBucket) -> TokenBucketStats,
  GetBucketCount: (self: TokenBucket) -> number,
}

local TokenBucket = {}
TokenBucket.__index = TokenBucket

function TokenBucket.new(config: TokenBucketConfig): TokenBucket
  assert(config.capacity > 0, "Capacity must be strictly positive")
  assert(config.refillRate > 0, "Refill rate must be strictly positive")

  local self = setmetatable({
    _config = {
      capacity = config.capacity,
      refillRate = config.refillRate,
      defaultCost = config.defaultCost or 1,
      violationThreshold = config.violationThreshold or 3,
      penaltyCooldownBase = config.penaltyCooldownBase or 5,
      maxPenaltyCooldown = config.maxPenaltyCooldown or 60,
      idleTtl = config.idleTtl or 120,
    },
    _buckets = {},
    _stats = {
      activeBuckets = 0,
      totalRequests = 0,
      totalAllowed = 0,
      totalRejected = 0,
      totalPenalized = 0,
    },
  }, TokenBucket)

  return (self :: any) :: TokenBucket
end

local function getEffectiveCapacity(self: TokenBucket, record: BucketRecord): number
  return self._config.capacity * record.multiplier
end

local function getEffectiveRefillRate(self: TokenBucket, record: BucketRecord): number
  return self._config.refillRate * record.multiplier
end

local function getOrCreateRecord(self: TokenBucket, key: string, now: number): BucketRecord
  local rec = self._buckets[key]
  if not rec then
    rec = {
      tokens = self._config.capacity,
      lastRefillTime = now,
      violations = 0,
      penaltyUntil = 0,
      multiplier = 1.0,
    }
    self._buckets[key] = rec
    self._stats.activeBuckets += 1
  end
  return rec
end

local function refillTokens(self: TokenBucket, record: BucketRecord, now: number)
  local elapsed = now - record.lastRefillTime
  if elapsed > 0 then
    local effectiveCap = getEffectiveCapacity(self, record)
    local effectiveRefill = getEffectiveRefillRate(self, record)
    record.tokens = math.min(effectiveCap, record.tokens + elapsed * effectiveRefill)
    record.lastRefillTime = now
  end
end

function TokenBucket.Consume(
  self: TokenBucket,
  key: string,
  cost: number?,
  currentTime: number?
): (boolean, number, number)
  local now = currentTime or os.clock()
  local requiredCost = cost or self._config.defaultCost
  assert(requiredCost > 0, "Cost must be strictly positive")

  self._stats.totalRequests += 1
  local record = getOrCreateRecord(self, key, now)

  -- Check active penalty cooldown lockout
  if record.penaltyUntil > now then
    self._stats.totalRejected += 1
    self._stats.totalPenalized += 1
    local penaltyRemaining = record.penaltyUntil - now
    return false, record.tokens, penaltyRemaining
  end

  refillTokens(self, record, now)

  if record.tokens >= requiredCost then
    record.tokens -= requiredCost
    self._stats.totalAllowed += 1
    -- Reset violations upon successful request
    record.violations = math.max(0, record.violations - 1)
    return true, record.tokens, 0
  else
    self._stats.totalRejected += 1
    record.violations += 1

    local effectiveRefill = getEffectiveRefillRate(self, record)
    local deficit = requiredCost - record.tokens
    local retryAfter = deficit / effectiveRefill

    -- Check if violation threshold reached for escalation
    if record.violations >= self._config.violationThreshold then
      local escalationFactor = 2 ^ (record.violations - self._config.violationThreshold)
      local penaltyDuration = math.min(
        self._config.maxPenaltyCooldown,
        self._config.penaltyCooldownBase * escalationFactor
      )
      record.penaltyUntil = now + penaltyDuration
      retryAfter = math.max(retryAfter, penaltyDuration)
    end

    return false, record.tokens, retryAfter
  end
end

function TokenBucket.Peek(self: TokenBucket, key: string, currentTime: number?): number
  local now = currentTime or os.clock()
  local record = self._buckets[key]
  if not record then
    return self._config.capacity
  end
  refillTokens(self, record, now)
  return record.tokens
end

function TokenBucket.Reset(self: TokenBucket, key: string, currentTime: number?): ()
  local record = self._buckets[key]
  if record then
    local now = currentTime or os.clock()
    record.tokens = getEffectiveCapacity(self, record)
    record.lastRefillTime = now
    record.violations = 0
    record.penaltyUntil = 0
  end
end

function TokenBucket.Remove(self: TokenBucket, key: string): boolean
  if self._buckets[key] then
    self._buckets[key] = nil
    self._stats.activeBuckets -= 1
    return true
  end
  return false
end

function TokenBucket.SetTierMultiplier(self: TokenBucket, key: string, multiplier: number, currentTime: number?): ()
  assert(multiplier > 0, "Multiplier must be strictly positive")
  local now = currentTime or os.clock()
  local record = getOrCreateRecord(self, key, now)
  local oldCap = getEffectiveCapacity(self, record)
  local fillRatio = if oldCap > 0 then (record.tokens / oldCap) else 1.0
  record.multiplier = multiplier
  local newCap = getEffectiveCapacity(self, record)
  record.tokens = math.min(newCap, fillRatio * newCap)
end

function TokenBucket.IsPenalized(self: TokenBucket, key: string, currentTime: number?): (boolean, number)
  local record = self._buckets[key]
  if not record then
    return false, 0
  end
  local now = currentTime or os.clock()
  if record.penaltyUntil > now then
    return true, record.penaltyUntil - now
  end
  return false, 0
end

function TokenBucket.PruneIdle(self: TokenBucket, currentTime: number?): number
  local now = currentTime or os.clock()
  local pruned = 0
  for key, record in pairs(self._buckets) do
    if (now - record.lastRefillTime) > self._config.idleTtl and record.penaltyUntil <= now then
      self._buckets[key] = nil
      self._stats.activeBuckets -= 1
      pruned += 1
    end
  end
  return pruned
end

function TokenBucket.GetStats(self: TokenBucket): TokenBucketStats
  return {
    activeBuckets = self._stats.activeBuckets,
    totalRequests = self._stats.totalRequests,
    totalAllowed = self._stats.totalAllowed,
    totalRejected = self._stats.totalRejected,
    totalPenalized = self._stats.totalPenalized,
  }
end

function TokenBucket.GetBucketCount(self: TokenBucket): number
  return self._stats.activeBuckets
end

return TokenBucket
