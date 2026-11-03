--!strict
--[[
  VoronoiDiagram.luau
  crustdev studio systems - ReplicatedStorage/Procedural/VoronoiDiagram

  Production-grade 2D Voronoi Diagram, Delaunay Triangulation, and Lloyd Relaxation generator:
  - Exact Bowyer-Watson incremental Delaunay Triangulation on XZ plane.
  - Dual Voronoi cell polygon extraction with Sutherland-Hodgman convex bounding box clipping.
  - Polygon metrics: shoelace area, perimeter, and centroid calculation via Green's theorem.
  - Lloyd's relaxation for organic, uniform hexagonal cell distribution (ideal for biome generation).
  - Adjacency graph topology extraction for procedural territory/faction expansion.
  - Multi-scale Worley / cellular noise queries: F1 (nearest), F2 (second nearest), and border metric (F2 - F1).
  - Zero external dependencies. Compatible with Roblox engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3

export type BoundingBox = {
  minX: number,
  minZ: number,
  maxX: number,
  maxZ: number,
}

export type Site = {
  id: number,
  point: Vector3,
  weight: number?,
  attributes: { [string]: any }?,
}

export type VoronoiCell = {
  siteId: number,
  sitePoint: Vector3,
  vertices: { Vector3 },
  neighbors: { number },
  area: number,
  centroid: Vector3,
  isBoundary: boolean,
}

export type VoronoiEdge = {
  startPoint: Vector3,
  endPoint: Vector3,
  leftSite: number,
  rightSite: number?,
}

export type VoronoiOptions = {
  bounds: BoundingBox,
  relaxIterations: number?,
  relaxDamping: number?,
}

export type VoronoiDiagramInstance = {
  Bounds: BoundingBox,
  Sites: { Site },
  Cells: { [number]: VoronoiCell },
  Edges: { VoronoiEdge },

  GetSites: (self: VoronoiDiagramInstance) -> { Site },
  GetCell: (self: VoronoiDiagramInstance, siteId: number) -> VoronoiCell?,
  GetAllCells: (self: VoronoiDiagramInstance) -> { [number]: VoronoiCell },
  GetNeighbors: (self: VoronoiDiagramInstance, siteId: number) -> { number },
  FindNearestSite: (self: VoronoiDiagramInstance, point: Vector3) -> (number, number),
  SampleWorley: (self: VoronoiDiagramInstance, point: Vector3) -> (number, number, number),
  Relax: (self: VoronoiDiagramInstance, iterations: number?, damping: number?) -> (),
  GetAdjacencyGraph: (self: VoronoiDiagramInstance) -> { [number]: { number } },
  ExportBiomeMap: (self: VoronoiDiagramInstance, resolutionX: number, resolutionZ: number) -> { { number } },
}

local VoronoiDiagram = {}
VoronoiDiagram.__index = VoronoiDiagram

type InternalVertex = {
  id: number,
  x: number,
  z: number,
}

type InternalTriangle = {
  a: number,
  b: number,
  c: number,
  circumX: number,
  circumZ: number,
  radiusSq: number,
}

type InternalEdge = {
  u: number,
  v: number,
}

local function computeCircumcircle(
  ax: number, az: number,
  bx: number, bz: number,
  cx: number, cz: number
): (number, number, number, boolean)
  local d = 2 * (ax * (bz - cz) + bx * (cz - az) + cx * (az - bz))
  if math.abs(d) < 1e-12 then
    return 0, 0, 0, false
  end

  local aSq = ax * ax + az * az
  local bSq = bx * bx + bz * bz
  local cSq = cx * cx + cz * cz

  local ux = (aSq * (bz - cz) + bSq * (cz - az) + cSq * (az - bz)) / d
  local uz = (aSq * (cx - bx) + bSq * (ax - cx) + cSq * (bx - ax)) / d
  local rSq = (ax - ux) * (ax - ux) + (az - uz) * (az - uz)

  return ux, uz, rSq, true
end

local function makeEdgeKey(u: number, v: number): string
  if u < v then
    return u .. "_" .. v
  else
    return v .. "_" .. u
  end
end

-- Bowyer-Watson Delaunay Triangulation
local function runDelaunayTriangulation(
  vertices: { InternalVertex },
  bounds: BoundingBox
): ({ InternalTriangle }, { [number]: { [number]: boolean } })
  local n = #vertices
  if n < 3 then
    return {}, {}
  end

  local midX = (bounds.minX + bounds.maxX) * 0.5
  local midZ = (bounds.minZ + bounds.maxZ) * 0.5
  local deltaMax = math.max(bounds.maxX - bounds.minX, bounds.maxZ - bounds.minZ) * 50

  local superA: InternalVertex = { id = n + 1, x = midX - 2 * deltaMax, z = midZ - deltaMax }
  local superB: InternalVertex = { id = n + 2, x = midX, z = midZ + 2 * deltaMax }
  local superC: InternalVertex = { id = n + 3, x = midX + 2 * deltaMax, z = midZ - deltaMax }

  local allVertices: { InternalVertex } = {}
  for i = 1, n do
    allVertices[i] = vertices[i]
  end
  allVertices[n + 1] = superA
  allVertices[n + 2] = superB
  allVertices[n + 3] = superC

  local triangles: { InternalTriangle } = {}
  local ux, uz, rSq, valid = computeCircumcircle(
    superA.x, superA.z,
    superB.x, superB.z,
    superC.x, superC.z
  )
  if valid then
    table.insert(triangles, {
      a = n + 1,
      b = n + 2,
      c = n + 3,
      circumX = ux,
      circumZ = uz,
      radiusSq = rSq,
    })
  end

  for i = 1, n do
    local pt = vertices[i]
    local px = pt.x
    local pz = pt.z

    local badIndices: { [number]: boolean } = {}
    local edgeCount: { [string]: { count: number, u: number, v: number } } = {}

    for tIdx, tri in ipairs(triangles) do
      local distSq = (px - tri.circumX) * (px - tri.circumX) + (pz - tri.circumZ) * (pz - tri.circumZ)
      if distSq <= tri.radiusSq + 1e-9 then
        badIndices[tIdx] = true

        local triEdges = {
          { tri.a, tri.b },
          { tri.b, tri.c },
          { tri.c, tri.a },
        }

        for _, e in ipairs(triEdges) do
          local key = makeEdgeKey(e[1], e[2])
          if edgeCount[key] then
            edgeCount[key].count = edgeCount[key].count + 1
          else
            edgeCount[key] = { count = 1, u = e[1], v = e[2] }
          end
        end
      end
    end

    local remainingTriangles: { InternalTriangle } = {}
    for tIdx, tri in ipairs(triangles) do
      if not badIndices[tIdx] then
        table.insert(remainingTriangles, tri)
      end
    end
    triangles = remainingTriangles

    for _, edgeInfo in pairs(edgeCount) do
      if edgeInfo.count == 1 then
        local v1 = allVertices[edgeInfo.u]
        local v2 = allVertices[edgeInfo.v]
        local cux, cuz, crSq, cvalid = computeCircumcircle(v1.x, v1.z, v2.x, v2.z, px, pz)
        if cvalid then
          table.insert(triangles, {
            a = edgeInfo.u,
            b = edgeInfo.v,
            c = pt.id,
            circumX = cux,
            circumZ = cuz,
            radiusSq = crSq,
          })
        end
      end
    end
  end

  -- Record adjacency for internal sites
  local adjacency: { [number]: { [number]: boolean } } = {}
  for i = 1, n do
    adjacency[i] = {}
  end

  for _, tri in ipairs(triangles) do
    if tri.a <= n and tri.b <= n then
      adjacency[tri.a][tri.b] = true
      adjacency[tri.b][tri.a] = true
    end
    if tri.b <= n and tri.c <= n then
      adjacency[tri.b][tri.c] = true
      adjacency[tri.c][tri.b] = true
    end
    if tri.c <= n and tri.a <= n then
      adjacency[tri.c][tri.a] = true
      adjacency[tri.a][tri.c] = true
    end
  end

  return triangles, adjacency
end

-- Sutherland-Hodgman Polygon Clipping against 2D AABB
local function clipPolygonAgainstBounds(
  poly: { { x: number, z: number } },
  bounds: BoundingBox
): { { x: number, z: number } }
  local function clipEdge(
    inList: { { x: number, z: number } },
    inside: (p: { x: number, z: number }) -> boolean,
    intersect: (p1: { x: number, z: number }, p2: { x: number, z: number }) -> { x: number, z: number }
  ): { { x: number, z: number } }
    local outList: { { x: number, z: number } } = {}
    if #inList == 0 then
      return outList
    end

    local prev = inList[#inList]
    local prevInside = inside(prev)

    for _, curr in ipairs(inList) do
      local currInside = inside(curr)
      if currInside then
        if prevInside then
          table.insert(outList, curr)
        else
          table.insert(outList, intersect(prev, curr))
          table.insert(outList, curr)
        end
      elseif prevInside then
        table.insert(outList, intersect(prev, curr))
      end
      prev = curr
      prevInside = currInside
    end
    return outList
  end

  local res = poly

  -- Left edge: x >= minX
  res = clipEdge(res, function(p) return p.x >= bounds.minX end, function(p1, p2)
    local t = (bounds.minX - p1.x) / (p2.x - p1.x)
    return { x = bounds.minX, z = p1.z + t * (p2.z - p1.z) }
  end)

  -- Right edge: x <= maxX
  res = clipEdge(res, function(p) return p.x <= bounds.maxX end, function(p1, p2)
    local t = (bounds.maxX - p1.x) / (p2.x - p1.x)
    return { x = bounds.maxX, z = p1.z + t * (p2.z - p1.z) }
  end)

  -- Bottom edge: z >= minZ
  res = clipEdge(res, function(p) return p.z >= bounds.minZ end, function(p1, p2)
    local t = (bounds.minZ - p1.z) / (p2.z - p1.z)
    return { x = p1.x + t * (p2.x - p1.x), z = bounds.minZ }
  end)

  -- Top edge: z <= maxZ
  res = clipEdge(res, function(p) return p.z <= bounds.maxZ end, function(p1, p2)
    local t = (bounds.maxZ - p1.z) / (p2.z - p1.z)
    return { x = p1.x + t * (p2.x - p1.x), z = bounds.maxZ }
  end)

  return res
end

-- Compute polygon shoelace area and centroid
local function computePolygonMetrics(poly: { { x: number, z: number } }): (number, number, number)
  local n = #poly
  if n < 3 then
    return 0, 0, 0
  end

  local area = 0
  local cx = 0
  local cz = 0

  for i = 1, n do
    local curr = poly[i]
    local nextPt = poly[i % n + 1]
    local factor = (curr.x * nextPt.z - nextPt.x * curr.z)
    area = area + factor
    cx = cx + (curr.x + nextPt.x) * factor
    cz = cz + (curr.z + nextPt.z) * factor
  end

  area = area * 0.5
  if math.abs(area) < 1e-9 then
    return 0, poly[1].x, poly[1].z
  end

  cx = cx / (6 * area)
  cz = cz / (6 * area)
  return math.abs(area), cx, cz
end

-- Reconstruct Voronoi cells from Delaunay triangulation
local function buildCells(
  sites: { Site },
  triangles: { InternalTriangle },
  adjacency: { [number]: { [number]: boolean } },
  bounds: BoundingBox
): ({ [number]: VoronoiCell }, { VoronoiEdge })
  local siteTriangles: { [number]: { InternalTriangle } } = {}
  for _, site in ipairs(sites) do
    siteTriangles[site.id] = {}
  end

  for _, tri in ipairs(triangles) do
    if siteTriangles[tri.a] then table.insert(siteTriangles[tri.a], tri) end
    if siteTriangles[tri.b] then table.insert(siteTriangles[tri.b], tri) end
    if siteTriangles[tri.c] then table.insert(siteTriangles[tri.c], tri) end
  end

  local cells: { [number]: VoronoiCell } = {}
  local edges: { VoronoiEdge } = {}
  local edgeRecord: { [string]: boolean } = {}

  for _, site in ipairs(sites) do
    local id = site.id
    local pt = site.point
    local tris = siteTriangles[id] or {}

    -- Collect circumcenters
    local rawVertices: { { x: number, z: number, angle: number } } = {}
    for _, tri in ipairs(tris) do
      local dx = tri.circumX - pt.X
      local dz = tri.circumZ - pt.Z
      local ang = math.atan2(dz, dx)
      table.insert(rawVertices, { x = tri.circumX, z = tri.circumZ, angle = ang })
    end

    -- Angular sort counter-clockwise around site
    table.sort(rawVertices, function(a, b)
      return a.angle < b.angle
    end)

    -- Deduplicate identical circumcenter coordinates
    local uniqueVerts: { { x: number, z: number } } = {}
    for _, v in ipairs(rawVertices) do
      local isDup = false
      if #uniqueVerts > 0 then
        local last = uniqueVerts[#uniqueVerts]
        if math.abs(last.x - v.x) < 1e-5 and math.abs(last.z - v.z) < 1e-5 then
          isDup = true
        end
      end
      if not isDup then
        table.insert(uniqueVerts, { x = v.x, z = v.z })
      end
    end

    -- Clip polygon against bounds
    local clipped = clipPolygonAgainstBounds(uniqueVerts, bounds)
    local cellVertices: { Vector3 } = {}
    local isBoundary = false

    for _, cv in ipairs(clipped) do
      table.insert(cellVertices, Vector3.new(cv.x, pt.Y, cv.z))
      if math.abs(cv.x - bounds.minX) < 1e-3
        or math.abs(cv.x - bounds.maxX) < 1e-3
        or math.abs(cv.z - bounds.minZ) < 1e-3
        or math.abs(cv.z - bounds.maxZ) < 1e-3 then
        isBoundary = true
      end
    end

    -- Compute polygon area and centroid
    local area, cx, cz = computePolygonMetrics(clipped)
    local centroid = Vector3.new(cx, pt.Y, cz)

    -- Neighbors from adjacency map
    local neighborList: { number } = {}
    if adjacency[id] then
      for neighborId, _ in pairs(adjacency[id]) do
        table.insert(neighborList, neighborId)
      end
      table.sort(neighborList)
    end

    cells[id] = {
      siteId = id,
      sitePoint = pt,
      vertices = cellVertices,
      neighbors = neighborList,
      area = area,
      centroid = centroid,
      isBoundary = isBoundary,
    }

    -- Record edges
    local nv = #cellVertices
    if nv >= 3 then
      for i = 1, nv do
        local p1 = cellVertices[i]
        local p2 = cellVertices[i % nv + 1]
        local eKey = string.format("%.2f_%.2f_%.2f_%.2f",
          math.min(p1.X, p2.X), math.min(p1.Z, p2.Z),
          math.max(p1.X, p2.X), math.max(p1.Z, p2.Z))

        if not edgeRecord[eKey] then
          edgeRecord[eKey] = true
          table.insert(edges, {
            startPoint = p1,
            endPoint = p2,
            leftSite = id,
          })
        end
      end
    end
  end

  return cells, edges
end

-- Constructor
function VoronoiDiagram.new(sites: { Vector3 }, options: VoronoiOptions): VoronoiDiagramInstance
  assert(#sites >= 3, "VoronoiDiagram requires at least 3 sites")
  assert(options.bounds ~= nil, "VoronoiDiagram requires bounds")
  assert(options.bounds.maxX > options.bounds.minX, "bounds.maxX must be > bounds.minX")
  assert(options.bounds.maxZ > options.bounds.minZ, "bounds.maxZ must be > bounds.maxZ")

  local siteList: { Site } = {}
  for i, pt in ipairs(sites) do
    table.insert(siteList, {
      id = i,
      point = pt,
    })
  end

  local self = setmetatable({
    Bounds = options.bounds,
    Sites = siteList,
    Cells = {} :: { [number]: VoronoiCell },
    Edges = {} :: { VoronoiEdge },
  }, VoronoiDiagram)

  self:_Rebuild()

  if options.relaxIterations and options.relaxIterations > 0 then
    self:Relax(options.relaxIterations, options.relaxDamping or 1.0)
  end

  return (self :: any) :: VoronoiDiagramInstance
end

function VoronoiDiagram:_Rebuild()
  local vertices: { InternalVertex } = {}
  for _, site in ipairs(self.Sites) do
    table.insert(vertices, {
      id = site.id,
      x = site.point.X,
      z = site.point.Z,
    })
  end

  local triangles, adjacency = runDelaunayTriangulation(vertices, self.Bounds)
  local cells, edges = buildCells(self.Sites, triangles, adjacency, self.Bounds)

  self.Cells = cells
  self.Edges = edges
end

function VoronoiDiagram:GetSites(): { Site }
  return self.Sites
end

function VoronoiDiagram:GetCell(siteId: number): VoronoiCell?
  return self.Cells[siteId]
end

function VoronoiDiagram:GetAllCells(): { [number]: VoronoiCell }
  return self.Cells
end

function VoronoiDiagram:GetNeighbors(siteId: number): { number }
  local cell = self.Cells[siteId]
  if cell then
    return cell.neighbors
  end
  return {}
end

-- Find nearest site to query point
function VoronoiDiagram:FindNearestSite(point: Vector3): (number, number)
  local bestId = -1
  local bestDistSq = math.huge

  for _, site in ipairs(self.Sites) do
    local dx = site.point.X - point.X
    local dz = site.point.Z - point.Z
    local distSq = dx * dx + dz * dz
    if distSq < bestDistSq then
      bestDistSq = distSq
      bestId = site.id
    end
  end

  return bestId, math.sqrt(bestDistSq)
end

-- Sample Worley / Cellular distance metrics: F1 (nearest), F2 (second nearest), and border metric
function VoronoiDiagram:SampleWorley(point: Vector3): (number, number, number)
  local d1 = math.huge
  local d2 = math.huge

  for _, site in ipairs(self.Sites) do
    local dx = site.point.X - point.X
    local dz = site.point.Z - point.Z
    local dist = math.sqrt(dx * dx + dz * dz)

    if dist < d1 then
      d2 = d1
      d1 = dist
    elseif dist < d2 then
      d2 = dist
    end
  end

  local borderDist = d2 - d1
  return d1, d2, borderDist
end

-- Lloyd's Relaxation: relocates site positions toward Voronoi cell centroids
function VoronoiDiagram:Relax(iterations: number?, damping: number?)
  local iters = iterations or 1
  local damp = damping or 1.0

  for _ = 1, iters do
    for _, site in ipairs(self.Sites) do
      local cell = self.Cells[site.id]
      if cell and #cell.vertices >= 3 and cell.area > 1e-4 then
        local targetX = site.point.X + (cell.centroid.X - site.point.X) * damp
        local targetZ = site.point.Z + (cell.centroid.Z - site.point.Z) * damp

        -- Clamp inside domain
        local pad = 1.0
        targetX = math.clamp(targetX, self.Bounds.minX + pad, self.Bounds.maxX - pad)
        targetZ = math.clamp(targetZ, self.Bounds.minZ + pad, self.Bounds.maxZ - pad)

        site.point = Vector3.new(targetX, site.point.Y, targetZ)
      end
    end

    self:_Rebuild()
  end
end

-- Returns adjacency dictionary mapping each site to its neighbors
function VoronoiDiagram:GetAdjacencyGraph(): { [number]: { number } }
  local graph: { [number]: { number } } = {}
  for id, cell in pairs(self.Cells) do
    graph[id] = cell.neighbors
  end
  return graph
end

-- Rasterizes domain into a discrete 2D grid of site IDs for terrain biomes
function VoronoiDiagram:ExportBiomeMap(resolutionX: number, resolutionZ: number): { { number } }
  assert(resolutionX > 1 and resolutionZ > 1, "Resolution must be > 1")

  local grid: { { number } } = {}
  local stepX = (self.Bounds.maxX - self.Bounds.minX) / (resolutionX - 1)
  local stepZ = (self.Bounds.maxZ - self.Bounds.minZ) / (resolutionZ - 1)

  for iz = 1, resolutionZ do
    grid[iz] = {}
    local z = self.Bounds.minZ + (iz - 1) * stepZ
    for ix = 1, resolutionX do
      local x = self.Bounds.minX + (ix - 1) * stepX
      local nearestId, _ = self:FindNearestSite(Vector3.new(x, 0, z))
      grid[iz][ix] = nearestId
    end
  end

  return grid
end

return VoronoiDiagram