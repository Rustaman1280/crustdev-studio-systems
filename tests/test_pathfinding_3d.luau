--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3

local PathfindingAStar3D = require("../src/ReplicatedStorage/AI/PathfindingAStar3D")

-- 1. Test initialization
local nav = PathfindingAStar3D.new()
assert(nav ~= nil, "PathfindingAStar3D instance must not be nil")
assert(nav.NodeCount == 0, "Initial node count must be 0")

-- 2. Test Node and Edge operations
local nA = nav:AddNode("A", Vector3.new(0, 0, 0), { label = "start" })
local nB = nav:AddNode("B", Vector3.new(10, 0, 0))
local nC = nav:AddNode("C", Vector3.new(20, 0, 0))

assert(nav.NodeCount == 3, string.format("Expected 3 nodes, got %d", nav.NodeCount))
assert(nA.Position == Vector3.new(0, 0, 0), "Node A position mismatch")

nav:AddEdge("A", "B", true)
nav:AddEdge("B", "C", true)

assert(nA.Neighbors["B"] ~= nil, "A should have neighbor B")
assert(nB.Neighbors["A"] ~= nil, "B should have neighbor A")
assert(nB.Neighbors["C"] ~= nil, "B should have neighbor C")
assert(math.abs(nA.Neighbors["B"] - 10.0) < 0.001, "Edge cost A-B should be 10")

-- 3. Test nearest node lookup
local near = nav:GetNearestNode(Vector3.new(9, 1, 0), 5.0)
assert(near ~= nil and near.Id == "B", "Nearest node to (9,1,0) should be B")

local far = nav:GetNearestNode(Vector3.new(100, 100, 100), 5.0)
assert(far == nil, "Distant search should return nil")

-- 4. Test basic straight line pathfinding
local pathResult = nav:FindPath("A", "C")
assert(pathResult.Success == true, "Pathfinding A -> C should succeed")
assert(pathResult.Partial == false, "Path should not be partial")
assert(#pathResult.NodeIds == 3, string.format("Expected 3 nodes in path, got %d", #pathResult.NodeIds))
assert(pathResult.NodeIds[1] == "A" and pathResult.NodeIds[2] == "B" and pathResult.NodeIds[3] == "C", "Path order invalid")
assert(math.abs(pathResult.Cost - 20.0) < 0.001, "Path cost should be 20")

-- 5. Test obstacle avoidance (Walkable = false)
-- Create diamond: A -> B1 -> C, A -> B2 -> C
local navDiamond = PathfindingAStar3D.new()
navDiamond:AddNode("S", Vector3.new(0, 0, 0))
navDiamond:AddNode("Upper", Vector3.new(10, 0, 10))
navDiamond:AddNode("Lower", Vector3.new(10, 0, -10))
navDiamond:AddNode("E", Vector3.new(20, 0, 0))

navDiamond:AddEdge("S", "Upper", true)
navDiamond:AddEdge("Upper", "E", true)
navDiamond:AddEdge("S", "Lower", true)
navDiamond:AddEdge("Lower", "E", true)

-- Block Upper path
navDiamond:SetNodeWalkable("Upper", false)

local diamondRes = navDiamond:FindPath("S", "E")
assert(diamondRes.Success == true, "Diamond path should find open Lower route")
assert(diamondRes.NodeIds[2] == "Lower", "Path should divert through Lower node")

-- 6. Test dynamic node penalty routing
-- Re-enable Upper, but add high penalty to Lower
navDiamond:SetNodeWalkable("Upper", true)
navDiamond:SetNodePenalty("Lower", 100.0)

local penaltyRes = navDiamond:FindPath("S", "E")
assert(penaltyRes.Success == true, "Penalty path should succeed")
assert(penaltyRes.NodeIds[2] == "Upper", "Path should prefer non-penalized Upper route")

-- 7. Test Vertical climb constraint
local navClimb = PathfindingAStar3D.new()
navClimb:AddNode("Ground", Vector3.new(0, 0, 0))
navClimb:AddNode("CliffTop", Vector3.new(0, 10, 0)) -- height diff 10 > default maxClimb 6
navClimb:AddEdge("Ground", "CliffTop", true)

local climbRes = navClimb:FindPath("Ground", "CliffTop", { MaxClimbHeight = 4.0, AllowPartialPath = false })
assert(climbRes.Success == false, "Climb should fail due to exceeding MaxClimbHeight")

local climbAllowed = navClimb:FindPath("Ground", "CliffTop", { MaxClimbHeight = 15.0 })
assert(climbAllowed.Success == true, "Climb should succeed with increased MaxClimbHeight")

-- 8. Test 3D Grid Generation & Heuristics (Manhattan, Octile, Euclidean)
local navGrid = PathfindingAStar3D.new()
local count = navGrid:GenerateGrid3D(Vector3.new(0, 0, 0), 5, 5, 5, 4.0, false)
assert(count == 125, string.format("Expected 125 grid nodes, got %d", count))
assert(navGrid.NodeCount == 125, "NodeCount should match created nodes")

local startPos = Vector3.new(0, 0, 0)
local endPos = Vector3.new(16, 16, 16) -- opposite corner (4*4, 4*4, 4*4)

local gridResEuclidean = navGrid:FindPath(startPos, endPos, { Heuristic = "Euclidean" })
assert(gridResEuclidean.Success == true, "Grid pathfinding with Euclidean heuristic should succeed")

local gridResOctile = navGrid:FindPath(startPos, endPos, { Heuristic = "Octile" })
assert(gridResOctile.Success == true, "Grid pathfinding with Octile heuristic should succeed")

local gridResManhattan = navGrid:FindPath(startPos, endPos, { Heuristic = "Manhattan" })
assert(gridResManhattan.Success == true, "Grid pathfinding with Manhattan heuristic should succeed")

-- 9. Test MaxExpansions budget limit with partial path
local limitedRes = navGrid:FindPath(startPos, endPos, { MaxExpansions = 5, AllowPartialPath = true })
assert(limitedRes.Success == false, "Budget exhausted path should report Success = false")
assert(limitedRes.Partial == true, "Budget exhausted path should return Partial = true")
assert(#limitedRes.Waypoints > 1, "Partial path should return partial waypoints")

-- 10. Test Path Smoothing (String Pulling)
local rawWaypoints: { Vector3 } = {
  Vector3.new(0, 0, 0),
  Vector3.new(4, 0, 0),
  Vector3.new(8, 0, 0),
  Vector3.new(12, 0, 0),
  Vector3.new(16, 0, 0),
}

-- Simple LOS checker where everything is visible
local function clearLOS(fromPos: Vector3, toPos: Vector3): boolean
  return true
end

local smoothed = navGrid:SmoothPath(rawWaypoints, clearLOS)
assert(#smoothed == 2, string.format("Smoothed path with open LOS should collapse to 2 waypoints, got %d", #smoothed))
assert(smoothed[1] == rawWaypoints[1], "Start waypoint should match")
assert(smoothed[2] == rawWaypoints[#rawWaypoints], "End waypoint should match")

-- Block LOS in the middle: positions with X > 8 cannot see X < 4
local function blockedLOS(fromPos: Vector3, toPos: Vector3): boolean
  if (fromPos.X <= 4 and toPos.X >= 12) or (fromPos.X >= 12 and toPos.X <= 4) then
    return false
  end
  return true
end

local partiallySmoothed = navGrid:SmoothPath(rawWaypoints, blockedLOS)
assert(#partiallySmoothed >= 3, string.format("Partially blocked LOS should retain detour waypoint, got %d", #partiallySmoothed))

print("PASS: PathfindingAStar3D tests (Graph, Nearest, Direct, Obstacles, Penalty, Climbs, 3D Grid, Budget, Smoothing) passed cleanly!")
