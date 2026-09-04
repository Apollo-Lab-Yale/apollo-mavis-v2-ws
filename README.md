# apollo-mavis-v2-ws

Development workspace for **MAVIS v2** (Manipulation And Viewpoint Selection,
version 2), the Apollo Lab (Yale) dual-arm cell: two UFACTORY xArm7 arms, each
mounted on a linear track, facing a shared tabletop. One arm carries the xArm
gripper plus a wrist camera (the *grip* arm); the other carries only a wrist
camera and acts as the *perception* / viewpoint arm (the *view* arm). The
software stack does teleoperation, data collection, DAgger and policy
inference for exactly this cell, against the real hardware or its MuJoCo
digital twin (scene `mavis_v2` in `apollo-mavis-v2-sim`, which is the
authoritative description of the cell's geometry).

## Topology

```
               interface definitions
                      │
                apollo-mavis-v2-core          ← interfaces, schemas, protocols
                 /          \
                /            \
       implementation     implementation
              │                │
apollo-mavis-v2-hardware        apollo-mavis-v2-sim
   (real xArm7 drivers)      (MuJoCo scenes + digital twin)
                \            /
                 \          /
                  ▼        ▼
               apollo-mavis-v2-runtime        ← teleop / data collection / DAgger / inference
                      │
                apollo-mavis-v2-ui            ← web UI, orchestration
```

## Layout

- `apollo-mavis-v2-*/` — the five sub-repos as git submodules (each tracks
  its own `main`; a ws commit pins one consistent combination). Clone with
  `git clone --recurse-submodules`, or run `git submodule update --init` in an
  existing checkout; `git submodule update --remote --merge` moves every
  pointer to the latest pushed `main`. Commit and push inside a sub-repo first,
  then commit the updated pointer here.
- `docs/architecture.md` — topology sketch.
- `docs/research/` — research notes on reference repos and tech choices.
- `docs/design/` — detailed design documents per repo + cross-cutting protocols.
- `docs/prompts/` — phased development prompts; each phase is meant to be a
  self-contained instruction for one implementation session.
- `docs/deploy/DEPLOYMENT.md` — operations deployment guide (dedicated `mavis`
  account, `/opt/apollo-mavis-v2`, systemd user service, dev-vs-ops hardware
  ownership); the matching scripts live in `scripts/deploy/`.

## Development flow

Work proceeds phase by phase following `docs/prompts/`. Read
`docs/design/00-overview.md` first for the system contract.
