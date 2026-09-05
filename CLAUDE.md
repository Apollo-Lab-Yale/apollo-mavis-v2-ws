# apollo-mavis-v2-ws — guidance for Claude

## What this is

Development workspace for **MAVIS v2** (Manipulation And Viewpoint Selection v2),
the Apollo Lab (Yale) dual-arm cell: two UFACTORY xArm7 arms on linear tracks over
one table — the **Manipulation Arm** (id `grip`: xArm Gripper G2 + wrist camera) and
the **Perception Arm** (id `view`: wrist RealSense D435 + RØDE NT-USB Mini
microphone, no gripper). Use those user-facing names everywhere a person reads
them; the ids stay internal. The stack targets exactly this cell, real or as its
MuJoCo digital twin (scene `mavis_v2`), not xArm7 in general. Five repos: `apollo-mavis-v2-core` (interfaces/schemas/protocols) ←
`apollo-mavis-v2-hardware` (real xArm7 + linear-track drivers) and
`apollo-mavis-v2-sim` (MuJoCo) ← `apollo-mavis-v2-runtime` (teleop / data
collection / DAgger / inference) ← `apollo-mavis-v2-ui` (web UI). Renamed from
`apollo-xarm7-*` on 2026-09-03 (GitHub keeps redirects from the old names).

The five sub-repos are **git submodules** of this workspace (since 2026-09-03),
each tracking its own `main`. A ws commit therefore pins a known-good
combination of the five. Rules: work inside a sub-repo on `main` (never on a
detached HEAD — run `git -C <sub> switch main` if `git submodule status` shows
one), commit + push there first, then bump the pointer in the ws
(`git add <sub> && git commit`); `git submodule update --remote --merge`
advances every pointer to the latest pushed `main`. Fresh checkout:
`git clone --recurse-submodules <ws-url>`.

## Where truth lives

- `docs/design/00-overview.md` — system contract and architecture decisions.
  Read it before touching any sub-repo.
- `docs/design/` — per-repo designs and cross-cutting protocols (frames,
  profiles, safety/collision, DAgger, networking).
- `docs/prompts/phase-XX-*.md` — the phased implementation plan. Each phase is
  one session's worth of work; do them in order unless told otherwise.
- `docs/research/` — background research notes (reference only).

## Conventions

- Converse with the user in Chinese; write code, comments, and repo docs in English.
- Python ≥3.10, managed with `uv`; each sub-repo is an installable package
  (`apollo_mavis_v2_core`, `_hardware`, `_sim`, `_runtime`). UI is React+Vite+TS.
- Dependency direction is strict: core depends on nothing in the stack;
  hardware/sim depend only on core; runtime depends on core (+ hardware/sim
  as optional extras); ui talks to runtime over HTTP/WebSocket only.
- Commit/push in sub-repos only when the user asks.

## Hardware facts (not discoverable from code)

- Exactly TWO xArm7 control boxes, one per arm, each on its own ethernet NIC with a
  NetworkManager profile that must be matched to the NIC programmatically at startup:
  `mavis_manipulation_arm` on `enp36s0f1` (192.168.1.11/24) → Manipulation Arm
  (`grip`) control box 192.168.1.201; `mavis_viewpoint_arm` on `enp36s0f0`
  (192.168.2.12/24) → Perception Arm (`view`) control box 192.168.2.219. The
  Manipulation Arm carries the xArm Gripper G2 (gripper model `xarm_g2`); there is no
  6-axis F/T sensor. The default teleop (active) arm is ALWAYS the Manipulation Arm
  (`grip`), hardware and sim.
- Arms may or may not have a linear track (rail); max rail travel 0.65 m.
  Presence must be auto-detected via the xArm SDK.
- Lab cell geometry (tape-measured 2026-09-02): 1.215 × 0.62 × 0.03 m table, top
  0.735 m above the floor; two identical rails 39.5 cm apart along the long axis
  (Perception Arm (`view`) on the outer rail, nearest the operator, 2.6 cm from the
  edge the operator stands at; Manipulation Arm (`grip`) inward). Frame is the
  OPERATOR's view (they are the authority on left/right): +Y = outer edge (operator
  side), operator faces −Y so their right = −X, left = +X. Each linear rail is a
  chiral part, so making its thin plate face the interior (−Y, away from the operator)
  is a true 180° rotation about z, NOT a mirror (a mirror would flip the mesh
  handedness): base_quat yaw +90, which reverses travel — rail zero (q=0) is at the
  operator's LEFT (+X) and qpos increases toward −X (q = 0.65 = the operator's RIGHT
  end, flush with the table edge). Digital-twin INITIAL STATE (mavis_v2 keyframe, user
  decision 2026-09-04): both arms at the xArm7 factory zero posture — joints 2–7 = 0,
  joint 1 = π (the base flip's forward-facing zero) — with the rails at opposite ends:
  Manipulation Arm (`grip`) rail 0.65 m = the operator's RIGHT end, Perception Arm
  (`view`) rail 0.0 = the operator's LEFT end, next to the obstacle. The xArm zero is
  a FOLDED pose (forearm beside the upper arm, tool straight down, flange 12 cm above
  the mount plane, 20.6 cm to the −Y side): the gripper hangs just outside the
  table's inner edge, the D435 + mic hang into the channel looking down (mic tip 3.8
  cm above the table — the tightest initial clearance). The intra-arm pair
  link2↔link4 is 1.78 cm at that posture and is whitelisted in the scene
  (`allowed_pairs`) so the twin audit / gate accept it at the 0.025 debug inflation.
  0.16 × 0.16 × 0.24 m untouchable obstacle flush against the operator's-left (+X)
  end in the channel. (Earlier the scene was mirrored in X from an inner-side
  viewpoint, then fixed to yaw −90 which left the plate facing the operator; turned
  each rail 180° to yaw +90 on 2026-09-03; until 2026-09-04 both arms rested together
  at q ≈ 0.597 in a lowered ready pose, now only the guardrail scenarios use it.)
  Encoded in `apollo-mavis-v2-sim/src/apollo_mavis_v2_sim/assets/scenes/mavis_v2.yaml`
  (header lists every measurement and the assumptions to confirm in phase-09);
  docs/design/03-sim.md §4.3 has the arithmetic. It is the ONLY scene the UI / API
  expose (registry `title: APOLLO MAVIS V2 Digital Twin`); the other scene YAMLs are
  `hidden: true` and kept for CI/tests.
- Microphone (phase-11, 2026-09-03): a RØDE NT-USB Mini is mounted on the Perception
  Arm (`view`) ahead of its wrist camera. ALSA card `Mini` (USB 19f7:0015, serial 750BFEE8),
  PulseAudio source
  `alsa_input.usb-R__DE_Microphones_R__DE_NT-USB_Mini_750BFEE8-00.mono-fallback`,
  S24_3LE mono 48 kHz only. PulseAudio 15.99 owns the card: opening `hw:CARD=Mini`
  directly gives EBUSY and can stall every other recorder — ALWAYS go through Pulse
  (PortAudio/sounddevice via the ALSA `pulse` plugin with `PULSE_SOURCE` pinned, or
  `parec`). The runtime exposes it session-less (`GET /api/microphones`,
  `telemetry.microphone`); the Welcome page shows its live waveform even with no arms.
  In the sim it is an optional collision body on the Perception Arm (`ArmSpec.microphone` /
  `ArmConfig.microphone`, default off; the hardware workcell's digital twin turns it
  on): a cylinder of radius 0.040 m (8 cm diameter) along link7 +z, `size=[0.040,
  0.095]`, `pos=[0, 0, 0.095]` (flange face to 0.14 m beyond the wrist-camera plane
  at z=0.05), mass 0.45 kg (NT-USB Mini ≈0.35 kg + mount — to be weighed), 1.5 cm
  radial clearance to the side-mounted camera. With the body on, the twin's view wrist-cam image is
  occluded from the bottom by the mic (~12 % of the 640×480 frame at the MJCF fovy 57, 03-sim
  §4.3; an earlier estimate said 7–8 %) — expected in the twin. The REAL `view_wrist` image
  (2026-09-04) shows NO occlusion at all: the mic body's size/position in the twin does not
  match the real mount, and the `view_wrist_align` overlay shows exactly that; measure the
  mount before changing the scene, do not "fix" the overlay.
- Wrist cameras (2026-09-04): BOTH arms carry an Intel RealSense D435i (USB 8086:0b3a),
  used as plain UVC colour cameras (`kind: v4l2`, colour stream is YUYV only, 640×480@30;
  no depth is recorded, pyrealsense2 is not installed). USB serial 349643062582 (PCI bus
  29:00.3, USB bus 6) → `grip_wrist` (Manipulation Arm); USB serial 322143060792 (29:00.1,
  USB bus 4) → `view_wrist` (Perception Arm) — CONFIRMED by the user 2026-09-04 from the
  Hardware-tab tiles (an earlier guess had them swapped). Address them by USB serial (sysfs
  lookup in `OpenCVCamera`), NEVER by `/dev/v4l/by-id`: the depth and colour UVC
  interfaces both claim `...-video-index0`, so only one symlink survives and which one
  changes between plugs. COLD-BOOT QUIRK (2026-09-04): after a reboot the colour UVC stream
  delivers no frames (`select() timeout`) until librealsense has opened the device once;
  `OpenCVCamera` therefore runs `rs-enumerate-devices -s` (librealsense2-utils, Intel apt
  repo, installed) once per process before opening a RealSense node — keep that tool
  installed. `rs-enumerate-devices` prints the ASIC serials (243522071002 fw 5.15.1,
  327122074467 fw 5.17.0.10), NOT the USB serials the config uses. The hardware camera ids
  differ from the twin's `grip_wrist_cam` / `view_wrist_cam` on purpose (both coexist in the
  VideoHub). D435i COLOUR intrinsics at 640×480 (`rs-enumerate-devices -c`, Inverse
  Brown-Conrady, distortion ignored; in `configs/mavis_v2.yaml` as `intrinsics:`):
  `grip_wrist` (ASIC 327122074467) fx 608.19 fy 608.23 cx 327.39 cy 247.90; `view_wrist`
  (ASIC 243522071002) fx 606.36 fy 606.38 cx 311.90 cy 249.45 → fovy = 2·atan(240/fy) ≈
  43.2°, NOT the MJCF `wrist_cam` fovy 57 (that is the depth FOV). When rendering the twin
  from these cameras use `cam.resolution/sensor_size/focal_pixel/principal_pixel` with
  `principal_pixel = [320 − cx, 240 − cy]` (MuJoCo's sign is the OPPOSITE of OpenCV's) and
  `offsamples = 0` for segmentation (03-sim §7).
- Control boxes, read-only facts (phase-09a, 2026-09-04; `docs/prompts/phase-09a-hardware-twin-overlay.md`):
  both run firmware **v1.12.10** (`7,7,XS1305,MC1303`; below the 2.7.100 gripper-current
  gate) with xarm-python-sdk **1.18.5** (pinned git rev); both arms `state 4` (not enabled),
  `mode 0`. The Perception Arm (`view`, 192.168.2.219) persistently reports controller error
  **C19** (SDK title "End Effector Communication Error"; xArm Studio: "End Module
  Communication Error" — the end-effector bus); the Manipulation Arm has no error. **Joint
  convention is an IDENTITY mapping**: the controller's 7 joint radians written verbatim into
  `mavis_v2`'s `<arm>_joint1..7` reproduce `get_position()` (flange, tcp_offset zero) to
  0.0 mm / 0.00° on both arms — NO +π on joint 1 (the keyframe's joint1 = π is the real arm's
  actual posture, not an offset); link7 origin = controller flange TCP, `<arm>_link_tcp` site
  168.6 mm below it. **Both linear tracks are unhomed and unenabled**:
  `get_linear_track_registers` → `{pos: 0, status: 2, error: 0, is_enabled: 0, on_zero: 0}`,
  so `pos` is meaningless (the Manipulation Arm's carriage is physically at the operator's
  RIGHT end ≈ sim q 0.65 while its register reads 0); homing (`set_linear_track_back_origin`)
  is a motion command → phase-09. SDK 1.18.5 API gaps (verified in source): `XArmAPI` has NO
  `get_linear_track_sn` / `get_linear_track_version` (`__getattr__` raises; only
  `get_linear_track_registers/pos/status/error/is_enabled/on_zero`, `set_linear_track_*`,
  `clean_linear_track_error`, `get_linear_motor_registers`); `register_report_callback` has
  NO `report_mode` kwarg; the 30003 report payload carries NO `mode` (use `api.mode`);
  `api.version` is the RAW string `7,7,XS1305,MC1303,v1.12.10` (use `api.version_number`);
  G2/classic gripper `set_*` need `wait_motion=False` or they `wait_move()`. The runtime's
  session-less READ-ONLY monitor (`telemetry.hardware_monitor`, one SDK client per arm,
  polling allowlist in hardware `monitor.py`; since phase-09b "zero writes unless an explicit
  maintenance request", next bullet) drives the twin overlays `grip_wrist_align` /
  `view_wrist_align` (kind `twin`, Hardware tab); it is PAUSED = disconnected while a
  hardware session owns a box (two SDK clients on one box are unevidenced). Read-only is not
  side-effect-free: SDK `connect()` runs `clean_warn()` if a warning is latched, and the first
  track/gripper register read may rewrite the RS-485 baud + soft-reboot the end module if the
  controller's baud differs from the SDK default (02-hardware §8.5).
- Controller error clearing / recovery + controller-side safety parameters (phase-09b,
  2026-09-04; `docs/prompts/phase-09b-error-recovery.md`). **C19 cause**: the control box looks
  for an end effector on the tool-port RS-485 bus and the Perception Arm has none
  (`get_tgpio_modbus_baudrate` → `(1, -1)`); it comes back after every clear until the one-off
  fix in xArm Studio: Settings → Externals → End Effector → **None** (SDK 1.18.5 has no write
  API for it). **Clearing errors produces no motion (measured 2026-09-04)**: `clean_error()` on
  the Perception Arm cleared C19, no recurrence for 6 s, all seven joints changed ≤ 5e-5 rad
  (encoder noise); the full recovery sequence `clean_error → clean_warn → motion_enable(True)
  → set_mode(1) → set_state(0)` is equally motion-free (it only enables / enters servo state;
  `motion_enable` releases the brakes so the motors hold position actively — motion comes only
  from explicit motion commands). Linear-track homing (`set_linear_track_back_origin`) IS motion
  and is NOT a maintenance op (phase-09). Interface: `POST /api/hardware/arms/{arm_id}/maintenance
  {op}` — `clear_errors` (no session: `clean_error` + `clean_warn` on the read-only monitor's
  poll thread, never enables; INSIDE a hardware session it is routed to the session driver's
  user-initiated recovery and is then equivalent to `recover`, i.e. it DOES `motion_enable` —
  the Welcome button never posts it then), `apply_backstops` (no session; 409 during one),
  `recover` (hardware session only: the driver's user-initiated recovery + re-seed from the
  MEASURED position; 409 without one). UI: Hardware-tab arm card **Clear errors** / **Apply
  safety settings** (disabled with "Use the Cockpit" while a hardware session owns the boxes),
  Cockpit `FaultBanner` **Clear errors & resume** (then re-grip the clutch). The monitor's
  guarantee is now "zero writes unless an explicit maintenance request"; the driver's own
  bounded auto-recovery (3 per 30 s for recoverable codes) is unchanged, anything LATCHED
  beyond it waits for the click. **Controller-side backstops live in core `ArmConfig`**
  (`tcp_load_kg`, `tcp_load_cog_mm`, `collision_sensitivity` 0..5, optional
  `reduced_tcp_boundary_mm`, `expected_sn`) → `configs/mavis_v2.yaml`, estimates the user accepted
  on 2026-09-05 without weighing (whole-arm collision detection is the goal): Manipulation Arm (G2 + D435i + mount) **0.95 kg @ (0, 0, 60) mm**,
  Perception Arm (D435i 0.072 kg + NT-USB Mini ≈ 0.35 kg + mount) **0.55 kg @ (0, 0, 90) mm**,
  collision sensitivity **3 on both**. As found 2026-09-04 both boxes had `tcp_load` 0 kg
  (wrong — collision detection is torque-estimate based) and sensitivity 3 (grip) / 1 (view).
  They are volatile (lost at a controller reboot, never `save_conf()`ed); the driver re-applies
  them at every connect. Read-back: SDK 1.18.5 has no `get_tcp_load` /
  `get_collision_sensitivity`; `XArmAPI.tcp_load` / `.collision_sensitivity` are properties fed
  by the rich 30002 report frame (NOT the 30003 stream the session driver uses) →
  `telemetry.hardware_monitor.arms[*]` `tcp_load_kg` / `tcp_load_cog_mm` /
  `collision_sensitivity` / `backstops_match` (sensitivity equal, |Δ load| ≤ 0.05 kg, |Δ cog| ≤
  10 mm). **`arm.sn` reads the model code `XS1305` on BOTH boxes**, not a unique serial →
  `expected_sn` stays None (useless for catching swapped cables; the NIC ↔ profile mapping is
  the check). Never open UFACTORY Studio "Live control" during a session (the driver's
  `StudioConflictWarning` shows as `fault_detail` "warning: close UFACTORY Studio live control").
- Machine: Ubuntu 22.04, 2× RTX 4090, node 22, nmcli available. Python: core/sim/
  hardware target ≥3.10; runtime requires 3.12 (lerobot floor; uv-managed).
  NVIDIA driver 580.173.02 (upgraded 2026-09-01); NVENC works. lerobot's
  `g=2` GOP needs `bf=0` on NVENC (runtime recorder injects it), otherwise
  the open fails and `vcodec: auto` falls back to libsvtav1.
