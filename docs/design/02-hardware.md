# 02 — apollo-mavis-v2-hardware (`apollo_mavis_v2_hardware`)

Status: v0.6 (2026-09-05 phase-09d: §3.1 `rail_homing: "allow_unhomed"` connect
for the runtime's rail-homing maintenance motion — position UNKNOWN, 0.0
placeholder + `rail_position_known`, §5 `XArmDriver.home_rail() ->
RailHomeOutcome` on a CONNECTED driver with the joints held, judged from the
registers, §9 `rail: "unhomed"` + connected, §10, §15; v0.5 2026-09-05
phase-09c: connect NEVER homes — §3.2/§5
`require_homed()` + `RailNotHomedError`, §8.6 `home_rail` = the ONE motion
maintenance op (operator-triggered, twin-gated, judged from registers), §3.1 D2
speed caps, §3.6 D6 hand-back, §9 `rail: "unhomed"`, §14; v0.4 2026-09-04
phase-09b: §8.6 explicit maintenance channel on the
monitor — "zero writes unless an explicit maintenance request", §3.5/§3.6
`request_recovery()` / `recovery_result()`, §6 backstop parameters from core
`ArmConfig` + read-back, §9 `drain_events()` / `request_recovery(arm_id)`, §13;
v0.3 2026-09-04 phase-09a: §8.5 read-only state monitor, §12 SDK
1.18.5 fixes from the first read-only contact with the real boxes; v0.2
2026-09-04: §7.4 NM dispatcher, state-path precedence, permissions; v0.1
2026-09-01). Conforms to `00-overview.md` v0.3 (spine). Ground
truth: `docs/research/xarm-python-sdk.md` (SDK 1.18.5, verified against
source), `network-manager.md` (audited on the target machine),
`web-teleop-stack.md` §5 (camera ABC). Depends **only** on
`apollo_mavis_v2_core` + `xarm-python-sdk==1.18.5`, `opencv-python`,
optional `pyrealsense2`. No MuJoCo, no FastAPI.

## 1. Package layout

```
apollo-mavis-v2-hardware/
├── pyproject.toml              # deps per header; extras: [realsense]
├── src/apollo_mavis_v2_hardware/
│   ├── config.py               # XArmDriverConfig, ServoLimits (pydantic)
│   ├── units.py                # ALL m/rad <-> mm + pulse/frac conversions (§2)
│   ├── driver.py               # XArmDriver, _ServoStreamer, _MonitorThread (§3)
│   ├── grippers.py             # GripperBackend ABC + Classic/G2/No (§4)
│   ├── rail.py                 # RailController (§5)
│   ├── monitor.py              # ArmStateMonitor: read-only controller poller (§8.5)
│   │                           #   + explicit maintenance channel (§8.6)
│   ├── backstops.py            # controller-side safety params (§6)
│   ├── events.py               # DriverEvent union: FaultEvent, RecoveredEvent,
│   │                           #   ReseedEvent, StudioConflictWarning, RailEvent,
│   │                           #   GripperFaultEvent
│   ├── netsetup/               # (§7) __init__.py (NetSetup facade), nmcli.py,
│   │                           #   types.py, probe.py, match.py, reconcile.py,
│   │                           #   install.py, state.py, dispatcher.py (§7.4 NM
│   │                           #   hook renderer), __main__.py (CLI: verify|
│   │                           #   match [--repair]|reconcile|install|status)
│   ├── cameras/                # (§8) __init__.py (make_camera, find_all_cameras),
│   │                           #   opencv_camera.py, realsense_camera.py
│   └── workcell.py             # HardwareWorkcell (§9)
└── tests/                      # fakes/{fake_xarm_api,report_replayer}.py, test_*.py,
                                #   fixtures/nmcli/*.txt + fixtures/report/*.bin
```

Import rule: `XArmAPI` only in `driver.py` (injected everywhere else);
`pyrealsense2` only in `realsense_camera.py` behind a try/except guard.

## 2. Unit conversion boundary (`units.py`)

Core is m/rad/quat-wxyz; the SDK is mm + rad (always construct
`XArmAPI(is_radian=True)` — **degrees never appear anywhere**). Conversion
happens exactly once, here; nothing else multiplies by 1000. Joints/torques
pass through (rad, N·m). Quat↔RPY helpers come from
`apollo_mavis_v2_core.se3`; this module fixes convention and scaling (RPY =
**extrinsic XYZ, `R = Rz(yaw)·Ry(pitch)·Rx(roll)`** — equivalently intrinsic ZYX —
the xArm firmware convention, verified 2026-09-11 against 15 hardware episodes: FK
of the recorded joints and the controller's reported RPY agree to 0.0001°. Before
that date `core.se3.rpy_to_quat` composed `Rx·Ry·Rz`, which is
wrong for any pose with two non-zero angles; only the read side was affected —
the driver sends no Cartesian commands).

The controller reports the **flange** (`tcp_offset` is zero on both boxes).
`sdk_to_pose` / `pose_to_sdk` stay the pure unit + RPY converters (flange in,
flange out); `sdk_to_tcp_pose(p, gripper=...)` composes `core.se3.flange_to_tcp`
on top — `(Rz(π), Trans(0, 0, 0.172))` for a gripper arm (the xArm Gripper base is
mounted 180° about tool z under link7, MJCF `xarm_gripper_base_link`
`quat="0 0 0 1"`), identity for a gripper-less arm whose `link_tcp` IS the
flange — and returns the twin's `link_tcp` pose, which is what `ArmState.ee_pose`
carries (10-frames §2.4).

```python
GRIPPER_PULSE_MAX = 850; GRIPPER_G2_MM_MAX = 84.0; RAIL_MM_MAX = 650

def m_to_mm(x: float) -> float: ...           # + mm_to_m
def pose_to_sdk(pose: Pose) -> list[float]:   # (m, wxyz) -> [x_mm,y_mm,z_mm,r,p,y rad]; FLANGE
def sdk_to_pose(p: Sequence[float]) -> Pose:  # inverse; quat normalized, w >= 0; FLANGE
def sdk_to_tcp_pose(p, *, gripper: bool) -> Pose:      # flange SDK -> twin link_tcp
    # = se3.flange_to_tcp(sdk_to_pose(p), gripper=gripper); + tcp_pose_to_sdk inverse
def frac_to_pulse(f: float) -> int:           # [0,1] open frac -> pulses [0,850]; + inverse
def frac_to_g2_mm(f: float) -> float:         # [0,1] -> [0, 84.0] mm; + inverse
def rail_m_to_mm(x: float) -> int:            # m -> abs int mm, clamped [0, 650]; + inverse
    # SDK does NOT clamp; over-travel raises linear-motor error 25/26
```

## 3. XArmDriver (`driver.py`)

### 3.1 Configuration & construction

One `XArmDriver` per arm; one `XArmAPI(ip, is_radian=True,
report_type='real')` per driver, never shared across arms/processes (each
instance owns its 502 socket, report socket, lock).

```python
# config.py
class ServoLimits(BaseModel):              # defaults = HARDWARE CAPS at speed_scale 1.0 (09c D2)
    rate_hz: float = 100.0
    max_joint_vel: NDArray7 = [0.6]*7      # rad/s cap (per-tick slew = vel*dt);
                                           #   0.3 / 0.002 (cart) before 2026-09-07
    max_joint_acc: NDArray7 = [20.0]*7     # rad/s^2 (prevents C24 on step changes)
    lever_arm_m: NDArray7 = [1.20, 1.20, 1.00, 0.75, 0.44, 0.30, 0.10]
    max_cart_step_m: float = 0.004         # 0.4 m/s TCP cap (2026-09-07; was 0.002); half the
                                           #   gate's 8 mm inflation - firmware limit 10 mm/tick
    joint_limit_margin_rad: float = 0.0087 # 0.5 deg inside limits (avoids -8 OUT_OF_RANGE)

class XArmDriverConfig(BaseModel):
    arm_id: str; ip: str
    expect_rail: Literal["auto", "yes", "no"] = "auto"
    gripper: Literal["xarm", "xarm_g2", "none"] = "xarm"
    tcp_load_kg: float = 0.82              # classic gripper mass; override per tool
    tcp_load_cog_mm: tuple[float, float, float] = (0.0, 0.0, 48.0)
    collision_sensitivity: int = 3         # 3..4 per overview §6
    reduced_tcp_boundary_mm: tuple[int, int, int, int, int, int] | None = None
        # optional [x_max,x_min,y_max,y_min,z_max,z_min] base-frame envelope
        # (11-safety §11); None = reduced mode off
    rail_speed_mm_s: int = 50; servo: ServoLimits = ServoLimits()   # 50 mm/s cap (D2)
    rail_homing: Literal["require_homed", "allow_unhomed"] = "require_homed"
        # 09d: "allow_unhomed" ONLY for the runtime's rail-homing maintenance motion —
        # connect proceeds with an unhomed track (dof 8, rail DETECTED, position UNKNOWN,
        # q[7] a 0.0 placeholder) and XArmDriver.home_rail() homes it later (§5)
    monitor_rate_hz: float = 5.0; stale_after_s: float = 0.15  # 30003 silence => stale
    expected_sn: str | None = None         # assert vs arm.sn (cabling swaps)

# driver.py — implements every core.ArmInterface member (01-core.md), plus:
class XArmDriver(ArmInterface):
    def __init__(self, cfg: XArmDriverConfig,
                 api_factory: Callable[..., Any] | None = None) -> None: ...
        # api_factory defaults to xarm.wrapper.XArmAPI; tests inject FakeXArmAPI
    phase: DriverPhase          # property: §3.5 machine phase
    def drain_events(self) -> list[DriverEvent]: ...  # bounded deque pickup
    def request_recovery(self) -> None: ...           # phase-09b: user recovery on the
                                                      #   monitor thread (§3.5, §3.6)
    def recovery_result(self) -> RecoveryResult | None: ...  # last sequence's outcome
    def home_rail(self) -> RailHomeOutcome: ...       # phase-09d: MOTION, caller's thread,
                                                      #   joints held by the stream (§5)
    rail_position_known: bool   # property: False = q[7]/rail_pos_m is the 0.0 placeholder
    tick_stats: TickStats       # property: jitter p50/p99, late ticks, faults

@dataclass(frozen=True)
class RecoveryResult:           # set at the end of every recovery sequence
    seq: int; ok: bool; error_code: int; detail: str = ""   # detail = latch reason
    user_initiated: bool = False; t_mono: float = 0.0
```

**Speed caps (phase-09c D2).** `servo.max_joint_vel` (0.6 rad/s since
2026-09-07; 0.3 for the first live runs), `servo.max_cart_step_m` (4 mm per
10 ms tick = 0.4 m/s TCP since 2026-09-07; 2 mm before — the operator found
100 % "still very slow"; 4 mm is deliberately HALF the gate's 8 mm inflation so
one tick can never cross the inflated shell the gate checks once per tick) and
`rail_speed_mm_s` (50) are the hardware caps at `SessionSpec.speed_scale == 1.0`;
the runtime multiplies all three by the session's `speed_scale` (Hardware-tab
segments 10 / 50 / 100 %, default 100 % = `hardware_session.default_speed_scale`
1.0 since 2026-09-08 evening — the operator's call after the first
`reset_to_initial` runs; it was 0.5 = 50 % from 2026-09-07 and the earlier
10 % / 30 % / 100 % picker with its 10 % default was meant for the very first
runs only; the lab config rendered from `configs/mavis_v2.yaml` keeps whatever
value it was rendered with until re-rendered and the runtime restarted) inside
its `driver_factory` closure before constructing the
driver, so the first live runs streamed at 0.03 rad/s / 0.2 mm per tick / 5 mm/s.
`ServoLimits` values are per-driver constants for the life of a connection
(`_ServoStreamer.set_scale` is internal to the C24 back-off).

`dof` = 8 if `has_rail` else 7; `gripper_force_capable` True only for
`xarm_g2`. `command_joints(q)` (len == dof, `q[7]` = rail, m) is
non-blocking: validate length, clamp into joint limits minus margin, store
joints 0–6 as the streamer target (latest-wins), forward `q[7]` to
`RailController.set_target(pos_m)`.

### 3.2 Connect / bring-up sequence

`connect()` runs synchronously (HardwareWorkcell parallelizes across arms):

1. `api = api_factory(cfg.ip, is_radian=True, report_type='real',
   enable_report=True, check_joint_limit=True)`; retry 3× 2 s apart.
   HardwareWorkcell delays this until TCP 502 probes open (§7).
2. Identity: `api.sn`; mismatch vs `expected_sn` → `ArmIdentityError`
   (cabling swap). Firmware tuple for the gates (≥2.7.100 gripper current
   monitor, ≥1.9.110 `is_real` readback) = `grippers.read_fw_tuple(api)` →
   `api.version_number` (SDK-parsed `(major, minor, rev)`). **Not**
   `parse_fw(api.version)`: in SDK 1.18.5 `api.version` is the RAW controller
   string `7,7,XS1305,MC1303,v1.12.10` (axes, type, arm SN, box SN, fw) and
   parsing it gave a bogus major so every gate passed (fixed 2026-09-04, §12).
3. `api.clean_warn(); api.clean_error()` (a latched prior error makes every
   call return 1); apply backstops (§6). The enable — `api.motion_enable(True);
   api.set_mode(0); api.set_state(0)`, required order, every `set_mode`
   followed by `set_state(0)` — comes AFTER the rail gate of step 4 (review
   fix 2026-09-05): register reads need no enable, so a rail refusal leaves the
   arm exactly as found (state 4, brakes engaged) — zero writes to the arm.
4. Rail detection per `expect_rail` (`auto` → `RailController.detect()`;
   `yes` → absent raises `RailExpectedError`; `no` → skip); fixes `dof`;
   `rail.warnings` (e.g. "SN not verified", §5) are appended to
   `connect_warnings`. With a track present: `rail.require_homed()` —
   **connect never homes** (phase-09c, user rule "no implicit motion"). It
   reads `get_linear_track_registers`; `on_zero == 0` raises
   `RailNotHomedError(step="rail")` with nothing written (the workcell maps it
   to `ArmBringupStatus.rail = "unhomed"`, the runtime refuses the session and
   the operator homes from the Hardware tab via the monitor's `home_rail` op,
   §8.6); `on_zero == 1` → `set_linear_track_enable(True)` +
   `set_linear_track_speed(cfg.rail_speed_mm_s)` (non-motion) and `pos_m` is
   SEEDED from the register (`get_linear_track_pos` after the enable), so the
   gate twin sees the true carriage position before the first 5 Hz `step()`.
   A failing register read, or a non-zero code from the enable / speed write,
   raises `BringupError(step="rail")` (phase `RAIL_ERROR`, `RailEvent`): the
   carriage position is unverifiable / the track is not enabled, so the
   connect is REFUSED (`ArmBringupStatus.rail = "error"` + `error`) — never a
   connected arm whose rail silently reports `pos_m == 0.0` (the gate twin would
   be off by up to the full travel). Exception (phase-09d, maintenance motion
   ONLY): with `cfg.rail_homing == "allow_unhomed"` the call is
   `rail.require_homed(allow_unhomed=True)` and `on_zero == 0` is ACCEPTED, still
   with nothing written — phase `DETECTED`, `pos_known False`, `dof` 8, the rail
   slot a 0.0 placeholder flagged by `XArmDriver.rail_position_known == False`,
   a "position UNKNOWN" `connect_warnings` entry + `RailEvent`; the runtime's job
   pre-positions the arm and then calls `home_rail()` (§5). An unreadable
   track is refused in both modes. Then the enable of step 3.
5. Gripper backend init (§4); `register_report_callback(self._on_report,
   report_cartesian=True, report_joints=True, report_state=True,
   report_error_code=False, report_warn_code=False, report_mtable=False,
   report_mtbrake=False, report_cmd_num=True)` → snapshots (§3.4). These are
   the ONLY keywords SDK 1.18.5 accepts (`xarm/wrapper/xarm_api.py:2222`);
   the former `report_mode=True` raised `TypeError` on the first real connect
   (fixed 2026-09-04).
6. Enter streaming: `set_mode(1); set_state(0); sleep(0.1)`, seed streamer
   from `get_servo_angle(is_real=True)` (plain fallback on old fw), start
   `_ServoStreamer` + `_MonitorThread`. Phase → `STREAMING`.

Failures raise typed exceptions (`ArmConnectError`, `ArmIdentityError`,
`RailExpectedError`, `RailNotHomedError`, `GripperInitError`) carrying the
step name; the workcell turns them into per-arm statuses (§9), never aborting
other arms. A connect that fails after step 3 has already enabled the arm;
`disconnect()` (§3.6) hands it back stopped and braked — the runtime tears the
workcell down on any per-arm error.

### 3.3 Servo streaming thread (`_ServoStreamer`)

One dedicated thread per arm, mode 1 (`set_servo_angle_j`), fixed 100 Hz —
official guidance: fixed 20–100 Hz, per-command step **< 10 mm**; SDK
examples stream at 100 Hz. Mode 1 has **no firmware smoothing** and executes
only the last instruction — the streamer owns all velocity/accel limiting.

API: `_ServoStreamer(api, limits: ServoLimits, on_fault)`: `set_target(q7)`
(thread-safe, latest-wins), `reseed(q7)` (target := last_sent := q7, zero
velocity), `pause()/resume()`, `start()/stop()` (join, 0.5 s timeout),
`last_sent`, `stats: TickStats`. Tick algorithm (`dt = 10 ms`):

```
next_t = monotonic() + dt
loop while running:
    sleep(max(0, next_t - monotonic())); now = monotonic()
    if now - next_t > 2*dt: next_t = now       # re-anchor after stalls: NEVER burst —
    next_t += dt                               # catch-up ticks = velocity spike = C24
    tgt = latest target (or last_sent if paused/none — hold is safe)
    dq  = clip(tgt - last_sent, -vel_step, +vel_step)      # vel_step = max_joint_vel*dt
    dq  = clip(dq, prev_dq - acc_step, prev_dq + acc_step) # acc_step = max_joint_acc*dt^2
    cart_est = sum(|dq[i]| * lever_arm_m[i])               # conservative TCP-step bound
    if cart_est > max_cart_step_m: dq *= max_cart_step_m / cart_est
    q_cmd = clip(last_sent + dq, joint_lo + margin, joint_hi - margin)
    code = api.set_servo_angle_j(list(q_cmd), is_radian=True)  # blocking, sub-ms LAN
    if code == 0: last_sent, prev_dq = q_cmd, dq
    elif code == 9 and now < grace_until: not_ready_ticks += 1   # still entering mode 1
    else: on_fault(code, q_cmd); pause()       # §3.5 takes over
    record tick latency into stats (EWMA + p99 ring)
```

**Entering servo mode is not instantaneous.** `set_mode(1); set_state(0)`
returns before the control box will accept `move_servoj`: its replies still
carry the "not ready to move" bit (0x10), which the SDK turns into APIState
**9** (`_check_code(is_move_cmd=True)` → `STATE_NOT_READY`; the reported state
code is NOT what gates the move). A blind `sleep(0.1)` raced it on the real
boxes — the FIRST servo tick of the first live hardware session returned 9 and
faulted the arm mid-bring-up (2026-09-05, §16). Two guards, both bounded:

1. `XArmDriver._enter_servo_mode()` is the single place the driver enters mode
   1 (connect step 6, `_recover`, `_handle_external`): `set_mode(1)`,
   `set_state(0)`, then `_await_servo_ready()` POLLS `get_state()` every
   `SERVO_READY_POLL_S` (20 ms) for up to `SERVO_READY_TIMEOUT_S` (1.5 s) until
   the state is in `SERVO_HEALTHY_STATES`. Read-only polling, and each reply
   also refreshes the SDK's ready flag. A timeout does not fault — guard 2 owns
   that decision.
2. `resume()` opens a `SERVO_NOT_READY_GRACE_S` (0.3 s) window in which a code
   **9** is retried on the next tick instead of faulting (`last_sent` is not
   advanced — nothing moved — and `not_ready_ticks` counts them). Past the
   window a 9 faults like any other bad return, so a box that stays not-ready
   still surfaces within ~0.3 s.

The lever-arm bound keeps worst-case TCP step ≤ `max_cart_step_m` (4 mm per
tick at `speed_scale` 1.0, i.e. 0.4 m/s, since 2026-09-07; scaled with the session, D2) with all
joints slewing (no MuJoCo/Jacobian in `hardware` — fixed conservative radii). Jitter:
deadline scheduling on `monotonic()`; sustained p99 > 3 ms emits a
`DriverEvent` warning (GIL-pressure cue, overview §2). The stale-input
deadman (~0.2 s) is runtime's job (overview §6): runtime ramps targets; the
streamer merely holds `last_sent`.

### 3.4 State: 30003 report stream, parsing, staleness

State comes from the controller's **push** stream on port 30003
(`report_type='real'`, 100 Hz, 87-byte frames) — never from polling. The
SDK report thread parses frames; our `register_report_callback` hook
writes a `_StateSnap` dataclass (written only by the callback, read by
`get_state()`): `q` (`actual_joint_angle[7]`, rad), `dq` (finite-diff at
100 Hz, EMA α=0.5 — 30003 carries no velocities), `ee_pose_sdk`
(`actual_tcp_pose[6]`, mm+rad, base frame), `tau` (N·m), `state` (payload),
`mode` (the SDK `api.mode` property — the callback PAYLOAD never carries
`mode`, `x3/base.py:1284-1300`; the SDK report thread keeps `_mode` current
from the 30003 `state_mode` byte. Reading `data["mode"]` returned 0 and made
the Studio-conflict detector latch every arm ~1.2 s after connect; fixed
2026-09-04), `cmd_num`, `mono_ts`, `wallclock_ns`.

Swap-in is one reference assignment (GIL-atomic); `get_state()` never
blocks: it assembles `ArmState` — `q`/`dq` (+ rail slot from
`RailController.pos_m`; rail dq = 0.0), `ee_pose = units.sdk_to_tcp_pose(...,
gripper=(cfg.gripper != "none"))` — the wire carries the FLANGE, `ArmState.ee_pose`
is the twin's `link_tcp` = flange ⊕ (Rz(π), +0.172 m along tool z) on a gripper arm
(2026-09-11; before that the raw flange was published as the TCP),
gripper state from the backend cache, `error_code`/`warn_code` from the
monitor cache (**30003 carries no err/warn**), `mode`, `stale`, `ts`.
**Staleness**: `monotonic() - mono_ts > 0.15 s` (15 missed frames) →
`stale=True` + `DriverEvent`; the runtime gate treats stale as hold + block.
The SDK report thread auto-reconnects; socket dead > 2 s → `FAULT` (link
loss). With `report_type='real'` the rich-only caches (temperatures, GPIO,
reduced-mode) never update — `_MonitorThread` polls what we need at 5 Hz.

### 3.5 Error / recovery state machine

`DriverPhase`: `IDLE → CONNECTING → READY(mode 0) → STREAMING(mode 1)`;
`STREAMING --fault--> FAULT --auto--> RECOVERING --ok--> STREAMING`;
`FAULT --unrecoverable|budget--> LATCHED --clear_errors()--> RECOVERING`.
Fault detection (all funnel into `_on_fault(source, code)`): (1)
`set_servo_angle_j` return ≠ 0, per tick — `1` controller error latched,
`9`/`-2` not ready, `3` timeout, `-1` disconnected, `-8` SDK joint-limit
reject (bug in our clamping — log loudly, treat as fault); (2) 5 Hz
`get_err_warn_code()` poll (errors while holding); (3) report staleness /
SDK `connected` flip. Recovery (on the monitor thread, streamer paused):

```
1. code, [err, warn] = api.get_err_warn_code()   # capture for event log
2. classify(err) -> RECOVERABLE | UNRECOVERABLE | EXTERNAL
3. api.clean_error(); api.clean_warn(); api.motion_enable(True)  # err -> mode 0
4. api.set_mode(1); api.set_state(0); sleep(0.1)
5. code, q = api.get_servo_angle(is_real=True)   # re-seed from MEASURED position
6. streamer.reseed(q); streamer.resume()
7. emit ReseedEvent(arm_id, q)  # runtime MUST re-seed its IK target pose
```

Classification (controller error codes):
- **RECOVERABLE**: 22 self-collision, 31 collision/abnormal current, 35
  safety boundary, 24 speed limit, 23 joint-angle limit, 25 planning.
  Budget ≤3 recoveries per rolling 30 s, else `LATCHED`. **C24
  special-case**: after recovery halve `max_joint_vel`/`max_joint_acc` for
  10 s, then restore; a second C24 in the backoff window → `LATCHED`.
  **Re-fault while holding (2026-09-09 evening)**: the SAME recoverable code
  firing again within `REFAULT_WINDOW_S` (1.5 s) of an AUTOMATIC recovery while
  the streamer has only re-sent the re-seeded posture (no target more than
  `REFAULT_STILL_TOL_RAD` = 1 mrad away arrived from the runtime) means the cause
  is still physically present — for C31 the collision load is still on the arm —
  and re-enabling cannot clear it. The driver `LATCHED`s at once with
  `re-latched <ms> ms after recovery with the arm holding still: the collision
  load is still on the arm - back it off or let go of the object, then Recover`
  (generic wording for the other codes) and the burst costs ONE budget slot.
  Measured in the fridge-door session (`var/logs/runtime.stderr.log` 21:42–22:55):
  every auto-recovery took 20 ms, the door's pull tripped C31 again ~200 ms
  later with the arm standing still, four C31 in 660 ms, "recovery budget
  exhausted (3 in 30 s)" before the operator had a turn — and a manual Recover
  13 s later succeeded because the load had gone. A re-fault AFTER a new target
  is a fresh event on the budget path; a user Recover forgets the burst
  (`_reset_recovery_budget`). Note the joint-torque read-back cannot gate this
  BEFORE re-enabling: with the servos off after a collision stop the reported
  currents are ~0 whatever the load, so the controller's own re-fault is the
  only detector. Tests: `test_driver_recovery.py` "re-fault under load" pack.
- **UNRECOVERABLE** → `LATCHED` immediately: 1/2/3 e-stop variants (never
  auto-resume), 10–17 servo motor, 19/28 end-module comms, 110 baseboard.
  **111** (rail dropped off RS-485) latches only the rail (`RAIL_ERROR`);
  the arm keeps streaming, rail frozen.
- **EXTERNAL** (the arm LEFT SERVO MODE with no error code, §9): pause, emit
  `StudioConflictWarning`, retry mode 1 once; again in 5 s → `LATCHED`. "Left
  servo mode" = `mode != 1` **or** `state in SERVO_CONFLICT_STATES = {3, 4, 5,
  6}` (paused / stopped / decelerating). `SERVO_HEALTHY_STATES = {0, 1, 2}`:
  **state 2 (standby, "sleeping") is the state a HELD mode-1 arm reports** —
  re-sending the same posture is not motion, and both lab boxes sit in `mode 1
  state 2` for a whole session. The SDK agrees (`ready = state not in (4, 5)`,
  `x3/base.py` `__handle_report_real`); we additionally count 3/6 as a conflict
  because a paused arm silently ignores servo ticks. Accepting only `{0, 1}`
  latched BOTH arms with "external mode/state conflict persisted (UFACTORY
  Studio?)" ~0.5 s after every connect and every recovery, with no Studio
  running, on the first live session (2026-09-05, §16). The latch text now
  reports the MEASURED mode/state instead of asserting a cause.

`LATCHED`: streamer paused, gripper/rail queues cleared, every `command_*`
raises `ArmFaultedError` (hardware-local, subclasses core `CommandError`);
state reporting continues (UI shows the arm red +
SDK error message). Only an explicit user action — `clear_errors()` or
`request_recovery()` — re-enters `RECOVERING`.

**User-initiated recovery (phase-09b).** `request_recovery()` only sets
`_user_recovery_pending`; `_MonitorThread.step()` services it first (before a
pending auto fault): budget + C24 backoff reset, streamer paused, then
`_recover(user_initiated=True)` — the same binding sequence, bypassing
classification and the budget, so it also works from `LATCHED` after an
UNRECOVERABLE code (e-stop released, C19 cleared in Studio, …) and from
`STREAMING` (then it is a re-seed). Its `FaultEvent` carries `source="user"`
and the controller error still latched at capture; success is
`ReseedEvent` + `RecoveredEvent`, failure a latch `FaultEvent`
(`motion_enable failed (release the physical e-stop?)`, …). Every sequence
(auto or user) ends by publishing a `RecoveryResult` (`recovery_result()`),
so a waiter (REST) can observe the outcome without draining the events the
control loop consumes. `request_recovery()` raises `CommandError` when the
driver is not connected. It never runs SDK calls on the caller's thread.

### 3.6 stop(), clear_errors(), disconnect()

`stop()`: pause streamer, `api.set_state(4)` (SDK `emergency_stop()` loops
this ≤3 s), clear queues, phase → `LATCHED` (`user_stop`); does **not**
clear errors and is not hardware STO — the physical e-stop button remains
the real emergency path. `clear_errors()`: from `LATCHED` only; runs §3.5
recovery synchronously ON THE CALLER's thread — with the physical e-stop still
engaged, `motion_enable` fails and it stays `LATCHED` ("release e-stop"
event). From another thread (the runtime's REST handler) use
`request_recovery()` instead: one `XArmAPI` must not be driven from two
threads, so the sequence runs on the driver's monitor thread (§3.5). `disconnect()`: stop streamer +
monitor (join, 0.5 s timeouts), then best-effort `set_mode(0); set_state(4);
motion_enable(False)` — the arm is handed back in the power-on posture
"stopped, brakes engaged" (phase-09c D6; before 09c it was left enabled in
mode 0) — gripper `close()`, `api.disconnect()`; idempotent, never raises
(logs). The linear track is deliberately left alone: it keeps its homed flag
and its enable (no `set_linear_track_enable(False)`), so the next session
needs no re-homing. A finished session therefore leaves the cell as found
except for the track state, and the physical e-stop remains the only hard stop.

## 4. Gripper backends (`grippers.py`)

`GripperBackend(ABC)`: `force_capable: ClassVar[bool]`; `init(api,
fw: tuple[int, int, int])`; `command(cmd: GripperCommand)` (queued, runs on
the monitor thread); `poll() -> GripperState` (5 Hz, monitor thread);
`close()`. Impls: `ClassicGripper` (False), `G2Gripper` (True), `NoGripper`.

**ClassicGripper** (`"xarm"`; RS-485 tool modbus, position-only, pulses
0–850). init: `set_gripper_enable(True); set_gripper_mode(0);
set_gripper_speed(3000)` (r/min, valid ~1000–5000). command:
`set_gripper_position(units.frac_to_pulse(cmd.open_frac), wait=False,
wait_motion=False)` — **never** `wait=True` in-session (latency jitter on the
shared 502 socket); `wait_motion=False` skips the SDK's implicit `wait_move()`
(`x3/gripper.py:560-568`, default on) that would block the monitor thread
while the arm streams (2026-09-04);
rate-limited 10 Hz, latest-wins, skip if |Δpulse| < 5; `cmd.force` ignored.
poll: `get_gripper_position()` → `GripperState{open_frac, grasped?,
current?}`; gripper fw ≥ 3.4.3: `get_gripper_status()&0x03 == 2` → grasped.
**Current monitor (controller fw ≥ 2.7.100)**: init calls
`set_external_device_monitor_params(dev_type=1, frequency=10)`; an optional
`_Port30000Reader` thread (SDK `ReportDataStructure.create(30000)` parser)
feeds `monitor_device_*` current into `GripperState.current`; absent fw →
None. errors: poll `get_gripper_err_code()`; nonzero →
`clean_gripper_error()` + re-enable, else `GripperFaultEvent` (arm unaffected).

**G2Gripper** (`"xarm_g2"`):
`set_gripper_g2_position(units.frac_to_g2_mm(f), speed=150,
force=int(cmd.force*100) if cmd.force else 50, wait=False,
wait_motion=False)` — pos 0–84 mm, speed 15–225 mm/s, force 1–100 %.
`wait_motion=False` is mandatory: the SDK otherwise runs `wait_move()` first
(`x3/gripper.py:969-977`) and blocks the 5 Hz monitor thread for as long as
the arm is moving (fixed 2026-09-04). `GripperCommand.force` (normalized [0,1])
is honored here and only here; poll `get_gripper_g2_position/force`.

## 5. Linear track / rail (`rail.py`)

Control-box RS-485 device (modbus proxied over 502, fw ≥ 1.8.0). Slow,
position-only axis — **no streaming interface**, not in controller
kinematics/collision — the driver folds measured rail position into
`ArmState.q[7]`; runtime folds it into world TF / twin.

```python
HOME_RAIL_SDK_WAIT_S = 30.0      # SDK homing-wait timeout (shared with the monitor op, §8.6)
UNKNOWN_RAIL_POS_M = 0.0         # placeholder published while the track is unhomed (09d)
class RailPhase(Enum): ABSENT; DETECTED; READY; RAIL_ERROR   # no HOMING: homing is a latch, not a phase
class RailController:
    def __init__(self, api: Any, speed_mm_s: int = 50, arm_id: str = "") -> None: ...
    def detect(self) -> bool: ...
    def require_homed(self, allow_unhomed: bool = False) -> None: ...  # raises RailNotHomedError
    def home(self) -> RailHomeOutcome            # 09d: MOTION, caller's thread, ≤ 30 s + reads
    def set_target(self, pos_m: float) -> None   # thread-safe, latest-wins; DROPPED unless READY
    def step(self) -> None                       # 5 Hz on monitor thread; no-op while homing
    pos_m: float; pos_known: bool; homing: bool; phase: RailPhase   # properties

@dataclass(frozen=True)
class RailHomeOutcome:           # judged from the REGISTERS, never from SDK return codes
    ok: bool; detail: str; written: bool = False      # written False = refused, nothing moved
    phase: str = "ABSENT"        # RailPhase.name after the attempt
    on_zero: int | None = None; is_enabled: int | None = None; error: int | None = None
    pos_m: float | None = None   # seeded position when ok (0.0); None = still unknown
    sdk_codes: dict[str, int] | None = None; duration_s: float = 0.0
```

`detect()`: present = `get_linear_track_registers()` code == 0 AND the reply
is a real register dict (absent → code 3 timeout / 20 host-id / 23
modbus-length; a controller in simulation mode never touches the bus and the
SDK returns `(0, [])` → absent). The AL13x SN prefix is checked only when the
SDK exposes `get_linear_track_sn` — **SDK 1.18.5 does not**: `XArmAPI` has
`get_linear_track_registers/pos/status/error/is_enabled/on_zero`,
`set_linear_track_*`, `clean_linear_track_error` (alias map
`wrapper/xarm_api.py:120-133`) and `get_linear_motor_registers`, but no
`get_linear_track_sn` / `get_linear_track_version` (`__getattr__` raises
`AttributeError`; `rail.py:77` did exactly that on the first real connect,
fixed 2026-09-04). Without the SN API `detect()` records one warning
(`rail.warnings` → `connect_warnings` → `ArmBringupStatus.warnings`) and
accepts the track on the registers alone.

**Rail facts measured read-only 2026-09-04 (both arms identical):**
`get_linear_track_registers` → `{pos: 0, status: 2, error: 0, is_enabled: 0,
on_zero: 0}` — the tracks are NOT homed and NOT enabled, so `pos` is
meaningless (the Manipulation Arm's carriage is physically at the operator's
right end ≈ sim q 0.65 while its register reads 0). `pos` becomes a position
only after `on_zero == 1` AND `is_enabled == 1`; the read-only monitor (§8.5)
reports `rail_pos_m = None` until then and `rail_raw_mm` always. Both tracks
were homed for the first time on 2026-09-05 (operator-triggered `home_rail`,
phase-09c).

**Homing is MOTION and the driver never issues it (phase-09c).**
`set_linear_track_back_origin` drives the carriage to the track's zero end
(the operator's LEFT, +X). Since the carriage position is unknown until the
track is homed, the twin cannot gate an unhomed arm — so homing must happen
BEFORE a session, explicitly: the operator presses "Home rail" on the
Hardware tab, the runtime checks a full-travel sweep of the twin at the arm's
CURRENT posture, and only then the read-only monitor executes the `home_rail`
maintenance op (§8.6) — the ONE maintenance op that moves anything. Homing is
required once per power-on (commanding an unhomed track returns APIState 82).
`require_homed()` (connect, §3.2 step 4): `get_linear_track_registers` →
`on_zero == 0` → `RailNotHomedError` (core `errors.py`, `step="rail"`), phase
stays `DETECTED`, nothing written; `on_zero == 1` → `set_linear_track_enable(True)`
+ `set_linear_track_speed(speed_mm_s)` (non-motion) → `pos_m` seeded from the
register (`get_linear_track_pos` after the enable) → `READY` + `RailEvent`
"rail ready at X m". A failing register read, or a non-zero enable / speed
code → `RAIL_ERROR` + `BringupError(step="rail")`: the connect is REFUSED
(`rail: "error"` + `error`; the runtime 409s) — a carriage of unverifiable
position must never be gated at a guessed 0.0 m (review fix 2026-09-05; before,
connect continued). `RailPhase.HOMING` no longer exists.
`step()` (only in `READY`): poll `get_linear_track_pos()` → `pos_m`; if new target and
`|Δ| >= 1 mm` → `set_linear_track_pos(units.rail_m_to_mm(target),
wait=False)` (absolute int mm, clamped [0, 650]); nonzero track error →
`clean_linear_track_error()` once + re-enable, repeated → `RAIL_ERROR` +
`RailEvent`. Teleop rail keys (←/→) arrive as the rail slot of
`command_joints`; ~5 Hz absolute re-targeting is smooth — the track plans
its own motion at `rail_speed_mm_s`. `set_target()` DROPS (does not queue) a
target unless the track is `READY` and not homing (09d): a target parked while
the track was not commandable must never fire the moment it becomes so.

**Connecting with an unhomed track — `rail_homing: "allow_unhomed"` (phase-09d,
maintenance motion ONLY).** When the arm's CURRENT posture does not clear the
whole rail travel, the runtime's rail-homing job must first move the arm along
a twin-planned, rail-position-agnostic path, which needs a connected driver
BEFORE the track is homed. `require_homed(allow_unhomed=True)` (set by
`XArmDriverConfig.rail_homing == "allow_unhomed"`, which the job puts on its
speed-scaled driver config; normal sessions keep the default `"require_homed"`
and are refused exactly as before) accepts `on_zero == 0` with still NOTHING
written: phase stays `DETECTED` (never commanded — the rail slot of
`command_joints` is dropped silently so the loop's hold target keeps flowing,
an explicit `command_rail` raises `CommandError`), `pos_known == False`, one
`connect_warnings` entry + one `RailEvent(DETECTED)` "position UNKNOWN".
`dof` stays 8 and `ArmState.q[7] == rail_pos_m == UNKNOWN_RAIL_POS_M (0.0)`:
core's `ArmState` requires a finite `q[7]` equal to `rail_pos_m`, so
NaN/None cannot be published — **the 0.0 is a PLACEHOLDER, not a measurement;
consumers MUST check `XArmDriver.rail_position_known`** (the runtime job feeds
the twin its own fallback and validates the path for all 131 rail positions).
0.0 is also the zero end the homing drives to, so a hold target the loop
derives from the published state is motionless once the track is homed.
`ArmBringupStatus.rail == "unhomed"` with `connected == True` and no `error` is
this state (§9). An unreadable track still refuses the connect (it could not be
homed either).

**Homing on a connected driver — `XArmDriver.home_rail() -> RailHomeOutcome`
(phase-09d).** Called by the runtime's rail-homing job on ITS OWN thread after
the pre-positioning motion finished, while the 100 Hz servo stream keeps
holding the joints; blocks ≤ `HOME_RAIL_SDK_WAIT_S` (30 s) + a few register
round-trips. Driver-level refusals (`written False`, nothing moved): not
connected → `CommandError`; no track → `RailUnavailableError`; driver not
`STREAMING` (FAULT / LATCHED: the stream is not holding the joints) or a
controller error cached by the monitor poll → refused outcome. Then
`RailController.home()`: raise the `homing` latch (under `_lock`; the pending
target is dropped) → take `_io_lock` once as a barrier so a `step()` already on
the bus finishes (every later `step()` sees the latch and returns without any
SDK call) → pre-read `get_linear_track_registers` (unreadable → failed,
`RAIL_ERROR`; a latched track `error != 0` → REFUSED, zero writes) →
`set_linear_track_back_origin(wait=True, timeout=HOME_RAIL_SDK_WAIT_S,
auto_enable=False)` → `set_linear_track_enable(True)` →
`set_linear_track_speed(speed_mm_s)` (the job's config is speed-scaled, so
5 mm/s at 10 %) → register read-back, **judged from the registers only**
(`on_zero == 1 and is_enabled == 1 and error == 0`; the three SDK codes are
kept in `sdk_codes` — 1.18.5 returns 0 for a homing that did not finish and
nonzero for one that did). Success: `pos_m` seeded from the register (0.0),
`pos_known True`, target + last-sent cleared, `READY`, `RailEvent(READY)`
"rail homed: carriage at 0.000 m, …"; the track is commandable again for a
FRESH target — the driver does no re-anchoring of the loop's target on its
own. Failure: `RAIL_ERROR` + `RailEvent`, position still UNKNOWN (`pos_m None`
in the outcome, `rail_position_known False`), the ARM unaffected (still
streaming). Re-homing a `READY` track is allowed. `RailEvent`s are emitted
both by `home_rail()` itself (so the caller sees them right after it returns)
and by the 5 Hz monitor tick (lock-protected drain, no double emission). The
SDK's per-instance command lock serialises the homing's modbus calls with the
streamer's `set_servo_angle_j`; the SDK homing wait is a 10 Hz register poll,
not a held lock, so the stream is not starved. After the homing the runtime
tears the driver down as usual (§3.6 D6: stopped + braked, posture kept, track
left homed + enabled) — there is no automatic "return to the previous posture".
The monitor-path `home_rail` op (§8.6, joints braked, session-less) is unchanged.

## 6. Controller-side safety backstops (`backstops.py`)

Layer 3 of overview §6 — controller-enforced limits under the twin gate
(the controller knows nothing about other arms or the rail).

**Parameters come from the core `ArmConfig`** (phase-09b): `tcp_load_kg`,
`tcp_load_cog_mm`, `collision_sensitivity` (0..5, default 3),
`reduced_tcp_boundary_mm` (optional `[x_max, x_min, y_max, y_min, z_max,
z_min]`, None = reduced mode off) and `expected_sn`, mapped field-for-field
into `XArmDriverConfig` by `workcell._driver_cfg` (an older core without the
three new fields keeps the driver defaults). `expected_sn` stays None in the
lab: `arm.sn` reads the model code `XS1305` on BOTH boxes (2026-09-04), so the
NIC ↔ profile mapping (§7) is the check against swapped cables, since `arm.sn`
cannot be. The lab values are in the runtime's
`configs/mavis_v2.yaml` and are estimates the user accepted on 2026-09-05 without weighing (whole-arm collision detection is what matters to the lab):
Manipulation Arm (G2 + D435i 0.072 kg + mount) ≈ 0.95 kg at (0, 0, 60) mm,
Perception Arm (D435i 0.072 kg + RØDE NT-USB Mini ≈ 0.35 kg + mount) ≈ 0.55 kg
at (0, 0, 90) mm, sensitivity
3 on both. As found on 2026-09-04 both boxes reported `tcp_load` 0 kg and
sensitivity 3 (grip) / 1 (view) — wrong for torque-estimate collision detection,
hence the operator-facing `apply_backstops` maintenance op (§8.6).

`apply_backstops(api, cfg, codes=None) -> list[str]` runs at every connect
(§3.2 step 3) and on an explicit monitor maintenance request (§8.6); it
returns non-fatal warnings (`"<call> returned <code>"`) and, when `codes` (a
dict) is passed, records every SDK return code by call name in call order.
Order (`BACKSTOP_SDK_METHODS`; `expected_backstop_sequence(cfg)` drops the two
reduced-mode calls when no boundary is configured):
(1) `set_tcp_load(cfg.tcp_load_kg, list(cfg.tcp_load_cog_mm))` +
`set_gravity_direction([0, 0, -1])` **first** — collision detection is
torque-estimate based, wrong payload = false pos/negatives;
(2) `set_collision_sensitivity(cfg.collision_sensitivity)` — volatile,
re-applied every connect; never `save_conf()` (controllers stay config-clean);
the operator may OVERRIDE this one at run time (below);
(3) `set_self_collision_detection(True)` + `set_collision_tool_model(1)`
classic / `(9)` G2 / `(0)` none;
(4) optional reduced mode (off by default): `set_reduced_tcp_boundary(mm)`,
then `set_reduced_mode(True)` **last**;
(5) `set_collision_rebound(False)` — stop-and-latch, not bounce
(C22/C31/C35 = RECOVERABLE with budget, §3.5).

**Read-back.** SDK 1.18.5 has no `get_tcp_load` / `get_collision_sensitivity`;
`XArmAPI.tcp_load` (`[kg, [x, y, z] mm]`) and `XArmAPI.collision_sensitivity`
are properties filled by the SDK report thread from bytes 115..132 of the
`normal`/`rich` report frame (`x3/base.py:1635-1636, 1784-1787`) — NOT from
the `real` 30003 stream the session driver uses, so the driver cannot read them
back; the monitor (§8.5, SDK default `report_type='rich'`) reports them every
slow round as `collision_sensitivity`, `tcp_load_kg`, `tcp_load_cog_mm`, and
the runtime compares them with the config (`backstops_match`). The values are
volatile: a controller reboot drops them, the next connect re-applies them.

**Operator override of the collision sensitivity (2026-09-11, operator
decision).** `set_collision_sensitivity(api, level, codes=None) -> list[str]`
is the level override: exactly ONE write, `api.set_collision_sensitivity(level,
wait=False)` — the step-(2) call with the operator's level instead of
`cfg.collision_sensitivity` — recorded under `"set_collision_sensitivity"` in
`codes`, a non-zero code returned as the one warning string. `level` must be in
`COLLISION_SENSITIVITY_LEVELS = {1, 2, 3}` (`ValueError` otherwise; 0 turns
detection off, 4 / 5 false-trigger under payload — the monitor, the driver and
core's `ArmMaintenanceRequest` all refuse the rest first). Two callers, one
helper: the session-less monitor op `set_collision_sensitivity` (§8.6, the
Hardware-tab arm card) and, inside a session, `XArmDriver.
request_set_collision_sensitivity(level)` (the Cockpit control): flagged under
`_phase_lock` like `request_recovery`, consumed by the 5 Hz `_MonitorThread.
step()` (step 0b, after a pending recovery), the outcome published as
`SettingResult(seq, ok, code, level, t_mono, detail)` via
`XArmDriver.setting_result()` / `HardwareWorkcell.setting_result(arm_id)`
(`HardwareWorkcell.request_set_collision_sensitivity(arm_id, level)` is the
sibling channel of `request_recovery`, so the runtime's wrapped workcell
forwards it unchanged). The driver never touches its phase, budget or streamer
for it, and it cannot read the value back (§6 read-back: the `real` 30003 stream
carries no sensitivity) — so `ok` there means the SDK accepted the write: code 0,
or a **status echo** (`STATUS_ECHO_CODES` 1 / 2 / 9, now defined in
`backstops.py` and imported by both `monitor.py` and `driver.py`) with `detail`
saying so; the read-only monitor verifies the value the next time it holds the
box. **The override is as volatile as the rest: the config value (3 on both lab
arms) is re-applied at EVERY connect by `apply_backstops`**, which is the
operator's chosen default — lower it to 2 / 1 for a task (the fridge door's
C31, §3.5 / §16), and a fresh session starts from 3 again; the UI shows the
controller's read-back, never the value it asked for.

SDK 1.18.5 facts behind both callers (`x3/xarm.py:955-964`, verified
2026-09-11): `set_collision_sensitivity(value, wait=True)` IGNORES `wait` — it
first runs `wait_move()` (`base.py:2508`: returns at once when `mode != 0`, i.e.
for the session driver's servo mode 1, and when an error is latched; on a
stopped mode-0 arm it polls `get_state` ~10 times, ≤ 0.5 s — the monitor path),
then `set_collis_sens(value)`, then an unconditional `set_state(0)`, and returns
the RAW uxbus code without `_check_code` (hence the status echoes). None of it
commands motion: `set_state(0)` is idempotent for a streaming arm, refused by the
controller while an error is latched, and on a user-stopped arm (state 4, no
error) it only re-arms the state machine — no servo command follows because the
streamer is paused and the driver phase does not change. It is the same call
`apply_backstops` has always issued session-less (measured 2026-09-04: no joint
moved).

## 7. netsetup module (`netsetup/`)

### 7.1 API and data types

Subprocess + `nmcli -t`/`-g` only (NM 1.36.6; libnm/D-Bus rejected per
research §6). Every call runs with `LC_ALL=C`, addresses profiles **by UUID
only** (the machine has two profiles both named `xarm7_1`), passes
`-w 10..15` (default wait is 90 s).

```python
# nmcli.py
NmcliRunner = Callable[..., subprocess.CompletedProcess]   # test seam (§11)
def nmcli(*args: str, timeout: float = 20.0) -> subprocess.CompletedProcess: ...
    # run(["nmcli", *args], env={**os.environ, "LC_ALL": "C"}, capture_output=True)
def split_terse(line: str) -> list[str]: ...
    # split on unescaped ':' — literal colons come escaped '\:' (MACs!)
# types.py dataclasses: ArmNet(name, ip, prefix=24, host_ip=None -> .12 default),
#   NicInfo(dev, mac, state, carrier, connection), ProfileInfo(uuid, name, ifname,
#   autoconnect, method, addresses, gateway, never_default, mac_pin,
#   permissions -> .user_restricted),
#   MatchResult(arm, ifname, mac, profile_uuid, probe: "open|refused|unreachable",
#               detail="", reason: "" | no-mapping | nic-missing | profile-inactive |
#               unreachable | no-candidate), NicMapEntry(mac, ifname, profile_uuid,
#               arm_ip, ts)
class NetSetup:
    def __init__(self, arms: list[ArmNet],
                 state_path: Path | None = None,   # None -> resolve_state_path() (§7.4)
                 run: NmcliRunner = nmcli) -> None: ...
    state_path: Path                                 # property, resolved on every access
    def verify(self) -> dict[str, MatchResult]: ...  # fast path; raises NetSetupError
    def match(self) -> dict[str, MatchResult]: ...   # full probe (§7.2), persists state
    def repair(self, deadline_s=60, poll_s=5, holdoff_s=600) -> dict[str, MatchResult]
                                                     # dispatcher mode (§7.4)
    def reconcile(self, apply: bool = False) -> ReconcilePlan: ...  # §7.3
    def status(self) -> list[NicInfo]: ...           # landing-page network health
    install_problems: list[str]   # verify(): polkit/dispatcher/permissions warnings
    warnings: list[str]; notes: list[str]            # match()/repair() decision trail
```

Live profiles (2026-09-04): `mavis_manipulation_arm` = 192.168.1.11/24 on
`enp36s0f1` → Manipulation Arm box 192.168.1.201; `mavis_viewpoint_arm` =
192.168.2.12/24 on `enp36s0f0` → Perception Arm box 192.168.2.219. The `.12`
default above applies only to profiles netsetup creates itself; the
manipulation profile was created by hand at `.11`.

State file (`state.py`): `USER_STATE_PATH = ~/.config/apollo-mavis-v2/nic_map.json`,
`SYSTEM_STATE_PATH = /etc/apollo-mavis-v2/nic_map.json` (root-written by the
dispatcher / `install`); precedence in §7.4.

Denylist (`probe.py::internet_devices`): devices of the lowest-metric
default route (`ip -j route show default`) plus every non-`ethernet` NM
type (covers `wlp38s0`, `tailscale0`); hard-coded exclusion from every
mutating path; never `networking off` / `radio wifi off` / disconnect.

### 7.2 verify / match algorithm

`verify()` (every session start, no root, ~1 s healthy): load
`nic_map.json`; per arm resolve stored **MAC** → current ifname (names
drift; MAC is stable), check the stored profile UUID exists and is active
on that ifname, then probe P. Any miss → `bring_up` runs `match()`.

`match()` runs serialized, one arm at a time (profiles are single-active;
probing a profile on NIC2 silently detaches it from NIC1).
1. `subnet = ip_network(f"{arm.ip}/{arm.prefix}", strict=False)`; pick (by
   UUID) an ethernet profile with `ipv4.method == manual` and a static
   address in the subnet (host part ≠ arm.ip); none → create (+ read UUID):
   `nmcli connection add type ethernet con-name apollo-{arm} ifname "*"
   connection.autoconnect no ipv4.method manual ipv4.addresses {host_ip}/24
   ipv4.never-default yes ipv4.gateway "" ipv6.method disabled`.
2. If at least one candidate NIC exists, clear **both** pins in one `modify` —
   `connection.interface-name ""` and `802-3-ethernet.mac-address ""` (a profile
   pinned to devA cannot activate on devB; a MAC pin alone would make a cable
   swap un-matchable forever). No candidate (no carrier anywhere) → pins stay,
   so NM autoconnect still re-activates the profile on re-plug.
3. Pool: ethernet devices, carrier on (`/sys/class/net/<dev>/carrier`;
   carrier-off = NM state 20, `con up` fails fast), not denylisted, not
   mapped. Per candidate: `nmcli -w 15 connection up uuid <UUID> ifname
   <dev>`; rc != 0 → next; else probe P; no-match → `nmcli -w 10 connection
   down uuid <UUID>` (release the NIC).

Probe P (`probe.py`, unprivileged): `ping -c1 -W1 -I <dev> <ip>` retried 3×
(first packet routinely lost to ARP), cross-check `ip neigh show <ip>` is
REACHABLE/STALE not FAILED/INCOMPLETE; then
`socket.create_connection((ip, 502), timeout=1.0)`, close immediately,
**write nothing** (502 is the live SDK control channel). connect OK →
`open`; ECONNREFUSED + ping OK → `refused` (right NIC, box booting ~1–2 min
— poll 502, do NOT re-probe NICs); timeout/no-ARP → `unreachable` (wrong
NIC). On success persist `{arm: NicMapEntry}` and run `reconcile(apply=True)`
so the next boot is deterministic (autoconnect does the work).

### 7.3 reconcile (one-time cleanup) and install

`reconcile(apply=False)` returns a `ReconcilePlan` (nmcli commands +
reasons); `apply=True` executes. It **never touches a currently active
profile carrying SDK traffic** nor denylisted devices. Per mapped arm
profile — pin `connection.interface-name <dev>` +
`802-3-ethernet.mac-address <mac>` (MAC survives ifname renames),
`connection.autoconnect yes`, `autoconnect-priority 50`; route hygiene —
`ipv4.never-default yes`, `ipv4.gateway ""`, `ipv6.method disabled`, force
`ipv4.method manual` (DHCP on an arm NIC hangs ~45 s/cycle), and
`connection.permissions ""` (system-wide, §7.4). Per stale/duplicate profile in
a **mapped** arm's subnet: `connection.autoconnect no` (`--delete` for hard
removal). Arms without a persisted mapping are skipped entirely — with no
keeper nothing is a duplicate, so `reconcile --apply` before `match` is
harmless (2026-09-04 live regression: the plan wanted to disable both working
profiles). **Known pollution the plan must fix**
(regression fixture §11): (a) two `xarm7_1` profiles, different UUIDs/IPs →
keep the matched one, disable the other; (b) `xarm7_1`/`xarm7_2` carry
`ipv4.gateway 192.168.1.1` (xarm7_2's outside its own subnet), source of the
bogus `default via 192.168.1.1 dev enp36s0f0 metric 20100` route → strip.

`install` (one-time; prints the sudo commands, asks confirmation): Ubuntu
22.04 polkitd 0.105 = LocalAuthority backend only, JS `.rules` **ignored**;
headless/SSH needs the `.pkla` grant — write
`/etc/polkit-1/localauthority/50-local.d/46-apollo-networkmanager.pkla` with
`Identity=unix-group:netdev`, `Action=org.freedesktop.NetworkManager.network-control;org.freedesktop.NetworkManager.settings.modify.system`,
`ResultAny/ResultInactive/ResultActive=yes` (exact file: research
`network-manager.md` §10), plus `sudo usermod -aG netdev $USER` (re-login;
polkitd watches the dir; `$USER` = `SUDO_USER` when install itself runs under
sudo). It further creates `/etc/apollo-mavis-v2/` (`install -d -m 755`),
installs the dispatcher hook (`install -D -m 755 <rendered>
/etc/NetworkManager/dispatcher.d/90-mavis-netsetup`, §7.4) and — if every arm
answers TCP 502 — runs `sudo <venv python> -m apollo_mavis_v2_hardware.netsetup
match --state /etc/apollo-mavis-v2/nic_map.json --arm …` once, so the system
map exists and both profiles are pinned before the operator is even in
`netdev`. `--dispatcher-only` = dir + hook only; `--check` (read-only) verifies
grant + group + hook (present, executable, equal to the rendering when arms are
given); `verify()` runs the same check so a missing piece becomes an actionable
landing-page warning, not a mid-bring-up failure. `install_commands()` /
`plan_install()` return the exact sudo lines, printed before execution.

### 7.4 Boot / hot-plug automation: NM dispatcher (`dispatcher.py`)

Pins + `autoconnect yes` make NetworkManager alone do the right thing at boot
and when a cable returns to the *same* NIC. Two cases need a re-probe: a cable
**swap** (both profiles auto-activate on their pinned NICs with the wrong arm
behind each) and a cable **moved** to another NIC. Neither may depend on a
user being logged in, so the hook runs as **root** from
`/etc/NetworkManager/dispatcher.d/90-mavis-netsetup` (rendered by
`render_dispatcher(python, arms, state)`, installed by `netsetup install`):

- NetworkManager-dispatcher(8) calls it for every device event (`$1` iface,
  `$2` action; env `CONNECTION_UUID`/`CONNECTION_ID`). It handles only
  `up`/`down` of **physical ethernet** devices — sysfs `type == 1`
  (ARPHRD_ETHER), a `device` symlink (PCI/USB; bridges, veth, tap, tun, lo have
  none), no `wireless`/`phy80211`, no `bridge`. Everything else exits 0
  silently (on this machine: selects `enp36s0f0`, `enp36s0f1`,
  `enx00e04c683d97`; rejects `wlp38s0`, `docker0`, `br-*`, `virbr0`,
  `tailscale0`, `lo`).
- It returns immediately (NM kills slow scripts): the worker is re-exec'd with
  `setsid -f` (own session, stdio to the log), sleeps `SETTLE_S = 2`, then runs
  `flock -w 600 /run/lock/mavis-netsetup.lock <venv python> -m
  apollo_mavis_v2_hardware.netsetup match --repair --state
  /etc/apollo-mavis-v2/nic_map.json --arm view=192.168.2.219 --arm
  grip=192.168.1.201` (arm args baked in at install time from
  `--arm`/`--config`). Log `/var/log/mavis-netsetup.log` (fallback `logger -t
  mavis-netsetup`). Missing venv python → one log line, exit 0. Env overrides
  `MAVIS_NETSETUP_{LOCK,LOG,SETTLE_S,SYSFS_NET}` serve tests / manual runs.
- Root needs no polkit grant, so this path works before `install`'s
  `.pkla`/`netdev` steps take effect and when nobody is logged in.

**`match --repair` = `NetSetup.repair()`.** The hook must not run the plain
`match`: every `nmcli connection up/down` it issues emits new `up`/`down`
events (feedback loop), and probing an arm on the *other* arm's NIC kicks a
healthy profile off it. Policy (`match.classify_for_repair`):

1. `verify()`; arms that pass are **frozen** — their NICs are never candidates.
   All OK → zero nmcli mutations → no new events (the loop terminator).
2. `no-mapping` / `nic-missing` → re-probe now.
3. `profile-inactive`, stored NIC **without carrier** (unplugged / box off) →
   nothing to match; NM autoconnect re-activates the pinned profile on
   re-plug. Exception: a *free* NIC (ethernet, carrier, unmapped, not frozen)
   exists → re-probe on the free NICs (cable moved). Stored NIC **with**
   carrier → re-probe (a foreign profile grabbed it / autoconnect blocked;
   `match` re-activates it).
4. `unreachable` (profile active on its NIC, probe fails) → **pending**: the
   box may be booting (link is up seconds before its IP stack). Poll `verify`
   every `REPAIR_POLL_S = 5` s up to `REPAIR_DEADLINE_S = 60`; still failing →
   re-probe (swap suspected), but at most once per `REPAIR_HOLDOFF_S = 600`
   (stamp `nic_map.holdoff` beside the state file) so a silent box does not
   cause periodic down/up churn.
5. Re-probe = `match(targets, frozen=…)` (pins cleared, serialized per §7.2).
   Targets that still find no NIC are put back on their stored NIC
   (`connection up uuid <U> ifname <dev>`) — things are left as found.
6. `reconcile(apply=True)` last: re-pins (both pins are cleared by `match`),
   clears `connection.permissions`, route hygiene. `connection modify` on an
   active profile does not re-activate it, so live SDK traffic is untouched.

`MatchResult.reason` carries the structured miss cause; `NetSetup.notes`
records the decisions (printed by the CLI, hence in the hook's log).

**State-file precedence** (`state.resolve_state_path`): explicit `--state` >
`~/.config/apollo-mavis-v2/nic_map.json` if it exists >
`/etc/apollo-mavis-v2/nic_map.json` if it exists > the user path (write
default). The hook and `install` always pass `--state /etc/…` (dir `0755`
root, file `0644`), so every account's `verify()` — the runtime's
session-start fast path — reads the root-written map with no plumbing. A user
`match` that resolved to the read-only system map falls back to the user map
(warning), which then shadows it.

**Permissions.** NM profiles are keyfiles in
`/etc/NetworkManager/system-connections/*.nmconnection` (root, `0600`), shared
by **all accounts** and root services unless `connection.permissions` is set
(`user:<name>:;`) — then only that user (not the root dispatcher) can activate
them. `verify()` warns for a mapped profile that is user-restricted;
`reconcile` clears the property. Both live MAVIS profiles are unrestricted.

## 8. Camera backends (`cameras/`)

Implements `core.CameraInterface` (LeRobot-style Camera ABC: background
capture thread + lock-protected latest-frame slot). Frames standardized at
the boundary: RGB `np.ndarray (H, W, 3) uint8` + monotonic timestamp;
BGR→RGB once, in the capture thread. `OpenCVCamera` (kind `v4l2`,
device_path) and `RealSenseCamera` (kind `realsense`, serial) implement
`start()`, `stop()`, `latest() -> CameraFrame | None` (non-blocking; None if
stale), static `find_cameras() -> list[dict]`; `make_camera(cfg)` dispatches
on the tagged-union `CameraConfig`; `find_all_cameras()` merges both
backends with RS-first dedup and feeds `GET /api/cameras`.

OpenCVCamera: open by **path**, never index — `device_path` (an explicit
node or a stable `/dev/v4l/by-path/...` / `by-id/...-video-index0` symlink)
or, when `CameraConfig.serial` is set instead, resolved through sysfs
(`v4l2_nodes_by_usb_serial`: `/sys/class/video4linux/videoN/device` → the USB
interface directory whose parent holds `serial`; capture nodes only
(`index == 0`), ordered by `bInterfaceNumber`, each tried until one honours
the requested format). The serial route exists because a RealSense D435i
exposes its depth (interface 0) and colour (interface 3) sensors as separate
UVC interfaces that BOTH claim `...-video-index0`, so udev keeps one by-id
symlink per name and the winner changes between plugs (observed 2026-09-04 on
the MAVIS cell — never address the wrist cameras by by-id). The D435i enumerates as USB
`8086:0b3a` (`lsusb -d 8086:0b3a` shows both units); on the lab host the two units hang
off different USB host controllers — 349643062582 on PCI 29:00.3 (USB bus 6),
322143060792 on PCI 29:00.1 (USB bus 4). **Cold-boot wake**: after a
reboot a D435i's colour UVC interface delivers no frames at all (`select() timeout` on
every read; observed 2026-09-04, kernel 7.0.11, firmware 5.15.1 / 5.17.0.10 — ASIC
243522071002 = fw 5.15.1 (`view_wrist`), 327122074467 = fw 5.17.0.10 (`grip_wrist`)) until
librealsense has opened the device once. Before the first RealSense node (USB
`idVendor` 8086, read from sysfs) is opened, `OpenCVCamera` calls `wake_realsense()`,
which runs `rs-enumerate-devices -s` (librealsense2-utils) once per process — the tool
queries and releases the devices in about a second and the colour streams work
afterwards. A missing tool is logged once and the open proceeds (a cold-booted D435i
then ends in `failed` = black tile, nothing crashes).
`cv2.VideoCapture(path, cv2.CAP_V4L2)` with `cv2.setNumThreads(1)` first.
Configure in order, **verifying each set() by read-back** (V4L2 silently
clamps): `CAP_PROP_FOURCC = cfg.fourcc` first (default `MJPG` — UVC webcams
reach 30 fps at 640×480+ only in MJPG; the D435i colour stream is `YUYV`
only), then FPS, then W/H; mismatch → `CameraInitError` (core §16). Capture
thread: 5 consecutive `read()` failures → release + reopen once, then mark
failed (UI greys the tile) — never crash the workcell. Enumeration: glob
`/dev/v4l/by-id/*-video-index0` (fallback `/dev/video*`) + one test `read()`
per node (the odd per-UVC metadata node opens but yields no frames).

RealSenseCamera (import-guarded, `[realsense]` extra): by serial —
`rs.config.enable_device(cfg, serial)`, `enable_stream(rs.stream.color, w,
h, rs.format.rgb8, fps)` (already RGB); optional `depth: bool` (z16, v1
ignores); ≥1 s warmup; `device.hardware_reset()` retry for the "wedged after
unclean shutdown" failure (both from LeRobot). **V4L2-ghost dedup** in
`find_all_cameras()`: query RealSense serials first, exclude those USB
devices from the OpenCV list (RS color sensors also appear as `/dev/video*`;
match by-id symlinks containing `Intel_RealSense` or the RS USB bus/dev).
Pre-session preview: cameras start **before** any session (landing page
shows real streams at reduced ~15 fps per the binding video protocol), so
`start_cameras()` is independent of arm bring-up.

## 8.5 Read-only state monitor (`monitor.py`, phase-09a)

Session-less view of the real cell for the runtime (`telemetry.hardware_monitor`,
the Welcome page's error chips, the digital-twin overlay streams `*_align`).
One `ArmStateMonitor` per arm; **it never commands the controller on its own —
zero writes unless an explicit maintenance request (§8.6)**.

```python
ArmMonitorStatus = Literal["off", "connecting", "running", "stale", "paused", "error"]

@dataclass(frozen=True)
class ArmMonitorSample:            # data part of core ArmMonitorTelemetry + t_mono
    arm_id: str; seq: int; t_mono: float
    q: tuple[float, ...]           # 7 rad, controller order (identity to the twin)
    tcp_pose: tuple[float, ...]    # [x, y, z m, roll, pitch, yaw rad], FLANGE (tcp_offset 0;
                                   #   RPY extrinsic XYZ; the TCP = ArmState.ee_pose, not this)
    error_code: int = 0; warn_code: int = 0
    state: int | None = None; mode: int | None = None
    rail_present: bool | None; rail_homed: bool | None; rail_enabled: bool | None
    rail_pos_m: float | None       # None unless on_zero == 1 AND is_enabled == 1
    rail_raw_mm: float | None      # raw register, always when present
    gripper_open_frac: float | None; gripper_raw: float | None  # None for "none"
    collision_sensitivity: int | None  # phase-09b read-backs, slow rounds (§6):
    tcp_load_kg: float | None          #   XArmAPI.collision_sensitivity / .tcp_load
    tcp_load_cog_mm: tuple[float, ...] #   properties (rich report frame); () until read

class ArmStateMonitor:
    def __init__(self, arm_id, ip, *, gripper: Literal["xarm", "xarm_g2", "none"],
                 expect_rail: bool, poll_hz=10.0, stale_s=0.5, reconnect_s=2.0,
                 api_factory=None, clock=time.monotonic) -> None: ...
    def start(self) -> None                      # daemon thread, reconnects itself (waits for
                                                 #   a previous thread still leaving the SDK)
    def stop(self, timeout=2.0) -> bool          # release the box; status "off"; True = released
    def disconnect(self, timeout=2.0) -> bool    # release the box; status "paused" (hand-over)
    def join(self, timeout=None) -> bool         # wait for the poll thread (late release)
    def snapshot(self) -> ArmMonitorSample | None
    def maintenance(self, op: MaintenanceOp, driver_cfg: XArmDriverConfig | None = None,
                    timeout_s: float = 10.0) -> MaintenanceOutcome   # §8.6
    maintenance_busy: bool                       # a request is queued / executing
    status: ArmMonitorStatus; detail: str; age_s: float | None; connected: bool
```

- **Connection**: `XArmAPI(ip, is_radian=True, do_not_open=True)` then
  `connect()` (SDK defaults otherwise, i.e. the `rich` report stream on 30002
  stays on so the `state`/`mode`/`tcp_load`/`collision_sensitivity` properties
  are live). Thread `hw.{arm_id}.monitor-ro` polls
  at `poll_hz`: `get_servo_angle(is_radian=True)`, `get_position(is_radian=True)`
  (mm → m via `units`), `get_err_warn_code()`, `api.state`, `api.mode`; every
  ≈2 Hz additionally `get_linear_track_registers()` (when `expect_rail`), the
  gripper reading — G2 through **the same call and conversion as
  `G2Gripper.poll()`** (`get_gripper_g2_position()` → `units.g2_mm_to_frac`),
  classic through `get_gripper_position()` → `units.pulse_to_frac`, `none` skipped —
  and the safety read-backs `api.collision_sensitivity` / `api.tcp_load` (§6).
  `detail` carries the SDK's error title (`controller error 19: End Effector
  Communication Error`), a controller warning, or read problems.
- **Zero writes unless an explicit maintenance request**:
  `monitor.READ_ONLY_SDK_METHODS = {connect, disconnect, get_servo_angle,
  get_position, get_err_warn_code, get_linear_track_registers,
  get_gripper_g2_position, get_gripper_position}` and `READ_ONLY_SDK_ATTRS =
  {connected, state, mode, collision_sensitivity, tcp_load}` are the complete
  list of `XArmAPI` members the polling touches; `MAINTENANCE_SDK_METHODS`
  (§8.6) is the complete per-operation write set. `tests/test_monitor.py`
  wraps the fake in a call-logging proxy and asserts that WITHOUT a request
  nothing outside the read lists is ever called (in particular no
  `motion_enable/set_mode/set_state/clean_error/clean_warn/set_*`) and the
  fake's state/mode/error are unchanged, that `clear_errors` writes exactly
  `[clean_error, clean_warn]` and `apply_backstops` exactly the `backstops.py`
  sequence in order — and nothing else either way.
- **Pause = disconnect**: a hardware session owns the boxes exclusively (two SDK
  clients on one control box are unevidenced). The runtime calls
  `disconnect()` before its session bring-up (status `paused`, last sample kept,
  the SDK client is torn down with exactly one `api.disconnect()`) and
  `start()` after teardown. `stop()` is the same with status `off`.
  **Hand-over guarantee under a slow `connect()`** (SDK 1.18.5 opens two
  sockets with their own timeouts and runs the version handshake — seconds on
  a flaky link, longer than the 2 s join budget): each `start()` bumps a
  generation counter and the poll thread publishes its client / status /
  samples only while it is the current generation AND `_running` holds (checked
  under the lock). If `stop()`/`disconnect()` return while the thread is still
  inside `connect()` they return **False** (box not yet released; a warning is
  logged) and the thread, on return, disconnects that client itself instead of
  adopting it — status stays `paused`/`off`, `connected` stays False, no poll
  happens; `join()` waits for that. `start()` after such a shutdown first joins
  the old thread (`STALE_THREAD_JOIN_S`), so a new client is never opened while
  the old one may still be connecting. `tests/test_monitor.py` covers all three
  (`connect_delay_s` on the fake): exactly one `disconnect` on the abandoned
  client, never published, status unchanged, one reconnect afterwards.
- **Failure**: any SDK exception → status `error` + detail, client released,
  reconnect after `reconnect_s` with exponential backoff (×2, capped at 10 s;
  reset on success). `connected` flipping to False on the SDK client counts as
  a failure. **Stale**: status `stale` (derived) when the newest sample is older
  than `stale_s` while nominally running — e.g. `get_servo_angle` returning a
  nonzero code (no sample that tick; the detail names the call and code — a
  failing `get_position` / err-warn / rail / gripper read is only appended to
  `detail` while the sample keeps the previous values) or a hung socket.
- **Read-only ≠ side-effect-free (SDK 1.18.5, verified in source)**: (a)
  `connect()` calls `clean_warn()` when a controller WARNING is latched
  (`x3/base.py:519-521`); (b) the first track/gripper register read runs
  `checkset_modbus_baud` (`x3/base.py:2581-2620`): if the controller's RS-485
  baud differs from the SDK default 2 000 000 the SDK WRITES the baud
  register, soft-reboots the end module (tool bus) and, should that raise
  C19/C28 (tool) or C111 (control-box bus), calls `clean_error()` +
  `set_state()`; at the factory baud nothing is written. `XArmAPI(...,
  baud_checkset=False)` would disable that path (a wrong baud then just fails
  the read) — the monitor keeps the SDK default so it reads through exactly the
  path `grippers.py`/`rail.py` use; (c) reads succeed (code 0) while a
  controller error is latched (`_check_code` maps ERR_CODE/WAR_CODE/
  STATE_NOT_READY → 0 for get-type calls) — the Perception Arm's C19 does not
  stop the monitor; (d) while `0 < error_code <= 17` the SDK stops refreshing
  its cached joints from the report stream, `get_servo_angle` still asks the box.

## 8.6 Maintenance channel (`ArmStateMonitor.maintenance`, phase-09b)

Operator-triggered, session-less controller maintenance for the UI's Hardware
tab ("Clear errors", "Apply safety settings", "Home rail", the collision-
sensitivity dropdown). Design rules: (a)
**nothing moves except `home_rail`** — `clear_errors` never enables (brakes
stay engaged; measured 2026-09-04: `clean_error()` on the Perception Arm
cleared C19 with ≤ 5e-5 rad joint change), enabling + servo mode (`recover`) is
refused here because it needs a session driver, and `home_rail` (phase-09c) is
the ONE op that moves a mechanical part — the track carriage — and is therefore
operator-triggered, twin-gated by the runtime and posture-checked here before
its first write; (b) **one `XArmAPI`, one thread** — the request is queued and
executed by the poll thread between polls, the caller only waits; (c)
**auditable** — the outcome lists every SDK return code in call order plus a
sample right before and right after the operation.

```python
MaintenanceOp = Literal["clear_errors", "apply_backstops", "recover", "home_rail",
                        "set_collision_sensitivity"]                    # 2026-09-11
MAINTENANCE_SDK_METHODS = {
    "clear_errors":    {"clean_error", "clean_warn"},          # in that order
    "apply_backstops": set(backstops.BACKSTOP_SDK_METHODS),   # §6 order, cfg-dependent
    "recover":         set(),                                  # refused: needs a session
    "home_rail":       {"set_linear_track_back_origin",       # MOTION: carriage -> zero end
                        "set_linear_track_enable", "set_linear_track_speed"},  # no motion_enable
    "set_collision_sensitivity": {"set_collision_sensitivity"},  # ONE write, the operator's
                                                                  #   level 1..3; no motion
}
DEFAULT_MAINTENANCE_TIMEOUT_S = 10.0; HOME_RAIL_SDK_WAIT_S = 30.0
HOME_RAIL_TIMEOUT_S = 45.0; HOME_RAIL_Q_TOL_RAD = 0.02

def maintenance(self, op, driver_cfg=None, timeout_s=None, *,
                expected_q=None, q_tol_rad=HOME_RAIL_Q_TOL_RAD,
                level=None) -> MaintenanceOutcome
    # timeout_s None -> per-op default (10 s; 45 s for home_rail)
    # level: set_collision_sensitivity only - 1 / 2 / 3, refused (ok=False) otherwise

@dataclass(frozen=True)
class MaintenanceOutcome:       # data part of core ArmMaintenanceResult (runtime adds path)
    arm_id: str; op: str; ok: bool; detail: str = ""
    sdk_codes: dict[str, int]   # SDK call -> return code, call order
    warnings: tuple[str, ...]   # apply_backstops non-fatal codes
    before: ArmMonitorSample | None; after: ArmMonitorSample | None
```

- **Execution** (poll thread): full slow poll → `before`; the op; for
  `apply_backstops` wait ≤ `BACKSTOP_READBACK_SETTLE_S` (0.5 s) until the rich
  report frame echoes the new sensitivity/payload (the `set_*` replies arrive
  before the ~10 Hz frame does); full slow poll → `after` (rail, gripper,
  sensitivity, payload refreshed at once); complete the request; back to polling
  without a sleep. `maintenance()` wakes the poll thread immediately instead of
  waiting out the current period.
- **Outcome**: `clear_errors` — `ok` iff neither code is a real failure AND
  `after.error_code == 0` (a controller error that re-latches right away — a
  persisting hardware fault — is reported as `ok=False`, "… re-latched right
  after clearing"). `clean_error` / `clean_warn` are the ONLY writes here that
  return the raw reply, skipping the SDK's `_check_code`
  (`x3/base.py:2394-2413`), so a box with something latched answers with the
  **status echo** `STATUS_ECHO_CODES = {1 ERR_CODE, 2 WAR_CODE, 9
  STATE_NOT_READY}` — the very codes `_check_code` maps to 0 for every non-move
  call. Those are not failures: judging on them reported "FAILED - clean_error
  returned 2" for the operator's **Clear errors** click on 2026-09-05 while the
  error HAD been cleared (the after-sample read `error_code` 0, §16). Like
  `home_rail`, the verdict comes from the READ-BACK; the codes stay in
  `sdk_codes` for diagnosis. Any other nonzero code (3 timeout, -1 not
  connected, …) still fails the op;
  `detail` names what was cleared (`cleared controller error 19: End Effector
  Communication Error and controller warning 11`) or says nothing was latched.
  `apply_backstops` — `ok` iff every code is 0 (`warnings` lists the nonzero
  ones; `detail` = "safety settings applied: sensitivity 3, payload 0.95 kg at
  (0, 0, 60) mm" [+ ", reduced-mode boundary on"], with a read-back note if the
  frame has not caught up yet).
  `set_collision_sensitivity` (2026-09-11) — one write
  (`backstops.set_collision_sensitivity(api, level, codes)`), then the same
  `_settle_backstops` wait generalised to a target level (`sensitivity=level`:
  the rich frame must echo that level; the payload is not part of this op), then
  the after-sample. **Judged from the read-back**: `ok` iff
  `after.collision_sensitivity == level`; the SDK code is diagnosis and — this
  call returns the RAW reply too (`x3/xarm.py:964`) — a `STATUS_ECHO_CODES` echo
  is not a failure ("… (set_collision_sensitivity returned 1: status echo, value
  verified by read-back)"), any other non-zero code is. `detail` = "collision
  sensitivity set to 2 (was 3; the config value 3 is re-applied at the next
  connect)" (`driver_cfg` is optional here and only names that config value);
  not ok = "collision sensitivity still reads 3 after writing 2" or, when a
  hand-over pre-empted the read-back, "collision sensitivity 2 written but not
  verified". The write set is exactly `{"set_collision_sensitivity"}`; nothing is
  enabled, nothing moves (§6 on the SDK's internal `wait_move` / `set_state(0)`).
- **`home_rail` (phase-09c) — the one motion op.** Request: `driver_cfg`
  (`rail_speed_mm_s`) + `expected_q` (the 7 joint angles the runtime's twin
  sweep was checked at; `q_tol_rad` default 0.02). Before-sample → refuse with
  ZERO writes unless: a track is present, `error_code == 0` ("… is latched;
  clear errors first"), track `error == 0`, and every joint is within
  `q_tol_rad` of `expected_q` ("the arm moved since the sweep was checked (joint
  4 differs by 0.050 rad, tolerance 0.02 rad); re-run the check"). Then exactly
  `set_linear_track_back_origin(wait=True, timeout=HOME_RAIL_SDK_WAIT_S,
  auto_enable=False)` — the SDK blocks until `on_zero` (or 30 s) —
  → `set_linear_track_enable(True)` → `set_linear_track_speed(cfg.rail_speed_mm_s)`
  (both non-motion, always issued once homing started) → one direct
  `get_linear_track_registers` read-back (taken even when a hand-over landed
  during the travel — the client is still the monitor's until the op returns)
  → after-sample. **Judged from the registers only**: `ok` iff that read-back
  says `on_zero == 1 and is_enabled == 1 and error == 0`; detail "rail homed:
  carriage at 0.000 m (register 0 mm), track enabled, positioning speed 50 mm/s"
  or "rail homing failed: on_zero still 0 (…), track not enabled, linear track
  error N (set_linear_track_back_origin returned 100)". The SDK return codes are
  reported, never trusted — **SDK 1.18.5 `auto_enable` masking**
  (`x3/linear_motor.py:131-148`, verified): `set_linear_motor_back_origin`
  waits (0 on `on_zero`, 80 track fault, 81 SCI low, 101 ten failed reads, 100
  timeout — and 100 as soon as `connected` drops) and then, when `auto_enable`
  (default True), OVERWRITES that result with `set_linear_motor_enable(True)`'s
  code, so a timed-out homing comes back as 0; the monitor's `auto_enable=False`
  keeps the wait code honest but the registers still decide. Re-homing an
  already homed track is allowed ("rail re-homed …": the twin sweep assumed an
  unknown start anyway). While the op runs the poll thread is inside the SDK
  wait: no sample is published, the arm's status reads **`stale`**,
  `maintenance_busy` is true — expected; the runtime refuses `POST /api/session`
  meanwhile. Caller timeout `HOME_RAIL_TIMEOUT_S` (45 s; the REST handler uses
  the same); a timed-out caller abandons the result but the op completes on the
  poll thread. `stop()`/`disconnect()` during a homing wait for the op up to
  `HOME_RAIL_TIMEOUT_S` (not the generic `STALE_THREAD_JOIN_S`) before
  releasing the client — the SDK wait loop exits on `connected == False` and
  whether the carriage then keeps travelling is unknown, so the monitor never
  disconnects mid-homing. Homing duration on the lab tracks is unmeasured; the
  track's own homing speed register has no public SDK setter (out of scope).
- **Refusals** (`ok=False`, no SDK call): `recover` ("recover needs a session");
  `set_collision_sensitivity` with `level` None / not an int / outside 1..3
  ("set_collision_sensitivity needs a level of 1, 2 or 3 (got 4); 0 turns
  detection off and 4 / 5 false-trigger under payload");
  `apply_backstops` / `home_rail` without a `driver_cfg`; `home_rail` without a
  7-vector `expected_q`, with `q_tol_rad <= 0`, or on a monitor that does not
  poll a rail; monitor `off` / `paused` / `connecting` / `error` ("not connected
  to <ip> (monitor paused: released for hand-over)"); unknown op → `ValueError`.
  On the poll thread, `home_rail` additionally refuses (zero writes; the sample
  it was judged on rides along as `before`) when the before-sample is not FRESH
  — `_poll` publishes nothing when `get_servo_angle` fails, so `before` would
  silently be the previous sample, equal to `expected_q` by construction,
  although the arm may have moved ("could not take a fresh sample of the arm
  (get_servo_angle failed)"; judged by `seq` against the newest sample before
  the re-read) or is older than `stale_s` (review fix 2026-09-05).
- **Failure paths**: an SDK exception inside the op completes the request with
  `ok=False` (`"clear_errors failed: Exception: …"`, codes so far) and the
  monitor treats the box as lost (client released, reconnect with backoff).
  Pending (queued) requests fail when the box is lost, when `stop()`/`disconnect()`
  run ("monitor paused: released for hand-over"), or when the monitor is
  superseded. A request already EXECUTING re-checks the hand-over between its
  SDK calls: if `stop()`/`disconnect()` landed during the before-sample it
  refuses with the same text and writes nothing; if the writes already went out
  it skips the after-sample and reports them (`after=None`, detail suffixed
  "(monitor paused: released for hand-over before the read-back)"). The shutdown
  itself never disconnects the client under a mid-write op — it waits for the op
  (bounded by `STALE_THREAD_JOIN_S`; `HOME_RAIL_TIMEOUT_S` for a `home_rail` in
  flight) before releasing the box, so a session driver taking over never finds
  the monitor still writing and no homing is cut mid-travel. A caller timeout
  (`timeout_s`, default 10 s / 45 s for `home_rail`)
  abandons the request: `ok=False` "… timed out …", the late result is dropped,
  polling continues. `maintenance_busy` is true while a request is queued or
  executing (telemetry `maintenance_busy`). `ArmMonitorSample.rail_error`
  (track error register, phase-09c) feeds both the `home_rail` pre-check and
  its judge.

### 8.7 Read-only connect and RealSense depth (phase-12, 2026-09-08)

`XArmDriver.connect(readonly=True)` enters `DriverPhase.READONLY`: one SDK
client, the report callback plus a `_ReadonlyPoller` restricted to
`READONLY_ALLOWED_SDK_METHODS` (`get_err_warn_code`,
`get_linear_track_registers`, gripper position reads,
`register_report_callback`, `disconnect`) — no enable, no mode / state writes,
no motion. It feeds the runtime's idle `arm_state` publisher between sessions
(`dora.publish.idle_source: driver`; the default `monitor` reuses the read-only
hardware monitor). Verified against the FakeSDK only, never on the boxes.
RealSense: `CameraConfig.depth` opens the depth stream and
`align_depth_to_color` aligns it; the runtime publishes it as
`cam_<id>_depth` (uint16 mm). The lab cameras are plain UVC colour (`kind:
v4l2`), so hardware depth is unverified on the real D435i (14-dora §16).

## 9. HardwareWorkcell assembly & bring-up (`workcell.py`)

```python
class ArmBringupStatus(BaseModel):        # streamed to the UI landing page
    arm_id: str
    network: Literal["pending", "probing", "ok", "booting", "failed"]
    connected: bool = False; fw_version: str | None = None; sn: str | None = None
    rail: Literal["unknown", "none", "detected", "unhomed", "ready", "error"] = "unknown"
        # "unhomed" (09c): track detected, on_zero 0 — connect refused (RailNotHomedError,
        # connected False + error) with the default rail_homing; with "allow_unhomed" (09d)
        # the arm IS connected (connected True, no error), position unknown until
        # XArmDriver.home_rail(); no "homing" value — bring-up never homes
    gripper: Literal["unknown", "xarm", "xarm_g2", "none", "error"] = "unknown"
    warnings: list[str] = []; error: str | None = None

class HardwareWorkcell(WorkcellInterface):
    kind: Literal["hardware"] = "hardware"
    def __init__(self, cfg: WorkcellConfig,
                 driver_factory: Callable[[XArmDriverConfig], ArmInterface] = XArmDriver,
                 netsetup: NetSetup | None = None) -> None: ...
    arms: dict[str, ArmInterface]; cameras: dict[str, CameraInterface]
    def start(self) -> None               # core ABC (core §5.1) — delegates to bring_up()
    def stop(self) -> None                # core ABC — delegates to shutdown(); idempotent
    def states(self) -> dict[str, ArmState]   # core ABC — per-arm get_state()
    def drain_events(self) -> list[DriverEvent]   # phase-09b: every driver's events, t_mono order
    def request_recovery(self, arm_id: str) -> None   # -> XArmDriver.request_recovery (§3.5)
    def recovery_result(self, arm_id: str) -> RecoveryResult | None
    def start_cameras(self) -> None       # pre-session landing previews; idempotent
    def bring_up(self, status_cb: Callable[[ArmBringupStatus], None] | None = None,
                 timeout_s: float = 180.0) -> dict[str, ArmBringupStatus]: ...
    def shutdown(self) -> None            # reverse order, never raises
```

`_driver_cfg(arm)` maps the core `ArmConfig` onto `XArmDriverConfig`: id, ip,
`expect_rail`, `gripper`, `tcp_load_kg`, `tcp_load_cog_mm` and (phase-09b)
`collision_sensitivity`, `reduced_tcp_boundary_mm`, `expected_sn` when the core
model carries them (driver defaults otherwise) — so the connect-time backstops
(§6) and the monitor's `apply_backstops` op (§8.6) write the same values.
`drain_events()` concatenates every driver's `drain_events()` (stable sort by
`t_mono`; the runtime's control loop drains it once per tick: `FaultEvent` →
that arm stops streaming / session FAULT, `RecoveredEvent`/`ReseedEvent` →
re-seed + RECOVERING, `StudioConflictWarning` → warning). `request_recovery(arm_id)`
forwards to the driver (unknown arm → `KeyError`; a driver without the channel →
`CommandError`).

Bring-up (`status_cb` fires on every transition → runtime pushes landing
updates over `/ws/telemetry`): (1) **netsetup** `verify()`,
on miss `match()` (`probing`); probe `refused` → `booting`: poll TCP 502
every 2 s within `timeout_s` — never re-probe NICs. (2) **connect** each arm
in its own thread (§3.2 steps updating statuses; `driver.connect_warnings` —
backstop set_* return codes, rail SN not verifiable — are copied into
`ArmBringupStatus.warnings`, fixed 2026-09-04: they were dropped before). (3) **rail detect +
require homed** (inside connect, §3.2 step 4, BEFORE `motion_enable`; bring-up NEVER homes — an
unhomed track ends the arm's bring-up with `rail: "unhomed"` + `error`
"[rail] grip: linear track not homed …", `RailNotHomedError` in
`WorkcellBringupError.statuses`, and the session layer refuses until the
operator has run `home_rail`, §8.6; an unverifiable track — register read /
enable / speed failed — ends it with `rail: "error"` + `error`, a plain
`BringupError(step="rail")`; in both cases the arm was never enabled. With
`rail_homing: "allow_unhomed"` on the driver config — phase-09d, the runtime's
rail-homing job only — an unhomed track instead yields `connected: True`,
`rail: "unhomed"`, NO `error` and a "position UNKNOWN" warning; the job then
pre-positions the arm and calls `XArmDriver.home_rail()`, §5). (4) **report stream**: require
one fresh 30003 snapshot (`stale == False`) before declaring `connected`.
(5) **cameras**: `start_cameras()` if not running. Partial failure: one arm
failing never aborts the others; the session layer decides whether the
surviving subset satisfies the requested arm list. Only the arms in
`cfg.arms` get a driver, so a runtime config listing a subset constructs — and
connects — only those (since phase-09d a teleop session always lists EVERY
configured arm; the rail-homing maintenance job lists the ONE arm it homes,
§15). `shutdown()` hands every connected arm back stopped + braked (§3.6 D6).

**UFACTORY-Studio conflict detection**: Studio "Live control" (arm web UI,
port 18333) grabs mode/state and fights the SDK stream. Detectors: (a)
mode/state change between our `set_mode(1)` and the first stream tick, no
error code → `EXTERNAL` fault (§3.5); (b) in-session uncommanded mode change
in `state_mode` → `StudioConflictWarning` UI banner ("close UFACTORY Studio
live control"). Behavioral only — who holds 18333 is invisible to the host,
so this is a HINT, never a diagnosis: the fault text states the measured
`mode`/`state` and only *suggests* closing Studio. The predicate is "left
servo mode" (§3.5), NOT `state not in {0, 1}` — a held healthy arm reports
state 2 and the strict form produced a permanent false-positive latch on both
arms (2026-09-05, §16). Studio's real grabs still trip it: Live control
switches the box to mode 0 (position) or 2 (teach), and its stop button leaves
state 4.

## 10. Threading model summary

Per arm (daemon threads, named `hw.{arm_id}.{role}` for py-spy):

| Thread | Rate | Owns | 502-lock usage |
|---|---|---|---|
| SDK report thread | 100 Hz push (30003) | `_StateSnap` swap via callback | none |
| `_ServoStreamer` | 100 Hz | `set_servo_angle_j` only | 1 sub-ms call/tick |
| `_MonitorThread` | 5 Hz | err/warn poll, rail `step()`, gripper poll + queued gripper/rail commands, recovery | few ms bursts |
| `_Port30000Reader` (opt) | 10 Hz push | gripper current fields | none |
| `hw.{arm_id}.monitor-ro` (§8.5, session-less; never coexists with the above) | 10 Hz + 2 Hz | `ArmMonitorSample` swap; queued maintenance ops (§8.6) run here, never on the requester's thread | 3 reads/tick + 2 modbus reads per slow tick (+ the op's writes on request) |
| `hw.{arm_id}.monitor-ro` during `home_rail` (§8.6) | blocked ≤ 30 s in the SDK homing wait, then the enable + speed writes and one register read-back | the same thread; no sample published → status `stale`, `maintenance_busy` true; `stop()`/`disconnect()` wait ≤ 45 s for it | the SDK's 10 Hz register polls |
| caller of `XArmDriver.home_rail()` (§5, phase-09d; the runtime's rail-homing job thread) | once; blocked ≤ 30 s in the SDK homing wait + 3 writes + 2 register reads | `RailController.home()`: homing latch, the track writes, `pos_m`/`pos_known`/phase, its `RailEvent`s | the SDK's 10 Hz register polls, interleaved with the streamer's ticks (per-instance command lock); `_MonitorThread.step()` keeps running, its `rail.step()` is a no-op meanwhile |

Plus one capture thread per camera (workcell-scoped). `_StateSnap` swap =
single reference assignment; targets are latest-wins slots under a `Lock`
held only for assignment; events → `deque(maxlen=256)`.
The SDK's per-instance `UxbusCmd` lock serializes 502 traffic; the 5 Hz
monitor bounds streamer lock contention. No thread blocks on network
without a timeout.

## 11. Test strategy (hardware-free)

**FakeXArmAPI** (`tests/fakes/`, injected via `api_factory`): stateful
double of the `XArmAPI` surface used in §3–§6 and §8.5 that MIRRORS SDK 1.18.5
rather than tolerating callers (2026-09-04): `register_report_callback` has the
exact SDK signature (a stray `report_mode` is a `TypeError`), the report payload
has the SDK keys only (no `mode`; `mode`/`state` are instance attributes the
"report thread" updates), `version` is the raw controller string and
`version_number` the parsed tuple, there is no `get_linear_track_sn`,
`do_not_open=True` needs `connect()`, `simulation_robot=True` answers track
reads with `(0, [])`, `connect_fails=N` scripts failing connects, and gripper
`set_*` calls record `wait_motion`. Scriptable `FaultScript`
(latch error at tick N, return code X from `set_servo_angle_j`, drop mode to
0, rail present/absent/unhomed, gripper fw, `collision_sensitivity` /
`tcp_load` start values — `set_collision_sensitivity` / `set_tcp_load` echo
into those properties like the controller's report frame does); records
`sent_joints` + full `calls` log; `emit_report(q, tcp, ...)` fires report callbacks. It encodes
the SDK gotchas as behavior: errors reset mode to 0; `set_servo_angle_j`
returns 1 latched / 9 not-ready / -8 joint-limit; `clean_error()` alone ≠
readiness; unhomed rail → 82; absent rail → code 3. **`set_state(0)` settles the
box in `state 2` (standby), never 0** (2026-09-05, §16): readiness is the
separate `ready_to_move` flag standing in for the reply's 0x10 bit — exactly the
split the real SDK has (the `state` enum vs `UxbusCmd.state_is_ready`) — so no
test can pass by assuming a held arm reports state 0, and `set_mode` still
requires its `set_state(0)`. `get_state()` exists (recorded, so tests can pin
"readiness is polled, not slept for") and `FaultScript.not_ready_ticks` scripts
the servo-mode entry race. **Homing (phase-09c)**
mirrors `x3/linear_motor.py`: `set_linear_track_back_origin(wait, **kwargs)`
blocks for `homing_duration_s` honouring the `timeout` kwarg (SDK default 10)
and `.connected` (100 on either), 80 on a track error, `homing_result_code`
forces the wait result, and `auto_enable` (SDK default True) OVERWRITES the
code with the enable's — the masking the monitor works around;
`inject_track_error(code)` latches the track error register (enable → 80,
homing → 80), `rail_homed` / `rail_enabled` are settable properties,
`homing_started` / `homing_completed` count. Key tests: recovery
order (clean_error → motion_enable → set_mode(1) → set_state(0) → reseed
from measured q); C24 backoff; budget → LATCHED; per-tick clamps (assert
|Δq|, accel, lever-arm bound on `sent_joints`); re-anchor (mocked
`monotonic` stalls 50 ms → no burst); e-stop code 1 → LATCHED; rail slot
round-trips into `get_state()`; `request_recovery()` runs on `hw.a1.monitor`
(thread name recorded inside the fake), emits FaultEvent(`user`) → ReseedEvent →
RecoveredEvent, stays LATCHED with `motion_enable_fails` and reports it via
`recovery_result()`; `HardwareWorkcell.drain_events()` aggregates both arms in
`t_mono` order and `request_recovery("arm1")` recovers only that arm.
**Monitor / maintenance** (`test_monitor.py`, call-logging proxy): zero writes
without a request (read-back attrs included); `clear_errors` write set exactly
`[clean_error, clean_warn]`, executed on `hw.<arm>.monitor-ro`, before/after
samples, no enable / mode change; `apply_backstops` write set == a reference
`apply_backstops` run on a fresh fake (same order) with the read-back reflected
in `after`; nonzero codes → `ok=False` + `warnings`; refusals (`recover`, no
cfg, off/paused/error) never touch the SDK; caller timeout drops the late result
while polling continues; an SDK exception fails the request and reconnects; a
request pending during `disconnect()` fails with "monitor paused".
**`home_rail`** (phase-09c): write set exactly `[set_linear_track_back_origin,
set_linear_track_enable, set_linear_track_speed]` with `wait=True, timeout=30,
auto_enable=False`, on the poll thread, arm state untouched; posture mismatch /
controller error / track error / no track / no cfg / no `expected_q` → refused
before the first write; judged from the registers in both directions (code 101
with `on_zero` 1 → ok; code 0 with `on_zero` 0 → not ok; honest 100; track
error mid-travel); the fake's `auto_enable` masking pinned; `disconnect()`
during the travel waits for the op (45 s budget, not 15 s) and releases after;
status `stale` + `maintenance_busy` while homing; a caller timeout abandons the
result while the homing still completes. **Driver/rail**: connect with an
unhomed track raises `RailNotHomedError(step="rail")` and never calls
`set_linear_track_back_origin`; homed → enable + speed + `pos_m` seeded;
`disconnect()` = `set_mode(0), set_state(4), motion_enable(False)` and nothing
to the track; default caps 0.6 rad/s / 4 mm / 50 mm/s (0.3 / 2 mm until 2026-09-07) honoured on the wire.
**Workcell**: unhomed → `rail: "unhomed"`, sibling untouched, `start()` carries
the typed error; a subset config builds only the selected drivers.

**Report-stream replayer**: TCP server on `127.0.0.1:<ephemeral>` replaying
`fixtures/report/*.bin` (captured 30003 streams; 87-byte frames: big-endian
u32 size prefix, little-endian f32 payload) at configurable rate, plus
`build_real_frame(q, tcp_pose, tau, state, mode, cmd_num) -> bytes`.
Tests: SDK-parser integration (snapshot equals frames); staleness (pause
200 ms → `stale` flips at 0.15 s + event, recovers on resume); dq EMA vs
scripted trajectory; fuzz (truncated/torn/garbage — resync or flag, never
crash); `test_state_snapshot_carries_frame_values_in_meters` pins the wire flange
`[300, -50, 220, π, 0, 0]` → `ArmState.ee_pose` = the TCP `(0.3, -0.05, 0.048)` /
`Ry(π)` and recovers the flange through `se3.tcp_to_flange`. `test_units.py` pins
the RPY composition numerically (`Rz·Ry·Rx` for `(0.4, 0.5, -0.6)`, and that the
old `Rx·Ry·Rz` differs) and `sdk_to_tcp_pose` for both gripper kinds.

**netsetup**: everything runs through the injected `NmcliRunner`; tests use
a `TranscriptRunner` matching argv against transcripts in `fixtures/nmcli/`
(unexpected command = failure), incl. the **actual polluted machine state**
(`machine_polluted.txt`) and the **pinned steady state** with the live MAVIS
UUIDs (`machine_pinned.txt` + overlays: swap, unplugged NIC, foreign profile on
the NIC, user-restricted permissions). Tests: `split_terse` escaped MACs;
serialized probing with NIC release; both pins cleared before probing (none
without a candidate); `refused` = booting; denylisted devices never in any
mutating argv (global call-log assert); reconcile plan on the polluted fixture
= exactly dedupe + strip-gateways + pin-by-MAC + priorities, nothing without a
mapping, permissions cleared; `apply` skips active-with-traffic profiles;
`repair()` with a `FakeClock`: healthy = zero mutations, unplugged = left to
autoconnect, booting = polled, swap = re-matched after the deadline, holdoff,
failed re-probe restores the profile; the rendered dispatcher script is
**executed** (bash/setsid/flock) against a fake sysfs + stub python (events and
device filter, argv contract, missing python, lock queueing); `install` plan /
check / execution with a fake `sys_run`; state-path precedence + read-only
fallback. `ping`/`ip`/socket faked at the `probe.py` seam.

**cameras**: fake `cv2.VideoCapture` — FOURCC-first ordering, read-back
mismatch error, BGR→RGB, reopen-once-then-fail; RS/V4L2 dedup with a fake
`rs.context`. **units**: hypothesis round-trips; clamp edges; quat/RPY
pinned cases. **workcell**: one arm scripted to fail identity → others still
`connected`; status_cb transitions match a golden list. **Live smoke**
(`APOLLO_HW_TESTS=1`, skipped in CI): connect one arm, 5 s joint-6 sine at
100 Hz, zero faults, p99 tick < 3 ms; rail detect/home; gripper open/close;
clean disconnect.

## 12. Fixed 2026-09-04 — first read-only contact with the real boxes

Both control boxes run fw **v1.12.10** (`7,7,XS1305,MC1303`); the pinned SDK is
1.18.5. Reading them (no motion) exposed six defects in code that had only
ever run against the permissive fake; all fixed the same day, the fake now
mirrors the SDK (§11), and each has a regression test:

1. `driver.py` `register_report_callback(..., report_mode=True)` — no such
   keyword in 1.18.5 → `TypeError` after `motion_enable/set_mode(0)/rail homing`.
   Now the exact SDK keyword set (§3.2 step 5).
2. `driver.py` `_on_report` read `data["mode"]` — the payload has no `mode`
   (only the `mode_changed` callback does) → `mode == 0` → Studio-conflict
   detector → `LATCHED` ~1.2 s after every connect. Now `api.mode` (§3.4).
3. `driver.py` `parse_fw(str(api.version))` parsed the raw controller string
   `7,7,XS1305,MC1303,v1.12.10` → bogus major, fw gates trivially true. Now
   `read_fw_tuple(api)` → `api.version_number` (§3.2 step 2).
4. `rail.py` `get_linear_track_sn()` — not on `XArmAPI` 1.18.5 → `AttributeError`.
   Now registers-only detection with a warning when the SN API is absent (§5).
5. `workcell.py` never copied `driver.connect_warnings` (backstop `set_*`
   return codes) into `ArmBringupStatus.warnings`. Now it does (§9).
6. `grippers.py` G2 `set_gripper_g2_position(..., wait=False)` without
   `wait_motion=False` → SDK `wait_move()` blocks the 5 Hz monitor thread
   while the arm moves. Now `wait_motion=False` — also applied to the classic
   `set_gripper_position`, whose SDK path has the same default (§4).

Also learned: the Perception Arm (`view`, 192.168.2.219) reported controller
error **C19** (SDK title "End Effector Communication Error"; Studio says "End
Module Communication Error") persistently (as found 2026-09-04; gone since
2026-09-05 after the Studio fix, §16). Cause: the controller polls the
tool-port RS-485 bus for an end effector and the Perception Arm has none
(`get_tgpio_modbus_baudrate` → `(1, -1)`), so the error re-latched after every
`clean_error` until the controller was told there is no end effector — xArm
Studio → Settings → Externals → End Effector → None; SDK 1.18.5 exposes no
write API for that setting, so it cannot be scripted. Both arms `state 4`,
`mode 0`; both
tracks unhomed/unenabled (§5). The joint convention is an identity mapping to
the `mavis_v2` twin (no +π on joint 1; see `docs/prompts/phase-09a-*.md`).

## 13. Phase-09b (2026-09-04) — controller error clearing / recovery interface

- Monitor (§8.5/§8.6): `ArmStateMonitor.maintenance(op, driver_cfg, timeout_s)`
  executes `clear_errors` (`clean_error` + `clean_warn`, no enable) and
  `apply_backstops` (`backstops.apply_backstops`) on the poll thread with
  before/after samples; `recover` is refused ("recover needs a session"). The
  zero-write guarantee is now "zero writes unless an explicit maintenance
  request" (`MAINTENANCE_SDK_METHODS`). Every slow round reads back
  `XArmAPI.collision_sensitivity` / `XArmAPI.tcp_load` (properties fed by the
  rich report frame; SDK 1.18.5 has no getters).
- Driver (§3.5/§3.6): `request_recovery()` (flag serviced by the 5 Hz monitor
  thread → `_recover(user_initiated=True)`, FaultEvent `source="user"`),
  `recovery_result()` / `RecoveryResult` for non-consuming waiters; events
  unchanged and still delivered through `drain_events()`.
- Workcell (§9): `drain_events()` (all drivers, `t_mono` order),
  `request_recovery(arm_id)`, `recovery_result(arm_id)`; `_driver_cfg` forwards
  `collision_sensitivity`, `reduced_tcp_boundary_mm`, `expected_sn` from the
  core `ArmConfig` (driver defaults with an older core).
- Backstops (§6): parameters documented as coming from `ArmConfig`
  (provisional lab payloads), `apply_backstops(api, cfg, codes=None)` records
  return codes, `BACKSTOP_SDK_METHODS` / `expected_backstop_sequence(cfg)`
  pin the write order for the maintenance tests.
- Out of scope here (phase-09b): rail homing (done in phase-09c as the
  `home_rail` maintenance op, §8.6/§14), `_bringup_hardware` (runtime,
  phase-09c), changing backstops inside a session.

## 14. Phase-09c (2026-09-05) — connect never homes; `home_rail`; caps; hand-back

- Rail (§5, §3.2): `RailController.ensure_homed()` → `require_homed()`: reads the
  registers, `on_zero == 0` → `RailNotHomedError` (core, `step="rail"`) with
  zero writes; `on_zero == 1` → enable + speed + `pos_m` seeded from the
  register. `RailPhase.HOMING` removed; `step()` never commands a `DETECTED`
  track. `ArmBringupStatus.rail` gains `"unhomed"` and loses `"homing"` (§9).
- Monitor (§8.6): `home_rail` = `set_linear_track_back_origin(wait=True,
  timeout=30, auto_enable=False)` → `set_linear_track_enable(True)` →
  `set_linear_track_speed(cfg.rail_speed_mm_s)`, refused before the first write
  on posture mismatch (`expected_q`, `q_tol_rad = 0.02`), controller error or
  track error; `ok` from the registers only (`on_zero`, `is_enabled`, `error`);
  `HOME_RAIL_TIMEOUT_S = 45`; shutdown waits that long for a homing in flight;
  status `stale` + `maintenance_busy` while homing. `ArmMonitorSample.rail_error`
  added. `maintenance(timeout_s=None)` → per-op default.
- Driver (§3.1, §3.6): D2 caps `max_joint_vel 0.6 rad/s`, `max_cart_step_m
  0.004`, `rail_speed_mm_s 50` at `speed_scale 1.0` (runtime scales; 0.3 / 0.002
  until 2026-09-07); D6
  `disconnect()` = `set_mode(0)`, `set_state(4)`, `motion_enable(False)`, track
  untouched.
- Fake (§11): `homing_duration_s`, `homing_result_code`, SDK-faithful
  `auto_enable` masking, `inject_track_error`, settable `rail_homed`.
- Out of scope here: the runtime's twin sweep gate, REST/UI for `home_rail`,
  the track's homing-speed register (no public SDK setter), per-arm monitor
  pause, detecting an unselected arm moved from Studio during a session (its
  monitor is paused with the others; the UI tells the operator not to touch
  it), collect / DAgger / inference on hardware.

## 15. Phase-09d (2026-09-05) — pre-positioning before homing: `allow_unhomed` connect + `home_rail()` on a connected driver

- Contract: `docs/prompts/phase-09d-rail-homing-planning.md` §2. When the arm's
  current posture does not clear the whole rail travel, the runtime plans a
  rail-position-agnostic path in the twin, connects ONLY that arm, executes the
  path at 10 % under the gate, homes the track with the joints held, then hands
  the arm back braked in the folded posture. The two driver-side pieces:
- Config (§3.1): `XArmDriverConfig.rail_homing: Literal["require_homed",
  "allow_unhomed"] = "require_homed"` — chosen over a `connect(allow_unhomed_rail=)`
  kwarg because `HardwareWorkcell._bring_up_arm` calls the core
  `ArmInterface.connect()` with no arguments and the runtime already derives a
  per-job driver config (`model_copy` for the speed scale carries the literal).
- Connect (§3.2 step 4, §5): `RailController.require_homed(allow_unhomed=True)`
  accepts `on_zero == 0` with zero writes; phase `DETECTED`, `pos_known False`,
  `dof` 8, `ArmState.q[7] == rail_pos_m == UNKNOWN_RAIL_POS_M (0.0)` as a
  placeholder (core's `ArmState` forbids NaN and requires `rail_pos_m == q[7]`,
  so the contract's "None/NaN" marker became the flag
  `XArmDriver.rail_position_known`); `command_joints` drops the rail slot,
  `command_rail` raises `CommandError`; `ArmBringupStatus.rail == "unhomed"` with
  `connected True` and no `error` (§9).
- `XArmDriver.home_rail() -> RailHomeOutcome` (§5, §10): caller's thread;
  refused unless `STREAMING` with no controller error; `RailController.home()` =
  homing latch (5 Hz `step()` no-op, targets dropped, barrier on `_io_lock`) →
  pre-read (track error → refused, zero writes) → `set_linear_track_back_origin
  (wait=True, timeout=HOME_RAIL_SDK_WAIT_S, auto_enable=False)` → enable →
  speed → read-back judged from the registers only → `READY` + `pos_m` seeded
  + target cleared (+ `RailEvent`) or `RAIL_ERROR` + `RailEvent`, position
  still unknown. `HOME_RAIL_SDK_WAIT_S` moved to `rail.py` (the monitor imports
  it). `set_target()` now drops targets unless `READY` and not homing;
  `drain_events()` is lock-protected (drained from two threads).
- Fake (§11): `homing_track_error` (trip a track error when the carriage would
  reach the zero end). Tests: `tests/test_rail.py` (controller: allow_unhomed
  gate, exact write set, register judge vs SDK code, refusals, mid-travel
  failure, re-homing, latch vs `step()` on two threads) and
  `tests/test_rail_homing.py` (driver: default still refuses, allow_unhomed
  connect, `home_rail` keeps streaming and holds the posture, failure, refusals,
  job thread vs control loop; workcell status mapping).
- Out of scope here: the runtime job / REST / UI (contract §3–§4), homing both
  tracks at once, the homing-speed register.


> **SDK 1.18.5 quirks met live (2026-09-04):** `set_collision_rebound` returns the raw
> reply list `[code, ...]` (every other setter returns `ret[0]`) — `_check` normalises
> list replies; `set_tcp_load` returns APIState 9 (STATE_NOT_READY) while the arm is
> stopped (state 4/5) although the controller stores the value — recorded as a warning
> and verified by the `tcp_load` read-back; the setters are called with `wait=False`
> because the SDK defaults would `wait_move()` in the stopped state. After
> `apply_backstops` both controllers reported state 5 instead of 4 (both "stopped / not
> ready" for the SDK; no joint moved).

## 16. Fixed 2026-09-05 — first live hardware session: three false alarms

The first real teleop session (both arms, 10 %, after both tracks homed) came up
and then latched BOTH arms within a second, repeatedly, with
`CONTROLLER FAULT — <Arm> external mode/state conflict persisted (UFACTORY
Studio?)`. Before this session the Perception Arm's C19 was cleared for good —
xArm Studio → Settings → Externals → End Effector → None stuck; the monitor has
read `error_code` 0 on both arms since 2026-09-05. **No UFACTORY Studio was
running** (nothing on port 18333; `ss`
showed the runtime process as the only client on 502/30003 of either box). Three
independent defects, all "our code misreading a healthy controller":

1. **State 2 is healthy, not a Studio grab** (§3.5, §9). The detector accepted
   only `state in {0, 1}`. A held mode-1 arm reports **state 2** (standby): the
   Manipulation Arm sat at `mode 1 state 2` with `error_code 0` and still
   latched. Across the whole session the boxes reported exactly two pairs —
   `mode 1 state 2` (15×) and one `mode 1 state 4` — i.e. never a Studio-shaped
   mode grab. Fix: `SERVO_HEALTHY_STATES = {0, 1, 2}` /
   `SERVO_CONFLICT_STATES = {3, 4, 5, 6}`, and the latch text now reports the
   measured mode/state instead of naming a cause it cannot observe. The 5 s
   re-trip rule turned the false positive into a permanent latch, so every
   **Clear errors & resume** click re-latched ~0.5 s later.
2. **The servo-mode entry race** (§3.3). The Perception Arm's FIRST fault was
   `source servo, code 9` on the very first tick after `set_state(0)`: the box
   had not finished entering servo mode. Fix: `_enter_servo_mode()` polls
   `get_state()` for readiness, and the streamer retries a code 9 inside a
   bounded 0.3 s post-`resume()` grace.
3. **`clean_error` returning 2 is not a failure** (§8.6). `clear_errors` on the
   Perception Arm reported `FAILED - clean_error returned 2` while the error was
   in fact cleared (`error_code` 0 in the very next sample). 2 = `WAR_CODE`, a
   status echo; `clean_error`/`clean_warn` are the only writes that skip
   `_check_code`. Fix: `STATUS_ECHO_CODES = {1, 2, 9}` (the SDK status echoes of
   those two writes) are tolerated and the verdict comes
   from the read-back.

Regression coverage (hardware-free) in `tests/test_driver_recovery.py`
(standby-is-not-a-conflict, external state 4 / persistent state 3 still detected
and the latch text carries no accusation, the mode-entry race does not fault,
readiness is polled not slept for, not-ready past the grace still faults) and
`tests/test_monitor.py::test_clear_errors_status_echo_codes_are_not_failures`.
The fake had hidden all three: it moved to `state 0` on `set_state(0)` and gated
`set_servo_angle_j` on `state == 0`. It now mirrors the box — `set_state(0)` →
**state 2** plus a separate `ready_to_move` flag standing in for the reply's
0x10 bit (`FaultScript.not_ready_ticks` scripts the entry race).
