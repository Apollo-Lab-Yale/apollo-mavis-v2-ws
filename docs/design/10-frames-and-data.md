# 10 — Frames & Data: Coordinate Frames + Dataset Format

Status: v1.1 (2026-09-01; amended 2026-09-07 — the on-disk layout became
EPISODE-LEVEL: §1 item 5, §7 intro/§7.5, §8.3, §9 rewritten, §11 new; LeRobot
v3 is now a derived export). Conforms to `00-overview.md` v0.3 (binding spine).
Spelling authority for every type/field name: `01-core.md` (`FrameRef`, `Pose`,
`ArmState`, `SessionSpec`, `FrameAnnotations`, `ControlMode`, `EpisodeSummary`,
`TCP_OFFSET_M`, `LEGACY_FLANGE_QUAT_OFFSET`, `RAIL_TRAVEL_M`, ...). Research
ground truth: `docs/research/{lerobot-data, xarm7-ik, dagger-online-training}.md`.

## 1. Scope, authorities, and binding resolutions

This is the **cross-cutting spec** every repo defers to for (a) coordinate-frame
definitions and conversions, and (b) the on-disk dataset format. Units are
**meters and radians**; quaternions are **(w, x, y, z)**, normalized, canonical
`w >= 0` (`core.se3.quat_normalize`). All math below is expressible in
`apollo_mavis_v2_core.se3` primitives — no repo rolls its own quaternion code.

Binding resolutions this document makes (siblings adopt on next edit; the
consistency pass aligns them):

1. **Joint-vector order** at every `ArmInterface` / `IKSolver` / dataset
   boundary: **7 arm joints first, rail LAST at `q[7]`** (8-DoF railed chain).
   MJCF-internal `qpos` order (rail joint is the kinematic ancestor, so it
   comes first inside MuJoCo) is a **sim-private detail**; `sim`/twin adapters
   permute at their boundary and nowhere else. The legacy `xarm7-ik`
   `[rail, j1..j7]` order is remapped by the compatibility layer (§4.3).
2. **Canonical action space** for datasets and DAgger-intended policies:
   **`delta_ee`** — per-tick deltas applied to the current *measured* TCP pose
   (12-dagger §6). `abs_ee` and `joint` are alternative per-session
   conventions using core's exact `PolicySpec.action_space` literals
   (`"delta_ee" | "abs_ee" | "joint"`). Exactly one convention per dataset,
   recorded in `features["action"]["info"]["action_space"]`.
3. **`world` is a first-class recording/action frame** alongside
   `arm_base:<arm_id>` and `camera:<camera_id>`. Everywhere a per-arm action
   frame is stored (`SessionSpec.frames`, `FrameAnnotations.action_frame`,
   `PolicySpec.action_frame`, `CheckpointInfo.action_frame`, dataset info),
   the value is a **full core `FrameRef` string** drawn from
   `{"arm_base:<arm_id>", "world", "camera:<camera_id>"}` — never `ee:<id>`,
   and never the bare legacy shorthand `"base"`.
4. **Custom metadata placement**: LeRobot v3 silently drops unknown top-level
   `info.json` keys (`DatasetInfo.from_dict`), but arbitrary keys inside a
   per-feature `"info"` dict round-trip. Therefore all Apollo metadata lives
   in per-feature `info` dicts (§7) or in sidecar files (§9). Never
   top-level `info.json`.
5. **On-disk layout (2026-09-07, operator decision)**: the recorder writes
   **one directory per episode** (`episodes/<episode_id>/` holding that
   episode's parquet, one mp4 per camera, the audio WAV and its JSON
   sidecar); a **LeRobot v3 dataset is a derived export** built from those
   directories by stream-copy concatenation — never the store the recorder
   writes into. Deleting an episode removes one directory and re-encodes
   nothing. §11 is the authority; §7 stays the schema of every row/feature.

## 2. Frame catalog (formal definitions)

Frame identifiers are core `FrameRef` strings (`types.py`): `"world"`,
`"arm_base:<arm_id>"`, `"camera:<camera_id>"`, `"ee:<arm_id>"`; parsed by
`parse_frame`, built by `frame_ref`. Notation below: `T_A_B: Transform` maps
B-frame coordinates into A; `R(q)` is the rotation matrix of quaternion `q`;
`⊕` is `pose_mul`, `⁻¹` is `pose_inv`, `T_A_B = pose_between(T_W_A, T_W_B)
= T_W_A⁻¹ ⊕ T_W_B`.

### 2.1 `world` (W)

The single workcell-fixed inertial frame, z-up, declared implicitly by
`WorkcellConfig`: every `ArmConfig.base_in_world` and camera calibration is
expressed relative to it. In sim/twin it is the MJCF `worldbody`. It has no
parameters of its own; it is the identity anchor of all conversion chains.

### 2.2 `arm_base:<arm_id>` (B_i) — rail treatment

The frame of the arm's `link_base` (the mounting flange of the xArm7 on its
platform). This is the frame the xArm SDK and `ArmState.ee_pose` report TCP
poses in. Two cases:

- **No rail** (`has_rail == False`): `T_W_Bi = ArmConfig.base_in_world`
  (static).
- **Rail** (`has_rail == True`): `ArmConfig.base_in_world` places the **rail
  origin** `RO_i` (fixed in world). The base translates along the rail axis —
  **+Y of the rail-origin frame** (03-sim §3) — by the measured rail position
  `d_i(t) = ArmState.q[7] = rail_pos_m ∈ [0, RAIL_TRAVEL_M]` (0–0.65 m):

  ```
  T_W_Bi(t) = T_W_ROi ⊕ Trans(0, d_i(t), 0)          # pure translation
  p_W_Bi(t) = p_W_ROi + R(q_W_ROi) · (0, d_i(t), 0)
  q_W_Bi    = q_W_ROi                                 # rotation is CONSTANT
  ```

  `arm_base:<id>` of a railed arm is therefore **time-varying in world**
  (translation only). Consequence: recording a railed arm in `arm_base:<id>`
  keeps rail motion out of the EE pose (it appears only in the rail dims);
  recording in `world` or `camera:<id>` folds rail travel into the EE
  position. Both are valid conventions — declare one per session (§5).

### 2.3 `camera:<camera_id>` (C_k) — calibration extrinsics

The camera's **optical frame in the OpenCV/RealSense convention**: +Z along
the optical axis (into the scene), +X right, +Y down in the image. Extrinsics
come from the calibration file referenced by `CameraConfig.extrinsics_file`,
expressed in `CameraConfig.extrinsics_frame` (a `FrameRef`, parent P):

```
T_W_Ck = T_W_P ⊕ T_P_Ck          # T_P_Ck read from the calibration file
```

- Env cameras: `extrinsics_frame = "world"` → `T_W_Ck` static.
- Wrist cameras: `extrinsics_frame = "ee:<arm_id>"` →
  `T_W_Ck(t) = T_W_Bi(t) ⊕ T_Bi_Ei(t) ⊕ T_Ei_Ck` (time-varying).
- **Sim cameras**: MuJoCo cameras look along **−Z** with +Y up; the sim
  adapter post-multiplies `R_x(π)` (quat `(0,1,0,0)`) onto the MJCF camera
  orientation so `camera:<id>` means the same OpenCV-convention frame in sim,
  twin, and hardware. This happens once, inside `apollo-mavis-v2-sim`.
- **As a recording frame**, `camera:<id>` requires `T_W_Ck` to be constant
  over the session: `extrinsics_frame` must be `"world"` or
  `"arm_base:<id>"` of a rail-less arm. Wrist (`ee:`-parented) and
  railed-base-parented cameras are rejected by session validation (§5.1);
  they remain fully usable as image observations.

### 2.4 `ee:<arm_id>` (E_i) — the TCP

The tool center point = MJCF site `link_tcp`, **`TCP_OFFSET_M` = 0.172 m past
the link7 flange along tool +Z**, orientation identical to the flange
(menagerie asset; the mavis fork's 0.165 m is rejected, 03-sim §3):

```
T_Fi_Ei = Trans(0, 0, 0.172)      # F_i = link7 flange frame; pure translation
T_Bi_Ei(t) = ArmState.ee_pose     # TCP in arm_base, reported by every driver
```

`ee:<id>` is never a recording frame (`SessionSpec` validator rejects it) —
it is the frame teleop twists act in (rotations about the TCP origin) and the
`IKSolver` `FrameTask` target site.

### 2.5 Joint-vector order (binding, restated)

At every `ArmInterface.command_joints/get_state`, `IKSolver.solve`, planner,
and dataset boundary: `q = [j1..j7]` (7-DoF) or `q = [j1..j7, rail_m]`
(8-DoF, rail last, `q[7] == rail_pos_m`). Dataset per-arm blocks order dims
as joints, gripper, then rail (§7.1) — rail always last within its block.

## 3. SE3 conversion math (observations and actions)

Everything recorded for an arm — the EE-pose part of `observation.state` and
the whole EE part of `action` — is expressed in that arm's declared recording
frame `F = SessionSpec.frames[arm_id]` **before** `add_frame` (04-runtime
§10.3). Drivers report in `arm_base:<id>`; conversion happens exactly once,
in the recorder, per frame, using the formulas below.

### 3.1 Poses (observations, `abs_ee` actions)

A pose `X` known in frame A as `(p_A, q_A)` re-expressed in frame B:

```
T_B_X = T_B_A ⊕ T_A_X,   T_B_A = (T_W_B)⁻¹ ⊕ T_W_A = pose_between(T_W_B, T_W_A)

p_B = p_BA + R(q_BA) · p_A
q_B = quat_normalize( quat_mul(q_BA, q_A) )
```

The three pairs actually used (all others compose from these):

- **base → world** (record frame `world`, source `ArmState.ee_pose`):
  `p_W = p_W_Bi(t) + R(q_W_Bi) p_B`, `q_W = q_W_Bi ⊗ q_B`, with
  `T_W_Bi(t)` from §2.2 (rail arms: re-evaluate every frame from `q[7]`).
- **world → base** (policy trained in `world`, executed on arm i):
  `p_B = R(q_W_Bi)ᵀ (p_W − p_W_Bi(t))`, `q_B = q_W_Bi⁻¹ ⊗ q_W`.
- **base → camera** (record frame `camera:<k>`):
  `T_Ck_Bi = (T_W_Ck)⁻¹ ⊕ T_W_Bi(t)`, then
  `p_C = p_Ck_Bi + R(q_Ck_Bi) p_B`, `q_C = q_Ck_Bi ⊗ q_B`. Equivalently via
  world: `p_C = R(q_W_Ck)ᵀ (p_W − p_W_Ck)`, `q_C = q_W_Ck⁻¹ ⊗ q_W`.
- **camera → base** (executing a camera-frame policy):
  `p_B = R(q_Ck_Bi)ᵀ (p_C − p_Ck_Bi)`, `q_B = q_Ck_Bi⁻¹ ⊗ q_C`.

`q⁻¹ = quat_conj(q)` for unit quaternions; every product is re-canonicalized
(`w >= 0`). For railed arms `T_Ck_Bi` and `T_W_Bi` are recomputed per frame;
`q_W_Bi` never changes (rail is a pure translation), only positions do.

### 3.2 Delta actions (`delta_ee`) — composition rule

A `delta_ee` action for one arm is `Δ = [δp(3), δr(3), grip, (rail_δ)]` with
`δr = quat_to_rotvec` of the delta rotation. Semantics (binding, matches
`integrate_twist` / `ActionAnchor.apply_delta`): applied to the current
**measured** TCP pose `(p, q)` expressed in the same frame F, with rotation
about the TCP origin and axes of F (left/space composition):

```
p' = p + δp                              # δp in F axes
q' = quat_mul( rotvec_to_quat(δr), q )   # δr in F axes, rotation about TCP origin
```

### 3.3 Delta actions — frame transform (rotate the delta)

Because deltas are **space-frame increments**, changing the recording frame
rotates them and nothing else. Let `R_BA = R(q_B_A)` be the rotation of
`T_B_A`. Then for a delta expressed in A:

```
δp_B = R_BA · δp_A
δr_B = R_BA · δr_A            # rotvec conjugation: exp(δr_B) = R_BA exp(δr_A) R_BAᵀ
grip_B = grip_A;  rail_δB = rail_δA      # frame-invariant scalars (§3.4)
```

Derivation (why only the rotation appears): with `p_B = p_BA + R_BA p_A`,
`p'_B − p_B = R_BA (p'_A − p_A)`; and
`q'_B = q_BA ⊗ exp(δr_A) ⊗ q_A = (q_BA ⊗ exp(δr_A) ⊗ q_BA⁻¹) ⊗ q_B
= exp(R_BA δr_A) ⊗ q_B`. Translations of the frame cancel — **deltas
transform as free vectors**; this is precisely why left-composition deltas
were chosen as the canonical action space. Instantiations:

- **base ↔ world**: `R = R(q_W_Bi)` (constant even for railed arms — rail
  travel never touches delta conversion) or its transpose.
- **base ↔ camera**: `R = R(q_Ck_Bi) = R(q_W_Ck)ᵀ R(q_W_Bi)` or transpose.

The same rotation rule applies to teleop `Twist{v, w}` vectors (per-second
instead of per-frame) — the control loop uses it when the teleop control
frame differs from the arm's canonical action frame (12-dagger §4:
conversion happens **before both execution and recording**).

### 3.4 Frame-invariant dimensions

- **Gripper**: `gripper.pos` is a normalized open fraction `[0, 1]` — no
  frame.
- **Rail**: the rail dim (`rail.pos` absolute, `rail.dpos` delta) is the
  scalar coordinate along the rail's own +Y axis (§2.2), **not** a world
  vector; it is identical in every recording frame. Converting a recorded
  pose to/from `world`/`camera` uses the rail value via `T_W_Bi(t)`, but the
  stored rail scalar itself never changes. Clamped to `[0, 0.65]` m always.
- **Joint dims** (`action_space == "joint"`, and the joint part of
  `observation.state`): frame-free; `SessionSpec.frames` affects only the
  `ee.*` entries of `observation.state` for such datasets.

### 3.5 Sanity identities (unit-tested in core/runtime)

```
roundtrip:  to_frame(from_frame(x)) == x            (pos < 1e-9 m, rot < 1e-9 rad)
consistency: apply(Δ_A, pose_A) converted to B  ==  apply(Δ_B, pose_B)
rail:        world-frame ee.z of a railed arm is invariant under rail motion
             when the rail axis ⊥ world z (pure y-translation folds into ee.y)
```

## 4. Legacy `xarm7-ik` compatibility mapping

The legacy solver (`M4D-SC1ENTIST/xarm7-ik`, research `xarm7-ik.md`) differs
from this stack in four ways; old datasets/policies are converted, not
reinterpreted:

| aspect | legacy `xarm7-ik` | apollo-mavis-v2 |
|---|---|---|
| target frame | **flange** (DH ends at d7 = 0.097 m) | **TCP** site `link_tcp`, 0.172 m past flange |
| orientation convention | user quat premultiplied by `quat_offset = (0,1,0,0)` (180° about X): user identity = "gripper down" | plain TCP orientation, no implicit offset |
| joint vector | `[rail, j1..j7]` (rail FIRST) | `[j1..j7, rail]` (rail LAST, §2.5) |
| rail bounds | hardcoded `[0, 0.74]` m | `RAIL_TRAVEL_M = 0.65` m |

Constants live in core: `TCP_OFFSET_M = 0.172`,
`LEGACY_FLANGE_QUAT_OFFSET = (0., 1., 0., 0.)`, `RAIL_TRAVEL_M = 0.65`.

### 4.1 Orientation: legacy user quat ↔ flange quat

The legacy solver internally targets `q_flange = q_off ⊗ q_legacy` with
`q_off = LEGACY_FLANGE_QUAT_OFFSET`. `q_off` is an involution as a rotation
(`q_off⁻¹ = quat_conj(q_off) = (0,−1,0,0) ≅ q_off`), so both directions are
the same product up to canonicalization:

```
q_flange = quat_normalize( quat_mul(LEGACY_FLANGE_QUAT_OFFSET, q_legacy) )
q_legacy = quat_normalize( quat_mul(quat_conj(LEGACY_FLANGE_QUAT_OFFSET), q_flange) )
```

The flange and TCP share orientation (`T_F_E` is a pure translation, §2.4),
so `q_tcp = q_flange`.

### 4.2 Position: flange target ↔ TCP target (both directions)

All in the arm-base frame (legacy targets are base-frame; rail variant:
rail-origin frame — see §4.3):

```
legacy -> apollo:   q_tcp    = quat_mul(LEGACY_FLANGE_QUAT_OFFSET, q_legacy)
                    p_tcp    = p_flange + quat_rotate(q_tcp, (0, 0, TCP_OFFSET_M))

apollo -> legacy:   q_legacy = quat_mul(quat_conj(LEGACY_FLANGE_QUAT_OFFSET), q_tcp)
                    p_flange = p_tcp − quat_rotate(q_tcp, (0, 0, TCP_OFFSET_M))
```

Check: gripper pointing straight down is `q_tcp = (0,1,0,0)` in our
convention; the formulas give `q_legacy = (1,0,0,0)` (legacy identity) and a
flange 0.172 m **above** the TCP — matching the legacy README semantics.

### 4.3 Configuration vectors, rail, and base offsets

```
q_apollo = [q_legacy[1], ..., q_legacy[7], q_legacy[0]]    # rail moves to slot 7
q_legacy = [q_apollo[7], q_apollo[0], ..., q_apollo[6]]
rail:      clamp(q, 0.0, RAIL_TRAVEL_M)   # legacy allowed up to 0.74 m; 0.65 is physical
```

- Legacy `linear_motor_x_offset` / `base_rotation_offset` (constant base X
  translation / Z rotation) fold into `ArmConfig.base_in_world` — they are
  workcell placement, not solver state:
  `T_W_ROi = T_legacy_world_placement ⊕ Trans(x_off, 0, 0) ⊕ Rot_z(base_rotation_offset)`.
- Legacy MJCF rail joint range `[-0.37, 0.37]` with the `+0.37` shift is
  replaced by our direct `[0, 0.65]` mapping (03-sim §3); converting legacy
  sim logs: `rail_apollo = rail_mjcf_legacy + 0.37`, then clamp to 0.65.
- Legacy solver frame = rail-origin frame for the rail variant; our
  `arm_base:<id>` rides the platform. Converting a legacy base-frame pose to
  our `arm_base:<id>`: subtract the rail translation,
  `p_base = p_legacy − (0, d_rail, 0)` (orientation unchanged).

### 4.4 Dataset/policy migration entry point

`apollo_mavis_v2_runtime.tools.convert_legacy` applies §4.1–§4.3 row-wise to a
legacy dataset and emits a LeRobot v3 dataset in this doc's schema with
`features["action"]["info"]["converted_from"] = "xarm7-ik-legacy"`. Policies
trained on unconverted legacy data must be wrapped with the inverse mapping
at `Policy.act` output — never silently loaded (checkpoint verification, §5.3).

## 5. Per-arm per-session recording-frame mechanics

### 5.1 Declaration & validation (`SessionSpec.frames`)

The recording frame is chosen **per arm, per session** at setup
(`POST /api/session`, core `SessionSpec`):

```python
SessionSpec.frames: dict[str, FrameRef]
# e.g. {"arm0": "arm_base:arm0", "arm1": "camera:cam_env"}
# or   {"arm0": "world", "arm1": "world"}
```

Validators (core §12 + runtime session bring-up):

- keys ⊆ `SessionSpec.arms`; missing arms default to `arm_base:<that_id>`.
- each value `parse_frame()`s; kind ∈ {`arm_base`, `world`, `camera`};
  `ee:` rejected.
- `arm_base:<x>` must reference the **same arm** (`x == arm_id`) — recording
  arm A in arm B's base frame is disallowed (no use case, high foot-gun).
- `camera:<k>` must reference a declared camera whose `T_W_Ck` is static
  (§2.3): `extrinsics_frame ∈ {"world"} ∪ {"arm_base:<j>" | arm j rail-less}`,
  with calibrated extrinsics present — else 409 / `SessionError` (runtime-local).
- The frame choice **never affects control math** (IK, gate, servo all run in
  `arm_base`/world internally); it only fixes what the recorder writes and
  what a policy consumes/emits.

### 5.2 Storage in dataset metadata

Per-feature `info` dicts are the durable location (§1.4). Both vector
features carry the same `frames` map so either can be read standalone:

```python
features["action"]["info"] = {
    "apollo_schema": 1,
    "action_space": "delta_ee",                # "delta_ee" | "abs_ee" | "joint"
    "frames": {"arm0": "arm_base:arm0", "arm1": "camera:cam_env"},
    "rail":   {"axis": "y", "travel_m": 0.65, "arms": ["arm0", "arm1"]},
}
features["observation.state"]["info"] = {
    "apollo_schema": 1,
    "frames": {...same map...},                # governs the ee.* dims of state
}
```

`FrameAnnotations.action_frame` (per-frame, DAgger) and
`PolicySpec.action_frame` / `CheckpointInfo.action_frame` carry the same
`FrameRef` strings. Frames are **fixed per dataset** — mixing frames inside
one `action` feature is statistically toxic (one normalization spans all
rows; research lerobot-data §5) — hence one repo per frame convention (§8).

### 5.3 Camera extrinsics snapshot & checkpoint-load verification

- **Snapshot per episode**: for every camera referenced by `frames` (and, for
  provenance, every recorded camera), the episode sidecar (§9) stores
  `{camera_id: {T_W_C: PoseModel, intrinsics, extrinsics_frame,
  calibration_file, calibration_sha256}}`, captured at `episode_new`. Sim
  episodes snapshot the MJCF camera pose after the OpenCV-convention fix-up.
- **At checkpoint load** (DAgger/inference session start and every hot-swap
  stage): the runtime compares `CheckpointInfo.action_frame` +
  `action_space` against the session's dataset convention — mismatch ⇒
  refuse (`SessionError("policy/dataset frame mismatch")`, 12-dagger §6).
  For `camera:<k>` frames it additionally compares the checkpoint's training
  extrinsics snapshot against the current calibration:

  ```
  (pos_err_m, rot_err_rad) = pose_error(T_W_C_train, T_W_C_now)
  pos_err <= 0.003 m and rot_err <= 0.010 rad   -> load
  pos_err <= 0.010 m and rot_err <= 0.035 rad   -> load + telemetry warning
  otherwise                                     -> refuse (recalibrate or retrain)
  ```

  Thresholds are `RecorderConfig` fields (`extrinsics_warn`/`extrinsics_max`)
  with the defaults above. Checkpoints trained on merged data with multiple
  snapshots verify against each; the widest error governs.

## 6. Action spaces

One `action_space` per dataset, spelled with core's `PolicySpec` literals.
Per-arm block layouts (rail dim present only for railed arms; multi-arm
vectors concatenate blocks in `WorkcellConfig` arm order):

| `action_space` | per-arm dims (rail / no rail) | block layout |
|---|---|---|
| `delta_ee` (**canonical**) | 8 / 7 | `[ee.dx, ee.dy, ee.dz, ee.drx, ee.dry, ee.drz, gripper.pos, rail.dpos]` |
| `abs_ee` | 10 / 9 | `[ee.x, ee.y, ee.z, ee.qw, ee.qx, ee.qy, ee.qz, gripper.pos, rail.pos]` |
| `joint` | 9 / 8 | `[joint1.pos … joint7.pos, gripper.pos, rail.pos]` |

Semantics:

- **`delta_ee`**: per-tick deltas applied to the current **measured** TCP
  pose in the arm's recording frame (§3.2) — the hil-serl mechanism that
  makes human↔policy switches jump-free (12-dagger §6, binding for
  DAgger-intended policies). `ee.dr*` is a rotation vector (`quat_to_rotvec`)
  in frame axes; `rail.dpos` is a rail-axis delta, target clamped to
  `[0, 0.65]` m; `gripper.pos` is the **absolute** open-fraction target
  (gripper deltas would drift; upstream convention keeps it absolute).
  Recorded deltas are per-**dataset-frame** increments (at `fps`), not
  per-servo-tick; the 100 Hz loop interpolates.
- **`abs_ee`**: absolute TCP pose in the recording frame, wxyz quaternion
  (canonical `w >= 0` enforced at write). Used by chunked policies
  (ACT/diffusion); handback rules in 12-dagger §6.2.
- **`joint`**: absolute joint targets, frame-free (§3.4). The `frames` map
  still governs the `ee.*` dims of `observation.state`.

`action` always stores the **executed** action — post-twin-gate, post-clamp
(`FrameAnnotations.executed_action`): the label is what the robot did, not
what was asked (12-dagger §4).

### 6.1 `observation.state` layout (all action spaces)

Per-arm block, same prefix/order rules (dims: 16 rail / 15 no rail):

```
[joint1.pos … joint7.pos, gripper.pos, rail.pos,
 ee.x, ee.y, ee.z, ee.qw, ee.qx, ee.qy, ee.qz]
```

Joints/gripper/rail are frame-free measurements; the `ee.*` entries are the
measured TCP pose in the arm's declared recording frame (§3.1). Policies
that want a leaner state select dims by name (`state_names` in `PolicySpec`).

## 7. LeRobot v3 dataset schema

The **feature schema** below is binding for every row the recorder writes:
the per-episode `frames.parquet` inside an episode directory (§11) carries
exactly these feature columns plus `timestamp` and `frame_index`, and the
derived LeRobot v3 export (§11.8) adds the remaining lerobot bookkeeping
columns (`episode_index`, `index`, `task_index`) when it assembles the
dataset. Until 2026-09-07 the recorder called `LeRobotDataset.create /
add_frame / save_episode / clear_episode_buffer / finalize` directly (phase-07);
it now encodes video with lerobot's `StreamingVideoEncoder` (the same class,
options and per-episode temp file lerobot's own writer uses, 04-runtime §10)
and writes parquet with pyarrow. The five lerobot bookkeeping features
(`timestamp`, `frame_index`, `episode_index`, `index`, `task_index`) are never
part of the recorder's frame dicts. Feature names must not contain `/`; dots
are the namespace separator.

### 7.1 Naming rules

- Per-dim names are `<arm_id>_` prefixed (upstream bimanual `left_`/`right_`
  precedent, generalized to config arm ids): `arm0_joint3.pos`,
  `arm1_ee.dx`, `arm2_rail.pos`, ...
- Per-arm block ordering inside `action`/`observation.state`: §6 layouts;
  blocks concatenated in `WorkcellConfig.arms` order.
- Cameras: one `observation.images.<camera_id>` feature per recorded camera
  (`cam_env`, `arm0_wrist`, ...), dtype `video`, shape `(H, W, 3)`,
  names `["height", "width", "channels"]`.

### 7.2 Schema tables (delta_ee, all arms railed, ids `arm0..arm2`)

**1-arm workcell** — `action` (8,), `observation.state` (16,):

| feature | dtype | shape | names |
|---|---|---|---|
| `action` | float32 | (8,) | `arm0_ee.dx, arm0_ee.dy, arm0_ee.dz, arm0_ee.drx, arm0_ee.dry, arm0_ee.drz, arm0_gripper.pos, arm0_rail.dpos` |
| `observation.state` | float32 | (16,) | `arm0_joint1.pos … arm0_joint7.pos, arm0_gripper.pos, arm0_rail.pos, arm0_ee.x, arm0_ee.y, arm0_ee.z, arm0_ee.qw, arm0_ee.qx, arm0_ee.qy, arm0_ee.qz` |
| `observation.images.cam_env` | video | (480, 640, 3) | `height, width, channels` |
| `observation.images.arm0_wrist` | video | (480, 640, 3) | `height, width, channels` |
| + always-present features (§7.3) | | | |

**2-arm workcell** — `action` (16,) = arm0 block ++ arm1 block;
`observation.state` (32,); cameras `cam_env`, `arm0_wrist`, `arm1_wrist`.
**3-arm workcell** — `action` (24,), `observation.state` (48,); up to 4
cameras (3 wrist + 1 env). A rail-less arm drops its `rail.dpos`/`rail.pos`
dims from its block (e.g. 2-arm with one rail: action (15,)) — dims are
always derived from `names`, never assumed from arm count.

Dims by convention (per arm, rail / no rail): `delta_ee` 8/7, `abs_ee` 10/9,
`joint` 9/8; state always 16/15.

### 7.3 Always-present features (every mode that records)

Present in **every** dataset so plain-collect and DAgger datasets stay
merge-compatible (overview §4.2; upstream `intervention` name/shape verbatim):

```python
features["intervention"]  = {"dtype": "bool",  "shape": (1,), "names": None}
features["action_source"] = {"dtype": "int8",  "shape": (1,), "names": None,
    "info": {"labels": {"0": "policy", "1": "teleop", "2": "joint_jog",
                        "3": "takeover", "4": "planner", "5": "gello"}}}
features["wallclock_ns"]  = {"dtype": "int64", "shape": (1,), "names": None}
```

- `action_source` labels mirror core's `CommandSource` string values
  (spelling authority; `"5": "gello"` was reserved on 2026-09-09 when phase-15 appended
  `CommandSource.GELLO` — GELLO Manipulation records nothing in v1, so no dataset carries
  it yet; 16-gello §12.2; supersedes the earlier
  `{0: policy, 1: human_teleop, 2: reset_planner}` draft — 0/1 semantics
  unchanged). Per mode: collect ⇒ `1` (teleop); DAgger ⇒ `0` while the policy
  drives, `3` during human takeover. `2` (joint_jog) and `4` (planner) are
  reserved and never appear in recorded frames: the runtime nacks
  `joint_target` while an episode is recording (04-runtime §7), and planner
  motions are never recorded inside an episode. Both values exist for
  telemetry/log contexts that reuse this enum.
- `intervention = (control_mode != POLICY)` in DAgger; constant `False` in
  plain collect (no policy to intervene on).
- `wallclock_ns`: `ArmState.wallclock_ns` of the snapshot — lerobot's
  `timestamp` is synthesized as `frame_index / fps`, so real capture time
  must be stored explicitly.

### 7.4 DAgger extras (12-dagger §4, verbatim)

```python
features["control_mode"]  = {"dtype": "int8", "shape": (1,), "names": None,
    "info": {"labels": {"0": "policy", "1": "human", "2": "takeover_transition"}}}
    # ControlMode.to_int8(); labels == core ControlMode values
features["policy_action"] = {"dtype": "float32", "shape": (D,),
    "names": features["action"]["names"],       # identical layout to `action`
    "info": {"counterfactual": True}}           # NaN row when no fresh query
features["policy_version"] = {"dtype": "int32", "shape": (1,), "names": None,
    "info": {"run_id": "<dagger run_id>"}}
# --- phase-14 (2026-09-08; 15-online-dagger §4 / D4, 12-dagger §4), DAgger repos only ---
features["actor"] = {"dtype": "int8", "shape": (1,), "names": None,
    "info": {"labels": {"0": "novice", "1": "expert"},
             "derived_from": "control_mode != 0"}}   # actor = 1 iff control_mode != policy
```

**`actor` (additive, 2026-09-08).** The operator's readable per-step key
"novice inference vs. expert demonstration" (operator decision, 15-online-dagger
§0 item 3; the morning's citation 15-pro-dagger §0 item 5 superseded 2026-09-08
evening, rule unchanged): `1` on every frame the human drove — HUMAN and TRANSITION
alike, i.e. the same predicate as `intervention` but under the name the Online DAgger
trainer contract and its dataset reader use (`expert_mask`, `actor_counts`). The actor
of a frame is decided by the runtime's takeover gate, never by the trainer's algorithm.
Training labels are unchanged (`control_mode == 1`, 12-dagger §5). Present in
DAgger repos only (`dagger_features()`), so a plain collect dataset has no such
column; the trainer spool (`SPOOL_COLUMNS`, appended last) and the LeRobot v3
export (via `manifest.features`) carry it automatically. **`apollo_schema`
(§8.2) is NOT bumped**: the column is additive, only present in DAgger repos,
and readers select columns by name — a merge of a DAgger repo with a
plain-teleop repo still fails only on the DAgger extras that already differed
(§8.3), exactly as before.

### 7.5 fps & video encoding

- `fps = 30` for the schema tables above (cameras run 640×480@30); the
  recorder paces at `RecorderConfig.fps` within the 20–30 band (04-runtime
  default 25 — the dataset's `fps` is whatever the session recorded at, one
  int for all features). The 100 Hz servo loop is never recorded; it
  interpolates between dataset frames (`interpolation_multiplier` pattern).
- Video: lerobot's `StreamingVideoEncoder` per episode (one encoder thread per
  camera, `rgb_encoder.vcodec="auto"` → `h264_nvenc` on the 4090s, `pix_fmt=
  "yuv420p"`, `g=2` (keyframe every 2 frames), `pts = k`, `time_base = 1/fps`,
  so every episode file starts at t = 0 and holds exactly `length` frames).
  Since 2026-09-07 that standalone per-episode mp4 IS the stored artefact
  (`episodes/<episode_id>/video/<camera_id>.mp4`, §11.4); lerobot's own v3
  writer produces the identical temp file and remuxes it into a size-capped
  shard, which is exactly what the export job does later (§11.8). Per-feature
  `info["video.*"]` (codec, pix_fmt, g, crf, extra_options, backend) is
  recorded in the manifest and per episode (§11.5) and written into the
  export's `info.json`. Saving an episode is near-instant (a rename).
  - NVENC needs `bf=0` alongside lerobot's `g=2`: its default 3 B-frames
    violate "GOP length > bf + 1" and `avcodec_open2` fails with EINVAL
    (regardless of driver or frame size). The recorder injects it via
    `RGBEncoderConfig.extra_options` for `h264_nvenc`/`hevc_nvenc`.
  - `"auto"` is resolved by a REAL open-probe that mirrors lerobot's exact
    codec options + `pix_fmt` at the **smallest** recorded stream size
    (hardware encoders enforce a minimum frame size), in lerobot's
    `HW_VIDEO_CODECS` order, falling back to `libsvtav1`. Listing an encoder
    is not enough; a bare open without options is not enough either.
  - A **resumed** dataset keeps its codec family (`manifest.json`
    `video.codec` = h264/hevc/av1, §11.5): `"auto"` re-probes only within
    that family (hardware first, then the software encoder), and an explicit
    `vcodec` of another family is rejected at session start — lerobot's
    concat (§11.8) refuses mixed-codec videos. Files produced by DIFFERENT
    encoders of one family (h264_nvenc, then libx264 after a GPU-less
    resume) pass lerobot's compatibility check but are not proven to remux
    cleanly, so the exporter never concatenates them into one file: a change
    of encoder identity starts a new export video file (§11.8).
  - GeForce NVENC allows 8 concurrent sessions per host and lerobot opens one
    per recorded video stream per episode; the 4-slot camera budget stays
    under that. Exhaustion surfaces as encoder-thread errors +
    `frames_dropped`, not at probe time.
  - Size/CPU: lerobot maps crf 30 to NVENC constqp `qp=30`; on noisy sensor
    content that is ~3× the bytes of `libsvtav1` at equal PSNR (smaller on
    clean scenes). NVENC buys CPU offload (~13× less CPU per frame), not
    wall speed.
- `robot_type` distinguishes real vs sim: `xarm7_{n}arm_rail` vs
  `xarm7_{n}arm_rail_mujoco`.

## 8. Dataset naming, versioning, and merge rules

### 8.1 Repo naming

One dataset repo per **(task × arm-count × frame convention)** (spine §4.2):

```
apollo/xarm7_{task}_{n}arm_{conv}[_dagger_{run_id}][_{YYYYmmdd_HHMMSS}]

conv = {action_space-token}-{frame-token}
  action_space-token: dee | aee | jnt          (delta_ee | abs_ee | joint)
  frame-token: per-arm tokens in arm order, "+"-joined:
      base            for arm_base:<own id>
      world           for world
      cam.<camera_id> for camera:<camera_id>
```

Examples: `apollo/xarm7_stack_2arm_dee-base+cam.cam_env`,
`apollo/xarm7_wipe_1arm_dee-world_dagger_a1b2c3`. The repo name is a
human-readable mirror only — the **authoritative** convention is
`features["action"]["info"]` (§5.2); tooling must read that, never parse
names. Per-session stamped repos are merged into the canonical unstamped
repo offline.

### 8.2 Versioning

- `features["action"]["info"]["apollo_schema"] = 1` — bumped on any change
  to layouts/labels in §6–§7; readers refuse unknown majors.
- lerobot `codebase_version` (`v3.0`) is managed by the library; pin the
  lerobot version (format has breaking majors).
- DAgger runs append to a dedicated `_dagger_{run_id}` repo; the seed/BC
  dataset is never mutated (12-dagger §4).

### 8.3 Merge rules (`lerobot.datasets.dataset_tools.merge_datasets`)

Merging is allowed iff **all** of:

1. identical feature sets — same keys, dtypes, shapes, and per-dim `names`
   (upstream hard requirement);
2. identical `apollo_schema`, `action_space`, and `frames` maps in both
   `action` and `observation.state` info dicts (same task, arm-count, frame
   convention — the §8.1 key);
3. identical `fps` and camera keys/resolutions;
4. `action_source`/`control_mode` label maps identical.

Explicitly allowed to differ: `robot_type` (sim + real co-training merges
are legal; per-episode ground truth lives in the sidecar §9 — NOTE lerobot's
own `aggregate_datasets` / `merge_datasets` REFUSE differing `robot_type`
(`aggregate.py validate_all_metadata`); a multi-store export that writes one
common `robot_type` is a follow-up to §11.8 — until then merge two exports with
lerobot's `merge_datasets` after rewriting one export's `robot_type` in its
`info.json`; the per-episode truth stays in the carried sidecars),
`policy_version`/`run_id` (DAgger repos from different runs merge for
round-based retraining, 12-dagger §9 — label masks recompute from
`control_mode`). After any merge/surgery: `recompute_stats` (normalization
stats drive policy preprocessing). Datasets that differ in any item 1–4 stay
separate repos, period — there is no cross-frame or cross-space merge; use
the §4.4 converter to re-express a dataset first if needed.

## 9. Episode & session metadata (sidecars)

LeRobot has no extension point for per-episode metadata, and unknown
top-level `info.json` keys are dropped (§1.4) — so Apollo metadata lives in
JSON files of its own. Since 2026-09-07 (§11) they live **next to the data
they describe** in the episode store, and the LeRobot v3 export carries them
under `meta/apollo/` exactly as phase-07 laid them out, so a consumer of the
export sees the old tree:

```
episode store (primary, §11.2)                 LeRobot v3 export (§11.8)
<root>/sessions/session_{session_id}.json  →  <export>/meta/apollo/session_{session_id}.json
<root>/scenes/{sha256[:16]}.xml            →  <export>/meta/apollo/scenes/{sha256[:16]}.xml
<root>/episodes/{episode_id}/episode.json  →  <export>/meta/apollo/episodes/episode_{index:06d}.json
                                              (episode_index rewritten to the export's dense index,
                                               episode_id kept; deleted episodes simply are not there)
```

**`sessions/session_*.json`** (written at session start, finalized at
teardown):

```jsonc
{
  "session_id": "...", "mode": "collect|dagger",
  "spec": { /* SessionSpec.model_dump() — arms, frames, task, start_from, dataset, ... */ },
  "workcell": { "kind": "hardware|sim", "config_sha256": "...",
                "arm_ids": ["grip", "view"], "rail": {"grip": true, "view": true},
                "cameras": { "grip_wrist": {"resolution": [640, 480], "kind": "v4l2",
                                            "twin_camera": "grip_wrist_cam"}, ... } },
  "software": { "apollo_core": "0.1.0", "apollo_runtime": "0.1.0",
                "lerobot": "0.6.1", "mujoco": "3.12.0", "mink": "1.3.0",
                "xarm_sdk": "1.18.5", "git_sha": "..." },
  "safety": { /* SafetyConfig.model_dump() — inflation, clearances, deadman */ }
}
```

**`episodes/{episode_id}/episode.json`** (written LAST inside the episode's
temp directory, immediately before the atomic rename that publishes the
episode — §11.6; discarded episodes leave nothing). It is the phase-07
sidecar plus the fields the export needs so that it never has to decode a
video or scan a parquet:

```jsonc
{
  "episode_id": "20260907T141203.512Z-3f9a1c",   // §11.3; the directory name
  "episode_index": null,                          // dense index exists only in an export
  "session_id": "...",
  "recorded_at": "2026-09-07T14:12:03.512Z",      // wallclock of the first frame
  "length": 1875, "fps": 25, "duration_s": 75.0,
  "tasks": ["pick the red cube"],                 // per-frame `task` values, deduped
  "scene_xml_sha256": "...",                      // -> scenes/, spec.to_xml()
  "start_from": "profile:<id> | keep_current",
  "initial_condition_profile_id": "...",          // the designated IC at record time
  "return_profile_id": "... | null",              // 04-runtime §10.5 (return_to_start)
  "profile_snapshot": { /* StateProfile.model_dump() if a profile was loaded */ },
  "frames": {"grip": "arm_base:grip", "view": "camera:cam_env"},
  "extrinsics": { "grip_wrist": { "T_W_C": {"position": [...],
        "orientation_wxyz": [...]}, "extrinsics_frame": "world | null",
        "twin_camera": "grip_wrist_cam", "intrinsics": {...},
        "calibration_file": null, "calibration_sha256": null } },  // §5.3, every camera
  "arm_bases": { "grip": {"rail_origin_in_world": {...}, "has_rail": true}, ... },
  "video": {                                       // one entry per camera (§11.4)
    "grip_wrist": { "file": "video/grip_wrist.mp4", "frames": 1875,
                    "codec": "h264", "encoder": "h264_nvenc", "pix_fmt": "yuv420p",
                    "g": 2, "crf": 30, "extra_options": {"bf": "0"},
                    "width": 640, "height": 480, "encoder_drops": 0 } },
  "audio": { "path": "audio.wav", "format": "wav", "sample_format": "pcm_s16le",
             "channels": 1, "sample_rate": 48000, "samples": 3600000,
             "duration_s": 75.0, "t0_mono": ..., "t0_wallclock_ns": ...,
             "audio_start_mono": ..., "audio_start_wallclock_ns": ...,
             "overruns_delta": 0 } ,                // null when no microphone (§11.4)
  "stats": { /* per-feature lerobot stats: min/max/mean/std/count/q01/q10/q50/q90/q99;
               image features as (3,1,1) arrays in [0,1] (/255 applied, `count` = the
               downsampled pixel vectors, exactly as lerobot's writer stores them) —
               the export aggregates these (§11.8) */ },
  "gate_events": [ /* DAgger: GateEvent list {arm_id, mode, t_mono, seq, source} */ ],
  "episode_summary": { /* EpisodeSummary fields incl. n_label_frames, segment_doubts;
                          2026-09-08: + episode_id, n_expert_frames, n_novice_frames (the
                          actor split; core §9, additive) */ },
  "online_dagger": {                               // Online DAgger rollouts ONLY (2026-09-08
    "session_name": "s1", "rollouts_saved": 2,     //   evening; 15-online-dagger §4 / §12): written
    "policy_version": 1,                           //   when an OnlineDaggerCoordinator is attached;
    "actor_counts": {"novice": 812, "expert": 143}  //   rollouts_saved INCLUDES this rollout; the same
  },                                               //   numbers ride events.episode_saved.online_dagger.
                                                   //   Absent otherwise. Superseded (2026-09-08
                                                   //   evening): the morning's "pro_dagger" block
                                                   //   {iteration, rollout_index, offline_dataset}
  "frames_dropped": 3,                             // recorder-side (camera age > 2/fps)
  "filter": { "enabled": true,                     // idle-frame filter (§11.4; 04-runtime §10.5)
              "params": { "pos_eps_m": 0.001, "rot_eps_rad": 0.001, "gripper_eps_frac": 0.01,
                          "rail_eps_m": 0.001, "gripper_context_s": 1.6 },
              "frames_seen": 2150, "frames_skipped": 275,
              "gaps": [[412, 60], [1301, 215]] },  // [kept frame_index, frames skipped right before it]
  "export_ok": true, "export_note": null,          // false + reason ⇒ excluded from exports
  "success": null
}
```

Sidecar writes are atomic (`.tmp` + `os.replace`, same discipline as
`ProfileStore`). The export writes `episode_index` into its copy and keeps
`episode_id`; the `manifest.json` at the dataset root (§11.5) is derivable
from these files and is rebuilt by a rescan whenever it disagrees with the
directory tree.

## 10. Worked numeric example (2-arm, mixed frames)

Collect session, `fps = 25`, `action_space = "delta_ee"`, both arms railed,
`frames = {"arm0": "arm_base:arm0", "arm1": "camera:cam_env"}`.

**Workcell setup** (numbers chosen so every rotation is exact):

```
arm0 rail origin: T_W_RO0 = { p (0, 0, 0),        q (1, 0, 0, 0) }         # identity
arm1 rail origin: T_W_RO1 = { p (1.20, 0, 0),     q (0, 0, 0, 1) }         # 180° about Z
cam_env:          T_W_C   = { p (0.60, −1.00, 0.80), q (0.7071, −0.7071, 0, 0) }
                  # R_x(−90°): optical +Z looks along world +Y; R(q_W_C) =
                  # [[1,0,0],[0,0,1],[0,−1,0]]; extrinsics_frame = "world"
```

**Measured state at this frame** (`ArmState`, all in each arm's base frame):

```
arm0: q[7] = rail = 0.30   -> T_W_B0 = { p (0, 0.30, 0), q (1,0,0,0) }
      ee_pose: p_B0 (0.50, 0.00, 0.35), q_B0 (0, 1, 0, 0)     # gripper straight down
      joints (0.00, −0.52, 0.00, 0.96, 0.00, 1.48, 0.00), gripper 0.80
arm1: q[7] = rail = 0.10   -> p_W_B1 = (1.20, 0, 0) + R_z(π)·(0, 0.10, 0)
                            = (1.20, −0.10, 0);  q_W_B1 = (0, 0, 0, 1)
      ee_pose: p_B1 (0.40, 0.10, 0.30), q_B1 (0, 1, 0, 0)
      joints (0.35, −0.40, 0.00, 1.10, 0.00, 1.30, −0.35), gripper 0.25
```

**arm0 observation (frame `arm_base:arm0`)** — recorded verbatim from
`ArmState.ee_pose`: `ee = (0.50, 0.00, 0.35, 0, 1, 0, 0)`. No conversion.

**arm1 observation (frame `camera:cam_env`)** — §3.1, base → world → camera:

```
p_W = p_W_B1 + R_z(π)·p_B1 = (1.20, −0.10, 0) + (−0.40, −0.10, 0.30) = (0.80, −0.20, 0.30)
q_W = q_W_B1 ⊗ q_B1 = (0,0,0,1) ⊗ (0,1,0,0) = (0, 0, 1, 0)            # 180° about Y
p_C = R(q_W_C)ᵀ (p_W − p_W_C) = [[1,0,0],[0,0,−1],[0,1,0]] · (0.20, 0.80, −0.50)
    = (0.20, 0.50, 0.80)      # 0.20 right of axis, 0.50 below, 0.80 in front  ✓
q_C = q_W_C⁻¹ ⊗ q_W = (0.7071, 0.7071, 0, 0) ⊗ (0, 0, 1, 0) = (0, 0, 0.7071, 0.7071)
```

**Actions.** The operator drives both arms with base-frame twists this tick:
`δp_B = (0.002, 0, 0) m` (0.05 m/s at 25 fps); arm1 additionally yaws
`δr_B1 = (0, 0, 0.010) rad`; arm0 nudges its rail `+0.001 m`.

- arm0 (recording frame == its base): recorded verbatim →
  `[0.002, 0, 0, 0, 0, 0, 0.80, 0.001]`.
- arm1 (recording frame `camera:cam_env`): §3.3 — rotate the delta by
  `R_C_B1 = R(q_W_C)ᵀ · R(q_W_B1) = [[−1,0,0],[0,0,−1],[0,−1,0]]`
  (as a quaternion: `q_C_B1 = q_W_C⁻¹ ⊗ q_W_B1 = (0, 0, −0.7071, 0.7071)`):

  ```
  δp_C = R_C_B1 · (0.002, 0, 0)  = (−0.002, 0, 0)
  δr_C = R_C_B1 · (0, 0, 0.010)  = (0, −0.010, 0)
  ```

  gripper/rail scalars pass through → `[−0.002, 0, 0, 0, −0.010, 0, 0.25, 0.0]`.

**The full `add_frame` record** (bookkeeping features auto-added by lerobot):

```python
{
 "action": [ 0.002, 0.0, 0.0,  0.0, 0.0, 0.0,    0.80, 0.001,      # arm0 block
            -0.002, 0.0, 0.0,  0.0, -0.010, 0.0, 0.25, 0.0  ],     # arm1 block
 "observation.state": [
    0.00, -0.52, 0.00, 0.96, 0.00, 1.48, 0.00,  0.80, 0.30,        # arm0 j1..7,grip,rail
    0.50, 0.00, 0.35,  0.0, 1.0, 0.0, 0.0,                         # arm0 ee (arm_base:arm0)
    0.35, -0.40, 0.00, 1.10, 0.00, 1.30, -0.35, 0.25, 0.10,        # arm1 j1..7,grip,rail
    0.20, 0.50, 0.80,  0.0, 0.0, 0.7071, 0.7071 ],                 # arm1 ee (camera:cam_env)
 "observation.images.cam_env":    <480x640x3 uint8>,
 "observation.images.arm0_wrist": <480x640x3 uint8>,
 "observation.images.arm1_wrist": <480x640x3 uint8>,
 "intervention": [False], "action_source": [1],                    # 1 = teleop
 "wallclock_ns": [1788278400123456789],
 "task": "hand the cube from arm0 to arm1",
}
```

Repo: `apollo/xarm7_handover_2arm_dee-base+cam.cam_env`. Episode sidecar
snapshots `T_W_C`, both rail origins, and the scene XML hash (§9).

**Legacy cross-check** (§4.2, arm0): our TCP `(0.50, 0, 0.35), (0,1,0,0)`
maps to legacy flange target `p_flange = (0.50, 0, 0.35) −
R((0,1,0,0))·(0,0,0.172) = (0.50, 0, 0.522)` and
`q_legacy = quat_conj((0,1,0,0)) ⊗ (0,1,0,0) = (1, 0, 0, 0)` — the legacy
"identity = gripper down" convention, flange 0.172 m above the TCP. ✓

## 11. On-disk layout: episode directories (primary) and the LeRobot v3 export

Decision (operator, 2026-09-07): **the recorder does not write a vanilla
LeRobot dataset.** LeRobot v3 concatenates many episodes into size-capped
`file-XXX.parquet` / `file-XXX.mp4` shards and indexes episodes by row range
and `from_timestamp/to_timestamp`; deleting one episode therefore means
lerobot's `delete_episodes`, which re-encodes every video shard that mixes
kept and deleted episodes, rewrites every parquet, renumbers `episode_index`
/ `index` / `task_index` and pulls torch onto the call path. The lab wants
episodes organised **per episode** so that a bad episode is one `rm -r` and
nothing else is touched. LeRobot itself moved from per-episode files (v2.1)
to v3 shards for Hub file-count limits (<100 k files per repo, 10 k entries
per folder), a constraint that does not apply to a lab disk — so we keep the
episode-level store and produce v3 only as an **export** for training.
Precedents borrowed: LeRobot v2.1 (one parquet + one mp4 per camera per
episode), DROID raw (one directory per trajectory, curated by moving /
removing directories), UMI (per-demo directories + a regenerable plan; the
derived replay buffer is rebuilt, never edited), RH20T (per-camera mp4 +
per-frame timestamps + audio in the episode folder), rosbag2 (one directory
per recording with a reindexable manifest).

### 11.1 Invariants

1. The episode directory is the **only source of truth**. `manifest.json`
   and every export are derivable from the directories and are rebuilt, never
   hand-edited.
2. **Episode ids are never reused** and are not dense integers (§11.3). Dense
   `episode_index` values exist only inside an export.
3. Every per-episode video starts at `pts 0`, has exactly `length` frames at
   `1/fps`, and records its encoder identity (§11.4) — the conditions under
   which lerobot's stream-copy concatenation is exact.
4. Saving is **atomic** (temp directory → rename, §11.6); a crash leaves at
   most one `.tmp-*` directory, never a corrupt dataset. There is no
   `finalize()` step whose omission corrupts anything.
5. Deletion touches one directory (§11.7). The export is regenerated from the
   remaining directories (remux only, §11.8).
6. The schema of every row is §7; the sidecar content is §9; the naming of a
   dataset (one per task × arm-count × frame convention) is §8.1. Nothing in
   this section changes what is recorded — only where it lives.

### 11.2 Tree

```
${APOLLO_HOME}/var/datasets/<namespace>/<name>/     # repo_id "<namespace>/<name>", §8.1 (bare name ⇒ "apollo/")
├── manifest.json                                    # dataset-level (§11.5): schema, fps, robot_type, video encoder,
│                                                    #   arms, cameras, episode count / frames (cached, rebuildable)
├── sessions/session_<session_id>.json               # §9, one per recording session
├── scenes/<sha256[:16]>.xml                         # §9, deduped composed-MJCF snapshots
├── episodes/
│   ├── 20260907T141203.512Z-3f9a1c/                 # one directory per SAVED episode (§11.3 id)
│   │   ├── episode.json                             # §9 sidecar (+ length, video, audio, stats, export_ok)
│   │   ├── frames.parquet                           # §11.4: §7 feature columns + timestamp + frame_index + task
│   │   ├── video/<camera_id>.mp4                    # one per recorded camera (§11.4)
│   │   └── audio.wav                                # optional, the Perception Arm microphone (§11.4)
│   ├── 20260907T141419.008Z-a71e02/
│   └── .tmp-20260907T141530.771Z-9b0c44/            # an episode being recorded / crashed mid-save (§11.6)
├── trainer_spool/ep_<episode_id>.parquet            # DAgger only (12-dagger §7 still reads ep_{index:06d} —
│                                                    #   phase-13 rekeys spool, EpisodeSummary and the trainer
│                                                    #   watermark to episode_id; the trainer reads ONLY the spool)
└── exports/
    └── lerobot_v3/                                  # DERIVED (§11.8): a complete LeRobot v3 dataset for repo_id
        ├── meta/{info.json, tasks.parquet, stats.json, episodes/chunk-000/file-000.parquet}
        ├── meta/apollo/{session_*.json, scenes/, episodes/episode_XXXXXX.json, episode_map.json}
        ├── data/chunk-000/file-000.parquet
        └── videos/observation.images.<camera_id>/chunk-000/file-000.mp4
```

Legacy phase-07 trees (a `meta/info.json` at the dataset root, no
`manifest.json`) are listed read-only as `layout: lerobot_v3` (04-runtime
§10.6); the recorder never appends to one.

### 11.3 Episode id

`episode_id = datetime.now(UTC).strftime("%Y%m%dT%H%M%S.%f")[:-3] + "Z-" + secrets.token_hex(3)`
— the UTC wall time at `episode_new` to the millisecond plus 6 lowercase hex,
e.g. `20260907T141203.512Z-3f9a1c` (the first frame's own wall time is
`episode.json.recorded_at`). The time prefix makes `sorted(os.listdir)`
the capture order (the export's dense `episode_index` follows it); the random
suffix makes an id unique even across hosts and clock corrections. Ids are
minted by the recorder at `episode_new`, are never reused, never renumbered,
and survive deletion of neighbours — the property every dense-integer scheme
surveyed lacks (ACT's `episode_{N}.hdf5` with `range(num_episodes)` loaders,
LeRobot's `episode_index`). The UI shows the position in capture order as a
convenience label ("#12 of 40"); the id is what every API takes.

### 11.4 Per-episode files

- **`frames.parquet`** — one row per recorded frame, one row group, written
  once at save from the in-memory episode buffer (a 25 fps episode of a few
  minutes is a few MB of floats). Columns: every §7 feature except the video
  ones (`action`, `observation.state`, `intervention`, `action_source`,
  `wallclock_ns`, DAgger extras §7.4), plus `timestamp` (float32,
  `frame_index / fps`), `frame_index` (int64) and `task` (string, the
  per-frame task label). **Not** present: `episode_index`, `index`,
  `task_index` — the export assigns them. Column dtypes/shapes are exactly the
  §7 feature dicts (fixed-size lists for vectors), so the export can stack
  files with pyarrow and no conversion. **Idle-frame filter (2026-09-07,
  operator; default ON; `SessionSpec.action_filter`, 04-runtime §10.5):** a
  frame whose commanded TCP / gripper / rail have not moved beyond the
  configured epsilons since the LAST KEPT frame, and that has no gripper
  change within ±`gripper_context_s`, is not recorded at all — not in the
  parquet, not fed to the encoder. Kept frames stay contiguous
  (`frame_index`, `timestamp = k / fps`), so the time gaps are invisible in
  the data exactly as in the heuristic's source project (pro-dagger); the real
  capture time is in `wallclock_ns`, and every gap is listed in
  `episode.json["filter"]["gaps"]` (§9). The first frame is always kept;
  policy-driven frames in DAgger are never filtered.
- **`video/<camera_id>.mp4`** — one per recorded camera, produced by lerobot's
  `StreamingVideoEncoder` with the dataset's pinned encoder (§7.5): `pts = k`,
  `time_base = 1/fps`, exactly `length` frames (the per-episode file is NOT
  `movflags=faststart`; only the export's concatenated file is). The recorder
  counts its own `feed_frame` calls per camera and reads the encoder's
  dropped-frame counter at save (`StreamingVideoEncoder._dropped_frames` is a
  private dict lerobot only logs — wrap it, or count the finished file's
  packets with `av`); `fed − dropped != rows`, or `stats is None` (fewer than
  2 frames encoded), marks the episode `export_ok: false` with `export_note` —
  the episode is kept and listed with a warning but excluded from exports (a
  shorter video than its parquet would break lerobot's decode tolerance for the
  trailing frames and the `length == round(to·fps) − round(from·fps)`
  assertion of its `delete_episodes` / `split` tools). The encoder
  identity (`codec` canonical name, `encoder` = the actual vcodec,
  `pix_fmt`, `g`, `crf`, `extra_options`, `width`, `height`) is recorded per
  camera in `episode.json["video"]` and pinned per dataset in the manifest.
- **`audio.wav`** — optional; mono PCM s16le at the microphone reader's rate
  (48 kHz for the RØDE NT-USB Mini), buffered by `EpisodeAudioSink` between
  `episode_new` and save (04-runtime §10.5). LeRobot has no audio feature
  type, so audio stays a sidecar of the episode; the alignment block in
  `episode.json["audio"]` (`t0_mono`/`t0_wallclock_ns` sampled together,
  `audio_start_mono`, block bookkeeping) maps sample `i` onto the frames'
  `wallclock_ns` column. An export never carries audio into the mp4s.
- **`episode.json`** — §9.

### 11.5 `manifest.json`

```jsonc
{
  "apollo_dataset_layout": 1,                 // this section's version; readers refuse unknown majors
  "repo_id": "apollo/pick_red_cube",
  "created_at": "...", "modified_at": "...",  // ISO-8601 UTC
  "fps": 25,
  "robot_type": "xarm7_2arm_rail",            // §7.5; "..._mujoco" for sim
  "features": { /* the §7 feature dicts incl. per-feature info blocks — the schema every episode must match */ },
  "arms": ["grip", "view"], "cameras": ["grip_wrist", "view_wrist"],
  "video": { "codec": "h264", "encoder": "h264_nvenc", "pix_fmt": "yuv420p", "g": 2, "crf": 30,
             "extra_options": {"bf": "0"}, "backend": "pyav" },   // pinned at creation (§7.5)
  "episodes": 40, "frames": 61250,             // cached counters — rebuilt from episodes/ on every open
  "last_export": { "format": "lerobot_v3", "path": "exports/lerobot_v3", "at": "...",
                   "episodes": 39, "stale": true,     // stale = an episode was added/deleted since
                   "error": null }                    // a failed job writes its reason here
                                               // (state `failed` until the next success;
                                               //  `running` is process-local telemetry)
}
```

`dataset_incompatibility` (04-runtime §10.5) compares a session's `fps`,
`robot_type` and feature signatures (dtype, shape, names AND the `info`
blocks `apollo_schema` / `action_space` / `frames` / `rail`, per §8.3) against
the manifest before a resumed session touches anything; a mismatch is a 409.

### 11.6 Write protocol (recorder)

1. `episode_new` (control-loop thread — never a filesystem or thread op):
   mint `episode_id`, flip state, `audio.begin()`, empty the row buffer.
   The RECORDER thread then, at once and before any frame, creates
   `episodes/.tmp-<episode_id>/` and starts one `StreamingVideoEncoder`
   episode with `temp_dir` = that directory — the encoder open holds the GIL
   for 160–330 ms (measured, NVENC), so it happens right after the operator
   pressed N, not on the first frame of motion (04-runtime §10.5 "GIL stall").
2. `add_frame` (recorder thread, paced at `fps`): `feed_frame` per camera and
   append the non-video columns to the buffer (subject to the idle-frame
   filter, §11.4).
3. `episode_save`: `finish_episode()` → per-camera `(path, stats)`; move each
   mp4 to `video/<camera_id>.mp4` and remove the encoder's `tmp*/`
   sub-directories it leaves behind; check frame counts (§11.4); write
   `frames.parquet`; compute non-video stats (lerobot's
   `compute_episode_stats` semantics) and store the video stats as lerobot's
   writer does — every key except `count` → `squeeze(v.reshape(1, -1, 1, 1) /
   255.0, axis=0)` = (3,1,1) in [0,1], `count` kept as (1,); `audio.finish()`
   into the temp directory; write `episode.json` (the last file); `os.replace`
   the temp directory to `episodes/<episode_id>/`; refresh `manifest.json`
   counters and mark `last_export.stale`. Save = one rename; there is no
   writer to finalize. Everything that goes into `episode.json` (extrinsics,
   `frames_dropped`, `gate_events`, `episode_summary`, the audio block) is
   assembled by `RecorderThread` BEFORE it calls `save(sidecar, audio)`
   (04-runtime §10.1), so the sidecar is inside the directory at publication.
4. `episode_discard`: `cancel_episode()`, `audio.abort()`, `rmtree` the temp
   directory. Nothing is left.
5. On open (session start, `DatasetStore` scan, runtime start): every
   `episodes/.tmp-*` older than the running session is a crashed episode —
   removed and logged. This replaces phase-07's `recorder_state.json` +
   `resume() + finalize()` repair.

### 11.7 Deletion

`DELETE /api/datasets/{ns}/{name}/episodes/{episode_id}` removes
`episodes/<episode_id>/` (and its `trainer_spool` row if any), refreshes the
manifest and marks the export stale — no other episode is read, decoded or
renumbered. It is allowed while a session records into the same dataset,
except for the episode currently open (409). Deleting the last episode leaves
an empty dataset (a manifest and zero episodes), which is legal here even
though lerobot cannot represent one; `DELETE /api/datasets/{ns}/{name}` removes
the whole tree (UI double-confirm). No trash / undo in this phase: the UI
confirm text says so.

### 11.8 Export to LeRobot v3

`exports/lerobot_v3/` is rebuilt as a whole by the export job (04-runtime
§10.6; also `python -m apollo_mavis_v2_runtime.tools.export_lerobot <repo_id>
[--out DIR]`) — a full rebuild is cheap because nothing is re-encoded (a
remux of N per-episode mp4s runs at disk speed), and rebuilding avoids every
incremental-append hazard in lerobot's writer. The algorithm mirrors
lerobot's own `convert_dataset_v21_to_v30` (per-episode files → v3):

1. Take the episodes with `export_ok == true`, sorted by `episode_id`
   (capture order); assign `episode_index = 0..n−1`; write
   `meta/apollo/episode_map.json` as `{"episodes": [{"episode_index": 0,
   "episode_id": "…"}, …]}`.
2. **Videos**, per camera: group consecutive episodes with an identical
   encoder identity (§11.4); within a group accumulate files while
   `size_so_far + size(ep) < video_files_size_in_mb` (lerobot default 200 MB,
   or a configured cap) and concatenate each group's files into
   `videos/<key>/chunk-CCC/file-FFF.mp4` with the **ffconcat demuxer, packet
   remux, no re-encode** (lerobot `concatenate_video_files` semantics; ~50
   lines over `av` when the job must stay torch-free — the concatenated file is
   written with `movflags=faststart`, the per-episode files are not). Per
   episode record
   `videos/<key>/chunk_index`, `file_index`, `from_timestamp` = the cumulative
   duration of the earlier episodes in that file (`Σ length/fps`, exact) and
   `to_timestamp = from + length/fps`. A change of encoder identity always
   starts a new file (§7.5).
3. **Data**: stack `frames.parquet` files in the same order into
   `data/chunk-CCC/file-FFF.parquet` (one row group per episode, snappy),
   adding `episode_index`, `index` (global, 0..N−1 in file order — lerobot
   indexes rows positionally) and `task_index` (from `meta/tasks.parquet`,
   whose row order must equal `task_index`), and DROPPING the per-frame
   `task` string column — a lerobot data parquet carries exactly the
   `info.json` features plus the five bookkeeping columns, and
   `Dataset.from_parquet(..., features=)` raises `CastError` on any extra
   column (verified with datasets 4.8.5); respect `data_files_size_in_mb`
   (default 100 MB).
4. **Meta**: `meta/episodes/chunk-000/file-000.parquet` with every column
   lerobot's reader looks up positionally (`episode_index`, `tasks`, `length`,
   `data/chunk_index`, `data/file_index`, `dataset_from_index`,
   `dataset_to_index`, `videos/<key>/…`, `meta/episodes/chunk_index|file_index`,
   flattened `stats/*` from each `episode.json["stats"]`); `meta/stats.json` =
   lerobot `aggregate_stats` over the per-episode stats (no video is decoded);
   `meta/info.json` from the manifest (`codebase_version v3.0`, fps, features
   with `info["video.*"]` probed from `chunk-000/file-000.mp4`, totals, `splits
   {"train": "0:N"}`, path templates, the size caps); `meta/tasks.parquet`.
5. Carry the sidecars (§9) into `meta/apollo/`, rewriting `episode_index`.
6. **Validate** by opening `LeRobotDataset(repo_id, root=<export>)` and
   reading the first and last frame of the first and last episode (this is
   the one place the export job may import `lerobot.datasets`, i.e. torch;
   it runs on the job thread, never on the REST path). Then write
   `manifest.last_export`.

What the export must satisfy, and why (verified against lerobot 0.6.1):

| Requirement | Because |
|---|---|
| `episode_index` exactly `0..n−1`, episodes-parquet row `i` = episode `i` | the reader indexes `meta.episodes` positionally and refuses gaps (falls through to a Hub download) |
| `index` == global row position; `total_frames` == rows | `hf_dataset[index]` is positional; `__len__` comes from `info.json` |
| `tasks.parquet` row order == `task_index` | `tasks.iloc[task_idx]` |
| `timestamp[k] == k/fps`, video frame `k` at `pts k/fps`, `from_timestamp` exact | decode tolerance `1e-4 s` against `from_timestamp + timestamp` |
| video frames == parquet rows per episode | trailing frames would miss the tolerance; `delete_episodes` asserts it |
| identical codec / pix_fmt / size / fps within a file; identical encoder by policy | lerobot checks the former only; the latter is our stricter rule (§7.5) |
| `stats/*` per episode with `count` and `(3,1,1)` image stats in [0,1] | `aggregate_stats` weights by count and validates shapes |
| no column outside the `info.json` features + bookkeeping in a data parquet | `Dataset.from_parquet(..., features=)` casts strictly — `CastError` on an extra column |

The export is what training and merging consume (`LeRobotDataset`,
`merge_datasets`, the ALOHA exporter of Appendix A, external Dora trainers
per 14-dora). DAgger rounds (12-dagger §7) rebuild the export at each round
boundary, or read the per-episode files directly through the runtime's own
reader — phase-13 fixes which and keeps 12-dagger consistent.

### 11.10 Dataset roots per namespace and the Online DAgger session directory (2026-09-08)

Operator decision 2026-09-08 (15-online-dagger §0 item 6, D5; the morning's spelling
`pro_dagger/<s>` / `ref_grad/` is superseded — the evening's decision made the runtime an
algorithm-agnostic shell, so the session directory holds NOTHING of the trainer's):
**where** a dataset lives is decided per namespace; the repo-id grammar (§8.1), the tree
(§11.2) and every REST route keep their shape. `RuntimeConfig.datasets`
(04-runtime §14) maps a namespace to `{root, subdir}`; `default_namespace` is
what a bare `dataset: "<name>"` resolves into (`bc_demo` on the lab; the
pre-2026-09-08 `apollo/` prefix is now the GENERIC fallback for unmapped
namespaces and the test default):

```
bc_demo/<name>      ->  ~/data/bc_demo/<name>/                       # demonstrations (Data Collection)
                        ├── manifest.json, sessions/, scenes/, episodes/<id>/…, exports/   (§11.2 tree)
online_dagger/<s>   ->  ~/data/online_dagger/<s>/                    # ONE Online DAgger session
                        ├── session.json          # runtime-owned resume record (15-online-dagger §3/§12):
                        │                         #   {session_name, created_at, session_id, task, spec,
                        │                         #    paths{session_dir, rollouts},
                        │                         #    rollouts[{episode_id, saved_at, actor_counts,
                        │                         #      policy_version, spool_path}],
                        │                         #    trainer_log[{at, state, policy_version, detail}] (newest 200),
                        │                         #    current{phase, rollouts_saved, expert_frames_session,
                        │                         #      novice_frames_session}, last_used_at};
                        │                         #   json.dumps(indent=2, sort_keys=True), tmp + os.replace
                        └── rollouts/             # the dataset "online_dagger/<s>" — a normal §11.2 tree
                            ├── manifest.json     #   (features incl. the DAgger extras + actor, §7.4)
                            ├── episodes/<id>/{episode.json (+ "online_dagger" block, §9), frames.parquet,
                            │                     video/<cam>.mp4, audio.wav}
                            ├── trainer_spool/ep_<id>.parquet          # SPOOL_COLUMNS incl. actor
                            └── sessions/, scenes/, exports/
                        # NOTHING else is created by the runtime. The trainer keeps its own artefacts
                        # wherever it likes — the skill suggests <session_dir>/trainer/ (the PRO-DAgger
                        # reference implementation writes trainer/ref_grad/ + trainer/checkpoints/ there);
                        # the runtime never reads or lists them.
<anything else>/<n> ->  ${APOLLO_HOME}/var/datasets/<ns>/<n>/       # generic root, unchanged (phase-07..13 data)
```

Rules (04-runtime §10.6 / §10.7, `recorder/datasets.py::DatasetStore`): the
rollouts dataset is addressed as `online_dagger/<s>` everywhere (`GET
/api/datasets/online_dagger/<s>`, delete, export); the session directory is the
rollouts' parent when the namespace maps a `subdir` (the shipped layout) and the
dataset directory itself when it does not (tests). `DatasetStore.list()` walks
the generic root AND every mapped root and skips a generic-root directory of a
mapped namespace (unaddressable); `delete_dataset` removes the dataset tree but
never a mapped root or the Online DAgger session directory (`session.json` and the
trainer's own files survive a rollouts delete); deleting a SAVED rollout of the
RUNNING Online DAgger session is 409 (`"dataset 'online_dagger/<s>' is in use by the
running Online DAgger session - end the session first (the trainer is told about
discards, not deletions)"` — 2026-09-08 evening review fix; every other dataset keeps
"only the open episode is protected"); `POST /api/session` for an Online DAgger name
is 409 while `online_dagger/<s>` is being exported (or is a legacy v3 tree); the
`.tmp-*` sweep covers every root. `GET /api/datasets/layout` → `DatasetLayoutInfo
{default_namespace, generic_root, namespaces}` is how the UI learns the real folders
(05-ui §8.1). Ids under `rollouts/episodes/` are §11.3 ids; the recorder's
`episode_index` counts SAVED episodes only (a discarded rollout consumes no index and
leaves nothing on disk — `events.episode_discarded` is the only trace). Anything else
the trainer writes into the session directory (checkpoints, reference-gradient caches,
logs) is its own business; the skill recommends `<session>/trainer/` and the runtime
never reads it.

### 11.9 Not in this layout

- No Hub upload of the raw tree (it would hit the 10 k-entries-per-folder
  limit at 10 k episodes and the recommended 100 k-files-per-repo budget at a
  few thousand episodes with two cameras + audio + sidecars) — upload an
  export.
- No in-place editing of an export; regenerate it.
- No importer from legacy phase-07 v3 trees in this phase (they stay listed
  read-only); a one-off `tools/import_lerobot_v3.py` that splits a v3 tree
  into episode directories is a possible follow-up (it would re-encode once,
  because a v3 shard cannot be cut exactly at episode boundaries by stream
  copy unless every episode starts on a keyframe — with `g=2` it does, so a
  keyframe-aligned `-c copy` cut is worth trying first).

## Appendix A — ALOHA-HDF5 exporter (interface sketch)

Optional offline export for training codebases that demand ALOHA-style HDF5
(research lerobot-data §7). ~100 lines over the lerobot reader; never a
recording path. Interface only:

```python
# apollo_mavis_v2_runtime/tools/export_aloha.py
@dataclass(frozen=True)
class AlohaExportConfig:
    repo_id: str; root: Path; out_dir: Path      # one episode_{idx}.hdf5 per episode
    camera_map: dict[str, str] = ...             # observation.images.<id> -> /images/<name>
    compress: bool = True                        # per-frame JPEG + /compress_len
    state_slice: str = "joints"                  # joints|full: qpos source dims by name

def export(cfg: AlohaExportConfig) -> list[Path]:
    # for each episode: decode video frames, slice observation.state by names
    # into /observations/qpos (T, n); zero-fill /observations/qvel; copy
    # action rows to /action (T, D); attrs: sim (from robot_type),
    # apollo_schema, action_space, frames (JSON string), source repo_id + episode.
```

Lossy by design (no stats/tasks/sidecar semantics in HDF5); the sidecar JSON
is copied next to each `.hdf5` verbatim. No importer — the episode store
(§11) is primary and the LeRobot v3 export is the training format.

## Appendix B — Cross-doc drift resolved by this document

Aligned by the consistency pass; until then this table governs:

| # | Drift | Resolution (canonical, this doc) |
|---|---|---|
| 1 | 04-runtime §10.2 `action_space: "joint_position"` | core `PolicySpec` literal `"joint"` (§1.2, §6) |
| 2 | core §5.2/§9 `action_frame: "base" \| "camera:<id>"`; research `ActionFrame` enum | full `FrameRef` strings `arm_base:<id> \| world \| camera:<id>` everywhere (§1.3); `world` first-class |
| 3 | 04-runtime/12-dagger `action_source` labels `{0 policy, 1 human_teleop, 2 reset_planner}` | `{0 policy, 1 teleop, 2 joint_jog, 3 takeover, 4 planner}` mirroring core `CommandSource` (§7.3); 0/1 semantics preserved |
| 4 | 03-sim MJCF `[rail, j1..j7]` config layout stated as the arm layout | MJCF `qpos` order is sim-private; every external boundary is `[j1..j7, rail]` (§1.1, §2.5) |
| 5 | 04-runtime `features["action"]["info"]["frames"]` keys shown as `"left"/"right"` (research example) | keys are `WorkcellConfig` arm ids; values full `FrameRef`s (§5.2) |
| 6 | 12-dagger repo pattern `{task}_{arms}arm_{frame}_dagger_{run_id}` | §8.1 grammar (`conv` token incl. action space) |
| 7 | research `xarm7-ik` rail bound 0.74 m / MJCF ±0.37 offset | `RAIL_TRAVEL_M = 0.65`, direct `[0, 0.65]` (§4.3) |
| 8 | 00-overview §3.3 / 04-runtime §10 (v0.1) "backed by LeRobot dataset v3 via `LeRobotDataset.create … finalize`" | since 2026-09-07 the recorder writes one directory per episode and LeRobot v3 is a derived export (§11); the §7 schema is unchanged |
| 9 | §11.2 tree / §8.1 "bare name ⇒ `apollo/`" and one root `${APOLLO_HOME}/var/datasets/<ns>/<name>` for every namespace | since 2026-09-08 (15-online-dagger D5, operator; the morning's `pro_dagger/<s>` spelling never shipped) roots are per namespace: `bc_demo/<name>` → `~/data/bc_demo/<name>`, `online_dagger/<s>` → `~/data/online_dagger/<s>/rollouts`, a bare name resolves into `RuntimeConfig.datasets.default_namespace` (`bc_demo`); the generic root keeps every unmapped namespace incl. the existing `apollo/…` data (§11.10, 04-runtime §10.6). Grammar, tree and routes unchanged |
| 10 | 12-dagger §4 lists three DAgger-only features | four since 2026-09-08: + `actor` (§7.4; `apollo_schema` not bumped) |

Open (tracked, not blocking): whether `observation.state` should also carry
measured EE twist dims for dynamic tasks (schema bump to `apollo_schema = 2`
if adopted); exact `RecorderConfig.fps` default (25 vs 30) is owned by
04-runtime — this doc's tables use 30 and bind only the 20–30 band.
