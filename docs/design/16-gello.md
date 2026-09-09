# 16 — GELLO Manipulation: a passive leader arm drives the Manipulation Arm, the Perception Arm is an external viewpoint, and the twin gains the kitchen

Status: **v1.0, binding for phase-15 (2026-09-09).** Operator request of 2026-09-09 (§0) plus the
main-agent decisions in §1. Every number in §3 was measured on 2026-09-09 from the Perception Arm's
wrist RealSense at the GELLO hold posture (the method and the raw captures are recorded there);
edit the numbers in `mavis_v2_kitchen.yaml` and this section together. §15 is the implementation
record; where this document and the code disagree, the code wins and the deviation is recorded
there. Companion phase plan: `docs/prompts/phase-15-gello.md`.

Vocabulary (00-overview §0): the **Manipulation Arm** (id `grip`) and the **Perception Arm** (id
`view`); **GELLO** is the passive xArm7-shaped leader arm (Dynamixel servos read over one USB
serial adapter); the **viewpoint node** is any external dora node that publishes actions for the
Perception Arm; the **kitchen twin** is the `mavis_v2_kitchen` scene (`mavis_v2` + the fridge, the
range, the counter run and their AprilTags).

## 0. Operator decisions (2026-09-09, binding)

1. The landing page gets a **fifth card, "GELLO Manipulation"**, beside Teleop, Data Collection,
   Online DAgger and Inference. It is a session mode of its own (wire id `gello`).
2. GELLO drives the **Manipulation Arm only**, in joint space; its operating logic is otherwise
   teleop-like (no recording in v1). The keyboard's **←/→ still drive the Manipulation Arm's rail**
   in this mode; GELLO drives the seven joints and the gripper.
3. In GELLO mode the **Perception Arm's action is published from outside** (e.g. a policy repo
   over the existing dora external interface). When nothing publishes, the Perception Arm **holds
   its GELLO hold posture**: J1–J7 `[2.646, -1.598, 0.018, 1.637, 0.25, 2.007, 0.029]` rad,
   rail `0.0` m (twin convention; the posture the arm stood in on 2026-09-09 when the kitchen was
   measured — verified identical to the controller reading to 1e-3 rad). This posture is
   DIFFERENT from the seeded initial condition used by Teleop / Data Collection.
4. GELLO mode uses a **different digital twin**: the cell plus a **refrigerator (GE GDE21ESKSS)**
   and a **30-inch GE free-standing electric range**, placed where the Perception Arm's camera sees
   them, each carrying its AprilTags at the measured positions. (The operator's message also said
   "dishwasher" for the second appliance; the camera shows a coil-top range and the operator named
   the range model, so the second appliance is the range.) The appliances must render in the twin
   overlays so their alignment against the real cameras can be checked.
5. Because GELLO is passive and starts at an arbitrary posture, a GELLO session **first moves the
   Manipulation Arm to the GELLO posture**. If that posture collides with the kitchen, the launch
   is **refused with the colliding pair** and the UI **shows where the virtual arm collides**; the
   operator adjusts GELLO and retries; when the posture is clear, **OK starts the session**.
6. The Cockpit's right-hand **clearance list must stop pushing the episode buttons out of view**
   (a bounded, compact readout). See §12.4 for what actually grows and the fix.

## 1. Main-agent decisions (implementation follows these; the operator can overturn)

- **D1 wire.** `SessionSpec.mode == "gello"` with a non-null `SessionSpec.gello: GelloSessionConfig`
  (`viewpoint: "auto" | "external" | "hold"`, default `auto`; `extra="forbid"`). `gello` accepts
  no `task` / `dataset` / `policy` / `online_dagger` and only the default `return_to_start` /
  `action_filter`; `policy_source` stays at its default — the viewpoint field says whether an
  external node may drive the Perception Arm. Every person-facing surface says "GELLO
  Manipulation"; the ids stay internal.
- **D2 the leader is a runtime device, like the Vive controller.** `apollo_mavis_v2_runtime.devices.gello.GelloReader`
  (daemon thread, `LatestSlot[GelloSample]` on the runtime bus, backends `none | fake | dynamixel`,
  `status(now)` with age / stale / rate, jump rejection, backoff restarts) — the tracker pattern
  (13-tracker §2), not a workcell member. `dynamixel_sdk` / `pyserial` are the new optional extra
  `[gello]` and are imported lazily in that one module (ruff banned-api + an AST guard test, as for
  `pysurvive` / `sounddevice`). Core gets no new interface (there is none for the tracker either).
- **D3 engagement state machine, no implicit motion.** The follower streams the leader only in
  state `tracking`; `no_leader` (stale / invalid sample), `out_of_sync` (leader farther than the
  engage tolerance from the measured arm, or the leash exceeded while tracking), `paused` (operator
  action, or forced by a fault / a planned motion) and `motion` (a twin-planned motion owns the arm)
  all HOLD the last command. Re-engagement is automatic only from `out_of_sync` (the operator brings
  GELLO back within tolerance); leaving `paused` needs the operator's **Resume**. The joints with a
  ±2π range (1, 3, 5, 7) are unwrapped to the branch nearest the measured arm at every engagement.
- **D4 launch = check, plan, move, engage.** `POST /api/session` (mode `gello`) reads the leader,
  builds `q_goal = {grip: unwrapped leader joints + the measured rail, view: hold posture, rail 0.0}`,
  refuses with the joint-limit violation or the colliding pairs (`409 GELLO posture collides:
  <a> / <b> at <mm> mm - move GELLO and retry`), plans both arms on the session twin
  (kitchen scene) and executes ONE ARM AT A TIME in `arm_order` through `_execute_arms` (the
  2026-09-08 rule), then engages if the leader is still within tolerance (else `out_of_sync`).
  The session-less **`POST /api/gello/preview`** runs the same check on a cached kitchen twin and
  returns the verdict plus a PNG of the virtual cell with the colliding bodies tinted red; the
  GELLO launch sheet polls it while the operator moves GELLO.
- **D5 the viewpoint node rides the existing external policy path, scoped to one arm.** In gello
  mode the runtime announces `external_arms: ["view"]` (new additive `SessionAnnounce` field,
  appended last) and a view-only `action_names` layout (`view_ee.dx … view_gripper.pos,
  view_rail.dpos`); it accepts `policy_action` (delta_ee, frame == the session's view frame,
  `action_names` == that layout) and applies it through the same `ActionAnchor` + slew + gate path
  as Online DAgger. `viewpoint: auto` attaches the node whenever a compatible `policy_spec` is fresh
  and drops it (hold) when it goes stale; `external` refuses the launch without one; `hold` ignores
  the bus. `obs_state` is published in gello mode. Nothing can move the Manipulation Arm over the
  bus.
- **D6 the kitchen is a second scene id, hidden from the listing.** `mavis_v2_kitchen`
  (`hidden: true`, title "APOLLO MAVIS V2 Kitchen (GELLO)") keeps `GET /api/scenes` and the
  operator decision "`mavis_v2` is the only exposed scene" literally intact; the GELLO card selects
  it implicitly (`sim_scene` / `digital_twin_scene`) and `GET /api/gello` names it. Appliances are
  dimensioned BOXES from the spec sheets placed on the measured faces (§3), collidable, and the
  AprilTags are non-collidable textured plates. The twin overlays draw them as outlines; the lab
  config may point `twin_overlay.scene` at the kitchen so the alignment check works session-less.
- **D7 the handles are graspable.** The scene declares `graspable: [fridge_door_handle,
  fridge_drawer_handle, range_handle]`; a gello session whitelists those geoms against the
  Manipulation Arm's gripper (the existing `set_grasp_whitelist`), so the fingers may touch a
  handle while every arm link is still gated against every appliance body. The twin does not model
  an opening door (v2).
- **D8 GELLO is admitted on hardware.** `_validate_hardware` lists `gello` beside teleop and
  collect (the operator asked for the real Manipulation Arm); `hardware_session.armed` still gates
  every driver connection and the first live run follows the phase-15 acceptance steps. Online
  DAgger stays refused on hardware (15-online-dagger D7 is untouched).
- **D9 in-session keys.** ←/→ = the Manipulation Arm's rail (every source, as today); every other
  held key (translate / rotate / gripper / clutch) is ignored for the Manipulation Arm; the gripper
  follows the leader's trigger; `Tab` / `Z` / the arm rows / `Space` / the episode keys are nacked
  with a reason; `R` and Go to profile run as planned motions that force `paused`. The keymap
  (operator-owned, 24 rows) is untouched — Pause / Resume are Cockpit buttons (actions
  `gello_pause` / `gello_resume`, idempotent).
- **D10 calibration is a session-less REST op.** `POST /api/gello/calibrate {op: match_arm}`
  reads the leader's raw joints and the Manipulation Arm's current joints and stores per-joint
  offsets (the nearest multiple of π/2, the GELLO convention) in `var/gello_calibration.json`;
  `joint_signs` are operator-owned config; the gripper endpoints are two more ops.

## 2. Roles

```
        GELLO leader (passive)             viewpoint node (optional, dora "policy" placeholder)
        Dynamixel bus over FT232H                  policy_spec / policy_action
                 │ /dev/serial/by-id/…FTAKROCJ…               │ private dora plane
                 ▼                                             ▼
   runtime.devices.gello.GelloReader ──► RuntimeBus.gello   ExternalPolicyHub ──► ViewpointSource
                 │ fresh sample (100 Hz)                                   │ delta_ee, view block only
                 ▼                                                         ▼
   ┌──────────────── GelloLoop (ControlLoop subclass, one 100 Hz tick) ────────────────┐
   │ grip: engage state machine ─► leader joints (unwrapped) + ←/→ rail + trigger gripper │
   │ view: viewpoint action (ActionAnchor + slew) or HOLD the GELLO hold posture           │
   │ both: _cap_joint_step (uniform) ─► SafetyGate on the KITCHEN twin ─► ArmSender        │
   └────────────────────────────────────────────────────────────────────────────────────┘
   launch: POST /api/gello/preview (check + PNG)  →  POST /api/session {mode: gello}
           = check → plan both arms → execute one arm at a time → engage
```

## 3. The kitchen: what was measured on 2026-09-09 and how

**Setup.** The Perception Arm stood at the GELLO hold posture (§0 item 3), rail 0.0, controller
stopped (E-stop), both wrist cameras live through the runtime. One colour frame of `view_wrist`
(640×480, the runtime's MJPEG mirror) and 45 depth frames of the same D435i (`243522071002`,
depth-only pipeline through librealsense — the runtime holds only the colour UVC node, so the depth
node was free) were captured; the median depth image was re-projected into the colour frame with
the device's own depth→colour extrinsics (t = [14.8, −0.16, 0.32] mm) and the colour intrinsics
(`fx 606.36 fy 606.38 cx 311.90 cy 249.45`, identical to `configs/mavis_v2.yaml`). Raw captures:
`var/gello-kitchen-20260909/` (colour JPEG, aligned depth `.npy`, tag detections, calibration).

**Camera pose.** From the `mavis_v2` twin at that posture (`REGISTRY.build`, `mj_kinematics`,
`cam_xpos/cam_xmat[view_wrist_cam]`): position **(0.460, 0.394, 1.579) m**, optical axis
**(−0.243, −0.907, −0.343)** (toward −Y = away from the operator, 20° down), image-right ≈ world
−X. The overlay's principal-point nudge for `view_wrist` (`principal_offset_px [21, 13]`) means the
real image equals the modelled camera with `cx + 21, cy + 13`; every pixel below was deprojected
with that convention (the alternative conventions shift the kitchen by ~5 cm; recorded in the
captures directory for re-analysis).

**Tags.** Family **tagStandard41h12**, ids **0, 1, 3, 4** (`pupil-apriltags`, margins 37–69,
hamming ≤ 1). Each tag's depth pixels were plane-fitted (RMS 1.8–3.2 mm) and its four detected
corners intersected with the plane. Detected-quad edge **0.0931 m** (mean of 16 edges, ±3 mm):
for this family the detected quad is the inner 5 of 9 bits, so the printed tag is **0.168 m** and a
sheet with a one-bit white margin **0.205 m** (the texture plate size, §10). World poses
(x, y, z in m):

| tag | where (real) | centre | face normal | face |
|---|---|---|---|---|
| 0 | fridge, left side panel, upper | (0.075, −1.314, 1.426) | (+0.997, +0.055, +0.049) | fridge +X side |
| 4 | fridge, left side panel, lower | (0.076, −1.142, 0.543) | (+0.997, +0.073, +0.037) | fridge +X side |
| 1 | fridge, upper door | (−0.360, −1.027, 1.489) | (+0.089, +0.990, +0.107) | fridge +Y front |
| 3 | range, oven door | (0.616, −1.222, 0.498) | (−0.028, +0.978, +0.208) | range +Y front |

Tags 0 and 4 share x to 1 mm although they are 17 cm apart in y and 88 cm apart in z: the fridge's
side panel is parallel to the world Y axis, i.e. the kitchen run is **parallel to the world X
axis (yaw 0)**. The individual normals disagree by up to 8° (specular door, small patches) and
were not used for orientation.

**Planes from depth.** Counter top **z = 0.926** (patch RMS 3 mm; the 36-inch standard is 0.914 —
+1 cm), drawer fronts **y = −1.279**, range front (tag 3) **y = −1.222**, fridge door (tag 1)
**y = −1.027**, fridge side (tags 0/4) **x = 0.075**, range's right edge (ray on the tag-3 plane)
**x ≈ 0.48**. Two consistency checks passed: the counter's depth from its drawer faces to the wall
implied by the range (28-inch range against the wall) is **0.604 m vs the 24-inch standard
0.610**, and the fridge's back (34.6-inch total depth less a 5 cm handle) lands **2.7 cm off that
wall**. The cabinet between range and fridge measures 0.405 m (a 15- or 18-inch box plus filler).

**Spec dimensions used** (web spec pages; GE's own site refused the fetch): GDE21ESKSS
W 29¾ in × H 69⅞ in × D 34⅝ in with handle (US Appliance lists 36⅝ — the depth only moves the back
face, which the arm cannot reach); 30-inch free-standing coil range (JBS60 class) W 29⅞ × H 47 (to
the backguard top) × D 28 in, cooktop 36 in; counter 36 in high, 24 in deep; upper cabinets 12 in
deep from 54 in to 84 in above the floor.

**Resulting boxes (world, metres; `size` = half-extents, `pos` = centre).** Floor z = 0 is the
twin's floor (the cell and the kitchen share the room floor — assumption).

| geom | x range | y range | z range | note |
|---|---|---|---|---|
| `fridge_body` | −0.681 … 0.075 | −1.856 … −1.027 | 0 … 1.775 | case + doors |
| `fridge_door_handle` | 0.015 … 0.045 | −1.027 … −0.977 | 0.75 … 1.65 | vertical bar, +X edge of the upper door |
| `fridge_drawer_handle` | −0.545 … −0.055 | −1.027 … −0.977 | 0.475 … 0.510 | freezer drawer bar (measured z 0.49) |
| `range_body` | 0.480 … 1.239 | −1.883 … −1.222 | 0 … 0.914 | |
| `range_backguard` | 0.480 … 1.239 | −1.883 … −1.783 | 0.914 … 1.194 | |
| `range_handle` | 0.530 … 1.189 | −1.222 … −1.172 | 0.600 … 0.630 | |
| `counter` | 0.075 … 0.480 | −1.889 … −1.279 | 0 … 0.914 | drawer cabinet between the two |
| `upper_cabinet` | 0.075 … 1.289 | −1.883 … −1.578 | 1.372 … 2.134 | |
| `kitchen_wall` | −1.00 … 1.50 | −1.933 … −1.883 | 0 … 2.40 | |
| `tag_0`, `tag_4` | plates on the fridge +X face at the tag centres above | | | non-collidable |
| `tag_1` | plate on the fridge +Y door face | | | non-collidable |
| `tag_3` | plate on the range +Y door face | | | non-collidable |

**Accuracy and what the overlays are for.** Depth at 1.5–2.2 m carries ±2–3 cm; the camera-model
convention another ±2 cm; the spec dimensions are exact only for the measured faces. Treat every
appliance face as **±3 cm** until the `*_align` overlays (kitchen scene) have been compared with
the real wrist images and the YAML nudged — that comparison is a phase-15 acceptance step, and a
sim test detects the four tags on a render of the kitchen twin from the same camera and compares
their pixel centres with the real detections (the tag orientation on the plates is checked the same
way). Reach: the Manipulation Arm's base line is y = −0.179, so the fridge door / handle at
y ≈ −1.03 / −0.98 is at the limit of its reach and the range is beyond it — the fridge is the
obstacle that matters for the gate; the range, counter and cabinets matter for completeness and
the overlays.

Not modelled: the blue cart with the toy food in front of the fridge, the tripod, the hood; the
fridge door as a hinged body (D7).

## 4. Runtime device: `GelloReader`

Module `apollo_mavis_v2_runtime/devices/gello.py` (only importer of `dynamixel_sdk` / `serial`).

- **Bus.** Dynamixel protocol 2.0, one `GroupSyncRead` of present position (address 132, 4 bytes)
  over `joint_ids` (default `[1..7]`) plus `gripper_id` (default `8`); poll at `poll_hz` (100).
  Baud: `baud` or auto-scan `57600, 1_000_000, 2_000_000, 3_000_000, 4_000_000` at connect (a
  broadcast ping per rate; the first rate that answers wins and is logged). Port: `port`
  (default `/dev/ttyUSB0`) or, when `usb_serial` is set, the `ttyUSB*` node whose sysfs USB parent
  carries that serial (the cameras' by-serial precedent; the by-id symlink is fine too — the lab
  adapter is `usb-FTDI_USB__-__Serial_Converter_FTAKROCJ-if00-port0`). The reader never enables
  torque and never writes a goal (GELLO stays passive). At connect it reads the FTDI
  `latency_timer` from sysfs and logs a WARNING when it is above 2 ms (the default 16 ms caps eight
  servos at ~30 Hz; the udev rule of §9.3 sets 1 ms).
- **Sample.** `GelloSample(q_raw[7] rad, q[7] rad = sign·(raw − offset), gripper_frac ∈ [0,1] |
  None, rx_mono, seq, valid)`; ticks → rad as `ticks · 2π / 4096`; `valid = False` when any joint
  jumped more than `max_jump_rad` (0.5) since the previous sample (a dropped byte / wrong id never
  becomes a target) or when the calibration is missing. `status(now)`: `no_backend | starting |
  connected | stale | error` with `detail`, `age_s`, `rate_hz`, `port`, `baud`.
- **Calibration.** `joint_signs` (config, operator-owned once set; default all `+1`) and
  `joint_offsets_rad` (config value or `var/gello_calibration.json`, written by
  `POST /api/gello/calibrate {op: "match_arm"}`: `offset_j = round((raw_j − sign_j·q_arm_j) / (π/2)) · π/2`
  where `q_arm` is the Manipulation Arm's current joints — the monitor sample on hardware, the
  parked sim posture in sim). `gripper_open_rad` / `gripper_closed_rad` come from
  `{op: "gripper_open"}` / `{op: "gripper_closed"}` (raw reading at the two endpoints);
  `gripper_frac = clip((raw − closed) / (open − closed), 0, 1)` and `None` until both exist.
  `{op: "clear"}` deletes the file. The result of every op is echoed in `GET /api/gello`.
- **Fake backend** (tests, sim): publishes a scripted posture at `poll_hz`; default = the
  `mavis_v2` keyframe of the Manipulation Arm (`[π, 0, 0, 0, 0, 0, 0]`, gripper 1.0) so a sim GELLO
  session launches already synced; `reader.fake_set(q, gripper)` moves it (LiveServer tests reach it
  through `srv.runtime.gello`). The fake needs no calibration file.
- **Owned by `Runtime`** for the process lifetime (`Runtime.__init__` / `stop`), started iff
  `backend != none`; status in `telemetry.gello` (device half) and `GET /api/gello` before any
  session.

## 5. Session lifecycle

### 5.1 Validation (`SessionManager.create`, before any side effect)

In order: the existing rail-homing guard → `_validate` (sim) / `_validate_hardware` (hardware;
`gello` admitted, D8) → `_check_gello(spec)`:

1. `spec.gello` non-null (core validator already enforces it), `spec.arms` == both arms (the
   Perception Arm must be in the session — it is the viewpoint), scene = `spec.sim_scene` /
   `digital_twin_scene` **or, when the client leaves it out, `gello.scene_id` (the kitchen) for
   BOTH kinds — the same default the session-less preview uses; the resolved id is written into
   the spec at `create()` so the check, the bring-up twin and the announce all see one scene**
   (2026-09-09 review; the UI sends `mavis_v2_kitchen`; any scene with both arms is accepted).
2. Leader: `GelloReader.status` `connected`, sample fresh (`age ≤ stale_s`), `valid`, calibrated →
   else `409 GELLO leader not available (<status/detail>)`.
3. `q_goal["grip"] = unwrap(sample.q, q_meas_grip)` (§6.2) + the measured rail; joint limits
   (the driver's table less 0.5°) → `409 GELLO posture outside the Manipulation Arm's joint limits
   (joint N = x.xx rad, limit ±y.yy)`. `q_goal["view"] = gello.view_posture_rad + [gello.view_rail_m]`.
4. Twin check on the kitchen scene (`DigitalTwin.check_config_violations` at the full goal, other
   arm at its goal) → `409 GELLO posture collides: <a> / <b> at <mm> mm[, …] - move GELLO and
   retry` (all pairs, tightest first).
5. `viewpoint == "external"` → the hub must hold a fresh compatible spec (§7) →
   `409 no external viewpoint node attached (…)` / `409 viewpoint node action_names … != view
   layout …`.

### 5.2 Bring-up and the start motion

Sim: the twin is built on the kitchen scene as today; the gate is `NullGate` unless
`safety.safety_debug` (unchanged). Hardware: `connect_hardware_rig` with the kitchen twin scene and
`tracker=False` (D9: the Vive cannot reach the Manipulation Arm in this mode) — the rig is
unchanged otherwise. The loop is `GelloLoop` (§6).

Then the start motion, replacing `start_from` for this mode (`start_from` must be `keep_current`;
409 otherwise): `PlanRequest(q_start = measured, q_goal = §5.1 goals, speed_scale)` on the session
twin, `arm_order` from the planner, executed by `_start_from_worker` → `_execute_arms` one arm at a
time with the usual `plan_gate_hold_s` cancellation, `start_from_fault_grace_s` retry and
`motion_detail` reporting (`start_from_progress`, `plan_status` on the wire as today). A plan
failure (`no_escape`, `timeout`) leaves the arms where they are, the session RUNNING, GELLO
`out_of_sync`, and the reason in `session.fault_detail` — the Cockpit's SESSION banner. During the
motion the GELLO state is `motion`; on arrival the engage rule (§6.1) runs once: within tolerance →
`tracking`, else `out_of_sync` with the per-joint deltas in telemetry.

### 5.3 In-session motions and teardown

`R` (`reset_to_initial`), `goto_profile` and the End-session return (`POST /api/session/return_home`)
keep their targets (the kind's initial-condition profile / the chosen profile) and their two-phase,
one-arm-at-a-time execution. In gello mode each one first forces `paused` (the follower stops
following before the plan is submitted) and leaves the state `paused` afterwards; the operator
presses **Resume** to re-engage (tolerance rule). `teardown()` produces no motion (unchanged).

### 5.4 Preview (`POST /api/gello/preview`, session-less)

Body `GelloPreviewRequest {kind, scene?: str, speed_scale?: float}`. Result
`GelloPreviewResult {status: clear | collision | joint_limit | no_leader | not_calibrated |
no_workcell | scene_error, ok: bool, detail, pairs: [{a, b, dist_m}], q_goal: {grip: [8], view: [8]},
leader_q: [7] | null, image_png_b64: str | null, camera: "cam_kitchen"}`. The runtime keeps one
kitchen `DigitalTwin` per (kind, scene) for previews (built lazily, like `_preview_scene_cache`),
poses the Perception Arm at the hold posture and the Manipulation Arm at the leader posture with the
CURRENT rail (the monitor sample on hardware — a FRESH one from a connected monitor, else status
`no_workcell`; in sim the launched scene's KEYFRAME, what `SimWorkcell.start` resets to — the
"parked pose" was the pre-implementation wording, §15.2 item 4), runs the joint-limit and
`check_config_violations` checks of §5.1, and renders `cam_kitchen` on a dedicated EGL renderer
thread with the colliding bodies' geoms tinted red (`geom_matid = -1`, `geom_rgba` on a private
model copy — plain `geom_rgba` is ignored while a material is assigned) and the inflation pads
hidden. The endpoint is cheap (~30 ms) and the sheet polls it at 2 Hz while open; it never moves
anything and works with no session and no viewpoint node.

## 6. `GelloLoop`

`apollo_mavis_v2_runtime/gello/loop.py`, a `ControlLoop` subclass (the `GatedPolicyExecutor`
pattern) with `_resolve_arms`:

```
grip:  stopped → hold | plan active → _plan_step | else → _gello_step
view:  stopped → hold | plan active → _plan_step | viewpoint fresh → _viewpoint_step | else hold
```

`active_arm` is pinned to `grip`; `switch_arm` / `switch_arm_prev` nack `"GELLO drives the
Manipulation Arm; the Perception Arm follows the viewpoint node"`; `takeover*`, `handback`,
`train_now`, the episode actions and `joint_target` nack with a mode reason; `tracker_settings` is
unaffected. One `CommandSource.GELLO` (new enum member) is reported for a GELLO-driven tick.

### 6.1 Engagement (`gello/engage.py`)

State `GelloState = no_leader | out_of_sync | tracking | paused | motion`, evaluated every tick:

- sample missing / stale (`age > stale_s`) / `valid == False` → `no_leader`;
- a plan owns the arm (`plans.active("grip")`) → `motion`; when it retires → run the engage rule;
- `paused` stays until `gello_resume`; the loop enters `paused` on `gello_pause`, on every
  `FaultEvent` / RECOVERING of the Manipulation Arm (the RECOVERING exit needs "no live input" — a
  paused GELLO is exactly that), and before every planned motion (§5.3);
- engage rule: `max_j |unwrap(q_leader)_j − q_meas_j| ≤ engage_tol_rad` (0.10) → `tracking`, else
  `out_of_sync` (per-joint deltas published);
- while `tracking`: `max_j |q_leader_j − q_cmd_j| > leash_rad` (0.80) → `out_of_sync` (the gate held
  the follower or the operator outran the 0.6 rad/s cap; the follower holds instead of chasing);
  re-engagement from `out_of_sync` is automatic once the rule passes again.

Every hold is "hold the last command" (the loop's `None` resolution re-servos `_last_cmd`), never a
move.

### 6.2 `_gello_step` (tracking only)

`q = q_last.copy(); q[:7] = clip(unwrap(sample.q), joint_lo, joint_hi); q[7] = rail slot integrated
from _rail_rate(self.sources)` (←/→ from every source at that source's scale, ±`teleop.rail_mps`,
clamped to [0, 0.65]) — `held_to_twist` is never called for the translate / rotate / gripper keys,
so they cannot act on the Manipulation Arm; `_hold_key_target` is inert (no `_key_twist`). The
result passes `_cap_joint_step` (uniform scaling: 0.006 rad/tick and the 4 mm lever-weighted bound
on hardware — a fast leader is followed at the cap, never jumped to) and the gate exactly like every
other source. In sim `SimArm` has no servo slew of its own, so `GelloLoop` lowers `dq_max_rad` to
`gello.max_joint_vel_rad_s / loop_hz × speed_scale` (0.6 rad/s → 0.006 rad/tick at 100 %) there
too; a sim proof-of-motion therefore has the hardware's lag and feel. Gripper: `_grip_frac["grip"] = round(sample.gripper_frac /
gripper_quantum) · gripper_quantum` (0.01) sent through `ArmSender.put_gripper` every
`GRIPPER_SEND_EVERY_N_TICKS` ticks (the policy path's cadence; G2 defaults 50 % force / 150 mm/s);
`_gripper_step` is skipped for `grip`. Unwrap: for joints 1, 3, 5, 7 pick `k ∈ {−1, 0, 1}`
minimising `|q_leader + 2πk − q_ref|` with `q_ref` = the measured joint at engagement, then keep
`k` while tracking (continuity); joints 2, 4, 6 are clipped to their limits.

### 6.3 `_viewpoint_step`

The view arm's block comes from the `ViewpointSource` (§7): `runner.latest()` (None / NaN / stale
→ hold), `split_action` over `arms_meta = [("view", True)]`, `ActionAnchor.apply_delta` (measured ⊕
Δ → IK, `SlewLimits`), rail delta, gripper dim ignored (no gripper), then the cap and the gate —
the Online DAgger path with the Manipulation Arm removed from the layout. NaN three-strike pauses
the source until the operator's Resume (there is no episode boundary in gello).

### 6.4 Health line and telemetry

`_health_log` adds ` gello=<state> age=<ms> lag=<rad>` next to the tracker segment;
`session_extra["gello"]` carries the session half of `GelloTelemetry` (§8.3).

## 7. Viewpoint source (`gello/viewpoint.py`)

`ViewpointSource(hub, publisher, session_id, frames["view"], rate_hz default, cfg.dora.policy)`:

- Every tick `poll(now)`: `ann = hub.spec(now)`; if attached and compatible (`action_space ==
  "delta_ee"`, `action_frame == frames["view"]`, `list(action_names) == arm_action_names("view",
  True, "delta_ee")`, `state_names ⊆ view state layout`) and no source is live → build
  `ExternalPolicySource(hub, publisher, session_id, spec, policy_id, arms_meta=[("view", True)],
  rate_hz=ann.rate_hz or dagger.policy_rate_hz, chunk_dt_s, cfg)` and `start()` (publishes
  `policy_reset{session_start}`); if the spec is stale (`> spec_stale_s`) or incompatible and a
  source is live → `stop()` (`policy_reset{session_stop}`) and hold. Incompatible specs are logged
  once per policy_id and shown in the panel (`viewpoint.detail`).
- The source attaches only while the session is RUNNING and no plan owns the Perception Arm:
  during BRINGUP / START_FROM (the launch motion) the announce already flows and `obs_state` is
  published, but `poll()` does not start an `ExternalPolicySource`, so nothing a node sends is
  counted late or advances a watermark; the first attach happens after the arm has reached its hold
  posture (the node sees `policy_reset{session_start}` then). A planned motion in-session (`R`,
  Go to profile, the exit return) detaches the source for its duration the same way.
- `latest()` / `staleness_scale()` forward to the live source or return None / 0.
- `viewpoint == "hold"`: the object is never polled (the announce still says `external_arms: []`).
- Announce (`_session_facts`): `external_arms = ["view"]` (`auto` / `external`) or `[]` (`hold`);
  `action_names` / `state_names` for the view block only; `action_space = "delta_ee"`;
  `arm_ids` still lists both arms (obs_state carries both arms' state). `SnapshotPublisher`
  publishes `obs_state` when `mode in ("dagger", "inference", "gello")`.
- `ExternalStatus` (telemetry.external) is unchanged; `GelloTelemetry.viewpoint` adds
  `{mode, attached, policy_id, detail}`.

Wire changes (core `protocol/external.py`, additive): `SessionAnnounce.external_arms: list[str] =
[]` appended after `online_dagger` (meaning "the arms this session accepts `policy_action` for;
empty = every session arm, today's behaviour"). Both contract goldens (runtime + policy-node) move
together; `EVENT_KINDS`, `RUNTIME_INPUTS`, `POLICY_OUTPUTS` are unchanged; `MAVIS_SCHEMA` stays 1.

## 8. Core models and wire

### 8.1 Session

```python
Mode = Literal["teleop", "collect", "dagger", "inference", "gello"]

class GelloSessionConfig(BaseModel):            # extra="forbid"
    viewpoint: Literal["auto", "external", "hold"] = "auto"

class SessionSpec(BaseModel):
    ...
    gello: GelloSessionConfig | None = None      # appended last
```

Cross-field rules added to `_cross_field`: `mode == "gello"` requires `gello is not None`,
`start_from == "keep_current"`, `task is None`, `dataset is None`, `policy is None`,
`online_dagger is None`, `policy_source == "checkpoint"` (the default), default `return_to_start`
and `action_filter`; `gello` non-null on any other mode is an error. `SessionInfo.gello:
GelloSessionConfig | None` echoes it (appended; the pinned field set in `test_protocol.py` grows).

### 8.2 Actions and sources

`ActionName` appends `"gello_pause"`, `"gello_resume"` after `goto_profile` (no args, no key; the
order asserts in `test_protocol.py` move to the new last name). `CommandSource` appends
`GELLO = "gello"` (rides gate events, the health line and the generated UI union; datasets are
unaffected in v1 — gello does not record).

### 8.3 Telemetry

```python
class GelloViewpointTelemetry(BaseModel):
    mode: Literal["auto", "external", "hold"]
    attached: bool
    policy_id: str | None = None
    detail: str = ""

class GelloTelemetry(BaseModel):                # TelemetryMsg.gello, appended last
    backend: Literal["dynamixel", "fake", "none"]
    status: Literal["no_backend", "starting", "connected", "stale", "error"]
    detail: str = ""
    port: str = ""
    baud: int | None = None
    seq: int = 0
    rate_hz: float = 0.0
    age_s: float | None = None
    q_raw: list[float] | None = None            # rad, before signs / offsets
    q: list[float] | None = None                # rad, mapped
    gripper_frac: float | None = None
    calibrated: bool = False
    joint_offsets_rad: list[float] | None = None
    joint_signs: list[int]
    # session half (None without a gello session)
    state: Literal["no_leader", "out_of_sync", "tracking", "paused", "motion"] | None = None
    state_detail: str = ""
    lag_rad: list[float] | None = None          # unwrap(leader) - measured, per joint
    max_lag_rad: float | None = None
    engaged_arm: str | None = None              # "grip" while tracking
    viewpoint: GelloViewpointTelemetry | None = None
```

### 8.4 REST models (exported schemas)

`GelloInfo` (`GET /api/gello`: the device half of `GelloTelemetry` plus `scene_id`, `scene_label`,
`view_posture_rad`, `view_rail_m`, `calibration_path`, `hardware_admitted: bool`),
`GelloCalibrateRequest {op: match_arm | gripper_open | gripper_closed | clear, kind}`,
`GelloCalibrateResult {ok, detail, joint_offsets_rad, gripper_open_rad, gripper_closed_rad}`,
`GelloPreviewRequest`, `GelloPreviewResult` (§5.4), `GelloPairInfo {a, b, dist_m}`. All in
`EXPORTED_MODELS`; `export_schemas --check` and the UI's `gen:check` follow.

## 9. Configuration, REST, deployment

### 9.1 `RuntimeConfig.gello: GelloConfig`

```yaml
gello:
  backend: none                 # none | fake | dynamixel  (repo default none; lab render dynamixel)
  port: /dev/ttyUSB0
  usb_serial: null              # e.g. FTAKROCJ -> resolve the ttyUSB node by sysfs USB serial
  baud: null                    # null = scan 57600 / 1M / 2M / 3M / 4M
  joint_ids: [1, 2, 3, 4, 5, 6, 7]
  gripper_id: 8                 # null = no gripper channel
  joint_signs: [1, 1, 1, 1, 1, 1, 1]        # operator-owned once set
  joint_offsets_rad: null       # null = var/gello_calibration.json (POST /api/gello/calibrate)
  poll_hz: 100.0
  stale_s: 0.2
  max_jump_rad: 0.5
  engage_tol_rad: 0.10
  leash_rad: 0.80
  gripper_quantum: 0.01
  max_joint_vel_rad_s: 0.6      # the follower's cap in SIM too (hardware already has it in ServoLimits)
  view_posture_rad: [2.646, -1.598, 0.018, 1.637, 0.25, 2.007, 0.029]
  view_rail_m: 0.0
  scene_id: mavis_v2_kitchen    # the twin the GELLO card launches (sim and hardware)
  calibration_path: ${APOLLO_HOME}/var/gello_calibration.json
twin_overlay:
  scene: null                   # null = the hardware workcell's digital_twin_scene; the lab render
                                #   may set mavis_v2_kitchen so *_align shows the appliances
```

`tests/test_configs.py` pins the shipped defaults (`backend: none`, `scene_id: mavis_v2_kitchen`).

### 9.2 REST

| route | purpose |
|---|---|
| `GET /api/gello` | `GelloInfo` (session-less) |
| `POST /api/gello/calibrate` | `GelloCalibrateRequest → GelloCalibrateResult`; 409 while a session runs or no leader sample |
| `POST /api/gello/preview` | `GelloPreviewRequest → GelloPreviewResult`; never 409 for a bad posture (the status says) |
| `POST /api/session` | 409 order for `gello`: existing guards → `GELLO leader not available` → joint limits → `GELLO posture collides` → viewpoint node (only `external`) |

### 9.3 Deployment (`docs/deploy/DEPLOYMENT.md`, scripts)

- udev: `SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6014", MODE="0660",
  GROUP="dialout", TAG+="uaccess"` and `latency_timer` 1 ms for the FTDI (`ACTION=="add",
  SUBSYSTEM=="usb-serial", DRIVER=="ftdi_sio", ATTR{latency_timer}="1"`) in the existing
  `60-apollo-teleop-input.rules` installer; the `mavis` account is already in `dialout`.
- Render knobs: `GELLO_BACKEND` (`dynamixel`), `GELLO_USB_SERIAL` (`FTAKROCJ`), `GELLO_BAUD`,
  `TWIN_OVERLAY_SCENE` (`mavis_v2_kitchen`); dev `local.env` mirrors them.
- Install: the ops sync gains `--extra gello` (`scripts/deploy/install-stack.sh`, DEPLOYMENT S3/S9)
  and `uv.lock` carries `dynamixel-sdk` / `pyserial`; without it the service has no serial driver
  and `GET /api/gello` reports `no_backend`.
- Exclusive owner: exactly one process opens the adapter (dev runtime vs service, like the dongle).
- Verification: `lsusb -d 0403:6014`, `ls -la /dev/serial/by-id/`, `curl :8765/api/gello`.

## 10. Sim: scene schema extensions and the kitchen scene

`EnvironmentSpec` gains `type: plane | box | mesh`, `mesh: str | None` (asset-relative STL/OBJ,
`scale`), `texture: str | None` (asset-relative PNG → `add_texture(2D, file)` + `add_material`
with `texuniform: false`), `collidable: bool = True` (False → `contype = conaffinity = 0`, group 1 —
never a monitored pair) and `group: int | None`. The builder sets `spec.texturedir = asset_path()`
beside `meshdir`; textures are FILES only (`spec.to_xml()` refuses buffer textures and the XML is
persisted with every episode). `SceneDescriptor` gains `graspable: tuple[str, ...] = ()` (world
geom names a session may whitelist against a gripper; validated at build), echoed on `SceneMeta`.

Assets: `assets/textures/tagStandard41h12_{00000,00001,00003,00004}.png` (704×704, 64 px per bit,
one white bit of margin, from the AprilRobotics `apriltag-imgs` 9×9 masters); `ASSET_MANIFEST.json`
regenerated.

`assets/scenes/mavis_v2_kitchen.yaml`: `id: mavis_v2_kitchen`, `hidden: true`, `suitable_for:
[sim, twin]`, the `mavis_v2` arms / cameras / table / obstacle / allowed_pairs copied verbatim (a
sim test asserts those blocks equal `mavis_v2`'s, so the cell geometry has one authority), plus the
§3 boxes, the four tag plates, `cam_kitchen` (an operator-side camera framing the fridge front and
the Manipulation Arm for the preview), `graspable` (D7), and the keyframe with the Perception Arm at
the GELLO hold posture (`view: [0.0, 2.646, -1.598, 0.018, 1.637, 0.25, 2.007, 0.029]`, MJCF order
rail first) and the Manipulation Arm at the `mavis_v2` keyframe. The twin audit must pass at
δ = 0.008 and 0.025 with the mic on and off (`test_mavis_v2_kitchen.py`, parametrised like
`test_mavis_v2.py`).

Overlays: appliance geoms are world geoms, so the `*_align` renderers draw their outlines with no
overlay code change; the overlay scene becomes `twin_overlay.scene or hw.digital_twin_scene`.

## 11. UI

- **Card.** `Mode` / `MODES` gain `gello` (fifth position); `MODE_LABELS.gello = "GELLO
  Manipulation"`, description "GELLO leader arm drives the Manipulation Arm in joint space; the
  Perception Arm follows an external viewpoint node or holds its GELLO posture. Kitchen twin."; a
  new glyph; `.launcher-grid` becomes five columns (three under 1000 px); route `#/gello`, page
  wrapper, session loader.
- **`GelloSheet`** (own sheet, the `OnlineDaggerSheet` shape, 640 px): (1) leader status from
  `GET /api/gello` (port, baud, rate, calibrated, raw / mapped joints; **Calibrate** = `match_arm`
  with a one-line instruction "pose GELLO like the Manipulation Arm, then click"; gripper open /
  closed buttons); (2) viewpoint choice (`auto` default / `external` / `hold`) with the external
  node's status chip; (3) the preview: `POST /api/gello/preview` every 500 ms while the sheet is
  open — the PNG, the verdict line ("clear" / "collides: fridge_body ↔ grip_link6 at 3 mm" /
  "joint 1 beyond limit"), the per-joint leader vs arm table; **Start** is enabled only on `clear`
  and posts `buildSpec("gello", sel)` = `{mode: gello, kind, arms: [both], frames, sim_scene |
  digital_twin_scene: <gello scene_id>, speed_scale, start_from: keep_current, gello: {viewpoint}}`;
  a 409 shows in the sheet and polling continues. Hardware tab: the card is enabled under the same
  readiness rules as teleop (every arm reachable, rails homed).
- **Cockpit (gello).** Title "GELLO Manipulation"; the ArmIndicator rows are disabled with the
  reason (no arm switching); `GelloPanel` in the side column: state chip (`TRACKING` green /
  `OUT OF SYNC` amber with the per-joint Δ bars / `PAUSED` grey / `NO LEADER` red / `MOTION`), the
  **Pause** / **Resume** buttons, leader age / rate, gripper fraction, the viewpoint row
  (`external node <id> attached` / `holding the GELLO posture` / `waiting for a node`), and the
  usual Go to profile / R hints. `KeymapOverlay` in gello mode shows only the rail, session and
  the `R` rows plus a caption "GELLO drives the Manipulation Arm's joints and gripper; ←/→ move its
  rail; the Perception Arm follows the viewpoint node." (no translate-frame caption).
  `EpisodeControls` and `JointPanel` are absent.
- **Clearance readout (§0 item 6).** See §12.4.

## 12. Cross-cutting notes

### 12.1 Safety

The gate is unchanged and mode-independent: every GELLO tick is checked on the kitchen twin at the
commanded configuration of both arms; the appliance boxes are ordinary environment geoms (monitored
pairs grow from 288 / 310 (mic off / on) to 540 / 571 with the kitchen — nine collidable boxes ×
the arm geoms; the 25 Hz sweep and the tick budget are unaffected at ~1 µs per pair, ~0.6 ms per
tick). GELLO adds three host-side guards the driver does not have: the per-sample jump
rejection (§4), the engage tolerance and the leash (§6.1). The threat-model row (11-safety §2):
**T11 leader glitch / mis-calibration** — a wrong sign or offset makes the follower sweep toward a
wrong posture at the cap; mitigations: the launch check on the twin, the engage tolerance (the arm
never starts following from far away), the leash, the operator's Pause, and the gate.

### 12.2 Recording

Not in v1 (teleop-like). Reserved for later: `CommandSource.GELLO` already exists so an
`action_source` label can be appended; the `joint` action space of 10-frames §6 fits the leader.

### 12.3 What the viewpoint node sees

The same `session` / `obs_state` / `cam_*` / `arm_state` streams as a dagger session, with
`spec.mode == "gello"`, `external_arms == ["view"]`, `action_names` for the view block only; it
answers `obs_state` with `Float32[K*8]` delta_ee rows for the Perception Arm (14-dora §6 rules for
metadata, watermark and staleness apply verbatim). The skill / policy-node contract copy documents
the field.

### 12.4 The clearance list

Diagnosis: both ends already cap the list at five pairs (`SafetySupervisor` keeps `sweep[:5]`,
`ClearanceReadout` slices `k = 5`), so the row COUNT never grows. What grows is row HEIGHT — pair
labels such as `grip_right_finger_pad_2 ↔ view_d435_mount` wrap to two or three lines in the 320 px
column, and the readout sits ABOVE the episode buttons in a flex column with no height bound, so
five wrapped rows push New episode / Save / Discard off the screen. Fix (UI only): the readout is
capped at **four** rows (`k = 4`, a `CLEARANCE_ROWS` constant), each row is one line (label
ellipsised, chip fixed), the panel has `max-height` with its own scroll, and `EpisodeControls`
renders ABOVE the readout in collect / dagger so the buttons never depend on it. 05-ui §8.2 and
11-safety §13 change from "k = 5" to "k = 4 of the runtime's five".

## 13. Tests

- core: Mode / validators / new actions / telemetry block / exported schemas (`--check`), the
  `SessionInfo` field-set pin and the ActionName order pins updated.
- sim: `test_mavis_v2_kitchen.py` (audit at 0.008 / 0.025, mic on / off; the cell blocks equal
  `mavis_v2`; `graspable` labels resolve; tag plates are not monitored; the four tags DETECT on a
  render from `view_wrist_cam` at the hold posture with ids 0/1/3/4 and centres within 25 px of
  the real detections stored in the test data — `pupil-apriltags` in the sim dev group, `egl`
  marked); descriptor tests for `mesh` / `texture` / `collidable`; `ASSET_MANIFEST` regenerated;
  `test_registry.py` still lists only `mavis_v2`.
- runtime: `GelloReader` unit tests (fake backend; an injected fake `dynamixel_sdk` module for the
  real backend's parsing, baud scan and jump rejection; import confinement AST test; missing module
  → `no_backend`); `engage.py` unit tests (state machine, unwrap, tolerance, leash); calibration op
  math; `GelloLoop` tick tests over `FakeWorkcell` (rail keys move only the rail slot, translate
  keys do nothing, cap applies, gripper cadence, pause / resume, fault → paused); manager tests
  (409 matrix incl. collision text, plan → sequential execution → engage; `keep_current` only;
  hardware admission with `HardwareFakeWorkcell`); REST contract (`/api/gello*`, preview status
  matrix, PNG present); sim e2e `test_e2e_gello.py` (LiveServer on the kitchen scene, fake leader:
  launch synced, `fake_set` moves the follower at the cap, ←/→ moves only the rail, an
  out-of-reach posture 409s with the fridge pair, `R` forces paused); dora e2e
  `tests/dora_bridge/test_e2e_gello_viewpoint.py` (the fake policy WITHOUT `--action-frame` derives
  `arm_base:view` from the announce's `external_arms` in a Manipulation-Arm-first spec and drives
  the Perception Arm, the Manipulation Arm's joints stay on the leader, `kill9` → hold within
  0.45 s + 1 tick, announce carries `external_arms == ["view"]`); goldens updated in both repos.
- ui: vitest for `GelloSheet`, `GelloPanel`, the fifth card (Landing / streams tests updated),
  `buildSpec("gello")`, `KeymapOverlay` gello filter, the clearance readout (four rows, order).
- Hardware acceptance (operator present): §16 of `docs/prompts/phase-15-gello.md`.

## 14. Deltas per repo (summary)

| repo | delta |
|---|---|
| core | `Mode` + `GelloSessionConfig` + validators; `gello_pause` / `gello_resume`; `CommandSource.GELLO`; `GelloTelemetry` block; REST models; `SessionAnnounce.external_arms`; schemas regenerated |
| sim | `EnvironmentSpec` mesh / texture / collidable / group, `graspable`; textured builder; `mavis_v2_kitchen.yaml`; tag PNGs; manifest; tests |
| runtime | `devices/gello.py`; `gello/{engage,loop,viewpoint,preview,calibration}.py`; `GelloConfig`; manager gello path (validation, plan, sequential execution, engage, pause on motions, hardware admission); viewpoint-scoped external source + announce + obs gate; REST routes; telemetry; overlay scene override; configs; tests |
| ui | fifth card, route, `GelloSheet`, `GelloPanel`, Cockpit / KeymapOverlay gello branches, clearance readout fix, generated types |
| policy-node | contract golden + `contract.md` mention of `external_arms` (byte-identical goldens) |
| docs | this file; phase-15; 00-overview §4/§5/§8/§10; 01-core; 03-sim §4; 04-runtime §5/§6/§13/§14; 05-ui §3/§8; 11-safety §2/§13; 14-dora §4/§5; DEPLOYMENT; README status; CLAUDE.md |

## 15. Implementation record (2026-09-09, phase-15; uncommitted in the five trees + the policy-node repo)

### 15.1 As shipped, per repo

- **core** — `Mode += "gello"`; `GelloSessionConfig` (`viewpoint`, `extra="forbid"`); `SessionSpec.gello` /
  `SessionInfo.gello` appended last with the §8.1 rules (gello-specific 422 texts evaluated before the
  generic mode rules); `ActionName += gello_pause, gello_resume`; `CommandSource.GELLO`; new leaf module
  `protocol/gello.py` (literals, `GelloDeviceTelemetry` base, REST models); `GelloTelemetry` /
  `GelloViewpointTelemetry`; `TelemetryMsg.gello` last; `SessionAnnounce.external_arms` last.
  48 exported models / 50 schema files, `--check` clean. Tests 482 (was 464).
- **sim** — `EnvironmentSpec` `mesh | texture | scale | collidable | group` (+ `size` optional, forbidden
  for meshes), `SceneDescriptor.graspable` → `SceneMeta.graspable` (validated); builder `texturedir`,
  file textures + materials (`tex_<path>` / `_mat`, `texuniform false`), meshes, `collidable: false` →
  `contype = conaffinity = 0`, group 1; the XML round-trips. `assets/textures/tagStandard41h12_0000{0,1,3,4}.png`
  (704 px, BSD-2 upstream); `mavis_v2_kitchen.yaml` (hidden, cell blocks verbatim from `mavis_v2`, nine
  boxes, four plates, `cam_kitchen` at (−0.15, 1.0, 2.0) fovy 60, `graspable`, keyframe view = hold
  posture); manifest regenerated. Audit clean at 0.008 / 0.025, mic on / off (540 / 571 monitored pairs).
  Tests 213 + 1 skip (was 155).
- **runtime** — `devices/gello.py` (`GelloReader`, backends none / fake / dynamixel, GroupSyncRead @132,
  baud scan, port by USB serial, jump rejection, latency-timer warning, never writes a register — AST-
  pinned), `gello/{calibration,engage,loop,viewpoint,preview}.py`, `GelloConfig` + `TwinOverlayConfig.scene`
  (both shipped configs carry the block, `backend: none`), `RuntimeBus.gello`, `GelloLoop` (rail-only key
  path, trigger gripper on the send cadence with change detection, viewpoint step, pause / resume /
  motion window, nacks, fault → paused, health-line segment, `session_extra["gello"]`), `ViewpointSource`
  (compatibility against the view-only layout, lazy attach only while RUNNING and no plan owns the arm),
  `GelloPreviewService` (cached kitchen twin per (kind, scene) WITH the grasp whitelist, dedicated EGL
  render thread, red tint via `geom_matid = -1`), the manager's gello path (`_check_gello` 409 matrix,
  `loop_factory` + `tracker=False` rig, launch plan executed one arm at a time inside the loop's motion
  window, plan failure → RUNNING + `out_of_sync` + `fault_detail`, R / goto / return force `paused`,
  D8 admission text `hardware sessions support teleop, data collection and GELLO Manipulation only
  (<mode> on hardware: not yet)`), `_session_facts` (`external_arms`, view-only layout), `obs_state` in
  gello mode, REST `GET /api/gello`, `POST /api/gello/calibrate`, `POST /api/gello/preview`, goldens, the
  `[gello]` extra (dynamixel-sdk 4.0.5, pyserial 3.5). Non-dora suite 849 passed / 2 skipped / 4 failed
  (§15.3) before the review; after the §15.5 fixes 860 passed / 2 skipped / 2 failed (the two
  pre-existing return-fuzz planner-timeout failures only; 14:05) and `test_e2e_gello_viewpoint`
  passes alone (11 s, no dora leftovers). Tests after the review: device 22, engage 13, calibration 3,
  REST 13, loop 17, session 7, sim e2e 3, dora e2e 1.
- **ui** — fifth card, `#/gello`, `GelloSheet` (Leader / Viewpoint / Start posture; `GET /api/gello` 1 Hz,
  preview 2 Hz; Start only on `clear`), `GelloPanel` + `GelloBanner`, Cockpit gello branch (inert arm
  rows, no joint panel / episode controls), `KeymapOverlay` gello filter + caption, §12.4 readout
  (`CLEARANCE_ROWS = 4`, one-line rows, scroll, `EpisodeControls` above), generated types. 47 files /
  476 tests (was 44 / 436); lint, gen:check, prettier, build clean.
- **policy-node** — `contract.SESSION_ANNOUNCE_FIELDS += external_arms`, golden byte-identical to the
  runtime's (sha256 `b0336d2f…`, 3719 B), skill `contract.md` mirrored; after the review the frame rule
  of §15.2 item 18 in `fake.py` / `node.py`. 142 non-dora tests (was 141).
- **workspace** — docs 00 / 01 / 03 / 04 / 05 / 10 / 11 / 14 amended, DEPLOYMENT S0 / S2 / S3 / S4 / S5 /
  S7 / S8.1c / S8.2 / S10 / S11, README status row 15, `install-stack.sh --extra gello`, udev rule +
  `latency_timer` in `01-sudo-udev-and-deps.sh`, render knobs `GELLO_BACKEND / GELLO_USB_SERIAL /
  GELLO_BAUD / TWIN_OVERLAY_SCENE` (`render-lab-config.sh`, `mavis-dev.sh`).

### 15.2 Deviations from v1.0 and why (code wins)

1. §8.3 flat `GelloTelemetry` → `GelloTelemetry(GelloDeviceTelemetry)` with `GelloInfo` sharing the base
   (identical wire shape; one source for the device half). `GelloInfo` gained `gripper_open_rad /
   gripper_closed_rad` (the calibrate ops need an echo). `GelloPreviewResult` validates `ok == (status ==
   "clear")`. `GelloCalibrateRequest.kind` / `GelloPreviewRequest.kind` are required.
2. §5.2 "on completion call `engage.on_motion_end`" → the manager brackets the launch / return sequence
   with the internal bus command `gello_motion {active, reason}` and the loop evaluates the engage rule
   on the first tick after the window closes; the window also spans the gap between two arms' plans and
   between the joints / carriage phases (a bare `plans.active()` check would have engaged mid-sequence).
3. §5.4 "never 409" → 409 only when no workcell of the requested kind is configured; a hardware kind
   without a monitor sample is status `no_workcell`; a scene lacking an arm is `scene_error`.
4. §5.1 sim reference posture = the launched scene's KEYFRAME (what `SimWorkcell.start` resets to),
   not the parked pose.
5. §7 "state_names for the view block only" holds for the ANNOUNCE (what compatibility is checked
   against); the `obs_state` METADATA names the actual two-arm vector so it stays self-describing.
6. §6.1 / D9: the rail keys integrate the Manipulation Arm's rail slot in EVERY GELLO state (nothing in
   the contract pauses the rail); `R` / goto pause the follower once the base op ACCEPTED (a refused
   request changes nothing — the 2026-09-09 review replaced the earlier "pause first, undo on a nack",
   item 13); the gripper target is sent on the cadence only when the quantised value differs from the
   value IN FORCE (`_grip_frac` as left by the last send, a profile's gripper or a re-seed; item 12).
7. §4: the FAKE backend applies no calibration (q == q_raw, always valid, no jump check) so a stale real
   calibration on the lab box can never bend the sim leader; `{op: clear}` needs no fresh sample.
8. `tests/test_chokepoint.py` whitelists `tools/axis_purity_measure.py` (an offline sim measurement tool
   committed 2026-09-09 that had been failing the guard on HEAD).
9. `recorder/features.py` `ACTION_SOURCE_LABELS` gained `"5": "gello"` (reserved; 10-frames §7.3).
10. The sim AprilTag detection test renders 2× supersampled and mic OFF for the four-tag assertion (edge-
    on side plates are ~10 px wide at 640×480 and MuJoCo's isotropic mipmaps blur them; the twin's mic
    body hides tag 4 although the real frame shows no occlusion — the mic geometry of 03-sim §4.3 is
    now visibly wrong against a fixed landmark); the native render must still decode ids 1 and 3, the
    mic-on render ids 0 / 1 / 3. Centre errors vs the real frame: 0.3–0.7 px.

Items 11–19 come from the adversarial review of 2026-09-09 (§15.5):

11. §6.2 / D3 unwrap is **limit-aware**: among `k ∈ {−1, 0, 1}` a branch whose unwrapped value lies
    outside the margined joint limits is dropped whenever another lies inside; the nearest survivor
    wins, ties keep `k = 0` (`unwrap_to_reference(limits=…)`, shared by `evaluate()`, the engage rule
    and the lag). Example: arm J1 = 3.5 rad, GELLO 0.3 rad → 0.3 (k = 0), not the 6.58 rad the pure
    nearest rule produced and the joint-limit check then refused.
12. §6.2 sim caps: `GelloLoop` lowers `jog.slew_rad_per_tick` to the same 0.006 rad as `dq_max_rad`
    BEFORE `ControlLoop.__init__` builds the `PlanExecutor` (`sim_gello_caps`, the hardware pairing of
    `apply_teleop_caps` / `apply_executor_caps`), so planned segments are walked in equal ticks at the
    cap and every waypoint is reached before the next segment starts; the rail slew is untouched. The
    gripper comparison is against the value in force (item 6).
13. §6.1 / §5.3: `gello_resume` is nacked `planned motion in progress - Resume after it ends` while the
    manager's motion window is open or an executor plan owns the follower (`gello_pause` stays accepted
    and latches); `R` / `goto_profile` pause only after the base op accepted.
14. §4: `GelloSample.jump` beside `valid` (`valid == calibrated and not jump`);
    `GelloReader.fresh_sample(now, *, require_calibrated=True)` — the calibrate ops (`match_arm`,
    `gripper_open`, `gripper_closed`) read `require_calibrated=False` (a stale or jump-flagged sample
    still 409s), so the first calibration of a real leader is possible; `_check_gello` / the preview
    keep refusing uncalibrated leaders. The baud scan pings the CONFIGURED ids one by one (~40 ms each)
    instead of the SDK's 0.8–1.4 s busy-polling broadcast, checks the stop flag before every rate and
    every ping (`GelloBusError('stopped during the baud scan')`, also after `resolve_port`), and
    `stop()`'s join budget covers a whole worst-case scan (`scan_budget_s`).
15. §5.4 / §4 hardware kind: the preview and `match_arm` use the monitor sample only while
    `status_of(arm)` is in `CONNECTED_STATUSES` AND the sample is younger than
    `hardware_monitor.stale_s`; otherwise `no fresh monitor sample of the Manipulation Arm (monitor
    <status>: <detail>)` → preview status `no_workcell`, `match_arm` 409 (the hardware monitor never
    clears its last sample, so a lost box used to yield a stale `clear`).
16. §5.1 item 1: the session scene defaults to `gello.scene_id` for both kinds (the spec is normalised
    at `create()`), matching the preview.
17. §7 / §8.3 wire additions (core, appended last): `GelloViewpointTelemetry.paused: bool = False` (with
    `detail` = `paused after 3 NaN actions - press Resume` while paused; `poll()` does not overwrite it)
    and `GelloTelemetry.paused_latched: bool | None` (the engage machine's pause latch, True inside a
    motion window too). A detach drops the viewpoint pause and the loop's NaN count, so a restarted
    node starts clean; the health line prints `viewpoint=paused(<n> NaN)`.
18. §7 / 14-dora §5 rule for viewpoint nodes: when `external_arms` is non-empty the node's
    `action_frame` MUST be `frames[external_arms[0]]` and compatibility is judged against those arms
    only (a gello session announces the Manipulation Arm first); both reference nodes (`nodes/
    fake_policy.py`, policy-node `fake.py` / `node.py`) and both `contract.md` copies say so; the dora
    e2e runs the UI's arm order without `--action-frame`.
19. §8.2: outside a gello session the base `ControlLoop` nacks `gello_pause` / `gello_resume` with
    `not a GELLO Manipulation session` (the `train_now` precedent), pinned in `test_server_contract`;
    the core comment and 01-core say the same.

### 15.3 Verified facts

- Sim smoke on a second runtime (port 8766, `gello.backend: fake`, 2026-09-09 09:27): `GET /api/gello`
  connected / calibrated / scene `mavis_v2_kitchen`; preview `clear` with a 66 kB PNG of `cam_kitchen`;
  `POST /api/gello/preview {kind: hardware}` → 409 `no hardware workcell is configured`; `POST /api/session`
  mode gello → RUNNING, `gello.state tracking`, lag 1e-10, viewpoint `no dora bridge (dora.enabled is
  false) - holding the GELLO posture`; calibrate during the session → 409; `gello_pause` → `paused`,
  again → `already paused`; `switch_arm` → nack `GELLO drives the Manipulation Arm; the Perception Arm
  follows the viewpoint node`; `episode_new` → nack; `gello_resume` → `resumed`; ArrowLeft held 3 s →
  rail 0.650 → 0.338 (0.104 m/s) with every joint unchanged; W / E / I / F held 1.5 s → no joint moved,
  the Perception Arm stayed at the hold posture; DELETE 204, no motion. (A `KeysMsg` without `ts` is
  silently dropped — the first smoke attempt's "rail did not move" was the client's fault.)
- The kitchen twin rendered from `view_wrist_cam` with the real intrinsics + nudge reproduces the four
  real tag detections to < 1 px (sim test data `tests/data/kitchen_tags_20260909.json`).
- Pre-existing failures, not from this work: `test_return_fuzz_mavis_v2[mic|nomic]` (3–4 honest RRT
  timeouts > 2 allowed on seeds 20260921 / 20260932 / 20360912, reproduced against a sim HEAD worktree
  and alone on the idle box — planner-speed / load, planner owner's call), and 2–3
  `test_e2e_reset_pinched_sim` timing flakes under full-suite load (pass alone).

### 15.4 Open items

- Nothing has run on the real arms; the GELLO servos never answered on 2026-09-09 (power?). First live
  run = phase-15 acceptance with the operator present, after `render` with `GELLO_BACKEND=dynamixel
  GELLO_USB_SERIAL=FTAKROCJ TWIN_OVERLAY_SCENE=mavis_v2_kitchen`, the udev rule, `uv sync --extra gello`
  and a runtime restart.
- The `*_align` overlays follow the config scene (§16 item 6); the appliance faces are ±3 cm until
  compared live.
- The twin's microphone body geometry (03-sim §4.3 open item) hides tag 4 where the real frame shows it.
- The `ArmSender` still drops a gripper value equal to the last one IT dispatched; a gripper moved
  behind the loop's back to exactly that value (a controller re-initialisation during a recovery) would
  not be re-commanded until the leader's trigger changes by one quantum (noted while fixing §15.5 item 2).

### 15.5 Review (2026-09-09)

An adversarial review of the shipped phase-15 trees confirmed 21 findings (five more were refuted); all
21 are fixed in the working trees (uncommitted). Runtime / policy-node / docs fixes in this pass, the UI
ones by the UI agent (05-ui). By title, with the fix in one line:

1. *Sim GelloLoop lowers dq_max below the PlanExecutor slew: planned motions cut every waypoint corner*
   — `sim_gello_caps` lowers `dq_max_rad` AND `jog.slew_rad_per_tick` before the executor is built;
   a two-waypoint plan test pins the corner (§15.2 item 12).
2. *Gripper stops following the leader after a profile gripper target* — `_gello_gripper` compares
   against the value in force (`_grip_frac`), not a private "last sent" copy; test extended with
   `_apply_gripper_target` + `reseed_arm` (item 12).
3. *gello_resume during a planned-motion window is accepted and pre-arms re-engagement* — nacked
   `planned motion in progress - Resume after it ends`; Pause still latches (item 13).
4. *Pre-pause on R / Go to profile is undone by resume()* — pause only after the base op accepted; a
   refused R leaves state, unwrap branch and transition count untouched (item 13).
5. *Hardware preview evaluates a stale monitor sample: says CLEAR while the launch will 409* —
   `Runtime._gello_monitor_sample` requires a connected status + age ≤ `hardware_monitor.stale_s`;
   preview `no_workcell`, `match_arm` 409 (item 15).
6. *Unwrap picks the nearest ±2π branch without regard to the joint limits* — limit-aware
   `unwrap_to_reference` (item 11).
7. *match_arm calibration is refused on every uncalibrated real leader (chicken-and-egg 409)* —
   `GelloSample.jump`, `fresh_sample(require_calibrated=False)` for the calibrate ops; REST test with
   the fake dynamixel SDK: uncalibrated → `match_arm` 200 → file → the next sample is valid (item 14).
8. *Baud scan ignores stop and busy-polls ~0.8–1.4 s per rate* — per-id pings, stop checks before
   every rate / ping / after `resolve_port`, `scan_budget_s` join floor; unit test: `stop()` returns
   within one ping (item 14).
9. *Reference viewpoint nodes derive action_frame from arm_ids[0]* — rule `action_frame ==
   frames[external_arms[0]]` in `fake_policy.py`, policy-node `fake.py` / `node.py`, both `contract.md`
   copies and 14-dora §5; the dora e2e uses `["grip", "view"]` without `--action-frame` (item 18).
10. *A NaN-paused viewpoint source is invisible in telemetry* — `GelloViewpointTelemetry.paused` +
    the paused detail, `GelloTelemetry.paused_latched`, reset on detach, health-line segment
    (item 17); the Cockpit half fixed by the UI agent — see 05-ui.
11. *14-dora §4.1 says obs_state `state_names` is the view block only in gello* — row reworded (the
    obs metadata names the FULL vector; the announced layout is what a node may DECLARE); one
    sentence added to both `contract.md` copies.
12. *Resume disabled while tracking makes a NaN-paused viewpoint unrecoverable from the UI* — fixed
    by the UI agent — see 05-ui.
13. *Pause is disabled during `motion` and its reason claims the motion 'ends paused'* — fixed by the
    UI agent — see 05-ui (the runtime now publishes `paused_latched` for it).
14. *Preview and info polls have no timeout and the verdict has no age* — fixed by the UI agent — see
    05-ui.
15. *GelloSheet's initial focus lands on 'Calibrate (match arm)'* — fixed by the UI agent — see 05-ui.
16. *Footer reason 'move GELLO and wait for the preview' is wrong advice for not_calibrated /
    no_workcell / scene_error* — fixed by the UI agent — see 05-ui.
17. *REASON.hardwareTeleopOnly still says 'teleop and data collection only' (D8)* — fixed by the UI
    agent — see 05-ui.
18. *Core comment claims gello_pause/gello_resume are nacked 'not a GELLO session' elsewhere* — base
    `ControlLoop` handlers nack `not a GELLO Manipulation session`; comment + 01-core aligned; pinned
    in `test_server_contract` (item 19).
19. *GelloPanel/05-ui claim a lost leader 'may hide a latent pause'* — fixed by the UI agent — see
    05-ui (the engage machine ranks paused ABOVE no_leader; §6.1 stands).
20. *GELLO session defaults to the bare cell twin while the preview defaults to the kitchen* —
    `_gello_scene_id` falls back to `gello.scene_id` for both kinds, the spec is normalised at
    `create()`; §5.1 item 1 states the default (item 16).
21. *16-gello §12.1 monitored-pair count is off by ~200 pairs* — §12.1 now reads 288 / 310 → 540 / 571
    (mic off / on); §5.4 says the sim reference posture is the launched scene's keyframe.

Verified after the fixes (2026-09-09): runtime `ruff` clean; the reviewer's quick set (16 files) 182
passed; the full non-dora suite 860 passed / 2 skipped / 2 failed (`test_return_fuzz_mavis_v2[mic|nomic]`,
pre-existing, §15.3) in 14:05; `tests/dora_bridge/test_e2e_gello_viewpoint.py` 1 passed alone with
`pgrep -x dora` empty before and after; policy-node 142 passed (non-dora); core `export_schemas --check`
clean (the two wire additions of item 17 were exported before this pass; the UI types were regenerated).

Refuted (no change): "§5.4 parked posture deviation unrecorded" (§15.2 item 4 records it — the §5.4
wording is now aligned anyway), the racy `stale` assertion in the fake-backend device test, the
"swallowed bracket failures" (a timed-out bus command is delayed, never dropped), the
`compatibility()` state_names subset rule (the documented contract), and the 11-safety §13 "k = 5"
sentence (already a dated history clause).

## 16. Open items for the operator

1. The GELLO build's servo model, ids, baud and joint signs — nothing answered on the bus on
   2026-09-09 (the adapter enumerated, no servo replied at any rate: most likely the servo power
   supply was off). The reader auto-scans the baud; the signs need one manual check per joint
   (the raw readout in the sheet).
2. Whether the kitchen twin should become the hardware workcell's default `digital_twin_scene`
   (every mode's gate would then know the fridge — the real fridge exists in every mode) or stay
   GELLO-only plus the overlay override. This document ships the second.
3. A key for Pause / Resume (`G` is free) — the keymap is operator-owned, so it is not added here.
4. Recording in GELLO mode (a collect-like variant) — out of scope, reserved.
5. The hinged fridge door in the twin (v2).
6. The `*_align` overlays follow the CONFIG scene (`twin_overlay.scene or digital_twin_scene`); a
   GELLO session's gate runs on the kitchen twin whatever the overlay shows. Making the overlay
   follow the session's twin scene (rebuild on session start / teardown) is v1.1; until then the lab
   render sets `TWIN_OVERLAY_SCENE=mavis_v2_kitchen` so both agree.
7. After a kitchen sim session ends, the Welcome previews (which render `wc.sim_scene`) drop the
   parked pose because the parked scene differs; they fall back to the keyframe. Cosmetic.
