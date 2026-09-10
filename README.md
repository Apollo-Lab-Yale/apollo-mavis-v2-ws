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

## Running the cell — the shared operations account

**The lab cell runs from one shared operations account.** Its checkout at
`~/apollo-mavis-v2-ws` is the copy that drives the real arms; a developer's own checkout
(`~/projects/apollo-mavis-v2-ws` in their own home) is for writing code, not for sessions.
Nothing in this repository hard-codes which account that is — it is the `OPS_USER` knob in
`scripts/deploy/_common.sh`, and the systemd unit uses systemd's `%h`, so the same tree
deploys under any account name. **On the Apollo lab machine it is `mavis-v2`**, admin
password **`ApolloLab#`**, and the account is a sudoer. Log in on the machine's desktop as
that account, or from another account:

```bash
sudo -iu mavis-v2          # or: su - mavis-v2   (both ask for a password)
```

A real login — the desktop session or `ssh mavis-v2@localhost` — is the easy way, because
`systemctl --user` needs the account's own D-Bus. `sudo -iu` / `su -` do **not** set it up,
and every `systemctl --user` then fails with *"Failed to connect to bus"*. Fix it in that
shell with:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
```

### Bring it up

```bash
systemctl --user start mavis-runtime          # the API + the built UI on :8765
systemctl --user status mavis-runtime         # Active: active (running)?
```

Then open **<http://127.0.0.1:8765/>** in a browser on this machine. That one service is
the whole stack: the FastAPI server, the built React UI it serves itself, the Vive
tracker, the microphone and the arm probes. There is no separate UI server to start and
no database.

It binds `127.0.0.1` and has **no authentication**: reachable from any account on this
machine, from nowhere else. Keep it that way — do not bind `0.0.0.0` to "just have a
look from a laptop".

```bash
journalctl --user -u mavis-runtime -f         # live log
tail -f ~/apollo-mavis-v2-ws/var/logs/runtime.log        # the 1 Hz `loop:` health line
systemctl --user stop mavis-runtime           # release the arms, dongle, mic and port
bash ~/apollo-mavis-v2-ws/scripts/deploy/healthcheck.sh  # read-only: arms, cameras, mic, tracker, UI
```

`start` is deliberately manual: **autostart at boot is OFF**. This config is *armed*
(it may open the real xArm drivers), and nobody wants the cell connecting itself with
no operator in the room — it would also take the tracker dongle, the microphone and
port 8765 away from a developer's instance. Turn it on only if you want that:
`AUTOSTART=1 bash ~/apollo-mavis-v2-ws/scripts/deploy/install-services.sh`.

**One runtime at a time.** The Watchman dongle, the RØDE microphone, each control box
and port 8765 all take a single owner. If the service will not start, a developer's
runtime is usually still holding them — stop that one first (`ss -tlnp | grep 8765`).

If the tracker never leaves `searching`, check that the Watchman dongle is actually
plugged in (`lsusb -d 28de:2101`); if the wrist cameras come up dark, see
`docs/deploy/DEPLOYMENT.md` (the cold-boot D435i quirk).

### Where things live

Everything below is relative to the operations account's home (`~` = `/home/mavis-v2` on
the lab machine).

| | |
|---|---|
| checkout (all five sub-repos) | `~/apollo-mavis-v2-ws` |
| rendered runtime config | `~/apollo-mavis-v2-ws/var/mavis_v2_lab.yaml` (generated — re-render, never edit) |
| persistent render knobs | `~/apollo-mavis-v2-ws/var/lab.env` (arming, tracker yaw, dora bind host) |
| profiles, calibration, logs | `~/apollo-mavis-v2-ws/var/{profiles,calibration,logs}` |
| **recorded demonstrations** | `~/data/bc_demo/<name>` |
| **Online DAgger rollouts** | `~/data/online_dagger/<session>/rollouts` |
| UFACTORY Studio | menu entry "UFACTORY-Studio (1.0.2)"; the AppImage is in `~/Applications` |

Datasets live in `~/data`, *outside* the checkout, one directory per episode, so a
re-clone or a `git clean` can never touch recorded data. `GET /api/datasets/layout`
publishes the map the UI uses.

### Updating

**Every repo in the stack is public, and the account holds no GitHub credentials.**
Pulls are anonymous HTTPS — nothing to log in to, nothing to expire:

```bash
bash ~/apollo-mavis-v2-ws/scripts/deploy/update.sh
```

That refuses to run while a session is open, stops the service, pulls the workspace and
every submodule at the pinned combination, re-syncs the four virtualenvs, rebuilds the
UI, re-renders the config from `var/lab.env` and restarts. To look before you leap:
`git -C ~/apollo-mavis-v2-ws fetch --recurse-submodules && git -C ~/apollo-mavis-v2-ws status`.

Never `git commit` in this checkout — it must stay clean so it can always fast-forward.
Development happens in a developer's own clone and arrives here through GitHub.

### Copying data in from a developer account

```bash
DEV_USER=<their-account> bash ~/apollo-mavis-v2-ws/scripts/deploy/sync-data-from-dev.sh
DRY_RUN=1 … # list first; DIRECTION=ops-to-dev copies the other way
```

Additive `rsync` (never deletes on the receiving side), re-owned to the receiving account.
`DEV_USER` defaults to whoever runs the script, so from a developer's own shell the bare
command already does the right thing.

### Before you move an arm

The digital twin does **not** yet model the room the cell now stands in, and the arms
and rails themselves are 15–30 mm out in the twin (`docs/design/03-sim.md` §4.5). The
collision gate is therefore inflated to 25 mm as a stop-gap and still cannot see the
blue cart or the kitchen run. Treat every planned motion — return-to-start, `R`,
"Go to profile", `home_rail` — as unverified: **10 % speed, hand on the E-stop.** Never
open UFACTORY Studio's "Live control" while a session is running.

Full operator guide, first-time install and troubleshooting: `docs/deploy/DEPLOYMENT.md`.

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
- `docs/deploy/DEPLOYMENT.md` — operations deployment guide (the shared operations
  account, its `~/apollo-mavis-v2-ws` checkout, the systemd user service, anonymous
  public-repo updates, dev-vs-ops hardware ownership); the matching scripts live in
  `scripts/deploy/`, and the day-to-day commands are in "Running the cell" above.

## Development flow

Work proceeds phase by phase following `docs/prompts/`. Read
`docs/design/00-overview.md` first for the system contract.
