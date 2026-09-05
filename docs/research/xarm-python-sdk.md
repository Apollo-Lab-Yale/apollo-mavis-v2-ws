# UFACTORY xArm-Python-SDK — research note

Source: https://github.com/xArm-Developer/xArm-Python-SDK (read at version **1.18.5**, shallow clone of `master`, 2026-09).
Cross-checked against `doc/api/xarm_api.md`, `doc/api/xarm_api_code.md`, `example/wrapper/common/*`, and the official `xarm_ros` README (report-port rates, mode-1 guidance).

Install: `pip install xarm-python-sdk` (pure Python, py3; works on 3.10). Entry point:

```python
from xarm.wrapper import XArmAPI
```

All public API lives in `xarm/wrapper/xarm_api.py` (class `XArmAPI`), which delegates to
`xarm/x3/*.py` (`base.py`, `xarm.py`, `gripper.py`, `linear_motor.py`, `report.py`, ...).
Low-level wire protocol: `xarm/core/wrapper/uxbus_cmd.py` + `uxbus_cmd_tcp.py` (private "uxbus" protocol on TCP port **502**).

---

## 1. Connection and lifecycle

```python
arm = XArmAPI('192.168.1.221',            # controller IP, port 502 (control) + report socket
              is_radian=True,             # default unit for ALL angle args/returns (default False = degrees)
              do_not_open=False,          # if True, call arm.connect() yourself
              # useful kwargs (all optional):
              report_type='rich',         # 'normal'(30001) | 'rich'(30002, default) | 'real'(30003)
              enable_report=True,         # spawn the report thread (needed for arm.state/arm.angles caches)
              check_joint_limit=True,     # SDK-side range check on set_servo_angle / set_servo_angle_j
              check_cmdnum_limit=True, max_cmdnum=512,
              max_callback_thread_count=0)  # >0: callbacks run in a ThreadPool; <0: asyncio loop
```

- `XArmAPI.__init__(self, port=None, is_radian=False, do_not_open=False, **kwargs)`.
- Command channel = TCP `ip:502`, synchronous request/response, **serialized by a
  `threading.Lock` inside `UxbusCmd`** (`xarm/core/wrapper/uxbus_cmd.py:38`, `@lock_require`).
- A background *report thread* connects to one of the report ports (below) and keeps the cached
  properties fresh: `arm.connected`, `arm.state`, `arm.mode`, `arm.error_code`, `arm.warn_code`,
  `arm.angles`, `arm.position`, `arm.position_aa`, `arm.realtime_tcp_speed`,
  `arm.realtime_joint_speeds`, `arm.temperatures`, `arm.currents`, `arm.voltages`, `arm.cmd_num`,
  `arm.version`, `arm.sn`, `arm.report_data` (the parsed report struct).
- `arm.connect(port=None, ...)` / `arm.disconnect()`.
- Event callbacks (invoked from the report thread unless `max_callback_thread_count` set):
  `register_report_callback`, `register_report_location_callback`,
  `register_connect_changed_callback`, `register_state_changed_callback`,
  `register_mode_changed_callback`, `register_error_warn_changed_callback`,
  `register_cmdnum_changed_callback`, `register_temperature_changed_callback`,
  `register_count_changed_callback`, `register_feedback_callback` (+ matching `release_*`).

### Standard bring-up sequence (required order)

```python
arm.motion_enable(enable=True)   # motion_enable(enable=True, servo_id=None) -> code
arm.set_mode(0)                  # set_mode(mode=0, detection_param=0) -> code
arm.set_state(0)                 # set_state(state=0) -> code   (0 = ready/motion state)
```

### Modes — `set_mode(mode, detection_param=0)`

| mode | meaning | streaming API |
|---|---|---|
| 0 | position control (queued, planned by controller) | `set_position`, `set_servo_angle`, `move_gohome`, ... |
| 1 | **servo motion mode** (execute only the last instruction, no controller planning) | `set_servo_cartesian`, `set_servo_cartesian_aa`, `set_servo_angle_j` |
| 2 | joint teaching / free-drive (zero-gravity). Verify mounting/payload first | — |
| 3 | reserved/invalid | — |
| 4 | joint velocity control | `vc_set_joint_velocity` |
| 5 | cartesian velocity control | `vc_set_cartesian_velocity` |
| 6 | joint online trajectory planning (OTG, fw >= 1.10.0) | `set_servo_angle(..., wait=False)` re-targets mid-motion |
| 7 | cartesian online trajectory planning (OTG, fw >= 1.11.0) | `set_position(..., wait=False)` re-targets mid-motion |

`detection_param` only matters for mode 2 (0 = motion detection on, 1 = off; fw >= 1.10.1).
**After `clean_error()` / most errors the controller drops back to mode 0** — always re-run
`motion_enable(True); set_mode(m); set_state(0)` in the recovery path.

### States

- `get_state() -> (code, state)` : 1 = in motion, 2 = sleeping (standby/ready), 3 = paused/suspended, 4 = stopping/stopped.
- `set_state(state)` accepts: 0 = motion(ready), 3 = pause, 4 = stop, 6 = deceleration stop.
- SDK internally treats state 4 and 5 as "not ready" (`base.py`: `state in [4, 5] -> _is_ready = False`).
- `arm.state` property is the report-fed cache; `mode` is only reported (upper nibble of `state_mode` byte).

### Errors / warnings

- `get_err_warn_code(show=False, lang='en') -> (code, [error_code, warn_code])`.
- `clean_error() -> code`, `clean_warn() -> code`. After `clean_error()` you **must**
  `motion_enable(True)` + `set_state(0)` (docstring is explicit), and re-set the mode.
- Every API returns an int `code` (or `(code, data)`); `0` = OK. Key **API codes**
  (`xarm/x3/code.py::APIState`): `-1` NOT_CONNECTED, `-2` NOT_READY (not enabled / wrong state),
  `-6` TCP_LIMIT, `-7` JOINT_LIMIT, `-8` OUT_OF_RANGE, `-9` EMERGENCY_STOP, `1` HAS_ERROR
  (unclcleared controller error), `2` HAS_WARN, `3` response timeout, `9` state not ready,
  `20` host id error, `21/22` modbus baud, `23` modbus reply length error,
  `80/81/82` linear-motor fault / SCI low / not homed, `100` wait-finish timeout.
- Key **controller error codes** (`doc/api/xarm_api_code.md`): 1/2/3 e-stop variants,
  10–17 servo motor errors, 19/28 end-module comms, 21 kinematic, **22 self-collision**,
  **23 joint angle exceeds limit**, **24 speed exceeds limit**, 25 planning error,
  **31 collision (abnormal current)**, **35 safety-boundary limit**, 38 abnormal joint angle,
  110 baseboard comms, **111 control-box external-485 device comms error (linear track!)**.
- `emergency_stop()` = software stop: `set_state(4)` in a loop (≤3 s) then `_sync()`. It does
  **not** clear errors and is not a hardware STO — the physical e-stop button is the real one.

---

## 2. High-rate streaming control (mode 1)

Signatures (`xarm/wrapper/xarm_api.py`):

```python
set_servo_cartesian(mvpose, speed=None, mvacc=None, mvtime=0,
                    is_radian=None, is_tool_coord=False, **kwargs) -> code
# mvpose = [x(mm), y(mm), z(mm), roll, pitch, yaw]  (rpy in rad if is_radian else deg)
# speed/mvacc/mvtime are RESERVED (ignored by firmware in mode 1)
# is_tool_coord=True -> mvpose is a delta in the current TOOL frame (fw >= 1.5.0)

set_servo_cartesian_aa(axis_angle_pose, speed=None, mvacc=None, is_radian=None,
                       is_tool_coord=False, relative=False, **kwargs) -> code
# [x, y, z, rx, ry, rz] axis-angle orientation; relative=True for delta moves

set_servo_angle_j(angles, speed=None, mvacc=None, mvtime=None, is_radian=None, **kwargs) -> code
# angles = ABSOLUTE joint targets, list of 7; speed/mvacc reserved
# SDK checks joint limits client-side (check_joint_limit=True) -> APIState.OUT_OF_RANGE (-8)
```

Facts that matter for the teleop/policy loop:

- **Units: mm and rad/deg — never metres.** All cartesian APIs are mm, mm/s, mm/s²;
  joints are rad if `is_radian=True` (construct with `is_radian=True` and standardize on rad + mm).
- Must be in `set_mode(1)` + `set_state(0)`; the firmware executes each point immediately and
  keeps only the newest one ("execute only the last instruction"). No controller-side buffering/queue,
  so the `max_cmdnum` (512) queue limit does *not* apply (the `xarm_wait_until_cmdnum_lt_max`
  decorator is not applied to `set_servo_angle_j` / `set_servo_cartesian`).
- **Official guidance** (xarm_ros examples doc, applies to the same SDK calls): send at a **fixed
  frequency of 20–100 Hz** with step distance **MUST be < 10 mm** per command; the path must start
  from the current TCP pose and each target must stay close to the current position, otherwise
  execution "will fail or act strange" — in practice large jumps trigger error **C24 (speed exceeds
  limit)** or violent motion. UFACTORY support commonly recommends 100 Hz–250 Hz; the shipped
  examples (`example/wrapper/common/7001-servo_j.py`, `7002-servo_cartesian.py`) stream at
  **100 Hz** (`time.sleep(0.01)`) with 1 mm / small-angle steps.
- There is **no firmware-side interpolation/smoothing in mode 1** — the caller owns trajectory
  smoothness (velocity/accel/jerk limiting). Duplicate or late packets = velocity discontinuity.
  If you want the controller to smooth for you, use **mode 7** (`set_position(..., wait=False)`,
  type-II OTG, speed-continuous re-planning) or **mode 6** for joint space (type-IV OTG) — good
  fallback for ~10–30 Hz policy outputs; mode 1 is right for a 100 Hz+ well-formed stream.
- Each call is a blocking TCP request/response (~sub-ms on LAN + lock). One arm = one socket;
  100–250 Hz per arm is fine. Keep one dedicated real-time thread per arm.
- Firmware constraints: servo cartesian needs fw >= 1.4.1 (tool-coord variant >= 1.5.0).
  Error recovery mid-stream: stop sending → `clean_error()` → `motion_enable(True)` →
  `set_mode(1)` → `set_state(0)` → re-seed stream from *current* pose (`get_position()`).

Velocity-mode alternatives (useful for keyboard teleop):

```python
vc_set_joint_velocity(speeds, is_radian=None, is_sync=True, duration=-1)   # mode 4, fw>=1.6.9
vc_set_cartesian_velocity(speeds, is_radian=None, is_tool_coord=False, duration=-1)  # mode 5
# duration>0 (s): auto-stop watchdog (fw>=1.8.0)  -> use it as a deadman switch
```

---

## 3. Reading joint / TCP state

Polling (request/response over port 502):

```python
code, [x, y, z, r, p, yw] = arm.get_position(is_radian=None)          # mm + rad/deg
code, pose_aa            = arm.get_position_aa(is_radian=None)        # axis-angle
code, angles             = arm.get_servo_angle(servo_id=None, is_radian=None, is_real=False)
# is_real=True (fw >= 1.9.110): returns measured feedback position (via get_joint_states)
# instead of the interpolated command position
code, [pos, vel, effort] = arm.get_joint_states(is_radian=None, num=3)  # fw-dependent; 7-vectors
```

Poll rate: each call is one synchronized round-trip; several hundred Hz is possible but shares
the lock with your streaming writes. **For high-rate state use the report socket instead.**

### Report sockets (controller pushes, one-way)

Constants in `xarm/core/config/x_config.py::XCONF.SocketConf`:

| port | SDK name | `report_type` | rate | content |
|---|---|---|---|---|
| 30000 | `TCP_REPORT_RT_PORT` | (not selectable via kwarg) | high-rate/config | "RT" report: `timestamp`, state/mode, target+actual joint angle/vel/acc, `actual_joint_current`, `estimated_joint_torque`, target+actual TCP pose/speed/acc, `ft_raw_force`/`ft_ext_force`, **monitor_device pos/speed/current** (external gripper/track monitor, `set_external_device_monitor_params`, fw >= 2.7.100), GPIO |
| 30001 | `TCP_REPORT_NORM_PORT` | `'normal'` | 5 Hz | joints, TCP pose, torques, brake/enable bits, err/warn, tcp_offset, payload |
| 30002 | `TCP_REPORT_RICH_PORT` | `'rich'` (SDK default) | 5 Hz | everything in normal + limits, temperatures, voltages/currents, reduced-mode state, collision config, GPIO, version, counter... |
| 30003 | `TCP_REPORT_REAL_PORT` | `'real'` | **100 Hz** | `state_mode`, `cmd_num`, `actual_joint_angle[7]`, `actual_tcp_pose[6]`, `estimated_joint_torque[7]`, `ft_ext_force[6]`, `ft_raw_force[6]` |

(Rates per xarm_ros docs: normal/rich = 5 Hz, `dev`/real 30003 = 100 Hz.)

Parsers ship in the SDK: `xarm/x3/report.py::ReportDataStructure.create(port)` returns a ctypes
struct (`_Report30003DataStructure` etc.) with `.update(bytes)`; each frame is length-prefixed
(`data_size` u32 big-endian; floats little-endian). Frame sizes: real=87 B, normal=133 B,
rich=233+ B (`TCP_REPORT_*_BUF_SIZE`).

Two usage options:

```python
# (a) let the SDK do it — 100 Hz cached state on the instance:
arm = XArmAPI(ip, report_type='real', is_radian=True)
arm.report_data.actual_joint_angle      # updated by the report thread
arm.angles; arm.position                # cached properties

# (b) roll your own socket (see example/wrapper/common/3004-get_report_data.py):
from xarm.core.comm import SocketPort
from xarm.core.utils.bytes_data import BytesData
sock = SocketPort(ip, 30003)
data = sock.read(timeout=1)
angles = BytesData.to_fp32_list(data[7:35], 7)   # rad
pose   = BytesData.to_fp32_list(data[35:59], 6)  # mm + rad
```

Caveat: with `report_type='real'` the rich-report-only caches (temperatures, reduced-mode state,
GPIO...) are not updated; if you need both, open a second raw socket to 30002 or poll.

---

## 4. Grippers

### Standard xArm Gripper (RS-485 on tool, modbus)

```python
set_gripper_enable(enable) -> code
set_gripper_mode(0) -> code                      # 0 = position mode (only mode)
set_gripper_speed(speed) -> code                 # unit r/min, valid ~1000-5000
set_gripper_position(pos, wait=False, speed=None, auto_enable=False, timeout=None) -> code
                                                 # pos in PULSES, hardware range approx -10..850
                                                 # (850 pulses ~= 85 mm opening); timeout default 10 s
get_gripper_position() -> (code, pos_pulse)
get_gripper_status()   -> (code, status)         # gripper fw >= 3.4.3; status&0x03: 0 stop,1 move,2 GRASP
get_gripper_err_code() -> (code, err)
clean_gripper_error()  -> code
get_gripper_version()  -> (code, 'x.y.z')
```

- **No force control and no direct force/current readback on the classic gripper** — no
  `set_gripper_force`/`get_gripper_current` exists for it. Grasp detection options:
  1) `get_gripper_status()` grasp bit (gripper fw >= 3.4.3);
  2) `wait=True` position convergence heuristics (SDK loops comparing position, `gripper.py`);
  3) fw >= 2.7.100: `set_external_device_monitor_params(dev_type=1, frequency)` → controller
     streams gripper **pos/speed/current** in the port-30000 report (`monitor_device_*` fields).
- **xArm Gripper G2** (if purchased): `set_gripper_g2_position(pos, speed=100, force=50, wait=False,
  timeout=None)` — pos 0–84 **mm**, speed 15–225 mm/s, **force 1–100 (%)**; plus
  `get_gripper_g2_position/speed/force`. G2 is the one with real force control.
- BIO gripper: `set_bio_gripper_enable(enable)`, `set_bio_gripper_speed(speed)`,
  `set_bio_gripper_force(force)` (1–100), `open_bio_gripper()/close_bio_gripper()`,
  `set_bio_gripper_position(pos, speed=0, force=50, wait=True)` (G2), `get_bio_gripper_status()`,
  `check_bio_gripper_is_catch()`.
- Vacuum: `set_vacuum_gripper(on, wait=False, timeout=3, delay_sec=None, hardware_version=1)`
  (just toggles tool GPIO 0/1), `get_vacuum_gripper() -> (code, state)` state −1 off / 0 no object /
  1 object held.
- Gripper calls share the 502 command socket → a slow `wait=True` gripper wait blocks nothing
  else (lock released between polls) but adds latency jitter; prefer `wait=False` + status polling
  in the data-collection loop.

---

## 5. Linear track ("linear motor") — the rail

Implemented in `xarm/x3/linear_motor.py`; the track hangs off the **control-box RS-485** port and
is addressed via modbus registers proxied by the controller (`arm_cmd.linear_motor_modbus_r16s/w16s`,
`host_id=XCONF.CONTROL_BOX_RS485_HOST_ID`). Requires controller **fw >= 1.8.0**.

Since SDK 1.17.0 the canonical names are `*_linear_motor_*`; every old `*_linear_track_*` name is
kept as an alias (`xarm_api.py:120-133`), so both spellings work.

```python
# presence / identity
get_linear_motor_version() -> (code, 'a.b.c')
get_linear_motor_sn()      -> (code, sn)      # 14 chars; product SN prefix encodes travel:
                                              # !! x3-level only: XArmAPI 1.18.5 exposes NO
                                              # get_linear_track_sn / get_linear_motor_sn /
                                              # *_version (alias map wrapper/xarm_api.py:120-133;
                                              # __getattr__ raises) -- verified 2026-09-04
                                              # AL1300 -> 0..700 mm, AL1301 -> 0..1000 mm, AL1302 -> 0..1500 mm
# lifecycle
set_linear_motor_enable(enable) -> code
set_linear_motor_back_origin(wait=True, auto_enable=True, timeout=10) -> code   # homing;
        # REQUIRED once after every power-on before set_linear_motor_pos will work
clean_linear_motor_error() -> code
# motion
set_linear_motor_speed(speed) -> code         # int 1..1000  (mm/s)
set_linear_motor_pos(pos, speed=None, wait=True, timeout=100, auto_enable=True) -> code
                                              # pos int, unit **mm**, absolute on the rail
set_linear_motor_stop() -> code
# status
get_linear_motor_pos()        -> (code, pos_mm)
get_linear_motor_status()     -> (code, status)   # bit0: 1=in motion, 0=finished; bit1: stopped
get_linear_motor_is_enabled() -> (code, 0/1)
get_linear_motor_on_zero()    -> (code, 0/1)      # 1 = homed
get_linear_motor_error()      -> (code, err)      # see Linear Motor Error Code list
get_linear_motor_registers(addr=0x0A20, number_of_registers=8) -> (code, {'pos','status','error','is_enabled','on_zero','sci','sco'})
```

- **Units are mm end-to-end.** Internally 1 mm = 2000 encoder counts (`int(pos * 2000)`,
  read back `to_s32(...)/2000`); speed register = `int(speed * 6.667)`. For our 0.65 m rail:
  positions are `0..650` (mm) — the SDK does **not** clamp; command over-travel raises linear-motor
  error 25/26 (command / feedback over software limit), so clamp to `[0, 650]` in our layer.
- `set_linear_motor_pos` refuses to move (returns `APIState.LINEAR_MOTOR_NOT_INIT` = **82**) if
  `on_zero != 1`, i.e. before homing. It auto-enables by default.
- **Runtime detection of a track**: there is no dedicated "has_track" API. Robust probe:

```python
def has_linear_track(arm) -> bool:
    code, status = arm.get_linear_motor_registers()   # modbus read via control box
    return code == 0        # no track -> code 3 (timeout) / 20 HOST_ID_ERR / 23 MODBUS_ERR_LENG
```

  Confirm with `get_linear_motor_sn()` (`AL13*` prefix) and read travel from the SN prefix
  — **not possible through `XArmAPI` 1.18.5** (no SN/version passthrough; `rail.detect()`
  accepts the track on the registers alone and records a warning, 02-hardware §5).
  Also: controller error **111** = control-box external-485 device (track) communication error —
  surfaces in `error_code` if the track drops off mid-session.
- The track's motion is a separate 1-DoF axis: the controller does **not** fold it into arm
  kinematics, collision checking or servo streaming. `set_linear_motor_pos` is position-only,
  blocking-modbus, ~"move and wait" semantics (its `wait` loop polls at 10 Hz). There is **no
  high-rate streaming interface for the track** — for coordinated arm+rail teleop, treat the rail
  as a slow axis (send sparse absolute targets with `wait=False`) and fold its measured position
  into the world-frame TF in software / the MuJoCo twin.
- One quirk: linear-motor APIs are wrapped by `@xarm_is_not_simulation_mode(ret=(0, []))` — with a
  controller in simulation mode they silently return success.

---

## 6. Safety-related APIs

```python
set_collision_sensitivity(value, wait=True)   # 0..5 (0 = off, 5 = most sensitive); volatile unless save_conf()
set_collision_rebound(on)                     # bounce back after collision (fw >= 1.2.11)
set_self_collision_detection(on_off)          # controller-side self-collision model
set_collision_tool_model(tool_type, **params) # end-tool geometry for self-collision:
        # 0 none, 1 xArm gripper, 2 vacuum, 9 gripper G2, ..., 21 cylinder(radius=,height=), 22 cuboid(x=,y=,z=)
        # + x_offset/y_offset/z_offset (mm)
set_reduced_mode(on)                          # master switch; re-set after changing any reduced-* param
set_reduced_max_tcp_speed(speed_mm_s)
set_reduced_max_joint_speed(speed, is_radian=None)
set_reduced_tcp_boundary([x_max, x_min, y_max, y_min, z_max, z_min])   # mm, base frame
set_reduced_joint_range([j1_min, j1_max, ..., j7_min, j7_max], is_radian=None)
get_reduced_states(is_radian=None) -> (code, [on, boundary, max_tcp_v, max_joint_v, joint_ranges, fence_on, rebound_on])
set_fence_mode(on)                            # enforce the boundary as a fence (error C35 when violated)
set_joint_jerk(jerk, is_radian=None); set_joint_maxacc(acc, is_radian=None)
set_tcp_jerk(jerk); set_tcp_maxacc(acc)       # mm/s^3, mm/s^2
set_tcp_load(weight_kg, [cx, cy, cz] mm)      # correct payload => correct torque-based collision detection
set_gravity_direction([0, 0, -1])
save_conf() / clean_conf()                    # persist / factory-reset controller params
emergency_stop()                              # software: set_state(4) loop; does NOT clear errors
```

Notes:
- Collision detection is torque-estimate based; it needs an accurate `set_tcp_load`. On trigger →
  error **C31** (or **C22** self-collision), motion stops, mode resets; recover via
  `clean_error()` + re-enable sequence.
- Reduced mode / fence give *controller-enforced* cartesian and joint envelopes — a good
  independent backstop underneath our MuJoCo-twin software collision checking (which remains the
  primary inter-arm guard, since the controller knows nothing about the *other* arms or the rail
  position).
- `is_tcp_limit(pose)`, `is_joint_limit(joint)` for pre-checks;
  `get_inverse_kinematics(pose, input_is_radian, return_is_radian, limited=True, ref_angles=None)` /
  `get_forward_kinematics(angles, ...)` use the controller's kinematics (fw >= 2.7.103 for
  `ref_angles`, handy for xArm7 redundancy; see also `set_xarm7_ik_redundancy`).

---

## 7. Multi-arm usage (3 arms, 3 NICs)

- **One `XArmAPI` instance per controller IP** — there is no multi-arm multiplexing in the SDK
  (the official dual-arm ROS example simply runs two drivers). Instances are fully independent:
  each owns its own 502 socket, report socket, report thread, and lock.
- **Thread safety:** every uxbus command takes the per-instance `threading.Lock`, so an instance
  may be shared across threads, but concurrent callers serialize — keep the 100 Hz+ servo stream on
  a dedicated thread per arm and do slow queries (gripper, track, temperatures) either from the
  report cache or on a low-rate thread, accepting occasional lock contention. Never share one
  instance across arms/processes.
- 3 NICs wired point-to-point: give each NIC a distinct subnet (e.g. 192.168.10/11/12.0/24) and
  set each controller's IP accordingly (UFACTORY Studio → Settings → Network); the SDK only needs
  the IP to be routable. `arm.sn` / `arm.control_box_sn` identify which physical arm answered —
  assert them at startup against config to catch cabling swaps.
- Heartbeat/keepalive: the SDK pings if the command socket has been idle (`timed_comm_interval`,
  default 30 s); `enable_heartbeat=False` by default. Report-socket disconnects auto-reconnect in
  the report thread.
- The SDK also speaks standard **Modbus-TCP (port 502)** and there is a WebSocket API used by
  UFACTORY Studio (port 18333); not needed for our stack but the web UI must not fight the SDK
  for mode/state (Studio "Live control" grabs mode/state too — don't run both).

---

## 8. Recommended recipes for apollo-mavis-v2

### Per-arm session setup

```python
arm = XArmAPI(ip, is_radian=True, report_type='real')  # 100 Hz feedback on 30003
assert arm.connected
arm.clean_warn(); arm.clean_error()
arm.motion_enable(True)
arm.set_tcp_load(weight, cog); arm.set_collision_sensitivity(3)
arm.set_mode(0); arm.set_state(0)
```

### 100 Hz cartesian servo streaming (teleop / policy)

```python
arm.set_mode(1); arm.set_state(0); time.sleep(0.1)
code, seed = arm.get_position(is_radian=True)      # seed from CURRENT pose
# loop at fixed 100 Hz; clamp per-tick translation to < 10 mm (< ~2-3 mm for smoothness)
code = arm.set_servo_cartesian([x_mm, y_mm, z_mm, r, p, yw], is_radian=True)
if code != 0:  # 1 => controller error latched; 9/-2 => state wrong
    handle_recovery(arm)   # clean_error -> motion_enable -> set_mode(1) -> set_state(0) -> re-seed
```

### Error recovery

```python
def handle_recovery(arm, mode):
    arm.get_err_warn_code(show=True)
    arm.clean_error(); arm.clean_warn()
    arm.motion_enable(True)
    arm.set_mode(mode); arm.set_state(0)
```

### Rail bring-up + detection

```python
code, _ = arm.get_linear_track_registers()          # alias of get_linear_motor_registers
has_track = (code == 0)
if has_track:
    _, on_zero = arm.get_linear_track_on_zero()
    if not on_zero:
        arm.set_linear_track_back_origin(wait=True) # once per power-cycle
    arm.set_linear_track_enable(True)
    arm.set_linear_track_speed(200)                 # mm/s
    arm.set_linear_track_pos(min(max(target_mm, 0), 650), wait=False)
```

---

## 9. Gotchas checklist

1. `is_radian` defaults to **False (degrees)** — always construct with `is_radian=True`.
2. Cartesian is **mm**, not m; convert once at the driver boundary (MuJoCo uses m/rad).
3. Mode 1 ignores `speed/mvacc` — you own smoothing; keep steps < 10 mm and rate fixed.
4. Errors reset mode to 0; recovery must re-run enable/mode/state and re-seed the stream.
5. `set_state(0)` after every `set_mode()` call — mode change moves state out of ready.
6. Rich report (default) is only 5 Hz; use `report_type='real'` (30003, 100 Hz) or a raw socket
   for UI/logging-rate state; port 30000 additionally carries target values, joint currents and
   (fw >= 2.7.100 + `set_external_device_monitor_params`) gripper pos/speed/current.
7. Classic gripper: pulses 0–850, no force sensing/control; G2 gripper has mm units + force %.
8. Linear track homing (`set_linear_motor_back_origin`) is mandatory after power-on; positions are
   int mm; clamp to 650 for our rail; no streaming control of the rail.
9. `emergency_stop()` is software (state 4); wire the hardware e-stop / three-state switch into
   the operator station for DAgger take-over safety.
10. Don't run UFACTORY Studio live-control simultaneously with the SDK stream.
11. Simulation-mode controllers silently no-op gripper/track calls (`@xarm_is_not_simulation_mode`).
