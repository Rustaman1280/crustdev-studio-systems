local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame

local ActionBuffer = require("../src/StarterPlayerScripts/Controllers/ActionBuffer")

-- Test 1: Buffer initialization and defaults
local buffer = ActionBuffer.new({
  DefaultBufferWindow = 0.3,
  HistoryLimit = 8,
  ActionCooldowns = {
    DodgeRoll = 1.0,
    HeavyAttack = 0.5,
  },
})

assert(buffer.Config.DefaultBufferWindow == 0.3, "Buffer window should be 0.3s")
assert(buffer.Config.HistoryLimit == 8, "History limit should be 8")

-- Test 2: Priority ordering in buffer
local t0 = 100.0
buffer:BufferAction("LightAttack", { comboStep = 1 }, 1, nil, t0)
buffer:BufferAction("Parry", { perfectWindow = true }, 5, nil, t0 + 0.05)
buffer:BufferAction("Jump", nil, 2, nil, t0 + 0.06)

-- Highest priority should be Parry (5)
local peeked = buffer:PeekAction(nil, t0 + 0.07)
assert(peeked ~= nil, "Should find peeked action")
assert(peeked.Action == "Parry", "Parry should have highest priority")
assert(peeked.Priority == 5, "Parry priority must be 5")

-- Test 3: Allowed actions filter on PeekAction
local peekAttack = buffer:PeekAction({ "LightAttack", "HeavyAttack" }, t0 + 0.07)
assert(peekAttack ~= nil, "Should find filtered attack action")
assert(peekAttack.Action == "LightAttack", "Filtered action should be LightAttack")

-- Test 4: Consumption and history tracking
local consumedParry, payload = buffer:ConsumeAction("Parry", t0 + 0.08)
assert(consumedParry == true, "Parry should be consumed")
assert(payload.perfectWindow == true, "Payload should be preserved")

-- Test 5: Cooldown enforcement
buffer:BufferAction("DodgeRoll", nil, 3, nil, t0 + 0.1)
local consumedDodge, _ = buffer:ConsumeAction("DodgeRoll", t0 + 0.12)
assert(consumedDodge == true, "First DodgeRoll should be consumed")

-- Attempt immediate second DodgeRoll while cooldown (1.0s) is active
buffer:BufferAction("DodgeRoll", nil, 3, nil, t0 + 0.2)
assert(buffer:IsOnCooldown("DodgeRoll", t0 + 0.2) == true, "DodgeRoll must be on cooldown")
assert(buffer:GetRemainingCooldown("DodgeRoll", t0 + 0.2) > 0.8, "Remaining cooldown should be > 0.8s")

local consumedCooldown, _ = buffer:ConsumeAction("DodgeRoll", t0 + 0.25)
assert(consumedCooldown == false, "Action on cooldown cannot be consumed")

-- Advance time past cooldown
assert(buffer:IsOnCooldown("DodgeRoll", t0 + 1.2) == false, "Cooldown should expire after 1.0s")
buffer:BufferAction("DodgeRoll", nil, 3, nil, t0 + 1.2)
local consumedAfterCd, _ = buffer:ConsumeAction("DodgeRoll", t0 + 1.25)
assert(consumedAfterCd == true, "Action should be consumable after cooldown expiration")

-- Test 6: Expiration pruning
buffer:Clear()
buffer:BufferAction("OldAction", nil, 1, 0.2, t0)
assert(#buffer.Queue == 1, "Queue should have 1 item")
local prunedCount = buffer:Prune(t0 + 0.25)
assert(prunedCount == 1, "Prune should remove expired action")
assert(#buffer.Queue == 0, "Queue should be empty after pruning")

-- Test 7: Combo sequence detection
buffer:Reset()
local seqTime = 200.0
-- Execute combo sequence: Slash1 -> Slash2 -> Finisher
buffer:BufferAction("Slash1", nil, 1, 0.5, seqTime)
buffer:ConsumeAction("Slash1", seqTime + 0.05)

buffer:BufferAction("Slash2", nil, 1, 0.5, seqTime + 0.2)
buffer:ConsumeAction("Slash2", seqTime + 0.25)

buffer:BufferAction("Finisher", nil, 1, 0.5, seqTime + 0.4)
buffer:ConsumeAction("Finisher", seqTime + 0.45)

local comboSuccess = buffer:DetectCombo({ "Slash1", "Slash2", "Finisher" }, 1.0)
assert(comboSuccess == true, "Combo sequence should be detected")

local comboFailWrongOrder = buffer:DetectCombo({ "Slash2", "Slash1", "Finisher" }, 1.0)
assert(comboFailWrongOrder == false, "Wrong order should not trigger combo")

print("PASS: ActionBuffer tests (Initialization, Priority ordering, Filtering, Cooldowns, Expiration, Combo detection) passed cleanly!")
