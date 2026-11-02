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
│   │   │   ├── BehaviorTree.luau              # Composable Behavior Tree engine with memory and Blackboard
│   │   │   ├── PathfindingAStar3D.luau        # 3D A* navigation graph, vertical constraints, and path smoothing
│   │   │   └── SteeringBehaviors.luau         # Autonomous agent steering, boids flocking, and obstacle avoidance
│   │   ├── Animation/
│   │   │   └── TwoBoneIK.luau                 # Analytical two-bone Inverse Kinematics and foot placement solver
│   │   ├── Audio/
│   │   │   └── AdaptiveSoundtrackManager.luau # Dynamic stem crossfader, ducking, and acoustic occlusion
│   │   ├── Camera/
│   │   │   └── CameraSpring.luau              # Analytical ODE spring system, recoil kick, and camera trauma
│   │   ├── Combat/
│   │   │   ├── DamagePipeline.luau            # Deterministic multi-stage armor, crit, shield, and lifesteal pipeline
│   │   │   ├── HitboxCaster.luau           # Continuous raycast and segment sweep collision
│   │   │   ├── ProjectileSolver.luau       # Sub-step ballistic solver and targeting predictor
│   │   │   └── StatusEffectManager.luau    # Authoritative buff, debuff, DoT, and CC manager
│   │   ├── Economy/
│   │   │   ├── InventoryGrid.luau          # 2D spatial inventory with rotation, stacking, and auto-pack
│   │   │   ├── TradeEscrow.luau            # Atomic two-party trade session with anti-scam lock enforcement
│   │   │   └── WeightedLootTable.luau      # Deterministic weighted drop engine with luck and pity rules
│   │   ├── Narrative/
│   │   │   ├── DialogueGraph.luau             # Branching dialogue tree with condition gates and state persistence
│   │   │   └── QuestTracker.luau              # Multi-objective quest engine, DAG dependencies, and DataStore sync
│   │   ├── Physics/
│   │   │   └── VerletRope.luau             # Dynamic Verlet integration rope, cable, and tear physics
│   │   ├── Utility/
│   │   │   ├── BitBuffer.luau              # Compact bit-level stream serializer and deserializer
│   │   │   ├── FastSignal.luau             # High-cadence zero-allocation event signal with re-entrancy safety
│   │   │   └── ObjectPool.luau             # High-cadence zero-allocation object pool with lifecycle hooks
│   │   ├── Spatial/
│   │   │   ├── FastVoxelRaycast.luau      # Amanatides and Woo O(N) discrete voxel ray traversal algorithm
│   │   │   ├── SparseOctree.luau          # 3D hierarchical dynamic octree spatial acceleration structure
│   │   │   ├── SpatialHashGrid.luau        # O(1) broadphase spatial acceleration structure
│   │   │   └── VoxelFloodFill.luau         # 3D discrete voxel flood fill, cavity detector, and cluster analysis
│   │   ├── State/
│   │   │   └── StateMachine.luau           # Hierarchical Finite State Machine (HFSM) with state stack
│   │   └── Net/
│   │       ├── ClockSync.luau              # Cristian's algorithm clock sync with outlier filtering
│   │       ├── DeltaCompressor.luau        # Bitmasked delta state serialization and quantization engine
│   │       ├── PacketSchema.luau           # Strict packet serialization and validation
│   │       └── TokenBucket.luau            # Rate limiter with burst tokens, refill rate, and penalty cooldowns
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

### 18. ClockSync (`ReplicatedStorage/Net/ClockSync.luau`)
- Client-server clock synchronization engine based on Cristian's algorithm with outlier rejection.
- Minimum-RTT window filtering focusing on the lowest-latency quartile samples for skew estimation.
- Strict monotonic server time guarantee preventing retrograding or backward clock warps.
- Local-to-server and server-to-local timestamp translation helpers with sub-millisecond precision.
- Ring buffer sample management with automatic outlier rejection during network hitches.

### 19. SparseOctree (`ReplicatedStorage/Spatial/SparseOctree.luau`)
- 3D hierarchical dynamic octree acceleration structure for volumetric entity queries and cave partitioning.
- Dynamic node subdivision (8 octants) upon exceeding capacity threshold up to maximum configurable depth.
- Hierarchical sphere-AABB distance pruning for rapid volumetric radius queries.
- 3D Axis-Aligned Bounding Box (AABB) intersection testing.
- Raycast broadphase traversal finding nearest spherical entity intersections with hit distance calculations.
- Dynamic entity repositioning with fast-path local node checks and cross-octant re-indexing.

### 20. PathfindingAStar3D (`ReplicatedStorage/AI/PathfindingAStar3D.luau`)
- 3D navigation graph and volumetric A* pathfinder with binary min-heap priority queue (O(log N) node extraction).
- 3D spatial heuristics: Euclidean, Manhattan, and Octile distance metrics with tunable heuristic weighting.
- Asymmetric vertical movement constraints: independent climb height and drop height thresholds.
- Tick-budget enforcement via MaxExpansions limit with graceful fallback to closest visited partial path.
- Incline slope weighting and dynamic node hazard penalty costs.
- String-pulling path smoothing (Raycast line-of-sight shortcutting) collapsing intermediate zig-zag waypoints.
- Volumetric 3D grid generator helper for terrain and multi-level structures.

### 21. StateMachine (`ReplicatedStorage/State/StateMachine.luau`)
- Hierarchical Finite State Machine (HFSM) engine for player locomotion, combat stances, and NPC boss phases.
- Strict state lifecycle hooks: OnEnter(fromState, ...), OnExit(toState), OnUpdate(dt), and OnEvent(eventName, ...).
- Lowest Common Ancestor (LCA) transition resolution preventing redundant parent state re-initialization.
- Guarded transition rules with conditional predicate validation.
- State stack push/pop mechanism for temporary interrupts, hit reactions, and stun states.
- Event bubbling from leaf state up through ancestor chain with event consumption flags.
- Full state lineage queries and Blackboard key-value context storage.

### 22. ClientPredictionReconciler (`ReplicatedStorage/Net/ClientPredictionReconciler.luau`)
- Client-side prediction and server reconciliation engine for responsive multiplayer locomotion.
- Sequence-indexed user command ring buffer with bounded history.
- Forward physics stepping with configurable acceleration and movement parameters.
- Authoritative server state reconciliation with configurable position/velocity drift thresholds.
- Fast-forward rollback replay for pending unacknowledged commands upon misprediction.
- Visual error dampening with exponential decay (anti-jitter and rubberband smoothing).
- Telemetry counters: misprediction count, drift magnitude, and total replay steps.

### 23. DungeonGraph (`ReplicatedStorage/Procedural/DungeonGraph.luau`)
- Procedural 2D/3D dungeon generator and topology analyzer using Binary Space Partitioning (BSP).
- Deterministic pseudo-random generation with configurable seed (SplitMix32 PRNG).
- Recursive spatial subdivision with aspect-ratio balancing.
- Organic L-shaped corridor carving with hallway smoothing.
- Automatic airtight perimeter wall boundary detection.
- Graph topology analysis with BFS distance field solving.
- Semantic room categorization: Spawn, Boss (deepest topological node), Loot (dead-ends), and Standard.
- Fast 2D DDA grid raycasting for line-of-sight and room occlusion testing.
- ASCII map serialization for visualization and regression diagnostics.

### 24. DamagePipeline (`ReplicatedStorage/Combat/DamagePipeline.luau`)
- Multi-stage combat damage resolution pipeline: Base Damage -> Attacker Buffs -> Crit Roll -> Armor Mitigation -> Elemental Affinities -> Flat Reductions -> Shield Layers -> Health Damage -> Lifesteal and Damage Reflection.
- Hyperbolic armor mitigation curve with flat and percentage armor penetration.
- Elemental affinities (-100% to +90%) with resistance caps and true damage bypass.
- Multi-layered shield and barrier absorption with bleedthrough support.
- Deterministic pseudo-random number generator (LCG) for critical strike resolution.

### 25. CameraSpring (`ReplicatedStorage/Camera/CameraSpring.luau`)
- Exact second-order harmonic oscillator ODE integration (critically damped, underdamped, overdamped).
- Closed-form analytical solver immune to variable frame-rate explosion, drift, or numerical instability.
- 3D positional and rotational spring solving for weapon recoil and viewmodel kick.
- Non-linear camera trauma system with cubic power falloff for explosions and impacts.
- FOV spring smoother for high-speed sprinting, dashing, and zoom transitions.

### 26. ObjectPool (`ReplicatedStorage/Utility/ObjectPool.luau`)
- Zero-allocation object pool for high-frequency game entities (projectiles, VFX parts, damage numbers).
- Fast O(1) acquire and release operations via contiguous stack with active set tracking.
- Lifecycle hooks (onCreate, onAcquire, onRelease, onDestroy) for complete state resetting.
- Configurable growth semantics: bounded or unbounded auto-expansion with capacity exhaustion guards.
- Batch allocation (AcquireBatch) and bulk reclamation (ReleaseAll / Drain).
- Real-time telemetry tracking: capacity, active count, free count, peak active count, and recycled volume.

### 27. WeightedLootTable (`ReplicatedStorage/Economy/WeightedLootTable.luau`)
- Deterministic weighted drop engine with cumulative prefix sum distribution sampling.
- Tiered classification hierarchy: Common, Uncommon, Rare, Epic, Legendary, Mythic.
- Dynamic luck multiplier scaling for high-tier item probability without mutating base definitions.
- Configurable pity counter system with automatic guaranteed drop triggering and counter resets.
- Guaranteed drop slots awarded unconditionally alongside weighted rolls.
- Fully deterministic pseudo-random number generator (LCG) for synchronized netcode drops.
- Supports both with-replacement and without-replacement roll semantics.
- Recursive sub-table nesting for complex hierarchical loot drop structures.

### 28. SteeringBehaviors (`ReplicatedStorage/AI/SteeringBehaviors.luau`)
- Production-grade autonomous agent steering pipeline based on Craig Reynolds' algorithms.
- Core single-agent behaviors: Seek, Flee (with panic distance cutoff), Arrive (smooth deceleration ramp without overshoot), Pursue (predictive interception), and Evade.
- Organic wander behavior using projected circle with per-frame constrained angular jitter.
- Multi-agent swarm boids: Separation (inverse-distance repulsion), Alignment (velocity matching), Cohesion (center-of-mass pull), and composite Flocking.
- Obstacle avoidance using forward feeler ray projection and lateral avoidance deflection.
- Truncated force accumulation, prioritized blending, and semi-implicit Euler kinematic integration.

### 29. DialogueGraph (`ReplicatedStorage/Narrative/DialogueGraph.luau`)
- Narrative state machine and branching dialogue tree engine for RPGs, quests, and NPCs.
- Flexible dialogue nodes with conditional gates, player choice prerequisites, and lifecycle action hooks.
- Rich condition evaluator supporting equality, comparison operators, and array/table membership.
- Node lifecycle hooks (onEnterActions, onExitActions) and choice execution actions (set, increment, toggle, custom event dispatching).
- Visited node tracking with per-node visit counters and traversal history.
- Full session state serialization and restoration for cross-session player persistence.

### 30. FastVoxelRaycast (`ReplicatedStorage/Spatial/FastVoxelRaycast.luau`)
- High-performance 3D discrete voxel ray traversal algorithm based on Amanatides and Woo (1987).
- Traverses discrete voxel grids in exact O(N) step increments without missing cells or continuous step drift.
- Supports axis-aligned rays without division-by-zero errors.
- Rich hit inspection: voxel coordinate, contact point, entry face normal, distance, and total step count.
- Step-by-step visitor traversal callback for projectile piercing, line-of-sight checks, and voxel destruction.

### 31. QuestTracker (`ReplicatedStorage/Narrative/QuestTracker.luau`)
- Narrative quest progression and multi-objective state machine engine.
- Objective types: counter thresholds, boolean flags, and timer constraints.
- Validates prerequisite quest chains (DAG dependencies) and player level gating.
- Auto-completion with reward payload dispatching upon satisfying mandatory objectives.
- Lossless serialization and deserialization routines for DataStore persistence with schema versioning.

### 32. FastSignal (`ReplicatedStorage/Utility/FastSignal.luau`)
- High-performance, re-entrancy safe event signaling system.
- Doubly-linked connection list with O(1) connect and disconnect.
- Error isolation across listeners with Once, Wait, and DisconnectAll routines.

### 33. VoxelFloodFill (`ReplicatedStorage/Spatial/VoxelFloodFill.luau`)
- 3D discrete voxel flood fill and connected-component labeling.
- 6-way and 26-way neighbor topology traversal with pointer queue optimization.
- Subterranean sealed cavity isolation, cluster volume, and center-of-mass calculations.

### 34. BitBuffer (`ReplicatedStorage/Utility/BitBuffer.luau`)
- Compact bit-level stream serializer and deserializer.
- Variable-width unsigned integers (1-32 bits), two's complement signed integers, and quantized floats.
- Length-prefixed string encoding and binary/hex string representations.

### 35. TokenBucket (`ReplicatedStorage/Net/TokenBucket.luau`)
- Deterministic token bucket rate limiter for network requests and player actions.
- Continuous fractional token refill, burst capacity limits, and escalating penalties.
- Dynamic tier multipliers and automatic pruning of stale buckets.

### 36. VerletRope (`ReplicatedStorage/Physics/VerletRope.luau`)
- Dynamic Verlet integration rope, cable, and cloth physics solver.
- Distance constraint relaxation via iterative Gauss-Seidel solver.
- Sphere obstacle and floor plane collisions with ground friction damping.
- Dynamic winching (reeling in/out), tension tracking, and structural tear detection.

### 37. TradeEscrow (`ReplicatedStorage/Economy/TradeEscrow.luau`)
- Atomic two-party trade session manager with finite state machine progression.
- Anti-scam protection: item modifications automatically revoke locks and abort countdowns.
- Mutual locking prerequisite, safety confirmation countdown window, and atomic commit callback.
- Comprehensive audit receipt logging with item manifests for server-side verification.

## Testing with Lune

All 37 core modules feature automated standalone Luau test coverage executed via [Lune](https://github.com/lune-org/lune):

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
- `ClockSync`: Warm-up progression, Cristian offset estimation, jitter outlier rejection, monotonic server clock, timestamp translation, and ring buffer capacity.
- `SparseOctree`: 3D node subdivision, 8 child octants, sphere radius queries, 3D AABB queries, raycast intersection, boundary re-indexing, and entity removal.
- `PathfindingAStar3D`: Graph/edge operations, nearest neighbor search, obstacle avoidance, slope and hazard penalties, vertical climb/drop limits, 3D grid navigation, expansion budget limits, and line-of-sight path smoothing.
- `StateMachine`: Flat and hierarchical states, LCA ancestor traversal, guarded transitions, state stack push/pop, event bubbling, and Blackboard data sharing.
- `ClientPredictionReconciler`: Sequence tracking, input forward prediction, authoritative server reconciliation, rollback replay, and visual error exponential decay smoothing.
- `DungeonGraph`: BSP recursive partitioning, seed determinism, airtight wall borders, BFS topology depth solving, Spawn/Boss/Loot classification, raycasting, and ASCII map serialization.
- `DamagePipeline`: Deterministic crit rolling, hyperbolic armor mitigation, flat/percent armor penetration, elemental affinities, flat reductions, multi-layer shield absorption, true damage bypass, lifesteal, and reflection.
- `CameraSpring`: Analytical ODE integration, critical damping non-overshoot, underdamped oscillation, recoil kick, trauma cubic dissipation, FOV smooth transitions, and numerical stability under extreme timesteps.
- `ObjectPool`: Contiguous free stack, active set validation, double-release rejection, custom lifecycle callbacks, capacity exhaustion protection, batch allocation, and drain metrics.
- `WeightedLootTable`: Deterministic pseudo-random distribution, guaranteed drop separation, luck coefficient scaling, pity threshold triggering, without-replacement selection, and nested loot trees.
- `SteeringBehaviors`: Single-agent Seek/Flee/Arrive/Pursue/Evade, organic wander jitter, Reynolds boids flocking (Separation, Alignment, Cohesion), forward feeler obstacle avoidance, and semi-implicit Euler integration.
- `DialogueGraph`: Graph integrity validation, linear node progression, condition-gated branching choices, variable mutation hooks, custom event dispatching, and full session serialization/restoration.
- `FastVoxelRaycast`: WorldToVoxel mapping, VoxelToWorld bounds, single-axis traversal, floor entry normal, solid start detection, max distance limits, oblique 3D raycast, and early-stopping visitor API.
- `QuestTracker`: Quest definition validation, player level gating, prerequisite DAG chaining, counter and boolean progress increments, automatic completion with rewards, DataStore serialization roundtrip, and failure handling.
- `FastSignal`: Doubly-linked connection list, re-entrancy safety, Once listeners, yielding Wait, error isolation, DisconnectAll, and Destroy lifecycle.
- `VoxelFloodFill`: 6-way and 26-way neighbor topology, pointer-based queue O(1) BFS traversal, disconnected cluster segmentation, subterranean sealed cavity extraction, volume calculation, discrete center of mass, and axis-aligned bounding boxes.
- `BitBuffer`: Arbitrary bit-width unsigned integers (1-32 bits), two's complement signed integers, float quantization across dynamic bounds, 16-bit length-prefixed strings, hex/binary stream serialization, and cursor seeking.
- `TokenBucket`: Deterministic token bucket rate limiter, burst capacity, continuous token refill, key-based state tracking, escalating penalty cooldowns, tier multipliers, and automatic idle bucket garbage collection.
- `VerletRope`: Node initialization, gravity integration, distance relaxation, winching, sphere obstacle collision, floor plane collision, tangent vectors, and structural rupture threshold.
- `TradeEscrow`: State machine progression, offer item/currency manipulation, anti-scam lock revocation, mutual lock transition, countdown timer, atomic commit, and audit receipts.

## Rojo Sync Workflow

Install Rojo and connect to Roblox Studio:
```bash
rojo serve default.project.json
```

In Roblox Studio, connect via the Rojo plugin to sync files live.
