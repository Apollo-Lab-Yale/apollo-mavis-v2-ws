# `var/` — workspace-local runtime data (gitignored)

Everything the MAVIS v2 runtime reads or writes at run time lives here, so a fresh
`git clone --recurse-submodules` is self-contained: no `~/apollo`, no machine-specific
absolute paths. The tracked configs anchor these at `${APOLLO_HOME}/var/...`, where
`${APOLLO_HOME}` is this workspace root (see `apollo-mavis-v2-runtime/src/.../config.py`).

Contents (all gitignored except this file):

- `profiles/`      teleop / arm profiles (`ProfileStore`)
- `datasets/`      recorded episodes (LeRoot HDF5 + MP4)
- `checkpoints/`   trained policy checkpoints
- `calibration/`   `tracker_calibration.json` (applied yaw, base-station install state)
- `libsurvive/`    `config.json` — lighthouse calibration libsurvive reads/writes at teleop
- `logs/`, `run/`  developer-instance logs + pidfiles (`scripts/dev/mavis-dev.sh`)
- `mavis_v2_local.yaml`  rendered local runtime config (from `scripts/dev/mavis-dev.sh render`)

Developer workflow: `scripts/dev/mavis-dev.sh render` then `... start`. Machine-specific
and safety-sensitive knobs (tracker yaw, libsurvive backend, `hardware_session.armed`)
live in the gitignored `scripts/dev/local.env` and the rendered `mavis_v2_local.yaml`,
never in a tracked file. The ops deploy uses the FHS layout instead (systemd units under
`scripts/deploy/`, data in `/var/lib/apollo-mavis-v2`).
