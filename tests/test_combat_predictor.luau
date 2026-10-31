local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

local CombatPredictor = require("../src/StarterPlayerScripts/Controllers/CombatPredictor")
local PacketSchema = require("../src/ReplicatedStorage/Net/PacketSchema")

-- Test 1: Instantiation
local predictor = CombatPredictor.new()
assert(predictor.EstimatedPing == 0.05, "Default ping estimate should be 50ms")
assert(predictor.SequenceCounter == 0, "Initial sequence counter should be 0")

-- Test 2: RTT Estimator (EMA smoothing)
-- RTT sample = 100ms -> Half-trip = 50ms -> No change initially
predictor:UpdateRTT(0.10)
assert(math.abs(predictor.EstimatedPing - 0.05) < 0.001, "EMA with 100ms RTT should stay steady at 50ms")

-- High RTT spike: 200ms -> Half-trip = 100ms. Alpha = 0.15. Expected = 0.85 * 0.05 + 0.15 * 0.10 = 0.0575
predictor:UpdateRTT(0.20)
assert(predictor.EstimatedPing > 0.055, "EMA should adjust upward with high RTT")

-- Test 3: Client Prediction Generation
local targetId = 88
local origin = Vector3.new(10, 2, -15)
local rawAim = Vector3.new(0, 0, -50) -- not unit vector
local weaponId = "ion_cannon_beta"

local seq, payload = predictor:PredictHit(targetId, origin, rawAim, weaponId)
assert(seq == 1, "First sequence counter should be 1")
assert(predictor.PendingForecasts[1] ~= nil, "Forecast 1 should be stored in PendingForecasts")
assert(math.abs(predictor.PendingForecasts[1].PredictedDirection.Magnitude - 1.0) < 0.0001, "Predicted direction should be normalized")

-- Validate payload against PacketSchema
local isValid, schemaErr = PacketSchema.ValidateHitIntent(payload)
assert(isValid, "Payload from CombatPredictor must satisfy PacketSchema: " .. tostring(schemaErr))

-- Test 4: Server Acknowledgement
predictor:HandleServerAcknowledge(seq, true, os.clock() + 0.02)
assert(predictor.PendingForecasts[seq] == nil, "Forecast should be cleared after server acknowledgement")

-- Handle non-existent or duplicate sequence without errors
predictor:HandleServerAcknowledge(999, false, os.clock())

print("PASS: CombatPredictor tests (RTT EMA smoothing, Forecast generation, PacketSchema conformity, Ack reconciliation) passed cleanly!")
