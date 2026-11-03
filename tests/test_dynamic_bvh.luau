--!strict
local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

local DynamicBVH = require("../src/ReplicatedStorage/Spatial/DynamicBVH")

local function assertApprox(a: number, b: number, eps: number?, msg: string?)
  local epsilon = eps or 1e-3
  if math.abs(a - b) > epsilon then
    error(string.format("%s: expected approx %f, got %f", msg or "assertApprox", b, a))
  end
end

-- Test 1: AABB Primitives & Raycast Slab Test
do
  local boxA = DynamicBVH.AABB.new(Vector3.new(0, 0, 0), Vector3.new(10, 10, 10))
  local boxB = DynamicBVH.AABB.new(Vector3.new(5, 5, 5), Vector3.new(15, 15, 15))
  local boxC = DynamicBVH.AABB.new(Vector3.new(20, 20, 20), Vector3.new(30, 30, 30))

  assert(DynamicBVH.AABB.ContainsPoint(boxA, Vector3.new(5, 5, 5)), "BoxA should contain (5,5,5)")
  assert(not DynamicBVH.AABB.ContainsPoint(boxA, Vector3.new(15, 5, 5)), "BoxA should not contain (15,5,5)")

  assert(DynamicBVH.AABB.IntersectsAABB(boxA, boxB), "BoxA and BoxB must intersect")
  assert(not DynamicBVH.AABB.IntersectsAABB(boxA, boxC), "BoxA and BoxC must not intersect")

  local unionAC = DynamicBVH.AABB.Union(boxA, boxC)
  assert(unionAC.Min.X == 0 and unionAC.Max.X == 30, "Union bounds must encompass both boxes")
  assert(DynamicBVH.AABB.ContainsAABB(unionAC, boxA), "Union must contain BoxA")
  assert(DynamicBVH.AABB.ContainsAABB(unionAC, boxC), "Union must contain BoxC")

  -- Raycast Slab Test on BoxA
  local origin = Vector3.new(-10, 5, 5)
  local dir = Vector3.new(1, 0, 0)
  local hit, dist, norm = DynamicBVH.AABB.Raycast(boxA, origin, dir, 50)
  assert(hit == true, "Ray must hit BoxA")
  assertApprox(dist :: number, 10, 1e-3, "Distance should be 10")
  assert(norm and norm.X == -1, "Normal should face negative X")

  -- Raycast miss
  local missHit = DynamicBVH.AABB.Raycast(boxA, Vector3.new(-10, 20, 20), dir, 50)
  assert(missHit == false, "Ray should miss BoxA")
end

-- Test 2: Tree Invariants & Balance on Multi-Node Insertion
do
  local bvh = DynamicBVH.new(0.5)
  assert(bvh:GetLeafCount() == 0, "Initial leaf count 0")
  assert(bvh:GetDepth() == 0, "Initial depth 0")
  assert(bvh:ValidateTree(), "Empty tree must be valid")

  -- Insert 30 boxes in a 3D grid
  for i = 1, 30 do
    local minP = Vector3.new(i * 10, (i % 5) * 10, 0)
    local maxP = minP + Vector3.new(4, 4, 4)
    local box = DynamicBVH.AABB.new(minP, maxP)
    bvh:Insert("entity_" .. i, box, { index = i })
  end

  assert(bvh:GetLeafCount() == 30, "Leaf count should be 30")
  assert(bvh:ValidateTree(), "Tree must satisfy AVL balance and AABB invariants")
  -- Depth of 30 balanced leaves should be around O(log2 30) <= 7
  assert(bvh:GetDepth() <= 7, "Tree depth must be bounded logarithmically")
end

-- Test 3: Dynamic Update & Loose Fattening Fast-Path
do
  local bvh = DynamicBVH.new(1.0)
  local initialBox = DynamicBVH.AABB.new(Vector3.new(0, 0, 0), Vector3.new(2, 2, 2))
  bvh:Insert("mover", initialBox, "player")

  -- Slight movement inside the fattened margin (0.2 studs) -> should not trigger tree rebuild!
  local smallShift = DynamicBVH.AABB.new(Vector3.new(0.2, 0.2, 0.2), Vector3.new(2.2, 2.2, 2.2))
  local reinserted = bvh:Update("mover", smallShift)
  assert(reinserted == false, "Small displacement should hit fast-path within fattened bounds")

  -- Large movement outside margin (15 studs) -> triggers re-insertion
  local largeShift = DynamicBVH.AABB.new(Vector3.new(15, 0, 0), Vector3.new(17, 2, 2))
  local reinsertedLarge = bvh:Update("mover", largeShift, Vector3.new(5, 0, 0))
  assert(reinsertedLarge == true, "Large displacement must trigger tree reinsertion")
  assert(bvh:ValidateTree(), "Tree must remain valid after large displacement update")
end

-- Test 4: Raycast Closest Hit & Filter Function
do
  local bvh = DynamicBVH.new(0.1)
  -- Place three obstacles in line: x=10 (dist 10), x=20 (dist 20), x=30 (dist 30)
  bvh:Insert("wall_1", DynamicBVH.AABB.new(Vector3.new(10, -2, -2), Vector3.new(12, 2, 2)), { type = "glass" })
  bvh:Insert("wall_2", DynamicBVH.AABB.new(Vector3.new(20, -2, -2), Vector3.new(22, 2, 2)), { type = "concrete" })
  bvh:Insert("wall_3", DynamicBVH.AABB.new(Vector3.new(30, -2, -2), Vector3.new(32, 2, 2)), { type = "steel" })

  local rayOrigin = Vector3.new(0, 0, 0)
  local rayDir = Vector3.new(1, 0, 0)

  -- Nearest hit without filter should hit wall_1
  local hit = bvh:Raycast(rayOrigin, rayDir, 100)
  assert(hit ~= nil, "Raycast should find hit")
  assert(hit and hit.Id == "wall_1", "Should hit closest obstacle (wall_1)")

  -- Filter out glass: should hit wall_2
  local concreteHit = bvh:Raycast(rayOrigin, rayDir, 100, function(id, data)
    return data.type ~= "glass"
  end)
  assert(concreteHit ~= nil, "Filtered raycast should find hit")
  assert(concreteHit and concreteHit.Id == "wall_2", "Should hit wall_2 when glass is filtered")

  -- RaycastAll returns all hits ordered by distance
  local allHits = bvh:RaycastAll(rayOrigin, rayDir, 100)
  assert(#allHits == 3, "RaycastAll should return all 3 obstacles")
  assert(allHits[1].Id == "wall_1" and allHits[2].Id == "wall_2" and allHits[3].Id == "wall_3", "Hits must be distance ordered")
end

-- Test 5: QueryAABB, QuerySphere, and Removal
do
  local bvh = DynamicBVH.new(0.2)
  bvh:Insert("target_a", DynamicBVH.AABB.new(Vector3.new(5, 5, 5), Vector3.new(7, 7, 7)), "A")
  bvh:Insert("target_b", DynamicBVH.AABB.new(Vector3.new(50, 50, 50), Vector3.new(52, 52, 52)), "B")

  -- Sphere query centered at (6, 6, 6) with radius 3
  local sphereHits = bvh:QuerySphere(Vector3.new(6, 6, 6), 3)
  assert(#sphereHits == 1, "Sphere should only find target_a")
  assert(sphereHits[1].Id == "target_a", "Sphere hit should be target_a")

  -- Remove target_a
  local removed = bvh:Remove("target_a")
  assert(removed == true, "Remove target_a should succeed")
  assert(bvh:GetLeafCount() == 1, "Remaining leaf count should be 1")
  assert(bvh:ValidateTree(), "Tree must be valid after removal")

  local emptySphereHits = bvh:QuerySphere(Vector3.new(6, 6, 6), 3)
  assert(#emptySphereHits == 0, "Sphere query should now find 0 results")
end

-- Test 6: Broadphase Overlapping Pairs Detection
do
  local bvh = DynamicBVH.new(0.0) -- No margin for exact geometric test
  -- Pair 1: Overlapping
  bvh:Insert("obj_1", DynamicBVH.AABB.new(Vector3.new(0, 0, 0), Vector3.new(4, 4, 4)), "1")
  bvh:Insert("obj_2", DynamicBVH.AABB.new(Vector3.new(2, 2, 2), Vector3.new(6, 6, 6)), "2")

  -- Pair 2: Disjoint
  bvh:Insert("obj_3", DynamicBVH.AABB.new(Vector3.new(100, 100, 100), Vector3.new(105, 105, 105)), "3")

  local pairs = bvh:FindOverlappingPairs()
  assert(#pairs == 1, string.format("Expected exactly 1 overlapping pair, got %d", #pairs))
  local p = pairs[1]
  local match = (p.IdA == "obj_1" and p.IdB == "obj_2") or (p.IdA == "obj_2" and p.IdB == "obj_1")
  assert(match, "Overlapping pair should be obj_1 and obj_2")
end

print("PASS: DynamicBVH tests (AABB Primitives, RaySlab, MultiNode Balance, Update FastPath, Raycast Filters, SphereQuery, Broadphase Pairs) passed cleanly!")
