# apollo-mavis-v2 — System Overview & Contract

Status: v0.3 (2026-09-01; renamed and re-scoped 2026-09-03). This document is
the **spine** of the stack: every other design doc and every sub-repo must stay
consistent with it. All major technology decisions are resolved against
`docs/research/` (several were benchmarked live on the target machine).

## 0. What MAVIS v2 is

**MAVIS v2** (Manipulation And Viewpoint Selection, version 2) is one physical
cell in the Apollo Lab (Yale): two UFACTORY xArm7 arms, each mounted on a
0.65 m linear track, on opposite rails of a shared tabletop. The **grip arm**
carries the xArm gripper and a wrist camera; the **view arm** carries only a
wrist camera and is the perception / viewpoint-selection arm. The software in
these repos exists for exactly this cell — real hardware or its MuJoCo digital
twin (`apollo-mavis-v2-sim` scene `mavis_v2`, the authoritative geometry, see
03-sim §4.3) — and is not a general xArm7 framework. Where the code is generic
(scene composition for 1–3 arms, per-arm rail auto-detection, camera-only arms)
that is an implementation convenience, not a product promise. The stack was
renamed from `apollo-xarm7-*` on 2026-09-03; package names follow
(`apollo_mavis_v2_*`).

## 1. Repos and dependency rules

```
                apollo-mavis-v2-core          interfaces, schemas, protocols, SE3 utils
                 /          \
apollo-mavis-v2-hardware    apollo-mavis-v2-sim   implementations of core interfaces
                 \          /
              apollo-mavis-v2-runtime          teleop / collect / DAgger / inference engine + server
                      |
                apollo-mavis-v2-ui             web frontend (React 18 + Vite + TS)
```

Hard rules:

- `core` depends on nothing in the stack (numpy + pydantic only; **no** MuJoCo,
  no xArm SDK, no FastAPI).
- `hardware` and `sim` depend only on `core`. They never import each other.
- `runtime` depends on `core`, with `hardware` and `sim` as optional extras
  (`pip install apollo-mavis-v2-runtime[hardware,sim]`). Hardware mode with
  digital-twin safety requires both extras; composition happens in runtime.
- `ui` never imports Python; it talks to runtime exclusively over HTTP/WebSocket.
- Python packages: `apollo_mavis_v2_core`, `apollo_mavis_v2_hardware`,
  `apollo_mavis_v2_sim`, `apollo_mavis_v2_runtime`. Python ≥3.10, managed with `uv`.

## 2. Process model

Single-process Python runtime by default:

- One process hosts: workcell (hardware or sim), 100 Hz control loop thread,
  per-camera capture threads, one dedicated MuJoCo render thread (EGL),
  episode recorder, digital twin + safety supervisor, FastAPI server
  (REST + WS + video).
- Separate processes only where isolation pays: the **DAgger training worker**
  (own GPU process — GPU 1 — communicating via dataset dir + checkpoint dir +
  a small control channel), and later, per-camera encoder subprocesses if GIL
  jitter appears.
- **Decision (2026-09-01): no Dora in v1** (see `docs/research/dora-middleware.md`):
  dora 1.0 requires Python ≥3.11 (we run 3.10), is still in RC with breaking wire
  changes, has no xArm/domain nodes to reuse, and lacks Python request/reply
  tooling. Migration seams are kept mechanical instead: messages are
  Arrow-representable core schemas, threads communicate via typed queues, and
  all commands flow through a `submit(cmd) -> Future` bus with correlation IDs.
  If GIL jitter shows up, first split cameras into a subprocess — the training
  worker is a separate process from day one.

## 3. Core domain model

### 3.1 Geometry & frames

- Internal units: **meters, radians**, quaternions `(w, x, y, z)` (MuJoCo
  order), poses as `Pose{position: vec3, orientation: quat}`; `Transform` = SE3.
  Conversion to xArm SDK units (mm, and deg where applicable) happens **only**
  inside `hardware`, exactly once at the driver boundary.
- End-effector frame: the TCP site (`link_tcp`, 0.172 m past link7 flange —
  matches the MJCF assets). The legacy xarm7-ik solver targets the *flange*
  with an implicit 180°-about-X offset; the compatibility mapping is specified
  in `10-frames-and-data.md` so old datasets/policies can be converted.
- Frame identifiers (`FrameRef`): `world`, `arm_base:<arm_id>`,
  `camera:<camera_id>`, `ee:<arm_id>`.
- `WorkcellConfig` declares the world frame and each arm's `base_in_world`
  transform (rail arms: the *rail origin* is fixed in world; base pose =
  rail origin ⊕ rail travel); camera extrinsics come from a calibration file
  referenced by config.
- **Recording frame choice is per-arm, per-session**: each recorded arm's
  observations/actions are expressed in `arm_base:<id>`, `world`, or
  `camera:<id>` — chosen independently for each arm at session setup and
  stored in dataset metadata (see §4.2 and `10-frames-and-data.md`).

### 3.2 Configuration (core)

```
WorkcellConfig
  kind: hardware | sim
  arms: [ArmConfig{ id, ip?, base_in_world, expect_rail: auto|yes|no,
                    gripper: xarm|xarm_g2|none }]
  cameras: [CameraConfig{ id, kind: v4l2|realsense|sim, device_path/serial,
                          intrinsics?, extrinsics_frame?, resolution, fps }]
  sim_scene?: scene id (sim mode)
  digital_twin_scene?: scene id (hardware mode — MJCF mirroring the real workcell)
  safety: { geom_inflation_m: 0.008 default, min_clearance_m, enabled: true }
```

Sim scenes and digital-twin scenes come from a **scene registry** in `sim`
(id → MJCF + metadata: #arms, rail flags, cameras). Scenes are composed at
runtime from a vendored menagerie `ufactory_xarm7` model (BSD-3) + a
`xarm7_on_rail.xml` child (rail meshes from mavis_mujoco, travel corrected to
0.65 m) using `mujoco.MjSpec.attach(child, prefix=f"{arm_id}_", frame=...)`;
the composed `spec.to_xml()` is persisted with every episode. 1–3 arms in both
modes; up to 4 cameras (3 wrist + 1 environment), typically 2.

### 3.3 Interfaces (in `apollo_mavis_v2_core.interfaces`)

- `ArmInterface` — per-arm driver facade: `connect/disconnect`,
  `get_state() -> ArmState` (joint pos/vel, rail pos, ee pose in base frame,
  gripper state, error flags), `command_joints(q)` (high-rate servo streaming),
  `command_gripper(GripperCommand)`, `command_rail(pos_m)` (0–0.65 m),
  `clear_errors()`, `stop()`; properties `dof` (7, or 8 with rail), `has_rail`,
  `gripper_force_capable`.
- `GripperCommand` — normalized `[0,1]` open fraction; optional force/effort
  field honored only by force-capable grippers (xArm G2). The classic xArm
  gripper is position-only (0–850 pulses ↔ 0–0.085 m); on firmware ≥2.7.100
  gripper current can be streamed into observations.
- `CameraInterface` — LeRobot-style Camera ABC: background capture thread,
  `start/stop`, `latest() -> CameraFrame{rgb, ts, id}`.
- `WorkcellInterface` — facade owning `arms: dict[str, ArmInterface]` and
  `cameras`; `kind` property; lifecycle. The sim workcell runs its own
  monotonic-clock-paced stepping thread (`data.ctrl` writes + `mj_step`) so
  runtime treats sim exactly like hardware.
- `IKSolver` — differential IK step: `solve(arm_id, target: Pose, q_seed) -> q`
  for 7-DoF and 8-DoF (rail) chains. **Primary implementation: mink QP
  differential IK** on the twin/sim model (measured ~8.6 kHz per arm on this
  machine): FrameTask on the TCP site + PostureTask (rail motion made
  expensive via per-joint weights) + ConfigurationLimit/VelocityLimit +
  `CollisionAvoidanceLimit` over self/cross-arm/environment geom pairs.
  Because velocity-level IK converges silently to the nearest reachable pose,
  the solver reports task residuals and runtime clamps/rejects diverging
  teleop targets. Four RelaxedIK ideas are ported into this layer:
  accel/jerk regularization over joint history, adaptive orientation-weight
  relaxation near obstacles, per-DoF flat-bottom tolerances, and a cap on
  active collision constraint rows per tick.
- `DigitalTwinInterface` — `sync(states)`, `check(q_by_arm) -> CollisionReport`,
  `clearance() -> per-pair distances` (`mj_geomDistance`),
  `plan(q_targets_by_arm) -> per-arm trajectories`, `render(view) -> frame`.
  Twin is kinematic-only (`mj_kinematics` + `mj_collision` per tick).
  **Inflation**: `geom_gap = δ` with `margin = 0` → detection-only contacts at
  inflated distance, no forces; pair thresholds are the SUM of both geoms'
  values (so per-geom gap = δ/2 for a δ total margin). Measured cost:
  0.24–0.75 ms/tick for 3 arms.
- `Policy` — `reset()`, `act(Observation) -> Action`, `load_weights(path)`
  (hot-reload at episode boundaries), spec metadata (obs/action layout +
  frame conventions + policy_version).
- `EpisodeRecorder` — `start/add_frame/save/discard`; backed by **LeRobot
  dataset v3** via the real `lerobot` library (`LeRobotDataset.create` /
  `add_frame` / `save_episode` / `clear_episode_buffer` / `finalize`,
  `streaming_encoding=True`, NVENC on the 4090s).
- `TeleopInput` — abstract held-key-state provider (implemented by runtime's
  WS bridge from the browser).

### 3.4 State profiles

A **StateProfile** captures a named workcell posture: per arm — joint config,
rail position, gripper opening — plus which arms it covers and free-form notes.

- Saved from teleop at any time; stored as versioned JSON under a profiles dir.
- One profile per workcell is **designated the initial condition**. Teleop UI
  offers "save current state as initial condition" (overwrite). Note: the xArm
  SDK's native `move_gohome()` target is factory-fixed and not overridable —
  irrelevant here, because the stack never calls native gohome/reset; "back to
  initial" always means a twin-planned motion to the designated
  initial-condition profile.
- Loadable at the start of teleop / collection / DAgger / inference. Every
  session declares `start_from: keep_current | profile:<id>` — either the arms
  stay exactly where they are, or a profile is loaded via planned safe motion.
- Loading never uses the xArm native reset: runtime asks the digital twin to
  **plan** a collision-free path (RRT-Connect in joint space over the composite
  model; per-arm sequential with the other arms as static obstacles when
  needed), validity-checked against inflated twin geoms, then executes
  waypoints through the same constrained differential IK / servo streaming.

## 4. Modes (runtime sessions)

All modes share: workcell bring-up → `start_from` resolution (keep current
state, or planned safe motion to a chosen profile) → control loop → teardown.
In hardware mode the safety gate (§6) is mode-independent — every command
tick in every mode passes through it, human- or policy-driven. In sim mode
the gate is off by default (collisions are harmless) and only enabled by the
`safety_debug` configuration for guardrail testing.
Active-arm selection: user picks the participating
arms; **Tab** cycles which one keyboard teleop drives; non-active arms hold.

1. **Teleop** — held-key state → twist in the arm's control frame →
   target-pose integration → collision-aware differential IK → per-tick
   clamped joint servo (≤ firmware step limits). Additionally, a **direct
   joint-control panel** in the UI: per-joint drag sliders and numeric entry
   (all 7 joints + rail) for reaching a specific configuration; small deltas
   stream through slew-limited joint servo, large jumps route through the twin
   planner — both stay behind the twin gate. Save profiles from here,
   including "set current state as initial condition".
2. **Data collection** — teleop + episode recording. Recording runs at
   20–30 fps while the 100 Hz servo loop interpolates. Every dataset (all
   modes) includes `intervention: bool`, `action_source: int8`,
   `wallclock_ns: int64` features so plain-teleop and DAgger datasets stay
   schema-compatible for merging. One dataset repo per
   (task × arm-count × frame convention); the convention is recorded in
   `features['action']['info']`.
3. **DAgger** — HG-DAgger semantics with async training
   (`12-dagger-protocol.md`): policy drives; **Space** toggles human takeover;
   3-state `control_mode` (`policy|human|takeover_transition`, transition
   frames excluded from labels); every frame stores `executed_action` +
   counterfactual `policy_action` + `policy_version`. AsyncTrainer (separate
   process, GPU 1) fine-tunes on human-labeled frames (50/50 new vs aggregate
   sampling), writes versioned checkpoints; runtime hot-swaps weights only at
   episode boundaries. Delta-EE actions applied to the current *measured* pose
   keep human↔policy switches jump-free.
4. **Inference** — policy drives; no recording (optional eval logging).
   **Space** still toggles human takeover (same TakeoverGate machinery as
   DAgger) as a *safety escape*: when the policy enters an unsafe state, the
   expert steers back to a safe configuration and then terminates, instead of
   blindly "returning to initial" and wrecking the scene. Inference-mode
   takeover is **never recorded** — no dataset exists in this mode, and the
   frames are not fed to DAgger aggregation.

## 5. Keybindings (canonical)

| Key | Gamepad | Action |
|---|---|---|
| W / S | — | translate +x / −x (forward/back) |
| A / D | — | translate left / right |
| E / Q | — | translate up / down |
| I / K | — | roll + / − |
| J / L | — | pitch + / − |
| U / O | — | yaw + / − |
| F / H | B / A | gripper close / open |
| ← / → | D-pad left / right | rail left / right (only if rail detected; 0–0.65 m) |
| C (hold) | RT (hold, ≥ 0.5) | tracker clutch — Vive tracker drives the EE while held (13-tracker §1) |
| Z | LB | switch to previous arm |
| Tab | RB | switch active arm |
| Space | — | takeover toggle (DAgger: recorded as intervention; inference: safety escape, never recorded) |
| N | — | start new episode (collect/DAgger) |
| Enter | — | save current episode |
| Backspace | — | discard current episode |

Note: the user's spec listed K for both roll and pitch; resolved as I/K = roll,
J/L = pitch (IJKL cluster). Teleop & collection pages must display a keybinding
hint overlay. Keymap is defined once in `core.protocol.keymap` and served to UI;
the **Gamepad** column is the `KeymapEntry.gamepad` field (13-tracker §3), so
the UI never hard-codes the pad mapping. The tracker clutch is a *held
modifier* (not an axis): the rail is never driven by the tracker.

## 6. Safety & collision (all modes, all command sources)

**Mode-independent invariant (hardware)**: in hardware mode the safety
machinery below is active in every mode — teleop, data collection, DAgger,
AND inference — and gates every command source: keyboard twist, joint-jog
panel, policy actions, DAgger takeover input, and planner trajectories. No
code path may send a command to a real arm without passing the gate.

**Sim mode**: the gate is **off by default** — collisions in sim are harmless
and the physics itself stops penetration; scene meshes/colliders constrain the
arm naturally. But the safety stack must be *testable* in sim: a
`safety_debug` configuration runs the full hardware-mode stack (twin instance
+ gate + IK collision limits) against a sim workcell playing the role of the
real robot, and `apollo-mavis-v2-sim` ships a guardrail debugging script that
deliberately drives arms onto environment-collision and arm↔arm
self-collision courses and asserts the gate clamps/blocks and emits
`CollisionEvent`s *before* contact. This doubles as the CI regression test
for the safety layer.

- The digital twin (kinematic MuJoCo scene mirroring the real workcell, geoms
  inflated per §3.3) runs in-process, synced from the 100 Hz report stream.
- Layered safety:
  1. **Twin gate (authoritative)**: every outgoing command tick is checked
     against the twin on the *commanded* configuration (arm↔arm +
     arm↔environment); violating commands are clamped/held and a
     `CollisionEvent` goes to the UI. The twin gate governs human AND policy
     actions equally.
  2. **IK-level avoidance**: `CollisionAvoidanceLimit` inequality constraints
     make teleop glide along obstacles rather than hit the gate.
  3. **Controller backstops** (per arm, via SDK): `set_collision_sensitivity`
     3–4, self-collision detection + correct tool model, reduced-mode TCP
     boundary, `set_tcp_load`.
  4. **Watchdogs**: stale-input deadman (~0.2 s) ramps twist to zero and
     requires an empty held-key set before resuming; servo stream re-seeds
     from `get_position` after any error recovery (controller silently drops
     to mode 0 on error — recovery is `clean_error → motion_enable →
     set_mode → set_state → re-seed`).
- Resets / profile loads / large motions go through the twin planner (§3.4);
  never xArm's native reset when arms are close.
- Sim teleop/inference use plain differential IK (posture + joint limits) with
  gate and collision-avoidance constraints disabled unless `safety_debug` is on.
- UI displays collision state prominently: imminent-collision warnings with
  the offending body pair, clearance readouts, blocked-command indicator.

## 7. Hardware bring-up (networking & discovery)

`netsetup` module in `hardware` (subprocess + `nmcli -t/-g`, `LC_ALL=C`,
UUID-addressed profiles):

- `verify/match`: read arm IPs from config, compute subnets, find-or-create
  manual-IPv4 profiles (`ipv4.never-default yes`, no gateway, ipv6 disabled),
  serially probe carrier-on ethernet NICs that are **not** the lowest-metric
  default-route device (internet NIC + non-ethernet devices are hard
  denylisted), confirm via interface-bound ping + TCP connect to port 502
  (xArm control port; 30001–30003 are report streams), persist
  `{arm → MAC, ifname, profile UUID}` to a JSON state file.
- `reconcile` (one-time): pin each matched profile to its NIC by MAC +
  interface-name, dedupe/disable stale profiles, strip gateway pollution.
  Never touches currently-active profiles carrying SDK traffic.
- One-time sudo install step: polkit `.pkla` grant (Ubuntu 22.04 = polkit
  0.105) + `netdev` group so the runtime works headless without sudo.
- "Ping OK but 502 refused" = arm still booting → poll, don't re-probe.
- After connect: **auto-detect rail presence** per arm via
  `get_linear_track_registers()` return code; select 7-DoF vs 8-DoF IK chain;
  rail homed once per power-on; rail commands are absolute int mm clamped to
  [0, 650], `wait=False`; measured rail position feeds the world TF and twin.
- UI landing page shows per-arm connectivity / rail / gripper capability.

## 8. Runtime ↔ UI protocol

Single FastAPI app, one port:

- REST under `/api`: workcell/config discovery, scene & digital-twin-scene
  registry, profiles CRUD, camera enumeration, session lifecycle
  (`POST /api/session {mode, arms, frames, scene, profile}`), episode ops.
- `/ws/control` — single-writer WS, hybrid key protocol: immediate held-key-set
  message on every key transition + 20–50 Hz full-state heartbeat with seq
  numbers; permessage-deflate disabled; server watchdog per §6.
- `/ws/telemetry` — 20–30 Hz broadcast: arm states, rail positions, active arm,
  collision report/clearances, episode & DAgger status, network/arm health.
- `/ws/video/{stream_id}` — binary JPEG frames (timestamp header), depth-1
  latest-frame slot per client. Real cameras, sim render, and digital-twin
  render are all uniform streams. `/video/{stream_id}.mjpg` MJPEG debug
  endpoints share the same encoded buffers. WebRTC and MuJoCo-WASM are
  explicitly out of scope for v1 (LAN, single viewer).
- MuJoCo rendering: server-side, one dedicated render thread owning
  `mujoco.Renderer` instances, `MUJOCO_GL=egl` (measured ~1600 FPS at 640×480
  on the 4090 — encoding, not rendering, is the bottleneck).
- Message schemas defined as pydantic models in `core.protocol`; TS types
  generated from their JSON schema.

UI pages: **Landing** (hardware/sim toggle, camera preview grid ×4, arm
selection + per-arm status, scene / digital-twin scene pickers, profile picker
+ `start_from` choice: keep current state vs load selected profile)
→ **Mode pages** (teleop / collect / DAgger / inference) with camera streams,
sim & twin renders, keybinding overlay, collision banner, episode controls.
Teleop page additionally has the direct joint-control panel (per-joint sliders
+ numeric entry + rail) and profile actions incl. "set as initial condition";
DAgger & inference pages show the takeover indicator (recorded vs
safety-escape semantics respectively).
Keyboard capture: explicit click-to-arm surface, `KeyboardEvent.code`,
repeat filtering, `preventDefault` on bound keys, release-all on
blur/visibilitychange.

## 9. Performance targets (validated on this machine)

- Teleop control loop 100 Hz (xArm mode-1 servo streaming; per-tick cartesian
  step well under 10 mm — firmware limit).
- IK step ~0.12 ms/arm (mink, measured); twin collision check 0.24–0.75 ms
  for 3 arms; total control-path budget <2 ms/tick.
- Policy inference at policy rate with interpolation up to servo rate.
- Video: 3–5 streams 640×480@30 to one local viewer (WS-JPEG).
- State WS to UI: 20–30 Hz (UI is never in the control path).
- Pin versions: MuJoCo (tested 3.12.0 — margin/gap semantics), mink 1.3.0,
  lerobot (v3 format churn), xArm-Python-SDK 1.18.5.

## 10. Design doc map

- `01-core.md` — core package layout, full interface & schema signatures.
- `02-hardware.md` — xArm driver, netsetup, discovery, cameras.
- `03-sim.md` — MuJoCo workcell, scene registry, digital twin, IK solvers, rendering.
- `04-runtime.md` — session engine, control loop, recorder, DAgger, server.
- `05-ui.md` — frontend structure, pages, streams, input capture.
- `10-frames-and-data.md` — frame conventions + dataset format.
- `11-safety-collision.md` — twin sync, checking, planning, inflation.
- `12-dagger-protocol.md` — takeover, aggregation, async training, hot-reload.
- `13-tracker-teleop.md` — Vive tracker/controller teleop (clutch model,
  controller buttons, pose filter) and the tracker calibration wizard
  (base stations + yaw, `/api/tracker/calibration`; phase-10).
