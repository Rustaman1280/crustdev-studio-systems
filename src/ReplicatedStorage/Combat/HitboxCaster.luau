--!strict
--[[
  HitboxCaster.luau
  Continuous raycast and segment sweep weapon collision detection system.
  Prevents fast melee weapon tunneling between frames via multi-point spatial interpolation.
  Part of crustdev studio game systems (Aetheria: Fractured Realms).
]]

export type HitRecord = {
  Instance: any,
  Position: Vector3,
  Normal: Vector3,
  Material: any?,
  PointIndex: number,
  SubStep: number,
}

export type RaycastQueryResult = {
  Instance: any,
  Position: Vector3,
  Normal: Vector3,
  Material: any?,
}

export type RaycastQueryFn = (origin: Vector3, direction: Vector3) -> RaycastQueryResult?

export type HitboxCasterConfig = {
  Offsets: { Vector3 },      -- Local offset points along weapon (e.g. hilt, mid, tip)
  SubSteps: number?,         -- Intermediate interpolation steps per frame (default 1)
  ConnectEdges: boolean?,    -- Also sweep between adjacent points (cross-segment checking)
}

local HitboxCaster = {}
HitboxCaster.__index = HitboxCaster

function HitboxCaster.new(config: HitboxCasterConfig): HitboxCasterInstance
  local subSteps = config.SubSteps or 1
  if subSteps < 1 then
    subSteps = 1
  end

  local self = setmetatable({}, HitboxCaster)
  self.Offsets = config.Offsets
  self.SubSteps = subSteps
  self.ConnectEdges = if config.ConnectEdges ~= nil then config.ConnectEdges else true
  self.IsActive = false
  self.PreviousTransform = nil :: CFrame?
  self.PreviousPoints = {} :: { Vector3 }
  self.HitDebounce = {} :: { [any]: boolean }
  return self
end

export type HitboxCasterInstance = typeof(setmetatable({} :: {
  Offsets: { Vector3 },
  SubSteps: number,
  ConnectEdges: boolean,
  IsActive: boolean,
  PreviousTransform: CFrame?,
  PreviousPoints: { Vector3 },
  HitDebounce: { [any]: boolean },
}, HitboxCaster))

-- Begin casting session
function HitboxCaster:Start(initialTransform: CFrame): ()
  self.IsActive = true
  self.PreviousTransform = initialTransform
  table.clear(self.PreviousPoints)
  table.clear(self.HitDebounce)

  for i, offset in ipairs(self.Offsets) do
    self.PreviousPoints[i] = initialTransform:PointToWorldSpace(offset)
  end
end

-- Stop casting session
function HitboxCaster:Stop(): ()
  self.IsActive = false
  self.PreviousTransform = nil
  table.clear(self.PreviousPoints)
  table.clear(self.HitDebounce)
end

-- Step cast: sweeps between previous points and current points across sub-steps
function HitboxCaster:Step(currentTransform: CFrame, raycastFn: RaycastQueryFn): { HitRecord }
  if not self.IsActive or not self.PreviousTransform or #self.PreviousPoints == 0 then
    return {}
  end

  local hits: { HitRecord } = {}
  local prevCF = self.PreviousTransform
  local subSteps = self.SubSteps

  local currentWorldPoints: { Vector3 } = {}
  for i, offset in ipairs(self.Offsets) do
    currentWorldPoints[i] = currentTransform:PointToWorldSpace(offset)
  end

  -- Substep interpolation: prevCF to currentTransform
  local lastSampledPoints = self.PreviousPoints

  for step = 1, subSteps do
    local alpha = step / subSteps
    local intermediateCF = prevCF:Lerp(currentTransform, alpha)
    local intermediatePoints: { Vector3 } = {}

    for i, offset in ipairs(self.Offsets) do
      intermediatePoints[i] = intermediateCF:PointToWorldSpace(offset)

      -- 1. Sweep ray from previous sampled point to current sampled point
      local origin = lastSampledPoints[i]
      local target = intermediatePoints[i]
      local delta = target - origin

      if delta.Magnitude > 0.0001 then
        local result = raycastFn(origin, delta)
        if result and result.Instance then
          if not self.HitDebounce[result.Instance] then
            self.HitDebounce[result.Instance] = true
            table.insert(hits, {
              Instance = result.Instance,
              Position = result.Position,
              Normal = result.Normal,
              Material = result.Material,
              PointIndex = i,
              SubStep = step,
            })
          end
        end
      end

      -- 2. Edge connection between adjacent blade points
      if self.ConnectEdges and i > 1 then
        local edgeOrigin = intermediatePoints[i - 1]
        local edgeDelta = intermediatePoints[i] - edgeOrigin
        if edgeDelta.Magnitude > 0.0001 then
          local edgeResult = raycastFn(edgeOrigin, edgeDelta)
          if edgeResult and edgeResult.Instance then
            if not self.HitDebounce[edgeResult.Instance] then
              self.HitDebounce[edgeResult.Instance] = true
              table.insert(hits, {
                Instance = edgeResult.Instance,
                Position = edgeResult.Position,
                Normal = edgeResult.Normal,
                Material = edgeResult.Material,
                PointIndex = i,
                SubStep = step,
              })
            end
          end
        end
      end
    end

    lastSampledPoints = intermediatePoints
  end

  self.PreviousTransform = currentTransform
  self.PreviousPoints = currentWorldPoints

  return hits
end

return HitboxCaster
