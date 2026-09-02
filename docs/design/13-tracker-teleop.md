# 13 — Vive-tracker + gamepad teleop (binding)

Status: v0.1, 2026-09-02. Extends 04-runtime §6 (teleop path), 01-core §13
(keymap), 05-ui §6 (input). Everything here is additive to the existing
keyboard teleop; the keyboard path keeps working unchanged, with one revised
semantic shared by every rail input: a rail-only tick holds the joint posture
and lets the TCP ride the rail (§1.1, 04-runtime §6 "Rail"; 2026-09-02).

## 1. Goal and operating model

A handheld HTC Vive Tracker moves the active arm's end effector; an XInput
gamepad supplies the discrete/rate inputs. Motion is **relative and clutched**
(the "lifted mouse" model):

- **Clutch** = a held input (gamepad RT, keyboard `KeyC`). While held, the
  tracker's displacement since the moment of engagement is applied to the EE
  target that was current at engagement. Releasing the clutch freezes the arm
  (hold-last, exactly like releasing a movement key). Moving the tracker while
  released does nothing. Pressing again re-anchors at the new tracker pose —
  the arm never teleports.
- Position deltas are scaled by `pos_scale` (default 1.0). Orientation deltas
  are applied when `follow_rotation` is on (default on), as a relative rotation
  about the anchored EE orientation.
- The rail is never driven by the tracker *pose*; it stays on held inputs (arrow
  keys, gamepad D-pad, controller trackpad left/right — §1.1).

Gamepad mapping (served by `GET /api/keymap` via the new `gamepad` field, so
the UI never hard-codes it):

| gamepad | keyboard code | action | kind |
|---|---|---|---|
| D-pad left / right | ArrowLeft / ArrowRight | rail_neg / rail_pos | held |
| A / B | KeyH / KeyF | gripper_open / gripper_close | held (rate) |
| LB / RB | KeyZ / Tab | switch_arm_prev / switch_arm | discrete |
| RT (hold, value ≥ 0.5) | KeyC | tracker_clutch | held (modifier) |

No other gamepad control is mapped (Start/Back/sticks/LT/X/Y are ignored).

### 1.1 Vive controller as the only input (lab default since 2026-09-02)

With a Vive Pro controller paired to the dongle, the same device supplies the
pose AND the discrete inputs; the gamepad is optional. libsurvive button events
(verified on the lab controller): event types `3` BUTTON_DOWN, `2` BUTTON_UP,
`5` TOUCH_DOWN, `4` TOUCH_UP, `8` AXIS_CHANGED; button ids `0` trigger, `1`
trackpad, `7` grip, `6` menu, `3` system; axis ids `1` trigger (0..1), `2`
trackpad x, `3` trackpad y (both −1..1, +y = top).

| controller | injected | action | kind |
|---|---|---|---|
| trigger click (button 0 down) | code KeyC | tracker_clutch | held |
| trackpad click, y > +0.3 (up) | code KeyH | gripper_open (rate, while held) | held |
| trackpad click, y < −0.3 (down) | code KeyF | gripper_close (rate, while held) | held |
| trackpad click, x < −0.3 (left) | code ArrowLeft | rail_neg (rail value decreases, while held) | held |
| trackpad click, x > +0.3 (right) | code ArrowRight | rail_pos (rail value increases, while held) | held |
| menu click (button 6 down) | action switch_arm | next arm | discrete, press edge |
| grip / system / touch without click | — | none (system is half of the menu+system pairing combo — never map it) | |

Mapping revised 2026-09-02 on operator request (was: pad left/right = gripper,
pad up/down = arm switch); `switch_arm_prev` has no Vive-controller binding
(keyboard `KeyZ` / gamepad `LB` only). Holding menu+system for the pairing
gesture fires `switch_arm` once — harmless, and pairing is a one-off operation.

A click is classified once, at its press edge, by the trackpad position at that
moment (dominant axis wins; |x| and |y| both below the deadzone ⇒ ignored); the
classification is held until release. Default `controller_map`:
`{clutch: trigger_click, gripper_open: trackpad_up, gripper_close:
trackpad_down, rail_neg: trackpad_left, rail_pos: trackpad_right, arm_next:
menu_click, arm_prev: none}` with `trackpad_deadzone: 0.3`. Bindable inputs:
`trigger_click`, `trackpad_left|right|up|down`, `menu_click`, `grip_click`,
`none`; held actions accept any input, discrete actions accept any input except
`trigger_click`; an input serves at most one action. Device-sourced discrete
actions are executed inside the control loop (`_op_switch_arm` /
`_op_switch_arm_prev`) on the press edge (`ControllerState.edge_seq` advances;
`edge_input` names the input that produced the edge; the state keeps a short
`(seq, input)` history so two buttons edging inside one 10 ms tick both fire),
subject to the same nacks as the WS actions (e.g. takeover engaged); the
telemetry `device_held` list
shows the held codes, `device_action` the last discrete action fired (or its
nack detail), cleared after ~1 s.

Device-held **rail codes** integrate the rail exactly like the arrow keys, at the
device source's scale (1.0 while the sample stream is fresh, 0.0 when stale) —
the same per-source rule as the gripper codes; the WS deadman latch never zeroes
a device-held rail input and a device-held code never depends on a browser
being connected. **Rail-only semantics** (arrow keys, D-pad and trackpad alike;
decided 2026-09-02, to be confirmed on hardware in phase-09): while only a rail
input is held the arm keeps its joint posture and the TCP rides the rail — the
IK is not run against the frozen world-frame target — and the teleop seed is
invalidated so that the next translate key or clutch engage re-seeds from the
measured TCP (§4 re-seed rule (d)); a rail input held together with translate
keys or a live clutch keeps the world-frame target and the IK compensates the
rail within the leash. Details: 04-runtime §6 "Rail".

The default **active arm is the gripper arm**: sessions started from the
devices page list `grip` first (`arms: [grip, view]`); operators can still
switch with the controller's menu button or Tab/KeyZ.

These **device-held codes** are produced by the runtime's tracker reader
(`TrackerSample.controller` + `TrackerSample.held_codes`) and merged into the
tick's held set (`held ∪ device_codes`) while the sample is fresh
(`age ≤ stale_s`); a stale sample contributes nothing (= released). They are
NOT covered by the WebSocket `InputWatchdog`: the controller's own ≥100 Hz
sample stream is their heartbeat, so a keyboard/WS deadman latch
(`AWAIT_EMPTY`) must not zero device-driven motion — the tick uses per-source
scales: WS-sourced codes use the WS watchdog scale, device-sourced codes use
`1.0` when fresh / `0.0` when stale. The tracker branch takes the scale of the
source that holds the clutch. A running session is still required; the browser
controller connection is not. Telemetry echoes the raw controller state and the
injected codes (`TrackerTelemetry.controller`, `.device_held`).

## 2. Architecture

```
 Vive Tracker ──RF──► Watchman dongle ──libusb──► pysurvive (libsurvive, in-process thread)
                                                        │ TrackerSample @ ≤250 Hz
                                                        ▼
 browser (Gamepad API + keyboard) ──KeysMsg/ActionMsg──► runtime ControlLoop (100 Hz)
        ▲                                               │ telemetry.tracker @ 25 Hz
        └──────────────── TelemetryMsg ◄────────────────┘
```

- **Tracker poses are read by the runtime process** (`apollo_xarm7_runtime/
  devices/tracker.py`, a daemon thread around libsurvive's blocking event API)
  and published to a process-wide `LatestSlot[TrackerSample]`. The browser never
  sees raw device data except through telemetry. Backends: `libsurvive` (real),
  `fake` (scripted circle, for UI/pipeline debugging without hardware), `none`.
- **The gamepad is read in the browser** and folded into the existing single-
  writer `/ws/control` channel: held rows become codes in `KeysMsg.held`
  (deadman-covered by the existing `InputWatchdog`, 25 Hz heartbeat, release-all
  semantics), discrete rows become `ActionMsg`. No new client→server message.
- The control loop stays the single command chokepoint (04-runtime §6): the
  tracker only supplies the *target pose* for the active arm's teleop step; leash,
  IK, residual re-anchoring, rail integration, `dq_max`, the safety gate and the
  ArmSender are untouched.

## 3. Core protocol changes (01-core)

1. `KeymapEntry.gamepad: str | None = None` — gamepad control label
   (`DpadLeft`, `DpadRight`, `A`, `B`, `LB`, `RB`, `RT`). Additive/optional.
2. New keymap rows (21 → 23): `KeyC → tracker_clutch` (held, new group
   `tracker`, gamepad `RT`) and `KeyZ → switch_arm_prev` (discrete, group
   `session`, gamepad `LB`). Existing rows gain `gamepad`: ArrowLeft
   `DpadLeft`, ArrowRight `DpadRight`, KeyH `A`, KeyF `B`, Tab `RB`.
3. `HELD_MODIFIER_ACTIONS = frozenset({"tracker_clutch"})`: held actions that are
   **not axes**. `axis_map()` excludes them; `held_to_twist` ignores them; the
   keymap tests' "every axis has ±" invariant applies to axis actions only.
4. `ActionName` gains `switch_arm_prev` (no args) and `tracker_settings` with
   args model `TrackerSettingsArgs {yaw_deg: float|None, pos_scale: float|None
   (0.1–3), follow_rotation: bool|None}` (fields omitted = unchanged).
5. Telemetry, additive: `TelemetryMsg.tracker: TrackerTelemetry | None` (plus
   `controller: ControllerTelemetry | None {trigger: float, trigger_pressed,
   trackpad_touch, trackpad_click, trackpad_x, trackpad_y, grip, menu, system}`
   and `device_held: list[str]`, §1.1):
   `backend` (`libsurvive|fake|none`), `status` (`no_backend|starting|
   searching|tracking|stale|error`), `detail: str`, `object_name`, `seq`,
   `rate_hz`, `age_s`, `pose_raw: PoseMsg|None` (lighthouse world), `pose_world:
   PoseMsg|None` (after yaw alignment), `clutch: bool`, `engaged_arm: str|None`,
   `anchor_tcp: PoseMsg|None`, `target_tcp: PoseMsg|None` (world), `settings:
   {yaw_deg, pos_scale, follow_rotation}`. Populated even without a session
   (device fields), session fields `None` otherwise.
6. `CommandSource` is unchanged: tracker motion is `TELEOP` (datasets record
   `action_source = teleop`).

Schema export (`export_schemas --out schemas/`), UI `gen:sync`/`gen:types`,
the spine table in 00-overview §5 and 01-core §13 ("exactly these 23 entries")
move together.

## 4. Runtime (04-runtime)

- `RuntimeConfig.tracker: TrackerConfig {backend: "none"|"fake"|"libsurvive" =
  "none", object_name: "WM0", libsurvive_args: ["--lighthousecount", "2"],
  yaw_deg: 0.0, pos_scale: 1.0, follow_rotation: True, stale_s: 0.2,
  max_jump_m: 0.10}`. `tracker_settings` mutates yaw/scale/rotation at runtime
  (process lifetime; config is the default).
- `devices/tracker.py`: `TrackerSample(pose: Pose, vel_lin, vel_ang, t_dev,
  rx_mono, seq)`; `TrackerReader(backend, slot)` thread; libsurvive poses are
  meters + **wxyz** (same as core `Pose`), stamped with `time.monotonic()` on
  receipt (device time is run-time seconds, not wall clock). Only objects of
  type OBJECT whose name equals `object_name` are used; lighthouses are ignored.
  A jump > `max_jump_m` between consecutive samples marks the sample invalid
  (occlusion/reflection glitch) — the loop holds. Import of `pysurvive` is lazy
  and confined to this module (ruff banned-api elsewhere); missing module ⇒
  status `no_backend`.
- Loop (`_teleop_step` provider): if `tracker_clutch ∈ held` and the sample is
  fresh (`now − rx_mono ≤ stale_s`) and valid:
  - on engage (first tick with clutch held, or after a stale/invalid gap or an
    arm switch): `A_trk = align(sample.pose)`, `A_ee = integrator.get(arm) or
    measured_tcp`;
  - `Δp = pos_scale·(align(p) − A_trk.p)`; `Δq = q_align ⊗ q ⊗ conj(A_trk.q)`
    (identity when `follow_rotation` is off);
  - `target = Pose(A_ee.p + Δp, Δq ⊗ A_ee.q)`, then the existing
    `clamp_pose_to_leash(target, measured, leash)` → `ik.solve` → residual
    handling. When the leash or IK residual truncates the step, shift `A_ee` by
    the truncated amount (anchor slip) so the hand↔arm offset stays consistent
    instead of accumulating.
  - `align(pose)` rotates position and orientation by `R_z(yaw_deg)`
    (lighthouse world and MJCF world are both z-up; only yaw is calibrated).
  - Watchdog `scale` multiplies the per-tick step toward the target (not the
    offset). Keyboard translate/rotate keys are ignored while the clutch is held;
    rail keys and gripper keys keep working.
  - Clutch released / sample stale or invalid / arm switched ⇒ hold-last (return
    `None`), anchors cleared.
- Controller inputs (§1.1): the libsurvive backend parses button/axis events
  into `ControllerState`; `TrackerConfig.controller_map` defaults to the §1.1 table
  (`{clutch: trigger_click, gripper_open: trackpad_up, gripper_close:
  trackpad_down, rail_neg: trackpad_left, rail_pos: trackpad_right, arm_next:
  menu_click, arm_prev: none}`) with `trackpad_deadzone: 0.3`; the reader
  attaches the latest controller state and the derived `held_codes` (clutch,
  gripper and rail codes looked up from the keymap by action) to every sample
  and publishes a sample on each button edge (re-publishing the last pose; this
  never refreshes the pose's age — a pose older than `stale_s` is re-published
  invalid so the clutch cannot anchor on it, and status / `age_s` / `rate_hz`
  follow the real pose stream only). Press edges of the trackpad (classified),
  menu and grip buttons are appended to `ControllerState.edges` as
  `(seq, input)` (`edge_seq` / `edge_input` = the newest entry);
  `derive_click_actions` maps every remembered edge through the discrete
  bindings to `TrackerSample.click_actions`, and the loop fires the entries
  newer than the `edge_seq` it saw last (lossless when two buttons edge inside
  one tick). The fake backend exposes the same fields (no buttons) so the merge
  path is unit-testable with a scripted controller state.
- **Pose filter** (`TrackerConfig.filter`): the aligned tracker pose is passed
  through a One Euro filter before the anchor/delta math — position per axis
  (`min_cutoff_hz: 1.0`, `beta: 0.05`, `d_cutoff_hz: 1.0`) and orientation via
  the same filter on the rotation-vector increment (slerp-equivalent for small
  steps), followed by a rest deadband (`deadband_m: 0.002`, `deadband_rad:
  0.005`): displacements below the deadband since the last emitted pose are
  dropped. The filter runs in the provider at the 100 Hz tick on the latest
  sample (not in the reader), resets on engage and on stale/invalid gaps, and
  `filter.enabled: false` bypasses it. `tracker_settings` gains optional
  `filter_min_cutoff_hz` / `filter_beta` so the debug page can tune it live;
  telemetry echoes the effective settings and reports `pose_filtered`.
- **Anchor and re-seed rules (review 2026-09-02):** (a) whenever an arm's tick
  was resolved by a non-teleop source (goto plan, joint jog, policy), the teleop
  target is re-seeded from the measured TCP before teleop resumes, so the first
  clutched tick after such motion has zero delta; (b) anchor slip for rotation
  is applied in the BODY frame — `dq_b = conj(intended.q) ⊗ achieved.q`,
  `A_ee.q ← A_ee.q ⊗ dq_b` — so that `D ⊗ A_ee'.q == achieved.q` exactly for
  any hand rotation `D`; (c) the settings (yaw, scale, rotation flag, filter)
  are snapshotted at engagement; a `tracker_settings` change while engaged
  re-anchors (`A_trk ← align(sample, new)`, `A_ee ← the provider's leash-clamped
  target`, i.e. the raw target the anchors produce with a still hand — not the
  rate-limited pose handed to IK, so a pending rate-limit catch-up is kept)
  instead of re-interpreting the accumulated offset — the arm never moves on a
  settings change; (d) a rail-only tick (joints held at `q_last`, only the rail slot
  integrates — §1.1) slides the base under the frozen world-frame target, so it
  discards the arm's teleop seed: the next translate or clutch tick re-seeds
  from the measured TCP (one twist step / zero delta) instead of stepping up to
  a leash (25 mm) toward the stale target.
- **Target rate limit and component-wise slip (2026-09-02):** the provider's
  leash-clamped target is rate-limited toward the previous commanded target
  (`control.target_rate`, 1.0 m/s / 2.0 rad/s; 04-runtime §6) before IK, and the
  IK residual slip is component-wise (position residual → position anchor,
  rotation residual → rotation anchor). Rationale: the QP's single differential
  step trades position for orientation once the joint velocity limits saturate,
  and slipping both components on a rotation-only residual turned that transient
  into permanent TCP drift (measured 8–10 cm after a 240 °/s in-place rotation,
  ≈0 with the two rules; the sim IK weights stay 1.0/0.5 because raising the
  position weight broke the guardrail contract A2/A5). Rate-limit truncation is
  not slipped (the target catches up inside the leash).
- **Reader robustness:** every libsurvive event is guarded (finite position,
  unit-norm quaternion; a bad event is dropped and counted, never raised); the
  device status distinguishes `error` (no OBJECT-type device after the grace
  period — dongle busy/not openable, tracker off/unpaired — with the libusb
  detail) from `searching` (device present, no pose yet) by enumerating
  OBJECT-type objects, and reports a mismatching `object_name` explicitly;
  `rate_hz` decays to 0 when samples stop; libsurvive warnings are rate-limited
  (≤ 1 line/s per message class) and the runtime entry point configures Python
  logging.
- `_op_switch_arm_prev` mirrors `_op_switch_arm` with `(i − 1) mod n`; the
  DAgger override nacks it while a takeover is engaged, like `switch_arm`.
- `_op_tracker_settings` updates the live settings and echoes them in telemetry.
- Telemetry: device fields from the `Runtime`-owned reader (available pre-
  session); clutch/anchor/target from `StateSnapshot.session_extra["tracker"]`.
- Tests: unit (fake kin/IK as in `tests/dagger/test_executor.py`): engage →
  target follows Δ 1:1 within the leash; release → hold; re-engage → no jump;
  stale sample → hold; arm switch clears anchors; yaw alignment rotates Δ;
  `follow_rotation` off keeps orientation; `switch_arm_prev` wraps; e2e with the
  `fake` backend on `mavis_v2`: clutch via `KeyC` moves the EE, telemetry carries
  `tracker.*`, no ERROR logs.

## 5. UI (05-ui)

- `src/input/gamepad.ts`: poll `navigator.getGamepads()` at 50 Hz
  (`setInterval`, injectable for tests); normalizer for `mapping === "standard"`
  (buttons 0 A, 1 B, 4 LB, 5 RB, 7 RT (value), 14 DpadLeft, 15 DpadRight) and the
  raw Linux joydev order (buttons 0 A, 1 B, 4 LB, 5 RB; axes 6 = D-pad x,
  5 = RT 0..255 or −1..1); mapping driven by `KeymapEntry.gamepad` from the served
  keymap. Held rows → codes in a shared held set (union with the keyboard set;
  `setHeldSource` becomes a union of sources); discrete rows → `sendAction` on
  press edge; release-all on `gamepaddisconnected`, blur, hidden, disarm.
- Release-all on blur/hidden/link-down is latched: no new press edges are
  accepted until every mapped control reads released (or the page is focused and
  visible again); the settings form sends `tracker_settings` on commit
  (Enter/blur), not per keystroke, and shows nacks as toasts.
- Arming: gamepad input arms capture automatically when the control link is
  open and the role is controller; the armed state is shown by the existing
  chip plus a gamepad chip.
- New hash route `#/devices` (no session loader). The page wraps its video
  area in the same keyboard-capture surface as the cockpit (`TeleopSurface`), so
  keyboard teleop (incl. `KeyC` clutch) works there too; its session start uses
  `arms: [grip, view]` (gripper arm active by default). Contents: gamepad panel (mapping
  string, raw button/axis indices and values, mapped actions lit when active),
  tracker panel (status/backend/rate/age, raw and world poses, 2-D top-down trail
  canvas with the anchor and current target when engaged, z readout), settings
  (yaw, scale, rotation toggle → `tracker_settings`), session controls (start a
  `teleop`/`sim`/`mavis_v2` session with arms `grip`,`view` if none) and the
  session's video streams (`sim`, cameras; `twin` only under `safety_debug`).
- `KeymapOverlay`: new `tracker` group and a gamepad glyph column.

## 6. Installation and calibration (operator)

Lab hardware (2026-09-02): the Vive Tracker 3.0 is dead (will not charge); a
**Vive Pro controller** (libsurvive object `WM0`, subtype WAND, serial
LHR-ABFB86B5) is paired to the Watchman dongle instead and plays the tracker
role — same object name, same code path (trigger = clutch, trackpad up/down =
gripper, trackpad left/right = rail, menu = arm switch, §1.1). Four **Lighthouse 2.0** base stations were
installed, but one (serial E9BFDF83, channel 7) has corrupted firmware: its
radio MCU is stuck in Nordic DFU (BLE name `LHB-DFU`), the FPGA image reads
0xFFFFFFFF and its USB console (`/dev/ttyACM0`, `lhtx>` prompt, `id`/`mode`)
reports `Radio Timeout`; it blinks amber and never sweeps. Until it is
re-flashed with SteamVR (or RMA'd) the cell runs on **three** stations
(channels 3/12/14, `--lighthousecount 3`). With a clean 3-station calibration
the resting pose noise is 0.1 mm std / 1 mm peak-to-peak / 0.08° — the 5 cm
"jitter" seen before was the broken station plus a stale calibration.
libsurvive's poser thread uses about one CPU core continuously.

Pairing a controller to the dongle (once): run libsurvive with `--pair-device`
(`survive-cli --pair-device --v 100 --lighthousecount 4`), then hold the
controller's **Menu + System** buttons until the LED blinks blue; the dongle
accepted the pairing after ~50 s of attempts. Always close libsurvive cleanly
(`simple_close`): a killed process keeps the USB interface claimed and the next
open fails with `LIBUSB_ERROR_BUSY` (`fuser /dev/bus/usb/<bus>/<dev>` finds the
holder). The runtime's reader must close on shutdown and on SIGTERM.

Scripts under `scripts/tracker/`: `01-sudo-udev-and-deps.sh` (apt deps, udev
rule `/etc/udev/rules.d/60-apollo-teleop-input.rules` for 28de:2101 usb+hidraw
and the gamepad, groups) and `02-build-pysurvive.sh` (full clone of libsurvive
at a pinned commit, `uv build --wheel`, `uv pip install --no-deps` into the
runtime venv, optional `survive-cli`). First run with the tracker on and still,
both base stations visible, ~10–20 s: libsurvive writes
`~/.config/libsurvive/config.json`; delete it after moving a base station.
Runtime config: `tracker: {backend: libsurvive, libsurvive_args: ["--lighthousecount", "3"], yaw_deg: 102.1}`.
Yaw calibration gesture (used 2026-09-02): click the trigger at a start point,
then after each of six moves — left, forward, right, back, up, down (20–30 cm
each, hand still at each click); record `pose_raw` at every click via telemetry
and fit the yaw that maps the operator's left/right/forward/back onto world
axes. **The mapping depends on where the operator stands.** The lab operator
stands at the OUTER edge facing the arms (facing −Y, camera-only arm nearest,
the same side the mavis_v2 overview cameras look from since 2026-09-02), so
forward = −Y and left = +X. The first fit (−77.9°) wrongly assumed the
arm's viewpoint (forward = +Y) and produced the classic symptoms — hand forward
moved the EE backward, pitch/yaw felt inverted, while left/right looked right on
screen only because the old cameras looked from the opposite side; the correct
value is the fit + 180° = **102.1°**. Verify with landmarks, not body words:
move the controller toward the arm bases → the EE moves toward the bases; toward
the right end of the rails (rail zero) → the EE moves to +X. Redo the gesture
after any libsurvive recalibration (the lighthouse world frame is re-anchored
then).

## 7. Open items (phase-09 / after first hardware test)

Yaw calibration gesture instead of a numeric field; tracker mount → tool
rotation; recording tracker poses into datasets; pairing (`--pair-device`) if
the tracker is not paired to this dongle; base-station generation; confirm the
rail-only semantics (§1.1: posture held, TCP rides the rail) with the operator
on the real rail — the alternative (IK keeps the TCP fixed in the world while
the base slides) is what the loop did before 2026-09-02.
