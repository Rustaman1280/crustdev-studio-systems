--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local InterestManager = require("../src/ServerScriptService/Services/InterestManager")

local function assertEqual(actual: any, expected: any, msg: string?)
  if actual ~= expected then
    error(string.format("Assertion failed: expected '%s', got '%s'. %s", tostring(expected), tostring(actual), msg or ""))
  end
end

local function assertTrue(val: boolean, msg: string?)
  if not val then
    error(string.format("Assertion failed: expected true. %s", msg or ""))
  end
end

local function contains(list: { any }, target: any): boolean
  for _, v in ipairs(list) do
    if v == target then
      return true
    end
  end
  return false
end

-- 1. Tier Distance Classification
do
  local im = InterestManager.new()
  assertEqual(im:GetTierForDistance(50), "Immediate", "50 studs is Immediate")
  assertEqual(im:GetTierForDistance(80), "Immediate", "80 studs is Immediate threshold")
  assertEqual(im:GetTierForDistance(150), "Near", "150 studs is Near")
  assertEqual(im:GetTierForDistance(250), "Near", "250 studs is Near threshold")
  assertEqual(im:GetTierForDistance(400), "Far", "400 studs is Far")
  assertEqual(im:GetTierForDistance(600), "Far", "600 studs is Far threshold")
  assertEqual(im:GetTierForDistance(650), "Culled", "650 studs is Culled")
end

-- 2. Observer Lifecycle & Delta Tracking
do
  local im = InterestManager.new()

  -- Register Entities
  im:RegisterEntity("goblin_01", Vector3.new(0, 0, 50), 10)   -- Immediate (< 80)
  im:RegisterEntity("orc_boss", Vector3.new(0, 0, 180), 50)   -- Near (80 - 250)
  im:RegisterEntity("dragon_distant", Vector3.new(0, 0, 450), 100) -- Far (250 - 600)
  im:RegisterEntity("culled_entity", Vector3.new(0, 0, 1000), 1)   -- Culled (> 600)

  -- Register Observer at origin
  im:RegisterObserver("player_1", Vector3.new(0, 0, 0), 10)

  -- Tick 1: Initial Discovery
  local step1 = im:Step()
  local delta1 = step1["player_1"]
  assertTrue(delta1 ~= nil, "Observer player_1 received delta")
  assertEqual(#delta1.Entered, 3, "3 entities entered horizon")
  assertTrue(contains(delta1.Entered, "goblin_01"), "goblin_01 entered")
  assertTrue(contains(delta1.Entered, "orc_boss"), "orc_boss entered")
  assertTrue(contains(delta1.Entered, "dragon_distant"), "dragon_distant entered")
  assertTrue(not contains(delta1.Entered, "culled_entity"), "culled_entity not entered")
  assertEqual(#delta1.Updated, 3, "All 3 entered entities received initial update")

  -- Tick 2: Only Immediate tier (goblin_01) should update on tick 2 (interval=1)
  local step2 = im:Step()
  local delta2 = step2["player_1"]
  assertEqual(#delta2.Entered, 0, "No new entities entered on tick 2")
  assertEqual(#delta2.Updated, 1, "Only Immediate tier updated on tick 2")
  assertEqual(delta2.Updated[1], "goblin_01", "goblin_01 updated on tick 2")

  -- Tick 3: Only goblin_01 should update
  local step3 = im:Step()
  local delta3 = step3["player_1"]
  assertEqual(#delta3.Updated, 1, "Only Immediate tier updated on tick 3")

  -- Tick 4: Both Immediate (goblin_01) and Near (orc_boss, interval=3) should update!
  local step4 = im:Step()
  local delta4 = step4["player_1"]
  assertEqual(#delta4.Updated, 2, "Immediate and Near updated on tick 4")
  assertTrue(contains(delta4.Updated, "goblin_01"), "goblin_01 updated on tick 4")
  assertTrue(contains(delta4.Updated, "orc_boss"), "orc_boss updated on tick 4")

  -- 3. Tier Change Detection: move orc_boss closer (<80 studs)
  im:UpdateEntityPosition("orc_boss", Vector3.new(0, 0, 30))
  local step5 = im:Step()
  local delta5 = step5["player_1"]
  assertEqual(#delta5.TierChanged, 1, "One tier change detected")
  assertEqual(delta5.TierChanged[1].EntityId, "orc_boss", "orc_boss changed tier")
  assertEqual(delta5.TierChanged[1].OldTier, "Near", "Old tier was Near")
  assertEqual(delta5.TierChanged[1].NewTier, "Immediate", "New tier is Immediate")

  -- 4. Exited Detection: move dragon beyond Far radius (>600 studs)
  im:UpdateEntityPosition("dragon_distant", Vector3.new(0, 0, 800))
  local step6 = im:Step()
  local delta6 = step6["player_1"]
  assertEqual(#delta6.Exited, 1, "One entity exited interest horizon")
  assertEqual(delta6.Exited[1], "dragon_distant", "dragon_distant exited")

  -- 5. Entity Unregistering
  im:UnregisterEntity("goblin_01")
  local step7 = im:Step()
  local delta7 = step7["player_1"]
  assertEqual(#delta7.Exited, 1, "Unregistered entity marked as Exited")
  assertEqual(delta7.Exited[1], "goblin_01", "goblin_01 exited upon unregister")
end

-- 6. Bandwidth Budget Limiting and Priority Ordering
do
  local im = InterestManager.new()
  -- Register 5 immediate-tier entities with different priorities
  im:RegisterEntity("ent_low", Vector3.new(0, 0, 10), 1)
  im:RegisterEntity("ent_mid", Vector3.new(0, 0, 15), 5)
  im:RegisterEntity("ent_high", Vector3.new(0, 0, 20), 50)
  im:RegisterEntity("ent_critical", Vector3.new(0, 0, 25), 100)

  -- Observer with budget of only 2 entities per tick
  im:RegisterObserver("budget_player", Vector3.new(0, 0, 0), 2)

  local step = im:Step()
  local delta = step["budget_player"]
  assertEqual(#delta.Updated, 2, "Updates capped strictly at maxEntitiesPerTick budget")
  assertEqual(delta.Updated[1], "ent_critical", "Highest priority entity dispatched first")
  assertEqual(delta.Updated[2], "ent_high", "Second highest priority entity dispatched second")
end

print("PASS: InterestManager tests (Tier Distance, Discovery, Cadence, Transitions, Exits, Bandwidth Budget) passed cleanly!")
