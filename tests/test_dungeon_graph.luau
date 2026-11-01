--!strict
local DungeonGraph = require("../src/ReplicatedStorage/Procedural/DungeonGraph")

-- 1. Test Dungeon Generation
local dungeon = DungeonGraph.new({
  Seed = 424242,
  MapWidth = 40,
  MapHeight = 40,
  MinRoomSize = 5,
  MaxRoomSize = 10,
  SplitDepth = 3,
})

local rooms = dungeon:GetRooms()
assert(#rooms >= 4, string.format("Expected at least 4 rooms from depth 3 BSP, got %d", #rooms))

-- 2. Test Determinism
local dungeon2 = DungeonGraph.new({
  Seed = 424242,
  MapWidth = 40,
  MapHeight = 40,
  MinRoomSize = 5,
  MaxRoomSize = 10,
  SplitDepth = 3,
})

local rooms2 = dungeon2:GetRooms()
assert(#rooms == #rooms2, "Deterministic seed must yield identical room counts")
for i = 1, #rooms do
  assert(rooms[i].X == rooms2[i].X, "Room X mismatch")
  assert(rooms[i].Y == rooms2[i].Y, "Room Y mismatch")
  assert(rooms[i].Width == rooms2[i].Width, "Room Width mismatch")
  assert(rooms[i].Height == rooms2[i].Height, "Room Height mismatch")
  assert(rooms[i].Kind == rooms2[i].Kind, "Room Kind mismatch")
end

-- 3. Test Room Bounds
for _, r in ipairs(rooms) do
  assert(r.X >= 1 and r.X + r.Width <= 40, "Room out of map bounds X")
  assert(r.Y >= 1 and r.Y + r.Height <= 40, "Room out of map bounds Y")
  assert(r.CenterX >= r.X and r.CenterX <= r.X + r.Width, "Center X inside room")
  assert(r.CenterY >= r.Y and r.CenterY <= r.Y + r.Height, "Center Y inside room")
end

-- 4. Test Topology (Spawn & Boss designations)
local spawnRoom = dungeon:GetSpawnRoom()
local bossRoom = dungeon:GetBossRoom()
assert(spawnRoom.Kind == "Spawn", "Spawn room must be tagged Spawn")
assert(spawnRoom.GraphDepth == 0, "Spawn room must have GraphDepth 0")
assert(bossRoom.Kind == "Boss", "Boss room must be tagged Boss")
assert(bossRoom.GraphDepth >= spawnRoom.GraphDepth, "Boss room must have greater or equal depth")

-- 5. Test Room Querying
local queriedRoom = dungeon:GetRoomAt(spawnRoom.CenterX, spawnRoom.CenterY)
assert(queriedRoom ~= nil, "Querying room center must find room")
assert(queriedRoom.Id == spawnRoom.Id, "Queried room ID must match spawn room ID")
assert(dungeon:IsWalkable(spawnRoom.CenterX, spawnRoom.CenterY), "Spawn center must be walkable")

-- 6. Test Perimeter Wall Airtightness
-- Every walkable tile must not have any 4-way adjacent void tile
local directions = { { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } }
for y = 1, 40 do
  for x = 1, 40 do
    if dungeon:IsWalkable(x, y) then
      for _, dir in ipairs(directions) do
        local nx = x + dir[1]
        local ny = y + dir[2]
        local neighborTile = dungeon:GetTile(nx, ny)
        assert(neighborTile ~= 0, string.format("Walkable tile at (%d, %d) leaks into void at (%d, %d)", x, y, nx, ny))
      end
    end
  end
end

-- 7. Test Raycasting (Line of Sight)
-- Ray within spawn room center to center+1 should not hit wall
local hitWithinRoom, _, _ = dungeon:Raycast(spawnRoom.CenterX, spawnRoom.CenterY, spawnRoom.CenterX + 1, spawnRoom.CenterY)
assert(hitWithinRoom == false, "Raycast within walkable room must not be blocked")

-- Raycast across the entire map from spawn center to (1, 1) which is void/wall must hit
local hitWall, hitX, hitY = dungeon:Raycast(spawnRoom.CenterX, spawnRoom.CenterY, 1, 1)
assert(hitWall == true, "Raycast into perimeter should hit wall")
assert(dungeon:GetTile(hitX, hitY) == 2, "Hit tile should be wall")

-- 8. Test ASCII Rendering
local ascii = dungeon:ToAscii()
assert(#ascii > 100, "ASCII rendering should produce map string")
assert(string.find(ascii, "S") ~= nil, "ASCII map must contain Spawn marker 'S'")
assert(string.find(ascii, "B") ~= nil, "ASCII map must contain Boss marker 'B'")
assert(string.find(ascii, "#") ~= nil, "ASCII map must contain Wall glyphs '#'")

print("PASS: DungeonGraph tests (BSP division, Determinism, Bounds, Topology, Airtight Walls, Raycast, ASCII) passed cleanly!")
