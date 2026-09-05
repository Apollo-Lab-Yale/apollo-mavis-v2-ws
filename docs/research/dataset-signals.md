# Dataset signals for MAVIS v2 — what to record from the arms, rails, Gripper G2 and the microphone, and at what rate

**Date:** 2026-09-03 (decisions of 2026-09-03 applied — §7)

**Sources actually read for this note**

- Vendored xArm-Python-SDK **1.18.5** at
  `apollo-mavis-v2-hardware/.venv/lib/python3.10/site-packages/xarm/`:
  `x3/report.py` (ctypes report structs, `ReportDataStructure.create(port)`),
  `x3/base.py` (report handlers), `x3/servo.py`, `x3/gripper.py` (G2 code
  lines 927–1008), `x3/linear_motor.py`, `x3/ft_sensor.py`,
  `core/wrapper/uxbus_cmd.py`, `core/config/x_config.py`, `wrapper/xarm_api.py`.
- UFACTORY official docs pulled as markdown from GitHub
  `xArm-Developer/ufactory_doc_usermanual` (branches `ufactory_doc_api` =
  private TCP protocol, `ufactory_doc_accessories` = Gripper G2 / F/T sensor /
  linear motor manuals, `ufactory_doc_releasenote`, `ufactory_doc_support_article`);
  *Gripper-G2-User-Manual_V2.7.0.pdf*; *xArm Developer Manual V2.0.1* §2.1.6
  (report ports); `xarm_ros` README + `xarm_ros2` `xarm_driver.cpp` (port-30000
  offsets, firmware gates); `xArm-CPLUS-SDK` `report_data.cc`.
- Installed **lerobot 0.6.1** in `apollo-mavis-v2-runtime/.venv` (Python 3.12):
  `datasets/feature_utils.py`, `datasets/video_utils.py`, `datasets/dataset_writer.py`,
  `datasets/utils.py`, `utils/feature_utils.py`, `configs/video.py`,
  `configs/policies.py`, `datasets/factory.py`, `datasets/dataset_tools.py`;
  upstream PRs #967 (closed) and #2824 (open) via `gh api`; Hub `meta/info.json`
  of ALOHA, DROID, SO-101, OpenArm, LIBERO and OXE xArm ports.
- Our code: `apollo-mavis-v2-core/src/apollo_mavis_v2_core/state.py`,
  `apollo-mavis-v2-hardware/src/apollo_mavis_v2_hardware/{driver,grippers,rail,units}.py`,
  `apollo-mavis-v2-runtime/src/apollo_mavis_v2_runtime/recorder/{features,thread,episode_recorder}.py`,
  `apollo-mavis-v2-runtime/src/apollo_mavis_v2_runtime/devices/microphone.py`,
  `apollo-mavis-v2-runtime/configs/mavis_v2.yaml`; design docs
  `docs/design/10-frames-and-data.md` §6–§9, `02-hardware.md` §4;
  earlier notes `docs/research/xarm-python-sdk.md`, `docs/research/lerobot-data.md`.
- Bench numbers measured on this machine under `/tmp` (PyAV 15.1.0 encoders,
  pyarrow row sizes, lerobot 0.6.1 create/add_frame/save/reload experiments).
  No hardware was touched; firmware-gated claims are marked as such.

**Question.** Which signals from the two xArm7 arms — the Perception Arm (arm
id `view`; wrist D435 + RØDE NT-USB Mini; control box 192.168.2.219) and the
Manipulation Arm (arm id `grip`; xArm Gripper G2 + wrist camera; control box
192.168.1.201) — their linear tracks, the Gripper G2 and the microphone are
worth recording for policy learning — in particular joint torque and the G2's extra capabilities — how
should they be stored in a LeRobot v3 dataset, and at what frequency?

---

## TL;DR

- **Joint torque exists but is an estimate.** xArm7 has no joint torque
  sensors. The 7 floats at byte 59 of report ports 30001/30002/30003
  (`estimated_joint_torque`, SDK `arm.joints_torque`) are "theoretical torque
  from current and the dynamic model, for reference only" (private-TCP register
  55), switchable to raw servo current with register 70 (`set_report_tau_or_i`).
  Our driver already receives it at 100 Hz on port 30003 and **drops it** —
  core `ArmState` has no effort field. Still worth recording: it is the arm's
  only contact/effort channel and is what ALOHA ships as `observation.effort`.
- **Port 30000 is the rich source we are not using.** It carries measured
  joint velocity + acceleration, `actual_joint_current` *and*
  `estimated_joint_torque` simultaneously, target-vs-actual joints/TCP,
  `estimated_tcp_torque`, and (with `set_external_device_monitor_params(2, f)`)
  the G2's position/speed/current/state — none of which port 30003 has. It
  needs controller firmware >= 2.7.101 (>= 2.8.2 for the GPIO/TCP-accel tail)
  and a raw `SocketPort(ip, 30000)` + `ReportDataStructure.create(30000)`;
  the SDK report thread cannot be pointed at it. Firmware of our two control
  boxes is unknown — the first open question.
- **Gripper G2 "force" is a motor-current limit (0–100 %), not sensed force**,
  and the % → N curve is stepwise (~15–63 N measured by UFACTORY at 100 %).
  The G2's real extra signals are: status bits (stopped/moving/grasping),
  Q-axis current (grasp-effort proxy), actual speed, position error and an
  error code — all readable in ONE Modbus read of registers 0x0000–0x0008, or
  streamed on port 30000. Today we read only an int-truncated position at 5 Hz.
- **lerobot 0.6.1 cannot store audio** (`dtype: "audio"` →
  `NotImplementedError`; no microphone device, no audio encode/decode path).
  PR #2824 (open since 2026-01, `observation.audio.<mic>` in `audio/…/*.m4a`)
  is the upstream direction. Fallback: one lossless FLAC per episode under
  `meta/apollo/audio/observation.audio.mic_view/`, a per-frame
  `audio_sample_index` column, and a cheap per-frame level feature.
- **Rate: dataset `fps = 30` (user decision, 2026-09-03)**; record the arm at
  its native 100 Hz into a per-episode side table (`meta/apollo/hires/`) —
  3.33 ticks per frame, so window aggregation must handle 3- and 4-tick
  windows — audio at 48 kHz continuous (1600 samples per frame), gripper at
  100 Hz via the port-30000 monitor (20 Hz polled fallback), rail/health at
  5 Hz hold-last; camera-`seq` dedupe in the recorder; **no depth recording**.
  Budget ≈ 2.2–5 GB/h dominated by video; everything proposed here adds
  < 0.4 GB/h.
- **Schema:** `observation.state`/`action` layouts stay exactly as in
  10-frames §6–§7 (`action` carries only the gripper *open fraction* for the
  gripper); new keys `observation.velocity.<arm>`, `observation.effort.<arm>`,
  `observation.gripper.grip`, `observation.gripper_status.grip`,
  `observation.gripper_cmd.grip` (force/speed **setpoints are state**, user
  decision), `observation.audio_level.mic_view`; the complementary action
  representation `complementary_info.action_abs_ee.<arm>` /
  `complementary_info.action_delta_ee.<arm>` so delta-TCP and absolute-TCP
  policies train from one recording; policy-invisible `complementary_info.*`
  diagnostics; **no `tcp_wrench`** (no F/T sensor on either arm);
  `apollo_schema` → 2. Details in §5, decisions in §7.

---

## 1. Signal catalogue: arm, servo, rail

### 1.1 Where signals come from

The controller exposes one command socket (TCP 502, synchronous, serialized by
the SDK's `UxbusCmd` lock — every poll below competes with the 100 Hz
`set_servo_angle_j` stream) and four *push* report sockets. Rates verified
from Developer Manual V2.0.1 §2.1.6 and the `xarm_ros` report-type table; the
"5 ms / 100 ms" folklore is wrong — periods are 10 ms and 200 ms.

| Port | SDK name | Rate | Frame | Unique content |
|---|---|---|---|---|
| 30003 | `real` (`TCP_REPORT_REAL_PORT`) | **100 Hz** | 135 B (87 B pre-F/T firmware) | state/mode, cmd_num, `actual_joint_angle[7]`, `actual_tcp_pose[6]`, `estimated_joint_torque[7]` (or current), `ft_ext/raw_force[6]`. **No** velocity, err/warn, temps. Our driver's current source. |
| 30001 | `normal` | 5 Hz | 133/145 B | 30003 minus F/T, plus brake/enable bitmasks, `error_code`, `warn_code`, `tcp_offset`, `tcp_payload`, collision/teaching sensitivity, gravity direction. |
| 30002 | `rich` (SDK default) | 5 Hz | 587 B (fw 2.8.2; shorter on older fw, length-gated) | 30001 plus version string, `temperatures int8[7]`, `joint_voltages u16[7]/100`, `joint_currents fp32[7]`, `servo_status_codes`, **target** joint/TCP speeds (SDK misnames them `realtime_*`), GPIO, reduced-mode config, F/T, and (fw >= 2.8.2) the gripper monitor fields. |
| 30000 | `TCP_REPORT_RT_PORT` | undocumented (>= 100 Hz; `xarm_ros2` reads it in a 1 ms loop; UFACTORY's monitor example uses 250 Hz) | 804 B | u64 timestamp; target+actual joint angle/velocity/acceleration; `actual_joint_current[7]` **and** `estimated_joint_torque[7]`; target/actual TCP pose/speed/acceleration; `estimated_tcp_torque[6]`; F/T; `monitor_device_{type,state,pos,speed,current}`; controller + tool GPIO. Needs fw >= 2.7.101 (tail fields >= 2.8.2). Not selectable via `report_type`; open a raw socket. |

Frame layouts are in `x3/report.py` (`_Report3000xDataStructure`); only 30000
carries a controller timestamp — stamp 30001–30003 frames at receipt. The SDK
receive loop keeps only the newest queued frame and runs callbacks
synchronously, so a slow callback silently loses 30003 frames (no counter).

### 1.2 Catalogue

Legend — *rate*: how often a fresh value can exist; *M/D*: measured / derived
(model-based or finite-difference); *fw*: minimum controller firmware where
known; *value*: for policy learning (H high, M medium, L diagnostic/metadata,
– do not record).

| Signal | Accessor (best → fallback) | Rate | Unit | M/D | fw | Value | Notes |
|---|---|---|---|---|---|---|---|
| Joint position (actual) | 30003/30000 `actual_joint_angle[7]`; polled `get_servo_angle(is_real=True)`; `get_joint_states()[0]` | 100 Hz | rad | M | any (`is_real` >= 1.9.110) | **H** | Already recorded (`observation.state`). `get_servo_angle()` without `is_real` is the *command* position. |
| Joint position (target) | 30000 `target_joint_angle[7]`; `get_joint_states(num=(1<<4)+3)` | 100 Hz+ | rad | M (cmd) | >= 2.7.101 / 2.6.107 | M | Target − actual = tracking error = implicit contact/stiffness signal. We already log `q_cmd` in the loop; 30000 gives the controller's view. |
| Joint velocity (actual) | 30000 `actual_joint_velocity[7]`; else finite-difference of 30003 angles (driver EMA α=0.5); `get_joint_states()[1]` (polled) | 100 Hz+ / 100 Hz | rad/s | M / **D** | >= 2.7.101 | M | 30002 `realtime_joint_speeds` is the **target** speed and "cannot be obtained in servoj mode" — do not use. |
| Joint acceleration | 30000 `target/actual_joint_acceleration[7]` | 100 Hz+ | rad/s² | M | >= 2.7.101 | L | Side table only. |
| Joint torque (estimated) | 30003/30001/30002 byte 59 `estimated_joint_torque[7]` (SDK `joints_torque`); 30000 `estimated_joint_torque`; polled `get_joints_torque()` (reg 55) | 100 Hz | N·m | **D** (model residual) | any | **H** | "Theoretical torque … for reference only." Semantics follow reg 70 `report_tau_or_i` (0 = N·m, 1 = A) — force 0 at bring-up and log the flag. Quality depends on `set_tcp_load` (G2 + wrist cam on grip; D435 + mic on view), mount direction, friction identification. |
| Joint current (measured) | 30000 `actual_joint_current[7]`; 30002 `joint_currents[7]` (5 Hz); 30003 byte 59 when `tau_or_i=1`; `get_servo_current(id)` (7 × 502 round trips) | 100 Hz+ / 5 Hz | A | M | >= 2.7.101 for 30000 | M | Raw measurement behind the torque estimate. Only 30000 gives current *and* torque simultaneously at rate. Side table. |
| TCP pose (actual) | 30003/30000 `actual_tcp_pose[6]`; `get_position()` | 100 Hz | mm, rad → m, quat | M (FK incl. `tcp_offset`) | any | **H** | Already recorded (`observation.state` ee dims, recording frame). |
| TCP speed / acceleration (actual) | 30000 `actual_tcp_speed[6]`, `actual_tcp_acceleration[6]` | 100 Hz+ | mm/s, rad/s | M | >= 2.7.101 (accel >= 2.8.2) | L | Side table. 30002 `realtime_tcp_speed` is target. |
| TCP wrench (estimated) | 30000 `estimated_tcp_torque[6]` | 100 Hz+ | N, N·m | **D** | >= 2.7.101 | M | Model-based Cartesian projection of the joint-torque residual. Side table; promote if it proves informative on hardware. |
| TCP wrench (measured) | 30003/30000/30002 `ft_ext_force[6]` / `ft_raw_force[6]`; `get_ft_sensor_data()` | 100 Hz (sensor 200 Hz) | N, N·m | M | >= 1.8.3 + **AI1500 sensor** | H *if sensor present* | Without the optional UFACTORY 6-axis F/T sensor (400 N / 20 Nm, 0.4 N / 0.01 Nm) these 12 floats are zeros/garbage. **MAVIS v2 has no F/T sensor on either arm (user, 2026-09-03) — not recorded.** |
| Controller state / mode | every port `state_mode` byte (state low nibble, mode high nibble); `arm.state`, `arm.mode` | 100 Hz | enum | M | any | L (episode-quality label) | Driver bug: `register_report_callback(report_mode=True)` is not an SDK kwarg → TypeError on real SDK; take `api.mode`. |
| Motion-queue depth | `cmd_num` u16 (every port) | 100 Hz | count | M | any | L | Non-zero in mode 1 means the streamer is ahead. |
| Error / warn code | 30001/30002 bytes 89/90; polled `get_err_warn_code()` (reg 15) | 5 Hz | code | M | any | L (label) | **Not on 30003**; driver polls at 5 Hz today. A raw 30002 reader replaces the poll. |
| Motor enable / brake bits | 30001/30002 bytes 87/88 | 5 Hz | bitmask | M | any | L | |
| Servo status codes | 30002 `servo_status_codes` 7×(status,code) + tgpio; `get_servo_debug_msg()` | 5 Hz | code | M | any | L | Servo error catalogue in `xarm_api_code.md` (10 current detection, 15 overheat, 23 position deviation, 33/34 overload…). |
| Joint temperature | 30002 `temperatures int8[7]`; `get_servo_temperature(id)` | 5 Hz (changes slowly) | °C | M | > 1.2.11 | L | Hold-last per frame; also a per-episode summary (max). |
| Joint bus voltage | 30002 `joint_voltages u16[7]/100`; `get_servo_bus_voltage(id)` | 5 Hz | V | M | any | – (skip) | Brown-out diagnostic only; session-level log is enough. |
| TCP payload / offset / world offset | 30001/30002 `tcp_payload[4]`, `tcp_offset[6]`, `world_offset[6]`; `arm.tcp_load` | 5 Hz (static) | kg, mm | config | any | L (metadata) | One snapshot per episode; torque estimates are only as good as `tcp_payload`. |
| Collision / reduced-mode config | 30001/30002 `collision_sens`, `is_collision_detection`, `collision_tool_type/params`, reduced-mode block; `get_reduced_states()` | static | – | config | any | L (metadata) | G2 self-collision model = tool type 9 (already set in `backstops.py`). |
| Firmware / SN / DH | `arm.version`, `get_robot_sn()`, `get_dh_params()` (fw >= 2.0.0), `get_servo_version()`, `get_gripper_version()`, `get_linear_track_version/_sn()` (NOT on `XArmAPI` 1.18.5 — verified 2026-09-04, 02-hardware §5) | once | str | – | – | L (metadata) | Not recorded anywhere yet (phase-09 todo). Every high-value signal here is firmware-gated. |
| Controller GPIO | 30002 / 30000 `cgpio_*`; `get_cgpio_digital()` | 5 Hz / RT | bits, mV | M | any | – unless wired | Would be a clean pedal / e-stop / episode-boundary channel if we wire one. |
| Tool GPIO | 30000 `tgpio_*` after `set_tgpio_monitor_params` | RT | bits, mV | M | >= 2.7.101 | – | Nothing wired on the G2 flange. |
| Base IMU, PID gains, `get_movement`, harmonic types | assorted polls | – | – | – | – | – | Not recorded. |
| **Rail** position | `get_linear_track_pos()` = Modbus 0x0A20 s32 / 2000 (SDK rounds to int mm); `get_linear_motor_registers(0x0A20, 8)` reads pos+status+error+enabled+on_zero+SCI+SCO in one transaction | polled; SDK's own loops use 10 Hz | mm → m | M | >= 1.8.0 | **H** | Already recorded (`rail.pos`) at 5 Hz via `RailController.step()`. Integer-mm truncation is inherent to the SDK helper; read the register yourself for 0.5 µm counts. |
| Rail velocity | none — speed register 0x0303 is write-only | – | – | **D** (finite-diff of 5 Hz position) | – | – (skip) | `ArmState.dq[7]` is hard-coded 0.0; a 5 Hz finite difference is not worth a column. |
| Rail status / error / SCI | 0x0A22 status (bit0 moving, bit1 stopped), 0x0A23 error (10–49: current, speed, position deviation, soft-limit 25/26, voltage 39/40), 0x0A24 enabled, 0x0A25 homed, 0x0A26 SCI e-stop input, 0x0A27 SCO | 5–10 Hz | bits/code | M | >= 1.8.0 | L (label) | No streaming path for the track: `set_external_device_monitor_params` dev types are grippers only (0 off / 1 xArm Gripper / 2 G2 / 3 BIO G2 / 4 Robotiq) — the "gripper/track monitor" wording in `xarm-python-sdk.md` §9 is wrong. |

### 1.3 Torque is estimated — what that means for us

- UFACTORY support: collision detection "relies on the combination of current
  and dynamic models … comparing the theoretical current and actual current
  of each joint" (error C31 = "Collision Caused Abnormal Current"). The
  reported torque is that model residual expressed in N·m.
- Consequences: (i) the signal is smooth and gravity-compensated only if
  `tcp_payload` (mass + CoG) is right — set it per arm for G2 + wrist camera
  and for D435 + microphone, optionally run `iden_tcp_load` once per tool
  configuration; (ii) friction is modelled, not measured — low-speed contact
  shows up as a bias, not a step; (iii) the same 28 bytes turn into amperes
  if anyone ran `set_report_tau_or_i(1)` and saved the config — record
  `get_report_tau_or_i()` (or 30002 `config_status` bit 2 /
  `arm.is_report_current`) in the session sidecar and refuse to record if it
  is 1.
- It is nevertheless the right thing to record: ALOHA's `observation.effort`
  (Dynamixel present-current scaled to N·m) is exactly this class of signal,
  and contact-rich xArm work in the community uses it. For a *measured* wrench
  the only path would be the AI1500 F/T sensor — none is installed on either
  arm (user, 2026-09-03), so `tcp_wrench` is not recorded (§7).

### 1.4 What we record today vs. what is available

| Layer | Today | Gap |
|---|---|---|
| Hardware driver (`driver.py`) | `XArmAPI(report_type='real')`; 30003 callback → `q`, `ee_pose`, `state`, `cmd_num`; `dq` finite-diff + EMA; `tau` from `api.joints_torque` into `_StateSnap.tau`; err/warn polled 5 Hz; rail pos 5 Hz; G2 position (int mm) 5 Hz | `tau` never leaves the driver; no 30000/30002 reader; no gripper status/current/error; no temps; `report_mode` kwarg bug (TypeError on the real SDK; if it did not raise, `mode` would be pinned to 0 and the monitor thread would latch the arm as a Studio conflict). |
| Core `ArmState` (`state.py:65`) | `q, dq, ee_pose, gripper, rail_pos_m, error_code, warn_code, mode, state, stale, t_mono, wallclock_ns` | no `effort`; `GripperState` has `open_frac, moving, grasped, current` only (no mm, speed, status enum, error). |
| Recorder (`features.py`, `thread.py`) | `action` (8/arm), `observation.state` (16/arm), videos, `intervention`, `action_source`, `wallclock_ns` | nothing else; point-sampled (latest snapshot), no window aggregation, no side table, no audio. |

---

## 2. xArm Gripper G2

Config note: `configs/mavis_v2.yaml` hardware workcell still says
`gripper: xarm` (classic) for the `grip` arm; the cell has a G2
(`gripper: xarm_g2`). Fix before bring-up.

### 2.1 Capabilities (official manual V2.7.0 + SDK 1.18.5)

| Property | G2 (AG1200) | Classic xArm Gripper (G1) | Source |
|---|---|---|---|
| Stroke | 84 ± 1 mm | 84 mm (SDK 0–850 pulses) | manual §6 |
| Gripping force | 10–50 N nominal, set as **1–100 % current limit**; measured ~15–63 N at 100 % (manual chart, 24 mm object) | 30 N max, **no force parameter** | manual §3 chart, xArm manual §8 |
| Closing speed | 15–225 mm/s (`Fn303` r/min) | r/min 1000–5000 | manual §6 |
| Payload / mass | 5 kg / 800 g | – / 802 g | manual §6 |
| Bus | RS-485 Modbus RTU 2 Mbps, slave ID 0x08, FC 0x03/0x06/0x10 via controller tool port (proxied over 502) | same | manual §4 |
| Feedback (spec sheet) | "Position" | "Position" | manual §6 |
| Readable monitoring registers | 0x0000 status (bits1:0 00 stopped / 01 moving / 10 **grasping**; bits3:2 enabled), 0x0001 actual speed r/min, 0x0002 **Q-axis current**, 0x0003 bus current, 0x0004–5 command position (pulses), 0x0006–7 motor position, 0x0008 position error, 0x000F error code, 0x0702–3 position feedback | status/speed/current/error, position | manual §4.1.1 |
| Setpoint registers | 0x0100 enable, 0x0109 fault reset, 0x0303 speed cmd, 0x0500 **grasp current cmd 0–100**, 0x0700–1 pos cmd, 0x0C00–4 combined block [enable, speed, current, pos hi, pos lo] (one FC 0x10 frame — what `set_gripper_g2_position` writes) | | manual §4 |
| Error codes | 0x01 FOC timeout, 0x02 over-V, 0x03 under-V, 0x04 overheating, 0x06 speed feedback, 0x07 overcurrent, 0x08 MCSDK, 0x09 driver protection | 9/11/12/14/15/20/21/23/25/26/33/34/36 | manual §5.1; `x_config.GripperErrorCodeMap` |
| Grasp detection | status bit "grasping"; Blockly has an "object gripped by Gripper G2" block; port-30000 monitor state 2 = object detected while closing | status bit only (gripper fw >= 3.4.3) | manual §3; support article |
| Streaming | `set_external_device_monitor_params(dev_type=2, frequency)` → controller polls the G2 and publishes type/state/pos (mm, s16)/speed (mm/s, s16)/current (mA, s16) on port 30000 (fw >= 2.7.101; UFACTORY example uses 250 Hz); mirrored into 30002 at 5 Hz on fw >= 2.8.2 | dev_type 1 | `xarm_api.py:4660`; release notes |
| Not documented | temperature register (despite error 0x04), firmware-version register (SDK reads G1's 0x0801–0x0803; unverified on G2), units of 0x0002/0x0003 | | |

SDK conversions (`x3/gripper.py`): `pulse = int((asin((mm-16)/110) [deg] + 8.33) * 18.28)`
(0 mm → 0, 84 mm → ~850); `mm = 110*sin(rad(pulse/18.28 - 8.33)) + 16`, which
`get_gripper_g2_position` **truncates to int mm**; speed register
`= int(((mm/s*60)/9.88235 + 140)/0.4)`. `get_gripper_g2_speed`/`_force` read
the **setpoint** registers 0x0303/0x0500, not measurements, and are not
exported by the `XArmAPI` wrapper (reach them via `arm._arm.*`).

### 2.2 Force is a current limit — record the setpoint and the current, not Newtons

The only force chart UFACTORY publishes (manual §3, `g2_torque.png`) plots
measured N vs commanded % for several speeds at closed position 230 pulses:
a speed-dependent floor of ~15 N (slow) to ~23 N (fast) below 20 %, then
plateaus of ~23 N @30 %, ~32 N @35 %, ~35–43 N @50–55 %, ~48 N @75–80 %,
~58 N @85 %, ~63 N @100 %. Six-ish steps, non-linear, speed-dependent, and
above the 50 N spec at 100 %. Therefore: store the commanded % (fraction) and
the measured Q-axis current; derive Newtons offline only after a bench
calibration with our finger pads (open question §6). Minimum achievable grip
is ~15 N, not 10 N — plan fragile-object tasks around low speed *and* low %.
The manual also states the G2 "is not intended for applying force to objects
or surfaces" — no pressing tasks.

#### 2.2.1 Can the grasp-detection bit protect against over-exertion?

Short answer: **no, not by itself — the protection is the current limit set
before closing; the bit only reports afterwards that the limit was reached.**
From the manual/SDK facts above:

- The G2 has **no force sensor** (spec-sheet feedback: "Position", §2.1). Its
  "gripping force" is the grasp current limit, register 0x0500 (1–100 %),
  written *before* the motion as part of the 0x0C00 block that
  `set_gripper_g2_position` sends. Whatever that limit is when the fingers
  meet the object is the force ceiling: ~15–63 N per the manual's chart, with
  a **speed-dependent floor of ~15 N (slow) to ~23 N (fast) below 20 %**.
  Below that floor there is no protection at all — a fragile object needs low
  speed *and* low %, or a different gripper.
- The status bit (0x0000 bits1:0 = `10` "grasping"; port-30000 monitor state 2
  "object detected while closing") is a **post-hoc indicator that the motor
  stalled at the current limit**. It becomes true only after the ceiling has
  already been applied to the object. It is good for two things: (i) stop
  commanding further closure — do not keep sending smaller position targets,
  the controller is already holding at the limit — and (ii) label the grasp
  (`observation.gripper_status.grip == 2`). It cannot lower the force.
- The **Q-axis current** (0x0002; monitor `current`, mA) is the continuous
  effort signal. A monitoring loop can read it at 100–250 Hz via the
  port-30000 monitor (`set_external_device_monitor_params(2, f)`,
  fw >= 2.7.101) or at <= 50 Hz via Modbus (one 0x0000–0x0008 read on the 502
  lock) and **back off** — re-issue the 0x0C00 block with a lower 0x0500 % or a
  wider position — when the current rises faster than expected for the
  object; the reaction is bounded by the tens of ms a block write takes to
  land, so it softens the ceiling rather than replacing it.
- Therefore: choose % and speed *before* closing, per object class; treat the
  grasp bit as "contact reached the limit" (stop, label); use the current as
  the effort observation and, where a soft grasp matters, as the input of a
  back-off loop. The manual's "not intended for applying force to objects or
  surfaces" stands.

### 2.3 Recommended gripper features

| Feature | Source (best → fallback) | Rate | Why |
|---|---|---|---|
| `grip_gripper.pos_mm` (float, **from raw pulses** with the sine map, no int truncation) | 30000 `monitor_device_pos` (int mm — also truncated; prefer the pulse register when polling) → `get_gripper_g2_register(0x0702, 2)` | 100 Hz / 20 Hz | 1 mm truncation = 1.2 % of stroke; matters for thin objects. Keep `gripper.pos` (open fraction) in `observation.state` as today for compatibility. |
| `grip_gripper.vel_mm_s` | 30000 `monitor_device_speed` → 0x0001 r/min via the SDK speed formula | 100 / 20 Hz | Closing-speed profile encodes contact (speed collapses on grasp). |
| `grip_gripper.current_a` | 30000 `monitor_device_current` (mA) → 0x0002 Q-axis current (units unverified; bench-calibrate) | 100 / 20 Hz | The G2's only grasp-effort signal; the actual "force" observation. |
| `grip_gripper.status` (int8 enum) | 30000 state byte: 0 moving/no object, 1 object detected opening, 2 object detected **closing**, 3 stopped at target/no object → 0x0000 bits1:0 mapped onto the same enum (stopped → 3, moving → 0, grasping → 2), −1 unknown | 100 / 20 Hz | Discrete grasp label; cheap success/failure heuristic. |
| `grip_gripper.error` (int) | 0x000F on status fault or at 1 Hz; mirror `ClassicGripper._poll_errors` | 1 Hz | Episode filtering; G2Gripper has no error poll today. |
| `grip_gripper.force_cmd`, `.speed_cmd` (fractions) | `GripperCommand.force/speed` as sent (default 50 %, 150 mm/s) | per frame | The recorded command must fully determine the G2 block write; today only `open_frac` is stored. **State, never `action`** (user, 2026-09-03: "they are state information") — stored as `observation.gripper_cmd.grip` (§5.2); `action` keeps only the open fraction. |

Polling budget: one combined `arm._arm.get_gripper_g2_register(0x0000, 9)`
returns status, speed, Q-axis current, bus current, command position, motor
position and position error in a single tool-RS-485 transaction; at 20 Hz on
the 502 lock this is safe, 50 Hz is the ceiling. The SDK helpers hide 2–3
round trips each (`get_gripper_g2_position` = position + error read;
`set_gripper_g2_position` defaults = enable-block write + `wait_move()` +
error read, and `wait_move` **blocks until the arm stops in mode 0**) — call
with `no_check=True`/`wait_motion=False` and never above 10 Hz. Above that,
use the controller monitor on port 30000 (zero traffic on 502; re-issue
`set_external_device_monitor_params` after every controller error, as the
docstring requires).

---

## 3. Microphone and audio in LeRobot v3

### 3.1 lerobot 0.6.1 (installed)

- No audio feature type: `validate_feature_dtype_and_shape`
  (`lerobot/datasets/feature_utils.py:270-297`) accepts numpy dtype strings,
  `image`/`video`, `string`, `language`; anything else raises
  `NotImplementedError("The feature dtype 'audio' is not implemented yet.")`
  (verified in `/tmp`).
- No microphone device class; `StreamingVideoEncoder` adds a video stream
  only; `decode_video_frames_pyav` still carries
  `# TODO(rcadene): also load audio stream at the same time`.
- The only audio-aware code is metadata: `get_audio_info()` probes an mp4's
  first audio stream and merges `has_audio`, `audio.channels`, `audio.codec`,
  `audio.sample_rate`, … into the **video** feature's `info`;
  `concatenate_video_files()` remuxes audio streams when appending episodes.
  So audio muxed into a camera mp4 is tolerated on read/concat, but nothing
  writes or decodes it — and muxing audio into a *video* container binds the
  mic to one camera and to lerobot's per-frame `pts = frame_index` grid.
- Numeric per-frame blocks **do** work: `observation.audio.mic0` float32
  `(1920, 1)` and int16 `(1920,)` (48 kHz / 25 fps; `(1600,)` at 30 fps) create, `add_frame`,
  `save_episode`, `finalize` and reload fine (Array2D parquet columns);
  `stats.json` collapses >= 2-D features to a scalar. Cost ~96 KB/s for
  int16 mono, i.e. the audio would be ~5.8 MB/min of parquet.

### 3.2 Upstream direction — PR #2824

PR #967 ("adding the audio modality") was closed unmerged 2026-01-20 and
superseded by PR #2824 "feat(audio dataset): Adding support for audio and
high frequency data" (open, last update 2026-04-29, +5230/−190, 66 files).
Design: feature `dtype: "audio"`, key `observation.audio.<mic>`, `shape
(n_channels,)`, `names ["channels"]`, `info {"sample_rate": ...}`; audio is
**not** in parquet but in `audio/{audio_key}/chunk-XXX/file-XXX.m4a` (AAC via
ffmpeg, 100 MB shards), recorded as per-episode WAV
`raw_audio/{audio_key}/episode_XXXXXX.wav` then encoded at save; episode
metadata gains `audio/<key>/chunk_index|file_index|from_timestamp`; the
reader decodes a fixed 0.5 s window ending at each frame timestamp
(torchcodec `AudioDecoder`, torchaudio fallback) with a 1.0 s pre-roll;
`AudioProcessorStep` makes a 16 kHz mel-spectrogram 224×224×3 image; ACT
gets an audio ResNet backbone. Not in any release; names may still change.

### 3.3 What we should do now (fallback that converts 1:1 later)

- Hardware facts: RØDE NT-USB Mini = ALSA card `Mini`, **S24_3LE mono
  48 kHz only**, owned by PulseAudio 15.99 (direct `hw:` open → EBUSY).
  `devices/microphone.py` already captures through Pulse at 48 kHz float32 in
  1920-sample blocks (25 Hz) via sounddevice/PortAudio or `parec
  --latency-msec=50`, but publishes only a `MicFrame` level/envelope and
  discards PCM.
- Store the master as **lossless FLAC, 48 kHz, mono, int16**, one file per
  episode: `<root>/meta/apollo/audio/observation.audio.mic_view/episode_{index:06d}.flac`
  (PyAV `flac` encoder is available; ~180–200 MB/h vs 346 MB/h WAV,
  518 MB/h 24-bit). Reasons for these choices: 48 kHz not 16 kHz because
  scrape/click/impact transients live in 8–24 kHz and a 16 kHz mel front-end
  (what PR #2824 uses) can always be derived offline; 16-bit not 24-bit
  because the mic's noise floor does not justify it and Pulse resamples
  anyway; FLAC not WAV because it is lossless and half the size; under
  `meta/apollo/` (our sidecar tree, travels with `push_to_hub`) rather than a
  top-level `audio/` so a future converter to #2824's `audio/<key>/chunk-…m4a`
  layout does not collide.
- Alignment: store in the **main table** a per-frame
  `complementary_info.audio_sample_index.mic_view` int64 = index of the FLAC
  sample corresponding to the frame's `wallclock_ns`, computed from the
  capture stream's running sample counter (not from wallclock arithmetic),
  plus in the episode sidecar the first-sample `wallclock_ns`/`t_mono`, the
  reported Pulse/PortAudio latency and the clap-test offset (open question).
  This survives USB clock drift over a 10-min episode where
  `frame_index/fps` alone would not.
- Also record a cheap aligned feature in the main table:
  `observation.audio_level.mic_view` float32 (2,) = `[rms_dbfs, peak_dbfs]`
  of the latest `MicFrame` (25 Hz already). It is policy-consumable today
  without any audio decoding and is a decent contact/impact cue.
- If a policy needs waveforms before #2824 lands, add the verified per-frame
  int16 block `(1600,)` at 30 fps as an *additional* dataset variant — not
  by default (bloats parquet, scalar stats).

---

## 4. Recording frequency

### 4.1 Decision: dataset `fps = 30` (user, 2026-09-03); 100 Hz side table; 48 kHz audio

Two researchers disagreed (25 vs 30); the first draft of this note chose 25
(then the `RecorderConfig.fps` default). **The user decided 30**: it is
lerobot's `--dataset.fps` default and what SO-100 / OpenArm ship (ALOHA 50,
DROID 15, LIBERO 10/20). The 20–30 band stays binding; `RecorderConfig.fps`
default becomes 30. The comparison, kept for the record:

| Argument | 25 fps | 30 fps |
|---|---|---|
| Control loop 100 Hz → ticks per frame | exactly 4 (uniform windows, integer `interpolation_multiplier`) | 3.33 (windows alternate 3/4 ticks) |
| Cameras at 30 fps | every frame gets a distinct image, 0–33 ms age jitter, 5/30 images unused | clock drift → periodic duplicate/skipped images; recorder dedupes on control tick, not camera `seq` |
| 48 kHz audio samples per frame | 1920 (integer) | 1600 (integer) |
| Existing `MicFrame` cadence | 25 Hz — matches | – |
| Operator bandwidth | hand motion 1–3 Hz, tremor 8–12 Hz, One Euro `min_cutoff` 1 Hz, 25 mm / 0.2 rad leash → Nyquist 12.5 Hz loses nothing of intent | same |
| Policy horizons (frames) | ACT chunk 100 = 4.0 s; pi0/smolvla 50 = 2.0 s; diffusion horizon 64 = 2.56 s, `n_obs_steps=2` = 80 ms | 3.3 s / 1.7 s / 2.1 s |
| DAgger `T_blend` 0.3 s | 7–8 frames | 9 frames |
| Ecosystem | lerobot `--dataset.fps` default 30; SO-100/OpenArm 30; ALOHA 50; DROID 15; LIBERO Hub ports 10 | – |

Consequences of 30 that the recorder must absorb (they were the arguments
for 25; now they are engineering items):

1. **3.33 control ticks per frame** — windows alternate 3 and 4 ticks (2–5
   under jitter). Window aggregation (§4.2, §4.4) must handle a **variable**
   tick count: means are over whatever ticks fell in the window,
   `ticks_in_frame` is stored per arm, and tests assert the per-episode
   histogram is `{3, 4}` with mean 3.33 ± 0.05 — never a constant.
   `delta_ee` is an integral over the window, so it is unaffected.
2. **Camera-`seq` dedupe is needed.** Cameras also run at 30 fps; the two
   clocks drift, so a 30 Hz capture periodically sees the same image twice
   or skips one. `RecorderThread._capture` must dedupe on `CameraFrame.seq`
   per camera (re-use the previous image only when no fresh frame exists and
   record it in `camera_age_ms`) instead of assuming a fresh image per
   control-tick capture.
3. **1600 audio samples per frame** (48 kHz / 30) — still an integer. The
   `MicrophoneReader` block is 1920 samples (25 Hz); either re-block to 1600
   (30 Hz) or keep 1920 and let `observation.audio_level` be the latest block
   (<= 40 ms old). `audio_sample_index` is the alignment either way.
4. Horizons shrink slightly (ACT chunk 100 = 3.3 s, pi0/smolvla 50 = 1.7 s,
   diffusion 64 = 2.1 s); DAgger `T_blend` 0.3 s = 9 frames.

Mixing with 10–15 fps corpora still requires offline resampling. Consider
running the D435 color at 848×480@60 or 640×480@60 and sampling at 30 to cut
image age jitter to <= 16.7 ms.

### 4.2 Per-signal rates

| Class | Capture rate | Stored where | Per-frame aggregation |
|---|---|---|---|
| Joint pos / TCP pose / rail pos / gripper pos | 100 Hz (30003 or 30000); rail 5–10 Hz; gripper 100 Hz monitor or 20 Hz poll | main table (`observation.state`, as today) + every tick in the side table | last-in-window (positions are alias-free) |
| Joint velocity, estimated torque, gripper current/speed, audio level | 100 Hz | main table (`observation.velocity/effort/gripper/audio_level`) + side table | **window mean** over the frame's ticks (3 or 4 at 30 fps — variable, §4.1); rate-like/noisy quantities must not be point-sampled |
| Joint current, tracking error, TCP speed/accel, estimated TCP wrench, q_cmd | 100 Hz (30000) | side table only | raw |
| Gripper status enum | 100 / 20 Hz | main table | latest, but any tick with state 2 (object detected closing) in the window wins |
| Mode/state/cmd_num/err/warn/stale, rail status/error, gripper error, temps | 5 Hz (raw 30002 reader replaces the err/warn poll) / 1 Hz | main table `complementary_info.arm_status.<arm>`, hold-last; errors also as episode events | latest |
| Audio | 48 kHz continuous | FLAC sidecar + `audio_sample_index` | – |
| Config / versions / tcp_load / tau_or_i | once | session + episode sidecar | – |

Port-30000 rate is undocumented; the side table stores whatever the
controller sends, stamped at receipt, plus the frame's own u64 timestamp so
the rate (and the timestamp unit) can be established from the first
hardware session.

### 4.3 Storage per hour (2 arms, 30 fps, measured on this machine)

| Stream | Size / h | Basis |
|---|---|---|
| RGB video, per 640×480 stream, `h264_nvenc` qp30 g2 bf0 | 0.9–2.3 GB (2.05 Mbit/s synthetic camera-like content at 30 fps; 5 Mbit/s on heavy noise) | PyAV bench in `/tmp/encbench` |
| 2 RGB streams (Manipulation Arm wrist + Perception Arm wrist) | 1.8–4.6 GB | |
| Main parquet today (action 16 + state 32 + 3 cols + 5 bookkeeping) | ~25 MB (227 B/row × 108 k rows) | pyarrow snappy, random-walk float32 |
| Main parquet with §5 additions (~45 extra float dims + 2 × 8–10 complementary action dims + ~50 status dims + ints) | ~70 MB (~650 B/row) | same method |
| Side table, 100 Hz, ~80–100 float32 dims + keys | 105–150 MB (291 B/row at 70 dims; float32 is incompressible under snappy) | measured |
| Audio FLAC 48 kHz mono int16 | ~180–200 MB (WAV 346 MB) | PCM arithmetic + typical FLAC ratio |
| D435 depth — **not recorded** (user, 2026-09-03); for reference, lossless HEVC gray12le (lerobot default) | 5.9 GB per stream, 89 enc fps CPU-bound | PyAV bench |
| **Total, recommended config** | **≈ 2.2–5 GB/h** | |

NVENC is not the constraint (2 streams × 30 fps = 60 enc fps vs ~460 fps per
session measured; 8 sessions allowed); CPU-side lossless depth would have
been, which is one more reason not to record it.

### 4.4 Rules to write into 10-frames §7.5

1. `delta_ee` stays the *net* commanded TCP displacement between consecutive
   captures (an integral — alias-free). After a camera-stale drop, reset
   `_pending` (or scale by elapsed ticks) so a delta never spans two frames.
2. Positions/poses: last-in-window. Rates and noisy quantities (velocity,
   effort, gripper current, audio level): mean over the window's ticks.
3. Store `ticks_in_frame` per arm (in `arm_status`); at 30 fps assert the
   per-episode histogram is `{3, 4}` with mean 3.33 ± 0.05 in tests — never a
   constant (§4.1).
4. Check `StreamingVideoEncoder._dropped_frames` after each `save_episode`
   and mark the episode (`frames_dropped_video` in the sidecar): lerobot
   drops the image with a warning when the encoder queue is full for 0.1 s
   but still appends the row, shifting every later video frame — the
   dataset would be silently misaligned.
5. Dedupe camera frames on `CameraFrame.seq` per camera (30 fps cameras vs a
   30 Hz capture drift against each other); a re-used image is recorded as
   such via `camera_age_ms`, never silently.
6. Write the complementary action block (§5.2 "Action representations") from
   the same `observation.state` row the recorder just built, so
   `state ⊕ delta == abs` holds exactly in float32 for every frame.

---

## 5. Schema proposal — amendment to `10-frames-and-data.md` §7 (`apollo_schema = 2`)

### 5.1 Principles

- **`observation.state` and `action` layouts are unchanged** (§6, §6.1, §7.2):
  existing checkpoints, `PolicySpec.state_names` selection and all tests keep
  working. New signals are separate keys (ALOHA `observation.effort`
  precedent), never appended inside `observation.state` (OpenArm style).
- **Key prefix = who may see it.** lerobot 0.6.1 `dataset_to_policy_features`
  (`utils/feature_utils.py:139-182`) classifies `observation.*` as STATE
  (normalized, `observation_delta_indices`-stacked, visible to policies),
  anything starting with `action` as ACTION, and **skips every other prefix**.
  Upstream ACT/pi0/smolvla/diffusion consume only `observation.state`
  (`robot_state_feature` requires that exact key), so extra `observation.*`
  keys are inert for them but available to our policies. Diagnostics and
  non-policy commands therefore go under `complementary_info.*` (HIL-SERL
  precedent) — stored, stat'ed, invisible to `input_features`.
- **Per-arm keys**, not one concatenated vector: the arms are heterogeneous
  (grip has the gripper, view has the microphone), a one-arm policy selects
  by key rather than by slice, and the set of keys stays valid for 1-arm
  datasets of the same cell.
- **The feature set is fixed by the hardware configuration**, not by
  firmware: a key exists for every dataset of the cell and is filled from
  the best available source with a `source` note in `info`. There is no
  conditional key any more: `observation.tcp_wrench.grip` is gone because
  neither arm has an F/T sensor (user, 2026-09-03).
- **Setpoints are state, not action (user, 2026-09-03).** The G2 force
  (current-limit %) and speed setpoints, like the measured current and speed,
  describe the gripper's configuration when the frame was taken — "they are
  state information". `action` carries only the gripper open fraction
  (10-frames §6). Hence `observation.gripper_cmd.grip`, not
  `complementary_info.gripper_cmd` and never `action` dims — whether or not
  teleop ever modulates them.
- **Both action representations, one dataset (user, 2026-09-03).** Canonical
  `action` = the session's action space (default `delta_ee`); the
  complementary representation is stored under `complementary_info.action_*`
  so delta-TCP and absolute-TCP policies train from the same recording (§5.2
  "Action representations"). The prefix matters: lerobot 0.6.1
  `dataset_to_policy_features` maps **every key starting with `action`** to
  `FeatureType.ACTION` — `lerobot/utils/feature_utils.py:172-173`
  (`elif key.startswith(ACTION): type = FeatureType.ACTION`, with
  `ACTION = "action"` at `lerobot/utils/constants.py:33`; verified in the
  installed runtime venv) — so a sibling named `action_abs_ee.grip` would be
  picked up as a second action feature and break `make_policy`.
  `complementary_info.*` falls into the `else: continue` branch and is
  skipped.

### 5.2 Feature table (MAVIS v2: arms `grip`, `view`, both railed; `delta_ee`)

Unchanged (10-frames §7.2/§7.3): `action` float32 (16,) — the session's
action space, default `delta_ee`, gripper dim = open fraction only —
`observation.state` float32 (32,), `observation.images.<camera_id>` video
(480, 640, 3) at **30 fps**, `intervention` bool (1,), `action_source` int8
(1,), `wallclock_ns` int64 (1,). `features["action"]["info"]["apollo_schema"] = 2`.

New, policy-consumable:

| Feature | dtype | shape | names | info | Source / fill |
|---|---|---|---|---|---|
| `observation.velocity.grip`, `observation.velocity.view` | float32 | (7,) | `<arm>_joint1.vel … <arm>_joint7.vel` | `{"unit": "rad/s", "source": "xarm.30000.actual_joint_velocity" \| "finite_diff_30003_ema", "aggregation": "window_mean"}` | 30000 measured; else driver finite-difference |
| `observation.effort.grip`, `observation.effort.view` | float32 | (7,) | `<arm>_joint1.effort … <arm>_joint7.effort` | `{"unit": "N*m", "source": "xarm.estimated_joint_torque", "model_based": true, "report_tau_or_i": 0, "aggregation": "window_mean"}` | 30003 byte 59 (or 30000); refuse to record if `tau_or_i == 1` |
| `observation.gripper.grip` | float32 | (3,) | `grip_gripper.pos_mm, grip_gripper.vel_mm_s, grip_gripper.current_a` | `{"model": "xarm_g2", "stroke_mm": 84.0, "source": "xarm.30000.monitor_device" \| "modbus_0x0000_0x0008", "current_calibrated": false, "aggregation": ["last", "window_mean", "window_mean"]}` | monitor stream or 20 Hz combined register read; `pos_mm` from pulses via sine map (float) |
| `observation.gripper_status.grip` | int8 | (1,) | None | `{"labels": {"-1": "unknown", "0": "moving_no_object", "1": "object_detected_opening", "2": "object_detected_closing", "3": "stopped_at_target"}}` | 30000 state byte or 0x0000 bits mapped |
| `observation.gripper_cmd.grip` | float32 | (2,) | `grip_gripper.force_cmd, grip_gripper.speed_cmd` | `{"model": "xarm_g2", "force_cmd": "grasp current limit, fraction of 1-100 %", "speed_cmd": "fraction of 15-225 mm/s", "defaults": [0.5, 0.643]}` | `GripperCommand.force/speed` in force for the frame's gripper target (`StateSnapshot.gripper_cmd`); **state, never `action`** (user, 2026-09-03) |
| `observation.audio_level.mic_view` | float32 | (2,) | `mic_view.rms_dbfs, mic_view.peak_dbfs` | `{"sample_rate": 48000, "channels": 1, "block_samples": 1920 \| 1600, "audio_sidecar": "meta/apollo/audio/observation.audio.mic_view/episode_{index:06d}.flac"}` | latest `MicFrame` |

`observation.tcp_wrench.grip` (first draft: conditional on an AI1500 F/T
sensor) is **dropped** — neither arm has a sensor (user, 2026-09-03); the 12
F/T floats on 30003/30000 are zeros/garbage and are not recorded.

New, policy-invisible (`complementary_info.*`):

| Feature | dtype | shape | names | Notes |
|---|---|---|---|---|
| `complementary_info.arm_status.grip`, `complementary_info.arm_status.view` | float32 | (18,) view / (20,) grip | `<arm>_ctrl.mode, <arm>_ctrl.state, <arm>_ctrl.cmd_num, <arm>_ctrl.error_code, <arm>_ctrl.warn_code, <arm>_ctrl.stale, <arm>_ctrl.ticks_in_frame, <arm>_ctrl.report_age_ms, <arm>_joint1.temp_c … <arm>_joint7.temp_c, <arm>_rail.status, <arm>_rail.error, <arm>_rail.age_ms` (+ `grip_gripper.error, grip_gripper.age_ms` on grip) | integers stored exactly in float32 (< 2^24); hold-last for 5 Hz / 1 Hz sources; `info["labels"]` for `mode`/`state`/`rail.status` bits. Dims always derived from `names`. |
| `complementary_info.action_abs_ee.grip`, `complementary_info.action_abs_ee.view` | float32 | (10,) | `<arm>_ee.x, <arm>_ee.y, <arm>_ee.z, <arm>_ee.qw, <arm>_ee.qx, <arm>_ee.qy, <arm>_ee.qz, <arm>_gripper.pos, <arm>_rail.pos` | Present when `action_space == "delta_ee"` (the default): the absolute TCP target the executed delta reached, in the arm's recording frame (`abs = state ⊕ delta`; 10-frames §6 `abs_ee` block layout). `info = {"action_space": "abs_ee", "frames": {...}, "derived": "state ⊕ action"}`. See "Action representations" below. |
| `complementary_info.action_delta_ee.grip`, `…view` | float32 | (8,) | `<arm>_ee.dx, <arm>_ee.dy, <arm>_ee.dz, <arm>_ee.drx, <arm>_ee.dry, <arm>_ee.drz, <arm>_gripper.pos, <arm>_rail.dpos` | Present when `action_space == "abs_ee"`: the TCP-relative delta equivalent of the executed absolute target (`delta = action ⊖ state`; 10-frames §6 `delta_ee` layout). Exactly one of the two `action_*` blocks exists per dataset. |
| `complementary_info.camera_age_ms` | float32 | (n_cams,) | camera ids in recorded order | recorder `now − frame.t_mono` per camera; quantifies image/state misalignment (today unrecorded, drop threshold 2/fps). |
| `complementary_info.tick` | int64 | (1,) | None | control-loop tick of the capture; join key into the side table. |
| `complementary_info.audio_sample_index.mic_view` | int64 | (1,) | None | FLAC sample index at the frame's capture instant (from the capture stream's sample counter). |

**Action representations (user, 2026-09-03): record both, train either.**

- **Canonical `action`** is the session's action space — default `delta_ee`
  (10-frames §6): per arm `[ee.dx, ee.dy, ee.dz, ee.drx, ee.dry, ee.drz,
  gripper.pos, rail.dpos]`, the *executed* per-frame increment (post-gate,
  12-dagger §4).
- **Complementary representation** under `complementary_info.action_abs_ee.<arm>`
  (for `delta_ee` sessions) or `complementary_info.action_delta_ee.<arm>` (for
  `abs_ee` sessions). Not `action*` (lerobot would treat it as ACTION, §5.1),
  not `observation.*` (it is a target, not a measurement, and would leak the
  label into `input_features`). Per-arm keys follow the per-arm rule above.
- **Frame semantics, precisely.** Absolute poses — the `ee.*` dims of
  `observation.state`, `abs_ee` actions, `action_abs_ee` — are expressed in
  the arm's per-session **recording frame** `F = SessionSpec.frames[arm]`:
  default `arm_base:<arm>` (the arm's own base; for a railed arm this frame
  translates with the carriage, 10-frames §2.2), alternatively `world` or a
  static `camera:<k>`; `ee:` is **not** a legal recording frame (10-frames
  §5.1 rejects it). Deltas — `delta_ee` actions, `action_delta_ee` — are
  **TCP-relative**: increments applied to the current *measured* TCP pose,
  with the rotation about the TCP origin and the increment's axes those of
  `F` (left/space composition, 10-frames §3.2: `p' = p + δp`,
  `q' = rotvec_to_quat(δr) ⊗ q`). "Relative" therefore refers to the TCP
  *pose* as the anchor, not to the tool axes; consequently deltas transform
  between recording frames by rotation only — as free vectors, translations
  cancel (10-frames §3.3). The gripper dim is the absolute open fraction in
  both representations; the rail dim is `rail.pos` (absolute, along the rail
  axis) vs `rail.dpos` (delta), both frame-invariant scalars (10-frames §3.4).
- **Determinism.** Because `observation.state` carries the absolute TCP pose
  in `F` for every frame, the two representations are mutually derivable
  offline without any other data:
  `abs = state ⊕ delta`: `p_abs = p_s + δp`, `q_abs = rotvec_to_quat(δr) ⊗ q_s`
  (canonicalised `w >= 0`), `grip_abs = grip`, `rail_abs = clamp(rail_s + rail_δ, 0, 0.65)`;
  `delta = abs ⊖ state`: `δp = p_abs − p_s`, `δr = quat_to_rotvec(q_abs ⊗ q_s⁻¹)`,
  `rail_δ = rail_abs − rail_s`. The recorder writes the complementary block
  with exactly this arithmetic on the same `state` row (round trip exact to
  float32) and records
  `features["action"]["info"]["complementary_action"] = {"key_prefix":
  "complementary_info.action_abs_ee", "action_space": "abs_ee"}`; the frame
  map is the same `frames` dict on both `info` blocks (10-frames §5.2).
- **Offline converter** `apollo_mavis_v2_runtime/tools/convert_action_space.py
  --to abs_ee|delta_ee <root> <out_root>` produces a **training view** whose
  `action` is the other representation: videos and sidecars are hard-linked,
  the parquet `action` column is rewritten from the `complementary_info.action_*`
  blocks (re-derived from `observation.state` if a block is missing), the two
  `info` blocks swap roles, `action_space`/`action_names` are set accordingly,
  `stats` for `action` are recomputed (`lerobot.datasets.dataset_tools`), and
  `info["derived_from"]` records the source repo + sha. One recording thus
  serves both a delta-TCP (hil-serl style, DAgger-intended, 12-dagger §6) and
  an absolute-TCP (ACT / diffusion chunked) policy with an identical frame
  map; the checkpoint frame checks of 10-frames §5.3 apply unchanged.
  Round-trip test: convert → convert back == original to float32.

Deliberately **not** in the main table: joint current (side table; the torque
estimate is its modelled form and both need 30000 to coexist), joint/TCP
acceleration, target-vs-actual, estimated TCP wrench (side table until
proven), bus voltages (session log), rail velocity (unobservable at 5 Hz),
F/T fields (no sensor), D435 depth (user, 2026-09-03), GPIO/IMU/PID (nothing
wired).

### 5.3 Sidecars (extend 10-frames §9)

```
<root>/meta/apollo/
├── session_{session_id}.json
├── episodes/episode_{index:06d}.json
├── scenes/{sha256[:16]}.xml
├── hires/episode_{index:06d}.parquet                      # NEW: 100 Hz side table
└── audio/observation.audio.mic_view/episode_{index:06d}.flac   # NEW: audio master
```

**`hires/` side table** — one row per control tick during the episode,
written by our own `pyarrow.parquet.ParquetWriter` (atomic `.tmp` +
`os.replace`, deleted on discard), columns:
`episode_index, frame_index` (dataset frame whose window the tick falls in;
−1 before the first capture), `tick, wallclock_ns, t_mono`,
per arm: `q[7|8]` measured, `dq[7]`, `effort[7]`, `current[7]` (30000 or NaN),
`q_target[7]` (30000) and `q_cmd[7|8]` (post-gate), `ee_meas[7]`/`ee_cmd[7]`
in the recording frame, `tcp_speed[6]`, `tcp_wrench_est[6]` (30000 or NaN),
`ctrl_mode, ctrl_state, cmd_num, stale`, `report_ts_u64` (30000 timestamp,
unit TBD), `gripper_cmd[3]` (frac, force, speed), `gripper_meas[4]` (pos_mm,
vel, current, status) with `gripper_fresh` flag, `gate_active`,
`clearance_min_m`, `action_source`, `control_mode`. ~80–100 float32 dims →
105–150 MB/h. Why a side table and not `(4, D)` Array2D columns: lerobot's
`validate_frame` requires an exact shape on every frame while the recorder
sees 3–5 ticks under jitter; 2-D features inflate the training-loader row and
collapse `stats.json` to a scalar; and a row-keyed table also holds the
mixed-rate columns (gripper 20–100 Hz, rail 5 Hz). Provide a loader helper
returning the `[ticks, D]` window per `frame_index` for policies that want a
torque/current history, and for re-deriving actions at another fps.

**Episode sidecar additions**: `"audio": {"mic_view": {"path": ..., "sample_rate": 48000, "channels": 1, "sample_format": "s16", "first_sample_wallclock_ns": ..., "first_sample_t_mono": ..., "capture_latency_ms": ..., "av_offset_ms": ...}}`,
`"hires": {"path": ..., "rows": N, "ticks_per_frame_hist": {...}, "port30000": true|false, "port30000_rate_hz_measured": ...}`,
`"frames_dropped_video": {camera_id: n}`, `"gripper_error_events": [...]`,
`"max_joint_temp_c": {arm: [...]}`, `"errors": [{t_mono, arm, code}]`.

**Session sidecar additions** (`"hardware"` block, one entry per arm):
`controller_fw`, `controller_sn`, `servo_fw[7]`, `report_tau_or_i`,
`tcp_load {mass_kg, cog_mm}`, `tcp_offset`, `collision_sens`,
`collision_tool_model`, `ft_sensor_enabled`, `gripper {kind, fw, sn}`,
`linear_track {fw, sn, travel_mm}`, `external_device_monitor {dev_type, freq_hz}`,
`report_ports_used [30003, 30000, 30002]`, `dh_params` (fw >= 2.0.0).

### 5.4 What must change, by repo

| Repo | Change |
|---|---|
| **core** | `ArmState` += `effort: np.ndarray (7,)` (N·m; sim fills MuJoCo `data.actuator_force`/`qfrc_actuator`), `dq_measured: bool` (True when from 30000). `GripperState` += `pos_mm: float \| None`, `vel_mm_s: float \| None`, `status: int` (enum above, −1 unknown), `error: int`; keep `current` in A. New frozen `ArmHealth` dataclass (temps[7], voltages[7], motor_enable/brake bits, servo codes, rail status/error/homed/sci, gripper error, versions) returned by a new `ArmInterface.get_health()` at <= 5 Hz. `StateSnapshot` += `gripper_cmd {arm: GripperCommand}` (today only `gripper_frac`) and a per-tick `HiresRow` pushed into a bounded ring the recorder drains. |
| **hardware** | Fix `register_report_callback(report_mode=True)` (not an SDK kwarg) and take `mode` from `api.mode`. Add `_Port30000Reader` (raw `SocketPort(ip, 30000)`, `ReportDataStructure.create(30000)`, fw >= 2.7.101) as primary source for dq/current/torque/gripper monitor, 30003 as fallback. Add a raw 5 Hz `_Port30002Reader` (`create(30002)`) for err/warn/temps/voltages/servo codes, replacing the `get_err_warn_code` poll (verify the controller accepts a second report client). `G2Gripper`: `init()` → `set_gripper_enable(True)`, `set_collision_tool_model(9)`, `set_tcp_load(...)`, `set_external_device_monitor_params(2, 100)` when supported; `poll()` → one `get_gripper_g2_register(0x0000, 9)` at 20 Hz (or monitor fields), float `pos_mm` from pulses, status enum, current, error poll at 1 Hz; `command()` → `set_gripper_g2_position(..., wait=False, no_check=True)`, skip sends when unchanged. `units.py`: `g2_pulse_to_mm`, `g2_mm_to_pulse`, `g2_rpm_to_mm_s`. Rail: `get_linear_motor_registers(0x0A20, 8)` per step to get status/error/SCI in the same transaction. Log `report_tau_or_i` and refuse to stream if 1. |
| **sim** | Fill `effort` (actuator force), `dq` exact, gripper `pos_mm/vel/status` from the twin, `current` = 0 with `info.source = "sim"`; `ArmHealth` constant. |
| **runtime / recorder** | `RecorderConfig.fps` default **30**. `features.py`: `APOLLO_SCHEMA_VERSION = 2`, builders for every §5.2 key (dims from names; gripper keys incl. `observation.gripper_cmd` only for `gripper != none`; `complementary_info.action_abs_ee.<arm>` for `delta_ee` sessions / `action_delta_ee.<arm>` for `abs_ee`; `audio_level` only when a microphone is configured; no `tcp_wrench`). `thread.py`: `_Capture` += `velocity, effort, gripper, gripper_status, gripper_cmd, audio_level, arm_status, camera_age_ms, tick, audio_sample_index, action_complement`; `_build_capture` computes window means from the drained `HiresRow`s over a **variable** tick count (3/4 at 30 fps) and the complementary action block (`state ⊕ delta` / `abs ⊖ state`) from the same state row; `_frame_from` emits all keys (lerobot `validate_frame` demands keys == features minus bookkeeping); `_capture` dedupes camera frames on `CameraFrame.seq`, resets `_pending` after a camera-stale drop and records `camera_age_ms`; after `save_episode` read the encoder's `_dropped_frames`. New `tools/convert_action_space.py` (§5.2) with a round-trip test. New `HiresWriter` and `AudioWriter` (PyAV `flac`) owned by the recorder thread, started/stopped with the episode; `MicrophoneReader` gains a raw-PCM ring with a running sample counter. `dagger/recorder.py`: extend `SPOOL_COLUMNS`; `policy_action` unchanged. `episode_recorder.py`: unchanged `create()` call apart from the features dict; still `resume()` only when `apollo_schema` matches (a schema-1 root cannot accept schema-2 columns — `add_frame` raises "Feature mismatch"). Tests: `tests/test_recorder_features.py`, `tests/dagger/test_recorder_schema.py`, `tests/test_recorder_thread.py`, `tests/test_recorder_lerobot.py`. Docs: 10-frames §6.1/§7/§7.5/§9, 02-hardware §4, 04-runtime §10.2, 12-dagger §4. |

### 5.5 Migration and merge

- Schema-2 datasets get a fresh repo (the §8.1 name gains nothing; the
  authority is `features["action"]["info"]["apollo_schema"]`). Schema-1
  datasets recorded so far are sim-only and can be re-recorded; if any must
  be kept, backfill with `lerobot.datasets.dataset_tools.add_features(...)`
  (full copy) + `recompute_stats` using NaN-free defaults (zeros + a
  `source: "backfilled"` note), because merge rule 1 requires identical
  feature sets.
- Merge rules (§8.3) gain: identical gripper `model`, identical
  `complementary_action` block (same `key_prefix`/`action_space`); `hires/`
  and `audio/` sidecars are copied through with `episode_index` rewritten
  like the JSON sidecars.
- Converted training views (`convert_action_space.py`) are derived
  artefacts: name them `<repo>-abs_ee` / `<repo>-delta_ee`, never push one as
  the primary, and keep `info["derived_from"]` so a view can be regenerated
  from its source after a recorder fix.

---

## 6. Open questions for the user

1. **Controller firmware of the two control boxes** (Perception Arm
   192.168.2.219, Manipulation Arm 192.168.1.201; and G2 / linear-motor
   firmware). Gates: port 30000 core >= 2.7.101; gripper monitor
   `set_external_device_monitor_params` >= 2.7.100 (30000 fields need
   2.7.101); 30000 GPIO/TCP-accel tail and 30002 gripper mirror >= 2.8.2;
   `get_joint_states` velocity/effort >= 1.9.0; `is_real` readback >= 1.9.110;
   16-bit servo error read >= 2.7.100. Nothing is recorded in `docs/`; read
   `arm.version` at the next power-on and put it in the session sidecar.
2. ~~Is a UFACTORY AI1500 6-axis F/T sensor installed or planned for the
   Manipulation Arm?~~ **Resolved 2026-09-03: no F/T sensor on either arm;
   `observation.tcp_wrench.grip` dropped** (§7).
3. ~~Keep the 100 Hz side table?~~ **Resolved 2026-09-03: keep it** (user:
   storage is fine); it stays the only place joint current, target-vs-actual,
   TCP speed/wrench estimate and raw G2 current live, and what lets actions be
   re-derived at another fps.
4. **Which signals to skip?** Proposed skips: bus voltages, rail velocity,
   GPIO, IMU, joint acceleration in the main table; proposed keeps that are
   debatable: `observation.velocity.*` (finite-differenced on 30003-only
   firmware), `complementary_info.camera_age_ms`, joint temperatures per
   frame (could be episode-level max only).
5. ~~25 vs 30 fps~~ **Resolved 2026-09-03: 30** (§4.1, §7).
6. **Audio: FLAC 16-bit master under `meta/apollo/audio/`**, or WAV 24-bit
   (1.5× size, exact mic bit depth), or additionally a per-frame int16 block
   in parquet for immediate policy use? Also the clap-test A/V offset
   procedure needs a hardware slot.
7. ~~G2 force teleop: do force/speed belong in `action`?~~ **Resolved
   2026-09-03: no — setpoints and measured current/speed are state
   (`observation.gripper_cmd.grip`, `observation.gripper.grip`); `action`
   keeps only the open fraction, whether or not teleop ever modulates
   force live** (§5.1, §7).
8. **Bench items for phase-09** (hardware, not now): measure port-30000 rate
   and the unit of its u64 timestamp; check whether the controller accepts
   concurrent 30003 + 30000 + 30002 clients from one host; calibrate G2
   register 0x0002 / monitor `current` (mA?) against a force gauge and the
   % → N chart with our finger pads; confirm the G2 answers version registers
   0x0801–0x0803 and whether a single FC03 read may span 0x0000–0x000F;
   measure 502 round-trip jitter with 20 Hz gripper polls alongside the
   100 Hz servo stream; verify 30000 `actual_joint_velocity` is populated in
   mode 1 (30002's planned speed explicitly is not).
9. ~~Depth in the dataset?~~ **Resolved 2026-09-03: no D435 depth
   recording** (lerobot 0.6.1 could store `(H, W, 1)` lossless HEVC gray12le
   at ~6 GB/h/stream, CPU-bound; not worth it). Live depth over the dora bus
   is a separate matter (14-dora §4.2).
10. **Config drift to fix regardless**: `configs/mavis_v2.yaml` hardware
    `grip.gripper: xarm` should be `xarm_g2`; `docs/research/xarm-python-sdk.md`
    §3/§9 should be corrected (monitor covers grippers only, 30003 frames are
    135 B on current firmware, `realtime_joint_speeds` are targets, port
    30000 rate undocumented and not selectable via `report_type`).

---

## 7. Decisions (2026-09-03, user)

Applied in place above (TL;DR, §1.2–§1.3, §2.2.1, §2.3, §4, §5, §6); listed
here so the note's history is readable.

1. **Gripper setpoints and measurements are state, never `action`.** The G2
   force (current-limit %) and speed setpoints and the measured Q-axis
   current / speed are observations — "they are state information". `action`
   keeps only the gripper open fraction (10-frames §6). The first draft's
   `complementary_info.gripper_cmd.grip` becomes `observation.gripper_cmd.grip`
   (§5.2); §6 Q7 is closed.
2. **Record state and action in both absolute and relative forms.** Canonical
   `action` = the session's action space (default `delta_ee`, TCP-relative
   deltas with axes of the recording frame, 10-frames §3.2–§3.3); the
   complementary representation under `complementary_info.action_abs_ee.<arm>`
   / `complementary_info.action_delta_ee.<arm>` — a non-`action`,
   non-`observation.` prefix because lerobot 0.6.1 maps every `action*` key to
   `FeatureType.ACTION` (`lerobot/utils/feature_utils.py:172-173`,
   `constants.py:33`). Absolute poses are in the per-arm recording frame
   (`arm_base:<arm>` by default; `ee:` disallowed per 10-frames §5.1); the
   converter `tools/convert_action_space.py` produces a training view with the
   other representation as `action`, deterministic because
   `observation.state` carries the absolute TCP pose (`abs = state ⊕ delta`).
   §5.1, §5.2 "Action representations", §5.4, §5.5.
3. **Dataset `fps = 30`** (matches lerobot's default, SO-100 / OpenArm; ALOHA
   50, DROID 15, LIBERO 10/20). Consequences accepted: 3.33 ticks per frame →
   window aggregation handles variable tick counts (histogram `{3, 4}`
   asserted, not a constant); 1600 audio samples per frame; camera-`seq`
   dedupe in the recorder. §4.1, §4.2, §4.4.
4. **Keep the 100 Hz side table** (`meta/apollo/hires/`) — storage is fine.
   §6 Q3 closed.
5. **No D435 depth recording** in the dataset. §4.3, §6 Q9 closed.
6. **No `observation.tcp_wrench`** — there is no 6-axis F/T sensor on the
   Manipulation Arm (nor on the Perception Arm). §1.2, §1.3, §5.2, §6 Q2
   closed.
7. **Cell facts**: two xArm7 control boxes — Perception Arm (`view`; wrist
   D435 + RØDE NT-USB Mini) at 192.168.2.219, Manipulation Arm (`grip`; xArm
   Gripper G2 + wrist camera) at 192.168.1.201 — both powered and on the wire
   as of 2026-09-03. §6 Q1 now asks for the firmware of these two.
8. **G2 over-exertion**: the grasp-detection bit does not protect; the
   commanded current limit set before closing does (floor ~15–23 N), the bit
   is a post-hoc stall indicator (stop closing, label the grasp), and the
   Q-axis current is the continuous effort signal for a back-off monitor.
   §2.2.1.
