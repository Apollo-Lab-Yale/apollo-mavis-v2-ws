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
   `docs/prompts/phase-09c-hardware-session.md` + `phase-09d-rail-homing-planning.md`) and
   **first ran on the real boxes on 2026-09-05** (`docs/design/02-hardware.md` §16: three
   false alarms of our own, fixed the same day; fakes only until then): `POST /api/session
   kind=hardware` is teleop-only (data collection admitted 2026-09-07; **GELLO Manipulation**
   admitted with phase-15 on 2026-09-09 — `docs/design/16-gello.md` D8; DAgger / Online DAgger /
   inference stay sim-only), ALWAYS brings up both arms (phase-09d: `SessionSpec.arms`
   must be every configured arm — no per-arm switch on the Hardware tab) at `speed_scale`
   (Hardware tab 10 / 50 / 100 %, default 100 % since 2026-09-08 evening — the operator's call,
   `hardware_session.default_speed_scale: 1.0`, uncommitted in the runtime/ui working trees; 50 %
   from 2026-09-07; the rendered lab config keeps whatever value it was rendered with until
   re-rendered (S4) AND the runtime restarted; was 10 / 30 / 100 %,
   default 10 %), and is refused (409 `rail not homed`) while either linear track is unhomed —
   the operator homes it first with the arm card's **Home rail**, the ONE maintenance action that moves
   hardware (twin-gated; since phase-09d it may first drive the arm along a twin-planned,
   rail-position-agnostic path to a folded posture at 10 % and then hold it there, S7). The
   first live run followed the 09c contract's 真机验收步骤 (as amended by its 09d header note)
   with the user present and the e-stop in hand — still the procedure after every runtime
   change (S7).
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
   │   ├─ GELLO leader (phase-15, 2026-09-09): Dynamixel bus over FTDI FT232H 0403:6014 │
   │   │     /dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_FTAKROCJ-if00-port0     │
   │   │     -> ttyUSB0, root:dialout 0660; EXACTLY ONE process opens it (dev vs service) │
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
| **Demonstrations and Online DAgger sessions (2026-09-08, operator decision — outside `var/` and outside `/var/lib`; the morning's `~/data/pro_dagger` name never shipped)**: `datasets.namespaces` in the runtime config maps `bc_demo/<name>` → `~/data/bc_demo/<name>` and `online_dagger/<session>` → `~/data/online_dagger/<session>/{session.json,rollouts/}` (the trainer may add its own files there, e.g. `trainer/` — the runtime never reads them); `~` is the HOME of the account that runs the runtime, so under the service it is `/home/mavis/data/...`. Only the generic `datasets_root` (legacy `apollo/...` data) stays under `/var/lib/apollo-mavis-v2/datasets`. `GET /api/datasets/layout` prints the effective roots | `~/data/bc_demo`, `~/data/online_dagger` | the runtime account (`mavis`); created on first use (`mkdir -p`) |
| GELLO leader calibration (phase-15, 2026-09-09; written by `POST /api/gello/calibrate`, S8.1c) | `gello.calibration_path` in the rendered YAML — repo default `${APOLLO_HOME}/var/gello_calibration.json`; **verify on first deploy** where the lab render puts it (expected under `/var/lib/apollo-mavis-v2/`) | the runtime account (`mavis`) |
| netsetup system state | `/etc/apollo-mavis-v2/nic_map.json` (written by root) | root |
| Service unit | `/home/mavis/.config/systemd/user/mavis-runtime.service` | mavis |
| Logs | `journalctl --user -u mavis-runtime` (as mavis) **and** the runtime's own rotating `$DATA_ROOT/logs/runtime.log` (20 MB × 10; `logging:` block, `LOG_LEVEL` render knob, 2026-09-07); netsetup: `/var/log/mavis-netsetup.log` | `<ws>/var/logs/runtime.log` (rotating) + `runtime.stderr.log` (raw stderr: libsurvive / MuJoCo C prints) |

The developer account (`xiatao`) is untouched: its checkout, venvs, `~/.config/libsurvive`,
`~/apollo/*`, nvm and uv stay where they are. Two things are shared by nature and are
system-wide already: the udev rules (`/etc/udev/rules.d/60-apollo-teleop-input.rules`) and
the NetworkManager profiles `mavis_manipulation_arm` / `mavis_viewpoint_arm`.

Ports in use on this machine you must not collide with: 22 ssh, 8000 (gohttpserver),
4000, 631 cups, 5939 TeamViewer, 21115-21119 RustDesk, 7001/12001/20804-5/25001 NoMachine.
The stack uses 8765 (runtime), 5757 (trainer ZMQ), 5173 (Vite, developers only) and — only
when the lab render turns the dora external interface on (`DORA_BIND_HOST`, S4) — 6113 /
53391 / 7447 (dora coordinator / daemon / zenoh, bound to the lab Wi-Fi interface, never
`0.0.0.0`). The Online DAgger policy node (S8.5) is a separate process the policy repo starts;
it attaches to 53391 and needs no port of its own.

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

2. NVIDIA driver + EGL — must already be there (580.173.02 on this box, upgraded 2026-09-01):

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
| `dialout` | GELLO leader adapter `/dev/ttyUSB0` (FTDI FT232H `0403:6014`, `root:dialout 0660`; by-id `usb-FTDI_USB__-__Serial_Converter_FTAKROCJ-if00-port0`) | **needed since phase-15 (2026-09-09)**: the runtime's `GelloReader` opens the serial port (16-gello §4, §9.3); `60-apollo-teleop-input.rules` also puts the raw USB node in `dialout` (S5). Was "not needed today; harmless" until then — `mavis` has been in the group since S2 was first run |
| `video` | `/dev/dri/card*` | not needed today; harmless |

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
(cd apollo-mavis-v2-runtime  && uv sync --locked --no-dev --extra sim --extra hardware --extra audio --extra gello)  # ~5 GB (torch cu130, lerobot, mujoco); gello = dynamixel-sdk + pyserial (phase-15, 2026-09-09) -- without it GET /api/gello reports no_backend
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
-profiles_dir: ${APOLLO_HOME}/var/profiles
-datasets_root: ${APOLLO_HOME}/var/datasets
-checkpoints_root: ${APOLLO_HOME}/var/checkpoints
-calibration_dir: ${APOLLO_HOME}/var/calibration
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
-  libsurvive_config_path: ${APOLLO_HOME}/var/libsurvive/config.json
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
1.0` — the Hardware tab's speed picker is 10 / 50 / 100 %, default 100 %, since 2026-09-08 evening
(operator's call; 0.5 = 50 % from 2026-09-07; uncommitted in the runtime/ui working trees, so the lab
config rendered from the pushed pins keeps its older value until re-rendered AND the runtime
restarted — the new default reaches the operator only then); `rail_flip: false` —
set `true` and re-render if the `*_align` overlay shows the twin's
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

### Render knobs added since 2026-09-07 (phase-12 dora, phase-13 datasets, phase-14 Online DAgger)

The script always had these knobs; this section documents them (2026-09-08).

- **`DORA_BIND_HOST`** (default empty = leave the repo's `dora.enabled: false` alone). When set
  the render writes `dora.enabled: true`, `dora.bind_host: <value>` (an IPv4 **or an interface
  name** — the lab uses `wlp38s0`, the "APOLLO Lab" Wi-Fi, DHCP 192.168.0.88/24 on 2026-09-07;
  `tailscale0` also works) and, unless `KEEP_REPO_PATHS=1`, `dora.var_dir: $DATA_ROOT/dora`
  (the auth token lands in `<var_dir>/.dora-token`, never in the YAML and never served by
  REST). Never `0.0.0.0`, never the arm links 192.168.1.11 / 192.168.2.12 — the runtime refuses
  them and reports `external.state: disabled`. Ports 6113 / 53391 / 7447 (14-dora §9/§12).
  The validation line the script prints ends with `dora: enabled=… bind_host=… ports=…`.
- **`DORA_MACHINES="gpubox,laptop"`** (optional, only with `DORA_BIND_HOST`): comma list of
  remote consumer machine ids allowed to join; each gets the default `viewer` + `observer`
  placeholders in `dora.machines`. The policy node runs ON the lab machine (placeholder
  `policy`, machine `lab`) and is not listed here.
- **Not templated: `datasets.namespaces`** (phase-14, 15-online-dagger D5). The render still
  points the generic `datasets_root` at `$DATA_ROOT/datasets`, but the two mapped namespaces
  keep the repo values `bc_demo: {root: ~/data/bc_demo}` and `online_dagger: {root:
  ~/data/online_dagger, subdir: rollouts}` (2026-09-08 evening; the morning's `pro_dagger`
  namespace never shipped) — `~` expands in the runtime process, i.e. `/home/mavis/data/...`
  under the service, `/home/xiatao/data/...` for a developer instance. That is the operator's
  2026-09-08 decision (data outside `var/`), not an omission; a `DATASETS_HOME` knob is an
  open item. The UI shows the effective folders (Data Collection sheet preview, Welcome
  DatasetsPanel groups, `GET /api/datasets/layout`).
- Carried over unchanged from the repo (no knob): `datasets.default_namespace: bc_demo`,
  the `online_dagger:` block (`skill_dir: null` = the skill shipped inside the runtime wheel,
  `session_file_hz: 1.0`), `control.translate_frame: world` (the keyboard translate frame;
  operator decision 2026-09-08 evening — `camera` / `base` stay selectable in the YAML).
- Not a YAML line at all (2026-09-08 evening): `hardware_session.start_from_fault_grace_s`
  (how long a hardware `start_from=profile` waits for a transient RECOVERING arm before
  submitting its plan) has no key in `configs/mavis_v2.yaml`, `configs/sim.yaml` or the render
  script — every rendered config inherits the pydantic default
  `HardwareSessionConfig.start_from_fault_grace_s = 3.0` (runtime `config.py`). To change it,
  add the key under `hardware_session:` in the rendered YAML by hand and restart. (An earlier
  wording listed it among the "carried over" YAML lines; corrected 2026-09-08 late evening.)

### Render knobs added 2026-09-09 (phase-15 GELLO Manipulation; 16-gello §9)

- **`GELLO_BACKEND`** (lab value `dynamixel`; the repo config says `gello.backend: none`): the
  runtime's `GelloReader` backend — `none` keeps GELLO off (`GET /api/gello` → `no_backend`, the
  GELLO card cannot start), `fake` is the scripted leader for sim / tests, `dynamixel` opens the
  real bus (needs the `gello` extra, S3).
- **`GELLO_USB_SERIAL`** (lab value `FTAKROCJ`): the FTDI adapter's USB serial → `gello.usb_serial`;
  the reader resolves the `ttyUSB*` node whose sysfs USB parent carries it (the cameras' by-serial
  precedent), so `/dev/ttyUSB` numbering and plug order do not matter. Empty = the fixed
  `gello.port` (`/dev/ttyUSB0`).
- **`GELLO_BAUD`** (empty = `gello.baud: null` = auto-scan 57600 / 1M / 2M / 3M / 4M at connect; the
  first rate whose broadcast ping is answered wins and is logged): set it once the build's servo
  baud is known (16-gello §16 item 1 — nothing answered on 2026-09-09, most likely unpowered servos).
- **`TWIN_OVERLAY_SCENE`** (lab value `mavis_v2_kitchen`; empty = `twin_overlay.scene: null` = the
  hardware workcell's `digital_twin_scene`, i.e. `mavis_v2`): which scene the session-less
  `grip_wrist_align` / `view_wrist_align` overlays render. With the kitchen twin the overlays also
  outline the fridge / range / counter boxes, so their placement can be checked against the real
  wrist images (16-gello §3: every appliance face is ±3 cm until this check has been done and the
  YAML nudged — a phase-15 acceptance step). A GELLO session's gate runs on the kitchen twin
  whatever the overlay shows (16-gello §16 item 6) — keep the two in step.
- Everything else in the `gello:` block (`scene_id: mavis_v2_kitchen`, the Perception Arm's hold
  posture `view_posture_rad` / `view_rail_m`, `joint_signs` — operator-owned once set —, the
  tolerances `engage_tol_rad` 0.10 / `leash_rad` 0.80 / `max_jump_rad` 0.5, `calibration_path`) comes
  from the repo config (16-gello §9.1); edit the rendered YAML by hand if it ever has to differ.

```bash
GELLO_BACKEND=dynamixel GELLO_USB_SERIAL=FTAKROCJ TWIN_OVERLAY_SCENE=mavis_v2_kitchen \
  bash /opt/apollo-mavis-v2/scripts/deploy/render-lab-config.sh     # + DORA_BIND_HOST=wlp38s0 if a viewpoint node should attach; then RESTART
```

**Restart after every render** applies to these knobs exactly as to the others below.

**Restart after every render or upgrade.** The runtime reads the config ONCE at start
(`systemctl --user restart mavis-runtime`; the script's last line says so). The same holds
for the developer's long-running instance: as of 2026-09-09 the dev runtime (PID 3869832,
started 04:45:20 with `var/mavis_v2_local.yaml`) runs the phase-12 / 13 / 14 trees exactly as
committed at 05:46 (ws e16d2c1) — `translate_frame: world`, Online DAgger v2.0, Go to profile
and `start_from_fault_grace_s` are live; nothing from phase-15 (GELLO, `gello:` block,
`/api/gello`, the kitchen twin) is, until it is restarted after a re-render. (Earlier notes here
named the 2026-09-08 18:00 process 2144376 and, before that, a 01:27 one; both are gone.)

```bash
bash /opt/apollo-mavis-v2/scripts/deploy/render-lab-config.sh          # -> /var/lib/apollo-mavis-v2/mavis_v2_lab.yaml
# stop-gap if the two camera tiles turn out crossed (see below): swap the serials without touching the repo
CAMERA_SERIALS="grip_wrist=322143060792,view_wrist=349643062582" bash /opt/apollo-mavis-v2/scripts/deploy/render-lab-config.sh
# turn the dora external interface on for policy nodes / LAN subscribers (phase-12; see the knobs above)
DORA_BIND_HOST=wlp38s0 bash /opt/apollo-mavis-v2/scripts/deploy/render-lab-config.sh
DORA_BIND_HOST=wlp38s0 DORA_MACHINES="gpubox" bash /opt/apollo-mavis-v2/scripts/deploy/render-lab-config.sh   # + one remote consumer machine
```

Cameras (**verify on first deploy**): the runtime opens each RealSense's colour stream as a
plain v4l2 device that it finds by **USB serial** (core `CameraConfig.serial`, sysfs lookup;
no by-id path, no `pyrealsense2`, `fourcc: YUYV` because the RS colour node offers no MJPG),
so `/dev/video*` numbering and plug order do not matter. Two D435i are attached, serials
`322143060792` and `349643062582` (`lsusb -d 8086: -v 2>/dev/null | grep iSerial`, or
`v4l2-ctl --list-devices`). `lsusb -d 8086:0b3a` lists both D435i units; on apollo-pc-1 they
hang off different USB host controllers — 349643062582 on PCI 29:00.3 (USB bus 6),
322143060792 on PCI 29:00.1 (USB bus 4). The repo maps `349643062582 → grip_wrist`
(Manipulation Arm) and `322143060792 → view_wrist` (Perception Arm) — **confirmed by the
operator on 2026-09-04** from the Hardware-tab tiles (the pre-2026-09-04 config had the two
serials the other way round — a guess, corrected from those tiles). If a camera is ever
replaced or moved: cover one lens and watch the Welcome page → Hardware tab tiles; if they are crossed, swap the two serials in
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

Since 2026-09-06 the normal reader **also** passes `--configfile
tracker.libsurvive_config_path` (`devices/tracker.py`), so libsurvive reads/writes exactly
that file at teleop — no reliance on `$XDG_CONFIG_HOME/libsurvive/config.json`. The
calibration wizard still owns the same path for copy / back up / install and strips any
`--configfile` before adding its own temp copy (`CALIBRATION_ARGS`). With an explicit
`--configfile` the S6 symlink `/home/mavis/.config/libsurvive ->
/var/lib/apollo-mavis-v2/libsurvive` is redundant (harmless; `install-services.sh` still
creates it and seeds `config.json` if missing). The self-contained default is
`${APOLLO_HOME}/var/libsurvive/config.json` (04-runtime §14.1).

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

   **Phase-15 (2026-09-09) adds two rules to the same file** (16-gello §9.3), installed by that
   script: `SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6014", MODE="0660",
   GROUP="dialout", TAG+="uaccess"` (the GELLO leader's FTDI FT232H adapter) and `ACTION=="add",
   SUBSYSTEM=="usb-serial", DRIVER=="ftdi_sio", ATTR{latency_timer}="1"` (1 ms USB latency — the
   kernel default 16 ms caps eight Dynamixel servos at ~30 Hz; the reader logs a WARNING above 2 ms).
   Because the rule file already exists on apollo-pc-1, `install-system-deps.sh` SKIPS it — re-run
   with `FORCE_UDEV=1 bash scripts/deploy/install-system-deps.sh` (or `bash
   scripts/tracker/01-sudo-udev-and-deps.sh` directly); the script also writes `latency_timer` 1
   into every FTDI port that is already plugged in, because the rule fires on `add` only (otherwise
   replug the adapter), and adds `dialout` to the invoking developer (`mavis` has it since S2).
   Verify: `cat /sys/bus/usb-serial/devices/ttyUSB0/latency_timer` → `1` (it read 16 on 2026-09-09
   before the rule), `ls -la /dev/ttyUSB0` → `root dialout 0660`.

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
   `/var/log/mavis-netsetup.log`. The two profiles: `mavis_manipulation_arm` = 192.168.1.11/24
   on `enp36s0f1` (MAC 08:BF:B8:89:4F:3B) → Manipulation Arm control box 192.168.1.201;
   `mavis_viewpoint_arm` = 192.168.2.12/24 on `enp36s0f0` (MAC 08:BF:B8:89:4F:3A) → Perception
   Arm control box 192.168.2.219. The MAC/interface pinning of both profiles is done (the
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
Environment=OPENBLAS_NUM_THREADS=1
Environment=OMP_NUM_THREADS=1
Environment=MKL_NUM_THREADS=1
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
tail -f /var/lib/apollo-mavis-v2/logs/runtime.log   # the same lines, rotating file (logging.dir); `grep 'loop:'` = the
                                                    #   1 Hz control-loop health line (04-runtime §14 "Logging") — the
                                                    #   first thing to read after a bad session
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
id mavis                                          # render plugdev input audio netdev dialout present (dialout: GELLO adapter, phase-15)
loginctl show-user mavis -p Linger                # Linger=yes
lsusb -d 28de:2101; lsusb -d 19f7:0015             # dongle, RØDE present
lsusb -d 0403:6014                                 # GELLO leader adapter (FTDI FT232H), phase-15 2026-09-09
ls -la /dev/serial/by-id/                          # usb-FTDI_USB__-__Serial_Converter_FTAKROCJ-if00-port0 -> ../../ttyUSB0 (root:dialout 0660)
cat /sys/bus/usb-serial/devices/ttyUSB0/latency_timer   # 1 (S5 udev rule); 16 = rule not applied -> leader rate ~30 Hz (S11)
nmcli -t -f NAME,DEVICE con show --active | grep mavis_    # mavis_manipulation_arm:enp36s0f1, mavis_viewpoint_arm:enp36s0f0
timeout 2 bash -c 'echo > /dev/tcp/192.168.1.201/502' && echo grip-open
timeout 2 bash -c 'echo > /dev/tcp/192.168.2.219/502' && echo view-open
curl -s 127.0.0.1:8765/api/health                                  # {"status":"ok",...}
curl -s '127.0.0.1:8765/api/workcell?kind=hardware' | python3 -m json.tool | grep -E '"arm_id"|"reachable"|hardware_ready'
curl -s 127.0.0.1:8765/api/microphones | python3 -m json.tool | grep -E '"status"|"live"'
curl -s 127.0.0.1:8765/api/cameras | python3 -c 'import json,sys; [print(c["camera_id"], c["live"]) for c in json.load(sys.stdin) if c["kind"] != "sim"]'   # grip_wrist True / grip_wrist_align True / view_wrist True / view_wrist_align True
curl -s 127.0.0.1:8765/api/tracker/calibration | python3 -m json.tool | grep -E 'yaw_valid|yaw_calibrated_at|applied_yaw'
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' 127.0.0.1:8765/     # 200 text/html (UI)
curl -s 127.0.0.1:8765/api/gello | python3 -m json.tool | grep -E '"backend"|"status"|"port"|"baud"|"rate_hz"|"calibrated"|scene_id|hardware_admitted'   # phase-15: backend dynamixel, status connected (servos powered) with rate_hz ~100, scene_id mavis_v2_kitchen, hardware_admitted true; no_backend / stale -> S11
```

With `TWIN_OVERLAY_SCENE=mavis_v2_kitchen` (S4, phase-15) the two `*_align` overlays also draw the
kitchen twin's fridge / range / counter boxes as outlines over the real wrist images — the
alignment check 16-gello §3 asks for (appliance faces ±3 cm until compared and the scene YAML
nudged; the Perception Arm at its GELLO hold posture sees the fridge front and the range).

The two `*_align` rows (phase-09a, 2026-09-04) are the digital-twin alignment overlays
(`kind: twin`, 640×480 @ 12 fps): each is `live: true` only while its real wrist camera is live
AND the runtime's read-only hardware monitor has samples from that arm's control box and no
hardware session owns the boxes — a box that is off leaves its overlay `false` while the real
camera stays `true`. On the Hardware tab expect five tiles (two cameras, two pale-yellow
overlays with the note `rail not homed · twin assumes 0.65 m` until the tracks are homed, the
microphone) and no red `C<code>` chip (until 2026-09-05 the Perception Arm card carried a red
`C19`; fixed for good that day in xArm Studio → Settings → Externals → End Effector → **None**,
both boxes read `error_code` 0 since); `/ws/telemetry`
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
curl -s -X POST -H 'content-type: application/json' -d '{"op":"clear_errors"}' $M/view/maintenance | python3 -m json.tool | grep -E '"ok"|"detail"|"error_code"'   # ok true, after.error_code 0 (the Perception Arm's C19 returned after every clear until Studio -> Settings -> Externals -> End Effector -> None, done 2026-09-05)
for a in grip view; do curl -s -X POST -H 'content-type: application/json' -d '{"op":"apply_backstops"}' $M/$a/maintenance | python3 -m json.tool | grep -E '"ok"|"detail"|collision_sensitivity|tcp_load_kg|backstops_match'; done   # ok true; after: collision_sensitivity 3, tcp_load_kg 0.95 / 0.55, backstops_match true
```

Afterwards `hardware_monitor.arms[]` still reads `state 4` / `mode 0`, the joints did not move,
the card's read-back line is neutral and both toasts appeared (`<Arm> · errors cleared`,
`<Arm> · safety settings applied (sensitivity 3, payload 0.95 kg)`). The settings are volatile
(lost at a controller reboot); the driver re-applies them at every session connect.

Phase-09c / 09d (2026-09-05) — hardware sessions; **first exercised live on 2026-09-05**
(`docs/design/02-hardware.md` §16: three false alarms of our own — controller `state 2` is
healthy, servo-mode entry is not instantaneous, `clean_error` 1/2/9 is a status echo — fixed the
same day; fakes only until then). Each
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
by its phase-09d header note** (user present, physical e-stop in hand, workspace clear; done
once on 2026-09-05 — 02-hardware §16 — and still the procedure after every runtime change):
(1) both arms `running`, err 0 (a latched error 409s the session and would LATCH its driver;
the Perception Arm's `C19` was fixed for good in Studio on 2026-09-05, S11), overlays normal;
(2) Manipulation Arm → **Home
rail** → dry-run (clear, or `pre-positioning planned`: read the plan, expect the ARM to move
first) → confirm → card reads `rail 0.000 m` → look at the `*_align` overlay **immediately**:
twin rail / base must coincide with the real ones; if the carriage sits at the wrong end set
`hardware_session.rail_flip: true` (re-render S4, restart) and look again; (3) Perception Arm
the same (judge its base from the Manipulation Arm's overlay — its own camera looks outward);
(4) **Speed 10 %** (pick it — the tab pre-selects 100 % since 2026-09-08) → Teleop (both arms
join; there is no per-arm switch) → bring-up rows until
`running`, Cockpit shows `speed 10%`, both arms stay still for 10 s without the clutch; (5)
clutch + a slow 5 cm hand motion → the Manipulation Arm (the active arm) follows in the same
direction at ~1/10 speed, the Perception Arm holds, releasing the clutch stops it; (6) end the
session → both arms are handed back stopped with the brakes engaged (`state 4`,
`motion_enable(False)`), the monitor resumes, the cards are normal. Only then 50 % (the picker's
30 % step became 50 % on 2026-09-07), switching
the active arm, rail following. The same over REST:

```bash
M=127.0.0.1:8765/api/hardware/arms
curl -s -X POST -H 'content-type: application/json' -d '{"op":"home_rail","dry_run":true}' $M/grip/maintenance | python3 -m json.tool | grep -E '"ok"|"detail"|"clear"|"needed"|"waypoints"|first_blocked|min_clearance'   # ok true + rail_sweep.clear true = safe to home with the joints untouched; pre_position.needed true + clear true = a pre-positioning motion is planned (phase-09d; waypoints, duration_s); nothing written
curl -s -m 60 -X POST -H 'content-type: application/json' -d '{"op":"home_rail"}' $M/grip/maintenance | python3 -m json.tool | grep -E '"ok"|"status"|"job_id"|"detail"|rail_homed|rail_enabled|rail_pos_m'   # MOVES THE CARRIAGE (<= 45 s): ok true, status done, after.rail_homed / rail_enabled true, rail_pos_m 0.0 -- OR HTTP 202 status accepted + job_id (phase-09d: the posture blocks the sweep; the ARM MOVES FIRST along the planned path at 10 %, then the carriage -- keep clear of the whole cell)
curl -s $M/grip/maintenance/last | python3 -m json.tool | grep -E '"ok"|"status"|"job_id"|"detail"'   # phase-09d: the job's FINAL result (status done, same job_id; ok false on failure); 404 until any home_rail ran. Progress meanwhile: /ws/telemetry hardware_monitor.arms[].maintenance.phase
curl -s 127.0.0.1:8765/api/session      # 404 without a session; "state":"bringup" while POST /api/session runs, then "running" with "kind":"hardware", both arm ids in "arms" (phase-09d), "speed_scale":0.1 for the acceptance run's Speed 10 % (the tab's default is 1.0 = 100 % since 2026-09-08)
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

### S8.1b The workcell's initial condition (2026-09-08)

The `R` key and the Cockpit's "End session" both walk the arms back to the **designated
initial-condition profile** of the running session's workcell kind, and both are no-ops
(with a reason in the UI) when none is designated. Seed the operator's default posture
once per machine, as `mavis`, with the runtime STOPPED or at least with no session
running:

```bash
cd /opt/apollo-mavis-v2/apollo-mavis-v2-runtime
uv run python -m apollo_mavis_v2_runtime.profiles.seed_initial     --config /var/lib/apollo-mavis-v2/mavis_v2_lab.yaml --dry-run   # look first
uv run python -m apollo_mavis_v2_runtime.profiles.seed_initial     --config /var/lib/apollo-mavis-v2/mavis_v2_lab.yaml             # then write
```

It writes one profile per workcell kind into `profiles_dir` and designates it (idempotent
— re-running rewrites the same two files). The postures are the operator's 2026-09-08
numbers: Manipulation Arm `[-180, -12, -20, 30, -5, 35, -8.9]°`, Perception Arm
`[0, 0.8, 0, 28.9, 0, 28.2, 0]°`, carriages left unset so a return never commands a
track onto its end stop. Prefer the Cockpit's "save current state as profile" + "use as
initial condition" when you want a posture measured on the real cell, carriages included
— the return then moves the carriages as a separate, separately gated second phase.
Designating an initial condition also changes what a collect session's per-episode
return-to-start aims at when no `start_from` profile is chosen (04-runtime §10.5).

### S8.1c GELLO leader calibration (2026-09-09, phase-15; 16-gello §4, D10)

Session-less and motion-free. Once per GELLO build (and after any servo re-mount): (1) power
the servos — the adapter alone enumerates (`lsusb -d 0403:6014`) but no servo answers the baud
scan until they are powered, and `GET /api/gello` stays `no_backend` / `error` (that was the bus's
state on 2026-09-09); (2) `GET /api/gello` → `status: connected`, `rate_hz` ≈ 100, `q_raw` moving
as you move GELLO; (3) pose GELLO like the Manipulation Arm stands RIGHT NOW (the read-only
monitor sample on hardware, the parked posture in sim) and click **Calibrate** in the GELLO sheet
= `POST /api/gello/calibrate {"op":"match_arm"}` — the runtime stores per-joint offsets (the
nearest multiple of π/2, the GELLO convention) in `gello.calibration_path`; (4) move each joint
alone and check its direction in the sheet's raw / mapped table — `gello.joint_signs` are CONFIG
(operator-owned once set; the calibrate op never writes them: edit the rendered YAML and
restart); (5) gripper endpoints `{"op":"gripper_open"}` / `{"op":"gripper_closed"}` at the two
ends — until both exist `gripper_frac` is null and the follower's gripper does not move;
`{"op":"clear"}` deletes the file. Every op's result is echoed in `GET /api/gello` (`calibrated`,
`joint_offsets_rad`); 409 while a session runs or without a leader sample. Then the GELLO
sheet's preview must read `clear` before **Start** is enabled (a collision names the pair and
tints the bodies red in the PNG — move GELLO and retry, 16-gello §0 item 5).

```bash
G=127.0.0.1:8765/api/gello
curl -s $G | python3 -m json.tool | grep -E '"status"|"baud"|"rate_hz"|"calibrated"|q_raw'
curl -s -X POST -H 'content-type: application/json' -d '{"op":"match_arm","kind":"hardware"}' $G/calibrate | python3 -m json.tool   # ok true, joint_offsets_rad [7 values]
curl -s -X POST -H 'content-type: application/json' -d '{"kind":"hardware"}' $G/preview | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["status"], r["detail"], r["pairs"])'   # clear [] -- or collision + the pairs (no motion either way)
```

### S8.2 Who owns what — exactly one owner per device

| Resource | Exclusive? | Consequence for a second instance |
|---|---|---|
| Watchman dongle 28de:2101 | yes (libusb claim) | second libsurvive context → `LIBUSB_ERROR_BUSY`, tracker `error` (retries forever). Only one `tracker.backend: libsurvive` per machine. |
| RØDE NT-USB Mini | one ALSA card; held by whichever **PulseAudio daemon** has a running stream | the loser's capture gets EBUSY/`absent`. Dev and ops each have their own PA daemon. |
| xArm control boxes (TCP 502) | one SDK controller at a time | probes are harmless; the read-only monitor and hardware sessions (phase-09c) must never run from two instances — inside one instance the monitor is paused while a session owns a box |
| GELLO leader adapter FTDI FT232H `0403:6014` (`/dev/ttyUSB0`; phase-15, 2026-09-09) | yes (one opener of the serial port) | a second `gello.backend: dynamixel` gets the port busy / a garbled bus and reports `error`; only one instance per machine may run the dynamixel backend — the other renders `GELLO_BACKEND=none` (or `fake`). Same rule as the dongle: dev runtime vs ops service (S8.4). |
| Ports 8765 / 5757 | per instance | second instance needs `--port` / `dagger.trainer.port` |
| NetworkManager profiles | system-wide | only the root dispatcher / one `netsetup` mutates them |
| GPUs, `/dev/video*`, sim | shareable | — |

### S8.3 Developer running a second instance while the ops service runs

Use fake/none backends, another port, and the self-contained developer launcher, which
keeps everything under `<ws>/var` (no `~/apollo`, no sudo; `04-runtime §14.1`):

```bash
cd ~/projects/apollo-mavis-v2-ws
scripts/dev/mavis-dev.sh render        # builds <ws>/var/mavis_v2_local.yaml from the tracked
                                       #   config + the gitignored scripts/dev/local.env knobs
scripts/dev/mavis-dev.sh start         # runtime (:8765) + Vite (:5173), logs/pids in <ws>/var
```

With no `scripts/dev/local.env` the render is a safe sim default (`tracker.backend: fake`,
`hardware_session.armed: false`); set `TRACKER_BACKEND` / `HARDWARE_ARMED` / `TRACKER_YAW_DEG`
/ `RUNTIME_PORT` there for a lab box. To render by hand instead (e.g. a second instance
beside the ops service on another port), call the renderer with `KEEP_REPO_PATHS=1` so the
workspace-relative paths survive:

```bash
OPS_ROOT=$PWD KEEP_REPO_PATHS=1 LAB_CONFIG=$PWD/var/dev.yaml \
  RUNTIME_PORT=8766 TRAINER_PORT=5758 TRACKER_BACKEND=fake MIC_ENABLED=false \
  bash scripts/deploy/render-lab-config.sh
MAVIS_CONFIG=$PWD/var/dev.yaml scripts/dev/mavis-dev.sh start runtime
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

### S8.5 Online DAgger trainer — the policy-node process (2026-09-08, phase-14; rewritten the same evening from the PRO-DAgger v1.0 wording)

Online DAgger (15-online-dagger v2.0) trains in **another process that the policy repo owns**:
the `mavis-policy-node` dora node (package `mavis_policy_node`, repo
`apollo-mavis-v2-policy-node` — on the developer machine at
`~/projects/apollo-mavis-v2-ws-p12/apollo-mavis-v2-policy-node`, no remote yet). The runtime
is an algorithm-agnostic shell: it creates the session directory, runs rollouts, exposes
take-over / hand-back, labels every frame novice / expert, relays the trainer's status and
serves the instructions — it knows nothing about iterations, reference gradients or
hyper-parameters (those live in the trainer's own config). Sim only for now: the launcher
refuses `dagger` on the Hardware tab (D7) until the operator says go after a sim session.
Nothing here is a systemd service — the policy repo's operator starts the node by hand on the
lab machine (the runtime's `policy` placeholder is deployed on machine `lab`; a remote policy
node is not supported in v1).

Steps, as they appear in the Welcome page's Online DAgger sheet ("1 Connect a trainer"):

```bash
# 0) the runtime must run with dora ON (S4: DORA_BIND_HOST) — check, then read the connection facts
curl -s http://127.0.0.1:8765/api/dora        # {"enabled": true, "state": "attached", "bind_host": ..., "daemon_port": 53391, "zenoh_connect": "tcp/<bind_host>:7447", ...}

# 1) in the POLICY repo's checkout: install the skill for its coding harness (the one-liner the sheet shows, with a Copy button)
curl -s http://<lab-host>:8765/api/online_dagger/skill.tgz | tar xz -C ~/.claude/skills/   # -> ~/.claude/skills/mavis-online-dagger-trainer/{SKILL.md,references/{contract.md,pro-dagger-example.md}}
curl -s http://<lab-host>:8765/api/online_dagger/skill                                      # the same SKILL.md as text/markdown
# port 8765 = the runtime; 8000 on this machine is gohttpserver, not us

# 2) install the node with the trainer extras into the policy repo's venv, implement Policy + the OnlineDaggerTrainer hooks (SKILL.md)
pip install "mavis-policy-node[pro_dagger,torch]"       # the `pro_dagger` extra is just pyarrow (episode-directory reader); + [video] for image policies; or pip install -e <checkout>[pro_dagger,torch]

# 3) test without the cell, then run the node against the runtime's daemon
mavis-policy-node --online-dagger my_pkg.trainer:make_trainer --trainer-config trainer.yaml --selftest online-dagger   # exit 0, prints idle -> preparing -> ready -> training -> ready (+ a version bump); no dora needed
export DORA_ZENOH_CONNECT=tcp/<bind_host>:7447 DORA_ZENOH_MULTICAST=off DORA_ZENOH_LISTEN=tcp/127.0.0.1:0
mavis-policy-node --loader entrypoint --entrypoint my_pkg.policy:make_policy \
    --online-dagger my_pkg.trainer:make_trainer --trainer-config trainer.yaml --path ckpt/ --device cuda:0 --daemon-port 53391

# the PRO-DAgger reference implementation that ships with the node (its config owns the offline anchor: offline_dataset is REQUIRED,
# resolved under datasets_home ~/data; defaults freeze_offline_gref: true, replay_buffer: true, max_demos: 0)
mavis-policy-node --loader entrypoint --entrypoint my_pkg.policy:make_policy \
    --online-dagger mavis_policy_node.pro_dagger:make_trainer --trainer-config pro_dagger.yaml --daemon-port 53391

# dry run with no model at all (the same fake the runtime's e2e uses; from the policy-node checkout)
mavis-policy-node --loader fake --online-dagger fake --daemon-port 53391
```

With `--online-dagger` the node's `spec.capabilities` lists `online_dagger`; the sheet's
trainer pill turns green and **Start Online DAgger** is enabled (otherwise `409 no Online
DAgger trainer attached (the policy node does not report the online_dagger capability)`). The
session then lives in `~/data/online_dagger/<session>/` (S0 table): the runtime writes
`session.json` and records `rollouts/` (one directory per episode, `actor` column 0 novice /
1 expert); the trainer's own artefacts go wherever it puts them (the skill suggests
`<session>/trainer/`). New rollouts are refused until the trainer has reported `ready` once for
this session (`wait_for_trainer_ready`) and while it reports `training`
(`pause_while_training`); a discarded rollout leaves nothing on disk. The trainer must echo the
announced `session_id` in every `trainer_status` it publishes — a status without it counts as
alive only and keeps the session in `WAITING FOR TRAINER` (15-online-dagger §3). Never run two
dora control planes on this host at once, never `pkill -f dora` (use `pgrep -x dora`), never
`dora up/down/destroy` without `--coordinator-addr/--coordinator-port` (CLAUDE.md "Dora
external interface").

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
(cd apollo-mavis-v2-runtime && uv sync --locked --no-dev --extra sim --extra hardware --extra audio --extra gello \
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

State on 2026-09-08: phase-12 (dora), phase-13 (episode-directory datasets, keyboard, return
to start), the 2026-09-08 follow-ups and phase-14 (Online DAgger) are implemented in the
developer's five working trees but **uncommitted and unpushed**, so an `UPDATE=1` run today
still deploys the 2026-09-07 pins (no `dora:`, `datasets:`, `online_dagger:` keys, no
`/api/online_dagger/*`, `translate_frame` absent). After they are pushed and pinned: `UPDATE=1`
→ re-render (the new keys land; add `DORA_BIND_HOST=wlp38s0` if policy nodes should attach)
→ restart. The UI is built with **npm** (`npm ci`; `package-lock.json` is the lockfile — pnpm's
pre-run install fails on this machine, and `pnpm-lock.yaml` / `pnpm-workspace.yaml` are never
committed).

State on 2026-09-09: phase-12 / 13 / 14 and the 2026-09-08/09 follow-ups were committed and
pushed at 05:46 (ws `e16d2c1` pins all five), so `UPDATE=1` now deploys them — re-render so the
`dora:` / `datasets:` / `online_dagger:` / `translate_frame` keys land. **Phase-15 (GELLO
Manipulation, `docs/design/16-gello.md`) is in progress in the developer's working trees and
uncommitted**: an upgrade today gets no `gello:` block, no `gello` extra in `uv.lock` (the
`--extra gello` above then fails — drop the flag until the runtime pin carries it), no
`/api/gello` and no `mavis_v2_kitchen` scene. After it is pushed and pinned: `UPDATE=1` →
re-render with the S4 GELLO knobs → `FORCE_UDEV=1` S5 once (the two new udev rules) → restart.

---

## S10. Backup and restore

What matters (everything else is rebuildable from git + PyPI):

| What | Path |
|---|---|
| Lighthouse calibration (+ wizard backups) | `/var/lib/apollo-mavis-v2/libsurvive/config.json`, `config.json.bak-*` |
| Tracker yaw + base-station install record | `/var/lib/apollo-mavis-v2/calibration/tracker_calibration.json`, `base_station-*.json` |
| Teleop profiles | `/var/lib/apollo-mavis-v2/profiles/` |
| GELLO leader calibration (phase-15, 2026-09-09; small — redo with S8.1c if lost) | `gello.calibration_path` of the rendered YAML (repo default `${APOLLO_HOME}/var/gello_calibration.json`) |
| Datasets (episode directories since phase-13; `exports/lerobot_v3/` is a derived export), checkpoints | legacy / generic root `/var/lib/apollo-mavis-v2/datasets/`; **since 2026-09-08 the demonstrations live in `~mavis/data/bc_demo/<name>/` and Online DAgger sessions in `~mavis/data/online_dagger/<session>/` (`session.json`, `rollouts/`, plus whatever the trainer writes there)** — back those two trees up too; `/var/lib/apollo-mavis-v2/checkpoints/` (large) |
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
| `POST /api/session` kind=hardware → 409 `<Arm>: rail not homed - home it from the Hardware tab (Home rail) before starting a session` | expected after every power-on (phase-09c): both tracks boot unhomed and a session needs the carriage position for the gate twin — and since phase-09d BOTH arms are always in a session, so both tracks must be homed. Card → **Home rail** → dry-run verdict → confirm (the carriage MOVES to the operator's left end, ≤ 45 s; or, phase-09d, the sheet says `pre-positioning planned` and the ARM MOVES FIRST along the planned path at 10 %, then the carriage — 202 job, watch the phases in the sheet) → `rail 0.000 m`; then check the `*_align` overlay before the session. Other 409s from the same matrix: `hardware sessions support teleop and data collection only (<mode> on hardware: not yet)` (collect is admitted on hardware since 2026-09-07 — 04-runtime §5 / §10.5; **GELLO Manipulation is admitted too since phase-15, 2026-09-09 — 16-gello D8, so the string names it as well from that runtime on**; DAgger / Online DAgger and inference stay on the Sim tab, 15-online-dagger D7; the pre-2026-09-07 string was `hardware sessions support teleop only`), `hardware sessions include every configured arm (Manipulation Arm, Perception Arm) - missing [...]` (a client posted a subset — the UI never does since phase-09d; both arms always join, so the Perception Arm must be homed / error-free too), `no monitor sample` (box off / monitor paused), `controller error N is latched - clear errors first` (**Clear errors**; the Perception Arm's `C19` blocked every session until it was fixed in Studio on 2026-09-05), `rail homing in progress` (wait for the carriage / the job), `control box … is unreachable`, `hardware bring-up failed: <Arm>: <stage> - …` (the drivers were torn down again, the monitor resumed — read the stage), `profile motion not collision-free: <failure> (<pair>) - …` (phase-09d: `start_from: profile:<id>` was planned on the gate twin inside bring-up and no collision-free path exists from the measured posture — use `keep_current` or another profile; the session was torn down). |
| **Home rail** refused / failed (sheet shows a red verdict or an error, `ok: false`, 409) | `Sweep blocked — no safe pre-positioning path` (`status: refused`, phase-09d) = the twin sweep found a pair within 25 mm somewhere along the 0–0.65 m travel at the arm's current posture (`rail_sweep.first_blocked_m` / `first_blocked_pair`) AND no candidate posture (scene keyframe, `<arm>_home`) is reachable by a rail-position-agnostic path: fold the arm toward the factory-zero posture in xArm Studio (joints 2–7 near 0; or move the other arm) and re-open Home rail — nothing was written. (`Current posture blocks the sweep — pre-positioning planned` is NOT a refusal: confirm and the arm moves first; an older runtime shows `Sweep blocked — homing refused` instead.) 409 `clear errors first` → **Clear errors** first; 409 `end the session first` → end the hardware session; 409 `needs the digital twin` → the lab config lacks `digital_twin_scene` or the runtime venv lacks the sim extra. `ok: false … the arm moved since the sweep was checked` → keep the arm still between the dry run and the confirm. `ok: false … on_zero still 0` after the 30 s SDK wait → the track never reached its zero switch: check the track cable / `hardware_monitor.arms[].rail_*` registers, **Clear errors**, retry. UI `no answer after 60 s` → read the card's rail pill; the runtime may still have finished. While homing the arm reads `stale` + `maintenance_busy` and `POST /api/session` is 409. |
| after a hardware session an arm is not back at `state 4` / brakes not engaged | `XArmDriver.disconnect()` ends with `set_mode(0)` → `set_state(4)` → `motion_enable(False)` (phase-09c D6) and the track keeps its homed flag. Check `hardware_monitor.arms[].state` once the monitor resumes; if the box still reports enabled, the disconnect writes failed (runtime log) — disable it from xArm Studio, never leave the cell enabled unattended. |
| rail-homing job `failed` (phase-09d; the sheet marks a phase red, toast `<Arm> · rail homing job failed during <phase>: …`, `GET /api/hardware/arms/<id>/maintenance/last` → `ok: false`) | the runtime tore the job down (arm stopped + braked where it was, monitor resumed, `maintenance_busy` cleared — nothing half-connected). Read the detail: `arm moved since the sweep` (> 0.02 rad between dry run and confirm — keep it still), `session slipped in` / `rail homing in progress` (retry), a driver fault or the gate holding during `positioning` (30 s or 3× the estimate; the posture must land within 0.05 rad — an obstacle / the other arm is in the way: check the overlay, fold in Studio), `on_zero still 0` after `home_rail()` (track cable / registers, **Clear errors**, retry), register verification (`rail_homed` / `rail_enabled` not both true). The arm stays wherever the job stopped it — look before re-opening Home rail; the next dry run plans from that posture. |
| red `C<code>` chip on a Hardware-tab arm card (the Perception Arm's `C19` until 2026-09-05; `hardware_monitor.arms[].error_code != 0`) | a controller error is latched in the box. Click **Clear errors** on the card (phase-09b; `POST /api/hardware/arms/<id>/maintenance {"op":"clear_errors"}` = `clean_error` + `clean_warn` on the read-only monitor — no enable, no motion, no confirm dialog). Toast `<Arm> · errors cleared`; the chip clears with the next monitor sample. `C19` (End Effector Communication Error: the box expects an end effector on the tool RS-485 bus, the Perception Arm has none) returned after every clear until xArm Studio → Settings → Externals → End Effector → **None** (no SDK write for it) — done 2026-09-05, both boxes read `error_code` 0 since. Inside a hardware session the card buttons are disabled (`Use the Cockpit`): use the Cockpit fault banner's **Clear errors & resume**, then re-grip the clutch. 409 `… needs the read-only monitor connected` = box off / monitor paused; `ok: false … re-latched right after clearing` = a persisting hardware fault (cable, e-stop). |
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
| `GET /api/dora` → `enabled: false` / `external.state: disabled` although `DORA_BIND_HOST` was set | re-render and restart; `bind_host` was `0.0.0.0` or an arm-link address (the runtime refuses both), or the interface name is not up (`ip -4 addr show wlp38s0`). The token file is `<dora.var_dir>/.dora-token`. A dead remote daemon makes the coordinator answer 429 for ~50 s. |
| Online DAgger sheet: Start disabled / `POST /api/session` 409 (phase-14) | read the reason: `no external policy attached (...)` = no node / no `spec` heartbeat within 3 s (start the policy node, S8.5); `no Online DAgger trainer attached (the policy node does not report the online_dagger capability)` = node started without `--online-dagger`; `Online DAgger session '<s>' already exists - resume it or pick another name` (the sheet offers Resume) / `... not found` (resume of a name that does not exist) / `session.json is unreadable - fix or remove it`; `dataset 'online_dagger/<s>' is being exported - retry in a moment`; `hardware sessions support teleop and data collection only` = Online DAgger is sim-only until the operator admits it (D7). A trainer whose OWN config needs an offline dataset (the PRO-DAgger reference: `offline_dataset` under `~/data/bc_demo/<name>`) reports that as `trainer_status.state: error` — record demonstrations first, the runtime does not check it. Once running: `episode_new` refused with `waiting for the trainer to report ready (...)` until the trainer's first `ready` for this session, `training in progress (...)` while it trains, `trainer error: ...`, `no Online DAgger trainer attached` when its status went stale — expected. |
| Online DAgger session stuck in `WAITING FOR TRAINER` although the trainer says ready | the trainer's `trainer_status` does not echo the runtime's `session_id` (15-online-dagger §3; `null` counts as alive only) — fix the trainer (the shipped `OnlineDaggerLoop` / `FakeTrainer` do echo it); also check `spec` heartbeats are < 3 s apart (`telemetry.external.state`). |
| `GET /api/gello` → `status: no_backend` (GELLO sheet: leader pill grey, Start disabled; phase-15, 2026-09-09) | one of three: (a) the runtime venv lacks the `gello` extra — `uv sync … --extra gello` (S3 / S9); `.venv/bin/python -c "import dynamixel_sdk, serial"` must work; (b) `gello.backend` is `none` in the rendered YAML — `GELLO_BACKEND=dynamixel`, re-render, restart (S4); (c) the servos are unpowered or answer none of the scanned rates — the adapter enumerates fine without them (`lsusb -d 0403:6014`, `ls /dev/serial/by-id/`) but the broadcast ping gets no reply at 57600 / 1M / 2M / 3M / 4M: check the servo power supply, then the ids (`gello.joint_ids` 1–7, `gripper_id` 8) and set `GELLO_BAUD` once known (16-gello §16 item 1 — this was the bus's state on 2026-09-09). |
| `GET /api/gello` → `status: stale` (`age_s` growing, `rate_hz` 0; Cockpit `NO LEADER`, the follower holds) | the bus stopped answering mid-run: USB cable / adapter unplugged (`ls /dev/serial/by-id/` empty, `dmesg -w` shows `ftdi_sio … disconnected`), servo power lost, or a servo reset. The reader restarts with backoff by itself; the follower HOLDS the last command (`no_leader`) and re-engages automatically once fresh samples are within the engage tolerance (16-gello §6.1). Replug / re-power; no restart needed. |
| `GET /api/gello` → `status: error`, log `Permission denied: '/dev/ttyUSB0'` | the runtime account is not in `dialout` (`id mavis`; `sudo usermod -aG dialout mavis`, then restart `user@<uid>` so the manager carries the group) or the udev rule is missing (`ls -la /dev/ttyUSB0` must read `root dialout 0660`; `FORCE_UDEV=1 bash scripts/deploy/install-system-deps.sh`, S5). A lingering account gets nothing from `TAG+="uaccess"` — only the GROUP fallback counts. |
| leader `rate_hz` ≈ 30 instead of ≈ 100; runtime log `WARNING … latency_timer 16 ms` at connect | the ftdi_sio `latency_timer` rule did not apply (it fires on `add` only): `cat /sys/bus/usb-serial/devices/ttyUSB0/latency_timer` → 16. Replug the adapter after installing the S5 rules, or once by hand `echo 1 \| sudo tee /sys/bus/usb-serial/devices/ttyUSB0/latency_timer`, then restart the runtime. 16 ms per USB transfer caps eight servos at ~30 Hz — the follower still works but lags. |
| GELLO sheet: `collides: <a> ↔ <b> at N mm` / `POST /api/session` 409 `GELLO posture collides: <a> / <b> at <mm> mm - move GELLO and retry` | by design (16-gello §0 item 5, D4): the leader's posture, placed on the kitchen twin with the Perception Arm at its hold posture, hits an appliance / the table / the other arm — nothing moved. Move GELLO until the preview reads `clear` (the PNG tints the colliding bodies red), then Start. `joint_limit` = the leader is outside the xArm's joint range; `not_calibrated` → S8.1c; `GELLO leader not available (…)` → the rows above. |
| Hardware session started from a profile but the arms are still at the measured posture; amber `SESSION — start_from refused: <Arm> faulted (controller state <n>, code C<k>) - use Clear errors & resume, then Go to profile` in the Cockpit | 2026-09-08 evening: a controller fault (or a RECOVERING arm whose inputs are still held) outlasted `hardware_session.start_from_fault_grace_s` (3.0 s) — nothing moved, the session is RUNNING. Do what the banner says: **Clear errors & resume**, then Cockpit → profile row → **Go to profile** (twin-planned, gated, any input cancels). Before the grace existed the one-tick RECOVERING right after enabling refused the plan silently (03:25 / 18:44 logs). |

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

2026-09-08 起（phase-12 / 13 / 14，开发树中尚未提交、真机未跑）：示教数据在 `~/data/bc_demo/<name>`、Online DAgger session 在
`~/data/online_dagger/<session>/{session.json,rollouts/}`（运行 runtime 的账号的 HOME，用户决定放在 `var/` 之外，渲染脚本不改它们，
一并备份；trainer 自己的产物由它放在旁边，runtime 不读；上午的 `~/data/pro_dagger` 从未发布）；`DORA_BIND_HOST=wlp38s0` 渲染才打开
dora 外部接口（端口 6113 / 53391 / 7447，绝不 `0.0.0.0`）；Online DAgger 的训练（任何 DAgger 变体，PRO-DAgger 只是 policy 仓的参考实现）
在 policy 仓自己启动的 `mavis-policy-node --online-dagger <fake|pkg.mod:make_trainer> [--trainer-config …]` 进程里（S8.5），skill 用
`curl -s http://<lab-host>:8765/api/online_dagger/skill.tgz | tar xz -C ~/.claude/skills/` 安装（→ `mavis-online-dagger-trainer/`）；
改配置或升级后**必须重启** runtime。

2026-09-09：phase-12 / 13 / 14 已于 05:46 提交推送（ws e16d2c1，`UPDATE=1` 即可部署）；phase-15 **GELLO Manipulation**（被动 GELLO leader 臂在
关节空间驱动 Manipulation Arm、Perception Arm 跟随外部 viewpoint 节点、厨房孪生 `mavis_v2_kitchen`、真机放开；契约 `docs/design/16-gello.md`）
实施中、未提交。落地时：runtime `uv sync … --extra gello`（S3 / S9）；udev `0403:6014` → `dialout` + ftdi_sio `latency_timer` 1 ms
（本机已有规则文件，须 `FORCE_UDEV=1 bash scripts/deploy/install-system-deps.sh` 重跑，S5）；渲染
`GELLO_BACKEND=dynamixel GELLO_USB_SERIAL=FTAKROCJ TWIN_OVERLAY_SCENE=mavis_v2_kitchen`（S4）后重启；舵机通电后按 S8.1c 标定
（`POST /api/gello/calibrate {op: match_arm}`）；`*_align` 叠加核对厨房箱体（±3 cm）；排障见 S11（`no_backend` / `stale` / 权限 / `latency_timer` 16）。
