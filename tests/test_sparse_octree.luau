--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local SparseOctree = require("../src/ReplicatedStorage/Spatial/SparseOctree")

-- 1. Test initialization
local octree = SparseOctree.new(Vector3.new(0, 0, 0), Vector3.new(512, 512, 512), 4, 4)

assert(octree ~= nil, "SparseOctree instance must not be nil")
assert(octree:Count() == 0, "Initial count must be 0")
assert(octree.Root.Children == nil, "Root should not have children initially")

-- 2. Test insertion of entities across octants
local e1 = octree:Insert("e1", Vector3.new(50, 50, 50), 2.0, { type = "ore_deposit" })
local e2 = octree:Insert("e2", Vector3.new(-50, -50, -50), 2.0, { type = "crystal" })
local e3 = octree:Insert("e3", Vector3.new(60, 55, 45), 3.0, { type = "cave_spider" })

assert(e1 == true and e2 == true and e3 == true, "Insertions should succeed")
assert(octree:Count() == 3, string.format("Expected count 3, got %d", octree:Count()))

-- 3. Test dynamic node subdivision when capacity is exceeded
-- Insert more entities into positive (+X, +Y, +Z) octant to trigger split
octree:Insert("p1", Vector3.new(10, 10, 10), 1.0)
octree:Insert("p2", Vector3.new(12, 12, 12), 1.0)
octree:Insert("p3", Vector3.new(14, 14, 14), 1.0)
octree:Insert("p4", Vector3.new(16, 16, 16), 1.0)

-- Root should have subdivided because positive octant received > 4 entities
assert(octree.Root.Children ~= nil, "Root should have subdivided after capacity reached")
assert(#octree.Root.Children == 8, "Subdivided node must have 8 child octants")
assert(octree:Count() == 7, string.format("Expected count 7, got %d", octree:Count()))

-- 4. Test QueryRadius (hierarchical sphere query)
local nearResults = octree:QueryRadius(Vector3.new(55, 50, 50), 20.0)
assert(#nearResults >= 2, string.format("Expected at least 2 entities near (55, 50, 50), got %d", #nearResults))

local hasE1 = false
local hasE3 = false
local hasE2 = false

for _, ent in ipairs(nearResults) do
  if ent.Id == "e1" then hasE1 = true end
  if ent.Id == "e3" then hasE3 = true end
  if ent.Id == "e2" then hasE2 = true end
end

assert(hasE1 == true, "e1 should be found within radius")
assert(hasE3 == true, "e3 should be found within radius")
assert(hasE2 == false, "e2 is in negative octant and must not be included")

-- Query empty region
local emptyResults = octree:QueryRadius(Vector3.new(400, 400, 400), 10.0)
assert(#emptyResults == 0, string.format("Expected 0 entities in distant empty space, got %d", #emptyResults))

-- 5. Test QueryAABB (3D bounding box query)
local minBox = Vector3.new(0, 0, 0)
local maxBox = Vector3.new(100, 100, 100)
local aabbResults = octree:QueryAABB(minBox, maxBox)

assert(#aabbResults == 6, string.format("Expected 6 positive entities inside [0..100] AABB, got %d", #aabbResults))

-- 6. Test Raycast query
-- Shoot ray from (0, 50, 50) pointing directly along +X toward e1 at (50, 50, 50)
local rayHit = octree:Raycast(Vector3.new(0, 50, 50), Vector3.new(1, 0, 0), 100.0)

assert(rayHit ~= nil, "Raycast should hit e1")
assert(rayHit.Entity.Id == "e1", string.format("Expected hit e1, got %s", tostring(rayHit.Entity.Id)))
assert(math.abs(rayHit.Distance - 48.0) <= 0.1, string.format("Hit distance should be near 48 (50 - radius 2), got %.2f", rayHit.Distance))

-- Shoot ray into empty direction
local missHit = octree:Raycast(Vector3.new(0, 0, 0), Vector3.new(0, -1, 0), 100.0)
assert(missHit == nil, "Raycast into empty space must return nil")

-- 7. Test Update (entity repositioning across octants)
-- Move e2 from (-50, -50, -50) to (+200, +200, +200)
local updated = octree:Update("e2", Vector3.new(200, 200, 200), 2.0)
assert(updated == true, "Update must succeed")

local movedRadius = octree:QueryRadius(Vector3.new(200, 200, 200), 5.0)
assert(#movedRadius == 1, string.format("Expected 1 entity at new position, got %d", #movedRadius))
assert(movedRadius[1].Id == "e2", "Entity at new position must be e2")

local oldRadius = octree:QueryRadius(Vector3.new(-50, -50, -50), 5.0)
assert(#oldRadius == 0, "Old position must no longer return e2")

-- 8. Test Remove and Clear
local removed = octree:Remove("e2")
assert(removed == true, "Remove must succeed")
assert(octree:Count() == 6, string.format("Expected count 6 after remove, got %d", octree:Count()))

octree:Clear()
assert(octree:Count() == 0, "Count must be 0 after Clear")
assert(#octree:QueryRadius(Vector3.new(0, 0, 0), 500.0) == 0, "Query on cleared tree must return empty")

print("PASS: SparseOctree tests (Init, Insert, Subdivision, QueryRadius, QueryAABB, Raycast, Update, Remove, Clear) passed cleanly!")
