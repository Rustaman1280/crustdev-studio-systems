--!strict
--[[
  RaycastSuspension.luau
  Custom raycast vehicle suspension physics calculation engine for Roblox.
  Part of crustdev studio game systems (Neon Velocity Drift).
]]

export type WheelConfig = {
  RestLength: number,
  SpringStiffness: number,
  DamperConstant: number,
  WheelRadius: number,
  FrictionCoefficient: number,
}

export type WheelState = {
  PreviousLength: number,
  CompressionRatio: number,
  IsGrounded: boolean,
  ContactPoint: Vector3?,
  ContactNormal: Vector3?,
}

local RaycastSuspension = {}

local DEFAULT_WHEEL_CONFIG: WheelConfig = {
  RestLength = 2.4,
  SpringStiffness = 32000.0,
  DamperConstant = 4200.0,
  WheelRadius = 1.2,
  FrictionCoefficient = 1.15,
}

function RaycastSuspension.CreateDefaultConfig(): WheelConfig
  return table.clone(DEFAULT_WHEEL_CONFIG)
end

function RaycastSuspension.CreateInitialState(config: WheelConfig): WheelState
  return {
    PreviousLength = config.RestLength,
    CompressionRatio = 0.0,
    IsGrounded = false,
    ContactPoint = nil,
    ContactNormal = nil,
  }
end

-- Calculate net suspension force vector (Spring + Damper + Tire Grip)
function RaycastSuspension.ComputeWheelForces(
  config: WheelConfig,
  state: WheelState,
  chassisCFrame: CFrame,
  chassisVelocity: Vector3,
  wheelAttachmentOffset: Vector3,
  raycastResult: RaycastResult?,
  deltaTime: number,
  throttleInput: number,
  steerAngle: number
): (Vector3, WheelState)
  local wheelWorldPos = chassisCFrame:PointToWorldSpace(wheelAttachmentOffset)
  local suspensionDirection = -chassisCFrame.UpVector

  if not raycastResult then
    local newState: WheelState = {
      PreviousLength = config.RestLength,
      CompressionRatio = 0.0,
      IsGrounded = false,
      ContactPoint = nil,
      ContactNormal = nil,
    }
    return Vector3.zero, newState
  end

  local hitDistance = raycastResult.Distance
  local currentLength = math.clamp(hitDistance - config.WheelRadius, 0.1, config.RestLength)
  local compression = config.RestLength - currentLength

  -- Spring Force (Hooke's Law: F = -k * x)
  local springForce = compression * config.SpringStiffness

  -- Damper Force (F = -c * v)
  local springVelocity = (state.PreviousLength - currentLength) / math.max(deltaTime, 0.001)
  local damperForce = springVelocity * config.DamperConstant

  local netUpwardMagnitude = math.max(0, springForce + damperForce)
  local suspensionForce = -suspensionDirection * netUpwardMagnitude

  -- Tire lateral and longitudinal friction forces
  local wheelForward = (chassisCFrame * CFrame.Angles(0, steerAngle, 0)).LookVector
  local wheelRight = (chassisCFrame * CFrame.Angles(0, steerAngle, 0)).RightVector

  local wheelVelocity = chassisVelocity + chassisVelocity:Cross(wheelWorldPos - chassisCFrame.Position)
  local forwardSpeed = wheelVelocity:Dot(wheelForward)
  local lateralSpeed = wheelVelocity:Dot(wheelRight)

  -- Counteract lateral sliding (tire grip)
  local lateralGripForce = -wheelRight * (lateralSpeed * config.FrictionCoefficient * (netUpwardMagnitude / 10.0))
  -- Longitudinal drive acceleration
  local driveForce = wheelForward * (throttleInput * (netUpwardMagnitude / 4.0))

  local totalForce = suspensionForce + lateralGripForce + driveForce

  local newState: WheelState = {
    PreviousLength = currentLength,
    CompressionRatio = compression / config.RestLength,
    IsGrounded = true,
    ContactPoint = raycastResult.Position,
    ContactNormal = raycastResult.Normal,
  }

  return totalForce, newState
end

return RaycastSuspension
