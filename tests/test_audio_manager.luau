local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame

local AdaptiveSoundtrackManager = require("../src/ReplicatedStorage/Audio/AdaptiveSoundtrackManager")

-- Test 1: Manager initialization and track registration
local manager = AdaptiveSoundtrackManager.new(1.0, 0.5)
local state0 = manager:GetState()
assert(state0.CurrentIntensity == 0.0, "Initial target intensity must be 0.0")
assert(state0.SmoothedIntensity == 0.0, "Initial smoothed intensity must be 0.0")
assert(state0.MasterVolume == 1.0, "Default master volume must be 1.0")
assert(state0.CutoffFrequency == 20000.0, "Default cutoff must be 20000 Hz")

local testTrack = {
  TrackId = "crustdev_records_aetheria_ost_01",
  Bpm = 120.0,
  TimeSignature = 4,
  Stems = {
    Ambient = {
      Name = "Ambient Pad",
      MinIntensity = 0.0,
      PeakIntensity = 0.2,
      MaxVolume = 1.0,
      Curve = "Linear",
    },
    Rhythm = {
      Name = "Cyber Percussion",
      MinIntensity = 0.2,
      PeakIntensity = 0.6,
      MaxVolume = 0.9,
      Curve = "Linear",
    },
    Lead = {
      Name = "Neon Synth Solo",
      MinIntensity = 0.5,
      PeakIntensity = 1.0,
      MaxVolume = 1.0,
      Curve = "Quadratic",
    },
  },
}

manager:SetTrack(testTrack)
local stateAfterTrack = manager:GetState()
assert(stateAfterTrack.StemGains["Ambient"] == 0.0, "Stem gains must initialize to 0.0")
assert(stateAfterTrack.StemGains["Rhythm"] == 0.0, "Stem gains must initialize to 0.0")
assert(stateAfterTrack.StemGains["Lead"] == 0.0, "Stem gains must initialize to 0.0")

-- Test 2: Slew rate intensity smoothing (attack)
manager:SetTargetIntensity(0.8)
manager:Update(0.4) -- attackRate = 1.0, dt = 0.4 -> SmoothedIntensity = 0.4
local stateSlew1 = manager:GetState()
assert(math.abs(stateSlew1.SmoothedIntensity - 0.4) < 0.001, string.format("Smoothed intensity should be ~0.4, got %f", stateSlew1.SmoothedIntensity))

-- At intensity 0.4:
-- Ambient: Peak is 0.2 -> 0.4 >= 0.2 -> MaxVolume = 1.0
-- Rhythm: Min 0.2, Peak 0.6 -> t = (0.4 - 0.2) / 0.4 = 0.5 -> Gain = 0.5 * 0.9 = 0.45
-- Lead: Min 0.5 -> 0.4 <= 0.5 -> Gain = 0.0
assert(math.abs(stateSlew1.StemGains["Ambient"] - 1.0) < 0.001, "Ambient should be max volume")
assert(math.abs(stateSlew1.StemGains["Rhythm"] - 0.45) < 0.001, string.format("Rhythm gain should be 0.45, got %f", stateSlew1.StemGains["Rhythm"]))
assert(stateSlew1.StemGains["Lead"] == 0.0, "Lead should be completely silent at 0.4 intensity")

-- Advance another 0.5s -> total 0.9s -> clamped at target 0.8
manager:Update(0.5)
local stateSlew2 = manager:GetState()
assert(math.abs(stateSlew2.SmoothedIntensity - 0.8) < 0.001, "Smoothed intensity should reach target 0.8")

-- At intensity 0.8:
-- Lead: Min 0.5, Peak 1.0 -> t = (0.8 - 0.5) / 0.5 = 0.6 -> Quadratic curve: 0.6^2 = 0.36
assert(math.abs(stateSlew2.StemGains["Lead"] - 0.36) < 0.001, string.format("Lead quadratic gain should be 0.36, got %f", stateSlew2.StemGains["Lead"]))

-- Test 3: Slew rate decay
manager:SetTargetIntensity(0.2)
manager:Update(0.6) -- decayRate = 0.5, dt = 0.6 -> drops by 0.3 -> from 0.8 down to 0.5
local stateDecay = manager:GetState()
assert(math.abs(stateDecay.SmoothedIntensity - 0.5) < 0.001, string.format("Decayed smoothed intensity should be 0.5, got %f", stateDecay.SmoothedIntensity))

-- Test 4: Dynamic Ducking Envelope (Attack -> Hold -> Release)
local duckProfile = {
  TargetGain = 0.25,
  AttackTime = 0.1,
  HoldTime = 0.2,
  ReleaseTime = 0.2,
}
manager:TriggerDucking(duckProfile)

-- Step through Attack (0.1s)
manager:Update(0.05)
local stateDuck1 = manager:GetState()
assert(stateDuck1.DuckingGain < 1.0 and stateDuck1.DuckingGain > 0.25, "Ducking gain should be interpolating down during attack")

manager:Update(0.06) -- finished attack, entered hold
local stateDuck2 = manager:GetState()
assert(math.abs(stateDuck2.DuckingGain - 0.25) < 0.01, "Ducking gain should be at TargetGain during hold")

manager:Update(0.21) -- finished hold, entered release
local stateDuck3 = manager:GetState()
manager:Update(0.21) -- finished release, back to idle
local stateDuck4 = manager:GetState()
assert(stateDuck4.DuckingGain == 1.0, "Ducking gain should restore to 1.0 after envelope completion")

-- Test 5: Acoustic Occlusion Frequency Cutoff
manager:SetOcclusion(0, 0)
local stateOccOpen = manager:GetState()
assert(stateOccOpen.CutoffFrequency == 20000.0, "Open air cutoff frequency should be 20000 Hz")

manager:SetOcclusion(2, 1.5) -- 2 walls of 1.5 density = 3.0 attenuation
local stateOccBlocked = manager:GetState()
assert(stateOccBlocked.CutoffFrequency < 2000.0, string.format("Occluded cutoff should drop significantly, got %f Hz", stateOccBlocked.CutoffFrequency))
assert(stateOccBlocked.CutoffFrequency >= 250.0, "Cutoff must clamp above minimum 250 Hz")

-- Test 6: Beat and Bar Quantization
-- 120 BPM = 0.5 sec/beat, 4/4 = 2.0 sec/bar
local nextBeat = manager:GetNextQuantizedTime(1.1, "Beat")
assert(math.abs(nextBeat - 1.5) < 0.001, string.format("Next beat after 1.1s should be 1.5s, got %f", nextBeat))

local nextBar = manager:GetNextQuantizedTime(1.1, "Bar")
assert(math.abs(nextBar - 2.0) < 0.001, string.format("Next bar after 1.1s should be 2.0s, got %f", nextBar))

local nextBarExact = manager:GetNextQuantizedTime(2.0, "Bar")
assert(math.abs(nextBarExact - 2.0) < 0.001, "Exact bar boundary should return current boundary")

print("PASS: AdaptiveSoundtrackManager tests (Initialization, Slew Filtering, Curve Gains, Ducking, Occlusion, Quantization) passed cleanly!")