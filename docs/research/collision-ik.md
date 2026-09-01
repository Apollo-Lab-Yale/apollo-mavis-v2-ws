# RelaxedIK / CollisionIK research note

Sources actually read for this note:

- Paper: *CollisionIK: A Per-Instant Pose Optimization Method for Generating Robot Motions with Environment Collision Avoidance*, Rakita, Shi, Mutlu, Gleicher, ICRA 2021 ([arXiv:2102.13187](https://arxiv.org/abs/2102.13187)).
- Code: [`uwgraphics/relaxed_ik_core`](https://github.com/uwgraphics/relaxed_ik_core), shallow-cloned and read at `/tmp/relaxed_ik_core` (branch `main`, HEAD `1c48d2a`, 2024-08-21) and `/tmp/collision_ik` (branch `collision-ik`).
- Comparison target: [`kevinzakka/mink`](https://github.com/kevinzakka/mink), read at `/tmp/mink`.
- Benchmarks in this note were run locally (Threadripper PRO 5975WX, single thread, `cargo build --release`, rustc 1.97).

**TL;DR up front:** the repo is really three different solvers on three branches. The `main` branch is **RangedIK** (ICRA'23): URDF-driven, multi-chain, prismatic-joint capable, builds today, solves a 8-DoF rail+7R chain in ~0.13 ms — but has **no environment-collision term** and a **buggy, single-chain-only self-collision term**. The `collision-ik` branch has the real CollisionIK environment-avoidance machinery but is bit-rotted (does not compile with modern Rust, needs per-robot preprocessed config + a trained per-robot collision NN). For our stack, **mink + MuJoCo digital twin is the more practical base**; the things worth *taking* from CollisionIK are ideas (groove loss, velocity/accel/jerk regularization, active-obstacle filtering, adaptive orientation-weight relaxation), not code.

---

## 1. The RelaxedIK family and which branch is which

| Branch of `relaxed_ik_core` | Method | Env. collision | Self collision | Config | Builds with rustc 1.97? |
|---|---|---|---|---|---|
| `main` | **RangedIK** (ICRA'23, tolerance/ranged goals) | **No** (dead code; `obstacles:` key in yaml is parsed nowhere) | Segment-capsule pairs, **hardcoded to chain 0** (bug, see §4) | small YAML + URDF | **Yes** (verified) |
| `collision-ik` | **CollisionIK** (ICRA'21) | Yes (ncollide3d proximity world, dynamic obstacles) | Learned NN per robot (`NNSelfCollision`) | preprocessed "info file" + collision yaml + trained NN files | **No** (verified: `ncollide2d 0.19` fails E0310) |
| `relaxed-ik` | RelaxedIK (RSS'18) | No | Learned NN | info file | untested, similar vintage to collision-ik |

ROS wrappers exist (`relaxed_ik_ros1` for CollisionIK/RelaxedIK, `relaxed_ik_ros2` for RangedIK) but we don't use ROS, and the core is callable directly via C FFI.

---

## 2. CollisionIK: the method (paper + `collision-ik` branch source)

### 2.1 Optimization form

Per-instant (per-tick) nonlinear optimization over joint config `x`, warm-started from the previous solution:

```
min_x  Σ_i w_i * f_i(x, goals, history)     s.t.  lb <= x <= ub   (joint-limit box)
```

Solved with **PANOC** (proximal averaged Newton-type) from the Rust **OpEn** (`optimization_engine`) crate; NLopt is an alternative backend on this branch. Gradients are finite-differenced (the code has both per-objective analytic hooks and global finite diff; CollisionIK branch sets `finite_diff_grad: true`).

Objective terms (from `src/groove/objective_master.rs::relaxed_ik()` on `collision-ik`):

| Term | Weight | Notes |
|---|---|---|
| `MatchEEPosGoals` (per chain) | 1.0 | `‖ee_pos − goal‖` through groove loss |
| `MatchEEQuatGoals` (per chain) | 1.0 | min over quat double-cover of angle-to-goal |
| `EnvCollision` (per chain) | 1.0 | see §2.2 |
| `MinimizeVelocity` | 7.0 | `‖x − xopt_prev‖` (joint-space) |
| `MinimizeAcceleration` | 2.0 | uses `prev_state`, `prev_state2` history |
| `MinimizeJerk` | 1.0 | uses 3-deep state history |
| `JointLimits` | 1.0 | polynomial barrier `a·(2(r−0.5))^50` per joint |
| `NNSelfCollision` | 1.0 | learned per-robot network predicting self-collision score (from RelaxedIK RSS'18; needs offline training) |

Every raw term value is passed through the **groove loss**:

```rust
// src/groove/objective.rs
pub fn groove_loss(x_val: f64, t: f64, d: i32, c: f64, f: f64, g: i32) -> f64 {
    -((-(x_val - t).powi(d)) / (2.0 * c.powi(2))).exp() + f * (x_val - t).powi(g)
}
```

i.e. a narrow negative Gaussian well around the target value plus a shallow polynomial tail — this normalizes heterogeneous terms so fixed weights compose sanely. This is the single most reusable *idea* in the codebase.

`objective_mode` in `config/settings.yaml` selects variants: `noECA` (no env avoidance), `ECA` (default), `ECA3` (position-only goal), `ECAA` (**adaptive**: `tune_weight_priors()` lowers the orientation-matching weight toward `a/(a+score)` with `a=0.05`, rate-capped at 0.001/tick, as the max active-obstacle proximity score rises — trades orientation fidelity for avoidance near obstacles; nice teleop UX trick).

### 2.2 Environment collision term and dynamic obstacles

Robot links are approximated as **line segments between consecutive joint frames** with one global `link_radius` (default 0.05 m) — effectively capsules. Obstacles live in an `ncollide3d` `CollisionWorld` (`src/groove/env_collision.rs::RelaxedIKEnvCollision`) with three shape types parsed from `config/settings.yaml`:

```yaml
obstacles:
  cuboids:
    - name: box1
      scale: [0.35, 0.6, 0.002]
      translation: [0.6, 0.0, 0.0]
      rotation: [0.0, 0.0, 0.0]
      animation: static        # static | interactive | <animation-file>
  spheres:
    - name: sphere1
      scale: 0.1
      translation: [0.4, 0.4, 0.3]
      animation: rotations_sphere1
  point_cloud:                 # converted to a convex hull (QuickHull) at load
    - name: bunny
      scale: [2.0, 2.0, 2.0]
      file: bunny
```

Per solver tick (`RelaxedIKVars::update_collision_world()` in `src/groove/vars.rs`):

1. Link segments are re-fit from FK of the current solution (`update_links`).
2. The ncollide broad phase (DBVT / AABB tree) with proximity margin `20 * link_radius` emits `WithinMargin` / `Disjoint` events, maintaining `active_pairs` per arm.
3. Exact narrow-phase distances are computed for active obstacles; per arm only the **top-3 highest-cost obstacles** (`filter_cutoff = 3`) are kept in `active_obstacles` — bounding the per-iteration cost of the objective.
4. If any link is already penetrating an obstacle, `update_collision_world()` returns `true` and **the solve is skipped entirely** (`RelaxedIK::solve()` returns the previous `xopt`) — i.e. once in collision it freezes rather than repairing.

The objective itself (`EnvCollision::call`) for each active obstacle sums over links:

```
cost = Σ_links (2·r)² / dist(obstacle, segment)²,  then groove_loss(cost, 0., 2, 3.5, 0.00005, 4)
```

(paper: `(5ε)²/dis²` with cutoff ε = 0.02 m; code uses `penalty_cutoff = 2·link_radius`). Smooth sum instead of min-distance so it stays differentiable.

**Per-tick inputs the method needs:**

- EE pose goal(s): 3-vector + quaternion per chain (relative-to-start or absolute).
- Current rigid transform of every *dynamic* obstacle, pushed via C FFI:

```rust
// src/relaxed_ik_wrapper.rs (collision-ik branch)
#[no_mangle]
pub unsafe extern "C" fn dynamic_obstacle_cb(name: *const c_char,
    pos_arr: *const c_double, quat_arr: *const c_double)  // 3 + 4 doubles
```

which calls `env_collision.update_dynamic_obstacle(name, Isometry3)`. Obstacle *shapes* are fixed at init; only poses stream. Point clouds are hulled once at load (~18 ms per 30k-vertex bunny), then moved rigidly.

Note the FFI here is a **global singleton** (`lazy_static! static ref R: Mutex<RelaxedIK>`), so one process = one robot config on this branch.

### 2.3 Reported performance (paper, AMD Ryzen 2700X)

- ~**0.5 ms/solve (≈2000 Hz)** with four sphere obstacles.
- ~16 ms/solve (≈60 Hz) with 100 Stanford-bunny convex hulls.
- Evaluated on UR5, Sawyer, Jaco, IIWA-7, and an 8-DoF Hubo+ chain, in simulation only, vs. RelaxedIK (many collisions) and a Trac-IK+RRT-Connect MoveIt pipeline (slower, jerkier, but escapes local minima).
- Stated limitations: local minima (cannot go around a large table the way a global planner can), no guarantees, simulation-only validation.

### 2.4 Config burden on the `collision-ik` branch

This branch predates URDF parsing in the core. Per robot you need:

- `config/info_files/<robot>_info.yaml` — hand/ROS-tool-generated kinematics dump (`joint_names`, `displacements`, `rot_offsets`, `axis_types`, `joint_types`, `joint_limits`, `starting_config`, …).
- `config/collision_files/collision_<robot>.yaml` — self-collision sample specification.
- `config/collision_nn_rust/<robot>_nn.yaml` — a **trained neural net** for the self-collision score, produced by the old `relaxed_ik` ROS1 preprocessing pipeline (scikit-learn, hours of sampling).

There are no xArm7 files; we would have to run a dead ROS1 Python-2-era pipeline to generate them. Combined with the compile failure on modern Rust (`ncollide2d 0.19` → E0310 on rustc 1.97; needs a ~2020 pinned toolchain), **the `collision-ik` branch should be treated as reference reading, not a dependency.**

---

## 3. `relaxed_ik_core` `main` branch (RangedIK) — what you actually get if you build today

### 3.1 Crate structure

```
src/
  lib.rs                  # pub mods; crate-type = ["rlib", "cdylib"] -> librelaxed_ik_lib.so
  relaxed_ik.rs           # RelaxedIK { vars, om, groove }; load_settings(), solve(), reset()
  relaxed_ik_wrapper.rs   # C FFI: relaxed_ik_new/free, solve, solve_position, solve_velocity, reset
  relaxed_ik_web.rs       # wasm-bindgen wrapper (browser demo)
  spacetime/robot.rs      # Robot::from_urdf(urdf, base_links, ee_links) via urdf-rs + k crate
  spacetime/arm.rs        # per-chain FK; revolute/continuous/prismatic/fixed all supported
  groove/groove.rs        # OptimizationEngineOpen: PANOC, max_iter=100, tol=5e-4, joint-limit Rectangle bounds
  groove/objective.rs     # groove_loss, swamp_loss, swamp_groove_loss + all objective structs
  groove/objective_master.rs
configs/
  settings.yaml           # active robot config
  example_settings/*.yaml # ur5, panda, baxter (2 chains), fetch, spot_arm, mobile_spot_arm (prismatic x/y base!), ...
  urdfs/*.urdf
wrappers/python_wrapper.py  # ctypes wrapper class RelaxedIKRust
```

Dependencies: `optimization_engine 0.7.7`, `parry3d-f64 0.8` (replaces ncollide), `urdf-rs 0.6.7`, `k 0.29`, nalgebra 0.30. Builds clean in ~19 s.

### 3.2 Config format: plain URDF + tiny YAML

```yaml
# configs/example_settings/ur5.yaml
urdf: ur5.urdf            # looked up under <cwd>/configs/urdfs/  (beware: path base is process CWD)
link_radius: 0.05
base_links: [base_link]   # one entry per chain
ee_links:   [right_hand]
starting_config: [0.0, 0.0, -1.5708, 1.5708, 0.0, -1.5708, 0.0]
obstacles:                # PARSED BY NOTHING on main — env collision is gone on this branch
```

No preprocessing, no info files, no NN. Multi-chain = list several base/ee pairs into the *same* URDF (see `baxter.yaml` with `base_links: [torso, torso]`, `ee_links: [right_hand, left_hand]`, 14-DoF joint vector = chains concatenated in order).

**Path gotcha:** `get_path_to_src()` is literally `std::env::current_dir()`, so URDF resolution is relative to the process CWD (`<cwd>/configs/urdfs/<name>`). Any wrapper we write should chdir or patch this.

### 3.3 Objectives on main (RangedIK)

Per chain: `MatchEEPosiDoF` ×3 (w=50) and `MatchEERotaDoF` ×3 (w=10) — *per-axis in the goal frame*, so each Cartesian DoF can have its own tolerance. With per-DoF tolerance ≤ 1e-2 it's a strict groove loss; larger tolerances switch to `swamp_groove_loss` (flat-bottomed well of width ±tolerance → "ranged" goals, e.g. free tool-roll). Plus `EachJointLimits` (w=0.1/joint), `MinimizeVelocity` (0.7), `MinimizeAcceleration` (0.5), `MinimizeJerk` (0.3), `MaximizeManipulability` (1.0, Yoshikawa √det(JJᵀ)), and segment-based `SelfCollision` (w=0.01 per pair, `swamp_loss(dist−0.05, ...)`, hardcoded 0.05 m radius).

`EnvCollision` is commented out in `objective_master.rs` and `RelaxedIKVars` has no collision world: **the main branch cannot avoid environment obstacles at all.**

### 3.4 Python API (ctypes, `wrappers/python_wrapper.py`)

```python
from python_wrapper import RelaxedIKRust   # loads target/debug/librelaxed_ik_lib.so (patch path for release)

rik = RelaxedIKRust("/path/to/settings.yaml")
x = rik.solve_position(positions,     # 3*N flat list (N = num chains), world/base frame, ABSOLUTE
                       orientations,  # 4*N quaternions, xyzw
                       tolerances)    # 6*N per-EE (x y z rx ry rz); 0 => exact
x = rik.solve_velocity(lin_vels, ang_vels, tolerances)  # integrates goal internally: goal += v (per call, no dt)
rik.reset(joint_state)                # re-seed state + history (use when arm moves externally / DAgger takeover)
```

Returned `x` is the full concatenated joint vector. Underlying C symbols: `relaxed_ik_new(path)->*RelaxedIK`, `solve_position`, `solve_velocity`, `solve`, `reset`, `relaxed_ik_free`, `get_ee_positions`. Instance-based (no global singleton) → several arms/solvers per process is fine.

### 3.5 Measured solve rates (this machine, single thread, release)

| Config | DoF / chains | ms/solve | Hz |
|---|---|---|---|
| panda | 7 / 1 | 0.101 | ~9,900 |
| fetch (torso_lift base) | 7 / 1 | 0.125 | ~8,000 |
| **panda + 0.65 m prismatic Y rail (synthetic)** | **8 / 1** | **0.128** | **~7,800** |
| mobile_spot_arm (x,y prismatic base + arm) | 8 / 1 | 0.127 | ~7,850 |
| baxter (two arms, one URDF) | 14 / 2 | 0.427 | ~2,340 |

Method: 2,000 sequential `solve()` calls tracking a moving goal (PANOC `max_iter=100`, warm-started). So the solver itself is 20–80× faster than a 100 Hz teleop tick even for two arms — solver speed is *not* a differentiator vs. mink at our rates.

### 3.6 Answering the specific modeling questions

- **8-DoF prismatic rail + 7R xArm7: yes.** `Robot::from_urdf` handles `k::JointType::Linear` (prismatic) with limits; FK in `arm.rs` implements prismatic updates. Verified empirically: I wrapped the panda URDF with a `type="prismatic"` rail joint (`lower=0.0 upper=0.65`, axis Y), set `base_links: [rail_base]`, and it solved at ~7.8 kHz with the rail DoF participating. The same recipe applies to the xArm7 URDF from `xarm_ros` (`link_base` … `link_eef`): add a `rail_base` link + prismatic joint above `link_base`. One caveat: URDF must be a tree with a single parent per link (I hit an `unwrap` panic in `robot.rs:31` when the stock URDF's extra `world` fixed joint gave `link0` two parents — strip such joints).
- **Multi-chain / two arms: yes, with a serious caveat.** Chains are just `(base_link, ee_link)` pairs into one URDF, goals are concatenated. BUT the only inter-link safety term, `SelfCollision`, is constructed as `SelfCollision::new(0, j, k)` inside the chain loop (`objective_master.rs:61`) — the chain index is **hardcoded to 0**. So chain 1's self-collision terms actually re-evaluate chain 0, and there are **no arm-A-vs-arm-B pairs at all**. Two nearby xArm7s would happily be driven through each other. Fixing this in the Rust source is easy (pass `i`, add cross-chain pairs), but stock `main` does not do dual-arm mutual avoidance.
- **Achievable rates:** see table; 100 Hz+ teleop is trivially within budget even ×3 arms ×1 solver each.

---

## 4. Comparison: CollisionIK vs. mink (MuJoCo differential IK) for our stack

What mink actually is (verified in `/tmp/mink/src/mink`): velocity-level differential IK as a QP over `Δq`, built directly on MuJoCo:

```python
import mink
configuration = mink.Configuration(model)           # wraps MjModel/MjData
tasks = [mink.FrameTask(frame_name="attachment_site", frame_type="site",
                        position_cost=1.0, orientation_cost=1.0),
         mink.PostureTask(model, cost=1e-2)]
limits = [mink.ConfigurationLimit(model),
          mink.VelocityLimit(model, velocities),
          mink.CollisionAvoidanceLimit(model, geom_pairs=[(arm1_geoms, arm2_geoms),
                                                          (arm_geoms, env_geoms)],
                                       gain=0.85,
                                       minimum_distance_from_collisions=0.005,   # our "inflation"
                                       collision_detection_distance=0.01)]
v = mink.solve_ik(configuration, tasks, dt, solver="daqp", damping=1e-3, limits=limits)
configuration.integrate_inplace(v, dt)
```

`CollisionAvoidanceLimit.compute_qp_inequalities()` calls `mujoco.mj_geomDistance()` per geom pair (with a strict vectorized sphere/plane broadphase pre-filter), and adds a hard linear constraint `−Jₙ·Δq ≤ gain·(dist − dmin)/dt` per pair — the velocity-obstacle-style constraint. mink ships a **UFACTORY xArm7 example** (`examples/ufactory_xarm7/`, `examples/arm_hand_xarm_leap.py`).

| Dimension | CollisionIK / relaxed_ik_core | mink + MuJoCo twin |
|---|---|---|
| Collision geometry | Segments + single global radius; obstacles = cuboid/sphere/one-shot convex hulls in a *second* geometry world (ncollide/parry) that must be kept in sync with the twin | **The digital twin itself.** Exact MuJoCo geoms (meshes/capsules), inflation = `minimum_distance_from_collisions`, self- and cross-arm pairs are just `geom_pairs` entries |
| Avoidance semantics | Soft cost (can be traded off; freezes solve if already penetrating) | Hard QP inequality (never commands closing velocity beyond the bound; degrades to sliding along the constraint) |
| Dual-arm mutual avoidance | Not on any usable branch (main: chain-0 bug; collision-ik: arms don't see each other either — links only collide with *obstacles*, group filters blacklist link-link) | Native: one MjModel containing both arms + rails; add `(arm1_geoms, arm2_geoms)` pair |
| 8-DoF rail chain | Yes (verified) | Yes — trivially, it's whatever the MJCF says |
| Orientation "give" near obstacles / tolerances | ECAA adaptive weight; RangedIK per-DoF tolerance (swamp loss) — genuinely nice features | Approximate via task cost ratios / `lm_damping`; no built-in per-DoF flat-bottom tolerance (partial: `FrameTask` per-axis costs) |
| Local minima behavior | Nonlinear per-instant opt; can exploit curvature a bit better, still local | Strictly local (one linearization per tick); for teleop this is fine, for resets you need a planner anyway |
| Language/integration | Rust + ctypes; second URDF/model source of truth; CWD-relative config paths; py bindings are thin and lossy (no obstacle API on main) | Pure Python on `mujoco` + `qpsolvers` (daqp/osqp); zero model duplication with our sim/twin; maintained (2024–2025), typed, tested |
| Speed (7-DoF, this class of machine) | ~0.1 ms/solve measured | ~0.5–2 ms/solve typical (QP + mj_geomDistance); comfortably >100 Hz; rates published in mink benchmarks dir |

**Verdict for our stack: mink-style QP differential IK on the MuJoCo digital twin is more practical.** Decisive reasons: (1) our collision authority *is already* the MuJoCo twin — CollisionIK would force a parallel, cruder geometry world (capsule links, convex-hulled env) that we'd have to keep consistent; (2) dual-arm mutual avoidance is a first-class one-liner in mink and effectively absent in every usable relaxed_ik_core branch; (3) the only branch with environment avoidance doesn't compile and needs a dead preprocessing pipeline; (4) hard inequality constraints are a better safety story for teleop streaming to real arms than soft costs that can be out-bid by the goal term; (5) Python-native fits our uv/Python-3.10 stack and the same `Configuration` doubles as the reset-planner's collision checker.

---

## 5. What to reuse vs. reimplement

### (a) Teleop-time collision-aware IK (~100 Hz+ cartesian servo)

Reuse (as design, reimplemented in our mink-based solver):

- **Groove/swamp loss & RangedIK tolerances** — if we outgrow pure QP weighting, per-DoF flat-bottom tolerances (free tool roll during teleop, camera-frame "don't-care" axes for data collection) are worth porting as a custom mink task or a post-QP nullspace objective.
- **ECAA adaptive weighting** — when close to collision, automatically relax orientation tracking before position tracking (`w_rot ← a/(a + proximity_score)`, rate-limited). Maps cleanly onto scaling `FrameTask.orientation_cost` per tick from the min `mj_geomDistance` of the last tick. Cheap, big UX win for teleop near clutter.
- **Joint-space velocity/accel/jerk regularization over a 3-deep history** — CollisionIK's `MinimizeVelocity/Acceleration/Jerk` trio is why RelaxedIK output looks smooth on real arms; mink only has damping/posture. Add accel/jerk terms to the QP cost (they're linear in Δq given history) before streaming to `set_servo_cartesian`-less joint servo.
- **Active-set filtering** (top-N nearest obstacle pairs, broadphase margin ≈ 20·radius): mink already broadphases, but capping constraint rows per tick keeps worst-case QP latency bounded — matters at 100 Hz with 2 arms + env meshes.
- **"Skip solve if already penetrating"** is the wrong recovery behavior for us; instead reuse mink's signed-distance handling (negative dist ⇒ constraint only allows opening velocity) which *repairs* shallow penetration.

Do **not** reuse: relaxed_ik_core as a runtime dependency (model duplication, no env world on main, singleton FFI on collision-ik, CWD path handling). If we ever want the Rust solver anyway (e.g., to offload the solve), use the `main` branch, fix `SelfCollision::new(0→i, j, k)` + add cross-chain pairs, and re-enable an `EnvCollision` term against parry3d — that's a ~2–3 day Rust patch, still with cruder geometry than the twin.

### (b) Collision-free reset planning between two nearby arms

CollisionIK offers nothing here — it is per-instant and explicitly gets stuck in local minima (paper Experiment 2); reset planning needs a global planner. Recommended:

- Plan in the twin's `MjModel` with a joint-space RRT-Connect/PRM over the 16-DoF composite (or sequential per-arm with the other arm as a moving obstacle), using `mj_geomDistance`/`mj_collision` on inflated geoms as the validity checker — the same geom pairs as the teleop limit, so one source of truth.
- Use IK-with-tolerances (mink with `PostureTask` toward a canonical home + collision limit) to generate goal configurations for the planner.
- Track the planned path by streaming waypoints through the *same* teleop-time constrained differential IK, so even during resets the runtime safety layer is identical.
- The one CollisionIK idea that helps: seed/warm-start and smoothness costs when shortcutting the planned path (velocity/accel/jerk trio again).

### Suggested concrete next steps for apollo-xarm7

1. Build the workcell MJCF: 1–3 xArm7 (MuJoCo Menagerie `ufactory_xarm7`, also vendored in mink examples) + prismatic rail joint (`range="0 0.65"`) per railed arm + environment meshes; add slightly inflated collision capsules on links (or rely on `minimum_distance_from_collisions`).
2. Wrap mink: one `Configuration` per workcell, `FrameTask` per arm EE, `PostureTask`, `ConfigurationLimit`, `VelocityLimit`, one `CollisionAvoidanceLimit` with self + cross-arm + env pairs. Target: solve+integrate < 5 ms worst case.
3. Add the RelaxedIK-inspired extras (accel/jerk cost, adaptive orientation weight, per-axis tolerance flags for camera-frame collection) as thin layers over `solve_ik`.
4. Keep `relaxed_ik_core@main` bookmarked as a fallback high-rate solver; do not adopt `collision-ik` branch code.
