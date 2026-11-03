--!strict
--[[
  ClothVerletMesh.luau
  crustdev studio systems - ReplicatedStorage/Physics/ClothVerletMesh

  Production-grade 2D mass-spring cloth simulation grid using Verlet numerical integration:
  - High-performance grid topology (rows x cols) with structural, shear, and flexion constraints.
  - Aerodynamic wind field with oscillatory gusts and surface normal pressure calculations.
  - Multi-obstacle collision support: dynamic sphere colliders and planar ground/wall colliders with friction.
  - Dynamic anchor pinning (top edge, corners, individual UV/grid coordinates).
  - Structural tearing thresholds: constraints rupture under excessive tensile strain.
  - Per-vertex normal vector calculation and triangulated index generation for real-time mesh rendering.
  - Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local ZERO_VECTOR = Vector3.new(0, 0, 0)

export type SphereCollider = {
  center: Vector3,
  radius: number,
  friction: number?,
}

export type PlaneCollider = {
  point: Vector3,
  normal: Vector3,
  friction: number?,
}

export type WindConfig = {
  baseVelocity: Vector3,
  gustStrength: number?,
  gustFrequency: number?,
  dragCoefficient: number?,
}

export type ClothConfig = {
  rows: number,
  cols: number,
  width: number,
  height: number,
  damping: number?,
  gravity: Vector3?,
  structuralIterations: number?,
  shearIterations: number?,
  flexionIterations: number?,
  tearRatio: number?,
  enableShear: boolean?,
  enableFlexion: boolean?,
  wind: WindConfig?,
  sphereColliders: { SphereCollider }?,
  planeColliders: { PlaneCollider }?,
}

export type ClothParticle = {
  position: Vector3,
  oldPosition: Vector3,
  acceleration: Vector3,
  normal: Vector3,
  isPinned: boolean,
  mass: number,
  u: number,
  v: number,
}

export type ConstraintKind = "structural" | "shear" | "flexion"

export type ClothConstraint = {
  indexA: number,
  indexB: number,
  restDistance: number,
  stiffness: number,
  kind: ConstraintKind,
  isBroken: boolean,
}

export type TriangleIndices = {
  a: number,
  b: number,
  c: number,
}

export type ClothVerletMeshInstance = {
  Rows: number,
  Cols: number,
  Width: number,
  Height: number,
  Config: ClothConfig,
  Particles: { ClothParticle },
  Constraints: { ClothConstraint },
  SphereColliders: { SphereCollider },
  PlaneColliders: { PlaneCollider },
  Wind: WindConfig?,
  ElapsedTime: number,
  TornConstraintCount: number,

  GetIndex: (self: ClothVerletMeshInstance, row: number, col: number) -> number,
  GetParticle: (self: ClothVerletMeshInstance, row: number, col: number) -> ClothParticle?,
  PinParticle: (self: ClothVerletMeshInstance, row: number, col: number, isPinned: boolean) -> (),
  PinTopEdge: (self: ClothVerletMeshInstance) -> (),
  SetParticlePosition: (self: ClothVerletMeshInstance, row: number, col: number, pos: Vector3) -> (),
  ApplyImpulse: (self: ClothVerletMeshInstance, row: number, col: number, impulse: Vector3) -> (),
  ApplyForceToAll: (self: ClothVerletMeshInstance, force: Vector3) -> (),
  SetWind: (self: ClothVerletMeshInstance, wind: WindConfig?) -> (),
  AddSphereCollider: (self: ClothVerletMeshInstance, collider: SphereCollider) -> (),
  AddPlaneCollider: (self: ClothVerletMeshInstance, collider: PlaneCollider) -> (),
  ClearColliders: (self: ClothVerletMeshInstance) -> (),
  Step: (self: ClothVerletMeshInstance, dt: number) -> (),
  GetPositions: (self: ClothVerletMeshInstance) -> { Vector3 },
  GetNormals: (self: ClothVerletMeshInstance) -> { Vector3 },
  GetTriangles: (self: ClothVerletMeshInstance) -> { TriangleIndices },
  GetActiveConstraintCount: (self: ClothVerletMeshInstance) -> number,
  GetTornConstraintCount: (self: ClothVerletMeshInstance) -> number,
  Reset: (self: ClothVerletMeshInstance, origin: Vector3) -> (),
}

local ClothVerletMesh = {}
ClothVerletMesh.__index = ClothVerletMesh

local DEFAULT_GRAVITY = Vector3.new(0, -98.1, 0)
local DEFAULT_DAMPING = 0.985
local DEFAULT_STRUCTURAL_ITERS = 4
local DEFAULT_SHEAR_ITERS = 2
local DEFAULT_FLEXION_ITERS = 1

function ClothVerletMesh.new(origin: Vector3, config: ClothConfig): ClothVerletMeshInstance
  local rows = math.max(2, math.floor(config.rows or 10))
  local cols = math.max(2, math.floor(config.cols or 10))
  local width = math.max(0.1, config.width or 10)
  local height = math.max(0.1, config.height or 10)

  local self = setmetatable({}, ClothVerletMesh) :: any
  self.Rows = rows
  self.Cols = cols
  self.Width = width
  self.Height = height
  self.Config = config
  self.SphereColliders = config.sphereColliders and table.clone(config.sphereColliders) or {}
  self.PlaneColliders = config.planeColliders and table.clone(config.planeColliders) or {}
  self.Wind = config.wind
  self.ElapsedTime = 0
  self.TornConstraintCount = 0

  self:Reset(origin)
  return self
end

function ClothVerletMesh:GetIndex(row: number, col: number): number
  return (row - 1) * self.Cols + col
end

function ClothVerletMesh:GetParticle(row: number, col: number): ClothParticle?
  if row < 1 or row > self.Rows or col < 1 or col > self.Cols then
    return nil
  end
  local idx = self:GetIndex(row, col)
  return self.Particles[idx]
end

function ClothVerletMesh:PinParticle(row: number, col: number, isPinned: boolean)
  local p = self:GetParticle(row, col)
  if p then
    p.isPinned = isPinned
  end
end

function ClothVerletMesh:PinTopEdge()
  for col = 1, self.Cols do
    self:PinParticle(1, col, true)
  end
end

function ClothVerletMesh:SetParticlePosition(row: number, col: number, pos: Vector3)
  local p = self:GetParticle(row, col)
  if p then
    p.position = pos
    p.oldPosition = pos
  end
end

function ClothVerletMesh:ApplyImpulse(row: number, col: number, impulse: Vector3)
  local p = self:GetParticle(row, col)
  if p and not p.isPinned then
    p.oldPosition = p.oldPosition - (impulse / p.mass)
  end
end

function ClothVerletMesh:ApplyForceToAll(force: Vector3)
  for _, p in ipairs(self.Particles) do
    if not p.isPinned then
      p.acceleration = p.acceleration + (force / p.mass)
    end
  end
end

function ClothVerletMesh:SetWind(wind: WindConfig?)
  self.Wind = wind
end

function ClothVerletMesh:AddSphereCollider(collider: SphereCollider)
  table.insert(self.SphereColliders, collider)
end

function ClothVerletMesh:AddPlaneCollider(collider: PlaneCollider)
  table.insert(self.PlaneColliders, collider)
end

function ClothVerletMesh:ClearColliders()
  table.clear(self.SphereColliders)
  table.clear(self.PlaneColliders)
end

function ClothVerletMesh:Reset(origin: Vector3)
  local particles: { ClothParticle } = {}
  local constraints: { ClothConstraint } = {}
  self.TornConstraintCount = 0
  self.ElapsedTime = 0

  local dx = self.Width / (self.Cols - 1)
  local dy = self.Height / (self.Rows - 1)

  for r = 1, self.Rows do
    for c = 1, self.Cols do
      local u = (c - 1) / (self.Cols - 1)
      local v = (r - 1) / (self.Rows - 1)
      local localX = (c - 1) * dx - (self.Width * 0.5)
      local localY = -(r - 1) * dy
      local worldPos = origin + Vector3.new(localX, localY, 0)

      table.insert(particles, {
        position = worldPos,
        oldPosition = worldPos,
        acceleration = ZERO_VECTOR,
        normal = Vector3.new(0, 0, 1),
        isPinned = false,
        mass = 1.0,
        u = u,
        v = v,
      })
    end
  end

  local function addConstraint(idxA: number, idxB: number, kind: ConstraintKind, stiffness: number)
    local pA = particles[idxA]
    local pB = particles[idxB]
    local dist = (pA.position - pB.position).Magnitude
    table.insert(constraints, {
      indexA = idxA,
      indexB = idxB,
      restDistance = dist,
      stiffness = stiffness,
      kind = kind,
      isBroken = false,
    })
  end

  -- 1. Structural constraints (horizontal and vertical neighbors)
  for r = 1, self.Rows do
    for c = 1, self.Cols do
      local current = (r - 1) * self.Cols + c
      if c < self.Cols then
        addConstraint(current, current + 1, "structural", 1.0)
      end
      if r < self.Rows then
        addConstraint(current, current + self.Cols, "structural", 1.0)
      end
    end
  end

  -- 2. Shear constraints (diagonals)
  if self.Config.enableShear ~= false then
    for r = 1, self.Rows - 1 do
      for c = 1, self.Cols - 1 do
        local topLeft = (r - 1) * self.Cols + c
        local topRight = topLeft + 1
        local bottomLeft = topLeft + self.Cols
        local bottomRight = bottomLeft + 1

        addConstraint(topLeft, bottomRight, "shear", 0.8)
        addConstraint(topRight, bottomLeft, "shear", 0.8)
      end
    end
  end

  -- 3. Flexion / Bending constraints (two steps away)
  if self.Config.enableFlexion ~= false then
    for r = 1, self.Rows do
      for c = 1, self.Cols do
        local current = (r - 1) * self.Cols + c
        if c + 2 <= self.Cols then
          addConstraint(current, current + 2, "flexion", 0.5)
        end
        if r + 2 <= self.Rows then
          addConstraint(current, current + 2 * self.Cols, "flexion", 0.5)
        end
      end
    end
  end

  self.Particles = particles
  self.Constraints = constraints
end

function ClothVerletMesh:GetTriangles(): { TriangleIndices }
  local tris: { TriangleIndices } = {}
  for r = 1, self.Rows - 1 do
    for c = 1, self.Cols - 1 do
      local i1 = self:GetIndex(r, c)
      local i2 = self:GetIndex(r, c + 1)
      local i3 = self:GetIndex(r + 1, c)
      local i4 = self:GetIndex(r + 1, c + 1)

      -- Upper triangle (i1, i2, i3)
      table.insert(tris, { a = i1, b = i2, c = i3 })
      -- Lower triangle (i2, i4, i3)
      table.insert(tris, { a = i2, b = i4, c = i3 })
    end
  end
  return tris
end

function ClothVerletMesh:GetPositions(): { Vector3 }
  local positions: { Vector3 } = table.create(#self.Particles)
  for i, p in ipairs(self.Particles) do
    positions[i] = p.position
  end
  return positions
end

function ClothVerletMesh:GetNormals(): { Vector3 }
  local normals: { Vector3 } = table.create(#self.Particles)
  for i, p in ipairs(self.Particles) do
    normals[i] = p.normal
  end
  return normals
end

function ClothVerletMesh:GetActiveConstraintCount(): number
  local count = 0
  for _, c in ipairs(self.Constraints) do
    if not c.isBroken then
      count += 1
    end
  end
  return count
end

function ClothVerletMesh:GetTornConstraintCount(): number
  return self.TornConstraintCount
end

function ClothVerletMesh:Step(dt: number)
  if dt <= 0 then
    return
  end
  -- Clamp step dt for numerical stability
  local clampedDt = math.min(dt, 0.033)
  local dtSq = clampedDt * clampedDt
  self.ElapsedTime += clampedDt

  local damping = self.Config.damping or DEFAULT_DAMPING
  local gravity = self.Config.gravity or DEFAULT_GRAVITY
  local tearRatio = self.Config.tearRatio

  -- 1. Apply environmental forces and compute wind aerodynamics
  local currentWindVelocity = ZERO_VECTOR
  local windDrag = 0.05
  if self.Wind then
    local baseVel = self.Wind.baseVelocity
    local gustStr = self.Wind.gustStrength or 0
    local gustFreq = self.Wind.gustFrequency or 1.0
    windDrag = self.Wind.dragCoefficient or 0.05
    local gustFactor = 1.0
    if gustStr > 0 then
      gustFactor = 1.0 + (math.sin(self.ElapsedTime * gustFreq * math.pi * 2) * (gustStr / (baseVel.Magnitude + 0.001)))
    end
    currentWindVelocity = baseVel * gustFactor
  end

  -- Apply base forces
  for _, p in ipairs(self.Particles) do
    if not p.isPinned then
      p.acceleration = p.acceleration + gravity
    end
  end

  -- Aerodynamic wind force per triangle face
  if self.Wind and currentWindVelocity.Magnitude > 0.01 then
    local tris = self:GetTriangles()
    for _, tri in ipairs(tris) do
      local pA = self.Particles[tri.a]
      local pB = self.Particles[tri.b]
      local pC = self.Particles[tri.c]

      local edge1 = pB.position - pA.position
      local edge2 = pC.position - pA.position
      local cross = edge1:Cross(edge2)
      local area = cross.Magnitude * 0.5

      if area > 1e-6 then
        local faceNormal = cross.Unit
        -- Average vertex velocity
        local velA = (pA.position - pA.oldPosition) / clampedDt
        local velB = (pB.position - pB.oldPosition) / clampedDt
        local velC = (pC.position - pC.oldPosition) / clampedDt
        local avgVel = (velA + velB + velC) / 3

        local relWind = currentWindVelocity - avgVel
        local relSpeed = relWind.Magnitude
        if relSpeed > 1e-4 then
          local dot = relWind:Dot(faceNormal)
          -- Aerodynamic pressure directed along normal
          local forceMag = dot * math.abs(dot) * windDrag * area
          local aeroForce = faceNormal * forceMag
          local forcePerVertex = aeroForce / 3

          if not pA.isPinned then pA.acceleration = pA.acceleration + (forcePerVertex / pA.mass) end
          if not pB.isPinned then pB.acceleration = pB.acceleration + (forcePerVertex / pB.mass) end
          if not pC.isPinned then pC.acceleration = pC.acceleration + (forcePerVertex / pC.mass) end
        end
      end
    end
  end

  -- 2. Verlet position integration
  for _, p in ipairs(self.Particles) do
    if not p.isPinned then
      local vel = (p.position - p.oldPosition) * damping
      local nextPos = p.position + vel + (p.acceleration * dtSq)
      p.oldPosition = p.position
      p.position = nextPos
    else
      p.oldPosition = p.position
    end
    p.acceleration = ZERO_VECTOR
  end

  -- 3. Iterative constraint relaxation
  local structIters = self.Config.structuralIterations or DEFAULT_STRUCTURAL_ITERS
  local shearIters = self.Config.shearIterations or DEFAULT_SHEAR_ITERS
  local flexionIters = self.Config.flexionIterations or DEFAULT_FLEXION_ITERS

  local maxIters = math.max(structIters, shearIters, flexionIters)

  for iter = 1, maxIters do
    for _, c in ipairs(self.Constraints) do
      if not c.isBroken then
        local shouldRelax = false
        if c.kind == "structural" and iter <= structIters then
          shouldRelax = true
        elseif c.kind == "shear" and iter <= shearIters then
          shouldRelax = true
        elseif c.kind == "flexion" and iter <= flexionIters then
          shouldRelax = true
        end

        if shouldRelax then
          local pA = self.Particles[c.indexA]
          local pB = self.Particles[c.indexB]

          local delta = pB.position - pA.position
          local dist = delta.Magnitude

          -- Check tearing rupture
          if tearRatio and dist > (c.restDistance * tearRatio) then
            c.isBroken = true
            self.TornConstraintCount += 1
          elseif dist > 1e-6 then
            local diff = (dist - c.restDistance) / dist
            local correction = delta * (0.5 * diff * c.stiffness)

            if pA.isPinned and not pB.isPinned then
              pB.position = pB.position - (delta * (diff * c.stiffness))
            elseif pB.isPinned and not pA.isPinned then
              pA.position = pA.position + (delta * (diff * c.stiffness))
            elseif not pA.isPinned and not pB.isPinned then
              pA.position = pA.position + correction
              pB.position = pB.position - correction
            end
          end
        end
      end
    end

    -- 4. Obstacle collisions
    for _, p in ipairs(self.Particles) do
      if not p.isPinned then
        -- Sphere colliders
        for _, sphere in ipairs(self.SphereColliders) do
          local toParticle = p.position - sphere.center
          local dist = toParticle.Magnitude
          if dist < sphere.radius and dist > 1e-6 then
            local colNormal = toParticle / dist
            p.position = sphere.center + colNormal * sphere.radius

            -- Apply friction to motion
            local friction = sphere.friction or 0.2
            local disp = p.position - p.oldPosition
            local normDisp = colNormal * disp:Dot(colNormal)
            local tangDisp = disp - normDisp
            p.oldPosition = p.position - (normDisp + tangDisp * (1 - friction))
          end
        end

        -- Plane colliders
        for _, plane in ipairs(self.PlaneColliders) do
          local planeDist = (p.position - plane.point):Dot(plane.normal)
          if planeDist < 0 then
            p.position = p.position - (plane.normal * planeDist)
            local friction = plane.friction or 0.3
            local disp = p.position - p.oldPosition
            local normDisp = plane.normal * disp:Dot(plane.normal)
            local tangDisp = disp - normDisp
            p.oldPosition = p.position - (normDisp + tangDisp * (1 - friction))
          end
        end
      end
    end
  end

  -- 5. Calculate smooth vertex surface normals
  for _, p in ipairs(self.Particles) do
    p.normal = ZERO_VECTOR
  end

  local tris = self:GetTriangles()
  for _, tri in ipairs(tris) do
    local pA = self.Particles[tri.a]
    local pB = self.Particles[tri.b]
    local pC = self.Particles[tri.c]

    local edge1 = pB.position - pA.position
    local edge2 = pC.position - pA.position
    local fn = edge1:Cross(edge2)
    if fn.Magnitude > 1e-6 then
      local n = fn.Unit
      pA.normal = pA.normal + n
      pB.normal = pB.normal + n
      pC.normal = pC.normal + n
    end
  end

  for _, p in ipairs(self.Particles) do
    if p.normal.Magnitude > 1e-6 then
      p.normal = p.normal.Unit
    else
      p.normal = Vector3.new(0, 0, 1)
    end
  end
end

return ClothVerletMesh