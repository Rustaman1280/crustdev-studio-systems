local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

print("=== crustdev studio systems Luau test suite ===")

local tests = {
  { name = "SpatialHashGrid", path = "./test_spatial" },
  { name = "PacketSchema", path = "./test_packet" },
  { name = "RollbackBuffer", path = "./test_rollback" },
  { name = "SnapshotInterpolator", path = "./test_interpolator" },
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
