# apollo-xarm7-ws — guidance for Claude

## What this is

Development workspace for a five-repo robotics stack (Apollo Lab, Yale):
`apollo-xarm7-core` (interfaces/schemas/protocols) ← `apollo-xarm7-hardware`
(real xArm7 drivers) and `apollo-xarm7-sim` (MuJoCo) ← `apollo-xarm7-runtime`
(teleop / data collection / DAgger / inference) ← `apollo-xarm7-ui` (web UI).

The five sub-repos live side by side in this directory as independent git
clones (gitignored by the ws repo until converted to submodules).

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
  (`apollo_xarm7_core`, `_hardware`, `_sim`, `_runtime`). UI is React+Vite+TS.
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
  (camera-only arm on the outer rail, 2.6 cm from the edge the arms face; gripper +
  wrist-cam arm inward), zero at the right end; 0.16 × 0.16 × 0.24 m untouchable
  obstacle flush against the right end in the channel between the rails. Encoded in
  apollo-xarm7-sim `scenes/mavis_v2.yaml` (header lists every measurement and the
  assumptions to confirm in phase-09); docs/design/03-sim.md §4.3 has the arithmetic.
- Machine: Ubuntu 22.04, 2× RTX 4090, node 22, nmcli available. Python: core/sim/
  hardware target ≥3.10; runtime requires 3.12 (lerobot floor; uv-managed).
  NVIDIA driver 580.173.02 (upgraded 2026-09-01); NVENC works. lerobot's
  `g=2` GOP needs `bf=0` on NVENC (runtime recorder injects it), otherwise
  the open fails and `vcodec: auto` falls back to libsvtav1.
