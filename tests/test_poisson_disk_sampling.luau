local PoissonDiskSampling = require("../src/ReplicatedStorage/Procedural/PoissonDiskSampling")

-- Test 1: 2D Sampling within bounds
local points2D = PoissonDiskSampling.Sample2D({
  MinX = 0,
  MaxX = 100,
  MinY = 0,
  MaxY = 100,
  MinDistance = 10,
  MaxCandidates = 30,
  Seed = 42,
})

assert(#points2D > 0, "Points array should not be empty")
for _, p in ipairs(points2D) do
  assert(p.X >= 0 and p.X < 100, "Point X out of bounds")
  assert(p.Y >= 0 and p.Y < 100, "Point Y out of bounds")
end

-- Test 2: Separation validation
local valid2D, minFound2D = PoissonDiskSampling.ValidateSeparation2D(points2D, 10, 0.999)
assert(valid2D, string.format("Separation violation detected in 2D: min distance %f", minFound2D))

-- Test 3: Determinism with identical seeds
local points2D_B = PoissonDiskSampling.Sample2D({
  MinX = 0,
  MaxX = 100,
  MinY = 0,
  MaxY = 100,
  MinDistance = 10,
  MaxCandidates = 30,
  Seed = 42,
})

assert(#points2D == #points2D_B, "Deterministic point counts must match")
for i = 1, #points2D do
  assert(math.abs(points2D[i].X - points2D_B[i].X) < 1e-6, "Point coordinate X must match")
  assert(math.abs(points2D[i].Y - points2D_B[i].Y) < 1e-6, "Point coordinate Y must match")
end

-- Test 4: Exclusion zones in 2D
local exclusion = {
  Center = { X = 50, Y = 50 },
  Radius = 25,
}
local pointsExclusion = PoissonDiskSampling.Sample2D({
  MinX = 0,
  MaxX = 100,
  MinY = 0,
  MaxY = 100,
  MinDistance = 8,
  Seed = 101,
}, { exclusion })

assert(#pointsExclusion > 0, "Should generate points outside exclusion zone")
for _, p in ipairs(pointsExclusion) do
  local dx = p.X - 50
  local dy = p.Y - 50
  local dist = math.sqrt(dx * dx + dy * dy)
  assert(dist >= 25, string.format("Point (%f, %f) penetrated exclusion zone radius 25", p.X, p.Y))
end

-- Test 5: 3D Sampling within bounding volume
local points3D = PoissonDiskSampling.Sample3D({
  MinX = 0,
  MaxX = 50,
  MinY = 0,
  MaxY = 50,
  MinZ = 0,
  MaxZ = 50,
  MinDistance = 12,
  MaxCandidates = 25,
  Seed = 777,
})

assert(#points3D > 0, "3D points array should not be empty")
for _, p in ipairs(points3D) do
  assert(p.X >= 0 and p.X < 50, "Point X out of bounds in 3D")
  assert(p.Y >= 0 and p.Y < 50, "Point Y out of bounds in 3D")
  assert(p.Z >= 0 and p.Z < 50, "Point Z out of bounds in 3D")
end

local valid3D, minFound3D = PoissonDiskSampling.ValidateSeparation3D(points3D, 12, 0.999)
assert(valid3D, string.format("Separation violation in 3D: min distance %f", minFound3D))

-- Test 6: Variable Distance Sampling (DistanceSampler)
local pointsVar = PoissonDiskSampling.Sample2D({
  MinX = 0,
  MaxX = 120,
  MinY = 0,
  MaxY = 120,
  MinDistance = 6,
  Seed = 555,
  DistanceSampler = function(p)
    -- Left half dense (r = 6), right half sparse (r = 20)
    if p.X < 60 then
      return 6
    else
      return 20
    end
  end,
})

local leftDense = 0
local rightSparse = 0
for _, p in ipairs(pointsVar) do
  if p.X < 60 then
    leftDense += 1
  else
    rightSparse += 1
  end
end
assert(leftDense > rightSparse * 2, string.format("Variable distance failed: dense=%d, sparse=%d", leftDense, rightSparse))

-- Test 7: ThinningSampler
local pointsThinned = PoissonDiskSampling.Sample2D({
  MinX = 0,
  MaxX = 100,
  MinY = 0,
  MaxY = 100,
  MinDistance = 8,
  Seed = 888,
  ThinningSampler = function(p)
    -- Suppress 90% of samples on right side
    return p.X < 50 and 1.0 or 0.1
  end,
})

local leftThin = 0
local rightThin = 0
for _, p in ipairs(pointsThinned) do
  if p.X < 50 then
    leftThin += 1
  else
    rightThin += 1
  end
end
assert(leftThin > rightThin * 2, string.format("Thinning sampler failed: left=%d, right=%d", leftThin, rightThin))

print("PASS: PoissonDiskSampling tests (2D, 3D, Invariants, Determinism, Exclusion, VariableDistance, Thinning) passed cleanly!")
