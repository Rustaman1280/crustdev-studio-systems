--!strict
--[[
  SpringBonePhysics.luau
  crustdev studio systems - ReplicatedStorage/Physics/SpringBonePhysics

  Production secondary animation (jiggle physics) engine for procedural bones,
  hair strands, animal tails, antennas, cloth accessories, capes, and pendants.

  Features:
  - Multi-node kinematic bone chains anchored to animated root / parent CFrames.
  - Verlet integration with critically damped Hooke spring restoration forces.
  - Invariant bone segment length preservation (rigid link constraint).
  - Angular cone limits preventing unnatural flipping, twisting, or joint inversion.
  - Spherical collider primitives with radial deflection and iterative PBD relaxation.
  - External force integration: directional wind, gravity vectors, and inertial body impulses.
  - Zero external dependencies. Fully compatible with Roblox Engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local CFrame = _G.CFrame or CFrame

local EPSILON = 1e-5

export type BoneConfig = {
  Stiffness: number?, -- Spring restoration strength (default: 45)
  Damping: number?, -- Velocity damping coefficient (default: 6)
  Drag: number?, -- Air drag resistance (default: 1.5)
  Radius: number?, -- Collision envelope radius (default: 0.25)
  Mass: number?, -- Virtual mass (default: 1.0)
  AngleLimitRad: number?, -- Maximum angular deviation from rest direction (rad)
}

export type BoneNode = {
  Index: number,
  ParentIndex: number?, -- Nil if directly attached to root
  RestOffset: Vector3, -- Local offset relative to parent rest CFrame
  RestLength: number,
  CurrentPosition: Vector3,
  PreviousPosition: Vector3,
  Stiffness: number,
  Damping: number,
  Drag: number,
  Radius: number,
  Mass: number,
  AngleLimitRad: number?,
}

export type SphereCollider = {
  Center: Vector3,
  Radius: number,
}

local SpringBonePhysics = {}
SpringBonePhysics.__index = SpringBonePhysics

-- Constructor
function SpringBonePhysics.new(initialRootCFrame: CFrame)
  local self = setmetatable({}, SpringBonePhysics)
  self._rootCFrame = initialRootCFrame
  self._bones = {} :: { BoneNode }
  self._sphereColliders = {} :: { SphereCollider }
  self._gravity = Vector3.new(0, -9.81 * 2, 0)
  self._wind = Vector3.new(0, 0, 0)
  return self
end

-- Add a bone node to the chain or skeleton
function SpringBonePhysics:AddBone(parentIndex: number?, localOffset: Vector3, config: BoneConfig?): number
  local cfg = config or {}
  local length = localOffset.Magnitude
  assert(length > EPSILON, "Bone offset must have non-zero length")

  local parentPos: Vector3
  local parentCF: CFrame
  if parentIndex and self._bones[parentIndex] then
    local pNode = self._bones[parentIndex]
    parentPos = pNode.CurrentPosition
    parentCF = CFrame.new(parentPos)
  else
    parentPos = self._rootCFrame.Position
    parentCF = self._rootCFrame
  end

  local initialPos = parentCF:PointToWorldSpace(localOffset)

  local index = #self._bones + 1
  local node: BoneNode = {
    Index = index,
    ParentIndex = parentIndex,
    RestOffset = localOffset,
    RestLength = length,
    CurrentPosition = initialPos,
    PreviousPosition = initialPos,
    Stiffness = cfg.Stiffness or 45,
    Damping = cfg.Damping or 6,
    Drag = cfg.Drag or 1.5,
    Radius = cfg.Radius or 0.25,
    Mass = cfg.Mass or 1.0,
    AngleLimitRad = cfg.AngleLimitRad,
  }

  table.insert(self._bones, node)
  return index
end

-- Add a spherical collider to the scene
function SpringBonePhysics:AddSphereCollider(center: Vector3, radius: number): number
  assert(radius > 0, "Collider radius must be greater than zero")
  table.insert(self._sphereColliders, {
    Center = center,
    Radius = radius,
  })
  return #self._sphereColliders
end

-- Update an existing spherical collider's position and radius
function SpringBonePhysics:UpdateSphereCollider(index: number, center: Vector3, radius: number?): ()
  local col = self._sphereColliders[index]
  if col then
    col.Center = center
    if radius and radius > 0 then
      col.Radius = radius
    end
  end
end

-- Clear all registered colliders
function SpringBonePhysics:ClearColliders(): ()
  table.clear(self._sphereColliders)
end

-- Set gravity acceleration vector
function SpringBonePhysics:SetGravity(gravity: Vector3): ()
  self._gravity = gravity
end

-- Set ambient wind velocity vector
function SpringBonePhysics:SetWind(wind: Vector3): ()
  self._wind = wind
end

-- Reset all bones instantly to their rest poses relative to root CFrame
function SpringBonePhysics:Reset(rootCFrame: CFrame?): ()
  if rootCFrame then
    self._rootCFrame = rootCFrame
  end

  for _, bone in ipairs(self._bones) do
    local pPos: Vector3
    local pCF: CFrame
    if bone.ParentIndex and self._bones[bone.ParentIndex] then
      local pNode = self._bones[bone.ParentIndex]
      pPos = pNode.CurrentPosition
      pCF = CFrame.new(pPos)
    else
      pPos = self._rootCFrame.Position
      pCF = self._rootCFrame
    end

    local restWorld = pCF:PointToWorldSpace(bone.RestOffset)
    bone.CurrentPosition = restWorld
    bone.PreviousPosition = restWorld
  end
end

-- Advance physics simulation step by dt seconds
function SpringBonePhysics:Step(dt: number, rootCFrame: CFrame, externalImpulse: Vector3?): ()
  local clampDt = math.clamp(dt, 0.001, 0.05)
  local impulse = externalImpulse or Vector3.new(0, 0, 0)
  self._rootCFrame = rootCFrame

  for _, bone in ipairs(self._bones) do
    local parentPos: Vector3
    local parentCF: CFrame

    if bone.ParentIndex and self._bones[bone.ParentIndex] then
      local pNode = self._bones[bone.ParentIndex]
      parentPos = pNode.CurrentPosition
      parentCF = CFrame.new(parentPos)
    else
      parentPos = rootCFrame.Position
      parentCF = rootCFrame
    end

    -- Target rest position in world space
    local targetRestPos = parentCF:PointToWorldSpace(bone.RestOffset)

    -- Verlet velocity with damping and drag
    local dampingFactor = math.clamp(1 - bone.Damping * clampDt, 0.01, 1.0)
    local dragFactor = math.clamp(1 - bone.Drag * clampDt, 0.01, 1.0)
    local velocity = (bone.CurrentPosition - bone.PreviousPosition) * (dampingFactor * dragFactor)

    -- Forces: Hooke's spring return + gravity + wind + impulse
    local springForce = (targetRestPos - bone.CurrentPosition) * bone.Stiffness
    local totalAcceleration = (springForce / bone.Mass) + self._gravity + self._wind + impulse

    -- Projected position
    local nextPos = bone.CurrentPosition + velocity + totalAcceleration * (clampDt * clampDt)

    -- Constraint 1: Cone angular limit from parent rest direction
    if bone.AngleLimitRad and bone.AngleLimitRad > 0 then
      local restDir = (targetRestPos - parentPos)
      if restDir.Magnitude > EPSILON then
        local restUnit = restDir.Unit
        local deltaPos = nextPos - parentPos
        if deltaPos.Magnitude > EPSILON then
          local currentUnit = deltaPos.Unit
          local dot = math.clamp(restUnit:Dot(currentUnit), -1, 1)
          local angle = math.acos(dot)

          if angle > bone.AngleLimitRad then
            local axis = restUnit:Cross(currentUnit)
            if axis.Magnitude > EPSILON then
              local rotCF = CFrame.fromAxisAngle(axis.Unit, bone.AngleLimitRad)
              local clampedDir = rotCF:VectorToWorldSpace(restUnit)
              nextPos = parentPos + clampedDir.Unit * bone.RestLength
            end
          end
        end
      end
    end

    -- Iterative PBD solver: alternating collision and distance constraints
    for _ = 1, 4 do
      -- Collision push-out
      for _, col in ipairs(self._sphereColliders) do
        local colDelta = nextPos - col.Center
        local colDist = colDelta.Magnitude
        local minAllowedDist = col.Radius + bone.Radius

        if colDist < minAllowedDist then
          local pushDir: Vector3
          if colDist > EPSILON then
            pushDir = colDelta / colDist
          else
            pushDir = Vector3.new(1, 0, 0)
          end

          -- If pushed along parent-collider axis, add outward radial deflection
          local toCol = (col.Center - parentPos)
          if toCol.Magnitude > EPSILON then
            local toColUnit = toCol.Unit
            local axialDot = pushDir:Dot(toColUnit)
            if math.abs(axialDot) > 0.8 then
              local radial = pushDir - toColUnit * axialDot
              if radial.Magnitude < EPSILON then
                local perp = toColUnit:Cross(Vector3.new(0, 1, 0))
                if perp.Magnitude < EPSILON then
                  perp = toColUnit:Cross(Vector3.new(1, 0, 0))
                end
                radial = perp.Unit
              else
                radial = radial.Unit
              end
              pushDir = (pushDir * 0.2 + radial * 0.8).Unit
            end
          end

          nextPos = col.Center + pushDir * minAllowedDist
        end
      end

      -- Distance preservation constraint
      local delta = nextPos - parentPos
      local dist = delta.Magnitude
      if dist > EPSILON then
        nextPos = parentPos + (delta / dist) * bone.RestLength
      else
        nextPos = targetRestPos
      end
    end

    -- Commit step
    bone.PreviousPosition = bone.CurrentPosition
    bone.CurrentPosition = nextPos
  end
end

-- Get current world position of a bone
function SpringBonePhysics:GetBonePosition(index: number): Vector3?
  local bone = self._bones[index]
  return bone and bone.CurrentPosition or nil
end

-- Get bone count
function SpringBonePhysics:GetBoneCount(): number
  return #self._bones
end

-- Get orientation CFrame aligned from parent to bone
function SpringBonePhysics:GetBoneCFrame(index: number): CFrame?
  local bone = self._bones[index]
  if not bone then
    return nil
  end

  local parentPos: Vector3
  if bone.ParentIndex and self._bones[bone.ParentIndex] then
    parentPos = self._bones[bone.ParentIndex].CurrentPosition
  else
    parentPos = self._rootCFrame.Position
  end

  local dir = bone.CurrentPosition - parentPos
  if dir.Magnitude > EPSILON then
    return CFrame.lookAt(parentPos, bone.CurrentPosition)
  else
    return CFrame.new(parentPos)
  end
end

return SpringBonePhysics
