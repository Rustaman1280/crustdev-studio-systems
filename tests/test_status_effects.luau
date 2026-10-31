local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame

local StatusEffectManager = require("../src/ReplicatedStorage/Combat/StatusEffectManager")

-- Test 1: Manager initialization and basic apply
local manager = StatusEffectManager.new("Player_123")
assert(manager.OwnerId == "Player_123", "OwnerId should match")
assert(manager:HasEffect("Burn") == false, "Burn should not be active initially")

local burnDef = {
  Id = "Burn",
  Name = "Ignite",
  Type = "Debuff",
  StackPolicy = "Stack",
  MaxStacks = 3,
  BaseDuration = 2.0,
  TickInterval = 0.5,
  Modifiers = {
    Defense = { Type = "Flat", Value = -5 },
  },
  Flags = nil,
}

local created, effect = manager:ApplyEffect(burnDef, "Attacker_456", { baseDamage = 10 })
assert(created == true, "First application should create new effect")
assert(manager:HasEffect("Burn") == true, "Burn must now be active")
assert(manager:GetStackCount("Burn") == 1, "Initial stack count should be 1")
assert(effect.RemainingDuration == 2.0, "Initial duration should match baseDuration")

-- Test 2: Stack policy increments up to MaxStacks
manager:ApplyEffect(burnDef, "Attacker_456")
assert(manager:GetStackCount("Burn") == 2, "Stack count should now be 2")
manager:ApplyEffect(burnDef, "Attacker_456")
assert(manager:GetStackCount("Burn") == 3, "Stack count should now be 3")
manager:ApplyEffect(burnDef, "Attacker_456")
assert(manager:GetStackCount("Burn") == 3, "Stack count should cap at MaxStacks (3)")

-- Test 3: Crowd control flag detection
local stunDef = {
  Id = "Stun",
  Name = "Stunned",
  Type = "CrowdControl",
  StackPolicy = "Refresh",
  MaxStacks = 1,
  BaseDuration = 1.5,
  TickInterval = nil,
  Modifiers = nil,
  Flags = {
    IsStunned = true,
    IsImmobilized = true,
  },
}

assert(manager:HasFlag("IsStunned") == false, "Should not have IsStunned flag prior to apply")
manager:ApplyEffect(stunDef)
assert(manager:HasFlag("IsStunned") == true, "Should have IsStunned flag active")
assert(manager:HasFlag("IsImmobilized") == true, "Should have IsImmobilized flag active")
assert(manager:HasFlag("IsSilenced") == false, "Should not have unapplied IsSilenced flag")

-- Test 4: Stat computation (Flat, Additive, Multiplicative)
local hasteDef = {
  Id = "Haste",
  Name = "Wind Fury",
  Type = "Buff",
  StackPolicy = "Stack",
  MaxStacks = 5,
  BaseDuration = 5.0,
  Modifiers = {
    MoveSpeed = { Type = "Additive", Value = 0.20 }, -- +20% per stack
    AttackPower = { Type = "Flat", Value = 15 },     -- +15 flat per stack
  },
}

local rageDef = {
  Id = "Berserk",
  Name = "Berserk Rage",
  Type = "Buff",
  StackPolicy = "Refresh",
  MaxStacks = 1,
  BaseDuration = 4.0,
  Modifiers = {
    MoveSpeed = { Type = "Multiplicative", Value = 0.10 }, -- 1.10x multiplier
  },
}

manager:ApplyEffect(hasteDef)
manager:ApplyEffect(hasteDef) -- 2 stacks of Haste (+40% MoveSpeed, +30 Flat AttackPower)
manager:ApplyEffect(rageDef)   -- 1 stack of Berserk (1.10x MoveSpeed)

-- Base AttackPower = 100 -> +30 flat = 130
local computedAP = manager:ComputeStat("AttackPower", 100)
assert(computedAP == 130, string.format("Computed AP must be 130, got %s", tostring(computedAP)))

-- Base MoveSpeed = 16 -> 16 * (1 + 0.40) * 1.10 = 16 * 1.4 * 1.1 = 24.64
local computedSpeed = manager:ComputeStat("MoveSpeed", 16)
assert(math.abs(computedSpeed - 24.64) < 0.001, string.format("Computed speed should be ~24.64, got %s", tostring(computedSpeed)))

-- Base Defense = 50 -> Burn has 3 stacks of -5 Flat = -15 -> 35
local computedDef = manager:ComputeStat("Defense", 50)
assert(computedDef == 35, string.format("Computed defense should be 35, got %s", tostring(computedDef)))

-- Test 5: Step, Periodic DoT Ticks, and Expiration
-- Burn has BaseDuration 2.0, TickInterval 0.5 -> 4 ticks across 2.0s
local stepResult1 = manager:Step(0.6)
assert(#stepResult1.TickEvents == 1, string.format("Expected 1 tick event after 0.6s, got %d", #stepResult1.TickEvents))
assert(stepResult1.TickEvents[1].EffectId == "Burn", "Tick event should be Burn")
assert(stepResult1.TickEvents[1].Stacks == 3, "Tick event should report 3 stacks")

-- Advance time by 1.0s (total elapsed 1.6s). Stun has 1.5s duration -> should expire!
local stepResult2 = manager:Step(1.0)
-- Burn had 0.1 remaining in interval, 1.0 added -> 1.1 / 0.5 = 2 ticks emitted
assert(#stepResult2.TickEvents == 2, string.format("Expected 2 tick events, got %d", #stepResult2.TickEvents))
local stunExpired = false
for _, id in ipairs(stepResult2.ExpiredEffects) do
  if id == "Stun" then
    stunExpired = true
  end
end
assert(stunExpired == true, "Stun should have expired after 1.6s")
assert(manager:HasEffect("Stun") == false, "Stun must be removed from active effects")
assert(manager:HasFlag("IsStunned") == false, "IsStunned flag must clear after expiration")

-- Test 6: Independent stack policy
local poisonDef = {
  Id = "Poison",
  Name = "Spider Venom",
  Type = "Debuff",
  StackPolicy = "Independent",
  MaxStacks = 3,
  BaseDuration = 1.0,
  TickInterval = 0.25,
}

manager:ApplyEffect(poisonDef)
manager:Step(0.4) -- stack 1 has 0.6s remaining
manager:ApplyEffect(poisonDef) -- stack 2 has 1.0s remaining
assert(manager:GetStackCount("Poison") == 2, "Poison should have 2 independent stacks")

local stepResult3 = manager:Step(0.7) -- stack 1 expires (0.6 - 0.7 <= 0), stack 2 still has 0.3s
assert(manager:GetStackCount("Poison") == 1, "Stack 1 should expire leaving 1 stack")
assert(manager:HasEffect("Poison") == true, "Poison should still be active with 1 stack")

-- Test 7: Snapshot export
local snapshot = manager:GetReplicationSnapshot()
assert(snapshot["Poison"] ~= nil, "Snapshot should contain Poison")
assert(snapshot["Poison"].Stacks == 1, "Poison stacks in snapshot should be 1")

-- Test 8: Manual removal and clear
assert(manager:RemoveEffect("Poison") == true, "RemoveEffect should return true")
assert(manager:HasEffect("Poison") == false, "Poison should be removed")
manager:Clear()
assert(manager:HasEffect("Burn") == false, "Clear should wipe all active effects")

print("PASS: StatusEffectManager tests (Creation, Stacking, Flags, Modifiers, Periodic Ticks, Independent Stacks) passed cleanly!")
