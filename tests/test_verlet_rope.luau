local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local VerletRope = require("../src/ReplicatedStorage/Physics/VerletRope")

-- Test 1: Initialization & Node Pinning
local startPos = Vector3.new(0, 50, 0)
local endPos = Vector3.new(20, 50, 0)
local rope = VerletRope.new(startPos, endPos, {
  numSegments = 10,
  totalLength = 20,
  gravity = Vector3.new(0, -98.1, 0),
  damping = 0.98,
  constraintIterations = 10,
})

assert(#rope.Nodes == 11, "10 segments must result in 11 nodes")
assert(rope.Nodes[1].isPinned == true, "Node 1 should be pinned anchor")
assert(rope.Nodes[11].isPinned == true, "Node 11 should be pinned anchor")
assert(rope.Nodes[5].isPinned == false, "Internal nodes should be free")
assert(math.abs(rope.SegmentLength - 2.0) < 1e-4, "Segment length should be 2.0")

-- Test 2: Step and Gravity Effect on Middle Nodes
local initialMidPos = rope.Nodes[6].position
for _ = 1, 10 do
  rope:Step(0.016)
end

assert(rope.Nodes[1].position == startPos, "Anchor A must remain stationary")
assert(rope.Nodes[11].position == endPos, "Anchor B must remain stationary")
assert(rope.Nodes[6].position.Y < initialMidPos.Y, "Middle node must sag downward under gravity")

-- Test 3: Constraint Preservation (Gauss-Seidel passes)
local totalLen = rope:GetTotalLength()
assert(math.abs(totalLen - 20) < 1.0, "Total length under tension should remain close to target")

-- Test 4: Winch Functionality
local initialTotal = rope:GetTotalLength()
local newTotalTarget = rope:Winch(5) -- reel out 5 studs
assert(newTotalTarget == 25, "New total length target should be 25")
assert(rope.SegmentLength == 2.5, "Segment length should scale to 2.5")

-- Test 5: Sphere Collider Collision
local spherePos = Vector3.new(10, 40, 0)
local sphereRadius = 5.0
rope:AddCollider({
  center = spherePos,
  radius = sphereRadius,
})

for _ = 1, 20 do
  rope:Step(0.016)
end

-- Ensure none of the nodes penetrate inside the sphere collider
for i, node in ipairs(rope.Nodes) do
  if not node.isPinned then
    local dist = (node.position - spherePos).Magnitude
    assert(dist >= sphereRadius - 1e-3, string.format("Node %d penetrated sphere collider! Dist: %f, Radius: %f", i, dist, sphereRadius))
  end
end

-- Test 6: Ground Plane Collision (floorY)
local floorRope = VerletRope.new(Vector3.new(0, 10, 0), Vector3.new(10, 10, 0), {
  numSegments = 5,
  totalLength = 10,
  gravity = Vector3.new(0, -50, 0),
  floorY = 5.0,
})

for _ = 1, 30 do
  floorRope:Step(0.016)
end

for i, node in ipairs(floorRope.Nodes) do
  assert(node.position.Y >= 5.0 - 1e-4, string.format("Node %d fell below floor plane! Y: %f", i, node.position.Y))
end

-- Test 7: Tangents and Tension
local tangents = rope:GetTangents()
assert(#tangents == 11, "Must return tangents for all nodes")
assert(math.abs(tangents[1].Magnitude - 1.0) < 1e-3, "Tangent vector must be normalized unit vector")

local tension = rope:GetTension(1)
assert(tension >= 0, "Tension strain must be non-negative")

-- Test 8: Structural Tear / Rupture Threshold
local fragileRope = VerletRope.new(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0), {
  numSegments = 5,
  totalLength = 10,
  tearRatio = 1.5, -- Rupture if stretched 1.5x segment length
})

assert(fragileRope.IsTorn == false, "Rope should initially not be torn")
-- Manually yank anchor B far away
fragileRope:SetAnchorB(Vector3.new(100, 0, 0))
fragileRope:Step(0.016)
assert(fragileRope.IsTorn == true, "Rope should snap under excessive stress")
assert(fragileRope.TornIndex ~= nil, "Torn index must be recorded")

print("PASS: VerletRope tests (Initialization, Gravity, Relaxation, Winch, Colliders, Floor, Tangents, Tear) passed cleanly!")
