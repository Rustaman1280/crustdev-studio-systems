local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local VoxelFloodFill = require("../src/ReplicatedStorage/Spatial/VoxelFloodFill")

local function key(v: Vector3): string
  return v.X .. "," .. v.Y .. "," .. v.Z
end

-- Test 1: Neighbor offsets
local offsets6 = VoxelFloodFill.GetNeighborOffsets("face6")
assert(#offsets6 == 6, "face6 should provide 6 orthogonal offsets")

local offsets26 = VoxelFloodFill.GetNeighborOffsets("all26")
assert(#offsets26 == 26, "all26 should provide 26 omnidirectional offsets")

-- Test 2: Solid cube flood fill (3x3x3 = 27 voxels)
local solidCube: { [string]: boolean } = {}
for x = 0, 2 do
  for y = 0, 2 do
    for z = 0, 2 do
      solidCube[key(Vector3.new(x, y, z))] = true
    end
  end
end

local isCubeSolid = function(v: Vector3): boolean
  return solidCube[key(v)] == true
end

local fillRes = VoxelFloodFill.FloodFill({
  start = Vector3.new(1, 1, 1),
  predicate = isCubeSolid,
  connectivity = "face6",
  maxSteps = 1000,
})

assert(fillRes.count == 27, "3x3x3 cube fill should discover exactly 27 voxels")
assert(fillRes.reachedLimit == false, "Fill should not have hit step limit")

-- Test 3: Wall barrier blocking flood fill
local wallWorld: { [string]: boolean } = {}
-- 5x5 open room split by a wall at X = 2
for x = 0, 4 do
  for y = 0, 4 do
    for z = 0, 0 do
      if x == 2 then
        -- Solid wall (impassable)
      else
        wallWorld[key(Vector3.new(x, y, z))] = true -- Passable air
      end
    end
  end
end

local isPassable = function(v: Vector3): boolean
  return wallWorld[key(v)] == true
end

local leftFill = VoxelFloodFill.FloodFill({
  start = Vector3.new(0, 0, 0),
  predicate = isPassable,
  connectivity = "face6",
  maxSteps = 1000,
})

-- Left side has X = 0 and X = 1 for Y = 0..4 (2 * 5 = 10 voxels)
assert(leftFill.count == 10, "Left side room should contain exactly 10 accessible voxels")
for _, v in ipairs(leftFill.voxels) do
  assert(v.X < 2, "Flood fill should not cross solid wall at X = 2")
end

-- Test 4: MaxSteps safety limit
local stepLimited = VoxelFloodFill.FloodFill({
  start = Vector3.new(1, 1, 1),
  predicate = isCubeSolid,
  connectivity = "face6",
  maxSteps = 5,
})

assert(stepLimited.count == 5, "Fill should stop after exactly 5 steps")
assert(stepLimited.reachedLimit == true, "reachedLimit flag should be true")

-- Test 5: Connected components clustering
local seeds = {
  -- Island 1
  Vector3.new(0, 0, 0),
  Vector3.new(1, 0, 0),
  Vector3.new(2, 0, 0),
  -- Island 2 (distant)
  Vector3.new(20, 20, 20),
  Vector3.new(21, 20, 20),
}

local islandLookup: { [string]: boolean } = {}
for _, s in ipairs(seeds) do
  islandLookup[key(s)] = true
end

local isIsland = function(v: Vector3): boolean
  return islandLookup[key(v)] == true
end

local components = VoxelFloodFill.FindConnectedComponents(seeds, isIsland, "face6")
assert(#components == 2, "Should identify exactly 2 disconnected components")

local counts = { #components[1], #components[2] }
table.sort(counts)
assert(counts[1] == 2 and counts[2] == 3, "Components should have sizes 2 and 3")

-- Test 6: Detect enclosed cavities (Hollow underground room)
-- Create a 5x5x5 outer solid box [0, 4] with hollow air inside [1, 3] (3x3x3 = 27 air cells)
local outerShell: { [string]: boolean } = {}
for x = 0, 4 do
  for y = 0, 4 do
    for z = 0, 4 do
      local isShell = (x == 0 or x == 4 or y == 0 or y == 4 or z == 0 or z == 4)
      if isShell then
        outerShell[key(Vector3.new(x, y, z))] = true
      end
    end
  end
end

local isShellSolid = function(v: Vector3): boolean
  return outerShell[key(v)] == true
end

local cavities = VoxelFloodFill.DetectEnclosedCavities(
  Vector3.new(-1, -1, -1),
  Vector3.new(5, 5, 5),
  isShellSolid,
  "face6"
)

assert(#cavities == 1, "Should discover exactly 1 sealed interior cavity")
assert(#cavities[1] == 27, "Interior cavity should have exactly 27 hollow air voxels (3x3x3)")

-- Test 7: Spatial metrics (Volume, Center of Mass, Bounds)
local vol = VoxelFloodFill.CalculateVolume(cavities[1], 2)
assert(vol == 27 * 8, "Volume of 27 voxels with size 2 should equal 216")

local com = VoxelFloodFill.CalculateCenterOfMass(cavities[1])
assert(math.abs(com.X - 2) < 1e-4 and math.abs(com.Y - 2) < 1e-4 and math.abs(com.Z - 2) < 1e-4, "Cavity center of mass should be (2, 2, 2)")

local bMin, bMax = VoxelFloodFill.ComputeBoundingBox(cavities[1])
assert(bMin.X == 1 and bMin.Y == 1 and bMin.Z == 1, "Bounding box min should be (1, 1, 1)")
assert(bMax.X == 3 and bMax.Y == 3 and bMax.Z == 3, "Bounding box max should be (3, 3, 3)")

print("PASS: VoxelFloodFill tests (Offsets, SolidCube, Barrier, MaxSteps, Components, EnclosedCavities, Metrics) passed cleanly!")
