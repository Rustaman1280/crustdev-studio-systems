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
├── src/
│   ├── ReplicatedStorage/
│   │   ├── SynthetixWorldGen.luau         # Deterministic procedural terrain generator
│   │   ├── AI/
│   │   │   └── BehaviorTree.luau              # Composable Behavior Tree engine with memory and Blackboard
│   │   ├── Animation/
│   │   │   └── TwoBoneIK.luau                 # Analytical two-bone Inverse Kinematics and foot placement solver
│   │   ├── Audio/
│   │   │   └── AdaptiveSoundtrackManager.luau # Dynamic stem crossfader, ducking, and acoustic occlusion
│   │   ├── Combat/
│   │   │   ├── HitboxCaster.luau           # Continuous raycast and segment sweep collision
│   │   │   ├── ProjectileSolver.luau       # Sub-step ballistic solver and targeting predictor
│   │   │   └── StatusEffectManager.luau    # Authoritative buff, debuff, DoT, and CC manager
│   │   ├── Economy/
│   │   │   └── InventoryGrid.luau          # 2D spatial inventory with rotation, stacking, and auto-pack
│   │   ├── Spatial/
│   │   │   └── SpatialHashGrid.luau        # O(1) broadphase spatial acceleration structure
│   │   └── Net/
│   │       ├── DeltaCompressor.luau        # Bitmasked delta state serialization and quantization engine
│   │       └── PacketSchema.luau           # Strict packet serialization and validation
│   ├── ServerScriptService/
│   │   └── Services/
│   │       ├── InterestManager.luau        # Area of Interest (AOI) tiered spatial replication engine
│   │       ├── RollbackBuffer.luau         # Authoritative 120-tick snapshot ring buffer
│   │       └── RaycastSuspension.luau      # Raycast vehicle suspension physics engine
│   └── StarterPlayerScripts/
        └── Controllers/
            ├── ActionBuffer.luau           # Input buffer queue with combo detection
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

### 8. ActionBuffer (`StarterPlayerScripts/Controllers/ActionBuffer.luau`)
- Client-side input buffering with configurable TTL window and priority-sorted consumption.
- Action-level cooldown enforcement preventing input flooding.
- Combo sequence pattern recognition and execution history ring buffer.

### 9. HitboxCaster (`ReplicatedStorage/Combat/HitboxCaster.luau`)
- Frame-rate independent continuous raycast sweeping across blade points of interest.
- Sub-step CFrame Lerp interpolation to eliminate melee tunneling against thin colliders.
- Cross-segment edge connection sweeps and swing debounce sets preventing multi-hits.

### 10. StatusEffectManager (`ReplicatedStorage/Combat/StatusEffectManager.luau`)
- Authoritative lifecycle management for buffs, debuffs, crowd control, and damage over time.
- Flexible stacking policies: Refresh, Stack (capped with duration refresh), Extend, and Independent.
- Compound stat modifier resolution combining Flat, Additive, and Multiplicative calculations.
- Periodic tick accumulation for DoT/HoT damage and lightweight snapshot replication.

### 11. ProjectileSolver (`ReplicatedStorage/Combat/ProjectileSolver.luau`)
- Deterministic sub-step ballistic trajectory simulator with drag physics and gravity scaling.
- Multi-phase collision detection with obstacle penetration piercing and specular restitution bouncing.
- Closed-form analytical ballistic launch velocity solver for high-arc and low-arc predictive targeting.

### 12. AdaptiveSoundtrackManager (`ReplicatedStorage/Audio/AdaptiveSoundtrackManager.luau`)
- Dynamic multi-stem audio director and adaptive acoustic manager bridging crustdev studio with crustdev records stems.
- Continuous intensity slew rate smoothing with distinct attack and decay slew rates.
- Stem gain crossfading (Linear, Quadratic, and Exponential response curves).
- Beat and bar quantization calculations for rhythmic musical transitions on downbeat boundaries.
- Dynamic priority ducking envelope (Attack, Hold, Release) for high-impact SFX and dialogue.
- Acoustic raycast occlusion filter calculation estimating low-pass filter (LPF) cutoff frequencies.

### 13. InventoryGrid (`ReplicatedStorage/Economy/InventoryGrid.luau`)
- 2D spatial matrix inventory system with cell occupancy tracking for RPG and tactical survival games.
- Multi-cell items with 90-degree spatial rotation and collision boundary enforcement.
- Stack merging and quantity splitting for stackable goods.
- Greedy First-Fit Decreasing (FFD) 2D bin packing algorithm (AutoPack) for automated inventory sorting.
- Full network-safe serialization and deserialization routines for client-server state replication.

### 14. BehaviorTree (`ReplicatedStorage/AI/BehaviorTree.luau`)
- Modular Behavior Tree decision architecture for autonomous NPC agents, bosses, and environmental entities.
- Composite nodes: Sequence (sequential execution with memory), Selector (fallback priority selection), and Parallel (concurrent execution with RequireAll / RequireOne completion policies).
- Decorator nodes: Inverter, Succeeder, and Repeater with loop bounds and failure break policies.
- Type-safe Blackboard implementation with default fallbacks, key removal, and isolated state dictionaries.

### 15. InterestManager (`ServerScriptService/Services/InterestManager.luau`)
- Area of Interest (AOI) spatial replication manager for multiplayer open-world Roblox servers.
- Tiered observer horizons (Immediate, Near, Far, Culled) with distance-proportional update cadences.
- Replication delta calculation tracking Entered, Updated, TierChanged, and Exited entities per observer.
- Per-observer bandwidth and packet budgeting enforcing strict entity count caps prioritized by tier weight and entity importance score.

### 16. TwoBoneIK (`ReplicatedStorage/Animation/TwoBoneIK.luau`)
- Analytical two-bone Inverse Kinematics solver using the Law of Cosines for humanoid and creature limbs (legs/arms).
- Pole vector constraint enforcement for realistic knee/elbow bending planes without axis flips.
- Singular orthonormal basis matrix construction ensuring zero NaN values even on vertical collinear vectors.
- Surface normal foot alignment with configurable maximum tilt clamping for uneven slopes and stairs.
- Dynamic multi-limb pelvic drop compensation calculating required hip descent to prevent foot floating on depressions.
- Locomotion foot target prediction with velocity lead vectors and ground plane constraint clamping.

### 17. DeltaCompressor (`ReplicatedStorage/Net/DeltaCompressor.luau`)
- Bitmasked delta state serialization engine for high-cadence multiplayer replication with minimal bandwidth.
- Differential state comparison against client baseline snapshots emitting only mutated fields.
- Fixed-point coordinate quantization (0.05 stud resolution) and velocity quantization (0.1 stud/s resolution).
- 8-bit unsigned integer yaw quantization and 8-bit signed integer pitch quantization.
- Native binary buffer serialization with automatic buffer shrinkage and zero heap garbage allocations.
- Client-side baseline snapshot merging with out-of-order sequence detection and recovery.

## Testing with Lune

All 17 core modules feature automated standalone Luau test coverage executed via [Lune](https://github.com/lune-org/lune):

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
- `ActionBuffer`: Priority queuing, buffer window expiration, cooldown tracking, and combo sequence detection.
- `HitboxCaster`: Point sweeping, debounce validation, sub-step interpolation, and edge segment checks.
- `StatusEffectManager`: Stacking policies, CC flags, compound modifiers, periodic DoT ticks, and independent stack decays.
- `ProjectileSolver`: Sub-step trajectory integration, piercing limits, restitution bouncing, and closed-form ballistic arc solving.
- `AdaptiveSoundtrackManager`: Initialization, slew rate filtering, curve gain evaluation, ducking envelope stages, acoustic occlusion cutoff, and beat/bar quantization.
- `InventoryGrid`: 2D bounds validation, collision rejection, spatial relocation, rotation transforms, stack merging/splitting, serialization, and FFD bin packing.
- `BehaviorTree`: Blackboard storage, actions, conditions, sequence memory resumption, selector fallbacks, parallel concurrency, and decorators.
- `InterestManager`: Distance-to-tier classification, initial discovery, tick rate cadence, tier transitions, horizon exits, and bandwidth budget limits.
- `TwoBoneIK`: Analytical solve, pole vector plane, overextension reach clamp, minimum reach singularity protection, ground normal alignment, pelvic drop compensation, and stride prediction.
- `DeltaCompressor`: Yaw/pitch quantization roundtrips, dirty bitmask tracking, full keyframe serialization, delta buffer compression efficiency, client baseline merging, and 100-entity batch throughput.

## Rojo Sync Workflow

Install Rojo and connect to Roblox Studio:
```bash
rojo serve default.project.json
```

In Roblox Studio, connect via the Rojo plugin to sync files live.
