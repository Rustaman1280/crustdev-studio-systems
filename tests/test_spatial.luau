local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

local SpatialHashGrid = require("../src/ReplicatedStorage/Spatial/SpatialHashGrid")
local grid = SpatialHashGrid.new(16.0)

-- Test 1: Insert
local inserted = grid:Insert("player_1", Vector3.new(10, 0, 10), 2.0, "warrior")
assert(inserted, "Should successfully insert")
assert(grid.TotalEntities == 1, "TotalEntities should be 1")

-- Duplicate insert should fail
local dupe = grid:Insert("player_1", Vector3.new(10, 0, 10), 2.0, "warrior")
assert(not dupe, "Duplicate insert should return false")

-- Test 2: QueryRadius
local results = grid:QueryRadius(Vector3.new(12, 0, 12), 5.0)
assert(#results == 1, "Should find 1 entity in radius")
assert(results[1].Id == "player_1", "Result ID should match player_1")

-- Outside radius query
local farResults = grid:QueryRadius(Vector3.new(100, 0, 100), 5.0)
assert(#farResults == 0, "Should find 0 entities far away")

-- Test 3: Update position across cell boundaries
grid:Insert("player_2", Vector3.new(50, 0, 50), 1.0, "scout")
assert(grid.TotalEntities == 2, "TotalEntities should be 2")

local updated = grid:Update("player_1", Vector3.new(100, 0, 100), 2.0, "warrior_promoted")
assert(updated, "Update should return true")

local oldPosResults = grid:QueryRadius(Vector3.new(10, 0, 10), 5.0)
assert(#oldPosResults == 0, "Old position should be empty")

local newPosResults = grid:QueryRadius(Vector3.new(100, 0, 100), 5.0)
assert(#newPosResults == 1, "New position should find player_1")
assert(newPosResults[1].Data == "warrior_promoted", "Data should be updated")

-- Test 4: QueryAABB
local aabbResults = grid:QueryAABB(Vector3.new(90, -10, 90), Vector3.new(110, 10, 110))
assert(#aabbResults == 1, "AABB query should find player_1")
assert(aabbResults[1].Id == "player_1", "AABB query ID should match")

-- Test 5: Remove
local removed = grid:Remove("player_1")
assert(removed, "Remove should return true")
assert(grid.TotalEntities == 1, "TotalEntities should be 1 after remove")

local postRemove = grid:QueryRadius(Vector3.new(100, 0, 100), 10.0)
assert(#postRemove == 0, "Removed entity should not appear in query")

-- Test 6: Clear
grid:Clear()
assert(grid.TotalEntities == 0, "TotalEntities should be 0 after clear")

print("PASS: SpatialHashGrid tests (Insert, QueryRadius, Update, QueryAABB, Remove, Clear) passed cleanly!")
