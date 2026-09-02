# 04 — apollo-xarm7-runtime (`apollo_xarm7_runtime`)

Status: v0.1 (2026-09-01). Conforms to `00-overview.md` (spine, v0.3) and mirrors
`05-ui.md` protocol shapes exactly. Research ground truth: `web-teleop-stack.md`,
`lerobot-data.md`, `dagger-online-training.md`, `xarm-python-sdk.md`.

## 1. Scope & dependencies

Runtime = session engine + server: composes a workcell (hardware or sim),
runs the 100 Hz control loop for all four modes (teleop / collect / DAgger /
inference), owns recording, safety supervision, the DAgger trainer process,
and the single FastAPI app (REST + WS + video + SPA) on **port 8765**.
Depends on `apollo_xarm7_core`; `hardware` and `sim` are optional extras
(hardware mode with twin safety needs both — the twin lives in `sim`).
Server deps: `fastapi`, `uvicorn[standard]`, `opencv-python`, `lerobot>=0.6`
(pinned), `numpy`, `pydantic`; trainer extra adds `torch`, `pyzmq`. Internal
units everywhere: **m / rad / wxyz quats** — mm/deg conversion happens only
inside `hardware`.

## 2. Package layout

```
src/apollo_xarm7_runtime/        # pyproject extras: [hardware] [sim] [trainer]
├── __main__.py                  # `python -m apollo_xarm7_runtime --config ...`
├── config.py                    # RuntimeConfig (§14)
├── runtime.py                   # Runtime: composition root, owns everything
├── bus.py                       # re-exports core.bus (Command, CommandBus, LatestSlot)
│                                #   + named-slot wiring (§4; core §15)
├── session/    manager.py (state machine §5), types.py (SessionState; SessionSpec/
│               SessionInfo imported from core.protocol.session, core §12)
├── control/    loop.py (ControlLoop 100 Hz §6), teleop.py (keys→twist→target),
│               joint_panel.py (jog/goto §7), arm_sender.py (per-arm senders §3),
│               snapshot.py (StateSnapshot + publisher)
├── safety/     gate.py (SafetyGate/NullGate §8), supervisor.py (twin gate §8),
│               watchdog.py (InputWatchdog + ArmReportWatchdog §8)
├── profiles/   store.py (core ProfileStore re-export + save_from_snapshot §9)
├── recorder/   episode_recorder.py (§10), features.py (schema builders §10.2)
├── dagger/     gate.py, loop.py (GatedPolicyExecutor/DaggerSession/InferenceSession),
│               policy_runner.py, recorder.py (DaggerRecorder), reloader.py, client.py,
│               trainer/ (AsyncTrainer process pkg — entrypoint
│               `python -m apollo_xarm7_runtime.dagger.trainer`) (§11; 12-dagger §1)
├── streams/    hub.py (VideoHub §13.4), render_source.py (sim/twin FrameSources)
└── server/     app.py, rest.py (§13.1), ws_control.py (§13.2),
                ws_telemetry.py (§13.3), ws_video.py (§13.4)
```

Protocol message models (`HelloMsg`, `KeysMsg`, `ActionMsg`, `AckMsg`,
`TelemetryMsg`, keymap) live in `apollo_xarm7_core.protocol` — runtime imports
them; it never redefines wire shapes.

## 3. Process & thread architecture

Single process, single uvicorn worker (one-operator appliance; in-memory
session state is singleton). Real-time work never runs on the event loop:

| Thread | Rate | Owns | Notes |
|---|---|---|---|
| asyncio event loop (main) | — | FastAPI, WS handlers, AckMsg routing | Only shuttles JSON/JPEG bytes |
| `ControlLoop` thread | 100 Hz | teleop pipeline, gate, snapshot publish | Budget <2 ms/tick: IK ~0.12 ms/arm + twin check 0.24–0.75 ms (3 arms), measured |
| `ArmSender` ×N (1/arm) | 100 Hz | blocking `ArmInterface.command_joints` | xArm SDK is sync TCP; a slow arm never stalls the tick — reads a depth-1 `LatestSlot[np.ndarray]` |
| camera capture ×M | cam fps | `CameraInterface` bg threads | Provided by hardware/sim packages |
| `RenderThread` | per-stream fps (≤30) | ALL `mujoco.Renderer` instances (sim + twin views) | runtime hosts sim's `RenderService` (03-sim §7), which paces each stream at its own fps — a fixed rate could not feed the 30 fps video streams; GL context thread-affinity; `MUJOCO_GL=egl`; ~0.6 ms/frame measured on the 4090 |
| `EncoderWorker` ×streams | stream fps | `cv2.imencode` JPEG q80 (1–3 ms/frame) | Encode-once; WS + MJPEG share the buffer |
| `RecorderThread` | 20–30 fps | the LeRobot dataset writer (single owner) | `add_frame`/`save_episode`; never touched from other threads |
| `PolicyRunner` | 10–30 Hz | policy `act()`, GPU 0 | DAgger/inference only (§11) |
| sim stepping thread | 500 Hz | `mj_step` (sim workcell) | Lives in `apollo_xarm7_sim`; runtime treats sim like hardware |
| **AsyncTrainer process** | — | GPU 1 fine-tuning | Separate process from day one (§11); crash-isolated |

Bridging rules: threads → asyncio only via
`loop.call_soon_threadsafe(event.set)` on latest-value slots; asyncio →
threads only via `CommandBus.submit` (§4). `ControlLoop` paces on
`time.monotonic()` absolute deadlines (`next_t += 0.01; sleep(max(0, next_t −
now))`); an overrun tick logs `tick_overrun` and skips catch-up (no burst
commands). Arm state comes from the drivers' report caches (hardware: 100 Hz
report socket 30003; sim: stepping thread) — no blocking query on the tick
path.

## 4. Command bus & typed queues

All discrete operations (ActionMsg dispatch, session lifecycle, profile ops)
flow through one bus with correlation IDs — the Dora migration seam
(overview §2).

```python
# bus.py — primitives are DEFINED in core.bus (core §15); runtime re-exports
# them and wires the named slots below. Shown for reference:
@dataclass(frozen=True)
class Command:
    op: str          # switch_arm | takeover_toggle | episode_{new,save,discard}
                     # | save_profile | set_initial_condition | joint_target | ...
    args: dict = field(default_factory=dict)
    corr_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    source: Literal["ws", "rest", "internal"] = "ws"

@dataclass(frozen=True)
class CommandResult:
    corr_id: str; ok: bool; detail: str = ""

class CommandBus:
    def submit(self, cmd: Command) -> Future[CommandResult]: ...
    # Producer: any thread / event loop. Consumer: ControlLoop drains the
    # internal queue.Queue at each tick boundary, runs handlers synchronously,
    # resolves the Future. Long ops (goto plans, profile loads) resolve
    # immediately ok=True detail="accepted"; progress goes via telemetry.

class LatestSlot(Generic[T]):
    """Depth-1 latest-value slot, lock-protected; the only inter-thread
    structure besides CommandBus. put() overwrites and stamps monotonic time;
    wait_fresh() blocks on a threading.Event."""
    def put(self, value: T) -> None: ...
    def get(self) -> tuple[T, float] | None: ...
    def wait_fresh(self, timeout: float) -> tuple[T, float] | None: ...
```

Named slots wired by `Runtime`: `held_keys: LatestSlot[HeldState]`
(WS → control), `q_cmd[arm_id]: LatestSlot[np.ndarray]` (control → senders),
`snapshot: LatestSlot[StateSnapshot]` (control → recorder / telemetry /
twin-sync), `policy_action: LatestSlot[PolicyOutput]` (policy runner →
control), `encoded[stream_id]: LatestSlot[bytes]` (encoders → WS/MJPEG).

## 5. Session state machine

One session at a time, owned by `SessionManager`. States (serialized into
telemetry as `session.state`):

```
IDLE ──POST /api/session──▶ BRINGUP ──▶ START_FROM ──▶ RUNNING ──▶ TEARDOWN ──▶ IDLE
                              │             │             │
                              └── error ────┴──▶ FAULT ◀──┘  (recoverable → RECOVERING → RUNNING)
```

```python
# session/types.py
class SessionState(str, Enum):
    IDLE = "idle"; BRINGUP = "bringup"; START_FROM = "start_from"
    RUNNING = "running"; RECOVERING = "recovering"; FAULT = "fault"
    TEARDOWN = "teardown"

class SessionSpec(BaseModel):         # pydantic, DEFINED in core.protocol.session
                                      # (core §12); runtime imports it. Shown for
                                      # reference (05-ui §4 mirrors it):
    mode: Literal["teleop", "collect", "dagger", "inference"]
    kind: Literal["hardware", "sim"]  # honored when that config is available
    arms: list[str]
    frames: dict[str, str]            # arm_id → FrameRef (recording frame, per-arm)
    sim_scene: str | None = None      # required when kind == "sim"
    digital_twin_scene: str | None = None   # required when kind == "hardware"
    start_from: str = "keep_current"  # "keep_current" | "profile:<id>"
    task: str | None = None           # dataset task string (collect/dagger)
    policy: str | None = None         # checkpoint id; None = latest (dagger only) /
                                      #   promoted deploy ckpt (inference; 409 if none
                                      #   promoted — 12-dagger §9)
```

Phase behavior (identical skeleton for all four modes; overview §4):

1. **BRINGUP** — instantiate the workcell for the requested `kind` (POST
   honors it iff that config exists, else 409); `connect()` arms, start
   camera threads, auto-detect rails; hardware: build the DigitalTwin from
   `digital_twin_scene`, apply controller backstops
   (`set_collision_sensitivity(3)`, self-collision model, `set_tcp_load`),
   set mode 1 + state 0 per arm, seed servo streams from `get_state()`; start
   Render/Encoder/Recorder/Policy threads as the mode requires. Composed
   twin/sim `spec.to_xml()` is persisted in the session dir.
2. **START_FROM** — `keep_current`: no motion, targets seed from measured
   state. `profile:<id>`: twin planner (`DigitalTwinInterface.plan`,
   RRT-Connect on inflated geoms, per-arm sequential with others as static
   obstacles) → waypoints through the normal gated servo path (§9). Never
   xArm native gohome. Progress → telemetry `session.start_from_progress`.
3. **RUNNING** — the mode loop (§6–§7, §10–§12). Modes differ only in action
   sources (human/policy), recorder on/off, and takeover semantics.
4. **TEARDOWN** (DELETE /api/session, fatal error, SIGTERM) — stop policy
   runner, zero-twist ramp, `recorder.finalize()` (§10.4), stop trainer
   process, stop encoders/renderer, `arm.stop()` + `disconnect()`; clients
   detect the released session via hello epoch/`session_id`.
5. **FAULT/RECOVERING** — per-arm SDK error recovery (§15). All arms hold
   while any arm recovers; resume requires an empty held-key set (§8).

## 6. Control loop — teleop pipeline

`ControlLoop.tick()` at 100 Hz, all modes (order fixed):

1. drain `CommandBus`; 2. read `held_keys` slot + watchdog check (§8);
3. read arm states from driver caches; 4. sync twin (`twin.sync(states)`);
5. compute per-arm action (teleop twist / jog / policy / plan waypoint);
6. integrate target pose + clamps; 7. `IKSolver.solve`; 8. safety gate check;
9. deposit `q_cmd[arm_id]`; 10. publish `StateSnapshot`.

```python
# control/teleop.py — HeldState is DEFINED in core.interfaces.teleop (core §5.2);
# runtime imports it. Produced by ws_control from KeysMsg:
@dataclass(frozen=True)
class HeldState:
    held: frozenset[str]    # KeyboardEvent.code values
    seq: int
    rx_mono: float          # server receive time (watchdog feed)

def held_to_twist(held: frozenset[str], keymap: Keymap, r: TeleopRates) -> Twist:
    ...  # Twist{v: vec3 m/s, w: vec3 rad/s, rail_v: float, grip_v: float}
    # TeleopRates defaults (§14): linear 0.12 m/s (WASD+EQ), angular 0.6 rad/s
    # (IK/JL/UO), rail 0.10 m/s (arrows), gripper 1.2 open-frac/s (F/H)
```

Per-arm teleop step (active arm only; non-active arms hold their last
commanded q — they are *not* re-servoed to measured state, avoiding drift):

- **Twist frame**: the arm's control frame = `arm_base:<id>` axes at the
  current TCP; translations along base axes, rotations about TCP axes. The
  recording frame (`SessionSpec.frames`) affects only dataset conversion
  (§10.3), never control math.
- **Target integration + leash**: `target ⟵ target ⊕ twist·dt`, then clamp to
  a leash around the *measured* EE pose: ≤ 0.025 m / ≤ 0.2 rad geodesic. The
  leash bounds IK divergence (mink converges silently to nearest-reachable)
  and keeps per-tick motion far under the firmware 10 mm/step mode-1 limit.
- **IK**: `q = ik.solve(arm_id, target, q_seed=last_cmd_q)` — mink QP with
  posture/limits/collision rows (hardware or safety_debug; plain
  posture+limits in sim), ~0.12 ms/arm measured. Task residual >
  `residual_max` (0.01 m / 0.1 rad) ⇒ freeze `target` back to the achieved
  pose (glide, don't wind up).
- **Per-tick joint clamp**: `|q_i − q_last_i| ≤ dq_max` (0.04 rad/tick ≈
  4 rad/s) before the gate; cartesian step stays < 2.5 mm at default rates.
- **Gate** (§8): `supervisor.filter(q_cmd, q_meas, source)`; violating arms
  hold last-safe (escape rule excepted) + `CollisionEvent` → telemetry.
- **Rail**: rail arms carry an 8th q slot; rail keys integrate a target
  clamped to [0, 0.65] m. Rail held-keys arrive for every arm; the loop
  ignores them when the active arm has no rail (binding decision). The
  hardware driver sends sparse absolute mm targets (`command_rail`; the track
  has no streaming interface); measured rail position feeds the twin.
- **Gripper**: F/H integrate `open_frac ∈ [0,1]` → `GripperCommand` at
  ≤ 10 Hz (modbus is slow; `wait=False`).
- **Tab / switch_arm**: server-authoritative — the Command cycles
  `active_arm` over `session.arms`; the previous arm's target freezes; the UI
  learns the new arm via telemetry only.

`StateSnapshot` (published every tick, consumed at lower rates):

```python
@dataclass(frozen=True)
class StateSnapshot:
    t_mono: float; wallclock_ns: int; tick: int
    arms: dict[str, ArmState]                 # measured (core schema)
    q_cmd: dict[str, np.ndarray]              # last commanded q (incl. rail)
    active_arm: str | None
    control_mode: dict[str, ControlMode]      # policy|human|takeover_transition
    executed_action: dict[str, np.ndarray]    # canonical recording frame (§10.3)
    policy_action: dict[str, np.ndarray] | None; policy_version: int | None
    gate: CollisionReport; clearances: list[tuple[tuple[str, str], float]]
    episode: EpisodeStatus | None; watchdog_tripped: bool
```

## 7. Direct joint-control path (jog / goto)

UI joint panel sends `ActionMsg {name: "joint_target", args: {arm_id,
positions, mode: "jog" | "goto"}}` — `positions` = the **full q including the
rail slot** (rad; rail slot m), length = arm `dof`; slider drags throttled
client-side to ~20 Hz. Both paths pass the hardware safety gate
(mode-independent invariant).

- **`jog`** (slider streaming): per-arm `jog_target`; each tick the loop
  slews commanded q toward it, `dq/tick ≤ jog_slew` (0.02 rad/tick; rail
  2 mm/tick), joint-space direct (no IK), then gate → `q_cmd`. New targets
  overwrite (LatestSlot). Jog with `max|Δq| > goto_threshold` (0.15 rad) ⇒
  Ack `ok=false` — the UI must send `goto`.
- **`goto`** (large jump / numeric entry): build a core `PlanRequest`
  (`q_start` = measured full q, `q_goal = {arm_id: positions}`; core §6) →
  `twin.plan(req) -> PlanResult` (per-arm sequential, 11-safety §9),
  validity-checked on inflated geoms, executed as a waypoint stream through
  the same slew-limited gated path (identical to profile loading §9). Ack =
  `"accepted"`; completion/failure via telemetry `session.plan_status`.
- While a goto plan runs on an arm, teleop twist/jog for it are ignored; any
  held movement key or `takeover_toggle` cancels the plan (decelerating stop
  over 0.2 s). `save_profile` / `set_initial_condition` work from this panel
  (§9).
- While `EpisodeStatus.state == "recording"`, every `joint_target` is nacked
  (`AckMsg{ok: false, detail: "recording"}`) — the UI also locks the panel
  (05-ui §8.3 / §12.7).

## 8. Safety supervisor & watchdogs

`SafetySupervisor` composes the twin gate + watchdogs. **Hardware: active in
all four modes for every command source** (keyboard, jog/goto, policy, DAgger
takeover, planner waypoints). **Sim: disabled unless `safety.safety_debug`**
— then the full hardware stack (twin instance + gate + IK collision rows)
runs against the sim workcell (overview §6).

```python
# safety/gate.py + safety/supervisor.py — shapes and semantics per 11-safety §7 (binding)
@dataclass
class GateDecision:
    q_out: dict[str, np.ndarray]   # what may be dispatched (cmd, held, or escape-limited)
    blocked: bool
    report: CollisionReport        # severity ok|warn|blocked, pairs, min_clearance_m
    events: list[CollisionEvent]   # transitions only (edge-triggered)

class SafetyGate:                  # state: _last_safe per arm, _blocked, _block_pairs
    def __init__(self, twin: DigitalTwinInterface, cfg: SafetyConfig): ...
    def filter(self, q_cmd: dict[str, np.ndarray], q_meas: dict[str, np.ndarray],
               source: CommandSource) -> GateDecision: ...

class SafetySupervisor:            # twin sync + gate + events + telemetry (11 §1)
    def __init__(self, gate: SafetyGate | NullGate, watchdog: InputWatchdog): ...
    def sync(self, states: dict[str, ArmState]) -> None: ...       # top of every tick
    def filter(self, q_cmd, q_meas, source) -> GateDecision: ...   # delegates to gate
    def publish(self, report, events) -> None: ...                 # telemetry + log
```

Gate algorithm — **hold-last-safe, exactly 11-safety §7.1** (per tick,
0.24–0.75 ms measured for 3 arms): stale twin ⇒ `q_out = _last_safe` +
`stale_twin`; else write the *commanded* q for ALL arms into the inflated
twin, `mj_kinematics` + `mj_collision`; violations use
`dist ≤ min_clearance_m` with `+hysteresis_m` while blocked (no chattering);
no violations ⇒ pass and update `_last_safe`; otherwise offending arms hold
`_last_safe` **unless the escape rule passes** (the command strictly opens
every violating pair by ≥1e-5 m and creates no new violation — T8);
non-offending arms keep `q_cmd`. **No segment bisection** (up to 3 extra
collision passes ≈ 2.3 ms worst case — over budget; L2 makes near-boundary
commands slide, so holds are rare and short). `_last_safe` re-seeds to
`q_meas` after error recovery (§15). Every 4th tick a `twin.clearance()`
sweep on the *measured* config feeds telemetry; `severity="warn"` when
`min_clearance_m < warn_clearance_m` (25 mm) while unblocked.

`InputWatchdog` (`safety/watchdog.py`) — states `OK → TRIPPED → AWAIT_EMPTY →
OK`:

- **Stale-input deadman**: `now − held.rx_mono > 0.2 s` (25 Hz heartbeat ⇒ 5
  missed beats) or control WS drop ⇒ TRIPPED: twist ramps to zero linearly
  over **0.1 s** (`SafetyConfig.input_ramp_s`; no hard stop — total stop
  ≤ 0.3 s incl. the 0.2 s deadman, 11-safety §14.3); gripper/rail targets
  freeze.
- **Empty-held-set-before-resume**: leaving TRIPPED requires a fresh KeysMsg
  with `held == []` (AWAIT_EMPTY) — never resume from a replayed held set.
- **Re-seed after recovery**: after SDK error recovery (§15) the servo stream
  and teleop `target` re-seed from `get_state()` before any command is sent;
  watchdog enters AWAIT_EMPTY.
- Applies to human inputs; `PolicyRunner` has its own staleness rule (§11,
  11-safety §10.2): interpolate toward the last action for ≤ 5 policy
  periods, then hold — never a ramp.

Controller backstops (bring-up, hardware only, beneath the authoritative twin
gate): collision sensitivity 3, self-collision detection + tool model,
`set_tcp_load`, optional reduced-mode TCP boundary from config.

## 9. State profiles

Core's `ProfileStore` (core §8 — versioned JSON under `cfg.profiles_dir`, one
file per profile: `<profile_id>.json`, `schema_version` field, atomic
write-tmp-then-rename; CRUD/atomicity live in `core.profiles.store`). Runtime
re-exports it and adds the thin `save_from_snapshot` wrapper:

```python
class StateProfile(BaseModel):        # core schema
    profile_id: str; name: str; notes: str = ""
    workcell_kind: Literal["hardware", "sim"]
    arms: dict[str, ArmPosture]       # ArmPosture{q: list[float] (7, rad),
                                      #   rail_pos_m: float | None,
                                      #   gripper_open_frac: float}
    created_at: str                   # ISO 8601
    is_initial_condition: bool = False  # exactly one per workcell kind

class ProfileStore:                   # core §8: list/get/save/delete/rename/
    ...                               #   set_initial/initial_for (imported)

# profiles/store.py — the runtime-side wrapper (core §19-3):
def save_from_snapshot(store: ProfileStore, snap: StateSnapshot, name: str,
                       notes: str = "") -> StateProfile: ...
```

Flows (available in every mode's RUNNING state; save/set-initial ride the
control WS as ActionMsg, management CRUD is REST §13.1):

- **Save** (`save_profile {name, notes?}`): snapshot measured q/rail/gripper
  for the session arms → `save_from_snapshot`; Ack carries `profile_id`.
- **Set as initial condition** (`set_initial_condition {profile_id?}`): no arg ⇒
  save current state first (name `"initial"`, overwrite) then flag it. Native
  `move_gohome` is never used (overview §3.4).
- **Load with planning** (START_FROM or mid-session reload): twin planner as
  §5.2; waypoints stream through the gated slew-limited path (§7 goto).
  Profile not covering the session arms → 409 / Ack false.

## 10. EpisodeRecorder (LeRobot v3)

### 10.1 Ownership & API

`RecorderThread` is the **single owner** of the `LeRobotDataset` writer (the
v3 writer is single-process/single-owner; reading while writing raises). All
other threads talk to it via its inbox (episode ops from CommandBus) and the
`snapshot` slot.

```python
# recorder/episode_recorder.py — implements core's EpisodeRecorder ABC (core §5.2)
class LeRobotEpisodeRecorder(EpisodeRecorder):
    def __init__(self, cfg: RecorderConfig, session: SessionSpec,
                 features: dict, dataset_root: Path): ...
    # open: LeRobotDataset.create(repo_id, fps=cfg.fps, features=features,
    #   root=..., robot_type=..., use_videos=True, streaming_encoding=True)
    #   — or LeRobotDataset.resume(repo_id, root=...) if the dir exists.
    def start(self, meta: dict[str, object]) -> None: ...   # opens buffer
        # (episode_new op; meta carries task etc.)
    def add_frame(self, frame: dict[str, object]) -> None: ...
        # frame dict built from StateSnapshot + camera images (§10.3)
    def save(self) -> int: ...          # ds.save_episode(); episode_index (episode_save op)
    def discard(self) -> None: ...      # ds.clear_episode_buffer() (episode_discard op)
    def finalize(self) -> None: ...     # MANDATORY (parquet footers)
```

Loop: paced at `cfg.fps` (default **25**, range 20–30) off the `snapshot`
slot; per frame pull `read_latest()` from each recorded camera (max_age
2/fps, else drop + count `frames_dropped`); `add_frame`. The 100 Hz control
loop is never recorded directly — it interpolates between recorded actions
(lerobot `interpolation_multiplier` pattern, here 100/fps = 4). Encoding:
`streaming_encoding=True`, `rgb_encoder.vcodec="auto"` → NVENC (`h264_nvenc`,
with `bf=0` for lerobot's `g=2`; resumed datasets keep their codec family —
10-frames §7.5) on the 4090s, so `save_episode()` is near-instant between
episodes.

### 10.2 Dataset schema (always, every mode that records)

One dataset repo per **(task × arm-count × frame convention)**; repo id
`apollo/xarm7_{task}_{n}arm_{conv}` (grammar: 10-frames §8.1) under
`cfg.datasets_root`. `robot_type` distinguishes real (`xarm7_{n}arm_rail`)
from sim (`xarm7_{n}arm_rail_mujoco`) — 10-frames §7.5.

```python
# Per-arm blocks. action_space literals are core's PolicySpec set —
# "delta_ee" | "abs_ee" | "joint" — with **delta_ee canonical** (required for
# new DAgger-intended policies, 12-dagger §6):
ARM_ACT = ["ee.dx", "ee.dy", "ee.dz", "ee.drx", "ee.dry", "ee.drz",
           "gripper.pos"]                    # + "rail.dpos" if rail (delta_ee layout)
ARM_OBS = ([f"joint{i}.pos" for i in range(1, 8)] + ["gripper.pos"]  # + "rail.pos" if rail
           + ["ee.x", "ee.y", "ee.z", "ee.qw", "ee.qx", "ee.qy", "ee.qz"])
           # 10-frames §6.1: state = joints, gripper, rail, then measured TCP pose
           # (ee.* in the arm's declared recording frame); 16/15 dims per arm
features = {
  "action": {"dtype": "float32", "shape": (D,), "names": per_arm_act_names,
             "info": {"apollo_schema": 1,
                      "action_space": "delta_ee",  # core literal; delta_ee canonical
                      "frames": {arm_id: frame_ref, ...},
                      "rail": {"axis": "y", "travel_m": 0.65, "arms": [...]}}},
  "observation.state": {"dtype": "float32", "shape": (D_obs,), "names": per_arm_obs_names,
                        "info": {"apollo_schema": 1, "frames": {...same map...}}},
  "observation.images.<cam>": {"dtype": "video", "shape": (480, 640, 3),
                               "names": ["height", "width", "channels"]},
  # always present so teleop & DAgger datasets merge (10-frames §7.3, binding):
  "intervention":  {"dtype": "bool",  "shape": (1,), "names": None},
  "action_source": {"dtype": "int8",  "shape": (1,), "names": None,
                    "info": {"labels": {"0": "policy", "1": "teleop", "2": "joint_jog",
                                        "3": "takeover", "4": "planner"}}},
                    # labels mirror core CommandSource (10-frames §7.3)
  "wallclock_ns":  {"dtype": "int64", "shape": (1,), "names": None},
}
# DAgger sessions add (12-dagger-protocol.md): control_mode (int8: 0 policy /
# 1 human / 2 takeover_transition), policy_action (float32 (D,)),
# policy_version (int32).
```

Plain teleop writes `intervention=False`, `action_source=1`. The five lerobot
bookkeeping features are auto-added — never put them in `add_frame` dicts.

### 10.3 Frame conversion at record time

Frame conversion applies to **EE-space quantities**: each arm's
`executed_action` block (`delta_ee` / `abs_ee`) AND the `ee.*` dims of
`observation.state` are converted into the arm's declared recording frame
(`SessionSpec.frames[arm_id]`: `arm_base:<id>` | `world` | `camera:<id>`)
**before** `add_frame` (per `10-frames-and-data.md` §3, §6.1).
Joint/gripper/rail dims — and whole `action_space == "joint"` blocks — are
frame-free (10-frames §3.4) and pass through unconverted. Frames are fixed per dataset (mixing frames in one
`action` feature is statistically toxic). Camera-frame choices snapshot the
extrinsics into episode metadata.

### 10.4 Crash-safe finalize

The recorder runs inside a `VideoEncodingManager`-style guard: TEARDOWN,
SIGINT/SIGTERM, and a `finally` in `RecorderThread.run` all call
`discard()` (if a buffer is open) then `finalize()` exactly once.
`finalize()` failures are logged and retried once; the session dir keeps
`recorder_state.json` `{repo_id, episodes_saved, finalized}` so an
unfinalized dataset is detected at next startup and repaired via `resume()` +
`finalize()`. Invalid transitions (`episode_save` while `saving`,
`episode_new` while `recording`) → Ack `ok=false`; the UI follows telemetry
`EpisodeStatus.state ∈ idle|recording|saving`.

## 11. DAgger orchestration

Components only — the wire protocol, aggregation rules, and trainer loop are
specified in `12-dagger-protocol.md`; runtime implements the core Protocols
(`TakeoverGate`, `PolicyReloader`, `AsyncTrainerClient` from
`apollo_xarm7_core.dagger.interfaces`).

- **`TakeoverGate`** (`dagger/gate.py`): **Space = discrete toggle**
  (ActionMsg `takeover_toggle`, once per press — not held), policy↔human;
  each switch emits `TAKEOVER_TRANSITION` for `T_blend = 0.3 s` of frames
  (recorded, excluded from labels). One gate for the active arm; non-active
  arms freeze their deltas when `dagger.pause_others_on_takeover` (default
  true). Gate events → telemetry `DaggerStatus.control_mode`.
- **`PolicyRunner`** (thread, GPU 0): builds `Observation` from the latest
  snapshot + camera frames at policy rate (10–30 Hz), calls `Policy.act`,
  converts output to per-arm **delta-EE anchored to the current measured
  pose** (hil-serl pattern — jump-free human↔policy switches), publishes
  `PolicyOutput{actions, version, t_mono}` to the `policy_action` slot. The
  control loop lerps/slerps policy targets up to 100 Hz through the same
  leash → IK → gate path as teleop. Stale output (`act()` past deadline =
  policy period + 50 ms): keep interpolating toward the last action for ≤ 5
  periods, then hold + telemetry flag (11-safety §10.2). Chunked policies
  (ACT/diffusion): on handback drop the stale chunk, re-query from the
  current observation, slew-limit the first 0.4 s.
- **Recording**: same recorder, schema §10.2 + DAgger columns. Every frame
  stores `executed_action` (training label when `control_mode == human`),
  counterfactual `policy_action`, `policy_version`. Human corrections are
  converted into the arm's canonical recording frame before both execution
  and recording (`RelativeFrame` rule). DAgger episodes append to a
  dedicated dataset; the seed dataset is never mutated.
- **`AsyncTrainerClient`**: trainer spawned as `python -m
  apollo_xarm7_runtime.dagger.trainer --config ...` with
  `CUDA_VISIBLE_DEVICES=1` (12-dagger §7). Transport = **filesystem +
  control channel**: checkpoints at `checkpoints/{run_id}/v{n:06d}/`
  (state_dict + preprocess stats + `CheckpointInfo` JSON with dataset
  watermark + `sanity_ok`); ZMQ REP control socket
  `tcp://127.0.0.1:${trainer_port}` (default **5757**) —
  `submit_episode(episode_path, EpisodeSummary)`, `poll_checkpoint`,
  `status` (polled 1 Hz, 2 s timeout), `request_stop`. Trainer crash
  (`proc.poll()` / 3 missed status replies) never touches motion — DAgger
  degrades to frozen-policy collection with a single auto-restart
  (`--resume`; 12-dagger §12); telemetry `trainer_alive=false`.
- **Hot-swap**: `PolicyReloader.stage(ckpt)` keeps newest staged; the mode
  loop calls `maybe_swap` **only at episode boundaries** (12-dagger §8 —
  never mid-episode, never mid-chunk), `load_state_dict` under the runner's
  lock; `rollback()` restores `last_known_good`.

## 12. Inference mode & safety-escape takeover

Inference = the DAgger loop with the **recorder OFF** and no trainer process:
same `PolicyRunner`, same gate machinery, same hardware safety invariant.

- **Space still toggles takeover** (same `TakeoverGate`) as the safety
  escape: the human's twist drives the active arm through the identical gated
  pipeline; steer to a safe configuration, then toggle back or end the
  session — never a blind "return to initial" (overview §4.4).
- **Never recorded**: no dataset exists; takeover frames are never fed to
  DAgger aggregation. Optional `inference.eval_log` writes JSONL of `{tick,
  wallclock_ns, control_mode, gate_severity, policy_version}` — scalars only.
- Episode ActionMsgs are rejected (`ok=false, detail="no recorder in
  inference"`); the UI hides episode rows by mode.

## 13. HTTP/WS surface

### 13.1 REST route table

All request/response models are pydantic in `core.protocol` (TS types are
generated from them — 05-ui §2). Errors: `{"detail": str}` with 4xx/5xx.

| Route | Req → Resp | Notes |
|---|---|---|
| `GET /api/health` | → `{status, epoch, version}` | liveness; `epoch` = process UUID |
| `GET /api/workcell` | → `WorkcellStatus{kind, available_kinds, arms: ArmStatusInfo[], cameras: CameraInfo[], policies_available: bool}` | per-arm connectivity/rail/gripper for the landing page |
| `GET /api/cameras` | → `CameraInfo[]` | merged v4l2 + RealSense + sim enumeration; `live` flag |
| `GET /api/scenes?kind=sim\|twin` | → `SceneInfo[]` | from the `sim` scene registry (id, #arms, rail flags, cameras) |
| `GET /api/keymap` | → `KeymapEntry[]` | canonical, from `core.protocol.keymap`; UI builds its bound-key set from it |
| `GET /api/profiles` | → `ProfileInfo[]` | incl. `is_initial_condition` |
| `GET /api/profiles/{id}` | → `StateProfile` | full posture |
| `PATCH /api/profiles/{id}` | `{name?, notes?}` → `ProfileInfo` | rename/annotate |
| `DELETE /api/profiles/{id}` | → 204 | 409 if it is the designated initial condition |
| `GET /api/policies` | → `PolicyInfo[]{policy_id, path, action_space, action_frame, policy_version, promoted}` | checkpoint registry for dagger/inference (core §12 model) |
| `GET /api/session` | → `SessionInfo` \| 404 | reconnect resync |
| `POST /api/session` | `SessionSpec` → `SessionInfo{session_id, epoch, mode, arms, streams, state}` | 409 if a session exists, requested `kind` unavailable, scene/arm mismatch, dagger without a policy, or inference with no promoted deploy checkpoint (`policy=None` resolves to latest for dagger, promoted deploy for inference — 12-dagger §9). Returns after BRINGUP; START_FROM progress via telemetry. `streams` = camera ids + `"sim"` and/or `"twin"` |
| `DELETE /api/session` | → 204 | TEARDOWN (idempotent) |
| `GET /api/episodes` | → `{repo_id, total_episodes, total_frames}` | current dataset counters (collect/dagger) |

**Not REST** (binding decision, 05-ui §4): episode new/save/discard, profile
save / set-as-initial, joint targets, switch_arm, takeover — all ride
`/ws/control` as `ActionMsg` and are answered by `AckMsg`.

### 13.2 `/ws/control`

Message shapes mirror 05-ui §2 (JSON; permessage-deflate disabled
server-wide, §13.5). ActionName is exactly the core §10 set (mirrored by
05-ui §2), incl. `set_initial_condition` and `joint_target`:

```jsonc
// server → client, immediately after accept:
{ "t": "hello", "epoch": "<uuid>", "session_id": "<id>|null",
  "role": "controller" | "observer" }
// client → controller only: on EVERY key transition + 25 Hz heartbeat
{ "t": "keys", "seq": 1042, "ts": 1756711234.123, "held": ["KeyW","KeyJ"] }
// client → server: discrete ops (keys AND UI buttons share this path)
{ "t": "action", "name": "switch_arm" }                      // no index — server cycles
{ "t": "action", "name": "takeover_toggle" }
{ "t": "action", "name": "episode_new" | "episode_save" | "episode_discard" }
{ "t": "action", "name": "save_profile", "args": {"name": "...", "notes": "..."} }
{ "t": "action", "name": "set_initial_condition", "args": {"profile_id": "..."} }
{ "t": "action", "name": "joint_target",
  "args": {"arm_id": "arm0", "positions": [/* full q incl. rail slot */],
           "mode": "jog" | "goto"} }
// server → client, per action:
{ "t": "ack", "name": "...", "ok": true, "detail": "" }
```

Handler rules (`server/ws_control.py`):

- **Single writer**: first connection = `controller`; later ones are accepted
  read-only as `observer` (never close-1008); observers' `keys`/`action` are
  ignored (`ok=false, detail="observer"`). Controller disconnect ⇒ zero-twist
  via the watchdog path + drop held state; the next connector becomes
  controller.
- `keys`: drop `seq <= last_seq`; else store `HeldState(frozenset(held), seq,
  monotonic())` into the `held_keys` slot. Rail codes are always accepted
  (control loop ignores them for rail-less arms). No motion work in handlers.
- `action`: wrap as `Command(op=name, args=args, source="ws")`,
  `bus.submit`, `await asyncio.wrap_future(fut)`, reply `AckMsg`; unknown
  name → `ok=false`.
- Watchdog feed = `HeldState.rx_mono` (§8); client `ts` is a latency metric
  only, never trusted for safety.

### 13.3 `/ws/telemetry`

Broadcast-only, N observers, **25 Hz** (config 20–30). An asyncio task reads
the `snapshot` slot, builds `TelemetryMsg` (shape exactly as 05-ui §2:
`t, seq, ts, epoch, active_arm, controller_connected, arms: ArmTelemetry[],
collision: CollisionReport, clearances, episode, dagger, inference`), and fans out with
per-client latest-wins: a slow consumer gets frames dropped, never
back-pressures control. Runtime-side additions inside the same message:
`session: {state, start_from_progress?, plan_status?, trainer_alive?}` —
additive, UI ignores unknown fields. `ee_pose` is m + **wxyz**;
`rail_pos_m: null` for rail-less arms; `dagger: null` outside DAgger;
`episode: null` in teleop/inference.

### 13.4 `/ws/video/{stream_id}` and MJPEG debug

`VideoHub` (`streams/hub.py`) — one pipeline per stream id:

```
FrameSource.read_latest() → EncoderWorker (cv2.imencode .jpg q80, own thread,
paced at stream fps) → encoded[stream_id]: LatestSlot[bytes(header+jpeg)]
   ├─ /ws/video/{id}: per-client asyncio sender, depth-1 latest-frame slot
   └─ /video/{id}.mjpg: StreamingResponse multipart/x-mixed-replace
```

- **Binary framing** (12-byte little-endian header, binding decision):
  `struct.pack("<dI", ts_seconds: f64, len(jpeg): u32) + jpeg`. Header built
  once in the encoder; WS and MJPEG share the encoded buffer (MJPEG strips
  the 12 bytes and wraps multipart) — encode-once, no double work.
- **Stream ids**: camera ids from config, plus reserved `"sim"` and `"twin"`
  (render-thread FrameSources; exist only during a session — connecting
  otherwise closes 1008). Unknown id → close 1008.
- **Pre-session previews**: real-camera streams are available with no
  session, encoded at **~15 fps** (landing-page grid); on session start the
  session's cameras switch to configured fps, on teardown back to 15.
- Sender: `await slot_fresh(); await ws.send_bytes(buf)` — a slow client
  skips frames (client also drops while a decode is in flight, 05-ui §5.4).
- 640×480@30 ⇒ 25–60 KB/frame, 6–15 Mbps/stream; encode 1–3 ms/frame
  (~0.36 core for 6×30) — measured envelope, no NVJPEG needed in v1.

### 13.5 SPA serving & server startup

```python
# server/app.py
def create_app(runtime: Runtime) -> FastAPI:
    app = FastAPI(lifespan=lifespan(runtime))   # lifespan: start/stop threads
    app.include_router(rest.router, prefix="/api")
    app.add_api_websocket_route("/ws/control", ws_control.endpoint)
    app.add_api_websocket_route("/ws/telemetry", ws_telemetry.endpoint)
    app.add_api_websocket_route("/ws/video/{stream_id}", ws_video.endpoint)
    app.add_api_route("/video/{stream_id}.mjpg", ws_video.mjpeg)
    ui_dist = runtime.cfg.ui_dist                # packaged or path from config
    if ui_dist and ui_dist.exists():             # mount LAST
        app.mount("/", StaticFiles(directory=ui_dist, html=True), name="spa")
    return app

# __main__.py
uvicorn.run(create_app(runtime), host=cfg.host, port=cfg.port,  # default 8765
            ws_per_message_deflate=False,        # 100 Hz control channel
            log_level="info")
```

SPA uses hash routing, so `StaticFiles(html=True)` deep-link 404s never
occur; dev mode runs Vite with a proxy to `http://localhost:8765` (05-ui
§1.1). `MUJOCO_GL=egl` is set in `__main__.py` before any mujoco import;
`MUJOCO_EGL_DEVICE_ID` from config (render on GPU 0; trainer owns GPU 1).

## 14. Configuration

`RuntimeConfig` (pydantic; YAML file via `--config path` or `APOLLO_CONFIG`
env; defaults sane for sim-only dev):

```yaml
host: 127.0.0.1
port: 8765
ui_dist: null                # path to built SPA; null = API-only (Vite dev)
workcells:                   # POST /api/session picks by requested kind
  hardware: { <WorkcellConfig, core §3.2>: arms/ips/base_in_world/cameras,
              digital_twin_scene, safety: {geom_inflation_m: 0.008,
              min_clearance_m: 0.016, enabled: true} }
  sim:      { <WorkcellConfig>: sim_scene, cameras (kind sim),
              safety: {safety_debug: false} }
profiles_dir: ~/apollo/profiles
datasets_root: ~/apollo/datasets
checkpoints_root: ~/apollo/checkpoints
control:
  rate_hz: 100
  teleop: {linear_mps: 0.12, angular_rps: 0.6, rail_mps: 0.10, gripper_frac_ps: 1.2}
  leash: {pos_m: 0.025, rot_rad: 0.2}
  dq_max_rad: 0.04           # per tick
  jog: {slew_rad_per_tick: 0.02, rail_m_per_tick: 0.002, goto_threshold_rad: 0.15}
  watchdog: {stale_s: 0.2, ramp_s: 0.1}   # = SafetyConfig input_deadman_s/input_ramp_s
recorder: {fps: 25, vcodec: auto, jpeg_quality: 80,
           extrinsics_warn: {pos_m: 0.003, rot_rad: 0.010},   # checkpoint-load
           extrinsics_max:  {pos_m: 0.010, rot_rad: 0.035}}   #   verify, 10-frames §5.3
telemetry_hz: 25
video: {preview_fps: 15, session_fps: 30}
dagger: {policy_hz: 15, t_blend_s: 0.3, pause_others_on_takeover: true,
         trainer: {gpu: 1, min_new_labels: 100, push_period_s: 5,   # 12-dagger §7
                   port: 5757}}                                     # tcp://127.0.0.1
egl_device_id: 0
```

Version pins carried by the workspace (overview §9): MuJoCo 3.12.0,
mink 1.3.0, lerobot ≥0.6 pinned, xArm-Python-SDK 1.18.5.

## 15. Error handling & recovery matrix

| Failure | Detection | Response |
|---|---|---|
| xArm controller error (C22 self-collision, C24 speed, C31 collision, C35 boundary…) | nonzero `error_code` in ArmState / command return code 1 | Arm → FAULT; stop sending; recovery worker: `clean_error → motion_enable(True) → set_mode(1) → set_state(0)`; **re-seed** servo target from `get_state()`; watchdog AWAIT_EMPTY; other arms hold |
| Command return 9 / −2 (state not ready) | per-command code | same recovery path (controller silently drops to mode 0 on error) |
| Rail comm loss (controller error 111) | error code | rail target frozen; arm control continues; telemetry flags rail fault |
| Control WS silent > 0.2 s | InputWatchdog | ramp twist → 0 over 0.1 s; resume needs empty held set (§8) |
| Controller WS disconnect | `WebSocketDisconnect` | immediate zero-twist + drop held state; session stays RUNNING; next connection becomes controller and re-syncs via `GET /api/session` + hello epoch |
| Twin gate HOLD persists > 2 s | supervisor counter | telemetry severity stays `blocked`; no auto-motion — operator steers away or ends session |
| Policy output stale / NaN | PolicyRunner check | hold arms; telemetry `dagger.policy_stale`; NaN → auto-takeover suggestion, gate unchanged |
| Trainer process dead | `proc.poll() != None` or 3 missed status replies | DAgger continues with frozen policy; `TrainerStatus.state="dead"` + UI banner; **auto-restart once with `--resume`** (trainer reloads `trainer_state.pt` of the newest version); dies again ⇒ stay degraded, never a third silent restart (12-dagger §12) |
| Camera hung | `read_latest` max-age miss | recorder drops frame + counts; video tile goes stale client-side; capture-thread reconnect (RealSense `hardware_reset` retry) |
| Recorder exception in `save_episode` | RecorderThread try/except | **KEEP the episode buffer** (do NOT `clear_episode_buffer`); retry once; on second failure mark the session degraded (recording off, telemetry + toastable detail), keep teleop/safety alive (12-dagger §12); control unaffected. `add_frame` exception: drop that frame + count; repeated failures degrade likewise |
| Tick overrun (> 10 ms) | pacing check | log + skip catch-up; ≥ 10 consecutive → telemetry warning `control_degraded` |
| Unclean prior shutdown | `recorder_state.json` finalized=false | on startup: `resume()` + `finalize()` repair before serving |
| SIGINT/SIGTERM | signal handlers | full TEARDOWN (§5.4): ramp, finalize, stop trainer, disconnect arms, `renderer.close()` (avoids EGL teardown noise) |

## 16. Test strategy

Hardware-free by default; pytest. Three tiers:

1. **Unit (no extras)** — `FakeWorkcell` (`tests/fakes.py`: in-memory
   Arm/Camera/Workcell interface impls, synthetic frames, scriptable error
   codes) + `FakeTwin` (scriptable `check`/`plan`); deterministic time via an
   injected `Clock` (control loop, watchdog, recorder pacing all take it).
   Cases: watchdog (stale 0.21 s ⇒ ramp; resume blocked until empty held set;
   recovery ⇒ AWAIT_EMPTY + re-seed); teleop math (held→twist per keymap,
   leash + dq clamps, rail [0, 0.65], rail keys ignored for rail-less active
   arm, Tab cycling server-side); jog/goto (slew limit, jog>threshold
   rejected, goto routes via `FakeTwin.plan`, held key cancels a plan); gate
   (scripted collision ⇒ block + hold-last-safe + CollisionEvent; hysteresis;
   escape-rule accept/reject; sim gate off unless safety_debug); bus (corr
   ids, Future resolution, unknown op); profiles
   (save/rename/delete/set_initial invariants, atomic write).
2. **WS/REST contract tests** — starlette `TestClient` over `create_app`
   with FakeWorkcell: hello-first + roles (second socket = observer, actions
   nack'd); stale `seq` dropped; Ack for every ActionMsg incl. error paths
   (episode ops in inference ⇒ ok=false); video framing round-trip
   (`struct.unpack("<dI", buf[:12])` + JPEG magic); unknown stream id closes
   1008; pre-session camera preview exists, `sim` does not; MJPEG shares the
   WS JPEG payload byte-for-byte; POST /api/session kind honoring + 409
   matrix; served keymap == core keymap.
3. **Sim-backed e2e** (`[sim]` extra, CI with EGL): (a) sim session, stream
   `KeysMsg` W for 1 s ⇒ EE moved +x, telemetry ≥ 20 Hz; (b) collect: record
   2 episodes (one saved, one discarded) to a tmpdir, `finalize`, re-open
   with `LeRobotDataset`, assert schema §10.2 (intervention / action_source /
   wallclock_ns), fps=25, episode count 1; (c) `safety_debug` guardrail: the
   `apollo-xarm7-sim` collision-course script through the runtime must be
   blocked *before* contact with `CollisionEvent`s (CI regression, overview
   §6); (d) DAgger smoke with scripted `Policy` + stub trainer: Space cycles
   policy→transition→human and back, hot-swap only at episode boundary;
   inference smoke: takeover works, recorder never instantiated.

Recorder crash-safety: raise inside `save_episode` ⇒ buffer kept + one retry
succeeds (fault injected once), second consecutive failure degrades recording
while the dataset stays finalizable; skip finalize (simulated death) ⇒
startup repair via `recorder_state.json`.
