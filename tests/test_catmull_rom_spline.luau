--!strict
local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame
Vector3 = roblox.Vector3
CFrame = roblox.CFrame

local CatmullRomSpline = require("../src/ReplicatedStorage/Procedural/CatmullRomSpline")

local Vector3 = _G.Vector3 or Vector3

local function assertApprox(a: number, b: number, eps: number?, msg: string?)
  local epsilon = eps or 1e-3
  if math.abs(a - b) > epsilon then
    error(string.format("%s: expected approx %f, got %f (diff: %f)", msg or "assertApprox", b, a, math.abs(a - b)))
  end
end

local function assertVecApprox(a: any, b: any, eps: number?, msg: string?)
  local epsilon = eps or 1e-3
  if (a - b).Magnitude > epsilon then
    error(string.format("%s: vectors differ by %f (a=(%f,%f,%f), b=(%f,%f,%f))",
      msg or "assertVecApprox", (a - b).Magnitude, a.X, a.Y, a.Z, b.X, b.Y, b.Z))
  end
end

-- Test 1: Open Spline Endpoint Interpolation
do
  local pts = {
    Vector3.new(0, 0, 0),
    Vector3.new(10, 5, 0),
    Vector3.new(20, 0, 0),
    Vector3.new(30, 10, 5),
  }

  local spline = CatmullRomSpline.new(pts, { SplineType = "Centripetal" })
  assert(spline:GetControlPoints() == pts, "Control points should match")
  assert(not spline:IsClosed(), "Spline should not be closed")

  -- Evaluated at t=0 should match the first point exactly
  local startPos = spline:Evaluate(0)
  assertVecApprox(startPos, pts[1], 1e-3, "Start position must equal P1")

  -- Evaluated at t=1 should match the last point exactly
  local endPos = spline:Evaluate(1)
  assertVecApprox(endPos, pts[#pts], 1e-3, "End position must equal Pn")

  -- Evaluated at t=0.5 should lie between control points
  local midPos = spline:Evaluate(0.5)
  assert(midPos.X > 5 and midPos.X < 25, "Mid point should lie within bounds")
end

-- Test 2: Closed Spline Periodic Invariant
do
  local circlePts = {
    Vector3.new(10, 0, 0),
    Vector3.new(0, 0, 10),
    Vector3.new(-10, 0, 0),
    Vector3.new(0, 0, -10),
  }

  local closedSpline = CatmullRomSpline.new(circlePts, { IsClosed = true })
  assert(closedSpline:IsClosed(), "Spline must report closed")

  local pStart = closedSpline:Evaluate(0)
  local pEnd = closedSpline:Evaluate(1)
  local pWrap = closedSpline:Evaluate(2.0)
  assertVecApprox(pStart, pEnd, 1e-3, "Closed spline 0 and 1 must be identical")
  assertVecApprox(pStart, pWrap, 1e-3, "Closed spline modular wrapping must work")
end

-- Test 3: Arc-length Parameterization and Constant Speed Traversal
do
  local pts = {
    Vector3.new(0, 0, 0),
    Vector3.new(0, 0, 50),
    Vector3.new(50, 0, 50),
    Vector3.new(50, 0, 100),
  }

  local spline = CatmullRomSpline.new(pts, { SplineType = "Centripetal", SamplesPerSegment = 64 })
  local totalLen = spline:GetLength()
  assert(totalLen > 100, "Spline length must be positive and realistic")

  -- Test monotonic distance mapping
  local prevT = 0
  local steps = 20
  for i = 1, steps do
    local dist = (i / steps) * totalLen
    local t = spline:DistanceToT(dist)
    assert(t >= prevT, "T must monotonically increase with distance")
    local roundTripDist = spline:TToDistance(t)
    assertApprox(roundTripDist, dist, 0.5, "DistanceToT and TToDistance round-trip fidelity")
    prevT = t
  end

  -- Test constant-speed sampling
  local sample0 = spline:EvaluateAtDistance(0)
  local sampleHalf = spline:EvaluateAtDistance(totalLen * 0.5)
  local sampleEnd = spline:EvaluateAtDistance(totalLen)
  assertVecApprox(sample0, pts[1], 1e-2, "Distance 0 must be P1")
  assertVecApprox(sampleEnd, pts[#pts], 1e-2, "Distance TotalLength must be Pn")
end

-- Test 4: Rotation Minimizing Frame (RMF) Orthogonality
do
  local helicalPts = {
    Vector3.new(0, 0, 0),
    Vector3.new(10, 10, 10),
    Vector3.new(20, 0, 20),
    Vector3.new(10, -10, 30),
    Vector3.new(0, 0, 40),
  }

  local spline = CatmullRomSpline.new(helicalPts)
  for step = 0, 10 do
    local t = step / 10
    local frame = spline:EvaluateFrame(t)
    local tan = spline:EvaluateTangent(t)
    local norm = frame.UpVector
    local binorm = frame.RightVector

    -- Verify unit length
    assertApprox(tan.Magnitude, 1.0, 1e-3, "Tangent must be unit length")
    assertApprox(norm.Magnitude, 1.0, 1e-3, "Normal must be unit length")
    assertApprox(binorm.Magnitude, 1.0, 1e-3, "Binormal must be unit length")

    -- Verify orthogonality
    assertApprox(norm:Dot(tan), 0, 1e-2, "Normal and tangent must be orthogonal")
    assertApprox(binorm:Dot(tan), 0, 1e-2, "Binormal and tangent must be orthogonal")
    assertApprox(norm:Dot(binorm), 0, 1e-2, "Normal and binormal must be orthogonal")
  end
end

-- Test 5: Closest Point Projection
do
  local pts = {
    Vector3.new(0, 0, 0),
    Vector3.new(50, 0, 0),
    Vector3.new(100, 0, 0),
  }

  local spline = CatmullRomSpline.new(pts)
  local queryPos = Vector3.new(45, 10, 0)
  local closestPos, optT, dist = spline:FindClosestPoint(queryPos)

  assertApprox(closestPos.X, 45, 0.5, "Projected X coordinate should be close to 45")
  assertApprox(closestPos.Y, 0, 0.5, "Projected Y coordinate should be close to 0")
  assertApprox(dist, 10, 0.5, "Closest distance should be approx 10")
end

-- Test 6: Uniform Sampling and Procedural Tube Geometry
do
  local pts = {
    Vector3.new(0, 0, 0),
    Vector3.new(10, 5, 0),
    Vector3.new(20, 10, 5),
    Vector3.new(30, 5, 10),
  }

  local spline = CatmullRomSpline.new(pts)
  local samples = spline:SampleUniform(10)
  assert(#samples == 10, "Should generate exactly 10 samples")

  -- Verify distance spacing between successive samples
  local expectedGap = spline:GetLength() / 9
  for i = 1, #samples - 1 do
    local actualGap = samples[i + 1].Distance - samples[i].Distance
    assertApprox(actualGap, expectedGap, 1e-3, "Sample spacing should be equal")
  end

  -- Procedural tube mesh generation
  local tube = spline:GenerateTubeGeometry(1.5, 6, 8)
  local expectedVerts = (8 + 1) * 6
  assert(#tube.Vertices == expectedVerts, string.format("Tube vertices count: %d vs expected %d", #tube.Vertices, expectedVerts))
  assert(#tube.Normals == #tube.Vertices, "Normals count must match vertices")
  local expectedTriangles = 8 * 6 * 2
  assert(#tube.Indices == expectedTriangles * 3, "Indices count must match 3 per triangle")
end

print("PASS: CatmullRomSpline tests (Open, Closed, ArcLength, RMF Orthogonality, ClosestPoint, Uniform, TubeGeometry) passed cleanly!")
