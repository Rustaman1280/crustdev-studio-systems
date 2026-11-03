--!strict
local roblox = require("@lune/roblox")
_G.Vector3 = roblox.Vector3
Vector3 = roblox.Vector3

local VoronoiDiagram = require("../src/ReplicatedStorage/Procedural/VoronoiDiagram")

local function assertApprox(a: number, b: number, eps: number?, msg: string?)
  local epsilon = eps or 1e-3
  if math.abs(a - b) > epsilon then
    error(string.format("%s: expected approx %f, got %f (diff: %f)", msg or "assertApprox", b, a, math.abs(a - b)))
  end
end

-- Test 1: Construction & Basic Cell Invariants
do
  local bounds: VoronoiDiagram.BoundingBox = {
    minX = -50,
    minZ = -50,
    maxX = 50,
    maxZ = 50,
  }

  local sites = {
    Vector3.new(-20, 0, -20),
    Vector3.new(20, 0, -20),
    Vector3.new(0, 0, 20),
    Vector3.new(0, 0, 0),
  }

  local voronoi = VoronoiDiagram.new(sites, { bounds = bounds })
  local cells = voronoi:GetAllCells()

  assert(#voronoi:GetSites() == 4, "Should have 4 sites")
  assert(cells[1] ~= nil and cells[2] ~= nil and cells[3] ~= nil and cells[4] ~= nil, "All 4 cells must exist")

  -- Check central cell (site 4 at 0,0,0)
  local centerCell = voronoi:GetCell(4)
  assert(centerCell ~= nil, "Center cell should exist")
  assert(centerCell.area > 0, "Center cell must have positive area")
  assert(#centerCell.vertices >= 3, "Center cell must form a valid polygon")
  assert(centerCell.neighbors ~= nil and #centerCell.neighbors > 0, "Center cell must have neighbors")
end

-- Test 2: Bounding Box Clipping Containment
do
  local bounds: VoronoiDiagram.BoundingBox = {
    minX = 0,
    minZ = 0,
    maxX = 100,
    maxZ = 100,
  }

  local sites = {
    Vector3.new(20, 0, 20),
    Vector3.new(80, 0, 20),
    Vector3.new(20, 0, 80),
    Vector3.new(80, 0, 80),
    Vector3.new(50, 0, 50),
  }

  local voronoi = VoronoiDiagram.new(sites, { bounds = bounds })
  local cells = voronoi:GetAllCells()

  for id, cell in pairs(cells) do
    assert(#cell.vertices >= 3, string.format("Cell %d must have at least 3 vertices", id))
    for _, v in ipairs(cell.vertices) do
      assert(v.X >= bounds.minX - 1e-4 and v.X <= bounds.maxX + 1e-4,
        string.format("Vertex X (%f) out of bounds [%f, %f]", v.X, bounds.minX, bounds.maxX))
      assert(v.Z >= bounds.minZ - 1e-4 and v.Z <= bounds.maxZ + 1e-4,
        string.format("Vertex Z (%f) out of bounds [%f, %f]", v.Z, bounds.minZ, bounds.maxZ))
    end
    assert(cell.area > 0, string.format("Cell %d must have positive shoelace area", id))
  end
end

-- Test 3: Nearest Site & Worley Distance Metrics
do
  local bounds: VoronoiDiagram.BoundingBox = {
    minX = 0,
    minZ = 0,
    maxX = 100,
    maxZ = 100,
  }

  local sites = {
    Vector3.new(10, 0, 10),
    Vector3.new(90, 0, 10),
    Vector3.new(10, 0, 90),
    Vector3.new(90, 0, 90),
  }

  local voronoi = VoronoiDiagram.new(sites, { bounds = bounds })

  -- Query near site 1
  local nearId, dist = voronoi:FindNearestSite(Vector3.new(12, 0, 11))
  assert(nearId == 1, "Nearest site must be 1")
  assertApprox(dist, math.sqrt(2 * 2 + 1 * 1), 1e-3, "Distance to site 1")

  -- Worley metrics
  local d1, d2, border = voronoi:SampleWorley(Vector3.new(50, 0, 50))
  assert(d1 <= d2, "F1 distance must be <= F2 distance")
  assert(border >= 0, "Border metric (F2 - F1) must be >= 0")
  assertApprox(border, 0, 1e-3, "At center equidistant from 4 corners, border metric should be approx 0")
end

-- Test 4: Lloyd Relaxation Step
do
  local bounds: VoronoiDiagram.BoundingBox = {
    minX = 0,
    minZ = 0,
    maxX = 200,
    maxZ = 200,
  }

  -- Irregularly clustered sites
  local sites = {
    Vector3.new(20, 0, 20),
    Vector3.new(25, 0, 25),
    Vector3.new(30, 0, 20),
    Vector3.new(150, 0, 150),
    Vector3.new(160, 0, 160),
    Vector3.new(100, 0, 100),
  }

  local voronoi = VoronoiDiagram.new(sites, { bounds = bounds })
  local siteBefore = voronoi:GetSites()[2].point

  voronoi:Relax(3, 0.5)

  local siteAfter = voronoi:GetSites()[2].point
  local movedDist = (siteAfter - siteBefore).Magnitude
  assert(movedDist > 0.1, "Lloyd relaxation must shift sites towards cell centroids")
end

-- Test 5: Adjacency Graph Symmetry & Biome Map Rasterization
do
  local bounds: VoronoiDiagram.BoundingBox = {
    minX = 0,
    minZ = 0,
    maxX = 100,
    maxZ = 100,
  }

  local sites = {
    Vector3.new(30, 0, 30),
    Vector3.new(70, 0, 30),
    Vector3.new(30, 0, 70),
    Vector3.new(70, 0, 70),
    Vector3.new(50, 0, 50),
  }

  local voronoi = VoronoiDiagram.new(sites, { bounds = bounds })
  local graph = voronoi:GetAdjacencyGraph()

  for id, neighbors in pairs(graph) do
    for _, nId in ipairs(neighbors) do
      local reciprocal = false
      if graph[nId] then
        for _, backId in ipairs(graph[nId]) do
          if backId == id then
            reciprocal = true
            break
          end
        end
      end
      assert(reciprocal, string.format("Adjacency must be symmetric: %d -> %d but missing %d -> %d", id, nId, nId, id))
    end
  end

  -- Export Biome Map
  local biomeGrid = voronoi:ExportBiomeMap(5, 5)
  assert(#biomeGrid == 5, "Biome grid must have 5 rows")
  assert(#biomeGrid[1] == 5, "Biome grid must have 5 columns")
  -- Corner (1,1) is at (0,0), closest to site 1 (30,30)
  assert(biomeGrid[1][1] == 1, "Top-left should map to site 1")
  -- Center (3,3) is at (50,50), closest to site 5 (50,50)
  assert(biomeGrid[3][3] == 5, "Center should map to site 5")
end

print("PASS: VoronoiDiagram tests (Invariants, Bounds, Worley, Lloyd Relaxation, Adjacency, Biome Map) passed cleanly!")
return true