local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local FastVoxelRaycast = require("../src/ReplicatedStorage/Spatial/FastVoxelRaycast")

-- Test 1: Coordinate mapping and roundtrip integrity
local p1 = Vector3.new(2.5, 4.1, -1.8)
local v1 = FastVoxelRaycast.WorldToVoxel(p1, 1)
assert(v1.X == 2 and v1.Y == 4 and v1.Z == -2, "WorldToVoxel integer floor failed for cellSize=1")

local worldLower = FastVoxelRaycast.VoxelToWorld(v1, 1)
assert(worldLower.X == 2 and worldLower.Y == 4 and worldLower.Z == -2, "VoxelToWorld lower bound failed")

local worldCenter = FastVoxelRaycast.VoxelToWorldCenter(v1, 1)
assert(math.abs(worldCenter.X - 2.5) < 1e-5 and math.abs(worldCenter.Y - 4.5) < 1e-5 and math.abs(worldCenter.Z - -1.5) < 1e-5, "VoxelToWorldCenter failed")

-- Test 2: Custom cell size and offset
local offset = Vector3.new(10, 20, 30)
local p2 = Vector3.new(14.5, 23.9, 38.1)
local v2 = FastVoxelRaycast.WorldToVoxel(p2, 4, offset)
assert(v2.X == 1 and v2.Y == 0 and v2.Z == 2, "WorldToVoxel with cellSize=4 and offset failed")

-- Test 3: Straight axis raycast hitting target
local grid: { [string]: boolean } = {}
local function key(x: number, y: number, z: number): string
  return string.format("%d,%d,%d", x, y, z)
end

grid[key(5, 0, 0)] = true -- Solid voxel at (5, 0, 0)

local isSolid = function(v: Vector3): boolean
  return grid[key(v.X, v.Y, v.Z)] == true
end

local rayOrigin = Vector3.new(0.5, 0.5, 0.5)
local rayDir = Vector3.new(1, 0, 0)
local hit = FastVoxelRaycast.Raycast(rayOrigin, rayDir, 20, isSolid, 1)

assert(hit ~= nil, "Ray should hit solid voxel at (5, 0, 0)")
assert(hit.voxel.X == 5 and hit.voxel.Y == 0 and hit.voxel.Z == 0, "Hit voxel coordinates mismatch")
assert(hit.normal.X == -1 and hit.normal.Y == 0 and hit.normal.Z == 0, "Hit normal must be (-1, 0, 0)")
assert(math.abs(hit.distance - 4.5) < 1e-4, "Distance to X boundary at 5 from 0.5 must be 4.5")
assert(hit.stepsTaken == 5, "Should have stepped through exactly 5 boundary transitions")

-- Test 4: Downward ray hitting floor
grid[key(0, -3, 0)] = true
local downHit = FastVoxelRaycast.Raycast(Vector3.new(0.5, 2.5, 0.5), Vector3.new(0, -1, 0), 10, isSolid, 1)
assert(downHit ~= nil, "Ray downwards should hit floor at Y=-3")
assert(downHit.voxel.Y == -3, "Floor voxel Y mismatch")
assert(downHit.normal.Y == 1, "Floor entry normal must be upward (0, 1, 0)")
assert(math.abs(downHit.distance - 4.5) < 1e-4, "Distance from 2.5 to -3 upper boundary mismatch")

-- Test 5: Immediate start inside solid voxel
local insideHit = FastVoxelRaycast.Raycast(Vector3.new(5.2, 0.2, 0.2), Vector3.new(1, 0, 0), 10, isSolid, 1)
assert(insideHit ~= nil, "Starting inside solid voxel must register hit immediately")
assert(insideHit.distance == 0, "Distance must be 0 for starting cell hit")
assert(insideHit.stepsTaken == 0, "Steps taken must be 0 for starting cell hit")

-- Test 6: Miss due to max distance
local missHit = FastVoxelRaycast.Raycast(Vector3.new(0.5, 0.5, 0.5), Vector3.new(1, 0, 0), 3.0, isSolid, 1)
assert(missHit == nil, "Raycast should return nil when target exceeds maxDistance")

-- Test 7: Oblique 3D raycast hitting diagonal target
grid[key(3, 3, 3)] = true
local diagOrigin = Vector3.new(0.1, 0.1, 0.1)
local diagDir = Vector3.new(1, 1, 1)
local diagHit = FastVoxelRaycast.Raycast(diagOrigin, diagDir, 10, isSolid, 1)
assert(diagHit ~= nil, "Oblique ray must hit diagonal target at (3, 3, 3)")
assert(diagHit.voxel.X == 3 and diagHit.voxel.Y == 3 and diagHit.voxel.Z == 3, "Diagonal hit voxel mismatch")

-- Test 8: Traversal visitor callback
local visited: { Vector3 } = {}
local totalSteps = FastVoxelRaycast.Traverse(
  Vector3.new(0.5, 0.5, 0.5),
  Vector3.new(1, 0, 0),
  4.0,
  function(v: Vector3, normal: Vector3, dist: number): boolean
    table.insert(visited, v)
    if v.X == 3 then
      return true -- Early stop at X=3
    end
    return false
  end,
  1
)

assert(#visited == 4, "Visitor should have visited 4 voxels (X=0, 1, 2, 3)")
assert(visited[1].X == 0 and visited[4].X == 3, "Visitor order must follow ray sequence")

print("PASS: FastVoxelRaycast tests (WorldToVoxel, VoxelToWorld, AxisRaycast, DownwardFloor, InsideSolid, MaxDistMiss, Oblique3D, VisitorTraverse) passed cleanly!")
