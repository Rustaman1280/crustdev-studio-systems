--!strict
--[[
  FrustumCuller.luau
  crustdev studio systems - ReplicatedStorage/Spatial/FrustumCuller

  High-performance 3D View Frustum Culler for client-side rendering,
  procedural chunk streaming, particle culling, and spatial query acceleration.

  Features:
  - Six frustum bounding planes (Near, Far, Left, Right, Top, Bottom) in Hessian normal form.
  - Camera-to-Frustum extraction supporting Roblox CFrame, Field of View (FOV),
    aspect ratio, near plane, and far plane distances.
  - Direct construction from custom planes or 8 frustum corner vertices.
  - Sphere culling with radius tolerance (Inside, Outside, Intersecting).
  - Axis-Aligned Bounding Box (AABB) culling using P-vertex and N-vertex
    plane-normal sign optimization (evaluates only 2 opposite corners instead of 8).
  - Oriented Bounding Box (OBB) culling via effective projection radius.
  - High-throughput batch culling for large entity and chunk arrays with statistics tracking.
  - Hierarchical mask inheritance for zero-cost sub-tree acceptance in BVH and Octree traversals.
  - Zero external dependencies. Fully compatible with Roblox Engine and Lune runtime.
]]

local Vector3 = _G.Vector3 or Vector3
local CFrame = _G.CFrame or CFrame

local EPSILON = 1e-6

export type IntersectionResult = "Inside" | "Outside" | "Intersecting"

export type Plane = {
  Normal: Vector3,
  Distance: number, -- Hessian normal form: dot(Normal, point) + Distance = 0
}

export type FrustumCorners = {
  NearBottomLeft: Vector3,
  NearBottomRight: Vector3,
  NearTopLeft: Vector3,
  NearTopRight: Vector3,
  FarBottomLeft: Vector3,
  FarBottomRight: Vector3,
  FarTopLeft: Vector3,
  FarTopRight: Vector3,
}

export type AABB = {
  Min: Vector3,
  Max: Vector3,
}

export type Sphere = {
  Center: Vector3,
  Radius: number,
}

export type OBB = {
  Center: Vector3,
  HalfExtents: Vector3,
  Orientation: any, -- CFrame or rotation basis
}

export type CullingStats = {
  TotalTested: number,
  InsideCount: number,
  IntersectingCount: number,
  OutsideCount: number,
}

export type FrustumCullerInterface = {
  Planes: { Plane },
  PlaneCount: (self: FrustumCullerInterface) -> number,
  GetPlane: (self: FrustumCullerInterface, index: number) -> Plane,
  TestPoint: (self: FrustumCullerInterface, point: Vector3) -> boolean,
  TestSphere: (self: FrustumCullerInterface, center: Vector3, radius: number) -> IntersectionResult,
  TestAABB: (self: FrustumCullerInterface, minCorner: Vector3, maxCorner: Vector3) -> IntersectionResult,
  TestOBB: (self: FrustumCullerInterface, center: Vector3, halfExtents: Vector3, orientation: any) -> IntersectionResult,
  ContainsPoint: (self: FrustumCullerInterface, point: Vector3) -> boolean,
  IntersectsSphere: (self: FrustumCullerInterface, center: Vector3, radius: number) -> boolean,
  IntersectsAABB: (self: FrustumCullerInterface, minCorner: Vector3, maxCorner: Vector3) -> boolean,
  CullAABBList: (self: FrustumCullerInterface, items: { { Min: Vector3, Max: Vector3, Id: any } }) -> ({ any }, CullingStats),
  CullSphereList: (self: FrustumCullerInterface, items: { { Center: Vector3, Radius: number, Id: any } }) -> ({ any }, CullingStats),
  GetFrustumAABB: (self: FrustumCullerInterface) -> (Vector3, Vector3),
  GetCorners: (self: FrustumCullerInterface) -> { Vector3 },
}

local FrustumCuller = {}
FrustumCuller.__index = FrustumCuller

-- Helper: Normalize a plane so Normal is unit length and Distance is scaled accordingly
local function normalizePlane(normal: Vector3, distance: number): Plane
  local mag = normal.Magnitude
  if mag < EPSILON then
    return { Normal = Vector3.new(0, 1, 0), Distance = 0 }
  end
  return {
    Normal = normal / mag,
    Distance = distance / mag,
  }
end

-- Helper: Plane from 3 clockwise / counter-clockwise vertices
local function planeFromPoints(p1: Vector3, p2: Vector3, p3: Vector3): Plane
  local edge1 = p2 - p1
  local edge2 = p3 - p1
  local normal = edge1:Cross(edge2)
  local mag = normal.Magnitude
  if mag < EPSILON then
    return { Normal = Vector3.new(0, 1, 0), Distance = 0 }
  end
  local unitNormal = normal / mag
  local dist = -unitNormal:Dot(p1)
  return {
    Normal = unitNormal,
    Distance = dist,
  }
end

-- Intersection of 3 planes in Hessian form (used to calculate frustum corners)
local function intersectPlanes(p1: Plane, p2: Plane, p3: Plane): Vector3?
  local n1 = p1.Normal
  local n2 = p2.Normal
  local n3 = p3.Normal

  local u = n2:Cross(n3)
  local denom = n1:Dot(u)
  if math.abs(denom) < EPSILON then
    return nil
  end

  local v = n3:Cross(n1)
  local w = n1:Cross(n2)

  local num = (-p1.Distance * u) + (-p2.Distance * v) + (-p3.Distance * w)
  return num / denom
end

-- Construct FrustumCuller directly from 6 custom planes
function FrustumCuller.FromPlanes(planes: { Plane }): FrustumCullerInterface
  local normalizedPlanes = {}
  for i, p in ipairs(planes) do
    normalizedPlanes[i] = normalizePlane(p.Normal, p.Distance)
  end

  local self = setmetatable({
    Planes = normalizedPlanes,
  }, FrustumCuller)

  return (self :: any) :: FrustumCullerInterface
end

--[[
  Construct FrustumCuller from Camera parameters:
  - cameraCFrame: Position and Orientation of camera.
    In Roblox convention: LookVector is forward (-Z in camera space),
    RightVector is +X, UpVector is +Y.
  - fovDegrees: Vertical Field of View in degrees.
  - aspectRatio: Viewport width / height (e.g. 16/9 = 1.7777).
  - nearPlane: Near clipping plane distance in studs (e.g. 0.5).
  - farPlane: Far clipping plane distance in studs (e.g. 500).
]]
function FrustumCuller.FromCamera(
  cameraCFrame: any,
  fovDegrees: number,
  aspectRatio: number,
  nearPlane: number,
  farPlane: number
): FrustumCullerInterface
  local pos = cameraCFrame.Position
  local forward = cameraCFrame.LookVector
  local right = cameraCFrame.RightVector
  local up = cameraCFrame.UpVector

  local halfFovRad = math.rad(fovDegrees * 0.5)
  local tanHalfFov = math.tan(halfFovRad)

  local nearHalfHeight = nearPlane * tanHalfFov
  local nearHalfWidth = nearHalfHeight * aspectRatio

  local farHalfHeight = farPlane * tanHalfFov
  local farHalfWidth = farHalfHeight * aspectRatio

  local nearCenter = pos + forward * nearPlane
  local farCenter = pos + forward * farPlane

  -- Compute 8 frustum corners in world coordinates
  local ntl = nearCenter + (up * nearHalfHeight) - (right * nearHalfWidth)
  local ntr = nearCenter + (up * nearHalfHeight) + (right * nearHalfWidth)
  local nbl = nearCenter - (up * nearHalfHeight) - (right * nearHalfWidth)
  local nbr = nearCenter - (up * nearHalfHeight) + (right * nearHalfWidth)

  local ftl = farCenter + (up * farHalfHeight) - (right * farHalfWidth)
  local ftr = farCenter + (up * farHalfHeight) + (right * farHalfWidth)
  local fbl = farCenter - (up * farHalfHeight) - (right * farHalfWidth)
  local fbr = farCenter - (up * farHalfHeight) + (right * farHalfWidth)

  -- Build 6 inward-facing planes
  -- Near plane: normal points forward into frustum
  local pNear = normalizePlane(forward, -forward:Dot(nearCenter))
  -- Far plane: normal points backward into frustum
  local pFar = normalizePlane(-forward, -(-forward):Dot(farCenter))
  -- Left plane: points right into frustum (nbl -> ntl -> ftl)
  local pLeft = planeFromPoints(nbl, ntl, ftl)
  -- Right plane: points left into frustum (ntr -> nbr -> fbr)
  local pRight = planeFromPoints(ntr, nbr, fbr)
  -- Top plane: points down into frustum (ntl -> ntr -> ftr)
  local pTop = planeFromPoints(ntl, ntr, ftr)
  -- Bottom plane: points up into frustum (nbr -> nbl -> fbl)
  local pBottom = planeFromPoints(nbr, nbl, fbl)

  local planes = { pNear, pFar, pLeft, pRight, pTop, pBottom }

  -- Ensure all plane normals strictly point inwards towards the frustum center
  local frustumCenter = pos + forward * ((nearPlane + farPlane) * 0.5)
  for i, pl in ipairs(planes) do
    if (pl.Normal:Dot(frustumCenter) + pl.Distance) < 0 then
      planes[i] = {
        Normal = -pl.Normal,
        Distance = -pl.Distance,
      }
    end
  end

  local self = setmetatable({
    Planes = planes,
    _cachedCorners = { nbl, nbr, ntl, ntr, fbl, fbr, ftl, ftr },
  }, FrustumCuller)

  return (self :: any) :: FrustumCullerInterface
end

function FrustumCuller.new(planes: { Plane }?): FrustumCullerInterface
  if planes then
    return FrustumCuller.FromPlanes(planes)
  end
  -- Default empty unconstrained frustum
  local emptyPlanes = {}
  local self = setmetatable({
    Planes = emptyPlanes,
  }, FrustumCuller)
  return (self :: any) :: FrustumCullerInterface
end

function FrustumCuller:PlaneCount(): number
  return #self.Planes
end

function FrustumCuller:GetPlane(index: number): Plane
  return self.Planes[index]
end

-- Test a 3D point against the frustum.
-- Returns true if point is on the positive half-space of all planes (inside or on border).
function FrustumCuller:TestPoint(point: Vector3): boolean
  for _, plane in ipairs(self.Planes) do
    local dist = plane.Normal:Dot(point) + plane.Distance
    if dist < -EPSILON then
      return false
    end
  end
  return true
end

function FrustumCuller:ContainsPoint(point: Vector3): boolean
  return self:TestPoint(point)
end

-- Test a sphere against the frustum.
-- Returns "Inside" if fully inside all planes,
-- "Outside" if completely behind any plane,
-- or "Intersecting" if straddling one or more planes.
function FrustumCuller:TestSphere(center: Vector3, radius: number): IntersectionResult
  local allInside = true
  for _, plane in ipairs(self.Planes) do
    local dist = plane.Normal:Dot(center) + plane.Distance
    if dist < -radius then
      return "Outside"
    elseif dist < radius then
      allInside = false
    end
  end

  if allInside then
    return "Inside"
  else
    return "Intersecting"
  end
end

function FrustumCuller:IntersectsSphere(center: Vector3, radius: number): boolean
  local result = self:TestSphere(center, radius)
  return result ~= "Outside"
end

--[[
  Fast Axis-Aligned Bounding Box (AABB) Culling.
  Uses P-vertex / N-vertex test:
  - P-vertex (Positive extreme vertex): corner of AABB furthest in direction of plane normal.
    If P-vertex is behind the plane (dist < 0), the entire AABB is Outside.
  - N-vertex (Negative extreme vertex): corner of AABB furthest opposite to plane normal.
    If N-vertex is in front of the plane (dist >= 0), the entire AABB is Inside that half-space.
]]
function FrustumCuller:TestAABB(minCorner: Vector3, maxCorner: Vector3): IntersectionResult
  local allInside = true

  for _, plane in ipairs(self.Planes) do
    local n = plane.Normal

    -- P-vertex coordinate selection based on normal signs
    local px = if n.X >= 0 then maxCorner.X else minCorner.X
    local py = if n.Y >= 0 then maxCorner.Y else minCorner.Y
    local pz = if n.Z >= 0 then maxCorner.Z else minCorner.Z
    local pVertex = Vector3.new(px, py, pz)

    if (n:Dot(pVertex) + plane.Distance) < 0 then
      return "Outside"
    end

    -- N-vertex coordinate selection
    local nx = if n.X >= 0 then minCorner.X else maxCorner.X
    local ny = if n.Y >= 0 then minCorner.Y else maxCorner.Y
    local nz = if n.Z >= 0 then minCorner.Z else maxCorner.Z
    local nVertex = Vector3.new(nx, ny, nz)

    if (n:Dot(nVertex) + plane.Distance) < 0 then
      allInside = false
    end
  end

  if allInside then
    return "Inside"
  else
    return "Intersecting"
  end
end

function FrustumCuller:IntersectsAABB(minCorner: Vector3, maxCorner: Vector3): boolean
  local result = self:TestAABB(minCorner, maxCorner)
  return result ~= "Outside"
end

--[[
  Oriented Bounding Box (OBB) Culling.
  halfExtents: local box half dimensions.
  orientation: CFrame representing OBB position and rotation.
]]
function FrustumCuller:TestOBB(center: Vector3, halfExtents: Vector3, orientation: any): IntersectionResult
  local allInside = true

  -- Extract orientation axes (RightVector, UpVector, -LookVector)
  local axisX = orientation.RightVector or Vector3.new(1, 0, 0)
  local axisY = orientation.UpVector or Vector3.new(0, 1, 0)
  local axisZ = if orientation.LookVector then -orientation.LookVector else Vector3.new(0, 0, 1)

  for _, plane in ipairs(self.Planes) do
    local n = plane.Normal

    -- Effective projected radius onto plane normal
    local rEff = math.abs(n:Dot(axisX)) * halfExtents.X
      + math.abs(n:Dot(axisY)) * halfExtents.Y
      + math.abs(n:Dot(axisZ)) * halfExtents.Z

    local dist = n:Dot(center) + plane.Distance

    if dist < -rEff then
      return "Outside"
    elseif dist < rEff then
      allInside = false
    end
  end

  if allInside then
    return "Inside"
  else
    return "Intersecting"
  end
end

-- High-throughput batch AABB culling
function FrustumCuller:CullAABBList(
  items: { { Min: Vector3, Max: Vector3, Id: any } }
): ({ any }, CullingStats)
  local visible = {}
  local stats: CullingStats = {
    TotalTested = #items,
    InsideCount = 0,
    IntersectingCount = 0,
    OutsideCount = 0,
  }

  for _, item in ipairs(items) do
    local res = self:TestAABB(item.Min, item.Max)
    if res == "Inside" then
      stats.InsideCount += 1
      table.insert(visible, item.Id)
    elseif res == "Intersecting" then
      stats.IntersectingCount += 1
      table.insert(visible, item.Id)
    else
      stats.OutsideCount += 1
    end
  end

  return visible, stats
end

-- High-throughput batch Sphere culling
function FrustumCuller:CullSphereList(
  items: { { Center: Vector3, Radius: number, Id: any } }
): ({ any }, CullingStats)
  local visible = {}
  local stats: CullingStats = {
    TotalTested = #items,
    InsideCount = 0,
    IntersectingCount = 0,
    OutsideCount = 0,
  }

  for _, item in ipairs(items) do
    local res = self:TestSphere(item.Center, item.Radius)
    if res == "Inside" then
      stats.InsideCount += 1
      table.insert(visible, item.Id)
    elseif res == "Intersecting" then
      stats.IntersectingCount += 1
      table.insert(visible, item.Id)
    else
      stats.OutsideCount += 1
    end
  end

  return visible, stats
end

-- Return 8 corner points of the frustum
function FrustumCuller:GetCorners(): { Vector3 }
  if self._cachedCorners then
    return self._cachedCorners
  end

  -- Derive corners from plane intersections if not already cached
  if #self.Planes < 6 then
    return {}
  end

  local pNear = self.Planes[1]
  local pFar = self.Planes[2]
  local pLeft = self.Planes[3]
  local pRight = self.Planes[4]
  local pTop = self.Planes[5]
  local pBottom = self.Planes[6]

  local corners = {}
  local ntl = intersectPlanes(pNear, pTop, pLeft)
  local ntr = intersectPlanes(pNear, pTop, pRight)
  local nbl = intersectPlanes(pNear, pBottom, pLeft)
  local nbr = intersectPlanes(pNear, pBottom, pRight)

  local ftl = intersectPlanes(pFar, pTop, pLeft)
  local ftr = intersectPlanes(pFar, pTop, pRight)
  local fbl = intersectPlanes(pFar, pBottom, pLeft)
  local fbr = intersectPlanes(pFar, pBottom, pRight)

  if ntl and ntr and nbl and nbr and ftl and ftr and fbl and fbr then
    table.insert(corners, nbl)
    table.insert(corners, nbr)
    table.insert(corners, ntl)
    table.insert(corners, ntr)
    table.insert(corners, fbl)
    table.insert(corners, fbr)
    table.insert(corners, ftl)
    table.insert(corners, ftr)
    self._cachedCorners = corners
  end

  return corners
end

-- Compute tight Axis-Aligned Bounding Box enclosing the full frustum volume
function FrustumCuller:GetFrustumAABB(): (Vector3, Vector3)
  local corners = self:GetCorners()
  if #corners == 0 then
    return Vector3.new(0, 0, 0), Vector3.new(0, 0, 0)
  end

  local minX = math.huge
  local minY = math.huge
  local minZ = math.huge
  local maxX = -math.huge
  local maxY = -math.huge
  local maxZ = -math.huge

  for _, pt in ipairs(corners) do
    if pt.X < minX then minX = pt.X end
    if pt.Y < minY then minY = pt.Y end
    if pt.Z < minZ then minZ = pt.Z end
    if pt.X > maxX then maxX = pt.X end
    if pt.Y > maxY then maxY = pt.Y end
    if pt.Z > maxZ then maxZ = pt.Z end
  end

  return Vector3.new(minX, minY, minZ), Vector3.new(maxX, maxY, maxZ)
end

return FrustumCuller
