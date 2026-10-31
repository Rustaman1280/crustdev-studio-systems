local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame

local ProjectileSolver = require("../src/ReplicatedStorage/Combat/ProjectileSolver")

-- Test 1: Projectile creation
local origin = Vector3.new(0, 10, 0)
local initVel = Vector3.new(100, 50, 0)
local proj = ProjectileSolver.create(origin, initVel)

assert(proj.Position == origin, "Origin should match")
assert(proj.Velocity == initVel, "Velocity should match")
assert(proj.IsAlive == true, "Projectile should be alive initially")
assert(proj.PierceCount == 0, "Initial pierce count must be 0")
assert(proj.BounceCount == 0, "Initial bounce count must be 0")

-- Test 2: Free ballistic flight (Drag and Gravity integration)
local config = {
  Gravity = Vector3.new(0, -100, 0),
  Drag = 0.05,
  MaxLifeTime = 5.0,
  MaxPierces = 0,
  Restitution = 0.0,
  SubStepDistance = 2.0,
}

local step1 = ProjectileSolver.step(proj, config, 0.1, nil)
assert(step1.FinalState.Position.X > 0, "Projectile should have moved forward in X")
assert(step1.FinalState.Position.Y > 10, "Projectile should have initial positive vertical displacement")
assert(#step1.Events == 0, "No collision events expected during free flight")

-- Test 3: Obstacle collision raycast (Terminal Hit)
local wallX = 50.0
local function mockWallRaycast(rayOrigin: Vector3, rayDir: Vector3)
  -- Wall located at X = 50, normal pointing in -X direction
  if rayOrigin.X < wallX and (rayOrigin.X + rayDir.X) >= wallX then
    local fraction = (wallX - rayOrigin.X) / rayDir.X
    local hitPos = rayOrigin + rayDir * fraction
    return {
      Instance = "ConcreteWall",
      Position = hitPos,
      Normal = Vector3.new(-1, 0, 0),
      Distance = (hitPos - rayOrigin).Magnitude,
    }
  end
  return nil
end

local projToWall = ProjectileSolver.create(Vector3.new(40, 10, 0), Vector3.new(200, 0, 0))
local hitResult = ProjectileSolver.step(projToWall, config, 0.1, mockWallRaycast)
assert(projToWall.IsAlive == false, "Projectile should terminate upon hitting solid wall")
assert(math.abs(projToWall.Position.X - wallX) < 0.1, "Projectile should stop at wall position")
assert(#hitResult.Events == 1, "Should emit exactly 1 Hit event")
assert(hitResult.Events[1].Type == "Hit", "Event type should be Hit")
assert(hitResult.Events[1].Instance == "ConcreteWall", "Hit instance should match")

-- Test 4: Piercing projectile logic
local pierceConfig = {
  Gravity = Vector3.new(0, 0, 0),
  Drag = 0.0,
  MaxLifeTime = 5.0,
  MaxPierces = 2,
  Restitution = 0.0,
  SubStepDistance = 1.0,
}

local walls = { 10, 20, 30 }
local function mockMultiWallRaycast(rayOrigin: Vector3, rayDir: Vector3)
  for _, wx in ipairs(walls) do
    if rayOrigin.X < wx and (rayOrigin.X + rayDir.X) >= wx then
      local fraction = (wx - rayOrigin.X) / rayDir.X
      return {
        Instance = "Wall_" .. tostring(wx),
        Position = rayOrigin + rayDir * fraction,
        Normal = Vector3.new(-1, 0, 0),
        Distance = (rayOrigin + rayDir * fraction - rayOrigin).Magnitude,
      }
    end
  end
  return nil
end

local piercingProj = ProjectileSolver.create(Vector3.new(0, 0, 0), Vector3.new(100, 0, 0))
-- Sweep 0.5s: encounters wall 10 (pierce 1), wall 20 (pierce 2), wall 30 (terminal hit after drag/attenuation)
local pierceResult = ProjectileSolver.step(piercingProj, pierceConfig, 0.5, mockMultiWallRaycast)
assert(piercingProj.PierceCount == 2, string.format("Expected 2 pierces, got %d", piercingProj.PierceCount))
assert(piercingProj.IsAlive == false, "Projectile should terminate after exceeding max pierces")
assert(#pierceResult.Events == 3, string.format("Expected 3 collision events (2 pierces, 1 hit), got %d", #pierceResult.Events))
assert(pierceResult.Events[1].Type == "Pierce", "First event should be Pierce")
assert(pierceResult.Events[2].Type == "Pierce", "Second event should be Pierce")
assert(pierceResult.Events[3].Type == "Hit", "Third event should be Hit")

-- Test 5: Specular bounce reflection off surface normal
local bounceConfig = {
  Gravity = Vector3.new(0, 0, 0),
  Drag = 0.0,
  MaxLifeTime = 5.0,
  MaxPierces = 0,
  Restitution = 0.8,
  SubStepDistance = 1.0,
}

local function mockFloorRaycast(rayOrigin: Vector3, rayDir: Vector3)
  -- Floor located at Y = 0, normal = (0, 1, 0)
  if rayOrigin.Y > 0 and (rayOrigin.Y + rayDir.Y) <= 0 then
    local fraction = (0 - rayOrigin.Y) / rayDir.Y
    return {
      Instance = "Floor",
      Position = rayOrigin + rayDir * fraction,
      Normal = Vector3.new(0, 1, 0),
      Distance = (rayOrigin + rayDir * fraction - rayOrigin).Magnitude,
    }
  end
  return nil
end

local bouncingProj = ProjectileSolver.create(Vector3.new(0, 5, 0), Vector3.new(50, -50, 0))
local bounceResult = ProjectileSolver.step(bouncingProj, bounceConfig, 0.2, mockFloorRaycast)
assert(bouncingProj.BounceCount == 1, "BounceCount should be 1")
assert(bouncingProj.IsAlive == true, "Bouncing projectile should remain alive")
assert(bouncingProj.Velocity.Y > 0, "Vertical velocity should be reflected upward")
assert(math.abs(bouncingProj.Velocity.Y - (50 * 0.8)) < 0.1, "Reflected velocity magnitude should match restitution")
assert(bouncingProj.Velocity.X == 50, "Horizontal velocity should remain unchanged by floor bounce")
assert(#bounceResult.Events == 1, "Should emit 1 bounce event")
assert(bounceResult.Events[1].Type == "Bounce", "Event should be Bounce")

-- Test 6: Lifetime expiration
local expiredProj = ProjectileSolver.create(Vector3.new(0, 0, 0), Vector3.new(10, 0, 0))
local expireConfig = { MaxLifeTime = 0.25 }
local expireStep = ProjectileSolver.step(expiredProj, expireConfig, 0.3, nil)
assert(expiredProj.IsAlive == false, "Projectile should expire after TTL")
assert(#expireStep.Events == 1, "Should emit Expired event")
assert(expireStep.Events[1].Type == "Expired", "Event should be Expired")

-- Test 7: Closed-form ballistic targeting equation solver
local launchOrigin = Vector3.new(0, 5, 0)
local targetPos = Vector3.new(120, 5, 0)
local speed = 200 -- At g=196.2, R_max = 200^2 / 196.2 = 203.8 studs (> 120)
local g = 196.2

local lowArcVel = ProjectileSolver.solveLaunchVelocity(launchOrigin, targetPos, speed, g, false)
assert(lowArcVel ~= nil, "Should find valid low-arc ballistic solution")
assert(math.abs(lowArcVel.Magnitude - speed) < 0.05, "Launch velocity magnitude must equal target launch speed")

local highArcVel = ProjectileSolver.solveLaunchVelocity(launchOrigin, targetPos, speed, g, true)
assert(highArcVel ~= nil, "Should find valid high-arc ballistic solution")
assert(math.abs(highArcVel.Magnitude - speed) < 0.05, "Launch velocity magnitude must equal target launch speed")
assert(highArcVel.Y > lowArcVel.Y, "High arc must have greater vertical elevation angle")

-- Test 8: Out of range ballistic target
local distantTarget = Vector3.new(2000, 0, 0)
local impossibleVel = ProjectileSolver.solveLaunchVelocity(launchOrigin, distantTarget, 50, g)
assert(impossibleVel == nil, "Out of range target should return nil")

print("PASS: ProjectileSolver tests (Creation, Ballistic Flight, Collision, Piercing, Bouncing, Targeting Arcs) passed cleanly!")
