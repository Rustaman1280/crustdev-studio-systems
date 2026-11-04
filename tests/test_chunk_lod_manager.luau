--!strict
local ChunkLODManager = require("../src/ReplicatedStorage/Spatial/ChunkLODManager")

-- Test 1: Coordinate mapping and round-trip centering
do
  local mgr = ChunkLODManager.new({
    ChunkSize = 64,
    Tiers = {
      { Level = 0, MaxDistance = 100 },
      { Level = 1, MaxDistance = 300 },
    },
    Hysteresis = 10,
  })

  local cx, cy, cz = mgr:WorldToChunkCoord(0, 0, 0)
  assert(cx == 0 and cy == 0 and cz == 0, "Origin should map to (0,0,0)")

  local wx, wy, wz = mgr:ChunkCoordToCenter(0, 0, 0)
  assert(wx == 32 and wy == 0 and wz == 32, "Center of chunk (0,0,0) should be (32, 0, 32)")

  local negCx, _, negCz = mgr:WorldToChunkCoord(-65, 0, -10)
  assert(negCx == -2 and negCz == -1, "Negative world coordinates should map correctly")

  local key = mgr:GetChunkKey(3, 0, -5)
  assert(key == "3:-5", "2D chunk key should format correctly")
end

-- Test 2: Initial load and multi-tier LOD assignment
do
  local loadedRecords = {}
  local mgr = ChunkLODManager.new({
    ChunkSize = 64,
    Tiers = {
      { Level = 0, MaxDistance = 64 },   -- Immediate chunk
      { Level = 1, MaxDistance = 150 },  -- Adjacent ring
      { Level = 2, MaxDistance = 250 },  -- Outer perimeter
    },
    Hysteresis = 8,
    BudgetPerFrame = 50, -- high budget to capture all in one step
  })

  mgr:SetCallbacks({
    OnLoad = function(key, coord, lod)
      loadedRecords[key] = lod
    end,
  })

  local obs = { X = 32, Y = 0, Z = 32 } -- Center of chunk 0:0
  local res = mgr:Update(obs)

  assert(#res.Loaded > 0, "Should load chunks on initial update")
  assert(mgr:GetActiveChunkCount() > 0, "Active chunk count should be positive")

  -- Center chunk should be LOD 0
  local centerChunk = mgr:GetChunk("0:0")
  assert(centerChunk ~= nil, "Center chunk must be loaded")
  assert(centerChunk.CurrentLOD == 0, "Center chunk must be LOD 0")
  assert(loadedRecords["0:0"] == 0, "OnLoad callback should record LOD 0")

  -- Adjacent chunk at (1, 0) -> distance center-to-center is 64 studs -> LOD 0 or 1
  local adjChunk = mgr:GetChunk("1:0")
  assert(adjChunk ~= nil, "Adjacent chunk must be loaded")
  assert(adjChunk.CurrentLOD == 0 or adjChunk.CurrentLOD == 1)

  -- Far chunk (e.g. at 200 studs) should be LOD 2
  local farChunk = mgr:GetChunk("2:2")
  if farChunk then
    assert(farChunk.CurrentLOD == 2, "Perimeter chunk should be LOD 2")
  end
end

-- Test 3: Hysteresis deadband boundary protection against oscillation
do
  local changedList = {}
  local mgr = ChunkLODManager.new({
    ChunkSize = 64,
    Tiers = {
      { Level = 0, MaxDistance = 100 },
      { Level = 1, MaxDistance = 200 },
    },
    Hysteresis = 20, -- Large 20 studs deadband
    BudgetPerFrame = 50,
  })

  mgr:SetCallbacks({
    OnChange = function(key, coord, oldLOD, newLOD)
      table.insert(changedList, { Key = key, Old = oldLOD, New = newLOD })
    end,
  })

  -- Observer at (32, 0, 32)
  mgr:Update({ X = 32, Y = 0, Z = 32 })
  local chunk = mgr:GetChunk("1:1")
  assert(chunk ~= nil, "Chunk (1,1) should be loaded")
  local initialLOD = chunk.CurrentLOD

  -- Move observer slightly towards boundary (dist change < hysteresis)
  mgr:Update({ X = 45, Y = 0, Z = 45 })
  assert(chunk.CurrentLOD == initialLOD, "Chunk LOD should not oscillate within hysteresis band")
  assert(#changedList == 0, "No change event should trigger inside hysteresis band")

  -- Move observer significantly far away
  mgr:Update({ X = 300, Y = 0, Z = 300 })
  -- The chunk should now either be downgraded or queued for unload
  local chunkAfterFar = mgr:GetChunk("1:1")
  if chunkAfterFar then
    assert(chunkAfterFar.CurrentLOD >= initialLOD, "Chunk LOD must downgrade or unload when observer moves far away")
  end
end

-- Test 4: Frame budget throttling
do
  local mgr = ChunkLODManager.new({
    ChunkSize = 64,
    Tiers = {
      { Level = 0, MaxDistance = 120 },
      { Level = 1, MaxDistance = 300 },
    },
    Hysteresis = 10,
    BudgetPerFrame = 3, -- Stiff budget of 3 operations per update
  })

  local res1 = mgr:Update({ X = 0, Y = 0, Z = 0 })
  assert(#res1.Loaded <= 3, "Update step 1 must not exceed frame budget of 3")

  local res2 = mgr:Update({ X = 0, Y = 0, Z = 0 })
  assert(#res2.Loaded <= 3, "Update step 2 must not exceed frame budget of 3")

  -- Iterate until fully converged
  local steps = 0
  while steps < 20 do
    local res = mgr:Update({ X = 0, Y = 0, Z = 0 })
    if #res.Loaded == 0 and #res.Changed == 0 and #res.Unloaded == 0 then
      break
    end
    steps += 1
  end

  assert(mgr:GetActiveChunkCount() >= 5, "Manager should converge to streaming the full active radius")
end

-- Test 5: Neighbor LOD delta calculation for seam stitching
do
  local mgr = ChunkLODManager.new({
    ChunkSize = 64,
    Tiers = {
      { Level = 0, MaxDistance = 70 },
      { Level = 1, MaxDistance = 180 },
    },
    Hysteresis = 10,
    BudgetPerFrame = 50,
  })

  mgr:Update({ X = 32, Y = 0, Z = 32 })

  local deltas = mgr:GetNeighborLODDelta(0, 0, 0)
  assert(deltas["North"] ~= nil, "Must include North neighbor")
  assert(deltas["South"] ~= nil, "Must include South neighbor")
  assert(deltas["East"] ~= nil, "Must include East neighbor")
  assert(deltas["West"] ~= nil, "Must include West neighbor")
end

-- Test 6: 3D Volumetric chunk streaming mode
do
  local mgr3D = ChunkLODManager.new({
    ChunkSize = 32,
    Is3D = true,
    Tiers = {
      { Level = 0, MaxDistance = 40 },
      { Level = 1, MaxDistance = 90 },
    },
    Hysteresis = 8,
    BudgetPerFrame = 50,
  })

  local key = mgr3D:GetChunkKey(1, 2, 3)
  assert(key == "1:2:3", "3D key must format with XYZ")

  local wx, wy, wz = mgr3D:ChunkCoordToCenter(0, 1, 0)
  assert(wx == 16 and wy == 48 and wz == 16, "3D center elevation should be accurate")

  mgr3D:Update({ X = 16, Y = 48, Z = 16 })
  local centerRecord = mgr3D:GetChunk("0:1:0")
  assert(centerRecord ~= nil, "Center 3D chunk must be loaded")
  assert(centerRecord.CurrentLOD == 0, "Center 3D chunk should be LOD 0")

  local deltas3D = mgr3D:GetNeighborLODDelta(0, 1, 0)
  assert(deltas3D["Top"] ~= nil, "3D seam deltas must include Top neighbor")
  assert(deltas3D["Bottom"] ~= nil, "3D seam deltas must include Bottom neighbor")

  -- Test FlushAll
  local unloads = 0
  mgr3D:SetCallbacks({
    OnUnload = function() unloads += 1 end,
  })
  local countBefore = mgr3D:GetActiveChunkCount()
  assert(countBefore > 0)
  mgr3D:FlushAll()
  assert(mgr3D:GetActiveChunkCount() == 0, "FlushAll must empty active chunks")
  assert(unloads == countBefore, "OnUnload must be invoked for each flushed chunk")
end

print("test_chunk_lod_manager: all tests passed successfully!")
