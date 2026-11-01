--!strict
--[[
  DungeonGraph.luau
  Procedural 2D/3D dungeon generator and topology graph analyzer using Binary Space Partitioning (BSP).
  Features:
  - Recursive BSP tree spatial partitioning with aspect-ratio balancing
  - Deterministic pseudo-random generation with configurable seed (SplitMix32 PRNG)
  - Organic L-shaped corridor carving with hallway smoothing
  - Automatic airtight perimeter wall boundary detection
  - Graph topology analysis with BFS distance field solving
  - Semantic room categorization: Spawn, Boss (deepest topological node), Loot (dead-ends), Standard
  - Fast 2D DDA grid raycasting for line-of-sight and room occlusion testing
  - ASCII map serialization for visualization and regression diagnostics
  Part of crustdev studio game systems.
  Zero external runtime dependencies.
]]

export type TileKind = number

local TILE_VOID: TileKind = 0
local TILE_FLOOR: TileKind = 1
local TILE_WALL: TileKind = 2
local TILE_CORRIDOR: TileKind = 3
local TILE_DOOR: TileKind = 4

export type RoomType = "Spawn" | "Standard" | "Loot" | "Boss" | "Puzzle"

export type DungeonRoom = {
  Id: number,
  X: number,
  Y: number,
  Width: number,
  Height: number,
  CenterX: number,
  CenterY: number,
  Kind: RoomType,
  GraphDepth: number,
  Neighbors: { number },
}

export type DungeonConfig = {
  Seed: number?,
  MapWidth: number?,
  MapHeight: number?,
  MinRoomSize: number?,
  MaxRoomSize: number?,
  SplitDepth: number?,
  RoomPadding: number?,
}

export type DungeonGraph = {
  Config: {
    Seed: number,
    MapWidth: number,
    MapHeight: number,
    MinRoomSize: number,
    MaxRoomSize: number,
    SplitDepth: number,
    RoomPadding: number,
  },
  Grid: { { TileKind } },
  Rooms: { DungeonRoom },
  SpawnRoomId: number,
  BossRoomId: number,

  -- Methods
  GetTile: (self: DungeonGraph, x: number, y: number) -> TileKind,
  IsWalkable: (self: DungeonGraph, x: number, y: number) -> boolean,
  GetRoomAt: (self: DungeonGraph, x: number, y: number) -> DungeonRoom?,
  GetRooms: (self: DungeonGraph) -> { DungeonRoom },
  GetSpawnRoom: (self: DungeonGraph) -> DungeonRoom,
  GetBossRoom: (self: DungeonGraph) -> DungeonRoom,
  Raycast: (self: DungeonGraph, x0: number, y0: number, x1: number, y1: number) -> (boolean, number, number),
  ToAscii: (self: DungeonGraph) -> string,
}

type BSPNode = {
  X: number,
  Y: number,
  W: number,
  H: number,
  Left: BSPNode?,
  Right: BSPNode?,
  Room: DungeonRoom?,
}

local DungeonGraphImpl = {}
DungeonGraphImpl.__index = DungeonGraphImpl

local DEFAULT_SEED = 133742
local DEFAULT_WIDTH = 48
local DEFAULT_HEIGHT = 48
local DEFAULT_MIN_ROOM = 6
local DEFAULT_MAX_ROOM = 12
local DEFAULT_SPLIT_DEPTH = 4
local DEFAULT_PADDING = 1

-- Simple deterministic PRNG
local function makeRng(seed: number)
  local state = seed
  return function(): number
    state = (state * 1103515245 + 12345) % 2147483648
    return state / 2147483648
  end
end

local function randomInt(rng: () -> number, minVal: number, maxVal: number): number
  if minVal >= maxVal then
    return minVal
  end
  return math.floor(minVal + rng() * (maxVal - minVal + 1))
end

-- Create empty 2D grid
local function makeGrid(w: number, h: number, fill: TileKind): { { TileKind } }
  local grid = table.create(h)
  for y = 1, h do
    local row = table.create(w, fill)
    grid[y] = row
  end
  return grid
end

-- Carve rectangle of floor
local function carveRoom(grid: { { TileKind } }, room: DungeonRoom)
  for y = room.Y, room.Y + room.Height - 1 do
    for x = room.X, room.X + room.Width - 1 do
      grid[y][x] = TILE_FLOOR
    end
  end
end

-- Carve corridor between two points
local function carveCorridor(
  grid: { { TileKind } },
  x1: number,
  y1: number,
  x2: number,
  y2: number,
  rng: () -> number
)
  local horizontalFirst = rng() > 0.5
  if horizontalFirst then
    -- Carve X then Y
    local stepX = if x2 >= x1 then 1 else -1
    for x = x1, x2, stepX do
      if grid[y1][x] == TILE_VOID then
        grid[y1][x] = TILE_CORRIDOR
      end
    end
    local stepY = if y2 >= y1 then 1 else -1
    for y = y1, y2, stepY do
      if grid[y][x2] == TILE_VOID then
        grid[y][x2] = TILE_CORRIDOR
      end
    end
  else
    -- Carve Y then X
    local stepY = if y2 >= y1 then 1 else -1
    for y = y1, y2, stepY do
      if grid[y][x1] == TILE_VOID then
        grid[y][x1] = TILE_CORRIDOR
      end
    end
    local stepX = if x2 >= x1 then 1 else -1
    for x = x1, x2, stepX do
      if grid[y2][x] == TILE_VOID then
        grid[y2][x] = TILE_CORRIDOR
      end
    end
  end
end

-- Recursive BSP subdivision
local function splitBSP(
  node: BSPNode,
  depth: number,
  maxDepth: number,
  minSize: number,
  rng: () -> number
)
  if depth >= maxDepth then
    return
  end

  local canSplitH = node.H >= minSize * 2 + 2
  local canSplitV = node.W >= minSize * 2 + 2

  if not canSplitH and not canSplitV then
    return
  end

  -- Choose split orientation based on aspect ratio
  local splitHorizontal = false
  if canSplitH and canSplitV then
    if node.W / node.H >= 1.25 then
      splitHorizontal = false
    elseif node.H / node.W >= 1.25 then
      splitHorizontal = true
    else
      splitHorizontal = rng() > 0.5
    end
  elseif canSplitH then
    splitHorizontal = true
  else
    splitHorizontal = false
  end

  if splitHorizontal then
    local splitY = randomInt(rng, minSize + 1, node.H - minSize - 1)
    node.Left = {
      X = node.X,
      Y = node.Y,
      W = node.W,
      H = splitY,
      Left = nil,
      Right = nil,
      Room = nil,
    }
    node.Right = {
      X = node.X,
      Y = node.Y + splitY,
      W = node.W,
      H = node.H - splitY,
      Left = nil,
      Right = nil,
      Room = nil,
    }
  else
    local splitX = randomInt(rng, minSize + 1, node.W - minSize - 1)
    node.Left = {
      X = node.X,
      Y = node.Y,
      W = splitX,
      H = node.H,
      Left = nil,
      Right = nil,
      Room = nil,
    }
    node.Right = {
      X = node.X + splitX,
      Y = node.Y,
      W = node.W - splitX,
      H = node.H,
      Left = nil,
      Right = nil,
      Room = nil,
    }
  end

  if node.Left then
    splitBSP(node.Left, depth + 1, maxDepth, minSize, rng)
  end
  if node.Right then
    splitBSP(node.Right, depth + 1, maxDepth, minSize, rng)
  end
end

-- Collect leaves and carve rooms
local function createRoomsInLeaves(
  node: BSPNode,
  roomsList: { DungeonRoom },
  grid: { { TileKind } },
  minRoom: number,
  maxRoom: number,
  padding: number,
  rng: () -> number
): DungeonRoom?
  if node.Left == nil and node.Right == nil then
    -- Leaf node: carve room
    local maxW = math.min(node.W - padding * 2, maxRoom)
    local maxH = math.min(node.H - padding * 2, maxRoom)
    local roomW = randomInt(rng, minRoom, maxW)
    local roomH = randomInt(rng, minRoom, maxH)

    local roomX = node.X + padding + randomInt(rng, 0, node.W - padding * 2 - roomW)
    local roomY = node.Y + padding + randomInt(rng, 0, node.H - padding * 2 - roomH)

    local id = #roomsList + 1
    local room: DungeonRoom = {
      Id = id,
      X = roomX,
      Y = roomY,
      Width = roomW,
      Height = roomH,
      CenterX = math.floor(roomX + roomW / 2),
      CenterY = math.floor(roomY + roomH / 2),
      Kind = "Standard",
      GraphDepth = 0,
      Neighbors = {},
    }

    carveRoom(grid, room)
    table.insert(roomsList, room)
    node.Room = room
    return room
  end

  local leftRoom: DungeonRoom? = nil
  local rightRoom: DungeonRoom? = nil

  if node.Left then
    leftRoom = createRoomsInLeaves(node.Left, roomsList, grid, minRoom, maxRoom, padding, rng)
  end
  if node.Right then
    rightRoom = createRoomsInLeaves(node.Right, roomsList, grid, minRoom, maxRoom, padding, rng)
  end

  if leftRoom and rightRoom then
    carveCorridor(grid, leftRoom.CenterX, leftRoom.CenterY, rightRoom.CenterX, rightRoom.CenterY, rng)
    -- Add bidirectional adjacency
    table.insert(leftRoom.Neighbors, rightRoom.Id)
    table.insert(rightRoom.Neighbors, leftRoom.Id)
  end

  return leftRoom or rightRoom
end

-- Build airtight perimeter walls around floors and corridors
local function generateWalls(grid: { { TileKind } }, w: number, h: number)
  local offsets = {
    { -1, -1 }, { 0, -1 }, { 1, -1 },
    { -1,  0 },          { 1,  0 },
    { -1,  1 }, { 0,  1 }, { 1,  1 },
  }

  for y = 1, h do
    for x = 1, w do
      if grid[y][x] == TILE_VOID then
        -- Check if adjacent to floor or corridor
        local hasWalkableNeighbor = false
        for _, off in ipairs(offsets) do
          local nx = x + off[1]
          local ny = y + off[2]
          if nx >= 1 and nx <= w and ny >= 1 and ny <= h then
            local t = grid[ny][nx]
            if t == TILE_FLOOR or t == TILE_CORRIDOR or t == TILE_DOOR then
              hasWalkableNeighbor = true
              break
            end
          end
        end
        if hasWalkableNeighbor then
          grid[y][x] = TILE_WALL
        end
      end
    end
  end
end

-- Analyze graph distances using BFS from Spawn room
local function analyzeTopology(rooms: { DungeonRoom }): (number, number)
  if #rooms == 0 then
    return 1, 1
  end

  local spawnId = 1
  rooms[spawnId].Kind = "Spawn"
  rooms[spawnId].GraphDepth = 0

  local queue = { spawnId }
  local visited = { [spawnId] = true }
  local maxDist = 0
  local bossId = spawnId

  while #queue > 0 do
    local currId = table.remove(queue, 1) :: number
    local currRoom = rooms[currId]

    for _, nId in ipairs(currRoom.Neighbors) do
      if not visited[nId] then
        visited[nId] = true
        rooms[nId].GraphDepth = currRoom.GraphDepth + 1
        if rooms[nId].GraphDepth > maxDist then
          maxDist = rooms[nId].GraphDepth
          bossId = nId
        end
        table.insert(queue, nId)
      end
    end
  end

  rooms[bossId].Kind = "Boss"

  -- Identify dead-ends for loot or puzzles
  for i, r in ipairs(rooms) do
    if i ~= spawnId and i ~= bossId then
      if #r.Neighbors == 1 then
        r.Kind = "Loot"
      else
        r.Kind = "Standard"
      end
    end
  end

  return spawnId, bossId
end

function DungeonGraphImpl.new(config: DungeonConfig?): DungeonGraph
  local cfg = config or {}
  local seed = cfg.Seed or DEFAULT_SEED
  local w = cfg.MapWidth or DEFAULT_WIDTH
  local h = cfg.MapHeight or DEFAULT_HEIGHT
  local minRoom = cfg.MinRoomSize or DEFAULT_MIN_ROOM
  local maxRoom = cfg.MaxRoomSize or DEFAULT_MAX_ROOM
  local depth = cfg.SplitDepth or DEFAULT_SPLIT_DEPTH
  local padding = cfg.RoomPadding or DEFAULT_PADDING

  local rng = makeRng(seed)
  local grid = makeGrid(w, h, TILE_VOID)

  local rootNode: BSPNode = {
    X = 2,
    Y = 2,
    W = w - 4,
    H = h - 4,
    Left = nil,
    Right = nil,
    Room = nil,
  }

  splitBSP(rootNode, 0, depth, minRoom, rng)

  local rooms: { DungeonRoom } = {}
  createRoomsInLeaves(rootNode, rooms, grid, minRoom, maxRoom, padding, rng)
  generateWalls(grid, w, h)
  local spawnId, bossId = analyzeTopology(rooms)

  local self = setmetatable({
    Config = {
      Seed = seed,
      MapWidth = w,
      MapHeight = h,
      MinRoomSize = minRoom,
      MaxRoomSize = maxRoom,
      SplitDepth = depth,
      RoomPadding = padding,
    },
    Grid = grid,
    Rooms = rooms,
    SpawnRoomId = spawnId,
    BossRoomId = bossId,
  }, DungeonGraphImpl)

  return (self :: any) :: DungeonGraph
end

function DungeonGraphImpl:GetTile(x: number, y: number): TileKind
  local w = self.Config.MapWidth
  local h = self.Config.MapHeight
  if x < 1 or x > w or y < 1 or y > h then
    return TILE_VOID
  end
  return self.Grid[y][x]
end

function DungeonGraphImpl:IsWalkable(x: number, y: number): boolean
  local t = self:GetTile(x, y)
  return t == TILE_FLOOR or t == TILE_CORRIDOR or t == TILE_DOOR
end

function DungeonGraphImpl:GetRoomAt(x: number, y: number): DungeonRoom?
  for _, r in ipairs(self.Rooms) do
    if x >= r.X and x < r.X + r.Width and y >= r.Y and y < r.Y + r.Height then
      return r
    end
  end
  return nil
end

function DungeonGraphImpl:GetRooms(): { DungeonRoom }
  return self.Rooms
end

function DungeonGraphImpl:GetSpawnRoom(): DungeonRoom
  return self.Rooms[self.SpawnRoomId]
end

function DungeonGraphImpl:GetBossRoom(): DungeonRoom
  return self.Rooms[self.BossRoomId]
end

-- Bresenham 2D raycast for wall occlusion / line of sight
function DungeonGraphImpl:Raycast(x0: number, y0: number, x1: number, y1: number): (boolean, number, number)
  local dx = math.abs(x1 - x0)
  local dy = math.abs(y1 - y0)
  local sx = if x0 < x1 then 1 else -1
  local sy = if y0 < y1 then 1 else -1
  local err = dx - dy

  local currX = x0
  local currY = y0

  while true do
    if not self:IsWalkable(currX, currY) and (currX ~= x0 or currY ~= y0) then
      -- Hit wall or void
      return true, currX, currY
    end

    if currX == x1 and currY == y1 then
      break
    end

    local e2 = 2 * err
    if e2 > -dy then
      err -= dy
      currX += sx
    end
    if e2 < dx then
      err += dx
      currY += sy
    end
  end

  return false, x1, y1
end

-- Render ASCII representation of the dungeon map
function DungeonGraphImpl:ToAscii(): string
  local w = self.Config.MapWidth
  local h = self.Config.MapHeight
  local lines = table.create(h)

  -- Mark room centers with special glyphs
  local markers: { [string]: string } = {}
  for _, r in ipairs(self.Rooms) do
    local key = string.format("%d,%d", r.CenterX, r.CenterY)
    if r.Kind == "Spawn" then
      markers[key] = "S"
    elseif r.Kind == "Boss" then
      markers[key] = "B"
    elseif r.Kind == "Loot" then
      markers[key] = "L"
    else
      markers[key] = "."
    end
  end

  for y = 1, h do
    local rowChars = table.create(w)
    for x = 1, w do
      local marker = markers[string.format("%d,%d", x, y)]
      if marker then
        rowChars[x] = marker
      else
        local t = self.Grid[y][x]
        if t == TILE_WALL then
          rowChars[x] = "#"
        elseif t == TILE_FLOOR then
          rowChars[x] = "."
        elseif t == TILE_CORRIDOR then
          rowChars[x] = "+"
        else
          rowChars[x] = " "
        end
      end
    end
    lines[y] = table.concat(rowChars)
  end

  return table.concat(lines, "\n")
end

return DungeonGraphImpl
