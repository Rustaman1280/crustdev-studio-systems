--!strict
--[[
  InventoryGrid.luau
  2D spatial matrix inventory system with rotation, stack management, and auto-pack heuristics.
  Part of crustdev studio game systems (survival, RPG, and tactical inventory).
  Features:
    - 2D grid matrix with cell occupancy tracking.
    - Multi-cell items with 90-degree spatial rotation.
    - Spatial collision validation: CanPlaceItem with ignore exclusion.
    - Stack merging and quantity splitting for stackable goods.
    - AutoPack: greedy First-Fit Decreasing (FFD) 2D bin packing.
    - Serializable network format for client-server state replication.
]]

export type GridItem = {
  Id: string,
  ItemType: string,
  Width: number,              -- Horizontal cell span (1 to N)
  Height: number,             -- Vertical cell span (1 to N)
  X: number,                  -- 1-based column coordinate
  Y: number,                  -- 1-based row coordinate
  Rotated: boolean,           -- Swaps effective width and height
  Quantity: number,
  MaxStack: number,
  Metadata: { [string]: any }?,
}

export type SerializedGrid = {
  Columns: number,
  Rows: number,
  Items: { [string]: any },
}

export type InventoryGrid = {
  GetDimensions: (self: InventoryGrid) -> (number, number),
  GetItem: (self: InventoryGrid, id: string) -> GridItem?,
  GetItemAt: (self: InventoryGrid, x: number, y: number) -> GridItem?,
  CanPlaceItem: (
    self: InventoryGrid,
    x: number,
    y: number,
    width: number,
    height: number,
    rotated: boolean,
    ignoreItemId: string?
  ) -> boolean,
  AddItem: (self: InventoryGrid, item: GridItem, targetX: number?, targetY: number?) -> (boolean, string?),
  RemoveItem: (self: InventoryGrid, id: string) -> GridItem?,
  MoveItem: (self: InventoryGrid, id: string, newX: number, newY: number) -> boolean,
  RotateItem: (self: InventoryGrid, id: string) -> boolean,
  StackItem: (self: InventoryGrid, sourceId: string, targetId: string) -> boolean,
  SplitItem: (self: InventoryGrid, sourceId: string, splitAmount: number, newId: string) -> (GridItem?, string?),
  AutoPack: (self: InventoryGrid) -> boolean,
  GetAllItems: (self: InventoryGrid) -> { [string]: GridItem },
  Serialize: (self: InventoryGrid) -> SerializedGrid,
}

type InternalGrid = InventoryGrid & {
  _columns: number,
  _rows: number,
  _items: { [string]: GridItem },
  _cells: { [number]: { [number]: string? } }, -- [row][col] -> ItemId
}

local InventoryGrid = {}
InventoryGrid.__index = InventoryGrid

local function getEffectiveDimensions(item: GridItem): (number, number)
  if item.Rotated then
    return item.Height, item.Width
  else
    return item.Width, item.Height
  end
end

function InventoryGrid.new(columns: number, rows: number): InventoryGrid
  local self = setmetatable({
    _columns = math.max(1, math.floor(columns)),
    _rows = math.max(1, math.floor(rows)),
    _items = {},
    _cells = {},
  }, InventoryGrid)

  local internal = self :: InternalGrid
  for r = 1, internal._rows do
    internal._cells[r] = {}
    for c = 1, internal._columns do
      internal._cells[r][c] = nil
    end
  end

  return (self :: any) :: InventoryGrid
end

function InventoryGrid.GetDimensions(self: InventoryGrid): (number, number)
  local internal = self :: InternalGrid
  return internal._columns, internal._rows
end

function InventoryGrid.GetItem(self: InventoryGrid, id: string): GridItem?
  local internal = self :: InternalGrid
  return internal._items[id]
end

function InventoryGrid.GetItemAt(self: InventoryGrid, x: number, y: number): GridItem?
  local internal = self :: InternalGrid
  if x < 1 or x > internal._columns or y < 1 or y > internal._rows then
    return nil
  end
  local itemId = internal._cells[y][x]
  if itemId then
    return internal._items[itemId]
  end
  return nil
end

function InventoryGrid.CanPlaceItem(
  self: InventoryGrid,
  x: number,
  y: number,
  width: number,
  height: number,
  rotated: boolean,
  ignoreItemId: string?
): boolean
  local internal = self :: InternalGrid
  local effW = if rotated then height else width
  local effH = if rotated then width else height

  if x < 1 or y < 1 or (x + effW - 1) > internal._columns or (y + effH - 1) > internal._rows then
    return false
  end

  for r = y, y + effH - 1 do
    for c = x, x + effW - 1 do
      local occ = internal._cells[r][c]
      if occ ~= nil and occ ~= ignoreItemId then
        return false
      end
    end
  end

  return true
end

local function occupyCells(internal: InternalGrid, item: GridItem)
  local effW, effH = getEffectiveDimensions(item)
  for r = item.Y, item.Y + effH - 1 do
    for c = item.X, item.X + effW - 1 do
      internal._cells[r][c] = item.Id
    end
  end
end

local function clearCells(internal: InternalGrid, item: GridItem)
  local effW, effH = getEffectiveDimensions(item)
  for r = item.Y, item.Y + effH - 1 do
    for c = item.X, item.X + effW - 1 do
      if internal._cells[r][c] == item.Id then
        internal._cells[r][c] = nil
      end
    end
  end
end

function InventoryGrid.AddItem(
  self: InventoryGrid,
  item: GridItem,
  targetX: number?,
  targetY: number?
): (boolean, string?)
  local internal = self :: InternalGrid
  if internal._items[item.Id] then
    return false, "Item with ID already exists"
  end

  local effW, effH = getEffectiveDimensions(item)

  if targetX and targetY then
    if not self:CanPlaceItem(targetX, targetY, item.Width, item.Height, item.Rotated, nil) then
      return false, "Target cell is occupied or out of bounds"
    end
    item.X = targetX
    item.Y = targetY
  else
    -- Search for first available free slot
    local found = false
    for r = 1, internal._rows - effH + 1 do
      for c = 1, internal._columns - effW + 1 do
        if self:CanPlaceItem(c, r, item.Width, item.Height, item.Rotated, nil) then
          item.X = c
          item.Y = r
          found = true
          break
        end
      end
      if found then break end
    end

    if not found then
      return false, "No suitable space available in inventory"
    end
  end

  internal._items[item.Id] = item
  occupyCells(internal, item)
  return true, nil
end

function InventoryGrid.RemoveItem(self: InventoryGrid, id: string): GridItem?
  local internal = self :: InternalGrid
  local item = internal._items[id]
  if not item then
    return nil
  end

  clearCells(internal, item)
  internal._items[id] = nil
  return item
end

function InventoryGrid.MoveItem(self: InventoryGrid, id: string, newX: number, newY: number): boolean
  local internal = self :: InternalGrid
  local item = internal._items[id]
  if not item then
    return false
  end

  if not self:CanPlaceItem(newX, newY, item.Width, item.Height, item.Rotated, id) then
    return false
  end

  clearCells(internal, item)
  item.X = newX
  item.Y = newY
  occupyCells(internal, item)
  return true
end

function InventoryGrid.RotateItem(self: InventoryGrid, id: string): boolean
  local internal = self :: InternalGrid
  local item = internal._items[id]
  if not item then
    return false
  end

  local newRotated = not item.Rotated
  if not self:CanPlaceItem(item.X, item.Y, item.Width, item.Height, newRotated, id) then
    return false
  end

  clearCells(internal, item)
  item.Rotated = newRotated
  occupyCells(internal, item)
  return true
end

function InventoryGrid.StackItem(self: InventoryGrid, sourceId: string, targetId: string): boolean
  local internal = self :: InternalGrid
  local source = internal._items[sourceId]
  local target = internal._items[targetId]
  if not source or not target or sourceId == targetId then
    return false
  end

  if source.ItemType ~= target.ItemType then
    return false
  end

  local availableSpace = target.MaxStack - target.Quantity
  if availableSpace <= 0 then
    return false
  end

  local transferAmount = math.min(source.Quantity, availableSpace)
  target.Quantity += transferAmount
  source.Quantity -= transferAmount

  if source.Quantity <= 0 then
    self:RemoveItem(sourceId)
  end

  return true
end

function InventoryGrid.SplitItem(
  self: InventoryGrid,
  sourceId: string,
  splitAmount: number,
  newId: string
): (GridItem?, string?)
  local internal = self :: InternalGrid
  local source = internal._items[sourceId]
  if not source then
    return nil, "Source item not found"
  end

  if splitAmount <= 0 or splitAmount >= source.Quantity then
    return nil, "Invalid split amount"
  end

  if internal._items[newId] then
    return nil, "Target item ID already exists"
  end

  local newItem: GridItem = {
    Id = newId,
    ItemType = source.ItemType,
    Width = source.Width,
    Height = source.Height,
    X = 1,
    Y = 1,
    Rotated = false,
    Quantity = splitAmount,
    MaxStack = source.MaxStack,
    Metadata = {},
  }

  local success, err = self:AddItem(newItem, nil, nil)
  if not success then
    return nil, err or "Failed to place split stack"
  end

  source.Quantity -= splitAmount
  return newItem, nil
end

function InventoryGrid.AutoPack(self: InventoryGrid): boolean
  local internal = self :: InternalGrid

  -- Collect and detach all items
  local itemList: { GridItem } = {}
  for _, item in pairs(internal._items) do
    clearCells(internal, item)
    table.insert(itemList, item)
  end

  -- Sort by decreasing footprint area (Width * Height), secondary by max dimension
  table.sort(itemList, function(a, b)
    local areaA = a.Width * a.Height
    local areaB = b.Width * b.Height
    if areaA ~= areaB then
      return areaA > areaB
    end
    return math.max(a.Width, a.Height) > math.max(b.Width, b.Height)
  end)

  -- First-Fit Decreasing placement
  local placed: { GridItem } = {}
  for _, item in ipairs(itemList) do
    local fits = false
    -- Try default rotation first, then flipped rotation if it doesn't fit
    local rotations = { false, true }
    for _, rot in ipairs(rotations) do
      local effW = if rot then item.Height else item.Width
      local effH = if rot then item.Width else item.Height

      for r = 1, internal._rows - effH + 1 do
        for c = 1, internal._columns - effW + 1 do
          if self:CanPlaceItem(c, r, item.Width, item.Height, rot, nil) then
            item.X = c
            item.Y = r
            item.Rotated = rot
            occupyCells(internal, item)
            table.insert(placed, item)
            fits = true
            break
          end
        end
        if fits then break end
      end
      if fits then break end
    end

    if not fits then
      -- Rollback placed cells and restore
      for _, p in ipairs(placed) do
        clearCells(internal, p)
      end
      for _, orig in ipairs(itemList) do
        occupyCells(internal, orig)
      end
      return false
    end
  end

  return true
end

function InventoryGrid.GetAllItems(self: InventoryGrid): { [string]: GridItem }
  local internal = self :: InternalGrid
  local copy = {}
  for k, v in pairs(internal._items) do
    copy[k] = v
  end
  return copy
end

function InventoryGrid.Serialize(self: InventoryGrid): SerializedGrid
  local internal = self :: InternalGrid
  local serializedItems = {}
  for id, item in pairs(internal._items) do
    serializedItems[id] = {
      Id = item.Id,
      ItemType = item.ItemType,
      Width = item.Width,
      Height = item.Height,
      X = item.X,
      Y = item.Y,
      Rotated = item.Rotated,
      Quantity = item.Quantity,
      MaxStack = item.MaxStack,
      Metadata = item.Metadata,
    }
  end

  return {
    Columns = internal._columns,
    Rows = internal._rows,
    Items = serializedItems,
  }
end

function InventoryGrid.Deserialize(data: SerializedGrid): InventoryGrid
  local grid = InventoryGrid.new(data.Columns, data.Rows)
  for _, itemData in pairs(data.Items) do
    local item: GridItem = {
      Id = itemData.Id,
      ItemType = itemData.ItemType,
      Width = itemData.Width,
      Height = itemData.Height,
      X = itemData.X,
      Y = itemData.Y,
      Rotated = itemData.Rotated,
      Quantity = itemData.Quantity,
      MaxStack = itemData.MaxStack,
      Metadata = itemData.Metadata,
    }
    grid:AddItem(item, item.X, item.Y)
  end
  return grid
end

return InventoryGrid