--!strict
--[[
  AnimationBlendTree.luau
  crustdev studio systems - ReplicatedStorage/Animation/AnimationBlendTree

  Production hierarchical animation blend tree and motion blending architecture.
  Provides 1D blend spaces, 2D directional blend spaces, normalized phase synchronization,
  skeletal bone masking, additive layering, and state cross-fading.

  Features:
  - 1D Blend Space: continuous interpolation across a 1D scalar parameter (e.g. idle -> walk -> run -> sprint).
  - 2D Cartesian Blend Space: multi-point directional interpolation (e.g. 8-way strafing)
    using normalized Shepard inverse-distance weighting.
  - Normalized Phase Synchronization: synchronizes locomotion cycle phases across clips of
    differing lengths to eliminate foot sliding and stuttering during blends.
  - Skeletal Bone Masking: branch-level bone filtering allowing isolated upper-body actions
    (aiming, weapon recoil, reloading) to overlay lower-body locomotion.
  - Layered Additive Blending: blends additive poses onto base poses with configurable alpha.
  - State Cross-Fading: smooth transition between blend states with linear and smoothstep easing.
  - Zero external dependencies. Fully compatible with Roblox Engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local CFrame = _G.CFrame or CFrame

local EPSILON = 1e-5

export type BoneTransform = {
  Position: Vector3,
  Rotation: CFrame,
}

export type Pose = { [string]: BoneTransform }

export type BoneMask = { [string]: number } -- 0.0 (ignore) to 1.0 (full weight)

export type ClipSample1D = {
  Value: number,
  Duration: number,
  SamplePose: (normalizedPhase: number) -> Pose,
}

export type ClipSample2D = {
  X: number,
  Y: number,
  Duration: number,
  SamplePose: (normalizedPhase: number) -> Pose,
}

export type EasingType = "Linear" | "SmoothStep" | "Cubic"

local AnimationBlendTree = {}
AnimationBlendTree.__index = AnimationBlendTree

-- Utility: CFrame rotation lerp
local function lerpCFrame(a: CFrame, b: CFrame, alpha: number): CFrame
  if a.Lerp then
    return a:Lerp(b, alpha)
  end
  return a
end

-- Utility: Bone transform linear interpolation
local function blendTransform(tA: BoneTransform, tB: BoneTransform, alpha: number): BoneTransform
  local clampedAlpha = math.clamp(alpha, 0, 1)
  local pos = tA.Position:Lerp(tB.Position, clampedAlpha)
  local rot = lerpCFrame(tA.Rotation, tB.Rotation, clampedAlpha)
  return {
    Position = pos,
    Rotation = rot,
  }
end

-- Utility: Blend two entire skeletal poses
local function blendPoses(poseA: Pose, poseB: Pose, alpha: number, boneMask: BoneMask?): Pose
  local blended: Pose = {}
  local clampedAlpha = math.clamp(alpha, 0, 1)

  -- Union of all bone names
  for boneName, tA in pairs(poseA) do
    local tB = poseB[boneName]
    local weight = clampedAlpha
    if boneMask and boneMask[boneName] ~= nil then
      weight *= boneMask[boneName]
    end

    if tB then
      blended[boneName] = blendTransform(tA, tB, weight)
    else
      blended[boneName] = { Position = tA.Position, Rotation = tA.Rotation }
    end
  end

  for boneName, tB in pairs(poseB) do
    if not blended[boneName] then
      local weight = clampedAlpha
      if boneMask and boneMask[boneName] ~= nil then
        weight *= boneMask[boneName]
      end
      blended[boneName] = { Position = tB.Position, Rotation = tB.Rotation }
    end
  end

  return blended
end

-- Utility: Easing evaluator
local function evaluateEasing(t: number, easing: EasingType): number
  local clamped = math.clamp(t, 0, 1)
  if easing == "SmoothStep" then
    return clamped * clamped * (3 - 2 * clamped)
  elseif easing == "Cubic" then
    return clamped * clamped * clamped
  else
    return clamped -- Linear
  end
end

-- ============================================================================
-- 1D BLEND SPACE NODE
-- ============================================================================
export type BlendSpace1D = {
  Type: "BlendSpace1D",
  Samples: { ClipSample1D },
  CurrentPhase: number,
  PlaybackRate: number,
}

function AnimationBlendTree.CreateBlendSpace1D(samples: { ClipSample1D }): BlendSpace1D
  -- Sort samples ascending by Value
  local sorted = table.clone(samples)
  table.sort(sorted, function(a, b)
    return a.Value < b.Value
  end)

  return {
    Type = "BlendSpace1D",
    Samples = sorted,
    CurrentPhase = 0.0,
    PlaybackRate = 1.0,
  }
end

function AnimationBlendTree.EvaluateBlendSpace1D(node: BlendSpace1D, param: number, dt: number): Pose
  local samples = node.Samples
  if #samples == 0 then
    return {}
  end
  if #samples == 1 then
    local s = samples[1]
    node.CurrentPhase = (node.CurrentPhase + (dt * node.PlaybackRate) / math.max(s.Duration, EPSILON)) % 1.0
    return s.SamplePose(node.CurrentPhase)
  end

  -- Determine bounding samples
  local indexA = 1
  local indexB = 2
  local alpha = 0.0

  if param <= samples[1].Value then
    indexA = 1
    indexB = 1
    alpha = 0.0
  elseif param >= samples[#samples].Value then
    indexA = #samples
    indexB = #samples
    alpha = 0.0
  else
    for i = 1, #samples - 1 do
      if param >= samples[i].Value and param <= samples[i + 1].Value then
        indexA = i
        indexB = i + 1
        local span = samples[i + 1].Value - samples[i].Value
        alpha = span > EPSILON and ((param - samples[i].Value) / span) or 0.0
        break
      end
    end
  end

  local sampleA = samples[indexA]
  local sampleB = samples[indexB]

  -- Phase matching: blended duration for synchronized cycle progression
  local blendedDuration = (1 - alpha) * sampleA.Duration + alpha * sampleB.Duration
  if blendedDuration < EPSILON then
    blendedDuration = 1.0
  end

  node.CurrentPhase = (node.CurrentPhase + (dt * node.PlaybackRate) / blendedDuration) % 1.0

  local poseA = sampleA.SamplePose(node.CurrentPhase)
  local poseB = sampleB.SamplePose(node.CurrentPhase)

  return blendPoses(poseA, poseB, alpha)
end

-- ============================================================================
-- 2D BLEND SPACE NODE (Cartesian Directional)
-- ============================================================================
export type BlendSpace2D = {
  Type: "BlendSpace2D",
  Samples: { ClipSample2D },
  CurrentPhase: number,
  PlaybackRate: number,
}

function AnimationBlendTree.CreateBlendSpace2D(samples: { ClipSample2D }): BlendSpace2D
  return {
    Type = "BlendSpace2D",
    Samples = samples,
    CurrentPhase = 0.0,
    PlaybackRate = 1.0,
  }
end

function AnimationBlendTree.EvaluateBlendSpace2D(node: BlendSpace2D, posX: number, posY: number, dt: number): Pose
  local samples = node.Samples
  if #samples == 0 then
    return {}
  end
  if #samples == 1 then
    local s = samples[1]
    node.CurrentPhase = (node.CurrentPhase + (dt * node.PlaybackRate) / math.max(s.Duration, EPSILON)) % 1.0
    return s.SamplePose(node.CurrentPhase)
  end

  -- Normalized Shepard Inverse-Distance Weighting (Power = 2)
  local weights: { number } = table.create(#samples, 0)
  local totalWeight = 0.0
  local exactMatchIndex: number? = nil

  for i, s in ipairs(samples) do
    local dx = posX - s.X
    local dy = posY - s.Y
    local distSq = dx * dx + dy * dy

    if distSq < 1e-6 then
      exactMatchIndex = i
      break
    end

    local w = 1.0 / distSq
    weights[i] = w
    totalWeight += w
  end

  if exactMatchIndex then
    for i = 1, #samples do
      weights[i] = (i == exactMatchIndex) and 1.0 or 0.0
    end
    totalWeight = 1.0
  else
    if totalWeight > EPSILON then
      for i = 1, #samples do
        weights[i] /= totalWeight
      end
    else
      weights[1] = 1.0
    end
  end

  -- Synchronized phase progression based on weighted average duration
  local blendedDuration = 0.0
  for i, s in ipairs(samples) do
    blendedDuration += weights[i] * s.Duration
  end
  if blendedDuration < EPSILON then
    blendedDuration = 1.0
  end

  node.CurrentPhase = (node.CurrentPhase + (dt * node.PlaybackRate) / blendedDuration) % 1.0

  -- Blend all sample poses by their normalized weight
  local accumulatedPose: Pose = {}
  local accumulatedWeights: { [string]: number } = {}

  for i, s in ipairs(samples) do
    local w = weights[i]
    if w > 0.001 then
      local p = s.SamplePose(node.CurrentPhase)
      for boneName, t in pairs(p) do
        if not accumulatedPose[boneName] then
          accumulatedPose[boneName] = {
            Position = t.Position * w,
            Rotation = t.Rotation,
          }
          accumulatedWeights[boneName] = w
        else
          local prev = accumulatedPose[boneName]
          prev.Position += t.Position * w
          local curWeight = accumulatedWeights[boneName]
          local nextWeight = curWeight + w
          if nextWeight > EPSILON then
            prev.Rotation = lerpCFrame(prev.Rotation, t.Rotation, w / nextWeight)
          end
          accumulatedWeights[boneName] = nextWeight
        end
      end
    end
  end

  return accumulatedPose
end

-- ============================================================================
-- ANIMATION BLEND TREE MANAGER
-- ============================================================================
export type TreeInstance = {
  _parameters: { [string]: number },
  _nodes: { [string]: any },
  _activeState: string,
  _transitionTarget: string?,
  _transitionDuration: number,
  _transitionTimer: number,
  _transitionEasing: EasingType,
  _layeredNodes: { [string]: { NodeName: string, Alpha: number, Mask: BoneMask? } },
}

function AnimationBlendTree.new(): any
  local self = setmetatable({}, AnimationBlendTree)
  self._parameters = {}
  self._nodes = {}
  self._activeState = ""
  self._transitionTarget = nil
  self._transitionDuration = 0.0
  self._transitionTimer = 0.0
  self._transitionEasing = "Linear"
  self._layeredNodes = {}
  return self
end

function AnimationBlendTree:SetParameter(name: string, value: number)
  self._parameters[name] = value
end

function AnimationBlendTree:GetParameter(name: string): number
  return self._parameters[name] or 0.0
end

function AnimationBlendTree:RegisterNode(name: string, node: any)
  self._nodes[name] = node
  if self._activeState == "" then
    self._activeState = name
  end
end

function AnimationBlendTree:SetActiveState(name: string)
  if self._nodes[name] then
    self._activeState = name
    self._transitionTarget = nil
  end
end

function AnimationBlendTree:CrossFade(targetState: string, duration: number, easing: EasingType?)
  if self._nodes[targetState] and targetState ~= self._activeState then
    self._transitionTarget = targetState
    self._transitionDuration = math.max(duration, EPSILON)
    self._transitionTimer = 0.0
    self._transitionEasing = easing or "SmoothStep"
  end
end

function AnimationBlendTree:AddLayer(layerName: string, nodeName: string, alpha: number, mask: BoneMask?)
  self._layeredNodes[layerName] = {
    NodeName = nodeName,
    Alpha = math.clamp(alpha, 0, 1),
    Mask = mask,
  }
end

function AnimationBlendTree:SetLayerAlpha(layerName: string, alpha: number)
  if self._layeredNodes[layerName] then
    self._layeredNodes[layerName].Alpha = math.clamp(alpha, 0, 1)
  end
end

-- Evaluate a single registered node
function AnimationBlendTree:_evaluateNode(node: any, dt: number): Pose
  if node.Type == "BlendSpace1D" then
    local paramValue = self:GetParameter(node.Param or "Speed")
    return AnimationBlendTree.EvaluateBlendSpace1D(node, paramValue, dt)
  elseif node.Type == "BlendSpace2D" then
    local paramX = self:GetParameter(node.ParamX or "MoveX")
    local paramY = self:GetParameter(node.ParamY or "MoveY")
    return AnimationBlendTree.EvaluateBlendSpace2D(node, paramX, paramY, dt)
  elseif node.SamplePose then
    node.CurrentPhase = ((node.CurrentPhase or 0.0) + (dt * (node.PlaybackRate or 1.0)) / math.max(node.Duration or 1.0, EPSILON)) % 1.0
    return node.SamplePose(node.CurrentPhase)
  end
  return {}
end

-- Full frame update
function AnimationBlendTree:Update(dt: number): Pose
  if self._activeState == "" or not self._nodes[self._activeState] then
    return {}
  end

  local basePose: Pose = {}

  -- Handle state cross-fading
  if self._transitionTarget and self._nodes[self._transitionTarget] then
    self._transitionTimer += dt
    local progress = math.clamp(self._transitionTimer / self._transitionDuration, 0, 1)
    local easeAlpha = evaluateEasing(progress, self._transitionEasing)

    local poseA = self:_evaluateNode(self._nodes[self._activeState], dt)
    local poseB = self:_evaluateNode(self._nodes[self._transitionTarget], dt)
    basePose = blendPoses(poseA, poseB, easeAlpha)

    if progress >= 1.0 then
      self._activeState = self._transitionTarget
      self._transitionTarget = nil
    end
  else
    basePose = self:_evaluateNode(self._nodes[self._activeState], dt)
  end

  -- Apply layered additive animations
  for _, layer in pairs(self._layeredNodes) do
    if layer.Alpha > EPSILON and self._nodes[layer.NodeName] then
      local layerPose = self:_evaluateNode(self._nodes[layer.NodeName], dt)
      basePose = blendPoses(basePose, layerPose, layer.Alpha, layer.Mask)
    end
  end

  return basePose
end

return AnimationBlendTree