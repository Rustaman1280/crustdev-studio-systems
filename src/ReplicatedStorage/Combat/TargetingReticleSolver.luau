--!strict
--[[
  TargetingReticleSolver.luau
  crustdev studio systems - ReplicatedStorage/Combat/TargetingReticleSolver

  Ballistic lead calculator, projectile trajectory intercept solver,
  conical target acquisition, aim assist magnetism, and crosshair friction matrix.

  Features:
  - First-order analytical ballistic lead intercept solver for moving targets.
  - Parabolic ballistic arc compensation under constant gravity fields with iterative convergence.
  - Conical target acquisition with angular aperture thresholds and composite distance/priority weighting.
  - Crosshair friction mechanics: deceleration factor when reticle sweeps over candidate hitboxes.
  - Aim assist magnetism: vector pulling towards target centroid/critical zones with cubic smoothstep falloff.
  - Flight time estimation and hit confidence scoring based on target acceleration and projectile transit time.
  - Zero Em-Dash Policy compliant.
  - Pure Luau / Lune compatible with zero external dependencies.
]]

local Vector3 = _G.Vector3 or Vector3

local EPSILON = 1e-6

export type TargetEntity = {
  Id: string,
  Position: Vector3,
  Velocity: Vector3,
  Acceleration: Vector3?,
  Radius: number,
  Priority: number?,
  Tags: { [string]: boolean }?,
}

export type ProjectileParams = {
  Speed: number,
  Gravity: Vector3?,
  MaxDistance: number?,
}

export type AimAssistConfig = {
  MaxAngleDeg: number,
  MaxDistance: number,
  FrictionRadiusDeg: number,
  FrictionMultiplier: number,
  MagnetismRadiusDeg: number,
  MagnetismStrength: number,
  AngleWeight: number,
  DistanceWeight: number,
  PriorityWeight: number,
}

export type LeadSolution = {
  CanHit: boolean,
  AimDirection: Vector3,
  InterceptPoint: Vector3,
  TimeToImpact: number,
  ProjectileVelocity: Vector3,
  Confidence: number,
}

export type AcquiredTarget = {
  Target: TargetEntity,
  Score: number,
  AngleDeg: number,
  Distance: number,
  ReticleOffset: Vector3,
}

export type AimAssistResult = {
  ModifiedLookVector: Vector3,
  FrictionApplied: boolean,
  MagnetismApplied: boolean,
  FrictionDamping: number,
  MagnetismPull: Vector3,
}

local TargetingReticleSolver = {}
TargetingReticleSolver.__index = TargetingReticleSolver

local DefaultAimConfig: AimAssistConfig = {
  MaxAngleDeg = 25.0,
  MaxDistance = 500.0,
  FrictionRadiusDeg = 12.0,
  FrictionMultiplier = 0.40,
  MagnetismRadiusDeg = 6.0,
  MagnetismStrength = 0.50,
  AngleWeight = 0.50,
  DistanceWeight = 0.25,
  PriorityWeight = 0.25,
}

function TargetingReticleSolver.GetDefaultConfig(): AimAssistConfig
  local copy: AimAssistConfig = {
    MaxAngleDeg = DefaultAimConfig.MaxAngleDeg,
    MaxDistance = DefaultAimConfig.MaxDistance,
    FrictionRadiusDeg = DefaultAimConfig.FrictionRadiusDeg,
    FrictionMultiplier = DefaultAimConfig.FrictionMultiplier,
    MagnetismRadiusDeg = DefaultAimConfig.MagnetismRadiusDeg,
    MagnetismStrength = DefaultAimConfig.MagnetismStrength,
    AngleWeight = DefaultAimConfig.AngleWeight,
    DistanceWeight = DefaultAimConfig.DistanceWeight,
    PriorityWeight = DefaultAimConfig.PriorityWeight,
  }
  return copy
end

-- Solves quadratic equation a*t^2 + b*t + c = 0, returning smallest positive real root t > 0
local function solveSmallestPositiveQuadratic(a: number, b: number, c: number): number?
  if math.abs(a) < EPSILON then
    if math.abs(b) < EPSILON then
      return nil
    end
    local t = -c / b
    return if t > EPSILON then t else nil
  end

  local disc = b * b - 4 * a * c
  if disc < 0 then
    return nil
  end

  local sqrtDisc = math.sqrt(disc)
  local t1 = (-b - sqrtDisc) / (2 * a)
  local t2 = (-b + sqrtDisc) / (2 * a)

  if t1 > EPSILON and t2 > EPSILON then
    return math.min(t1, t2)
  elseif t1 > EPSILON then
    return t1
  elseif t2 > EPSILON then
    return t2
  end

  return nil
end

-- Smoothstep function: 3x^2 - 2x^3 clamped to [0, 1]
local function smoothstep(edge0: number, edge1: number, x: number): number
  local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
  return t * t * (3 - 2 * t)
end

-- Solves ballistic lead intercept for projectile targeting moving entity
function TargetingReticleSolver.SolveBallisticLead(
  origin: Vector3,
  targetPos: Vector3,
  targetVel: Vector3,
  projParams: ProjectileParams
): LeadSolution
  local speed = projParams.Speed
  if speed <= EPSILON then
    return {
      CanHit = false,
      AimDirection = Vector3.new(0, 0, -1),
      InterceptPoint = targetPos,
      TimeToImpact = 0,
      ProjectileVelocity = Vector3.new(0, 0, 0),
      Confidence = 0,
    }
  end

  local gravity = projParams.Gravity or Vector3.new(0, 0, 0)
  local hasGravity = gravity:Dot(gravity) > EPSILON
  local disp = targetPos - origin
  local dist = disp.Magnitude

  if dist < EPSILON then
    return {
      CanHit = true,
      AimDirection = Vector3.new(0, 0, -1),
      InterceptPoint = targetPos,
      TimeToImpact = 0,
      ProjectileVelocity = Vector3.new(0, 0, -speed),
      Confidence = 1.0,
    }
  end

  -- Initial linear intercept solution: |disp + targetVel * t|^2 = (speed * t)^2
  local a = targetVel:Dot(targetVel) - (speed * speed)
  local b = 2 * disp:Dot(targetVel)
  local c = disp:Dot(disp)

  local t = solveSmallestPositiveQuadratic(a, b, c)

  if not t then
    -- Cannot intercept with projectile speed
    return {
      CanHit = false,
      AimDirection = disp.Unit,
      InterceptPoint = targetPos,
      TimeToImpact = 0,
      ProjectileVelocity = disp.Unit * speed,
      Confidence = 0,
    }
  end

  -- If gravity is present, run iterative convergence to compute launch vector
  local currentT = t
  if hasGravity then
    for _ = 1, 4 do
      local predictedTarget = targetPos + targetVel * currentT
      -- Projectile displacement with launch velocity V0 and gravity:
      -- P(t) = origin + V0 * t + 0.5 * gravity * t^2
      -- Setting P(t) = predictedTarget gives:
      -- V0 * t = predictedTarget - origin - 0.5 * gravity * t^2
      local requiredTravel = predictedTarget - origin - (0.5 * gravity * currentT * currentT)
      local reqDist = requiredTravel.Magnitude
      local newT = reqDist / speed
      if math.abs(newT - currentT) < 0.001 then
        currentT = newT
        break
      end
      currentT = newT
    end
  end

  if projParams.MaxDistance and (currentT * speed > projParams.MaxDistance) then
    return {
      CanHit = false,
      AimDirection = disp.Unit,
      InterceptPoint = targetPos + targetVel * currentT,
      TimeToImpact = currentT,
      ProjectileVelocity = disp.Unit * speed,
      Confidence = 0,
    }
  end

  local interceptPoint = targetPos + targetVel * currentT
  local launchOffset = interceptPoint - origin - (0.5 * gravity * currentT * currentT)
  local aimDir = if launchOffset.Magnitude > EPSILON then launchOffset.Unit else disp.Unit
  local launchVel = aimDir * speed

  -- Confidence decays with distance and flight time
  local timePenalty = math.clamp(1.0 - (currentT / 3.0), 0.1, 1.0)
  local speedRatio = math.clamp(speed / (targetVel.Magnitude + 1.0), 0.2, 1.0)
  local confidence = timePenalty * speedRatio

  return {
    CanHit = true,
    AimDirection = aimDir,
    InterceptPoint = interceptPoint,
    TimeToImpact = currentT,
    ProjectileVelocity = launchVel,
    Confidence = confidence,
  }
end

-- Evaluates candidate targets and returns best target inside aim assist cone
function TargetingReticleSolver.AcquireBestTarget(
  cameraPos: Vector3,
  cameraLook: Vector3,
  targets: { TargetEntity },
  configOpt: AimAssistConfig?
): AcquiredTarget?
  local config = configOpt or DefaultAimConfig
  local lookDir = cameraLook.Unit
  local bestTarget: AcquiredTarget? = nil
  local bestScore = -math.huge

  for _, target in ipairs(targets) do
    local toTarget = target.Position - cameraPos
    local dist = toTarget.Magnitude

    if dist > EPSILON and dist <= config.MaxDistance then
      local toTargetDir = toTarget.Unit
      local dot = math.clamp(lookDir:Dot(toTargetDir), -1, 1)
      local angleRad = math.acos(dot)
      local angleDeg = math.deg(angleRad)

      if angleDeg <= config.MaxAngleDeg then
        local angleNorm = 1.0 - (angleDeg / config.MaxAngleDeg)
        local distNorm = 1.0 - (dist / config.MaxDistance)
        local priority = target.Priority or 1.0
        local priorityNorm = math.clamp(priority / 5.0, 0, 1)

        local compositeScore = (angleNorm * config.AngleWeight)
          + (distNorm * config.DistanceWeight)
          + (priorityNorm * config.PriorityWeight)

        if compositeScore > bestScore then
          bestScore = compositeScore
          -- Project displacement onto camera view plane (plane perpendicular to cameraLook)
          local projOnLook = lookDir * lookDir:Dot(toTarget)
          local reticleOffset = toTarget - projOnLook

          bestTarget = {
            Target = target,
            Score = compositeScore,
            AngleDeg = angleDeg,
            Distance = dist,
            ReticleOffset = reticleOffset,
          }
        end
      end
    end
  end

  return bestTarget
end

-- Calculates aim assist modifiers: friction damping and magnetic pull towards target
function TargetingReticleSolver.CalculateAimAssist(
  cameraPos: Vector3,
  cameraLook: Vector3,
  target: TargetEntity,
  configOpt: AimAssistConfig?
): AimAssistResult
  local config = configOpt or DefaultAimConfig
  local lookDir = cameraLook.Unit
  local toTarget = target.Position - cameraPos
  local dist = toTarget.Magnitude

  if dist <= EPSILON or dist > config.MaxDistance then
    return {
      ModifiedLookVector = lookDir,
      FrictionApplied = false,
      MagnetismApplied = false,
      FrictionDamping = 1.0,
      MagnetismPull = Vector3.new(0, 0, 0),
    }
  end

  local toTargetDir = toTarget.Unit
  local dot = math.clamp(lookDir:Dot(toTargetDir), -1, 1)
  local angleRad = math.acos(dot)
  local angleDeg = math.deg(angleRad)

  local frictionApplied = false
  local frictionDamping = 1.0

  if angleDeg <= config.FrictionRadiusDeg then
    frictionApplied = true
    -- Closer to center of target yields stronger deceleration
    local proximity = 1.0 - (angleDeg / config.FrictionRadiusDeg)
    local ease = smoothstep(0, 1, proximity)
    -- Multiplier scales from 1.0 (no effect at boundary) down to FrictionMultiplier (at center)
    frictionDamping = 1.0 - (ease * (1.0 - config.FrictionMultiplier))
  end

  local magnetismApplied = false
  local magnetismPull = Vector3.new(0, 0, 0)
  local modifiedLook = lookDir

  if angleDeg <= config.MagnetismRadiusDeg then
    magnetismApplied = true
    local proximity = 1.0 - (angleDeg / config.MagnetismRadiusDeg)
    local ease = smoothstep(0, 1, proximity)
    local pullFactor = ease * config.MagnetismStrength

    -- Spherically interpolate or blend look direction towards target direction
    modifiedLook = (lookDir * (1.0 - pullFactor) + toTargetDir * pullFactor).Unit
    magnetismPull = modifiedLook - lookDir
  end

  return {
    ModifiedLookVector = modifiedLook,
    FrictionApplied = frictionApplied,
    MagnetismApplied = magnetismApplied,
    FrictionDamping = frictionDamping,
    MagnetismPull = magnetismPull,
  }
end

-- Evaluates predicted hit probability taking target evasion into account
function TargetingReticleSolver.CalculateHitProbability(
  target: TargetEntity,
  projSpeed: number,
  timeToImpact: number
): number
  if timeToImpact <= EPSILON then
    return 1.0
  end

  local accelMag = if target.Acceleration then target.Acceleration.Magnitude else 0.0
  -- Expected evasive offset over flight time: 0.5 * accel * t^2
  local evasiveOffset = 0.5 * accelMag * timeToImpact * timeToImpact
  local targetRadius = math.max(target.Radius, 0.5)

  -- Ratio of hitbox radius to evasion zone
  local coverage = targetRadius / (targetRadius + evasiveOffset)
  local distancePenalty = math.clamp(1.0 - (timeToImpact / 4.0), 0.1, 1.0)

  return math.clamp(coverage * distancePenalty, 0.05, 1.0)
end

return TargetingReticleSolver