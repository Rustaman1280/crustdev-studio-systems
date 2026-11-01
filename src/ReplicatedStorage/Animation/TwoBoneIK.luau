--!strict
--[[
  TwoBoneIK.luau
  Production-grade analytical two-bone Inverse Kinematics (IK) solver.
  Calculates exact closed-form joint positions and orientation CFrames for
  humanoid and creature limbs (hips/knees/feet or shoulders/elbows/hands).
  Includes pole vector constraints, reach clamping, surface normal foot alignment,
  and multi-limb pelvic drop compensation for procedural terrain traversal.
  Part of crustdev studio game systems (Aetheria: Fractured Realms).
]]

local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

export type LimbConfig = {
  UpperLength: number,
  LowerLength: number,
  PoleOffset: typeof(Vector3.new(0, 0, 0))?,
}

export type IKSolution = {
  JointPosition: typeof(Vector3.new(0, 0, 0)),
  RootCFrame: any,
  JointCFrame: any,
  EffectorCFrame: any,
  ReachRatio: number,
  IsOverextended: boolean,
}

export type FootRaycastResult = {
  Hit: boolean,
  Position: typeof(Vector3.new(0, 0, 0)),
  Normal: typeof(Vector3.new(0, 0, 0)),
  Distance: number,
}

local TwoBoneIK = {}
TwoBoneIK.__index = TwoBoneIK

-- Robust orthonormal basis construction to avoid NaN singularities
local function buildBasis(position: typeof(Vector3.new(0, 0, 0)), forward: typeof(Vector3.new(0, 0, 0)), desiredUp: typeof(Vector3.new(0, 0, 0))): any
  local fMag = forward.Magnitude
  local f = if fMag > 0.0001 then forward.Unit else Vector3.new(0, 0, -1)

  local uMag = desiredUp.Magnitude
  local u = if uMag > 0.0001 then desiredUp.Unit else Vector3.new(0, 1, 0)

  local r = f:Cross(u)
  if r.Magnitude < 0.0001 then
    local alt = if math.abs(f.Y) > 0.99 then Vector3.new(0, 0, 1) else Vector3.new(0, 1, 0)
    r = f:Cross(alt).Unit
  else
    r = r.Unit
  end

  local trueUp = r:Cross(f).Unit
  -- In Roblox convention, forward is -Z
  return CFrame.fromMatrix(position, r, trueUp, -f)
end

--[[
  Solve analytical two-bone IK chain.
  rootPos: origin of upper joint (e.g. hip or shoulder)
  targetPos: desired position of end effector (e.g. ankle or wrist)
  polePos: guide point defining the bending plane (e.g. knee/elbow forward vector)
  upperLength: length of upper limb bone
  lowerLength: length of lower limb bone
]]
function TwoBoneIK.Solve(
  rootPos: typeof(Vector3.new(0, 0, 0)),
  targetPos: typeof(Vector3.new(0, 0, 0)),
  polePos: typeof(Vector3.new(0, 0, 0)),
  upperLength: number,
  lowerLength: number
): IKSolution
  local maxReach = upperLength + lowerLength
  local minReach = math.abs(upperLength - lowerLength) + 0.001

  local toTarget = targetPos - rootPos
  local dist = toTarget.Magnitude

  local isOverextended = dist >= (maxReach - 0.001)
  local reachRatio = dist / maxReach

  local clampedDist = math.clamp(dist, minReach, maxReach - 0.0001)
  local targetDir = if dist > 0.0001 then toTarget.Unit else Vector3.new(0, -1, 0)
  local effectiveTarget = rootPos + targetDir * clampedDist

  -- Law of Cosines for interior angles
  -- a = upperLength, b = lowerLength, c = clampedDist
  local a = upperLength
  local b = lowerLength
  local c = clampedDist

  local cosAlpha = math.clamp((a * a + c * c - b * b) / (2 * a * c), -1, 1)
  local alpha = math.acos(cosAlpha)

  -- Calculate bending plane normal from target vector and pole vector
  local toPole = polePos - rootPos
  local planeNormal = targetDir:Cross(toPole)
  if planeNormal.Magnitude < 0.001 then
    -- Pole vector collinear with target; construct fallback orthogonal normal
    local alt = if math.abs(targetDir.Y) > 0.99 then Vector3.new(1, 0, 0) else Vector3.new(0, 1, 0)
    planeNormal = targetDir:Cross(alt).Unit
  else
    planeNormal = planeNormal.Unit
  end

  -- Bend vector perpendicular to target direction in the limb plane
  local bendDir = planeNormal:Cross(targetDir).Unit

  -- Joint (midpoint) position
  local jointOffset = targetDir * (math.cos(alpha) * a) + bendDir * (math.sin(alpha) * a)
  local jointPos = rootPos + jointOffset

  -- Orientation frames
  local upperDir = (jointPos - rootPos).Unit
  local lowerDir = (effectiveTarget - jointPos).Unit

  local rootCF = buildBasis(rootPos, upperDir, planeNormal)
  local jointCF = buildBasis(jointPos, lowerDir, planeNormal)
  local effectorCF = buildBasis(effectiveTarget, lowerDir, planeNormal)

  return {
    JointPosition = jointPos,
    RootCFrame = rootCF,
    JointCFrame = jointCF,
    EffectorCFrame = effectorCF,
    ReachRatio = reachRatio,
    IsOverextended = isOverextended,
  }
end

--[[
  Align foot CFrame to terrain ground normal with maximum angle clamp.
  footCF: baseline foot orientation CFrame
  groundNormal: surface normal vector from raycast
  maxTiltRadians: max allowable tilt angle (e.g. math.rad(45))
]]
function TwoBoneIK.AlignFoot(
  footCF: any,
  groundNormal: typeof(Vector3.new(0, 0, 0)),
  maxTiltRadians: number?
): any
  local maxTilt = maxTiltRadians or math.rad(45)
  local currentUp = footCF.UpVector
  local targetUp = groundNormal.Unit

  local axis = currentUp:Cross(targetUp)
  local axisMag = axis.Magnitude

  if axisMag < 0.0001 then
    return footCF
  end

  local angle = math.acos(math.clamp(currentUp:Dot(targetUp), -1, 1))
  local clampedAngle = math.min(angle, maxTilt)

  local rotCF = CFrame.fromAxisAngle(axis.Unit, clampedAngle)
  return rotCF * (footCF - footCF.Position) + footCF.Position
end

--[[
  Compute pelvic drop compensation across multiple legs.
  Lowers the hip/pelvis root so that the foot on lower ground can reach without overextending.
  legs: array of { HipOffset: Vector3, UpperLength: number, LowerLength: number, HitTarget: Vector3 }
  returns: pelvic drop distance (Y offset <= 0)
]]
function TwoBoneIK.CalculatePelvicDrop(
  rootCFrame: any,
  legs: {
    {
      HipOffset: typeof(Vector3.new(0, 0, 0)),
      UpperLength: number,
      LowerLength: number,
      HitTarget: typeof(Vector3.new(0, 0, 0)),
    }
  },
  maxDrop: number?
): number
  local maxAllowedDrop = maxDrop or 2.5
  local requiredDrop = 0

  for _, leg in ipairs(legs) do
    local hipWorld = (rootCFrame * CFrame.new(leg.HipOffset)).Position
    local toGround = leg.HitTarget - hipWorld
    local maxReach = leg.UpperLength + leg.LowerLength

    if toGround.Magnitude > (maxReach * 0.95) then
      local shortage = toGround.Magnitude - (maxReach * 0.95)
      if shortage > requiredDrop then
        requiredDrop = shortage
      end
    end
  end

  return -math.min(requiredDrop, maxAllowedDrop)
end

--[[
  Predict foot placement target during locomotion based on ground height and velocity.
]]
function TwoBoneIK.PredictTarget(
  hipWorldPos: typeof(Vector3.new(0, 0, 0)),
  velocity: typeof(Vector3.new(0, 0, 0)),
  legReach: number,
  groundY: number,
  anticipationTime: number?
): typeof(Vector3.new(0, 0, 0))
  local dt = anticipationTime or 0.15
  local lead = Vector3.new(velocity.X, 0, velocity.Z) * dt
  local candidateXZ = Vector3.new(hipWorldPos.X + lead.X, 0, hipWorldPos.Z + lead.Z)

  local dy = math.abs(hipWorldPos.Y - groundY)
  local maxHorizontalReach = if dy < legReach then math.sqrt(legReach * legReach - dy * dy) * 0.95 else 0

  local offsetXZ = candidateXZ - Vector3.new(hipWorldPos.X, 0, hipWorldPos.Z)
  if offsetXZ.Magnitude > maxHorizontalReach then
    if maxHorizontalReach > 0.001 and offsetXZ.Magnitude > 0.001 then
      offsetXZ = offsetXZ.Unit * maxHorizontalReach
    else
      offsetXZ = Vector3.new(0, 0, 0)
    end
  end

  return Vector3.new(hipWorldPos.X + offsetXZ.X, groundY, hipWorldPos.Z + offsetXZ.Z)
end

return TwoBoneIK
