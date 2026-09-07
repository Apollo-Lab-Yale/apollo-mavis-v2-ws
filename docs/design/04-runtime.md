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
§15 job rows). Conforms to
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
inside `hardware`.

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
| `hw.<arm>.monitor-ro` ×N + `HardwareStateMonitor` supervisor (phase-09a/b) | 10 Hz (+ ~2 Hz registers) / 0.5 s | one READ-ONLY xArm SDK client per hardware arm (`apollo_mavis_v2_hardware.ArmStateMonitor`) | Session-less; zero writes unless an explicit maintenance request (`clear_errors` / `apply_backstops`, executed on this thread, REST only waits; §13.1); released (`paused`) while a hardware session owns the box (§13.3) |
| `RecorderThread` | 20–30 fps | the LeRobot dataset writer (single owner) | `add_frame`/`save_episode`; never touched from other threads |
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
   `docs/prompts/phase-09d-rail-homing-planning.md`; teleop only for now — other
   modes 409 `"hardware sessions support teleop only (phase-09c)"`).** Since
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
       worker from `ActiveSession.planned_start` without planning again). A
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
  discarded travel for the loop's health line (§14 "Logging").
- **Per-tick joint clamp**: `|q_i − q_last_i| ≤ dq_max` (0.04 rad/tick ≈
  4 rad/s) before the gate; cartesian step stays < 2.5 mm at default rates.
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
  `note_edges`). Default `controller_map`: `{clutch: trigger_click,
  gripper_open: trackpad_up, gripper_close: trackpad_down, rail_neg:
  trackpad_left, rail_pos: trackpad_right, arm_next: menu_click, arm_prev:
  none}` (the reference map the tests pin); **the lab config
  `configs/mavis_v2.yaml` departs from it since 2026-09-07** — `gripper_close:
  grip_click, gripper_open: menu_click, arm_next: trackpad_up, arm_prev:
  trackpad_down` — so the two actions that must never miss sit on plain
  buttons and the pad carries arm switching (also on the keyboard and in the
  UI); bindable inputs are `trigger_click`, `trackpad_left|right|up|down`,
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
`apollo_mavis_v2_core.dagger.interfaces`).

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
| `POST /api/session` | `SessionSpec{…, speed_scale}` → `SessionInfo{session_id, epoch, mode, arms, streams, state, kind, speed_scale}` | 409 if a session exists, a tracker calibration is in progress (`"tracker calibration in progress"`, phase-10), requested `kind` unavailable, scene/arm mismatch, dagger without a policy, or inference with no promoted deploy checkpoint (`policy=None` resolves to latest for dagger, promoted deploy for inference — 12-dagger §9). Returns after BRINGUP; START_FROM progress via telemetry. `streams` = camera ids + `"sim"` and/or `"twin"` (sim); `[]` for a hardware session (the preview cameras are ADOPTED, not re-added — §13.4). **Hardware refusal matrix (phase-09c/09d, `SessionManager._validate_hardware`, all before anything is touched; `detail` substrings):** `mode != teleop` → `"hardware sessions support teleop only (phase-09c)"`; empty arms → `"session needs at least one arm"`; an arm outside `workcells.hardware.arms` / outside the twin scene → `"arms [...] not in the hardware workcell"` / `"… not in scene"`; **not EVERY configured arm (phase-09d)** → `"hardware sessions include every configured arm (Manipulation Arm, Perception Arm) - missing ['view'] (phase-09d: both arms are always part of the session)"`; no / unknown `digital_twin_scene` (or the `[sim]` extra missing); no read-only monitor configured → `"no read-only hardware monitor - the digital twin cannot be posed for the gate"`; a rail homing in flight on ANY arm (`maintenance_busy`: the monitor op OR a phase-09d `RailHomingJob`) → `"rail homing in progress on the Perception Arm - wait for it to finish"`; per selected arm (user-facing name first): the read-only monitor not `running`/`stale` or without a sample → `"Manipulation Arm: no monitor sample (monitor error: …) - the read-only monitor must be connected before a hardware session (the digital twin cannot be posed)"`; probe `refused`/`unreachable` → `"…: control box 192.168.1.201 is unreachable - power it on / check the network first"`; `error_code != 0` → `"…: controller error 31 is latched - clear errors first"`; the twin expects a rail the monitor did not find → `"…: the digital twin 'mavis_v2' expects a linear track but the monitor found none"`; `rail_present and not (rail_homed and rail_enabled)` → **`"Manipulation Arm: rail not homed - home it from the Hardware tab (Home rail) before starting a session (carriage position unknown)"`**; `start_from` profile not covering the arms. Post-connect: a monitor poll thread still inside the SDK after 15 s, a per-arm bring-up error (`"hardware bring-up failed: Manipulation Arm: rail - [rail] …"`), a connected arm whose track is not `ready` (`"… rail - linear track error after connect (carriage position unknown …)"`), a dof mismatch with the twin, a stale first state, or — phase-09d — a `start_from` profile motion the gate twin cannot plan (`"profile motion not collision-free: goal_in_collision (grip_right_inner_knuckle / table) - the digital twin found no safe path from the measured posture to profile '…'"`) → teardown + 409. `hardware_session_active` (the monitor hand-over predicate) turns true only AFTER this matrix passed, right before `_bringup_hardware` pauses the monitor: a refused request never flips it (a supervisor round inside the validation window would otherwise disconnect the monitors and 409 with "monitor paused"). `speed_scale` outside (0, 1] is pydantic's 422. `GET /api/session` answers `state: bringup` while the hardware bring-up runs (D5) |
| `DELETE /api/session` | → 204 | TEARDOWN (idempotent) |
| `GET /api/episodes` | → `{repo_id, total_episodes, total_frames}` | current dataset counters (collect/dagger) |
| `GET /api/tracker/calibration` | → `TrackerCalibrationStatus` | phase-10 (13-tracker §3 item 8); idle snapshot (`kind: none, phase: idle` + persisted `yaw_valid` / dates) when nothing runs; the same object rides `telemetry.tracker.calibration` |
| `POST /api/tracker/calibration` | `TrackerCalibrationCommand{kind: base_station\|yaw, op: start\|capture\|validate\|install\|apply\|abort, point?}` → `TrackerCalibrationStatus` | 409 `{detail}` on an illegal transition (`CalibrationError`): `"stop the session first"`, `"backend is not libsurvive"`, too few scenes for `validate`, `install` without `validation.passed`, `apply` with non-empty `fit_checks`, `capture` after all seven points, a second `start` while one runs. Returns the post-command snapshot; progress via telemetry (§6 "Tracker calibration modes") |
| `POST /api/hardware/arms/{arm_id}/maintenance` | `ArmMaintenanceRequest{op: clear_errors\|apply_backstops\|recover\|home_rail, dry_run}` → `ArmMaintenanceResult{arm_id, op, path: monitor\|session, ok, detail, sdk_codes, warnings, before?, after?, rail_sweep?, status: done\|accepted\|refused, job_id?}` (200; **202** when `status == accepted`) | phase-09b (core §12 `protocol/maintenance.py`; `docs/prompts/phase-09b-error-recovery.md`). **Three of the four ops produce no motion; `home_rail` (phase-09c, below) is THE ONE op that moves a mechanical part.** Routing (`Runtime.arm_maintenance`): 404 = `arm_id` not in `workcells.hardware`; **a hardware session owns the boxes** → the *session path* (`SessionManager.session_recovery`): `clear_errors` and `recover` both run the driver's user-initiated recovery on ITS monitor thread (`HardwareWorkcell.request_recovery(arm_id)`: `clean_error → clean_warn → motion_enable(True) → set_mode(1) → set_state(0)` → re-seed from the MEASURED position; the handler waits ≤ 10 s for a `recovery_result()` with a higher `seq` AND `user_initiated` — the driver bumps `seq` for its own auto recoveries too, and an auto sequence already running when the operator clicked completes first and must not be reported as the operator's outcome — and reports `ok` / the latch reason, e.g. `controller error 1: … - motion_enable failed (release the physical e-stop?)`), `apply_backstops` → 409 (the driver applied the volatile settings at connect), an arm outside `SessionSpec.arms` → 409; **no hardware session** → the *monitor path* (`HardwareStateMonitor.maintenance`): `clear_errors` = `clean_error` + `clean_warn` and NEVER `motion_enable`, `apply_backstops` = `backstops.apply_backstops(api, XArmDriverConfig)` with the arm's `ArmConfig` mapped through the hardware package's own `workcell._driver_cfg` (identical values to the connect-time call; §14), both queued to the arm monitor's poll thread (one `XArmAPI`, one thread; the REST threadpool thread only waits ≤ 10 s), `recover` → 409 `"no hardware session - use clear_errors"`, monitor off / paused / connecting / error → 409 (`"… needs the read-only monitor connected to 'view' (monitor error: …)"`), a second op on the same arm while one runs → 409 (`"a maintenance op is already running on 'view'"`; per-arm lock + the monitor's `maintenance_busy`). 200 whether or not `ok` (a failed `clean_error` code, a re-latched error, a timed-out poll thread all come back as `ok: false` + `detail`). `before` / `after` (monitor path only) are `ArmMonitorTelemetry` rows sampled right before / after the op with `backstops_match` computed against the config, so the UI can show `error_code` → 0 and `collision_sensitivity` / `tcp_load_kg` landing. `sdk_codes` preserves call order (`{clean_error, clean_warn}`; the `backstops.py` sequence). One INFO audit line per call: `maintenance <op> on arm <id> from <client host> via <path>: ok|FAILED - <detail>` (refusals: `refused - <detail>`). **`home_rail` (phase-09c; `docs/prompts/phase-09c-hardware-session.md`, user rule 1 "no implicit motion"):** `set_linear_track_back_origin` drives the carriage to the track's zero end (the operator's LEFT, +X) at the track's OWN homing speed (no SDK setter, duration unmeasured; the positioning cap `rail_speed_mm_s` 50 is written AFTER homing for later moves — 02-hardware §8.6), so it is operator-triggered from the arm card only, **session-less only** (a hardware session exists → 409 `"home_rail is not available while a hardware session owns the arms - end the session first"`; a session is refused while the rail is unhomed, so homing is never needed inside one) and **twin-gated**: `HardwareStateMonitor.maintenance(…, dry_run)` first runs `devices/rail_sweep.py::RailSweepChecker.check` — a dedicated `DigitalTwin` (never the overlay's or a session's; `SceneOverrides(microphones, base_pose)`, `hardware_session.home_rail_inflation_m` 0.025 m = the guardrail's debug margin for a blind sweep from an unknown start, D4) posed with the target arm at its CURRENT 7 joints and the other arm at ITS last sample (rail → `rail_fallback_m` + an `assumptions` entry when unknown, `rail_flip` applied), sweeping the target's rail slot `linspace(0, 0.65, 131)` (`home_rail_step_m` 5 mm) with `check_config_violations` (blocked / clear) and `mj_geomDistance` over the monitored pairs (`min_clearance_*`) → `RailSweepVerdict{scene_id, inflation_m, step_m, travel_m, clear, first_blocked_m/pair, min_clearance_m/at_m/pair, q_checked[7], other_arms, assumptions, sample_seq}` in `rail_sweep`. `dry_run: true` → 200 with the verdict alone, `ok = clear`, `sdk_codes {}` (the HomeRailSheet shows it before the operator confirms); a blocked sweep → 200 `ok: false`, `detail "home_rail refused: rail sweep blocked at 0.000 m (grip_right_inner_knuckle / table) - fold the arm into a tighter posture (xArm Studio) and retry; nothing was written"`, zero writes; a clear sweep → the hardware monitor's `home_rail` op with `expected_q = q_checked` (its poll thread re-samples and refuses, zero writes, if any joint moved > 0.02 rad or an error is latched), writing exactly `set_linear_track_back_origin(wait=True, timeout=30, auto_enable=False)` → `set_linear_track_enable(True)` → `set_linear_track_speed(50)` and judging `ok` from the after-sample registers only (`on_zero == 1 and is_enabled == 1 and error == 0`; the SDK's return code is untrustworthy with `auto_enable`) — `detail "rail homed: carriage at 0.000 m (register 0 mm), track enabled, positioning speed 50 mm/s"`. The REST handler blocks up to **45 s** for this op (D3; `HOME_RAIL_TIMEOUT_S`, 10 s for the others); while it runs the arm reads `stale` with `maintenance_busy: true` and `POST /api/session` is 409 `"rail homing in progress on the …"`. 409s before any write: monitor not connected, a sample missing, `rail_present` false (`"no linear track detected"`), `error_code != 0` (`"clear errors first"`), no twin (`"home_rail needs the digital twin to gate the sweep"`), another op running, **a homing in flight on the OTHER arm** (`"home_rail refused: rail homing in progress on the Perception Arm - wait for it to finish"` — its monitor publishes nothing while the carriage travels, so its sample would pose it pre-homing), **the target's monitor `stale`** (`"… sample of 'grip' is stale … retry when it reads running"` — the sweep needs the CURRENT posture; the hardware monitor re-samples before the write and refuses too when that read fails). Another arm whose monitor is not `running` is still posed from its last sample, with the `assumptions` entry `"view: monitor stale - posed from its last sample, which may not be its current posture"`. **Phase-09d (`docs/prompts/phase-09d-rail-homing-planning.md`; `devices/rail_homing.py::RailHomingService.request`):** a blocked sweep is no longer a flat refusal. The service runs `HardwareStateMonitor.home_rail_preflight` (the refusals + sweep above, zero writes) and then `PrePositionPlanner.evaluate`: candidate postures in order — the scene keyframe's 7 joints for the arm (`source: keyframe`, the folded factory zero), then the `<arm>_home` key (`home`) — each must be sweep-clear itself, reachable by the sweep twin's RRT-Connect from the current posture with the rail slot LOCKED at `rail_fallback_m` (`RailSweepChecker.plan_path`: the carriage is unknown, the job never moves it) AND pass the position-agnostic `RailSweepChecker.check_path`: the path densified to 0.05 rad, EVERY configuration checked at EVERY one of the 131 rail positions at the 0.025 m sweep margin under the planner's start-posture hysteresis (a pair the current posture already violates at a position may only open up; any new violation blocks) — this check is the ONLY safety basis of the motion. The verdict rides `rail_sweep.pre_position: PrePositionPlan{needed, source, target_q[7], waypoints, duration_s (at 10 %), checked_rail_positions (131), clear, detail}` and decides the response: `pre_position.needed == false` (sweep clear) → the synchronous monitor-path homing above (200, `status: done`); `dry_run` → 200 with the verdict + plan only (`ok` = the op can proceed, zero writes); `needed and clear` → a `RailHomingJob` starts (§5 "Rail-homing maintenance motion") and the reply is **202** `status: accepted`, `ok: true`, `job_id`, `sdk_codes {}`, `path: session` (the job connects this arm's driver) — progress on `telemetry.hardware_monitor.arms[].maintenance` (§13.3), the final `ArmMaintenanceResult` (`status: done`, same `job_id`, `ok` true/false, the driver's `sdk_codes`, `after` = the first monitor sample after the resume) at `GET …/maintenance/last`; `needed and not clear` → 200 `status: refused`, `ok: false`, `detail "home_rail refused: … no rail-safe pre-positioning path: keyframe: …; home: … - fold the arm toward the factory zero posture in xArm Studio (joints 2-7 near 0) and retry"`, zero writes. While a job runs on ANY arm every maintenance op is 409 `"<op> refused: rail homing in progress on the Manipulation Arm - wait for it to finish"` and `POST /api/session` is 409 (`maintenance_busy` covers the job's whole life) |
| `GET /api/hardware/arms/{arm_id}/maintenance/last` | → `ArmMaintenanceResult` \| 404 | phase-09d: the last result of the last `home_rail` on this arm — while a `RailHomingJob` runs the 202's `accepted` result (same `job_id`), afterwards its final result, else a synchronous homing's or a refused real op's; 404 until one exists (also for an unknown arm). The HomeRailSheet fetches it when the job's phase reaches `done` / `failed` (polling past `accepted`), and polls it itself when telemetry never shows the job; it only settles on a result carrying ITS `job_id` |

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

### 13.3 `/ws/telemetry`

Broadcast-only, N observers, **25 Hz** (config 20–30). An asyncio task reads
the `snapshot` slot, builds `TelemetryMsg` (shape exactly as 05-ui §2:
`t, seq, ts, epoch, active_arm, controller_connected, arms: ArmTelemetry[],
collision: CollisionReport, clearances, episode, dagger, inference`), and fans out with
per-client latest-wins: a slow consumer gets frames dropped, never
back-pressures control. Runtime-side additions inside the same message:
`session: {state, start_from_progress?, plan_status?, trainer_alive?, bringup?}` —
additive, UI ignores unknown fields. **`session.bringup:
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

**`hardware_monitor: HardwareMonitorTelemetry`** (additive, phase-09a; core §11
`protocol/hardware_monitor.py`; the LAST field of `TelemetryMsg`, after
`microphone`). Always present: `{enabled: false, paused: false, arms: [],
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
  `devices.hardware_monitor.backstops_match(sample, ArmConfig)`: sensitivity
  equal AND `|Δ tcp_load| ≤ 0.05 kg` AND every centre-of-gravity component
  within 10 mm (`null` until the first read-back) — the Hardware tab's
  "differs from config" amber; **`maintenance_busy`** = a maintenance op is
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
         intrinsics: {fx: 608.19, fy: 608.23, cx: 327.39, cy: 247.90}}  # D435i COLOUR
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
control:
  rate_hz: 100
  teleop: {linear_mps: 0.12, angular_rps: 0.6, rail_mps: 0.10, gripper_frac_ps: 1.2}
  leash: {pos_m: 0.025, rot_rad: 0.2}
  target_rate: {v_mps: 1.0, w_radps: 2.0}   # tracker target approach rate (§6)
  dq_max_rad: 0.04           # per tick
  rail_in_ik: false          # rail excluded from the IK; rail inputs slide the whole arm (§6 "Rail")
  jog: {slew_rad_per_tick: 0.02, rail_m_per_tick: 0.002, goto_threshold_rad: 0.15}
  watchdog: {stale_s: 0.2, ramp_s: 0.1}   # = SafetyConfig input_deadman_s/input_ramp_s
  health_log_every_s: 1.0    # control-loop INFO health line period ("Logging" below); 0 = off
recorder: {fps: 25, vcodec: auto, jpeg_quality: 80,
           extrinsics_warn: {pos_m: 0.003, rot_rad: 0.010},   # checkpoint-load
           extrinsics_max:  {pos_m: 0.010, rot_rad: 0.035}}   #   verify, 10-frames §5.3
telemetry_hz: 25
video: {preview_fps: 15, session_fps: 30}
dagger: {policy_hz: 15, t_blend_s: 0.3, pause_others_on_takeover: true,
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
          filter: {enabled: true, min_cutoff_hz: 1.0, beta: 0.05,    # One Euro (live: enabled/
                   d_cutoff_hz: 1.0, deadband_m: 0.002,              #   min_cutoff/beta via
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
  sample_rate: 48000         # the NT-USB Mini is 48 kHz mono only
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
                             #   "hardware not armed" (the lab render sets true, HARDWARE_ARMED)
  default_speed_scale: 0.1   # Hardware-tab default (D2: 10 % / 30 % / 100 % segmented control)
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
so the first live teleop defects could not be read off a log. Now
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
(`backstops_match`, §13.3). A YAML value out of range fails
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
fakes only — the first live run is the phase-09c acceptance). Mechanism: every tick the
loop calls `workcell.drain_events()` (core `WorkcellInterface`, default `[]`;
`HardwareWorkcell` returns every driver's events in `t_mono` order) and
dispatches BY CLASS NAME (`control.loop.FAULT_EVENT_NAMES`; the runtime never
imports the optional hardware package's event types — the fakes mirror them
field-for-field and a test pins the names against the hardware package).

| Failure | Detection | Response |
|---|---|---|
| xArm controller error (C22 self-collision, C24 speed, C31 collision, C35 boundary…) | driver `FaultEvent` via `workcell.drain_events()` (the driver's 5 Hz monitor / servo return code 1 funnel into it; `ArmState.error_code` ≠ 0 holds the arm meanwhile) | THAT arm → FAULT: `ArmSender.pause()` (drains its slot, dispatches nothing), the loop holds it (`arm_stopped`) and publishes no target for it, drops its plan / jog / teleop seed, releases the clutch anchors if it was the clutched arm; `session.state = fault`, `arms[*].fault_detail` = the SDK `x_code` title (+ the driver's latch reason); **other arms keep running**. Recovery is the driver's (auto within its 3/30 s budget for RECOVERABLE codes, else the operator's `recover` click, §13.1): `clean_error → clean_warn → motion_enable(True) → set_mode(1) → set_state(0)` → `ReseedEvent` + `RecoveredEvent` → the loop **re-seeds** from `get_state()` (`_last_cmd`, IK warm state, gate `_last_safe`, watchdog AWAIT_EMPTY), resumes the sender and holds the arm in RECOVERING until the first tick whose inputs hold nothing live (clutch released / keys up or watchdog-latched) → RUNNING; a latch `FaultEvent` (`motion_enable failed (release the physical e-stop?)`, budget exhausted, …) keeps FAULT until the next click |
| Command return 9 / −2 (state not ready) | per-command code → driver `FaultEvent(source="servo")` | same recovery path (controller silently drops to mode 0 on error) |
| Operator "Clear errors & resume" (Cockpit) / "Clear errors" (Hardware tab) | `POST /api/hardware/arms/{arm_id}/maintenance` | session: `request_recovery` on the driver's monitor thread, result awaited ≤ 10 s via `recovery_result()`; no session: `clean_error` + `clean_warn` on the read-only monitor's poll thread, never `motion_enable` (§13.1). Neither moves the arm |
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
| Camera hung | `read_latest` max-age miss | recorder drops frame + counts; video tile goes stale client-side; capture-thread reconnect (RealSense `hardware_reset` retry) |
| Recorder exception in `save_episode` | RecorderThread try/except | **KEEP the episode buffer** (do NOT `clear_episode_buffer`); retry once; on second failure mark the session degraded (recording off, telemetry + toastable detail), keep teleop/safety alive (12-dagger §12); control unaffected. `add_frame` exception: drop that frame + count; repeated failures degrade likewise |
| Tick overrun (> 10 ms) | pacing check | log + skip catch-up; ≥ 10 consecutive → telemetry warning `control_degraded` |
| Unclean prior shutdown | `recorder_state.json` finalized=false | on startup: `resume()` + `finalize()` repair before serving |
| SIGINT/SIGTERM | signal handlers | full TEARDOWN (§5.4): ramp, finalize, stop trainer, disconnect arms, `renderer.close()` (avoids EGL teardown noise) |

## 16. Test strategy

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
   404 unknown arm, 422 unknown op.
3. **Sim-backed e2e** (`[sim]` extra, CI with EGL): (a) sim session, stream
   `KeysMsg` W for 1 s ⇒ EE moved +x, telemetry ≥ 20 Hz; (b) collect: record
   2 episodes (one saved, one discarded) to a tmpdir, `finalize`, re-open
   with `LeRobotDataset`, assert schema §10.2 (intervention / action_source /
   wallclock_ns), fps=25, episode count 1; (c) `safety_debug` guardrail: the
   `apollo-mavis-v2-sim` collision-course script through the runtime must be
   blocked *before* contact with `CollisionEvent`s (CI regression, overview
   §6); (d) DAgger smoke with scripted `Policy` + stub trainer: Space cycles
   policy→transition→human and back, hot-swap only at episode boundary;
   inference smoke: takeover works, recorder never instantiated.

Recorder crash-safety: raise inside `save_episode` ⇒ buffer kept + one retry
succeeds (fault injected once), second consecutive failure degrades recording
while the dataset stays finalizable; skip finalize (simulated death) ⇒
startup repair via `recorder_state.json`.
