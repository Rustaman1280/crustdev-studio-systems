local PriorityQueue = require("../src/ReplicatedStorage/Utility/PriorityQueue")

-- Test 1: Min-Heap Push and Pop order
local minPQ = PriorityQueue.new({ Mode = "Min" })
assert(minPQ:IsEmpty() == true, "Should initially be empty")
assert(minPQ:Size() == 0, "Initial size should be 0")

minPQ:Push("Medium", 50)
minPQ:Push("High", 10)
minPQ:Push("Low", 100)
minPQ:Push("Critical", 1)

assert(minPQ:Size() == 4, "Size should be 4")
local val, prio = minPQ:Peek()
assert(val == "Critical" and prio == 1, "Peek should return minimum priority item")

local popped = {}
while not minPQ:IsEmpty() do
  local val = minPQ:Pop()
  table.insert(popped, val)
end

assert(#popped == 4, "Should pop 4 items")
assert(popped[1] == "Critical", "1st should be Critical (1)")
assert(popped[2] == "High", "2nd should be High (10)")
assert(popped[3] == "Medium", "3rd should be Medium (50)")
assert(popped[4] == "Low", "4th should be Low (100)")

-- Test 2: Max-Heap Mode
local maxPQ = PriorityQueue.new({ Mode = "Max" })
maxPQ:Push("Loot Tier 1", 10)
maxPQ:Push("Loot Tier 3", 100)
maxPQ:Push("Loot Tier 2", 50)

assert(maxPQ:Pop() == "Loot Tier 3", "Max-heap root must be highest priority (100)")
assert(maxPQ:Pop() == "Loot Tier 2", "Max-heap 2nd must be 50")
assert(maxPQ:Pop() == "Loot Tier 1", "Max-heap 3rd must be 10")

-- Test 3: Stable tie-breaking (FIFO for equal priorities)
local stablePQ = PriorityQueue.new({ Mode = "Min", Stable = true })
stablePQ:Push("Task A", 10)
stablePQ:Push("Task B", 10)
stablePQ:Push("Task C", 10)

assert(stablePQ:Pop() == "Task A", "Stable FIFO tie break: Task A first")
assert(stablePQ:Pop() == "Task B", "Stable FIFO tie break: Task B second")
assert(stablePQ:Pop() == "Task C", "Stable FIFO tie break: Task C third")

-- Test 4: Key tracking, Contains, and UpdatePriority
local keyPQ = PriorityQueue.new({ Mode = "Min" })
keyPQ:Push("Player1", 50, "p1")
keyPQ:Push("Player2", 80, "p2")
keyPQ:Push("Player3", 20, "p3")

assert(keyPQ:Contains("p1") == true, "Must contain p1")
assert(keyPQ:Contains("p4") == false, "Must not contain p4")

-- Decrease key p2 from 80 to 5
local updated = keyPQ:UpdatePriority("p2", 5)
assert(updated == true, "UpdatePriority should return true")

local topVal, topPrio, topKey = keyPQ:Peek()
assert(topVal == "Player2" and topPrio == 5 and topKey == "p2", "Player2 should now be root after priority drop to 5")

-- Remove key p3
local remVal, remPrio = keyPQ:Remove("p3")
assert(remVal == "Player3" and remPrio == 20, "Removed p3 correctly")
assert(keyPQ:Contains("p3") == false, "p3 should no longer exist")
assert(keyPQ:Size() == 2, "Size should be 2 after removal")

-- Test 5: In-Place Floyd Heapify (FromTable)
local rawItems = {
  { Value = "D", Priority = 40 },
  { Value = "B", Priority = 20 },
  { Value = "E", Priority = 50 },
  { Value = "A", Priority = 10 },
  { Value = "C", Priority = 30 },
}

local heapified = PriorityQueue.FromTable(rawItems, { Mode = "Min" })
assert(heapified:Size() == 5, "Heapified size should be 5")
local drained = heapified:Drain()
assert(#drained == 5, "Drained array length should be 5")
assert(drained[1] == "A" and drained[2] == "B" and drained[3] == "C" and drained[4] == "D" and drained[5] == "E", "Floyd heapify must extract sorted items")

-- Test 6: Capacity bounded PushWithLimit
local boundedPQ = PriorityQueue.new({ Mode = "Min" })
boundedPQ:PushWithLimit("Job1", 10, 3)
boundedPQ:PushWithLimit("Job2", 20, 3)
boundedPQ:PushWithLimit("Job3", 30, 3)
-- Queue has 3 items: 10, 20, 30.
-- Pushing priority 5 with limit 3: should evict the worst (30)
local evicted = boundedPQ:PushWithLimit("Job0", 5, 3)
assert(evicted == "Job3", string.format("Evicted element should be Job3 (30), got %s", tostring(evicted)))
assert(boundedPQ:Size() == 3, "Size should remain at limit 3")

-- Test 7: Clear
boundedPQ:Clear()
assert(boundedPQ:IsEmpty() == true, "Should be empty after Clear")
assert(boundedPQ:Size() == 0, "Size should be 0 after Clear")

print("PASS: PriorityQueue tests (Min, Max, Stable, KeyTracking, Update, Remove, FloydHeapify, BoundedLimit, Clear) passed cleanly!")
