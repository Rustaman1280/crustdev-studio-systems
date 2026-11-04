--!strict
local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame
_G.Vector3 = Vector3
_G.CFrame = CFrame

local SpatialSoundZone = require("../src/ReplicatedStorage/Audio/SpatialSoundZone")

local function assertApprox(a: number, b: number, eps: number?, msg: string?)
  local epsilon = eps or 1e-3
  if math.abs(a - b) > epsilon then
    error(string.format("%s: expected approx %f, got %f (diff: %f)", msg or "assertApprox", b, a, math.abs(a - b)))
  end
end

-- 1. Initialization and Baseline Acoustics
do
  local mgr = SpatialSoundZone.new()
  local baseline = mgr:GetActiveAcoustics()
  assertApprox(baseline.ReverbTime, 0.5, 1e-4, "Default reverb time should be 0.5")
  assertApprox(baseline.RoomFilter, 20000, 1e-4, "Default room filter should be 20000 Hz")
  assertApprox(baseline.WetDryMix, 0.05, 1e-4, "Default wet/dry mix should be 0.05")
  assert(mgr:GetActiveZoneId() == nil, "Active zone should be nil in baseline environment")
end

-- 2. Sphere Zone Geometry & Smoothstep Margin Blend
do
  local mgr = SpatialSoundZone.new()
  mgr:AddZone({
    Id = "sphere_cave",
    Shape = "Sphere",
    Priority = 10,
    BlendMargin = 10,
    Center = Vector3.new(0, 0, 0),
    Radius = 20,
    Acoustics = {
      ReverbTime = 3.5,
      RoomFilter = 5000,
      WetDryMix = 0.6,
      AmbientVolume = 0.8,
      EchoFeedback = 0.3,
    },
  })

  -- Inside core (dist 10 <= radius 20)
  local weightCore = mgr:CalculateZoneWeight(mgr._zones["sphere_cave"], Vector3.new(10, 0, 0))
  assertApprox(weightCore, 1.0, 1e-4, "Inside core must have weight 1.0")

  -- Outside zone and margin (dist 35 >= radius 20 + margin 10)
  local weightOut = mgr:CalculateZoneWeight(mgr._zones["sphere_cave"], Vector3.new(35, 0, 0))
  assertApprox(weightOut, 0.0, 1e-4, "Outside margin must have weight 0.0")

  -- Midpoint of blend margin (dist 25, exactly halfway between 20 and 30)
  local weightMid = mgr:CalculateZoneWeight(mgr._zones["sphere_cave"], Vector3.new(25, 0, 0))
  -- Smoothstep(0.5) = 0.5 * 0.5 * (3 - 1) = 0.5
  assertApprox(weightMid, 0.5, 1e-3, "Midpoint of margin should have smoothstep weight 0.5")
end

-- 3. Cylinder Zone Geometry (Radius and Height checks)
do
  local mgr = SpatialSoundZone.new()
  mgr:AddZone({
    Id = "cylinder_silo",
    Shape = "Cylinder",
    Priority = 10,
    BlendMargin = 5,
    Center = Vector3.new(0, 50, 0),
    Radius = 15,
    Height = 40, -- extends from Y=30 to Y=70
    Acoustics = {
      ReverbTime = 2.0,
      RoomFilter = 8000,
      WetDryMix = 0.4,
      AmbientVolume = 0.7,
      EchoFeedback = 0.1,
    },
  })

  local zone = mgr._zones["cylinder_silo"]

  -- Inside cylinder
  local wInside = mgr:CalculateZoneWeight(zone, Vector3.new(5, 50, 5))
  assertApprox(wInside, 1.0, 1e-4, "Inside cylinder core must be 1.0")

  -- Above cylinder ceiling (Y=70 + margin 5 = 75, testing at 80)
  local wAbove = mgr:CalculateZoneWeight(zone, Vector3.new(0, 80, 0))
  assertApprox(wAbove, 0.0, 1e-4, "Above cylinder height must be 0.0")

  -- Outside cylinder radial margin (distXZ = 25 >= radius 15 + margin 5)
  local wOutsideXZ = mgr:CalculateZoneWeight(zone, Vector3.new(25, 50, 0))
  assertApprox(wOutsideXZ, 0.0, 1e-4, "Outside radial bounds must be 0.0")
end

-- 4. Box Zone Geometry (AABB and Rotated CFrame)
do
  local mgr = SpatialSoundZone.new()
  mgr:AddZone({
    Id = "box_room",
    Shape = "Box",
    Priority = 5,
    BlendMargin = 4,
    Center = Vector3.new(100, 0, 100),
    Size = Vector3.new(20, 10, 30), -- half-extents: 10, 5, 15
    Acoustics = {
      ReverbTime = 1.8,
      RoomFilter = 12000,
      WetDryMix = 0.25,
      AmbientVolume = 0.9,
      EchoFeedback = 0.05,
    },
  })

  local zone = mgr._zones["box_room"]

  -- Inside center of room
  local wCenter = mgr:CalculateZoneWeight(zone, Vector3.new(100, 0, 100))
  assertApprox(wCenter, 1.0, 1e-4, "Inside box center must be 1.0")

  -- Far outside room
  local wFar = mgr:CalculateZoneWeight(zone, Vector3.new(0, 0, 0))
  assertApprox(wFar, 0.0, 1e-4, "Far from box must be 0.0")
end

-- 5. Priority Hierarchy & Nested Environments
do
  local mgr = SpatialSoundZone.new()

  -- Large low-priority outdoor cathedral courtyard (Priority 1)
  mgr:AddZone({
    Id = "courtyard",
    Shape = "Box",
    Priority = 1,
    BlendMargin = 5,
    Center = Vector3.new(0, 0, 0),
    Size = Vector3.new(200, 50, 200),
    Acoustics = {
      ReverbTime = 1.2,
      RoomFilter = 15000,
      WetDryMix = 0.15,
      AmbientVolume = 1.0,
      EchoFeedback = 0.05,
    },
  })

  -- High-priority inner subterranean vault (Priority 10)
  mgr:AddZone({
    Id = "inner_vault",
    Shape = "Box",
    Priority = 10,
    BlendMargin = 2,
    Center = Vector3.new(0, 0, 0),
    Size = Vector3.new(20, 10, 20),
    Acoustics = {
      ReverbTime = 4.5,
      RoomFilter = 3000,
      WetDryMix = 0.8,
      AmbientVolume = 0.5,
      EchoFeedback = 0.5,
    },
  })

  -- Inside both: inner_vault must dominate due to Priority 10
  mgr:Update(Vector3.new(0, 0, 0), 1.0)
  assert(mgr:GetActiveZoneId() == "inner_vault", "Inner high-priority zone must be active")
  assert(mgr:IsListenerInZone("inner_vault"), "Listener should be inside inner_vault")
  assert(mgr:GetZoneBlendWeight("inner_vault") > 0.99, "Vault blend weight should be 1.0")

  -- Move outside inner_vault into courtyard (e.g., at X=50)
  mgr:Update(Vector3.new(50, 0, 0), 1.0)
  assert(mgr:GetActiveZoneId() == "courtyard", "Courtyard must become active outside vault")
  assert(mgr:GetZoneBlendWeight("inner_vault") == 0.0, "Inner vault weight must be 0.0")
  assert(mgr:IsListenerInZone("courtyard"), "Listener should be inside courtyard")
end

-- 6. Temporal Parameter Slewing across Frames
do
  local mgr = SpatialSoundZone.new({ SlewRate = 5.0 })
  mgr:AddZone({
    Id = "cathedral",
    Shape = "Sphere",
    Priority = 10,
    BlendMargin = 0,
    Center = Vector3.new(0, 0, 0),
    Radius = 50,
    Acoustics = {
      ReverbTime = 6.0,
      RoomFilter = 2500,
      WetDryMix = 0.9,
      AmbientVolume = 0.4,
      EchoFeedback = 0.4,
    },
  })

  -- Initially at baseline (0.5s reverb)
  local initial = mgr:GetActiveAcoustics()
  assertApprox(initial.ReverbTime, 0.5, 1e-3, "Initial reverb time should be baseline")

  -- Step into zone with small dt=0.05s
  mgr:Update(Vector3.new(0, 0, 0), 0.05)
  local stepped = mgr:GetActiveAcoustics()
  -- Should have smoothly increased toward 6.0 without snapping immediately to 6.0
  assert(stepped.ReverbTime > initial.ReverbTime, "Reverb time should begin increasing")
  assert(stepped.ReverbTime < 6.0, "Reverb time should not immediately jump to 6.0 in one small step")

  -- Simulate several seconds of convergence
  for _ = 1, 60 do
    mgr:Update(Vector3.new(0, 0, 0), 0.05)
  end
  local settled = mgr:GetActiveAcoustics()
  assertApprox(settled.ReverbTime, 6.0, 0.05, "Reverb time should have settled near target 6.0")
end

-- 7. Add and Remove Zone lifecycle
do
  local mgr = SpatialSoundZone.new()
  local id = mgr:AddZone({
    Id = "temp_zone",
    Shape = "Sphere",
    Priority = 1,
    BlendMargin = 2,
    Center = Vector3.new(0, 0, 0),
    Radius = 10,
    Acoustics = {
      ReverbTime = 2.0,
      RoomFilter = 10000,
      WetDryMix = 0.3,
      AmbientVolume = 0.8,
      EchoFeedback = 0.0,
    },
  })
  assert(id == "temp_zone")
  assert(mgr:RemoveZone("temp_zone") == true)
  assert(mgr:RemoveZone("temp_zone") == false)
end

print("SpatialSoundZone unit tests passed successfully!")
