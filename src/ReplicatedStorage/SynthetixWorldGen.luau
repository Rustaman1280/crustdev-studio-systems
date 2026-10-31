--!strict
--[[
  SynthetixWorldGen.luau
  Deterministic procedural terrain and heightfield generation module for Roblox.
  Part of crustdev studio game systems.
  Zero dependencies, pure math execution.
]]

export type GeneratorConfig = {
  Seed: number,
  Octaves: number,
  Persistence: number,
  Lacunarity: number,
  WorldScale: number,
  HeightScale: number,
}

export type ChunkData = {
  ChunkX: number,
  ChunkZ: number,
  Resolution: number,
  Elevations: { number },
  MinElevation: number,
  MaxElevation: number,
}

local SynthetixWorldGen = {}
SynthetixWorldGen.__index = SynthetixWorldGen

local DEFAULT_CONFIG: GeneratorConfig = {
  Seed = 482917,
  Octaves = 4,
  Persistence = 0.5,
  Lacunarity = 2.0,
  WorldScale = 120.0,
  HeightScale = 45.0,
}

-- Fast pseudo-random hash based on SplitMix32
local function hash2D(seed: number, x: number, z: number): number
  local ix = math.floor(x)
  local iz = math.floor(z)
  local n = ix * 374761393 + iz * 668265263 + seed * 1442695040888963407
  n = bit32.bxor(n, bit32.rshift(n, 13))
  n = (n * 1274126177) % 4294967296
  n = bit32.bxor(n, bit32.rshift(n, 16))
  return (n % 1000000) / 1000000.0
end

-- Smoothstep interpolation curve (Hermite 3t^2 - 2t^3)
local function smoothstep(t: number): number
  return t * t * (3 - 2 * t)
end

-- Value noise with Hermite interpolation
local function valueNoise2D(seed: number, x: number, z: number): number
  local x0 = math.floor(x)
  local z0 = math.floor(z)
  local x1 = x0 + 1
  local z1 = z0 + 1

  local fx = x - x0
  local fz = z - z0

  local sx = smoothstep(fx)
  local sz = smoothstep(fz)

  local v00 = hash2D(seed, x0, z0)
  local v10 = hash2D(seed, x1, z0)
  local v01 = hash2D(seed, x0, z1)
  local v11 = hash2D(seed, x1, z1)

  local nx0 = v00 + sx * (v10 - v00)
  local nx1 = v01 + sx * (v11 - v01)

  return nx0 + sz * (nx1 - nx0)
end

function SynthetixWorldGen.new(config: GeneratorConfig?): SynthetixWorldGenInstance
  local self = setmetatable({}, SynthetixWorldGen)
  self.Config = table.clone(config or DEFAULT_CONFIG)
  return self
end

export type SynthetixWorldGenInstance = typeof(setmetatable({} :: {
  Config: GeneratorConfig
}, SynthetixWorldGen))

-- Fractional Brownian Motion (fBm) multi-octave sampling
function SynthetixWorldGen:SampleElevation(worldX: number, worldZ: number): number
  local config = self.Config
  local currentScale = config.WorldScale
  local amplitude = 1.0
  local total = 0.0
  local maxAmplitude = 0.0

  local x = worldX
  local z = worldZ

  for octave = 1, config.Octaves do
    local n = valueNoise2D(config.Seed + octave * 1013, x / currentScale, z / currentScale)
    total += n * amplitude
    maxAmplitude += amplitude

    amplitude *= config.Persistence
    currentScale /= config.Lacunarity
  end

  local normalized = if maxAmplitude > 0 then total / maxAmplitude else 0.5
  return normalized * config.HeightScale
end

-- Generate elevation grid slice for a terrain chunk
function SynthetixWorldGen:GenerateChunk(chunkX: number, chunkZ: number, resolution: number): ChunkData
  local res = math.clamp(resolution, 8, 128)
  local count = res * res
  local elevations = table.create(count, 0)

  local minElev = math.huge
  local maxElev = -math.huge

  local step = self.Config.WorldScale / res

  for z = 0, res - 1 do
    for x = 0, res - 1 do
      local wx = (chunkX * (res - 1) + x) * step
      local wz = (chunkZ * (res - 1) + z) * step

      local h = self:SampleElevation(wx, wz)
      local idx = z * res + x + 1
      elevations[idx] = h

      if h < minElev then minElev = h end
      if h > maxElev then maxElev = h end
    end
  end

  return {
    ChunkX = chunkX,
    ChunkZ = chunkZ,
    Resolution = res,
    Elevations = elevations,
    MinElevation = minElev,
    MaxElevation = maxElev,
  }
end

return SynthetixWorldGen
