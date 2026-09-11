# 04 — apollo-mavis-v2-runtime (`apollo_mavis_v2_runtime`)

Status: v0.1 (2026-09-01; amended 2026-09-03 — phase-10 tracker calibration:
§2 `devices/tracker_calibration.py`, §6 "Tracker calibration modes", §13.1
`/api/tracker/calibration` + "Not REST" addendum, §14 `calibration_dir` /
`tracker.libsurvive_config_path` / `tracker.calibration`; amended 2026-09-04 —
phase-09b error recovery: §5 FAULT/RECOVERING implemented, §13.1
`POST /api/hardware/arms/{arm_id}/maintenance`, §13.3 `arms[*].fault_detail` /
`.recovering` + `hardware_monitor.arms[*]` safety read-backs, §14 per-arm
backstop parameters, §15 driver-event consumption, §16 `tests/fakes.py`;
amended 2026-09-05 — phase-09c hardware session: §5 BRINGUP / TEARDOWN for the
real cell (`_bringup_hardware`: monitor hand-over, subset workcell, camera
adoption, unconditional gate, frozen arm, speed scale), §13.1 hardware 409
matrix + `home_rail` maintenance op, §13.3 `session.bringup` / `SessionInfo.kind`
/ `speed_scale`, §13.4 adoption + overlay state provider, §14
`hardware_session`, §15 rail-not-homed row; amended 2026-09-05 — phase-09d
rail homing with twin planning: §5 every configured arm in a hardware session
(`default_arms` gone, D1 for the maintenance motion only), `connect_hardware_rig`,
the `RailHomingJob` motion, `start_from=profile` planned inside bring-up,
`PlanExecutor` straight-segment slew; §13.1 `pre_position` / 202 / `refused` /
`GET …/maintenance/last` / the every-arm 409; §13.3 `arms[*].maintenance`; §14;
§15 job rows; amended 2026-09-07 — data collection re-based on the
episode-directory store (§10 rewritten, §10.5 / §10.6 new; §13.1
`/api/datasets`; §14 `recorder`), `mode: collect` admitted on hardware (§5),
teleop-cap / pose-filter status notes (§6), speed default 0.5 (1.0 since
2026-09-08 evening, §10.5) and the arming incident (§14), test-guard notes
(§16); amended 2026-09-08 — §6 keyboard
translate frame `ControlConfig.translate_frame` (`camera` / `world` / `base`,
published as `SessionTelemetry.translate_frame` §13.3): `camera` was the
morning's default, the operator flipped the default to `world` the same
evening; amended 2026-09-08 (evening) — the phase-12 dora bridge merged onto
the phase-13 trees (§17; 14-dora §16.4), and phase-14 — **Online DAgger, the
algorithm-agnostic shell (`15-online-dagger.md` v2.0; operator decision 2026-09-08
evening, replacing the morning's PRO-DAgger v1.0 wording, kept in `15-pro-dagger.md`
as history)**: §5 the hardware refusal for dagger is unchanged, §10.6 the
`online_dagger` namespace, §10.7 Online DAgger sessions, §13.1 `GET /api/datasets/
layout` / `/api/online_dagger/{skill,skill.tgz,sessions}` + the `POST /api/session`
409s (`/api/pro_dagger/*` never shipped → 404), §14 the `datasets:` and
`online_dagger:` blocks, §15 trainer rows, §16 tests — v1.0 statements superseded
in-body with a dated note); amended 2026-09-08 (late evening) — §10.5 the
`start_from` fault grace (`hardware_session.start_from_fault_grace_s`, a model
default, no YAML key) written down where CLAUDE.md / DEPLOYMENT already pointed;
**amended 2026-09-11 — action spaces and playback: §10.2 / §10.3 the second action
column `action.abs_ee` (`FK(q_cmd[k+1])`, r6 rotation) and `observation.state`
`ee.*` = twin FK of the measured joints, §10.8 the three replay sources (`state |
delta_ee | abs_ee`) with the TCP-residual verdict, §11 / §12 the executor
integrates `delta_ee` on the last COMMAND with a leash and interpolates `abs_ee`
waypoints to their deadline (`DaggerConfig.anchor_leash`), both spaces accepted
from in-process and external policies, §13.1 `source` / `sources` on the playback
routes, §14 `anchor_leash`, §16 the 2026-09-11 tests, §17 the bridge's abs rows.**
Conforms to
`00-overview.md` (spine, v0.3) and mirrors `05-ui.md` protocol shapes exactly. Research ground truth: `web-teleop-stack.md`,
`lerobot-data.md`, `dagger-online-training.md`, `xarm-python-sdk.md`.

## 1. Scope & dependencies

Runtime = session engine + server: composes a workcell (hardware or sim),
runs the 100 Hz control loop for all four modes (teleop / collect / DAgger /
inference), owns recording, safety supervision, the DAgger trainer process,
and the single FastAPI app (REST + WS + video + SPA) on **port 8765**.
Depends on `apollo_mavis_v2_core`; `hardware` and `sim` are optional extras
(hardware mode with twin safety needs both — the twin lives in `sim`).
Server deps: `fastapi`, `uvicorn[standard]`, `opencv-python`, `lerobot>=0.6`
(pinned), `numpy`, `pydantic`; trainer extra adds `torch`, `pyzmq`. Internal
units everywhere: **m / rad / wxyz quats** — mm/deg conversion happens only
inside `hardware`. Runtime requires **Python ≥ 3.12** (lerobot's floor),
unlike core / sim / hardware (≥ 3.10).

## 2. Package layout

```
src/apollo_mavis_v2_runtime/        # pyproject extras: [hardware] [sim] [trainer] [audio]
├── __main__.py                  # `python -m apollo_mavis_v2_runtime --config ...`
├── config.py                    # RuntimeConfig (§14)
├── runtime.py                   # Runtime: composition root, owns everything
├── bus.py                       # re-exports core.bus (Command, CommandBus, LatestSlot)
│                                #   + named-slot wiring (§4; core §15)
├── session/    manager.py (state machine §5), types.py (SessionState; SessionSpec/
│               SessionInfo imported from core.protocol.session, core §12)
├── control/    loop.py (ControlLoop 100 Hz §6), teleop.py (keys→twist→target),
│               tracker_teleop.py (clutched tracker target provider, 13-tracker §4),
│               joint_panel.py (jog/goto §7), arm_sender.py (per-arm senders §3),
│               snapshot.py (StateSnapshot + publisher)
├── devices/    tracker.py (TrackerReader thread: libsurvive|fake|none → LatestSlot;
│               the ONLY pysurvive import site, 13-tracker §2),
│               tracker_calibration.py (TrackerCalibration: base-station + yaw
│               calibration state machines behind /api/tracker/calibration,
│               Runtime-owned, 13-tracker §4 "Calibration modes"),
│               microphone.py (MicrophoneReader thread: PulseAudio capture via
│               sounddevice|parec, or fake|none → LatestSlot[MicFrame]; the ONLY
│               sounddevice import site; feeds telemetry.microphone +
│               GET /api/microphones, phase-11 §13.3),
│               hardware_probe.py (HardwareProbe thread: TCP 502 connect-and-close
│               per configured hardware arm → ArmStatusInfo.reachable /
│               WorkcellStatus.hardware_ready, phase-11 §13.1),
│               hardware_monitor.py (HardwareStateMonitor: one READ-ONLY
│               apollo_mavis_v2_hardware.ArmStateMonitor per hardware arm — joints,
│               flange pose, error/warn codes, rail + gripper registers, safety
│               read-backs; zero writes unless an explicit maintenance request —
│               with the pause = release-the-box supervisor; feeds
│               telemetry.hardware_monitor, ArmStatusInfo.error_code and the twin
│               overlays, phase-09a §13.3; .maintenance(arm_id, op) = the monitor
│               path of POST /api/hardware/arms/{arm_id}/maintenance, phase-09b §13.1)
├── safety/     gate.py (SafetyGate/NullGate §8), supervisor.py (twin gate §8),
│               watchdog.py (InputWatchdog + ArmReportWatchdog §8)
├── profiles/   store.py (core ProfileStore re-export + save_from_snapshot §9)
├── recorder/   episode_recorder.py (§10), features.py (schema builders §10.2)
#   + datasets.py (DatasetStore §10.6), audio.py (EpisodeAudioSink §10.5),
#     sidecars.py (10-frames §9), export_lerobot.py + tools/export_lerobot.py (§10.6)
├── dagger/     gate.py, loop.py (GatedPolicyExecutor/DaggerSession/InferenceSession),
│               policy_runner.py, recorder.py (DaggerRecorder), reloader.py, client.py,
│               trainer/ (AsyncTrainer process pkg — entrypoint
│               `python -m apollo_mavis_v2_runtime.dagger.trainer`) (§11; 12-dagger §1)
├── streams/    hub.py (VideoHub §13.4), render_source.py (sim/twin FrameSources),
│               twin_overlay.py (TwinOverlayRenderer thread + per-stream
│               TwinOverlaySource: the "<camera_id>_align" digital-twin alignment
│               overlays over the hardware wrist cameras, phase-09a §13.4)
└── server/     app.py, rest.py (§13.1), ws_control.py (§13.2),
                ws_telemetry.py (§13.3), ws_video.py (§13.4)
```

Protocol message models (`HelloMsg`, `KeysMsg`, `ActionMsg`, `AckMsg`,
`TelemetryMsg`, keymap) live in `apollo_mavis_v2_core.protocol` — runtime imports
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
| `RenderThread` | per-stream fps (≤30) | every `mujoco.Renderer` of sim's `RenderService` (sim + twin views) | runtime hosts sim's `RenderService` (03-sim §7), which paces each stream at its own fps — a fixed rate could not feed the 30 fps video streams; GL context thread-affinity; `MUJOCO_GL=egl`; ~0.6 ms/frame measured on the 4090 |
| `EncoderWorker` ×streams | stream fps | `cv2.imencode` JPEG q80 (1–3 ms/frame) | Encode-once; WS + MJPEG share the buffer |
| `TwinOverlayRenderer` (phase-09a) | `twin_overlay.fps` (12) | its OWN `BuiltScene` copy, `MjData` and two `mujoco.Renderer`s (RGB + segmentation) for the `<camera_id>_align` overlays | Session-less; renderers created and closed in-thread (GL affinity); ~1 ms RGB + ~4.5 ms segmentation per stream; never touches the gate's `DigitalTwin` (§13.4) |
| `hw.<arm>.monitor-ro` ×N + `HardwareStateMonitor` supervisor (phase-09a/b) | 10 Hz (+ ~2 Hz registers) / 0.5 s | one READ-ONLY xArm SDK client per hardware arm (`apollo_mavis_v2_hardware.ArmStateMonitor`) | Session-less; zero writes unless an explicit maintenance request (`clear_errors` / `apply_backstops` / `set_collision_sensitivity`, executed on this thread, REST only waits; §13.1); released (`paused`) while a hardware session owns the box (§13.3) |
| `RecorderThread` | 20–30 fps | the episode-directory store (`EpisodeDirRecorder`, single owner; §10) | `add_frame`/`save`; never touched from other threads |
| `PolicyRunner` | 10–30 Hz | policy `act()`, GPU 0 | DAgger/inference only (§11) |
| sim stepping thread | 500 Hz | `mj_step` (sim workcell) | Lives in `apollo_mavis_v2_sim`; runtime treats sim like hardware |
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
    dataset: str | None = None        # collect (2026-09-07, §10.5): repo id to record into,
                                      #   "<ns>/<name>" or a bare name (⇒ "apollo/<name>";
                                      #   DATASET_RE); None = derived from task (10-frames §8.1)
    dataset_resume: bool = False      # False = must NOT exist yet (409 "already exists");
                                      #   True = must exist and match this session (409)
    return_to_start: bool = True      # collect (§10.5; DEFAULT ON, operator 2026-09-07): after
                                      #   every save / discard a twin-planned, gated return to
                                      #   the start_from / initial-condition profile; 409 at
                                      #   POST if none exists and the flag is left on
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

   **Hardware bring-up (phase-09c/09d, `SessionManager._bringup_hardware` over
   `SessionManager.connect_hardware_rig`; `docs/prompts/phase-09c-hardware-session.md`,
   `docs/prompts/phase-09d-rail-homing-planning.md`; teleop AND collect — data
   collection admitted on hardware 2026-09-07 (§10.5); DAgger / inference 409
   `"hardware sessions support teleop and data collection only (<mode> on
   hardware: not yet)"` — unchanged by phase-14 (2026-09-08): an Online DAgger
   session (`mode: dagger` + `policy_source: external` + `online_dagger`, §10.7) is
   refused on hardware by the same line BEFORE its own checks run, 15-online-dagger
   D7).** Since
   phase-09d a hardware session ALWAYS includes every configured arm
   (`SessionSpec.arms` must equal `workcells.hardware.arms`, else 409
   `"hardware sessions include every configured arm (Manipulation Arm, Perception
   Arm) - missing ['view'] …"`; the Hardware tab has no per-arm "Include in
   session" switch and `hardware_session.default_arms` is gone); steps 2-11 live
   in `connect_hardware_rig(arms, …) -> HardwareRig` (connected drivers behind
   their adapters, the FRESH gate twin + `SafetyGate`, the supervisor and a NOT yet
   started `ControlLoop`), which the phase-09d rail-homing job reuses for ONE arm
   (§13.1 `home_rail`). Order, each step mirroring `_bringup_sim`:
   1. *Refusal matrix first* (`_validate_hardware`, §13.1) — nothing is
      touched until every check passes. `hardware_session_active` (the
      monitor's / probe's / overlay's hand-over predicate) turns TRUE right
      after the matrix passed — `create()` records `_creating_kind = spec.kind`
      under `_lock` before step 2 — and stays true until the session ends or
      the bring-up aborts, so the monitor's 0.5 s supervisor round can never
      reconnect a control box mid-bring-up (a bare `pause()` would be undone);
      a refused request never flips it (§13.1).
   2. *Monitor hand-over* (user rule 3): `hardware_monitor.pause()` releases
      EVERY arm's read-only SDK client (all arms together, D1), then `join(15 s)`
      per arm waits for the poll threads to really exit (`disconnect()` may return
      while a thread is still inside a blocking SDK call); a thread still alive →
      409 `"read-only monitor of the … is still inside the SDK after 15 s - retry"`.
   3. *Session `WorkcellConfig`*: `wc.model_copy(arms=[the connected arms],
      cameras=[])` — every configured arm for a session (phase-09d), ONE arm
      for the rail-homing job; the preview cameras stay manager-owned (rule 4).
   4. *`HardwareWorkcell(session_cfg, driver_factory=<speed-scaled XArmDriver>,
      netsetup=None)`* — the closure applies `SessionSpec.speed_scale` (D2) to
      the driver caps (`servo.max_joint_vel`, `servo.max_cart_step_m`,
      `rail_speed_mm_s`; `session/hardware.py::scale_driver_config`); no NIC
      matching inside a POST (reachability comes from the probe).
      `SessionManager.workcell_factory` / `driver_api_factory` are the test seams.
   5. *`bring_up(status_cb, hardware_session.bringup_timeout_s)`* (never
      `start()`: one arm failing must not abort the report); every
      `ArmBringupStatus` transition becomes `SessionTelemetry.bringup` rows
      (`session/hardware.py::bringup_rows`; `GET /api/session` already answers
      `state: bringup`, D5). Any arm of the rig with `error` / not `connected` →
      teardown + 409 `"hardware bring-up failed: Manipulation Arm: rail - [rail]
      …"` (user-facing arm name + stage + the driver's message); a CONNECTED arm
      whose `rail` is not `ready` on a railed twin arm (`error` / `detected` /
      `unhomed`: the carriage position is unverifiable) → teardown + 409
      `"… rail - linear track error after connect (carriage position unknown, the
      digital twin cannot gate it)"` (`none` is the dof mismatch of step 6). The
      driver never homes: an unhomed track is `rail: unhomed` + `RailNotHomedError`.
   6. *Consistency*: `driver.dof == twin dof` per arm (a 7-dof driver on a railed
      twin arm would make every `twin.sync` raise → silent hold of ALL arms) and
      the first `states()` not stale.
   7. *`hardware_session.rail_flip`*: when set, the workcell is wrapped in
      `RailFlipWorkcell` (`q_sim = 0.65 − q_track` on every state, mapped back
      on every command), so twin, IK, gate and loop share ONE rail convention
      and the transform is applied before every `twin.sync`; the overlay reads
      the inner workcell and applies the flip itself as before.
   8. *FRESH gate twin*: `DigitalTwin(REGISTRY.build(twin_scene,
      SceneOverrides(microphones, base_pose)), inflation_m=safety.geom_inflation_m,
      allowed_pairs_extra)` — the same overrides as the overlay twin; never the
      cached status scene (inflation mutates the model), never the overlay's or
      the sweep's twin (three independent `MjData`s / threads).
   9. *Gate UNCONDITIONAL*: `SafetyGate(twin, safety)` + `default_collision_pairs`;
      `ControlLoop.__init__` raises `SafetyConfigError` for `workcell_kind ==
      "hardware"` without a `SafetyGate` bound to a live twin (11-safety §4 item 4;
      REST maps it to 409). A start posture already inside the inflation only
      adds a `gate` warning row — the gate holds until the clearance opens.
   10. *D1 — arms not connected frozen*: every twin arm not among the connected
       arms is posed ONCE from its last monitor sample (q7 + `rail_pos_m`, or
       `twin_overlay.rail_fallback_m[arm]` when the track is unknown, `rail_flip`
       applied; `session/hardware.py::frozen_state`) via `twin.sync` and
       `ik.sync_passive`, then never updated (its brakes are engaged, it is not
       commanded; the operator must not move it from xArm Studio — telemetry row
       `frozen: "Perception Arm frozen at last sample (monitor seq N)"`, an
       unsampled arm keeps the keyframe with a warning row). Since phase-09d a
       teleop session connects both arms, so this mechanism serves the
       rail-homing maintenance motion alone (the other arm is the static obstacle).
   11. *`MinkIKSolver` (`lock_rail = not control.rail_in_ik`), `SceneKinematics`,
       `SafetySupervisor(gate, InputWatchdog, twin, ArmReportWatchdog)`*, then
       *`ControlLoop(workcell, scale_control_config(control, speed_scale), …,
       workcell_kind="hardware", gripper_arms=[ArmConfig.gripper != none])`* —
       host-side D2: `teleop.linear_mps/angular_rps/rail_mps`,
       `target_rate.v_mps/w_radps`, `dq_max_rad`, `jog.slew_rad_per_tick/
       rail_m_per_tick` × scale, **then capped by the connected drivers' servo
       stream** (`executor_caps_for` → `apply_executor_caps` for the
       PlanExecutor, and since 2026-09-07 `apply_teleop_caps` for the TELEOP
       chain: `target_rate.v_mps/w_radps`, `teleop.linear_mps/angular_rps` and
       `dq_max_rad` are lowered to `max_cart_step_m·rate_hz` / `min(max_joint_vel)`
       of the tightest `XArmDriver.cfg.servo` — 0.4 m/s + 0.6 rad/s at scale
       1.0, 0.04 m/s + 0.06 rad/s at 0.1 (the 2026-09-07 caps; 0.2 / 0.3 before); `rail_mps` and the leash are not
       servo quantities and stay; fakes without `ServoLimits` leave everything
       at the plain scale; both cap sets are logged at INFO) (the rig ends here)
       — then, phase-09d,
       *`start_from=profile:<id>` is PLANNED NOW* (`_plan_profile_start`: the
       gate twin synced with the measured states, `twin.plan(PlanRequest)` —
       RRT-Connect, frozen arms as obstacles, the rail slot follows the profile
       or stays; the same `execute_plan` path as sim, executed by the start_from
       worker from `ActiveSession.planned_start` without planning again —
       **one arm at a time in the planner's `arm_order`** since 2026-09-08
       evening, the waypoints dict keyed in that order by `_ordered_waypoints`;
       §10.5 "Sequential execution"). A
       failed plan tears the session down with 409 `"profile motion not
       collision-free: goal_in_collision (grip_right_inner_knuckle / table) - …"`
       — a hardware session never starts with a motion the twin refused. Then
       `loop.start()`.
   12. *Camera adoption* (rule 4): for every open preview camera
       `hub.set_fps(cam_id, video.session_fps)`; the ids go to
       `ActiveSession.adopted_streams` (NOT `streams`: `SessionInfo.streams` is
       `[]`, teardown restores the fps instead of removing the stream, the UVC
       node is never re-opened, `hardware_camera()` keeps returning the same
       object). The `<id>_align` overlays keep running: the monitor is paused, so
       `TwinOverlayRenderer.set_state_provider(SessionStateProvider(inner
       workcell, session arms, frozen samples))` feeds them from the driver's
       `states()` (live tint) and any frozen sample (grey, "frozen at last
       sample").
   Every failure path (`_abort_hardware_bringup` → `stop_rig`) stops the loop
   and the workcell (drivers hand the arms back stopped + braked, D6; the
   workcell owns no cameras), restores the adopted fps, drops the overlay
   provider, clears `_creating_kind` and `resume()`s the monitor — nothing stays
   half-connected.

   **Rail-homing maintenance motion (phase-09d, `devices/rail_homing.py`;
   NOT a session).** When `home_rail`'s full-travel sweep is blocked at the
   arm's current posture, the `RailHomingJob` (one arm, one thread, REST 202)
   runs `sweeping → planning → connecting → positioning → homing → verifying →
   done|failed` on `ArmMonitorTelemetry.maintenance`: `connecting` takes the
   manager's lock (exclusive with `create()` / `teardown()`; a session that
   exists or is starting fails the job) and calls `connect_hardware_rig` for
   THIS arm alone with `speed_scale` 0.1, `allow_unhomed_rail` (driver config
   `rail_homing: allow_unhomed` → `ArmBringupStatus.rail == "unhomed"` accepted)
   and `rail_hold` (`RailHoldWorkcell`: the twin sees `rail_fallback_m` instead of
   the driver's 0.0 placeholder while `rail_position_known` is false, and every
   rail command is pinned to the reported slot — the job never moves the
   carriage), the other arm frozen (D1), a PRIVATE `RuntimeBus` and no tracker
   (`loop.active_arm = None`: the loop only holds and executes plans; no WS or
   device input can reach it); the measured posture must match the sweep's
   within 0.02 rad. `positioning` = `execute_plan` with the position-agnostic
   waypoints (§13.1) and a wait for the executor (a driver fault or the 30 s /
   3× estimate timeout aborts; the measured joints must reach the target within
   0.05 rad); `homing` stops the loop FIRST (the driver's servo stream holds the
   joints; no 8-dof hold can move the freshly homed carriage) and calls
   `XArmDriver.home_rail()` on the job thread; `verifying` = registers homed +
   enabled + no error, `rail_position_known`, phase `READY`, raw `rail_pos_m`
   0.0; then `stop_rig` (D6: the arm HOLDS the folded posture — no automatic
   return), `hardware_monitor.resume()`, a fresh monitor sample awaited (≤ 5 s),
   and the final `ArmMaintenanceResult` (`status: done`, the 202's `job_id`) at
   `GET .../maintenance/last`. Any failure → `failed` with the same teardown +
   resume. `Runtime._hardware_session_active` is also true while the job's
   driver holds a box (`RailHomingService.owns_boxes`), so the monitor's
   supervisor never reconnects mid-job; `maintenance_busy` is true for the job's
   whole life, `POST /api/session` and every other maintenance op are 409 "rail
   homing in progress" meanwhile.
2. **START_FROM** — `keep_current`: no motion, targets seed from measured
   state. `profile:<id>`: twin planner (`DigitalTwinInterface.plan`,
   RRT-Connect on inflated geoms, per-arm sequential with others as static
   obstacles) → waypoints through the normal gated servo path (§9). Never
   xArm native gohome. Progress → telemetry `session.start_from_progress`.
   Hardware (phase-09d): the plan was made INSIDE bring-up (item 11 above); the
   worker only executes `ActiveSession.planned_start`. The `PlanExecutor` moves
   along the STRAIGHT joint-space segment between waypoints (every joint by the
   same fraction of its remaining delta, the fastest at `jog.slew_rad_per_tick`)
   — exactly the segments the planner edge-checked; a per-joint clip would bend
   the path off the validated line and the hardware gate would hold it for good.
   Since 2026-09-09 a segment is walked in `ceil(ratio)` EQUAL ticks (no tiny
   remainder tick onto the waypoint: the gate's escape rule demands ≥ 10 um of
   opening on EVERY tick of a pinched arm, and a 3-13 % remainder tick was held
   and bent the next tick off the validated path; 11-safety §9). Every
   `PlanRequest` the runtime builds carries the session's `speed_scale`
   (`ControlLoop(speed_scale=…)` for the joint-panel goto, the manager for
   `start_from` / returns / `goto_profile`, `JOB_SPEED_SCALE` for rail homing):
   the planner judges a pinched start's escape tick by tick at that speed.
3. **RUNNING** — the mode loop (§6–§7, §10–§12). Modes differ only in action
   sources (human/policy), recorder on/off, and takeover semantics.
4. **TEARDOWN** (DELETE /api/session, fatal error, SIGTERM) — stop policy
   runner, zero-twist ramp, `recorder.finalize()` (§10.4), stop trainer
   process, stop encoders/renderer, `arm.stop()` + `disconnect()`; clients
   detect the released session via hello epoch/`session_id`. Hardware
   (phase-09c, the mirror of the bring-up): `loop.stop()` → `workcell.stop()`
   (`XArmDriver.disconnect()` ends with `set_mode(0)`, `set_state(4)`,
   `motion_enable(False)` — the arm is handed back as found after power-on,
   stopped and braked, D6; the track keeps its homed flag and enable, no
   re-homing between sessions) → adopted previews back to `video.preview_fps`
   → overlay provider removed → `session = None` → `hardware_monitor.resume()`
   (reconnects every arm) → `start_previews()` (no camera is re-opened).
5. **FAULT/RECOVERING** — per-arm SDK error recovery (§15; implemented
   phase-09b, fake-tested). The control loop drains the workcell's driver
   events every tick: a `FaultEvent` stops THAT arm (its `ArmSender` is
   paused — dispatch stops and the pending gripper target is dropped — it
   holds, its plan / jog / teleop seed are dropped, the clutch anchors are
   released if it was the clutched arm, and `_gripper_step` ignores F/H for
   it while FAULTED / RECOVERING so nothing integrates or queues; the re-seed
   re-syncs the gripper target from the measured opening) and the session
   goes FAULT; the OTHER arms keep running in the loop. The driver's own bounded
   auto-recovery (02-hardware §3.5: ≤ 3 per 30 s for RECOVERABLE codes such
   as C22 / C24 / C31 / C35) still runs; once it is LATCHED (budget exhausted,
   unrecoverable code, e-stop) only the operator's click recovers (`POST
   /api/hardware/arms/{arm_id}/maintenance {op: recover}` → the driver's
   `request_recovery`, §13.1) — the runtime itself never re-enables an arm.
   `ReseedEvent` /
   `RecoveredEvent` re-seed the arm's targets from the MEASURED position
   (`ControlLoop.reseed_arm`: `_last_cmd`, IK warm state, gate `_last_safe`,
   watchdog AWAIT_EMPTY) and put it — and the session — in RECOVERING; it
   returns to RUNNING on the first tick whose inputs (sampled after the
   re-seed) hold nothing live: the device clutch released (its next press is
   a true rising edge → zero delta on engage) and every WS code up or latched
   by the watchdog (which itself only clears on a fresh EMPTY KeysMsg, §8).
   `session.state` follows the loop's aggregate (`ControlLoop.on_fault_state`
   → `SessionManager._on_arm_fault_state`): `fault` while any arm is stopped,
   `recovering` while any is re-seeded and waiting, else `running`; the
   start_from worker never overwrites a fault. Telemetry: `arms[*].fault_detail`
   (the SDK `x_code` title, e.g. `controller error 24: Speed Exceeds Limit`,
   kept through RECOVERING, `""` when running) and `arms[*].recovering`.

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

- **Twist frame** (translations CHANGED 2026-09-08, operator request; default
  flipped from `camera` to `world` the same evening, operator decision).
  Rotations are about the **TCP axes** — unchanged, and self-consistent
  whatever the arm is doing. Translations follow
  `ControlConfig.translate_frame`:
  - `world` (**default** since 2026-09-08 evening) — the operator frame, fixed
    to the table: `W` away from the operator (−Y), `A` to the operator's left
    (+X), `E` up. Never follows the tool.
  - `camera` (the wrist-image alternative; the 2026-09-08 morning default,
    superseded the same day) — the active arm's **wrist-camera** frame: `W`/`S`
    along the optical axis, `A`/`D` image left/right, `E`/`Q` image up/down.
    The operator teleops off the wrist stream, and the old base frame meant a
    rotated tool sent every key somewhere else on screen ("the whole axis set
    is misaligned after I rotate the EE"). The camera's WORLD orientation comes
    from the model, per arm, via `SceneKinematics.wrist_cam_quat_world`
    (`quat_mul(tcp_quat, cam_from_tcp)`, the constant computed once at
    construction from `site_xmat`/`cam_xmat`). It **must** be per arm: the
    gripper base is mounted `quat="0 0 0 1"` under link7, a 180° turn about the
    tool axis, so the Manipulation Arm's TCP frame is that much rotated against
    the Perception Arm's and one constant key→TCP matrix reverses `A`/`D` and
    `E`/`Q` on the default teleop arm (pinned in
    `tests/test_camera_frame.py`). An arm with no wrist camera (some test
    scenes) falls back to the TCP frame with the same forward axis. **Property
    of this frame to say out loud: `E`/`Q` mean up/down in the WRIST IMAGE, not
    world up/down** — with the tool pointing at the table they run roughly
    horizontally, and `W` runs into the table. That is correct camera-frame
    behaviour and what makes the keys match the stream.
  - `base` — pre-2026-09-08: the arm's `link_base` axes. Fixed as the rail
    slides, but in this cell `base_quat` is a +90° z rotation and joint 1 = π,
    so it reads yawed 180° against the operator (`W` toward the operator, `A`
    to their right). Kept for the test suites that pin world-axis
    displacement.

  The recording frame (`SessionSpec.frames`) affects only dataset conversion
  (§10.3), never control math, and the canonical policy action frame stays
  `arm_base:<id>` (`dagger/policy_runner.py` is untouched by this knob).

  The live frame is published as `SessionTelemetry.translate_frame` (§13.3) and
  captioned above the KeymapOverlay (05-ui §8.2): the keymap labels the KEY axes
  ("forward", "up") and never a frame, so nothing else in the UI could tell the
  operator what those keys currently point at. Switching frames is one config
  line (`translate_frame: camera` for the wrist-image behaviour) and needs a
  runtime restart.
- **Target integration + leash**: `target ⟵ target ⊕ twist·dt`, then clamp to
  a leash around the *measured* EE pose: ≤ 0.025 m / ≤ 0.2 rad geodesic. The
  leash bounds IK divergence (mink converges silently to nearest-reachable)
  and keeps per-tick motion far under the firmware 10 mm/step mode-1 limit.
- **IK**: `q = ik.solve(arm_id, target, q_seed=last_cmd_q)` — mink QP with
  posture/limits/collision rows (hardware or safety_debug; plain
  posture+limits in sim), ~0.12 ms/arm measured. Task residual >
  `residual_max` (0.01 m / 0.1 rad) ⇒ freeze `target` back to the achieved
  pose (glide, don't wind up) — **component-wise** (2026-09-02): a position
  residual re-anchors the position only, a rotation residual the orientation
  only. The single-step QP trades position for orientation when the joint
  velocity limits saturate (weights 1.0/m vs 0.5/rad), so re-anchoring both on
  a rotation-only residual leaked the transient position error into the
  tracker anchor and the TCP drifted several cm while the hand only rotated.
- **Target rate limit (tracker path)**: the clutched target handed to IK moves
  from the previous commanded target toward the leash-clamped hand target by at
  most `target_rate.v_mps·dt` / `target_rate.w_radps·dt` (defaults 1.0 m/s,
  2.0 rad/s). This keeps the QP out of velocity saturation (the leash alone
  allows a 25 mm / 0.2 rad step per tick) so it never has to choose between
  position and orientation; the truncation is NOT slipped into the anchor (the
  target catches up within the leash), the leash slip still bounds the offset.
  Keyboard twists are already rate-bounded by `teleop.*` and skip this stage.
  **The rate must not exceed what the arm executes (2026-09-07).** On hardware
  the servo streamer clips every joint at `max_joint_vel·dt` and the whole step
  at `max_cart_step_m` (then 0.002 m/tick = 0.2 m/s at speed scale 1.0, 0.02 m/s
  at the 0.1 default; 0.004 = 0.4 m/s since the same day), while the host chain ran at 1.0 m/s: the target ran ahead
  of the measured TCP until the 25 mm leash truncated it, and `TrackerTeleop.slip`
  folded that truncation into the engagement anchor — hand travel silently
  DISCARDED (worst along directions that need large joint motion, e.g. straight
  down), and whatever got through kept arriving for up to one leash (0.125 s at
  scale 1.0, **1.25 s at 0.1**) after the hand stopped. Those were the operator's
  "does not follow the hand" / "moving the controller down barely moves the
  gripper" / "keeps moving after I release the trigger" reports. The hardware
  bring-up therefore caps the teleop chain at the streamer's own rates
  (`apply_teleop_caps`, §5 step 11): slower than the hand at low scale, but
  faithful — the commanded direction is the hand's direction and a release
  stops the arm within one streamer tick. The arm's top speed is unchanged (it
  always was the streamer's); a faster FEEL is `speed_scale` / `ServoLimits`,
  chosen deliberately. `TrackerTeleop.slip_count` / `slip_pos_total_m` count the
  discarded travel for the loop's health line (§14 "Logging"). The joint
  bound comes from `ExecutorCaps.joint_step_rad` (the streamer's own
  `max_joint_vel / rate_hz`), NOT from `ExecutorCaps.slew_rad_per_tick`, which
  `apply_executor_caps` also bounds by the host JOG slew — a jog cap must
  never leak into teleop. Status: not yet verified on the arms — the
  2026-09-07 01:12 session ran at scale 1.0 before the caps landed; a runtime
  restart is needed to pick them up.

  **That was not the whole delay — the pose filter was the bigger half
  (2026-09-07, measured).** After the caps landed the operator still reported a
  lag on the trigger, and the One Euro filter turned out to be misparameterised:
  `beta` is in **Hz per (m/s)**, so the shipped `beta: 0.05` added 0.015 Hz at a
  0.3 m/s hand and the cutoff never left `min_cutoff_hz: 1.0` — an "adaptive"
  filter degenerated into a FIXED first-order low-pass, τ = 159 ms. Against a
  constant-velocity ramp the filtered pose trailed the hand by **148 ms / 15 mm
  at 0.1 m/s and 131 ms / 39 mm at 0.3 m/s**; 39 mm is past the 25 mm leash, so
  the two defects compounded — the filter's own lag pushed the target into the
  leash, which truncated and slipped the travel away. Retuned to `beta: 5.0`:
  **7.6 mm / ~25 ms** at 0.3 m/s (4.3 mm / 43 ms at 0.1, 11.7 mm / 15 ms at 0.8),
  costing nothing measurable at rest — the real controller measures 0.1 mm p-p,
  an order below `deadband_m`. `d_cutoff_hz` **stays at 1.0 on purpose**: it is
  the cutoff of the speed estimate, so raising it reacts to acceleration sooner
  (`beta 10` + `d_cutoff 10` measured 5.2 mm / ~17 ms) but couples input noise
  into that estimate and lifts the cutoff while the hand rests — against 3 mm-std
  input, rest suppression falls 4.9× → 2.8×. Eight milliseconds is not worth a
  third of the jitter rejection while libsurvive keeps corrupting the lighthouse
  calibration, since the corrupted regime is the noisy one. `deadband_m` also
  went 2 → 1 mm (still 10× the measured noise) to halve the dead travel at the
  start of a motion.
  Re-measure with the same two experiments (ramp lag, rest std over 20 s) before
  touching these; `control/pose_filter.py`'s docstring carries the numbers. The
  `reset()` on every clutch engage was checked and is NOT a factor — a resting
  hand leaves the speed estimate near zero, so a reset and a warm filter give
  identical engage transients. Status: the retune is measured offline (ramp +
  rest-noise experiments) and not yet verified on the arms.
- **Per-tick joint step cap** (`dq_max`, 0.04 rad/tick in the repo config; a
  HARDWARE loop lowers it to the streamer's own `max_joint_vel / rate_hz` —
  0.006 rad/tick at speed scale 1.0, 0.003 at 0.5, `apply_teleop_caps` — and
  carries the streamer's lever-weighted Cartesian bound `jog.plan_cart_step_m` /
  `plan_lever_arm_m` = `ServoLimits.max_cart_step_m` × `lever_arm_m`, 4 mm/tick
  at 1.0, `apply_executor_caps`): before the gate the joint step `q[:7] −
  q_last[:7]` is bounded by **uniform scaling** — the WHOLE step is divided by
  the larger of `max|dq_j| / dq_max` and `Σ|dq_j|·lever_j / plan_cart_step_m`
  whenever that ratio exceeds 1, so the joint-space direction, and with it the
  Cartesian direction the IK solved for, is preserved and the arm is merely
  slower (`ControlLoop._cap_joint_step`; the rule `PlanExecutor.step` already
  used for planned segments, both bounds included — in sim `plan_cart_step_m`
  is None and only `dq_max` applies). Both bounds are exactly the two clips the
  hardware `_ServoStreamer` would otherwise apply itself (02-hardware §3.3), so
  with the host cap in force the streamer's clips are inactive and the executed
  path is the commanded one, up to its acceleration ramp. A non-positive
  `dq_max` HOLDS the arm (the fail-safe direction; `ControlConfig.dq_max_rad` is
  validated `> 0`). The rail slot is a separate axis with its own
  controller-side speed and keeps an independent bound. The loop counts the
  ticks the cap bound (`clamp_ticks`; `dq_capped=+N` on the health line, §14):
  on a hardware loop a held translate key binds it on nearly every tick, because
  the key requests 0.12 m/s (100 %) while the streamer's lever-weighted capacity
  for a translating TCP is **~0.04–0.09 m/s** (0.02–0.05 m/s at 50 %) — that,
  not `apply_teleop_caps`' 0.4 m/s `tcp_mps` ceiling, is the real top speed of
  keyboard teleop on the cell. Uniform scaling trades speed for direction:
  whenever one joint (or the lever sum) saturates, EVERY axis slows instead of
  the direction bending — for the keyboard, the tracker, policy and plan steps
  alike. A capped KEYBOARD tick also pulls the integrated target back along the
  DRIVEN axes to the pose the capped step reaches (`_hold_key_target`): the
  translation along the commanded direction and the rotation about the
  commanded axis, nothing else — the off-axis position and the undriven
  orientation stay pinned to the line the seed defined so the IK keeps
  correcting them instead of ratcheting each tick's residue into the anchor. A
  key is a velocity command with no absolute reference, so a target that runs
  ahead of a joint-capped arm only winds up to the leash (the QP then chases a
  25 mm error into its own per-joint velocity box, bending the direction
  again) and keeps the arm going for a leash after the key is released. The
  tracker path is untouched: there the hand pose IS the reference and the
  target catches up within the leash by design (above). The IK is untouched:
  it still warm-starts from its own last output (03-sim §9), so after a capped
  tick its state sits one truncated step ahead of the command; with the
  pull-back that offset stays constant (the next request is exactly the cap,
  which passes unscaled) instead of growing to the 0.05 rad reseed and
  snapping back.

  **History — operator report 2026-09-09: "when I press forward/back with the
  keyboard the arm also drifts up/down; a single-axis key should move only
  along that axis".** Until then the step was `np.clip`ped PER JOINT: whenever
  one joint saturated the others kept their full step and the direction bent.
  Measured on the `mavis_v2` sim (real `ControlLoop` + `MinkIKSolver` +
  servo-faithful `SimWorkcell` in lockstep, translate frame `world`, 2 s holds,
  the host-side caps of a hardware bring-up — the sim's servo has NO streamer —
  world-frame TCP before → after settle). Harness: `python -m
  apollo_mavis_v2_runtime.tools.axis_purity_measure` (not collected by pytest;
  carries every isolation control below: `--config dq=0.04 | leash=1 | nores`,
  `--cap uniform | joint-only | per-joint-clip`, `--no-pullback`, `--streamer`,
  `--tracker`, postures P0–P3). The live-server subset is
  `tests/test_teleop_axis_purity.py` (egl, P0 only, both arms, both speeds;
  fails with the old clamp at 100 %, the 50 % rows are a timing-dependent
  regression guard); the pure behaviours — exact uniform scaling, both bounds,
  the pull-back geometry, `clamp_ticks`, the `dq_max <= 0` hold — are
  `tests/test_joint_step_cap.py` (FakeWorkcell, milliseconds).
  - Manipulation Arm from the initial posture, 100 %: `S` 6.4 mm off-axis
    (−6.0 mm in Z) + 1.68° over 237 mm with the cap binding 93 of 200 ticks;
    `Q` 1.8° at 50 % (64 ticks). One `W` further (P1): `W` 39.5 mm off
    (−39.4 mm Z, i.e. DOWN) + 1.2° over 181 mm at 100 % (148 ticks), 15.5 mm
    (−15.4 Z) + 2.0° over 107 mm at 50 % (96 ticks) — the operator's symptom.
    Deeper in (P3): `Q` 34 mm off with only 69 mm on-axis, 16 IK slips.
    Perception Arm at P3: `S` 18.9 mm (−18.6 Z) + 1.8°.
  - Isolation: the same rates with `dq_max` 0.04 (cap never binds) give
    < 0.7 mm and < 0.1° on every one of those keys ⇒ the clamp is the cause
    (suspect a). Leash 1 m instead of 0.025: numbers identical to the digit ⇒
    the leash is not a factor (b). Residual freeze disabled: unchanged on the
    core cases ⇒ not a cause (c). IK weighting (d): with the cap inactive the
    IK floor is < 0.7 mm / 240 mm. The requested keyboard rate does exceed
    the joint cap in many postures — 28–197 of 200 ticks capped at 0.12 m/s
    and 0.006 rad/tick — so (e) is real and is why the keyboard target must
    not run ahead.
  - Uniform scaling against `dq_max` alone: 100 % `S` 3.7 mm / 0.19° (1 slip —
    the IK's warm state ran 0.05 rad ahead of the capped command and snapped
    back), P1 `W` 9.8 mm (5 slips), P3 `Q` still 26–41 mm (the target at the
    leash, the QP saturating). With the keyboard target pull-back added: `S`
    0.53 mm / 0.066°, P1 `W` 0.09 mm / 0.078°, P3 `Q` 0.35 mm on 72 mm; worst
    ratio anywhere 1.5 mm per 100 mm (50 %, P3 `Q`, the arm doing a third of
    the requested rate); 0 IK slips everywhere (were up to 16). Making the sim
    IK linearize at the commanded seed as well was tried and gave the same
    numbers, but it stalls a caller that seeds from the MEASURED q (the
    guardrail CI's `cross_arm_rail_converge` never reached its block), so the
    IK stays as it was. Not a clamp effect and left alone: the Perception Arm's
    `W` from the initial posture runs its elbow (joint 4) into the −11° stop
    after ~190 mm, where the link2/link4 contact pushes the TCP up — the
    workspace boundary.
  - **Second layer (review, 2026-09-09 evening): the sim has no streamer.**
    That first fix bounded the per-joint step only; the real `_ServoStreamer`
    also clips per joint at `max_joint_vel·dt`, per joint at the acceleration
    step, then scales so `Σ|dq_j|·lever_j ≤ max_cart_step_m`. The lever
    estimate is 5–10× conservative for a keyboard step (a host step of 6–12 mm
    lever-weighted at 100 % against the 4 mm cap; 3–6 mm vs 2 mm at 50 %), so
    on the real arm the streamer would have executed a third to a half of every
    host step, the command would have wound up to the 25 mm leash (the
    pull-back anchors to the COMMANDED pose and fires only when the host cap
    binds — which it did not), and the streamer's own per-joint clip would have
    bent the direction every tick: the mechanism the fix removed, one layer
    down. Closed-loop emulation of the streamer on the lockstep harness
    (`--streamer`; host-only rows bit-identical to the run above): 100 % P0
    Manipulation Arm `W` 28 mm off on 109 mm (26 %), `S` 60 mm (50 %) + 3.2°,
    `Q` 131 mm + 15.4°; 50 % `W` 22 mm on 55 mm (40 %), `S` 35 mm (58 %) +
    2.4°; the streamer's velocity clip bound on 207–248 of 250 ticks, lag up to
    0.35 rad, while the host cap bound 0 ticks. **Fix: fold the streamer's
    Cartesian bound into the same uniform ratio** (`plan_cart_step_m` /
    `plan_lever_arm_m`, already on every hardware loop). Emulation after: every
    non-elbow-stop row ≤ 0.35 mm per 100 mm and ≤ 0.06° at 100 %, ≤ 0.65 mm /
    100 mm and ≤ 0.06° at 50 % (P0 and P1, both arms); the streamer's velocity
    clip acts on 0 ticks, its lag ≤ 0.004 rad (the acceleration ramp at key
    press); host-only and streamer-emulated rows are identical to the digit,
    so the sim result now transfers. On-axis travel per 2 s hold: 83–182 mm
    at 100 % (0.04–0.09 m/s) and 44–97 mm at 50 % against 240 / 120 mm
    requested; `dq_capped` 195–200 of 200 ticks. Live-server run
    (`test_teleop_axis_purity.py`, both arms, both speeds): worst 0.31 % /
    0.044° on the Manipulation Arm at 100 %.
  - Tracker path, same harness (`--tracker`: hand scripted at 0.3 m/s along
    each world axis, clutch held, filter off, P0, both arms, streamer
    emulated). Before (per-joint clip): off-axis up to 100 mm per 100 mm +
    14.5° (Manipulation Arm −z), 33–57 mm on `±y`; the streamer's velocity clip
    on 213–249 of 250 ticks. After: ≤ 33 mm per 100 mm, ≤ 0.5°, streamer clip
    0 ticks; on-axis rate unchanged within the noise (0.05–0.10 m/s at 100 %,
    e.g. `+x` 200 vs 183 mm, `−z` 114 vs 129 mm per 2 s). The remaining
    off-axis component is the leash, not the cap: a hand outrunning the arm
    3–6× parks the target at the 25 mm leash and the single-step QP trades
    position for orientation inside its velocity box, with 400–550 mm of the
    600 mm hand travel slipped into the anchor (`leash_slips`). That is the
    tracker design (the hand pose is the reference, no pull-back) and it is
    invisible at hand speeds the arm can follow.
  - OPEN: the streamer's C24 backoff (`_ServoStreamer.set_scale(0.5)` for
    10 s) halves the streamer's steps below the host `dq_max` /
    `plan_cart_step_m` and re-introduces its per-joint clip for that window;
    the driver does not publish its effective scale, so the host cannot follow
    it yet. Not yet verified on the real arms — what to watch on the health
    line: `dq_capped` binding on nearly every keyboard tick and a small
    `cmd-meas` lag.
- **Gate** (§8): `supervisor.filter(q_cmd, q_meas, source)`; violating arms
  hold last-safe (escape rule excepted) + `CollisionEvent` → telemetry.
- **Rail**: rail arms carry an 8th q slot; rail keys integrate a target
  clamped to [0, 0.65] m. Rail held-keys arrive for every arm; the loop
  ignores them when the active arm has no rail (binding decision). The
  hardware driver sends sparse absolute mm targets (`command_rail`; the track
  has no streaming interface); measured rail position feeds the twin.
  **Rail-only semantics (2026-09-02, to confirm on hardware in phase-09):** a
  tick whose only motion input is a rail code holds the joint posture
  (`q[:7] = q_last`) and integrates the rail slot alone, so the TCP rides the
  rail by the travelled distance — the IK is NOT run against the frozen
  world-frame target (before 2026-09-02 it was, and the arm folded to keep the
  TCP fixed in the world while the base slid). Because the base moves under the
  frozen target, a rail-only tick also invalidates the arm's teleop seed
  (`_teleop_seeded.discard`; 13-tracker §4 re-seed rule (d)): the next
  translate key or clutch engage re-seeds the integrator from the measured TCP
  and moves by one twist step / zero, never by a leash-sized (25 mm) step
  toward the stale target. **Rail inputs slide the whole arm (2026-09-03):**
  translate/rotate keys or a live clutch held *together with* a rail code no
  longer keep the world-frame target fixed — the integrator target and the
  tracker anchors ride along by the base displacement of the tick's rail step
  (`_ride_rail`), the IK is seeded with the new rail value, and the joints keep
  tracking the hand / keys (before 2026-09-03 the IK compensated the rail and
  the arm folded to hold the TCP in place). **The rail is out of the IK**
  (`control.rail_in_ik: false`, default → `IKParams.lock_rail`, 03-sim §9): the
  differential solve moves the 7 joints only and adopts the rail slot from its
  seed each tick, so a TCP target is never reached by sliding the base — the
  operator moves the rail explicitly (arrow keys / controller trackpad
  left-right), which also stops the IK from fighting those inputs. `rail_in_ik:
  true` restores the pre-2026-09-03 behaviour (rail = expensive IK dof).
- **Gripper**: F/H integrate `open_frac ∈ [0,1]` → `GripperCommand` at
  ≤ 10 Hz (modbus is slow; `wait=False`).
- **Tab / switch_arm**: server-authoritative — the Command cycles
  `active_arm` over `session.arms`; the previous arm's target freezes; the UI
  learns the new arm via telemetry only.
- **Device-held codes + per-source scales** (13-tracker §1.1): step 2 also
  reads the newest `TrackerSample`; when it is fresh (`age ≤ tracker.stale_s`)
  its `held_codes` (Vive-controller buttons mapped by `tracker.controller_map`
  to the keymap codes of `tracker_clutch` / `gripper_open` / `gripper_close` /
  `rail_neg` / `rail_pos`) are merged into the tick's set: `held_eff = held ∪ device_codes`
  (`ControlLoop.sources: HeldSources`). Each source keeps its own scale — WS
  codes the `InputWatchdog` scale, device codes `1.0` fresh / `0.0` stale (the
  controller's ≥100 Hz sample stream is their heartbeat; a WS `AWAIT_EMPTY`
  latch never zeroes device-driven motion). A code held by both sources takes
  the larger scale (`HeldSources.scale_for`): the tracker clutch branch runs
  at the clutch holder's scale, `_gripper_step` integrates F/H per code at
  that code's scale, `_rail_rate` integrates the rail codes per code at that
  code's scale (clamped to `teleop.rail_mps`, so WS + device holding the same
  direction never double the speed; a device-held rail code moves the rail
  with no browser connected and through a WS deadman latch; a rail-only tick
  holds the arm joints at `q_last`, never seeds the teleop integrator and
  invalidates an existing seed — see "Rail" above),
  keyboard translate/rotate keep the WS scale (only WS codes carry them), and
  the movement-key plan-cancel rule fires for any code whose source scale is
  > 0. A running session is required; a connected
  `/ws/control` client is not. Telemetry echoes the raw controller state and
  the injected codes (`tracker.controller`, `tracker.device_held`).
- **Trackpad click classification + device discrete actions** (13-tracker
  §1.1, remap 2026-09-02): the reader classifies a trackpad click at its
  press edge from `(x, y)` by the dominant axis (`|x|` and `|y|` both within
  `trackpad_deadzone` ⇒ unclassified) and holds the class until release
  (`ControllerState.trackpad_dir`); **since 2026-09-07 a click whose press edge
  fell inside the deadzone is re-classified while still held, the first time
  the finger leaves the deadzone, and that appends its own edge** (before, such
  a click stayed dead however far the finger moved — and the pad axes are only
  refreshed by an event, so an idle or just-woken controller read a stale
  centre at the press edge; squeezing the trigger produced axis events and
  appeared to "unlock" the pad — the operator's "gripper only works after the
  trigger"); every press edge of the trackpad click,
  the menu button and the grip button advances `ControllerState.edge_seq` and
  sets `edge_input` to the input that produced it (the classified
  `trackpad_*`, `None` for a deadzone click, `menu_click`, `grip_click`;
  `note_edges`). `controller_map` — **the operator's map, code default and lab
  config alike; do not change it without being asked**: `{clutch: trigger_click,
  gripper_open: trackpad_up, gripper_close: trackpad_down, rail_neg:
  trackpad_left, rail_pos: trackpad_right, arm_next: menu_click, arm_prev:
  none}`. (It was briefly remapped onto the plain buttons on 2026-09-07 to work
  around the stale-axes bug above; that was the wrong fix — the bug belongs in
  `note_edges`, which now resolves a deadzone click late, and the map was
  reverted the same day.) Bindable inputs are `trigger_click`,
  `trackpad_left|right|up|down`,
  `menu_click`, `grip_click`, `none` (system is never bindable: menu + system
  is the pairing combo); every input binds at most one action, held actions
  accept any input and the discrete actions accept any input except
  `trigger_click` (held-only). Held bindings become `held_codes` as above; the
  discrete ones ride on the sample as `click_actions` (`(seq, switch_arm |
  switch_arm_prev)` for every remembered edge — `ControllerState.edges` keeps
  the last 8 `(seq, input)` press edges) and the loop fires, in step 2 on a
  fresh sample, every entry newer than the `edge_seq` it saw last
  (`_device_click_edge` → `_handle_command`, i.e. the same `_op_switch_arm*`
  handlers and the same nacks as the WS action, incl. the DAgger "takeover
  active" nack), so two buttons edging inside one tick both fire. The first
  observed counter is adopted silently, stale edges are dropped, and the
  outcome is shown as `tracker.device_action` (`"switch_arm"` or
  `"switch_arm nacked: <detail>"`) for `DEVICE_ACTION_LINGER_S` = 1 s.
- **Tracker pose filter** (13-tracker §4 "Pose filter"): `TrackerTeleop`
  runs `control/pose_filter.PoseFilter` (One Euro on position and on the
  orientation increment, then a rest deadband) on the *aligned* sample pose at
  the 100 Hz tick, before the anchor/delta math. Static fields come from
  `tracker.filter` (`d_cutoff_hz`, `deadband_m`, `deadband_rad`); `enabled` /
  `min_cutoff_hz` / `beta` live in the process-wide `TrackerSettings` and are
  retuned live by `tracker_settings` (`filter_*` args). The filter resets on
  engage and after stale/invalid gaps, free-runs while the clutch is up (so
  `tracker.pose_filtered` is live in any session), and `enabled: false`
  bypasses it. Telemetry `tracker.settings` echoes the effective filter fields.
- **Anchor and re-seed rules** (13-tracker §4, review 2026-09-02):
  (a) `_resolve_arms` (and the DAgger override) records the per-arm resolving
  source (`_note_source`); any non-teleop source (plan, jog, policy)
  invalidates the arm's teleop seed, and `_teleop_step` re-seeds the integrated
  target from the measured TCP the moment motion input starts (keys / clutch,
  not on idle hold ticks), so the first clutched or keyed tick after such
  motion has zero delta. (b) Rotation anchor slip is applied in the BODY frame:
  `dq_b = conj(intended.q) ⊗ achieved.q`, `A_ee.q ← A_ee.q ⊗ dq_b`, hence
  `D ⊗ A_ee'.q == achieved.q` exactly for any hand rotation `D`. (c) The
  settings (yaw, scale, rotation flag, filter) are snapshotted at engagement;
  a `tracker_settings` change while engaged re-anchors (`A_trk ← filtered(
  sample, new)`, `A_ee ← the provider's leash-clamped target` — the raw target
  the anchors produce with a still hand, not the rate-limited pose handed to
  IK, so a pending rate-limit catch-up is kept) instead of re-interpreting the
  accumulated offset — the arm never moves on a settings change.
- **Reader robustness** (13-tracker §4): the libsurvive loop polls
  `simple_next_event` (1 ms idle wait, so `stop()` and the no-device check
  never hang on a silent dongle); every event is guarded (finite position,
  unit-norm quaternion; malformed events and handler exceptions are dropped
  and counted in `bad_events`, never raised); the loop auto-restarts with
  backoff 0.5 → 5 s when it dies and `start()` is restartable (`_thread`
  cleared on exit); after a 3 s grace the status is `error` when libsurvive
  enumerates no OBJECT-type device (detail: dongle busy / not openable / udev
  / tracker off / unpaired + the last libusb line) and `searching` when a
  device is present but silent (a mismatching `object_name` is spelled out);
  `rate_hz` is measured over a 1 s window and decays to 0 when samples stop;
  forwarded libsurvive warnings are rate-limited to ≤ 1 line/s per message
  class; `python -m apollo_mavis_v2_runtime` configures Python logging (INFO to
  stderr) unless the root logger already has handlers.
- **Tracker calibration modes** (13-tracker §3 items 7–8, §4 "Calibration
  modes"; phase-10, 2026-09-03): `devices/tracker_calibration.py` —
  `TrackerCalibration(reader, settings, cfg, slot, session_active,
  clock=time.monotonic, wall=time.time)`, owned by `Runtime` (created in
  `Runtime.__init__`, `close()`d first in `Runtime.stop()`), never by the
  `ControlLoop` or the `SessionManager`. A worker thread runs the timed
  phases; `status()` is a cheap lock-protected `TrackerCalibrationStatus`
  (core §12) that `ws_telemetry.build_tracker_telemetry` copies into
  `tracker.calibration` at 25 Hz; `command(TrackerCalibrationCommand)` raises
  `CalibrationError(detail)` on an illegal transition (REST 409, §13.1). Both
  kinds require no active session (409 `"stop the session first"`) and
  `post_session` answers 409 `"tracker calibration in progress"` while one
  runs. **`base_station`** drives libsurvive through `TrackerReader.restart(
  args)` — `stop()` + join (`simple_close` frees the dongle; a premature
  re-`simple_init` is `LIBUSB_ERROR_BUSY`) → `self.cfg = cfg.model_copy(
  update={"libsurvive_args": args})` (the shared `TrackerConfig` is never
  mutated) → `start()`; `status()` reads `starting`/`searching` meanwhile —
  with the argument sets of 13-tracker §4: the normal `tracker.libsurvive_args`
  stripped of the `--globalscenesolver / --disable-calibrate / --configfile /
  --force-calibrate / --use-stationary-sensor-window` pairs, plus
  `--configfile <calibration_dir>/base_station-<ts>.json` (a temp copy of
  `tracker.libsurvive_config_path` — libsurvive rewrites whatever file it is
  pointed at) and `--force-calibrate 1 --globalscenesolver 1` (`start`),
  `--globalscenesolver 1` (`capture` = refine, keep the solution),
  `--globalscenesolver 0 --disable-calibrate 1 --use-stationary-sensor-window
  0` (`validate`, moving-mode sensor window). Progress comes from the reader's
  new INFO-line queue (`TrackerReader.info_lines`, level ≥ 2, ANSI stripped,
  optional `on_info` callback on the C thread that must never raise — the
  reader used to forward warnings only): `Force calibrate flag set`
  (`starting` → `capturing`), `Global solve with N scenes for M` (per-station
  `scenes`, status = max), `Using LH i (serial) as reference lighthouse`,
  `OOTX not set for LH in channel c`; plus `TrackerReader.lighthouses()`
  snapshots (0.5 s poll of `ps.SurviveSimpleObject_LIGHTHOUSE` objects: name,
  serial, latest pose) for `channel` / `stations_visible`, and
  `controller_still` from the `slot` (`still_window_s`, `still_threshold_mm`).
  The regexes are pinned to the libsurvive commit built by
  `scripts/tracker/02-build-pysurvive.sh`. `validate` gates on `scenes ≥
  tracker.calibration.min_scenes` (409 with the missing count), then after
  `validation_skip_seconds` collects `validation_seconds` of valid samples and
  passes when every per-axis std < `validation_std_mm` and the max adjacent
  step < `validation_step_mm` (`CalibrationValidation`); `install` requires
  `validation.passed`, backs the real config up as `<path>.bak-YYYYMMDD-HHMMSS`,
  copies the temp bytes over it, keeps `<calibration_dir>/base_station-<ts>-
  installed.json`, writes `base_station_installed_at` /
  `lighthouse_config_sha256` / `yaw_valid=false` to the persisted file and
  restarts the reader with the normal args (`detail = "installed — run Yaw
  alignment"`); `abort` restarts with the normal args from any phase and
  leaves the temp file for forensics. **`yaw`** collects seven raw
  lighthouse-world points — rising edge of `controller.trigger_pressed` on a
  fresh valid sample (worker polls the `slot` at ~50 Hz) or REST `op:
  capture`; a point = mean raw position over `yaw_capture_average_s` — then
  `fit_yaw(points, cfg)` (pure function, 13-tracker §4) fits `θ` over the four
  horizontal legs against the operator axes (left +X, forward −Y, right −X,
  back +Y; `p_world = Rz(yaw)·p_raw` like `align_pose`) with the
  `yaw_min_leg_m` / flatness / up-down sign / `yaw_max_residual_deg` checks;
  `apply` (409 while `fit_checks` is non-empty) calls
  `settings.update(yaw_deg=fitted)` and persists `yaw_deg`, `yaw_valid=true`,
  `yaw_calibrated_at`. Persistence: `<calibration_dir>/tracker_calibration.json
  {yaw_deg, yaw_valid, yaw_calibrated_at, base_station_installed_at,
  lighthouse_config_sha256}`, read in `Runtime.__init__` before
  `TrackerSettings.from_config` — a valid persisted `yaw_deg` overrides
  `tracker.yaw_deg` (the YAML is the boot default, §14). No handler does motion
  work and nothing here touches the control loop: calibration is refused while
  a session exists, and a reader restart is otherwise just a stale-sample hold.

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
  2 mm/tick; on hardware the bring-up lowers `jog.*` to the connected
  driver's servo bounds, so the panel runs at the arm's own rate — §5 step
  11), joint-space direct (no IK), then gate → `q_cmd`. New targets
  overwrite (LatestSlot). **Any delta is accepted** (the 0.15 rad
  `goto_threshold_rad` nack was dropped 2026-09-07, operator's call): a jog
  target is a DESTINATION, never a step, so a large delta is just a longer
  constant-speed move and every intermediate posture is gated like any other
  command. The UI joint panel is exactly this and has no second mode — a slider
  drag is followed continuously and dragging faster than the arm can move leaves
  it trailing and catching up. The price is that a straight joint-space line into
  an obstacle is HELD by the gate instead of routed around it.
  A jog step is multiplied by the **WS input watchdog** scale like any other
  WS-sourced motion, so a latched deadman silently drops it (`_jog_step` returns
  None at `scale <= 0.0`). Since the jog outranks teleop in `_resolve_arms` and
  the deadman check returns before `JogState.step` can retire the target, a
  pending target used to wedge the arm in `JOINT_JOG` for the rest of the
  session — it froze the 2026-09-07 live session. The latch edge therefore calls
  `JogState.clear_all()`: the arm falls back to teleop and no stale destination
  resumes when the browser returns (11-safety §10.1, 05-ui §5.2).
- **Interruptible plans (2026-09-07, phase-13).** `execute_plan {interruptible:
  true}` is the return-to-start motion (§10.5): a jog on ANY arm, an arm switch,
  a takeover toggle, a browser disconnect, a driver fault (all interruptible
  plans) or the PRESENCE of any movement code from any source — regardless of
  the WS watchdog scale — cancels it (`ControlLoop.plan_cancel_reason`: `jog`,
  `arm switch`, `movement key`, `browser disconnected`, `driver fault`); the
  internal `cancel_plan` op cancels it from a worker. The profile's gripper
  target is applied on arrival, never at load. `start_from` and rail-homing
  plans stay non-interruptible (held movement key only, as before).
- **`goto`** (twin-planned routing; no longer reachable from the joint panel,
  kept for the profile `start_from` and rail-homing paths): build a core
  `PlanRequest`
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
  watchdog enters AWAIT_EMPTY. The arm additionally stays held (RECOVERING)
  until a tick whose inputs — sampled after the re-seed — hold nothing live:
  the device clutch must be released (the next press is a rising edge with
  zero delta) and WS codes must be up or watchdog-latched (phase-09b, §5).
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

## 10. EpisodeRecorder — episode-directory store (LeRobot v3 is an export)

Status (2026-09-07, operator decision; **10-frames §11 is the layout
authority**, this section is the runtime's side of it; implementation:
`docs/prompts/phase-13-keyboard-episode-datasets.md`). The recorder writes
**one directory per saved episode** under the dataset root
(`episodes/<episode_id>/{frames.parquet, video/<camera_id>.mp4, audio.wav,
episode.json}`) and a **LeRobot v3 dataset is derived** from those directories
by an export job — a remux, never a re-encode. Phase-07 (v0.1 of this
section) wrote LeRobot v3 directly through `LeRobotDataset.create / add_frame
/ save_episode / clear_episode_buffer / finalize`; a 2026-09-07 interim
variant (v3 with a 1 MB `video_files_size_in_mb` cap so lerobot's
`delete_episodes` would copy whole files) was written but never shipped —
deleting one episode still rewrote every parquet, renumbered every index and
loaded torch on the REST path, and the layout was not per episode. The row
schema (§10.2), the frame conversion (§10.3), the 25 fps pacing and the
100 Hz interpolation rule are unchanged. The code in the working tree as of
2026-09-07 is still the interim variant — phase-13 replaces
`LeRobotEpisodeRecorder`, `recorder_state.json` / `repair_unfinalized_datasets`,
`pending_delete` / `finalized`, `meta/apollo/audio/`, extends
`dataset_incompatibility` to the feature `info` blocks and renames the
"is being rewritten" 409 to "is being exported".

### 10.1 Ownership & API

`RecorderThread` is still the **single owner** of the episode being written:
all other threads talk to it via its inbox (episode ops from the CommandBus)
and the `snapshot` slot. It drives an `EpisodeDirRecorder` that implements
core's `EpisodeRecorder` ABC (core §5.2):

```python
# recorder/episode_recorder.py
class EpisodeDirRecorder(EpisodeRecorder):
    def __init__(self, cfg: RecorderConfig, features: dict, root: Path,
                 repo_id: str, robot_type: str, default_task: str): ...
    # open or create <root>/manifest.json (10-frames §11.5); a resumed dataset is
    # checked with dataset_incompatibility() BEFORE anything else (fps, robot_type,
    # feature signatures incl. the info blocks) -> SessionError (409); the encoder
    # is pinned from manifest.video (codec family; "auto" re-probes within it,
    # 10-frames §7.5); every stale episodes/.tmp-* is swept (§10.4)
    def start(self, meta: dict[str, object]) -> None: ...
    # episode_new (CONTROL-LOOP thread, via RecorderThread.request): mint
    # episode_id (10-frames §11.3), remember meta (task etc.), empty the row
    # buffer — no filesystem or thread creation here; the RECORDER thread
    # then immediately mkdirs episodes/.tmp-<id>/ and calls
    # StreamingVideoEncoder.start_episode(video_keys, temp_dir=that dir)
    # (its 160-330 ms GIL stall lands right after N, §10.5 "GIL stall")
    def add_frame(self, frame: dict[str, object]) -> None: ...
    # recorder thread; feed_frame() per camera and append the non-video
    # columns + timestamp (frame_index / fps), frame_index, task to the
    # in-memory buffer (idle-frame filter applied first, §10.5); count the
    # frames fed per camera
    def save(self, sidecar: dict[str, object],
             audio: EpisodeAudioSink | None = None) -> tuple[int, str]: ...
    # finish_episode() -> {key: (mp4 path, stats | None)}; move each mp4 to
    # video/<camera_id>.mp4 and rmtree the encoder's tmp*/ leftovers; verify
    # fed - encoder._dropped_frames == rows per camera and stats is not None
    # (else export_ok False + export_note); frames.parquet (pyarrow, one row
    # group); non-video stats (lerobot compute_episode_stats semantics), video
    # stats reshaped (3,1,1) / 255 like lerobot's writer; audio.finish() into
    # the tmp dir; episode.json = sidecar + video/audio/stats blocks, LAST;
    # os.replace tmp -> episodes/<id>/; refresh manifest counters +
    # last_export.stale; returns (ordinal in capture order, episode_id).
    # RecorderThread assembles `sidecar` (extrinsics, frames_dropped,
    # gate_events, episode_summary, meta_base) BEFORE calling save, so the
    # sidecar is inside the directory at publication; its _episode_saved hook
    # (DAgger spool) receives (ordinal, episode_id)
    def discard(self) -> None: ...      # cancel_episode(); rmtree the tmp dir
    def finalize(self) -> None: ...     # idempotent: discard an open episode,
                                        # close the encoder, sweep; nothing can
                                        # be left half-written
    @property
    def episodes_saved(self) -> int: ...  # manifest.episodes
    @property
    def total_frames(self) -> int: ...    # manifest.frames
    @property
    def episode_id(self) -> str | None: ...  # the open episode's id
```

Loop: paced at `cfg.fps` (default **25**, range 20–30) off the `snapshot`
slot; per frame pull `read_latest()` from each recorded camera (max_age
2/fps, else drop the whole frame + count `frames_dropped`); one-frame
lookahead so `action` is the delta of the commanded TCP between consecutive
recorded frames — `FK(q_cmd[k]) → FK(q_cmd[k+1])` at the twin site `link_tcp` — and
`action.abs_ee` (2026-09-11) is that same `FK(q_cmd[k+1])` as an absolute r6 pose
(10-frames §6); `add_frame`. The 100 Hz control loop is never recorded
directly — it interpolates between recorded actions (lerobot
`interpolation_multiplier` pattern, here 100/fps = 4). Encoding: lerobot's
`StreamingVideoEncoder` with `rgb_encoder.vcodec="auto"` → NVENC
(`h264_nvenc`, `bf=0` for lerobot's `g=2`; a resumed dataset keeps its codec
family — 10-frames §7.5) on the 4090s, one encoder thread per camera per
episode, so saving is near-instant (a rename). `lerobot` is imported lazily
inside `recorder/` only; the REST listing path (§10.6) never imports it.

### 10.2 Dataset schema (always, every mode that records)

One dataset repo per **(task × arm-count × frame convention)**; repo id
`apollo/xarm7_{task}_{n}arm_{conv}` (grammar: 10-frames §8.1) when
`SessionSpec.dataset` is None, else the operator's `<ns>/<name>` (§10.5),
under `cfg.datasets_root`. `robot_type` distinguishes real (`xarm7_{n}arm_rail`)
from sim (`xarm7_{n}arm_rail_mujoco`) — 10-frames §7.5.

```python
# Per-arm blocks. action_space literals are core's PolicySpec set —
# "delta_ee" | "abs_ee" | "joint" — with **delta_ee canonical** (required for
# new DAgger-intended policies, 12-dagger §6):
ARM_ACT = ["ee.dx", "ee.dy", "ee.dz", "ee.drx", "ee.dry", "ee.drz",
           "gripper.pos"]                    # + "rail.dpos" if rail (delta_ee layout, 8/7)
ARM_ABS = ["ee.x", "ee.y", "ee.z",           # abs_ee layout (11/10, 2026-09-11): TCP position,
           "ee.r00", "ee.r10", "ee.r20",     #   the first two COLUMNS of its rotation matrix
           "ee.r01", "ee.r11", "ee.r21",     #   (r6, Zhou et al. 2019; 10-frames §3.1),
           "gripper.pos"]                    #   absolute gripper; + "rail.pos" if rail
ARM_OBS = ([f"joint{i}.pos" for i in range(1, 8)] + ["gripper.pos"]  # + "rail.pos" if rail
           + ["ee.x", "ee.y", "ee.z", "ee.qw", "ee.qx", "ee.qy", "ee.qz"])
           # 10-frames §6.1: state = joints, gripper, rail, then the MEASURED TCP pose =
           # the twin FK of the measured joints at link_tcp (2026-09-11: never the
           # driver's ee_pose), ee.* in the arm's declared recording frame; 16/15 dims
features = {
  "action": {"dtype": "float32", "shape": (D,), "names": per_arm_act_names,
             "info": {"apollo_schema": 1,
                      "action_space": "delta_ee",  # core literal; delta_ee canonical
                      "frames": {arm_id: frame_ref, ...},
                      "rail": {"axis": "y", "travel_m": 0.65, "arms": [...]}}},
  # ALWAYS written next to `action` (2026-09-11; recorder/features.py ABS_EE_KEY): row k =
  # the COMMANDED TCP + carriage at frame k+1 = FK(q_cmd[k+1]) in the recording frame,
  # gripper.pos identical to the delta column's. Older datasets: tools.backfill_abs_ee
  # (10-frames §11.11). `label` / `rotation` are informative; the compatibility
  # signature compares the four convention keys only.
  "action.abs_ee": {"dtype": "float32", "shape": (D_abs,), "names": per_arm_abs_names,
                    "info": {"apollo_schema": 1, "action_space": "abs_ee",
                             "frames": {...same map...}, "rail": {...same...},
                             "label": "commanded_tcp_at_next_frame",
                             "rotation": "rot6d_first_two_columns"}},
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

Plain teleop writes `intervention=False`, `action_source=1`. The lerobot
bookkeeping columns `episode_index` / `index` / `task_index` are assigned by
the export (10-frames §11.8); `timestamp` and `frame_index` are written by the
recorder; none of them is ever in an `add_frame` dict. `features` (with the
info blocks) is stored in `manifest.json` and is what a resumed session must
match.

### 10.3 Frame conversion at record time

Frame conversion applies to **EE-space quantities**: each arm's
`executed_action` block (`delta_ee` / `abs_ee`) AND the `ee.*` dims of
`observation.state` are converted into the arm's declared recording frame
(`SessionSpec.frames[arm_id]`: `arm_base:<id>` | `world` | `camera:<id>`)
**before** `add_frame` (per `10-frames-and-data.md` §3, §6.1).
Joint/gripper/rail dims — and whole `action_space == "joint"` blocks — are
frame-free (10-frames §3.4) and pass through unconverted. Frames are fixed per dataset (mixing frames in one
`action` feature is statistically toxic).

**Where the poses come from (2026-09-11, `recorder/thread.py`).** Every EE quantity
is the twin's forward kinematics at the site `link_tcp` (`RecorderKinematics.tcp_base`
/ `base_world`, the session's twin scene) — never the driver-reported `ArmState.ee_pose`:

- `observation.state` `ee.*` = `FK(q_meas)` of the frame's measured joints and
  carriage, converted with the measured base pose. Kind-independent, so sim, hardware
  and backfilled episodes agree bit-for-bit (10-frames §6.1). (The hardware driver's
  `ee_pose` is the same TCP since 2026-09-11 — flange ⊕ (Rz(π), +0.172 m) on a gripper
  arm, the flange itself on the Perception Arm — but the recorder does not read it.)
- `action` row `k` = the increment `FK(q_cmd[k]) → FK(q_cmd[k+1])` of the post-gate
  COMMANDED joints (the one-frame lookahead), deltas rotated into the recording frame.
- `action.abs_ee` row `k` = `FK(q_cmd[k+1])` converted with the FULL commanded base
  pose `base_world(q_cmd[k+1])` (the carriage moves the base — matters for `world` /
  `camera` frames; identity for `arm_base`), rotation encoded `quat_to_rot6d`, the
  gripper dim the same value as the delta column's, the commanded carriage at `k+1`. Camera-frame choices snapshot the
extrinsics into episode metadata. On hardware the kinematics for the
conversion and the wrist-camera extrinsics come from the digital-twin
`BuiltScene` (the MJCF camera `<id>` or `<id>_cam` stands in for the real
camera; the factory D435 intrinsics from `CameraConfig.intrinsics` go into
`episode.json`).

### 10.4 Crash safety

An episode lives in `episodes/.tmp-<episode_id>/` until `save()` renames it
into place; `episode.json` is written last, so a directory without it is by
definition incomplete. TEARDOWN, SIGINT/SIGTERM and the `finally` in
`RecorderThread.run` all call `discard()` (if an episode is open) then
`finalize()` exactly once; `finalize()` failures are logged and retried once.
At every open — session start, `DatasetStore` scan, `Runtime.start()` —
`sweep_incomplete_episodes(datasets_root)` removes stale `.tmp-*` directories
(those not owned by the running session) and logs them. There is no
`recorder_state.json` and no `resume() + finalize()` repair any more: a
parquet is only ever written whole. Invalid transitions (`episode_save`
while `saving`, `episode_new` while `recording` or `returning`, an empty
episode) → Ack `ok=false`; the UI follows telemetry `EpisodeStatus.state ∈
idle|recording|saving|returning` (`returning` only with `return_to_start`,
§10.5).

### 10.5 Dataset naming & resume, return-to-start, audio (2026-09-07)

- **Naming.** `SessionSpec.dataset` names the repo (`DATASET_RE`; a bare
  name is prefixed `apollo/`; the UI slugs the operator's text); `None` keeps
  the phase-07 task-derived grammar. `dataset_resume: false` ⇒ the dataset
  must NOT exist yet (409 `"dataset 'apollo/x' already exists - choose
  'Continue existing' to append to it, or another name"`); `true` ⇒ it must
  exist (409 `"unknown dataset 'apollo/x' - it has no recorded episode yet;
  start it as a new dataset instead"`) and `dataset_incompatibility(manifest,
  features, fps, robot_type)` must be `None` (409 `"dataset 'apollo/x' cannot
  be continued by this session: <why> - record into a new dataset"`, where
  `<why>` names the fps, `robot_type` (sim vs hardware, arm count), feature
  set, or the first differing feature signature / info block). A legacy
  phase-07 v3 tree (`meta/info.json`, no `manifest.json`) is 409 `"dataset
  'apollo/x' is a legacy LeRobot v3 dataset (read-only; already trainable
  as-is) - record into a new dataset"`. All of this runs in `SessionManager.create`
  **before any box or camera is touched**; a repo an export job is rewriting
  is 409 `"dataset … is being exported - retry in a moment"`.
- **Hardware collect.** `_validate_hardware` admits `mode ∈ {teleop,
  collect}`; the recorder is built inside `_bringup_hardware` after the rig
  connects and `start_from` is planned, reading the **adopted** preview
  cameras (no second UVC open; none live → 409 `"data collection needs at
  least one live hardware camera - none is open (see the Hardware tab camera
  tiles)"`), and started after the loop; bring-up progress shows a `recorder`
  row per arm (`pending` → `ok "recording into <repo_id>"`). A dataset refusal
  during bring-up tears the rig down (409) and leaves no directory behind.
- **Return-to-start (DEFAULT ON, operator decision 2026-09-07; per-session
  opt-out).** `SessionSpec.return_to_start: bool = True` (Collect LaunchSheet
  checkbox "Return to start after save / discard", checked by default) makes
  every save and discard end with a motion back to the **return profile** —
  the `start_from` profile if one was chosen, else the kind's designated
  initial-condition profile; with neither and the flag on, the POST is 409
  `"return_to_start needs a start_from profile or an initial-condition profile
  - set an initial condition or untick 'Return to start'"` (the LaunchSheet
  disables Start with the same reason first). The motion is
  the `start_from` machinery: `twin.plan(PlanRequest(q_start=measured,
  q_goal=profile))` on the session's twin (gate twin on hardware), executed as
  an `execute_plan` command at the session's speed scale; while it runs
  `EpisodeStatus.state == "returning"` with `detail` (`"returning to profile
  'ready'"`), `episode_new` is nacked `"returning to the initial
  configuration"`, and ANY operator input — a held key, a clutch engage, a
  jog, an arm switch, a device edge — cancels it (`detail "return cancelled:
  movement key"` / `"… : jog"` / `"… : arm switch"`, arm holds where it is).
  Cancellation keys on the PRESENCE of a movement code from either source,
  never on the WS watchdog scale (a key held under a latched deadman must still
  stop the return); a browser disconnect cancels too, and a return is not even
  started while the deadman is tripped / latched (`detail "return skipped:
  browser input latched - release every key"`). The plan runs as an
  interruptible `execute_plan`; the profile's gripper target is applied on
  ARRIVAL, never at plan load, so a cancelled return leaves the gripper
  untouched. The worker's deadline is derived from the plan (`plan_duration_s`
  over the waypoints incl. the rail slot, × 3 + a gate-hold allowance, ≥ 30 s);
  on expiry or on any non-RUNNING exit it cancels the plan through the loop
  (`cancel_plan` op) and only then reports (`"return timed out - held by the
  gate; arm stopped"`, `"return cancelled: driver fault"`, `"return skipped:
  session <state>"`, and since 2026-09-08 evening `"return stopped - held by the
  safety gate: <body a> / <body b> at <mm> mm"` from the loop's gate-held abort
  below); `returning` stays true until the plan is really gone. The budget and
  the wait are PER ARM (see "Sequential execution" below): a two-arm return
  reports `"return cancelled: movement key - Perception Arm; Manipulation Arm
  not moved"` — which arm was interrupted and which never started.
  Teardown cancels an in-flight return before stopping the recorder, so the
  arm is braked at rest, not mid-move. A planning failure produces no motion
  (`detail` carries the planner's reason, state back to `idle`). This is not the "blind
  return to initial" the overview forbids for inference (overview §4 item 4 /
  §12): it exists only in collect, is twin-planned, gated and cancellable, can
  be unticked per session, and inference never has it.
  `return_profile_id` is recorded in `episode.json`.
- **Return to the initial condition on demand and on the way out (operator
  request, 2026-09-08).** The same planned motion as above, aimed at the
  workcell kind's **designated initial-condition profile**, reachable two ways:
  - the `reset_to_initial` key (`R`, 01-core §13) over /ws/control —
    fire-and-forget: `ControlLoop._op_reset_to_initial` validates inline (fast)
    and hands the motion to `SessionManager.request_reset_to_initial`, whose
    ack only says it started (`"returning to '<profile>'"`). A no-op **with a
    reason** when there is nothing to return to (no profile store, or no
    initial condition designated for this kind) — `ack.ok=false`, nothing
    moves, the UI toasts the reason. Also refused while an episode records
    (`"recording - save or discard first"`) or another plan runs.
  - `POST /api/session/return_home` → `ReturnHomeResult{ok, status ∈
    done|skipped|failed|cancelled|timeout|refused, detail, arms, profile_id}`
    — **synchronous**, which is what the Cockpit's "End session" /
    "Terminate session" runs *before* the DELETE (05-ui §8.2). Operational
    refusals are a 200 with `ok=false`, never an HTTP error: the UI branches on
    `ok` and shows `detail`. `skipped` is a SUCCESS (no initial condition
    designated, the profile covers no session arm, or the arms are already
    there), so a workcell without one behaves exactly as before.

  The motion runs as **two separately planned and gated phases** (operator
  decision: sliding a carriage with the arm extended sweeps it through the
  cell, folding first does not): (1) the joints to the profile's posture with
  each carriage HELD where it is — enforced by the planner since 2026-09-09: a
  rail slot whose start and goal coincide is pinned for the whole plan, escape
  included (03-sim §10 item 2; before, the RRT could slide a carriage 12.6 cm
  inside this phase); (2) the carriages to the profile's
  `rail_pos_m` with the joints held. A phase whose start already equals its
  goal is skipped, phase 2 never runs if phase 1 did not arrive, and a profile
  storing no rail (`rail_pos_m: None` = keep the carriage — how
  `profiles.seed_initial` writes the seeded default) has no phase 2 at all.
  Both phases go through `twin.plan` → interruptible `execute_plan`, so ANY
  movement key / clutch / jog / arm switch cancels the motion and the arms hold
  where they are; the profile's gripper target rides the last phase that runs
  and is applied on arrival. Preconditions (`SessionManager._reset_precheck`):
  a running session, no open episode, no faulted / recovering arm, no plan in
  flight. `_return_goals` / `_plan_return` / `_run_return_plan` are shared with
  the per-episode return above, which stays SINGLE-phase and byte-identical in
  its reporting.

  **Headless proof (2026-09-09).** `tests/test_return_fuzz_mavis_v2.py` replays
  this whole flow — `_return_goals` (imported), the phase split, `twin.plan` at
  the session speed, `_ordered_waypoints` / `_moving_arms`, `PlanExecutor` at
  the hardware caps, the loop's step cap, every tick through the real
  `SafetyGate` with the gate seeded as a live session finds it, the
  `plan_gate_hold_s` abort and the measured-arrival check — from random
  pinched two-arm starts on the mavis_v2 twin (`MAVIS_FUZZ_N`, default 40 plus
  10 normal; `MAVIS_FUZZ_SPEED`, `MAVIS_FUZZ_SEED`) and asserts: a plan the
  planner accepts is never held by the gate and both arms arrive, or the
  planner fails honestly naming a pair. It found the three planner fixes of
  03-sim §10 items 2 / 5 (RRT margin predicate, held carriage, budget use).

  **Sequential execution (2026-09-08 evening; BINDING, 11-safety §9).** Every
  twin-planned multi-arm motion — both return phases, the per-episode return,
  `start_from` on sim and hardware, `goto_profile` (all through
  `SessionManager._execute_arms`) — executes **ONE ARM AT A TIME in
  `PlanResult.arm_order`** (fallback: the waypoints dict order;
  `_ordered_waypoints` re-keys the dict in `arm_order`). `ResetPlanner` (03-sim
  §10) validates arm k with the arms before it AT their goals and the arms
  after it AT their starts, so the paths are collision-free in that order and
  in no other. *Incident, 2026-09-08 23:16:52 (`var/logs/runtime.log`):* the
  first live `reset_to_initial` planned both arms sequentially but
  `_run_return_plan` submitted ONE `execute_plan` carrying both arms' waypoints;
  `PlanExecutor` moved them simultaneously through never-validated
  combinations, the gate blocked at 5.2 mm (`grip_right_finger` /
  `view_link3`) and the return sat gate-blocked ~30 s until the budget. Rules,
  as implemented: one `execute_plan` per arm carrying that arm's waypoints
  only; the next arm is submitted when `plans.active_arms` is empty again; an
  arm the planner left in place (every waypoint within 1e-6 of the first) is
  not submitted at all; the profile's gripper targets ride the LAST arm that
  moves and an interruptible plan applies them on THAT arm's arrival (the
  loop defers every gripper target of an interruptible plan, including one for
  an arm the command does not move); any refusal / cancel / fault / timeout of
  one arm stops the sequence — the remaining arms never start and the detail
  names the arm (`"<reason> - <Arm>; <other arms> not moved"`; a single-arm
  sequence reports exactly as before; a refusal of a LATER arm carries the
  same suffix, so the notice says the earlier arms did move); the budget
  (`_return_budget_s`) is per arm from that arm's waypoints (`start_from`:
  `max(120 s, budget)`); `session.start_from_progress` keeps counting over ALL
  arms' waypoints; a `start_from` that is cancelled / held / timed out
  part-way now writes the notice `"start_from cancelled: <reason> - <Arm>;
  <arms> not moved (Go to profile retries it)"`. **Hand-over on MEASURED
  arrival (2026-09-08 review).** `plans.active_arms` emptying only means the
  COMMAND reached the last waypoint; a carriage follows its latest-wins
  targets at the track's own speed. `_execute_arms` therefore waits
  (`_await_arrival`, 20 ms polls of the driver's cached states) until arm k's
  measured q is within `PLAN_ARRIVAL_TOL_RAD` 1e-3 rad (every joint) and
  `PLAN_ARRIVAL_TOL_RAIL_M` 2 mm of its last waypoint before arm k+1 is
  submitted (and before the last arm is reported done); the wait shares the
  arm's budget deadline with at least `PLAN_ARRIVAL_GRACE_S` 2 s after the
  executor retired the waypoints, and reports the new status **`stalled`**
  (`"did not arrive: joints off by <mrad>[, carriage off by <mm>] after <s>"`,
  wire status `timeout` on the reset / exit path, `"return stopped - …"` on
  the per-episode return, `"start_from stalled (the arm did not settle at its
  goal): …"` notice) when it never gets there — the remaining arms never
  start. The tolerance doubles as the parked-arm threshold (`_moving_arms`:
  every waypoint within 1e-3 of the first ⇒ not submitted; a start that
  differs from the goal by the SDK's ~1e-4 rad read-back noise is no longer a
  1–2 tick micro-plan). A profile that moves no arm but sets a gripper still
  submits ONE gripper-only `execute_plan` (`waypoints: {}`), which the loop
  applies at once (`ack "done"`) — before, the targets were silently dropped
  (`start_from` regression). **The hardware executor's rail slew is capped at
  the track's positioning speed** (`ExecutorCaps.rail_m_per_tick` =
  `rail_speed_mm_s` (already speed-scaled) / 1000 / `rate_hz`, read from every
  connected driver's config by `executor_caps_for`, applied by
  `apply_executor_caps` as `min(jog.rail_m_per_tick, cap)` — 0.0005 m/tick at
  100 % against the host's 0.002), so the commanded carriage never runs ahead
  of the track; `_return_budget_s` follows automatically. **The loop is the
  last line too (2026-09-08 review):** `execute_plan` refuses a command
  carrying more than one arm's waypoints (`"one arm per plan (sequential
  execution)"`), the joint panel's `goto` is refused with `"plan executing"`
  while ANY plan executes or is being planned (it would have loaded a second
  arm into the executor beside a running `start_from`, planned with the
  other arm frozen at a mid-path posture), and a `_plan_ready` result
  arriving while a plan runs is dropped (per-arm `failed`). **A plan is
  finished AFTER the gate:** `_plan_step` parks the executor's goal in
  `_plan_arriving` and `_confirm_plan_arrivals` (after `supervisor.filter`)
  reports `done` only when the gated output IS the goal; a final step the
  gate (or the per-tick clamp) held goes back into the executor as a
  one-waypoint plan, so `active_arms` never empties one slew step short,
  the deferred gripper is never applied on an arm that has not arrived and
  the gate-held watch sees the hold. `_gate_hold_pairs` no longer prints the
  pair-less report's 1.0 m default for a hold inside the hysteresis band: it
  asks the twin (`pair_distance(pair, None, 0.5)`) or names the pair alone.
  `tests/test_sequential_plan_execution.py`.

  **Gate-held abort (2026-09-08 evening; `hardware_session.plan_gate_hold_s`,
  default 3.0 s, `ge=0`, honoured on sim loops too).** While a plan executes,
  `ControlLoop._plan_gate_watch` (control thread, after the gate, O(active arms)
  per tick, no allocation) starts a clock on the first tick where the gate
  blocked and every executing arm's gated output equals its last command (no
  waypoint progress), resets it on any progressing tick, and past
  `plan_gate_hold_s` cancels the plan with `plan_cancel_reason = "held by the
  safety gate: <body a> / <body b> at <mm> mm"` (`GATE_HOLD_PREFIX`; pairs from
  the gate report, else the merged report, else the gate's block pairs;
  `"stale digital twin"` on a stale-twin hold), telemetry `plan_status:
  "cancelled"`, the arms hold where they are. The manager maps the prefix to an
  internal status `held`: the per-episode return reports `"return stopped -
  held by the safety gate: <pair> at <mm> mm"`, the reset / exit dialog text is
  `"the motion was held by the safety gate[ while moving the joints] and
  stopped (<pair> at <mm> mm - <Arm>; <arms> not moved). The arms hold where
  they are."` with wire status `timeout` (the `ReturnHomeResult` literal for
  "held by the gate, stopped where they are") — the real-budget `timeout`
  branch (`"… and stopped part-way (budget 30.0 s)."`) is unchanged and remains
  the outer bound. `0` = the first held tick cancels.

  `teardown()` is unchanged: it still cancels an in-flight plan and produces no
  motion of its own, so a SIGTERM or a client that skips `return_home` leaves
  the arms braked at rest rather than starting a move nobody is watching.

  **Outcome, serialization, refusals (2026-09-08 review).**
  - *The outcome is never silent.* `R` and `goto_profile` ack "started"; the
    worker's result — a phase the twin could not plan, a refusal, a gate
    timeout, an operator cancel, a skip ("already at profile 'shelf'" under the
    goto label, "already at the initial condition" otherwise) — is written to
    `ActiveSession.motion_detail` as `"<Go to profile '<name>' | Return to the
    initial condition>: <phase text>"` and published as
    **`SessionTelemetry.fault_detail`** / `SessionInfo.fault_detail` (§13.3),
    which the Cockpit's FaultBanner shows as an amber `SESSION — …` row. The
    same field carries a refused / unplannable `start_from`
    (`"start_from refused: Manipulation Arm faulted (controller state 4, code
    C24) - use Clear errors & resume, then Go to profile"`; a RECOVERING arm
    reads `"… is recovering - release every input (clutch / keys), then Go to
    profile"` because RECOVERING is lifted by releasing the inputs, not by
    clearing errors). `motion_detail` is separate from `fault_detail` (the
    arms' fault text the callback wipes on RUNNING) so the hint survives the
    fault cycle; it is replaced when the next profile motion starts and cleared
    when one arrives (incl. the per-episode return). On the wire the notice wins;
    the fault text is only sent while no arm row carries a fault.
  - *One profile motion at a time.* The manager-side blockers run BEFORE a worker
    plans (`twin.plan` takes tens to hundreds of ms), so the per-episode return,
    `R`, Go to profile and the exit return are serialized behind one token
    claim (`_claim_profile_motion`; refusal `"a planned motion is already
    running"`, the per-episode return reports `"return skipped: a planned motion
    is already running"`), and the loop's `_op_execute_plan` nacks
    `"plan executing"` while any plan is active or planning — `PlanExecutor.load`
    would otherwise replace the running waypoints. `_reset_blockers` also says
    `"an episode is still saving - wait for it to finish"` while the recorder is
    saving (the episode directory is still open) instead of asking to save it.
  - *Policy modes.* In a DAgger / inference session `GatedPolicyExecutor` nacks
    `reset_to_initial` / `goto_profile` with `"policy driving - take over (Space)
    first"` while the policy is active and no arm is engaged: the plan would
    pre-empt the rollout arm by arm with the runner still producing ignored
    actions, and the overview's rule that inference never "returns to initial"
    on its own stands. After a takeover the human is the driver, the policy's
    arms hold, and the motion is allowed exactly as in teleop; a hand-back
    re-queries the policy from the new posture (no jump — the anchor is measured
    ⊕ Δ). Between DAgger episodes (recorder idle) nothing is refused here.
  - *`start_from` fault grace (2026-09-08 late evening, as implemented).* Right
    after enabling, the real controller reports state 4 for ONE tick and the
    loop marks the arm RECOVERING (Reseed / Recovered); on 2026-09-08 (03:25
    `grip`, 18:44 `view`) the pre-planned `execute_plan` was drained in exactly
    that tick, `_op_execute_plan` refused it (`"arm 'view' is faulted"`) and
    the plan was dropped silently. `_start_from_worker` now polls every 50 ms
    (`START_FROM_FAULT_POLL_S`) until `loop.faulted_arms | loop.recovering_arms`
    is empty and the session is not FAULT / RECOVERING, bounded by ONE deadline
    `HardwareSessionConfig.start_from_fault_grace_s` (default **3.0 s**, `ge=0`,
    `0` = submit at once; a pydantic default in `config.py` — neither
    `configs/mavis_v2.yaml` nor the lab render carries the key, so a rendered
    config inherits 3.0 unless the operator adds it under `hardware_session:`);
    a refused ack is retried ONCE with the same waypoints if the arms clear
    within the remaining grace; a persistent fault is left to the loop (never
    move a faulted arm) and reported as the refusal text above. The 3.0 s
    default is generous against the ~10 ms transient — lowering it once seen
    live is the operator's call (`tests/test_return_manager_units.py`).
  - *`start_from` bookkeeping.* The worker follows the EXECUTOR (`plans.active_arms`,
    TEARDOWN) once the loop accepted the plan, not `session.state`: a transient
    fault mid-plan walks the session START_FROM → FAULT → RECOVERING → RUNNING
    through the callback while the other arm's waypoints keep executing, and
    `start_from_progress` / the bring-up rows (`_bringup`) are cleared when the
    motion is over on every exit path (plan failure, refusal, arrival, crash).

  **Seeding the default posture.** `python -m
  apollo_mavis_v2_runtime.profiles.seed_initial [--kind hardware|sim]
  [--dry-run]` writes the operator's 2026-09-08 default posture — Manipulation
  Arm `[-180, -12, -20, 30, -5, 35, -8.9]°`, Perception Arm
  `[0, 0.8, 0, 28.9, 0, 28.2, 0]°`, carriages unset — as one initial-condition
  profile per kind (idempotent: matched by name within the kind). Verified
  against the twin at both carriage ends, microphone on and off: collision-free
  with 107 mm to the nearest monitored pair, and plannable from the cell's
  keyframe (`tests/test_reset_to_initial.py`). Never run automatically —
  designating an initial condition changes what every return aims at.

  **Seeding the "Kitchen Interaction" posture** (operator request 2026-09-09
  evening; **amended 2026-09-10**). `python -m
  apollo_mavis_v2_runtime.profiles.seed_kitchen [--kind hardware|sim] [--dry-run]`
  writes ONE ordinary profile per kind, named **`Kitchen Interaction`**. Its job is
  to put the **Perception Arm** where the `mavis_v2_kitchen` twin was measured FROM
  (03-sim §4.4): `[2.646, -1.598, 0.018, 1.637, 0.25, 2.007, 0.029]` rad, framing
  the fridge / range / counter with its wrist D435i, carriage **pinned at 0.0** —
  every kitchen number was deprojected from a frame taken there, so the appliances
  only line up with the real cameras from that carriage position. The
  **Manipulation Arm is its entry in the DEFAULT posture, carriage left unset**
  ("keep it where it is"), and it is DERIVED from `seed_initial.default_profile`
  rather than copied, so the two can never drift apart. Consequence, and the point
  of the amendment: **a goto between the default posture and this profile moves the
  Perception Arm and nothing else.**

  Until 2026-09-10 the profile carried the kitchen SCENE's keyframe for the grip
  arm — the xArm7 factory zero `[π, 0, 0, 0, 0, 0, 0]` with the carriage pinned at
  0.65 — and both halves of that cost motion for nothing. Joint 1 of the factory
  zero is `+π` where the default posture's is `−180° = −π`: the same physical
  orientation, a DIFFERENT joint value, and the planner walks straight lines in
  joint space, so every goto rotated joint 1 a full **360°** before teleop could
  start (the operator's "it has to turn a full circle"). The 0.65 pin added an
  up-to-0.65 m carriage traverse whose only purpose was parking the arm at the far
  end. Neither is needed — the grip arm plays no part in the kitchen measurement.
  It still **never touches the initial-condition designation**, which stays with
  the default posture, and it is idempotent the same way (matched by name within
  the kind). **A store seeded before 2026-09-10 holds the old numbers — re-run it.**

  Verified 2026-09-10 collision-free on BOTH twins (`mavis_v2_kitchen` and
  `mavis_v2`), microphone off and on, at the cell's raised shell
  `geom_inflation_m = 0.025`, at **every** grip carriage position from 0.000 to
  0.650 m — that sweep is what allowed the pin to be dropped — with the tightest
  monitored pair `obstacle ↔ grip_rail_platform` at 75.3 mm
  (`tests/test_reset_to_initial.py`, which also pins "a goto moves the Perception
  Arm only" as an invariant). The pre-amendment posture was checked LIVE on
  2026-09-09: from both arms at the seeded default the same planner the goto uses
  found a path on both twins at the raised shell — `arm_order ['view', 'grip']`, 2
  and 3 waypoints, executed one arm at a time. Not yet EXECUTED on the real arms.
- **GIL stall of the video encoder (measured 2026-09-07).** lerobot's
  `StreamingVideoEncoder` holds the GIL while PyAV opens (`start_episode`,
  160–330 ms) and closes (`finish_episode`, 118–324 ms with `h264_nvenc`, ≈ 15
  ms with `libsvtav1`) the per-camera encoders; every thread freezes — the
  100 Hz loop, the WS reader, the tracker reader, the servo streamer. On
  hardware nothing jumps (the streamer re-anchors after a late tick under the
  velocity / acceleration caps; the box holds the last servo target;
  `ArmReportWatchdog` fails the gate closed for the first tick after the
  stall), but the WS deadman trips on every save and a key held across the
  stall latches `AWAIT_EMPTY`. Mitigations in phase-13: the loop detects a
  process-wide stall (`now − last_tick > watchdog.timeout_s`), holds every arm
  for that tick and credits the stall once to the `InputWatchdog`
  (`on_process_stall`) so a frozen process is not read as a silent browser;
  the encoder is opened right after `episode_new` on the recorder thread (§10.1)
  rather than at the first frame of motion; the return-to-start cancel rule
  ignores the watchdog scale (above). The real fix — running the encoder in a
  child process — is a follow-up; `recorder.vcodec: libsvtav1` removes the
  finish stall at the cost of CPU (operator's choice, not changed here).
- **Idle-frame filter (2026-09-07, operator; default ON).**
  `SessionSpec.action_filter: ActionFilterConfig{enabled: true, pos_eps_m:
  0.001, rot_eps_rad: 0.001, gripper_eps_frac: 0.01, rail_eps_m: 0.001,
  gripper_context_s: 1.6}` (core §12) ports the hesitation filter of the
  operator's pro-dagger project (`_land_chunk` / `_anzu_chunk_first_idle`:
  1 mm / 1e-3 / 1 mm per step, gripper-toggle chunks exempt, measured SR 0.16 →
  0.58) to the frame stream: `RecorderThread` compares each candidate frame's
  commanded TCP (Chebyshev over xyz, geodesic angle), gripper fraction and
  rail slot with the LAST KEPT frame's; below every epsilon AND no gripper
  change within ±`gripper_context_s` ⇒ the frame is skipped (not appended, not
  fed to the encoder, no audio alignment point). The look-ahead is a delay
  buffer of `round(gripper_context_s · fps)` frames (≈ 74 MB for two cameras
  at 25 fps) flushed at save / discard. DAgger filters only human-controlled
  frames (`action_source ∈ {teleop, takeover}`). The first frame is always
  kept; `EpisodeStatus.frames_skipped` (additive) shows the running count;
  `episode.json.filter` records params, counts and every gap (10-frames §9).
  pro-dagger's `chunk_stride` de-duplication concerns overlapping action
  chunks and has no counterpart in a sequential dataset — not ported.
- **Audio.** When the runtime's `MicrophoneReader` is live and
  `recorder.audio` is true (hardware default; sim only with a fake reader),
  `EpisodeAudioSink` buffers the Perception Arm microphone between
  `episode_new` and save and writes `episodes/<id>/audio.wav` (mono PCM
  s16le at the reader's rate) with the alignment block in `episode.json`
  (10-frames §11.4). `Runtime.__init__` MUST set `self.manager.microphone =
  self.microphone` right after constructing the `SessionManager` (missing as
  of 2026-09-07 — the sink is never built otherwise); audio failures never
  block recording.

### 10.6 DatasetStore: listing, deletion, export (2026-09-07)

`recorder/datasets.py::DatasetStore(datasets_root)` reads **only**
`manifest.json` and `episode.json` files (plus `meta/info.json` to recognise a
legacy v3 tree) — no lerobot, no torch, no parquet scan on the REST path:

- `list() -> list[DatasetInfo]` (newest first; `layout: episode_dirs |
  lerobot_v3`, `in_use` = the running session records into it, `export`
  status), `describe(repo_id)`, `episodes(repo_id) -> list[EpisodeInfo]`
  (`episode_id`, capture-order `index`, `frames`, `duration_s`, `task`,
  `session_id`, `recorded_at`, `frames_dropped`, `audio`, `export_ok`,
  `export_note`, `open` = currently recording).
- `delete_episode(repo_id, episode_id)`: `rmtree(episodes/<id>)` (+ its
  `trainer_spool` row), refresh the manifest, mark the export stale — nothing
  else is read. Allowed during a session recording into that dataset except
  for the open episode (409); 404 for an unknown dataset / id.
  `delete_dataset(repo_id)`: the whole tree (409 while a session records into
  it or an export runs).
- `export(repo_id, format="lerobot_v3", out=None)`: the batch job of
  10-frames §11.8 on a `dataset-export` thread (one at a time; 409 while a
  session records into that dataset — the export needs a consistent episode
  set). Progress rides telemetry `datasets.export {repo_id, phase:
  scanning|videos|data|meta|validating|done|failed, done, total, detail}`;
  the result (`path`, `episodes`, `at`) is written to `manifest.last_export`;
  a failed job writes `last_export.error` (state `failed` until the next
  success), `running` is process-local.
  The job MAY import `lerobot.datasets` for the final validation
  (`LeRobotDataset(repo_id, root=<export>)`), which is why it is a job and
  not a request handler. The same code is the CLI
  `python -m apollo_mavis_v2_runtime.tools.export_lerobot <repo_id> [--out DIR]`.
- Legacy v3 trees are listed read-only (`total_episodes` / `fps` /
  `robot_type` from `meta/info.json`); none of the mutating ops accept them
  (409 `"legacy LeRobot v3 dataset - read-only"`).

Telemetry: `EpisodeStatus` carries `repo_id`, `total_episodes`,
`total_frames`, `detail` and the `returning` state; the interim
`pending_delete` field is gone (deletion is immediate, §10.6).

**Per-namespace roots (2026-09-08; 15-online-dagger §7 / D5, operator decision;
the morning's citation 15-pro-dagger §6 D4 is superseded, the rule unchanged).**
`DatasetStore(root, *, default_namespace, namespaces)` — `root` is still
`datasets_root` (the GENERIC `<root>/<ns>/<name>`), `default_namespace` comes
from `RuntimeConfig.datasets.default_namespace` (`bc_demo`; the constructor
default stays `apollo` for tests), `namespaces` maps a namespace to
`{root, subdir}`: `bc_demo/<name>` → `~/data/bc_demo/<name>`,
`online_dagger/<s>` → `~/data/online_dagger/<s>/rollouts` (2026-09-08 evening:
the `pro_dagger` namespace never shipped), everything else stays
under the generic root (the phase-07..13 `var/datasets/apollo/…` data is
listed, addressed and deleted as before). `resolve()` prefixes a bare name with
the default namespace; `root_of(repo_id)` consults the map; `list()` walks the
generic root AND every mapped root (a generic-root directory of a MAPPED
namespace is skipped — `root_of` could never address it); `delete_dataset`
never removes a mapped root or an Online DAgger session directory;
`episode_delete_refusal` (a manager hook, review fix 2026-09-08) makes the DELETE
of a SAVED rollout of the RUNNING Online DAgger session 409 (`"dataset
'online_dagger/<s>' is in use by the running Online DAgger session - end the
session first (the trainer is told about discards, not deletions)"`); `sweep()` (run
at `Runtime.start()`) covers every root; `layout()` → `DatasetLayoutInfo`
(`GET /api/datasets/layout`, §13.1); `DatasetInfo` rows carry `namespace` +
`path`. The export CLI gained `--namespace` (default: the loaded config's
`datasets.default_namespace`).

### 10.7 Online DAgger sessions (phase-14, 2026-09-08 evening)

Contract: `15-online-dagger.md` (§3 coordinator, §4 recording, §5 models, §6 wire, §7
config / paths / REST, §12 implementation record). History: the morning's v1.0 text
"PRO-DAgger sessions" (iteration machine `preparing → rollout → training → swapping`,
`ProDaggerCoordinator`, `ref_grad/`, `iteration_complete`, `pro_dagger_train_now`,
`/api/pro_dagger/*`) is superseded (2026-09-08 evening, operator decision: the runtime
is an algorithm-agnostic shell) and kept in `15-pro-dagger.md` §15 only — none of it
shipped. Runtime side, as shipped:

- **What it is.** `SessionSpec{mode: dagger, policy_source: external,
  online_dagger: OnlineDaggerConfig{session_name, resume, pause_while_training,
  wait_for_trainer_ready}}` (core §12). The takeover gate, the `GatedPolicyExecutor`,
  the `DaggerRecorderThread` and the external policy stack of §11 / §17 are
  unchanged; the addition is a session-scoped **`OnlineDaggerCoordinator`**
  (`dagger/online_dagger.py`) owned by the executor: rollout-level state only —
  `phase ∈ waiting_trainer | rollout | training | error` (a PURE function of the
  latest trainer status echoing THIS `session_id` + the `trainer_seen_ready` latch),
  `rollouts_saved`, the session's `expert_frames_session` / `novice_frames_session`,
  the last `TrainerStatusAnnounce` + receive time, `policy_version_acting` — pure
  state + publishing, no motion, NO iteration counting, no hyper-parameter, no
  training artefact. Its two side effects — `events.*` on the dora bus and
  `session.json` — leave through one `SerialWorker` thread (never the tick, never the
  recorder thread); the executor rebuilds `DaggerStatus.online_dagger` every
  `OD_STATUS_EVERY_N = 4` ticks (25 Hz) and `SessionTelemetry.trainer_alive` mirrors
  the trainer's freshness (`dora.policy.spec_stale_s`).
- **Session directory** (`SessionManager._build_online_dagger`, inside the sim
  bring-up, after every 409 check): `<online_dagger root>/<session_name>/` with
  `rollouts/` (the episode-directory dataset `online_dagger/<session_name>`, recorded
  by the normal DAgger recorder — resumed via the manifest path when
  `online_dagger.resume`) and `session.json` (runtime-owned, `json.dumps(indent=2,
  sort_keys=True)` via tmp + `os.replace`, rewritten on every transition, ≤
  `online_dagger.session_file_hz` otherwise; the resume record:
  `{session_name, created_at, session_id, task, spec, paths{session_dir, rollouts},
  rollouts[{episode_id, saved_at, actor_counts, policy_version, spool_path}],
  trainer_log[{at, state, policy_version, detail}] (newest 200), current{phase,
  rollouts_saved, expert_frames_session, novice_frames_session}, last_used_at}`).
  NOTHING else is created — the trainer keeps its own artefacts wherever it likes
  (the skill suggests `<session_dir>/trainer/`; the runtime never reads them). The
  rollouts dataset is `DatasetStore.root_of("online_dagger/<s>")`; the session
  directory is its parent when the namespace maps a `subdir` (the shipped
  `~/data/online_dagger/<s>/rollouts`), the dataset directory itself when
  `online_dagger` is not mapped. A FRESH directory gets its first `session.json`
  during bring-up and is removed again (`_OnlineDagger.abandon()`) if any later
  bring-up step fails (recorder, executor, a `start()`), so the name stays usable; a
  RESUMED record is neither removed nor rewritten before the session is RUNNING
  (`on_session_start()`), so a resume that 409s later leaves it byte-identical.
  `GET /api/online_dagger/sessions` scans `<root>/*/session.json`.
- **`actor` column** (12-dagger §4; 10-frames §7.4): every DAgger frame, the spool
  and the export; `EpisodeSummary.n_expert_frames` / `.n_novice_frames`;
  `episode.json["online_dagger"] = {session_name, rollouts_saved, policy_version,
  actor_counts}` (`rollouts_saved` includes this rollout). `events.episode_saved`
  gains the same block (+ `episode_id`, `spool_path` — `null` when the trainer spool
  could not be written; the rollout still counts and the event still fires);
  `events.episode_discarded {episode_index, episode_id, reason}` on every discard —
  the operator's (`""`), `"empty episode discarded"`, a rollout still open at teardown
  (`"session teardown"`), the degraded-save path (`"save failed twice - recording
  degraded (buffer kept)"`); `events.train_now {rollouts_saved, requested_by:
  "operator"}` on **Train now** (`ActionMsg train_now`, no key); `events.gate {arm_id,
  mode, seq, source: keyboard | action | auto_advance | episode_reset, episode_id}` on
  every `TakeoverGate` transition (the boundary's `episode_reset` names the episode that
  CLOSED); the executor spells `policy_reset(reason="episode_boundary")` at boundaries
  (a handback keeps `"handback"`). The coordinator's saved hook runs BEFORE the
  executor's boundary callback so `episode_saved` precedes the boundary's gate events.
  Every coordinator event carries the session id pinned at submit time.
- **Take over / Hand back / Train now** (`GatedPolicyExecutor._op_takeover` /
  `_op_handback` / `_op_train_now`; 15-online-dagger D3): `takeover` = the transition
  Space makes from POLICY on the active arm (ack detail `"takeover_transition"`;
  idempotent `"already taken over"` in HUMAN / TRANSITION; nack `"takeover active"`
  when another arm is engaged, `"no active arm"`); `handback` hands the ENGAGED arm back
  (ack `"policy"`; idempotent `"policy already driving"`); both accepted at any time
  — like Space — and both emit `GateEvent.source: "action"`. `train_now` → the
  coordinator (`"asked the trainer to train (<n> rollout(s) saved)"`; nack `"save or
  discard the episode first"` — the recorder is read directly — or `"no Online DAgger
  trainer attached"`). The base `ControlLoop` nacks `takeover` / `handback` `"takeover
  not available in teleop"` and `train_now` `"not an Online DAgger session"`. Under
  POLICY with no arm engaged, `reset_to_initial` (`R`) / `goto_profile` are nacked
  `"policy driving - take over (Space) first"` (§10.5).
- **Return-to-start for dagger (D6).** `SessionSpec.return_to_start` (DEFAULT
  ON) is a collect **or dagger** field since 2026-09-08 (core §12); the same
  `_on_episode_done → _return_home_worker → _run_return_plan(interruptible=True)`
  path as collect runs after every kept / discarded rollout (the episode state
  walks `returning`; `episode_new` is refused meanwhile); the executor's boundary
  (`_settle_boundary`) fires on the episode LEAVING `recording` / `saving` whatever
  follows (`idle` or `returning`) AND is re-run from `_op_episode_new` before the next
  episode opens (commands drain before the tick's own check; with return-to-start off
  an `N` in the next tick otherwise hid the discard boundary — review fix 2026-09-08),
  so the gate reset / runner resume / boundary reset always happen.
  `_check_return_to_start` (409 without a return profile) applies to dagger too; the
  DAgger e2es therefore pin `return_to_start: False`.
- **Refusals** (`_check_online_dagger`, evaluated at `create()` after
  `_check_dataset_spec` and the hardware refusal matrix — hardware + dagger keeps the
  D7 line, §5 — and BEFORE `_check_return_to_start`, before any side effect; order
  session directory → exporting / legacy → trainer): 409 `"Online DAgger session '<s>'
  already exists - resume it or pick another name"` (`resume: false` on an existing
  directory) / `"Online DAgger session '<s>' not found"` (`resume: true` on a missing
  one) / `"Online DAgger session '<s>': session.json is unreadable - fix or remove it"`
  (never overwritten); `"dataset 'online_dagger/<s>' is being exported - retry in a
  moment"` / the legacy-tree 409; the shared `"no external policy attached (dora bridge
  is not attached)"` / `"… (no policy_spec heartbeat within 3 s)"`; `"no Online DAgger
  trainer attached (the policy node does not report the online_dagger capability)"`.
  There is NO offline-dataset check (the trainer configures its own anchor). 422s are
  core's (`"online_dagger requires mode dagger"`, `"… requires policy_source
  'external'"`, `"online_dagger derives the rollouts dataset - leave dataset unset"`,
  unknown keys, `session_name` > 64 chars / off `SLUG_RE`). WS nacks while running:
  `episode_new` → `"no Online DAgger trainer attached"` (no fresh status; checked
  FIRST), `"waiting for the trainer to report ready (<detail>)"`, `"training in
  progress (<detail>)"`, `"trainer error: <detail>"` (`<detail>` = the trainer's, else
  `no trainer status yet` / `the trainer has not picked up this session yet` /
  `<progress>%` / `trainer <state>`). Only a trainer status whose `session_id` echoes
  this session drives a transition (`null` = alive only; another id is ignored; an
  older-than-seen status is dropped).
- **Config**: `RuntimeConfig.online_dagger {skill_dir: null, session_file_hz: 1.0}`
  (`OnlineDaggerRuntimeConfig`) and `RuntimeConfig.datasets` (§14). **Skill**: package
  data `online_dagger/skill/{SKILL.md, references/contract.md,
  references/pro-dagger-example.md}` (`SKILL_NAME = "mavis-online-dagger-trainer"`)
  served by `GET /api/online_dagger/skill[.tgz]` (§13.1), byte-identical to the
  policy-node mirror `skills/mavis-online-dagger-trainer/`
  (`tests/test_online_dagger_package.py`).
- **Not on hardware** (D7). Not exercised on the real cell / the lab dora plane;
  sim + the runtime's fake trainer node (`dora_bridge/nodes/fake_policy.py`,
  `FAKE_TRAINER=1`: capability `online_dagger`, `preparing` → `ready`, trains after
  `FAKE_TRAINER_EVERY` 2 kept rollouts or on `train_now`, bumps the version, knobs
  `FAKE_TRAINER_PREPARE_S` 0.5 / `FAKE_TRAINER_TRAIN_S` 1.0 / `FAKE_TRAINER_FAIL_AT`)
  only. Numbers, deviations and open items: 15-online-dagger §12.

### 10.8 Episode playback (2026-09-10, operator request)

The Welcome page's Datasets panel gets a **Playback** button on every episode row; it
opens an in-page modal with two actions, the second gated on the first (05-ui §8.1
item 7). `recorder/playback.py` reads the episode, `SessionManager` runs the motions,
`GET …/episodes/{id}/playback` + `POST /api/session/playback` are the wire (§13.1).

**The default source replays `observation.state`** (superseded in part 2026-09-11 —
see "Replay sources" below: the action columns are replayable too, and the 2026-09-10
sentence "integrating `delta_ee` would drift" described the executor bug of that day,
not the data). The measured joint / rail / gripper trajectory is the ground truth of
where the arms actually went, and it is directly commandable. The per-dim column layout
comes from the dataset's OWN manifest (`features["observation.state"]["names"]`,
`features["action"]["names"]`, `features["action.abs_ee"]["names"]`), never from the
current session's arm set, so an episode recorded with one arm or before a track was
fitted either reads back correctly or is refused by name — never mis-sliced in silence.
Nothing imports lerobot or torch: one pyarrow read.

**Return to this episode's initial state** builds a TRANSIENT `StateProfile` from frame
0 and hands it to the existing `_profile_motion_reported` path, so it inherits
everything unchanged — twin planning, the gate, the two separately planned phases
(joints with the carriages held, then the carriages), one arm at a time in the
planner's `arm_order`, cancellation by any operator input. The profile is never stored.
Synchronous, like `return_home`, because the dialog only enables **Playback** once it
succeeded; a `skipped` ("already there") counts as arrival.

**Play back the whole episode** is the one motion in the stack that moves several arms
AT ONCE, and the reason it may is exactly the reason `execute_plan` may not. The
2026-09-08 incident was a SEQUENTIALLY PLANNED motion executed simultaneously: each
arm's RRT path had been validated against the other arm standing still, so running
them together walked combinations nothing had checked and the gate held them at 5.2 mm.
A playback is the opposite case — a trajectory the arms already executed together on
the real cell — and splitting it one arm at a time would be the unvalidated thing to
do (arm A walking its whole 37 s path while arm B sat at frame 0 is a different path
through space). Three things earn it the right, all binding:

1. **Lockstep resampling** (`playback.resample`). ONE global time scale for every arm,
   never a per-arm one: the tick count of each recorded interval is the MAX over all
   arms of what the executor's caps need (`ExecutorCaps.ticks_for` mirrors
   `PlanExecutor.step`'s `ratio` exactly — joint slew, rail slew AND the hardware
   lever-weighted Cartesian bound), floored at `rate_hz / fps` so the replay runs at
   the RECORDED rate where the caps allow and uniformly slower where they do not
   (recorded at 100 % speed, replayed at 10 %). Every arm therefore gets the same
   waypoint count and every segment costs exactly one tick, so the executor cannot
   subdivide one arm's segment and desynchronise the pair. `slowdown` reports the
   factor. The loop refuses a command whose per-arm counts differ.
2. **Whole-path twin verification** (`_verify_playback`) before a single waypoint is
   sent: every posture, all arms jointly, at the resolution it will be COMMANDED — not
   at the recorded frame rate, so there is no unchecked interpolation between two
   approved postures. A recorded trajectory can legitimately fail this, because the
   episode was recorded with objects the twin does not model (03-sim §4.5): the refusal
   names the pair and how many seconds in. Sim sessions with a `NullGate` have no twin
   and skip it (11-safety §5).
3. **The live gate stays the authority per tick**, and the plan is interruptible
   throughout: any operator input, a driver fault or a teardown cancels it and the arms
   hold. The Welcome page has no control socket, so `action: "stop"` is the operator's
   cancel (idempotent).

The recorded **gripper** rides a per-waypoint TRACK (`_playback_gripper`, applied in
`ControlLoop._plan_step` from `PlanExecutor.index`), not a single target deferred to
arrival: for a manipulation episode the grip IS the task. Playback refuses when an arm
is more than `PLAYBACK_START_TOL_RAD` (1°) from frame 0 — with the distance, rather
than quietly re-placing it, because a drifted cell is news. Arrival is confirmed per
arm with `_await_arrival` (the executor retiring waypoints only says the COMMAND
arrived; a carriage trails its targets at the track's own speed).

Measured 2026-09-10 in sim on a real recording (`bc_demo/drawer_assembling`, 932
frames at 25 fps, both arms): `goto_initial` 5.1 s and every joint + both carriages
exactly on frame 0; `play` **37.2 s for a 37.28 s recording** (real time, `slowdown`
1.0) ending exactly on the last frame with the gripper following its track. Not yet
run on the real arms. Tests: `tests/test_episode_playback.py` (48 since 2026-09-11,
incl. the lockstep and real-time properties, an end-to-end state replay in sim and
the two action-source replays below).

**Replay sources (2026-09-11).** `POST /api/session/playback {action: "play",
source}` takes `source ∈ state | delta_ee | abs_ee` (default `state`, the path above,
unchanged); `GET …/episodes/{id}/playback` answers `sources` — the list this episode
offers: `state` always, `delta_ee` when the `action` column is present and well-formed,
`abs_ee` when `action.abs_ee` is — plus `action_space` (the recorded primary space,
`delta_ee` for every dataset the cell records). `recorder/playback.py::ACTION_COLUMNS`
maps the two action sources onto their parquet columns (`delta_ee → action`, `abs_ee →
action.abs_ee`); an absent, unnamed or malformed column simply does not appear in
`sources` and the reason is kept per source.

The two action sources exist to **measure the executor**: a recorded episode is the
one input whose right answer is known, so replaying its action column through the
SAME per-tick path a policy drives — `dagger/step.policy_step` over a
`ReplayActionSource` (`dagger/replay_source.py`, a `PolicySource` serving row `k`
from `t0 + k / fps` on, never skipping ahead of the clock, never repeating a row as
new) + an `ActionAnchor` built with `anchor_leash_kwargs(cfg.dagger, cfg.control)` —
and comparing where the arm ended with where the recording ended IS the fidelity
report (§11 for what that path does). Mechanics, all in `ControlLoop`
(`_op_replay_actions`, the `_ActionReplay` slot, 2026-09-11):

- the replay runs INSIDE the current teleop / collect session's control loop, one
  `replay_actions` command carrying the source and the anchor; the driven arms'
  commands come from `_replay_step` (`policy_step` with `CommandSource.PLANNER`), every
  other arm holds; the recorded gripper dim goes to `on_gripper` per row;
  `loop.motion_active` is true while it runs, so telemetry and the manager's blockers
  treat it as one more planned motion;
- there is NO pre-planned joint path, so `_verify_playback` does not apply: every row
  is gated on the tick it is due, and the gate-hold watch (`_plan_gate_watch`, the
  same `plan_gate_hold_s`) cancels it with the blocking pair; `stop`, any operator
  input, a driver fault or a teardown cancel it too (`_clear_replay` is on the same
  paths as `_cancel_plans`); the replay finishes when the LAST row has been current for
  a full period (`staleness_scale` drops to 0 — there is no decay, the recording ends);
- **admission**: sim sessions only (`"action replay is admitted in sim only"` — the
  per-tick gate is the only check it gets and the twin does not model the room, 03-sim
  §4.5; the operator admits it on hardware, D7's spirit), teleop / collect sessions only
  (`"action replay runs in teleop / collect sessions only - this session's loop drives
  its own policy"`), a session with IK + kinematics, and an episode that carries the
  column (the refusal names the backfill: ``backfill it with `python -m
  apollo_mavis_v2_runtime.tools.backfill_abs_ee <repo_id>` ``). `SessionManager.
  _action_replay_refusal` runs BEFORE the shared blockers so the operator reads the
  specific reason. The frame-0 check (1°) applies to every source;
- **arrival verdict** (`_replay_motion`, `_replay_residuals`): after the rows run out
  each arm is waited on until it has ARRIVED (the plan rule) or SETTLED (no joint /
  carriage moved more than `REPLAY_SETTLE_EPS` 1e-4 over `REPLAY_SETTLE_S` 0.3 s), then
  the MEASURED TCP is judged against the last recorded frame's TCP: **`REPLAY_TCP_TOL_M`
  0.005 m / `REPLAY_TCP_TOL_RAD` 0.02 rad** — an IK-driven replay tracks the TCP and a
  7-DOF arm has a null space, so it cannot be held to the state replay's 1 mrad joint
  criterion (the first sim replay ended 8.8 mrad off in joints with the tool where the
  recording said). The detail reports joints (mrad), carriage (mm), the TCP residual
  off the last frame and, when the episode carries `action.abs_ee`, off the last
  COMMANDED pose — the executor-fidelity number; a miss is `status: "stalled"` with the
  distance. An episode without TCP dims falls back to the joint verdict;
- an arm recorded without a track on a session arm that has one gets `rail.dpos 0` /
  `rail.pos = rail_hold[arm]`, so its carriage stays put (the `resample` rule of the
  state replay); a session arm the episode does not name gets a NaN block = hold.

First sim measurements (12-frame synthetic episode, `tests/test_episode_playback.py`):
`delta_ee` 2.0 mm / 2 mrad, `abs_ee` 0.3 mm / 0 mrad off the last frame. A replay of a
REAL recording on the twin lags the real arm for a reason that is the twin's, not the
executor's: the session twin's PD servo closes ~9 % of the error per 10 ms tick
(time constant ~100 ms) where the xArm lags ~1 tick (03-sim §6). Telemetry:
`session_extra["replay"] = {frame, frames, source}` exists in the loop
(`_replay_progress`) but is **NOT yet on the wire** — the dialog shows the synchronous
result only. Neither action source has run on the real arms.

## 11. DAgger orchestration

Components only — the wire protocol, aggregation rules, and trainer loop are
specified in `12-dagger-protocol.md`; runtime implements the core Protocols
(`TakeoverGate`, `PolicyReloader`, `AsyncTrainerClient` from
`apollo_mavis_v2_core.dagger.interfaces`).

- **`TakeoverGate`** (`dagger/gate.py`): **Space = discrete toggle**
  (ActionMsg `takeover_toggle`, once per press — not held), policy↔human;
  each switch emits `TAKEOVER_TRANSITION` for `T_blend = 0.3 s` of frames
  (recorded, excluded from labels). One gate for the active arm; non-active
  arms freeze their deltas when `dagger.pause_others_on_takeover` (default
  true). Gate events → telemetry `DaggerStatus.control_mode`.
- **`PolicyRunner`** (thread, GPU 0): builds `Observation` from the latest
  snapshot + camera frames at policy rate (10–30 Hz), calls `Policy.act`,
  publishes `PolicyOutput{actions, version, t_mono}` to the `policy_action`
  slot (latest wins; the servo loop never blocks on inference). **How a row
  becomes a joint command (2026-09-11; `dagger/step.py::policy_step` +
  `dagger/policy_runner.py::ActionAnchor`, shared by `GatedPolicyExecutor.
  _policy_step` and the §10.8 action replay; 12-dagger §6 is the contract):**
  the whole-cell row is split into per-arm blocks by the NAME-derived widths of
  the announced space (`arm_action_names`: 8 / 7 for `delta_ee`, 11 / 10 for
  `abs_ee`); a missing, short or non-finite block for THIS arm holds it, and
  `staleness_scale <= 0` holds it (both spaces). A **`delta_ee`** row is scaled
  by `dt / period × staleness` (per-period increments → per-tick, decaying toward
  hold) and **integrated on the LAST COMMAND**: `target = FK(q_last) ⊕ Δ`, then
  clamped to a **leash around the MEASURED pose** (`ControlConfig.leash`, 0.025
  m / 0.2 rad — the teleop rule; per session `DaggerConfig.anchor_leash`
  overrides it, `anchor_leash_kwargs`), then IK from `q_last`. It is NOT
  re-anchored to the measured pose each tick any more: that (the pre-2026-09-11
  "hil-serl" rule) capped the executed velocity at the arm's own lag and bled the
  motion on the twin — 8.7 % replay fidelity; MoveIt Servo #1857 is the same bug.
  A lagging arm now accumulates the policy's intent up to the leash instead. An
  **`abs_ee`** row is a WAYPOINT: the command interpolates from `FK(q_last)`
  toward the row's pose by the row's period — `remaining = max(period − (now −
  t_row), dt)`, `frac = dt / remaining`, `pose_interp(FK(q_last), target, frac)` —
  so it ARRIVES at the row's deadline; the rail slot approaches its absolute
  target with the same fraction; the gripper (index 9) is absolute; nothing about
  an absolute row is ever scaled by a tick, chunk or staleness factor (stale ⇒
  hold). A bad r6 pair (`rot6d_to_quat` raises) or an IK failure holds the whole
  arm, gripper included. Inside the handback slew window (`SlewLimits`, 0.4 s) the
  per-tick step of BOTH spaces is capped. The gate then clips the command as for
  teleop. Stale output (`act()` past deadline = policy period + 50 ms): keep
  scaling toward hold for ≤ 5 periods, then hold + telemetry flag (11-safety
  §10.2). Chunked policies (ACT / diffusion): on handback drop the stale chunk,
  re-query from the current observation, slew-limit the first 0.4 s. **Both
  spaces are accepted** from a checkpoint (`CheckpointInfo.action_space ∈
  {delta_ee, abs_ee}`, else `SessionError("unsupported policy action_space …")`)
  and from an external node (14-dora §6.1); `joint` has no executor path (hold).
  The counterfactual `policy_action` column keeps the recorded `delta_ee` width:
  an `abs_ee` row is stored as its delta from `FK(q_last)` per frame (`_abs_
  counterfactual`, NaN where the conversion fails, one warning).
- **Recording**: same recorder, schema §10.2 + DAgger columns. Every frame
  stores `executed_action` (training label when `control_mode == human`),
  counterfactual `policy_action`, `policy_version`. Human corrections are
  converted into the arm's canonical recording frame before both execution
  and recording (`RelativeFrame` rule). DAgger episodes append to a
  dedicated dataset; the seed dataset is never mutated.
- **`AsyncTrainerClient`**: trainer spawned as `python -m
  apollo_mavis_v2_runtime.dagger.trainer --config ...` with
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
same `PolicyRunner`, same gate machinery, same hardware safety invariant — and the
same `policy_step` / `ActionAnchor` execution of §11 (integrate-on-command + leash
for `delta_ee`, deadline interpolation for `abs_ee`; both spaces accepted, 2026-09-11).

- **Space still toggles takeover** (same `TakeoverGate`) as the safety
  escape: the human's twist drives the active arm through the identical gated
  pipeline; steer to a safe configuration, then toggle back or end the
  session — never a blind "return to initial" (overview §4 item 4).
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
| `GET /api/workcell?kind=hardware\|sim` | → `WorkcellStatus{kind, available_kinds, arms: ArmStatusInfo[], cameras: CameraInfo[], policies_available: bool, hardware_ready: bool}` | per-arm connectivity/rail/gripper for the Welcome page (`reachable` / `hardware_ready`: core §12). `kind` optional (phase-11): omitted = the session's kind, else sim, cameras = everything previewed (legacy); `sim` = arms of the preview/session scene + sim cameras; `hardware` = arms from `workcells.hardware` (`ip` filled, `reachable: open\|refused\|unreachable\|unknown` from the `HardwareProbe`, `connected` keeps its "a hardware session exists" meaning, rail/joint limits from the digital-twin scene) + hardware cameras (`live` = preview opened). `hardware_ready` (every configured hardware arm `open`) is on every response and gates the Hardware-tab launchers (05-ui §8.1); a `kind` that is not configured returns empty `arms`/`cameras` (UI reads `available_kinds`); other values → 422 |
| `GET /api/cameras` | → `CameraInfo[]` | sim preview/session cameras (kind `sim`, `live: true`) AND every configured hardware camera (kind `v4l2\|realsense`; `live` iff its pre-session preview opened, §13.4) AND, phase-09a, one `<camera_id>_align` row per hardware wrist camera (kind `twin`, `live` = the real camera is live AND the overlay composites, §13.4). The UI never opens `/ws/video/<id>` for `live: false` rows (draws a black "no signal" tile instead: an unknown stream id closes 1008 and would reconnect forever) |
| `GET /api/microphones` | → `MicrophoneInfo[]{mic_id, label, kind: pulse\|fake\|none, source, sample_rate, channels, live, status: MicStatus, detail}` | phase-11 (`MicrophoneInfo` / `MicStatus`: core §12 `protocol/microphone.py`; `ArmConfig.microphone`: core §7): the configured microphone (`microphone.enabled`) is ALWAYS listed — `live: false` with `status: absent\|stalled\|error\|no_backend` and a human-readable `detail` when it is unplugged / silent / failing / disabled — so the Hardware tab can render the MicTile with nothing connected; `[]` when `microphone.enabled: false`. Same device status as `telemetry.microphone` (§13.3); levels ride telemetry |
| `GET /api/scenes?kind=sim\|twin` | → `SceneInfo[]` | from the `sim` scene registry (id, #arms, rail flags, cameras) |
| `GET /api/keymap` | → `KeymapEntry[]` | canonical, from `core.protocol.keymap`; UI builds its bound-key set from it |
| `GET /api/profiles` | → `ProfileInfo[]` | incl. `is_initial_condition` |
| `GET /api/profiles/{id}` | → `StateProfile` | full posture |
| `PATCH /api/profiles/{id}` | `{name?, notes?}` → `ProfileInfo` | rename/annotate |
| `DELETE /api/profiles/{id}` | → 204 | 409 if it is the designated initial condition |
| `GET /api/policies` | → `PolicyInfo[]{policy_id, path, action_space, action_frame, policy_version, promoted}` | checkpoint registry for dagger/inference (core §12 model) |
| `GET /api/session` | → `SessionInfo` \| 404 | reconnect resync |
| `POST /api/session` | `SessionSpec{…, speed_scale}` → `SessionInfo{session_id, epoch, mode, arms, streams, state, kind, speed_scale}` | 409 if a session exists, a tracker calibration is in progress (`"tracker calibration in progress"`, phase-10), requested `kind` unavailable, scene/arm mismatch, dagger without a policy, or inference with no promoted deploy checkpoint (`policy=None` resolves to latest for dagger, promoted deploy for inference — 12-dagger §9). Returns after BRINGUP; START_FROM progress via telemetry. `streams` = camera ids + `"sim"` and/or `"twin"` (sim); `[]` for a hardware session (the preview cameras are ADOPTED, not re-added — §13.4). **Hardware refusal matrix (phase-09c/09d, `SessionManager._validate_hardware`, all before anything is touched; `detail` substrings):** `mode ∉ {teleop, collect}` → `"hardware sessions support teleop and data collection only (<mode> on hardware: not yet)"` (collect admitted 2026-09-07, §10.5; a collect body is additionally checked by `_check_dataset_spec` BEFORE this matrix — 409 `"dataset … already exists …"` / `"unknown dataset … start it as a new dataset instead"` / `"… is being exported - retry in a moment"` / `"… is a legacy LeRobot v3 dataset (read-only) …"`, and after connect by `dataset_incompatibility` → 409 `"dataset … cannot be continued by this session: <why> …"`; `return_to_start` without a return profile → 409; no live hardware camera → 409 `"data collection needs at least one live hardware camera …"`); empty arms → `"session needs at least one arm"`; an arm outside `workcells.hardware.arms` / outside the twin scene → `"arms [...] not in the hardware workcell"` / `"… not in scene"`; **not EVERY configured arm (phase-09d)** → `"hardware sessions include every configured arm (Manipulation Arm, Perception Arm) - missing ['view'] (phase-09d: both arms are always part of the session)"`; no / unknown `digital_twin_scene` (or the `[sim]` extra missing); no read-only monitor configured → `"no read-only hardware monitor - the digital twin cannot be posed for the gate"`; a rail homing in flight on ANY arm (`maintenance_busy`: the monitor op OR a phase-09d `RailHomingJob`) → `"rail homing in progress on the Perception Arm - wait for it to finish"`; per selected arm (user-facing name first): the read-only monitor not `running`/`stale` or without a sample → `"Manipulation Arm: no monitor sample (monitor error: …) - the read-only monitor must be connected before a hardware session (the digital twin cannot be posed)"`; probe `refused`/`unreachable` → `"…: control box 192.168.1.201 is unreachable - power it on / check the network first"`; `error_code != 0` → `"…: controller error 31 is latched - clear errors first"`; the twin expects a rail the monitor did not find → `"…: the digital twin 'mavis_v2' expects a linear track but the monitor found none"`; `rail_present and not (rail_homed and rail_enabled)` → **`"Manipulation Arm: rail not homed - home it from the Hardware tab (Home rail) before starting a session (carriage position unknown)"`**; `start_from` profile not covering the arms. Post-connect: a monitor poll thread still inside the SDK after 15 s, a per-arm bring-up error (`"hardware bring-up failed: Manipulation Arm: rail - [rail] …"`), a connected arm whose track is not `ready` (`"… rail - linear track error after connect (carriage position unknown …)"`), a dof mismatch with the twin, a stale first state, or — phase-09d — a `start_from` profile motion the gate twin cannot plan (`"profile motion not collision-free: goal_in_collision (grip_right_inner_knuckle / table) - the digital twin found no safe path from the measured posture to profile '…'"`) → teardown + 409. `hardware_session_active` (the monitor hand-over predicate) turns true only AFTER this matrix passed, right before `_bringup_hardware` pauses the monitor: a refused request never flips it (a supervisor round inside the validation window would otherwise disconnect the monitors and 409 with "monitor paused"). `speed_scale` outside (0, 1] is pydantic's 422. `GET /api/session` answers `state: bringup` while the hardware bring-up runs (D5). **Online DAgger (2026-09-08 evening, §10.7; 15-online-dagger §3 / §7 / §12; the morning's "PRO-DAgger" text with its `offline dataset …` 409s is superseded):** a body with `online_dagger` set (`mode: dagger`, `policy_source: external`) is additionally checked by `_check_online_dagger` AFTER `_check_dataset_spec` + the hardware matrix and BEFORE `_check_return_to_start` — 409 `"Online DAgger session '<s>' already exists - resume it or pick another name"`, `"Online DAgger session '<s>' not found"`, `"Online DAgger session '<s>': session.json is unreadable - fix or remove it"`, `"dataset 'online_dagger/<s>' is being exported - retry in a moment"` (or the legacy-tree text), `"no external policy attached (dora bridge is not attached)"` / `"no external policy attached (no policy_spec heartbeat within 3 s)"`, `"no Online DAgger trainer attached (the policy node does not report the online_dagger capability)"`; `return_to_start` without a return profile is 409 for dagger too (D6). 422: `"online_dagger requires mode dagger"`, `"online_dagger requires policy_source 'external'"`, `"online_dagger derives the rollouts dataset - leave dataset unset"`, `"return_to_start is a collect / dagger-mode field"`, unknown `online_dagger` keys (`extra="forbid"`), `session_name` > 64 chars / off `SLUG_RE`. `SessionInfo` echoes `online_dagger` (and `policy_source`, `fault_detail`; not `dataset` / `return_to_start`) |
| `POST /api/session/return_home` | → `ReturnHomeResult{ok, status: done\|skipped\|failed\|cancelled\|timeout\|refused, detail, arms, profile_id}` | 2026-09-08 (§10.5). Walk the workcell back to its designated initial-condition profile — joints first with the carriages held, then the carriages, each phase twin-planned + gated + interruptible — and report where the arms ended up. **SYNCHRONOUS**: the Cockpit's "End session" awaits it before the DELETE (05-ui §8.2), which is why the client deadline is 240 s while the runtime bounds each phase by the plan's own budget. Operational refusals are a **200 with `ok: false`**, never an HTTP error: no session (`refused`, `"no active session"`), an open episode (`refused`), a non-running or faulted session (`failed`), an unplannable path (`failed`, the twin's reason + failing pair), operator input (`cancelled`), a gate hold past budget (`timeout`). `skipped` is a SUCCESS — no initial condition designated for this kind, the profile covers no session arm, or the arms are already there. The `reset_to_initial` key (`R`) fires the same motion over /ws/control, fire-and-forget |
| `POST /api/session/playback` | body `EpisodePlaybackRequest{repo_id, episode_id, action: goto_initial\|play\|stop, source: state\|delta_ee\|abs_ee = state}` → `ReturnHomeResult` | 2026-09-10 (§10.8, operator request). `goto_initial` walks the arms to the episode's FIRST recorded frame (a transient profile through the return-to-initial path: two twin-planned + gated phases, one arm at a time, interruptible); `play` replays the whole episode from `source` (2026-09-11): `state` = the measured trajectory (lockstep-resampled, every posture twin-verified first, both arms together — the ONE motion that may, §10.8), `delta_ee` / `abs_ee` = the recorded `action` / `action.abs_ee` column through the policy's per-tick executor path inside the current session's loop (gated per tick, no whole-path verification, the outcome carries the TCP residual — §10.8 "Replay sources"); `stop` cancels a replay (idempotent, the Welcome page's only cancel — it has no control socket). Both motions are **SYNCHRONOUS** (a 37 s episode is a 37 s request). Operational refusals are a **200 with `ok: false`**: no session, an episode naming arms this session does not drive, an arm more than 1° from frame 0 (`"run 'Return to the initial state' first"`), a twin-blocked posture (naming the pair and how many seconds in), `MOTION_BUSY`, the §10.5 blockers; for the action sources also `"action replay is admitted in sim only"`, `"action replay runs in teleop / collect sessions only - …"`, an episode lacking the column (names `tools.backfill_abs_ee`), `"unknown playback source …"`. `repo_id` / `episode_id` are pattern-validated in the MODEL (422), not only in the path routes: they arrive in a JSON body and are joined onto a filesystem root |
| `DELETE /api/session` | → 204 | TEARDOWN (idempotent). Cancels an in-flight plan and produces **no motion of its own** — the return above is a separate, explicit call. Also the path the orphaned-session watch takes on its own (§13.2) |
| `GET /api/datasets` | → `DatasetInfo[]` | 2026-09-07 (§10.6; core §12): every dataset under `datasets_root`, newest first — `repo_id`, `root`, `layout: episode_dirs \| lerobot_v3`, `total_episodes`, `total_frames`, `fps`, `robot_type`, `kind`, `task`, `cameras`, `arms`, `modified_at`, `in_use`, `export {state: none\|stale\|fresh\|running\|failed, path, at, episodes}`. Reads `manifest.json` / `episode.json` only (no lerobot import). 2026-09-08: also every dataset under the mapped namespace roots (§10.6 "Per-namespace roots"); rows carry `namespace` + `path` (additive) |
| `GET /api/datasets/layout` | → `DatasetLayoutInfo{default_namespace, generic_root, namespaces: {ns: {root, subdir}}}` | 2026-09-08 (15-online-dagger §7; core §12): where datasets live, so the UI shows the REAL folder in its previews and never hard-codes a namespace. Declared BEFORE `/datasets/{ns}/{name}` — the literal segment is never read as a namespace (`/api/datasets/layout/x` → 404). Always 200 |
| `GET /api/datasets/{ns}/{name}` | → `DatasetInfo` \| 404 | one dataset |
| `GET /api/datasets/{ns}/{name}/episodes` | → `EpisodeInfo[]` \| 404 | capture order; `episode_id`, `index` (position), `frames`, `duration_s`, `task`, `session_id`, `recorded_at`, `frames_dropped`, `audio`, `export_ok`, `export_note`, `open` |
| `GET /api/datasets/{ns}/{name}/episodes/{id}/playback` | → `EpisodePlaybackInfo` \| 404 \| 409 | 2026-09-10 (§10.8): `frames`, `fps`, `duration_s`, the per-arm INITIAL state (`EpisodePlaybackArm{arm_id, q, rail_pos_m, gripper_open_frac}`), `playable` / `reason`, and since 2026-09-11 `sources` (`["state"]` always, + `delta_ee` when the `action` column is well-formed, + `abs_ee` when `action.abs_ee` is) and `action_space` (the recorded primary space, `null` without one). **Session-less on purpose** — the dialog opens and explains itself before anything moves, so a refusal is a sentence rather than a 409 to interpret. 404 unknown dataset / episode; 409 a legacy LeRobot tree, a missing or unreadable `frames.parquet`, a manifest without `observation.state` column names |
| `DELETE /api/datasets/{ns}/{name}/episodes/{episode_id}` | → 204 | removes ONE episode directory (10-frames §11.7); 404 unknown; 409 `"episode is being recorded"` for the open episode, 409 `"legacy LeRobot v3 dataset - read-only"`; allowed while a session records into the dataset — EXCEPT (2026-09-08 evening, §10.7) a saved rollout of the RUNNING Online DAgger session: 409 `"dataset 'online_dagger/<s>' is in use by the running Online DAgger session - end the session first (the trainer is told about discards, not deletions)"` |
| `DELETE /api/datasets/{ns}/{name}` | → 204 | the whole tree; 409 while a session records into it or an export runs; 404 unknown |
| `POST /api/datasets/{ns}/{name}/export` | `{format: "lerobot_v3", out?: str}` → **202** `{repo_id, format, started_at}` | starts the export job (§10.6, 10-frames §11.8); progress on `telemetry.datasets.export`; 409 while a session records into that dataset, while another export runs, or for a legacy tree; 404 unknown |
| `GET /api/episodes` | → `{repo_id, total_episodes, total_frames}` | DEPRECATED (2026-09-07): the running session's counters now ride `telemetry.episode`; kept one release as an alias, `repo_id: null` without a collect/dagger session |
| `GET /api/tracker/calibration` | → `TrackerCalibrationStatus` | phase-10 (13-tracker §3 item 8); idle snapshot (`kind: none, phase: idle` + persisted `yaw_valid` / dates) when nothing runs; the same object rides `telemetry.tracker.calibration` |
| `POST /api/tracker/calibration` | `TrackerCalibrationCommand{kind: base_station\|yaw, op: start\|capture\|validate\|install\|apply\|abort, point?}` → `TrackerCalibrationStatus` | 409 `{detail}` on an illegal transition (`CalibrationError`): `"stop the session first"`, `"backend is not libsurvive"`, too few scenes for `validate`, `install` without `validation.passed`, `apply` with non-empty `fit_checks`, `capture` after all seven points, a second `start` while one runs. Returns the post-command snapshot; progress via telemetry (§6 "Tracker calibration modes") |
| `POST /api/hardware/arms/{arm_id}/maintenance` | `ArmMaintenanceRequest{op: clear_errors\|apply_backstops\|recover\|home_rail\|set_collision_sensitivity, dry_run, collision_sensitivity?}` → `ArmMaintenanceResult{arm_id, op, path: monitor\|session, ok, detail, sdk_codes, warnings, before?, after?, rail_sweep?, status: done\|accepted\|refused, job_id?, collision_sensitivity?}` (200; **202** when `status == accepted`) | phase-09b (core §12 `protocol/maintenance.py`; `docs/prompts/phase-09b-error-recovery.md`). **Four of the five ops produce no motion; `home_rail` (phase-09c, below) is THE ONE op that moves a mechanical part.** Routing (`Runtime.arm_maintenance`): 404 = `arm_id` not in `workcells.hardware`; **a hardware session owns the boxes** → the *session path* (`SessionManager.session_recovery`): `clear_errors` and `recover` both run the driver's user-initiated recovery on ITS monitor thread (`HardwareWorkcell.request_recovery(arm_id)`: `clean_error → clean_warn → motion_enable(True) → set_mode(1) → set_state(0)` → re-seed from the MEASURED position; the handler waits ≤ 10 s for a `recovery_result()` with a higher `seq` AND `user_initiated` — the driver bumps `seq` for its own auto recoveries too, and an auto sequence already running when the operator clicked completes first and must not be reported as the operator's outcome — and reports `ok` / the latch reason, e.g. `controller error 1: … - motion_enable failed (release the physical e-stop?)`), `apply_backstops` → 409 (the driver applied the volatile settings at connect), an arm outside `SessionSpec.arms` → 409; **no hardware session** → the *monitor path* (`HardwareStateMonitor.maintenance`): `clear_errors` = `clean_error` + `clean_warn` and NEVER `motion_enable`, `apply_backstops` = `backstops.apply_backstops(api, XArmDriverConfig)` with the arm's `ArmConfig` mapped through the hardware package's own `workcell._driver_cfg` (identical values to the connect-time call; §14), both queued to the arm monitor's poll thread (one `XArmAPI`, one thread; the REST threadpool thread only waits ≤ 10 s), `recover` → 409 `"no hardware session - use clear_errors"`, monitor off / paused / connecting / error → 409 (`"… needs the read-only monitor connected to 'view' (monitor error: …)"`), a second op on the same arm while one runs → 409 (`"a maintenance op is already running on 'view'"`; per-arm lock + the monitor's `maintenance_busy`). 200 whether or not `ok` (a failed `clean_error` code, a re-latched error, a timed-out poll thread all come back as `ok: false` + `detail`). `before` / `after` (monitor path only) are `ArmMonitorTelemetry` rows sampled right before / after the op with `backstops_match` computed against the config, so the UI can show `error_code` → 0 and `collision_sensitivity` / `tcp_load_kg` landing. `sdk_codes` preserves call order (`{clean_error, clean_warn}`; the `backstops.py` sequence). One INFO audit line per call: `maintenance <op> on arm <id> from <client host> via <path>: ok\|FAILED - <detail>` (refusals: `refused - <detail>`). **`home_rail` (phase-09c; `docs/prompts/phase-09c-hardware-session.md`, user rule 1 "no implicit motion"):** `set_linear_track_back_origin` drives the carriage to the track's zero end (the operator's LEFT, +X) at the track's OWN homing speed (no SDK setter, duration unmeasured; the positioning cap `rail_speed_mm_s` 50 is written AFTER homing for later moves — 02-hardware §8.6), so it is operator-triggered from the arm card only, **session-less only** (a hardware session exists → 409 `"home_rail is not available while a hardware session owns the arms - end the session first"`; a session is refused while the rail is unhomed, so homing is never needed inside one) and **twin-gated**: `HardwareStateMonitor.maintenance(…, dry_run)` first runs `devices/rail_sweep.py::RailSweepChecker.check` — a dedicated `DigitalTwin` (never the overlay's or a session's; `SceneOverrides(microphones, base_pose)`, `hardware_session.home_rail_inflation_m` 0.025 m = the guardrail's debug margin for a blind sweep from an unknown start, D4) posed with the target arm at its CURRENT 7 joints and the other arm at ITS last sample (rail → `rail_fallback_m` + an `assumptions` entry when unknown, `rail_flip` applied), sweeping the target's rail slot `linspace(0, 0.65, 131)` (`home_rail_step_m` 5 mm) with `check_config_violations` (blocked / clear) and `mj_geomDistance` over the monitored pairs (`min_clearance_*`) → `RailSweepVerdict{scene_id, inflation_m, step_m, travel_m, clear, first_blocked_m/pair, min_clearance_m/at_m/pair, q_checked[7], other_arms, assumptions, sample_seq}` in `rail_sweep`. `dry_run: true` → 200 with the verdict alone, `ok = clear`, `sdk_codes {}` (the HomeRailSheet shows it before the operator confirms); a blocked sweep → 200 `ok: false`, `detail "home_rail refused: rail sweep blocked at 0.000 m (grip_right_inner_knuckle / table) - fold the arm into a tighter posture (xArm Studio) and retry; nothing was written"`, zero writes; a clear sweep → the hardware monitor's `home_rail` op with `expected_q = q_checked` (its poll thread re-samples and refuses, zero writes, if any joint moved > 0.02 rad or an error is latched), writing exactly `set_linear_track_back_origin(wait=True, timeout=30, auto_enable=False)` → `set_linear_track_enable(True)` → `set_linear_track_speed(50)` and judging `ok` from the after-sample registers only (`on_zero == 1 and is_enabled == 1 and error == 0`; the SDK's return code is untrustworthy with `auto_enable`) — `detail "rail homed: carriage at 0.000 m (register 0 mm), track enabled, positioning speed 50 mm/s"`. The REST handler blocks up to **45 s** for this op (D3; `HOME_RAIL_TIMEOUT_S`, 10 s for the others); while it runs the arm reads `stale` with `maintenance_busy: true` and `POST /api/session` is 409 `"rail homing in progress on the …"`. 409s before any write: monitor not connected, a sample missing, `rail_present` false (`"no linear track detected"`), `error_code != 0` (`"clear errors first"`), no twin (`"home_rail needs the digital twin to gate the sweep"`), another op running, **a homing in flight on the OTHER arm** (`"home_rail refused: rail homing in progress on the Perception Arm - wait for it to finish"` — its monitor publishes nothing while the carriage travels, so its sample would pose it pre-homing), **the target's monitor `stale`** (`"… sample of 'grip' is stale … retry when it reads running"` — the sweep needs the CURRENT posture; the hardware monitor re-samples before the write and refuses too when that read fails). Another arm whose monitor is not `running` is still posed from its last sample, with the `assumptions` entry `"view: monitor stale - posed from its last sample, which may not be its current posture"`. **Phase-09d (`docs/prompts/phase-09d-rail-homing-planning.md`; `devices/rail_homing.py::RailHomingService.request`):** a blocked sweep is no longer a flat refusal. The service runs `HardwareStateMonitor.home_rail_preflight` (the refusals + sweep above, zero writes) and then `PrePositionPlanner.evaluate`: candidate postures in order — the scene keyframe's 7 joints for the arm (`source: keyframe`, the folded factory zero), then the `<arm>_home` key (`home`) — each must be sweep-clear itself, reachable by the sweep twin's RRT-Connect from the current posture with the rail slot LOCKED at `rail_fallback_m` (`RailSweepChecker.plan_path`: the carriage is unknown, the job never moves it) AND pass the position-agnostic `RailSweepChecker.check_path`: the path densified to 0.05 rad, EVERY configuration checked at EVERY one of the 131 rail positions at the 0.025 m sweep margin under the planner's start-posture hysteresis (a pair the current posture already violates at a position may only open up; any new violation blocks) — this check is the ONLY safety basis of the motion. The verdict rides `rail_sweep.pre_position: PrePositionPlan{needed, source, target_q[7], waypoints, duration_s (at 10 %), checked_rail_positions (131), clear, detail}` and decides the response: `pre_position.needed == false` (sweep clear) → the synchronous monitor-path homing above (200, `status: done`); `dry_run` → 200 with the verdict + plan only (`ok` = the op can proceed, zero writes); `needed and clear` → a `RailHomingJob` starts (§5 "Rail-homing maintenance motion") and the reply is **202** `status: accepted`, `ok: true`, `job_id`, `sdk_codes {}`, `path: session` (the job connects this arm's driver) — progress on `telemetry.hardware_monitor.arms[].maintenance` (§13.3), the final `ArmMaintenanceResult` (`status: done`, same `job_id`, `ok` true/false, the driver's `sdk_codes`, `after` = the first monitor sample after the resume) at `GET …/maintenance/last`; `needed and not clear` → 200 `status: refused`, `ok: false`, `detail "home_rail refused: … no rail-safe pre-positioning path: keyframe: …; home: … - fold the arm toward the factory zero posture in xArm Studio (joints 2-7 near 0) and retry"`, zero writes. While a job runs on ANY arm every maintenance op is 409 `"<op> refused: rail homing in progress on the Manipulation Arm - wait for it to finish"` and `POST /api/session` is 409 (`maintenance_busy` covers the job's whole life). **`set_collision_sensitivity` (2026-09-11, operator decision after the fridge-door C31 bursts; core `protocol/maintenance.py`, 02-hardware §3.5 / §6):** ONE write, `set_collision_sensitivity(level)` with `level = body.collision_sensitivity` — REQUIRED for this op and **1, 2 or 3 only** (0 turns detection off, 4 / 5 false-trigger under payload): a missing / out-of-range / fractional level is **422** on the wire (the core model's `ge=1, le=3` + after-validator) and `ValueError → 422` from `Runtime.arm_maintenance` for an in-process caller; every other op ignores the field. No motion. **Allowed on BOTH paths, unlike `apply_backstops`:** *no hardware session* → the monitor path (`HardwareStateMonitor.maintenance(…, collision_sensitivity=)` → the arm monitor's poll thread writes once, waits ≤ `BACKSTOP_READBACK_SETTLE_S` for the rich frame and is `ok` iff the read-back equals the level; `before` / `after` rows carry it, `after.backstops_match` is judged against the level WRITTEN, the result's `collision_sensitivity` is the read-back; `detail "collision sensitivity set to 2 (was 3; the config value 3 is re-applied at the next connect)"`); *a hardware session owns the boxes* → the session path (`SessionManager.session_set_collision_sensitivity` → `HardwareWorkcell.request_set_collision_sensitivity(arm_id, level)` on the SESSION driver's 5 Hz monitor thread — the sibling of `request_recovery`, never an SDK call on the REST thread — awaited ≤ 10 s via `setting_result(arm_id)` (`SettingResult{seq, ok, code, level, detail}` with a higher `seq`); `before` / `after` `None` (the `real` report stream has no read-back), `sdk_codes {set_collision_sensitivity: <raw code>}`, `collision_sensitivity` = the level written when `ok`, `detail "collision sensitivity set to 1 on the session driver (verified by the monitor after the session)"`). **SDK fact (1.18.5):** `set_collision_sensitivity(value, wait=True)` ignores `wait`, calls `wait_move()` (returns at once in servo mode 1 or with an error latched), then `set_collis_sens`, then unconditionally `set_state(0)` (idempotent for a streaming arm; refused by the controller while an error is latched), and returns the RAW uxbus code — a 1 / 2 / 9 status echo while a fault is latched is NOT a failure: the hardware half reports it `ok` with the note (session path: the note rides `warnings`; monitor path: the read-back decides and the echo is appended to `detail`). **Volatile, server-authoritative:** the controller default stays the config value (`workcells.hardware.arms[*].collision_sensitivity`, 3 on both lab arms), re-applied at EVERY driver connect by `apply_backstops` (§14); the runtime remembers the operator's REQUESTED level per arm (`HardwareStateMonitor.requested_sensitivity`, set by both paths on success) until the next hand-over (`_apply_paused(True)`: a hardware session or a `RailHomingJob` connects a driver) or a successful `apply_backstops` forgets it; the UI shows the READ-BACK (the monitor row, kept meaningful while paused — §13.3), never an optimistic value. 409s unchanged: `"<op> refused: rail homing in progress on the … - wait for it to finish"` (every op while a job runs), monitor off / paused / connecting / error without a session, `"a maintenance op is already running on '<arm>'"`, an arm outside `SessionSpec.arms` inside a session, `"the session workcell has no collision-sensitivity channel"`, the driver's `CommandError` (not connected / read-only). 404 unknown arm. D7 unchanged (hardware sessions are teleop / collect only). Fake-tested both paths (`tests/test_maintenance_api.py`, §16) |
| `GET /api/hardware/arms/{arm_id}/maintenance/last` | → `ArmMaintenanceResult` \| 404 | phase-09d: the last result of the last `home_rail` on this arm — while a `RailHomingJob` runs the 202's `accepted` result (same `job_id`), afterwards its final result, else a synchronous homing's or a refused real op's; 404 until one exists (also for an unknown arm). The HomeRailSheet fetches it when the job's phase reaches `done` / `failed` (polling past `accepted`), and polls it itself when telemetry never shows the job; it only settles on a result carrying ITS `job_id` |
| `GET /api/online_dagger/skill` | → `text/markdown; charset=utf-8` (the `SKILL.md`) \| 404 | 2026-09-08 evening (§10.7; 15-online-dagger §7 / §9, D8). Session-less. The skill is package data (`online_dagger/skill/`); `RuntimeConfig.online_dagger.skill_dir` overrides the directory; 404 `"Online DAgger skill not found: <OSError>"` when it has no `SKILL.md`. Superseded (2026-09-08 evening): the morning's `/api/pro_dagger/{skill,skill.tgz,sessions}` rows — those routes never shipped and answer 404 (pinned by `tests/test_server_contract.py`) |
| `GET /api/online_dagger/skill.tgz` | → `application/gzip`, `Content-Disposition: attachment; filename="mavis-online-dagger-trainer.tgz"` \| 404 | the whole skill directory as a gzip tarball rooted at `mavis-online-dagger-trainer/` (deterministic member order) — `curl -s http://<host>:<port>/api/online_dagger/skill.tgz \| tar xz -C ~/.claude/skills/`; never an empty tarball (404 instead) |
| `GET /api/online_dagger/sessions` | → `OnlineDaggerSessionInfo[]{session_name, path, created_at, task, rollouts, last_used_at}` | session-less; every `<online_dagger root>/*/session.json` (the mapped `online_dagger` namespace root, else `<datasets_root>/online_dagger`), newest `last_used_at` first; `rollouts` = `current.rollouts_saved`; an unreadable file is skipped with a warning; `[]` when the root does not exist. The launch sheet's resume picker |
| `GET /api/dora` | → `DoraInfo` | phase-12 (14-dora §2.6, §16): the connection facts foreign clients need (bind host, coordinator / daemon / zenoh ports, `zenoh_connect`, dataflow, placeholders, machines) — never the auth token. `POST /api/dora/machines/{id}/join` → 202 `DoraInfo` \| 404 `"machine '<id>' is not in dora.machines"` (§17) |

**Not REST** (binding decision, 05-ui §4): episode new/save/discard, profile
save / set-as-initial, joint targets, switch_arm, takeover — all ride
`/ws/control` as `ActionMsg` and are answered by `AckMsg`. **Addendum
(binding, 2026-09-03, phase-10):** session-less *device management* is REST
with progress broadcast via telemetry — `/api/tracker/calibration` is the
first instance, `/api/hardware/arms/{arm_id}/maintenance` (phase-09b) the
second: it is session-less on the Welcome page's Hardware tab and, inside a
hardware session, still an operator action on a *device* (the controller),
not on the session, so it adds no `ActionName` and no keymap row either. The
Devices page has no session, `/ws/control` nacks every
action without one ("no session") and `AckMsg` carries no payload, so
calibration adds no `ActionName` and no keymap row; the rule above still
covers every discrete op that acts on a session.

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

**Orphaned session** (2026-09-09 evening, operator request; `session/orphan.py`,
`OrphanSessionWatch`). A session nobody can drive is a hazard, not a feature: that
evening a hardware Teleop session started at 22:51 was still `running` at 23:16
because the Cockpit tab had been closed with the browser's Back button instead of
**End session**. Both control boxes stayed enabled with the arms holding their
posture, the read-only hardware monitor stayed paused — so every Welcome-page arm
gate read `monitor_off` and all four launch cards were disabled with no explanation
— and nothing on the machine would ever have released them.

So the runtime ends such a session itself. The one liveness signal is the
**controller** `/ws/control` connection, because that socket carries the 25 Hz key
heartbeat, the actions and the deadman: without it nobody can drive, and an
`observer` deliberately does not count. When it has been gone for
`control.orphan_session_grace_s` (default **30 s**; 0 disables the watch) the watch
calls `SessionManager.teardown()`. Properties, all binding:

- **The end produces NO motion.** It is exactly the `DELETE /api/session` path: the
  drivers hand the arms back stopped with the brakes engaged, where they stand, and
  the tracks keep their homed state. It deliberately does NOT run the Cockpit's
  return-to-initial-condition first — that is a twin-planned motion, and with nobody
  in the room and the twin not modelling the furniture (03-sim §4.5) an unattended
  replan is the last thing wanted.
- **A reload is not an orphan.** The grace period is what separates "closed for
  good" from F5: a reloaded Cockpit re-opens the socket within a second and the
  countdown resets. `POST /api/session` and `POST /api/session/{return_home,
  playback}` also stamp it (`note_activity`), so a synchronous motion driven from a
  page with no control socket is never cut off mid-way.
- **A session that never had a controller is never ended.** The watch fires only on
  a session whose controller connected and then went away — the case that bit us —
  which keeps a deliberately REST-driven session (a test harness, a script, a policy
  bring-up that has not opened its socket) safe from a background thread tearing it
  down. `ws_control` records the attendance itself (`note_controller_connected`), so
  a controller that connects and drops inside one poll period still counts. The one
  gap left: a `POST /api/session` whose browser died before the Cockpit ever mounted
  stays up — visible instead, because `telemetry.session.mode` now lets the Welcome
  page offer its Cockpit route (and thus **End session**).
- **An open episode is discarded**, because `teardown()` discards it (§10.4). An
  episode being recorded by nobody is not worth keeping the arms live for; the notice
  and the log line both say it happened, naming the episode id.
- A dedicated 0.5 s daemon thread polls it (`Runtime.start()` arms it last,
  `Runtime.stop()` disarms it first so the two teardowns cannot race). Not the
  telemetry socket: the orphan case is "every browser tab is gone".

Why the session ended is published on `telemetry.session.auto_ended`
(`SessionAutoEndNotice{session_id, mode, kind, ended_at, reason}`; core §11) and
survives until the next session starts, so the Welcome page can tell the operator
the arms were released while nobody was watching — otherwise the cell is silently in
a different state than the person walking back to it expects. Tests:
`tests/test_orphan_session.py` (injected clock; plus one end-to-end over
`create_app` that closes a control socket and watches the session go).

### 13.3 `/ws/telemetry`

Broadcast-only, N observers, **25 Hz** (config 20–30). An asyncio task reads
the `snapshot` slot, builds `TelemetryMsg` (shape exactly as 05-ui §2:
`t, seq, ts, epoch, active_arm, controller_connected, arms: ArmTelemetry[],
collision: CollisionReport, clearances, episode, dagger, inference`), and fans out with
per-client latest-wins: a slow consumer gets frames dropped, never
back-pressures control. Runtime-side additions inside the same message:
`session: {state, session_id?, mode?, kind?, auto_ended?, start_from_progress?,
plan_status?, trainer_alive?, bringup?, translate_frame?, fault_detail?}` — additive,
UI ignores unknown fields.
**`session.session_id` / `mode` / `kind`** (additive, 2026-09-09; a hardware bring-up
counts, exactly as for `GET /api/session` — `SessionManager.session_identity()`): the
live session's identity, `null` with none. The Welcome page never opens `/ws/control`
and has no `SessionInfo` on a fresh load, so this is how it learns a session is
running and which Cockpit route to offer instead of four disabled launch cards.
**`session.auto_ended`** (additive, 2026-09-09; `SessionAutoEndNotice`): why the LAST
session ended WITHOUT an operator click — today only the orphaned-session watch
(§13.2) — cleared when the next session starts, `null` when the last one ended by
DELETE or none ran. Shown verbatim by the Welcome page.
**`session.fault_detail: str`** (additive, 2026-09-08; core §11): the
manager's session-level notice the per-arm rows do NOT already carry —
`ActiveSession.notice()`: the last profile motion's outcome / a refused or
unplannable `start_from` (`ActiveSession.motion_detail`, §10.5) first, else the
arms' fault text but only while no `arms[*].fault_detail` is non-empty (a fault
before the first snapshot); `""` = nothing to say. `SessionInfo.fault_detail`
(REST) carries the same text. The Cockpit's FaultBanner shows it verbatim as an
amber `SESSION — …` row (05-ui §8.2). **`session.bringup:
ArmBringupTelemetry[] | null`** (phase-09c, D5; core §11): one row per
`(arm_id, step, status: pending|ok|warning|error, detail)` while a HARDWARE
bring-up is in flight and until the session is `running` — the `monitor`
hand-over, the workcell's `ArmBringupStatus` stages (`network` / `connect` /
`rail` / `gripper` / `report` / `warnings`), `gate`, `frozen`
(`"Perception Arm frozen at last sample (monitor seq 5)"`, D1) and `loop`; `null`
for sim sessions, after RUNNING and after a failed bring-up. `session.state` is
`bringup` during that window although `arms` is still empty (no snapshot yet);
`SessionInfo` (REST) carries `kind` and `speed_scale` for the same reason. `ee_pose` is m + **wxyz**;
`rail_pos_m: null` for rail-less arms; `dagger: null` outside DAgger;
`episode: null` in teleop/inference. **`arms[*].fault_detail` /
`arms[*].recovering`** (additive, phase-09b; core §11): the control loop's
per-arm driver-fault text (`StateSnapshot.session_extra["arm_faults"]`, the
SDK `x_code` title — `controller error 24: Speed Exceeds Limit` — plus the
driver's latch reason when there is one; kept while the arm is FAULT or
RECOVERING, `""` once RUNNING) and the re-seeded-waiting-for-the-operator
flag (`session_extra["arm_recovering"]`), §5 item 5 / §15. A
`StudioConflictWarning` (UFACTORY Studio live control fighting the stream)
rides the same `fault_detail` field as `warning: close UFACTORY Studio live
control` for 5 s without stopping the arm (`recovering: false`, `session.state`
unchanged — core `TelemetryMsg` has no separate warnings field); a real fault
replaces it. `session.state` reports `fault` / `recovering` per §5.
**`arms[*].collision_sensitivity: int | null`** (additive, 2026-09-11; core
§11): the collision sensitivity the operator WROTE this session with the
`set_collision_sensitivity` maintenance op (1..3; §13.1), read from the
runtime's per-arm requested-level map (`HardwareStateMonitor.requested_sensitivity`)
for HARDWARE sessions — the session driver's report stream carries no
read-back, so this is the in-session value; `null` = the config value / unknown
(every sim session, an arm never written). Volatile: the map is cleared at the
hand-over that precedes every driver connect (the config value is back). The
Cockpit's sensitivity control prefers the monitor row's `collision_sensitivity`
(below) and falls back to this field.

**`microphone: MicrophoneTelemetry | null`** (additive, phase-11; core §11): the
Runtime-owned `MicrophoneReader`'s newest frame + device status, present pre-
session and `null` only when `microphone.enabled` is false. Fields: `mic_id`,
`status: MicStatus` (`no_backend | starting | absent | live | stalled | error`,
shared with `MicrophoneInfo`), `detail`, `seq`, `age_s`, `rate_hz`,
`sample_rate`, `rms_dbfs` / `peak_dbfs` (0 dBFS = |1.0|, `null` before the
first frame), `clipping` (`peak_dbfs >= -1`), `env_min[64]` / `env_max[64]`
(time-ordered per-bin min/max of the frame as int8 −127..127 **relative to the
frame peak** — the loudest sample maps to ±127 so a −58 dBFS room keeps its
shape instead of rounding to zeros; absolute = env / 127 × 10^(peak_dbfs / 20))
and `overruns`. The reader's frame rate is
`telemetry_hz` (25 Hz → 1920 samples = 64 bins × 30, exact binning), so each
telemetry tick carries exactly one new frame; the UI still de-duplicates on
`seq` (a slow client sees the newest frame, never an invented one). `stalled` is
derived like the tracker's `stale`: `status == live` and `age_s > stale_s`. One
block is ≈0.5 kB (≈13 kB/s per client at 25 Hz). Raw PCM is never streamed on
telemetry; a future listen/record feature would get its own `/ws/audio/<id>`
binary channel with the §13.4 framing.

**`datasets: DatasetsTelemetry | null`** (additive, 2026-09-07; core §11):
`export` = the running / last `DatasetExportTelemetry` of the `dataset-export`
job (§10.6: `repo_id`, `format`, `phase: scanning | videos | data | meta |
validating | done | failed`, `done`, `total`, `detail`), built by
`ws_telemetry` from the export job's progress object the same way
`build_hardware_monitor_telemetry(runtime)` builds its block; `null` when no
export has run in this process. Session-less like `microphone`.

**`hardware_monitor: HardwareMonitorTelemetry`** (additive, phase-09a; core §11
`protocol/hardware_monitor.py`; after `microphone`, before `datasets`). Always present: `{enabled: false, paused: false, arms: [],
overlays: []}` is the valid block when no `hardware` workcell is configured or
the `[hardware]` extra is missing. Built by
`ws_telemetry.build_hardware_monitor_telemetry(runtime)` from two
Runtime-owned objects, session-less and pre-session:

- `arms: ArmMonitorTelemetry[]` — one row per configured hardware arm (config
  order) from `devices/hardware_monitor.py` (`HardwareStateMonitor`, one
  read-only `ArmStateMonitor` per arm, `hardware_monitor.*` config §14):
  `status: off | connecting | running | stale | paused | error`, `detail` (the
  SDK's controller-error title, e.g. `controller error 19: End Effector
  Communication Error` — the Perception Arm's live C19), `seq`, `age_s`, `q[7]`
  (rad, controller order — an **identity** mapping onto the twin's
  `<arm>_joint1..7`, verified 2026-09-04, no π offset), `tcp_pose` (flange pose
  `[x, y, z m, roll, pitch, yaw rad]` in the base frame), `rail_present /
  rail_homed / rail_enabled`, `rail_pos_m` (**null unless homed AND enabled** —
  the register is meaningless otherwise; both lab tracks are unhomed today),
  `rail_raw_mm` (always when present), `gripper_open_frac` (0 closed .. 1 open,
  `null` for gripper `none`) / `gripper_raw`, `error_code`, `warn_code`,
  `state` (4 = stopped / not enabled), `mode`. `stale` is derived from the
  sample age (`hardware_monitor.stale_s`); the same `error_code` fills
  `ArmStatusInfo.error_code` in `GET /api/workcell?kind=hardware` (0 without
  a sample). **Phase-09b read-backs** (every slow poll, from the SDK's
  `collision_sensitivity` / `tcp_load` properties — the rich 30002 report
  frame; SDK 1.18.5 has no `get_*` for them): `collision_sensitivity` (0..5),
  `tcp_load_kg`, `tcp_load_cog_mm[3]`; **`backstops_match`** =
  `devices.hardware_monitor.backstops_match(sample, ArmConfig, expected_sensitivity)`:
  sensitivity equal to the EXPECTED level — the operator's
  `set_collision_sensitivity` override since the last driver connect
  (`HardwareStateMonitor.requested_sensitivity`, 2026-09-11) when there is one,
  else the config — AND `|Δ tcp_load| ≤ 0.05 kg` AND every centre-of-gravity
  component within 10 mm (`null` until the first read-back) — the Hardware
  tab's "differs from config" amber, so an obeyed override is not amber;
  **while the monitor is `paused`** (a hardware session owns the box, no fresh
  sample) and a requested level is known, the row's `collision_sensitivity`
  publishes THAT level (the sample's is the pre-session read-back) and
  `backstops_match` judges the payload alone — the Cockpit's sensitivity
  control reads this row first (05-ui §8.2); the read-back replaces it the
  moment the box is polled again; **`maintenance_busy`** = a maintenance op is
  queued / executing on that arm's monitor (§13.1) OR a phase-09d
  `RailHomingJob` owns the arm (true for the job's whole life);
  **`maintenance: MaintenanceProgress | null`** (phase-09d, additive) = the
  job's live progress `{op: home_rail, job_id, phase: queued | sweeping |
  planning | connecting | positioning | homing | verifying | done | failed,
  detail, progress 0..1 (phase index + the waypoint fraction while
  positioning), started_at}` — `null` when no job exists; a terminal phase
  lingers for 60 s (`rail_homing.PROGRESS_LINGER_S`) so the HomeRailSheet sees
  `done` / `failed` and then fetches `GET …/maintenance/last`. During the
  `connecting…verifying` phases the arm's `status` reads `paused` (the job's
  driver holds the box) and `paused` is true for the block. **Zero writes unless an
  explicit maintenance request**: the polling allowlist is
  `apollo_mavis_v2_hardware.monitor.READ_ONLY_SDK_METHODS` /
  `READ_ONLY_SDK_ATTRS`, the per-op write sets `MAINTENANCE_SDK_METHODS`
  (02-hardware §8.6).
- `paused: bool` — a hardware session owns the boxes (the UI's only "a
  hardware session exists" signal, 05-ui §8.2; an INERT monitor — `enabled:
  false` / no hardware package — has nothing to release and reports the
  predicate directly). **Pause = release the connection**: the supervisor
  thread polls `Runtime._hardware_session_active`
  every 0.5 s and `disconnect()`s every arm monitor on the rising edge (status
  `paused`, last sample kept), `start()`s them again on the falling edge; two
  SDK clients on one control box are unevidenced, so the monitor and a
  session driver never hold the same box. `HardwareStateMonitor.pause() /
  resume()` are the synchronous seams the hardware bring-up (phase-09c, §5)
  calls around its own connect, and `join(timeout_s)` waits for the poll
  threads to really exit (the arm ids still alive are returned; the bring-up
  refuses on any); the predicate itself is
  `SessionManager.hardware_session_active` = a hardware session exists OR a
  hardware `create()` is in flight (`_creating_kind`), so `pause()` is never
  undone by the next supervisor round; whole transitions are serialized
  (`_apply_lock`) so a supervisor edge and a seam call never interleave their
  per-arm walks. During a hardware session every arm's row reads `paused`
  (all arms release together, D1) and the session arms' live data ride
  `arms[*]` from the control loop instead.
  `ArmStateMonitor.disconnect()` returns False when its poll thread is still
  inside a blocking SDK call (`connect()` can exceed the 2 s join budget) —
  the runtime logs it; the thread then releases that client itself and never
  re-publishes it (02-hardware §8.5 hand-over guarantee), and a following
  `start()` waits for it before reconnecting.
- `overlays: TwinOverlayTelemetry[]` — one row per `<camera_id>_align` stream
  (§13.4): `stream_id`, `camera_id`, `arm_id`, `status: off | waiting | live |
  stale | error`, `detail` (`rail not homed - twin assumes 0.65 m` — metres,
  two decimals; `monitor stale: …`, `no frame from grip_wrist`, `no sample from
  view yet - monitor error: …`, `paused - a hardware session owns the arms`;
  parts are joined with `; `; the UI tile renders it as a caption with the
  separators as middle dots), `fps` (1 s window),
  `rail_fallback_m` (set while the twin assumes a rail position),
  `joint1_offset_rad` (the diagnostic knob, 0 = verified identity),
  `mask_fraction` (robot pixels / image pixels of the last composited frame).

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
  otherwise closes 1008), plus the phase-09a **`<camera_id>_align`** twin
  overlays of the hardware wrist cameras (session-less; below). Unknown id →
  close 1008. Reservation rules: an overlay id must not end in `_wrist_cam`
  (the sim scene's wrist-camera names) and must not equal any camera id or
  `sim`/`twin`; `twin_overlay.stream_suffix` (default `_align`) is the only
  knob and a colliding id is skipped with an error log.
- **Pre-session previews**: real-camera streams are available with no
  session, encoded at **~15 fps** (landing-page grid); on session start the
  session's cameras switch to configured fps, on teardown back to 15. Hardware
  (phase-09c): the switch IS the adoption — `hub.set_fps(cam_id,
  video.session_fps)` on every open preview camera, ids recorded in
  `ActiveSession.adopted_streams`, the same `OpenCVCamera` object keeps the UVC
  node (never re-opened, `hardware_camera()` unchanged), `set_fps(…,
  preview_fps)` at teardown; `SessionInfo.streams` stays `[]`.
- Sender: `await slot_fresh(); await ws.send_bytes(buf)` — a slow client
  skips frames (client also drops while a decode is in flight, 05-ui §5.4).
- 640×480@30 ⇒ 25–60 KB/frame, 6–15 Mbps/stream; encode 1–3 ms/frame
  (~0.36 core for 6×30) — measured envelope, no NVJPEG needed in v1.

**Hardware camera previews (phase-11).** `SessionManager.start_previews()`
also opens every `workcells.hardware.cameras[]` entry via
`apollo_mavis_v2_hardware.cameras.make_camera(cfg).start()` and streams the ones
that opened at `video.preview_fps` under their camera id. Each camera is
failure-isolated: `CameraInitError` / any exception (device path absent, cv2 or
the `[hardware]` extra missing, duplicate stream id) marks that camera
`live: false` in `/api/cameras` and `/api/workcell?kind=hardware` and touches
nothing else; failed cameras are retried on the next `start_previews()` (after
every session). `stop_previews()` — called when a sim session starts — stops
only the sim preview sources; hardware previews survive sim sessions and are
torn down by `stop_hardware_previews()` at process exit (a hardware session
ADOPTS them in place — fps switch only — instead of taking them over, phase-09c
above). Hardware camera ids must not collide with
sim scene camera names (one VideoHub namespace).
`SessionManager.hardware_camera(cam_id)` returns the started preview camera
(or `None`): a UVC node cannot be opened twice, so every other consumer of a
real frame — the twin overlay below — reads `latest()` from that one object.

**Digital-twin alignment overlays (phase-09a;
`docs/prompts/phase-09a-hardware-twin-overlay.md`; `streams/twin_overlay.py`).**
For every hardware camera mounted on an arm (`extrinsics_frame: ee:<arm>`, else
the `<arm>_` id prefix: `grip_wrist` → `grip`) the Runtime-owned
`TwinOverlayRenderer` publishes a session-less stream
`<camera_id><twin_overlay.stream_suffix>` — `grip_wrist_align`,
`view_wrist_align` — at `twin_overlay.fps` (12): the REAL frame with the
`digital_twin_scene` (`mavis_v2`, Perception Arm with the microphone body,
`SceneOverrides(microphones=…, base_pose=…)`) rendered from the SAME wrist
camera and composited as a pale-yellow translucent silhouette. It is a visual
tool to judge the twin against the cell (rail position and direction, base
pose, camera extrinsics, joint convention) — not a calibration, and not shown
in the Cockpit. One thread owns a PRIVATE `BuiltScene` copy (never the
gate's `DigitalTwin`, nor the `home_rail` sweep's) with these compile-time edits, all verified on
the lab box (MuJoCo 3.12.0 + EGL): `spec.visual.quality.offsamples = 0`
(multisampling blends segmentation ids at edges into OTHER valid geom ids —
mask area inflates, centroid off by 37 px); per wrist camera
`resolution = [640, 480]`, `sensor_size`, `focal_pixel = [fx, fy]`,
`principal_pixel = [W/2 − cx, H/2 − cy]` from `CameraConfig.intrinsics`
(**MuJoCo's principal-point offset has the opposite sign of OpenCV's**; a camera
without intrinsics falls back to fovy 43.2° — the D435i colour field of view,
never the MJCF depth `fovy 57` — with a warning); the environment geoms
(floor / table / obstacle) moved to geom group 4 so `MjvOption.geomgroup[4] =
0` hides them in the robot passes. Per frame: pose every sampled arm from the
monitor (`qpos[j1..j7] = q + [joint1_offset_rad, 0…]`; `qpos[rail] =
rail_pos_m`, `rail_flip` → `0.65 − pos`, or `rail_fallback_m[arm]` while the
track is not homed / enabled — telemetry `rail_fallback_m` + detail `rail not
homed - twin assumes X m`; gripper fingers `(1 − open_frac) · 0.85` rad via the
sim gripper mapping), `mj_forward`, an RGB pass (twin shading) and a
segmentation pass (robot mask = every non-environment geom, mic and camera
bodies included), then `out[mask] = alpha · tint + (1 − alpha) · real` with
`tint = tint_rgb · (0.55 + 0.45 · luminance)`, a 1 px `edge_rgb` inner outline,
and with `env_outline` an env-only segmentation pass whose Canny edges are
drawn in `env_rgb` (table / obstacle edges = the base-placement cue; the robot
occludes them). A stale / erroring / connecting / paused monitor for the
stream's arm swaps the tint for `stale_tint_rgb` (grey) and reports status
`stale` — provided the arm HAS a sample (the twin is drawn from that last
reading); an arm the monitor never sampled (box off, still connecting) →
`waiting` with detail `no sample from <arm> yet - monitor <status>: …`
(nothing published, `/api/cameras` `live: false`) rather than a grey twin at
the keyframe posture nobody measured; no real frame → `waiting` (nothing
published); a hardware session (`paused()`) WITHOUT a state provider → `waiting`
with detail `paused - a hardware session owns the arms`. **During a hardware
session (phase-09c)** the bring-up installs
`TwinOverlayRenderer.set_state_provider(SessionStateProvider)`: the session
arms are posed from the driver's `workcell.states()` (inner workcell, track rail
convention — the overlay applies `rail_flip` itself; status `running`, or
`stale` when the 30003 stream is), the unselected arms from their frozen last
monitor sample (status `stale`, detail `Perception Arm frozen at last sample
(hardware session)`, grey tint); `paused()` is ignored while a provider is
installed and teardown removes it, so the `*_align` streams keep their ids and
stay `live` through the session. The published `CameraFrame` keeps the real frame's `t_mono` /
`wallclock_ns`; each stream is an ordinary `VideoHub` FrameSource
(`TwinOverlaySource`, JPEG q80 over `/ws/video/<id>_align`). GL contexts are
thread-affine: both `mujoco.Renderer`s (RGB + segmentation) and the `MjData`
are created and closed inside the overlay thread; `Runtime.start()` starts
monitor → overlay after `start_previews()`, `Runtime.stop()` stops overlay →
monitor → the rest. `/api/cameras` and `/api/workcell?kind=hardware` list the
overlays as `CameraInfo{kind: "twin", label: "Manipulation · twin overlay" |
"Perception · twin overlay", resolution: [640, 480], fps: 12, live}` with
`live` = the real camera underneath is live AND the overlay status is `live`
or `stale` (so `waiting` / paused / `off` rows draw the black tile and open no
WebSocket). Cost: ~1 ms RGB + ~4.5 ms segmentation per stream per frame.

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
  hardware:                  # phase-11: present even with no arm connected — it is what
                             #   makes the Welcome page's Hardware tab exist (05-ui §8.1)
    kind: hardware
    digital_twin_scene: mavis_v2        # twin for planning/gating; ArmConfig.microphone: true
                                        #   on the Perception Arm adds the mic collision body (03-sim §4)
    arms:                               # exactly two control boxes (2026-09-04), one NIC each
      - {id: grip, ip: 192.168.1.201, base_in_world: {}, gripper: xarm_g2,  # Manipulation Arm:
         tcp_load_kg: 0.95, tcp_load_cog_mm: [0, 0, 60],                    #   Gripper G2 + wrist
         collision_sensitivity: 3}                                          #   cam; default teleop arm
      - {id: view, ip: 192.168.2.219, base_in_world: {}, gripper: none,     # Perception Arm: wrist
         microphone: true,                                                  #   D435 + RØDE NT-USB Mini
         tcp_load_kg: 0.55, tcp_load_cog_mm: [0, 0, 90],
         collision_sensitivity: 3}
                                        # tcp_load_* are estimates accepted 2026-09-05 (not weighed; phase-09b):
                                        #   G2 + D435i + mount ≈ 0.95 kg @ (0, 0, 60) mm, D435i +
                                        #   NT-USB Mini + mount ≈ 0.55 kg @ (0, 0, 90) mm; sensitivity
                                        #   3 on both; reduced_tcp_boundary_mm / expected_sn unset
    cameras:                                # both wrist cams are RealSense D435i used as UVC
                                            # colour cameras: by USB serial (by-id collides
                                            # between the depth and colour interfaces), YUYV
                                            # only; serial -> arm mapping confirmed 2026-09-04
      - {id: grip_wrist, kind: v4l2, serial: "349643062582", fourcc: YUYV,
         resolution: [640, 480], fps: 30,
         intrinsics: {fx: 608.19, fy: 608.23, cx: 327.39, cy: 247.90}}  # D435i COLOUR (Inverse
                                                   # Brown-Conrady, distortion ignored)
      - {id: view_wrist, kind: v4l2, serial: "322143060792", fourcc: YUYV,   #   imager
         resolution: [640, 480], fps: 30,                                   #   (rs-enumerate-
         intrinsics: {fx: 606.36, fy: 606.38, cx: 311.90, cy: 249.45}}  #   devices -c),
                                            # fovy = 2·atan(240/fy) ≈ 43.2°, NOT the MJCF
                                            # depth fovy 57; the twin overlay renders with them
    safety: {enabled: true, geom_inflation_m: 0.008, min_clearance_m: 0.016}
  sim:      { <WorkcellConfig>: sim_scene, cameras (kind sim),
              safety: {safety_debug: false} }
profiles_dir: ${APOLLO_HOME}/var/profiles       # ${APOLLO_HOME} = workspace root (self-contained
datasets_root: ${APOLLO_HOME}/var/datasets      #   paths, below); resolved by config.py, then
checkpoints_root: ${APOLLO_HOME}/var/checkpoints  #   ~ / other $VARS expanded, still-relative
calibration_dir: ${APOLLO_HOME}/var/calibration   # anchored at the ws root. tracker_calibration.json
                                        #   + libsurvive temp/installed copies (phase-10, 13-tracker §4)
datasets:                               # 2026-09-08 (operator decision; 15-online-dagger §7 D5; §10.6): per-
  default_namespace: bc_demo            #   namespace roots. Repo ids keep the <ns>/<name> grammar; a bare
  namespaces:                           #   `dataset: "<name>"` resolves into default_namespace. Roots expand
    bc_demo:       {root: ~/data/bc_demo}   #   ~ / ${APOLLO_HOME} like datasets_root. -> ~/data/bc_demo/<name>
    online_dagger: {root: ~/data/online_dagger, subdir: rollouts}   # -> ~/data/online_dagger/<s>/rollouts
                                        #   (next to session.json; the trainer's own files live beside them);
                                        #   subdir is ONE directory name. Every namespace NOT listed lives at
                                        #   <datasets_root>/<ns>/<name>. Keys validated against the REST <ns>
                                        #   grammar. Same values as the model defaults (DatasetsConfig /
                                        #   DatasetNamespaceConfig). Superseded (2026-09-08 evening): the
                                        #   morning's `pro_dagger: {root: ~/data/pro_dagger, …}` — never shipped
online_dagger:                          # phase-14 (15-online-dagger §7; §10.7): the runtime's side only - it is
  skill_dir: null                       #   the algorithm-agnostic shell, the trainer node configures itself.
  session_file_hz: 1.0                  #   null = the skill shipped inside the package (GET /api/online_dagger/
                                        #   skill[.tgz]); session_file_hz caps session.json rewrites outside
                                        #   transitions. Same values as the model defaults (OnlineDaggerRuntimeConfig).
                                        #   Superseded (2026-09-08 evening): the morning's `pro_dagger:` block
control:
  rate_hz: 100
  teleop: {linear_mps: 0.12, angular_rps: 0.6, rail_mps: 0.10, gripper_frac_ps: 1.2}
  leash: {pos_m: 0.025, rot_rad: 0.2}
  target_rate: {v_mps: 1.0, w_radps: 2.0}   # tracker target approach rate (§6)
  dq_max_rad: 0.04           # per tick
  rail_in_ik: false          # rail excluded from the IK; rail inputs slide the whole arm (§6 "Rail")
  jog: {slew_rad_per_tick: 0.02, rail_m_per_tick: 0.002}   # any delta; constant-speed approach
  watchdog: {stale_s: 0.2, ramp_s: 0.1}   # = SafetyConfig input_deadman_s/input_ramp_s
  health_log_every_s: 1.0    # control-loop INFO health line period ("Logging" below); 0 = off
  orphan_session_grace_s: 30 # 2026-09-09 (§13.2): how long a session survives with NO
                             # controller /ws/control connection and no session REST
                             # activity before the runtime ends it ITSELF through the
                             # no-motion teardown. Long enough that an F5 in the Cockpit
                             # is not an orphan; 0 disables the watch (the test suites pin 0)
recorder: {fps: 25, vcodec: auto, jpeg_quality: 80,
           audio: true,                                      # per-episode WAV when the mic is live (§10.5)
           export: {video_file_mb: 200, data_file_mb: 100},   # LeRobot v3 export shard caps (10-frames §11.8)
           extrinsics_warn: {pos_m: 0.003, rot_rad: 0.010},   # checkpoint-load
           extrinsics_max:  {pos_m: 0.010, rot_rad: 0.035}}   #   verify, 10-frames §5.3
                             # (the 2026-09-07 interim `video_file_size_mb` never shipped — §10)
telemetry_hz: 25
video: {preview_fps: 15, session_fps: 30}
dagger: {policy_hz: 15, t_blend_s: 0.3, pause_others_on_takeover: true,
         anchor_leash: null,        # 2026-09-11: LeashConfig{pos_m, rot_rad} for the policy /
                                    #   replay ActionAnchor; null = control.leash (§11)
         trainer: {gpu: 1, min_new_labels: 100, push_period_s: 5,   # 12-dagger §7
                   port: 5757}}                                     # tcp://127.0.0.1
tracker: {backend: none,            # none | fake | libsurvive (13-tracker §4)
          object_name: WM0, libsurvive_args: ["--lighthousecount", "2"],
                                              # lab adds --globalscenesolver 0 --disable-calibrate 1
                                              #   (frozen calibration, 13-tracker §6); these are the
                                              #   NORMAL args the reader returns to after a calibration
          yaw_deg: 0.0, pos_scale: 1.0, follow_rotation: true,       # live defaults; yaw_deg is
                                                                     #   overridden by a valid
                                                                     #   tracker_calibration.json
          stale_s: 0.2, max_jump_m: 0.10,
          controller_map: {clutch: trigger_click,                    # 13-tracker §1.1;
                           gripper_open: trackpad_up,                #   trackpad_* classified
                           gripper_close: trackpad_down,             #   at the press edge;
                           rail_neg: trackpad_left,                  #   rail codes drive the
                           rail_pos: trackpad_right,                 #   rail at device scale;
                           arm_next: menu_click,                     #   arm_* = discrete (any
                           arm_prev: none},                          #   input but trigger_click)
          trackpad_deadzone: 0.3,             # |x|,|y| both within -> click ignored
          filter: {enabled: true, min_cutoff_hz: 1.0, beta: 5.0,     # One Euro (live: enabled/
                   d_cutoff_hz: 1.0, deadband_m: 0.001,              #   min_cutoff/beta via
                   deadband_rad: 0.005},                             #   tracker_settings)
          libsurvive_config_path: ${APOLLO_HOME}/var/libsurvive/config.json,  # libsurvive reads/writes
                                              #   it at teleop (tracker.py adds --configfile); the
                                              #   `install` step (wizard) is the only other writer
          calibration: {min_scenes: 6,                               # phase-10 (13-tracker §4)
                        validation_seconds: 10.0, validation_skip_seconds: 3.0,
                        validation_std_mm: 5.0, validation_step_mm: 20.0,
                        still_window_s: 0.5, still_threshold_mm: 3.0,
                        yaw_min_leg_m: 0.10, yaw_max_residual_deg: 15.0,
                        yaw_capture_average_s: 0.3}}
microphone:                  # phase-11 (§13.3); Runtime-owned like tracker.*
  enabled: true              # false (default) = not listed, telemetry.microphone null
  mic_id: mic_view           # ids never change; only the labels are user-facing
  label: Perception Arm microphone   # default "Perception Arm microphone"; landing page + telemetry
  backend: auto              # auto | sounddevice | parec | fake | none
                             #   auto = sounddevice (PortAudio ALSA `pulse` plugin, source
                             #   pinned via PULSE_SOURCE) -> parec subprocess; NEVER hw:
  source_match: NT-USB Mini  # substring of the Pulse source name/description
                             #   (`pactl -f json list sources`; monitors ignored; `_`/`-`/space
                             #   interchangeable — pactl blanks the Ø description to "(null)")
  sample_rate: 48000         # the NT-USB Mini is S24_3LE mono 48 kHz only (ALSA card
                             #   `Mini`, USB 19f7:0015, serial 750BFEE8)
  bins: 64                   # int8 min/max envelope points per frame
  stale_s: 0.5               # no frame for this long -> stalled
                             # frame rate = telemetry_hz (25 Hz -> 1920 samples/frame)
hardware_probe:              # phase-11 (§13.1 `reachable` / `hardware_ready`)
  enabled: true
  period_s: 2.0              # one connect-and-close round per configured hardware arm
  timeout_s: 1.0
  port: 502                  # xArm control port; 30001-30003 report streams are never probed
hardware_monitor:            # phase-09a (§13.3 `hardware_monitor.arms`): READ-ONLY SDK client
  enabled: true              #   per hardware arm, session-less; paused (boxes released) while
  poll_hz: 10.0              #   a hardware session runs; joints/pose/codes at poll_hz, rail +
  stale_s: 0.5               #   gripper registers at ~2 Hz; sample older than stale_s -> stale
  reconnect_s: 2.0           #   first retry delay after a failure (doubles, capped at 10 s)
twin_overlay:                # phase-09a (§13.4 `<camera_id>_align` streams)
  enabled: true
  fps: 12.0
  alpha: 0.5                 # robot tint opacity
  tint_rgb: [255, 235, 140]  # pale yellow, shaded by the twin's own luminance
  edge_rgb: [255, 220, 60]   # 1 px robot outline
  env_outline: true          # table / obstacle edges as thin lines (alignment cue)
  env_rgb: [90, 200, 250]
  stale_tint_rgb: [170, 170, 170]   # monitor stale / error -> grey twin
  joint1_offset_rad: 0.0     # diagnostic knob only; the identity convention is verified
  rail_flip: false           # DEPRECATED alias of hardware_session.rail_flip (phase-09c; either
                             #   key set -> both true, one convention for overlay + gate + sweep)
  rail_fallback_m: {grip: 0.65, view: 0.0}  # rail position the twin assumes while the
                                            #   track is not homed (its register is meaningless);
                                            #   also the home_rail sweep's / frozen arm's assumption
  stream_suffix: _align      # grip_wrist_align / view_wrist_align (reservation rules §13.4)
hardware_session:            # phase-09c/09d (§5 hardware BRINGUP, §13.1 home_rail)
                             #   (phase-09d removed default_arms: a session always includes
                             #   every configured arm; an old key in a YAML is ignored)
  armed: false               # ARMING SWITCH (2026-09-05): real drivers connect / rails home only
                             #   when true; repo default false -> tests, dev instances and a
                             #   forgotten render refuse hardware sessions + home_rail with 409
                             #   "hardware not armed" (the lab render sets true, HARDWARE_ARMED;
                             #   so does the dev render via scripts/dev/local.env, §14.1). WHY:
                             #   on 2026-09-05 a runtime test that bypassed the fake seam built a
                             #   real HardwareWorkcell and started a RailHomingJob against the
                             #   real Manipulation Arm box — no motion, but the arm was enabled
                             #   and then braked again by the teardown (§16 has the guard)
  default_speed_scale: 1.0   # Hardware-tab default (D2; segments 10 / 50 / 100 %). 1.0 since the
                             #   evening of 2026-09-08 (operator decision after a day of live
                             #   sessions; 0.5 was the 2026-09-07 call, 0.1 the first-run default
                             #   with 10 / 30 / 100 %); the UI's DEFAULT_SPEED_SCALE mirrors it
  plan_gate_hold_s: 3.0      # gate-held abort (2026-09-08 evening, §10.5): a running plan the
                             #   gate holds this long with no waypoint progress is cancelled by
                             #   the loop with the blocking pair in the reason ("held by the
                             #   safety gate: <a> / <b> at <mm> mm"); arms hold; 0 = first held
                             #   tick; honoured on sim loops too (a sim gate = safety_debug)
  rail_flip: false           # q_sim = 0.65 - q_track for the overlay AND the gate / sweep twins;
                             #   verify with the *_align overlay right after the first home_rail
  home_rail_inflation_m: 0.025  # D4: blind-sweep margin (the guardrail's debug inflation);
                             #   also the margin of the 09d pre-positioning plan + path check
  home_rail_step_m: 0.005    # D4: 5 mm -> 131 checks over the 0.65 m travel
  bringup_timeout_s: 60.0    # HardwareWorkcell.bring_up budget inside POST /api/session
                             #   and inside the rail-homing job's connect
egl_device_id: 0
logging:                     # 2026-09-07 ("Logging" below)
  level: INFO                # DEBUG | INFO | WARNING | ERROR, both handlers
  dir: ${APOLLO_HOME}/var/logs   # rotating file next to the rest of the machine state; null = stderr only
  file: runtime.log
  max_bytes: 20971520        # 20 MB x
  backup_count: 10           #   10 kept
  access_log: false          # uvicorn per-request lines (25 Hz UI polls) off by default
```

**Logging (2026-09-07).** Until then the process had one `basicConfig` to
stderr, no level knob and no file: the dev launcher appended stderr to an
unrotated `var/logs/runtime.log` (40 MB after two days, a quarter of it the
access log of three UI poll endpoints, 42 INFO application records in total),
so the first live teleop defects could not be read off a log (that 40 MB file
is larger than `max_bytes`, so the `RotatingFileHandler` rolls it to
`runtime.log.1` on its first write — renamed, not lost). Now
`__main__.configure_file_logging(cfg.logging)` adds a
`RotatingFileHandler` at `logging.dir/logging.file` after the config loads and
keeps the stderr handler (journald on the ops path; the dev launcher's
`var/logs/runtime.stderr.log`, which is also the ONLY place libsurvive's and
MuJoCo's C-side prints land — they never pass through Python logging).
uvicorn runs with `log_config=None` so its lines propagate to the same
handlers; `access_log` follows the config. The control loop writes:

- one INFO **health line** per `control.health_log_every_s` —
  `loop: 100 ticks/1.0s (100 Hz, tick p50 0.9 ms p99 2.1 ms, +0 overruns)
  active=grip src=teleop held=['KeyC'] tracker=tracking pose_age=4ms
  ctl_age=0.3s engaged=grip leash_slips=+3 (+0.041 m total) gate=ok
  ik_slips=+0 ik_diverged=+0 cmd-meas={grip:0.0031 view:0.0000}
  servo={grip: 1200 ticks, 0 late, 0 faults, p99 10.4 ms; …}` — the pose age
  and the controller (button) age are printed separately because the two paths
  die independently (2026-09-06: poses at 135 Hz, no button event for minutes);
  `leash_slips` is the hand travel discarded this window (§6); `cmd-meas` is
  `max|q_cmd − q_meas|` per arm; `servo=` is `XArmDriver.tick_stats()` (duck
  typed; absent for sim);
- INFO/WARNING **edge lines**: `clutch ENGAGED/released (arm, source)`,
  `controller stream STALE/fresh again`, `ws input watchdog LATCHED/cleared`
  (gate block/clear edges were already the supervisor's `collision event`
  lines), plus DEBUG per-event IK divergence / residual-freeze lines.

`ControlLoop.ik_slips` / `.ik_diverged` and `TrackerTeleop.slip_count` /
`.slip_pos_total_m` are the cumulative counters behind the deltas.
`grep 'loop:' var/logs/runtime.log` is the first thing to read after a bad
session; `var/logs/runtime.stderr.log` the second (libsurvive / MuJoCo).

The `dora:` block (`RuntimeConfig.dora`: `enabled: false` in the repo config,
`bind_host`, `machine_id`, `machines`, ports, `auth`, `publish`, `policy.spec_stale_s`
3 s, `log`, `var_dir`) is specified in 14-dora §12 and summarised in §17; the lab
render turns it on (`DORA_BIND_HOST`, `DORA_MACHINES`). `datasets` /
`online_dagger` above: `render-lab-config.sh` rewrites `datasets_root` but does
not template the namespace roots (open item, 15-online-dagger §12.3 item 4).

### 14.1 Self-contained paths (`${APOLLO_HOME}`)

Every filesystem path the runtime reads or writes resolves *inside the
workspace*, so `git clone --recurse-submodules <ws>` runs with no `~/apollo`
(or any machine-specific) dependency and the repo can be deployed to another
user unchanged. The tracked configs anchor data at `${APOLLO_HOME}/var/...`;
`config.py` resolves each path field (`profiles_dir`, `datasets_root`,
`checkpoints_root`, `calibration_dir`, `ui_dist`, `tracker.libsurvive_config_path`)
by expanding `${APOLLO_HOME}` and any other `$VARS`, then `~`, then anchoring a
still-relative result at the workspace root. Absolute paths and `~` still work
verbatim, so the FHS ops render may pin `/var/lib/apollo-mavis-v2/...`.

`${APOLLO_HOME}` is the workspace root: `$APOLLO_HOME` when the launcher /
systemd unit exports it, otherwise inferred from the config file's own location
(the nearest ancestor holding the side-by-side sub-repos) and, failing that,
from the installed package's location. `load_runtime_config` also seeds
`$APOLLO_HOME` from the config file so child processes (dagger trainer,
libsurvive) inherit the same anchor. libsurvive is started with
`--configfile ${...}/var/libsurvive/config.json` at teleop (the calibration
wizard strips `--configfile` and points at its own temp copy), so the lighthouse
calibration lives in the workspace too.

Developer instance: `scripts/dev/mavis-dev.sh` derives the workspace root from
its own location, exports `APOLLO_HOME`, and runs the runtime + a Vite dev server
with logs/pidfiles under `<ws>/var`. `mavis-dev.sh render` builds the gitignored
`<ws>/var/mavis_v2_local.yaml` from the tracked `configs/mavis_v2.yaml` plus the
machine knobs in the gitignored `scripts/dev/local.env` (via
`scripts/deploy/render-lab-config.sh KEEP_REPO_PATHS=1`, which keeps the
workspace-relative paths). Machine-specific and safety-sensitive values (tracker
yaw, libsurvive backend, `hardware_session.armed`) live ONLY in `local.env` + the
rendered local config, both gitignored — the tracked config stays `armed:false`
with the `fake` tracker. The ops path is unchanged (systemd units + FHS layout).

User-facing arm names (2026-09-04): arm id `grip` is the **Manipulation Arm**
(xArm Gripper G2 + wrist camera, control box 192.168.1.201) and arm id `view`
is the **Perception Arm** (wrist RealSense D435 + RØDE NT-USB Mini, control box
192.168.2.219); the ids stay as they are in every config, spec and telemetry
field. The Manipulation Arm is the initial `active_arm` of every session,
hardware and sim, whatever its position in `SessionSpec.arms`
(`control.loop.default_active_arm`: `grip` when present, else the first arm),
and `GET /api/workcell` lists it first in `arms` for both kinds.

`microphone.*` and `hardware_probe.*` are owned by `Runtime` for the process
lifetime (phase-11): `MicrophoneReader` (`devices/microphone.py`) is started in
`Runtime.__init__` when `enabled` and `backend != none`, publishes one
`MicFrame` per telemetry tick into `bus.microphone` and is stopped in
`Runtime.stop()`; `HardwareProbe` (`devices/hardware_probe.py`) exists when a
`hardware` workcell is configured, is paused while a hardware session runs and
is stopped in `Runtime.stop()`. Capture goes through PulseAudio only: the
daemon owns the card, a direct `hw:CARD=Mini` open fails with EBUSY and stalls
every other Pulse client. The `[audio]` extra (`sounddevice>=0.5`, apt
`libportaudio2`) is optional — without it `auto` falls back to `parec`
(`pulseaudio-utils`) and, with neither, reports `status: no_backend` instead of
failing. Unplugging is detected by a 1 Hz Pulse source re-listing (Pulse
migrates streams to the fallback source rather than erroring); open/read
failures re-open with 0.5 → 5 s backoff. Placeholder arm IPs / camera paths
only make the probe report `unreachable` and the previews `live: false`.

`hardware_monitor.*` and `twin_overlay.*` are owned by `Runtime` for the process
lifetime (phase-09a): `HardwareStateMonitor` (`devices/hardware_monitor.py`) is
constructed in `Runtime.__init__` (inert — `enabled: false`, every arm `off`
with a `detail` — without a `hardware` workcell, with `enabled: false`, or when
`apollo_mavis_v2_hardware` is not importable) and `TwinOverlayRenderer`
(`streams/twin_overlay.py`) when a hardware workcell exists (inert without a
wrist camera matching an arm, without `digital_twin_scene`, or without the
`[sim]` extra). `Runtime.start()` starts them monitor → overlay AFTER
`manager.start_previews()` (the overlay composites onto the hardware camera
previews); `Runtime.stop()` stops overlay → monitor before everything else.
`Runtime(cfg, monitor_factory=…)` is the test seam that replaces the hardware
package's `ArmStateMonitor`. `CameraConfig.intrinsics` on the hardware wrist
cameras are the D435i **colour** intrinsics (the depth stream is not used);
without them the overlay renders with fovy 43.2° and logs a warning. Both lab
tracks are unhomed at power-on, so `rail_fallback_m` (grip 0.65 = the operator's
right end, view 0.0 = the left end, matching the `mavis_v2` keyframe) is what
the twin shows until the operator homes them (`home_rail`, §13.1);
`joint1_offset_rad` / `hardware_session.rail_flip` exist only to diagnose a
convention mismatch on the live cell and stay at their identity defaults.
`hardware_session.*` (phase-09c) holds the Hardware-tab defaults, the shared
rail convention and the `home_rail` sweep margins (§5, §13.1); `Runtime` builds
one `RailSweepChecker` from it and hands it to the `HardwareStateMonitor`.

**Controller-side backstops per arm (phase-09b; core §7, 02-hardware §6).**
`workcells.hardware.arms[*].tcp_load_kg` / `tcp_load_cog_mm` /
`collision_sensitivity` (0..5, default 3) / `reduced_tcp_boundary_mm`
(optional `[x_max, x_min, y_max, y_min, z_max, z_min]`, None = Reduced mode
off) / `expected_sn` (None: both lab boxes read the model code `XS1305`) are
the ONLY source of the values written to a control box: the hardware driver
applies them at every connect (`backstops.apply_backstops`, order tcp_load →
gravity → sensitivity → self-collision + tool model → optional reduced
boundary → rebound off) and the session-less `apply_backstops` maintenance op
(§13.1) writes the very same values through the same `ArmConfig →
XArmDriverConfig` mapping (`apollo_mavis_v2_hardware.workcell._driver_cfg`,
resolved lazily by `devices/hardware_monitor.py`; the `driver_cfg_factory`
seam replaces it in tests). They are volatile on the controller (a reboot
drops them; the boxes were found at 0 kg / sensitivity 3 and 1 on
2026-09-04), never `save_conf()`ed; the monitor reads them back
(`backstops_match`, §13.3). **One operator override exists (2026-09-11):** the
`set_collision_sensitivity` maintenance op (§13.1) writes a level 1..3 on top
of the config — from the Hardware-tab arm card (monitor path) or the Cockpit
(session path) — and the runtime remembers it PER ARM
(`HardwareStateMonitor.requested_sensitivity`) so `backstops_match` and the
telemetry rows report the level the operator asked for; it is volatile and
never written to the config: the next driver connect's `apply_backstops`
(and the session-less `apply_backstops` op) puts the config value back and
forgets the override, and the UI always shows the controller's read-back.
Lowering the Manipulation Arm to 2 (then 1) for the fridge door is the
operator's call, made per session. A YAML value out of range fails
`load_runtime_config` with the core `ConfigError` (`/workcells/hardware/arms/<i>/collision_sensitivity`).
`configs/mavis_v2.yaml` carries the PROVISIONAL lab payloads above with
'estimate accepted by the user 2026-09-05 (not weighed)' comments; `tests/test_configs.py` pins them.

`tracker.*` is owned by `Runtime` for the process lifetime (`TrackerReader`
thread + live `TrackerSettings`); the `tracker_settings` action mutates
yaw/scale/rotation and the live filter fields at runtime and telemetry echoes
them (13-tracker §4). `ControllerMapConfig` rejects an input bound to more
than one action and the held-only `trigger_click` on `arm_next` / `arm_prev`
(the discrete actions accept `trackpad_*`, `menu_click`, `grip_click` or
`none`). Since phase-10 (2026-09-03) `tracker.yaw_deg` is only the **boot
default**: `Runtime.__init__` overrides it from
`<calibration_dir>/tracker_calibration.json` when that file has `yaw_valid:
true` and a non-null `yaw_deg`; the yaw wizard's `apply` writes the file and a
base-station `install` clears `yaw_valid`. `tracker.libsurvive_args` are the
*normal* arguments the reader returns to after every calibration (§6 "Tracker
calibration modes"); `tracker.libsurvive_config_path` and
`tracker.calibration.*` are read by `TrackerCalibration` only.

Version pins carried by the workspace (overview §9): MuJoCo 3.12.0,
mink 1.3.0, lerobot ≥0.6 pinned, xArm-Python-SDK 1.18.5.

## 15. Error handling & recovery matrix

Status (phase-09b, 2026-09-04): the first two rows and the Studio-conflict
row are **implemented and fake-tested** (`tests/test_fault_recovery_loop.py`,
`tests/test_maintenance_api.py` over `tests/fakes.EventFakeWorkcell`); the
hardware session itself landed with phase-09c (§5; `tests/test_hardware_session.py`,
fakes first; the first live run was 2026-09-05 — 02-hardware §16). Mechanism: every tick the
loop calls `workcell.drain_events()` (core `WorkcellInterface`, default `[]`;
`HardwareWorkcell` returns every driver's events in `t_mono` order) and
dispatches BY CLASS NAME (`control.loop.FAULT_EVENT_NAMES`; the runtime never
imports the optional hardware package's event types — the fakes mirror them
field-for-field and a test pins the names against the hardware package).

| Failure | Detection | Response |
|---|---|---|
| xArm controller error (C22 self-collision, C24 speed, C31 collision, C35 boundary…) | driver `FaultEvent` via `workcell.drain_events()` (the driver's 5 Hz monitor / servo return code 1 funnel into it; `ArmState.error_code` ≠ 0 holds the arm meanwhile) | THAT arm → FAULT: `ArmSender.pause()` (drains its slot, dispatches nothing), the loop holds it (`arm_stopped`) and publishes no target for it, drops its plan / jog / teleop seed, releases the clutch anchors if it was the clutched arm; `session.state = fault`, `arms[*].fault_detail` = the SDK `x_code` title (+ the driver's latch reason); **other arms keep running**. Recovery is the driver's (auto within its 3/30 s budget for RECOVERABLE codes, else the operator's `recover` click, §13.1): `clean_error → clean_warn → motion_enable(True) → set_mode(1) → set_state(0)` → `ReseedEvent` + `RecoveredEvent` → the loop **re-seeds** from `get_state()` (`_last_cmd`, IK warm state, gate `_last_safe`, watchdog AWAIT_EMPTY), resumes the sender and holds the arm in RECOVERING until the first tick whose inputs hold nothing live (clutch released / keys up or watchdog-latched) → RUNNING; a latch `FaultEvent` (`motion_enable failed (release the physical e-stop?)`, budget exhausted, `re-latched <ms> ms after recovery with the arm holding still: the collision load is still on the arm - back it off or let go of the object, then Recover` — the same code re-fired within 1.5 s of an auto-recovery with no new target, 02-hardware §3.5, 2026-09-09 — …) keeps FAULT until the next click |
| Command return 9 / −2 (state not ready) | per-command code → driver `FaultEvent(source="servo")` | same recovery path (controller silently drops to mode 0 on error) |
| Operator "Clear errors & resume" (Cockpit) / "Clear errors" (Hardware tab) | `POST /api/hardware/arms/{arm_id}/maintenance` | session: `request_recovery` on the driver's monitor thread, result awaited ≤ 10 s via `recovery_result()`; no session: `clean_error` + `clean_warn` on the read-only monitor's poll thread, never `motion_enable` (§13.1). Neither moves the arm |
| Operator lowers / restores the collision sensitivity (Cockpit sensitivity control in a hardware session, Hardware-tab arm card without one; 2026-09-11 — the fridge door's seal force reads as C31 at sensitivity 3) | `POST /api/hardware/arms/{arm_id}/maintenance {op: set_collision_sensitivity, collision_sensitivity: 1..3}` | session: `request_set_collision_sensitivity` on the driver's monitor thread, result awaited ≤ 10 s via `setting_result()` (ok on code 0 or a 1 / 2 / 9 status echo, the note in `warnings`); no session: the read-only monitor's poll thread writes once and judges by the rich-frame read-back (§13.1). Neither moves the arm; the driver's phase / budget / streamer are untouched. The level is remembered per arm (telemetry `arms[*].collision_sensitivity`, the monitor row while paused, `backstops_match`) until the next driver connect re-applies the config value; 422 outside 1..3, 409 while a rail homing runs |
| Linear track not homed at power-on (`on_zero == 0`: carriage position unknown, the twin cannot gate) | monitor sample `rail_present and not (rail_homed and rail_enabled)`; the driver's `connect()` raises `RailNotHomedError` (never homes) | `POST /api/session kind=hardware` → 409 `"… rail not homed - home it from the Hardware tab (Home rail) …"` for any arm; the operator runs `home_rail` (§13.1) — the ONE motion-class maintenance op: dry-run sweep verdict (+ `pre_position` plan, phase-09d) in the HomeRailSheet → confirm → posture sweep-clear: `set_linear_track_back_origin` on the monitor's thread (≤ 45 s, `maintenance_busy`, session POST 409 meanwhile); posture blocked but plannable: the `RailHomingJob` (202) connects that arm alone, drives the planned rail-position-agnostic path to the keyframe / home posture at 10 % under the gate, homes, verifies, hands the arm back braked in that posture and resumes the monitor (§5; progress on `hardware_monitor.arms[].maintenance`, result at `GET …/maintenance/last`) → the card reads `rail 0.000 m` → check the `*_align` overlay (`hardware_session.rail_flip` if mirrored) → the session may start. The track keeps its homed flag across sessions (D6: `disconnect()` never disables it) |
| Rail-homing job fails half-way (arm moved since the sweep, a session slipped in first, a driver fault during the pre-positioning motion, the executor times out / the posture is not reached, `home_rail()` not ok, register verification fails) | `RailHomingJob` phase handlers (`JobFailed`) | phase `failed` on telemetry with the reason (`"rail homing job failed during positioning: …"`, incl. the gate verdict and the commanded posture on a timeout), the rig torn down (`stop_rig`: loop → drivers, D6 hand-back, the arm holds where it stopped), the monitor resumed, the final `ArmMaintenanceResult` (`ok: false`, `status: done`, same `job_id`) at `GET …/maintenance/last`; nothing half-connected, the carriage never commanded by the job (`RailHoldArm`) |
| Hardware bring-up fails half-way (monitor thread stuck in the SDK, a driver's `BringupError`, dof mismatch, stale first report) | `_bringup_hardware` (§5) | `_abort_hardware_bringup`: loop stopped, `workcell.stop()` (drivers hand back stopped + braked), adopted previews back to preview fps, overlay provider dropped, monitor resumed; 409 with the arm's user-facing name + stage + the driver's message; nothing half-connected |
| UFACTORY Studio "Live control" grabs mode/state (no error code) | driver `StudioConflictWarning` (it pauses, re-enters mode 1 once, re-seeds; a second grab within 5 s latches) | telemetry warning: `arms[*].fault_detail = "warning: close UFACTORY Studio live control"` for 5 s, nothing stopped; the eventual latch arrives as a `FaultEvent` (row 1) |
| Rail comm loss (controller error 111) | error code | rail target frozen; arm control continues; telemetry flags rail fault |
| Control WS silent > 0.2 s | InputWatchdog | ramp twist → 0 over 0.1 s; resume needs empty held set (§8) |
| Controller WS disconnect | `WebSocketDisconnect` | immediate zero-twist + drop held state; session stays RUNNING; next connection becomes controller and re-syncs via `GET /api/session` + hello epoch |
| Twin gate HOLD persists > 2 s | supervisor counter | telemetry severity stays `blocked`; no auto-motion — operator steers away or ends session |
| Policy output stale / NaN | PolicyRunner check | hold arms; telemetry `dagger.policy_stale`; NaN → auto-takeover suggestion, gate unchanged |
| Trainer process dead | `proc.poll() != None` or 3 missed status replies | DAgger continues with frozen policy; `TrainerStatus.state="dead"` + UI banner; **auto-restart once with `--resume`** (trainer reloads `trainer_state.pt` of the newest version); dies again ⇒ stay degraded, never a third silent restart (12-dagger §12) |
| Online DAgger trainer stale (phase-14, 2026-09-08 evening; §10.7; the morning's "PRO-DAgger" rows superseded) | no `policy_trainer_status` echoing this session within `dora.policy.spec_stale_s` (3 s): `dagger.online_dagger.trainer_alive: false`, `trainer_age_s` growing, `session.trainer_alive: false` | phase keeps its value; `episode_new` / `train_now` nacked `"no Online DAgger trainer attached"` (aliveness is checked before the phase); Cockpit red banner (`OnlineDaggerBanner`: TRAINER LOST); no motion — an open rollout continues under the gate, the external policy's own `policy_stale` hold is independent (12-dagger §12) |
| Online DAgger trainer `state: "error"` | `trainer_status.state == "error"` for this session | coordinator phase `error` (no event — the shell publishes no phase event; telemetry carries it); rollouts refused `"trainer error: <detail>"`; a rollout already open finishes and its save is a kept rollout (`events.episode_saved` fires; the trainer decides); the trainer recovering moves the phase per the pure phase rule; End session clears it; no rollback exists for an external policy (14-dora §11.3) |
| Online DAgger bring-up fails after the session directory was created | any exception in `_bringup_sim` after `_build_online_dagger` (recorder 409, executor ctor, a `start()`) | rollback in reverse order, `_OnlineDagger.abandon()` removes a FRESH directory (a resumed one is kept and its `session.json` stays byte-identical — it is not rewritten before RUNNING), 409 with the cause; the name stays usable |
| Online DAgger `session.json` unreadable on resume | `_check_online_dagger` pre-bring-up read (non-dict / invalid JSON) | 409 `"Online DAgger session '<s>': session.json is unreadable - fix or remove it"`; the file is never overwritten (the rollouts rows and the counters a resume continues live only there) |
| Online DAgger trainer spool write fails at save (pyarrow / disk) | `DaggerRecorderThread._write_spool` raises | logged; `on_episode_saved(index, summary, "")` still fires → `events.episode_saved` with `spool_path: null`, the rollout counts, the boundary spells `episode_boundary` (never a silent discard) — review fix 2026-09-08 |
| Camera hung | `read_latest` max-age miss | recorder drops frame + counts; video tile goes stale client-side; capture-thread reconnect (RealSense `hardware_reset` retry) |
| Recorder exception in `save()` | RecorderThread try/except | **KEEP the episode buffer and the temp directory** (do NOT discard); retry once; on second failure mark the session degraded (recording off, telemetry + toastable detail), keep teleop/safety alive (12-dagger §12); control unaffected. `add_frame` exception: drop that frame + count; repeated failures degrade likewise |
| Tick overrun (> 10 ms) | pacing check | log + skip catch-up; ≥ 10 consecutive → telemetry warning `control_degraded` |
| Unclean prior shutdown | an `episodes/.tmp-*` directory without `episode.json` | `sweep_incomplete_episodes(datasets_root)` at `Runtime.start()` / session start / `DatasetStore` scan removes it and logs (§10.4); published episodes are untouched |
| SIGINT/SIGTERM | signal handlers | full TEARDOWN (§5.4): ramp, finalize, stop trainer, disconnect arms, `renderer.close()` (avoids EGL teardown noise) |

## 16. Test strategy

**Guard (2026-09-05).** `tests/conftest.py` carries an autouse fixture
`_never_touch_real_hardware` that makes `SessionManager._default_workcell_factory`
raise unless `driver_api_factory` is a fake, and the fixture config sets
`hardware_session.armed: true` so the fake paths run at all. The lab machine
can reach both control boxes — **never run the runtime suite there without
this guard in place** (before it existed, a test without the fake seam
started a rail-homing job against the real Manipulation Arm box; §14
`armed`).

Hardware-free by default; pytest. Three tiers:

1. **Unit (no extras)** — core `testing.FakeWorkcell` (in-memory
   Arm/Camera/Workcell interface impls, synthetic frames, scriptable error
   codes) extended by `tests/fakes.py` `EventFakeWorkcell` (phase-09b:
   scriptable driver events `FaultEvent` / `ReseedEvent` / `RecoveredEvent` /
   `StudioConflictWarning` mirroring the hardware package by name and field,
   `fault(arm, code)`, `request_recovery` / `recovery_result` with a latency
   and a scriptable latch) + `FakeTwin` (scriptable `check`/`plan`);
   deterministic time via an injected `Clock` (control loop, watchdog,
   recorder pacing all take it).
   Cases: watchdog (stale 0.21 s ⇒ ramp; resume blocked until empty held set;
   recovery ⇒ AWAIT_EMPTY + re-seed); driver faults
   (`test_fault_recovery_loop.py`: a FaultEvent stops only that arm — sender
   paused, no publish, plan/jog dropped — sibling keeps moving; re-seed from
   MEASURED; RECOVERING held while the device clutch stays down, released →
   RUNNING, re-grip = zero-delta engage; WS keys stay behind the watchdog
   latch; Studio warning lingers 5 s without stopping; event names pinned
   against `apollo_mavis_v2_hardware.events`); teleop math (held→twist per keymap,
   leash + dq clamps, rail [0, 0.65], rail keys ignored for rail-less active
   arm, Tab cycling server-side); jog/goto (slew limit; ANY jog delta accepted
   since 2026-09-07 — the 0.15 rad `goto_threshold_rad` nack is gone; goto
   routes via `FakeTwin.plan`; held key cancels a plan; a watchdog latch
   clears pending jog targets); gate
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
   matrix; served keymap == core keymap; arm maintenance
   (`test_maintenance_api.py`, fake read-only monitor + a hand-installed
   hardware session over `EventFakeWorkcell`): monitor path (`clear_errors`
   writes exactly `clean_error` + `clean_warn`, `apply_backstops` the
   `backstops.py` order with the `ArmConfig → XArmDriverConfig` values,
   `before`/`after` rows + `backstops_match`, telemetry read-backs flip),
   session path (`recover` / `clear_errors` = driver recovery, FAULT →
   RECOVERING → RUNNING on telemetry, latch stays FAULT, 10 s timeout),
   409 matrix (recover without session, apply_backstops in session, arm
   outside the session, monitor off/paused/error, busy, no recovery channel),
   404 unknown arm, 422 unknown op. `set_collision_sensitivity` (2026-09-11):
   monitor path (one write reaches the fake arm monitor with `level=`, the
   read-back rules — a 1 / 2 / 9 echo is ok, a box that keeps the old value is
   `ok: false` with the read-back in `collision_sensitivity`; `before` /
   `after.backstops_match` judged against the level in force / written; the
   telemetry row and `requested_sensitivity` follow; `pause()` forgets it,
   `resume()` alone does not restore it, `apply_backstops` forgets it), session
   path (the fake workcell's `request_set_collision_sensitivity` /
   `setting_result` channel, the recovery channel untouched; `warnings` carries
   the echo note; the in-session `arms[*].collision_sensitivity` AND the paused
   monitor row publish the level; a refused code records nothing; 0.2 s timeout
   `"no result from the session driver within …"`; 409 without the channel /
   on the driver's `CommandError`), 422 for a missing / 0 / 4 / 5 / fractional
   level on the wire and `ValueError` in-process, 409 `"… refused: rail homing
   in progress …"`, the other ops ignore the field (`test_maintenance_api.py`);
   `backstops_match(expected_sensitivity)` + `MAINTENANCE_OPS` + the requested
   map on the runtime monitor (`test_hardware_monitor.py`).
3. **Sim-backed e2e** (`[sim]` extra, CI with EGL): (a) sim session, stream
   `KeysMsg` W for 1 s ⇒ EE moved +x, telemetry ≥ 20 Hz; (b) collect: record
   2 episodes (one saved, one discarded) into a tmp `datasets_root` ⇒
   exactly one `episodes/<id>/` directory (`frames.parquet`, one mp4 per
   camera with `frames == rows`, `episode.json`), no `.tmp-*` left, manifest
   counters match; run the LeRobot v3 export and re-open it with
   `LeRobotDataset`, assert schema §10.2 (intervention / action_source /
   wallclock_ns), fps=25, episode count 1, `codebase_version v3.0`
   (10-frames §11.8); delete the episode over REST ⇒ directory gone, export
   marked stale, nothing re-encoded; (c) `safety_debug` guardrail: the
   `apollo-mavis-v2-sim` collision-course script through the runtime must be
   blocked *before* contact with `CollisionEvent`s (CI regression, overview
   §6); (d) DAgger smoke with scripted `Policy` + stub trainer: Space cycles
   policy→transition→human and back, hot-swap only at episode boundary;
   inference smoke: takeover works, recorder never instantiated.

Recorder crash-safety: raise inside `save()` ⇒ buffer + temp directory kept,
one retry succeeds (fault injected once), second consecutive failure degrades
recording while every published episode stays readable; kill mid-save
(simulated death) ⇒ one `.tmp-*` directory left, swept at the next open,
published episodes untouched (10-frames §11.6).

**Phase-12 merge + phase-14 Online DAgger (2026-09-08; the morning's PRO-DAgger test
names — `test_pro_dagger_coordinator.py` (30), `test_pro_dagger_package.py`,
`test_pro_dagger_session.py`, `test_e2e_pro_dagger.py` — are superseded: deleted, not
renamed).** The dora tests live in `tests/dora_bridge/` (a package — a top-level
`tests/dora` would shadow the PyPI module; markers `dora` / `egl` / `perf`, a private
control plane per module, 14-dora §10 / §16.4 for the two adapted tests and the known
flakes: the 1.0 s `RUNNING` budget with ~150 ms headroom, the machine-wide `pgrep -x
dora` leak check). Online DAgger (15-online-dagger §11 / §12): unit
`tests/dagger/test_online_dagger_coordinator.py` (23: phases as a pure function,
refusals verbatim, discard = event only + no files, `train_now`, gate events, resume,
`spool_path: null`, the session-id pin, the 200-row `trainer_log` cap),
`tests/dagger/test_executor.py` (+ `takeover` / `handback` / `train_now` ops and their
acks, gate payloads incl. the CLOSED episode's id, `episode_boundary` vs `handback`, the
discard boundary under return-to-start AND from `_op_episode_new`, the POLICY-driving nack
for `R` / `goto_profile`), `tests/dagger/test_recorder_schema.py` (`actor`, teardown
discard, the spool-failure path), `tests/test_return_manager_units.py` (D6 through the
real loop); contract `tests/test_server_contract.py` (skill / sessions routes, the 409
matrix incl. the capability via a fake hub, the `train_now` nack, `SessionInfo.
online_dagger`, `/api/pro_dagger/*` → 404), `tests/test_configs.py`,
`tests/test_dataset_layout.py` (mapped roots, `GET /api/datasets/layout`, a real collect
session into `bc_demo/<name>`, delete / sweep rules), `tests/test_dataset_store.py` (the
in-use delete guard), `tests/test_online_dagger_package.py` (4: package data, tarball,
mirror identity — skipped without the policy-node checkout —, config block),
`tests/dora_bridge/test_external_status.py` / `test_policy_source.py` (`capabilities`,
`trainer_status` cache + replay), `tests/dora_bridge/test_fake_trainer_role.py` (3, no
dora: every status the fake emits validates as the 10-key `TrainerStatusAnnounce`);
integration `tests/test_online_dagger_session.py` (4: a real sim server + fake dora
wiring + real `ExternalPolicyHub` — lifecycle incl. the 409 on deleting a saved rollout
mid-session and the export 409 on resume, fresh-directory rollback, unreadable
`session.json`, a `start()` failure); sim e2e `tests/dora_bridge/test_e2e_online_dagger.py`
(3, `dora` + `egl`: the fake node in trainer mode over the real private control plane +
an `observer` node — `test_409_matrix_before_any_trainer`, `test_online_dagger_rollouts_
over_the_bus` (waiting → ready → two kept rollouts with take-over via the actions and via
Space → the fake trains → `"training in progress"` refusal → ready with policy v2 → a
discard while the expert holds the arm leaves NO directory and publishes the event →
Train now → v3; 9 gate events, `session.json`, `actor` in `frames.parquet` and the spool,
return-to-start walked `returning`), `test_skill_endpoints_are_session_less`; 30.9–32.3 s
wall for the file, the big test 23.9–24.2 s alone). Full suite after the review fixes:
713 passed / 1 failed (the pre-existing `test_return_to_start.py` WS-deadman flake, green
on re-run) / 2 hardware-probe skips in 688.79 s with the dora + egl + perf tiers; the
non-dora tier after the same-evening `goto_profile` work 715 passed / 2 skipped / 20
deselected. `tests/dagger/test_e2e_dagger.py` and `tests/dora_bridge/
test_e2e_external_policy.py` pin `return_to_start: False` (D6). Config pins in
`make_runtime_config` / `harness.dora_runtime_config` / `test_perf.py` /
`test_e2e_safety_debug.py`: `datasets=DatasetsConfig(default_namespace="apollo",
namespaces={})` so no test lists or sweeps the operator's `~/data`. New this pass,
unrelated to Online DAgger: `tests/test_video_hub_pacing.py` (the phase-locked
`EncoderWorker` poll; two `perf`-marked).

**Action spaces + playback (2026-09-11).** `tests/test_backfill_abs_ee.py` (9: the live
recorder's `action.abs_ee` reproduced bit-for-bit by the backfill, idempotence +
`--force`, manifest patched only after every episode succeeded, dry run writes nothing,
CLI + refusals, rotations integrate to the commanded orientation, mixed rail offsets, a
foreign layout refused, a real-twin round trip); `tests/dagger/test_executor.py` (+ the
lagging arm running ahead to the leash with the intent accumulating, leash defaults from
`control.leash` and the `dagger.anchor_leash` override, an `abs_ee` row reached at its
deadline with gripper + absolute rail, the `abs_ee` counterfactual as the per-frame delta
toward the waypoint, hold when stale / non-finite and never scaled by staleness, the
handback window capping the per-tick step); `tests/dora_bridge/test_policy_source.py`
(+ abs rows pass verbatim with the abs block width, `resolve_driven_arms` for an abs
spec); `tests/test_episode_playback.py` (48: + `sources` per episode, an episode without
the abs column offers `state` + `delta_ee` only, the action-source refusals, the
`delta_ee` / `abs_ee` replays in sim with the TCP verdict — `PLAYBACK_JOINT_TOL_RAD`
0.02 for the IK-driven replay against the state replay's 3 mrad); the recorder schema /
episode-dir / export / dataset-store / action-filter tests updated for the second column.
Run them through `.venv/bin/pytest`, never `uv run`, with the dev runtime stopped or from
a separate worktree (CLAUDE.md).

## 17. dora bridge (phase-12, 2026-09-08)

Contract and measurements: `14-dora-interface.md` (v1.0; §16 is the
implementation record). The bridge (`dora_bridge/`) owns one
`dora.Node("mavis_runtime")` on the `dora-bus` thread: depth-1 slots per topic
plus a FIFO for events / mic, `SnapshotPublisher` (`dora-publisher` thread) for
`arm_state` / `obs_state` / `telemetry` / `session`, `CameraTap` on
`EncoderWorker.taps` (re-tapped for every new worker), `MicTap`, `PoseStamper`
(one-pass FK, `park()` at teardown), `IdleArmReader` (sim / read-only monitor /
read-only driver) between sessions, and `ExternalPolicyHub` +
`ExternalPolicySource` (a `PolicySource`) for `policy_source: external`.
Control plane: `DoraControlPlane` spawns `dora coordinator --interface <ip>
--port …` + `dora daemon` (setsid, reaped on stop), renders the dataflow YAML
(`dataflow.py`), `dora validate --strict-types`, `dora start --detach`. dora
1.0.1 facts that shaped it (14-dora §16): the multi-machine start barrier makes
`Node()` block while holding the GIL until every remote placeholder has
attached → a join handshake (`POST /api/dora/machines/{id}/join`) plus a
subprocess `canary` node that proves the barrier is open; a dead remote daemon
makes the coordinator answer `429` to every CLI call for ~50 s → a lost machine
is marked `lost`, never restarted automatically; `Node()` monkey-patches
`logging.basicConfig` → restored after attach; the first `Array.to_numpy()`
costs ~190 ms → `codec.warm_up()` before "attached". Measured: bridge threads
≈ 7 % of one core at 4 rgb × 15 Hz + depth + mic + telemetry; the control-loop
median is unchanged, the tick p99 goes 3.0 → 5.4–7.9 ms with the bridge on
(open problem, 14-dora §16.2). Config `RuntimeConfig.dora` (`enabled: false`
in the repo; the lab render turns it on with `DORA_BIND_HOST=wlp38s0`,
`DORA_MACHINES`); `${var_dir}/node-stdout.log` holds dora's own diagnostics;
`GET /api/dora` publishes the connection facts (never the auth token). Since
2026-09-11 (14-dora v1.4) `ExternalPolicySource` accepts a node spec in `delta_ee` OR
`abs_ee` against the session's `delta_ee` announce: the per-arm block widths follow
the ANNOUNCED space (8 / 7 vs 11 / 10), `action_dim` must equal the length of the
node's own `action_names`, and abs rows pass through VERBATIM (the chunk rescale mask
is all zeros — an absolute value is never multiplied by a period or chunk factor).
