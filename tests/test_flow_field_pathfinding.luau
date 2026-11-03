local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

local FlowFieldPathfinding = require("../src/ReplicatedStorage/AI/FlowFieldPathfinding")

-- Test 1: Initialization, Dimensions, and Coordinate Mapping
local ff = FlowFieldPathfinding.new({
  origin = Vector3.new(0, 0, 0),
  cellSize = 4,
  width = 10,
  height = 10,
  defaultCost = 1,
})

local w, h = ff:GetDimensions()
assert(w == 10 and h == 10, "Dimensions should be 10x10")
assert(ff:GetCellSize() == 4, "Cell size should be 4 studs")
assert(ff:IsValidCell(1, 1) == true, "Cell (1, 1) must be valid")
assert(ff:IsValidCell(10, 10) == true, "Cell (10, 10) must be valid")
assert(ff:IsValidCell(0, 1) == false, "Cell (0, 1) must be invalid")
assert(ff:IsValidCell(11, 5) == false, "Cell (11, 5) must be invalid")

-- Coordinate conversions
local gx, gz = ff:WorldToGrid(Vector3.new(2, 0, 2))
assert(gx == 1 and gz == 1, "World (2, 0, 2) should map to grid cell (1, 1)")

local gx2, gz2 = ff:WorldToGrid(Vector3.new(18, 0, 22))
assert(gx2 == 5 and gz2 == 6, "World (18, 0, 22) should map to grid cell (5, 6)")

local worldCenter = ff:GridToWorld(1, 1)
assert(math.abs(worldCenter.X - 2) < 0.001 and math.abs(worldCenter.Z - 2) < 0.001, "Cell (1, 1) center should be (2, 0, 2)")

-- Test 2: Walkability & Obstacle Management
assert(ff:IsWalkable(5, 5) == true, "Default cell must be walkable")
ff:SetObstacle(5, 5, true)
assert(ff:IsWalkable(5, 5) == false, "Obstacle cell must not be walkable")
assert(ff:GetCost(5, 5) == 255, "Obstacle cell cost must be 255")

ff:SetObstacle(5, 5, false)
assert(ff:IsWalkable(5, 5) == true, "Cleared cell must be walkable")
assert(ff:GetCost(5, 5) == 1, "Default cost must be restored to 1")

-- Rectangular obstacle box
ff:SetRectObstacle(3, 3, 5, 5, true)
for rz = 3, 5 do
  for rx = 3, 5 do
    assert(ff:IsWalkable(rx, rz) == false, string.format("Cell (%d, %d) in rect obstacle must be non-walkable", rx, rz))
  end
end
ff:SetRectObstacle(3, 3, 5, 5, false)
for rz = 3, 5 do
  for rx = 3, 5 do
    assert(ff:IsWalkable(rx, rz) == true, string.format("Cell (%d, %d) must be restored to walkable", rx, rz))
  end
end

-- Test 3: Wavefront Integration & Vector Field with Single Destination
ff:Reset()
-- Set destination at center (5, 5)
ff:SetDestination(5, 5)
local updated = ff:UpdateField()
assert(updated == true, "UpdateField should succeed with destination")

-- Distance at destination must be 0
assert(ff:GetIntegrationDistance(5, 5) == 0, "Destination cell integration distance must be 0")
assert(ff:GetFlowVector(5, 5).Magnitude < 0.001, "Destination cell flow vector should be zero magnitude")

-- Cardinal neighbors should have distance 1.0
assert(math.abs(ff:GetIntegrationDistance(5, 6) - 1.0) < 0.01, "North neighbor integration distance should be 1.0")
assert(math.abs(ff:GetIntegrationDistance(6, 5) - 1.0) < 0.01, "East neighbor integration distance should be 1.0")
assert(math.abs(ff:GetIntegrationDistance(5, 4) - 1.0) < 0.01, "South neighbor integration distance should be 1.0")
assert(math.abs(ff:GetIntegrationDistance(4, 5) - 1.0) < 0.01, "West neighbor integration distance should be 1.0")

-- Diagonal neighbor should have distance ~1.414
local diagDist = ff:GetIntegrationDistance(6, 6)
assert(math.abs(diagDist - 1.414) < 0.02, "Diagonal neighbor integration distance should be approx 1.414")

-- Vectors should point towards destination (5, 5)
-- From (5, 8) South to (5, 5): vector should point South (negative Z)
local southFlow = ff:GetFlowVector(5, 8)
assert(southFlow.Z < -0.9, "From (5, 8) flow vector must point South towards (5, 5)")

-- From (2, 5) East to (5, 5): vector should point East (positive X)
local eastFlow = ff:GetFlowVector(2, 5)
assert(eastFlow.X > 0.9, "From (2, 5) flow vector must point East towards (5, 5)")

-- Test 4: Corner-Cutting Obstacle Avoidance
ff:Reset()
ff:SetDestination(1, 1)
-- Build a corner wall barrier around (1, 1):
-- Cell (2, 1) and (1, 2) obstacles
ff:SetObstacle(2, 1, true)
ff:SetObstacle(1, 2, true)
ff:UpdateField()

-- Diagonal neighbor (2, 2) cannot cut corners diagonally into (1, 1) because both adjacent cardinal cells are solid!
-- So distance at (2, 2) must route around or be greater than 1.414
local cornerDist = ff:GetIntegrationDistance(2, 2)
assert(cornerDist > 1.42, "Corner-cutting protection should prevent diagonal traversal through corner barriers")

-- Test 5: Multi-Destination Integration Field
ff:Reset()
-- Two exits: (1, 1) at bottom-left and (10, 10) at top-right
ff:SetDestinations({
  { x = 1, z = 1 },
  { x = 10, z = 10 },
})
ff:UpdateField()

assert(ff:GetIntegrationDistance(1, 1) == 0, "Target (1, 1) distance should be 0")
assert(ff:GetIntegrationDistance(10, 10) == 0, "Target (10, 10) distance should be 0")

-- Agent at (2, 2) should flow towards (1, 1)
local vecNearExit1 = ff:GetFlowVector(2, 2)
assert(vecNearExit1.X < 0 and vecNearExit1.Z < 0, "Vector at (2, 2) should flow towards (1, 1)")

-- Agent at (9, 9) should flow towards (10, 10)
local vecNearExit2 = ff:GetFlowVector(9, 9)
assert(vecNearExit2.X > 0 and vecNearExit2.Z > 0, "Vector at (9, 9) should flow towards (10, 10)")

-- Test 6: Continuous Bilinear Sampling
ff:Reset()
ff:SetDestination(5, 5)
ff:UpdateField()

-- Sample world position in studs near cell (2, 5) -> World position (6, 0, 18)
local sampledDir = ff:SampleDirection(Vector3.new(6, 0, 18))
assert(math.abs(sampledDir.Magnitude - 1.0) < 0.05, "SampleDirection must return a normalized unit vector")
assert(sampledDir.X > 0.5, "Sampled vector should point towards destination X")

-- Test SampleVelocity
local velocity = ff:SampleVelocity(Vector3.new(6, 0, 18), 16)
assert(math.abs(velocity.Magnitude - 16.0) < 0.1, "SampleVelocity magnitude should match desired speed")

-- Test 7: ASCII Map Output
local ascii = ff:RenderASCII()
assert(type(ascii) == "string", "RenderASCII must return a string")
assert(string.find(ascii, "%*") ~= nil, "RenderASCII output must contain the destination marker *")
assert(string.find(ascii, "FlowField") ~= nil, "RenderASCII header must mention FlowField")

print("PASS: FlowFieldPathfinding tests (Init, Coordinates, Obstacles, Wavefront, AntiCornerCut, MultiDest, Bilinear, ASCII) passed cleanly!")
