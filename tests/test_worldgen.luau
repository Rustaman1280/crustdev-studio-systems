local SynthetixWorldGen = require("../src/ReplicatedStorage/SynthetixWorldGen")

-- Test 1: Instantiation with default and custom configs
local gen1 = SynthetixWorldGen.new()
assert(gen1.Config.Seed == 482917, "Default seed should match")

local genCustom = SynthetixWorldGen.new({
  Seed = 999111,
  Octaves = 6,
  Persistence = 0.45,
  Lacunarity = 2.1,
  WorldScale = 150.0,
  HeightScale = 60.0,
})
assert(genCustom.Config.Seed == 999111, "Custom seed should match")

-- Test 2: Deterministic Elevation Sampling
local h1 = gen1:SampleElevation(24.5, -81.2)
local h2 = gen1:SampleElevation(24.5, -81.2)
assert(h1 == h2, "Sampling same coordinates must yield identical elevation")
assert(type(h1) == "number", "Elevation must be a number")
assert(h1 >= 0 and h1 <= gen1.Config.HeightScale, "Elevation should fall within [0, HeightScale]")

-- Test 3: Variation across different seeds
local hCustom = genCustom:SampleElevation(24.5, -81.2)
assert(h1 ~= hCustom, "Different seeds should yield different elevations")

-- Test 4: Chunk Generation Grid Resolution
local chunk = gen1:GenerateChunk(0, 0, 16)
assert(chunk.Resolution == 16, "Resolution must be 16")
assert(#chunk.Elevations == 256, "16x16 chunk should have 256 elevation points")
assert(chunk.MinElevation <= chunk.MaxElevation, "MinElevation must be <= MaxElevation")
assert(chunk.ChunkX == 0 and chunk.ChunkZ == 0, "Chunk coordinates should match")

-- Test 5: Resolution clamping (min 8, max 128)
local chunkClampedMin = gen1:GenerateChunk(1, -1, 4)
assert(chunkClampedMin.Resolution == 8, "Resolution should clamp up to 8")
assert(#chunkClampedMin.Elevations == 64, "8x8 chunk should have 64 points")

print("PASS: SynthetixWorldGen tests (Deterministic sampling, Seed variation, Chunk generation, Bounds) passed cleanly!")
