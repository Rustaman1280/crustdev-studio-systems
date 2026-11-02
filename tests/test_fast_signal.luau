local FastSignal = require("../src/ReplicatedStorage/Utility/FastSignal")

-- Test 1: Basic dispatch and parameter forwarding
local s1 = FastSignal.new()
local receivedA, receivedB = nil, nil
local conn1 = s1:Connect(function(a, b)
  receivedA = a
  receivedB = b
end)

assert(conn1.Connected == true, "Connection should be marked connected")
assert(s1:GetConnectionCount() == 1, "Connection count should be 1")

s1:Fire("hello", 42)
assert(receivedA == "hello", "First argument should match")
assert(receivedB == 42, "Second argument should match")

-- Test 2: Disconnection stops events
conn1:Disconnect()
assert(conn1.Connected == false, "Connection should be marked disconnected")
assert(s1:GetConnectionCount() == 0, "Connection count should be 0")

s1:Fire("unheard", 999)
assert(receivedA == "hello", "Listener should not have received updated value after disconnect")

-- Test 3: Multiple listeners and invocation order
local s2 = FastSignal.new()
local callOrder = {}

local cA = s2:Connect(function() table.insert(callOrder, "A") end)
local cB = s2:Connect(function() table.insert(callOrder, "B") end)
local cC = s2:Connect(function() table.insert(callOrder, "C") end)

s2:Fire()
assert(#callOrder == 3, "All 3 listeners should fire")
assert(callOrder[1] == "A" and callOrder[2] == "B" and callOrder[3] == "C", "Listeners should fire in connection order")

-- Disconnect middle node
cB:Disconnect()
table.clear(callOrder)
s2:Fire()
assert(#callOrder == 2, "Only 2 listeners should fire after removing middle")
assert(callOrder[1] == "A" and callOrder[2] == "C", "A and C should remain connected")

-- Test 4: Once listener auto-disconnects
local s3 = FastSignal.new()
local onceCount = 0
s3:Once(function()
  onceCount += 1
end)

assert(s3:GetConnectionCount() == 1, "Once listener should be counted")
s3:Fire()
assert(onceCount == 1, "Once listener should fire on first call")
assert(s3:GetConnectionCount() == 0, "Once listener should auto-disconnect after first fire")

s3:Fire()
assert(onceCount == 1, "Once listener should not fire on second call")

-- Test 5: Re-entrancy (Listener disconnecting itself during callback)
local s4 = FastSignal.new()
local selfDisconnectConn: any = nil
local selfDisconnectFired = 0

selfDisconnectConn = s4:Connect(function()
  selfDisconnectFired += 1
  selfDisconnectConn:Disconnect()
end)

s4:Fire()
assert(selfDisconnectFired == 1, "Self disconnecting listener should execute once")
assert(selfDisconnectConn.Connected == false, "Connection should be marked disconnected")
s4:Fire()
assert(selfDisconnectFired == 1, "Self disconnecting listener must not fire again")

-- Test 6: Error isolation across listeners
local s5 = FastSignal.new()
local healthyRan = false

s5:Connect(function()
  error("Simulated catastrophic listener failure")
end)

s5:Connect(function()
  healthyRan = true
end)

-- Fire should not throw and abort execution
s5:Fire()
assert(healthyRan == true, "Healthy listener should run despite prior listener error")

-- Test 7: DisconnectAll
local s6 = FastSignal.new()
s6:Connect(function() end)
s6:Connect(function() end)
assert(s6:GetConnectionCount() == 2, "Should have 2 connections")
s6:DisconnectAll()
assert(s6:GetConnectionCount() == 0, "Should have 0 connections after DisconnectAll")

-- Test 8: Coroutine Wait
local s7 = FastSignal.new()
local waitResult1, waitResult2 = nil, nil
local co = coroutine.create(function()
  waitResult1, waitResult2 = s7:Wait()
end)

coroutine.resume(co)
assert(waitResult1 == nil, "Coroutine should be yielding inside Wait")
s7:Fire("payload", 12345)
assert(waitResult1 == "payload", "Wait should resume with first argument")
assert(waitResult2 == 12345, "Wait should resume with second argument")

-- Test 9: Destroy lifecycle
local s8 = FastSignal.new()
local firedAfterDestroy = false
s8:Connect(function() firedAfterDestroy = true end)
s8:Destroy()
assert(s8:IsDestroyed() == true, "Signal should be marked destroyed")
assert(s8:GetConnectionCount() == 0, "Connection count should be 0 after Destroy")

s8:Fire()
assert(firedAfterDestroy == false, "Firing destroyed signal should be a no-op")

print("PASS: FastSignal tests (Connect, Fire, Disconnect, Once, Re-entrancy, Error Isolation, Wait, Destroy) passed cleanly!")
