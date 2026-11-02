--!strict
--[[
  VerletRope.luau
  crustdev studio systems - ReplicatedStorage/Physics/VerletRope

  Production-grade Verlet integration physics solver for dynamic ropes, cables,
  vines, and grappling lines:
  - Verlet numerical integration: x(t + dt) = x(t) + (x(t) - x(t - dt)) * damping + a * dt^2
  - Distance relaxation constraints via Gauss-Seidel iterative solver
  - Dynamic pinned anchor points (anchor A, anchor B, or arbitrary intermediate nodes)
  - Sphere and floor plane collision solvers with friction response
  - Dynamic length winching (retracting / paying out cable in real-time)
  - Structural tear threshold detection (snapping under excessive tension)
  - Segment tangent and tension calculations for Beam and Spline rendering

  Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local ZERO_VECTOR = Vector3.new(0, 0, 0)

export type SphereCollider = {
  center: Vector3,
  radius: number,
}

export type RopeConfig = {
  numSegments: number?,
  totalLength: number?,
  damping: number?, -- Drag damping multiplier per tick (default 0.985)
  gravity: Vector3?, -- Gravity acceleration vector (default Vector3.new(0, -98.1, 0))
  constraintIterations: number?, -- Relaxation passes per step (default 8)
  tearRatio: number?, -- Rupture multiplier threshold (e.g. 2.0x resting length, nil = unbreakable)
  floorY: number?, -- Optional ground plane Y collision limit
  colliders: { SphereCollider }?, -- Spherical obstacle colliders
}

export type RopeNode = {
  position: Vector3,
  oldPosition: Vector3,
  acceleration: Vector3,
  isPinned: boolean,
  mass: number,
}

export type VerletRopeInstance = {
  Nodes: { RopeNode },
  SegmentLength: number,
  NumSegments: number,
  Config: RopeConfig,
  IsTorn: boolean,
  TornIndex: number?,

  PinNode: (self: VerletRopeInstance, index: number, isPinned: boolean) -> (),
  SetNodePosition: (self: VerletRopeInstance, index: number, position: Vector3) -> (),
  SetAnchorA: (self: VerletRopeInstance, position: Vector3) -> (),
  SetAnchorB: (self: VerletRopeInstance, position: Vector3) -> (),
  ApplyImpulse: (self: VerletRopeInstance, index: number, impulse: Vector3) -> (),
  ApplyForceToAll: (self: VerletRopeInstance, force: Vector3) -> (),
  AddCollider: (self: VerletRopeInstance, collider: SphereCollider) -> (),
  ClearColliders: (self: VerletRopeInstance) -> (),
  Winch: (self: VerletRopeInstance, deltaLength: number) -> number,
  Step: (self: VerletRopeInstance, dt: number) -> (),
  GetPositions: (self: VerletRopeInstance) -> { Vector3 },
  GetTangents: (self: VerletRopeInstance) -> { Vector3 },
  GetTension: (self: VerletRopeInstance, segmentIndex: number) -> number,
  GetTotalLength: (self: VerletRopeInstance) -> number,
  Reset: (self: VerletRopeInstance, startPos: Vector3, endPos: Vector3) -> (),
}

local VerletRope = {}
VerletRope.__index = VerletRope

local DEFAULT_CONFIG: RopeConfig = {
  numSegments = 10,
  totalLength = 20,
  damping = 0.985,
  gravity = Vector3.new(0, -98.1, 0),
  constraintIterations = 8,
  tearRatio = nil,
  floorY = nil,
  colliders = {},
}

-- Create a new dynamic Verlet rope instance spanning startPos to endPos
function VerletRope.new(startPos: Vector3, endPos: Vector3, userConfig: RopeConfig?): VerletRopeInstance
  local cfg: RopeConfig = {}
  for k, v in pairs(DEFAULT_CONFIG) do
    (cfg :: any)[k] = v
  end
  if userConfig then
    for k, v in pairs(userConfig) do
      (cfg :: any)[k] = v
    end
  end

  local numSegments = math.max(2, cfg.numSegments or 10)
  local totalLength = cfg.totalLength or (endPos - startPos).Magnitude
  if totalLength <= 0 then
    totalLength = 1
  end

  local segmentLength = totalLength / numSegments
  local numNodes = numSegments + 1
  local nodes: { RopeNode } = table.create(numNodes)

  for i = 1, numNodes do
    local alpha = (i - 1) / (numNodes - 1)
    local pos = startPos + (endPos - startPos) * alpha
    nodes[i] = {
      position = pos,
      oldPosition = pos,
      acceleration = cfg.gravity or Vector3.new(0, -98.1, 0),
      isPinned = (i == 1 or i == numNodes),
      mass = 1.0,
    }
  end

  local self = setmetatable({
    Nodes = nodes,
    SegmentLength = segmentLength,
    NumSegments = numSegments,
    Config = cfg,
    IsTorn = false,
    TornIndex = nil,
  }, VerletRope)

  return (self :: any) :: VerletRopeInstance
end

function VerletRope:PinNode(index: number, isPinned: boolean)
  local node = self.Nodes[index]
  if node then
    node.isPinned = isPinned
  end
end

function VerletRope:SetNodePosition(index: number, position: Vector3)
  local node = self.Nodes[index]
  if node then
    node.position = position
    node.oldPosition = position
  end
end

function VerletRope:SetAnchorA(position: Vector3)
  local node = self.Nodes[1]
  if node then
    node.position = position
    node.oldPosition = position
    node.isPinned = true
  end
end

function VerletRope:SetAnchorB(position: Vector3)
  local node = self.Nodes[#self.Nodes]
  if node then
    node.position = position
    node.oldPosition = position
    node.isPinned = true
  end
end

function VerletRope:ApplyImpulse(index: number, impulse: Vector3)
  local node = self.Nodes[index]
  if node and not node.isPinned then
    node.oldPosition = node.oldPosition - impulse
  end
end

function VerletRope:ApplyForceToAll(force: Vector3)
  for _, node in ipairs(self.Nodes) do
    if not node.isPinned then
      node.acceleration = node.acceleration + force
    end
  end
end

function VerletRope:AddCollider(collider: SphereCollider)
  if not self.Config.colliders then
    self.Config.colliders = {}
  end
  table.insert(self.Config.colliders, collider)
end

function VerletRope:ClearColliders()
  self.Config.colliders = {}
end

function VerletRope:Winch(deltaLength: number): number
  local currentTotal = self.SegmentLength * self.NumSegments
  local newTotal = math.max(0.5, currentTotal + deltaLength)
  self.SegmentLength = newTotal / self.NumSegments
  return newTotal
end

function VerletRope:Step(dt: number)
  if dt <= 0 then
    return
  end

  local dtSq = dt * dt
  local damping = self.Config.damping or 0.985
  local baseGravity = self.Config.gravity or Vector3.new(0, -98.1, 0)
  local floorY = self.Config.floorY
  local colliders = self.Config.colliders or {}
  local tearRatio = self.Config.tearRatio
  local iterations = self.Config.constraintIterations or 8

  -- Phase 1: Verlet numerical integration
  for _, node in ipairs(self.Nodes) do
    if not node.isPinned then
      local currentPos = node.position
      local velocity = (currentPos - node.oldPosition) * damping
      local nextPos = currentPos + velocity + node.acceleration * dtSq

      node.oldPosition = currentPos
      node.position = nextPos
      node.acceleration = baseGravity -- reset per-tick acceleration back to gravity
    else
      node.oldPosition = node.position
    end
  end

  -- Phase 2: Relaxation constraints (Gauss-Seidel passes)
  local numNodes = #self.Nodes
  for _ = 1, iterations do
    -- Distance constraints across consecutive nodes
    for i = 1, numNodes - 1 do
      if self.IsTorn and self.TornIndex == i then
        -- Skip severed link
        continue
      end

      local nodeA = self.Nodes[i]
      local nodeB = self.Nodes[i + 1]

      local delta = nodeB.position - nodeA.position
      local dist = delta.Magnitude

      if dist > 1e-6 then
        -- Check structural tear threshold
        if tearRatio and dist > (self.SegmentLength * tearRatio) and not self.IsTorn then
          self.IsTorn = true
          self.TornIndex = i
          continue
        end

        local diff = (dist - self.SegmentLength) / dist
        local adjust = delta * (0.5 * diff)

        if not nodeA.isPinned and not nodeB.isPinned then
          nodeA.position = nodeA.position + adjust
          nodeB.position = nodeB.position - adjust
        elseif nodeA.isPinned and not nodeB.isPinned then
          nodeB.position = nodeB.position - (adjust * 2)
        elseif not nodeA.isPinned and nodeB.isPinned then
          nodeA.position = nodeA.position + (adjust * 2)
        end
      end
    end

    -- Collision constraints: Sphere colliders
    for _, collider in ipairs(colliders) do
      local cPos = collider.center
      local r = collider.radius
      local rSq = r * r

      for _, node in ipairs(self.Nodes) do
        if not node.isPinned then
          local toNode = node.position - cPos
          local distSq = toNode.X * toNode.X + toNode.Y * toNode.Y + toNode.Z * toNode.Z
          if distSq < rSq and distSq > 1e-8 then
            local dist = math.sqrt(distSq)
            local normal = toNode / dist
            node.position = cPos + normal * r
          end
        end
      end
    end

    -- Collision constraints: Ground plane (floorY)
    if floorY ~= nil then
      for _, node in ipairs(self.Nodes) do
        if not node.isPinned and node.position.Y < floorY then
          local cur = node.position
          node.position = Vector3.new(cur.X, floorY, cur.Z)
          -- Ground friction: dampen horizontal motion
          local oldX = node.oldPosition.X
          local oldZ = node.oldPosition.Z
          node.oldPosition = Vector3.new(
            oldX + (cur.X - oldX) * 0.5,
            floorY,
            oldZ + (cur.Z - oldZ) * 0.5
          )
        end
      end
    end
  end
end

function VerletRope:GetPositions(): { Vector3 }
  local positions: { Vector3 } = table.create(#self.Nodes)
  for i, node in ipairs(self.Nodes) do
    positions[i] = node.position
  end
  return positions
end

function VerletRope:GetTangents(): { Vector3 }
  local numNodes = #self.Nodes
  local tangents: { Vector3 } = table.create(numNodes)

  for i = 1, numNodes do
    local tangent: Vector3
    if i == 1 then
      local delta = self.Nodes[2].position - self.Nodes[1].position
      tangent = if delta.Magnitude > 1e-6 then delta.Unit else Vector3.new(0, 1, 0)
    elseif i == numNodes then
      local delta = self.Nodes[numNodes].position - self.Nodes[numNodes - 1].position
      tangent = if delta.Magnitude > 1e-6 then delta.Unit else Vector3.new(0, 1, 0)
    else
      local deltaPrev = self.Nodes[i].position - self.Nodes[i - 1].position
      local deltaNext = self.Nodes[i + 1].position - self.Nodes[i].position
      local combined = deltaPrev + deltaNext
      tangent = if combined.Magnitude > 1e-6 then combined.Unit else Vector3.new(0, 1, 0)
    end
    tangents[i] = tangent
  end

  return tangents
end

function VerletRope:GetTension(segmentIndex: number): number
  if segmentIndex < 1 or segmentIndex >= #self.Nodes then
    return 0
  end
  if self.IsTorn and self.TornIndex == segmentIndex then
    return 0
  end

  local nodeA = self.Nodes[segmentIndex]
  local nodeB = self.Nodes[segmentIndex + 1]
  local actualDist = (nodeB.position - nodeA.position).Magnitude
  local strain = (actualDist - self.SegmentLength) / self.SegmentLength
  return math.max(0, strain)
end

function VerletRope:GetTotalLength(): number
  local total = 0
  for i = 1, #self.Nodes - 1 do
    if not (self.IsTorn and self.TornIndex == i) then
      total += (self.Nodes[i + 1].position - self.Nodes[i].position).Magnitude
    end
  end
  return total
end

function VerletRope:Reset(startPos: Vector3, endPos: Vector3)
  self.IsTorn = false
  self.TornIndex = nil
  local numNodes = #self.Nodes
  for i = 1, numNodes do
    local alpha = (i - 1) / (numNodes - 1)
    local pos = startPos + (endPos - startPos) * alpha
    self.Nodes[i].position = pos
    self.Nodes[i].oldPosition = pos
    self.Nodes[i].acceleration = self.Config.gravity or Vector3.new(0, -98.1, 0)
  end
end

return VerletRope
