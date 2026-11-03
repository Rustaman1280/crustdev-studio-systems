--!strict
--[[
  FABRIKSolver.luau
  crustdev studio systems - ReplicatedStorage/Animation/FABRIKSolver

  Production-grade Forward And Backward Reaching Inverse Kinematics (FABRIK) solver.
  Solves arbitrary N-link kinematic chains (humanoids, multi-joint tentacles, robot arms,
  tails, spider limbs, and procedural spine rigs) in 3D position space with zero matrix
  inversions, robust singularity avoidance, and sub-millimeter convergence.

  Features:
  - Arbitrary chain lengths (N >= 2 joints, N - 1 bone segments).
  - Fast O(N) iterative convergence in 1 to 4 passes for typical poses.
  - Analytical single-pass straight reach for targets beyond maximum chain extension.
  - Joint cone angle constraints (angular limits in radians) to prevent unnatural twisting.
  - Dynamic pole vector targeting for planar knee/elbow/hinge bias with singularity bypass.
  - Orthonormal basis computation delivering valid Roblox CFrames along each bone segment.
  - Zero external dependencies. Fully compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local CFrame = _G.CFrame or CFrame

export type JointConstraint = {
  maxAngleRad: number?, -- Maximum angular deviation from predecessor bone vector
}

export type SolverOptions = {
  tolerance: number?,      -- Target proximity threshold in studs (default: 0.001)
  maxIterations: number?,  -- Maximum solver iterations before early exit (default: 15)
  poleTarget: Vector3?,    -- Pole vector attractor position
  poleJointIndex: number?, -- Which intermediate joint is attracted to poleTarget
}

export type FABRIKSolution = {
  positions: { Vector3 },
  isReachable: boolean,
  iterations: number,
  errorDistance: number,
  cframes: { any },
}

export type FABRIKSolverImpl = {
  __index: FABRIKSolverImpl,
  new: (initialPositions: { Vector3 }) -> FABRIKSolver,
  fromBoneLengths: (root: Vector3, initialDirection: Vector3, lengths: { number }) -> FABRIKSolver,
  GetJointCount: (self: FABRIKSolver) -> number,
  GetTotalLength: (self: FABRIKSolver) -> number,
  GetJointPosition: (self: FABRIKSolver, index: number) -> Vector3,
  GetBoneLength: (self: FABRIKSolver, boneIndex: number) -> number,
  SetJointConstraint: (self: FABRIKSolver, jointIndex: number, maxAngleRad: number) -> (),
  SetRootPosition: (self: FABRIKSolver, newRoot: Vector3) -> (),
  Solve: (self: FABRIKSolver, target: Vector3, options: SolverOptions?) -> FABRIKSolution,
  GetJointCFrames: (self: FABRIKSolver) -> { any },
  Reset: (self: FABRIKSolver) -> (),
}

export type FABRIKSolver = typeof(setmetatable({} :: {
  _originalPositions: { Vector3 },
  _positions: { Vector3 },
  _lengths: { number },
  _constraints: { JointConstraint? },
  _totalLength: number,
  _jointCount: number,
}, {} :: FABRIKSolverImpl))

local FABRIKSolver = {} :: FABRIKSolverImpl
FABRIKSolver.__index = FABRIKSolver

-- Orthonormal basis builder safe from collinear singularities
local function buildCFrame(origin: Vector3, targetPos: Vector3, fallbackUp: Vector3?): any
  local diff = targetPos - origin
  local mag = diff.Magnitude
  local forward = if mag > 0.0001 then diff.Unit else Vector3.new(0, 0, -1)
  local upHint = fallbackUp or Vector3.new(0, 1, 0)

  local right = forward:Cross(upHint)
  if right.Magnitude < 0.0001 then
    -- Collinear with upHint, choose alternate reference axis
    upHint = Vector3.new(0, 0, 1)
    right = forward:Cross(upHint)
    if right.Magnitude < 0.0001 then
      upHint = Vector3.new(1, 0, 0)
      right = forward:Cross(upHint)
    end
  end

  local rightUnit = right.Unit
  local upUnit = rightUnit:Cross(forward).Unit

  return CFrame.fromMatrix(origin, rightUnit, upUnit, -forward)
end

-- Clamp a vector to lie within an angular cone around a reference vector
local function clampVectorToCone(dir: Vector3, refDir: Vector3, maxAngleRad: number): Vector3
  local cosAngle = math.clamp(dir:Dot(refDir), -1.0, 1.0)
  local currentAngle = math.acos(cosAngle)

  if currentAngle <= maxAngleRad then
    return dir
  end

  -- Angle exceeds limit: project dir onto cone perimeter
  local perp = dir - refDir * cosAngle
  if perp.Magnitude < 0.0001 then
    return refDir
  end

  local perpUnit = perp.Unit
  local clamped = refDir * math.cos(maxAngleRad) + perpUnit * math.sin(maxAngleRad)
  return clamped.Unit
end

function FABRIKSolver.new(initialPositions: { Vector3 }): FABRIKSolver
  assert(#initialPositions >= 2, "FABRIKSolver requires at least 2 joint positions")

  local count = #initialPositions
  local positions: { Vector3 } = table.create(count)
  local originalPositions: { Vector3 } = table.create(count)
  local lengths: { number } = table.create(count - 1)
  local totalLength = 0

  for i = 1, count do
    positions[i] = initialPositions[i]
    originalPositions[i] = initialPositions[i]
    if i > 1 then
      local dist = (initialPositions[i] - initialPositions[i - 1]).Magnitude
      lengths[i - 1] = dist
      totalLength = totalLength + dist
    end
  end

  local constraints: { JointConstraint? } = table.create(count)

  local self = setmetatable({
    _originalPositions = originalPositions,
    _positions = positions,
    _lengths = lengths,
    _constraints = constraints,
    _totalLength = totalLength,
    _jointCount = count,
  }, FABRIKSolver)

  return self
end

function FABRIKSolver.fromBoneLengths(root: Vector3, initialDirection: Vector3, lengths: { number }): FABRIKSolver
  assert(#lengths >= 1, "Must provide at least 1 bone length")
  local dir = if initialDirection.Magnitude > 0.0001 then initialDirection.Unit else Vector3.new(0, 1, 0)

  local positions = { root }
  local currentPos = root
  for i, len in ipairs(lengths) do
    currentPos = currentPos + dir * len
    table.insert(positions, currentPos)
  end

  return FABRIKSolver.new(positions)
end

function FABRIKSolver:GetJointCount(): number
  return self._jointCount
end

function FABRIKSolver:GetTotalLength(): number
  return self._totalLength
end

function FABRIKSolver:GetJointPosition(index: number): Vector3
  assert(index >= 1 and index <= self._jointCount, "Joint index out of bounds")
  return self._positions[index]
end

function FABRIKSolver:GetBoneLength(boneIndex: number): number
  assert(boneIndex >= 1 and boneIndex < self._jointCount, "Bone index out of bounds")
  return self._lengths[boneIndex]
end

function FABRIKSolver:SetJointConstraint(jointIndex: number, maxAngleRad: number)
  assert(jointIndex >= 1 and jointIndex <= self._jointCount, "Joint index out of bounds")
  assert(maxAngleRad >= 0 and maxAngleRad <= math.pi, "maxAngleRad must be between 0 and pi")
  self._constraints[jointIndex] = { maxAngleRad = maxAngleRad }
end

function FABRIKSolver:SetRootPosition(newRoot: Vector3)
  local delta = newRoot - self._positions[1]
  for i = 1, self._jointCount do
    self._positions[i] = self._positions[i] + delta
  end
end

function FABRIKSolver:Reset()
  for i = 1, self._jointCount do
    self._positions[i] = self._originalPositions[i]
  end
end

function FABRIKSolver:GetJointCFrames(): { any }
  local cframes = table.create(self._jointCount)
  local pos = self._positions
  local n = self._jointCount

  for i = 1, n - 1 do
    cframes[i] = buildCFrame(pos[i], pos[i + 1])
  end

  -- End-effector inherits orientation from the preceding bone segment
  if n >= 2 then
    local prevForward = (pos[n] - pos[n - 1])
    local targetOffset = if prevForward.Magnitude > 0.0001 then prevForward.Unit else Vector3.new(0, 0, -1)
    cframes[n] = buildCFrame(pos[n], pos[n] + targetOffset)
  else
    cframes[n] = CFrame.new(pos[n])
  end

  return cframes
end

function FABRIKSolver:Solve(target: Vector3, options: SolverOptions?): FABRIKSolution
  local opts = options or {}
  local tolerance = opts.tolerance or 0.001
  local maxIterations = opts.maxIterations or 15
  local poleTarget = opts.poleTarget
  local poleJointIdx = opts.poleJointIndex

  local n = self._jointCount
  local pos = self._positions
  local len = self._lengths
  local root = pos[1]

  local distToTarget = (target - root).Magnitude

  -- Case 1: Target is unreachable (beyond maximum extension)
  if distToTarget >= self._totalLength - 0.0001 then
    local dir = if distToTarget > 0.0001 then (target - root).Unit else Vector3.new(0, 1, 0)
    for i = 1, n - 1 do
      pos[i + 1] = pos[i] + dir * len[i]
    end

    local finalError = (pos[n] - target).Magnitude
    return {
      positions = pos,
      isReachable = false,
      iterations = 0,
      errorDistance = finalError,
      cframes = self:GetJointCFrames(),
    }
  end

  -- Case 2: Target is reachable. Perform iterative FABRIK solver loop
  local initialRoot = root
  local iterationsUsed = 0
  local errorDist = (pos[n] - target).Magnitude

  -- If pole vector is configured and the chain is currently collinear with target,
  -- nudge the pole joint towards pole target before starting to break singularity
  if poleTarget and poleJointIdx and poleJointIdx > 1 and poleJointIdx < n then
    local chainLine = target - initialRoot
    if chainLine.Magnitude > 0.0001 then
      local chainDir = chainLine.Unit
      local jointLine = pos[poleJointIdx] - initialRoot
      local proj = initialRoot + chainDir * (jointLine:Dot(chainDir))
      local distFromLine = (pos[poleJointIdx] - proj).Magnitude
      if distFromLine < 0.001 then
        local poleDir = poleTarget - proj
        local polePerp = poleDir - chainDir * (poleDir:Dot(chainDir))
        if polePerp.Magnitude > 0.001 then
          pos[poleJointIdx] = pos[poleJointIdx] + polePerp.Unit * 0.1
        end
      end
    end
  end

  while errorDist > tolerance and iterationsUsed < maxIterations do
    iterationsUsed = iterationsUsed + 1

    -- Stage 1: Forward Reaching Pass (Effector to Root)
    pos[n] = target
    for i = n - 1, 1, -1 do
      local r = (pos[i + 1] - pos[i]).Magnitude
      local lambda = len[i] / (if r > 0.00001 then r else 0.00001)
      pos[i] = (1 - lambda) * pos[i + 1] + lambda * pos[i]
    end

    -- Stage 2: Backward Reaching Pass (Root to Effector)
    pos[1] = initialRoot
    for i = 1, n - 1 do
      local rawDir = (pos[i + 1] - pos[i])
      local dir = if rawDir.Magnitude > 0.00001 then rawDir.Unit else Vector3.new(0, 1, 0)

      -- Apply joint cone angular constraints
      local constraint = self._constraints[i]
      if constraint and constraint.maxAngleRad and i > 1 then
        local prevDir = (pos[i] - pos[i - 1])
        if prevDir.Magnitude > 0.00001 then
          dir = clampVectorToCone(dir, prevDir.Unit, constraint.maxAngleRad)
        end
      end

      pos[i + 1] = pos[i] + dir * len[i]
    end

    -- Stage 3: Pole vector alignment for intermediate joint (e.g. elbow / knee)
    if poleTarget and poleJointIdx and poleJointIdx > 1 and poleJointIdx < n then
      local base = pos[1]
      local effector = pos[n]
      local chainLine = effector - base
      local chainLen = chainLine.Magnitude

      if chainLen > 0.0001 then
        local chainDir = chainLine.Unit
        local jointVec = pos[poleJointIdx] - base
        local t = jointVec:Dot(chainDir)
        local jointProj = base + chainDir * t

        local poleVec = poleTarget - base
        local poleProj = base + chainDir * (poleVec:Dot(chainDir))
        local desiredArm = poleTarget - poleProj

        if desiredArm.Magnitude > 0.0001 then
          local desiredDir = desiredArm.Unit
          local currentOffset = pos[poleJointIdx] - jointProj
          local armLen = currentOffset.Magnitude
          if armLen < 0.001 then
            -- Collinear with chord: compute geometric height from bone lengths
            local bLen = len[poleJointIdx - 1]
            armLen = math.sqrt(math.max(0.01, bLen * bLen - t * t))
          end
          pos[poleJointIdx] = jointProj + desiredDir * armLen
        end
      end
    end

    errorDist = (pos[n] - target).Magnitude
  end

  return {
    positions = pos,
    isReachable = true,
    iterations = iterationsUsed,
    errorDistance = errorDist,
    cframes = self:GetJointCFrames(),
  }
end

return FABRIKSolver
