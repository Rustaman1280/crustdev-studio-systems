local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
_G.Vector3 = Vector3

local OcclusionModule = require("../src/ReplicatedStorage/Audio/AudioOcclusionRaycaster")
local AudioOcclusionRaycaster = OcclusionModule.new

-- Mock Raycast Environments
local function MakeEmptyWorldRaycast()
  return function(origin, direction, maxDist, ignoreList)
    return nil -- Clear line of sight, no hits
  end
end

-- Test 1: Initialization and Source Registration
local audio = AudioOcclusionRaycaster({
  minCutoffFrequency = 400,
  maxCutoffFrequency = 20000,
  minDistance = 10,
  maxDistance = 200,
})

audio:RegisterSource("engine", Vector3.new(0, 0, 50), 1.0)
local src = audio:GetSourceState("engine")
assert(src ~= nil, "Engine source must be registered")
assert(src.id == "engine", "Source ID must match")
assert(src.currentCutoffFrequency == 20000, "Initial cutoff should be max")

-- Test 2: Unoccluded Direct Line of Sight Propagation
local listenerPos = Vector3.new(0, 0, 0)
local emptyRaycast = MakeEmptyWorldRaycast()

local sources = audio:Update(0.1, listenerPos, emptyRaycast)
local updatedEngine = sources["engine"]
assert(updatedEngine ~= nil, "Engine source must update")
assert(updatedEngine.occlusionRatio == 0.0, "Should have 0 occlusion in open space")
assert(updatedEngine.targetCutoffFrequency == 20000, "Target frequency should be max (20000 Hz)")
assert(updatedEngine.calculatedDistance == 50, "Distance should be 50 studs")
-- Distance is 50, minDist is 10 -> gain = 10 / 50 = 0.2
assert(math.abs(updatedEngine.targetVolumeGain - 0.2) < 1e-4, "Target volume should follow inverse distance")

-- Test 3: Material Absorption Occlusion (Concrete Wall vs Glass Window)
local function MakeWallRaycast(materialName, wallPos)
  return function(origin, direction, maxDist, ignoreList)
    if math.abs(direction.Z) < 1e-5 then
      return nil
    end
    local t = (wallPos - origin.Z) / direction.Z
    if t > 0 and t <= maxDist then
      local hitPos = origin + direction * t
      return {
        Position = hitPos,
        Normal = Vector3.new(0, 0, -1),
        Distance = t,
        Material = materialName,
      }
    end
    return nil
  end
end

-- Concrete test instance
local audioConcrete = AudioOcclusionRaycaster({ minCutoffFrequency = 350, maxCutoffFrequency = 20000 })
audioConcrete:RegisterSource("sound_concrete", Vector3.new(0, 0, 40), 1.0)
local concreteRaycast = MakeWallRaycast("Concrete", 20)
audioConcrete:Update(0.01, listenerPos, concreteRaycast)
local concreteSrc = audioConcrete:GetSourceState("sound_concrete")
assert(concreteSrc ~= nil, "Concrete source must exist")
assert(concreteSrc.occlusionRatio > 0.4, "Concrete must cause heavy occlusion")
assert(concreteSrc.targetCutoffFrequency < 10000, "Cutoff frequency must significantly decrease behind concrete")

-- Glass test instance
local audioGlass = AudioOcclusionRaycaster({ minCutoffFrequency = 350, maxCutoffFrequency = 20000 })
audioGlass:RegisterSource("sound_glass", Vector3.new(0, 0, 40), 1.0)
local glassRaycast = MakeWallRaycast("Glass", 20)
audioGlass:Update(0.01, listenerPos, glassRaycast)
local glassSrc = audioGlass:GetSourceState("sound_glass")
assert(glassSrc ~= nil, "Glass source must exist")
assert(glassSrc.occlusionRatio < concreteSrc.occlusionRatio, "Glass must have lower occlusion than concrete")
assert(glassSrc.targetCutoffFrequency > concreteSrc.targetCutoffFrequency, "Glass must preserve higher frequencies")

-- Test 4: Slew Rate Temporal Smoothing (Anti-Popping)
local prevCutoff = concreteSrc.currentCutoffFrequency
audioConcrete:Update(0.05, listenerPos, concreteRaycast)
local nextCutoff = concreteSrc.currentCutoffFrequency
assert(nextCutoff < prevCutoff, "Cutoff must smoothly decay downwards")
assert(nextCutoff >= concreteSrc.targetCutoffFrequency, "Cutoff must not instantly overshoot target")

-- Test 5: Reverb and Room Acoustic Estimation
-- Scenario A: Open Field (no surfaces)
local openRoom = audio:EstimateRoomAcoustics(listenerPos, emptyRaycast, 50)
assert(openRoom.enclosureRatio == 0.0, "Open field enclosure ratio must be 0")
assert(openRoom.recommendedReverbWet == 0.0, "Open field should have 0 wet reverb")

-- Scenario B: Enclosed Room (Cardinals hit at 15 studs)
local function MakeEnclosedBoxRaycast(halfSize)
  return function(origin, direction, maxDist, ignoreList)
    local hitDist = halfSize
    if hitDist <= maxDist then
      return {
        Position = origin + direction * hitDist,
        Normal = -direction,
        Distance = hitDist,
        Material = "Concrete",
      }
    end
    return nil
  end
end

local boxRaycast = MakeEnclosedBoxRaycast(15)
local indoorRoom = audio:EstimateRoomAcoustics(listenerPos, boxRaycast, 50)
assert(indoorRoom.enclosureRatio == 1.0, "Enclosed box must have enclosureRatio of 1.0")
assert(indoorRoom.recommendedReverbWet > 0.1, "Enclosed room must recommend active reverb wet mix")
assert(indoorRoom.recommendedDecayTime > 0.2, "Enclosed room must have positive decay time")

-- Test 6: Custom Material Absorption
audio:SetMaterialAbsorption("Vibranium", 0.99)
assert(audio:GetMaterialAbsorption("Vibranium") == 0.99, "Custom material absorption must be stored")

-- Test 7: Reset
audio:Reset()
assert(audio:GetSourceState("engine") == nil, "Sources must be cleared after reset")

print("PASS: AudioOcclusionRaycaster tests (Registration, Propagation, Absorption, Slew, Reverb, Materials, Reset) passed cleanly!")
