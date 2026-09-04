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
  radial clearance to the side-mounted camera. With the body on, the bottom ~7–8% of
  the view wrist-cam image is occluded by the mic — that is expected.
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
  VideoHub).
- Machine: Ubuntu 22.04, 2× RTX 4090, node 22, nmcli available. Python: core/sim/
  hardware target ≥3.10; runtime requires 3.12 (lerobot floor; uv-managed).
  NVIDIA driver 580.173.02 (upgraded 2026-09-01); NVENC works. lerobot's
  `g=2` GOP needs `bf=0` on NVENC (runtime recorder injects it), otherwise
  the open fails and `vcodec: auto` falls back to libsvtav1.
