local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local ClothVerletMesh = require("../src/ReplicatedStorage/Physics/ClothVerletMesh")

-- Test 1: Grid Topology & Initialization
local origin = Vector3.new(0, 50, 0)
local rows = 5
local cols = 5
local cloth = ClothVerletMesh.new(origin, {
  rows = rows,
  cols = cols,
  width = 20,
  height = 20,
  damping = 0.98,
  gravity = Vector3.new(0, -98.1, 0),
  structuralIterations = 6,
  shearIterations = 3,
  flexionIterations = 2,
})

assert(#cloth.Particles == rows * cols, string.format("Expected %d particles, got %d", rows * cols, #cloth.Particles))
local activeConstraints = cloth:GetActiveConstraintCount()
assert(activeConstraints > 0, "Cloth must have active constraints")

local tris = cloth:GetTriangles()
local expectedTris = (rows - 1) * (cols - 1) * 2
assert(#tris == expectedTris, string.format("Expected %d triangles, got %d", expectedTris, #tris))

-- Test 2: Top Edge Pinning & Gravity Response
cloth:PinTopEdge()
for c = 1, cols do
  local p = cloth:GetParticle(1, c)
  assert(p ~= nil and p.isPinned == true, string.format("Top edge particle (1, %d) must be pinned", c))
end

local bottomParticleInitial = cloth:GetParticle(rows, math.ceil(cols / 2))
assert(bottomParticleInitial ~= nil, "Bottom particle should exist")
local initialBottomY = bottomParticleInitial.position.Y

-- Step physics
for _ = 1, 20 do
  cloth:Step(0.016)
end

-- Top edge should remain at origin Y
for c = 1, cols do
  local p = cloth:GetParticle(1, c)
  assert(p ~= nil, "Top edge particle must exist")
  assert(math.abs(p.position.Y - origin.Y) < 1e-4, "Top edge must remain anchored")
end

local bottomParticleAfter = cloth:GetParticle(rows, math.ceil(cols / 2))
assert(bottomParticleAfter ~= nil, "Bottom particle must exist")
assert(bottomParticleAfter.position.Y < initialBottomY, "Bottom edge must sag under gravity")

-- Test 3: Aerodynamic Wind Force Response
local initialZ = bottomParticleAfter.position.Z
cloth:SetWind({
  baseVelocity = Vector3.new(0, 0, 50),
  gustStrength = 10,
  gustFrequency = 1.5,
  dragCoefficient = 0.1,
})

for _ = 1, 30 do
  cloth:Step(0.016)
end

local bottomParticleWind = cloth:GetParticle(rows, math.ceil(cols / 2))
assert(bottomParticleWind ~= nil, "Bottom particle must exist")
assert(bottomParticleWind.position.Z > initialZ + 0.5, "Cloth must billow in +Z direction under wind")

-- Test 4: Sphere Collider Collision
local sphereCenter = Vector3.new(0, 38, 2)
local sphereRadius = 6.0
cloth:AddSphereCollider({
  center = sphereCenter,
  radius = sphereRadius,
  friction = 0.2,
})

for _ = 1, 30 do
  cloth:Step(0.016)
end

for _, p in ipairs(cloth.Particles) do
  if not p.isPinned then
    local dist = (p.position - sphereCenter).Magnitude
    assert(dist >= sphereRadius - 1e-3, string.format("Particle penetrated sphere collider! Dist: %f, Radius: %f", dist, sphereRadius))
  end
end

-- Test 5: Planar Ground Collision
local floorY = 25.0
cloth:AddPlaneCollider({
  point = Vector3.new(0, floorY, 0),
  normal = Vector3.new(0, 1, 0),
  friction = 0.3,
})

for _ = 1, 30 do
  cloth:Step(0.016)
end

for _, p in ipairs(cloth.Particles) do
  if not p.isPinned then
    assert(p.position.Y >= floorY - 1e-3, string.format("Particle fell below floor plane! Y: %f, FloorY: %f", p.position.Y, floorY))
  end
end

-- Test 6: Normal Calculation
local normals = cloth:GetNormals()
assert(#normals == #cloth.Particles, "Must return normal for every particle")
for i, n in ipairs(normals) do
  local mag = n.Magnitude
  assert(math.abs(mag - 1.0) < 1e-3, string.format("Normal %d is not unit length! Magnitude: %f", i, mag))
end

-- Test 7: Structural Tearing Threshold
local tearCloth = ClothVerletMesh.new(origin, {
  rows = 3,
  cols = 3,
  width = 6,
  height = 6,
  tearRatio = 1.5,
})
tearCloth:PinParticle(1, 1, true)
-- Move particle (1, 2) far away to snap the constraint
local p = tearCloth:GetParticle(1, 2)
assert(p ~= nil, "Particle (1, 2) should exist")
p.position = p.position + Vector3.new(100, 0, 0)
tearCloth:Step(0.016)

assert(tearCloth:GetTornConstraintCount() > 0, "Constraint should rupture when stretched beyond tearRatio")

print("PASS: ClothVerletMesh tests (Topology, Pinning, Gravity, Wind, SphereCollider, PlaneCollider, Normals, Tearing) passed cleanly!")
return true