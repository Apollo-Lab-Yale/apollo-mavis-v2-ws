# apollo-mavis-v2-ws

Development workspace for **MAVIS v2** (Manipulation And Viewpoint Selection,
version 2), the Apollo Lab (Yale) dual-arm cell: two UFACTORY xArm7 arms, each
mounted on a linear track, facing a shared tabletop. One arm carries the xArm
gripper plus a wrist camera (the *grip* arm); the other carries only a wrist
camera and acts as the *perception* / viewpoint arm (the *view* arm). The
software stack does teleoperation, data collection, Online DAgger (an
algorithm-agnostic shell for online interactive learning — rollouts, take-over /
hand-back, novice / expert labels — with the policy AND its trainer in an
external dora node, phase-14) and policy inference for exactly this cell,
against the real hardware or its MuJoCo
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
                apollo-mavis-v2-policy-node   ← independent dora policy node (phase-12; copies core's
                                                 wire spellings, never imports the stack; local repo, no remote yet;
                                                 phase-14 adds the generic Online DAgger trainer role, PRO-DAgger
                                                 as a reference implementation on top of it, and the byte-identical
                                                 mirror of the runtime's `mavis-online-dagger-trainer` skill)
```

## Layout

- `apollo-mavis-v2-*/` — the five sub-repos as git submodules (submodules
  since 2026-09-03; each tracks its own `main`; a ws commit pins one consistent
  combination). The repos were renamed from `apollo-xarm7-*` on 2026-09-03;
  GitHub redirects the old names, so old clone URLs still resolve. Clone with
  `git clone --recurse-submodules`, or run `git submodule update --init` in an
  existing checkout; `git submodule update --remote --merge` moves every
  pointer to the latest pushed `main`. Work inside each sub-repo on `main`,
  never on a detached HEAD — if `git submodule status` shows one, run
  `git -C <sub> switch main` before editing (a detached HEAD is normal only in
  the ops clone, `docs/deploy/DEPLOYMENT.md`). Commit and push inside a
  sub-repo first, then commit the updated pointer here. Commits and pushes in
  the sub-repos are made only on the maintainer's explicit request; a session
  never pushes on its own.
- `docs/architecture.md` — topology sketch.
- `docs/research/` — research notes on reference repos and tech choices.
- `docs/design/` — detailed design documents per repo + cross-cutting protocols
  (`00-overview.md` is the spine; `14-dora-interface.md` the external dora bus,
  `15-online-dagger.md` the Online DAgger shell (v2.0, 2026-09-08 evening;
  `15-pro-dagger.md` v1.0 is kept for history only)).
- `docs/prompts/` — phased development prompts; each phase is meant to be a
  self-contained instruction for one implementation session (status table in
  `docs/prompts/README.md`; latest: `phase-14-online-dagger.md`, 2026-09-08).
- `docs/deploy/DEPLOYMENT.md` — operations deployment guide (dedicated `mavis`
  account, `/opt/apollo-mavis-v2`, systemd user service, dev-vs-ops hardware
  ownership); the matching scripts live in `scripts/deploy/`.

## Development flow

Work proceeds phase by phase following `docs/prompts/`. Read
`docs/design/00-overview.md` first for the system contract.
