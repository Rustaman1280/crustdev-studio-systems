# Crustdev Studio Systems

Modular Luau architecture, procedural world generation, netcode contracts, and spatial vehicle physics for Roblox studio productions.

## Overview

Designed for high-performance Roblox titles produced by the crustdev studio collective:
- **Aetheria: Fractured Realms**: Client predictive combat, lag compensation, and cave generation.
- **Neon Velocity Drift**: Raycast wheel suspension physics, tire grip friction, and 16-player netcode.
- **The Depths: Stratum Zero**: Volumetric subterranean elevation sampling and voxel density fields.

## Directory Structure

```
crustdev-studio-systems/
├── default.project.json                    # Rojo project definition
├── README.md                               # Architecture and documentation
└── src/
    ├── ReplicatedStorage/
    │   ├── SynthetixWorldGen.luau         # Deterministic procedural terrain generator
    │   ├── Spatial/
    │   │   └── SpatialHashGrid.luau        # O(1) broadphase spatial acceleration structure
    │   └── Net/
    │       └── PacketSchema.luau           # Strict packet serialization and validation
    ├── ServerScriptService/
    │   └── Services/
    │       ├── RollbackBuffer.luau         # Authoritative 120-tick snapshot ring buffer
    │       └── RaycastSuspension.luau      # Raycast vehicle suspension physics engine
    └── StarterPlayerScripts/
        └── Controllers/
            ├── CombatPredictor.luau        # Client prediction with RTT smoothing
            └── SnapshotInterpolator.luau   # Cubic Hermite transform interpolation and jitter buffer
```

## Luau Layer Contracts

### 1. SynthetixWorldGen (`ReplicatedStorage/SynthetixWorldGen.luau`)
- Pure Luau port of `@crustdev/synthetix` algorithms.
- Mulberry32 / SplitMix32 PRNG and continuous multi-octave 2D value noise.
- Deterministic chunk elevation slicing for streaming terrain.

### 2. PacketSchema (`ReplicatedStorage/Net/PacketSchema.luau`)
- Type-safe remote event contracts for combat and vehicle state.
- Timestamp drift and vector normalization guards preventing packet spoofing.
- Fixed-point vector quantization (0.01 stud precision) for low-bandwidth replication.

### 3. RollbackBuffer (`ServerScriptService/Services/RollbackBuffer.luau`)
- Fixed-capacity circular snapshot buffer (120 ticks / ~2 seconds history).
- Backward historical timestamp lookup with linear interpolation (Lerp).
- Lag-compensated ray-sphere collision verification.

### 4. RaycastSuspension (`ServerScriptService/Services/RaycastSuspension.luau`)
- Hooke's Law spring compression and linear damper shock absorption.
- Longitudinal acceleration and lateral tire friction forces.

### 5. CombatPredictor (`StarterPlayerScripts/Controllers/CombatPredictor.luau`)
- Local hit forecasting with zero-latency client presentation.
- Exponential moving average round-trip time (RTT) tracking.
- Reconciliation on server authority feedback.

### 6. SpatialHashGrid (`ReplicatedStorage/Spatial/SpatialHashGrid.luau`)
- O(1) broadphase proximity queries replacing expensive O(N) workspace iteration.
- Configurable bucket cell bounds, radial sphere queries, and AABB intersection filtering.
- Dynamic entity insertion, continuous movement updates, and automatic empty-cell pruning.

### 7. SnapshotInterpolator (`StarterPlayerScripts/Controllers/SnapshotInterpolator.luau`)
- Client transform smoothing with Hermite cubic spline interpolation using velocity tangents.
- Shortest-path angular interpolation for yaw orientation.
- Jitter buffer with bounded dead-reckoning extrapolation and velocity damping during network lag.

## Testing with Lune

All 7 core modules feature automated standalone Luau test coverage executed via [Lune](https://github.com/lune-org/lune):

```bash
lune run tests/runner.luau
```

Test coverage includes:
- `SpatialHashGrid`: O(1) uniform spatial hashing, radial queries, bounding box queries, dynamic entity transfers, and cell cleanup.
- `PacketSchema`: Header sequencing, drift protection, anti-exploit direction normalization, and 0.01-stud precision vector compression.
- `RollbackBuffer`: 120-tick ring buffer, retroactive timeline position reconstruction, and lag-compensated raycast hit reconciliation.
- `SnapshotInterpolator`: Cubic Hermite velocity spline interpolation and dead-reckoning extrapolation with jitter resistance.
- `SynthetixWorldGen`: Deterministic elevation sampling, seed variation, resolution bounds, and multi-octave chunk generation.
- `RaycastSuspension`: Default wheel configurations, airborne zero-force state, grounded Hooke spring compression, and lateral slide friction.
- `CombatPredictor`: Exponential moving average ping smoothing, predictive client forecast creation, PacketSchema conformance, and server reconciliation.

## Rojo Sync Workflow

Install Rojo and connect to Roblox Studio:
```bash
rojo serve default.project.json
```

In Roblox Studio, connect via the Rojo plugin to sync files live.
