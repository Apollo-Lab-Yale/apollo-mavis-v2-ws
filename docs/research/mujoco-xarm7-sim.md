# MuJoCo simulation assets & techniques for xArm7

Research note for the apollo-xarm7 stack (1-3 real/simulated UFACTORY xArm7, rail-mounted,
digital-twin collision checking, web-streamed rendering, teleop-in-sim).

**Verified against:** MuJoCo **3.12.0** (installed and benchmarked on this machine: Ubuntu 22.04,
Python 3.10, RTX 4090, EGL headless). Sources read: shallow clones of
`M4D-SC1ENTIST/mavis_mujoco`, `google-deepmind/mujoco_menagerie` (`ufactory_xarm7`), and the
MuJoCo source tree (`src/engine/engine_collision_driver.c`, `doc/`).

All benchmark numbers below were measured on this machine, 2026-09-01.

---

## 1. mavis_mujoco (prior dual-xArm7 scene) — what is there, what to reuse

Repo layout (relevant parts):

```
mavis_mujoco_gym/
  envs/MJCF/
    mavis_base_scene.xml            # top-level scene: <include> of the two arm files
    xarm7_with_gripper_and_rail.xml # "manipulation" arm: rail + xArm7 + xArm Gripper
    xarm7_with_camera_and_rail.xml  # "viewpoint" arm: rail + xArm7 + D435 camera mount
    xarm7_with_gripper_kit.xml      # same arm, rail mounted elevated (pos="-1 -0.15 1.65")
    xarm7_with_cam_kit.xml          # elevated camera arm variant
    pick_and_place.xml, microwave.xml, basic_scene_kit.xml
    assets/*.stl                    # menagerie meshes + linear_motor_rail/platform + d435_with_cam_stand
    LICENSE                         # BSD-3-Clause (UFACTORY) — inherited from menagerie
  envs/mavis_base/mavis_base_env.py # gymnasium MujocoEnv subclass, dual-arm obs/act spaces
  envs/realworld_system/realworld_system.py  # same env API against real arms (xArm-Python-SDK + pyrealsense2)
  utils/mavis_utils.py              # numba-jit analytic FK + nlopt IK (bimanual, look-at objectives)
```

### Scene composition (MJCF structure)

- **Composition is by `<include>` with fully manual name-suffixing.** `mavis_base_scene.xml`
  includes the two robot files; every body/joint/actuator in one file is suffixed
  `_manipulation`, in the other `_viewpoint`. Crucially, **even the mesh assets are duplicated
  on disk** (`link1.stl` vs `link1_viewpoint.stl`, `linear_motor_rail.stl` vs
  `linear_motor_rail_viewpoint.stl`) because `<include>` shares a single global namespace and
  asset names collide. This is exactly the pain point that `MjSpec.attach` (Section 3) removes.
- **Robot model is a copy of menagerie `ufactory_xarm7`** (same link inertias/poses verbatim, same
  gripper linkage), predating the Dec-2024 menagerie grasping fix (no finger pad boxes, no
  `armature="0.1"` on arm joints). Local modifications: `condim="4"/"6"`,
  `friction="1 1 1"` on finger geoms, softer gripper equality constraints
  (`solref="0.01 1" solimp="0.99 0.999 0.01"`), extra gripper-knuckle `<exclude>` pairs, TCP site
  moved to `pos="0 0 .165"` (menagerie: `0 0 .172`).
- **Linear rail model** (matches your hardware concept): a static `linear_motor_rail` body +
  `linear_motor_platform` child with

  ```xml
  <joint name="linear_track_joint_manipulation" type="slide" axis="0 1 0"
         range="-0.37 0.37" stiffness="50" damping="50" armature="0.1"/>
  ...
  <general name="linear_track_actuator_manipulation" joint="linear_track_joint_manipulation"
           ctrlrange="-0.37 0.37" forcerange="-50 50" gear="50"/>
  ```

  i.e. 0.74 m travel, re-zeroed in Python by `+0.37` so the app-level range is `[0, 0.74]`.
  **Your real rail is 0.65 m max travel — the range must be changed** (`range="-0.325 0.325"`
  or `[0, 0.65]` with offset convention).
- **Arm actuators**: identical to menagerie — `<general>` position servos, `biastype="affine"`,
  three strength classes (`size1`: kp=1500, force ±50; `size2`: kp=1000, ±30; `size3`: kp=800,
  ±20), `ctrlrange` = joint limits. Gripper: single `<general>` actuator on a `split` fixed
  tendon (0.5 × each driver joint), `ctrlrange="0 255"` (mimics the real xArm gripper's 0-255-ish
  command), `gainprm="0.333" biasprm="0 -100 -10"`; the fingers are coupled by
  `<equality><connect>` + `<joint ... polycoef="0 1 0 0 0">` mimic constraints and a
  `spring_link` class on inner knuckles.
- **Wrist camera**: on the viewpoint arm's `link7`, a `d435_with_cam_stand.stl` mesh body plus

  ```xml
  <camera name="realsense_camera" pos="0.07 0 0.05" quat="0 0.7071 0.7071 0" fovy="57"/>
  ```

  (fovy 57° ≈ D435 vertical FoV). Rendered via gymnasium's `mujoco_renderer` at 640×480 RGB +
  normalized depth.
- **Physics options** used for grasping (in `pick_and_place.xml`):
  `<flag multiccd="enable"/>`, `cone="elliptic"`, `impratio="10"`, `tolerance="1e-10"`, box
  object with `condim="6" friction="3 0.1 0.1" margin="0.001"`. Base timestep 0.001-0.002,
  `integrator="implicitfast"`; gym env steps with `frame_skip=20` → 25 Hz env rate.
- **Keyframe convention**: first `<key>` is the initial robot state; envs reset with
  `mujoco.mj_resetDataKeyframe(model, data, 0)`.
- **Control/IK**: no Jacobian IK; `mavis_utils.py` implements hand-written analytic FK
  (numba `@jit`) for arm+rail and solves bimanual IK as an nlopt (`LD_SLSQP`-style) optimization
  with finite-difference gradients, including "look-at" objectives for the camera arm.
  `realworld_system.py` mirrors the sim env against two real arms via
  `xarm.wrapper.XArmAPI` (`set_servo_angle`, `get_linear_track_pos`, `get_gripper_position`,
  `set_collision_sensitivity`, `set_self_collision_detection`).

### Directly reusable for apollo-xarm7

| Asset | Verdict |
| --- | --- |
| `linear_motor_rail.stl`, `linear_motor_platform.stl` | **Reuse** — only existing mesh of your rail; fix travel to 0.65 m |
| `d435_with_cam_stand.stl` + camera pose/fovy | **Reuse** for wrist-cam digital twin |
| Rail slide-joint + actuator pattern (8-DoF arm = rail + 7 joints) | **Reuse** pattern |
| Gripper `ctrlrange 0-255` ↔ real gripper 0-850 mapping idea (`0.085 m` opening) | Reuse conversion helpers (`_convert_gripper_state_to_mujoco_ctrl`) |
| Grasping physics options (`multiccd`, elliptic cone, `impratio=10`, finger `condim`) | Reuse as starting point, but prefer menagerie's newer finger-pad geoms |
| Dual-file `<include>` + manual suffix composition | **Do not reuse** — replace with `MjSpec.attach` |
| nlopt/numba analytic IK | Do not reuse — hardcoded to this exact 2-arm layout; use mink/Jacobian IK on the MuJoCo model instead |
| Keyframe-0-as-initial-state, reset via `mj_resetDataKeyframe` | Reuse convention |

---

## 2. mujoco_menagerie `ufactory_xarm7` — model quality, gripper, license

Files: `xarm7.xml` (arm + xArm Gripper, 13 DoF), `xarm7_nohand.xml` (arm only, 7 DoF),
`hand.xml` (standalone xArm Gripper, 6 DoF), `scene.xml` (arm + floor + skybox + a 0.12 m
pedestal cylinder), `assets/*.stl` (16 meshes).

- **License: BSD-3-Clause**, copyright UFACTORY Inc. — permissive, fine to vendor.
- Derived from the official `xarm_ros` URDF; requires MuJoCo ≥ 2.3.3.
- **Quality**: good. Real inertias from URDF; per-joint `frictionloss="1"`, `armature="0.1"`;
  `implicitfast` integrator; joint limits match the real arm
  (j2 `[-2.059, 2.0944]`, j4 `[-0.19198, 3.927]`, j6 `[-1.69297, 3.14159]`, others ±2π).
  CHANGELOG 2024-12-17: grasping improved by adding **two collision box pads per finger**
  (`pad_box1`/`pad_box2` classes, `priority="1"`, tuned `solimp/solref/friction`) and
  `armature=0.1` — this is the main reason to prefer menagerie's current copy over the mavis fork.
- **Gripper is included** (the UFACTORY xArm Gripper): driver/follower/spring-link joint classes,
  `split` tendon + one `<general name="gripper" ... ctrlrange="0 255">` actuator, mimic
  equality constraints, knuckle `<exclude>` pairs, and a TCP site `link_tcp` at `0 0 .172` from
  the gripper base.
- **Actuators**: `<general>` position servos with `biastype="affine"`
  (`gainprm=kp`, `biasprm="0 -kp -kv"`), classes size1/2/3 as described above. These behave like
  the real arm's `set_servo_angle_j` streaming mode: write joint targets into `data.ctrl` each tick.
- **Keyframe** `home`: `qpos/ctrl = 0 -.247 0 .909 0 1.15644 0 ...`.
- Caveats: single mesh per link used for both visual and collision (collides via **convex
  hull**); no rail; `link_base` in `xarm7.xml` sits at `pos="0 0 .12"` to match the pedestal in
  `scene.xml` — remove/override that offset when mounting on the rail platform.

---

## 3. Composing N arms + environment programmatically: `mujoco.MjSpec`

Since MuJoCo 3.1.x the model-editing API (`mjSpec` / Python `mujoco.MjSpec`) is the right way to
build N-robot scenes. Verified working on 3.12.0:

```python
import mujoco

XARM = "third_party/mujoco_menagerie/ufactory_xarm7/xarm7.xml"

spec = mujoco.MjSpec()                        # parent scene
spec.option.timestep = 0.002
spec.option.integrator = mujoco.mjtIntegrator.mjINT_IMPLICITFAST
spec.visual.global_.offwidth = 1920           # offscreen framebuffer for Renderer
spec.visual.global_.offheight = 1080
spec.worldbody.add_light(pos=[0, 0, 3], dir=[0, 0, -1],
                         type=mujoco.mjtLightType.mjLIGHT_DIRECTIONAL)
spec.worldbody.add_geom(name="floor", type=mujoco.mjtGeom.mjGEOM_PLANE, size=[3, 3, 0.1])
spec.worldbody.add_camera(name="cam_front", pos=[2, 0, 1.2], xyaxes=[0, 1, 0, -0.5, 0, 1])

for i, base_pose in enumerate(arm_base_poses):          # 1-3 arms
    arm = mujoco.MjSpec.from_file(XARM)                 # fresh child spec per attach
    frame = spec.worldbody.add_frame(pos=base_pose.pos, quat=base_pose.quat)
    spec.attach(arm, prefix=f"arm{i}_", frame=frame)    # namespaces EVERYTHING

model = spec.compile()
xml_string = spec.to_xml()      # round-trip for debugging / archiving with episodes
```

Facts verified by running the above with 3 arms:

- `MjSpec.attach(child, prefix=..., suffix=..., site=... | frame=...)` copies the child's whole
  kinematic tree **plus** referencing elements outside it (actuators, sensors, tendons,
  equalities, excludes, defaults, keyframes) and **namespaces every name** with the prefix:
  actuators become `arm0_act1 ... arm0_gripper`, meshes `arm0_link_base`, keyframes
  `arm0_home`, etc. No hand-editing, no duplicated STL files (contrast with mavis).
- Attached **keyframes are re-indexed to the full model** (`model.key(0).qpos.shape == (nq,)`,
  3 keyframes for 3 arms). Doc caveat (`doc/programming/modeledit.rst`): keyframe re-indexing is
  finalized at compile; older versions lose keyframes if you attach twice without compiling —
  worked fine in 3.12 with 3 sequential attaches.
- **All child assets are copied in, referenced or not** (known limitation) — 3 arms → `nmesh=48`.
  Harmless at this scale.
- **Option conflicts**: if both parent and child author `<option>` fields, attach emits
  `Attach conflict ... keeping parent value` warnings (policy `spec.compiler.conflict`:
  `"warning"` default / `"merge"` / `"error"`). Set options explicitly on the parent spec and
  ignore/prefix-silence the warnings.
- Body-level variant: `body.attach_frame(frame, prefix, suffix)`; site-anchored attach for
  end-effectors: `spec.attach(gripper_spec, site="attachment_site", prefix=...)` — this is the
  menagerie-documented way to put a hand on `xarm7_nohand.xml`.
- Pure-MJCF alternatives exist (`<attach model=... body=... prefix=.../>` meta-element with
  `<asset><model .../></asset>`, and `<replicate>`), but the Python API is strictly more
  flexible for "N arms chosen at runtime, per-arm rail yes/no, per-arm gripper yes/no".

**Recommended composition for this stack:** write one clean `xarm7_on_rail.xml` child model
(rail slide joint `range` set to the real 0.65 m + menagerie arm + gripper, with an
`attachment_site` on the platform), then a scene builder that `attach`es it 1-3 times with
prefixes `armK_`, adds environment meshes (slightly inflated copies for the twin, see §4), and
compiles. Keep `spec.to_xml()` output alongside recorded episodes for reproducibility.

---

## 4. Digital-twin collision checking (2-3 arms + environment)

### The primitives, with verified semantics

**`mj_geomDistance`** — exact signed clearance between two geoms:

```python
fromto = np.zeros(6)   # optional: witness segment from geom1 surface to geom2 surface
d = mujoco.mj_geomDistance(model, data, g1, g2, distmax, fromto)
# returns min(signed_distance, distmax); if nothing within distmax, returns distmax
# negative = penetration. Requires the (default) native CCD pipeline for accurate
# positive distances; legacy CCD (mjDSBL_NATIVECCD disabled) gives wrong distances.
```

**`margin` / `gap`** — current semantics (confirmed in `engine_collision_driver.c` and the 3.12
XML reference; this changed from older MuJoCo docs, do not trust old blog posts):

- Contacts are **detected** at distance `margin + gap`, but **forces are only generated** at
  distance `margin`. Contacts with `margin < dist < margin + gap` appear in `mjData.contact`
  as *inactive* contacts with `efc_address == -1` / `exclude == 1`.
- The per-pair threshold is the **SUM of the two geoms' values**:
  `pair_margin = geom_margin[g1] + geom_margin[g2]`, same for gap
  (`getMargin`/`getGap`, engine_collision_driver.c:160-175). So setting `gap=δ` on every geom
  yields a `2δ` geom-geom threshold but only `δ` against non-inflated geoms (e.g. floor).
- `margin > 0` alone is NOT pure inflation for a dynamic sim: it makes the constraint solver act
  from `margin` away (measured: 18 N contact force at +2 cm separation with `margin=0.03`).

### Recipe for the twin

The digital twin should be **kinematic-only**: mirror measured joint positions into `qpos`, then
run only the position stages — never `mj_step`:

```python
# one-time inflation: margin stays 0, gap = delta  -> detection-only, zero dynamics effect
DELTA = 0.0125          # 1.25 cm per geom => 2.5 cm effective between two robot geoms
for g in range(model.ngeom):
    if model.geom_contype[g] or model.geom_conaffinity[g]:
        model.geom_gap[g] = DELTA

# per tick (100 Hz):
data.qpos[qpos_idx] = measured_joint_positions      # per-arm slices, precomputed via
mujoco.mj_kinematics(model, data)                   # model.joint(f"arm{i}_joint{j}").qposadr
mujoco.mj_collision(model, data)
for i in range(data.ncon):
    c = data.contact
    pair = (body_of_geom[c.geom1[i]], body_of_geom[c.geom2[i]])
    if pair in allowed_pairs:        # adjacent links, fingers vs grasped object, ...
        continue
    alarm(pair, c.dist[i])           # dist < 2*DELTA: proximity; dist <= 0: hull contact
```

Notes:

- **Geom scaling vs margin/gap**: mesh geoms can't be inflated per-instance
  (`mesh scale` is a compile-time asset attribute and true offset-surfaces aren't supported);
  `gap` inflation is the idiomatic mechanism. For environment meshes you can additionally bake
  slightly scaled/decimated collision copies (e.g. trimesh `mesh.convex_hull` + vertex offset
  along normals) and mark them `contype/conaffinity` collision-only, `group="3"`, `rgba` alpha 0.
- **Mesh collisions use the convex hull** of each link STL — already a mild inflation and a
  conservative over-approximation for concave links (fine for a safety twin).
- **Filtering**: three layers available — automatic (same-body, welded bodies, parent-child),
  `<contact><exclude body1 body2/>` (menagerie already excludes gripper knuckle pairs),
  and `contype/conaffinity` bitmasks (32 bits; e.g. give each arm its own bit to disable
  intra-arm checking entirely while keeping arm-arm and arm-environment).
- **Gotcha found while testing**: MuJoCo's parent-child auto-filter is *disabled when the parent
  is welded to the world*, so `armK_link_base` vs `armK_link1` produces a permanent
  near-contact (dist ≈ 0.0002 m at qpos=0) once the base is fixed. Add an explicit
  `<exclude>`/allowed-pair entry for `link_base↔link1` per arm (and audit other adjacent hulls
  under inflation).
- For **continuous distance monitoring / gradient-style avoidance**, sweep `mj_geomDistance`
  over the arm-vs-arm and arm-vs-environment pair list instead of using contacts.

### Measured cost (3 arms with grippers, 17 collidable geoms/arm, RTX-4090 box, single core)

| Query | Cost |
| --- | --- |
| `mj_kinematics + mj_collision`, no inflation, ncon=0 | **~15 µs / tick** |
| same, `gap=0.0125` on all geoms, home pose (37 inactive contacts) | **~240 µs / tick** |
| same, adversarial leaned pose (72 contacts) | **~750 µs / tick** |
| `mj_geomDistance` full arm0×arm1 sweep, 289 pairs, `distmax=0.2` | **~0.29 ms** (~1 µs/pair) |
| `mj_step` full dynamics, 3 arms | **~38 µs / step** (≈ 26 000 steps/s) |

Conclusion: a 2-3-arm digital twin with 2-3 cm inflation costs **well under 1 ms per 100 Hz
tick** on one core — collision checking will not be the bottleneck. For collision-free reset
planning, the same model + `mj_kinematics/mj_collision` is a valid state-validity checker for an
RRT/OMPL-style planner at ~4k-60k checks/s per core (parallelize with one `MjData` per thread).

---

## 5. Offscreen rendering for web streaming (EGL, `mujoco.Renderer`)

Setup that works headless on this machine:

```bash
export MUJOCO_GL=egl                # per-process; must be set before importing mujoco
export MUJOCO_EGL_DEVICE_ID=1       # optional: pin twin-rendering to the 2nd RTX 4090
```

```python
renderer = mujoco.Renderer(model, height=480, width=640)   # max_geom=10000 default
renderer.update_scene(data, camera="cam_front")            # or camera id / free camera
rgb = renderer.render()                                    # (H, W, 3) uint8
renderer.render(out=preallocated)                          # zero-alloc variant

renderer.enable_depth_rendering()                          # then render() -> (H, W) float32 meters
renderer.disable_depth_rendering()
```

Facts / gotchas:

- Frame sizes above 640×480 require enlarging the offscreen framebuffer in the model:
  `<visual><global offwidth="1920" offheight="1080"/></visual>` (or
  `spec.visual.global_.offwidth = ...`). Otherwise `Renderer(...)` raises
  `Image width 1280 > framebuffer width 640`.
- One GL context per `Renderer`; a context must be used from the thread that created it. For the
  web app, run rendering in a dedicated process/thread that owns the `Renderer`, renders all
  requested cameras from the latest twin state, and hands frames to the encoder
  (nvenc H.264 / MJPEG / WebRTC).
- `update_scene(data, camera, scene_option)` — pass an `mjvOption` to toggle collision-geom
  groups (e.g. show group 3 inflated geoms in a "twin debug" stream but not in the pretty one).
- Segmentation is also available (`renderer.enable_segmentation_rendering()`) if the UI ever
  needs pickable objects.
- Benign EGL teardown noise: destructor-order `EGLError` spam at interpreter exit — call
  `renderer.close()` explicitly on shutdown.
- MuJoCo 3.12 ships a second, experimental **Filament**-based renderer
  (`mujoco.rendering.filament`, PBR quality) next to the classic one; the classic renderer is
  the stable choice today.

### Measured throughput (3-arm scene, EGL on RTX 4090, single process)

| Configuration | Time / frame | FPS |
| --- | --- | --- |
| 640×480 RGB, 1 camera | 0.61 ms | ~1600 |
| 640×480 RGB, 3 cameras sequentially | 1.81 ms/tick | ~1650 aggregate |
| 640×480 depth | 1.07 ms | ~930 |
| 1280×720 RGB | 1.21 ms | ~830 |
| 1920×1080 RGB | 2.35 ms | ~430 |

Rendering 3 sim cameras + 2 twin views at 640×480 @ 30 Hz costs ≈ 3 ms/frame-set — negligible.
The real budget goes to **encoding** (use NVENC via PyNvVideoCodec/GStreamer, not CPU x264, if
streaming several 720p feeds).

---

## 6. Real-time stepping for teleop-in-sim (sim IS the robot)

The menagerie actuators are position servos, so "sim as robot" is exactly the xArm
`set_servo_angle_j` streaming pattern: write joint targets to `data.ctrl` at the command rate and
let the sim integrate. Pattern (100 Hz command tick, 500 Hz physics, wall-clock paced):

```python
CTRL_DT = 0.01                                  # 100 Hz command tick
model.opt.timestep = 0.002                      # keep menagerie's implicitfast + 2 ms
nsub = round(CTRL_DT / model.opt.timestep)      # 5 substeps per tick

mujoco.mj_resetDataKeyframe(model, data, model.key("arm0_home").id)
next_t = time.monotonic()
while running:
    targets = teleop.latest_joint_targets()          # rate-limited / IK output
    data.ctrl[arm_ctrl_idx] = targets                # per-arm slices precomputed from
    data.ctrl[grip_ctrl_idx] = grip_cmd_0_255        #   model.actuator(f"arm{i}_act{j}").id
    mujoco.mj_step(model, data, nstep=nsub)          # nstep kwarg verified in 3.12 bindings
    publish_state(data.qpos, data.qvel, data.time)   # same message type as real-robot driver
    next_t += CTRL_DT
    time.sleep(max(0.0, next_t - time.monotonic()))  # drift-free pacing
```

- Measured `mj_step` cost for 3 arms is ~38 µs, so 5 substeps ≈ 0.2 ms per 10 ms tick — the sim
  runs ~50× real time; pacing is purely sleep-bound and there is ample headroom for the twin's
  collision pass and rendering in the same tick.
- Never pace by counting steps alone; use `time.monotonic()` accumulation (above) so encoder or
  GC hiccups don't accumulate drift. Optionally re-sync (`next_t = time.monotonic()`) if the loop
  falls > 1 tick behind.
- Cartesian teleop: run differential IK (recommend `mink`, or plain damped-least-squares on
  `mujoco.mj_jacSite` at the `armK_link_tcp` site) at the 100 Hz tick, exactly mirroring the real
  pipeline so the "sim robot" and "real robot" expose an identical joint-target interface.
- For interactive debugging visualisation use `mujoco.viewer.launch_passive(model, data)` and
  call `viewer.sync()` once per tick (it takes the physics lock; keep it out of the hot path in
  production — the web stream replaces it).
- Keep one process = one `MjModel/MjData` for the *robot* sim; give the *twin* its own
  model/data pair (same MJCF, inflated gaps) so proximity contacts never perturb teleop physics
  — at these costs, running both at 100 Hz is trivial.

---

## 7. Recommendations for the apollo-xarm7 stack

1. **Vendor menagerie `ufactory_xarm7`** (BSD-3) as the single source of arm/gripper MJCF; do not
   fork per-scene copies. Take mavis's `linear_motor_rail/platform.stl` + `d435_with_cam_stand.stl`
   meshes and its rail-joint pattern, corrected to 0.65 m travel.
2. Author one child model `xarm7_on_rail.xml` (rail slide + menagerie arm + gripper + wrist-cam
   site) and **compose scenes at runtime with `mujoco.MjSpec.attach(child, prefix=f"arm{i}_",
   frame=...)`** — verified to namespace joints/actuators/keyframes/meshes automatically and to
   compile 1-3 arms cleanly. Persist `spec.to_xml()` with every recorded episode.
3. Digital twin = same composed model, kinematic-only (`mj_kinematics` + `mj_collision`),
   inflation via `geom_gap = δ` (margin left 0 → contacts are detection-only), Python-side
   allowed-pair filter; add the `link_base↔link1` exclude per arm. Budget: < 1 ms per 100 Hz tick
   for 3 arms. Use `mj_geomDistance` for the UI's live minimum-clearance readout.
4. Web rendering: `MUJOCO_GL=egl`, one renderer process pinned with `MUJOCO_EGL_DEVICE_ID` to
   GPU 1, `mujoco.Renderer` with `out=` buffers, `offwidth/offheight` bumped to 1920×1080 in the
   scene spec; ~0.6 ms per 640×480 frame leaves encoding as the only real cost.
5. Teleop-in-sim: 100 Hz `data.ctrl` writes + `mj_step(model, data, nstep=5)` + monotonic-clock
   pacing behind the same joint-target interface as the real-arm driver.

## 8. Risks / open items

- mavis rail travel (0.74 m) differs from the stated real rail (0.65 m); rail mesh geometry may
  also differ from the actual linear motor — verify against hardware before trusting twin
  clearances near the rail.
- Menagerie xArm7 actuator gains (kp 1500/1000/800) are plausible but not identified against the
  real arm; for high-fidelity DAgger-in-sim, log real step responses and retune
  `gainprm/biasprm/frictionloss/armature`.
- `margin/gap` semantics changed across MuJoCo versions (detection at `margin+gap` is the
  *current* behavior) — pin the MuJoCo version (tested 3.12.0) and keep the §4 unit test in CI.
- Convex-hull collision inflates concave links; if a tight tabletop layout produces false twin
  alarms, decompose the offending link meshes (e.g. CoACD) into a few convex pieces.
- `MjSpec.attach` copies all child assets per attach (nmesh ×N) and emits option-conflict
  warnings; both benign but should be handled deliberately in the scene builder.
