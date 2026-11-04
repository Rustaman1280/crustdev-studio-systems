--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local InfluenceMap = require("../src/ReplicatedStorage/AI/InfluenceMap")

local function assertApprox(a: number, b: number, eps: number?, msg: string?)
  local epsilon = eps or 1e-4
  if math.abs(a - b) > epsilon then
    error(string.format("%s: expected approx %f, got %f (diff: %f)", msg or "assertApprox", b, a, math.abs(a - b)))
  end
end

-- 1. Initialization and Dimensions
do
  local imap = InfluenceMap.new({
    origin = Vector3.new(0, 0, 0),
    sizeX = 20,
    sizeZ = 20,
    cellSize = 10,
  })

  local sx, sz, cs = imap:GetGridDimensions()
  assert(sx == 20 and sz == 20 and cs == 10, "Dimensions should match config")
  assert(imap:GetOrigin() == Vector3.new(0, 0, 0), "Origin should match config")

  -- Coordinate mapping
  local gx, gz = imap:WorldToGrid(Vector3.new(5, 0, 5))
  assert(gx == 1 and gz == 1, "World (5,0,5) should map to cell (1, 1)")

  local gx2, gz2 = imap:WorldToGrid(Vector3.new(15, 0, 25))
  assert(gx2 == 2 and gz2 == 3, "World (15,0,25) should map to cell (2, 3)")

  local centerWorld = imap:GridToWorld(1, 1)
  assert(centerWorld.X == 5 and centerWorld.Z == 5, "Grid (1, 1) center should be (5, 0, 5)")
end

-- 2. Point Influence and Falloffs
do
  local imap = InfluenceMap.new({
    origin = Vector3.new(0, 0, 0),
    sizeX = 10,
    sizeZ = 10,
    cellSize = 5,
  })

  -- Constant Falloff
  imap:AddInfluencePoint("Cover", Vector3.new(22.5, 0, 22.5), 50, 10, "Constant")
  local centerVal = imap:GetInfluence("Cover", Vector3.new(22.5, 0, 22.5))
  assertApprox(centerVal, 50, 1e-2, "Center constant influence should be 50")

  -- Linear Falloff
  imap:RegisterLayer("TestLinear", { decayRate = 0, diffusionRate = 0, minValue = 0, maxValue = 100 })
  imap:AddInfluencePoint("TestLinear", Vector3.new(25, 0, 25), 100, 20, "Linear")

  local centerLinear = imap:GetInfluence("TestLinear", Vector3.new(25, 0, 25))
  assert(centerLinear > 80, "Linear center should be high")

  local midLinear = imap:GetInfluence("TestLinear", Vector3.new(35, 0, 25))
  assert(midLinear > 30 and midLinear < 70, "Midpoint linear influence should be near 50")

  local outsideLinear = imap:GetInfluence("TestLinear", Vector3.new(50, 0, 25))
  assertApprox(outsideLinear, 0, 1e-2, "Outside radius should be 0")
end

-- 3. Line Influence
do
  local imap = InfluenceMap.new({
    origin = Vector3.new(0, 0, 0),
    sizeX = 20,
    sizeZ = 20,
    cellSize = 5,
  })

  imap:RegisterLayer("Laser", { decayRate = 0, diffusionRate = 0, minValue = 0, maxValue = 100 })
  imap:AddInfluenceLine("Laser", Vector3.new(10, 0, 50), Vector3.new(90, 0, 50), 80, 10, "Linear")

  -- Along the line segment
  local valMid = imap:GetInfluence("Laser", Vector3.new(50, 0, 50))
  assert(valMid >= 60, "Midpoint along line segment should receive strong influence")

  local valNear = imap:GetInfluence("Laser", Vector3.new(20, 0, 50))
  assert(valNear >= 60, "Segment point near start should receive strong influence")

  -- Far away from segment
  local valFar = imap:GetInfluence("Laser", Vector3.new(50, 0, 80))
  assertApprox(valFar, 0, 1e-2, "Far away perpendicular point should receive zero influence")
end

-- 4. Gradient Calculation
do
  local imap = InfluenceMap.new({
    origin = Vector3.new(0, 0, 0),
    sizeX = 15,
    sizeZ = 15,
    cellSize = 5,
  })

  imap:AddInfluencePoint("Threat", Vector3.new(50, 0, 50), 100, 30, "Linear")

  -- At position (40, 0, 50), Threat increases to the right (+X towards 50)
  local grad = imap:GetGradient("Threat", Vector3.new(40, 0, 50))
  assert(grad.X > 0, "Gradient X should point towards increasing threat (+X)")
  assertApprox(grad.Z, 0, 0.5, "Gradient Z should be close to 0 along horizontal axis")

  -- At position (60, 0, 50), Threat decreases to the right (-X towards 50)
  local gradRight = imap:GetGradient("Threat", Vector3.new(60, 0, 50))
  assert(gradRight.X < 0, "Gradient X should point back towards threat source (-X)")
end

-- 5. Time Dynamics: Decay and Diffusion
do
  local imap = InfluenceMap.new({
    origin = Vector3.new(0, 0, 0),
    sizeX = 10,
    sizeZ = 10,
    cellSize = 5,
  })

  imap:RegisterLayer("DecayExp", { decayRate = 1.0, diffusionRate = 0, minValue = 0, maxValue = 100, decayType = "Exponential" })
  imap:SetCell("DecayExp", 5, 5, 80)

  imap:Update(1.0) -- 1 second decay: 80 * exp(-1.0) ~ 80 * 0.3678 = 29.4
  local decayedVal = imap:GetCell("DecayExp", 5, 5)
  assert(decayedVal < 40 and decayedVal > 20, "Exponential decay should reduce value")

  -- Diffusion: value spreads to neighbors
  imap:RegisterLayer("DiffTest", { decayRate = 0, diffusionRate = 0.5, minValue = 0, maxValue = 100 })
  imap:SetCell("DiffTest", 5, 5, 100)
  assert(imap:GetCell("DiffTest", 4, 5) == 0, "Neighbor should start at 0 before diffusion")

  imap:Update(0.5)
  local neighborVal = imap:GetCell("DiffTest", 4, 5)
  assert(neighborVal > 0, "Diffusion should propagate influence to adjacent neighbor")
end

-- 6. Optimal Position Tactical Query
do
  local imap = InfluenceMap.new({
    origin = Vector3.new(0, 0, 0),
    sizeX = 15,
    sizeZ = 15,
    cellSize = 10,
  })

  -- Place Threat at (25, 0, 25)
  imap:AddInfluencePoint("Threat", Vector3.new(25, 0, 25), 80, 40, "Linear")

  -- Place Cover at (120, 0, 120)
  imap:AddInfluencePoint("Cover", Vector3.new(120, 0, 120), 100, 40, "Linear")

  local bestPos, bestScore = imap:FindOptimalPosition({
    center = Vector3.new(75, 0, 75),
    radius = 80,
    weights = {
      Threat = -2.0, -- Strongly avoid threat
      Cover = 1.5,   -- Strongly seek cover
    },
  })

  assert(bestPos ~= nil, "Should find an optimal position")
  assert(bestPos.X > 75 and bestPos.Z > 75, "Best position should be shifted towards cover and away from threat")
  assert(bestScore > 0, "Score should be positive due to cover weighting")
end

-- 7. Tension Map Calculation
do
  local imap = InfluenceMap.new({
    origin = Vector3.new(0, 0, 0),
    sizeX = 10,
    sizeZ = 10,
    cellSize = 10,
  })

  imap:AddInfluencePoint("Threat", Vector3.new(50, 0, 50), 100, 40, "Constant")
  imap:AddInfluencePoint("Friendly", Vector3.new(50, 0, 50), 100, 40, "Constant")

  local tension = imap:ComputeTension("Threat", "Friendly")
  local centerGx, centerGz = imap:WorldToGrid(Vector3.new(50, 0, 50))
  local centerTension = tension[centerGx][centerGz]
  assertApprox(centerTension, 100, 1e-2, "Tension at overlapping peak should be sqrt(100*100) = 100")
end

-- 8. Clear functionality
do
  local imap = InfluenceMap.new({
    origin = Vector3.new(0, 0, 0),
    sizeX = 5,
    sizeZ = 5,
    cellSize = 5,
  })

  imap:SetCell("Threat", 2, 2, 75)
  assert(imap:GetCell("Threat", 2, 2) == 75, "Cell should be set")

  imap:Clear("Threat")
  assert(imap:GetCell("Threat", 2, 2) == 0, "Cell should be cleared to 0")
end

print("InfluenceMap tests passed successfully!")
