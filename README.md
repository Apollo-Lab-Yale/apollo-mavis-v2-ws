# apollo-xarm7-ws

Development workspace for the Apollo Lab xArm7 stack: teleoperation, data
collection, DAgger, and policy inference for 1–3 UFACTORY xArm7 arms
(optionally on linear rails), against real hardware or MuJoCo simulation.

## Topology

```
               interface definitions
                      │
                apollo-xarm7-core          ← interfaces, schemas, protocols
                 /          \
                /            \
       implementation     implementation
              │                │
apollo-xarm7-hardware        apollo-xarm7-sim
   (real xArm7 drivers)      (MuJoCo scenes + digital twin)
                \            /
                 \          /
                  ▼        ▼
               apollo-xarm7-runtime        ← teleop / data collection / DAgger / inference
                      │
                apollo-xarm7-ui            ← web UI, orchestration
```

## Layout

- `apollo-xarm7-*/` — the five sub-repos, cloned side by side (gitignored
  here until they have initial commits and are converted to submodules).
- `docs/architecture.md` — topology sketch.
- `docs/research/` — research notes on reference repos and tech choices.
- `docs/design/` — detailed design documents per repo + cross-cutting protocols.
- `docs/prompts/` — phased development prompts; each phase is meant to be a
  self-contained instruction for one implementation session.

## Development flow

Work proceeds phase by phase following `docs/prompts/`. Read
`docs/design/00-overview.md` first for the system contract.
