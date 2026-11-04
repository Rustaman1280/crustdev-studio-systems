local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
_G.Vector3 = Vector3
_G.CFrame = CFrame

local FrustumCuller = require("../src/ReplicatedStorage/Spatial/FrustumCuller")

-- Test 1: Direct construction from custom bounding planes
local customPlanes = {
  { Normal = Vector3.new(1, 0, 0), Distance = 10 }, -- x >= -10
  { Normal = Vector3.new(-1, 0, 0), Distance = 10 }, -- x <= 10
  { Normal = Vector3.new(0, 1, 0), Distance = 10 }, -- y >= -10
  { Normal = Vector3.new(0, -1, 0), Distance = 10 }, -- y <= 10
  { Normal = Vector3.new(0, 0, 1), Distance = 10 }, -- z >= -10
  { Normal = Vector3.new(0, 0, -1), Distance = 10 }, -- z <= 10
}

local boxCuller = FrustumCuller.FromPlanes(customPlanes)
assert(boxCuller:PlaneCount() == 6, "Plane count must be 6")
assert(boxCuller:TestPoint(Vector3.new(0, 0, 0)) == true, "Center point must be inside")
assert(boxCuller:TestPoint(Vector3.new(5, -5, 2)) == true, "Interior point must be inside")
assert(boxCuller:TestPoint(Vector3.new(15, 0, 0)) == false, "Exterior point (+15, 0, 0) must be outside")
assert(boxCuller:TestPoint(Vector3.new(0, -12, 0)) == false, "Exterior point (0, -12, 0) must be outside")

-- Test 2: Camera Frustum Construction
-- Camera at (0, 10, 0) looking forward along -Z: CFrame.new(0, 10, 0) * CFrame.Angles(0, 0, 0)
local camCFrame = CFrame.new(Vector3.new(0, 5, 0))
local culler = FrustumCuller.FromCamera(camCFrame, 60, 16 / 9, 1, 100)
assert(culler:PlaneCount() == 6, "Camera frustum must have 6 planes")

-- In front of camera along -Z (e.g. at 0, 5, -20)
local inFrontPoint = Vector3.new(0, 5, -20)
assert(culler:TestPoint(inFrontPoint) == true, "Point in front of camera should be inside")

-- Behind camera along +Z (e.g. at 0, 5, 10)
local behindPoint = Vector3.new(0, 5, 10)
assert(culler:TestPoint(behindPoint) == false, "Point behind camera should be outside")

-- Too far along -Z (e.g. at 0, 5, -150)
local tooFarPoint = Vector3.new(0, 5, -150)
assert(culler:TestPoint(tooFarPoint) == false, "Point beyond far plane should be outside")

-- Too close along -Z (e.g. at 0, 5, -0.2)
local tooClosePoint = Vector3.new(0, 5, -0.2)
assert(culler:TestPoint(tooClosePoint) == false, "Point in front of near plane should be outside")

-- Test 3: Sphere Culling
-- Sphere centered at (0, 5, -30) with radius 2 should be fully inside
local resInside = culler:TestSphere(Vector3.new(0, 5, -30), 2)
assert(resInside == "Inside", "Interior sphere must evaluate to Inside, got: " .. tostring(resInside))

-- Sphere far behind camera
local resOutside = culler:TestSphere(Vector3.new(0, 5, 50), 5)
assert(resOutside == "Outside", "Behind sphere must evaluate to Outside")

-- Sphere straddling the near plane (-1 stud forward from camera, so z = -1)
-- Center at (0, 5, -1), radius 1 -> straddles near plane
local resStraddle = culler:TestSphere(Vector3.new(0, 5, -1), 1)
assert(resStraddle == "Intersecting", "Straddling sphere must evaluate to Intersecting, got: " .. tostring(resStraddle))

-- Test 4: Axis-Aligned Bounding Box (AABB) Culling (P-vertex / N-vertex)
local aabbInsideMin = Vector3.new(-2, 4, -40)
local aabbInsideMax = Vector3.new(2, 6, -35)
assert(culler:TestAABB(aabbInsideMin, aabbInsideMax) == "Inside", "AABB inside frustum must be Inside")

local aabbOutsideMin = Vector3.new(100, 4, -40)
local aabbOutsideMax = Vector3.new(120, 6, -35)
assert(culler:TestAABB(aabbOutsideMin, aabbOutsideMax) == "Outside", "AABB far to the right must be Outside")

-- AABB straddling the far plane (z = -100)
local aabbFarStraddleMin = Vector3.new(-2, 4, -105)
local aabbFarStraddleMax = Vector3.new(2, 6, -95)
assert(culler:TestAABB(aabbFarStraddleMin, aabbFarStraddleMax) == "Intersecting", "Straddling AABB must be Intersecting")

-- Test 5: Oriented Bounding Box (OBB) Culling
local obbCenter = Vector3.new(0, 5, -25)
local obbHalfExtents = Vector3.new(1, 2, 3)
local obbRot = CFrame.Angles(0, math.rad(45), 0)
assert(culler:TestOBB(obbCenter, obbHalfExtents, obbRot) == "Inside", "OBB should be inside")

local obbOutsideCenter = Vector3.new(-80, 5, -25)
assert(culler:TestOBB(obbOutsideCenter, obbHalfExtents, obbRot) == "Outside", "OBB off-screen should be outside")

-- Test 6: High-throughput Batch Culling
local aabbBatch = {
  { Min = Vector3.new(-1, 4, -20), Max = Vector3.new(1, 6, -18), Id = "box1" },
  { Min = Vector3.new(-1, 4, -105), Max = Vector3.new(1, 6, -95), Id = "box2" },
  { Min = Vector3.new(50, 4, -20), Max = Vector3.new(60, 6, -18), Id = "box3" },
}

local visibleAABBs, aabbStats = culler:CullAABBList(aabbBatch)
assert(#visibleAABBs == 2, "Should have 2 visible AABBs (inside + intersecting)")
assert(aabbStats.TotalTested == 3, "Total tested should be 3")
assert(aabbStats.InsideCount == 1, "Inside count should be 1")
assert(aabbStats.IntersectingCount == 1, "Intersecting count should be 1")
assert(aabbStats.OutsideCount == 1, "Outside count should be 1")

-- Test 7: Frustum Corners and Tight Bounding Box
local corners = culler:GetCorners()
assert(#corners == 8, "Frustum must have 8 corners, got " .. tostring(#corners))

local fMin, fMax = culler:GetFrustumAABB()
assert(fMin.Z < fMax.Z, "Frustum bounding box min Z must be less than max Z")
assert(fMin.X < 0 and fMax.X > 0, "Frustum bounding box should span both sides of X")

print("PASS: FrustumCuller tests (Planes, Camera, Points, Spheres, AABB P/N, OBB, Batch, Corners) passed cleanly!")
