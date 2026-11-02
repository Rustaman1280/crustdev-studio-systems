local ObjectPool = require("../src/ReplicatedStorage/Utility/ObjectPool")

-- Mock Item type
type MockBullet = {
  id: number,
  active: boolean,
  speed: number,
}

local nextId = 1
local function createBullet(): MockBullet
  local bullet = {
    id = nextId,
    active = false,
    speed = 0,
  }
  nextId += 1
  return bullet
end

-- Test 1: Pre-allocation & Initial Capacity
local pool = ObjectPool.new({
  createFn = createBullet,
  initialCapacity = 5,
  maxCapacity = 10,
})

local stats = pool:GetStats()
assert(stats.capacity == 5, "Initial capacity should be 5")
assert(stats.freeCount == 5, "Free count should be 5")
assert(stats.activeCount == 0, "Active count should be 0")
assert(stats.isExhausted == false, "Pool should not be exhausted")

-- Test 2: Basic Acquire & Release
local b1 = pool:Acquire()
assert(b1 ~= nil, "Acquired item should not be nil")
assert(pool:IsActive(b1) == true, "b1 should be active")
assert(pool:GetStats().activeCount == 1, "Active count should be 1")
assert(pool:GetStats().freeCount == 4, "Free count should be 4")

local releaseSuccess = pool:Release(b1)
assert(releaseSuccess == true, "Release should succeed")
assert(pool:IsActive(b1) == false, "b1 should no longer be active")
assert(pool:GetStats().activeCount == 0, "Active count should be 0")
assert(pool:GetStats().freeCount == 5, "Free count should be 5")

-- Test 3: Double Release Prevention
local doubleRelease = pool:Release(b1)
assert(doubleRelease == false, "Double release must return false")
assert(pool:GetStats().freeCount == 5, "Free count should still be 5")

-- Foreign object release prevention
local foreignBullet = { id = 9999, active = false, speed = 0 }
assert(pool:Release(foreignBullet) == false, "Foreign object release must return false")

-- Test 4: Lifecycle Hooks (onAcquire & onRelease)
local acquiredCount = 0
local releasedCount = 0
local destroyedCount = 0

local lifecyclePool = ObjectPool.new({
  createFn = function()
    return { initialized = false, val = 0 }
  end,
  initialCapacity = 2,
  maxCapacity = 4,
  onAcquire = function(item, initialVal)
    item.initialized = true
    item.val = initialVal or 100
    acquiredCount += 1
  end,
  onRelease = function(item)
    item.initialized = false
    item.val = 0
    releasedCount += 1
  end,
  onDestroy = function(item)
    destroyedCount += 1
  end,
})

local itemA = lifecyclePool:Acquire(42)
assert(itemA.initialized == true, "Item should be initialized by onAcquire")
assert(itemA.val == 42, "Item should have param passed to onAcquire")
assert(acquiredCount == 1, "onAcquire should have been called once")

lifecyclePool:Release(itemA)
assert(itemA.initialized == false, "Item should be reset by onRelease")
assert(itemA.val == 0, "Item val should be reset by onRelease")
assert(releasedCount == 1, "onRelease should have been called once")

-- Test 5: Expansion & Bounds (canGrow, maxCapacity)
local boundedPool = ObjectPool.new({
  createFn = function() return { id = math.random() } end,
  initialCapacity = 2,
  maxCapacity = 3,
  canGrow = false,
})

local obj1 = boundedPool:Acquire()
local obj2 = boundedPool:Acquire()
local obj3, err = boundedPool:TryAcquire()
assert(obj3 == nil, "Fixed pool must fail when exhausted")
assert(err ~= nil, "TryAcquire should return error reason")
assert(boundedPool:GetStats().isExhausted == true, "Pool must be marked exhausted")

boundedPool:Release(obj1)
assert(boundedPool:GetStats().isExhausted == false, "Pool should no longer be exhausted after release")
local obj3Retry = boundedPool:Acquire()
assert(obj3Retry == obj1, "LIFO free stack should return obj1")

-- Test 6: Batch Acquire & Batch Release
local batchPool = ObjectPool.new({
  createFn = function() return { id = math.random() } end,
  initialCapacity = 5,
  maxCapacity = 20,
})

local batch = batchPool:AcquireBatch(4)
assert(#batch == 4, "Batch size should be 4")
assert(batchPool:GetStats().activeCount == 4, "Active count should be 4")

local batchReleased = batchPool:ReleaseBatch(batch)
assert(batchReleased == 4, "ReleaseBatch should release 4 items")
assert(batchPool:GetStats().activeCount == 0, "Active count should be 0")

-- Test 7: ReleaseAll & Drain
local drainPool = ObjectPool.new({
  createFn = function() return {} end,
  initialCapacity = 3,
  maxCapacity = 10,
  onDestroy = function()
    destroyedCount += 1
  end,
})

drainPool:Acquire()
drainPool:Acquire()
assert(drainPool:GetStats().activeCount == 2, "Active count should be 2")

local reclaimed = drainPool:ReleaseAll()
assert(reclaimed == 2, "ReleaseAll should reclaim 2 items")
assert(drainPool:GetStats().activeCount == 0, "Active count should be 0")

local prevDestroyed = destroyedCount
drainPool:Drain()
assert(drainPool:GetStats().capacity == 0, "Capacity should be 0 after Drain")
assert(destroyedCount - prevDestroyed == 3, "Drain should call onDestroy on 3 items")

print("PASS: ObjectPool tests (Pre-allocation, Acquire/Release, Safety, Hooks, Bounds, Batch, Drain) passed cleanly!")
