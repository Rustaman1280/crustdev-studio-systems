local WaveFunctionCollapse = require("../src/ReplicatedStorage/Procedural/WaveFunctionCollapse")

-- Test 1: Initialization & Properties
local wfc = WaveFunctionCollapse.new({
  Width = 6,
  Height = 6,
  Depth = 1,
  Seed = 42,
})

assert(wfc.Width == 6 and wfc.Height == 6 and wfc.Depth == 1, "Grid dimensions mismatch")
assert(wfc.TotalCells == 36, "Total cells should be 36")
assert(wfc:IsCollapsed() == false, "Initially should not be collapsed")

-- Test 2: Register Tiles with Sockets
-- Tile types: "Water", "Sand", "Grass"
wfc:RegisterTile("Water", {
  Weight = 1.0,
  Sockets = {
    ["+X"] = "sea", ["-X"] = "sea", ["+Y"] = "sea", ["-Y"] = "sea",
    ["+Z"] = "sea", ["-Z"] = "sea",
  },
})

wfc:RegisterTile("Coast", {
  Weight = 1.0,
  Sockets = {
    ["+X"] = "beach", ["-X"] = "sea", ["+Y"] = "beach", ["-Y"] = "sea",
    ["+Z"] = "sea", ["-Z"] = "sea",
  },
})

wfc:RegisterTile("Sand", {
  Weight = 1.5,
  Sockets = {
    ["+X"] = "beach", ["-X"] = "beach", ["+Y"] = "beach", ["-Y"] = "beach",
    ["+Z"] = "beach", ["-Z"] = "beach",
  },
})

wfc:RegisterTile("Grass", {
  Weight = 2.0,
  Sockets = {
    ["+X"] = "land", ["-X"] = "land", ["+Y"] = "land", ["-Y"] = "land",
    ["+Z"] = "land", ["-Z"] = "land",
  },
})

assert(#wfc.TileList == 4, "TileList count must be 4")
assert(wfc.Tiles["Water"].Weight == 1.0, "Water weight mismatch")
assert(wfc.Tiles["Grass"].Weight == 2.0, "Grass weight mismatch")

-- Test 3: Explicit Adjacency Rules
-- Allow Sand and Grass to transition across all directions
for _, dir in ipairs({ "+X", "-X", "+Y", "-Y", "+Z", "-Z" }) do
  wfc:AddRule("Sand", dir, "Grass")
end

assert(wfc.Tiles["Sand"].Rules["+X"]["Grass"] == true, "Explicit rule Sand -> +X -> Grass must exist")
assert(wfc.Tiles["Grass"].Rules["-X"]["Sand"] == true, "Inverse rule Grass -> -X -> Sand must be set")

-- Test 4: Fixed Seed Collapse Run
local wfcGen = WaveFunctionCollapse.new({
  Width = 5,
  Height = 5,
  Seed = 10029,
})

-- Simple dungeon tiles: Floor, Wall, Door
wfcGen:RegisterTile("Floor", { Weight = 4.0 })
wfcGen:RegisterTile("Wall", { Weight = 2.0 })
wfcGen:RegisterTile("Door", { Weight = 0.5 })

-- Floor can be adjacent to Floor, Wall, Door
-- Door must be between Floor and Wall
local dirs = { "+X", "-X", "+Y", "-Y" }
for _, d in ipairs(dirs) do
  wfcGen:AddRule("Floor", d, "Floor")
  wfcGen:AddRule("Floor", d, "Wall")
  wfcGen:AddRule("Floor", d, "Door")
  wfcGen:AddRule("Wall", d, "Wall")
  wfcGen:AddRule("Door", d, "Floor")
end

local okCol, colErr = wfcGen:Collapse()
assert(okCol == true, "Collapse must succeed: " .. tostring(colErr))
assert(wfcGen:IsCollapsed() == true, "All cells should be collapsed")

-- Verify every cell has exactly 1 tile
local matrix = wfcGen:ToMatrix()
for x = 1, 5 do
  for y = 1, 5 do
    local tile = wfcGen:GetCell(x, y, 1)
    assert(tile ~= nil, "Cell must have a collapsed tile")
    assert(matrix[x][y][1] == tile, "Matrix cell must match GetCell")
  end
end

-- Test 5: Determinism Verification
local wfcGen2 = WaveFunctionCollapse.new({
  Width = 5,
  Height = 5,
  Seed = 10029,
})
wfcGen2:RegisterTile("Floor", { Weight = 4.0 })
wfcGen2:RegisterTile("Wall", { Weight = 2.0 })
wfcGen2:RegisterTile("Door", { Weight = 0.5 })
for _, d in ipairs(dirs) do
  wfcGen2:AddRule("Floor", d, "Floor")
  wfcGen2:AddRule("Floor", d, "Wall")
  wfcGen2:AddRule("Floor", d, "Door")
  wfcGen2:AddRule("Wall", d, "Wall")
  wfcGen2:AddRule("Door", d, "Floor")
end
wfcGen2:Collapse()

for x = 1, 5 do
  for y = 1, 5 do
    local t1 = wfcGen:GetCell(x, y, 1)
    local t2 = wfcGen2:GetCell(x, y, 1)
    assert(t1 == t2, string.format("Deterministic mismatch at (%d,%d): %s vs %s", x, y, tostring(t1), tostring(t2)))
  end
end

-- Test 6: Manual Pinning via SetCell
local wfcPin = WaveFunctionCollapse.new({
  Width = 4,
  Height = 4,
  Seed = 777,
})
wfcPin:RegisterTile("Floor", { Weight = 1.0 })
wfcPin:RegisterTile("Wall", { Weight = 1.0 })
for _, d in ipairs(dirs) do
  wfcPin:AddRule("Floor", d, "Floor")
  wfcPin:AddRule("Wall", d, "Wall")
  wfcPin:AddRule("Floor", d, "Wall")
end

-- Pin (1, 1) as Wall
local pinOk = wfcPin:SetCell(1, 1, 1, "Wall")
assert(pinOk == true, "Pinning (1,1) as Wall should succeed")
assert(wfcPin:GetCell(1, 1, 1) == "Wall", "(1,1) must be Wall")

local okPinCol = wfcPin:Collapse()
assert(okPinCol == true, "Collapse with pinned cell must succeed")
assert(wfcPin:GetCell(1, 1, 1) == "Wall", "(1,1) must remain Wall after collapse")

-- Test 7: 3D Grid WFC
local wfc3D = WaveFunctionCollapse.new({
  Width = 3,
  Height = 3,
  Depth = 3,
  Seed = 999,
})
wfc3D:RegisterTile("Air", { Weight = 2.0 })
wfc3D:RegisterTile("Stone", { Weight = 1.0 })
local allDirs = { "+X", "-X", "+Y", "-Y", "+Z", "-Z" }
for _, d in ipairs(allDirs) do
  wfc3D:AddRule("Air", d, "Air")
  wfc3D:AddRule("Stone", d, "Stone")
  wfc3D:AddRule("Air", d, "Stone")
end

local ok3D = wfc3D:Collapse()
assert(ok3D == true, "3D WFC collapse must succeed")
assert(wfc3D:IsCollapsed() == true, "3D WFC must be fully collapsed")

-- Test 8: ASCII Rendering
local ascii = wfcGen:RenderASCII(1, {
  ["Floor"] = ".",
  ["Wall"] = "#",
  ["Door"] = "+",
})
assert(type(ascii) == "string" and #ascii > 0, "ASCII rendering should return non-empty string")
assert(string.find(ascii, "\n") ~= nil, "ASCII output should contain multiple lines")

print("PASS: WaveFunctionCollapse tests (Init, Sockets, ExplicitRules, Collapse, Determinism, SetCell, 3D, ASCII) passed cleanly!")
