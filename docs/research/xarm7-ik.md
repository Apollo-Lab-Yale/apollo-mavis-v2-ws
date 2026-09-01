# Research note: `xarm7-ik` (M4D-SC1ENTIST/xarm7-ik)

Deep-dive into the user's existing IK solver, https://github.com/M4D-SC1ENTIST/xarm7-ik
(v0.3.2 on PyPI as `xarm7-ik`), based on reading the full source (shallow clone) and
benchmarking it on this workstation (AMD Threadripper PRO 5975WX; the README's "~150 Hz"
was measured on an i7-11800H laptop and reproduces here as ~130 Hz warm / ~97 Hz cold).

---

## 1. Repo structure

```
xarm7-ik/
├── pyproject.toml            # deps: nlopt>=2.9.1, numba>=0.61.2, scipy>=1.15.3; optional: mujoco>=3.3.5
├── src/xarm7_ik/
│   ├── __init__.py           # empty
│   ├── solver.py             # InverseKinematicsSolver, LookAtInverseKinematicsSolver, RotationRepresentation
│   ├── kinematics.py         # numba-jitted FK (DH), objective functions, finite-diff gradients, nlopt shims
│   └── utils.py              # numba-jitted quaternion math, RelaxedIK-style displacement distance, look-at errors
└── examples/
    ├── simple_ik_example.py, mujoco_ik_example.py, mujoco_ik_example_with_rail.py
    ├── lookat_ik_example.py, lookat_ik_with_linear_rail_example.py, mujoco_lookat_ik_*.py
    ├── base_rotation_offset_example.py
    └── xarm7_env/mjcf/       # xarm7.xml, xarm7_with_linear_rail.xml, xarm7_camera_rail.xml + STL assets
```

Notably the repo ships ready-made **MJCF models of the xArm7 with and without the linear
rail** (including `linear_motor_rail.stl` / `linear_motor_platform.stl` and a
`link_tcp` site) — directly reusable for the digital twin and for a MuJoCo-based IK
reimplementation.

There is a single branch/variant: the "with/without linear motor" variants are one code
path switched by the `use_linear_motor` constructor flag (7 vs 8 decision variables).

## 2. Entry-point API and conventions

```python
from xarm7_ik.solver import InverseKinematicsSolver, LookAtInverseKinematicsSolver

ik = InverseKinematicsSolver(
    use_linear_motor=True,        # False -> 7 DoF, True -> 8 DoF (rail + 7 joints)
    linear_motor_x_offset=0.0,    # constant X offset of the rail origin, meters
    rotation_repr="quaternion",   # "quaternion" | "euler" | "axis-angle"  (see BUG in §5)
    opt_solver=nlopt.LD_SLSQP,    # default; NOTE: rail branch ignores this arg and hardcodes LD_SLSQP
    base_rotation_offset=0.0,     # Z rotation of the arm base, radians
)

q_out = ik.inverse_kinematics(
    initial_configuration,   # np.ndarray (7,) or (8,); rail variant: [rail_pos, j1..j7]
    target_gripper_pos,      # np.ndarray (3,), meters, arm-base/world frame
    target_gripper_rot,      # (4,) quaternion W-X-Y-Z (MuJoCo order)
)                            # returns np.ndarray of joint values; ON FAILURE returns the seed unchanged (+prints)

pos, quat_wxyz = ik.forward_kinematics(configuration)   # meters, W-X-Y-Z
```

Conventions and details that matter for integration:

- **Units:** meters and radians throughout. **Quaternions: W-X-Y-Z** (MuJoCo order;
  scipy X-Y-Z-W is converted internally for the euler path).
- **Frame:** targets are in the arm-base frame (rail variant: the rail-origin frame).
  `base_rotation_offset` applies an extra Z rotation at the base of the DH chain
  (`kinematics.py:36-48`) for arms mounted rotated in the workcell.
- **Implicit tool-orientation offset:** `solver.py:48` sets `quat_offset = [0,1,0,0]`
  (180° about X) and premultiplies every target quaternion
  (`target = quat_offset ⊗ target`). So a user-facing **identity quaternion means
  "gripper pointing straight down"** — any consumer must adopt this convention.
- **FK terminates at the flange** (UFACTORY DH, last d = 0.097 m). There is **no TCP /
  gripper-length parameter**; the MJCF's `link_tcp` site sits 0.172 m past link7, so
  gripper-frame targets must be converted to flange targets by the caller. (The look-at
  solver instead takes an ad-hoc `lookat_offset=[0,0,-0.15]`.)
- **DH parameters** are hardcoded in `kinematics.py:26-34` from the official UFACTORY
  table (a, d, alpha, theta): d1=0.267, d3=0.293, a3=0.0525, a4=0.0775, d5=0.3425,
  a6=0.076, d7=0.097.
- **Joint bounds** hardcoded in `solver.py:35-39`; xArm7 limits (J2 ∈ [-2.059, 2.0944],
  J4 ∈ [-1.9198, 3.927], J6 ∈ [-1.69297, 3.14159], others ±2π). Rail bound is
  **[0.0, 0.74] m** — the physical rail in our workcell has **0.65 m travel**, so these
  constants must be edited (they are not constructor args).
- The MJCF rail joint is `<joint name="linear_track_joint" type="slide" axis="0 1 0"
  range="-0.37 0.37">` — examples shift by 0.37 to map solver range [0, 0.74] onto
  MJCF range [-0.37, 0.37].
- `LookAtInverseKinematicsSolver.inverse_kinematics(initial_configuration, target_pos,
  lookat_pos)` solves position + "camera looks at a point" + "keep side axis level"
  instead of full orientation — useful for a wrist/rail camera.

## 3. Algorithm

**It is a small NLopt SLSQP nonlinear program with a scalarized pose error, numba-jitted
DH forward kinematics, and central finite-difference gradients.** No Jacobian
pseudo-inverse, no analytic Jacobian at all.

Per `inverse_kinematics` call (`solver.py:81-133`):

1. Convert rotation to W-X-Y-Z quaternion, normalize, premultiply `quat_offset`.
2. `opt.set_min_objective(lambda x, grad: ik_objective_function_nlopt(...))` — a fresh
   Python closure every call.
3. `opt.optimize(seed)` with `nlopt.LD_SLSQP`, box bounds = joint limits,
   `xtol_rel=1e-6`, `maxtime=0.5` (!).
4. Objective (`kinematics.py:73-76`): scalar
   `‖p−p*‖ + quaternion_displacement_based_distance(q, q*)` — the quaternion term
   (`utils.py:108-121`, "based on Danny's notes") is the log-map displacement distance
   from **RelaxedIK** (Rakita et al.; Rakita co-authors the paper this repo cites).
   This solver is essentially a minimal, unweighted RelaxedIK without the Groove loss,
   smoothness terms, or collision terms.
5. Gradient (`kinematics.py:89-104`): central finite differences, ε=1e-6 → **2N+1 FK
   evaluations per objective+gradient call** (15 for 7-DoF, 17 for 8-DoF), executed
   inside one numba `@jit(nopython=True)` function.
6. FK (`kinematics.py:7-69`): loop of seven 4×4 DH transforms, all `np.array` literals
   allocated per call, then matrix→quaternion.

### Where the ~150 Hz ceiling comes from (measured)

Micro-benchmarks on this machine (`numba 0.67`, `nlopt 2.11`):

| item | cost |
|---|---|
| one jitted FK call (from Python) | ~4.6 µs |
| one objective value | ~4.7 µs |
| one finite-diff gradient (14 FK evals, inside numba) | ~72 µs |
| **objective callbacks per solve, warm-started servo, 7-DoF** | **~110** |
| objective callbacks per solve, 8-DoF (rail) | ~203 |

So one warm-started solve ≈ 110 × (4.7 + 72) µs ≈ 8.5 ms → measured **134 Hz** (7-DoF)
and **59 Hz** (8-DoF rail). End-to-end measurements:

| config | cold (random targets, zero seed) | warm (servo-style, prev-solution seed) |
|---|---|---|
| 7-DoF | 10.3 ms → **97 Hz** | 7.4 ms → **134 Hz** |
| 8-DoF rail | 15.5 ms → **65 Hz** | 16.9 ms → **59 Hz** |

Bottleneck decomposition, in order of impact:

1. **Iteration count.** `xtol_rel=1e-6` forces SLSQP to grind ~110–200 objective calls
   even when the seed is microns from the solution — there is **no `stopval` early
   exit**, so warm-starting barely helps. This is the #1 cost.
2. **Finite-difference gradients.** Each iteration pays 2N+1 FK evaluations (~72 µs)
   instead of one analytic Jacobian (~5 µs equivalent). ~15× waste.
3. **Per-call FK allocation overhead.** The jitted FK allocates the 7×4 DH array and
   seven 4×4 temporaries per call; 4.6 µs/FK is ~10× what a preallocated C/Rust FK costs.
4. Python↔C callback overhead per nlopt iteration and the per-call
   `set_min_objective` closure are real but minor (<10%).

Also relevant for a 100 Hz servo loop: `maxtime=0.5 s` means a pathological solve can
block half a second; numba functions here don't use `nogil=True` and nlopt calls back
into Python, so solves hold the GIL — **3 arms in one process cannot solve concurrently**.

### Rate is tunable without touching the algorithm (measured)

Adding a stop-value / eval cap to the existing solver (servo-style, warm-started):

| stopping rule | 7-DoF rate | 8-DoF rate | tracking err (mean / max) |
|---|---|---|---|
| `xtol_rel=1e-6` (shipped default) | 132 Hz | 69 Hz | 0.000 / 0.008 mm |
| `opt.set_stopval(1e-4)` | **318 Hz** | **264 Hz** | 0.05 / 0.10 mm |
| `opt.set_maxeval(30)` | 520 Hz | 420 Hz | 0.3 / 4.4 mm |
| `xtol_rel=1e-4` | 371 Hz | 249 Hz | 3.2 / 34 mm (unsafe) |

`set_stopval(1e-4)` (objective < 0.1 mm-equivalent) is a two-line change giving 2–4×
with sub-0.1 mm accuracy.

## 4. How the linear-motor variant models the rail; redundancy resolution

- The rail is an **8th decision variable** prepended to the configuration:
  `[rail, j1..j7]`, bounds `[0.0, 0.74]` m (hardcoded).
- FK composition (`kinematics.py:16-18, 60-63`): the rail is a **pure translation of
  the arm base along +Y** of the base frame with a constant X offset:
  `T = Trans([linear_motor_x_offset, rail, 0]) @ T_arm`. It is *not* a DH row and its
  axis/direction is not configurable (Y only).
- **Redundancy resolution: none, and this is the key limitation.** The xArm7 alone is
  1-redundant for a 6-DoF pose; with the rail it is 2-redundant. There is no posture
  cost, no nullspace bias, no penalty on rail motion or joint displacement from the
  seed — SLSQP simply converges to *some* local optimum near the seed. Continuity in a
  servo loop relies entirely on warm-starting; nothing prevents elbow flips or the rail
  "absorbing" motion that the joints should take (or vice versa), and cold solves are
  arbitrary among the self-motion manifold.

## 5. Bugs / gotchas found while reading the source (verified by execution)

1. **`rotation_repr="euler"` and `"axis-angle"` are broken.** `solver.py:41`
   (`self.rotation_repr = rotation_repr`) overwrites the parsed enum with the raw
   string, so every `self.rotation_repr == RotationRepresentation.X` comparison in
   `inverse_kinematics` is `False`. Quaternion input works only by falling through to
   the `else:` branch, whose `ValueError(...)` is constructed **but never raised**
   (`solver.py:100`). Verified: a 3-element euler input crashes with
   `ZeroDivisionError` inside `normalize_quaternion`; axis-angle input is silently
   treated as a raw W-X-Y-Z quaternion. **Only pass W-X-Y-Z quaternions.**
2. **Failure handling swallows everything:** `except (…, Exception)` returns the seed
   configuration and `print`s — at 100 Hz this silently freezes the arm while spamming
   stdout; no status/error is returned to the caller.
3. `opt_solver` argument is ignored in the rail branch of `InverseKinematicsSolver`
   (`solver.py:51` hardcodes `nlopt.LD_SLSQP`).
4. Rail bounds hardcoded to 0.74 m travel; our rail is 0.65 m — must patch
   `solver.py:35-36` (and `:178-179` for the look-at solver).
5. First-instance construction pays **~5 s of numba JIT warm-up** (`init_dry_run`);
   plan for it at process start (or ship a numba cache dir).
6. `calculate_look_at_error` mutates then discards `eef_pos += offset` after computing
   the projection (`utils.py:194-195`) — the look-at offset effectively does nothing to
   the error; likely a latent bug in the look-at variant.

## 6. Acceleration paths, measured/estimated

### (a) Tune / fix the existing code (numba + nlopt stays)

- Two-line win, measured: `set_stopval(1e-4)` + a `maxeval` latency cap → **~320 Hz
  (7-DoF) / ~265 Hz (rail)** with ≤0.1 mm error.
- Analytic Jacobian in numba (position part is textbook for a revolute chain; the
  quaternion-log distance gradient is more work) removes the 15-17× finite-diff
  multiplier → per-iteration cost ~10 µs → est. **1–2 kHz**.
- Rewriting the whole solve loop in numba (damped Gauss–Newton instead of nlopt, no
  Python callbacks) → est. 5–10 kHz, but at that point you have re-implemented
  differential IK by hand and still own DH params, limits, and the redundancy problem.
- Effort: hours (tuning) → ~1 week (analytic Jacobian + in-numba solver). Still
  GIL-bound per process; 3 arms ⇒ 3 processes or 3× headroom.

### (b) MuJoCo differential IK via `mink` — measured on the repo's own MJCF

Benchmarked `mink 1.3.0` (`pip install mink`, uses `qpsolvers`+`daqp`) with
`FrameTask(frame_name="link_tcp", frame_type="site")` + `PostureTask` +
`ConfigurationLimit` on `examples/xarm7_env/mjcf/xarm7*.xml` from this very repo:

| scenario | result |
|---|---|
| servo loop, 7-DoF | **116 µs/step mean, 132 µs p99 → ~8,600 Hz**, 0.01 mm tracking |
| servo loop, 8-DoF rail | **113 µs/step → ~8,800 Hz** (rail is just one more velocity DoF) |
| one-shot far target (rail variant, iterate to convergence) | 18–28 QP steps, **2–4 ms**, <0.1 mm, rail placed automatically |

- ~65× faster than the current solver; one process handles 3 arms at 100 Hz with ~4%
  of a core.
- Solves the redundancy problem properly: `PostureTask` (nullspace bias) + optional
  `DampingTask`; a per-DoF weight can make rail motion "expensive" so the arm prefers
  joint motion (`mink.PostureTask(cost=...)` accepts per-joint costs).
- `mink.CollisionAvoidanceLimit(model, geom_pairs)` gives velocity-level collision
  avoidance from the same MJCF **digital twin** (inflated geoms) — arm-arm and
  arm-environment pairs — unifying IK and the collision layer in one model.
- Caveats: it is velocity IK (needs a target stream, which teleop/policy inference
  naturally provide); for one-shot queries wrap it in the 2–4 ms convergence loop;
  unreachable targets converge to the closest reachable pose without an explicit
  failure flag (check residual).
- Effort: ~1–2 days (the MJCF already exists in the repo; keyframe + site are present).

### (c) Rust/C++ port, e.g. `relaxed_ik_core`

- `uwgraphics/relaxed_ik_core` (MIT, Rust, `ranged-ik` branch is the maintained one):
  configure with URDF in `configs/urdfs/` + a settings file; call through
  `wrappers/python_wrapper.py` (cdylib `librelaxed_ik_lib.so`). This is the direct
  ancestor of xarm7-ik's objective (same quaternion displacement distance), adds Groove
  loss + smoothness terms, typically solves in 0.1–1 ms → **1–10 kHz**.
- Needs an xArm7+rail URDF with a prismatic first joint; FFI/build plumbing; less
  natural integration with the MuJoCo twin than (b). Alternative modern Rust option:
  `kylc/optik` (URDF, PyO3 bindings, sub-ms global+local IK).
- Effort: ~1–2 weeks including URDF authoring, packaging, and redundancy-weight tuning.
  Justified only if we later need guaranteed sub-100 µs worst-case in a non-MuJoCo
  process.

### (d) CasADi / compiled NLP

- Build the DH chain symbolically once, get exact Jacobians by AD, codegen the
  objective/Jacobian to C, solve with `sqpmethod`/Ipopt or a hand-rolled damped
  Gauss–Newton on the compiled functions. Realistic **1–5 kHz** warm-started; keeps the
  "position IK with hard bounds" formulation.
- Effort: ~3–5 days. Strictly dominated here by (b) unless we need NLP-only features
  (exact hard constraints on arbitrary nonlinear expressions, e.g. look-at as a hard
  constraint).

## 7. Recommendation for the apollo-xarm7 stack

Adopt **path (b): mink-based differential IK on the MuJoCo digital twin** as the
primary Cartesian-servo IK for all modes (teleop, DAgger take-over, policy inference).
Measured ~8.6 kHz/arm on this machine leaves enormous headroom for 3 arms at 100–500 Hz
in a single Python process, the rail DoF and its redundancy are handled by posture-task
weights, and `CollisionAvoidanceLimit` reuses the same inflated-geometry MJCF already
planned for collision checking — one model, one process, no extra FFI. Keep the repo's
conventions at the API boundary (meters, radians, **W-X-Y-Z** quaternions,
"identity = gripper down" via the 180°-about-X offset) so existing datasets/policies
stay compatible, and reuse its MJCF assets for the twin. As a stopgap while porting,
patch the existing solver with `opt.set_stopval(1e-4)` + `opt.set_maxeval(~60)`
(measured ~320/265 Hz), fix the rail bounds to 0.65 m, and only ever feed it
quaternions (euler/axis-angle paths are broken). Revisit path (c) (Rust) only if a
hard-real-time non-MuJoCo consumer appears.

---
*Benchmarks: 2026-09-01, Threadripper PRO 5975WX, Python 3.10.12, numba 0.67.0,
nlopt 2.11.0, mujoco 3.12.0, mink 1.3.0, daqp 0.9.1. Scripts used: servo-style loops
with warm-started seeds; see /tmp/bench_ik.py, /tmp/bench_tol.py, /tmp/bench_mink*.py
(ephemeral).*
