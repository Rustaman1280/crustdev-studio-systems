local DamagePipeline = require("../src/ReplicatedStorage/Combat/DamagePipeline")

local function assertAlmostEqual(a: number, b: number, eps: number?, msg: string?)
  local epsilon = eps or 1e-4
  if math.abs(a - b) > epsilon then
    error(string.format("%s: expected ~%f, got %f", msg or "Assertion failed", b, a))
  end
end

-- Test 1: Deterministic Crit Rolling
assert(DamagePipeline.RollCrit(0.0, 1234, 1) == false, "Zero crit chance must return false")
assert(DamagePipeline.RollCrit(1.0, 1234, 1) == true, "100% crit chance must return true")
local r1 = DamagePipeline.RollCrit(0.5, 9999, 42)
local r2 = DamagePipeline.RollCrit(0.5, 9999, 42)
assert(r1 == r2, "Crit roll must be deterministic given identical seed and index")

-- Test 2: Armor Mitigation & Penetration
-- Raw 100, Armor 100, k 100 -> mult = 100 / 200 = 0.5 -> postArmor = 50, mitigated = 50
local post, mit = DamagePipeline.CalculateArmorMitigation(100, 100, 100, 0, 0)
assertAlmostEqual(post, 50, 1e-4, "Hyperbolic armor 100 should cut damage by 50%")
assertAlmostEqual(mit, 50, 1e-4, "Mitigated amount should be 50")

-- With flat pen 50 -> effective armor 50 -> mult = 100 / 150 = 0.6667 -> post = 66.6667
local postPen, mitPen = DamagePipeline.CalculateArmorMitigation(100, 100, 100, 50, 0)
assertAlmostEqual(postPen, 66.66667, 1e-3, "Flat pen 50 should reduce mitigation")

-- With percent pen 50% -> effective armor 50 -> post = 66.6667
local postPct, _ = DamagePipeline.CalculateArmorMitigation(100, 100, 100, 0, 0.5)
assertAlmostEqual(postPct, 66.66667, 1e-3, "Percent pen 50% should reduce mitigation")

-- Test 3: Elemental Resistances & Vulnerability
local postRes, mitRes = DamagePipeline.CalculateResistanceMitigation(100, 0.4)
assertAlmostEqual(postRes, 60, 1e-4, "40% resistance should leave 60 damage")
assertAlmostEqual(mitRes, 40, 1e-4, "40% resistance should mitigate 40 damage")

local postVuln, mitVuln = DamagePipeline.CalculateResistanceMitigation(100, -0.5)
assertAlmostEqual(postVuln, 150, 1e-4, "Negative 50% resistance should amplify to 150 damage")
assertAlmostEqual(mitVuln, -50, 1e-4, "Vulnerability should have negative mitigation")

-- Test 4: Flat Damage Reduction & Multi-layer Shields
local payload: DamagePipeline.DamagePayload = {
  attackerId = "Warrior",
  targetId = "Boss",
  rawAmount = 100,
  damageType = "Physical",
  isCrit = false,
}

local defense: DamagePipeline.TargetDefense = {
  armor = 0,
  flatDamageReduction = 10,
  currentHealth = 100,
  maxHealth = 100,
  shields = {
    { id = "Overshield", amount = 30, maxAmount = 50, absorptionRatio = 1.0 },
    { id = "EnergyBarrier", amount = 40, maxAmount = 40, absorptionRatio = 0.5 },
  },
}

-- Raw 100 - Flat 10 = 90.
-- Shield 1 (Overshield): absorbs 30 -> 0 remaining. Damage remaining = 60.
-- Shield 2 (EnergyBarrier): ratio 0.5 -> portion to absorb = 60 * 0.5 = 30.
-- Shield 2 amount = 40 - 30 = 10 remaining. Damage remaining = 60 - 30 = 30.
-- Health damage = 30. Health remaining = 100 - 30 = 70.
local res = DamagePipeline.ProcessDamage(payload, defense)
assertAlmostEqual(res.mitigatedByFlat, 10, 1e-4, "Flat reduction should be 10")
assertAlmostEqual(res.absorbedByShields, 60, 1e-4, "Shields should absorb 60 total")
assertAlmostEqual(res.finalHealthDamage, 30, 1e-4, "Final health damage should be 30")
assertAlmostEqual(res.targetRemainingHealth, 70, 1e-4, "Target remaining health should be 70")
assert(res.isLethal == false, "Damage must not be lethal")
assert(res.remainingShields[1].amount == 0, "Overshield should be broken")
assertAlmostEqual(res.remainingShields[2].amount, 10, 1e-4, "EnergyBarrier should have 10 left")

-- Test 5: True Damage Bypass
local truePayload: DamagePipeline.DamagePayload = {
  attackerId = "Mage",
  targetId = "Boss",
  rawAmount = 80,
  damageType = "True",
}
local trueDefense: DamagePipeline.TargetDefense = {
  armor = 300,
  flatDamageReduction = 50,
  currentHealth = 100,
  maxHealth = 100,
  shields = { { id = "Barrier", amount = 100, maxAmount = 100, absorptionRatio = 1.0 } },
}
local trueRes = DamagePipeline.ProcessDamage(truePayload, trueDefense)
assertAlmostEqual(trueRes.finalHealthDamage, 80, 1e-4, "True damage must bypass all defenses")
assertAlmostEqual(trueRes.mitigatedByArmor, 0, 1e-4, "Armor must not mitigate true damage")
assertAlmostEqual(trueRes.absorbedByShields, 0, 1e-4, "Shields must not absorb true damage")
assertAlmostEqual(trueRes.remainingShields[1].amount, 100, 1e-4, "Shield must remain full")
assertAlmostEqual(trueRes.targetRemainingHealth, 20, 1e-4, "Health should drop directly to 20")

-- Test 6: Critical Strike, Life Steal, and Thorns Reflection
local critPayload: DamagePipeline.DamagePayload = {
  attackerId = "Rogue",
  targetId = "Golem",
  rawAmount = 50,
  damageType = "Fire",
  isCrit = true,
  critMultiplier = 2.0, -- 50 * 2.0 = 100
}
local golemDefense: DamagePipeline.TargetDefense = {
  armor = 0,
  resistances = { Fire = 0.2 }, -- 100 * (1 - 0.2) = 80
  currentHealth = 60,
  maxHealth = 100,
}
local critRes = DamagePipeline.ProcessDamage(critPayload, golemDefense, {
  attackerLifeStealPercent = 0.25, -- 80 * 0.25 = 20
  targetReflectPercent = 0.10, -- 80 * 0.10 = 8
})
assertAlmostEqual(critRes.effectiveRawDamage, 100, 1e-4, "Crit should double raw damage to 100")
assertAlmostEqual(critRes.finalHealthDamage, 80, 1e-4, "Post-resistance health damage should be 80")
assert(critRes.isLethal == true, "80 damage against 60 HP must be lethal")
assertAlmostEqual(critRes.targetRemainingHealth, 0, 1e-4, "Health cannot go below 0")
assertAlmostEqual(critRes.lifeStealAmount, 20, 1e-4, "Lifesteal should be 20")
assertAlmostEqual(critRes.reflectedDamageAmount, 8, 1e-4, "Reflected damage should be 8")

print("PASS: DamagePipeline tests (Crit, Armor, Penetration, Resistances, Shields, True Damage, Lifesteal, Lethal) passed cleanly!")
