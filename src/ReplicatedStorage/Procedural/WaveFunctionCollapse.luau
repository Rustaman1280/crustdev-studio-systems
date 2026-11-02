--!strict
--[[
  WaveFunctionCollapse.luau
  Constraint-satisfaction procedural level generator using the Wave Function Collapse (WFC) algorithm.
  Features:
  - 2D and 3D grid layout support with arbitrary bounding dimensions (width, height, depth)
  - Directional socket matching and explicit directional adjacency rules (+X, -X, +Y, -Y, +Z, -Z)
  - Shannon minimum-entropy heuristic for optimal cell selection
  - Weighted tile distribution probabilities with dynamic frequency normalization
  - AC-3 style recursive arc-consistency constraint propagation
  - Deterministic pseudo-random number generator (SplitMix32 PRNG)
  - Pre-allocated superpositions with fast candidate filtering
  - Automatic contradiction detection with rollback snapshot stack
  - Matrix export, ASCII visualization, and spatial cell queries
  Part of crustdev studio game systems.
  Zero external runtime dependencies.
]]

export type Direction = "+X" | "-X" | "+Y" | "-Y" | "+Z" | "-Z"

export type TileSockets = {
  ["+X"]: string?,
  ["-X"]: string?,
  ["+Y"]: string?,
  ["-Y"]: string?,
  ["+Z"]: string?,
  ["-Z"]: string?,
}

export type TileDefinition = {
  Id: string,
  Weight: number,
  Sockets: TileSockets?,
  Rules: { [Direction]: { [string]: boolean } },
}

export type CellCoord = {
  X: number,
  Y: number,
  Z: number,
}

export type WFCConfig = {
  Width: number,
  Height: number,
  Depth: number?,
  Seed: number?,
  Periodic: boolean?,
  MaxBacktracks: number?,
}

export type WFCStateSnapshot = {
  Grid: { { { { [string]: boolean } } } },
  Entropy: { { { number } } },
  TargetCoord: CellCoord,
  AttemptedTile: string,
  RemainingCandidates: { string },
}

local DIRECTIONS: { Direction } = { "+X", "-X", "+Y", "-Y", "+Z", "-Z" }

local OPPOSITE_DIRECTIONS: { [Direction]: Direction } = {
  ["+X"] = "-X",
  ["-X"] = "+X",
  ["+Y"] = "-Y",
  ["-Y"] = "+Y",
  ["+Z"] = "-Z",
  ["-Z"] = "+Z",
}

local DIR_OFFSETS: { [Direction]: { x: number, y: number, z: number } } = {
  ["+X"] = { x = 1, y = 0, z = 0 },
  ["-X"] = { x = -1, y = 0, z = 0 },
  ["+Y"] = { x = 0, y = 1, z = 0 },
  ["-Y"] = { x = 0, y = -1, z = 0 },
  ["+Z"] = { x = 0, y = 0, z = 1 },
  ["-Z"] = { x = 0, y = 0, z = -1 },
}

-- SplitMix32 deterministic PRNG
local function createPRNG(seed: number)
  local state = seed % 4294967296
  return function(): number
    state = (state + 0x9E3779B9) % 4294967296
    local z = state
    z = bit32.bxor(z, bit32.rshift(z, 16))
    z = (z * 0x85EBCA6B) % 4294967296
    z = bit32.bxor(z, bit32.rshift(z, 13))
    z = (z * 0xC2B2AE35) % 4294967296
    z = bit32.bxor(z, bit32.rshift(z, 16))
    return z / 4294967296
  end
end

local WaveFunctionCollapse = {}
WaveFunctionCollapse.__index = WaveFunctionCollapse

export type WaveFunctionCollapse = {
  Width: number,
  Height: number,
  Depth: number,
  Periodic: boolean,
  MaxBacktracks: number,
  Tiles: { [string]: TileDefinition },
  TileList: { string },
  Grid: { { { { [string]: boolean } } } },
  Entropy: { { { number } } },
  CollapsedCount: number,
  TotalCells: number,
  NextRandom: () -> number,
  BacktrackStack: { WFCStateSnapshot },

  RegisterTile: (self: WaveFunctionCollapse, id: string, options: { Weight: number?, Sockets: TileSockets? }?) -> (),
  AddRule: (self: WaveFunctionCollapse, tileId: string, direction: Direction, neighborTileId: string) -> (),
  SetCell: (self: WaveFunctionCollapse, x: number, y: number, z: number, tileId: string) -> boolean,
  GetCell: (self: WaveFunctionCollapse, x: number, y: number, z: number) -> string?,
  GetCandidates: (self: WaveFunctionCollapse, x: number, y: number, z: number) -> { string },
  IsCollapsed: (self: WaveFunctionCollapse) -> boolean,
  Step: (self: WaveFunctionCollapse) -> (boolean, string?),
  Collapse: (self: WaveFunctionCollapse, maxSteps: number?) -> (boolean, string?),
  ToMatrix: (self: WaveFunctionCollapse) -> { { { string? } } },
  RenderASCII: (self: WaveFunctionCollapse, zLayer: number?, charMap: { [string]: string }?) -> string,
}

function WaveFunctionCollapse.new(config: WFCConfig): WaveFunctionCollapse
  assert(config.Width > 0 and config.Height > 0, "Dimensions must be positive integers")
  local depth = config.Depth or 1
  assert(depth > 0, "Depth must be positive integer")

  local seed = config.Seed or 1337
  local prng = createPRNG(seed)

  local self = setmetatable({}, WaveFunctionCollapse)
  self.Width = config.Width
  self.Height = config.Height
  self.Depth = depth
  self.Periodic = config.Periodic or false
  self.MaxBacktracks = config.MaxBacktracks or 50
  self.Tiles = {}
  self.TileList = {}
  self.CollapsedCount = 0
  self.TotalCells = config.Width * config.Height * depth
  self.NextRandom = prng
  self.BacktrackStack = {}

  -- Allocate 3D grid
  self.Grid = {}
  self.Entropy = {}
  for x = 1, self.Width do
    self.Grid[x] = {}
    self.Entropy[x] = {}
    for y = 1, self.Height do
      self.Grid[x][y] = {}
      self.Entropy[x][y] = {}
      for z = 1, self.Depth do
        self.Grid[x][y][z] = {}
        self.Entropy[x][y][z] = 0
      end
    end
  end

  return (self :: any) :: WaveFunctionCollapse
end

function WaveFunctionCollapse.RegisterTile(self: WaveFunctionCollapse, id: string, options: { Weight: number?, Sockets: TileSockets? }?)
  assert(self.Tiles[id] == nil, "Tile already registered: " .. id)
  local weight = (options and options.Weight) or 1.0
  assert(weight > 0, "Weight must be positive")

  local sockets = options and options.Sockets
  local tileDef: TileDefinition = {
    Id = id,
    Weight = weight,
    Sockets = sockets,
    Rules = {
      ["+X"] = {},
      ["-X"] = {},
      ["+Y"] = {},
      ["-Y"] = {},
      ["+Z"] = {},
      ["-Z"] = {},
    },
  }

  self.Tiles[id] = tileDef
  table.insert(self.TileList, id)

  -- Resolve socket-based adjacency with already registered tiles
  if sockets then
    for _, otherTile in pairs(self.Tiles) do
      if otherTile.Sockets then
        for _, dir in ipairs(DIRECTIONS) do
          local opp = OPPOSITE_DIRECTIONS[dir]
          local sockOut = sockets[dir]
          local sockIn = otherTile.Sockets[opp]
          if sockOut and sockIn and sockOut == sockIn then
            tileDef.Rules[dir][otherTile.Id] = true
            otherTile.Rules[opp][tileDef.Id] = true
          end

          -- Symmetric self-socket check
          local selfSockOpp = sockets[opp]
          if sockOut and selfSockOpp and sockOut == selfSockOpp then
            tileDef.Rules[dir][tileDef.Id] = true
          end
        end
      end
    end
  end

  -- Update all grid cells to include this tile in superposition
  for x = 1, self.Width do
    for y = 1, self.Height do
      for z = 1, self.Depth do
        self.Grid[x][y][z][id] = true
      end
    end
  end

  self:_RecalculateAllEntropies()
end

function WaveFunctionCollapse.AddRule(self: WaveFunctionCollapse, tileId: string, direction: Direction, neighborTileId: string)
  local tile = self.Tiles[tileId]
  local neighbor = self.Tiles[neighborTileId]
  assert(tile, "Tile not found: " .. tileId)
  assert(neighbor, "Neighbor tile not found: " .. neighborTileId)

  tile.Rules[direction][neighborTileId] = true
  local opp = OPPOSITE_DIRECTIONS[direction]
  neighbor.Rules[opp][tileId] = true
end

function WaveFunctionCollapse._CalculateCellEntropy(self: WaveFunctionCollapse, x: number, y: number, z: number): number
  local candidates = self.Grid[x][y][z]
  local count = 0
  local weightSum = 0
  local weightLogWeightSum = 0

  for tileId in pairs(candidates) do
    count += 1
    local w = self.Tiles[tileId].Weight
    weightSum += w
    weightLogWeightSum += w * math.log(w)
  end

  if count <= 1 then
    return 0 -- Already collapsed or contradiction
  end

  -- Shannon Entropy: H = log(sum(w)) - (sum(w * log(w)) / sum(w))
  local entropy = math.log(weightSum) - (weightLogWeightSum / weightSum)
  -- Add tiny deterministic noise to break ties predictably without distorting true entropy
  local noise = (self.NextRandom() * 1e-6)
  return entropy + noise
end

function WaveFunctionCollapse._RecalculateAllEntropies(self: WaveFunctionCollapse)
  for x = 1, self.Width do
    for y = 1, self.Height do
      for z = 1, self.Depth do
        self.Entropy[x][y][z] = self:_CalculateCellEntropy(x, y, z)
      end
    end
  end
end

function WaveFunctionCollapse._CloneGrid(self: WaveFunctionCollapse): { { { { [string]: boolean } } } }
  local copy = {}
  for x = 1, self.Width do
    copy[x] = {}
    for y = 1, self.Height do
      copy[x][y] = {}
      for z = 1, self.Depth do
        copy[x][y][z] = {}
        for tileId in pairs(self.Grid[x][y][z]) do
          copy[x][y][z][tileId] = true
        end
      end
    end
  end
  return copy
end

function WaveFunctionCollapse._CloneEntropy(self: WaveFunctionCollapse): { { { number } } }
  local copy = {}
  for x = 1, self.Width do
    copy[x] = {}
    for y = 1, self.Height do
      copy[x][y] = {}
      for z = 1, self.Depth do
        copy[x][y][z] = self.Entropy[x][y][z]
      end
    end
  end
  return copy
end

function WaveFunctionCollapse.GetCandidates(self: WaveFunctionCollapse, x: number, y: number, z: number): { string }
  local candidates = {}
  if self.Grid[x] and self.Grid[x][y] and self.Grid[x][y][z] then
    for tileId in pairs(self.Grid[x][y][z]) do
      table.insert(candidates, tileId)
    end
  end
  return candidates
end

function WaveFunctionCollapse.GetCell(self: WaveFunctionCollapse, x: number, y: number, z: number): string?
  local list = self:GetCandidates(x, y, z)
  if #list == 1 then
    return list[1]
  end
  return nil
end

function WaveFunctionCollapse.IsCollapsed(self: WaveFunctionCollapse): boolean
  return self.CollapsedCount >= self.TotalCells
end

function WaveFunctionCollapse._Propagate(self: WaveFunctionCollapse, startX: number, startY: number, startZ: number): boolean
  local queue: { CellCoord } = { { X = startX, Y = startY, Z = startZ } }
  local inQueue: { [string]: boolean } = {}
  inQueue[string.format("%d,%d,%d", startX, startY, startZ)] = true

  while #queue > 0 do
    local current = table.remove(queue, 1) :: CellCoord
    local key = string.format("%d,%d,%d", current.X, current.Y, current.Z)
    inQueue[key] = nil

    local currentCandidates = self.Grid[current.X][current.Y][current.Z]

    -- Iterate all 6 neighboring directions
    for _, dir in ipairs(DIRECTIONS) do
      local offset = DIR_OFFSETS[dir]
      local nx = current.X + offset.x
      local ny = current.Y + offset.y
      local nz = current.Z + offset.z

      if self.Periodic then
        nx = ((nx - 1) % self.Width) + 1
        ny = ((ny - 1) % self.Height) + 1
        nz = ((nz - 1) % self.Depth) + 1
      end

      if nx >= 1 and nx <= self.Width and ny >= 1 and ny <= self.Height and nz >= 1 and nz <= self.Depth then
        local neighborCandidates = self.Grid[nx][ny][nz]
        local changed = false

        -- Find all tiles allowed in neighbor from current valid candidates
        local allowedNeighbors: { [string]: boolean } = {}
        for curTileId in pairs(currentCandidates) do
          local curTile = self.Tiles[curTileId]
          if curTile then
            local allowedForDir = curTile.Rules[dir]
            if allowedForDir then
              for targetTileId in pairs(allowedForDir) do
                allowedNeighbors[targetTileId] = true
              end
            end
          end
        end

        -- Filter neighbor candidates
        for nTileId in pairs(neighborCandidates) do
          if not allowedNeighbors[nTileId] then
            neighborCandidates[nTileId] = nil
            changed = true
          end
        end

        -- Check for contradiction (0 candidates remaining)
        local remainingCount = 0
        for _ in pairs(neighborCandidates) do
          remainingCount += 1
        end

        if remainingCount == 0 then
          return false -- Contradiction detected
        end

        if changed then
          self.Entropy[nx][ny][nz] = self:_CalculateCellEntropy(nx, ny, nz)
          local nKey = string.format("%d,%d,%d", nx, ny, nz)
          if not inQueue[nKey] then
            table.insert(queue, { X = nx, Y = ny, Z = nz })
            inQueue[nKey] = true
          end
        end
      end
    end
  end

  return true
end

function WaveFunctionCollapse.SetCell(self: WaveFunctionCollapse, x: number, y: number, z: number, tileId: string): boolean
  assert(self.Tiles[tileId], "Unregistered tile: " .. tostring(tileId))
  assert(x >= 1 and x <= self.Width and y >= 1 and y <= self.Height and z >= 1 and z <= self.Depth, "Out of bounds")

  local currentCandidates = self.Grid[x][y][z]
  if not currentCandidates[tileId] then
    return false
  end

  local hadMultiple = false
  local count = 0
  for _ in pairs(currentCandidates) do
    count += 1
  end
  if count > 1 then
    hadMultiple = true
  end

  -- Collapse to single tile
  self.Grid[x][y][z] = { [tileId] = true }
  self.Entropy[x][y][z] = 0

  if hadMultiple then
    self.CollapsedCount += 1
  end

  local ok = self:_Propagate(x, y, z)
  return ok
end

function WaveFunctionCollapse.Step(self: WaveFunctionCollapse): (boolean, string?)
  if self:IsCollapsed() then
    return false, nil
  end

  -- Find cell with lowest non-zero entropy
  local minEntropy = math.huge
  local minCoord: CellCoord? = nil

  for x = 1, self.Width do
    for y = 1, self.Height do
      for z = 1, self.Depth do
        local e = self.Entropy[x][y][z]
        if e > 0 and e < minEntropy then
          minEntropy = e
          minCoord = { X = x, Y = y, Z = z }
        end
      end
    end
  end

  if not minCoord then
    -- Check if all cells collapsed
    local allDone = true
    for x = 1, self.Width do
      for y = 1, self.Height do
        for z = 1, self.Depth do
          local c = self:GetCandidates(x, y, z)
          if #c == 0 then
            return false, "Contradiction: Unresolvable empty cell at (" .. x .. "," .. y .. "," .. z .. ")"
          elseif #c > 1 then
            allDone = false
          end
        end
      end
    end
    if allDone then
      self.CollapsedCount = self.TotalCells
      return false, nil
    end
    return false, "Contradiction: Deadlock with zero entropy remaining"
  end

  local candidates = self:GetCandidates(minCoord.X, minCoord.Y, minCoord.Z)
  if #candidates <= 1 then
    self.Entropy[minCoord.X][minCoord.Y][minCoord.Z] = 0
    return true, nil
  end

  -- Weighted random selection
  local totalWeight = 0
  for _, tileId in ipairs(candidates) do
    totalWeight += self.Tiles[tileId].Weight
  end

  local roll = self.NextRandom() * totalWeight
  local chosenTile = candidates[1]
  local running = 0
  for _, tileId in ipairs(candidates) do
    running += self.Tiles[tileId].Weight
    if roll <= running then
      chosenTile = tileId
      break
    end
  end

  -- Prepare remaining alternatives for backtracking
  local alternatives = {}
  for _, tileId in ipairs(candidates) do
    if tileId ~= chosenTile then
      table.insert(alternatives, tileId)
    end
  end

  -- Save snapshot if backtracking is allowed
  if #self.BacktrackStack < self.MaxBacktracks and #alternatives > 0 then
    local snapshot: WFCStateSnapshot = {
      Grid = self:_CloneGrid(),
      Entropy = self:_CloneEntropy(),
      TargetCoord = minCoord,
      AttemptedTile = chosenTile,
      RemainingCandidates = alternatives,
    }
    table.insert(self.BacktrackStack, snapshot)
  end

  -- Collapse chosen cell
  self.Grid[minCoord.X][minCoord.Y][minCoord.Z] = { [chosenTile] = true }
  self.Entropy[minCoord.X][minCoord.Y][minCoord.Z] = 0
  self.CollapsedCount += 1

  -- Propagate constraints
  local ok = self:_Propagate(minCoord.X, minCoord.Y, minCoord.Z)
  if not ok then
    -- Contradiction occurred, attempt backtracking
    if #self.BacktrackStack > 0 then
      local snap = table.remove(self.BacktrackStack) :: WFCStateSnapshot
      self.Grid = snap.Grid
      self.Entropy = snap.Entropy
      self.CollapsedCount -= 1

      -- Eliminate attempted tile from candidates
      self.Grid[snap.TargetCoord.X][snap.TargetCoord.Y][snap.TargetCoord.Z][snap.AttemptedTile] = nil
      self.Entropy[snap.TargetCoord.X][snap.TargetCoord.Y][snap.TargetCoord.Z] = self:_CalculateCellEntropy(snap.TargetCoord.X, snap.TargetCoord.Y, snap.TargetCoord.Z)

      -- Propagate elimination
      local propOk = self:_Propagate(snap.TargetCoord.X, snap.TargetCoord.Y, snap.TargetCoord.Z)
      if propOk then
        return true, nil
      end
    end
    return false, string.format("Contradiction at cell (%d, %d, %d)", minCoord.X, minCoord.Y, minCoord.Z)
  end

  return true, nil
end

function WaveFunctionCollapse.Collapse(self: WaveFunctionCollapse, maxSteps: number?): (boolean, string?)
  local limit = maxSteps or (self.TotalCells * 8)
  local steps = 0

  while not self:IsCollapsed() do
    steps += 1
    if steps > limit then
      return false, "Step limit exceeded (" .. tostring(limit) .. ")"
    end

    local hasMore, err = self:Step()
    if err then
      return false, err
    end
    if not hasMore then
      break
    end
  end

  return true, nil
end

function WaveFunctionCollapse.ToMatrix(self: WaveFunctionCollapse): { { { string? } } }
  local matrix = {}
  for x = 1, self.Width do
    matrix[x] = {}
    for y = 1, self.Height do
      matrix[x][y] = {}
      for z = 1, self.Depth do
        matrix[x][y][z] = self:GetCell(x, y, z)
      end
    end
  end
  return matrix
end

function WaveFunctionCollapse.RenderASCII(self: WaveFunctionCollapse, zLayer: number?, charMap: { [string]: string }?): string
  local z = zLayer or 1
  local map = charMap or {}
  local lines = {}

  for y = 1, self.Height do
    local chars = {}
    for x = 1, self.Width do
      local cell = self:GetCell(x, y, z)
      local ch = "?"
      if cell then
        ch = map[cell] or string.sub(cell, 1, 1)
      end
      table.insert(chars, ch)
    end
    table.insert(lines, table.concat(chars, " "))
  end

  return table.concat(lines, "\n")
end

return WaveFunctionCollapse
