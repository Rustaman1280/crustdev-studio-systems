local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
_G.CFrame = roblox.CFrame

local InventoryGrid = require("../src/ReplicatedStorage/Economy/InventoryGrid")

-- Test 1: Grid initialization and dimensions
local grid = InventoryGrid.new(10, 6)
local cols, rows = grid:GetDimensions()
assert(cols == 10, "Columns must be 10")
assert(rows == 6, "Rows must be 6")
assert(grid:GetItemAt(1, 1) == nil, "Cell (1,1) should be initially empty")

-- Test 2: CanPlaceItem validation
assert(grid:CanPlaceItem(1, 1, 2, 3, false, nil) == true, "2x3 item should fit at (1,1)")
assert(grid:CanPlaceItem(10, 1, 2, 1, false, nil) == false, "2x1 item starting at col 10 overflows column bounds")
assert(grid:CanPlaceItem(1, 6, 1, 2, false, nil) == false, "1x2 item starting at row 6 overflows row bounds")
assert(grid:CanPlaceItem(10, 1, 2, 1, true, nil) == true, "2x1 item rotated becomes 1x2 and fits at col 10 row 1")

-- Test 3: AddItem with explicit position
local medkit = {
  Id = "medkit_01",
  ItemType = "Consumable",
  Width = 2,
  Height = 2,
  X = 1,
  Y = 1,
  Rotated = false,
  Quantity = 1,
  MaxStack = 1,
  Metadata = { HealthRestore = 50 },
}

local ok1, err1 = grid:AddItem(medkit, 1, 1)
assert(ok1 == true, string.format("AddItem should succeed, got error: %s", tostring(err1)))
assert(grid:GetItem("medkit_01") ~= nil, "medkit_01 should be retrievable")
assert(grid:GetItemAt(1, 1) ~= nil, "Cell (1,1) should reference medkit")
assert(grid:GetItemAt(2, 2) ~= nil, "Cell (2,2) should reference medkit")
assert(grid:GetItemAt(3, 1) == nil, "Cell (3,1) should remain empty")

-- Overlapping placement should fail
local overlappingItem = {
  Id = "potion_01",
  ItemType = "Consumable",
  Width = 2,
  Height = 1,
  X = 1,
  Y = 1,
  Rotated = false,
  Quantity = 1,
  MaxStack = 5,
}
local okOverlap, _ = grid:AddItem(overlappingItem, 2, 2)
assert(okOverlap == false, "Placing item overlapping (2,2) should fail")

-- Test 4: Automatic free-slot discovery
local okAuto, _ = grid:AddItem(overlappingItem, nil, nil)
assert(okAuto == true, "AddItem without coordinates should auto-find available slot")
assert(overlappingItem.X == 3 and overlappingItem.Y == 1, string.format("Auto slot should be (3,1), got (%d, %d)", overlappingItem.X, overlappingItem.Y))

-- Test 5: MoveItem
local moveSuccess = grid:MoveItem("potion_01", 5, 3)
assert(moveSuccess == true, "Moving potion to (5,3) should succeed")
assert(overlappingItem.X == 5 and overlappingItem.Y == 3, "Potion coordinates should be updated")
assert(grid:GetItemAt(3, 1) == nil, "Previous cell (3,1) should now be vacant")
assert(grid:GetItemAt(5, 3) ~= nil, "New cell (5,3) should contain potion")

-- Test 6: RotateItem
local rifle = {
  Id = "rifle_01",
  ItemType = "Weapon",
  Width = 4,
  Height = 1,
  X = 1,
  Y = 3,
  Rotated = false,
  Quantity = 1,
  MaxStack = 1,
}
local okRifle, _ = grid:AddItem(rifle, 1, 3)
assert(okRifle == true, "Rifle should be placed at (1,3)")
local rotateSuccess = grid:RotateItem("rifle_01")
assert(rotateSuccess == true, "Rifle should rotate to 1x4 at (1,3)")
assert(rifle.Rotated == true, "Rifle Rotated flag should be true")
assert(grid:GetItemAt(1, 3) ~= nil, "Cell (1,3) occupied")
assert(grid:GetItemAt(1, 4) ~= nil, "Cell (1,4) occupied by rotated height")
assert(grid:GetItemAt(1, 5) ~= nil, "Cell (1,5) occupied by rotated height")
assert(grid:GetItemAt(1, 6) ~= nil, "Cell (1,6) occupied by rotated height")
assert(grid:GetItemAt(2, 3) == nil, "Previous horizontal cell (2,3) should now be vacant")

-- Test 7: Stacking Items
local ammoA = {
  Id = "ammo_box_a",
  ItemType = "Ammo",
  Width = 1,
  Height = 1,
  X = 8,
  Y = 1,
  Rotated = false,
  Quantity = 20,
  MaxStack = 50,
}
local ammoB = {
  Id = "ammo_box_b",
  ItemType = "Ammo",
  Width = 1,
  Height = 1,
  X = 9,
  Y = 1,
  Rotated = false,
  Quantity = 40,
  MaxStack = 50,
}
grid:AddItem(ammoA, 8, 1)
grid:AddItem(ammoB, 9, 1)

local stackSuccess = grid:StackItem("ammo_box_a", "ammo_box_b")
assert(stackSuccess == true, "Stacking ammo should succeed")
assert(ammoB.Quantity == 50, string.format("ammo_box_b should be capped at MaxStack 50, got %d", ammoB.Quantity))
assert(ammoA.Quantity == 10, string.format("ammo_box_a should have remaining 10, got %d", ammoA.Quantity))

-- Stacking remainder to deplete source
local ammoC = {
  Id = "ammo_box_c",
  ItemType = "Ammo",
  Width = 1,
  Height = 1,
  X = 10,
  Y = 1,
  Rotated = false,
  Quantity = 30,
  MaxStack = 50,
}
grid:AddItem(ammoC, 10, 1)
grid:StackItem("ammo_box_a", "ammo_box_c")
assert(ammoC.Quantity == 40, "ammo_box_c should receive all 10 bullets")
assert(grid:GetItem("ammo_box_a") == nil, "ammo_box_a should be automatically removed when depleted to 0")

-- Test 8: SplitItem
local splitItem, splitErr = grid:SplitItem("ammo_box_c", 15, "ammo_box_d")
assert(splitItem ~= nil, string.format("SplitItem should succeed, got error: %s", tostring(splitErr)))
assert(ammoC.Quantity == 25, string.format("ammo_box_c should have 25 left, got %d", ammoC.Quantity))
assert(splitItem.Quantity == 15, "New stack should have 15 bullets")
assert(grid:GetItem("ammo_box_d") ~= nil, "New item ammo_box_d must exist in grid")

-- Test 9: Serialization and Deserialization
local serialized = grid:Serialize()
assert(serialized.Columns == 10, "Serialized columns must be 10")
assert(serialized.Rows == 6, "Serialized rows must be 6")
assert(serialized.Items["medkit_01"] ~= nil, "Serialized items must include medkit_01")
assert(serialized.Items["rifle_01"].Rotated == true, "Serialized rifle must preserve Rotated state")

local deserializedGrid = InventoryGrid.Deserialize(serialized)
local dCols, dRows = deserializedGrid:GetDimensions()
assert(dCols == 10 and dRows == 6, "Deserialized grid must match dimensions")
assert(deserializedGrid:GetItem("medkit_01") ~= nil, "Deserialized grid must contain medkit_01")
assert(deserializedGrid:GetItem("rifle_01").Rotated == true, "Deserialized rifle must remain rotated")

-- Test 10: AutoPack bin packing
local freshGrid = InventoryGrid.new(6, 6)
local itemsToPack = {
  { Id = "p1", ItemType = "A", Width = 3, Height = 2, X = 4, Y = 5, Rotated = false, Quantity = 1, MaxStack = 1 },
  { Id = "p2", ItemType = "B", Width = 2, Height = 4, X = 1, Y = 1, Rotated = false, Quantity = 1, MaxStack = 1 },
  { Id = "p3", ItemType = "C", Width = 1, Height = 1, X = 6, Y = 1, Rotated = false, Quantity = 1, MaxStack = 1 },
  { Id = "p4", ItemType = "D", Width = 2, Height = 2, X = 3, Y = 3, Rotated = false, Quantity = 1, MaxStack = 1 },
}
for _, item in ipairs(itemsToPack) do
  freshGrid:AddItem(item, item.X, item.Y)
end

local packResult = freshGrid:AutoPack()
assert(packResult == true, "AutoPack must succeed in packing items compactly")
-- Verify all items are placed and cells properly referenced
for _, item in ipairs(itemsToPack) do
  local placedItem = freshGrid:GetItem(item.Id)
  assert(placedItem ~= nil, string.format("Item %s must be present after pack", item.Id))
  assert(freshGrid:GetItemAt(placedItem.X, placedItem.Y) ~= nil, "Placed item root cell must be occupied")
end

print("PASS: InventoryGrid tests (Initialization, Bounds, Collision, Move, Rotate, Stacking, Splitting, Serialization, AutoPack) passed cleanly!")