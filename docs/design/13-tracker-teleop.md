# 13 — Vive-tracker + gamepad teleop (binding)

Status: v0.2, 2026-09-03 (v0.1 2026-09-02; amended 2026-09-03 — phase-10
tracker calibration: §3 items 7–8, §4 "Calibration modes", §5 "Calibration"
wizard, §6 rewritten around the wizard, §7). Extends 04-runtime §6 (teleop
path), 01-core §13 (keymap), 05-ui §6 (input) and, since v0.2, 01-core §12 /
04-runtime §13.1 (`/api/tracker/calibration`). Everything here is additive to the existing
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
keys or a live clutch slides the whole arm as well — the integrator target and
the clutch anchors ride along by the rail step, so the hand<->arm offset is kept
and the joints never fold to hold the TCP in place (2026-09-03). The rail is not
an IK degree of freedom (`control.rail_in_ik: false`): the trackpad / arrow keys
are the only way the rail moves. Details: 04-runtime §6 "Rail".

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

- **Tracker poses are read by the runtime process** (`apollo_mavis_v2_runtime/
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
7. **Tracker calibration models (phase-10, 2026-09-03)** — new core module
   `protocol/tracker.py` (01-core §12 is the spelling authority):
   `CalibrationKind = "none"|"base_station"|"yaw"`, `CalibrationPhase =
   "idle"|"starting"|"capturing"|"validating"|"fitting"|"installing"|"done"|
   "failed"|"aborted"`, `CalibrationOp = "start"|"capture"|"validate"|
   "install"|"apply"|"abort"`, `YawPointLabel = "start"|"left"|"forward"|
   "right"|"back"|"up"|"down"`; models `LighthouseStatus {index, channel,
   serial, pose (lighthouse world, m + wxyz), scenes, reference}`,
   `CalibrationValidation {samples, std_mm[3], max_step_mm, threshold_std_mm
   = 5.0, threshold_step_mm = 20.0, passed}`, `YawGesturePoint {label, pose
   (RAW lighthouse-world pose at the click)}`, `TrackerCalibrationStatus
   {kind, phase, detail, started_at, elapsed_s; scenes (max over stations),
   lighthouses, stations_visible, controller_still, validation,
   installed_path, backup_path; yaw_points, next_point, fitted_yaw_deg,
   fit_residual_deg, fit_checks (failed checks, empty = ok), applied_yaw_deg;
   yaw_valid, yaw_calibrated_at, base_station_installed_at (persisted state,
   always filled)}` and `TrackerCalibrationCommand {kind: "base_station"|
   "yaw", op, point: YawPointLabel|None (yaw capture label; None =
   next_point)}`. Telemetry, additive: `TrackerTelemetry.calibration:
   TrackerCalibrationStatus | None` — the very object `GET
   /api/tracker/calibration` returns; the sub-models ride `TelemetryMsg.json`'s
   `$defs`, so the UI generator gets same-named interfaces — and, pinned in
   the same pass because it was already in code, `TrackerTelemetry.charging:
   bool | None` (controller on external USB power; `None` = not reported).
   `EXPORTED_MODELS` gains `TrackerCalibrationStatus` and
   `TrackerCalibrationCommand` (REST bodies; the other new models are `$defs`
   only); `protocol/__init__.py`, `__all__`, `tests/test_schema_export.py`'s
   exact set, `tests/test_protocol.py::_WIRE_MODELS` and the `TrackerTelemetry`
   attribute-set assertion move together. Class names are unique across the
   protocol (no json-schema-to-typescript alias renumbering); no keymap row.
8. **Transport (binding, 2026-09-03):** calibration adds **no** `ActionName`
   and **no** keymap row (item 2's 23-entry invariant holds). Commands ride
   REST — `GET /api/tracker/calibration -> TrackerCalibrationStatus`, `POST
   /api/tracker/calibration (TrackerCalibrationCommand) ->
   TrackerCalibrationStatus`, illegal transitions 409 `{detail}` — and
   progress rides telemetry (`TrackerTelemetry.calibration`). Rationale: the
   Devices page has no session, `/ws/control` nacks every action without one
   (`ws_control.py` "no session") and `AckMsg` carries no payload. This is a
   binding *addition* to 04-runtime §13.1 "REST = management CRUD":
   session-less device management is REST, progress is broadcast via
   telemetry. Both calibrations require that **no session is active** (409
   `"stop the session first"`: base-station calibration restarts the reader,
   and the yaw gesture's trigger clicks would clutch inside a session); while
   a calibration is active `POST /api/session` is 409 `"tracker calibration
   in progress"`.

Schema export (`export_schemas --out schemas/`), UI `gen:sync`/`gen:types`,
the spine table in 00-overview §5 and 01-core §13 ("exactly these 23 entries")
move together.

## 4. Runtime (04-runtime)

- `RuntimeConfig.tracker: TrackerConfig {backend: "none"|"fake"|"libsurvive" =
  "none", object_name: "WM0", libsurvive_args: ["--lighthousecount", "2"],
  yaw_deg: 0.0, pos_scale: 1.0, follow_rotation: True, stale_s: 0.2,
  max_jump_m: 0.10}`. `tracker_settings` mutates yaw/scale/rotation at runtime
  (process lifetime; the YAML is the boot default — since phase-10 a valid
  persisted `tracker_calibration.json` overrides `yaw_deg` at start, see
  "Calibration modes" below).
- `devices/tracker.py`: `TrackerSample(pose: Pose, vel_lin, vel_ang, t_dev,
  rx_mono, seq)`; `TrackerReader(backend, slot)` thread; libsurvive poses are
  meters + **wxyz** (same as core `Pose`), stamped with `time.monotonic()` on
  receipt (device time is run-time seconds, not wall clock). Only objects of
  type OBJECT whose name equals `object_name` are used for poses; lighthouses
  are ignored by the pose path (since phase-10 LIGHTHOUSE-type objects are
  snapshotted for the calibration status only, "Calibration modes" below).
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
- **Calibration modes (phase-10, 2026-09-03; 04-runtime §6 / §14).** Two
  calibrations, one controller: `devices/tracker_calibration.py` holds
  `TrackerCalibration(reader, settings, cfg: RuntimeConfig, slot:
  LatestSlot[TrackerSample], session_active: Callable[[], bool],
  clock=time.monotonic, wall=time.time)`, owned by `Runtime` (never by the
  `ControlLoop` or the `SessionManager`); `status() ->
  TrackerCalibrationStatus` is cheap and lock-protected (the telemetry
  builder calls it at 25 Hz), `command(cmd: TrackerCalibrationCommand) ->
  TrackerCalibrationStatus` raises `CalibrationError(detail)` on an illegal
  transition (REST → 409), `active` is a property, and `close()` restores the
  normal libsurvive arguments before the reader stops at process exit when a
  calibration is still running. A worker thread runs the timed phases.
  `pysurvive` stays confined to `devices/tracker.py`.
  - **Reader extensions** (`devices/tracker.py`): `TrackerReader.restart(
    libsurvive_args: list[str])` = `stop()` (join; `simple_close` releases
    the dongle — a second `simple_init` before that close completes fails
    with `LIBUSB_ERROR_BUSY`) → `self.cfg = self.cfg.model_copy(update=
    {"libsurvive_args": args})` (the shared `TrackerConfig` is **never**
    mutated in place) → `start()`. During a restart `status()` reports
    `starting` / `searching` and the loop holds by sample expiry as usual.
    libsurvive INFO lines (level ≥ 2 in `_on_survive_log`, ANSI escapes
    stripped first) are queued in `reader.info_lines: deque[tuple[float,
    str]]` (maxlen 256) and handed to an optional `on_info` callback that runs
    on the C thread and must never raise — until phase-10 the reader only
    forwarded warnings. `TrackerReader.lighthouses() ->
    list[LighthouseSnapshot]`: every 0.5 s the reader thread walks
    `simple_get_first_object` / `simple_next_object` inside
    `_libsurvive_events`, keeps the objects whose `simple_object_get_type ==
    ps.SurviveSimpleObject_LIGHTHOUSE` (always compare against
    `ps.<constant>`; the test stub's enum values differ) and records name,
    `simple_serial_number` and `simple_object_get_latest_pose` under a lock.
  - **Argument sets.** *Normal* = `cfg.tracker.libsurvive_args` (lab:
    `["--lighthousecount", "3", "--globalscenesolver", "0",
    "--disable-calibrate", "1"]`, §6). *Stripped* = normal minus the pairs
    `--globalscenesolver X`, `--disable-calibrate X`, `--configfile X`,
    `--force-calibrate X`, `--use-stationary-sensor-window X`. libsurvive
    rewrites the file `--configfile` points at, so a calibration always runs
    on a **temporary config** `calibration_dir/base_station-<ts>.json` (a byte
    copy of `tracker.libsurvive_config_path`, default
    `~/.config/libsurvive/config.json`); the real file is replaced only by
    `install`. The runtime always passes `--configfile` explicitly
    (`--record` without it silently switches the config to `<rec>.json`) and
    never relies on `--run-time` (inert in this build).
  - **`base_station` state machine.** `start`: requires backend `libsurvive`
    (409 `"backend is not libsurvive"`), no session, no calibration running;
    copies the config to the temp file; `reader.restart(stripped +
    ["--configfile", tmp, "--force-calibrate", "1", "--globalscenesolver",
    "1"])`; phase `starting`, then `capturing` on the first `Force calibrate
    flag set` INFO line or the first pose. While `capturing` the worker parses
    INFO lines: `Global solve with (\d+) scenes for (\d+)` → per-station
    `scenes` (`status.scenes` = max over stations); `Using LH (\d+) \((\w+)\)
    as reference lighthouse` → `reference`; `OOTX not set for LH in channel
    (\d+)` plus the lighthouse snapshots → `channel`, `stations_visible`;
    `controller_still` = position std of the samples in the last
    `still_window_s` below `still_threshold_mm`; `detail` is operator prose,
    e.g. `"scenes 3/6 — park the controller still ≥ 3 s at another spot"`
    (the GSS only takes a scene when the controller has been still ≥ 0.54 s,
    with scenes > 3 s apart). `capture` (continue after `done` /
    `validating`): `reader.restart(stripped + ["--configfile", tmp,
    "--globalscenesolver", "1"])` — **without** `--force-calibrate`, so the
    existing solution is refined, not discarded. `validate`: requires
    `scenes ≥ calibration.min_scenes` (409 saying how many are missing);
    `reader.restart(stripped + ["--configfile", tmp, "--globalscenesolver",
    "0", "--disable-calibrate", "1", "--use-stationary-sensor-window", "0"])`
    — the moving-mode 33.6 ms sensor window, so an inconsistent calibration
    cannot hide behind the 1 s stationary window (the CLI ancestor is
    `scripts/tracker/03-lh-consistency-check.sh`, §6); wait for tracking,
    drop the first `validation_skip_seconds`, collect `validation_seconds` of
    valid samples, compute the per-axis position std (mm) and the largest
    step between adjacent samples (mm); `passed = all(std) <
    validation_std_mm and max_step < validation_step_mm`; phase `done` with
    `validation` filled and `detail` = `"validation passed — install"` or
    `"validation failed — capture more spots"`. `install`: requires
    `validation.passed`; backs the real file up as `<path>.bak-YYYYMMDD-HHMMSS`
    (the naming already used by hand) → copies the temp file's bytes over the
    real path → keeps a copy as `calibration_dir/base_station-<ts>-installed.
    json` → writes `base_station_installed_at`, `lighthouse_config_sha256` and
    `yaw_valid=false` to the persisted file → `reader.restart(normal)` →
    phase `done`, `detail = "installed — run Yaw alignment"`. `abort` (any
    phase): `reader.restart(normal)`, phase `aborted`; the temp file stays in
    `calibration_dir` for forensics.
  - **`yaw` state machine.** `start`: no session, no calibration running;
    `yaw_points = []`, `next_point = "start"`, phase `capturing`. Two
    equivalent capture triggers: the worker reads the `slot` at ~50 Hz and
    takes the **rising edge** of `controller.trigger_pressed` on a fresh valid
    sample, or REST `op: capture` (the wizard's button — the only route with
    the button-less `fake` backend). A recorded point = the mean raw position
    of the valid samples of the last `yaw_capture_average_s` (latest
    orientation). After the seventh point the phase is `fitting`, the fit
    completes at once and the phase returns to `done`, waiting for `apply`.
    `fit_yaw(points, cfg) -> (yaw_deg, residual_deg, checks)` is a pure,
    separately unit-tested function: the four horizontal legs `left = P1−P0,
    forward = P2−P1, right = P3−P2, back = P4−P3` must land on the operator
    axes (CLAUDE.md "Hardware facts", §6.2): `left→+X, forward→−Y, right→−X,
    back→+Y`; with xy-normalised leg vectors `u_i` and expected `e_i`, `θ =
    atan2(Σ(u_x e_y − u_y e_x), Σ(u_x e_x + u_y e_y))`, i.e. `Rz(θ)·u_i ≈
    e_i`, consistent with `align_pose(raw, yaw_deg)` (`p_world =
    Rz(yaw)·p_raw`); `residual` = mean angle (deg) between `Rz(θ)u_i` and
    `e_i`. Checks (any failure → `fit_checks` non-empty; `fitted_yaw_deg` is
    still reported but `apply` is 409): every horizontal leg ≥
    `yaw_min_leg_m`; horizontal legs `|dz| ≤ 0.5|d|`; `up = P5−P4` has `dz >
    0` and `dz ≥ 0.5|d|`, `down = P6−P5` has `dz < 0` (confirms that
    lighthouse-world z is up and the gesture was not mirrored); `residual ≤
    yaw_max_residual_deg`. Fitting all four horizontal legs against the stated
    viewpoint removes the 180° ambiguity that produced −77.9° vs 102.1° on
    2026-09-02. `apply`: `settings.update(yaw_deg=fitted)` → persist
    `yaw_deg`, `yaw_valid=true`, `yaw_calibrated_at` → phase `done`,
    `applied_yaw_deg`. `capture` in `done` (all seven taken) is 409; `start`
    restarts the gesture; `abort` clears it.
  - **Persistence and boot override.** `calibration_dir/tracker_calibration.
    json` = `{"yaw_deg": float|null, "yaw_valid": bool, "yaw_calibrated_at":
    float|null, "base_station_installed_at": float|null,
    "lighthouse_config_sha256": str|null}`. `Runtime.__init__` reads it
    before `TrackerSettings.from_config`: if it exists with `yaw_valid` and a
    non-null `yaw_deg`, that value overrides `cfg.tracker.yaw_deg` (the YAML
    is only the boot default). With `yaw_valid=false` telemetry reports the
    fact and the UI shows "yaw alignment needed". Config keys (04-runtime
    §14): `RuntimeConfig.calibration_dir = ~/apollo/calibration`,
    `TrackerConfig.libsurvive_config_path = ~/.config/libsurvive/config.json`,
    `TrackerConfig.calibration = TrackerCalibrationConfig {min_scenes: 6,
    validation_seconds: 10.0, validation_skip_seconds: 3.0,
    validation_std_mm: 5.0, validation_step_mm: 20.0, still_window_s: 0.5,
    still_threshold_mm: 3.0, yaw_min_leg_m: 0.10, yaw_max_residual_deg: 15.0,
    yaw_capture_average_s: 0.3}`.
  - **The INFO-line contract is version-fragile:** the regexes above match
    the libsurvive commit pinned by `scripts/tracker/02-build-pysurvive.sh`
    (`f1e6eddb669320f2a30760f4b42936bdb4306da0`, 2026-08-27, v1.01-204).
    Bumping the pin means re-checking `Force calibrate flag set`, `Global
    solve with N scenes for M`, `Using LH i (serial) as reference lighthouse`
    and `OOTX not set for LH in channel c` against the new build.
  - **Wiring and tests.** `Runtime.__init__` creates
    `self.tracker_calibration` and `Runtime.stop()` calls `close()` first;
    `server/rest.py` serves `GET` / `POST /api/tracker/calibration`
    (`CalibrationError` → 409 `{detail}`) and `post_session` is 409 while a
    calibration is active; `ws_telemetry.build_tracker_telemetry` fills
    `calibration = runtime.tracker_calibration.status()`. Tests: `fit_yaw`
    unit tests (synthetic gestures, the +180° trap, short legs, up/down
    reversed, noise); state-machine tests with a duck-typed fake reader
    (records every `restart` argument list, injects INFO lines and lighthouse
    snapshots) plus hand-fed `LatestSlot` samples covering the whole
    `base_station` flow (per-phase argument assertions, scene counting,
    validation pass / fail, install backup + byte copy in `tmp_path`,
    `yaw_valid` cleared, abort restores the normal arguments) and the whole
    `yaw` flow (trigger rising edge and REST capture, apply persistence, boot
    override); `test_tracker_controller.py`'s `StubPS` grows LIGHTHOUSE
    objects and INFO lines to cover `restart` / `lighthouses()` / the INFO
    queue; e2e (`LiveServer`, backend `fake`): initial `GET`, `base_station
    start` → 409 `"backend is not libsurvive"`, the full yaw flow over REST,
    telemetry carrying the `calibration` block, 409 while a session exists.
    Hardware tests are gated by `APOLLO_TRACKER_HW=1`.
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
- **Calibration (phase-10, 2026-09-03; 05-ui §8.4 / §9 / §10).** The Devices
  side column gains a `CalibrationPanel`: a status row (`yaw_valid` → green
  chip `yaw aligned <date>` from `yaw_calibrated_at`, otherwise an amber chip
  `yaw alignment needed`; the last base-station install date from
  `base_station_installed_at`) and two buttons, **Base-station calibration**
  and **Yaw alignment**, each disabled with a reason line when
  `telemetry.tracker` is null, when the backend is `none`, or when a session
  exists (`Stop the session first`); the base-station button is also disabled
  when the backend is not `libsurvive` (the yaw wizard works on the `fake`
  backend through its Capture button). `Devices.tsx` holds `wizard: null |
  kind`. Both flows run in one in-page modal, `TrackerCalibrationWizard`
  (props `{kind: "base_station" | "yaw"; onClose(): void}`), on the existing
  `.modal-backdrop/.modal` styling — never a native browser dialog:
  `.modal[role=dialog][aria-modal][aria-labelledby]`, the primary button is
  focused on open, `Escape` and a backdrop click mean Close, and while a phase
  is in progress (`starting` / `capturing` / `validating` / `installing`)
  Close first shows an inline "Abort calibration?" confirmation. All wizard
  state comes from `useStore(selectTracker)?.calibration` (nothing is held
  locally, so a page reload resumes where the runtime is); every button is
  one `postTrackerCalibration({kind, op[, point]})`, a 409 becomes a toast
  carrying the `detail`. Step bar `.wizard-steps` / `.wizard-step.is-active`,
  stations table `.stations-table`; otherwise the existing tokens, chips and
  `.analog` bars.
  - Base-station steps: **Intro** (requirements: controller on, three
    stations visible, no session; Start) → **Capture** (large `scenes N /
    min_scenes` counter, stations table index / channel / serial / scenes /
    reference, `controller_still` indicator, the `detail` hint; Validate —
    enabled once `scenes ≥ min_scenes` — and Abort) → **Validate** (`.analog`
    progress, result table std / max step against the thresholds, pass / fail
    badge; Install — enabled only when `validation.passed` — Capture more,
    Abort) → **Done** (`installed_path` / `backup_path`, amber "Yaw alignment
    required", Start yaw alignment (switches `kind`), Close).
  - Yaw steps: **Intro** (where the operator stands and what the four
    directions mean: left = +X, forward = −Y, right = −X, back = +Y; Start) →
    **Points** (large `next_point` label with the instruction "Move LEFT 20–30
    cm, hold still, pull the trigger or click Capture", list of captured
    points; Capture, Restart, Abort) → **Fit** (`fitted_yaw_deg`,
    `fit_residual_deg`, `fit_checks`; Apply — enabled only when `fit_checks`
    is empty — Redo, Cancel) → **Done** (`applied_yaw_deg`).
  - `failed` / `aborted` show `detail` with Retry / Close.

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
and the gamepad, groups), `02-build-pysurvive.sh` (full clone of libsurvive
at a pinned commit — `f1e6eddb669320f2a30760f4b42936bdb4306da0`, 2026-08-27,
v1.01-204 — `uv build --wheel`, `uv pip install --no-deps` into the runtime
venv, optional `survive-cli` under `~/opt/libsurvive`) and
`03-lh-consistency-check.sh` (2026-09-03: records ~20 s of a STILL controller
through `survive-cli` on a temp copy of the config with `--globalscenesolver 0
--disable-calibrate 1`, replays it with the moving-mode sensor window forced
on (`--use-stationary-sensor-window 0`) for all lighthouses and leave-one-out
(`--disable-lighthouse i`), and prints the scatter of the fixes; consistent =
a few mm std in every column and near-zero offsets between columns. It never
touches `~/.config/libsurvive/config.json`; the runtime must not be running
while it holds the dongle). It is the command-line ancestor of the wizard's
Validate step (§4 "Calibration modes").

Lab runtime config (2026-09-03): `tracker: {backend: libsurvive,
libsurvive_args: ["--lighthousecount", "3", "--globalscenesolver", "0",
"--disable-calibrate", "1"], yaw_deg: <boot default — the persisted
tracker_calibration.json wins, §4>}`. `--lighthousecount` is 3 in the live
config (three working stations); the repo `configs/mavis_v2.yaml` still says
4 — reconcile when the channel-7 station is repaired or written off (§7).
`--globalscenesolver 0 --disable-calibrate 1` **freeze the lighthouse
calibration during teleop**: on 2026-09-03 the online global scene solver
moved a base station's solution 32 cm in the middle of a session. Calibration
is therefore an explicit, operator-driven mode (below), never a side effect of
running the arm.

### 6.1 Base-station calibration (wizard first, CLI as fallback)

**Why (root cause, 2026-09-03; evidence under `~/apollo/calib/`).** libsurvive's
first-run "keep the tracker still for 10–20 s" calibration solves every base
station from a single spot, and the resulting station poses were mutually
inconsistent: the same physical point resolved 26 cm apart through two
different stations. A still controller hides this (after 1 s of stillness
MPFIT switches to a 1 s sensor window that averages the stations); a moving
controller uses a 33.6 ms window, so whichever station swept last decides the
fix and the pose snaps between the per-station solutions — the "walk in one
direction for a while and it jumps back" symptom. Measured with the
moving-mode window at a spot away from the calibration spot: position std
61 / 62 / 53 mm (x/y/z), max step 248 mm, single-station offset 259 mm. A
**multi-position** calibration (global scene solver, GSS, collecting still
"scenes" at ≥ 6 spots; the 2026-09-03 run used 14 scenes, optical residual
RMS 0.22 mrad) brought this to std ≤ 0.1 mm, max step 0.1 mm and a
leave-one-out offset ≤ 3.1 mm. The wizard's acceptance thresholds come from
these two data points: **std < 5 mm on every axis and max step < 20 mm**.

**Procedure (Devices page → Calibration panel → "Base-station calibration";
requires: controller on and paired, all working stations powered, no
session).** Start (the runtime restarts libsurvive on a temp copy of the
config with `--force-calibrate 1 --globalscenesolver 1`, §4) → **Capture**:
park the controller still for ≥ 3 s at one spot, move to another spot, repeat,
spreading the spots over the working volume (both rail ends, near and far from
the operator, high and low); the counter shows `scenes N / 6` and the stations
table shows which station is the reference and how many scenes each has
solved (the GSS only takes a scene after ≥ 0.54 s of stillness and > 3 s
after the previous one, so walking around does not count) → **Validate** once
`scenes ≥ 6`: hold the controller still for ~13 s (3 s skipped + 10 s
measured with the moving-mode window, scene solver off); pass = std < 5 mm
and max step < 20 mm on the result table; fail → "Capture more" at further
spots → **Install**: the runtime backs `~/.config/libsurvive/config.json` up
as `config.json.bak-YYYYMMDD-HHMMSS`, copies the validated temp config over
it, keeps `~/apollo/calibration/base_station-<ts>-installed.json`, marks the
yaw **invalid** and restarts libsurvive with the normal (frozen) arguments →
**Yaw alignment** (§6.2) is mandatory after every install: the lighthouse
world frame is re-anchored by a recalibration (the 2026-09-03 install rotated
it by −14.2° relative to the previous frame). Abort at any time restores the
normal arguments; temp configs stay under `~/apollo/calibration/`.

**Files.** Installed config: `~/.config/libsurvive/config.json` (three
lighthouse blocks with a 7-vector `pose` and a 6-vector `variance`,
`"poser": "MPFIT"`, `"configed-lighthouse-gen": "2"`). A copy of the cell's
reference calibration lives in the runtime repo as
`apollo-mavis-v2-runtime/configs/libsurvive/<cell>-lighthouses-<date>.json`
(currently `mavis_v2-lighthouses-20260903.json`) so a fresh machine or a
corrupted config can be restored by copying it back; update the copy after
every accepted install.

**CLI fallback (runtime stopped — the dongle is exclusive, `LIBUSB_ERROR_BUSY`
otherwise).** Capture with `survive-cli --configfile <tmp copy>
--lighthousecount 3 --force-calibrate 1 --globalscenesolver 1` and the same
still-at-many-spots discipline (watch for `Global solve with N scenes for M`
in the INFO output); validate with `scripts/tracker/03-lh-consistency-check.sh`
(set `LIBSURVIVE_CONFIG` to the temp copy); then back up and copy the temp
config over `~/.config/libsurvive/config.json` by hand and redo the yaw
gesture. Deleting `config.json` and letting libsurvive recalibrate from a
single spot on the next start — the v0.1 procedure — is exactly what produced
the inconsistent solutions and is no longer recommended.

### 6.2 Yaw alignment (lighthouse world → MJCF world)

Only the yaw between the two z-up frames is calibrated (`align(pose)` =
`R_z(yaw_deg)`, §4). **The mapping depends on where the operator stands** and
the operator is the authority on left/right (CLAUDE.md "Hardware facts"): the
lab operator stands at the OUTER edge of the table (+Y) facing the arms
(facing −Y; the camera-only arm is nearest, the same side the mavis_v2
overview cameras look from since 2026-09-02), so **left = +X, forward = −Y,
right = −X, back = +Y**.

**Procedure (Devices page → Calibration panel → "Yaw alignment"; no
session).** Start → the wizard names the next point: pull the trigger (or
click Capture — the only way on the `fake` backend) at a **start** point with
the hand still, then after each of six moves of 20–30 cm — **left, forward,
right, back, up, down** — again with the hand still at the click (each point
is the 0.3 s mean of the raw lighthouse-world position). After the seventh
click the runtime fits the yaw over the four horizontal legs against the
operator axes above and shows yaw, residual and the checks (legs ≥ 10 cm,
horizontal legs flat, up/down truly vertical and in the right order, residual
≤ 15°); **Apply** installs it live (`tracker_settings` path) and persists it
to `~/apollo/calibration/tracker_calibration.json`, which overrides the YAML
`yaw_deg` on every later start. Redo the gesture after **any** base-station
recalibration — the wizard enforces this by clearing `yaw_valid` on install
and showing "yaw alignment needed" until a new yaw is applied.

**Verify with landmarks, not body words:** move the controller toward the arm
bases (away from you) → the EE moves toward the bases (−Y); move it toward
your LEFT, i.e. toward rail zero at the +X end where the obstacle sits → the
EE moves to +X; toward your RIGHT, where the arms rest flush with the table
edge (−X) → the EE moves to −X. (Since the 2026-09-03 rail flip rail zero is
at the operator's LEFT and rail q increases toward −X; earlier revisions of
this section called it "the right end of the rails".)

**History.** 2026-09-02: the first fit (−77.9°) assumed the arm's viewpoint
(forward = +Y) and produced the classic symptoms — hand forward moved the EE
backward, pitch/yaw felt inverted, while left/right looked right on screen
only because the old cameras looked from the opposite side; the correct value
was the fit + 180° = **102.1°**. Fitting all four horizontal legs against the
stated viewpoint (§4) removes that ambiguity. 2026-09-03: the base-station
recalibration rotated the lighthouse frame by −14.2°, giving an *estimate* of
**116.3°** that the live config carried until the gesture was redone through
the wizard — treat any yaw typed into `TrackerSettingsForm` as
process-lifetime only; the persisted, wizard-applied value is authoritative.

## 7. Open items (phase-09 / after first hardware test)

Tracker mount → tool rotation; recording tracker poses into datasets; pairing
(`--pair-device`) if the tracker is not paired to this dongle; base-station
generation; confirm the rail-only semantics (§1.1: posture held, TCP rides the
rail) with the operator on the real rail — the alternative (IK keeps the TCP
fixed in the world while the base slides) is what the loop did before
2026-09-02. (The v0.1 item "yaw calibration gesture instead of a numeric
field" was closed by the phase-10 wizard, §4/§5/§6.2, on 2026-09-03.)
Deferred by phase-10 (out of its scope): re-flashing / RMA of the channel-7
station E9BFDF83 and then reconciling `--lighthousecount` (3 live vs 4 in the
repo YAML, §6); base-station placement advice; a second controller; writing
the applied yaw back into the YAML (the persisted `tracker_calibration.json`
is authoritative, §4); SteamVR.
