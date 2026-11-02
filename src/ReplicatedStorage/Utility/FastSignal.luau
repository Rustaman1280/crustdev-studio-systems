--!strict
--[[
  FastSignal.luau
  crustdev studio systems - ReplicatedStorage/Utility/FastSignal

  High-performance, zero-allocation event signal dispatcher for Roblox and Lune:
  - Doubly-linked connection list for O(1) connection and disconnection.
  - Re-entrancy safety: listeners can safely connect, disconnect, or fire signals during callbacks.
  - ConnectOnce: automatically unbinds listener upon first trigger.
  - Yielding Wait: pauses current thread until signal fires, returning all fired arguments.
  - Isolated listener errors: exceptions inside one listener do not abort subsequent listeners.
  - Full cleanup lifecycle: DisconnectAll and Destroy methods for zero memory leaks.

  Zero external dependencies. Fully typed under Luau strict mode.
]]

export type Connection = {
  Connected: boolean,
  Disconnect: (self: Connection) -> (),
  _signal: FastSignal?,
  _next: Connection?,
  _prev: Connection?,
  _fn: ((...any) -> ())?,
  _once: boolean,
}

export type FastSignal = {
  _head: Connection?,
  _tail: Connection?,
  _count: number,
  _destroyed: boolean,

  Connect: (self: FastSignal, callback: (...any) -> ()) -> Connection,
  Once: (self: FastSignal, callback: (...any) -> ()) -> Connection,
  Wait: (self: FastSignal) -> ...any,
  Fire: (self: FastSignal, ...any) -> (),
  DisconnectAll: (self: FastSignal) -> (),
  Destroy: (self: FastSignal) -> (),
  GetConnectionCount: (self: FastSignal) -> number,
  IsDestroyed: (self: FastSignal) -> boolean,
}

local Connection = {}
Connection.__index = Connection

local FastSignal = {}
FastSignal.__index = FastSignal

function Connection.new(signal: FastSignal, callback: (...any) -> (), once: boolean): Connection
  local self = setmetatable({
    Connected = true,
    _signal = signal,
    _next = nil,
    _prev = nil,
    _fn = callback,
    _once = once,
  }, Connection)
  return (self :: any) :: Connection
end

function Connection:Disconnect()
  if not self.Connected then
    return
  end
  self.Connected = false

  local signal = self._signal
  if signal then
    if self._prev then
      self._prev._next = self._next
    else
      signal._head = self._next
    end

    if self._next then
      self._next._prev = self._prev
    else
      signal._tail = self._prev
    end

    signal._count = math.max(0, signal._count - 1)
  end

  self._signal = nil
  self._next = nil
  self._prev = nil
  self._fn = nil
end

function FastSignal.new(): FastSignal
  local self = setmetatable({
    _head = nil,
    _tail = nil,
    _count = 0,
    _destroyed = false,
  }, FastSignal)
  return (self :: any) :: FastSignal
end

function FastSignal:Connect(callback: (...any) -> ()): Connection
  assert(not self._destroyed, "Cannot connect to a destroyed FastSignal")
  assert(type(callback) == "function", "Listener callback must be a function")

  local connection = Connection.new(self, callback, false)

  if self._tail then
    self._tail._next = connection
    connection._prev = self._tail
    self._tail = connection
  else
    self._head = connection
    self._tail = connection
  end

  self._count += 1
  return connection
end

function FastSignal:Once(callback: (...any) -> ()): Connection
  assert(not self._destroyed, "Cannot connect to a destroyed FastSignal")
  assert(type(callback) == "function", "Listener callback must be a function")

  local connection = Connection.new(self, callback, true)

  if self._tail then
    self._tail._next = connection
    connection._prev = self._tail
    self._tail = connection
  else
    self._head = connection
    self._tail = connection
  end

  self._count += 1
  return connection
end

function FastSignal:Fire(...: any)
  if self._destroyed then
    return
  end

  local node = self._head
  while node ~= nil do
    local nextNode = node._next

    if node.Connected then
      local fn = node._fn
      if node._once then
        node:Disconnect()
      end

      if fn then
        local ok, err = pcall(fn, ...)
        if not ok then
          local warnFn = warn or print
          warnFn(string.format("[FastSignal Error]: %s", tostring(err)))
        end
      end
    end

    node = nextNode
  end
end

function FastSignal:Wait(): ...any
  assert(not self._destroyed, "Cannot wait on a destroyed FastSignal")
  local running = coroutine.running()
  assert(running, "FastSignal:Wait must be called within a running coroutine")

  local connection: Connection? = nil
  connection = self:Connect(function(...)
    if connection then
      connection:Disconnect()
    end
    coroutine.resume(running, ...)
  end)

  return coroutine.yield()
end

function FastSignal:DisconnectAll()
  local node = self._head
  while node ~= nil do
    local nextNode = node._next
    node.Connected = false
    node._signal = nil
    node._next = nil
    node._prev = nil
    node._fn = nil
    node = nextNode
  end
  self._head = nil
  self._tail = nil
  self._count = 0
end

function FastSignal:Destroy()
  if self._destroyed then
    return
  end
  self:DisconnectAll()
  self._destroyed = true
end

function FastSignal:GetConnectionCount(): number
  return self._count
end

function FastSignal:IsDestroyed(): boolean
  return self._destroyed
end

return FastSignal
