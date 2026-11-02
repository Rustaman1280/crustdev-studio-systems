local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame
Vector3 = roblox.Vector3
CFrame = roblox.CFrame

print("=== crustdev studio systems Luau test suite ===")

local tests = {
  { name = "SpatialHashGrid", path = "./test_spatial" },
  { name = "PacketSchema", path = "./test_packet" },
  { name = "RollbackBuffer", path = "./test_rollback" },
  { name = "SnapshotInterpolator", path = "./test_interpolator" },
  { name = "SynthetixWorldGen", path = "./test_worldgen" },
  { name = "RaycastSuspension", path = "./test_suspension" },
  { name = "CombatPredictor", path = "./test_combat_predictor" },
  { name = "ActionBuffer", path = "./test_action_buffer" },
  { name = "HitboxCaster", path = "./test_hitbox_caster" },
  { name = "StatusEffectManager", path = "./test_status_effects" },
  { name = "ProjectileSolver", path = "./test_projectile_solver" },
  { name = "AdaptiveSoundtrackManager", path = "./test_audio_manager" },
  { name = "InventoryGrid", path = "./test_inventory_grid" },
  { name = "BehaviorTree", path = "./test_behavior_tree" },
  { name = "InterestManager", path = "./test_interest_manager" },
  { name = "TwoBoneIK", path = "./test_two_bone_ik" },
  { name = "DeltaCompressor", path = "./test_delta_compressor" },
  { name = "ClockSync", path = "./test_clock_sync" },
  { name = "SparseOctree", path = "./test_sparse_octree" },
  { name = "PathfindingAStar3D", path = "./test_pathfinding_3d" },
  { name = "StateMachine", path = "./test_state_machine" },
  { name = "ClientPredictionReconciler", path = "./test_prediction_reconciler" },
  { name = "DungeonGraph", path = "./test_dungeon_graph" },
  { name = "DamagePipeline", path = "./test_damage_pipeline" },
  { name = "CameraSpring", path = "./test_camera_spring" },
  { name = "ObjectPool", path = "./test_object_pool" },
  { name = "WeightedLootTable", path = "./test_weighted_loot_table" },
  { name = "SteeringBehaviors", path = "./test_steering_behaviors" },
  { name = "DialogueGraph", path = "./test_dialogue_graph" },
  { name = "FastVoxelRaycast", path = "./test_fast_voxel_raycast" },
  { name = "QuestTracker", path = "./test_quest_tracker" },
  { name = "FastSignal", path = "./test_fast_signal" },
  { name = "VoxelFloodFill", path = "./test_voxel_flood_fill" },
}

local passed = 0
local failed = 0

for _, t in ipairs(tests) do
  print(string.format("--> Running test: %s", t.name))
  local ok, err = pcall(function()
    require(t.path)
  end)

  if ok then
    passed += 1
  else
    failed += 1
    print(string.format("FAILED [%s]: %s", t.name, tostring(err)))
  end
end

print("--------------------------------------------------")
print(string.format("Total tests: %d | Passed: %d | Failed: %d", #tests, passed, failed))

if failed > 0 then
  error(string.format("%d tests failed", failed))
else
  print("All Luau systems verified and passing!")
end
