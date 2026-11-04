--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local ParryRiposteWindow = require("../src/ReplicatedStorage/Combat/ParryRiposteWindow")

local function assertApprox(a: number, b: number, eps: number?, msg: string?)
  local epsilon = eps or 1e-4
  if math.abs(a - b) > epsilon then
    error(string.format("%s: expected approx %f, got %f (diff: %f)", msg or "assertApprox", b, a, math.abs(a - b)))
  end
end

-- 1. State Transitions: Startup -> Active -> Whiff -> Neutral
do
  local pr = ParryRiposteWindow.new({
    StartupDuration = 0.05,
    ActiveDuration = 0.15,
    WhiffPenaltyDuration = 0.30,
  })

  assert(pr:GetState() == "Neutral", "Initial state must be Neutral")
  assert(pr:CanParry(), "Should be able to parry from Neutral")

  local triggered = pr:TriggerParry()
  assert(triggered, "TriggerParry should succeed")
  assert(pr:GetState() == "ParryStartup", "State should be ParryStartup")

  -- Advance through startup
  pr:Update(0.06)
  assert(pr:GetState() == "ParryActive", "State should advance to ParryActive")

  -- Advance through active window with no incoming hits (whiff)
  pr:Update(0.16)
  assert(pr:GetState() == "ParryWhiff", "State should advance to ParryWhiff on empty parry")
  assert(pr:IsVulnerable(), "Defender in ParryWhiff must be vulnerable")

  -- Advance through whiff recovery
  pr:Update(0.31)
  assert(pr:GetState() == "Neutral", "State should return to Neutral after whiff duration")
  assert(not pr:IsVulnerable(), "Neutral state should not be vulnerable")
end

-- 2. Perfect Parry & Riposte Execution
do
  local pr = ParryRiposteWindow.new({
    StartupDuration = 0.05,
    ActiveDuration = 0.20,
    ParryAngleDeg = 100,
    RiposteDamageMultiplier = 2.5,
  })

  local parrySuccessReported = false
  pr:OnParrySuccess(function(attackerId, stunDuration)
    parrySuccessReported = true
    assert(attackerId == "boss_vanguard", "Attacker ID must match")
    assert(stunDuration > 1.0, "Stun duration should be positive")
  end)

  pr:TriggerParry()
  pr:Update(0.06) -- Enter ParryActive
  assert(pr:GetState() == "ParryActive", "Must be in ParryActive")

  local defenderPos = Vector3.new(0, 0, 0)
  local defenderFacing = Vector3.new(0, 0, 1) -- Facing +Z
  local attack = {
    AttackerId = "boss_vanguard",
    AttackerPosition = Vector3.new(0, 0, 5), -- Direct frontal attack (+Z)
    Damage = 120,
    PostureDamage = 40,
  }

  local res = pr:ProcessIncomingAttack(defenderPos, defenderFacing, attack)
  assert(res.Outcome == "Parried", "Attack must be parried")
  assert(res.DamageTaken == 0, "Parried attack must deal 0 damage")
  assert(res.PostureDamageTaken == 0, "Parried attack must deal 0 posture damage")
  assert(res.DefenderRiposteAvailable, "Riposte must be available")
  assertApprox(res.RiposteMultiplier, 2.5, 1e-3, "Riposte multiplier should match config")
  assert(parrySuccessReported, "OnParrySuccess callback must be fired")
  assert(pr:GetState() == "RiposteReady", "State must transition to RiposteReady")

  -- Consume Riposte
  local ok, mult, target = pr:ConsumeRiposte()
  assert(ok, "Riposte should be successfully consumed")
  assertApprox(mult, 2.5, 1e-3, "Consumed multiplier should be 2.5")
  assert(target == "boss_vanguard", "Target must match attacker")
  assert(pr:GetState() == "Neutral", "Consuming riposte should return to Neutral")
end

-- 3. Unparryable Attack during Parry Window
do
  local pr = ParryRiposteWindow.new({
    StartupDuration = 0.05,
    ActiveDuration = 0.20,
  })

  pr:TriggerParry()
  pr:Update(0.06) -- Active

  local defenderPos = Vector3.new(0, 0, 0)
  local defenderFacing = Vector3.new(0, 0, 1)
  local attack = {
    AttackerId = "colossus_slam",
    AttackerPosition = Vector3.new(0, 0, 5),
    Damage = 200,
    PostureDamage = 50,
    Unparryable = true, -- Heavy slam that cannot be parried
  }

  local res = pr:ProcessIncomingAttack(defenderPos, defenderFacing, attack)
  assert(res.Outcome == "Hit", "Unparryable attack should hit defender")
  assert(res.DamageTaken == 200, "Full damage should be taken")
end

-- 4. Flanked Attack (Outside Parry Angle)
do
  local pr = ParryRiposteWindow.new({
    StartupDuration = 0.05,
    ActiveDuration = 0.20,
    ParryAngleDeg = 90, -- 45 degrees left/right
  })

  pr:TriggerParry()
  pr:Update(0.06)

  local defenderPos = Vector3.new(0, 0, 0)
  local defenderFacing = Vector3.new(0, 0, 1) -- Facing +Z
  local attackFromBehind = {
    AttackerId = "rogue_backstab",
    AttackerPosition = Vector3.new(0, 0, -5), -- Attacking from -Z (180 degrees behind)
    Damage = 150,
    PostureDamage = 30,
  }

  local res = pr:ProcessIncomingAttack(defenderPos, defenderFacing, attackFromBehind)
  assert(res.Outcome == "Hit", "Attack from behind should hit defender")
  assert(not res.AngleWithinParryCone, "Should be outside parry cone")
  assert(res.DamageTaken == 150, "Full damage taken from behind")
end

-- 5. Guarding, Mitigation & Posture Drain
do
  local pr = ParryRiposteWindow.new({
    MaxPosture = 100,
    BlockMitigation = 0.80, -- 80% mitigated, 20% chip damage
    BlockAngleDeg = 140,
  })

  pr:StartBlock()
  assert(pr:GetState() == "Guarding", "Must be Guarding")

  local defenderPos = Vector3.new(0, 0, 0)
  local defenderFacing = Vector3.new(1, 0, 0) -- Facing +X
  local attack = {
    AttackerId = "soldier_slash",
    AttackerPosition = Vector3.new(5, 0, 0), -- From +X
    Damage = 100,
    PostureDamage = 35,
  }

  local res = pr:ProcessIncomingAttack(defenderPos, defenderFacing, attack)
  assert(res.Outcome == "Blocked", "Attack should be blocked")
  assertApprox(res.DamageTaken, 20, 1e-3, "Chip damage should be 20")
  assertApprox(res.PostureDamageTaken, 35, 1e-3, "Posture damage should be 35")

  local currentPosture, maxPosture = pr:GetPosture()
  assertApprox(currentPosture, 65, 1e-3, "Remaining posture should be 65/100")
end

-- 6. Guard Break Mechanics
do
  local pr = ParryRiposteWindow.new({
    MaxPosture = 50,
    GuardBreakStunDuration = 2.0,
  })

  local guardBreakReported = false
  pr:OnGuardBreak(function(attackerId, stunDuration)
    guardBreakReported = true
    assert(stunDuration == 2.0, "Stun duration should match")
  end)

  pr:StartBlock()

  local defenderPos = Vector3.new(0, 0, 0)
  local defenderFacing = Vector3.new(0, 0, 1)
  local heavyAttack = {
    AttackerId = "crusher_hammer",
    AttackerPosition = Vector3.new(0, 0, 4),
    Damage = 150,
    PostureDamage = 60, -- Exceeds 50 posture!
  }

  local res = pr:ProcessIncomingAttack(defenderPos, defenderFacing, heavyAttack)
  assert(res.Outcome == "GuardBroken", "Should trigger GuardBroken outcome")
  assert(guardBreakReported, "OnGuardBreak callback must be fired")
  assert(pr:GetState() == "GuardBroken", "State must transition to GuardBroken")
  assert(pr:IsVulnerable(), "Guard broken defender must be vulnerable")

  local curPost, _ = pr:GetPosture()
  assert(curPost == 0, "Posture should be 0 on guard break")

  -- Update through stun duration
  pr:Update(2.1)
  assert(pr:GetState() == "Neutral", "Should recover to Neutral after stun duration")
  local recPost, _ = pr:GetPosture()
  assert(recPost == 25, "Should recover 50% posture after stun")
end

-- 7. Whiff Punish Damage Bonus
do
  local pr = ParryRiposteWindow.new({
    StartupDuration = 0.05,
    ActiveDuration = 0.10,
    WhiffPenaltyDuration = 0.30,
    WhiffDamageMultiplier = 1.30, -- +30% punish damage
  })

  pr:TriggerParry()
  pr:Update(0.16) -- Past active into Whiff
  assert(pr:GetState() == "ParryWhiff", "Must be in ParryWhiff")

  local defenderPos = Vector3.new(0, 0, 0)
  local defenderFacing = Vector3.new(0, 0, 1)
  local attack = {
    AttackerId = "punish_spear",
    AttackerPosition = Vector3.new(0, 0, 3),
    Damage = 100,
    PostureDamage = 20,
  }

  local res = pr:ProcessIncomingAttack(defenderPos, defenderFacing, attack)
  assert(res.Outcome == "WhiffPunished", "Outcome should be WhiffPunished")
  assertApprox(res.DamageTaken, 130, 1e-3, "Punish damage should be 100 * 1.30 = 130")
end

-- 8. Posture Regeneration
do
  local pr = ParryRiposteWindow.new({
    MaxPosture = 100,
    PostureRegenRate = 50, -- 50 per second
    PostureRegenDelay = 0.5, -- 0.5s delay
  })

  -- Manually drain posture via hit
  local defenderPos = Vector3.new(0, 0, 0)
  local defenderFacing = Vector3.new(0, 0, 1)
  pr:ProcessIncomingAttack(defenderPos, defenderFacing, {
    AttackerId = "test_poke",
    AttackerPosition = Vector3.new(0, 0, 1),
    Damage = 10,
    PostureDamage = 40,
  })

  local post1, _ = pr:GetPosture()
  assertApprox(post1, 60, 1e-3, "Posture drained to 60")

  -- During cooldown (0.3s < 0.5s), no regen
  pr:Update(0.3)
  local post2, _ = pr:GetPosture()
  assertApprox(post2, 60, 1e-3, "Posture should not regenerate during cooldown")

  -- After delay expires (another 0.3s), regenerates at 50/s
  pr:Update(0.4) -- 0.2s of actual regen -> 10 points
  local post3, _ = pr:GetPosture()
  assert(post3 > 65, "Posture should regenerate after cooldown")
end

print("ParryRiposteWindow tests passed successfully!")
