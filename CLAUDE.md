# apollo-mavis-v2-ws — guidance for Claude

## What this is

Development workspace for **MAVIS v2** (Manipulation And Viewpoint Selection v2),
the Apollo Lab (Yale) dual-arm cell: two UFACTORY xArm7 arms on linear tracks over
one table — the *grip* arm (xArm gripper + wrist camera) and the *view* arm
(wrist camera only, the perception / viewpoint arm). The stack targets exactly
this cell, real or as its MuJoCo digital twin (scene `mavis_v2`), not xArm7 in
general. Five repos: `apollo-mavis-v2-core` (interfaces/schemas/protocols) ←
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

- 3 ethernet NICs, each wired to one real xArm7 control box; NetworkManager
  profiles must be matched to NICs programmatically at startup.
- Arms may or may not have a linear track (rail); max rail travel 0.65 m.
  Presence must be auto-detected via the xArm SDK.
- Lab cell geometry (tape-measured 2026-09-02): 1.215 × 0.62 × 0.03 m table, top
  0.735 m above the floor; two identical rails 39.5 cm apart along the long axis
  (camera-only arm on the outer rail, nearest the operator, 2.6 cm from the edge the
  operator stands at; gripper + wrist-cam arm inward). Frame is the OPERATOR's view
  (they are the authority on left/right): +Y = outer edge (operator side), operator
  faces −Y so their right = −X, left = +X. The arms REST at the operator's right (−X),
  flush with the table edge. Each linear rail is a chiral part, so making its thin
  plate face the interior (−Y, away from the operator) is a true 180° rotation about z,
  NOT a mirror (a mirror would flip the mesh handedness): base_quat yaw +90, which
  reverses travel — rail zero (q=0) is now at the operator's LEFT (+X) and qpos
  increases toward −X, so the arms rest at rail q ≈ 0.597 and the keyframe adds π to
  joint 1 to re-face the workspace. 0.16 × 0.16 × 0.24 m untouchable obstacle flush
  against the operator's-left (+X) end in the channel. (Earlier the scene was mirrored
  in X from an inner-side viewpoint, then fixed to yaw −90 which left the plate facing
  the operator; turned each rail 180° to yaw +90 on 2026-09-03.) Encoded in apollo-mavis-v2-sim
  `scenes/mavis_v2.yaml` (header lists every measurement and the assumptions to
  confirm in phase-09); docs/design/03-sim.md §4.3 has the arithmetic.
- Machine: Ubuntu 22.04, 2× RTX 4090, node 22, nmcli available. Python: core/sim/
  hardware target ≥3.10; runtime requires 3.12 (lerobot floor; uv-managed).
  NVIDIA driver 580.173.02 (upgraded 2026-09-01); NVENC works. lerobot's
  `g=2` GOP needs `bf=0` on NVENC (runtime recorder injects it), otherwise
  the open fails and `vcodec: auto` falls back to libsvtav1.
