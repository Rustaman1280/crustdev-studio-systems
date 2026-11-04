local UtilityAIModule = require("../src/ReplicatedStorage/AI/UtilityAI")
local UtilityAI = UtilityAIModule.new
local EvaluateCurve = UtilityAIModule.EvaluateCurve
local ApplyCompensationFactor = UtilityAIModule.ApplyCompensationFactor

-- Test 1: Mathematical Response Curves
assert(math.abs(EvaluateCurve(0.5, "Linear") - 0.5) < 1e-4, "Linear curve must match input")
assert(math.abs(EvaluateCurve(0.5, "Polynomial", 2.0) - 0.25) < 1e-4, "Polynomial curve x^2 must match")
assert(math.abs(EvaluateCurve(0.0, "SmoothStep") - 0.0) < 1e-4, "Smoothstep at 0 should be 0")
assert(math.abs(EvaluateCurve(1.0, "SmoothStep") - 1.0) < 1e-4, "Smoothstep at 1 should be 1")
assert(math.abs(EvaluateCurve(0.5, "SmoothStep") - 0.5) < 1e-4, "Smoothstep at 0.5 should be 0.5")

assert(EvaluateCurve(0.4, "Threshold", nil, nil, 0.5) == 0.0, "Threshold below cutoff must be 0")
assert(EvaluateCurve(0.6, "Threshold", nil, nil, 0.5) == 1.0, "Threshold above cutoff must be 1")

local logMid = EvaluateCurve(0.5, "Logistic", 10.0, 0.5)
assert(math.abs(logMid - 0.5) < 0.05, "Logistic midpoint should be approx 0.5")

-- Test 2: Dave Mark Compensation Factor
local raw2 = 0.5 * 0.5 -- 0.25
local comp2 = ApplyCompensationFactor(raw2, 2)
assert(comp2 > raw2, "Compensation factor should boost multi-factor score dilution")
assert(ApplyCompensationFactor(0.8, 1) == 0.8, "Single consideration should not be modified")

-- Test 3: Action Registration and Multi-Consideration Scoring
local ai = UtilityAI()

ai:RegisterAction({
  id = "attack",
  name = "Melee Attack",
  tier = 1,
  cooldown = 1.0,
  hysteresisBonus = 0.1,
  minScoreThreshold = 0.1,
})

ai:AddConsideration("attack", {
  name = "TargetDistance",
  minInput = 2,
  maxInput = 20,
  curve = "Linear",
  invert = true, -- closer is better
}, function(ctx)
  return ctx.targetDistance or 20
end)

ai:AddConsideration("attack", {
  name = "PlayerHealth",
  minInput = 0,
  maxInput = 100,
  curve = "SmoothStep",
}, function(ctx)
  return ctx.health or 100
end)

ai:RegisterAction({
  id = "heal",
  name = "Drink Potion",
  tier = 1,
  cooldown = 5.0,
  minScoreThreshold = 0.1,
})

ai:AddConsideration("heal", {
  name = "LowHealthUrgency",
  minInput = 0,
  maxInput = 100,
  curve = "Linear",
  invert = true, -- lower health means higher score
}, function(ctx)
  return ctx.health or 100
end)

-- High health, close target -> Attack should win
local eval1 = ai:Evaluate({ health = 90, targetDistance = 3 })
assert(eval1 ~= nil, "AI should select an action")
assert(eval1.actionId == "attack", string.format("Expected 'attack', got '%s'", eval1.actionId))

-- Low health (15 HP), far target -> Heal should win
local eval2 = ai:Evaluate({ health = 15, targetDistance = 15 })
assert(eval2 ~= nil, "AI should select an action")
assert(eval2.actionId == "heal", string.format("Expected 'heal', got '%s'", eval2.actionId))

-- Test 4: Cooldowns and Stepping
local step1 = ai:Step(0.1, { health = 15, targetDistance = 15 })
assert(step1 ~= nil and step1.actionId == "heal", "Heal chosen on step")
assert(ai:IsOnCooldown("heal") == true, "Heal should now be on cooldown")

-- Immediately next tick with same context -> heal is on cooldown, attack or nil should result
local evalOnCd = ai:Evaluate({ health = 15, targetDistance = 15 })
assert(evalOnCd == nil or evalOnCd.actionId ~= "heal", "Heal cannot be chosen while on cooldown")

-- Step forward with full health context past heal cooldown (5.5s)
ai:Step(5.5, { health = 100, targetDistance = 3 })
assert(ai:IsOnCooldown("heal") == false, "Heal cooldown must expire when not retriggered")

-- Test 5: Tier Priority
ai:RegisterAction({
  id = "flee",
  name = "Flee Combat",
  tier = 0, -- Critical emergency tier (tier 0 < tier 1)
  minScoreThreshold = 0.5,
})

ai:AddConsideration("flee", {
  name = "CriticalThreat",
  minInput = 0,
  maxInput = 1,
  curve = "Threshold",
  threshold = 0.8,
}, function(ctx)
  return ctx.imminentDeath and 1 or 0
end)

local emergencyEval = ai:Evaluate({ imminentDeath = true, health = 90, targetDistance = 2 })
assert(emergencyEval ~= nil and emergencyEval.actionId == "flee", "Emergency Tier 0 must override Tier 1")

-- Test 6: Hysteresis / Momentum Bonus
local ai2 = UtilityAI()
ai2:RegisterAction({
  id = "patrol",
  name = "Patrol Path",
  baseScore = 0.45,
  hysteresisBonus = 0.2, -- pushes 0.45 to 0.65 when active
})
ai2:RegisterAction({
  id = "inspect",
  name = "Inspect Sound",
  baseScore = 0.55,
})

-- Initial eval: inspect (0.55) > patrol (0.45)
local first = ai2:Step(0.1, {})
assert(first ~= nil and first.actionId == "inspect", "Inspect wins initial tick")

-- Now switch active to patrol manually
ai2:TriggerAction("patrol")
-- With hysteresis bonus, patrol becomes 0.45 + 0.20 = 0.65 > inspect (0.55)
local second = ai2:Step(0.1, {})
assert(second ~= nil and second.actionId == "patrol", "Patrol retains active state due to hysteresis")

-- Test 7: Softmax Probabilistic Mode
local counts = { patrol = 0, inspect = 0 }
for _ = 1, 100 do
  local chosen = ai2:Evaluate({}, "Softmax", 0.5)
  if chosen then
    counts[chosen.actionId] = (counts[chosen.actionId] or 0) + 1
  end
end
assert(counts.patrol > 0 and counts.inspect > 0, "Softmax must sample distribution over repeated evaluations")

-- Test 8: Reset
ai2:Reset()
local state = ai2:GetState()
assert(state.activeActionId == nil, "Active action must clear on reset")
assert(state.previousActionId == nil, "Previous action must clear on reset")

print("PASS: UtilityAI tests (Curves, Compensation, Multi-Consideration, Cooldowns, Tiers, Hysteresis, Softmax, Reset) passed cleanly!")
