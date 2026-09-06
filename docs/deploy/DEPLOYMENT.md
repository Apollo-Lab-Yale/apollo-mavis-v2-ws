# MAVIS v2 — deployment and operations guide (lab machine `apollo-pc-1`)

Audience: anyone standing at the lab machine who has to (re)deploy or operate the
MAVIS v2 stack under the dedicated operations account **`mavis`**, without touching
the developer's account. Every command is copy-pasteable and was checked against the
machine on 2026-09-04 (Ubuntu 22.04.5, systemd 249, NVIDIA 580.173.02, PulseAudio
15.99). Items marked **verify on first deploy** could not be exercised without
creating the account; check them the first time and fix this document.

The matching scripts live in `scripts/deploy/` (idempotent, `set -euo pipefail`,
print what they do); every step below shows both the script and the commands it
runs. Defaults shared by all scripts are in `scripts/deploy/_common.sh` and can be
overridden from the environment (`OPS_USER`, `OPS_ROOT`, `DATA_ROOT`, …).

Before you start — **read this first**:

1. The ops checkout is cloned from GitHub (`Apollo-Lab-Yale/apollo-mavis-v2-ws`, public,
   no credentials). It gets only what is **pushed and pinned**: a sub-repo commit reaches
   the ops machine only when it is on that repo's `origin/main` AND referenced by a pushed
   workspace commit. Before S3 and before every S9 upgrade the developer pushes **all five**
   repos in dependency order — `core` → `sim` / `hardware` → `runtime` → `ui` (after
   `npm run gen:sync && npm run gen:types`, so the generated types match core's schemas) —
   then bumps the five pointers in the workspace (`git add apollo-mavis-v2-* && git commit
   && git push`). Check in the developer tree: `git status -sb` in the ws and in every
   sub-repo shows no `[ahead N]`, and `git submodule status` has no line starting with `+`
   (checkout ahead of the pinned commit) or `-` (not initialised). On the ops side
   `git -C /opt/apollo-mavis-v2 submodule status` must list the same five hashes. State when
   this was written (2026-09-04): everything the guide relies on is pushed and pinned —
   core `a1fce61` (v4l2 cameras by USB serial + `fourcc`), hardware `3e54c6c` (netsetup
   dispatcher, `install --python/--user`), runtime `f7e9868`, sim `5c58840`, ui `3647a03`.
   If core lags runtime, the S4 render fails validation; if ui lags core, `gen:check` fails.
2. Real-arm sessions landed with **phase-09c / 09d** (2026-09-05; contracts
   `docs/prompts/phase-09c-hardware-session.md` + `phase-09d-rail-homing-planning.md`) but have
   **never run on the real boxes yet** (fakes only): `POST /api/session kind=hardware` is
   teleop-only, ALWAYS brings up both arms (phase-09d: `SessionSpec.arms` must be every
   configured arm — no per-arm switch on the Hardware tab) at `speed_scale` (default 10 %),
   and is refused (409 `rail not homed`) while either linear track is unhomed — the operator
   homes it first with the arm card's **Home rail**, the ONE maintenance action that moves
   hardware (twin-gated; since phase-09d it may first drive the arm along a twin-planned,
   rail-position-agnostic path to a folded posture at 10 % and then hold it there, S7). The
   first live run follows the 09c contract's 真机验收步骤 (as amended by its 09d header note)
   with the user present and the e-stop in hand (S7).
   Also running against the real cell: arm reachability probes, the read-only controller
   monitor + twin overlays, the RØDE microphone preview, Vive tracker teleop + calibration
   wizard, the two RealSense colour previews (mapped to the arms by USB serial, S4), and
   full **sim** sessions on the `mavis_v2` digital twin.
3. Exactly **one** process may own the Watchman dongle, the microphone capture and the
   arms (S8). The developer's runtime on `:8765` owns them right now; the ops service
   cannot start on the same machine until that instance is stopped or moved (S8.3).

---

## S0. What you get

```
                       browser  http://127.0.0.1:8765/  (or via ssh -L / tailscale)
                          │
   systemd --user (mavis) │  mavis-runtime.service   (starts at boot: loginctl enable-linger)
   ┌──────────────────────┴──────────────────────────────────────────────────────────┐
   │ /opt/apollo-mavis-v2/apollo-mavis-v2-runtime/.venv/bin/python -m apollo_mavis_v2_runtime
   │   --config /var/lib/apollo-mavis-v2/mavis_v2_lab.yaml    MUJOCO_GL=egl           │
   │   ├─ FastAPI/uvicorn :8765  /api/*  /ws/control  /ws/telemetry  /ws/video/*  /video/*
   │   ├─ built UI (ui_dist = .../apollo-mavis-v2-ui/dist) mounted at /              │
   │   ├─ tracker: libsurvive via pysurvive -> Watchman dongle 28de:2101 (exclusive)  │
   │   ├─ microphone: RØDE NT-USB Mini through the account's OWN PulseAudio (pactl/parec)
   │   ├─ hardware probe: TCP 502 to 192.168.1.201 (grip) and 192.168.2.219 (view), 2 s
   │   ├─ sim previews: MuJoCo EGL on GPU 0 (/dev/nvidia*, /dev/dri/renderD*)         │
   │   └─ dagger trainer child: ZMQ tcp://127.0.0.1:5757, CUDA_VISIBLE_DEVICES=1     │
   └─────────────────────────────────────────────────────────────────────────────────┘
   root: NetworkManager dispatcher /etc/NetworkManager/dispatcher.d/90-mavis-netsetup
         keeps the two arm NICs on their profiles at boot / cable events (S5)
```

| Item | Location | Owner |
|---|---|---|
| Workspace checkout (5 submodules, 4 venvs, uv interpreters in `.uv/python`, UI dist) | `/opt/apollo-mavis-v2` | `mavis:mavis`, setgid 2775, developers in group `mavis` may write |
| Profiles, datasets, checkpoints, tracker calibration, libsurvive config, pysurvive wheel staging | `/var/lib/apollo-mavis-v2/{profiles,datasets,checkpoints,calibration,libsurvive,wheels}` | `mavis:mavis`, 2775 + default ACL |
| Lab runtime config (rendered by S4 — no sudo, re-rendered by mavis alone in S9) | `/var/lib/apollo-mavis-v2/mavis_v2_lab.yaml` | `mavis:mavis`, 664 |
| netsetup system state | `/etc/apollo-mavis-v2/nic_map.json` (written by root) | root |
| Service unit | `/home/mavis/.config/systemd/user/mavis-runtime.service` | mavis |
| Logs | `journalctl --user -u mavis-runtime` (as mavis); netsetup: `/var/log/mavis-netsetup.log` | — |

The developer account (`xiatao`) is untouched: its checkout, venvs, `~/.config/libsurvive`,
`~/apollo/*`, nvm and uv stay where they are. Two things are shared by nature and are
system-wide already: the udev rules (`/etc/udev/rules.d/60-apollo-teleop-input.rules`) and
the NetworkManager profiles `mavis_manipulation_arm` / `mavis_viewpoint_arm`.

Ports in use on this machine you must not collide with: 22 ssh, 8000 (gohttpserver),
4000, 631 cups, 5939 TeamViewer, 21115-21119 RustDesk, 7001/12001/20804-5/25001 NoMachine.
The stack uses 8765 (runtime), 5757 (trainer ZMQ), 5173 (Vite, developers only).

---

## S1. Prerequisites (sudo, once per machine)

Script: `bash scripts/deploy/install-system-deps.sh` (run as your own sudo-capable
account, not as root). It performs S1 and the system half of S5.

1. Packages (all already installed on apollo-pc-1; this is the reproducible list):

   ```bash
   sudo apt-get update && sudo apt-get install -y \
     build-essential cmake ninja-build pkg-config git curl ca-certificates \
     zlib1g-dev libx11-dev libusb-1.0-0-dev libeigen3-dev libopenblas-dev liblapacke-dev \
     libatlas-base-dev libudev-dev \
     libportaudio2 pulseaudio pulseaudio-utils alsa-utils \
     libegl1 libgl1 libgles2 libglvnd0 ffmpeg v4l-utils \
     network-manager udev acl
   ```

   Not needed: `python3-venv` (uv creates venvs itself), a system CUDA toolkit (the
   runtime venv ships CUDA 13 wheels), `pyrealsense2` (cameras are opened as v4l2/OpenCV).

2. NVIDIA driver + EGL — must already be there (580.173.02 on this box):

   ```bash
   nvidia-smi --query-gpu=index,name,driver_version,pci.bus_id --format=csv
   ls /usr/share/glvnd/egl_vendor.d/10_nvidia.json /dev/dri/renderD* /dev/nvidia0
   ```

   GPU index 0 is PCI 41:00.0 (render node `renderD129`), index 1 is 61:00.0
   (`renderD128`). `/dev/nvidia*` are 0666; `/dev/dri/renderD*` are `root:render 0660` —
   the headless runtime opens both, hence group `render` in S2.

3. `uv` and `node` are **per-user** installs (the developer's live in `~/.local/bin/uv`
   and `~/.nvm`, unreadable from other accounts because homes are 0750). S3 installs
   them for whoever runs the build. The Python **interpreters** uv downloads are the one
   thing that must *not* be per-user: every venv symlinks to its interpreter
   (`.venv/bin/python -> …/cpython-3.12.x/bin/python3.12`), so S3 places them under
   `/opt/apollo-mavis-v2/.uv/python` (`UV_PYTHON_INSTALL_DIR`, world-readable, gitignored).
   A copy in the builder's home would make the ops venvs fail with EACCES for every other
   account — including `mavis-runtime.service` if a developer did the build. Ubuntu's apt
   `nodejs` is 12.22.9 — do not use it.

4. inotify: `/etc/sysctl.d/60-inotify.conf` already raises
   `fs.inotify.max_user_watches=524288` system-wide (the script re-creates it if missing).

---

## S2. The `mavis` account, groups, linger, shared directories (sudo)

Script: `bash scripts/deploy/create-mavis-account.sh` (`DEV_USER=<name>` adds that
developer to group `mavis`; default: you). Manual equivalent:

```bash
sudo useradd --create-home --user-group --shell /bin/bash --comment "MAVIS v2 operations" mavis
sudo usermod -aG render,video,plugdev,input,audio,netdev,dialout mavis
sudo usermod -aG mavis "$USER"                 # developer: write access to /opt + /var/lib trees (re-login)
sudo loginctl enable-linger mavis              # user manager at boot -> XDG_RUNTIME_DIR=/run/user/<uid>, PulseAudio socket
sudo install -d -m 2775 -o mavis -g mavis /opt/apollo-mavis-v2
sudo install -d -m 2775 -o mavis -g mavis /var/lib/apollo-mavis-v2 \
  /var/lib/apollo-mavis-v2/{profiles,datasets,checkpoints,calibration,libsurvive,wheels}   # wheels: pysurvive staging (S3)
for d in /opt/apollo-mavis-v2 /var/lib/apollo-mavis-v2 /var/lib/apollo-mavis-v2/*/; do
  sudo setfacl -m d:u::rwX,d:g::rwX,d:o::rX "$d"   # new files stay group-writable
done
sudo install -d -m 755 -o root -g root /etc/apollo-mavis-v2      # netsetup's nic_map.json only (S5); the lab config lives in /var/lib
id mavis; loginctl show-user mavis -p Linger
```

Why each group (checked against real node ownership, `ls -la`):

| group | device | why |
|---|---|---|
| `render` | `/dev/dri/renderD128`, `renderD129` (`root:render 0660`) | MuJoCo EGL opens them (the live runtime holds both) |
| `plugdev` | dongle `/dev/bus/usb/009/002` (`root:plugdev 0660`), RealSense hidraw | `60-apollo-teleop-input.rules`; librealsense rules |
| `input` | gamepad `/dev/input/event17` (`root:input 0660`) | same rule file |
| `audio` | `/dev/snd/*` (`root:audio 0660`) | mavis's own PulseAudio must open the RØDE card |
| `netdev` | — | netsetup's polkit `.pkla` grants NetworkManager control to `unix-group:netdev` |
| `video`, `dialout` | `/dev/dri/card*`, serial | not needed today; harmless |

The developer's devices work through `TAG+="uaccess"` ACLs (`user:xiatao:rw-`) that
logind grants to the **seat owner**. A lingering account never owns a seat, so `mavis`
gets nothing from uaccess and relies entirely on the MODE/GROUP fallbacks above.
**Verify on first deploy**: from a mavis shell, `ls -la /dev/bus/usb/$(lsusb -d 28de:2101 | awk '{printf "%s/%s", $2, substr($4,1,3)}')` and `test -r /dev/dri/renderD128 && echo ok`.

Group changes apply to new sessions only: after S2, `sudo systemctl restart user@$(id -u mavis).service`
(or reboot) so the user manager itself carries the groups.

No password is set; use `sudo -iu mavis` (or `sudo passwd mavis` if a console login is wanted).

---

## S3. Clone and build under `/opt` (no sudo)

Run as `mavis` (`sudo -iu mavis`, recommended) or as a developer who is in group `mavis`
(re-login after S2). Whoever builds, the tree stays usable by **both** accounts: the scripts
put the uv-managed interpreters under `/opt/apollo-mavis-v2/.uv/python`
(`UV_PYTHON_INSTALL_DIR`; a home-private copy would break the venvs for everyone else, S1.3)
and pass `safe.directory=*` to git, because Ubuntu's git 2.34.1 (CVE-2022-24765 patches)
refuses to touch a checkout owned by another uid ("detected dubious ownership"). Script:
`bash scripts/deploy/install-stack.sh` — you need the script before the clone exists, so
fetch the workspace's copy first or run it from the developer's checkout with
`OPS_ROOT=/opt/apollo-mavis-v2`. `/opt/apollo-mavis-v2` must be **empty** when the clone
runs (the script refuses otherwise) — do not put the wheel there beforehand, see below.

```bash
sudo -iu mavis
curl -LsSf https://astral.sh/uv/install.sh | sh && export PATH="$HOME/.local/bin:$PATH"
git clone --recurse-submodules --branch main https://github.com/Apollo-Lab-Yale/apollo-mavis-v2-ws.git /opt/apollo-mavis-v2
bash /opt/apollo-mavis-v2/scripts/deploy/install-stack.sh
```

What it does (manual equivalent, in order):

```bash
cd /opt/apollo-mavis-v2
export UV_PYTHON_INSTALL_DIR=/opt/apollo-mavis-v2/.uv/python                        # shared interpreters (gitignored /.uv/) — needed by EVERY later uv command here
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'   # the clone may be owned by the other account
git submodule update --init --recursive           # pinned commits; detached HEAD is expected for ops
uv python install 3.10 3.12                       # hardware pins 3.10, runtime needs >= 3.12 -> /opt/apollo-mavis-v2/.uv/python/cpython-*
(cd apollo-mavis-v2-core     && uv sync --locked --no-dev)
(cd apollo-mavis-v2-sim      && uv sync --locked --no-dev)
(cd apollo-mavis-v2-hardware && uv sync --locked --no-dev)     # needs GitHub: xarm-python-sdk git pin d911319c
(cd apollo-mavis-v2-runtime  && uv sync --locked --no-dev --extra sim --extra hardware --extra audio)  # ~5 GB (torch cu130, lerobot, mujoco)
# pysurvive is OUT of uv.lock and every plain `uv sync` removes it again -> install last:
mkdir -p third_party/wheels && cp -n /var/lib/apollo-mavis-v2/wheels/pysurvive-*-cp312-*.whl third_party/wheels/   # from the S2 staging dir
(cd apollo-mavis-v2-runtime  && uv pip install --no-deps --force-reinstall ../third_party/wheels/pysurvive-1.1.204-cp312-cp312-linux_x86_64.whl)
apollo-mavis-v2-runtime/.venv/bin/python -c "import pysurvive; print(pysurvive.__file__)"
# UI: node 22 via nvm (per user), package-lock.json is authoritative (pnpm-lock.yaml is stale)
(cd apollo-mavis-v2-ui && npm ci --no-audit --no-fund && npm run gen:check && npm run build)   # -> dist/
```

The pysurvive wheel: it is gitignored (`/third_party/wheels/`) and exists only in the
developer's tree at
`/home/xiatao/projects/apollo-mavis-v2-ws/third_party/wheels/pysurvive-1.1.204-cp312-cp312-linux_x86_64.whl`
(2.86 MB, self-contained: bundles `libsurvive.so.0.3` + plugins, needs no
`LD_LIBRARY_PATH`/`SURVIVE_PLUGINS`). `mavis` cannot read anything under `/home/xiatao`
(0750, so `PYSURVIVE_WHEEL=~xiatao/…` does not work from a mavis shell), and
`/opt/apollo-mavis-v2` has to be empty for the clone — so the **developer** stages it in
the group-writable directory S2 created, any time after S2 (before or after the clone):

```bash
install -m 664 ~/projects/apollo-mavis-v2-ws/third_party/wheels/pysurvive-1.1.204-cp312-cp312-linux_x86_64.whl \
  /var/lib/apollo-mavis-v2/wheels/
```

`install-stack.sh` takes `PYSURVIVE_WHEEL=/path` if given, otherwise the newest
`pysurvive-*-cp312-*.whl` in `/opt/apollo-mavis-v2/third_party/wheels/` or
`/var/lib/apollo-mavis-v2/wheels/`, copies it next to the venvs and installs it. If the
wheel was staged only after a first pass (which then just warned `no pysurvive wheel`),
re-run the script: it is idempotent and skips everything already in place. Or rebuild it
(network + build deps; the libsurvive source used before lived in `/tmp` and is gone):
`BUILD_PYSURVIVE=1 bash scripts/deploy/install-stack.sh` runs
`scripts/tracker/02-build-pysurvive.sh` with `LIBSURVIVE_SRC=/opt/apollo-mavis-v2/third_party/src/libsurvive`
(pinned commit `f1e6eddb…`, full clone: `setup.py` runs `git describe`).

Script knobs: `UPDATE=1` (pull first, S9), `WITH_DEV=1` (keep pytest/ruff), `SKIP_UI=1`,
`PYSURVIVE_WHEEL=/path`, `REINSTALL_PYSURVIVE=1`, `UV_PYTHON_INSTALL_DIR=…` (default
`/opt/apollo-mavis-v2/.uv/python`, exported by `_common.sh`; keep it shared — the script
warns if it points into a home. For ad-hoc `uv sync`/`uv run` in the ops tree first
`source /opt/apollo-mavis-v2/scripts/deploy/_common.sh` or export it by hand, otherwise uv
does not find the interpreters and downloads private ones into `~`), `UV_CACHE_DIR=…` (a
fresh account re-downloads ~5 GB; point it at a shared, writable cache to avoid that).

---

## S4. Lab config `/var/lib/apollo-mavis-v2/mavis_v2_lab.yaml`

Script: `bash scripts/deploy/render-lab-config.sh`, as `mavis` or as a developer in group
`mavis` — **no sudo**: the file lives in the mavis-owned `/var/lib` tree, not in `/etc`,
precisely so the ops account can re-render it alone in S9 (`LAB_CONFIG=/etc/…/x.yaml` still
works and then falls back to sudo for the final `install`; `DRY_RUN=1` prints instead). It
loads the repo config `apollo-mavis-v2-runtime/configs/mavis_v2.yaml`, applies the overrides
below, **validates the result with the runtime's own `RuntimeConfig`** (so it needs the ops
runtime venv from S3), and installs it with mode 664. Comments are dropped by the YAML dump —
the repo file stays the documented reference and the rendered header lists every override.

Exact diff versus the repo config (values, comments stripped):

```diff
-ui_dist: null
+ui_dist: /opt/apollo-mavis-v2/apollo-mavis-v2-ui/dist
-profiles_dir: ~/apollo/profiles
-datasets_root: ~/apollo/datasets
-checkpoints_root: ~/apollo/checkpoints
-calibration_dir: ~/apollo/calibration
+profiles_dir: /var/lib/apollo-mavis-v2/profiles
+datasets_root: /var/lib/apollo-mavis-v2/datasets
+checkpoints_root: /var/lib/apollo-mavis-v2/checkpoints
+calibration_dir: /var/lib/apollo-mavis-v2/calibration
 control:
+  rail_in_ik: false                         # 2026-09-03 lab decision: rail excluded from IK, trackpad/arrows slide the arm
 tracker:
-  backend: fake
+  backend: libsurvive
-  libsurvive_args: ["--lighthousecount", "4", "--globalscenesolver", "0", "--disable-calibrate", "1"]
+  libsurvive_args: ["--lighthousecount", "3", "--globalscenesolver", "0", "--disable-calibrate", "1"]
-  libsurvive_config_path: ~/.config/libsurvive/config.json
+  libsurvive_config_path: /var/lib/apollo-mavis-v2/libsurvive/config.json
-  yaw_deg: 0.0
+  yaw_deg: 116.3                            # ESTIMATE (2026-09-03); redo the Yaw wizard, it persists to calibration_dir
```

Unchanged because the repo already has the lab values: `host: 127.0.0.1`, `port: 8765`,
arm IPs `grip` 192.168.1.201 / `view` 192.168.2.219 (gripper `xarm_g2`, `view`
`microphone: true`), the two wrist cameras (`grip_wrist` serial `349643062582`,
`view_wrist` serial `322143060792`; `kind: v4l2`, `fourcc: YUYV`, 640×480 @ 30 — see
"Cameras" below), `microphone.enabled: true` with `source_match: NT-USB Mini`,
`hardware_probe` on 502, the phase-09a `hardware_monitor` / `twin_overlay` blocks, the wrist
cameras' D435i colour `intrinsics` (2026-09-04), the phase-09b per-arm controller backstops
(`tcp_load_kg` / `tcp_load_cog_mm` / `collision_sensitivity`: `grip` 0.95 kg @ (0, 0, 60) mm,
`view` 0.55 kg @ (0, 0, 90) mm, sensitivity 3 — estimates accepted by the user on 2026-09-05 (the tools were not weighed); the
driver writes them at every session connect, the Hardware tab's **Apply safety settings** writes
them without a session), the phase-09c/09d `hardware_session` block (`armed: true` — the lab render is the ONLY config that
arms the real drivers, `HARDWARE_ARMED=false` renders a monitor-only config; `default_speed_scale:
0.1`, `rail_flip: false` — set `true` and re-render if the `*_align` overlay shows the twin's
carriage at the wrong end after the first **Home rail**; `home_rail_inflation_m: 0.025`,
`home_rail_step_m: 0.005` — also the margin / step of the phase-09d pre-positioning path check;
`bringup_timeout_s: 60`; there is NO `default_arms` any more — since phase-09d a hardware
session always includes both arms and an old key in a YAML is ignored),
`egl_device_id: 0`, `control.target_rate`, `tracker.controller_map`,
`filter`, `calibration` blocks (these newer keys are **missing** from the developer's
`/tmp/mavis_v2_live.yaml`; the render starts from the repo file so they are kept).

Values carried over from the developer's volatile `/tmp/mavis_v2_live.yaml` (the only
place they lived; `/tmp` is wiped at reboot): `tracker.backend: libsurvive`,
`--lighthousecount 3` (three powered stations after the bricked E9BFDF83),
`yaw_deg: 116.3`, `control.rail_in_ik: false`. They are the script defaults
(`TRACKER_BACKEND`, `LIGHTHOUSE_COUNT`, `TRACKER_YAW_DEG`, `RAIL_IN_IK`).

```bash
bash /opt/apollo-mavis-v2/scripts/deploy/render-lab-config.sh          # -> /var/lib/apollo-mavis-v2/mavis_v2_lab.yaml
# stop-gap if the two camera tiles turn out crossed (see below): swap the serials without touching the repo
CAMERA_SERIALS="grip_wrist=322143060792,view_wrist=349643062582" bash /opt/apollo-mavis-v2/scripts/deploy/render-lab-config.sh
```

Cameras (**verify on first deploy**): the runtime opens each RealSense's colour stream as a
plain v4l2 device that it finds by **USB serial** (core `CameraConfig.serial`, sysfs lookup;
no by-id path, no `pyrealsense2`, `fourcc: YUYV` because the RS colour node offers no MJPG),
so `/dev/video*` numbering and plug order do not matter. Two D435i are attached, serials
`322143060792` and `349643062582` (`lsusb -d 8086: -v 2>/dev/null | grep iSerial`, or
`v4l2-ctl --list-devices`). The repo maps `349643062582 → grip_wrist` (Manipulation Arm) and
`322143060792 → view_wrist` (Perception Arm) — **confirmed by the operator on 2026-09-04**
from the Hardware-tab tiles. If a camera is ever replaced or moved: cover one lens and watch
the Welcome page → Hardware tab tiles; if they are crossed, swap the two serials in
`configs/mavis_v2.yaml` (developer: commit + push, then S9 re-render) or use the
`CAMERA_SERIALS` stop-gap above until then (note that `rs-enumerate-devices` prints the
ASIC serials, not these USB serials — read them with `lsusb -v`). The script exits with an
error for a camera id that is not in the repo config, so a rename there cannot be ignored
silently. An unplugged camera shows a black tile with `live: false`
and has no other effect. **Cold boot**: a D435i's colour stream stays silent after a reboot
until librealsense has opened the device once; the driver runs `rs-enumerate-devices -s`
(librealsense2-utils, from Intel's apt repo — present on apollo-pc-1, keep it installed) once
per process before the first RealSense open, so no manual step is needed as long as that
tool exists (S11 has the manual fallback).

### libsurvive lighthouse calibration (per account!)

`tracker.libsurvive_config_path` is used only by the calibration wizard (copy / back up /
install). libsurvive itself ignores it and reads `$XDG_CONFIG_HOME/libsurvive/config.json`,
i.e. `~/.config/libsurvive/config.json` of the **service user** (the normal reader never
passes `--configfile`; the strings `XDG_CONFIG_HOME` and `%s/.config/libsurvive` are in
`libsurvive.so`). S6's `install-services.sh` therefore symlinks
`/home/mavis/.config/libsurvive -> /var/lib/apollo-mavis-v2/libsurvive` so both paths are
the same file, and seeds `config.json` if missing.

Seed it from the developer's **current** calibration, which is newer than the repo copy
(`~/.config/libsurvive/config.json` 2026-09-04 01:10 vs
`apollo-mavis-v2-runtime/configs/libsurvive/mavis_v2-lighthouses-20260903.json`
2026-09-03 18:26; they differ in the lighthouse0 pose). Developer, after S2 re-login:

```bash
install -m 664 -g mavis ~/.config/libsurvive/config.json /var/lib/apollo-mavis-v2/libsurvive/config.json
# and refresh the repo reference copy (docs/design/13-tracker-teleop.md §6.1): commit it in the runtime repo
cp ~/.config/libsurvive/config.json ~/projects/apollo-mavis-v2-ws/apollo-mavis-v2-runtime/configs/libsurvive/mavis_v2-lighthouses-$(date +%Y%m%d).json
```

The tracker **yaw** is a separate per-account artefact: `calibration_dir/tracker_calibration.json`
(written by the Yaw alignment wizard; overrides `yaw_deg` when `yaw_valid`). The developer
never persisted one (`GET /api/tracker/calibration` shows `yaw_calibrated_at: null`), so
the ops account starts from the 116.3° estimate — run the 7-click Yaw wizard on the
Debug page (`#/devices`, the Welcome page's top-right link; named "Devices" before phase-09d)
after S7.

---

## S5. udev rules, netsetup one-time install, sysctl (sudo)

1. udev + sysctl — done by S1's `install-system-deps.sh` (it runs
   `scripts/tracker/01-sudo-udev-and-deps.sh` only if
   `/etc/udev/rules.d/60-apollo-teleop-input.rules` is missing; the file is installed since
   2026-09-02; `FORCE_UDEV=1` re-runs it). Manual: `bash scripts/tracker/01-sudo-udev-and-deps.sh`.

2. netsetup install (polkit `.pkla` for group `netdev`, `netdev` membership, the NM
   dispatcher hook `/etc/NetworkManager/dispatcher.d/90-mavis-netsetup` with a venv python
   **baked in**, initial `match` seeding `/etc/apollo-mavis-v2/nic_map.json` and pinning both
   profiles). **Already run once, on 2026-09-04 01:30, from the developer's tree**: the hook
   exists with `PYTHON=/home/xiatao/projects/apollo-mavis-v2-ws/apollo-mavis-v2-hardware/.venv/bin/python`,
   `nic_map.json` holds both arms (`repair done rc=0`, both `[OK ]` in the log), both
   profiles are pinned to MAC + interface, and `netdev` contains `xiatao`. That hook depends
   on the developer's checkout: if that venv is moved or re-synced, boot-time NIC repair
   silently logs `python missing` and stops. Re-running install is therefore **required**
   to re-point the hook at the ops venv (it also adds `mavis` to `netdev`, which S2 did
   already). As your own sudo-capable account — `mavis` has no sudo — with the arms on:

   ```bash
   PY=/opt/apollo-mavis-v2/apollo-mavis-v2-hardware/.venv/bin/python
   sudo $PY -m apollo_mavis_v2_hardware.netsetup install --yes --python $PY --user mavis \
     --arm grip=192.168.1.201 --arm view=192.168.2.219
   # check WITH sudo: /etc/polkit-1/localauthority is root-only (0700), so a non-root check
   # cannot see the .pkla and reports it as "not verified" (a note, not a problem)
   sudo $PY -m apollo_mavis_v2_hardware.netsetup install --check --python $PY --user mavis \
     --arm grip=192.168.1.201 --arm view=192.168.2.219
   $PY -m apollo_mavis_v2_hardware.netsetup verify --arm grip=192.168.1.201 --arm view=192.168.2.219
   grep -q "^PYTHON=$PY$" /etc/NetworkManager/dispatcher.d/90-mavis-netsetup && echo hook-points-at-ops-venv
   tail -n 5 /var/log/mavis-netsetup.log       # last "repair done rc=0", both arms [OK ]
   nmcli -g 802-3-ethernet.mac-address,connection.interface-name con show mavis_viewpoint_arm      # 08\:BF\:B8\:89\:4F\:3A / enp36s0f0
   nmcli -g 802-3-ethernet.mac-address,connection.interface-name con show mavis_manipulation_arm   # 08\:BF\:B8\:89\:4F\:3B / enp36s0f1
   ```

   `--python` bakes the interpreter into the hook (default would be the running interpreter —
   the same here since we run the ops venv, but keep it explicit); `--user mavis` puts
   **mavis**, not `$SUDO_USER`, into `netdev`; the `--arm` list must be given in the same
   order each time, or `--check` reports the hook as "differs from the rendered script".
   Details: `apollo-mavis-v2-hardware/docs/netsetup-install.md`. Log:
   `/var/log/mavis-netsetup.log`. The MAC/interface pinning of both profiles is done (the
   earlier worry that `mavis_viewpoint_arm` could attach to the unused USB RTL8153
   `enx00e04c683d97` at boot is closed); the two `nmcli` lines above are the verification.

---

## S6. systemd user services for `mavis`

Templates: `scripts/deploy/systemd/mavis-runtime.service` (ops) and
`scripts/deploy/systemd/mavis-ui-dev.service` (developers only). Script, **as mavis**:

```bash
sudo -iu mavis
bash /opt/apollo-mavis-v2/scripts/deploy/install-services.sh          # symlink + seed libsurvive dir, install + enable unit
START=1 bash /opt/apollo-mavis-v2/scripts/deploy/install-services.sh  # ... and (re)start it — only when no other runtime owns the devices (S8)
```

Manual equivalent:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
mkdir -p ~/.config ~/.config/systemd/user
ln -s /var/lib/apollo-mavis-v2/libsurvive ~/.config/libsurvive          # see S4 "per account"
install -m 644 /opt/apollo-mavis-v2/scripts/deploy/systemd/mavis-runtime.service ~/.config/systemd/user/
systemd-analyze --user verify ~/.config/systemd/user/mavis-runtime.service
systemctl --user daemon-reload
systemctl --user enable mavis-runtime.service
systemctl --user start  mavis-runtime.service
```

The unit (defaults; `install-services.sh` rewrites the two paths if `OPS_ROOT`/`LAB_CONFIG` differ):

```ini
[Unit]
Description=MAVIS v2 runtime (API + built UI on :8765, Vive tracker, microphone, arm probes)
After=network-online.target pulseaudio.socket
Wants=pulseaudio.socket
StartLimitIntervalSec=300
StartLimitBurst=10
[Service]
Type=simple
WorkingDirectory=/opt/apollo-mavis-v2/apollo-mavis-v2-runtime
Environment=MUJOCO_GL=egl
Environment=APOLLO_CONFIG=/var/lib/apollo-mavis-v2/mavis_v2_lab.yaml
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/apollo-mavis-v2/apollo-mavis-v2-runtime/.venv/bin/python -m apollo_mavis_v2_runtime --config /var/lib/apollo-mavis-v2/mavis_v2_lab.yaml
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=20
[Install]
WantedBy=default.target
```

Notes:

- The venv interpreter is called directly, **not** `uv run`: that needs uv on PATH and
  network at boot and may re-lock/resync (only a plain `uv sync` — exact by default —
  drops pysurvive; `uv run` syncs inexactly and keeps it).
- `network-online.target` does not exist in a user manager (system target); the ordering
  is inert there. Harmless: the probe re-tries the arms every 2 s and the arms need 1-2 min
  after power-on anyway. PulseAudio is socket-activated per user (`pulseaudio.socket` is
  enabled for every account via `/etc/systemd/user/sockets.target.wants`), so `After=pulseaudio.socket`
  is what matters for the microphone.
- SIGTERM → uvicorn → lifespan → `Runtime.stop()` releases the dongle (`simple_close`),
  the mic stream and the trainer child; `TimeoutStopSec=20` gives it room.
- Why the runtime serves the UI: with `ui_dist` set the SPA is mounted at `/` (mounted last,
  after `/api`, `/ws/*`, `/video/*`; hash routing so no deep-link 404) — same origin, no
  CORS, no node/Vite process, one port. Vite (`mavis-ui-dev.service`, `scripts/deploy/ui-dev.sh`)
  is a **developer** hot-reload tool that proxies `/api /ws /video` to a runtime
  (`APOLLO_RUNTIME_URL`); it has no place in the ops account.

Commands (as mavis; `sudo -iu mavis` does not export the bus, hence the two exports):

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
systemctl --user status  mavis-runtime
systemctl --user restart mavis-runtime
systemctl --user stop    mavis-runtime
journalctl --user -u mavis-runtime -f          # stderr of the runtime (INFO)
journalctl --user -u mavis-runtime -b --no-pager | tail -100
```

From the developer account (no mavis shell):

```bash
U=$(id -u mavis)
sudo -u mavis env XDG_RUNTIME_DIR=/run/user/$U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus systemctl --user status mavis-runtime
sudo systemctl --user -M mavis@ status mavis-runtime       # systemd >= 248 shortcut — verify on first deploy
sudo journalctl _SYSTEMD_USER_UNIT=mavis-runtime.service -f
systemctl status user@$U.service                            # the lingering user manager itself
```

---

## S7. Verification checklist (first boot and after every upgrade)

Read-only script: `bash /opt/apollo-mavis-v2/scripts/deploy/healthcheck.sh`
(`RUNTIME_PORT=8766` for a developer instance). It checks `/api/health`, both arms
`reachable: open` via `/api/workcell?kind=hardware`, `/api/microphones` `live: true`,
`/api/tracker/calibration`, one `/ws/telemetry` frame for `tracker.status`
(`tracking`/`searching`), and that `GET /` returns the SPA. Manual:

```bash
id mavis                                          # render plugdev input audio netdev present
loginctl show-user mavis -p Linger                # Linger=yes
lsusb -d 28de:2101; lsusb -d 19f7:0015             # dongle, RØDE present
nmcli -t -f NAME,DEVICE con show --active | grep mavis_    # mavis_manipulation_arm:enp36s0f1, mavis_viewpoint_arm:enp36s0f0
timeout 2 bash -c 'echo > /dev/tcp/192.168.1.201/502' && echo grip-open
timeout 2 bash -c 'echo > /dev/tcp/192.168.2.219/502' && echo view-open
curl -s 127.0.0.1:8765/api/health                                  # {"status":"ok",...}
curl -s '127.0.0.1:8765/api/workcell?kind=hardware' | python3 -m json.tool | grep -E '"arm_id"|"reachable"|hardware_ready'
curl -s 127.0.0.1:8765/api/microphones | python3 -m json.tool | grep -E '"status"|"live"'
curl -s 127.0.0.1:8765/api/cameras | python3 -c 'import json,sys; [print(c["camera_id"], c["live"]) for c in json.load(sys.stdin) if c["kind"] != "sim"]'   # grip_wrist True / grip_wrist_align True / view_wrist True / view_wrist_align True
curl -s 127.0.0.1:8765/api/tracker/calibration | python3 -m json.tool | grep -E 'yaw_valid|yaw_calibrated_at|applied_yaw'
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' 127.0.0.1:8765/     # 200 text/html (UI)
```

The two `*_align` rows (phase-09a, 2026-09-04) are the digital-twin alignment overlays
(`kind: twin`, 640×480 @ 12 fps): each is `live: true` only while its real wrist camera is live
AND the runtime's read-only hardware monitor has samples from that arm's control box and no
hardware session owns the boxes — a box that is off leaves its overlay `false` while the real
camera stays `true`. On the Hardware tab expect five tiles (two cameras, two pale-yellow
overlays with the note `rail not homed · twin assumes 0.65 m` until the tracks are homed, the
microphone) and, today, a red `C19` chip on the Perception Arm card; `/ws/telemetry`
`hardware_monitor.arms[].status` should read `running` for both arms.

Phase-09b (2026-09-04) — controller maintenance without a session. These are **configuration
writes only, no motion** (the arms stay `state 4` / `mode 0`, no joint moves). While a hardware
session owns the boxes the card buttons read `Use the Cockpit`: `apply_backstops` is then refused
with 409, and `clear_errors` is NOT refused but routed to the session driver's user-initiated
recovery (= `recover`: clears, `motion_enable`s, re-enters servo mode, re-seeds — the arm does
not move, but its brakes release; use the Cockpit's **Clear errors & resume** instead of curl).
Each Hardware-tab arm card shows the controller's read-back `sensitivity N · payload X kg`
(amber + `differs from config` while it does not match `mavis_v2_lab.yaml`); a red `C<code>`
chip enables **Clear errors**, a mismatch enables **Apply safety settings**. The same over REST:

```bash
M=127.0.0.1:8765/api/hardware/arms
curl -s -X POST -H 'content-type: application/json' -d '{"op":"clear_errors"}' $M/view/maintenance | python3 -m json.tool | grep -E '"ok"|"detail"|"error_code"'   # ok true, after.error_code 0 (C19 returns until Studio -> Settings -> Externals -> End Effector -> None)
for a in grip view; do curl -s -X POST -H 'content-type: application/json' -d '{"op":"apply_backstops"}' $M/$a/maintenance | python3 -m json.tool | grep -E '"ok"|"detail"|collision_sensitivity|tcp_load_kg|backstops_match'; done   # ok true; after: collision_sensitivity 3, tcp_load_kg 0.95 / 0.55, backstops_match true
```

Afterwards `hardware_monitor.arms[]` still reads `state 4` / `mode 0`, the joints did not move,
the card's read-back line is neutral and both toasts appeared (`<Arm> · errors cleared`,
`<Arm> · safety settings applied (sensitivity 3, payload 0.95 kg)`). The settings are volatile
(lost at a controller reboot); the driver re-applies them at every session connect.

Phase-09c / 09d (2026-09-05) — hardware sessions; **not yet exercised live** (fakes only). Each
Hardware-tab arm card shows the track read-back: the amber pill **`rail not homed`** plus a
**Home rail** button while a track is present but unhomed (both lab tracks after every
power-on: registers `on_zero 0 / is_enabled 0`), `rail 0.000 m` once homed and enabled.
**Home rail is the ONE maintenance action that moves hardware** — the carriage drives to the
operator's LEFT (+X) end at the track's own homing speed (no SDK setter, duration unmeasured;
50 mm/s is the positioning cap written after homing) — so it never posts directly: the sheet first shows the
digital-twin sweep verdict (`{"op":"home_rail","dry_run":true}` — the full 0–0.65 m travel at
the arm's CURRENT posture, the other arm at its last monitor sample, 25 mm margin, zero
writes) and offers the destructive confirm (`Sweep clear — safe to home`, **Home rail — move
carriage**) when the sweep is clear — the joints stay untouched. A blocked sweep no longer
ends there (phase-09d): the dry run also PLANS a pre-positioning motion — the sheet reads
`Current posture blocks the sweep — pre-positioning planned` with `The arm will first move
along a planned path (N waypoints, ~X s at 10 %) to a folded posture that clears the whole
rail travel, then the rail homes, then the arm holds that posture.`, the target posture in
degrees and `path checked at 131 rail positions` (every waypoint of the twin-planned path is
collision-free at every rail position, because the carriage is unknown); confirming
(**Home rail — move arm, then carriage**) starts a `RailHomingJob` (REST 202) whose seven
phases (queued → sweeping → planning → connecting → positioning → homing → verifying) show
live in the sheet: the job connects that arm alone at 10 %, moves it along the path under the
gate, homes the track with the joints held, verifies the registers and hands the arm back
braked **in that folded posture — nothing moves it back**. Only when no rail-safe path exists
is homing refused (`Sweep blocked — no safe pre-positioning path`: fold the arm toward the
factory-zero posture in xArm Studio, or move the other arm, and retry). While the carriage
moves (≤ 45 s) the arm reads `stale` with `maintenance_busy: true` (a job: `paused` +
`maintenance_busy` for its whole life) and `POST /api/session` is 409. A hardware session is
refused while either arm's track is unhomed (the carriage position is unknown, so the gate
twin cannot be posed; both arms are always in a hardware session since phase-09d). **First
live run — follow the 真机验收步骤 in `docs/prompts/phase-09c-hardware-session.md` as amended
by its phase-09d header note** (user present, physical e-stop in hand, workspace clear; the
driver's connect write sequence has never run on a real box): (1) both arms `running`, err 0
(clear the Perception Arm's `C19` first — a latched error 409s the session and would LATCH its
driver; the permanent fix is in Studio, S11), overlays normal; (2) Manipulation Arm → **Home
rail** → dry-run (clear, or `pre-positioning planned`: read the plan, expect the ARM to move
first) → confirm → card reads `rail 0.000 m` → look at the `*_align` overlay **immediately**:
twin rail / base must coincide with the real ones; if the carriage sits at the wrong end set
`hardware_session.rail_flip: true` (re-render S4, restart) and look again; (3) Perception Arm
the same (judge its base from the Manipulation Arm's overlay — its own camera looks outward);
(4) **Speed 10 %** → Teleop (both arms join; there is no per-arm switch) → bring-up rows until
`running`, Cockpit shows `speed 10%`, both arms stay still for 10 s without the clutch; (5)
clutch + a slow 5 cm hand motion → the Manipulation Arm (the active arm) follows in the same
direction at ~1/10 speed, the Perception Arm holds, releasing the clutch stops it; (6) end the
session → both arms are handed back stopped with the brakes engaged (`state 4`,
`motion_enable(False)`), the monitor resumes, the cards are normal. Only then 30 %, switching
the active arm, rail following. The same over REST:

```bash
M=127.0.0.1:8765/api/hardware/arms
curl -s -X POST -H 'content-type: application/json' -d '{"op":"home_rail","dry_run":true}' $M/grip/maintenance | python3 -m json.tool | grep -E '"ok"|"detail"|"clear"|"needed"|"waypoints"|first_blocked|min_clearance'   # ok true + rail_sweep.clear true = safe to home with the joints untouched; pre_position.needed true + clear true = a pre-positioning motion is planned (phase-09d; waypoints, duration_s); nothing written
curl -s -m 60 -X POST -H 'content-type: application/json' -d '{"op":"home_rail"}' $M/grip/maintenance | python3 -m json.tool | grep -E '"ok"|"status"|"job_id"|"detail"|rail_homed|rail_enabled|rail_pos_m'   # MOVES THE CARRIAGE (<= 45 s): ok true, status done, after.rail_homed / rail_enabled true, rail_pos_m 0.0 -- OR HTTP 202 status accepted + job_id (phase-09d: the posture blocks the sweep; the ARM MOVES FIRST along the planned path at 10 %, then the carriage -- keep clear of the whole cell)
curl -s $M/grip/maintenance/last | python3 -m json.tool | grep -E '"ok"|"status"|"job_id"|"detail"'   # phase-09d: the job's FINAL result (status done, same job_id; ok false on failure); 404 until any home_rail ran. Progress meanwhile: /ws/telemetry hardware_monitor.arms[].maintenance.phase
curl -s 127.0.0.1:8765/api/session      # 404 without a session; "state":"bringup" while POST /api/session runs, then "running" with "kind":"hardware", both arm ids in "arms" (phase-09d), "speed_scale":0.1
```

From a mavis shell additionally (**verify on first deploy**): `pactl list short sources | grep NT-USB`
must list `alsa_input.usb-R__DE_Microphones_R__DE_NT-USB_Mini_750BFEE8-00.mono-fallback`
(needs `XDG_RUNTIME_DIR` exported; proves mavis's PulseAudio sees the card via group `audio`).

Browser: the runtime binds `127.0.0.1` (no authentication anywhere) — open
`http://127.0.0.1:8765/` on the machine, or `ssh -L 8765:127.0.0.1:8765 apollo-pc-1` /
tailscale from elsewhere. Do **not** switch `host` to `0.0.0.0` without a reverse proxy
with auth: it would expose arm control to the LAN. Then: Welcome page shows the mic
waveform and both arms reachable; Debug page (`#/devices`, top-right link) → tracker
`tracking` when the controller is on → run **Yaw alignment** (7 clicks) so
`/var/lib/apollo-mavis-v2/calibration/tracker_calibration.json` exists; start a **sim** session
on `mavis_v2` and teleop with the controller. A **hardware** session only after the
phase-09c/09d first-run procedure above, with the user present.

---

## S8. Daily operation and the dev-vs-ops split

### S8.1 Start / stop (as mavis, exports as in S6)

```bash
systemctl --user start|stop|restart|status mavis-runtime
journalctl --user -u mavis-runtime -f
```

It starts by itself at boot (linger + `WantedBy=default.target`) and restarts on failure.
After power-cycling the arms, `reachable` goes `unreachable → refused → open` over ~1-2 min.

### S8.2 Who owns what — exactly one owner per device

| Resource | Exclusive? | Consequence for a second instance |
|---|---|---|
| Watchman dongle 28de:2101 | yes (libusb claim) | second libsurvive context → `LIBUSB_ERROR_BUSY`, tracker `error` (retries forever). Only one `tracker.backend: libsurvive` per machine. |
| RØDE NT-USB Mini | one ALSA card; held by whichever **PulseAudio daemon** has a running stream | the loser's capture gets EBUSY/`absent`. Dev and ops each have their own PA daemon. |
| xArm control boxes (TCP 502) | one SDK controller at a time | probes are harmless; the read-only monitor and hardware sessions (phase-09c) must never run from two instances — inside one instance the monitor is paused while a session owns a box |
| Ports 8765 / 5757 | per instance | second instance needs `--port` / `dagger.trainer.port` |
| NetworkManager profiles | system-wide | only the root dispatcher / one `netsetup` mutates them |
| GPUs, `/dev/video*`, sim | shareable | — |

### S8.3 Developer running a second instance while the ops service runs

Use fake/none backends, another port, your own data dirs. Render such a config from your
own checkout (no sudo; `DATA_ROOT` becomes your `~/apollo`, ports move):

```bash
cd ~/projects/apollo-mavis-v2-ws
OPS_ROOT=$PWD LAB_CONFIG=$HOME/apollo/dev.yaml DATA_ROOT=$HOME/apollo \
  RUNTIME_PORT=8766 TRAINER_PORT=5758 TRACKER_BACKEND=fake MIC_ENABLED=false \
  LIBSURVIVE_CONFIG=$HOME/.config/libsurvive/config.json UI_DIST=$PWD/apollo-mavis-v2-ui/dist \
  bash scripts/deploy/render-lab-config.sh
(cd apollo-mavis-v2-runtime && uv run python -m apollo_mavis_v2_runtime --config ~/apollo/dev.yaml)
(cd apollo-mavis-v2-ui && APOLLO_RUNTIME_URL=http://localhost:8766 npm run dev -- --port 5173)
```

`tracker.backend: fake` (scripted circle), `microphone.enabled: false`, sim sessions only.
If your dev PulseAudio should also stop holding the RØDE (it does while any stream runs):
`pactl set-card-profile alsa_card.usb-R__DE_Microphones_R__DE_NT-USB_Mini_750BFEE8-00 off`
(**verify on first deploy**; `… input:mono-fallback` restores it).

### S8.4 Developer needs the real dongle / mic / arms

Stop the ops service first, start it again when done:

```bash
U=$(id -u mavis); OPS="sudo -u mavis env XDG_RUNTIME_DIR=/run/user/$U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus systemctl --user"
$OPS stop mavis-runtime          # releases dongle + mic stream + arms
# ... develop with tracker.backend libsurvive / mic auto on :8765 ...
$OPS start mavis-runtime
```

Heavy option: `sudo systemctl stop user@$U.service` stops the whole mavis manager (also its
PulseAudio). The root NM dispatcher keeps matching the arm NICs regardless of which instance runs.

---

## S9. Upgrade

As `mavis` — nothing in this section needs sudo — or as a developer in group `mavis`. The
clone may be owned by the *other* account: the scripts pass `safe.directory=*` to git for
their own calls (for ad-hoc git commands see the "dubious ownership" row in S11). With the
service stopped:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus   # if you are mavis
systemctl --user stop mavis-runtime
UPDATE=1 bash /opt/apollo-mavis-v2/scripts/deploy/install-stack.sh     # git pull --ff-only, submodule update, uv sync --locked ×4, pysurvive check, npm ci + gen:check + build
bash /opt/apollo-mavis-v2/scripts/deploy/render-lab-config.sh          # re-render: new repo keys land, overrides stay; shows a diff; no sudo
systemctl --user start mavis-runtime && bash /opt/apollo-mavis-v2/scripts/deploy/healthcheck.sh
```

Manual equivalent of the update part:

```bash
source /opt/apollo-mavis-v2/scripts/deploy/_common.sh   # exports UV_PYTHON_INSTALL_DIR + git safe.directory; without it uv fetches private interpreters into ~
cd /opt/apollo-mavis-v2 && git pull --ff-only && git submodule sync --recursive && git submodule update --init --recursive
for r in core sim hardware; do (cd apollo-mavis-v2-$r && uv sync --locked --no-dev); done
(cd apollo-mavis-v2-runtime && uv sync --locked --no-dev --extra sim --extra hardware --extra audio \
  && uv pip install --no-deps --force-reinstall ../third_party/wheels/pysurvive-*-cp312-*.whl \
  && .venv/bin/python -c "import pysurvive")
(cd apollo-mavis-v2-ui && npm ci --no-audit --no-fund && npm run gen:check && npm run build)
```

Schema regeneration check (protocol drift between core and the UI's generated types —
`gen:check` above fails on drift; the core side of the same guard):

```bash
(cd /opt/apollo-mavis-v2/apollo-mavis-v2-core && .venv/bin/python -m apollo_mavis_v2_core.protocol.export_schemas --check --out schemas/)
```

Rules: the ops clone tracks the workspace's pinned submodule commits (detached HEADs are
normal); upgrades happen by the developer pushing **all five** sub-repos in dependency order
and bumping the pointers in the ws (intro item 1), then `UPDATE=1` here — afterwards
`git -C /opt/apollo-mavis-v2 submodule status` must show no line starting with `+` or `-`.
Keep `--locked`: if it fails, the developer forgot to commit `uv.lock`. A pysurvive/Python bump needs a new wheel (S3). If `configs/mavis_v2.yaml`
gained keys, re-rendering picks them up; if the wheel or dist path moved, re-render too.

---

## S10. Backup and restore

What matters (everything else is rebuildable from git + PyPI):

| What | Path |
|---|---|
| Lighthouse calibration (+ wizard backups) | `/var/lib/apollo-mavis-v2/libsurvive/config.json`, `config.json.bak-*` |
| Tracker yaw + base-station install record | `/var/lib/apollo-mavis-v2/calibration/tracker_calibration.json`, `base_station-*.json` |
| Teleop profiles | `/var/lib/apollo-mavis-v2/profiles/` |
| Datasets (LeRobot v3), checkpoints | `/var/lib/apollo-mavis-v2/datasets/`, `/var/lib/apollo-mavis-v2/checkpoints/` (large) |
| Lab config, netsetup state | `/var/lib/apollo-mavis-v2/mavis_v2_lab.yaml` (re-renderable, S4), `/etc/apollo-mavis-v2/nic_map.json` |
| Developer-side originals | `/home/xiatao/.config/libsurvive/`, `/home/xiatao/apollo/{calib,calibration,profiles}` |

```bash
# calibration + config (small): tar to /home/shared (world-writable, exists) or removable media
sudo tar czf /home/shared/mavis-calib-$(date +%Y%m%d).tgz \
  /var/lib/apollo-mavis-v2/libsurvive /var/lib/apollo-mavis-v2/calibration /var/lib/apollo-mavis-v2/profiles \
  /var/lib/apollo-mavis-v2/mavis_v2_lab.yaml /etc/apollo-mavis-v2
# datasets/checkpoints (large): rsync
rsync -a --info=progress2 /var/lib/apollo-mavis-v2/datasets/ /media/backup/mavis-datasets/
# restore (service stopped)
sudo tar xzf /home/shared/mavis-calib-YYYYMMDD.tgz -C /
sudo chown -R mavis:mavis /var/lib/apollo-mavis-v2/{libsurvive,calibration,profiles}
```

After every accepted base-station install (wizard → Install) copy the new
`config.json` into the runtime repo as `configs/libsurvive/mavis_v2-lighthouses-<date>.json`
and commit — that copy is how a fresh machine is restored (13-tracker §6.1). Restoring
a lighthouse config invalidates the yaw: redo the Yaw wizard.

---

## S11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| tracker `error` with `LIBUSB_ERROR_BUSY` in `journalctl --user -u mavis-runtime` | another libsurvive holds the dongle: the developer's runtime, `survive-cli`, `scripts/tracker/03-…`. `sudo fuser -v /dev/bus/usb/$(lsusb -d 28de:2101 \| awk '{printf "%s/%s", $2, substr($4,1,3)}')` shows the pid; stop it (S8.4). A killed process can keep the interface claimed → replug the dongle. |
| tracker `no_backend` | pysurvive missing — a plain `uv sync` removed it. `(cd /opt/apollo-mavis-v2/apollo-mavis-v2-runtime && uv pip install --no-deps --force-reinstall ../third_party/wheels/pysurvive-*-cp312-*.whl)`; restart. |
| tracker `error`: permission / cannot open device | mavis lacks `plugdev` or the udev rule is missing: `id mavis`, `ls -la /dev/bus/usb/…` should be `root plugdev 0660`; `sudo udevadm trigger --subsystem-match=usb`; restart `user@<uid>` after group changes. |
| tracker `searching` forever | controller off/asleep, or stations off; `--lighthousecount 3` must match the powered stations. Yaw/base-station: Debug page (`#/devices`) wizard. |
| microphone `absent` / `error: pactl…` | mavis's PulseAudio does not see the card: (a) `XDG_RUNTIME_DIR` unset → service must run under the user manager (it does) — from shells export it; (b) mavis not in `audio` (`/dev/snd/* root:audio 0660`); (c) the developer's PA has a stream open on the RØDE (S8.3, set its card profile off); (d) `pactl info` fails → `systemctl --user status pulseaudio.socket pulseaudio.service` as mavis (**verify on first deploy**: module-udev-detect for a seatless user). Never open `hw:CARD=Mini` directly: EBUSY and it stalls every Pulse recorder. |
| both wrist-cam tiles black after a reboot (`/api/cameras` `live: false`, log: `select() timeout` / `cannot open`) | cold-boot quirk of the D435i colour UVC stream: it delivers nothing until librealsense has opened the device once. The driver runs `rs-enumerate-devices -s` automatically before the first RealSense open — check `command -v rs-enumerate-devices` (librealsense2-utils, Intel apt repo) and the runtime log for `RealSense wake`; manual fallback: run `rs-enumerate-devices -s`, then restart the service. `rs-enumerate-devices` prints ASIC serials (243522071002 / 327122074467), not the USB serials in the config. |
| sim previews black / `stream died` in the log, EGL errors | render node permission: mavis needs `render` (`/dev/dri/renderD* root:render 0660`); `/dev/nvidia*` are 0666. Check `MUJOCO_GL=egl` in `systemctl --user show mavis-runtime -p Environment`; `egl_device_id: 0` = PCI 41:00.0. An EGL failure kills only the preview streams, not the runtime. |
| `POST /api/session` kind=hardware → 409 `<Arm>: rail not homed - home it from the Hardware tab (Home rail) before starting a session` | expected after every power-on (phase-09c): both tracks boot unhomed and a session needs the carriage position for the gate twin — and since phase-09d BOTH arms are always in a session, so both tracks must be homed. Card → **Home rail** → dry-run verdict → confirm (the carriage MOVES to the operator's left end, ≤ 45 s; or, phase-09d, the sheet says `pre-positioning planned` and the ARM MOVES FIRST along the planned path at 10 %, then the carriage — 202 job, watch the phases in the sheet) → `rail 0.000 m`; then check the `*_align` overlay before the session. Other 409s from the same matrix: `hardware sessions support teleop only` (use the Sim tab for collect / DAgger / inference), `hardware sessions include every configured arm (Manipulation Arm, Perception Arm) - missing [...]` (a client posted a subset — the UI never does since phase-09d; both arms always join, so the Perception Arm must be homed / error-free too), `no monitor sample` (box off / monitor paused), `controller error N is latched - clear errors first` (**Clear errors**; the Perception Arm's `C19` blocks every session until fixed in Studio), `rail homing in progress` (wait for the carriage / the job), `control box … is unreachable`, `hardware bring-up failed: <Arm>: <stage> - …` (the drivers were torn down again, the monitor resumed — read the stage), `profile motion not collision-free: <failure> (<pair>) - …` (phase-09d: `start_from: profile:<id>` was planned on the gate twin inside bring-up and no collision-free path exists from the measured posture — use `keep_current` or another profile; the session was torn down). |
| **Home rail** refused / failed (sheet shows a red verdict or an error, `ok: false`, 409) | `Sweep blocked — no safe pre-positioning path` (`status: refused`, phase-09d) = the twin sweep found a pair within 25 mm somewhere along the 0–0.65 m travel at the arm's current posture (`rail_sweep.first_blocked_m` / `first_blocked_pair`) AND no candidate posture (scene keyframe, `<arm>_home`) is reachable by a rail-position-agnostic path: fold the arm toward the factory-zero posture in xArm Studio (joints 2–7 near 0; or move the other arm) and re-open Home rail — nothing was written. (`Current posture blocks the sweep — pre-positioning planned` is NOT a refusal: confirm and the arm moves first; an older runtime shows `Sweep blocked — homing refused` instead.) 409 `clear errors first` → **Clear errors** first; 409 `end the session first` → end the hardware session; 409 `needs the digital twin` → the lab config lacks `digital_twin_scene` or the runtime venv lacks the sim extra. `ok: false … the arm moved since the sweep was checked` → keep the arm still between the dry run and the confirm. `ok: false … on_zero still 0` after the 30 s SDK wait → the track never reached its zero switch: check the track cable / `hardware_monitor.arms[].rail_*` registers, **Clear errors**, retry. UI `no answer after 60 s` → read the card's rail pill; the runtime may still have finished. While homing the arm reads `stale` + `maintenance_busy` and `POST /api/session` is 409. |
| after a hardware session an arm is not back at `state 4` / brakes not engaged | `XArmDriver.disconnect()` ends with `set_mode(0)` → `set_state(4)` → `motion_enable(False)` (phase-09c D6) and the track keeps its homed flag. Check `hardware_monitor.arms[].state` once the monitor resumes; if the box still reports enabled, the disconnect writes failed (runtime log) — disable it from xArm Studio, never leave the cell enabled unattended. |
| rail-homing job `failed` (phase-09d; the sheet marks a phase red, toast `<Arm> · rail homing job failed during <phase>: …`, `GET /api/hardware/arms/<id>/maintenance/last` → `ok: false`) | the runtime tore the job down (arm stopped + braked where it was, monitor resumed, `maintenance_busy` cleared — nothing half-connected). Read the detail: `arm moved since the sweep` (> 0.02 rad between dry run and confirm — keep it still), `session slipped in` / `rail homing in progress` (retry), a driver fault or the gate holding during `positioning` (30 s or 3× the estimate; the posture must land within 0.05 rad — an obstacle / the other arm is in the way: check the overlay, fold in Studio), `on_zero still 0` after `home_rail()` (track cable / registers, **Clear errors**, retry), register verification (`rail_homed` / `rail_enabled` not both true). The arm stays wherever the job stopped it — look before re-opening Home rail; the next dry run plans from that posture. |
| red `C<code>` chip on a Hardware-tab arm card (Perception Arm `C19` today; `hardware_monitor.arms[].error_code != 0`) | a controller error is latched in the box. Click **Clear errors** on the card (phase-09b; `POST /api/hardware/arms/<id>/maintenance {"op":"clear_errors"}` = `clean_error` + `clean_warn` on the read-only monitor — no enable, no motion, no confirm dialog). Toast `<Arm> · errors cleared`; the chip clears with the next monitor sample. `C19` (End Effector Communication Error: the box expects an end effector on the tool RS-485 bus, the Perception Arm has none) returns until xArm Studio → Settings → Externals → End Effector → **None** (no SDK write for it). Inside a hardware session the card buttons are disabled (`Use the Cockpit`): use the Cockpit fault banner's **Clear errors & resume**, then re-grip the clutch. 409 `… needs the read-only monitor connected` = box off / monitor paused; `ok: false … re-latched right after clearing` = a persisting hardware fault (cable, e-stop). |
| amber `sensitivity 1 · payload 0.00 kg` with `differs from config` on an arm card (`hardware_monitor.arms[].backstops_match: false`) | the controller lost its volatile safety settings (reboot) or never had them written. Click **Apply safety settings** (`{"op":"apply_backstops"}`: payload, gravity, collision sensitivity, self-collision model, rebound off — configuration writes only, no motion) → toast `<Arm> · safety settings applied (sensitivity 3, payload 0.95 kg)` and `backstops_match: true`. The driver re-applies the same values at every session connect; the values live in the lab config per arm (`tcp_load_kg` / `tcp_load_cog_mm` / `collision_sensitivity`; PROVISIONAL payloads until the tools are weighed — change them in `configs/mavis_v2.yaml`, then S9 re-render). |
| arms `unreachable` | boxes off (1-2 min after power-on), or the NIC lost its profile: `nmcli -t -f NAME,DEVICE con show --active \| grep mavis_`, `tail /var/log/mavis-netsetup.log` (dispatcher repairs on link events), `$PY -m apollo_mavis_v2_hardware.netsetup verify --arm grip=192.168.1.201 --arm view=192.168.2.219`, `… match --repair` (needs `netdev` + the `.pkla`, S5). Also `ip route get 192.168.2.219` must leave via `enp36s0f0`. |
| landing-page warning "polkit grant missing / user not in netdev / dispatcher hook missing" | S5 not run for this venv/user; `sudo $PY -m apollo_mavis_v2_hardware.netsetup install --check --python $PY --user mavis --arm … --arm …` (same `--arm` order as the install). Without sudo the `.pkla` cannot be read (`/etc/polkit-1/localauthority` is root-only) and is reported as a `note:` only. |
| `fatal: detected dubious ownership in repository at '/opt/apollo-mavis-v2…'` | git 2.34.1 refuses a checkout owned by another uid. The deploy scripts export `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'` for their own git calls (`_common.sh`; verified to work with this git build). For ad-hoc git in the ops tree either `source /opt/apollo-mavis-v2/scripts/deploy/_common.sh` or, once per account, `for d in /opt/apollo-mavis-v2 /opt/apollo-mavis-v2/apollo-mavis-v2-{core,sim,hardware,runtime,ui}; do git config --global --add safe.directory $d; done`. |
| `EACCES` / `Permission denied` on `…/.venv/bin/python` when run by another account than the builder | the interpreters were installed into the builder's 0750 home (`readlink -f /opt/apollo-mavis-v2/apollo-mavis-v2-runtime/.venv/bin/python` shows `/home/…`). Rebuild with the default `UV_PYTHON_INSTALL_DIR=/opt/apollo-mavis-v2/.uv/python`: `rm -rf /opt/apollo-mavis-v2/*/.venv && bash /opt/apollo-mavis-v2/scripts/deploy/install-stack.sh`. |
| `systemctl --user` → "Failed to connect to bus" | export `XDG_RUNTIME_DIR=/run/user/$(id -u)` and `DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus`; if `/run/user/<uid>` is missing, linger is off (`loginctl show-user mavis`) or the manager is down (`sudo systemctl start user@<uid>`). |
| `Address already in use` on 8765 | the developer's runtime (or a stale one) has the port: `ss -ltnp \| grep 8765`; use S8.3 ports for dev instances. |
| Vite: `ENOSPC: System limit for number of file watchers` | `sysctl fs.inotify.max_user_watches` should print 524288 (`/etc/sysctl.d/60-inotify.conf`, S1); `sudo sysctl --system`. |
| `uv sync --locked` fails | `uv.lock` drifted (developer must commit it) or no GitHub access (hardware's `xarm-python-sdk` git pin). |
| `npm run gen:check` fails | UI generated types or `schemas/` out of date with core — a developer must run `npm run gen:sync && npm run gen:types` and commit; not an ops fix. |
| UI shows the old title / stale bundle | `dist/` not rebuilt: `(cd apollo-mavis-v2-ui && npm run build)`, then `systemctl --user restart mavis-runtime` (StaticFiles is mounted at start). |
| `survive-cli` (developer tooling) fails to load `libsurvive.so.0` | its RUNPATH points at the wiped `/tmp/libsurvive-build`; run with `LD_LIBRARY_PATH=~/opt/libsurvive/lib` and the `SURVIVE_PLUGINS` trick from `scripts/tracker/03-lh-consistency-check.sh`, or rebuild with `LIBSURVIVE_SRC=~/opt/src/libsurvive scripts/tracker/02-build-pysurvive.sh`. The runtime's wheel is unaffected. |

---

## S12. 中文速览（Chinese quick start）

目标：在实验室机器上用专用运维账号 **mavis** 部署并无人值守地运行 MAVIS v2（运行时 :8765 同时提供
已构建的网页 UI、Vive 追踪器、RØDE 麦克风、机械臂探测）；开发者账号保持不变。整套硬件（接收器、
麦克风、机械臂）**同一时刻只能被一个实例占用**。

前提：开发者已按依赖顺序（core → sim/hardware → runtime → ui）把**五个**子仓库 push 到 GitHub
并更新 workspace 指针（2026-09-04 已完成；S4 依赖 core/runtime 里按 USB 序列号配相机的改动，S5 依赖
hardware 的 `netsetup install --python/--user`）。真机 session 已在 phase-09c/09d 落地（仅 teleop；**两臂常驻
session**（09d，无 Include 开关）、10% 限速；任一导轨未归零时 409，先在臂卡片点 **Home rail** 归零——这是唯一会让
硬件运动的维护操作，先看孪生扫掠判定再确认；09d 起若当前姿态挡住扫掠，会先按孪生规划的、与导轨位置无关的路径以
10% 把臂折叠到安全姿态再归零，归零后保持该姿态，进度在面板里），但**尚未在真机上跑过**：首次运行按
`docs/prompts/phase-09c-hardware-session.md` 末尾的「真机验收步骤」（按其 09d 头注修订）、用户在场、急停在手（S7）。此外可用的是探测、只读监视 + 孪生叠加、麦克风、追踪器、
相机预览和 **仿真** session。

```bash
# 1) 系统依赖 + udev + sysctl（需 sudo，用自己的账号运行）
bash scripts/deploy/install-system-deps.sh
# 2) 创建 mavis 账号、设备用户组、开机自启的用户会话、共享目录（含 /var/lib/apollo-mavis-v2/wheels）
bash scripts/deploy/create-mavis-account.sh          # 之后重新登录（你被加进了 mavis 组）
sudo systemctl restart user@$(id -u mavis).service
# 3) 开发者（重新登录后）把 pysurvive wheel 和当前的 lighthouse 标定放进 mavis 可读的共享目录。
#    注意：mavis 读不了 /home/xiatao（0750）；/opt/apollo-mavis-v2 在 clone 前必须为空，wheel 不要放那里
install -m 664 ~/projects/apollo-mavis-v2-ws/third_party/wheels/pysurvive-1.1.204-cp312-cp312-linux_x86_64.whl /var/lib/apollo-mavis-v2/wheels/
install -m 664 -g mavis ~/.config/libsurvive/config.json /var/lib/apollo-mavis-v2/libsurvive/config.json
# 4) 以 mavis 身份：克隆、构建（uv 四个 venv、pysurvive、UI）、生成配置、安装服务 —— 全程不需要 sudo
sudo -iu mavis
curl -LsSf https://astral.sh/uv/install.sh | sh && export PATH="$HOME/.local/bin:$PATH"
git clone --recurse-submodules https://github.com/Apollo-Lab-Yale/apollo-mavis-v2-ws.git /opt/apollo-mavis-v2
bash /opt/apollo-mavis-v2/scripts/deploy/install-stack.sh      # 解释器放在 /opt/apollo-mavis-v2/.uv/python；wheel 取自 /var/lib/apollo-mavis-v2/wheels
bash /opt/apollo-mavis-v2/scripts/deploy/render-lab-config.sh  # -> /var/lib/apollo-mavis-v2/mavis_v2_lab.yaml（libsurvive、3 基站、yaw 116.3、共享路径、ui_dist）
bash /opt/apollo-mavis-v2/scripts/deploy/install-services.sh   # 安装并 enable systemd 用户服务（先不启动）
exit                                                           # 回到自己的账号：下一步需要 sudo，mavis 没有 sudo
# 5) netsetup（sudo，用自己的账号；机械臂开机）：把 NM dispatcher 钩子从开发者的 venv 改指向 ops venv，并检查
PY=/opt/apollo-mavis-v2/apollo-mavis-v2-hardware/.venv/bin/python
sudo $PY -m apollo_mavis_v2_hardware.netsetup install --yes   --python $PY --user mavis --arm grip=192.168.1.201 --arm view=192.168.2.219
sudo $PY -m apollo_mavis_v2_hardware.netsetup install --check --python $PY --user mavis --arm grip=192.168.1.201 --arm view=192.168.2.219
# 6) 先停掉开发者占用硬件（:8765、接收器、麦克风）的运行时，再以 mavis 身份启动服务
sudo -iu mavis
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
systemctl --user start mavis-runtime && journalctl --user -u mavis-runtime -f
# 7) 验证
bash /opt/apollo-mavis-v2/scripts/deploy/healthcheck.sh     # 浏览器打开 http://127.0.0.1:8765/ ，Debug 页（#/devices，右上角链接）做 Yaw 标定
```

日常：`systemctl --user start|stop|restart|status mavis-runtime`（mavis 身份，需先 export 上面两个变量）；
开发者要用真实接收器/麦克风/机械臂时先 `sudo -u mavis env XDG_RUNTIME_DIR=/run/user/<uid> DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus systemctl --user stop mavis-runtime`，
用完再 start；开发者自己的第二个实例用 `tracker.backend: fake`、`microphone.enabled: false`、
`--port 8766`（S8.3 有一条命令直接生成该配置）。升级（S9，mavis 身份即可，不需要 sudo）：停服务 →
`UPDATE=1 install-stack.sh` → `render-lab-config.sh` → 启动 → `healthcheck.sh`。备份：
`/var/lib/apollo-mavis-v2/{libsurvive,calibration,profiles,mavis_v2_lab.yaml}` 与
`/etc/apollo-mavis-v2/nic_map.json`（S10）。
