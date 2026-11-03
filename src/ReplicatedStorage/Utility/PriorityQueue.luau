--!strict
--[[
  PriorityQueue.luau
  High-performance binary heap priority queue supporting Min-Heap and Max-Heap modes.
  Features:
  - Min-Heap (lowest priority number extracted first) and Max-Heap (highest extracted first)
  - Generic item storage with numeric priority scores or custom comparator predicates
  - Fast O(log N) insertion (Push) and root extraction (Pop)
  - Constant time O(1) inspection of root element (Peek)
  - Constant time O(1) key indexing with O(log N) in-place priority updates (UpdatePriority / decrease-key)
  - Arbitrary item removal by key in O(log N) time (Remove)
  - Linear time O(N) Floyd heapify initialization from un-ordered tables (FromTable)
  - Capacity bounds with automatic lowest-priority eviction (PushWithLimit)
  - Stable tie-breaking preserving FIFO insertion order for identical priorities
  - Ordered batch extraction iterator (Drain)
  Part of crustdev studio game systems.
  Zero external runtime dependencies.
]]

export type HeapMode = "Min" | "Max"

export type QueueNode<T> = {
  Value: T,
  Priority: number,
  Key: string?,
  Sequence: number,
}

export type PriorityQueueConfig<T> = {
  Mode: HeapMode?,
  Stable: boolean?,
  Comparator: ((a: QueueNode<T>, b: QueueNode<T>) -> boolean)?,
}

export type IPriorityQueue<T> = {
  Mode: HeapMode,
  Stable: boolean,
  Size: (self: IPriorityQueue<T>) -> number,
  IsEmpty: (self: IPriorityQueue<T>) -> boolean,
  Peek: (self: IPriorityQueue<T>) -> (T?, number?, string?),
  Push: (self: IPriorityQueue<T>, value: T, priority: number, key: string?) -> (),
  PushWithLimit: (self: IPriorityQueue<T>, value: T, priority: number, maxCapacity: number, key: string?) -> T?,
  Pop: (self: IPriorityQueue<T>) -> (T?, number?, string?),
  UpdatePriority: (self: IPriorityQueue<T>, key: string, newPriority: number) -> boolean,
  Remove: (self: IPriorityQueue<T>, key: string) -> (T?, number?),
  Contains: (self: IPriorityQueue<T>, key: string) -> boolean,
  Clear: (self: IPriorityQueue<T>) -> (),
  Drain: (self: IPriorityQueue<T>) -> { T },
  ToArray: (self: IPriorityQueue<T>) -> { QueueNode<T> },
}

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue

-- Default comparator generator based on mode and stability
local function CreateDefaultComparator<T>(mode: HeapMode, stable: boolean): (QueueNode<T>, QueueNode<T>) -> boolean
  if mode == "Min" then
    if stable then
      return function(a: QueueNode<T>, b: QueueNode<T>): boolean
        if a.Priority == b.Priority then
          return a.Sequence < b.Sequence
        end
        return a.Priority < b.Priority
      end
    else
      return function(a: QueueNode<T>, b: QueueNode<T>): boolean
        return a.Priority < b.Priority
      end
    end
  else -- "Max"
    if stable then
      return function(a: QueueNode<T>, b: QueueNode<T>): boolean
        if a.Priority == b.Priority then
          return a.Sequence < b.Sequence
        end
        return a.Priority > b.Priority
      end
    else
      return function(a: QueueNode<T>, b: QueueNode<T>): boolean
        return a.Priority > b.Priority
      end
    end
  end
end

--[[
  Create a new PriorityQueue instance.
]]
function PriorityQueue.new<T>(config: PriorityQueueConfig<T>?): IPriorityQueue<T>
  local cfg = config or {}
  local mode: HeapMode = cfg.Mode or "Min"
  local stable = if cfg.Stable ~= nil then cfg.Stable else true
  local comparator = cfg.Comparator or CreateDefaultComparator(mode, stable)

  local self = setmetatable({}, PriorityQueue)
  self.Mode = mode
  self.Stable = stable
  self._comparator = comparator
  self._heap = {} :: { QueueNode<T> }
  self._keyIndexMap = {} :: { [string]: number }
  self._sequenceCounter = 0

  return (self :: any) :: IPriorityQueue<T>
end

-- Internal swap helper that updates index map
local function SwapNodes<T>(self: any, i: number, j: number)
  local heap = self._heap
  local keyMap = self._keyIndexMap

  local nodeA = heap[i]
  local nodeB = heap[j]

  heap[i] = nodeB
  heap[j] = nodeA

  if nodeA.Key then
    keyMap[nodeA.Key] = j
  end
  if nodeB.Key then
    keyMap[nodeB.Key] = i
  end
end

-- Bubble up element at index
local function SiftUp<T>(self: any, index: number)
  local heap = self._heap
  local comp = self._comparator

  local current = index
  while current > 1 do
    local parent = math.floor(current / 2)
    if comp(heap[current], heap[parent]) then
      SwapNodes(self, current, parent)
      current = parent
    else
      break
    end
  end
end

-- Bubble down element at index
local function SiftDown<T>(self: any, index: number)
  local heap = self._heap
  local comp = self._comparator
  local count = #heap

  local current = index
  while true do
    local leftChild = current * 2
    local rightChild = current * 2 + 1
    local best = current

    if leftChild <= count and comp(heap[leftChild], heap[best]) then
      best = leftChild
    end
    if rightChild <= count and comp(heap[rightChild], heap[best]) then
      best = rightChild
    end

    if best ~= current then
      SwapNodes(self, current, best)
      current = best
    else
      break
    end
  end
end

--[[
  Returns number of elements in the queue.
]]
function PriorityQueue:Size(): number
  return #self._heap
end

--[[
  Returns true if the queue contains zero elements.
]]
function PriorityQueue:IsEmpty(): boolean
  return #self._heap == 0
end

--[[
  Inspect the highest priority element without removing it.
]]
function PriorityQueue:Peek(): (any?, number?, string?)
  local root = self._heap[1]
  if not root then
    return nil, nil, nil
  end
  return root.Value, root.Priority, root.Key
end

--[[
  Push a value with a priority score and optional identifier key.
]]
function PriorityQueue:Push(value: any, priority: number, key: string?)
  if key and self._keyIndexMap[key] ~= nil then
    -- Key already exists: update its priority instead
    self:UpdatePriority(key, priority)
    return
  end

  self._sequenceCounter += 1
  local node: QueueNode<any> = {
    Value = value,
    Priority = priority,
    Key = key,
    Sequence = self._sequenceCounter,
  }

  table.insert(self._heap, node)
  local index = #self._heap

  if key then
    self._keyIndexMap[key] = index
  end

  SiftUp(self, index)
end

--[[
  Push with maximum capacity enforcement. Evicts lowest priority item if exceeded.
]]
function PriorityQueue:PushWithLimit(value: any, priority: number, maxCapacity: number, key: string?): any?
  assert(maxCapacity > 0, "maxCapacity must be greater than 0")

  self:Push(value, priority, key)

  if #self._heap > maxCapacity then
    -- Find lowest priority element (leaves of binary heap)
    local heap = self._heap
    local comp = self._comparator
    local leafStart = math.floor(#heap / 2) + 1
    local worstIndex = leafStart

    for i = leafStart + 1, #heap do
      -- The "worst" element is one where comp(heap[i], heap[worst]) is false
      if comp(heap[worstIndex], heap[i]) then
        worstIndex = i
      end
    end

    local evictedNode = heap[worstIndex]
    local lastIndex = #heap

    if worstIndex == lastIndex then
      table.remove(heap)
      if evictedNode.Key then
        self._keyIndexMap[evictedNode.Key] = nil
      end
    else
      SwapNodes(self, worstIndex, lastIndex)
      table.remove(heap)
      if evictedNode.Key then
        self._keyIndexMap[evictedNode.Key] = nil
      end
      SiftDown(self, worstIndex)
      SiftUp(self, worstIndex)
    end

    return evictedNode.Value
  end

  return nil
end

--[[
  Extract and return the root (highest priority) element.
]]
function PriorityQueue:Pop(): (any?, number?, string?)
  local count = #self._heap
  if count == 0 then
    return nil, nil, nil
  end

  local root = self._heap[1]
  if root.Key then
    self._keyIndexMap[root.Key] = nil
  end

  if count == 1 then
    table.remove(self._heap)
    return root.Value, root.Priority, root.Key
  end

  local last = table.remove(self._heap) :: QueueNode<any>
  self._heap[1] = last
  if last.Key then
    self._keyIndexMap[last.Key] = 1
  end

  SiftDown(self, 1)

  return root.Value, root.Priority, root.Key
end

--[[
  Update the priority of an existing item by its string key.
]]
function PriorityQueue:UpdatePriority(key: string, newPriority: number): boolean
  local index = self._keyIndexMap[key]
  if not index then
    return false
  end

  local node = self._heap[index]
  local oldPriority = node.Priority
  node.Priority = newPriority

  -- Re-balance depending on direction
  SiftUp(self, index)
  SiftDown(self, index)

  return true
end

--[[
  Remove an arbitrary element by its unique key.
]]
function PriorityQueue:Remove(key: string): (any?, number?)
  local index = self._keyIndexMap[key]
  if not index then
    return nil, nil
  end

  local count = #self._heap
  local targetNode = self._heap[index]
  self._keyIndexMap[key] = nil

  if index == count then
    table.remove(self._heap)
    return targetNode.Value, targetNode.Priority
  end

  local last = table.remove(self._heap) :: QueueNode<any>
  self._heap[index] = last
  if last.Key then
    self._keyIndexMap[last.Key] = index
  end

  SiftDown(self, index)
  SiftUp(self, index)

  return targetNode.Value, targetNode.Priority
end

--[[
  Check if a key currently exists in the queue.
]]
function PriorityQueue:Contains(key: string): boolean
  return self._keyIndexMap[key] ~= nil
end

--[[
  Clear all elements and reset indices.
]]
function PriorityQueue:Clear()
  table.clear(self._heap)
  table.clear(self._keyIndexMap)
  self._sequenceCounter = 0
end

--[[
  Extract all elements in order into a sorted array.
]]
function PriorityQueue:Drain(): { any }
  local result = {}
  while not self:IsEmpty() do
    local val = self:Pop()
    table.insert(result, val)
  end
  return result
end

--[[
  Get shallow copy of current internal heap nodes.
]]
function PriorityQueue:ToArray(): { QueueNode<any> }
  local copy = {}
  for i, node in ipairs(self._heap) do
    copy[i] = {
      Value = node.Value,
      Priority = node.Priority,
      Key = node.Key,
      Sequence = node.Sequence,
    }
  end
  return copy
end

--[[
  Construct a PriorityQueue from an un-ordered list in O(N) Floyd heapify time.
]]
function PriorityQueue.FromTable<T>(items: { { Value: T, Priority: number, Key: string? } }, config: PriorityQueueConfig<T>?): IPriorityQueue<T>
  local pq = PriorityQueue.new(config)
  local rawSelf = pq :: any

  for i, item in ipairs(items) do
    rawSelf._sequenceCounter += 1
    local node: QueueNode<T> = {
      Value = item.Value,
      Priority = item.Priority,
      Key = item.Key,
      Sequence = rawSelf._sequenceCounter,
    }
    table.insert(rawSelf._heap, node)
    if item.Key then
      rawSelf._keyIndexMap[item.Key] = i
    end
  end

  -- In-place Floyd heapify from bottom-up
  local count = #rawSelf._heap
  local startIdx = math.floor(count / 2)
  for i = startIdx, 1, -1 do
    SiftDown(rawSelf, i)
  end

  return pq
end

return PriorityQueue