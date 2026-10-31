--!strict
--[[
  ProjectileSolver.luau
  Deterministic sub-step ballistic trajectory simulator and predictive targeting solver.
  Features:
    - Continuous sub-stepping to prevent high-velocity tunneling through thin obstacles.
    - Drag physics and customizable gravity vectors.
    - Multi-phase collision resolution: penetration/pierce tracking, specular bounce reflection.
    - Closed-form analytical ballistic launch velocity solver for high/low targeting arcs.
  Part of crustdev studio game systems (Aetheria: Fractured Realms & Neon Velocity).
]]

export type ProjectileConfig = {
  Mass: number?,              -- Mass in kg (default 1.0)
  Drag: number?,              -- Velocity damping coefficient (default 0.02)
  Gravity: Vector3?,          -- Acceleration vector (default Vector3.new(0, -196.2, 0))
  MaxLifeTime: number?,       -- Despawn TTL in seconds (default 10.0)
  MaxPierces: number?,        -- Penetration count before stopping (default 0)
  Restitution: number?,       -- Bounciness [0.0 - 1.0] (default 0.0)
  SubStepDistance: number?,   -- Max segment length per raycast step (default 2.0 studs)
}

export type ProjectileState = {
  Position: Vector3,
  Velocity: Vector3,
  ElapsedTime: number,
  PierceCount: number,
  BounceCount: number,
  IsAlive: boolean,
}

export type RaycastHit = {
  Instance: any,
  Position: Vector3,
  Normal: Vector3,
  Material: any?,
  Distance: number,
}

export type RaycastQueryFn = (origin: Vector3, direction: Vector3) -> RaycastHit?

export type StepEventType = "Hit" | "Pierce" | "Bounce" | "Expired"

export type StepEvent = {
  Type: StepEventType,
  Position: Vector3,
  Normal: Vector3?,
  Instance: any?,
  SubStep: number,
}

export type StepResult = {
  Events: { StepEvent },
  FinalState: ProjectileState,
}

local Vector3 = rawget(_G, "Vector3") or (Vector3 :: any)

local function getDefaultGravity(): Vector3
  local v3 = rawget(_G, "Vector3") or (Vector3 :: any)
  return v3.new(0, -196.2, 0)
end

local DEFAULT_DRAG = 0.02
local DEFAULT_TTL = 10.0
local DEFAULT_SUBSTEP_DIST = 2.0

local ProjectileSolver = {}

-- Create a fresh projectile state representation
function ProjectileSolver.create(
  origin: Vector3,
  initialVelocity: Vector3
): ProjectileState
  return {
    Position = origin,
    Velocity = initialVelocity,
    ElapsedTime = 0,
    PierceCount = 0,
    BounceCount = 0,
    IsAlive = true,
  }
end

-- Simulate forward by dt seconds with sub-step raycasting
function ProjectileSolver.step(
  state: ProjectileState,
  config: ProjectileConfig,
  dt: number,
  raycastFn: RaycastQueryFn?
): StepResult
  local events: { StepEvent } = {}

  if not state.IsAlive or dt <= 0 then
    return {
      Events = events,
      FinalState = state,
    }
  end

  local gravity = config.Gravity or getDefaultGravity()
  local drag = config.Drag or DEFAULT_DRAG
  local maxLifeTime = config.MaxLifeTime or DEFAULT_TTL
  local maxPierces = config.MaxPierces or 0
  local restitution = config.Restitution or 0.0
  local subStepDist = config.SubStepDistance or DEFAULT_SUBSTEP_DIST

  -- Estimate total displacement to determine sub-step count
  local initialSpeed = state.Velocity.Magnitude
  local estimatedDist = initialSpeed * dt
  local subSteps = math.clamp(math.ceil(estimatedDist / math.max(0.5, subStepDist)), 1, 32)
  local subDt = dt / subSteps

  for step = 1, subSteps do
    if not state.IsAlive then
      break
    end

    -- Drag and gravity acceleration integration (Semi-implicit Euler / Verlet-lite)
    local dragForce = -state.Velocity * drag
    local totalAccel = gravity + dragForce
    local newVelocity = state.Velocity + totalAccel * subDt
    local displacement = (state.Velocity + newVelocity) * 0.5 * subDt
    local nextPosition = state.Position + displacement

    if raycastFn and displacement.Magnitude > 0.001 then
      local hit = raycastFn(state.Position, displacement)
      if hit then
        if state.PierceCount < maxPierces then
          -- Pierce through object
          state.PierceCount += 1
          table.insert(events, {
            Type = "Pierce",
            Position = hit.Position,
            Normal = hit.Normal,
            Instance = hit.Instance,
            SubStep = step,
          })
          -- Attenuate velocity slightly and advance slightly beyond hit point
          state.Velocity = newVelocity * 0.85
          state.Position = hit.Position + displacement.Unit * 0.05
        elseif restitution > 0.0 then
          -- Specular bounce reflection: normal restitution damping with tangential momentum preservation
          state.BounceCount += 1
          local normal = hit.Normal.Unit
          local normalVelocity = newVelocity:Dot(normal) * normal
          local tangentialVelocity = newVelocity - normalVelocity
          local reflectedVelocity = tangentialVelocity - normalVelocity * restitution
          state.Velocity = reflectedVelocity
          state.Position = hit.Position + normal * 0.05

          table.insert(events, {
            Type = "Bounce",
            Position = hit.Position,
            Normal = hit.Normal,
            Instance = hit.Instance,
            SubStep = step,
          })
        else
          -- Terminal impact
          state.IsAlive = false
          state.Position = hit.Position
          state.Velocity = Vector3.zero

          table.insert(events, {
            Type = "Hit",
            Position = hit.Position,
            Normal = hit.Normal,
            Instance = hit.Instance,
            SubStep = step,
          })
          break
        end
      else
        state.Position = nextPosition
        state.Velocity = newVelocity
      end
    else
      state.Position = nextPosition
      state.Velocity = newVelocity
    end
  end

  -- Check lifetime expiration
  state.ElapsedTime += dt
  if state.ElapsedTime >= maxLifeTime and state.IsAlive then
    state.IsAlive = false
    table.insert(events, {
      Type = "Expired",
      Position = state.Position,
      Normal = nil,
      Instance = nil,
      SubStep = subSteps,
    })
  end

  return {
    Events = events,
    FinalState = state,
  }
end

-- Analytical closed-form ballistic trajectory launch solver.
-- Computes the launch velocity vector required to hit targetPos from origin at launchSpeed under gravity.
-- Returns nil if target is mathematically out of range at the specified speed.
function ProjectileSolver.solveLaunchVelocity(
  origin: Vector3,
  targetPos: Vector3,
  launchSpeed: number,
  gravityMag: number?,
  preferHighArc: boolean?
): Vector3?
  local diff = targetPos - origin
  local diffHoriz = Vector3.new(diff.X, 0, diff.Z)
  local x = diffHoriz.Magnitude
  local y = diff.Y
  local g = math.abs(gravityMag or 196.2)
  local v = launchSpeed

  if v <= 0 then
    return nil
  end

  -- Target is directly above or below
  if x < 0.001 then
    if y > 0 then
      local peakHeight = (v * v) / (2 * g)
      if peakHeight >= y then
        return Vector3.new(0, v, 0)
      end
    else
      return Vector3.new(0, -v, 0)
    end
    return nil
  end

  -- Closed-form ballistic range equation:
  -- v^4 - g*(g*x^2 + 2*y*v^2)
  local v2 = v * v
  local v4 = v2 * v2
  local discriminant = v4 - g * (g * x * x + 2 * y * v2)

  if discriminant < 0 then
    -- Out of maximum ballistic range
    return nil
  end

  local sqrtDisc = math.sqrt(discriminant)
  local tanTheta: number

  if preferHighArc == true then
    tanTheta = (v2 + sqrtDisc) / (g * x)
  else
    tanTheta = (v2 - sqrtDisc) / (g * x)
  end

  local theta = math.atan(tanTheta)
  local cosTheta = math.cos(theta)
  local sinTheta = math.sin(theta)

  local horizDir = diffHoriz.Unit
  local horizVel = horizDir * (v * cosTheta)
  local vertVel = Vector3.new(0, v * sinTheta, 0)

  return horizVel + vertVel
end

-- Fast estimation of flight time ignoring drag
function ProjectileSolver.estimateTimeToTarget(
  origin: Vector3,
  targetPos: Vector3,
  launchSpeed: number
): number
  if launchSpeed <= 0 then
    return 0
  end
  local dist = (targetPos - origin).Magnitude
  return dist / launchSpeed
end

return ProjectileSolver
