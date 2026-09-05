# 02 — apollo-mavis-v2-hardware (`apollo_mavis_v2_hardware`)

Status: v0.4 (2026-09-04 phase-09b: §8.6 explicit maintenance channel on the
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
intrinsic XYZ per `core.se3.rpy_to_quat` — equivalently extrinsic ZYX — the
xArm firmware convention).

```python
GRIPPER_PULSE_MAX = 850; GRIPPER_G2_MM_MAX = 84.0; RAIL_MM_MAX = 650

def m_to_mm(x: float) -> float: ...           # + mm_to_m
def pose_to_sdk(pose: Pose) -> list[float]:   # (m, wxyz) -> [x_mm,y_mm,z_mm,r,p,y rad]
def sdk_to_pose(p: Sequence[float]) -> Pose:  # inverse; quat normalized, w >= 0
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
class ServoLimits(BaseModel):
    rate_hz: float = 100.0
    max_joint_vel: NDArray7 = [1.0]*7      # rad/s (per-tick slew = vel*dt)
    max_joint_acc: NDArray7 = [20.0]*7     # rad/s^2 (prevents C24 on step changes)
    lever_arm_m: NDArray7 = [1.20, 1.20, 1.00, 0.75, 0.44, 0.30, 0.10]
    max_cart_step_m: float = 0.009         # firmware hard limit 10 mm/tick; keep margin
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
    rail_speed_mm_s: int = 200; servo: ServoLimits = ServoLimits()
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
    tick_stats: TickStats       # property: jitter p50/p99, late ticks, faults

@dataclass(frozen=True)
class RecoveryResult:           # set at the end of every recovery sequence
    seq: int; ok: bool; error_code: int; detail: str = ""   # detail = latch reason
    user_initiated: bool = False; t_mono: float = 0.0
```

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
   call return 1); apply backstops (§6); then `api.motion_enable(True);
   api.set_mode(0); api.set_state(0)` — required order; every `set_mode`
   must be followed by `set_state(0)`.
4. Rail detection per `expect_rail` (`auto` → `RailController.detect()`;
   `yes` → absent raises `RailExpectedError`; `no` → skip); fixes `dof`;
   `rail.warnings` (e.g. "SN not verified", §5) are appended to
   `connect_warnings`.
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
`RailExpectedError`, `GripperInitError`) carrying the step name; the
workcell turns them into per-arm statuses (§9), never aborting other arms.

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
    else: on_fault(code, q_cmd); pause()       # §3.5 takes over
    record tick latency into stats (EWMA + p99 ring)
```

The lever-arm bound keeps worst-case TCP step ≤ 9 mm with all joints slewing
(no MuJoCo/Jacobian in `hardware` — fixed conservative radii). Jitter:
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
`RailController.pos_m`; rail dq = 0.0), `ee_pose = units.sdk_to_pose(...)`,
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
- **UNRECOVERABLE** → `LATCHED` immediately: 1/2/3 e-stop variants (never
  auto-resume), 10–17 servo motor, 19/28 end-module comms, 110 baseboard.
  **111** (rail dropped off RS-485) latches only the rail (`RAIL_ERROR`);
  the arm keeps streaming, rail frozen.
- **EXTERNAL** (mode/state changed under us, no error code — Studio, §9):
  pause, emit `StudioConflictWarning`, retry mode 1 once; again in 5 s →
  `LATCHED`.

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
monitor (join, 0.5 s timeouts), best-effort `set_mode(0); set_state(0)`,
gripper `close()`, `api.disconnect()`; idempotent, never raises (logs).

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
class RailPhase(Enum): ABSENT; DETECTED; HOMING; READY; RAIL_ERROR
class RailController:
    def __init__(self, api: Any, speed_mm_s: int = 200) -> None: ...
    def detect(self) -> bool: ...  /  def ensure_homed(self) -> None: ...
    def set_target(self, pos_m: float) -> None   # thread-safe, latest-wins
    def step(self) -> None                       # 5 Hz on monitor thread
    pos_m: float; phase: RailPhase               # properties
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
reports `rail_pos_m = None` until then and `rail_raw_mm` always. Homing
(`set_linear_track_back_origin`) is a MOTION command and belongs to the
session bring-up (phase-09), never to the monitor. `ensure_homed()`: if `get_linear_track_on_zero()`
is 0 → `set_linear_track_back_origin(wait=True, timeout=30)` — REQUIRED once
per power-on (commanding unhomed returns APIState 82); then
`set_linear_track_enable(True)` + `set_linear_track_speed(speed_mm_s)`.
`step()`: poll `get_linear_track_pos()` → `pos_m`; if new target and
`|Δ| >= 1 mm` → `set_linear_track_pos(units.rail_m_to_mm(target),
wait=False)` (absolute int mm, clamped [0, 650]); nonzero track error →
`clean_linear_track_error()` once + re-enable, repeated → `RAIL_ERROR` +
`RailEvent`. Teleop rail keys (←/→) arrive as the rail slot of
`command_joints`; ~5 Hz absolute re-targeting is smooth — the track plans
its own motion at `rail_speed_mm_s`.

## 6. Controller-side safety backstops (`backstops.py`)

Layer 3 of overview §6 — controller-enforced limits under the twin gate
(the controller knows nothing about other arms or the rail).

**Parameters come from the core `ArmConfig`** (phase-09b): `tcp_load_kg`,
`tcp_load_cog_mm`, `collision_sensitivity` (0..5, default 3),
`reduced_tcp_boundary_mm` (optional `[x_max, x_min, y_max, y_min, z_max,
z_min]`, None = reduced mode off) and `expected_sn`, mapped field-for-field
into `XArmDriverConfig` by `workcell._driver_cfg` (an older core without the
three new fields keeps the driver defaults). The lab values are in the runtime's
`configs/mavis_v2.yaml` and are estimates the user accepted on 2026-09-05 without weighing (whole-arm collision detection is what matters to the lab):
Manipulation Arm (G2 + D435i + mount) ≈ 0.95 kg at (0, 0, 60) mm, Perception
Arm (D435i + RØDE NT-USB Mini + mount) ≈ 0.55 kg at (0, 0, 90) mm, sensitivity
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
the MAVIS cell — never address the wrist cameras by by-id). **Cold-boot wake**: after a
reboot a D435i's colour UVC interface delivers no frames at all (`select() timeout` on
every read; observed 2026-09-04, kernel 7.0.11, firmware 5.15.1 / 5.17.0.10) until
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
    tcp_pose: tuple[float, ...]    # [x, y, z m, roll, pitch, yaw rad], flange (tcp_offset 0)
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
tab ("Clear errors", "Apply safety settings"). Design rules: (a) **nothing
moves** — `clear_errors` never enables (brakes stay engaged; measured
2026-09-04: `clean_error()` on the Perception Arm cleared C19 with ≤ 5e-5 rad
joint change), and enabling + servo mode (`recover`) is refused here because it
needs a session driver; (b) **one `XArmAPI`, one thread** — the request is
queued and executed by the poll thread between polls, the caller only waits;
(c) **auditable** — the outcome lists every SDK return code in call order plus
a sample right before and right after the operation.

```python
MaintenanceOp = Literal["clear_errors", "apply_backstops", "recover"]
MAINTENANCE_SDK_METHODS = {
    "clear_errors":    {"clean_error", "clean_warn"},          # in that order
    "apply_backstops": set(backstops.BACKSTOP_SDK_METHODS),   # §6 order, cfg-dependent
    "recover":         set(),                                  # refused: needs a session
}

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
- **Outcome**: `clear_errors` — `ok` iff both codes are 0 AND `after.error_code
  == 0` (a controller error that re-latches right away — a persisting hardware
  fault — is reported as `ok=False`, "… re-latched right after clearing");
  `detail` names what was cleared (`cleared controller error 19: End Effector
  Communication Error and controller warning 11`) or says nothing was latched.
  `apply_backstops` — `ok` iff every code is 0 (`warnings` lists the nonzero
  ones; `detail` = "safety settings applied: sensitivity 3, payload 0.95 kg at
  (0, 0, 60) mm" [+ ", reduced-mode boundary on"], with a read-back note if the
  frame has not caught up yet).
- **Refusals** (`ok=False`, no SDK call): `recover` ("recover needs a session");
  `apply_backstops` without a `driver_cfg`; monitor `off` / `paused` /
  `connecting` / `error` ("not connected to <ip> (monitor paused: released for
  hand-over)"); unknown op → `ValueError`.
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
  (bounded by `STALE_THREAD_JOIN_S`) before releasing the box, so a session
  driver taking over never finds the monitor still writing. A caller timeout (`timeout_s`, default 10 s)
  abandons the request: `ok=False` "… timed out …", the late result is dropped,
  polling continues. `maintenance_busy` is true while a request is queued or
  executing (telemetry `maintenance_busy`).

## 9. HardwareWorkcell assembly & bring-up (`workcell.py`)

```python
class ArmBringupStatus(BaseModel):        # streamed to the UI landing page
    arm_id: str
    network: Literal["pending", "probing", "ok", "booting", "failed"]
    connected: bool = False; fw_version: str | None = None; sn: str | None = None
    rail: Literal["unknown", "none", "detected", "homing", "ready", "error"] = "unknown"
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
`ArmBringupStatus.warnings`, fixed 2026-09-04: they were dropped before). (3) **rail detect + home**
(inside connect; ~10 s, once per power-on). (4) **report stream**: require
one fresh 30003 snapshot (`stale == False`) before declaring `connected`.
(5) **cameras**: `start_cameras()` if not running. Partial failure: one arm
failing never aborts the others; the session layer decides whether the
surviving subset satisfies the requested arm list.

**UFACTORY-Studio conflict detection**: Studio "Live control" (arm web UI,
port 18333) grabs mode/state and fights the SDK stream. Detectors: (a)
mode/state change between our `set_mode(1)` and the first stream tick, no
error code → `EXTERNAL` fault (§3.5); (b) in-session uncommanded mode change
in `state_mode` → `StudioConflictWarning` UI banner ("close UFACTORY Studio
live control"). Behavioral only — who holds 18333 is invisible to the host.

## 10. Threading model summary

Per arm (daemon threads, named `hw.{arm_id}.{role}` for py-spy):

| Thread | Rate | Owns | 502-lock usage |
|---|---|---|---|
| SDK report thread | 100 Hz push (30003) | `_StateSnap` swap via callback | none |
| `_ServoStreamer` | 100 Hz | `set_servo_angle_j` only | 1 sub-ms call/tick |
| `_MonitorThread` | 5 Hz | err/warn poll, rail `step()`, gripper poll + queued gripper/rail commands, recovery | few ms bursts |
| `_Port30000Reader` (opt) | 10 Hz push | gripper current fields | none |
| `hw.{arm_id}.monitor-ro` (§8.5, session-less; never coexists with the above) | 10 Hz + 2 Hz | `ArmMonitorSample` swap; queued maintenance ops (§8.6) run here, never on the requester's thread | 3 reads/tick + 2 modbus reads per slow tick (+ the op's writes on request) |

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
readiness; unhomed rail → 82; absent rail → code 3. Key tests: recovery
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

**Report-stream replayer**: TCP server on `127.0.0.1:<ephemeral>` replaying
`fixtures/report/*.bin` (captured 30003 streams; 87-byte frames: big-endian
u32 size prefix, little-endian f32 payload) at configurable rate, plus
`build_real_frame(q, tcp_pose, tau, state, mode, cmd_num) -> bytes`.
Tests: SDK-parser integration (snapshot equals frames); staleness (pause
200 ms → `stale` flips at 0.15 s + event, recovers on resume); dq EMA vs
scripted trajectory; fuzz (truncated/torn/garbage — resync or flag, never
crash). One live capture pins `sdk_to_pose` against Studio ground truth.

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

Also learned: the Perception Arm (`view`, 192.168.2.219) reports controller
error **C19** (SDK title "End Effector Communication Error"; Studio says "End
Module Communication Error") persistently; both arms `state 4`, `mode 0`; both
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
- Out of scope here (phase-09): rail homing (motion), `_bringup_hardware`,
  changing backstops inside a session.


> **SDK 1.18.5 quirks met live (2026-09-04):** `set_collision_rebound` returns the raw
> reply list `[code, ...]` (every other setter returns `ret[0]`) — `_check` normalises
> list replies; `set_tcp_load` returns APIState 9 (STATE_NOT_READY) while the arm is
> stopped (state 4/5) although the controller stores the value — recorded as a warning
> and verified by the `tcp_load` read-back; the setters are called with `wait=False`
> because the SDK defaults would `wait_move()` in the stopped state. After
> `apply_backstops` both controllers reported state 5 instead of 4 (both "stopped / not
> ready" for the SDK; no joint moved).
