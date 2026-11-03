--!strict
--[[
  CatmullRomSpline.luau
  crustdev studio systems - ReplicatedStorage/Procedural/CatmullRomSpline

  Production-grade 3-dimensional Catmull-Rom spline evaluator with arc-length parameterization
  and Rotation-Minimizing Frames (RMF / Bishop frame).

  Features:
  - Spline knot parameterization types: Uniform (alpha=0.0), Centripetal (alpha=0.5), Chordal (alpha=1.0).
  - Open curves (with automatic phantom endpoint extrapolation) and closed loop curves.
  - C1 continuous evaluation of position, tangent (1st derivative), and acceleration/curvature (2nd derivative).
  - Arc-Length parameterization via numerical integration lookup table (LUT) for constant-velocity traversal.
  - Rotation-Minimizing Frame (RMF / Bishop frame) calculation via the Double Reflection method (Wang et al., 2008),
    guaranteeing zero-twist orientation without Frenet-Serret inflection singularities.
  - Closest point projection via hierarchical LUT seeding and golden-section refinement.
  - Uniform arc-length point distribution and procedural tube/rail geometry extraction.
  - Fully compatible with Roblox Engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local CFrame = _G.CFrame or CFrame

export type SplineType = "Uniform" | "Centripetal" | "Chordal"

export type SplineOptions = {
  SplineType: SplineType?,
  IsClosed: boolean?,
  SamplesPerSegment: number?,
  InitialUp: Vector3?,
}

export type SplineSample = {
  Position: Vector3,
  Tangent: Vector3,
  Normal: Vector3,
  Binormal: Vector3,
  CFrame: CFrame,
  Distance: number,
  T: number,
}

export type TubeGeometry = {
  Vertices: { Vector3 },
  Normals: { Vector3 },
  Indices: { number },
}

export type CatmullRomSplineImpl = {
  __index: CatmullRomSplineImpl,
  new: (points: { Vector3 }, options: SplineOptions?) -> CatmullRomSpline,
  Evaluate: (self: CatmullRomSpline, t: number) -> Vector3,
  EvaluateDerivative: (self: CatmullRomSpline, t: number) -> Vector3,
  EvaluateSecondDerivative: (self: CatmullRomSpline, t: number) -> Vector3,
  EvaluateTangent: (self: CatmullRomSpline, t: number) -> Vector3,
  EvaluateCurvature: (self: CatmullRomSpline, t: number) -> number,
  EvaluateFrame: (self: CatmullRomSpline, t: number) -> CFrame,
  GetLength: (self: CatmullRomSpline) -> number,
  DistanceToT: (self: CatmullRomSpline, distance: number) -> number,
  TToDistance: (self: CatmullRomSpline, t: number) -> number,
  EvaluateAtDistance: (self: CatmullRomSpline, distance: number) -> Vector3,
  EvaluateTangentAtDistance: (self: CatmullRomSpline, distance: number) -> Vector3,
  EvaluateFrameAtDistance: (self: CatmullRomSpline, distance: number) -> CFrame,
  FindClosestPoint: (self: CatmullRomSpline, targetPos: Vector3, steps: number?) -> (Vector3, number, number),
  SampleUniform: (self: CatmullRomSpline, sampleCount: number) -> { SplineSample },
  GenerateTubeGeometry: (self: CatmullRomSpline, radius: number, radialSegments: number?, pathSegments: number?) -> TubeGeometry,
  GetControlPoints: (self: CatmullRomSpline) -> { Vector3 },
  IsClosed: (self: CatmullRomSpline) -> boolean,
}

export type CatmullRomSpline = typeof(setmetatable({} :: {
  _points: { Vector3 },
  _extendedPoints: { Vector3 },
  _segmentCount: number,
  _splineType: SplineType,
  _alpha: number,
  _isClosed: boolean,
  _samplesPerSegment: number,
  _totalLength: number,
  _arcLengthLUT: { { T: number, Distance: number } },
  _sampleFrames: { { Position: Vector3, Tangent: Vector3, Normal: Vector3, Binormal: Vector3 } },
}, {} :: CatmullRomSplineImpl))

local CatmullRomSpline = {} :: CatmullRomSplineImpl
CatmullRomSpline.__index = CatmullRomSpline

local EPSILON = 1e-6
local DERIVATIVE_DELTA = 1e-4

local function getAlpha(splineType: SplineType): number
  if splineType == "Uniform" then
    return 0.0
  elseif splineType == "Chordal" then
    return 1.0
  else
    return 0.5 -- Centripetal default
  end
end

-- Evaluates single segment using Barry and Goldman's pyramidal formulation
local function evaluateSegment(
  p0: Vector3,
  p1: Vector3,
  p2: Vector3,
  p3: Vector3,
  alpha: number,
  u: number -- normalized [0, 1] within this segment
): Vector3
  if alpha == 0.0 then
    -- Fast path for uniform Catmull-Rom
    local u2 = u * u
    local u3 = u2 * u
    local term0 = -u3 + 2 * u2 - u
    local term1 = 3 * u3 - 5 * u2 + 2
    local term2 = -3 * u3 + 4 * u2 + u
    local term3 = u3 - u2
    return (p0 * term0 + p1 * term1 + p2 * term2 + p3 * term3) * 0.5
  end

  -- Non-uniform centripetal or chordal knot vector
  local d01 = math.max((p1 - p0).Magnitude ^ alpha, EPSILON)
  local d12 = math.max((p2 - p1).Magnitude ^ alpha, EPSILON)
  local d23 = math.max((p3 - p2).Magnitude ^ alpha, EPSILON)

  local t0 = 0
  local t1 = t0 + d01
  local t2 = t1 + d12
  local t3 = t2 + d23

  local t = t1 + u * (t2 - t1)

  -- Level 1 pyramidal interpolation
  local a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
  local a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
  local a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))

  -- Level 2 pyramidal interpolation
  local b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
  local b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))

  -- Level 3 final point
  return b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1))
end

function CatmullRomSpline.new(points: { Vector3 }, options: SplineOptions?): CatmullRomSpline
  assert(#points >= 2, "CatmullRomSpline requires at least 2 control points")

  local opts = options or {}
  local splineType = opts.SplineType or "Centripetal"
  local isClosed = opts.IsClosed or false
  local samplesPerSegment = math.max(opts.SamplesPerSegment or 64, 16)
  local initialUp = opts.InitialUp or Vector3.new(0, 1, 0)

  local extended: { Vector3 } = {}
  local n = #points

  if isClosed then
    assert(n >= 3, "Closed spline requires at least 3 control points")
    -- In closed mode: segment 1 is between P1 and P2, ..., segment n is between Pn and P1
    -- Extended array needs Pn at front, then P1..Pn, then P1, P2
    table.insert(extended, points[n])
    for i = 1, n do
      table.insert(extended, points[i])
    end
    table.insert(extended, points[1])
    table.insert(extended, points[2])
  else
    -- Open mode: synthesize phantom endpoints via linear reflection
    -- P_start = P1 - (P2 - P1)
    local pStart = points[1] - (points[2] - points[1])
    -- P_end = Pn + (Pn - P_{n-1})
    local pEnd = points[n] + (points[n] - points[n - 1])

    table.insert(extended, pStart)
    for i = 1, n do
      table.insert(extended, points[i])
    end
    table.insert(extended, pEnd)
  end

  local segmentCount = if isClosed then n else n - 1

  local self = setmetatable({
    _points = points,
    _extendedPoints = extended,
    _segmentCount = segmentCount,
    _splineType = splineType,
    _alpha = getAlpha(splineType),
    _isClosed = isClosed,
    _samplesPerSegment = samplesPerSegment,
    _totalLength = 0,
    _arcLengthLUT = {},
    _sampleFrames = {},
  }, CatmullRomSpline)

  -- Build arc-length lookup table (LUT)
  local totalSamples = segmentCount * samplesPerSegment
  local lut = table.create(totalSamples + 1)
  local accumulatedDist = 0

  lut[1] = { T = 0, Distance = 0 }
  local prevPos = self:Evaluate(0)

  for i = 1, totalSamples do
    local t = i / totalSamples
    local currPos = self:Evaluate(t)
    accumulatedDist += (currPos - prevPos).Magnitude
    lut[i + 1] = { T = t, Distance = accumulatedDist }
    prevPos = currPos
  end

  self._totalLength = accumulatedDist
  self._arcLengthLUT = lut

  -- Build Rotation-Minimizing Frames (RMF) along LUT samples via double reflection
  local sampleFrames = table.create(totalSamples + 1)
  local initPos = self:Evaluate(0)
  local initTan = self:EvaluateTangent(0)

  -- Determine initial normal orthogonal to tangent
  local normal = initialUp:Cross(initTan)
  if normal.Magnitude < EPSILON then
    local fallbackAxis = if math.abs(initTan.X) < 0.9 then Vector3.new(1, 0, 0) else Vector3.new(0, 0, 1)
    normal = fallbackAxis:Cross(initTan).Unit
  else
    normal = normal.Unit
  end
  local binormal = initTan:Cross(normal).Unit

  sampleFrames[1] = {
    Position = initPos,
    Tangent = initTan,
    Normal = normal,
    Binormal = binormal,
  }

  for i = 1, totalSamples do
    local prevFrame = sampleFrames[i]
    local x0 = prevFrame.Position
    local t0 = prevFrame.Tangent
    local n0 = prevFrame.Normal

    local tNext = lut[i + 1].T
    local x1 = self:Evaluate(tNext)
    local t1 = self:EvaluateTangent(tNext)

    -- Double reflection algorithm (Wang et al., 2008)
    local v1 = x1 - x0
    local c1 = v1:Dot(v1)
    local n1: Vector3

    if c1 > EPSILON then
      local rL = n0 - v1 * (2 * (v1:Dot(n0)) / c1)
      local tL = t0 - v1 * (2 * (v1:Dot(t0)) / c1)

      local v2 = t1 - tL
      local c2 = v2:Dot(v2)
      if c2 > EPSILON then
        n1 = (rL - v2 * (2 * (v2:Dot(rL)) / c2)).Unit
      else
        n1 = rL.Unit
      end
    else
      n1 = n0
    end

    local b1 = t1:Cross(n1).Unit
    n1 = b1:Cross(t1).Unit -- ensure strict orthogonality

    sampleFrames[i + 1] = {
      Position = x1,
      Tangent = t1,
      Normal = n1,
      Binormal = b1,
    }
  end

  self._sampleFrames = sampleFrames

  return self
end

function CatmullRomSpline:Evaluate(t: number): Vector3
  local count = self._segmentCount
  if count <= 0 then
    return Vector3.new(0, 0, 0)
  end

  local clampedT: number
  if self._isClosed then
    clampedT = t % 1.0
    if clampedT < 0 then
      clampedT += 1.0
    end
  else
    clampedT = math.clamp(t, 0, 1)
  end

  local rawSegment = clampedT * count
  local segIndex = math.floor(rawSegment)
  local u = rawSegment - segIndex

  if segIndex >= count then
    segIndex = count - 1
    u = 1.0
  end

  -- Extended array indices: extended[1] = P0, extended[2] = P1, extended[3] = P2, extended[4] = P3 for segIndex 0
  local base = segIndex + 1
  local p0 = self._extendedPoints[base]
  local p1 = self._extendedPoints[base + 1]
  local p2 = self._extendedPoints[base + 2]
  local p3 = self._extendedPoints[base + 3]

  return evaluateSegment(p0, p1, p2, p3, self._alpha, u)
end

function CatmullRomSpline:EvaluateDerivative(t: number): Vector3
  local delta = DERIVATIVE_DELTA
  local pNext = self:Evaluate(t + delta)
  local pPrev = self:Evaluate(t - delta)
  return (pNext - pPrev) / (2 * delta)
end

function CatmullRomSpline:EvaluateSecondDerivative(t: number): Vector3
  local delta = DERIVATIVE_DELTA
  local pCurr = self:Evaluate(t)
  local pNext = self:Evaluate(t + delta)
  local pPrev = self:Evaluate(t - delta)
  return (pNext - 2 * pCurr + pPrev) / (delta * delta)
end

function CatmullRomSpline:EvaluateTangent(t: number): Vector3
  local deriv = self:EvaluateDerivative(t)
  local mag = deriv.Magnitude
  if mag < EPSILON then
    return Vector3.new(0, 0, 1)
  end
  return deriv / mag
end

function CatmullRomSpline:EvaluateCurvature(t: number): number
  local v = self:EvaluateDerivative(t)
  local a = self:EvaluateSecondDerivative(t)
  local vMag = v.Magnitude
  if vMag < EPSILON then
    return 0
  end
  local cross = v:Cross(a)
  return cross.Magnitude / (vMag * vMag * vMag)
end

function CatmullRomSpline:GetLength(): number
  return self._totalLength
end

function CatmullRomSpline:DistanceToT(distance: number): number
  if self._totalLength <= EPSILON then
    return 0
  end

  local dist = distance
  if self._isClosed then
    dist = dist % self._totalLength
    if dist < 0 then
      dist += self._totalLength
    end
  else
    dist = math.clamp(dist, 0, self._totalLength)
  end

  local lut = self._arcLengthLUT
  local low = 1
  local high = #lut

  while low <= high do
    local mid = math.floor((low + high) / 2)
    local sampleDist = lut[mid].Distance
    if sampleDist < dist then
      low = mid + 1
    else
      high = mid - 1
    end
  end

  local idx = math.clamp(high, 1, #lut - 1)
  local d0 = lut[idx].Distance
  local d1 = lut[idx + 1].Distance
  local t0 = lut[idx].T
  local t1 = lut[idx + 1].T

  local span = d1 - d0
  local factor = if span > EPSILON then (dist - d0) / span else 0
  return t0 + factor * (t1 - t0)
end

function CatmullRomSpline:TToDistance(t: number): number
  local clampedT = if self._isClosed then (t % 1.0) else math.clamp(t, 0, 1)
  if clampedT < 0 then
    clampedT += 1.0
  end

  local lut = self._arcLengthLUT
  local targetIdx = clampedT * (#lut - 1) + 1
  local lowIdx = math.floor(targetIdx)
  local highIdx = math.min(lowIdx + 1, #lut)
  local factor = targetIdx - lowIdx

  return lut[lowIdx].Distance + factor * (lut[highIdx].Distance - lut[lowIdx].Distance)
end

function CatmullRomSpline:EvaluateAtDistance(distance: number): Vector3
  local t = self:DistanceToT(distance)
  return self:Evaluate(t)
end

function CatmullRomSpline:EvaluateTangentAtDistance(distance: number): Vector3
  local t = self:DistanceToT(distance)
  return self:EvaluateTangent(t)
end

-- Evaluates orientation CFrame via interpolated Rotation Minimizing Frame (RMF)
function CatmullRomSpline:EvaluateFrame(t: number): CFrame
  local clampedT = if self._isClosed then (t % 1.0) else math.clamp(t, 0, 1)
  if clampedT < 0 then
    clampedT += 1.0
  end

  local frames = self._sampleFrames
  local count = #frames
  local posFloat = clampedT * (count - 1) + 1
  local idx0 = math.floor(posFloat)
  local idx1 = math.min(idx0 + 1, count)
  local f = posFloat - idx0

  local f0 = frames[idx0]
  local f1 = frames[idx1]

  local pos = f0.Position:Lerp(f1.Position, f)
  local tan = (f0.Tangent:Lerp(f1.Tangent, f)).Unit
  local norm = (f0.Normal:Lerp(f1.Normal, f)).Unit
  local binorm = tan:Cross(norm).Unit
  norm = binorm:Cross(tan).Unit

  return CFrame.lookAt(pos, pos + tan, norm)
end

function CatmullRomSpline:EvaluateFrameAtDistance(distance: number): CFrame
  local t = self:DistanceToT(distance)
  return self:EvaluateFrame(t)
end

-- Golden-section projection to find closest point on spline
function CatmullRomSpline:FindClosestPoint(targetPos: Vector3, steps: number?): (Vector3, number, number)
  local lut = self._arcLengthLUT
  local lutCount = #lut
  local bestIdx = 1
  local bestDistSq = math.huge

  for i = 1, lutCount do
    local p = self:Evaluate(lut[i].T)
    local diff = p - targetPos
    local distSq = diff:Dot(diff)
    if distSq < bestDistSq then
      bestDistSq = distSq
      bestIdx = i
    end
  end

  local tSpan = 2 / self._segmentCount
  local tMin = math.max(0, lut[bestIdx].T - tSpan)
  local tMax = math.min(1, lut[bestIdx].T + tSpan)

  local phi = (math.sqrt(5) - 1) / 2
  local iterations = steps or 16

  local a = tMin
  local b = tMax
  local c = b - phi * (b - a)
  local d = a + phi * (b - a)

  for _ = 1, iterations do
    local pC = self:Evaluate(c)
    local pD = self:Evaluate(d)
    local distC = (pC - targetPos).Magnitude
    local distD = (pD - targetPos).Magnitude

    if distC < distD then
      b = d
      d = c
      c = b - phi * (b - a)
    else
      a = c
      c = d
      d = a + phi * (b - a)
    end
  end

  local optimalT = (a + b) / 2
  local closestPos = self:Evaluate(optimalT)
  local finalDist = (closestPos - targetPos).Magnitude

  return closestPos, optimalT, finalDist
end

-- Samples uniform points along the arc-length
function CatmullRomSpline:SampleUniform(sampleCount: number): { SplineSample }
  assert(sampleCount >= 2, "SampleUniform requires at least 2 samples")
  local samples = table.create(sampleCount)
  local totalLength = self._totalLength

  for i = 1, sampleCount do
    local dist = ((i - 1) / (sampleCount - 1)) * totalLength
    local t = self:DistanceToT(dist)
    local frame = self:EvaluateFrame(t)
    local tan = self:EvaluateTangent(t)
    local norm = frame.UpVector
    local binorm = frame.RightVector

    samples[i] = {
      Position = frame.Position,
      Tangent = tan,
      Normal = norm,
      Binormal = binorm,
      CFrame = frame,
      Distance = dist,
      T = t,
    }
  end

  return samples
end

-- Generates procedural tube mesh geometry (vertices, normals, and triangle indices)
function CatmullRomSpline:GenerateTubeGeometry(
  radius: number,
  radialSegments: number?,
  pathSegments: number?
): TubeGeometry
  local rSegments = radialSegments or 8
  local pSegments = pathSegments or (self._segmentCount * 16)
  assert(rSegments >= 3, "Radial segments must be at least 3")
  assert(pSegments >= 2, "Path segments must be at least 2")

  local vertices: { Vector3 } = {}
  local normals: { Vector3 } = {}
  local indices: { number } = {}

  for i = 0, pSegments do
    local t = i / pSegments
    local frame = self:EvaluateFrame(t)
    local center = frame.Position
    local up = frame.UpVector
    local right = frame.RightVector

    for j = 0, rSegments - 1 do
      local angle = (j / rSegments) * math.pi * 2
      local cosA = math.cos(angle)
      local sinA = math.sin(angle)
      local localNorm = (right * cosA + up * sinA).Unit
      local vertPos = center + localNorm * radius

      table.insert(vertices, vertPos)
      table.insert(normals, localNorm)
    end
  end

  -- Generate triangle strips
  for i = 0, pSegments - 1 do
    for j = 0, rSegments - 1 do
      local nextJ = (j + 1) % rSegments
      local v0 = i * rSegments + j + 1
      local v1 = i * rSegments + nextJ + 1
      local v2 = (i + 1) * rSegments + j + 1
      local v3 = (i + 1) * rSegments + nextJ + 1

      -- Triangle 1 (v0, v2, v1)
      table.insert(indices, v0)
      table.insert(indices, v2)
      table.insert(indices, v1)

      -- Triangle 2 (v1, v2, v3)
      table.insert(indices, v1)
      table.insert(indices, v2)
      table.insert(indices, v3)
    end
  end

  return {
    Vertices = vertices,
    Normals = normals,
    Indices = indices,
  }
end

function CatmullRomSpline:GetControlPoints(): { Vector3 }
  return self._points
end

function CatmullRomSpline:IsClosed(): boolean
  return self._isClosed
end

return CatmullRomSpline
