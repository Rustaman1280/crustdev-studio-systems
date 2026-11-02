--!strict
--[[
  SteeringBehaviors.luau
  crustdev studio systems - ReplicatedStorage/AI/SteeringBehaviors

  Production-grade autonomous agent steering pipeline based on Craig Reynolds' algorithms:
  - Core single-agent behaviors: Seek, Flee, Arrive (smooth slowing ramp), Pursue, Evade
  - Organic wandering with circular projection and angular jitter
  - Multi-agent swarm boids: Separation, Alignment, Cohesion, and unified Flocking
  - Obstacle avoidance with dynamic forward feeler projection and lateral avoidance vectors
  - Prioritized force blending, force truncation, and kinematic Euler integration
  - Fully deterministic: zero allocation in hot math loops where possible

  Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local ZERO_VECTOR = Vector3.new(0, 0, 0)

export type Agent = {
  position: Vector3,
  velocity: Vector3,
  maxSpeed: number,
  maxForce: number,
  mass: number?,
  radius: number?,
}

export type Target = {
  position: Vector3,
  velocity: Vector3?,
}

export type Obstacle = {
  position: Vector3,
  radius: number,
}

export type WeightedForce = {
  force: Vector3,
  weight: number,
}

export type WanderState = {
  angle: number,
  distance: number,
  radius: number,
  jitter: number,
}

export type FlockingConfig = {
  separationRadius: number,
  neighborRadius: number,
  separationWeight: number,
  alignmentWeight: number,
  cohesionWeight: number,
}

local SteeringBehaviors = {}

-- Utility: Clamp vector magnitude to maxLen without allocation if already below
function SteeringBehaviors.Truncate(vec: Vector3, maxLen: number): Vector3
  local mag = vec.Magnitude
  if mag > maxLen and mag > 0.00001 then
    return (vec / mag) * maxLen
  end
  return vec
end

-- Utility: Safe heading vector (falls back to unit Z if velocity is near zero)
function SteeringBehaviors.GetHeading(velocity: Vector3, fallbackHeading: Vector3?): Vector3
  local mag = velocity.Magnitude
  if mag > 0.0001 then
    return velocity / mag
  end
  return fallbackHeading or Vector3.new(0, 0, 1)
end

-- Seek: Direct pursuit vector towards target position
function SteeringBehaviors.Seek(agent: Agent, targetPos: Vector3): Vector3
  local diff = targetPos - agent.position
  local dist = diff.Magnitude
  if dist < 0.0001 then
    return ZERO_VECTOR
  end

  local desiredVelocity = (diff / dist) * agent.maxSpeed
  local steering = desiredVelocity - agent.velocity
  return SteeringBehaviors.Truncate(steering, agent.maxForce)
end

-- Flee: Repulsion vector directly away from threat position (optional panic distance)
function SteeringBehaviors.Flee(agent: Agent, threatPos: Vector3, panicDistance: number?): Vector3
  local diff = agent.position - threatPos
  local dist = diff.Magnitude

  if panicDistance and dist > panicDistance then
    return ZERO_VECTOR
  end

  if dist < 0.0001 then
    -- If sitting right on threat, flee in random or forward direction
    return Vector3.new(1, 0, 0) * agent.maxForce
  end

  local desiredVelocity = (diff / dist) * agent.maxSpeed
  local steering = desiredVelocity - agent.velocity
  return SteeringBehaviors.Truncate(steering, agent.maxForce)
end

-- Arrive: Smooth deceleration ramp approaching target without overshoot
function SteeringBehaviors.Arrive(
  agent: Agent,
  targetPos: Vector3,
  slowingRadius: number?,
  arrivalTolerance: number?
): Vector3
  local diff = targetPos - agent.position
  local dist = diff.Magnitude
  local tolerance = arrivalTolerance or 0.1
  local slowRadius = slowingRadius or 10.0

  if dist <= tolerance then
    -- Reached target: counter current velocity to bring agent to a halt
    return SteeringBehaviors.Truncate(-agent.velocity, agent.maxForce)
  end

  local speed: number
  if dist < slowRadius then
    speed = agent.maxSpeed * (dist / slowRadius)
  else
    speed = agent.maxSpeed
  end

  local desiredVelocity = (diff / dist) * speed
  local steering = desiredVelocity - agent.velocity
  return SteeringBehaviors.Truncate(steering, agent.maxForce)
end

-- Pursue: Predictive interception based on target relative distance and velocity
function SteeringBehaviors.Pursue(agent: Agent, target: Target): Vector3
  local toTarget = target.position - agent.position
  local dist = toTarget.Magnitude
  local targetVel = target.velocity or ZERO_VECTOR

  -- Lookahead time directly proportional to distance, inversely to max speed
  local lookahead = dist / math.max(agent.maxSpeed, 0.001)
  local predictedPosition = target.position + targetVel * lookahead

  return SteeringBehaviors.Seek(agent, predictedPosition)
end

-- Evade: Predictive evasion based on anticipated threat movement
function SteeringBehaviors.Evade(agent: Agent, threat: Target, panicDistance: number?): Vector3
  local toThreat = threat.position - agent.position
  local dist = toThreat.Magnitude

  if panicDistance and dist > panicDistance then
    return ZERO_VECTOR
  end

  local threatVel = threat.velocity or ZERO_VECTOR
  local lookahead = dist / math.max(agent.maxSpeed, 0.001)
  local predictedPosition = threat.position + threatVel * lookahead

  return SteeringBehaviors.Flee(agent, predictedPosition, panicDistance)
end

-- Wander: Organic roaming using projected circle with per-frame constrained jitter
function SteeringBehaviors.Wander(
  agent: Agent,
  state: WanderState,
  dt: number?,
  stepRandom: number?
): (Vector3, number)
  local timeStep = dt or 1.0
  local randVal = stepRandom or math.random()

  -- Apply angular displacement step [-jitter/2, +jitter/2]
  local angleDelta = (randVal - 0.5) * state.jitter * timeStep
  local newAngle = (state.angle + angleDelta) % (math.pi * 2)

  local heading = SteeringBehaviors.GetHeading(agent.velocity)
  local circleCenter = agent.position + heading * state.distance

  -- Calculate displacement on XZ plane relative to heading
  local right = Vector3.new(-heading.Z, 0, heading.X)
  if right.Magnitude < 0.001 then
    right = Vector3.new(1, 0, 0)
  else
    right = right.Unit
  end

  local displacement = (heading * math.cos(newAngle) + right * math.sin(newAngle)) * state.radius
  local targetPoint = circleCenter + displacement

  local seekForce = SteeringBehaviors.Seek(agent, targetPoint)
  return seekForce, newAngle
end

-- Separation: Repulsion force inversely proportional to distance from neighbors
function SteeringBehaviors.Separation(
  agent: Agent,
  neighbors: { Agent },
  separationRadius: number
): Vector3
  local steering = ZERO_VECTOR
  local count = 0

  for _, neighbor in ipairs(neighbors) do
    if neighbor ~= agent then
      local diff = agent.position - neighbor.position
      local dist = diff.Magnitude

      if dist > 0.0001 and dist < separationRadius then
        -- Repulsive force scaled inversely by distance fraction
        local normalizedDiff = diff / dist
        local weight = (separationRadius - dist) / separationRadius
        steering = steering + (normalizedDiff * weight)
        count += 1
      end
    end
  end

  if count > 0 then
    local desired = (steering / count).Unit * agent.maxSpeed
    return SteeringBehaviors.Truncate(desired - agent.velocity, agent.maxForce)
  end

  return ZERO_VECTOR
end

-- Alignment: Velocity matching with nearby cohort heading
function SteeringBehaviors.Alignment(
  agent: Agent,
  neighbors: { Agent },
  neighborRadius: number
): Vector3
  local avgVelocity = ZERO_VECTOR
  local count = 0

  for _, neighbor in ipairs(neighbors) do
    if neighbor ~= agent then
      local dist = (agent.position - neighbor.position).Magnitude
      if dist < neighborRadius then
        avgVelocity = avgVelocity + neighbor.velocity
        count += 1
      end
    end
  end

  if count > 0 then
    avgVelocity = avgVelocity / count
    if avgVelocity.Magnitude > 0.0001 then
      local desired = avgVelocity.Unit * agent.maxSpeed
      return SteeringBehaviors.Truncate(desired - agent.velocity, agent.maxForce)
    end
  end

  return ZERO_VECTOR
end

-- Cohesion: Steering force towards flock center-of-mass
function SteeringBehaviors.Cohesion(
  agent: Agent,
  neighbors: { Agent },
  neighborRadius: number
): Vector3
  local centerOfMass = ZERO_VECTOR
  local count = 0

  for _, neighbor in ipairs(neighbors) do
    if neighbor ~= agent then
      local dist = (agent.position - neighbor.position).Magnitude
      if dist < neighborRadius then
        centerOfMass = centerOfMass + neighbor.position
        count += 1
      end
    end
  end

  if count > 0 then
    centerOfMass = centerOfMass / count
    return SteeringBehaviors.Seek(agent, centerOfMass)
  end

  return ZERO_VECTOR
end

-- ComputeFlock: Unified Boids flocking composite
function SteeringBehaviors.ComputeFlock(
  agent: Agent,
  neighbors: { Agent },
  config: FlockingConfig
): Vector3
  local sep = SteeringBehaviors.Separation(agent, neighbors, config.separationRadius) * config.separationWeight
  local ali = SteeringBehaviors.Alignment(agent, neighbors, config.neighborRadius) * config.alignmentWeight
  local coh = SteeringBehaviors.Cohesion(agent, neighbors, config.neighborRadius) * config.cohesionWeight

  return SteeringBehaviors.Truncate(sep + ali + coh, agent.maxForce)
end

-- AvoidObstacles: Forward feeler ray intersection and lateral deflection
function SteeringBehaviors.AvoidObstacles(
  agent: Agent,
  obstacles: { Obstacle },
  feelerLength: number?,
  agentRadius: number?
): Vector3
  local length = feelerLength or (agent.velocity.Magnitude * 1.5 + 5.0)
  local radius = agentRadius or agent.radius or 1.0
  local heading = SteeringBehaviors.GetHeading(agent.velocity)
  local feelerEnd = agent.position + heading * length

  local mostThreatening: Obstacle? = nil
  local closestDist = math.huge
  local closestLocalPos = ZERO_VECTOR

  for _, obs in ipairs(obstacles) do
    -- Vector from agent to obstacle
    local toObs = obs.position - agent.position
    local forwardDist = toObs:Dot(heading)

    -- Obstacle must be in front of agent and within feeler range
    if forwardDist > 0 and forwardDist < length + obs.radius then
      -- Projected point along feeler line
      local projectedPoint = agent.position + heading * forwardDist
      local lateralDist = (obs.position - projectedPoint).Magnitude
      local expandedRadius = obs.radius + radius

      if lateralDist < expandedRadius then
        if forwardDist < closestDist then
          closestDist = forwardDist
          mostThreatening = obs
          closestLocalPos = obs.position - projectedPoint
        end
      end
    end
  end

  if mostThreatening then
    -- Compute lateral deflection force away from obstacle center
    local lateralDir: Vector3
    if closestLocalPos.Magnitude > 0.0001 then
      lateralDir = -closestLocalPos.Unit
    else
      -- Directly collinear: push laterally perpendicular to heading
      lateralDir = Vector3.new(-heading.Z, 0, heading.X).Unit
    end

    -- Force is stronger the closer the obstacle is
    local proximityFactor = 1.0 - (closestDist / (length + mostThreatening.radius))
    local avoidanceForce = lateralDir * (agent.maxForce * math.clamp(proximityFactor, 0.2, 1.0))
    return SteeringBehaviors.Truncate(avoidanceForce, agent.maxForce)
  end

  return ZERO_VECTOR
end

-- Blend: Truncated accumulation of weighted steering forces
function SteeringBehaviors.Blend(
  agent: Agent,
  weightedForces: { WeightedForce },
  customMaxForce: number?
): Vector3
  local maxF = customMaxForce or agent.maxForce
  local totalForce = ZERO_VECTOR

  for _, item in ipairs(weightedForces) do
    local weighted = item.force * item.weight
    local remaining = maxF - totalForce.Magnitude

    if remaining <= 0.0001 then
      break
    end

    if weighted.Magnitude > remaining then
      totalForce = totalForce + weighted.Unit * remaining
      break
    else
      totalForce = totalForce + weighted
    end
  end

  return totalForce
end

-- Integrate: Semi-implicit Euler kinematic step for updating agent state
function SteeringBehaviors.Integrate(
  agent: Agent,
  steeringForce: Vector3,
  dt: number
): (Vector3, Vector3)
  local mass = math.max(agent.mass or 1.0, 0.001)
  local acceleration = steeringForce / mass
  local newVelocity = SteeringBehaviors.Truncate(agent.velocity + acceleration * dt, agent.maxSpeed)
  local newPosition = agent.position + newVelocity * dt

  return newPosition, newVelocity
end

return SteeringBehaviors