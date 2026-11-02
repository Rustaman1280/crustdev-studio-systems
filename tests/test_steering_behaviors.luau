local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local SteeringBehaviors = require("../src/ReplicatedStorage/AI/SteeringBehaviors")

-- Mock Agent factory
local function createAgent(pos: Vector3, vel: Vector3?, maxSpeed: number?, maxForce: number?): SteeringBehaviors.Agent
  return {
    position = pos,
    velocity = vel or Vector3.new(0, 0, 0),
    maxSpeed = maxSpeed or 20,
    maxForce = maxForce or 40,
    mass = 1.0,
    radius = 1.5,
  }
end

-- Test 1: Seek
local a1 = createAgent(Vector3.new(0, 0, 0))
local targetPos = Vector3.new(0, 0, 50)
local seekForce = SteeringBehaviors.Seek(a1, targetPos)

assert(seekForce.Z > 0, "Seek force should point towards positive Z")
assert(math.abs(seekForce.X) < 0.001, "Seek force X component should be negligible")
assert(seekForce.Magnitude <= a1.maxForce + 0.001, "Seek force must be clamped to maxForce")

-- At target: should return zero force
local seekAtTarget = SteeringBehaviors.Seek(a1, Vector3.new(0, 0, 0))
assert(seekAtTarget.Magnitude < 0.001, "Seek at exact target position should return zero force")

-- Test 2: Flee
local threatPos = Vector3.new(0, 0, 10)
local fleeForce = SteeringBehaviors.Flee(a1, threatPos, 30)

assert(fleeForce.Z < 0, "Flee force should steer away from threat in negative Z")
assert(fleeForce.Magnitude <= a1.maxForce + 0.001, "Flee force must be clamped to maxForce")

-- Threat outside panic distance
local farThreat = Vector3.new(0, 0, 100)
local fleeFar = SteeringBehaviors.Flee(a1, farThreat, 50)
assert(fleeFar.Magnitude < 0.001, "Threat beyond panic distance must return zero force")

-- Test 3: Arrive
local arriveTarget = Vector3.new(100, 0, 0)
local arriveFar = SteeringBehaviors.Arrive(a1, arriveTarget, 20, 0.5)
assert(arriveFar.X > 0, "Arrive from afar should steer towards target")
assert(arriveFar.Magnitude <= a1.maxForce + 0.001, "Arrive far must respect maxForce")

-- Near target (within slowing radius 20, at distance 5)
local aNear = createAgent(Vector3.new(95, 0, 0), Vector3.new(10, 0, 0))
local arriveNear = SteeringBehaviors.Arrive(aNear, arriveTarget, 20, 0.5)
assert(arriveNear.Magnitude > 0, "Arrive near must produce deceleration force")

-- Within arrival tolerance (at target)
local aAtTarget = createAgent(Vector3.new(99.9, 0, 0), Vector3.new(5, 0, 0))
local arriveStop = SteeringBehaviors.Arrive(aAtTarget, arriveTarget, 20, 0.5)
assert(arriveStop.X < 0, "Arrive within tolerance must counter forward velocity to stop")

-- Test 4: Pursue & Evade
local runner = {
  position = Vector3.new(0, 0, 40),
  velocity = Vector3.new(10, 0, 0), -- moving along +X
}
local chaser = createAgent(Vector3.new(0, 0, 0), Vector3.new(0, 0, 10))
local pursueForce = SteeringBehaviors.Pursue(chaser, runner)
assert(pursueForce.X > 0, "Pursue must anticipate target's +X motion and lead target")
assert(pursueForce.Z > 0, "Pursue must maintain forward closing component")

local evader = createAgent(Vector3.new(0, 0, 10), Vector3.new(0, 0, 0))
local evadeForce = SteeringBehaviors.Evade(evader, runner, 100)
assert(evadeForce.Magnitude > 0, "Evade must produce avoidance force")

-- Test 5: Wander
local wanderAgent = createAgent(Vector3.new(0, 0, 0), Vector3.new(0, 0, 5))
local wanderState: SteeringBehaviors.WanderState = {
  angle = 0,
  distance = 10,
  radius = 4,
  jitter = 1.0,
}
local wForce, nextAngle = SteeringBehaviors.Wander(wanderAgent, wanderState, 0.1, 0.8)
assert(wForce.Magnitude <= wanderAgent.maxForce + 0.001, "Wander force must be clamped")
assert(nextAngle ~= wanderState.angle, "Angle must be updated by jitter")

-- Test 6: Flocking (Separation, Alignment, Cohesion)
local centerBoid = createAgent(Vector3.new(10, 0, 10), Vector3.new(5, 0, 0))
local neighbors: { SteeringBehaviors.Agent } = {
  centerBoid,
  createAgent(Vector3.new(11, 0, 10), Vector3.new(6, 0, 0)), -- close neighbor to the right
  createAgent(Vector3.new(10, 0, 12), Vector3.new(4, 0, 1)), -- close neighbor ahead
  createAgent(Vector3.new(30, 0, 30), Vector3.new(0, 0, 0)), -- far neighbor
}

-- Separation: should push away from close neighbor (11, 0, 10) in -X direction
local sepForce = SteeringBehaviors.Separation(centerBoid, neighbors, 5.0)
assert(sepForce.X < 0, "Separation must repel away from neighbor on the right")

-- Alignment: should align with general forward velocity (+X)
local aliForce = SteeringBehaviors.Alignment(centerBoid, neighbors, 10.0)
assert(aliForce.Magnitude <= centerBoid.maxForce + 0.001, "Alignment force must be clamped")

-- Cohesion: should steer towards center of mass of local flock
local cohForce = SteeringBehaviors.Cohesion(centerBoid, neighbors, 15.0)
assert(cohForce.Magnitude > 0, "Cohesion must steer towards neighbor group")

-- Composite Flocking
local flockConfig: SteeringBehaviors.FlockingConfig = {
  separationRadius = 5.0,
  neighborRadius = 15.0,
  separationWeight = 1.5,
  alignmentWeight = 1.0,
  cohesionWeight = 1.0,
}
local flockForce = SteeringBehaviors.ComputeFlock(centerBoid, neighbors, flockConfig)
assert(flockForce.Magnitude <= centerBoid.maxForce + 0.001, "Flock composite force must be clamped to maxForce")

-- Test 7: Obstacle Avoidance
local obsAgent = createAgent(Vector3.new(0, 0, 0), Vector3.new(0, 0, 15))
local obstacles: { SteeringBehaviors.Obstacle } = {
  { position = Vector3.new(0.5, 0, 20), radius = 3.0 }, -- directly in front
  { position = Vector3.new(0, 0, -10), radius = 3.0 },  -- behind agent
}

local avoidForce = SteeringBehaviors.AvoidObstacles(obsAgent, obstacles, 30, 1.5)
assert(avoidForce.Magnitude > 0, "Obstacle directly ahead must trigger avoidance force")
assert(avoidForce.X < 0, "Avoidance should deflect away from obstacle slightly offset to the right")

-- Obstacle behind agent should be ignored
local clearObstacles: { SteeringBehaviors.Obstacle } = {
  { position = Vector3.new(0, 0, -20), radius = 3.0 },
}
local noAvoid = SteeringBehaviors.AvoidObstacles(obsAgent, clearObstacles, 30, 1.5)
assert(noAvoid.Magnitude < 0.001, "Obstacle behind agent must produce zero avoidance force")

-- Test 8: Force Blending & Integration
local force1 = { force = Vector3.new(10, 0, 0), weight = 1.0 }
local force2 = { force = Vector3.new(0, 0, 10), weight = 1.0 }
local blended = SteeringBehaviors.Blend(a1, { force1, force2 }, 15.0)
assert(blended.Magnitude <= 15.001, "Blended force must not exceed custom cap")

-- Kinematic Integration
local intAgent = createAgent(Vector3.new(0, 0, 0), Vector3.new(0, 0, 0))
local newPos, newVel = SteeringBehaviors.Integrate(intAgent, Vector3.new(0, 0, 20), 0.5)
assert(newVel.Z > 0, "Velocity should increase along Z")
assert(newPos.Z > 0, "Position should advance along Z")

print("PASS: SteeringBehaviors tests (Seek, Flee, Arrive, Pursue, Evade, Wander, Separation, Alignment, Cohesion, ObstacleAvoidance, Blend, Integrate) passed cleanly!")
