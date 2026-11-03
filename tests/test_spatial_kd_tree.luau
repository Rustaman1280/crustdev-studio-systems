local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

local SpatialKDTree = require("../src/ReplicatedStorage/Spatial/SpatialKDTree")

local Vector3 = _G.Vector3 or Vector3

-- Test 1: Empty tree invariants
local emptyTree = SpatialKDTree.new()
assert(emptyTree:IsEmpty() == true, "Empty tree should report IsEmpty == true")
assert(emptyTree:GetCount() == 0, "Empty tree count should be 0")
assert(emptyTree:GetDepth() == 0, "Empty tree depth should be 0")
local pos, data, dist = emptyTree:FindNearest(Vector3.new(0, 0, 0))
assert(pos == nil and data == nil and dist == nil, "Empty tree FindNearest should return nil")
assert(#emptyTree:FindKNearest(Vector3.new(0, 0, 0), 5) == 0, "Empty tree FindKNearest should return empty table")
assert(#emptyTree:FindInRadius(Vector3.new(0, 0, 0), 10) == 0, "Empty tree FindInRadius should return empty table")
assert(#emptyTree:FindInBox(Vector3.new(-5, -5, -5), Vector3.new(5, 5, 5)) == 0, "Empty tree FindInBox should return empty table")

-- Test 2: Balanced Construction from Point Cloud
local samplePoints = {
  { Position = Vector3.new(2, 3, 5), Data = "Node_A", Id = "a" },
  { Position = Vector3.new(5, 4, 1), Data = "Node_B", Id = "b" },
  { Position = Vector3.new(9, 6, 2), Data = "Node_C", Id = "c" },
  { Position = Vector3.new(4, 7, 9), Data = "Node_D", Id = "d" },
  { Position = Vector3.new(8, 1, 3), Data = "Node_E", Id = "e" },
  { Position = Vector3.new(7, 2, 6), Data = "Node_F", Id = "f" },
  { Position = Vector3.new(1, 8, 4), Data = "Node_G", Id = "g" },
}

local tree = SpatialKDTree.build(samplePoints)
assert(tree:IsEmpty() == false, "Tree should not be empty")
assert(tree:GetCount() == 7, "Tree count should be 7")
assert(tree:GetDepth() <= 4, "Balanced tree with 7 nodes must have depth <= 4")

-- Test 3: Nearest Neighbor Query (Exact match & Arbitrary Query)
local exactPos, exactData, exactDist = tree:FindNearest(Vector3.new(2, 3, 5))
assert(exactData == "Node_A", "Exact coordinate query must return Node_A")
assert(math.abs(exactDist :: number) < 1e-5, "Exact match distance should be 0")

-- Query point close to Node_E (8, 1, 3)
local qPos, qData, qDist = tree:FindNearest(Vector3.new(8.1, 1.2, 2.9))
assert(qData == "Node_E", "Query near (8, 1, 3) must resolve to Node_E")
local distVal: number = (qDist :: any)
assert(distVal < 0.5, "Distance to near neighbor should be < 0.5")

-- Max radius limit
local farPos, farData, farDist = tree:FindNearest(Vector3.new(100, 100, 100), 5)
assert(farPos == nil and farData == nil and farDist == nil, "FindNearest with tight maxRadius should return nil if out of bounds")

-- Test 4: K-Nearest Neighbors (k-NN)
local knn = tree:FindKNearest(Vector3.new(7, 2, 6), 3)
assert(#knn == 3, "k-NN with k=3 should return exactly 3 results")
assert(knn[1].Data == "Node_F", "First closest neighbor must be Node_F (distance 0)")
assert(knn[1].Distance <= knn[2].Distance, "Results must be ordered by distance ascending")
assert(knn[2].Distance <= knn[3].Distance, "Results must be ordered by distance ascending")

-- Test 5: Spherical Radius Query
local inRadius = tree:FindInRadius(Vector3.new(7, 2, 5), 3.0)
assert(#inRadius >= 2, "Radius 3.0 around (7, 2, 5) should catch at least Node_F and Node_E")
for _, res in ipairs(inRadius) do
  assert(res.Distance <= 3.0, "Every item must have distance <= radius")
end

-- Test 6: AABB Box Range Query
local inBox = tree:FindInBox(Vector3.new(1, 1, 1), Vector3.new(6, 5, 6))
-- Check that all returned nodes have coords inside the bounds
assert(#inBox > 0, "AABB query must capture points inside [1,1,1] to [6,5,6]")
for _, res in ipairs(inBox) do
  assert(res.Position.X >= 1 and res.Position.X <= 6, "X coordinate inside box")
  assert(res.Position.Y >= 1 and res.Position.Y <= 5, "Y coordinate inside box")
  assert(res.Position.Z >= 1 and res.Position.Z <= 6, "Z coordinate inside box")
end

-- Test 7: Incremental Dynamic Insertion
local dynTree = SpatialKDTree.new()
local id1 = dynTree:Insert(Vector3.new(10, 20, 30), "Custom_Payload_1", "ent_1")
local id2 = dynTree:Insert(Vector3.new(15, 25, 35), "Custom_Payload_2", "ent_2")
local id3 = dynTree:Insert(Vector3.new(-10, -20, -30), "Custom_Payload_3", "ent_3")

assert(dynTree:GetCount() == 3, "Dynamic tree should have 3 nodes")
assert(id1 == "ent_1" and id2 == "ent_2" and id3 == "ent_3", "IDs should match passed ids")

local nearDyn, dynData = dynTree:FindNearest(Vector3.new(-9.9, -20.1, -29.8))
assert(dynData == "Custom_Payload_3", "Dynamic insert query should find negative quadrant node")

-- Test 8: Dynamic Deletion
local removed = dynTree:Remove("ent_2")
assert(removed == true, "Removing existing node should return true")
assert(dynTree:GetCount() == 2, "Count should decrement to 2")

local _, checkData = dynTree:FindNearest(Vector3.new(15, 25, 35))
assert(checkData ~= "Custom_Payload_2", "Deleted node ent_2 should no longer be returned as nearest")

local failRemove = dynTree:Remove("non_existent_id")
assert(failRemove == false, "Removing non-existent ID should return false")

-- Test 9: Clear & Re-use
dynTree:Clear()
assert(dynTree:IsEmpty() == true, "After Clear, tree should be empty")
assert(dynTree:GetCount() == 0, "Count should be 0 after Clear")
dynTree:Insert(Vector3.new(1, 2, 3), "Reborn")
assert(dynTree:GetCount() == 1, "Can insert after Clear")

print("PASS: SpatialKDTree tests (Empty, BalancedBuild, Nearest, k-NN, Radius, AABB, DynamicInsert, DynamicRemove, Clear) passed cleanly!")
