# 13 — Vive-tracker + gamepad teleop (binding)

Status: v0.1, 2026-09-02. Extends 04-runtime §6 (teleop path), 01-core §13
(keymap), 05-ui §6 (input). Everything here is additive to the existing
keyboard teleop; the keyboard path keeps working unchanged.

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
- The rail is never driven by the tracker; it stays on the D-pad / arrow keys.

Gamepad mapping (served by `GET /api/keymap` via the new `gamepad` field, so
the UI never hard-codes it):

| gamepad | keyboard code | action | kind |
|---|---|---|---|
| D-pad left / right | ArrowLeft / ArrowRight | rail_neg / rail_pos | held |
| A / B | KeyH / KeyF | gripper_open / gripper_close | held (rate) |
| LB / RB | KeyZ / Tab | switch_arm_prev / switch_arm | discrete |
| RT (hold, value ≥ 0.5) | KeyC | tracker_clutch | held (modifier) |

No other gamepad control is mapped (Start/Back/sticks/LT/X/Y are ignored).

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
5. Telemetry, additive: `TelemetryMsg.tracker: TrackerTelemetry | None`:
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
- Arming: gamepad input arms capture automatically when the control link is
  open and the role is controller; the armed state is shown by the existing
  chip plus a gamepad chip.
- New hash route `#/devices` (no session loader): gamepad panel (mapping
  string, raw button/axis indices and values, mapped actions lit when active),
  tracker panel (status/backend/rate/age, raw and world poses, 2-D top-down trail
  canvas with the anchor and current target when engaged, z readout), settings
  (yaw, scale, rotation toggle → `tracker_settings`), session controls (start a
  `teleop`/`sim`/`mavis_v2` session with arms `view`,`grip` if none) and the
  session's video streams (`sim`, cameras; `twin` only under `safety_debug`).
- `KeymapOverlay`: new `tracker` group and a gamepad glyph column.

## 6. Installation and calibration (operator)

Scripts under `scripts/tracker/`: `01-sudo-udev-and-deps.sh` (apt deps, udev
rule `/etc/udev/rules.d/60-apollo-teleop-input.rules` for 28de:2101 usb+hidraw
and the gamepad, groups) and `02-build-pysurvive.sh` (full clone of libsurvive
at a pinned commit, `uv build --wheel`, `uv pip install --no-deps` into the
runtime venv, optional `survive-cli`). First run with the tracker on and still,
both base stations visible, ~10–20 s: libsurvive writes
`~/.config/libsurvive/config.json`; delete it after moving a base station.
Runtime config: `tracker: {backend: libsurvive}`.

## 7. Open items (phase-09 / after first hardware test)

Yaw calibration gesture instead of a numeric field; tracker mount → tool
rotation; recording tracker poses into datasets; pairing (`--pair-device`) if
the tracker is not paired to this dongle; base-station generation.
