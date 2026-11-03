local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame
Vector3 = roblox.Vector3
CFrame = roblox.CFrame

local GreedyVoxelMesher = require("../src/ReplicatedStorage/Procedural/GreedyVoxelMesher")

-- Test 1: Empty volume
local emptyRes = GreedyVoxelMesher.MeshFromTable({}, {})
assert(#emptyRes.Quads == 0, "Empty table must yield 0 quads")
assert(emptyRes.Stats.TotalVoxels == 0, "TotalVoxels should be 0")
assert(emptyRes.Stats.MergedQuads == 0, "MergedQuads should be 0")

-- Test 2: Single 1x1x1 isolated voxel
local singleGrid = {
  { { 1 } }
}
local singleRes = GreedyVoxelMesher.MeshFromTable(singleGrid, { CellSize = 1 })
assert(singleRes.Stats.TotalVoxels == 1, "Should count 1 solid voxel")
assert(singleRes.Stats.RawFaces == 6, "Isolated voxel has exactly 6 exposed faces")
assert(#singleRes.Quads == 6, "Isolated voxel must produce exactly 6 quads")

local facesFound = {}
for _, quad in ipairs(singleRes.Quads) do
  facesFound[quad.Face] = true
  assert(quad.Material == 1, "Material must be 1")
end
assert(facesFound["+X"] and facesFound["-X"], "Must have +X and -X faces")
assert(facesFound["+Y"] and facesFound["-Y"], "Must have +Y and -Y faces")
assert(facesFound["+Z"] and facesFound["-Z"], "Must have +Z and -Z faces")

-- Test 3: Uniform 4x4x4 solid cube (Greedy reduction benchmark)
-- Total voxels = 64. Raw exterior faces = 6 sides * 16 = 96 faces.
-- Greedy mesher should merge each side into 1 giant quad, yielding exactly 6 quads!
local cubeSize = 4
local cubeSampler = function(x: number, y: number, z: number): number
  if x >= 1 and x <= cubeSize and y >= 1 and y <= cubeSize and z >= 1 and z <= cubeSize then
    return 1
  end
  return 0
end

local cubeRes = GreedyVoxelMesher.MeshFromSampler(cubeSize, cubeSize, cubeSize, cubeSampler, { CellSize = 1 })
assert(cubeRes.Stats.TotalVoxels == 64, "Total solid voxels must be 64")
assert(cubeRes.Stats.RawFaces == 96, "Raw exposed faces must be 96 (4*4*6)")
assert(#cubeRes.Quads == 6, string.format("4x4x4 cube must merge into exactly 6 quads, got %d", #cubeRes.Quads))

-- Verify reduction percentage is ~93.75%
local reductionPercent = math.floor(cubeRes.Stats.ReductionRatio * 100 + 0.5)
assert(reductionPercent == 94 or reductionPercent == 93, string.format("Reduction ratio should be ~94%%, got %d%%", reductionPercent))

-- Verify quad dimensions: each quad must span 4x4 in world size along its tangential axes
for _, quad in ipairs(cubeRes.Quads) do
  if quad.Face == "+Y" or quad.Face == "-Y" then
    assert(math.abs(quad.Size.X - 4) < 1e-3 and math.abs(quad.Size.Z - 4) < 1e-3, "Top/Bottom quads must be 4x4")
  elseif quad.Face == "+X" or quad.Face == "-X" then
    assert(math.abs(quad.Size.Y - 4) < 1e-3 and math.abs(quad.Size.Z - 4) < 1e-3, "Left/Right quads must be 4x4")
  elseif quad.Face == "+Z" or quad.Face == "-Z" then
    assert(math.abs(quad.Size.X - 4) < 1e-3 and math.abs(quad.Size.Y - 4) < 1e-3, "Front/Back quads must be 4x4")
  end
end

-- Test 4: Multi-material boundary separation
-- 4x4 flat plane (Y=1): left half is "Stone", right half is "Grass"
local multiSampler = function(x: number, y: number, z: number): string
  if y == 1 and x >= 1 and x <= 4 and z >= 1 and z <= 4 then
    if x <= 2 then
      return "Stone"
    else
      return "Grass"
    end
  end
  return "Air"
end

local multiRes = GreedyVoxelMesher.MeshFromSampler(4, 1, 4, multiSampler, {
  CellSize = 1,
  AirValue = "Air",
})

-- Top face (+Y) must have 2 distinct quads: one 2x4 Stone and one 2x4 Grass
local topQuads = {}
for _, quad in ipairs(multiRes.Quads) do
  if quad.Face == "+Y" then
    table.insert(topQuads, quad)
  end
end
assert(#topQuads == 2, string.format("Top face of multi-material plane must have 2 quads, got %d", #topQuads))
local mats = {}
for _, q in ipairs(topQuads) do
  mats[q.Material] = q.Size
end
assert(mats["Stone"] and mats["Grass"], "Must separate Stone and Grass")
assert(math.abs(mats["Stone"].X - 2) < 1e-3 and math.abs(mats["Stone"].Z - 4) < 1e-3, "Stone quad must be 2x4")
assert(math.abs(mats["Grass"].X - 2) < 1e-3 and math.abs(mats["Grass"].Z - 4) < 1e-3, "Grass quad must be 2x4")

-- Test 5: World scaling and origin offset
local scaledRes = GreedyVoxelMesher.MeshFromSampler(1, 1, 1, function() return 1 end, {
  CellSize = 10,
  OriginOffset = Vector3.new(100, 200, 300),
})
assert(#scaledRes.Quads == 6, "Scaled single voxel has 6 quads")
for _, quad in ipairs(scaledRes.Quads) do
  assert(quad.Position.X >= 100, "X position scaled with origin")
  assert(quad.Position.Y >= 200, "Y position scaled with origin")
  assert(quad.Position.Z >= 300, "Z position scaled with origin")
end

-- Test 6: Solid Volume Consolidation (3D Box Consolidation)
local solidSampler = function(x: number, y: number, z: number): number
  if x >= 1 and x <= 3 and y >= 1 and y <= 3 and z >= 1 and z <= 3 then
    return 1 -- 3x3x3 solid block
  end
  return 0
end

local boxes = GreedyVoxelMesher.ConsolidateSolidVolume(3, 3, 3, solidSampler, { CellSize = 2 })
assert(#boxes == 1, string.format("3x3x3 solid cube must consolidate into exactly 1 solid box, got %d", #boxes))
assert(boxes[1].Size == Vector3.new(6, 6, 6), "Consolidated box size must be 6x6x6")

print("PASS: GreedyVoxelMesher tests (Empty, SingleVoxel, 4x4x4Cube, MultiMaterial, WorldScaling, SolidConsolidation) passed cleanly!")
