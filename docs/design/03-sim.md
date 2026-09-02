# 03 — apollo-xarm7-sim (`apollo_xarm7_sim`)

Status: v0.1 (2026-09-01). Conforms to `00-overview.md` (spine, v0.3). Ground
truth for numbers: `docs/research/{mujoco-xarm7-sim,xarm7-ik,collision-ik}.md`
(benchmarked on this machine, 2026-09-01). Depends only on `apollo_xarm7_core`
(+ mujoco, mink, numpy); never imports `hardware`, `runtime`, or FastAPI.

---

## 1. Package layout & dependencies

```
apollo-xarm7-sim/
├── pyproject.toml                  # deps: apollo-xarm7-core, mujoco==3.12.0,
│                                   #   mink==1.3.0, numpy>=1.24, pyyaml, pydantic>=2
├── src/apollo_xarm7_sim/
│   ├── __init__.py                 # re-exports the public classes below
│   ├── assets/                     # package data: ufactory_xarm7/ (§2),
│   │                               #   xarm7_on_rail.xml + xarm7_fixed.xml (§3),
│   │                               #   rail/, cameras/, meshes/ (STLs, §2),
│   │                               #   scenes/*.yaml descriptors (§4)
│   ├── scenes/                     # descriptor.py, registry.py (§4),
│   │                               #   builder.py, addressing.py (§5)
│   ├── workcell.py                 # SimWorkcell, SimArm (§6)
│   ├── cameras.py, rendering.py    # SimCamera, RenderService (§7)
│   ├── twin.py                     # DigitalTwin (§8)
│   ├── ik.py                       # MinkIKSolver + refinements (§9)
│   ├── planner.py                  # ResetPlanner — RRT-Connect (§10)
│   ├── gripper.py                  # 0–255 ↔ open-fraction ↔ 0.085 m (§6)
│   └── tools/guardrail_check.py    # §11 — CI guardrail regression (11-safety §5.1)
└── tests/                          # §14
```

Rules (overview §1): imports from `apollo_xarm7_core` only. Public classes
implement the core interfaces and schemas (`WorkcellInterface`, `ArmInterface`,
`CameraInterface`, `IKSolver`, `DigitalTwinInterface`; `Pose`, `ArmState`,
`CameraFrame`, `CollisionReport`, `CollisionEvent` — exact spellings in
`01-core.md`). Units: meters, radians, quaternions **wxyz** (overview §3.1).

## 2. Vendored assets & licensing

| Asset | Source | License | Notes |
|---|---|---|---|
| `assets/ufactory_xarm7/` (`xarm7.xml`, `xarm7_nohand.xml`, `hand.xml`, 16 STLs, `LICENSE`) | `google-deepmind/mujoco_menagerie` | **BSD-3-Clause** (UFACTORY Inc.) | Vendor the **current** menagerie copy (post 2024-12-17 grasping fix: finger `pad_box1/pad_box2` collision pads, `armature=0.1`). Record the upstream commit hash in `assets/ufactory_xarm7/UPSTREAM` for provenance. Do NOT use the mavis fork of the arm (predates the fix). |
| `assets/rail/linear_motor_rail.stl`, `linear_motor_platform.stl` | `M4D-SC1ENTIST/mavis_mujoco` | BSD-3 (inherited from menagerie per its `LICENSE`) | Only existing mesh of our rail. The mavis joint models **0.74 m travel — wrong**; our rail is **0.65 m** (§3). Mesh geometry unverified against real hardware; flag in `UPSTREAM`. |
| `assets/cameras/d435_with_cam_stand.stl` | mavis_mujoco | BSD-3 | Wrist D435 + mount, used for the wrist-camera body + `<camera fovy="57">` (≈ D435 vertical FoV). |
| Environment meshes (`assets/meshes/`) | authored in-house | project license | Each env mesh ships a visual copy and, where the convex hull is too coarse, a decomposed collision copy (`group="3"`, alpha 0). |

Repo root: `THIRD_PARTY_LICENSES.md` with the BSD-3 texts; no GPL assets.
Canonical path accessor: `asset_path(*parts) -> Path` over
`importlib.resources.files("apollo_xarm7_sim") / "assets"`.

## 3. The `xarm7_on_rail.xml` child model

One clean, hand-authored child MJCF composing rail + menagerie arm + gripper +
wrist-cam mount. It is the unit that `MjSpec.attach` stamps into scenes 1–3×.

Structure (names are pre-prefix; after attach they become `<arm_id>_...`):

```xml
<mujoco model="xarm7_on_rail">
  <worldbody>
    <body name="rail_base">            <!-- linear_motor_rail.stl, static -->
      <body name="rail_platform">      <!-- linear_motor_platform.stl -->
        <joint name="rail_joint" type="slide" axis="0 1 0"
               range="0 0.65" stiffness="50" damping="50" armature="0.1"/>
        <!-- menagerie xarm7.xml body tree, link_base pos="0 0 .12" pedestal
             offset REMOVED; gripper per menagerie hand.xml; site link_tcp at
             0 0 .172; on link7: d435_with_cam_stand.stl body + <camera
             name="wrist_cam" pos="0.07 0 0.05" quat="0 0.7071 0.7071 0"
             fovy="57"/>  -->
      </body></body></worldbody>
  <actuator>
    <general name="rail" joint="rail_joint" ctrlrange="0 0.65"
             forcerange="-50 50" gear="50"/>
    <!-- menagerie servos act1..act7 (kp 1500/1000/800) + gripper (0–255) -->
  </actuator>
  <contact><exclude body1="link_base" body2="link1"/></contact>  <!-- §8 gotcha -->
  <keyframe><key name="home" qpos="0.325  0 -.247 0 .909 0 1.15644 0 ..."/></keyframe>
</mujoco>
```

Binding decisions:

- **Rail range `[0, 0.65]` directly** — no ±0.325 re-zeroing. MJCF qpos ==
  app-level rail meters == hardware's absolute rail mm/1000. Kills the mavis
  `+0.37` offset class of bug.
- Rail slide axis = **+Y of the rail base frame**; `base_in_world` places
  `rail_base` (the *rail origin* fixed in world, overview §3.1); arm base
  pose = rail origin ⊕ rail travel.
- MJCF-internal qpos layout: railed `[rail, j1..j7]` (8 DoF — the rail slide
  is the kinematic parent, so it comes first in `qpos`); `xarm7_fixed.xml` (no
  rail body/actuator) gives `[j1..j7]` (7 DoF). This ordering is **internal
  only**: the `Addressing` layer (§5) remaps it so every
  `ArmInterface`/`IKSolver`-facing vector uses core order — joints `q[0:7]`,
  rail **LAST** at `q[7]` (01-core §4).
- `keyframe home` = menagerie home posture, rail mid-travel (0.325 m).
  Keyframe 0 of the composed model = scene initial state
  (`mj_resetDataKeyframe(model, data, 0)`).
- Physics options live in the *parent* scene spec only (§4 `options`). TCP
  site stays at menagerie's `0 0 .172` (the mavis fork moved it to .165; we
  do not — overview §3.1).

## 4. Scene registry & YAML scene descriptors

A scene id serves as **sim scene** (`WorkcellConfig.sim_scene`) or
**digital-twin scene** (`digital_twin_scene`) — same machinery. Runtime's
`GET /api/scenes` serializes `SceneMeta` into core `SceneInfo` rows (core §12).

```python
# scenes/registry.py
@dataclass(frozen=True)
class SceneMeta:
    id: str; description: str; n_arms: int
    arm_ids: tuple[str, ...]        # descriptor arm ids, e.g. ("left", "right")
    rail: dict[str, bool]; wrist_cams: dict[str, bool]   # per arm_id
    cameras: tuple[str, ...]        # named MJCF cameras (post-prefix names)
    suitable_for: frozenset[str]    # {"sim", "twin"} — most scenes: both
    allowed_pairs: tuple[tuple[str, str], ...]  # scene-authored structural pairs (§4.2)

class SceneRegistry:                # REGISTRY = SceneRegistry() at import,
    def list(self) -> list[SceneMeta]: ...        # scans assets/scenes/*.yaml
    def meta(self, scene_id: str) -> SceneMeta: ...       # KeyError if unknown
    def build(self, scene_id: str,
              overrides: SceneOverrides | None = None) -> BuiltScene: ...  # §5
```

### 4.1 Descriptor schema

Descriptor schema (pydantic `SceneDescriptor`, one YAML file per scene):

```yaml
# assets/scenes/dual_rail_tabletop.yaml
id: dual_rail_tabletop
description: two railed arms facing a 1.2 m table
suitable_for: [sim, twin]
options: {timestep: 0.002, integrator: implicitfast, cone: elliptic,
          impratio: 10, multiccd: true}
offscreen: {width: 1920, height: 1080}      # spec.visual.global_.off*
arms:                                       # attach prefix "<id>_"
  - {id: left, model: xarm7_on_rail,        # or xarm7_fixed
     base_pos: [0.0, -0.55, 0.0],           # rail-origin in world, m
     base_quat: [1, 0, 0, 0],               # wxyz
     gripper: xarm, wrist_cam: true}        # gripper: xarm | none
  - {id: right, ...}
cameras:
  - {name: cam_front, pos: [2.0, 0.0, 1.2], xyaxes: [0, 1, 0, -0.5, 0, 1], fovy: 45}
environment:   # plane | box | mesh; collider: convex_hull | mesh_copy | boxes;
  - ...        # baked inflated collider copies: visual false, group 3, alpha 0
keyframe:      # optional; default = per-arm "home". NOTE: q is MJCF qpos
  left: {q: [0.325, 0, -0.247, 0, 0.909, 0, 1.15644, 0], gripper: 1.0}
               # order (rail slide FIRST, §3) — internal to scene authoring
allowed_pairs: # optional; structural pairs, twin pair labels (§4.2)
  - [left_rail_platform, table]
```

`gripper: none` + `wrist_cam: true` composes a **camera-only arm**: the gripper
subtree is deleted, `link_tcp` sits on the link7 flange, and the D435 + stand
mesh becomes **collidable** (it is the tool; with a gripper mounted the same
mesh stays visual-only because it overlaps the gripper hull).

`SceneOverrides` (runtime-supplied at session start): subset of arms to
instantiate (`arm_ids`), per-arm base-pose overrides from `WorkcellConfig`
(twin scenes must mirror measured reality), `geom_inflation_m` (twin only,
§8). `WorkcellConfig` arm ids must match descriptor arm ids;
`SceneRegistry.build` raises `SceneArmMismatchError` otherwise. Arm ids must
not be prefixes of each other (`cam` / `cam_2`): pair labels are
`"<arm_id>_<body>"` and the twin attributes a label to an arm by prefix.

### 4.2 Scene-authored structural pairs (`allowed_pairs`)

Some pairs are permanently inside the inflation band **by construction**: a rail
carriage rides 24 mm above the table it is bolted to; two rails mounted 1.5 cm
apart put each carriage ~2 mm from the neighbour's cable-tray plate. Physics
never reports them (static↔static pairs are weld-filtered; the carriage is the
moving exception) but the twin's at-home audit would refuse to arm the gate at
the debug inflation of 0.025 m. The scene author therefore declares them:

- `allowed_pairs: [[label_a, label_b], ...]` with the twin's pair labels — world
  geoms by **geom name** (`table`, `obstacle`, `floor`), arm bodies as
  `"<arm_id>_<body>"` (`grip_rail_platform`, `view_rail_base`).
- Validated at build time against the built model: an unknown label raises
  `SceneCompileError` (labels of arms dropped by an `arm_ids` override are
  skipped). Carried on `SceneMeta.allowed_pairs`.
- `DigitalTwin` merges them as source (a) of 11-safety §6.3, before
  `safety.allowed_pairs_extra` (b) and the built-in rail-platform↔plane rule;
  `default_collision_pairs(scene, twin.allowed)` therefore drops them from the IK
  avoidance rows too. They are a whitelist of *labels*, never a change of geometry.

### 4.3 Scene catalog

| id | arms | purpose |
|---|---|---|
| `single_rail`, `single_fixed_tabletop` | 1 | dev defaults |
| `dual_rail_tabletop`, `dual_mixed`, `triple_rail_row` | 2–3 | composition coverage |
| `guardrail_env`, `guardrail_face`, `guardrail_rail` | 1–2 | safety CI cells (§11) |
| **`mavis_v2`** | 2 | **the lab cell**: digital-twin reference for the real arms and a sim scenario |

**`mavis_v2`** (Apollo lab, tape-measured 2026-09-02; the YAML header carries
the same numbers — edit there). World frame: z-up, origin on the floor under
the table centre; +X along the long edge toward the *right* end, +Y across the
table toward the *back*; the operator / camera-arm side is −Y.

| element | measurement | descriptor value |
|---|---|---|
| table | 1.215 × 0.63 × 0.03 m, top at 0.735 m | box half `[0.6075, 0.315, 0.015]` at z 0.72 |
| rails | parallel to the long edge, feet on the table; zero at the right end, travel toward −X | `base_quat` yaw +90° `[0.7071, 0, 0, 0.7071]`; z = 0.735 + 0.107188 |
| front rail (`view`, camera-only) | outer edge 2 cm from the front edge | y0 = −0.315 + 0.02 + 0.120 = **−0.175** |
| back rail (`grip`, gripper + wrist cam) | outer edge 42 cm from the front edge | y0 = −0.315 + 0.42 − 0.0724 = **0.0326** |
| rail zero | arms 14.5 cm from the right edge at q = 0 | x0 = 0.6075 − 0.145 − 0.098 = **0.3645** (14.5 cm read to the carriage edge; base edge → 0.3995, base centre → 0.4625) |
| obstacle | 0.16 × 0.16 × 0.26 m box, flush with the back edge, +X face 29.2 cm from the right edge | half `[0.08, 0.08, 0.13]` at `(0.2355, 0.235, 0.865)` |
| keyframe | both rails at zero; gripper TCP 11 cm above the box, tool down; camera arm swung 0.5 rad, D435 1.5 m up looking at the back strip | audit-clean at δ = 0.008 and 0.025 |
| `allowed_pairs` | carriages ↔ table (24 mm), carriages ↔ neighbouring rail (~2 mm) | four pairs |

Rail mesh facts used (mavis asset, unverified vs hardware — phase-09 item):
across-axis extent `[−0.120, +0.0724]` m about the base line (the −0.120 side is
a 3 mm cable-tray plate), carriage `[−0.098, +0.088]` m along the travel axis,
1.0926 m long. The 2 cm / 42 cm / 39.5 cm readings disagree by 5 mm and the
14.5 cm reference is ambiguous — both resolve in the phase-09 twin calibration.

## 5. Scene composition via `mujoco.MjSpec`

```python
# scenes/builder.py
@dataclass
class BuiltScene:
    meta: SceneMeta; spec: mujoco.MjSpec; model: mujoco.MjModel
    xml: str                      # spec.to_xml() — persisted per episode
    addressing: Addressing

def build_scene(desc, overrides=None) -> BuiltScene:
    spec = mujoco.MjSpec()
    _apply_options(spec, desc)    # timestep/integrator/cone + offwidth/offheight
    _add_lights_cameras_environment(spec, desc)
    for arm in _selected(desc.arms, overrides):
        child = mujoco.MjSpec.from_file(str(asset_path(f"{arm.model}.xml")))
        frame = spec.worldbody.add_frame(pos=arm.base_pos, quat=arm.base_quat)
        spec.attach(child, prefix=f"{arm.id}_", frame=frame)
    _apply_keyframe(spec, desc.keyframe)       # merged scene keyframe 0
    model = spec.compile()
    return BuiltScene(meta, spec, model, spec.to_xml(), Addressing(model, meta))
```

Verified `MjSpec.attach` facts (3.12.0) the builder relies on:

- `attach(child, prefix=..., frame=...)` copies the child tree **plus**
  actuators/tendons/equalities/excludes/keyframes/defaults, prefixing every
  name (`left_act1`, `left_link_tcp`, `left_home`) — no manual suffixing, no
  duplicated STLs (contrast mavis `<include>`).
- **Asset-copy caveat**: all child assets copy per attach, referenced or not
  (3 arms → `nmesh=48`); harmless. **Option-conflict warnings** (`keeping
  parent value`) are expected — author options on the parent only, filter
  via `warnings.catch_warnings`.
- **Keyframe caveat**: attached keyframes re-index to full-model `nq` at
  `spec.compile()`; fine with 3 sequential attaches on 3.12.0, older MuJoCo
  lost them — §13 pin + `test_composition` guard it. The builder writes ONE
  merged keyframe (index 0, `initial`) from the descriptor, since per-arm
  `<arm>_home` keys zero the other arms.

**Per-episode persistence contract**: runtime stores `BuiltScene.xml` +
`scene_id` + overrides + package version with every episode — replayable by
`MjModel.from_xml_string` + vendored assets (`ASSET_MANIFEST.json`, sha256
per asset, recorded instead of copying STLs).

`Addressing` precomputes per arm id: `qpos_adr` — qpos indices **in core
order** (j1..j7, then the rail slide), so `data.qpos[qpos_adr[arm]] = q`
consumes rail-LAST vectors directly even though MJCF stores the rail slide
first (§3) — plus `dof_adr`, `ctrl_adr` (likewise core-ordered over
`[act1..act7, rail?]`), `gripper_ctrl_adr`, `tcp_site_id`, `wrist_cam_id`,
`geom_ids` (collidable), `env_geom_ids`, `body_of_geom` — resolved once so
hot loops never do name lookups. All rail-first↔rail-last remapping lives
HERE; nothing above this layer ever sees MJCF ordering.

## 6. SimWorkcell — `WorkcellInterface` implementation

The sim workcell **is the robot**: runtime drives it through the same
`ArmInterface` as hardware and cannot tell the difference.

```python
# workcell.py
class SimWorkcell(WorkcellInterface):
    kind: Literal["sim"] = "sim"
    arms: dict[str, SimArm]
    cameras: dict[str, CameraInterface]     # SimCamera per named MJCF camera
    def __init__(self, scene: BuiltScene, config: WorkcellConfig,
                 render_service: RenderService | None = None,
                 ctrl_hz: float = 100.0) -> None: ...
    def start(self) -> None: ...            # reset keyframe 0, spawn step thread
    def stop(self) -> None: ...
    def states(self) -> dict[str, ArmState]: ...  # core ABC (workcell.py, core §5.1)
    def snapshot(self) -> WorkcellSnapshot: ...   # latest state, lock-free read
    def inject_fault(self, arm_id: str, code: int) -> None: ...   # tests only

class SimArm(ArmInterface):
    dof: int                # 7, or 8 with rail (rail slot LAST: q[7], core §4/§5.1)
    has_rail: bool
    gripper_force_capable: bool = False     # sim gripper is position-only
    # connect/disconnect: no-ops (state -> CONNECTED)
    def get_state(self) -> ArmState: ...    # from snapshot; never blocks physics
    def command_joints(self, q: np.ndarray) -> None: ...  # len==dof; rad; q[7]=rail (m)
    def command_gripper(self, cmd: GripperCommand) -> None: ...
    def command_rail(self, pos_m: float) -> None: ...  # clamp [0,0.65]
    def clear_errors(self) -> None: ...     # clears sim fault latch
    def stop(self) -> None: ...             # freeze: targets := current qpos
```

**Stepping thread** (one daemon; pattern verified in mujoco-xarm7-sim §6):

```python
nsub = round(CTRL_DT / model.opt.timestep)       # 5 × 2 ms per 10 ms tick
while running:
    with self._cmd_lock:                         # written by SimArm.command_*
        _write_ctrl(data, targets, grip_ctrl)    # rad/m absolute + 0–255 gripper
    mujoco.mj_step(model, data, nstep=nsub)
    self._publish_snapshot()                     # frozen snapshot -> atomic slot
    if render_service: render_service.submit_state("sim", data.qpos, data.time)
    next_t += CTRL_DT; lag = time.monotonic() - next_t
    if lag > CTRL_DT: next_t = time.monotonic()  # re-sync if >1 tick behind
    else: time.sleep(max(0.0, -lag))             # drift-free monotonic pacing
```

- Measured: `mj_step` 3 arms ≈ 38 µs → 5 substeps ≈ 0.2 ms per 10 ms tick
  (~50× real-time headroom); pacing is sleep-bound.
- `command_joints(q)` only writes the target buffer (position servos via
  `data.ctrl` — the `set_servo_angle_j` streaming pattern); slew/step
  clamping is runtime's job. `q` arrives in core order (rail LAST, `q[7]`);
  the write into `data.ctrl` goes through `Addressing.ctrl_adr` (§5), which
  hides the MJCF rail-first layout. `command_rail(pos_m)` writes the rail
  target slot only.
- Snapshot per arm (read post-step, kinematics valid): `q`, `dq`, `ee_pose`
  (`site_xpos/xmat` of `<arm>_link_tcp` → base frame), `rail_pos_m`,
  `gripper_open_frac`, `error_flags`, `t_mono`, `sim_time`. Readers never
  take the physics lock. `inject_fault` latches `error_flags` until
  `clear_errors()` — exercises runtime's recovery path without hardware.

**Gripper mapping** (`gripper.py`). Menagerie actuator `ctrlrange="0 255"`,
equilibrium driver angle `q_drv = ctrl·0.85/255` rad (0.85 = fully closed);
real gripper 0–850 pulses ↔ 0–0.085 m opening (**850 = open**). Core's
`GripperCommand.open_frac` is the open fraction `f ∈ [0,1]` (1 = open). Helpers:
`open_frac_to_ctrl(f) = (1−f)·255`, `driver_q_to_open_frac(q) = 1 − q/0.85`,
`open_frac_to_meters(f) = f·0.085` (inputs clamped to [0,1]). The direction
(ctrl 0 = open, 255 = closed) is asserted by `test_gripper_mapping` via
fingertip-gap measurement at ctrl ∈ {0, 255} — never trusted from memory.
Hardware maps the same open-fraction to pulses (`f·850`), so both workcells
agree at the `GripperCommand` boundary.

## 7. Sim cameras & the offscreen RenderService

One dedicated render thread owns every `mujoco.Renderer` (GL contexts are
thread-affine). It serves three consumers uniformly: sim wrist/env cameras
(`CameraInterface` → recorded like real cameras), the `sim` scene view, and
the `twin` view — the latter two feed `/ws/video/{sim,twin}` (reserved stream
ids; exist only during a session, per protocol contract).

```python
# rendering.py
@dataclass(frozen=True)
class StreamSpec:
    stream_id: str            # "sim", "twin", or camera id e.g. "left_wrist"
    source: str               # "sim" | "twin" (which model/state to render)
    camera: str | int | None  # named MJCF camera; None = free camera
    width: int = 640; height: int = 480; fps: float = 30.0
    depth: bool = False
    show_inflation: bool = False  # twin debug: geom group 3 on in mjvOption

class RenderService:
    def register_source(self, source: str, model: mujoco.MjModel) -> None: ...
    def add_stream(self, spec: StreamSpec) -> None: ...
    def remove_stream(self, stream_id: str) -> None: ...
    def submit_state(self, source: str, qpos: np.ndarray, t: float) -> None: ...
    def latest(self, stream_id: str) -> CameraFrame | None: ...  # lock-free slot
    def start(self) -> None: ...  # thread creates Renderers lazily inside itself
    def stop(self) -> None: ...   # renderer.close() each — avoids EGL exit spam
```

`SimCamera(CameraInterface)` (cameras.py) is a thin adapter:
`start()` = `add_stream(StreamSpec(camera_id, "sim", mjcf_cam))`;
`latest()` = `svc.latest(camera_id)`.

Render loop: per stream at its own fps (monotonic schedule), copy the
source's latest `qpos` into the render thread's **own `MjData`** (one per
source — never the physics `MjData`), `mj_forward`, `update_scene(...,
scene_option)`, `render(out=stream.buffer)` (zero-alloc), publish to a
depth-1 latest-frame slot (matches runtime's video fanout). Facts:

- `MUJOCO_GL=egl` must be set **before importing mujoco** — the RUNTIME
  entrypoint sets it (04-runtime §13.5); this package's `__init__.py` never
  touches env vars. `MUJOCO_EGL_DEVICE_ID` comes from runtime config
  (`egl_device_id`, default **0** — rendering shares GPU 0 with inference;
  the DAgger trainer owns GPU 1).
- `offwidth/offheight = 1920×1080` in every scene spec (§4); `Renderer`
  raises `Image width > framebuffer width` otherwise for >640×480.
- Measured: 0.61 ms/frame 640×480 (~1600 FPS); 3 cameras 1.81 ms/tick;
  1280×720 1.21 ms. 3 sim cams + 2 views @30 Hz ≈ 3 ms/frame-set — encoding
  (runtime side) is the bottleneck. Depth rendering off in v1.

## 8. DigitalTwin — `DigitalTwinInterface` implementation

Kinematic-only mirror: own `MjModel`/`MjData` built from the
`digital_twin_scene` (hardware mode) or a second instance of the sim scene
(`safety_debug`). Never calls `mj_step`; proximity contacts cannot perturb
the robot.

```python
# twin.py
class DigitalTwin(DigitalTwinInterface):
    def __init__(self, scene: BuiltScene, inflation_m: float = 0.008,
                 render_service: RenderService | None = None) -> None: ...
    def sync(self, states: Mapping[str, ArmState]) -> None: ...
    def check(self, q_by_arm: Mapping[str, np.ndarray]) -> CollisionReport: ...
    def check_config(self, q_full: np.ndarray) -> bool: ...   # planner path (§10)
    def clearance(self, distmax: float = 0.05) -> list[PairClearance]: ...
    def set_grasp_whitelist(self, arm_id: str, bodies: list[str]) -> None: ...
    def plan(self, req: PlanRequest) -> PlanResult: ...  # core §6 shapes; §10
    def render(self, view: str) -> CameraFrame | None: ...  # render_service "twin"
```

**Inflation** (measured 3.12.0 semantics — mujoco-xarm7-sim §4):
`geom_margin = 0`, `geom_gap = inflation_m / 2` on **every collidable geom**
at construction. Contacts are *detected* at `margin+gap` but generate forces
only inside `margin` — with margin 0 they are detection-only
(`efc_address == -1`), zero dynamics effect. Pair thresholds **sum both
geoms' values**: per-geom `δ/2` yields the full `δ` between inflated geoms
(default δ = `safety.geom_inflation_m` = 0.008; `safety_debug` uses 0.025).
Mesh collisions use convex hulls — already conservative for concave links.

**Per tick** (`sync` then `check`, from runtime's 100 Hz gate):

```
sync(states): data.qpos[addr.qpos_adr[arm]] = state.q      (incl. rail slot)
check(q_cmd): data.qpos[...] = q_cmd          # COMMANDED config, not measured
              mj_kinematics(model, data); mj_collision(model, data)
              violations = [CollisionEvent(                 # core §6 shape
                              kind="penetration" if dist <= 0 else "blocked",
                              pairs=[body_pair], dists_m=[dist],
                              min_clearance_m=dist, arm_ids=arm_ids)
                            for c in contacts if pair not in allowed_pairs]
              restore measured qpos            # check is stateless, ~+15 µs
              return CollisionReport(blocked=bool(violations),
                                     severity="blocked" if violations else "ok",
                                     violations=violations, ts=t, ...)
```

**Allowed-pair filter** (precomputed body-id pair set): MJCF `<exclude>`s
(menagerie gripper knuckles) plus **`<arm>_link_base ↔ <arm>_link1` per
arm** — MuJoCo's parent-child auto-filter is disabled when the parent is
welded to the world, producing a permanent dist≈0.0002 m contact (verified
gotcha); authored in `xarm7_on_rail.xml` (§3) AND re-asserted in the Python
filter (`test_twin_excludes`). Also rail_base ↔ rail_platform ↔ link_base,
and fingers/pads ↔ the session grasp whitelist (`set_grasp_whitelist`) so a
held object never trips the gate. An audit test sweeps `home` + 4 random
valid configs asserting zero violations from adjacent-hull artifacts at
δ=0.025.

**`clearance()`** sweeps `mj_geomDistance(model, data, g1, g2, distmax,
fromto)` over the monitored pairs (arm×arm + arm×env), returning core
`PairClearance{geom1, geom2, body_pair, dist_m, fromto}` (core §5.2) sorted
ascending.
Measured ~1 µs/pair; arm0×arm1 sweep (289 pairs) ≈ 0.29 ms — called at
telemetry rate (20–30 Hz), not in the 100 Hz gate. Requires native CCD
(3.12 default; legacy CCD gives wrong positive distances).

**Measured cost** (3 arms + grippers, one core): `mj_kinematics+mj_collision`
with gap inflation = **0.24 ms** (home, 37 inactive contacts) to **0.75 ms**
(adversarial, 72); bare 15 µs. Fits the <2 ms/tick control-path budget
(overview §9) alongside IK.

## 9. MinkIKSolver — `IKSolver` implementation

Primary Cartesian IK for all modes (overview §3.3): QP differential IK
(mink 1.3.0, `qpsolvers`+`daqp`) over the **composite** twin/sim model, one
`mink.Configuration` shared by all arms. Measured: **~116 µs/step mean,
132 µs p99 (7-DoF), ~113 µs (8-DoF rail) → ~8.6 kHz/arm**; one-shot far
target 18–28 QP steps, 2–4 ms.

```python
# ik.py
@dataclass
class IKParams:
    dt: float = 0.01; damping: float = 1e-3; solver: str = "daqp"
    position_cost: float = 1.0
    orientation_cost: float = 0.5            # base; refinement 2 adapts it
    posture_cost_joint: float = 5e-2
    posture_cost_rail: float = 5.0           # rail expensive → prefer joints
    collision_gain: float = 0.85
    max_collision_rows: int = 12             # = safety.max_active_constraint_rows
                                             #   (11-safety §8); refinement 4
    min_distance_m: float = 0.010            # = safety.geom_inflation_m + 0.002 —
                                             #   sits OUTSIDE the gate (11-safety §8)
    detection_distance_m: float = 0.05
    velocity_limits: dict[str, float] = ...  # rad/s per joint; rail 0.2 m/s
    flat_tolerances: np.ndarray = zeros(6)   # (x y z rx ry rz), refinement 3
    w_accel: float = 1e-2; w_jerk: float = 1e-3               # refinement 1
    pos_reject_m: float = 0.02; rot_reject_rad: float = 0.35  # residual monitor

@dataclass(frozen=True)
class IKResult:                              # core §5.2 shape
    q: np.ndarray                            # full arm config, core order (rail LAST, q[7])
    pos_err_m: float; rot_err_rad: float
    diverged: bool                           # residual monitor tripped
    active_collision_rows: int; solve_time_s: float

class MinkIKSolver(IKSolver):
    def __init__(self, scene: BuiltScene, params: IKParams,
                 collision_pairs: list[tuple[list[int], list[int]]] | None): ...
    def sync_passive(self, states: Mapping[str, ArmState]) -> None: ...
    def solve(self, arm_id: str, target: Pose, q_seed: np.ndarray) -> IKResult: ...
    def solve_to_convergence(self, arm_id, target, q_seed,
                             max_steps=50, n_restarts=4) -> IKResult: ...
    def reset(self, arm_id: str, q_measured: np.ndarray) -> None: ...
```

Task/limit stack per `solve` tick:
`FrameTask(frame_name=f"{arm_id}_link_tcp", frame_type="site")` +
`PostureTask` (per-DoF costs; **non-active arms pinned**: posture cost 1e4
toward measured q from `sync_passive`, Δq slice zeroed before integrate —
exact holds while cross-arm collision constraints still see them) +
`ConfigurationLimit` + `VelocityLimit` + `CollisionAvoidanceLimit(geom_pairs,
gain, minimum_distance_from_collisions, collision_detection_distance)` over
self/cross-arm/environment pairs from `Addressing`. Plain sim mode (gate off,
overview §6) **omits** the CollisionAvoidanceLimit; `safety_debug` and
hardware mode include it. mink's signed-distance handling repairs shallow
penetration (negative dist ⇒ only opening velocity) — kept; CollisionIK's
"skip solve when penetrating" freeze is NOT ported.

The four RelaxedIK/CollisionIK-derived refinements (collision-ik §5a):

1. **Accel/jerk regularization** over a 3-deep Δq history: quadratic costs
   `w_accel·‖Δq − Δq₋₁‖²` + `w_jerk·‖Δq − 2Δq₋₁ + Δq₋₂‖²` (posture-like task
   with moving target, linear in Δq) — why RelaxedIK looks smooth on real
   arms; mink alone only damps. History clears on `reset()`.
2. **Adaptive orientation-weight relaxation (ECAA)**: from last twin
   clearance, `s = max(0, (d_warn − d_min)/d_warn)`, `d_warn=0.05 m`; target
   weight `orientation_cost·a/(a+s)`, `a=0.05`; slewed ≤2% of base per tick,
   floor 10%. Position tracking is never relaxed.
3. **Per-DoF flat-bottom tolerances**: shrinkage on the 6-D task error before
   the QP — `e_i ← 0 if |e_i| ≤ tol_i else e_i − tol_i·sign(e_i)` (subclassed
   `FrameTask.compute_error`). Default zeros; collection may free tool roll
   (`tol[5] = π`).
4. **Active-constraint-row cap**: after mink's broadphase, keep the
   `max_collision_rows` pairs with smallest `dist − dmin` — bounds worst-case
   QP latency at 100 Hz with 3 arms + env meshes.

**Residual monitoring** (velocity IK fails *silently* — xarm7-ik §6b): after
integrate, recompute task error; `diverged` when `pos_err > pos_reject_m` or
`rot_err > rot_reject_rad` for 10 consecutive ticks. Runtime then clamps the
integrated teleop target back to `FK(q) ⊕ max_step` (re-anchor) and flashes
the UI banner; the solver only reports.

**Warm start & one-shot**: servo `solve` seeds from its own last output;
`reset(arm_id, q_measured)` re-seeds on session start, takeover toggles,
post-planner handoff, and when `max|q_cmd − q_meas| > 0.05 rad` (external
motion / clamp). `solve_to_convergence` (joint-panel `goto`, planner goals)
iterates to `pos_err < 1 mm ∧ rot_err < 0.01 rad` or `max_steps`; on failure
retries from `n_restarts` seeds (keyframe home + uniform random within
limits), returning the converged solution with smallest weighted posture
distance to `q_seed`; all failing ⇒ `IKUnreachableError(best_result)`.

## 10. ResetPlanner — per-arm sequential RRT-Connect in joint space

Serves overview §3.4 (profile loads / `start_from`), joint-panel `goto`
targets, and safety-escape "back to initial" motions. Pure Python; the twin is
the validity checker (~4k–60k checks/s measured with/without inflation
contacts — thousands of checks per plan is fine). Request/response shapes are
**core's `PlanRequest`/`PlanResult`** (01-core §6) — this module defines no
wire shape of its own.

```python
# planner.py
@dataclass
class PlannerParams:                        # local tuning knobs only; request-level
    rail_weight: float = 4.0                #   knobs (timeout_s, max_step_rad) ride
    max_iters: int = 2000                   #   PlanRequest (core §6)
    shortcut_attempts: int = 50             # 11-safety §9
    vel_limits: dict[str, float]            # time-param caps: 0.6 rad/s joints,
    acc_limits: dict[str, float]            #   2 rad/s²; rail 0.1 m/s (11-safety §9)

class ResetPlanner:
    def __init__(self, twin: DigitalTwin, addr: Addressing,
                 params: PlannerParams = PlannerParams()) -> None: ...
    def plan(self, req: PlanRequest) -> PlanResult: ...
        # PlanRequest{q_start, q_goal, arm_order?, timeout_s=5.0 (per arm),
        #   max_step_rad=0.05 (rail 0.01 m)}; PlanResult{ok, waypoints:
        #   dict[str, list[list[float]]], failure: "goal_in_collision" |
        #   "start_in_collision" | "timeout" | None, failing_pair}
```

Algorithm (**per-arm sequential — the v1 strategy**, 11-safety §9; composite
16–24 DoF planning is a v1 non-goal): (1) order the moving arms by
`req.arm_order`, else the heuristic *deepest-in-warn-band first*; plan arm k
alone (7/8 DoF RRT-Connect, bidirectional connect-extend, weighted L∞ metric
with rail dims × `rail_weight`, uniform sampling within limits, rail
[0, 0.65]) with arms `<k` frozen at their **goals** and arms `>k` at their
**starts** as static obstacles; on failure retry the reverse order —
two-arm swap deadlocks fail loudly (11-safety §14.2). (2) Validity =
`twin.check_config(q_full)` (`mj_kinematics` + `mj_collision` + allowed-pair
filter, §8); edges interpolated at `req.max_step_rad` per joint (rail
0.01 m). (3) **Start-state hysteresis**: pairs already violating at
`q_start` (arm parked inside the inflation shell) are whitelisted until first
exceeding `inflation + 5 mm`, then re-armed — else a clamped arm could never
plan out. (4) **Shortcut smoothing**: `shortcut_attempts` random replacements
kept when the straight edge validates; then time-parameterization with
`vel_limits`/`acc_limits`.

**Waypoint execution contract** (runtime side, binding): waypoints are
sparse; runtime interpolates them into 100 Hz setpoints streamed through the
**same** servo path and **same twin gate** as teleop (overview §6 — planner
trajectories are not exempt). Plans execute arm-by-arm in the planned
sequential order. Goal configs for pose-level requests come from
`solve_to_convergence` (§9). Failed plan ⇒ `PlanResult(ok=False,
failure=..., failing_pair=...)`: runtime refuses the profile load and
reports to the UI — never unplanned motion, never xArm native gohome.

## 11. `safety_debug` guardrail script (`apollo_xarm7_sim/tools/guardrail_check.py`)

The CI regression test for the safety layer — spec is **11-safety §5.1
(binding)**, restated here. A **SimWorkcell plays the real robot** while the
full hardware-mode stack (separate twin instance from the same scene id +
`SafetyGate` at the chokepoint + IK avoidance rows + watchdogs) runs against
it, per `safety_debug`. Headless, **virtual-tick paced** (no sleeps /
wall-clock), fixed seeds ⇒ deterministic; exit 0 = all assertions pass,
nonzero = CI fail.

```python
@dataclass
class GuardrailScenario:
    scenario_id: str; scene_id: str; driven_arm: str
    twist: np.ndarray                      # (6,) constant world-frame twist via the teleop path
    target_pair_prefixes: tuple[str, str]  # e.g. ("arm0/", "table") or ("arm0/", "arm1/")
    max_ticks: int = 2000                  # 20 s virtual @ 100 Hz
    escape_after_block_ticks: int = 50     # then reverse twist
def run_scenario(s: GuardrailScenario, ik_avoidance: bool) -> ScenarioResult: ...
def main(argv: list[str]) -> int: ...      # exit 0 = all assertions pass; nonzero = CI fail
```

Each scenario builds a `safety_debug` session programmatically (no server),
injects a synthetic `TeleopInput` holding the twist, and steps the control
loop tick-by-tick. **Ground truth** = the *physics* model with zero
inflation: any tick with a `mj_collision` contact `dist <= 0` between geoms
matching `target_pair_prefixes` counts as a real-contact failure.

Scenarios: `env_table_descend` (−z into table), `env_pedestal_sweep` (+x
into pedestal) for arm↔environment; `cross_arm_head_on` (+y toward arm1),
`cross_arm_rail_converge` (rail drive toward arm1) for arm↔arm.

**Assertion contract** (11-safety §5.1 — all must hold; failures name the
scenario):

- **A1 Pre-contact trigger**: ≥1 `CollisionEvent(kind="blocked")` emitted AND
  ground-truth contact count for the target pair is 0 over the whole run.
- **A2 Inside the inflation band**: at the first `blocked` event, twin
  clearance of an offending pair matching `target_pair_prefixes` is in
  `(0, geom_inflation_m + min_clearance_m]`, and the event's
  `min_clearance_m` matches a direct `mj_geomDistance` recomputation
  (|Δ| ≤ 1e-6 m).
- **A3 Hold is a hold**: while blocked with twist still applied,
  `max |q_sent(t) − q_sent(t_block)| ≤ 1e-4` (rad; rail slot m) per driven arm.
- **A4 Escape works**: after twist reversal, `kind="cleared"` within 100
  ticks, min pair clearance non-decreasing (tol 1e-4 m), motion resumes.
- **A5 Layer independence**: each scenario runs twice — IK avoidance ON:
  graze variants produce **0 blocked events** (L2 glides); OFF
  (`--no-ik-avoidance`): the gate alone must still satisfy A1–A4.

CI wiring: `uv run python -m apollo_xarm7_sim.tools.guardrail_check --all` in
sim CI + runtime CI (integration job, both extras); < 30 s total (virtual
ticks, 0.75 ms/tick max).

## 12. Threading model & error handling summary

Threads owned by this package (all daemon, joined in `stop()`):

| Thread | Owner | Rate | Shared state & discipline |
|---|---|---|---|
| sim step thread | `SimWorkcell` | 100 Hz (5×2 ms substeps) | exclusive owner of physics `MjData`; inputs via `_cmd_lock`-guarded target buffers; outputs via immutable snapshot slot |
| render thread | `RenderService` | per-stream fps | owns all `Renderer`s + one private `MjData` per source; inputs via latest-qpos slots; outputs via latest-frame slots |

Everything else runs on the **caller's** thread: `DigitalTwin.sync/check/
clearance` and `MinkIKSolver.solve` on runtime's 100 Hz control loop;
`ResetPlanner.plan` on runtime's session executor (plans take up to seconds).
Twin, IK solver, and planner own distinct `MjData` instances; no MuJoCo
object is ever shared across threads. Error handling:

- `SceneRegistry.build`: `SceneNotFoundError`, `SceneArmMismatchError`;
  `mujoco.FatalError` from `spec.compile()` wrapped as `SceneCompileError`.
- `SimWorkcell`: step-thread exceptions latch a workcell fault, stop
  stepping, set every arm's `error_flags`; runtime's watchdog sees frozen
  `t_mono` within 2 ticks. `clear_errors()` does not restart a dead thread —
  `stop()`+`start()` does (mirrors hardware recovery). Pacing overruns
  re-sync `next_t` + bump `overrun_count`; >5% in 10 s warns.
- `MinkIKSolver`: QP failure (rare with daqp) returns previous q with
  `diverged=True`; `IKUnreachableError` only from `solve_to_convergence`;
  never raises on the 100 Hz path. `DigitalTwin.check` likewise never raises
  on the gate path (bad arm ids / q length = `ValueError`, programming error).
- `RenderService`: a renderer exception kills only its stream (slot → `None`,
  logged once); EGL context loss rebuilds the thread's renderers.

## 13. Version pins & the margin/gap semantics CI test

`pyproject.toml` pins **exactly**: `mujoco==3.12.0`, `mink==1.3.0` (+ `daqp`
via mink's qpsolvers extra) — `margin/gap` semantics have changed across
MuJoCo versions and attach keyframe re-indexing only recently became
reliable. Upgrades = deliberate bump PR keeping `test_mujoco_semantics.py`
green:

```python
test_gap_is_detection_only       # spheres r=0.05, surface dist 0.03; gap=0.02
                                 # each (sum 0.04>0.03), margin=0 -> exactly one
                                 # contact, efc_address == -1, zero force
test_pair_threshold_sums_both    # gap on ONE geom: contact at 0.015, not 0.03
test_geom_distance_signed        # == 0.03 ± 1e-9; negative when penetrating;
                                 # returns distmax beyond distmax
test_margin_generates_forces     # margin=0.03, gap=0 -> contact HAS efc rows
test_attach_keyframes_and_names  # 3 attaches: nmesh==48, keyframes at full nq,
                                 # arm0_act1..; to_xml() recompiles identically
```

Any failure = upstream drift; re-audit twin inflation (§8) and the builder
(§5) before unpinning.

## 14. Test strategy (all headless)

No hardware anywhere; the only split is CPU-only vs EGL-capable. Markers:
`@pytest.mark.egl` (CI runner has GPU/EGL; laptops skip), `@pytest.mark.perf`
(timing assertions at 5× measured headroom).

| Area | Tests (CPU unless noted) |
|---|---|
| Assets | STL + LICENSE + UPSTREAM in the wheel; `ASSET_MANIFEST.json` hashes match |
| Composition (§5) | build every scene ×1–3 arms: prefixed names, `nq/nv`, keyframes, rail `range == (0, 0.65)`; `to_xml()` round-trip recompiles equal-sized; addressing slices verified by perturb-and-check FK |
| Gripper (§6) | fingertip gap monotone in ctrl; direction assert (ctrl 0 = open); open-frac round-trip |
| SimWorkcell (§6) | command_joints reaches target (servo settle < 0.5 s); rail clamp [0, 0.65]; snapshot immutability; pacing: 200 ticks within ±2% wall time (perf); fault injection latches & recovers via stop/start |
| Twin (§8) | inflation thresholds: contact appears at δ, not 1.1δ (two-arm approach sweep); link_base↔link1 excluded; grasp whitelist; `check` restores measured qpos; clearance vs analytic sphere distance; audit sweep (no false alarms at δ=0.025) |
| IK (§9) | circle-tracking servo 500 ticks: pos err < 0.5 mm, no limit violations; rail-preference (lateral target moves joints, rail < 1 cm); unreachable target sets `diverged` within 10 ticks; ECAA weight slews & floors; flat-tolerance frees roll; row cap respected (perf: p99 < 1 ms with 3 arms + env) |
| Planner (§10) | two-arm position swap on `dual_rail_tabletop`: sequential plan succeeds within ≤2 orderings, edges valid at `max_step_rad` resolution; impossible variant returns `goal_in_collision` with the correct pair; start-inside-inflation hysteresis escapes; waypoints all pass `check_config` |
| Guardrail (§11) | all four scenarios × {IK avoidance on, off}, full A1–A5 contract (11-safety §5.1) — this IS the safety CI |
| Semantics (§13) | `test_mujoco_semantics.py` suite |
| Rendering (§7) | egl: 640×480 frame non-black & correct shape; stream fps pacing; `show_inflation` toggles group-3 pixels; renderer crash isolates stream |
| Interfaces | `SimWorkcell`/`DigitalTwin`/`MinkIKSolver` satisfy core ABCs (isinstance + signature check via `inspect`) |

Integration smoke (`tests/test_end_to_end_sim.py`, egl): build scene → start
workcell + render service → 100 scripted teleop ticks through MinkIKSolver →
assert EE tracks, frames flow on `sim` + wrist streams, and the
`safety_debug` composition reproduces guardrail scenario `env_table_descend`.
Suite target:
<90 s CPU, <60 s EGL.
