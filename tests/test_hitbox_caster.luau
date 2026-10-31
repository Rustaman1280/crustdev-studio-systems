local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame

local HitboxCaster = require("../src/ReplicatedStorage/Combat/HitboxCaster")

-- Mock raycast world with simple bounding box / line segment intersections
local function createMockRaycast(targets: { { Instance: any, Min: Vector3, Max: Vector3 } })
  return function(origin: Vector3, direction: Vector3)
    local dirMag = direction.Magnitude
    if dirMag < 0.0001 then
      return nil
    end

    -- Segment raycast against simple AABBs
    local bestDistance = math.huge
    local bestHit = nil

    for _, target in ipairs(targets) do
      -- Check if line segment intersects target AABB
      -- Sample 10 points along the segment for robust discrete hit detection in mock
      for s = 0, 10 do
        local p = origin + direction * (s / 10)
        if p.X >= target.Min.X and p.X <= target.Max.X
          and p.Y >= target.Min.Y and p.Y <= target.Max.Y
          and p.Z >= target.Min.Z and p.Z <= target.Max.Z then
          local dist = (p - origin).Magnitude
          if dist < bestDistance then
            bestDistance = dist
            bestHit = {
              Instance = target.Instance,
              Position = p,
              Normal = Vector3.new(0, 1, 0),
              Material = "Plastic",
            }
          end
          break
        end
      end
    end

    return bestHit
  end
end

-- Test 1: HitboxCaster initialization and defaults
local bladeOffsets = {
  Vector3.new(0, 1, 0), -- Hilt
  Vector3.new(0, 3, 0), -- Mid-blade
  Vector3.new(0, 5, 0), -- Tip
}

local caster = HitboxCaster.new({
  Offsets = bladeOffsets,
  SubSteps = 3,
  ConnectEdges = true,
})

assert(caster.SubSteps == 3, "SubSteps should be 3")
assert(caster.ConnectEdges == true, "ConnectEdges should be true")
assert(caster.IsActive == false, "Should not be active initially")

-- Test 2: Inactive caster returns empty hits
local emptyHits = caster:Step(CFrame.new(0, 0, 0), function() return nil end)
assert(#emptyHits == 0, "Inactive caster must return empty table")

-- Test 3: Melee sweep detection and debounce
local dummyEnemyA = { Id = "EnemyA" }
local dummyEnemyB = { Id = "EnemyB" }

local mockWorld = createMockRaycast({
  {
    Instance = dummyEnemyA,
    Min = Vector3.new(1.0, 2.0, -1.0),
    Max = Vector3.new(3.0, 6.0, 1.0),
  },
  {
    Instance = dummyEnemyB,
    Min = Vector3.new(8.0, 2.0, -1.0),
    Max = Vector3.new(12.0, 6.0, 1.0),
  },
})

-- Start swing at X = 0
caster:Start(CFrame.new(0, 0, 0))
assert(caster.IsActive == true, "Caster must be active after Start")
assert(#caster.PreviousPoints == 3, "PreviousPoints should have 3 points")

-- Frame 1: Swing from X = 0 to X = 4 (passing through EnemyA at X = 1..3)
local hitsFrame1 = caster:Step(CFrame.new(4, 0, 0), mockWorld)
assert(#hitsFrame1 > 0, "Should detect hit on EnemyA during swing")
assert(hitsFrame1[1].Instance == dummyEnemyA, "Hit instance should be EnemyA")

-- Frame 2: Continue swing from X = 4 to X = 6 (no enemies)
local hitsFrame2 = caster:Step(CFrame.new(6, 0, 0), mockWorld)
assert(#hitsFrame2 == 0, "No hits expected in empty space")

-- Frame 3: Move back over EnemyA (X = 2) within same swing
-- HitDebounce must prevent hitting EnemyA again during this swing session
local hitsFrame3 = caster:Step(CFrame.new(2, 0, 0), mockWorld)
assert(#hitsFrame3 == 0, "EnemyA must be debounced and not hit again in same swing")

-- Frame 4: Swing forward to X = 10 (hitting EnemyB)
local hitsFrame4 = caster:Step(CFrame.new(10, 0, 0), mockWorld)
assert(#hitsFrame4 > 0, "Should detect hit on EnemyB")
assert(hitsFrame4[1].Instance == dummyEnemyB, "Hit instance should be EnemyB")

-- Test 4: Stop resets active state and debounce
caster:Stop()
assert(caster.IsActive == false, "Caster should be inactive after Stop")
assert(caster.PreviousTransform == nil, "PreviousTransform should be cleared")

-- New swing session: EnemyA can now be hit again
caster:Start(CFrame.new(0, 0, 0))
local hitsNewSwing = caster:Step(CFrame.new(2.5, 0, 0), mockWorld)
assert(#hitsNewSwing > 0, "EnemyA should be hittable in a fresh swing session")
assert(hitsNewSwing[1].Instance == dummyEnemyA, "Fresh swing hits EnemyA")

caster:Stop()

print("PASS: HitboxCaster tests (Initialization, Inactive state, Melee sweep, Debounce, Sub-step, Reset) passed cleanly!")
