# 03 — apollo-mavis-v2-sim (`apollo_mavis_v2_sim`)

Status: v0.1 (2026-09-01; amended 2026-09-05 — phase-09c: §8 the static
rail-sweep recipe the runtime builds on `check_config_violations` /
`monitored_pairs` to gate the `home_rail` maintenance op, and the `DigitalTwin`
API it relies on; amended 2026-09-09 — phase-15: §4.4 the `mavis_v2_kitchen`
scene, and **§4.5 the overlay-alignment investigation** whose answer is that the
camera model, the extrinsics and the SDK state are all exact and the twin is
missing real furniture, which the gate and the planner also cannot see). Conforms to `00-overview.md` (spine, v0.3). Ground
truth for numbers: `docs/research/{mujoco-xarm7-sim,xarm7-ik,collision-ik}.md`
(benchmarked on this machine, 2026-09-01). Depends only on `apollo_mavis_v2_core`
(+ mujoco, mink, numpy); never imports `hardware`, `runtime`, or FastAPI.

---

## 1. Package layout & dependencies

```
apollo-mavis-v2-sim/
├── pyproject.toml                  # deps: apollo-mavis-v2-core, mujoco==3.12.0,
│                                   #   mink==1.3.0, numpy>=1.24, pyyaml, pydantic>=2
├── src/apollo_mavis_v2_sim/
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

Rules (overview §1): imports from `apollo_mavis_v2_core` only. Public classes
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
`importlib.resources.files("apollo_mavis_v2_sim") / "assets"`.

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
  do not — overview §3.1). The `<arm>_link7` origin coincides with the
  controller's flange TCP (tcp_offset zero) and the `<arm>_link_tcp` site sits
  below it along the tool axis (0.172 m on the gripper arm; on the flange
  itself on a camera-only arm, §4.1) — verified against `get_position()` on
  both real arms on 2026-09-04: the controller's 7 joint radians written
  verbatim reproduce the flange pose to 0.0 mm / 0.00°, i.e. the joint mapping
  is an identity (02-hardware §12).
- **Optional microphone body** (`ArmSpec.microphone`, phase-11; camera-only arms
  only — `wrist_cam: true` + `gripper: none`, enforced by an `ArmSpec`
  after-validator). `_customize_child` adds a **joint-less** body `microphone`
  under `link7` with ONE collidable cylinder (`builder.MIC_*` constants): radius
  **0.040 m** (8 cm diameter — RØDE NT-USB Mini + bracket), axis = link7 +z (the
  flange axis; the link7 origin is the flange face), spanning z ∈ [0, 0.19] — from
  the flange face to **0.14 m past the wrist-cam plane** (`<camera pos="0.07 0 0.05">`
  looks along +z) → `size=[0.040, 0.095]`, `pos=[0, 0, 0.095]`; `contype=conaffinity=1`,
  group 0 (rendered in every stream), dark rgba, explicit **mass 0.45 kg** (estimate,
  to be weighed). The D435 block of `d435_with_cam_stand` starts at x = 0.055, so the
  radial gap is **1.5 cm**; only the 3 mm mount plate (z ≤ 0.003) lies inside the
  footprint — same welded body, MuJoCo never generates that pair
  (`test_mavis_v2.py::test_microphone_clears_the_side_mounted_camera` recomputes the gap
  from the compiled mesh vertices). No joint/actuator/site: `nq`/`nu`/keyframes and
  `Addressing` are unchanged; the twin, IK avoidance rows and guardrail pick the geom
  up through the per-arm subtree scan under pair label `<arm_id>_microphone` (§8). The
  mic sits in front of the lens, so it occludes **~12 % of the view wrist-cam image**
  (a dark rounded silhouette centred on the bottom edge, about half the edge wide and
  reaching ~45 % of the frame height at the centre; measured on the 640×480 render) —
  by design, as on the real mount; not a rendering bug. Default OFF in every
  YAML; the hardware digital twin switches it on per arm via
  `SceneOverrides.microphones` (runtime maps core `ArmConfig.microphone`).

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
    title: str | None = None        # display name; runtime SceneInfo.label = title or description
    hidden: bool = False            # dev/CI scene: filtered from list(), still built by id
    microphones: dict[str, bool]    # per arm_id, AFTER SceneOverrides.microphones (§3)
    graspable: tuple[str, ...] = () # world geoms a session may whitelist against a gripper (§4.1, §4.4)

class SceneRegistry:                # REGISTRY = SceneRegistry() at import,
    def list(self, include_hidden: bool = False) -> list[SceneMeta]: ...  # scans assets/scenes/*.yaml
    def descriptor(self, scene_id: str) -> SceneDescriptor: ...  # SceneNotFoundError if unknown
    def meta(self, scene_id: str) -> SceneMeta: ...       # by id, NOT filtered by hidden
    def build(self, scene_id: str,
              overrides: SceneOverrides | None = None) -> BuiltScene: ...  # §5, unfiltered
```

`list()` hides `hidden: true` scenes by default so the UI/API (`GET /api/scenes`)
see exactly one scene — **`mavis_v2`, titled "APOLLO MAVIS V2 Digital Twin"**; the
eight dev/CI scenes (§4.3) and the hidden GELLO kitchen twin `mavis_v2_kitchen`
(§4.4, selected implicitly by the GELLO card) stay in the package for tests,
benchmarks, the guardrail script and the runtime, which address them by id.

### 4.1 Descriptor schema

Descriptor schema (pydantic `SceneDescriptor`, one YAML file per scene):

```yaml
# assets/scenes/dual_rail_tabletop.yaml
id: dual_rail_tabletop
description: two railed arms facing a 1.2 m table
title: null                                 # optional display name (mavis_v2: APOLLO MAVIS V2 Digital Twin)
hidden: true                                # dev/CI scene: not listed by REGISTRY.list() (§4)
suitable_for: [sim, twin]
options: {timestep: 0.002, integrator: implicitfast, cone: elliptic,
          impratio: 10, multiccd: true}
offscreen: {width: 1920, height: 1080}      # spec.visual.global_.off*
view: {azimuth: -90, elevation: -30}        # optional; spec.visual.global_.azimuth/elevation
arms:                                       # attach prefix "<id>_"
  - {id: left, model: xarm7_on_rail,        # or xarm7_fixed
     base_pos: [0.0, -0.55, 0.0],           # rail-origin in world, m
     base_quat: [1, 0, 0, 0],               # wxyz
     gripper: xarm, wrist_cam: true,        # gripper: xarm | none
     microphone: false}                     # camera-only arms only (§3); default false
  - {id: right, ...}
cameras:       # fixed MJCF cameras: xyaxes = image right, image up; looks along -z = -(x cross y)
  - {name: cam_front, pos: [2.0, 0.0, 1.2], xyaxes: [0, 1, 0, -0.5, 0, 1], fovy: 45}
environment:   # world geoms: plane | box | mesh (§4.1 "Environment geoms")
  - {name: table, type: box, size: [0.6, 0.4, 0.015], pos: [0, 0, 0.72],
     rgba: [0.62, 0.48, 0.32, 1]}                     # collidable (default), MuJoCo group 0
  - {name: tag_1, type: box, size: [0.0005, 0.1024, 0.1024], pos: [-0.36, -1.0262, 1.489],
     quat: [0.7071, 0, 0, 0.7071],                    # local +x = outward normal, +z = tag up
     texture: textures/tagStandard41h12_00001.png,    # asset-relative PNG FILE
     collidable: false}                               # -> contype = conaffinity = 0, group 1
  - {name: fridge, type: mesh, mesh: kitchen/fridge.stl, scale: [1, 1, 1],
     pos: [...], group: 2}                            # file mesh; collider = its convex hull
graspable: [fridge_door_handle, range_handle]  # optional; world geoms a session may
               # whitelist against a gripper (DigitalTwin.set_grasp_whitelist); build-checked
keyframe:      # optional; default = per-arm "home". NOTE: q is MJCF qpos
  left: {q: [0.325, 0, -0.247, 0, 0.909, 0, 1.15644, 0], gripper: 1.0}
               # order (rail slide FIRST, §3) — internal to scene authoring
allowed_pairs: # optional; structural pairs, twin pair labels (§4.2)
  - [left_rail_platform, table]
```

**Environment geoms** (`EnvironmentSpec`; extended 2026-09-09 for the kitchen twin,
16-gello §10). `type: plane | box` take `size` (MuJoCo half-extents); **`type: mesh`
is implemented for FILE meshes** (the pre-phase-15 text called it "phase-03+"): `mesh`
is an asset-relative STL/OBJ under `assets/`, `scale` its per-axis scale, `size` must
be absent, and the **collider is MuJoCo's convex hull of the mesh** (a mesh_copy or
box-decomposed collider is not offered). `texture` (asset-relative PNG) makes the
builder add ONE 2D texture + material per distinct file (`texuniform: false`, material
`tex_<sanitised path>_mat`) and assign it to the geom; the renderer maps the whole
image onto each box face with, for the identity quat, the image's right along local +y
and its top along local +z on the +x face (verified by the kitchen tag-detection test).
Textures are **files only**: `spec.to_xml()` refuses buffer textures and the XML is
persisted with every episode, so the builder sets `spec.texturedir = asset_path()`
beside `meshdir` and the XML carries the relative file name. `collidable: false` sets
`contype = conaffinity = 0` — the geom is never a contact, never a monitored pair,
never inflated by the twin, and goes to **group 1** unless `group` (0–5) says otherwise;
`group` alone overrides MuJoCo's default group 0 for a collidable geom. Mesh / texture
paths must be relative (no `/` prefix, no `..`) and must exist at build
(`SceneCompileError` before MuJoCo's compiler sees them).

**`graspable`** (`SceneDescriptor.graspable`, echoed on `SceneMeta.graspable`): world
geom names a session may whitelist against a gripper — the GELLO session calls
`DigitalTwin.set_grasp_whitelist("grip", meta.graspable)` so the fingers may touch a
handle while every arm link stays gated against every appliance body (16-gello D7).
Validated at build: every name must be a world geom of the built model; the descriptor
rejects duplicates and names that point at a non-collidable geom (a whitelist on a
visual-only plate would be a no-op).

`gripper: none` + `wrist_cam: true` composes a **camera-only arm**: the gripper
subtree is deleted, `link_tcp` sits on the link7 flange, and the D435 + stand
mesh becomes **collidable** (it is the tool; with a gripper mounted the same
mesh stays visual-only because it overlaps the gripper hull). Only such an arm
may set `microphone: true` (§3): `ArmSpec` rejects the flag on a gripper arm or a
camera-less arm (`ValueError` → `SceneCompileError` when it arrives through an
override), because the 0.19 m cylinder would run through the gripper and its
jointed fingers.

`view` (optional) sets MuJoCo's default **free camera** (`<visual><global
azimuth elevation>`), which `RenderService` renders for the runtime `sim` /
`twin` streams (`camera=None` → `-1`, §7); it orbits the model statistic
centre. Azimuth 90 / elevation −45 (MuJoCo's defaults, used when the field is
absent) puts the camera at −Y looking +Y; azimuth −90 puts it at +Y looking −Y.
It is baked into the persisted scene XML like every other `<visual>` setting.

`SceneOverrides` (runtime-supplied at session start): subset of arms to
instantiate (`arm_ids`), per-arm base-pose overrides from `WorkcellConfig`
(twin scenes must mirror measured reality), `geom_inflation_m` (twin only,
§8), and `microphones: dict[str, bool]` (per-arm mic body on/off, same shape as
`base_pose`; overrides `ArmSpec.microphone` so ONE YAML serves the mic-less sim
scene and the hardware digital twin — `{arm.id: arm.microphone for arm in
wc.arms}` from core `ArmConfig.microphone`; an unknown arm id raises
`SceneArmMismatchError`, `SceneMeta.microphones` reports the effective flags).
`WorkcellConfig` arm ids must match descriptor arm ids;
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

| id | arms | listed | purpose |
|---|---|---|---|
| `single_rail`, `single_fixed_tabletop` | 1 | hidden | dev defaults |
| `dual_rail_tabletop`, `dual_mixed`, `triple_rail_row` | 2–3 | hidden | composition coverage |
| `guardrail_env`, `guardrail_face`, `guardrail_rail` | 1–2 | hidden | safety CI cells (§11) |
| **`mavis_v2`** | 2 | **the only visible scene** — title "APOLLO MAVIS V2 Digital Twin" | **the lab cell**: digital-twin reference for the real arms and a sim scenario |
| `mavis_v2_kitchen` | 2 | hidden — title "APOLLO MAVIS V2 Kitchen (GELLO)" | the lab cell + the kitchen (fridge, range, counter, cabinets, wall, four AprilTags): the GELLO Manipulation twin, selected implicitly by the GELLO card (§4.4, 16-gello D6) |

`hidden: true` scenes are kept in the package (built by id by tests, benchmarks and
the guardrail script) but never reach the runtime's `GET /api/scenes` or the UI; the
kitchen twin is hidden for the same reason — the operator decision "`mavis_v2` is the
only exposed scene" stays literally true.

**`mavis_v2`** (Apollo lab, tape-measured 2026-09-02; the YAML header carries
the same numbers — edit there). Arms, user-facing names with the internal ids: the
**Perception Arm** (`view`, wrist RealSense D435 + RØDE NT-USB Mini) on the outer
rail and the **Manipulation Arm** (`grip`, xArm Gripper G2 + wrist camera) on the
inner rail. World frame follows the **operator's own view** (the authority on
left/right): z-up, origin on the floor under the table centre; **+Y = the outer
edge**, where the operator stands (the Perception Arm's rail runs along it, so that
arm is nearest). The operator faces the arms (−Y); their **right is −X** (the
Manipulation Arm starts there, at the rail end flush with the −X edge) and their
**left is +X** (the obstacle, with the Perception Arm starting next to it). Both
rails are mounted the same way. The linear rail is a **chiral** part: getting its
thin cable-tray plate to face the interior (−Y, away from the operator) is a genuine
180° rotation about z (`base_quat` yaw +90°), NOT a mirror — a mirror would change
the mesh handedness. The price of that rotation is **reversed travel**: rail zero
(q=0) sits at the operator's LEFT (+X) and a qpos increase drives the carriage
toward −X — `grip` at **q = 0.65** (full travel) is the operator's RIGHT end, `view`
at **q = 0** the LEFT end. The 180° base flip also makes **joint 1 = π** the arm's
forward-facing zero, which the keyframe uses. The workspace is the channel between
the rails. (An earlier version encoded this cell mirrored in X — rail zero at +X,
obstacle at −X — from an inner-side viewpoint; a fix to yaw −90° put the
arms/obstacle on the operator-correct sides but left the plate facing the operator;
corrected 2026-09-03 by turning each rail 180° to yaw +90°. Until 2026-09-04 both
arms rested together at q ≈ 0.597 in a lowered ready pose; the initial state is now
the opposite-ends factory-zero posture below — user decision.)

| element | measurement | descriptor value |
|---|---|---|
| table | 1.215 × 0.62 × 0.03 m, top at 0.735 m | box half `[0.6075, 0.31, 0.015]` at z 0.72 |
| rails | identical, same orientation; plate faces −Y (interior, away from operator); travel reversed (qpos↑ → −X): q = 0 is the operator's LEFT (+X) end, q = 0.65 the RIGHT (−X) end | `base_quat` yaw +90° `[0.7071, 0, 0, +0.7071]`; z = 0.735 + 0.107188 |
| Perception Arm rail (`view`, camera-only: D435 + microphone) | outer edge 2.6 cm from the table's outer edge | y0 = 0.31 − 0.026 − 0.0724 = **0.2116** |
| Manipulation Arm rail (`grip`, gripper + wrist cam) | 39.5 cm inward by tape (2026-09-02); **39.0 cm by the wrist-camera overlay (2026-09-06)**: the same mesh edge (+Y body edge) aligns to 0 px on the outer rail, whose Y is pinned by the 2.6 cm reading, and is 4 px = 5 mm off on this one | y0 = 0.2116 − 0.3902 = **−0.1786**; plate edge 1.14 cm from the inner table edge |
| channel | between the rail bodies | y ∈ [−0.1062, 0.0916] (19.8 cm with the 19.2 cm mavis mesh) |
| rail placement along travel | **MEASURED 2026-09-05, end feature corrected 2026-09-06** (supersedes the 2026-09-02 derivation). The operator's reference is the rail's **WIDE END FACE** (the 14 cm end plate), not the 3.2 cm boss protruding 2.0 cm past it: wide face **14.5 cm** from the table's +X edge, wide face → base cylinder centre **18.5–19 cm**; boss tip ~12 cm (hard to read with the sleeve fitted) | rail geom offset y = **0.365093** puts the wide face 0.187 m and the boss tip 0.2075 m from the base centre; base centre x0 = **+0.2800**, 32.75 cm from the +X edge (twin: face 14.05 cm, boss 12.0 cm from the edge — the operator's rough boss reading was 12). **Why 0.2800 and not the tape chain's 0.2750**: with the wrist camera pinned to the tape-referenced table dots, BOTH rails' end faces still sat 4–7 mm further +X in the frame than the twin's; the face is 5.95 cm +X of the dots that the tape called 20.0 cm from the edge, so the two table-referenced tape readings (face 14.5, dots 20.0) disagree by 4.5 mm and the image decides. Face → base stays at the measured 18.7, so arms and rails moved together. **09-05 anchored the BOSS at 14.0 cm by mistake** (x0 0.2800, offset 0.385093): the drawn rail sat 20 mm too far −X and the arms 5 mm too far +X, which surfaced as a 22 mm contradiction between the tape-referenced dots and the rail end in the wrist frame during the 09-06 camera solve — the wide-face definition resolves it to 1.3 px. **Before 09-05 x0 = +0.2375** from the reference mesh (carriage centred at mid-travel), a 4 cm error that put BOTH arms too far from the obstacle end; every obstacle-side clearance the twin reported was optimistic by that much. Rail geom offset history: 0.325 (mavis reference mesh, carriage centred at mid-travel) → 0.385093 (2026-09-05, boss anchored) → 0.365093 (2026-09-06, wide face anchored). The mesh is 1.0926 m against the real 1.075 m; with the zero end anchored the drawn rail's −X end stops 0.24 cm short of the table's −X edge (the real track is flush there — the zero end has the obstacle, so it wins). At the keyframe's q = 0.65 the carriage's −X edge is 14.95 cm from the −X edge |
| obstacle | 0.16 × 0.16 × 0.24 m untouchable block, flush against the **+X** edge (operator's left, the empty end) in the channel; near face 27.5 cm in from the outer edge | half `[0.08, 0.08, 0.12]` at `(**0.5275**, −0.045, 0.855)`, y ∈ [−0.125, 0.035]; its inner face is 1.4 cm past the mesh gripper-rail inner edge and the 1.0926 m mesh rail's boss reaches 4.0 cm into its x-span — a static corner overlap (mesh vs real track) that MuJoCo filters, both being welded to the world, so it never reaches the gate or the sweep |
| keyframe = **initial state** (user decision 2026-09-04) | both arms at the xArm7 factory zero posture — joints 2–7 = 0, **joint 1 = π** (the yaw +90 base flip) — with the rails at **opposite ends**: `grip` q = **0.65** (−X, operator's right, link_base x = −0.3700), `view` q = **0** (+X, operator's left, link_base x = +0.2800; its carriage 6.95 cm short of the obstacle's −X face and 9.7 cm outside its y span). The xArm7 zero is a FOLDED pose: forearm hanging beside the upper arm, tool pointing straight down, flange 12.05 cm above the mounting plane and 20.6 cm to the side; joint 1 = π puts that side at −Y (away from the operator) — the gripper hangs at y ≈ −0.39, 8 cm outside the table's inner edge with the finger pads 9.3 cm above the table plane; the D435 hangs into the channel at y ≈ 0.006 looking down at the table 22 cm below. Gripper open | MJCF order (rail FIRST): `view: [0, π, 0, 0, 0, 0, 0, 0]`, `grip: [0.65, π, 0, 0, 0, 0, 0, 0]`, `gripper: 1.0`. Twin audit clean at δ = 0.008 and 0.025, mic off and on, given the link2↔link4 allowed pair below. Smallest monitored clearances (obstacle-side ones ~4 cm tighter than the pre-09-05 twin claimed): grip finger pads ↔ table 8.97 cm (a diagonal to the table's inner edge: the pads hang 8 cm outside it), link_base ↔ table 10.7 cm, view flange (link7) ↔ obstacle 11.55 cm, `view_d435_mount` ↔ grip rail 12.2 cm, view carriage ↔ obstacle 12.4 cm (was 15.4); mic on: **mic tip ↔ table 3.8 cm** (tip z ≈ 0.773 — the tightest clearance of the initial state, 1.3 cm outside the safety_debug band), mic ↔ grip rail 7.2 cm, mic ↔ obstacle 12.75 cm (was 17), mic ↔ own link1 12.4 cm. Nothing monitored within 8.5 cm with the mic off |
| **wrist camera extrinsic** (both arms, shared MJCF) | **MEASURED 2026-09-06**: four hand-drawn dots on the table, world positions tape-referenced (near pair 20.0 cm from the +X edge, near row 25.5 cm from the operator's +Y edge, 195 × 96 mm rectangle), imaged by the Manipulation Arm's wrist camera with the arm braked | `<camera name="wrist_cam" pos="0.06832 -0.02220 0.02945">` in `d435_mount` on link7 — solved for POSITION with the rotation held at the model's value, re-solved after the residual pass moved `base_pos` (the mount absorbs the arm's placement: mount = measured camera − FK). **The reference model's guess `0.07 0 0.05` was ~22 mm sideways and ~20 mm too far from the flange**; that one error was the entire visible overlay offset the operator reported and the twin's 2.7 % table-plane over-scale. What was ruled OUT first: fx/fy (three-height tape solve, 607 ± 4 px vs the configured 608.19, 0.24 σ — i.e. the YUYV 640×480 UVC path really does carry librealsense's colour intrinsics), the camera rotation (the rectangle's near/far-edge convergence 1.0226 measured vs 1.0226 predicted; a free PnP that "wanted" 19.6° of tilt was the co-planar degeneracy, not evidence) and the principal-point sign convention in runtime `streams/twin_overlay.py` (`principal_pixel = [W/2 − cx, H/2 − cy]`, §7) — verified correct. Fit: 3 unknowns / 8 observations, reprojection RMS 1.24 px. **Residual pass (same day)** on features NOT in the fit: both rails' zero-end faces and the inner rail's channel edge were each 4–7 mm off in one direction → `base_pos` X +5 mm (both arms) and grip Y +5 mm (spacing 39.0), after which every measured edge is within ±2 px: table +X edge −1.0, outer rail edge +0.5, inner rail channel edge 0.0, outer rail face −1.0, inner rail face +2.0. Naive single-height readings are ambiguous between focal and distance — the split needs ≥ 2 heights with a long lever arm (h ≥ 0.5 m); because f ∝ h in that solve, the focal-length estimate is never better than the height measurement. Hand-drawn dot spacing must be tape-verified (the "20 cm" dots were 19.5 cm, the "10 cm" dots 9.6 cm). Localise dot centroids against a locally fitted plane background — a constant background under the shadow gradient biased v by 1 px. The mic body is deliberately NOT coupled to this pose (`MIC_REF_PLANE_Z_M`) |
| **per-arm wrist camera overlay offset** (runtime, not MJCF) | **MEASURED 2026-09-06**: with the shared `wrist_cam` pose (solved on the Manipulation Arm) and each camera's own factory intrinsics, the twin overlay aligns the **Manipulation** Arm to 0 px but the **Perception** Arm's twin sits a **uniform +21 px x / +13 px y (~2 cm at the arm)** off the real arm across EVERY link. Edge-alignment of the twin silhouette to the real Sobel edges in a FAR band (top cylinder) and a MID band gave the SAME shift → depth-/pose-independent, so it is a fixed view-camera mount discrepancy (a small mount pitch/yaw or principal-point difference between the two hand-assembled camera brackets), NOT parallax (a camera-position error would vary with depth) and NOT a shared-geometry error (grip is clean) | encoded as `twin_overlay.principal_offset_px: {view_wrist: [21, 13]}` in `configs/mavis_v2.yaml` — an **overlay-only** nudge (`cx += du`, `cy += dv`) applied by `TwinOverlayRenderer` when rendering the overlay. It does **not** touch `CameraConfig.intrinsics` (those are the true factory D435 values that `session/manager.py` bakes into recordings as ground truth). A principal-point offset cancels a uniform pose-independent shift exactly: residual < 1 px after the fix, confirmed live at a fresh posture. Encoding it as a principal point is an approximation of a likely mount-orientation error, but the two are indistinguishable from images and produce identical (pose-independent) overlay shifts, so the overlay is correct at every posture |
| microphone (`view`, optional) | RØDE NT-USB Mini + bracket in front of the wrist camera: 8 cm diameter, tip 14 cm past the camera plane; mass ~0.45 kg (to be weighed) | `microphone: false` in the YAML (pure sim); the hardware twin builds with `SceneOverrides(microphones={"view": True})` → body `view_microphone`, cylinder `size [0.040, 0.095]`, `pos [0, 0, 0.095]` in link7 (§3); 1.5 cm radial gap to the D435 block; occludes ~12 % of `view_wrist_cam` (bottom-centre silhouette) by design |
| `allowed_pairs` | carriages ↔ table (24 mm by construction); per arm **link2 ↔ link4**: at the factory zero the elbow housing sits 1.78 cm from the shoulder housing — inside the safety_debug band (0.025) whenever J4 ≈ 0 (J4 ≥ 0.10 rad opens it past 2.5 cm), so without the whitelist the audit refuses the initial state and the `safety_debug` gate would hold every command from it. The pair can truly meet only near J4's −11° stop with J3 rolled; intra-arm self-collision is the xArm controller's own job | four pairs; the link pairs remove link2↔link4 from the audit and from `check()` (mj_collision's full contact list) — the clearance sweep / IK rows never held intra-arm pairs, and physics still collides. None for the mic (initial-state clearances ≥ 3.8 cm) |
| cameras / `view` | **operator convention**: every overview is framed as the operator sees the cell — the red obstacle (the +X / empty end, operator's left) and the Perception Arm on the LEFT, the Manipulation Arm (−X end) on the RIGHT, the Perception Arm nearest; all three look from the +Y (operator) side toward −Y, so image right = −X | `cam_front` at `(0, 2.0, 1.9)`, `xyaxes [-1,0,0, 0,-0.55,1]` (looks −Y and down); `cam_top` at `(0, 0, 2.6)`, `xyaxes [-1,0,0, 0,-1,0]` (image up = −Y: near +Y edge at the bottom); `view: {azimuth: -90, elevation: -30}` (free camera at +Y looking −Y — the runtime `sim` stream default) |

Reference renders live in `docs/renders/mavis_v2/` (`render_mavis_v2.py`
regenerates them — regenerated 2026-09-04 for the opposite-ends initial state):
`cam_front.png`, `cam_top.png`, the two wrist cams, the 2×2 contact sheet and
`operator_view.png` (free camera, azimuth −90 / elevation −30, lookat the table
centre) all follow the operator convention above (obstacle and the Perception Arm on
the LEFT, the Manipulation Arm on the RIGHT, the Perception Arm nearest; both arms
folded at the zero posture). From the folded pose the two wrist cams look straight
down: `view_wrist_cam.png` shows the table 22 cm below the lens, `grip_wrist_cam.png`
the gripper over the table's inner edge. `render_mavis_v2.py --microphone` writes the
hardware-twin variant as `*_mic.png`; in `view_wrist_cam_mic.png` the dark mic housing
occludes ~12 % of the frame from the bottom edge (an earlier 6.3 cm estimate gave
~7–8 %) — by construction of the twin's mic body. The REAL `view_wrist` image
(measured 2026-09-04, phase-09a) shows **no occlusion at all**, so the modelled
size / position of the microphone body does not match the physical mount: it is
to be re-measured in phase-09 (03-sim §4.3 mic bullet), and the phase-09a
`view_wrist_align` overlay is what makes the difference visible — do not hide it
in the overlay, fix the scene from measurements.

Rail mesh facts used (mavis asset): across-axis extent `[−0.120, +0.0724]` m
about the base line (the −0.120 side is a 3 mm cable-tray plate; main body
14.2 cm), carriage `[−0.080, +0.090]` across / `[−0.098, +0.088]` along,
1.0926 m long. **The carriage is 1.0 cm asymmetric about the base**: under the
yaw +90 flip its **+X (operator's left) edge is base + 0.098** and its
**−X edge base − 0.088**. Two doc lines used 0.098 on both sides and were 1 cm
off (fixed 2026-09-05 with the rail-zero measurement); at q = 0 the mesh
carriage's +X edge stops 8.95 cm short of the mesh zero end, 0.1496 m of rail
beyond it. The mesh carriage is also **~7.5 cm SHORT along the rail**
(noted 2026-09-07): 18.6 cm (local y −0.098…+0.088) against the real ≈ 26 cm,
base-centred (the real length is not yet tape-measured) — which is why it stops
8.95 cm short of the rail's zero end where the real one stops 5–6 cm short.
**Closed 2026-09-05** by the operator's homed-carriage measurement:
the zero-end overhang that sets x0 (see the rail-placement row — it was 6.0 cm
wrong) and the rail length (1.0926 m mesh vs 1.075 m real). Still open, and both
make the twin OPTIMISTIC rather than conservative: the real carriage stops 5–6 cm
short of the rail end where the mesh stops 8.95 cm short, so the monitored
carriage ↔ obstacle gap is ~3.4 cm generous, and the mesh rail width leaves the
obstacle's inner face 1.4 cm past the mesh gripper-rail edge.

### 4.4 `mavis_v2_kitchen` (GELLO)

The digital twin of **GELLO Manipulation** mode (phase-15; contract and measurement
record in `16-gello.md` §3 / §10 — the numbers live THERE and in the YAML header,
edit both together). `id: mavis_v2_kitchen`, `hidden: true`, `suitable_for: [sim,
twin]`, title "APOLLO MAVIS V2 Kitchen (GELLO)". The cell geometry is `mavis_v2`'s:
`arms`, `cam_front` / `cam_top`, `table`, `obstacle`, `allowed_pairs` and the
Manipulation Arm's keyframe are copied **verbatim** from `mavis_v2.yaml`
(`tests/test_mavis_v2_kitchen.py` asserts the blocks are equal, so §4.3 stays the one
authority for the cell). What the kitchen adds:

- **Appliances as dimensioned boxes** on the faces the Perception Arm's wrist D435i
  measured on 2026-09-09 from the GELLO hold posture (one colour frame + the median of
  45 depth frames, deprojected with the colour intrinsics and the overlay's `view_wrist`
  principal-point nudge `[21, 13]`; details in 16-gello §3). The anchor planes: fridge
  side **x = 0.075**, fridge door **y = −1.027**, range front **y = −1.222**, drawer
  fronts **y = −1.279**, counter top z = 0.926 (modelled at the 36-inch standard 0.914);
  the kitchen run is parallel to world X (tags 0 and 4 share x to 1 mm over 88 cm of
  height). Spec dimensions: GE GDE21ESKSS 29¾ × 69⅞ × 34⅝ in; 30-inch GE range 29⅞ ×
  47 × 28 in; counter 36 in high, 24 in deep; upper cabinets 12 in deep at 54–84 in.
  `size` = half-extents, `pos` = centre, computed from these ranges (world metres):

  | geom | x | y | z | note |
  |---|---|---|---|---|
  | `fridge_body` | −0.681 … 0.075 | −1.856 … −1.027 | 0 … 1.775 | case + doors |
  | `fridge_door_handle` | 0.015 … 0.045 | −1.027 … −0.977 | 0.75 … 1.65 | vertical bar, +X edge of the upper door — graspable |
  | `fridge_drawer_handle` | −0.545 … −0.055 | −1.027 … −0.977 | 0.475 … 0.510 | freezer drawer bar — graspable |
  | `range_body` | 0.480 … 1.239 | −1.883 … −1.222 | 0 … 0.914 | |
  | `range_backguard` | 0.480 … 1.239 | −1.883 … −1.783 | 0.914 … 1.194 | |
  | `range_handle` | 0.530 … 1.189 | −1.222 … −1.172 | 0.600 … 0.630 | oven door bar — graspable |
  | `counter` | 0.075 … 0.480 | −1.889 … −1.279 | 0 … 0.914 | drawer cabinet between the two |
  | `upper_cabinet` | 0.075 … 1.289 | −1.883 … −1.578 | 1.372 … 2.134 | |
  | `kitchen_wall` | −1.00 … 1.50 | −1.933 … −1.883 | 0 … 2.40 | |

  **Accuracy ±3 cm per face** (depth at 1.5–2.2 m ±2–3 cm, camera-model convention
  ±2 cm) until the `*_align` overlays on this scene have been compared with the real
  wrist images — a phase-15 acceptance step. Reach: the Manipulation Arm's base line is
  y = −0.179, so the fridge door / handles (y ≈ −1.03 / −0.98) are at the limit of its
  reach and the range is beyond it — the fridge is the obstacle that matters for the
  gate. Not modelled: the cart in front of the fridge, the tripod, the hood, the door as
  a hinged body.
- **Four AprilTag plates** (`tag_0`, `tag_4` on the fridge's +X side panel at
  x = 0.0755, `tag_1` on the fridge door at y = −1.0262, `tag_3` on the range's oven
  door at y = −1.2215; centres from the measurement, 16-gello §3): non-collidable 1 mm
  boxes `size [0.0005, 0.1024, 0.1024]` (a 0.205 m sheet = the 9-bit tagStandard41h12
  tag plus one white bit of margin at 18.6 mm / bit; the detected quad is the inner 5
  bits = 0.0931 m as measured), textured with `assets/textures/tagStandard41h12_*.png`
  (AprilRobotics apriltag-imgs, BSD-2, 704 × 704 = 64 px per bit). Identity quat for
  the +X plates, yaw +90° (`[0.7071, 0, 0, 0.7071]`) for the +Y plates: the tag's right
  along local +y, its top along local +z, upright and unmirrored as seen from outside.
- **`cam_kitchen`** at `(−0.15, 1.0, 2.0)`, `xyaxes [−1, 0, 0, 0, −0.6, 1]`, fovy 60:
  the operator-side overview for the GELLO launch preview (looks −Y and 31° down, image
  right = −X); the fridge front and the Manipulation Arm at its keyframe are in frame.
- **`graspable: [fridge_door_handle, fridge_drawer_handle, range_handle]`** (16-gello
  D7): a GELLO session whitelists them against the Manipulation Arm's gripper; every
  arm link stays gated against every appliance body.
- **Keyframe**: Perception Arm at the **GELLO hold posture** `view: [0.0, 2.646, −1.598,
  0.018, 1.637, 0.25, 2.007, 0.029]` (MJCF order, rail first — rail 0 = the operator's
  left end, camera on the kitchen: from the twin the wrist camera then sits at
  (0.460, 0.394, 1.579) m with its axis (−0.243, −0.907, −0.343)); Manipulation Arm at
  the `mavis_v2` initial state (`[0.65, π, 0, 0, 0, 0, 0, 0]`, gripper open).

**Tests** (`tests/test_mavis_v2_kitchen.py`): the twin audits clean at δ = 0.008 and
0.025 with the microphone off and on (540 / 571 monitored pairs, nothing within 5 cm at
the keyframe); the cell blocks equal `mavis_v2`'s; every box matches the ranges above;
the plates stand ≤ 1 mm proud of their faces, are visual-only (group 1, not in
`Addressing.env_geom_ids`, never a monitored pair, never inflated); the graspable
whitelist removes exactly the gripper-body ↔ handle pairs and nothing else; and the
**tag-detection test** (EGL) renders `view_wrist_cam` at the keyframe with the REAL
colour intrinsics plus the overlay nudge applied to the MjSpec camera (the twin-overlay
recipe) and runs `pupil-apriltags`: ids 0 / 1 / 3 / 4 decode with centres and corners
within 25 px of the real 2026-09-09 detections (`tests/data/kitchen_tags_20260909.json`;
measured 0.3–0.7 px) in the same corner order (upright, unmirrored). Two facts recorded
by that test: the fridge-side plates are seen edge-on (~10 px wide at 640 × 480) and
MuJoCo's isotropic mipmapping blurs them below decodability at native resolution — the
four-tag assertion renders the same pinhole camera **supersampled 2×** and halves the
coordinates, while the native render must still decode the frontal tags 1 and 3; and the
twin's modelled **microphone body occludes tag 4** at the bottom-centre of the image
(the real frame shows no occlusion — the mic geometry is still the unverified item of
§4.3), so the four-tag run is mic-off and the mic-on run asserts 0 / 1 / 3. Renders for
the operator: `kitchen_final_cam_kitchen.png`, `kitchen_final_view_wrist_cam*.png`
(phase-15 report).

### 4.5 Overlay-alignment investigation, 2026-09-09 (the twin is right; the CELL changed)

The operator reported that the `*_align` overlays, accepted at 0 px / < 1 px on 2026-09-06
(§4.3), "no longer line up" and asked whether the cause was the camera intrinsics, the
xArm SDK's state estimate, or the twin's own geometry. Five parallel audits (intrinsics +
projection, extrinsics + kinematics, state plumbing, empirical measurement, regression
history) answered: **none of them. Nothing regressed. The twin no longer models the room.**

What was ruled out, with the number that rules it out:

| suspect | verdict | evidence |
| --- | --- | --- |
| camera intrinsics | REJECTED | both cameras' configured `fx/fy/cx/cy` equal the librealsense factory **Color 640×480** values to **< 0.01 px**; `rs-enumerate-devices -c` re-read live. The "fx ≈ 385 at 640×480" trap is the **DEPTH** imager — colour 640×480 is a centre CROP of the 16:9 chain, so fx stays 608 (55.5° × 43.1°). The live V4L2 nodes confirm `640×480 YUYV`, and `opencv_camera.py` read-back-verifies every field, so a silent profile fallback is unreachable |
| intrinsics → MuJoCo conversion | REJECTED | an independent EGL render of spheres at known `(X, Y, −2 m)` matches the OpenCV projection to **0.55 px mean / 0.67 px max** with the repo's `principal_pixel = [W/2 − cx, H/2 − cy]`, versus 15.3 px with the opposite sign and 7.9 px with zero. Inverting the compiled `cam_intrinsic` returns the config values exactly (float32); effective fovy 43.067° (the MJCF's 57 is the depth FOV and is overwritten) |
| xArm SDK state | REJECTED | the twin's FK, posed from the monitor's `q`, reproduces the **controller's own** `tcp_pose` to **0.0002 mm / 0.0001°** on both arms (grip differs by exactly the 172 mm gripper TCP offset, 0.000 mm perpendicular) — same joint zeros, same signs, no DH mismatch. Bounds any joint order/sign/offset error at **< 2 µrad** |
| joint order / rail slot / `rail_flip` / `base_in_world: {}` | REJECTED | `base_in_world: {}` is filtered out as identity, so the scene's measured base poses win (verified: twin `grip_link_base` = `[−0.356, −0.1786, 0.8422]`). `rail_flip` false is correct for this cell and is applied once, not twice; a wrong flip would move grip's carriage **622 mm** |
| twin extrinsics / cell geometry drift | REJECTED | every number in `mavis_v2.yaml` and `xarm7_on_rail.xml` matches §4.3 to the last digit and is **byte-identical since sim `536c4ba` / runtime `a11cdd2` (2026-09-07 02:29)**; later commits touched only comments. All five working trees clean |
| a code/config regression | REJECTED | the overlay-relevant slice of the rendered lab config equals `a11cdd2:configs/mavis_v2.yaml` exactly; `git diff a11cdd2 HEAD` is **empty** for `streams/twin_overlay.py` and `devices/hardware_monitor.py` |
| camera roll / J1 / J3 / J5 / J7 offset | ≤ **0.7°** | the two edges of a rectangular mat back-project to world directions deviating **−0.650°** and **+0.641°** — anti-symmetric, so best-fit roll is **+0.005°**; a roll error would shift both the same way. The 0.65° residual is the hand-laid mat not being square |
| camera pitch / yaw, J2 / J4 / J6 offset | ≤ **5.5°**, and 5° moves the feature only 89 px of the 502 px needed | perpendicularity residual −1.291° has sensitivity −0.237 °/deg to pitch, −0.020 °/deg to yaw |
| wrist-camera extrinsic translation | ≤ ~3 mm in the direction that matters | ±20 mm moves the target edge ≤ 41 px; and the twin puts `grip_left_finger` only **14 px** below the frame edge while the real frame shows no finger, so it cannot be off by more in that direction |

What is actually wrong: **at the captured posture the twin's wrist cameras look at nothing
the twin contains.** `grip_wrist_cam` sits at world `(−0.465, −0.595, 1.091)` looking down,
**0.286 m outside the twin table's −Y edge** (`table` half-size `[0.6075, 0.31, 0.015]`,
y ∈ [−0.310, +0.310]); the environment pass returns `floor` over **100.00 %** of the frame,
one segmentation level, so Canny finds no edge and `env_outline` draws nothing either.
Result: `grip_wrist_align.mask_fraction = 0.0` **exactly** — the Manipulation Arm's overlay
is a pass-through of the real frame with **zero twin pixels** (verified two ways: the live
telemetry value, and a pixel diff of the published pair whose max is JPEG noise on 3 px of
307 200). `view_wrist_align`'s **only** content is the `view_microphone` capsule, 8.128 % of
the frame, over a real frame that contains no microphone. Both facts were reproduced offline
**bit-exactly** (robot mask 0.00000 / 0.08128 vs telemetry 0.0 / 0.08127604166666667), which
also proves the live process renders the on-disk geometry with the `[21, 13]` nudge applied.

Meanwhile the real frame is full of an object at table height that the twin does not have.
The blue mat's two edges were fitted per-row / per-column on an HSV mask (TLS, rms 0.63 and
1.09 px, n = 15 / 12) and back-projected through the twin's camera rotation: the surface's
world position is **y = −0.597 ± 0.002** (robust to the plane-height assumption: −0.596 at
z 0.735, −0.598 at z 0.0), against the twin table's near edge at **y = −0.310**. The range
is fixed independently by prop scale — at the twin's table plane (0.343–0.376 m) the props
measure banana 11.1 cm, lime 5.9 × 4.2 cm, cucumber 12.6 cm, plate 18.3 cm (textbook plastic
play food); at the twin's **floor** (1.05–1.15 m, what it actually renders) they would be
banana 34 cm, lime 18 cm. So the real surface is at **0.37 ± 0.04 m ⇒ z ≈ 0.72 ± 0.04**,
statistically indistinguishable from the twin's table top 0.735 — and the twin renders bare
floor there. **This is the blue cart with the toy food that §4.4 lists as "not modelled"**,
pushed against the operator side of the cell table since the 09-06 acceptance. Explaining the
gap with a camera parameter instead would need 502 px in v (105 % of the frame height) or
+307 mm of camera translation; the full single-parameter sensitivity sweep (fx 380/460/500/700,
cx/cy ±20/±40, camera ±5/10/20 mm along and across the axis, pitch/yaw/roll ±1…5°, every joint
±1…5°, the J1 + π branch, rail ±10/50 mm) has no candidate above 18 % of the deficit, and the
`+π` branch is excluded outright because it puts the table on the wrong side of its own edge.

Consequences, in order of importance:

1. **The safety gate and the planner share this twin.** They are blind to the cart, to the
   kitchen run of §4.4, and to the props. On 2026-09-09 at 19:05:17 a **twin-planned,
   gate-approved** `return_home` on the Manipulation Arm (8 waypoints, max |dq| 2.86 rad) was
   cancelled 10 s in by **controller error 31 "Collision Caused Abnormal Current"**, twice
   (`var/logs/runtime.log.1`) — after an E-stop at 18:58:34 and a re-home of both rails at
   19:01. Modelling the cart is therefore a **safety** fix, not a cosmetic one.
2. **The overlay currently cannot show a misalignment even if one existed** at postures like
   this: with nothing but floor in the twin's frustum there is no cue to judge. A residual
   measurement needs a posture where the twin predicts geometry in frame — close the gripper
   to `open_frac ≈ 0.2`, or add ~15° on J5/J6, which brings the fingers from 14 px outside to
   well inside; or aim at the rail end faces / table edges as on 09-06.
3. **The `[21, 13]` nudge's "depth-independent" evidence spans only ~0.1–0.3 m.** The two
   bands of the 09-06 test were both near, so a **positional** mount error fitted at
   D₀ ≈ 0.25 m and a **rotational** one are still indistinguishable. They now diverge
   measurably: under the position model the 21 px becomes `21·(1 − D₀/D)` of
   over-correction — **7.9 px at 0.4 m, 15.8 px at 1.0 m, 18.4 px at 2.0 m** (the same ~5 cm
   ambiguity §4.4 records for the kitchen deprojection) — while under the rotation model it
   stays 21 px at every depth and instead leaves `21·x²` ≈ **6 px at the left/right edges**.
   One frame containing a near **and** a far feature settles it. The physically correct
   encoding is a per-arm 6-DOF wrist-camera extrinsic (today it is **one shared constant for
   two hand-assembled brackets**, patched in 2-D on one of them), solved by `calibrateHandEye`
   over 10–15 braked postures at depths spanning ≥ 3×, using the twin's FK as `T_base_flange`
   (proved exact above).
4. **Two mesh defects dominate the picture wherever they are in frame, and neither can move
   the camera** (the arm base pose is `base_pos + (0, q, 0)` and depends on no mesh; the
   camera's `pos` is an absolute link7 offset): the carriage mesh is **42 mm (−X) / 32 mm (+X)
   short per end = 64 px / 49 px at 0.4 m**, and the microphone body is off by **≥ 20–30 mm**
   (displacing it 20–30 mm in world −Y empties it from the frame; 10 and 20 mm in any of ±Y/±Z
   do not). The mic is the ONLY twin body in the Perception Arm's wrist frame today, so an
   operator judging that tile is judging the known-bad mic mesh.
5. `hardware_monitor` reads `get_servo_angle()` **without `is_real`**, i.e. the **commanded**
   register, while the session driver reads the measured 30003 push. Worth ≤ 1e-4 rad ⇒
   **≤ 0.13 px** at rest (measured: `cmd-meas` = 0.0000 rad on 33 399 health lines at rest,
   max 0.0087 rad while moving), so it is not the alignment story — but it means the twin draws
   the *planned* posture after an abort, exactly the error-31 case above.

Raw captures, scripts and figures: `var/alignment-20260909/` (untracked). Nothing in this
investigation changed a tracked number; §4.3 stands as measured.

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

**Overlay rendering recipe (phase-09a, 2026-09-04; consumer = runtime
`streams/twin_overlay.py`, nothing in this package changed).** The runtime's
digital-twin alignment overlays (`grip_wrist_align` / `view_wrist_align`,
04-runtime §13.4) render `mavis_v2` from the real wrist camera's viewpoint and
need a segmentation mask + per-camera intrinsics, which `RenderService` /
`StreamSpec` do not offer (RGB only, shared renderer per source). The runtime
therefore builds its OWN `BuiltScene` via `REGISTRY.build("mavis_v2",
SceneOverrides(microphones=…, base_pose=…))` and edits the `MjSpec` copy before
`compile()`; every primitive below was verified on the lab box (MuJoCo 3.12.0 +
EGL) and is the recipe to reuse for any future segmentation / intrinsics work:

- `spec.visual.quality.offsamples = 0` is **required** for segmentation
  rendering: the default 4× multisampling blends edge pixels into OTHER valid
  geom ids (mask area inflated 212 → 432 px on a test sphere, centroid off by
  37 px). No `OffscreenSpec` knob exists for it (§4.1/§5); set it on the spec.
- Pinhole intrinsics on a spec camera: `cam.resolution = [640, 480]`,
  `cam.sensor_size` (any consistent size, e.g. `[640e-5, 480e-5]`),
  `cam.focal_pixel = [fx, fy]`, `cam.principal_pixel = [W/2 − cx, H/2 − cy]` —
  **MuJoCo's principal-point offset has the opposite sign of OpenCV's**
  (verified to < 0.5 px). Render at exactly the intrinsics' resolution. The
  D435i colour imager at 640×480 is fovy ≈ 43.2° (2·atan(240/fy)); the MJCF
  `wrist_cam` `fovy=57` is the DEPTH field of view and must not be used for
  alignment against the colour stream.
- Robot / environment separation: floor, table and obstacle are
  `Addressing.env_geom_ids` (geoms 0, 1, 2) and share group 0 with the arm,
  rail, gripper, microphone and camera bodies, so `geomgroup` alone cannot
  isolate the robot. Move the env geoms to group 4 after compile
  (`model.geom_group[env] = 4`) and hide them with `MjvOption.geomgroup[4] = 0`
  in the robot passes (group 3 = the inflation pads, already hidden), or map
  the segmentation ids through `geom_bodyid` into the per-arm subtrees.
- Segmentation output: `Renderer.enable_segmentation_rendering()`, `render()`
  → int32 `(H, W, 2)`; `[..., 1] == mjOBJ_GEOM` is the object mask and
  `[..., 0]` the geom id (−1 background). Cost ≈ 1 ms RGB + 4.5 ms segmentation
  per 640×480 camera on the 4090.
- Thread affinity as in §12: the overlay's `MjData` and both `Renderer`s (RGB +
  segmentation) live on the overlay thread and are created/closed there; the
  phase-09 gate's `DigitalTwin` instance is never shared with it.

**Depth rendering (phase-12, 2026-09-08).** `SimCamera(depth=True)` /
`SimWorkcell(depth_cameras=[…])` render depth in the same pass
(`rendering.depth_m_to_u16_mm`, 0.001 m scale, ≥ 65.535 m clipped) into
`CameraFrame.depth`; the digital twin publishes `view_wrist_cam` depth by
default (`dora.publish.depth_cameras`, 14-dora §4.2).

## 8. DigitalTwin — `DigitalTwinInterface` implementation

Kinematic-only mirror: own `MjModel`/`MjData` built from the
`digital_twin_scene` (hardware mode) or a second instance of the sim scene
(`safety_debug`). Never calls `mj_step`; proximity contacts cannot perturb
the robot.

```python
# twin.py
class DigitalTwin(DigitalTwinInterface):
    def __init__(self, scene: BuiltScene, inflation_m: float = 0.008,
                 render_service: RenderService | None = None,
                 allowed_pairs_extra: Iterable[tuple[str, str]] = ()) -> None: ...
    def sync(self, states: Mapping[str, ArmState]) -> None: ...
    def check(self, q_by_arm: Mapping[str, np.ndarray]) -> CollisionReport: ...
    def check_config(self, q_full: np.ndarray) -> bool: ...   # planner path (§10)
    def check_config_violations(self, q_full: np.ndarray, *, data: MjData | None = None
                                ) -> list[tuple[tuple[str, str], float]]: ...  # (pair, dist) detail
    def pair_distance(self, pair: tuple[str, str], q_by_arm=None, distmax: float = 0.5) -> float: ...
    monitored_pairs: list[tuple[int, int]]   # geom-id pairs (arm×arm + arm×env) minus allowed pairs
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
(default δ = `safety.geom_inflation_m` = 0.008; `safety_debug` and the runtime's
`home_rail` sweep twin use 0.025).
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

**Pair labels** are body names for arm geoms (`view_link5`, `grip_rail_platform`,
`view_d435_mount`, `view_microphone`) and geom names for world geoms (`table`,
`obstacle`, `floor`); `_arms_of_pair` attributes a label to the arm whose
JOINTS move it (kinematic ownership, 2026-09-09: a body below one of the arm's
seven joints or its rail joint — links, carriage, arm base, gripper, camera
mount, microphone; the static `<arm_id>_rail_base`, a child of `world` with no
joint, belongs to no arm, like the world geoms). Until that day the rule was
the `<arm_id>_` name prefix, so the Perception Arm's camera mount pinched
against the Manipulation Arm's rail read as a pair of BOTH arms and the gate
demanded that the Manipulation Arm open a distance none of its joints can
change — hold-last-safe for good (runtime `tests/test_return_fuzz_mavis_v2.py`,
seeds 20261013 / 20261014: planned returns held from their first moving tick;
teleop would have frozen the same way). The optional microphone body (§3) therefore appears as
`view_microphone`: in `mavis_v2` with the mic on, `build_monitored_pairs` adds 20
pairs (mic ↔ floor, table, obstacle and the 17 collidable `grip_*` bodies) and the
IK avoidance rows follow through `default_collision_pairs`; mic ↔ `view_d435_mount`
/ `view_link7` are same-weld and never generated, mic ↔ `view_link6` is the
weld-parent pair MuJoCo filters. The keyframe audit is clean at δ = 0.008 and
0.025 with the mic on (nearest self pair mic ↔ `view_link1` 7.5 cm, nearest cross
pair mic ↔ `grip_link6` 16.5 cm).

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

**Static rail-sweep recipe (phase-09c; runtime `devices/rail_sweep.py`,
`docs/prompts/phase-09c-hardware-session.md` D4).** Rail homing
(`set_linear_track_back_origin`) drives the carriage to the track's zero end
from an UNKNOWN position (the register is meaningless while `on_zero == 0`), so
it cannot go through the 100 Hz gate; the runtime gates the operator-triggered
`home_rail` maintenance op with a static sweep on a dedicated `DigitalTwin`
instead — the sim package ships no sweep of its own (the guardrail's
`mavis_v2_rail_sweep` scenario, §11, is a closed-loop IK + gate run from a
teleported pose and is NOT reusable for this). Recipe, all on the API above:
(1) one private twin per checker, `DigitalTwin(REGISTRY.build(scene,
SceneOverrides(microphones, base_pose)), inflation_m=0.025,
allowed_pairs_extra=safety.allowed_pairs_extra)` — the guardrail's debug margin
rather than the gate's 0.008, because a blind sweep from an unknown start
deserves more; built lazily, guarded by a lock (one `MjData`, one thread), never
shared with the gate's or the overlay's twin; (2) `q_full =
np.array(twin.data.qpos)` (keyframe for unsampled arms), every OTHER arm posed
via `addr[arm].qpos_adr` from its last read-only-monitor sample — `q[:7]` and
the rail slot (`rail_pos_m`, or the configured `rail_fallback_m` plus an
`assumptions` entry when unknown; `rail_flip` = `0.65 − q` applied); (3) the
target arm gets its sampled `q[:7]` and its rail slot `qpos_adr[7]` steps
through `linspace(0, 0.65, 131)` (5 mm): at every step
`check_config_violations(q_full)` decides blocked / clear (any `dist < δ`, the
first hit recorded as `first_blocked_m` / `first_blocked_pair` = the tightest
violating pair) and `mj_geomDistance(model, data, g1, g2, 0.10, None)` over
`monitored_pairs` records the tightest pair (`min_clearance_m` / `_at_m` /
`_pair`, labels via `allowed.label_of_geom`); measured qpos is restored
afterwards. Verdict = core `RailSweepVerdict` (01-core §12): `clear` iff no step
violates — the whole interval must be clear because the start position is
unknown. Measured on `mavis_v2` with the mic body (310 monitored pairs, `nq`
22): build 0.8 s, one 131-step sweep **≈ 32 ms**; at the keyframe the tightest
pair over the Manipulation Arm's travel is `table ↔ view_microphone` at 3.77 cm
(rail-independent — the Perception Arm's mic tip above the table). A clear
verdict hands `q_checked` to the hardware monitor, whose poll thread re-samples
and refuses (zero writes) if the arm moved > 0.02 rad since.

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
    lock_rail: bool = False                  # servo path: rail EXCLUDED from the QP —
                                             #   pinned, adopted from q_seed each tick
                                             #   (runtime control.rail_in_ik false sets it);
                                             #   one-shot solves still place the rail
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
    max_iters: int = 10000                  #   PlanRequest (core §6); per seed - the
    #   request deadline bounds planning, restarts happen at this count (2026-09-09)
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
        #   "start_in_collision" | "no_escape" | "timeout" | None, failing_pair,
        #   arm_order: list[str] (2026-09-08: the order actually validated —
        #   the heuristic order, or the reversed retry that succeeded, or the
        #   caller's explicit order; [] on failure)}
```

Algorithm (**per-arm sequential — the v1 strategy**, 11-safety §9; composite
16–24 DoF planning is a v1 non-goal): (1) order the moving arms by
`req.arm_order`, else the heuristic *deepest-in-warn-band first*; plan arm k
alone (7/8 DoF RRT-Connect, bidirectional connect-extend, weighted L∞ metric
with rail dims × `rail_weight`, uniform sampling within limits, rail
[0, 0.65]) with arms `<k` frozen at their **goals** and arms `>k` at their
**starts** as static obstacles; on failure retry the reverse order —
two-arm swap deadlocks fail loudly (11-safety §14.2). (2) Validity =
`mj_kinematics` + `mj_collision` + allowed-pair filter (§8) on the planner's
fine model copy — **the RRT, the direct edge and the shortcut pass use the same
predicate as the final verification of item (5)**: every movable pair
≥ `δ + FINE_MARGIN_M`, pairs already that tight at the path's endpoints ≥ δ
(2026-09-09 fuzz: with the bare "≥ δ" predicate the RRT skimmed an intra-arm
pair at 8-10 mm for a whole segment after a correct escape, the repair pass
ran out of nudges and all three seeds failed alike — `timeout` after 0.7 s of
a 5 s budget); edges interpolated at `req.max_step_rad` per joint (rail
0.01 m). **Held carriage** (same day): a rail slot whose start and goal
coincide within `RAIL_HOLD_TOL_M` (1 mm) is a request for NO carriage motion
and is pinned for the RRT samples, the escape candidates and the repair nudges
alike (the goal snaps to the start's rail; arm k+1 is validated against arm k
where its path ENDS). The runtime's joints phase promises "each carriage held"
(04-runtime §10.5) and the rail-homing pre-positioning plans on a carriage
whose position is unknown; before, the RRT sampled the rail like any dof and
the fuzz measured a 12.6 cm carriage excursion inside a "joints" phase. Joints
are not held this way — the joint-panel `goto` relies on them for routing. **Only pairs the planned arm's joints can move count** (`_moves`,
2026-09-09 review): a pair the arm is not part of (the OTHER arm's intra-arm
pinch, the other arm against the table) or whose two bodies hang under the same
set of this arm's joints (the gripper's own knuckles, gripper base vs finger —
only the finger joints move them) is a constant for this arm — never escaped,
never its `start_in_collision`, never a block for its RRT — exactly as the gate
never holds an arm outside the offending set. An arm whose goal IS its start is
left alone (two identical waypoints; nothing will be commanded) so the other
arm can be planned around it. (3) **Pinched start ⇒ escape phase mirroring
the gate** (2026-09-09; 11-safety §9): this arm's movable pairs closer than
`δ + hysteresis_m` at `q_start` — inside the inflation shell OR the gate's
hysteresis band (`DigitalTwin(hysteresis_m=…)` = `SafetyConfig.hysteresis_m`,
detected on a model copy inflated by it: a blocked gate demands that every pair
in its `_block_pairs`, band pairs included, opens on every tick) — are first
walked out by a greedy local search under exactly the gate's T8 rule, judged
**per executor tick of the session the plan will run at**: the runtime executor
walks a segment in `ceil(ratio)` equal ticks (`ratio` = the segment in caps:
`HW_SLEW_RAD_PER_TICK` 0.006 rad, `HW_RAIL_M_PER_TICK` 0.5 mm, `HW_CART_STEP_M`
4 mm of lever-weighted travel, × `PlanRequest.speed_scale`; duplicated from the
hardware `ServoLimits` and pinned by runtime `tests/test_plan_passes_gate.py`),
and every pinched pair must open by ≥ `ESCAPE_RATE_MARGIN` (1.25) ×
`PLANNER_ESCAPE_EPS_M` (= runtime `gate.ESCAPE_EPS_M`, 1e-5 m, duplicated: sim
may not import the runtime) on every one of those ticks (`_tick_count`), no
other movable pair comes within `δ + 2 mm` (checked at ≤ 0.002 rad AND ≤ 4 mm
of arm-point travel), a re-armed pair never falls back below `δ + 5 mm`.
Candidates per step = the opening gradient of the tightest pair, the joint
ascent, the axes and 24 random directions at half the edge resolution, filtered
at the coarse resolution for the same rate, ranked by the largest smallest
opening, the best one whose tick-level re-walk passes kept. A slower session has
smaller ticks and less opening per tick, so a plan judged at `speed_scale` s is
valid at any speed ≥ s; the core default (0.1, the slowest speed offered) is
the conservative choice, the runtime passes the session's speed (the rail-homing
job its 10 %). Done once every pinched pair is past `δ + REARM_MARGIN_M` (5 mm,
above the gate's hysteresis band), then the normal RRT-Connect with the
margin predicate of item (2). The goal is judged BEFORE the escape (a goal
inside the shell is `goal_in_collision`, the certain diagnosis). A pinched pair
at ≤ 0 mm is `start_in_collision`; a start no step can open at that rate is
**`no_escape`** (`failing_pair` = the tightest pair; `PlannerParams.
escape_max_steps` 400) — on the 40-pinch sweep of the review 39 planned and
replayed with 0 holds at 100 / 50 / 10 %, the one refusal (three pairs against
`view_link1` / `view_link2`) is a start the real gate holds for good at 10 %
when the rate is ignored. Replaces the whitelist that let the 01:14 incident's
plan close `grip_right_finger` / `view_link3` 2.1 → 1.1 mm in its first
segment. When both orderings of a two-arm request fail, the ordering that got
furthest (more arms planned) is reported, the heuristic's on a tie; the
heuristic itself also weighs the violating pairs at the start (intra-arm ones
included), so an arm pinched against itself is planned first. (4) **Shortcut
smoothing**: `shortcut_attempts` random replacements kept when the straight
edge validates. (5) **Verification at the gate's resolution** (same day): the
finished path is re-sampled so that no arm point travels more than
`FINE_STEP_M` = 4 mm between samples (per-joint lever bound `_LEVER_ARM_M` =
the driver's `ServoLimits.lever_arm_m`, rail 1:1 — the executor's Cartesian
cap per tick) on a planner-private model copy inflated by a further
`FINE_MARGIN_M` = 2 mm, so the ticks in between stay ≥ δ (pairs already that
tight at the endpoints only have to stay ≥ δ); a grazing sample is nudged off
its pair along the opening gradient, else the RRT is re-run with the next seed
— **until the request deadline** (2026-09-09 fuzz; an RRT that exhausts
`max_iters` restarts with a new seed too, and after a repair failure the
direct edge and the shortcut pass are skipped so the retries differ), so
`timeout` means the budget was really spent (it used to mean "three seeds",
reported with 4 s of a 5 s budget unused). Two-arm requests without an explicit
order first PROBE both orderings with `ORDER_PROBE_FRACTION` (0.2) of the
per-arm budget — the RRT cannot prove a dead end, and an arm whose goal is
clear but walled in by the other arm's START would otherwise spend its whole
budget before the reverse ordering (which frees it in 0.1 s) is tried; a
deterministic probe failure (`goal_in_collision` / `start_in_collision` /
`no_escape`) is not retried with more budget. `LOCAL_SAMPLE_FRACTION` (0.7) of
the RRT samples come from the box spanned by start and goal widened by 1.5 rad
(rail 0.15 m), the rest from the full range (completeness): four joints have
±2π limits and uniform samples over two turns grew the trees toward postures no
return needs. Found by the first gate replay: a shortcut edge grazed
`grip_left_finger` / `view_link4` at 7.92 mm between two 0.05 rad samples.
For UNPINCHED starts this is the same code path as before but not the same
output: the fine pass reseeds / nudges, so plans differ and planning takes
~4-5× longer (guardrail_env detour 16 → 73 ms, mavis free → initial 85 →
120 ms) — and the OLD plans for both requests were held for good by the real
gate (detour: `arm0_left_finger` / `pedestal` 7.14 mm from tick 84; mavis:
`grip_right_finger` / `view_link3` 7.99 mm from tick 326) while the new ones
replay with 0 holds at 100 % and 10 % (runtime `tests/test_plan_passes_gate.py`).
Then time-parameterization with `vel_limits`/`acc_limits`.

**Fuzz evidence (2026-09-09; runtime `tests/test_return_fuzz_mavis_v2.py`).**
The whole two-phase return / reset flow (04-runtime §10.5) replayed headless on
the mavis_v2 twin from random two-arm starts with the closest cross-arm pair at
1-20 mm (inside the shell, inside the band, just outside) plus normal ones at
20-60 mm, toward the seeded default posture (joints phase) and the folded
keyframe with the carriages at the rail ends (joints + carriage phases), every
tick through the real `SafetyGate` at the hardware caps: **0 gate holds** in
every sweep once the fixes above and the kinematic pair ownership of §8 were in
(the 200-start sweep had found the Perception Arm's camera mount against the
Manipulation Arm's static rail base holding the Manipulation Arm for good — a
gate-attribution bug, not a planner one); the remaining failures are honest
`timeout`s (a 2.7 rad base rotation of the Manipulation Arm past the Perception
Arm from j1 ≈ -336°, or a genuine sequential deadlock — each arm's path blocked
by the other's start, which the one-arm-at-a-time strategy cannot solve) and
`goal_in_collision` (the default posture against the other arm's start in both
orderings). The tables live in the phase-13 notes; `MAVIS_FUZZ_N=200` for the
long sweep. Open: the sequential planner's capacity on interlocked starts, and
the joint-space profile's 2π branch (a profile stored on the far branch of a
±2π joint asks for a full turn — the fuzz writes its keyframe goal on the
branch nearest the start).

**Waypoint execution contract** (runtime side, binding): waypoints are
sparse; runtime interpolates them into 100 Hz setpoints streamed through the
**same** servo path and **same twin gate** as teleop (overview §6 — planner
trajectories are not exempt). Plans execute arm-by-arm in **`PlanResult.arm_order`**
— the order `_plan_ordered` actually validated (arm k with arms `<k` frozen at
their goals and arms `>k` at their starts), which since 2026-09-08 the planner
reports explicitly and the runtime's `SessionManager._execute_arms` honours by
submitting ONE arm per `execute_plan` and waiting for its arrival before the
next (the `waypoints` dict's insertion order equals it, but `arm_order` is the
contract; 04-runtime §10.5). That day a two-arm return executed as one plan
moved both arms simultaneously and the gate blocked at 5.2 mm — the paths are
collision-free in this order and in no other. Goal configs for pose-level requests come from
`solve_to_convergence` (§9). Failed plan ⇒ `PlanResult(ok=False,
failure=..., failing_pair=...)`: runtime refuses the profile load and
reports to the UI — never unplanned motion, never xArm native gohome.

## 11. `safety_debug` guardrail script (`apollo_mavis_v2_sim/tools/guardrail_check.py`)

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
    overrides: SceneOverrides | None = None  # applied to the played robot AND the twin
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
`cross_arm_rail_converge` (rail drive toward arm1) for arm↔arm;
`mavis_v2_rail_sweep` (the lab cell's Manipulation Arm `grip` +x along the
channel into its obstacle, §4.3) as the deployment cell's own regression, and
`mavis_v2_rail_sweep_mic` — the same sweep with
`overrides=SceneOverrides(microphones={"view": True})`, i.e. the hardware digital
twin's geometry (microphone body on the held Perception Arm, §3) in CI. A scenario
may carry its own start posture (`GuardrailScenario.start_q`, per arm, core order
with the rail LAST) that `run_scenario` writes into the played robot before the
servos settle; the two mavis scenarios use `MAVIS_SWEEP_START_Q` — the cell's
pre-2026-09-04 keyframe (both rails at q = 0.5974, `grip` elbow-up in the channel
with the TCP 4.5 cm below the obstacle top, `view` parked ~1.4 m up) — because the
scene keyframe is now the folded initial state with the rails at opposite ends,
from which a +x sweep reaches nothing (the `grip` carriage stops 5 cm short of the
obstacle). Scenarios without `start_q` start at the scene keyframe.

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
- **A5 Layer independence**: each scenario runs three times — gate-only main
  (`--no-ik-avoidance`: L1 alone must satisfy A1–A4), IK-on main, and the
  IK-on graze variant, which must produce **0 blocked events** (L2 glides).

CI wiring: `uv run python -m apollo_mavis_v2_sim.tools.guardrail_check --all` in
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
| Registry (§4) | `list()` returns only `mavis_v2` (title "APOLLO MAVIS V2 Digital Twin", `hidden` false); `list(include_hidden=True)` returns all 9; hidden scenes still resolve by id through `descriptor()/meta()/build()`; `title`/`hidden` default and flow into `SceneMeta` |
| Composition (§5) | build every scene ×1–3 arms: prefixed names, `nq/nv`, keyframes, rail `range == (0, 0.65)`; `to_xml()` round-trip recompiles equal-sized; addressing slices verified by perturb-and-check FK; **microphone** (§3): flag adds body `a0_microphone` welded to link7 with one cylinder `size [0.040, 0.095]` / `pos z 0.095` / contype 1 / mass 0.45, `nq/nu/nkey` and key 0 unchanged, XML round-trip; rejected on a gripper or camera-less arm; `SceneOverrides.microphones` toggles the same `mavis_v2` (meta `{view: True, grip: False}`, unknown arm → `SceneArmMismatchError`, gripper arm → `SceneCompileError`); an `allowed_pairs` label naming a switched-off mic is skipped |
| mavis_v2 (§4.3) | measurement pins (table, rails, obstacle, overview cameras); keyframe = the initial state (joint 1 = π, joints 2–7 = 0, rails 0 / 0.65, folded tools toward −Y, view carriage 11.2 cm short of the obstacle); initial-state clearances (nothing monitored within 9 cm; link2↔link4 = 1.78 cm and whitelisted, gate `check()` clean); YAML `title`/`microphone: false`; mic ↔ camera gap recomputed from the compiled `d435` mesh (block starts at x = 0.055 → 1.5 cm radial gap; tip = cam z + 0.14; look = link7 +z); twin audit clean at δ = 0.008/0.025 with the mic, 20 monitored `view_microphone` pairs, none with `view_d435_mount`, initial-state mic clearances (table 3–4.5 cm, grip rail > 0.07, obstacle > 0.15, own link1 > 0.1, grip_link6 > 0.5) |
| Gripper (§6) | fingertip gap monotone in ctrl; direction assert (ctrl 0 = open); open-frac round-trip |
| SimWorkcell (§6) | command_joints reaches target (servo settle < 0.5 s); rail clamp [0, 0.65]; snapshot immutability; pacing: 200 ticks within ±2% wall time (perf); fault injection latches & recovers via stop/start |
| Twin (§8) | inflation thresholds: contact appears at δ, not 1.1δ (two-arm approach sweep); link_base↔link1 excluded; grasp whitelist; `check` restores measured qpos; clearance vs analytic sphere distance; audit sweep (no false alarms at δ=0.025) |
| IK (§9) | circle-tracking servo 500 ticks: pos err < 0.5 mm, no limit violations; rail-preference (lateral target moves joints, rail < 1 cm); unreachable target sets `diverged` within 10 ticks; ECAA weight slews & floors; flat-tolerance frees roll; row cap respected (perf: p99 < 1 ms with 3 arms + env) |
| Planner (§10) | two-arm position swap on `dual_rail_tabletop`: sequential plan succeeds within ≤2 orderings, edges valid at `max_step_rad` resolution; impossible variant returns `goal_in_collision` with the correct pair; start inside the inflation shell / the gate's band escapes tick by tick at the requested speed (the other arm's pinch and the gripper's own knuckle pairs are constants; goal judged first; the executor's equal ticks); waypoints all pass `check_config` |
| Guardrail (§11) | all six scenarios (incl. `mavis_v2_rail_sweep_mic`) × {gate-only main, IK-on main, IK-on graze}, full A1–A5 contract (11-safety §5.1) — this IS the safety CI; the two mavis scenarios carry `start_q = MAVIS_SWEEP_START_Q` (the pre-2026-09-04 ready pose), the others none |
| Semantics (§13) | `test_mujoco_semantics.py` suite |
| Rendering (§7) | egl: 640×480 frame non-black & correct shape; stream fps pacing; `show_inflation` toggles group-3 pixels; renderer crash isolates stream |
| Interfaces | `SimWorkcell`/`DigitalTwin`/`MinkIKSolver` satisfy core ABCs (isinstance + signature check via `inspect`) |

Integration smoke (`tests/test_end_to_end_sim.py`, egl): build scene → start
workcell + render service → 100 scripted teleop ticks through MinkIKSolver →
assert EE tracks, frames flow on `sim` + wrist streams, and the
`safety_debug` composition reproduces guardrail scenario `env_table_descend`.
Suite target:
<90 s CPU, <60 s EGL.
