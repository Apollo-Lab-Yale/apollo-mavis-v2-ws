# MAVIS v2 — deployment and operations guide (lab machine `apollo-pc-1`)

Audience: anyone standing at the lab machine who has to (re)deploy or operate the
MAVIS v2 stack under the **shared operations account `mavis-v2`**, without touching a
developer's account. Every command is copy-pasteable; the layout below was deployed and
checked on the machine on 2026-09-09 (Ubuntu 22.04.5, systemd 249, NVIDIA 580.173.02,
PulseAudio 15.99).

On this machine the ops account is `mavis-v2`, and it **already exists** (uid 1001, home `/home/mavis-v2`, in group
`sudo`) and its admin password is **`ApolloLab#`** — published here on the operator's
explicit instruction, 2026-09-09, because everyone with this repo is in the lab. So the
account is reachable three ways: a desktop login, `ssh mavis-v2@localhost`, or
`sudo -iu mavis-v2` / `su - mavis-v2` from another account.

**Day-to-day operation is in the workspace README** ("Running the cell"): start / stop,
where data lives, how to update. This file is first-time install, the details behind each
step, and troubleshooting.

**No account name or home path is hard-coded anywhere in this repository.** Every path
below is written as the variable the scripts actually use — `$OPS_ROOT` (the ops checkout),
`$DATA_ROOT` (`$OPS_ROOT/var`), `$OPS_HOME`, `$DEV_USER` — or, inside a shell block that
runs as the ops account, as `~/…`. The systemd unit uses systemd's own `%h`, so it carries
no account name either. `mavis-v2` and `xiatao` appear only as *this machine's* values:
`OPS_USER=mavis-v2`, `OPS_ROOT=~mavis-v2/apollo-mavis-v2-ws`, `DATA_ROOT=$OPS_ROOT/var`, and
`xiatao` as the developer account these notes were written from. Point the knobs elsewhere
and every step still works.

The matching scripts live in `scripts/deploy/` (idempotent, `set -euo pipefail`,
print what they do); every step below shows both the script and the commands it
runs. Defaults shared by all scripts are in `scripts/deploy/_common.sh` and can be
overridden from the environment (`OPS_USER`, `OPS_HOME`, `OPS_ROOT`, `DATA_ROOT`,
`LAB_CONFIG`, `LAB_ENV`, `WS_URL`, `WS_REF`, …). The **pre-2026-09-09 FHS layout is still
reachable** that way — `OPS_USER=mavis OPS_ROOT=/opt/apollo-mavis-v2
DATA_ROOT=/var/lib/apollo-mavis-v2` reproduces it, and `create-mavis-account.sh` then
creates the setgid + default-ACL trees it needs (requires `acl`). It is a fallback, not
the recommended path: everything below assumes one account with everything in its home.

Before you start — **read this first**:

1. The ops checkout is cloned from GitHub, **anonymously**. The workspace and all five
   sub-repos are public under `Apollo-Lab-Yale/`, every remote is HTTPS, and every git
   call in the deploy scripts carries `GIT_TERMINAL_PROMPT=0` so git can never fall back
   to a credential prompt. **No GitHub account is logged in on `mavis-v2`, and none
   should be** — there is no `~/.git-credentials`, no `~/.config/gh`, no credential
   helper. A dependency that goes private must be made public again, not authenticated
   (this is why `apollo-mavis-v2-runtime` was flipped to public on 2026-09-09). The
   checkout gets only what is **pushed and pinned**: a sub-repo commit reaches
   the ops machine only when it is on that repo's `origin/main` AND referenced by a pushed
   workspace commit. Before S3 and before every S9 upgrade the developer pushes **all five**
   repos in dependency order — `core` → `sim` / `hardware` → `runtime` → `ui` (after
   `npm run gen:sync && npm run gen:types`, so the generated types match core's schemas) —
   then bumps the five pointers in the workspace (`git add apollo-mavis-v2-* && git commit
   && git push`). Check in the developer tree: `git status -sb` in the ws and in every
   sub-repo shows no `[ahead N]`, and `git submodule status` has no line starting with `+`
   (checkout ahead of the pinned commit) or `-` (not initialised). On the ops side
   `git -C $OPS_ROOT submodule status` must list the same five hashes.
   No commit hashes are quoted here on purpose — they rot; read the pins from
   `git -C <ws> submodule status` and compare, and `update.sh` warns for you when a
   submodule sits off its pin. If core lags runtime, the S4 render fails validation; if ui
   lags core, `gen:check` fails.
2. Real-arm sessions landed with **phase-09c / 09d** (2026-09-05; contracts
   `docs/prompts/phase-09c-hardware-session.md` + `phase-09d-rail-homing-planning.md`) and
   **first ran on the real boxes on 2026-09-05** (`docs/design/02-hardware.md` §16: three
   false alarms of our own, fixed the same day; fakes only until then): `POST /api/session
   kind=hardware` is teleop-only, ALWAYS brings up both arms (phase-09d: `SessionSpec.arms`
   must be every configured arm — no per-arm switch on the Hardware tab) at `speed_scale`
   (Hardware tab 10 / 50 / 100 %, default 100 % since 2026-09-08 evening — the operator's call,
   `hardware_session.default_speed_scale: 1.0`, pushed 2026-09-09; 50 % from 2026-09-07; the
   rendered lab config keeps whatever value it was rendered with until re-rendered (S4)
   AND the runtime restarted; was 10 / 30 / 100 %, default 10 %), and is refused (409 `rail not homed`) while either linear track is unhomed —
   the operator homes it first with the arm card's **Home rail**, the ONE maintenance action that moves
   hardware (twin-gated; since phase-09d it may first drive the arm along a twin-planned,
   rail-position-agnostic path to a folded posture at 10 % and then hold it there, S7). The
   first live run followed the 09c contract's 真机验收步骤 (as amended by its 09d header note)
   with the user present and the e-stop in hand — still the procedure after every runtime
   change (S7).
   Also running against the real cell: arm reachability probes, the read-only controller
   monitor + twin overlays, the RØDE microphone preview, Vive tracker teleop + calibration
   wizard, the two RealSense previews (mapped to the arms by RealSense device serial, S4;
   colour + aligned depth through librealsense since 2026-09-11), and
   full **sim** sessions on the `mavis_v2` digital twin.
3. Exactly **one** process may own the Watchman dongle, the microphone capture and the
   arms (S8). The developer's runtime on `:8765` owns them right now; the ops service
   cannot start on the same machine until that instance is stopped or moved (S8.3).

---

## S0. What you get

```
                       browser  http://127.0.0.1:8765/  (or via ssh -L / tailscale)
                          │
   systemd --user (mavis-v2) │  mavis-runtime.service   (linger ON, autostart OFF: started by hand)
   ┌──────────────────────┴──────────────────────────────────────────────────────────┐
   │ ~/apollo-mavis-v2-ws/apollo-mavis-v2-runtime/.venv/bin/python -m apollo_mavis_v2_runtime
   │   --config ~/apollo-mavis-v2-ws/var/mavis_v2_lab.yaml    MUJOCO_GL=egl           │
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
| Workspace checkout (5 submodules, 4 venvs, uv interpreters in `.uv/python`, UI dist) | `$OPS_ROOT` | `mavis-v2:mavis-v2` — an ordinary clone in the account's home. No setgid, no ACL: other people work from their own clone and push through GitHub |
| Profiles, datasets, checkpoints, tracker calibration, libsurvive config, logs, pysurvive wheel staging | `$DATA_ROOT/{profiles,datasets,checkpoints,calibration,libsurvive,logs,wheels}` (gitignored `/var/*`; `dora/` appears once `DORA_BIND_HOST` is set) | `mavis-v2:mavis-v2` |
| Lab runtime config (rendered by S4 — no sudo, re-rendered by mavis-v2 alone in S9) | `$DATA_ROOT/mavis_v2_lab.yaml` | `mavis-v2:mavis-v2`, 664 |
| **Persistent render knobs** — `KEY=value` per line, sourced by `render-lab-config.sh` and re-used by `update.sh`, so an upgrade re-renders the same config (`HARDWARE_ARMED`, `HARDWARE_POLICY_MODES`, `TRACKER_YAW_DEG`, `LOG_LEVEL`, `CAMERA_SERIALS`, `DORA_BIND_HOST`). Not re-derivable — back it up | `$DATA_ROOT/lab.env` | `mavis-v2:mavis-v2`, 664 |
| **Demonstrations and Online DAgger sessions (2026-09-08, operator decision — outside `var/` and outside `/var/lib`; the morning's `~/data/pro_dagger` name never shipped)**: `datasets.namespaces` in the runtime config maps `bc_demo/<name>` → `~/data/bc_demo/<name>` and `online_dagger/<session>` → `~/data/online_dagger/<session>/{session.json,rollouts/}` (the trainer may add its own files there, e.g. `trainer/` — the runtime never reads them); `~` is the HOME of the account that runs the runtime, so under the service it is `$OPS_HOME/data/...`. Only the generic `datasets_root` (legacy `apollo/...` data) stays under `$DATA_ROOT/datasets`. `GET /api/datasets/layout` prints the effective roots | `~/data/bc_demo`, `~/data/online_dagger` | the runtime account (`mavis-v2`); created on first use (`mkdir -p`) |
| netsetup system state | `/etc/apollo-mavis-v2/nic_map.json` (written by root) | root |
| Service unit (installed, **not** `enable`d — see S6) | `$OPS_HOME/.config/systemd/user/mavis-runtime.service` | mavis-v2 |
| Logs — `journalctl --user -u mavis-runtime` (as the ops account) **and** the runtime's own rotating `runtime.log` (20 MB × 10; `logging:` block, `LOG_LEVEL` render knob, 2026-09-07) beside `runtime.stderr.log` (raw stderr: libsurvive / MuJoCo C prints). netsetup logs to `/var/log/mavis-netsetup.log` | `$DATA_ROOT/logs/` | `mavis-v2:mavis-v2` |

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
   runtime venv ships CUDA 13 wheels), a system `pyrealsense2` — since 2026-09-11 the wheel
   (`pyrealsense2>=2.54`, 2.58.4 on this box) rides the runtime's `hardware` extra and `uv
   sync` installs it; until 2026-09-10 no pyrealsense2 was installed at all because the
   cameras were opened as v4l2/OpenCV (history, S4 "Cameras").

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
   `$OPS_ROOT/.uv/python` (`UV_PYTHON_INSTALL_DIR`, gitignored
   `/.uv/`). In this layout checkout and interpreters share one owner, so the EACCES trap
   is gone — `install-stack.sh` only warns when `UV_PYTHON_INSTALL_DIR` sits in a home
   while `OPS_ROOT` does not, i.e. in the legacy `/opt` layout. Ubuntu's apt `nodejs` is
   12.22.9 — too old. `install-stack.sh` installs nvm's node 22 and, since 2026-09-09,
   appends a delimited nvm block to the ops account's `~/.bashrc`, so a terminal there
   agrees with what the build used (before that a hand-run `npm ci` picked up node 12).

4. inotify: `/etc/sysctl.d/60-inotify.conf` already raises
   `fs.inotify.max_user_watches=524288` system-wide (the script re-creates it if missing).

5. `librealsense2-utils` — keep it installed: `rs-enumerate-devices -s` is how the RealSense
   DEVICE serials in the camera config are read and `-c` the colour intrinsics (S4 "Cameras").
   Until 2026-09-10 it was also what woke a cold-booted D435i so the plain-UVC reader got
   frames; since the cameras are opened through librealsense itself (2026-09-11) that wake is
   history, still wired in for a `kind: v4l2` entry (S11). It comes from Intel's apt
   repository, not Ubuntu's.

### UFACTORY Studio (the xArm desktop client)

Several steps below tell you to use it — clearing the Perception Arm's `C19` for good,
folding an arm to factory zero when **Home rail** refuses, disabling a box by hand — so
install it once per account that needs it (an AppImage integrates per user, not system-wide):

```bash
bash ~/apollo-mavis-v2-ws/scripts/deploy/install-ufactory-studio.sh /path/to/ufactory-studio-*.AppImage
```

It copies the AppImage into `~/Applications`, makes it executable and adds a menu entry
through AppImageLauncher's `ail-cli` (installed on this machine) or a hand-written
`.desktop` file. Electron needs `--no-sandbox`; both paths add it. No sudo, idempotent.
Download: <https://www.ufactory.cc/ufactory-studio/>. **Exactly one version is kept on this
machine — `ufactory-studio-client-linux-1.0.2`** (operator decision 2026-09-09; 1.0.1 was
removed from every account, do not re-install it). Control-box firmware: v1.12.10.

**Never open Studio's "Live control" while a MAVIS session is running** — two masters on one
control box. Studio also holds a TCP connection to the box while it is merely open, so close
it before a session rather than leaving the window behind.

---

## S2. The operations account: groups and linger (sudo)

The account **already exists** on this machine, so this step only tops it up. Script:
`bash scripts/deploy/create-mavis-account.sh` — idempotent; it creates nothing under
`/opt` or `/var/lib` when `OPS_ROOT` is inside the account's home (`install-stack.sh` and
`install-services.sh` make the `var/` subdirectories later, as the account itself, with no
sudo). `DEV_USER=<name>` is only meaningful in the legacy shared-FHS layout, where it adds
that developer to the ops group; it defaults to nobody. Manual equivalent:

```bash
# The account exists: uid 1001, home /home/mavis-v2, in group sudo, password ApolloLab#.
# On a FRESH machine only:
#   sudo useradd --create-home --user-group --shell /bin/bash --comment "MAVIS V2" mavis-v2
#   sudo passwd mavis-v2 && sudo usermod -aG sudo mavis-v2
sudo usermod -aG render,video,plugdev,input,audio,netdev,dialout mavis-v2
sudo loginctl enable-linger mavis-v2              # user manager at boot -> XDG_RUNTIME_DIR=/run/user/1001, PulseAudio socket
sudo install -d -m 755 -o root -g root /etc/apollo-mavis-v2   # netsetup's nic_map.json only (S5)
id mavis-v2; loginctl show-user mavis-v2 -p Linger
```

Nothing here is shared with a developer account any more: the checkout is an ordinary
clone in `/home/mavis-v2`, both homes stay 0750, and data moves between them with
`sync-data-from-dev.sh` (S10) rather than through a group-writable tree.

Why each group (checked against real node ownership, `ls -la`):

| group | device | why |
|---|---|---|
| `render` | `/dev/dri/renderD128`, `renderD129` (`root:render 0660`) | MuJoCo EGL opens them (the live runtime holds both) |
| `plugdev` | dongle `/dev/bus/usb/009/002` (`root:plugdev 0660`), RealSense hidraw | `60-apollo-teleop-input.rules`; librealsense rules |
| `input` | gamepad `/dev/input/event17` (`root:input 0660`) | same rule file |
| `audio` | `/dev/snd/*` (`root:audio 0660`) | mavis-v2's own PulseAudio must open the RØDE card |
| `netdev` | — | netsetup's polkit `.pkla` grants NetworkManager control to `unix-group:netdev` |
| `video`, `dialout` | `/dev/dri/card*`, serial | not needed today; harmless |

The developer's devices work through `TAG+="uaccess"` ACLs (`user:xiatao:rw-`) that
logind grants to the **seat owner**. When someone logs in at the desktop as `mavis-v2` it
*is* the seat owner and gets those ACLs; the boot-time lingering service does not own a
seat, so it relies entirely on the MODE/GROUP fallbacks above. Both paths are covered.
**Verify on first deploy**: from a mavis-v2 shell, `ls -la /dev/bus/usb/$(lsusb -d 28de:2101 | awk '{printf "%s/%s", $2, substr($4,1,3)}')` and `test -r /dev/dri/renderD128 && echo ok`.

Group changes apply to new sessions only: after S2, `sudo systemctl restart user@$(id -u mavis-v2).service`
(= `user@1001.service`, or reboot) so the user manager itself carries the groups. Do not
restart it while someone is logged in as `mavis-v2` — have them log out and back in.

The password is **`ApolloLab#`** and the account is a sudoer, so a desktop login,
`ssh mavis-v2@localhost`, `su - mavis-v2` and `sudo -iu mavis-v2` all work. One catch:
`su -` / `sudo -iu` do **not** set up the account's D-Bus, so `systemctl --user` fails
there with *"Failed to connect to bus"* until you
`export XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus`
(what the scripts' `ops_user_env` helper does). A real login needs none of that.

---

## S3. Clone and build in the ops account's home (no sudo, no GitHub login)

Run **as `mavis-v2`**. The interpreters go under
`$OPS_ROOT/.uv/python` (`UV_PYTHON_INSTALL_DIR`), and the scripts
still pass `safe.directory=*` to git — harmless here, where one account owns everything;
it exists because Ubuntu's git 2.34.1 (CVE-2022-24765 patches) refuses to touch a checkout
owned by another uid ("detected dubious ownership"), which only happens in the legacy
shared layout. (`_common.sh` appends to `GIT_CONFIG_COUNT` rather than clobbering it.)
Script: `bash scripts/deploy/install-stack.sh` — you need the script before the clone
exists, so run the workspace's copy from a staging directory with
`OPS_ROOT=$OPS_ROOT`. That path must not exist, be empty, **or
already be a checkout** (the script reuses an existing `.git`).

```bash
sudo -iu mavis-v2      # or log in as mavis-v2 (password ApolloLab#)
curl -LsSf https://astral.sh/uv/install.sh | sh && export PATH="$HOME/.local/bin:$PATH"
GIT_TERMINAL_PROMPT=0 git clone --recurse-submodules --branch main \
  https://github.com/Apollo-Lab-Yale/apollo-mavis-v2-ws.git ~/apollo-mavis-v2-ws
bash ~/apollo-mavis-v2-ws/scripts/deploy/install-stack.sh
```

`GIT_TERMINAL_PROMPT=0` is deliberate, not decoration: every repo here is public, so a
credential prompt can only mean a wrong remote or a repo that went private — and the fix
for that is to make it public again, never to log a GitHub account into this machine.

What it does (manual equivalent, in order):

```bash
cd ~/apollo-mavis-v2-ws
export UV_PYTHON_INSTALL_DIR=~/apollo-mavis-v2-ws/.uv/python                        # shared interpreters (gitignored /.uv/) — needed by EVERY later uv command here
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'   # only matters in the legacy shared layout
GIT_TERMINAL_PROMPT=0 git submodule update --init --recursive    # the pinned commits (anonymous HTTPS)
uv python install 3.10 3.12                       # hardware pins 3.10, runtime needs >= 3.12 -> ~/apollo-mavis-v2-ws/.uv/python/cpython-*
(cd apollo-mavis-v2-core     && uv sync --locked --no-dev)
(cd apollo-mavis-v2-sim      && uv sync --locked --no-dev)
(cd apollo-mavis-v2-hardware && uv sync --locked --no-dev)     # needs GitHub: xarm-python-sdk git pin d911319c
(cd apollo-mavis-v2-runtime  && uv sync --locked --no-dev --extra sim --extra hardware --extra audio)  # ~5 GB (torch cu130, lerobot, mujoco)
# pysurvive is OUT of uv.lock and every plain `uv sync` removes it again -> install last:
mkdir -p third_party/wheels && cp -n ~/apollo-mavis-v2-ws/var/wheels/pysurvive-*-cp312-*.whl third_party/wheels/   # from the S2 staging dir
(cd apollo-mavis-v2-runtime  && uv pip install --no-deps --force-reinstall ../third_party/wheels/pysurvive-1.1.204-cp312-cp312-linux_x86_64.whl)
apollo-mavis-v2-runtime/.venv/bin/python -c "import pysurvive; print(pysurvive.__file__)"
# UI: node 22 via nvm (per user), package-lock.json is authoritative (pnpm-lock.yaml is stale)
(cd apollo-mavis-v2-ui && npm ci --no-audit --no-fund && npm run gen:check && npm run build)   # -> dist/
```

The pysurvive wheel: it is gitignored (`/third_party/wheels/`) and exists only in the
developer's tree at
`~$DEV_USER/projects/apollo-mavis-v2-ws/third_party/wheels/pysurvive-1.1.204-cp312-cp312-linux_x86_64.whl`
(2.86 MB, self-contained: bundles `libsurvive.so.0.3` + plugins, needs no
`LD_LIBRARY_PATH`/`SURVIVE_PLUGINS`). The ops account cannot read another home
(0750, so a bare `PYSURVIVE_WHEEL=~$DEV_USER/…` fails from an ops shell). The staging
directory now lives **inside the checkout**, so staging can only happen **after** the
clone: the first `install-stack.sh` pass warns `no pysurvive wheel`, you drop the wheel in,
and you re-run. `mavis-v2` is a sudoer, so it can fetch the wheel itself:

```bash
# as mavis-v2, after the clone:
sudo install -m 664 -o mavis-v2 -g mavis-v2 \
  ~$DEV_USER/projects/apollo-mavis-v2-ws/third_party/wheels/pysurvive-1.1.204-cp312-cp312-linux_x86_64.whl \
  ~/apollo-mavis-v2-ws/var/wheels/
bash ~/apollo-mavis-v2-ws/scripts/deploy/install-stack.sh    # picks it up, installs it last
```

Equivalently the developer can hop it through `/tmp`, or pass
`PYSURVIVE_WHEEL=/readable/path.whl`.

`install-stack.sh` takes `PYSURVIVE_WHEEL=/path` if given, otherwise the newest
`pysurvive-*-cp312-*.whl` in `$OPS_ROOT/third_party/wheels/` or
`$DATA_ROOT/wheels/`, copies it next to the venvs and installs it. If the
wheel was staged only after a first pass (which then just warned `no pysurvive wheel`),
re-run the script: it is idempotent and skips everything already in place. Or rebuild it
(network + build deps; the libsurvive source used before lived in `/tmp` and is gone):
`BUILD_PYSURVIVE=1 bash scripts/deploy/install-stack.sh` runs
`scripts/tracker/02-build-pysurvive.sh` with `LIBSURVIVE_SRC=$OPS_ROOT/third_party/src/libsurvive`
(pinned commit `f1e6eddb…`, full clone: `setup.py` runs `git describe`).

Script knobs: `UPDATE=1` (pull first, S9), `WITH_DEV=1` (keep pytest/ruff), `SKIP_UI=1`,
`PYSURVIVE_WHEEL=/path`, `REINSTALL_PYSURVIVE=1`, `UV_PYTHON_INSTALL_DIR=…` (default
`$OPS_ROOT/.uv/python`, exported by `_common.sh`; keep it shared — the script
warns if it points into a home. For ad-hoc `uv sync`/`uv run` in the ops tree first
`source $OPS_ROOT/scripts/deploy/_common.sh` or export it by hand, otherwise uv
does not find the interpreters and downloads private ones into `~`), `UV_CACHE_DIR=…` (a
fresh account re-downloads ~5 GB; point it at a shared, writable cache to avoid that).

---

## S4. Lab config `$DATA_ROOT/mavis_v2_lab.yaml`

Script: `bash scripts/deploy/render-lab-config.sh`, as `mavis-v2` — **no sudo**: the file
lives in the ops account's own `var/`, not in `/etc`, precisely so it can re-render alone in S9 (`LAB_CONFIG=/etc/…/x.yaml` still
works and then falls back to sudo for the final `install`; `DRY_RUN=1` prints instead). It
loads the repo config `apollo-mavis-v2-runtime/configs/mavis_v2.yaml`, applies the overrides
below, **validates the result with the runtime's own `RuntimeConfig`** (so it needs the ops
runtime venv from S3), and installs it with mode 664. Comments are dropped by the YAML dump —
the repo file stays the documented reference and the rendered header lists every override.

Exact diff versus the repo config (values, comments stripped):

```diff
-ui_dist: null
+ui_dist: ~/apollo-mavis-v2-ws/apollo-mavis-v2-ui/dist
-profiles_dir: ${APOLLO_HOME}/var/profiles
-datasets_root: ${APOLLO_HOME}/var/datasets
-checkpoints_root: ${APOLLO_HOME}/var/checkpoints
-calibration_dir: ${APOLLO_HOME}/var/calibration
+profiles_dir: ~/apollo-mavis-v2-ws/var/profiles
+datasets_root: ~/apollo-mavis-v2-ws/var/datasets
+checkpoints_root: ~/apollo-mavis-v2-ws/var/checkpoints
+calibration_dir: ~/apollo-mavis-v2-ws/var/calibration
 control:
+  rail_in_ik: false                         # 2026-09-03 lab decision: rail excluded from IK, trackpad/arrows slide the arm
 tracker:
-  backend: fake
+  backend: libsurvive
-  libsurvive_args: ["--lighthousecount", "4", "--globalscenesolver", "0", "--disable-calibrate", "1"]
+  libsurvive_args: ["--lighthousecount", "3", "--globalscenesolver", "0", "--disable-calibrate", "1"]
-  libsurvive_config_path: ${APOLLO_HOME}/var/libsurvive/config.json
+  libsurvive_config_path: ~/apollo-mavis-v2-ws/var/libsurvive/config.json
-  yaw_deg: 0.0
+  yaw_deg: 116.3                            # ESTIMATE (2026-09-03); redo the Yaw wizard, it persists to calibration_dir
```

Unchanged because the repo already has the lab values: `host: 127.0.0.1`, `port: 8765`,
arm IPs `grip` 192.168.1.201 / `view` 192.168.2.219 (gripper `xarm_g2`, `view`
`microphone: true`), the two wrist cameras (`grip_wrist` RealSense serial `327122074467`,
`view_wrist` RealSense serial `243522071002`; `kind: realsense`, colour + aligned depth,
640×480 @ 30 since 2026-09-11 — the 2026-09-04..09-10 render carried `kind: v4l2`, `fourcc:
YUYV` and the USB iSerials; see "Cameras" below), `microphone.enabled: true` with
`source_match: NT-USB Mini`,
`hardware_probe` on 502, the phase-09a `hardware_monitor` / `twin_overlay` blocks, the wrist
cameras' D435i colour `intrinsics` (2026-09-04), the phase-09b per-arm controller backstops
(`tcp_load_kg` / `tcp_load_cog_mm` / `collision_sensitivity`: `grip` 0.95 kg @ (0, 0, 60) mm,
`view` 0.55 kg @ (0, 0, 90) mm, sensitivity 3 — estimates accepted by the user on 2026-09-05 (the tools were not weighed); the
driver writes them at every session connect, the Hardware tab's **Apply safety settings** writes
them without a session), the phase-09c/09d `hardware_session` block (`armed: true` — the lab render is the ONLY config that
arms the real drivers, `HARDWARE_ARMED=false` renders a monitor-only config; `policy_modes: true` since
2026-09-12 — `HARDWARE_POLICY_MODES=true`, the operator's admission of POLICY-DRIVEN motion on the real arms
(inference / dagger sessions incl. Online DAgger, the action-column playback), repo default false, 15-online-dagger
D7 as amended, 04-runtime §5 / §11; unverified live — first trial at 10 % with a recorded episode through the
playback dialog; `default_speed_scale:
1.0` — the Hardware tab's speed picker is 10 / 50 / 100 %, default 100 %, since 2026-09-08 evening
(operator's call; 0.5 = 50 % from 2026-09-07; pushed 2026-09-09, so a fresh render carries it —
but an ALREADY rendered config keeps its old value until re-rendered AND the runtime restarted); `rail_flip: false` —
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

### `var/lab.env` — where the knobs are remembered (2026-09-09)

Knobs passed on the command line are forgotten the moment the shell exits, and `update.sh`
re-renders on every upgrade — so a knob that lives only in your shell history silently
disappears from the config at the next upgrade. **Put the persistent ones in
`$DATA_ROOT/lab.env`** (`LAB_ENV`), one `KEY=value` per line, no
shell logic. `render-lab-config.sh` sources it and prints which keys it picked up; anything
already exported in the environment still wins, so a one-off
`CAMERA_SERIALS=… bash render-lab-config.sh` behaves as typed.

What this machine keeps there: `HARDWARE_ARMED=true`, `HARDWARE_POLICY_MODES=true` (2026-09-12), `MIC_ENABLED=true`,
`TRACKER_BACKEND=libsurvive`, `LIGHTHOUSE_COUNT=3`, `TRACKER_YAW_DEG=116.3`,
`RAIL_IN_IK=false`, `LOG_LEVEL=INFO`, `EGL_DEVICE_ID=0`, with `CAMERA_SERIALS` and
`DORA_BIND_HOST` present but commented out. Back this file up (S10) — unlike the rendered
config it is not re-derivable from the repo.

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
- **`HARDWARE_POLICY_MODES`** (2026-09-12; default `false` = the repo's `hardware_session.policy_modes:
  false`). `true` renders `hardware_session.policy_modes: true`: the runtime admits `mode: inference` /
  `dagger` (incl. Online DAgger) on the real arms and the action-column playback inside a hardware
  session (04-runtime §5 / §10.8 / §11; 15-online-dagger D7 as amended). Operator decision — the lab
  keeps it `true` in `var/lab.env` since 2026-09-12. It changes NOTHING about the arming switch, the
  gate, the leash or the servo caps; with it false the old 409 names the knob. A running runtime needs
  a re-render AND a restart to see it. Policy-driven motion has not run on the real arms yet: first
  trial = a recorded episode through the playback dialog at 10 %, E-stop in hand.
- **`DORA_MACHINES="gpubox,laptop"`** (optional, only with `DORA_BIND_HOST`): comma list of
  remote consumer machine ids allowed to join; each gets the default `viewer` + `observer`
  placeholders in `dora.machines`. The policy node runs ON the lab machine (placeholder
  `policy`, machine `lab`) and is not listed here.
- **Not templated: `datasets.namespaces`** (phase-14, 15-online-dagger D5). The render still
  points the generic `datasets_root` at `$DATA_ROOT/datasets`, but the two mapped namespaces
  keep the repo values `bc_demo: {root: ~/data/bc_demo}` and `online_dagger: {root:
  ~/data/online_dagger, subdir: rollouts}` (2026-09-08 evening; the morning's `pro_dagger`
  namespace never shipped) — `~` expands in the runtime process, i.e. `$OPS_HOME/data/...`
  under the service, `~$DEV_USER/data/...` for a developer instance. That is the operator's
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

**Restart after every render or upgrade.** The runtime reads the config ONCE at start
(`systemctl --user restart mavis-runtime`; the script's last line says so). The same holds
for the developer's long-running instance, which holds whatever snapshot of the working trees
it started from — check its start time against the trees before believing a live symptom, and
re-render plus restart before concluding that a config change did not work. No PID is quoted
here on purpose; `ss -tlnp | grep 8765` and `ps -o lstart= -p <pid>` answer it in two commands.

```bash
bash ~/apollo-mavis-v2-ws/scripts/deploy/render-lab-config.sh          # -> ~/apollo-mavis-v2-ws/var/mavis_v2_lab.yaml
# stop-gap if the two camera tiles turn out crossed (see below): swap the serials without touching the repo
CAMERA_SERIALS="grip_wrist=243522071002,view_wrist=327122074467" bash ~/apollo-mavis-v2-ws/scripts/deploy/render-lab-config.sh   # RealSense DEVICE serials (2026-09-11), not USB iSerials
# turn the dora external interface on for policy nodes / LAN subscribers (phase-12; see the knobs above)
DORA_BIND_HOST=wlp38s0 bash ~/apollo-mavis-v2-ws/scripts/deploy/render-lab-config.sh
DORA_BIND_HOST=wlp38s0 DORA_MACHINES="gpubox" bash ~/apollo-mavis-v2-ws/scripts/deploy/render-lab-config.sh   # + one remote consumer machine
```

Cameras (**verify on first deploy**): since 2026-09-11 the runtime opens each wrist D435i
through **librealsense** (`kind: realsense`; `pyrealsense2` 2.58.4 from the runtime's
`hardware` extra, no system package) — colour rgb8 plus z16 depth aligned to colour at
640×480 @ 30 (`depth: true`, `align_depth_to_color: true`) — and finds it by the **RealSense
DEVICE serial** (core `CameraConfig.serial`; the serial `rs-enumerate-devices -s` prints), so
`/dev/video*` numbering and plug order do not matter. Two D435i are attached
(`lsusb -d 8086:0b3a` lists both units); the repo maps `327122074467 → grip_wrist`
(Manipulation Arm; USB iSerial 349643062582, firmware 5.17.0.10, USB bus 6 / PCI 29:00.3) and
`243522071002 → view_wrist` (Perception Arm; USB iSerial 322143060792, firmware 5.15.1, USB bus
4 / PCI 29:00.1). The RS device serial is NOT the USB iSerial (`lsusb -d 8086:0b3a -v | grep
iSerial`) that the 2026-09-04..09-10 configs carried, when the cameras were plain v4l2
colour devices (`kind: v4l2`, `fourcc: YUYV` because the RS colour node offers no MJPG, no
`pyrealsense2`); the two serial families were tied together on 2026-09-11 from pyrealsense2
`physical_port` → the sysfs `serial` of that USB device, and the result agrees with the
mapping the **operator confirmed on 2026-09-04** from the Hardware-tab tiles (the
pre-2026-09-04 config had the two serials the other way round — a guess, corrected from those
tiles). Probe on the real pair (service paused, both cameras at once, 8 s): 30.0 / 30.1 fps,
depth on every frame, 96 % (grip, table at 35–43 cm) / 91 % (view, 44 cm – 2.2 m) valid depth
pixels, `depth_scale` 0.001 m; the dora bridge publishes `cam_grip_wrist_depth` /
`cam_view_wrist_depth` (uint16 mm) next to the colour streams, datasets stay video-only. If a
camera is ever replaced or moved: cover one lens and watch the Welcome page → Hardware tab
tiles; if they are crossed, swap the two serials in `configs/mavis_v2.yaml` (developer: commit
+ push, then S9 re-render) or use the `CAMERA_SERIALS` stop-gap above until then (RS device
serials, as in the example). The script exits with an error for a camera id that is not in
the repo config, so a rename there cannot be ignored silently. An unplugged camera shows a
black tile with `live: false` and has no other effect. **Cold boot** (history of the v4l2
path): a D435i's colour UVC stream stayed silent after a reboot until librealsense had opened
the device once, so `OpenCVCamera` runs `rs-enumerate-devices -s` (librealsense2-utils, from
Intel's apt repo — present on apollo-pc-1) once per process before the first RealSense open;
with `kind: realsense` the pipeline IS that open and no wake is involved. Keep the tool
installed anyway — it reads the device serials and the colour intrinsics
(`rs-enumerate-devices -c`), and a `kind: v4l2` fallback still relies on it (S11).

### libsurvive lighthouse calibration (per account!)

Since 2026-09-06 the normal reader **also** passes `--configfile
tracker.libsurvive_config_path` (`devices/tracker.py`), so libsurvive reads/writes exactly
that file at teleop — no reliance on `$XDG_CONFIG_HOME/libsurvive/config.json`. The
calibration wizard still owns the same path for copy / back up / install and strips any
`--configfile` before adding its own temp copy (`CALIBRATION_ARGS`). With an explicit
`--configfile` the S6 symlink `$OPS_HOME/.config/libsurvive ->
$DATA_ROOT/libsurvive` is redundant (harmless; `install-services.sh` still
creates it and seeds `config.json` if missing — and `install-services.sh`'s own header
comment claims the opposite, that libsurvive ignores the config key; the CODE agrees with
this section, `devices/tracker.py` appends `--configfile` when it is absent, so the script
comment is the one that is wrong). The self-contained default is
`${APOLLO_HOME}/var/libsurvive/config.json` (04-runtime §14.1).

`install-services.sh` **seeds it for you** when `var/libsurvive/config.json` does not exist,
from the newest repo copy `configs/libsurvive/mavis_v2-lighthouses-*.json`
(`LIBSURVIVE_SEED=/path/config.json` overrides). That is the right default and what this
machine was deployed with on 2026-09-09: the repo copy is the KNOWN-GOOD calibration, while
a developer's live `~/.config/libsurvive/config.json` is whatever libsurvive last rewrote —
and it degrades on every run (extra lighthouse blocks, a station demoted, cm-scale wander;
13-tracker §6.1). Prefer a developer's copy only when you know it is a fresh, verified
calibration:

```bash
# as mavis-v2, only if the developer's copy is known good:
sudo install -m 664 -o mavis-v2 -g mavis-v2 ~$DEV_USER/.config/libsurvive/config.json \
  ~/apollo-mavis-v2-ws/var/libsurvive/config.json
# and refresh the repo reference copy (docs/design/13-tracker-teleop.md §6.1), in the developer tree:
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
   exists and originally pointed at a DEVELOPER's venv
   (`PYTHON=~$DEV_USER/projects/apollo-mavis-v2-ws/apollo-mavis-v2-hardware/.venv/bin/python`),
   `nic_map.json` holds both arms (`repair done rc=0`, both `[OK ]` in the log), both
   profiles are pinned to MAC + interface, and `netdev` contains `xiatao`. That hook depends
   on the developer's checkout: if that venv is moved or re-synced, boot-time NIC repair
   silently logs `python missing` and stops. Re-running install is therefore **required**
   to re-point the hook at the ops venv (it also adds `mavis-v2` to `netdev`, which S2 did
   already). **`mavis-v2` is itself a sudoer**, so run this from a `mavis-v2` shell — no
   hopping back to a developer account. Done on 2026-09-09: the hook now bakes in
   `$OPS_ROOT/apollo-mavis-v2-hardware/.venv/bin/python`, so NIC
   repair no longer depends on a developer's checkout existing. With the arms on:

   ```bash
   PY=$OPS_ROOT/apollo-mavis-v2-hardware/.venv/bin/python
   sudo $PY -m apollo_mavis_v2_hardware.netsetup install --yes --python $PY --user mavis-v2 \
     --arm grip=192.168.1.201 --arm view=192.168.2.219
   # check WITH sudo: /etc/polkit-1/localauthority is root-only (0700), so a non-root check
   # cannot see the .pkla and reports it as "not verified" (a note, not a problem)
   sudo $PY -m apollo_mavis_v2_hardware.netsetup install --check --python $PY --user mavis-v2 \
     --arm grip=192.168.1.201 --arm view=192.168.2.219
   $PY -m apollo_mavis_v2_hardware.netsetup verify --arm grip=192.168.1.201 --arm view=192.168.2.219
   grep -q "^PYTHON=$PY$" /etc/NetworkManager/dispatcher.d/90-mavis-netsetup && echo hook-points-at-ops-venv
   tail -n 5 /var/log/mavis-netsetup.log       # last "repair done rc=0", both arms [OK ]
   nmcli -g 802-3-ethernet.mac-address,connection.interface-name con show mavis_viewpoint_arm      # 08\:BF\:B8\:89\:4F\:3A / enp36s0f0
   nmcli -g 802-3-ethernet.mac-address,connection.interface-name con show mavis_manipulation_arm   # 08\:BF\:B8\:89\:4F\:3B / enp36s0f1
   ```

   `--python` bakes the interpreter into the hook (default would be the running interpreter —
   the same here since we run the ops venv, but keep it explicit); `--user mavis-v2` puts
   **mavis-v2**, not `$SUDO_USER`, into `netdev`; the `--arm` list must be given in the same
   order each time, or `--check` reports the hook as "differs from the rendered script".
   Details: `apollo-mavis-v2-hardware/docs/netsetup-install.md`. Log:
   `/var/log/mavis-netsetup.log`. The two profiles: `mavis_manipulation_arm` = 192.168.1.11/24
   on `enp36s0f1` (MAC 08:BF:B8:89:4F:3B) → Manipulation Arm control box 192.168.1.201;
   `mavis_viewpoint_arm` = 192.168.2.12/24 on `enp36s0f0` (MAC 08:BF:B8:89:4F:3A) → Perception
   Arm control box 192.168.2.219. The MAC/interface pinning of both profiles is done (the
   earlier worry that `mavis_viewpoint_arm` could attach to the unused USB RTL8153
   `enx00e04c683d97` at boot is closed); the two `nmcli` lines above are the verification.

---

## S6. The systemd user service

Templates: `scripts/deploy/systemd/mavis-runtime.service` (ops) and
`scripts/deploy/systemd/mavis-ui-dev.service` (developers only). Script, **as mavis-v2**:

```bash
sudo -iu mavis-v2
bash ~/apollo-mavis-v2-ws/scripts/deploy/install-services.sh           # var/ dirs, libsurvive symlink + seed, install the unit
START=1 bash ~/apollo-mavis-v2-ws/scripts/deploy/install-services.sh   # ... and (re)start it — only when no other runtime owns the devices (S8)
AUTOSTART=1 bash ~/apollo-mavis-v2-ws/scripts/deploy/install-services.sh   # ... and enable it at boot (opt-in, read the box below first)
```

Other knobs: `WITH_UI_DEV=1` also installs `mavis-ui-dev.service` (developer accounts,
never enabled), `LIBSURVIVE_SEED=/path/config.json` picks the lighthouse calibration to
seed, `ALLOW_ANY_USER=1` bypasses the "am I the ops account" refusal.

> **Autostart is OFF by default, and that is a decision, not an oversight.** Linger is on,
> so the account has a user manager at boot and the service *could* start there — but
> `install-services.sh` actively `disable`s it. Two reasons: the rendered lab config is
> **armed**, so a boot-time start would open the real control boxes with nobody in the
> room; and it would seize the Watchman dongle, the microphone and port 8765 from a
> developer's instance after every reboot. The operator starts it by hand
> (`systemctl --user start mavis-runtime`). `AUTOSTART=1` opts in if you ever want the
> cell to come up unattended.

Manual equivalent:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
mkdir -p ~/.config ~/.config/systemd/user
ln -s ~/apollo-mavis-v2-ws/var/libsurvive ~/.config/libsurvive          # see S4 "per account"
install -m 644 ~/apollo-mavis-v2-ws/scripts/deploy/systemd/mavis-runtime.service ~/.config/systemd/user/
systemd-analyze --user verify ~/.config/systemd/user/mavis-runtime.service
systemctl --user daemon-reload
systemctl --user start  mavis-runtime.service     # by hand, every time
# systemctl --user enable mavis-runtime.service   # ONLY if you want it at boot (see the box above)
```

The unit (defaults; `install-services.sh` rewrites the two paths if `OPS_ROOT`/`LAB_CONFIG` differ):

```ini
# MAVIS v2 runtime -- systemd --user unit for the shared operations account (mavis-v2).
# Installed by scripts/deploy/install-services.sh into ~/.config/systemd/user/;
# the two paths are rewritten there when OPS_ROOT / LAB_CONFIG differ from the defaults
# (checkout ~mavis-v2/apollo-mavis-v2-ws, rendered config in its var/).
# Guide: docs/deploy/DEPLOYMENT.md S6; day-to-day commands: the workspace README.
# Runs at boot through `loginctl enable-linger mavis-v2`.
[Unit]
Description=MAVIS v2 runtime (API + built UI on :8765, Vive tracker, microphone, arm probes)
Documentation=file://~/apollo-mavis-v2-ws/docs/deploy/DEPLOYMENT.md
# The user manager has no network-online.target of its own (system target); the
# ordering is harmless there and the runtime re-probes the arms every 2 s anyway.
# PulseAudio is socket-activated per user: order after the socket so the first
# pactl/parec call of the microphone service finds a daemon.
After=network-online.target pulseaudio.socket
Wants=pulseaudio.socket
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
WorkingDirectory=~/apollo-mavis-v2-ws/apollo-mavis-v2-runtime
# Headless MuJoCo rendering on the NVIDIA EGL platform (also defaulted in __main__).
Environment=MUJOCO_GL=egl
# The runtime honours $APOLLO_CONFIG when --config is absent; keep both in sync.
Environment=APOLLO_CONFIG=~/apollo-mavis-v2-ws/var/mavis_v2_lab.yaml
# Workspace root for any ${APOLLO_HOME}-relative path (the render pins absolute paths, this
# only makes the inference explicit).
Environment=APOLLO_HOME=~/apollo-mavis-v2-ws
Environment=PYTHONUNBUFFERED=1
Environment=OPENBLAS_NUM_THREADS=1
Environment=OMP_NUM_THREADS=1
Environment=MKL_NUM_THREADS=1
# The venv interpreter directly, not `uv run`: that needs uv on PATH and network at
# boot and may re-lock/resync (only a plain `uv sync` drops pysurvive).
ExecStart=~/apollo-mavis-v2-ws/apollo-mavis-v2-runtime/.venv/bin/python -m apollo_mavis_v2_runtime --config ~/apollo-mavis-v2-ws/var/mavis_v2_lab.yaml
Restart=on-failure
RestartSec=5
# SIGTERM -> uvicorn -> lifespan -> Runtime.stop(): releases the Watchman dongle
# (libsurvive simple_close), stops the microphone stream and the trainer child.
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

Commands (as mavis-v2; `sudo -iu mavis-v2` does not export the bus, hence the two exports):

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
systemctl --user status  mavis-runtime
systemctl --user restart mavis-runtime
systemctl --user stop    mavis-runtime
journalctl --user -u mavis-runtime -f          # stderr of the runtime (INFO)
tail -f ~/apollo-mavis-v2-ws/var/logs/runtime.log   # the same lines, rotating file (logging.dir); `grep 'loop:'` = the
                                                    #   1 Hz control-loop health line (04-runtime §14 "Logging") — the
                                                    #   first thing to read after a bad session
journalctl --user -u mavis-runtime -b --no-pager | tail -100
```

From the developer account (no mavis-v2 shell):

```bash
U=$(id -u mavis-v2)
sudo -u mavis-v2 env XDG_RUNTIME_DIR=/run/user/$U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus systemctl --user status mavis-runtime
sudo systemctl --user -M mavis-v2@ status mavis-runtime       # systemd >= 248 shortcut — verify on first deploy
sudo journalctl _SYSTEMD_USER_UNIT=mavis-runtime.service -f
systemctl status user@$U.service                            # the lingering user manager itself
```

---

## S7. Verification checklist (first boot and after every upgrade)

> **Before you let anything move, 2026-09-09.** The digital twin does not model the room the
> cell now stands in — the blue cart with the toy food and the whole kitchen run of 03-sim
> §4.4 are absent from the `mavis_v2` scene that the collision GATE, the PLANNER and the
> overlays all use — and the arms and rails themselves are 15–30 mm out in the twin (03-sim
> §4.5). A twin-planned, gate-approved `return_home` was cancelled twice by `controller error
> 31: Collision Caused Abnormal Current` at 19:05 that day. The hardware gate's inflation was
> raised **0.008 → 0.025 m** with `warn_clearance_m: 0.045` as a stop-gap (`safety` block in
> `configs/mavis_v2.yaml`; do NOT confuse it with `hardware_session.home_rail_inflation_m`,
> which was always 0.025). Until the room is measured into the scene, treat EVERY planned
> motion — return-to-start, `R`, "Go to profile", **Home rail** — as unverified: **10 % speed,
> hand on the E-stop.** Pointing the gate and planner at the kitchen scene is one config key,
> `workcells.<kind>.digital_twin_scene: mavis_v2_kitchen` (hardware) or `sim_scene` (sim), but
> that scene has its own measurement caveats — read 03-sim §4.4 first.

Read-only script: `bash $OPS_ROOT/scripts/deploy/healthcheck.sh`
(`RUNTIME_PORT=8766` for a developer instance). It checks `/api/health`, both arms
`reachable: open` via `/api/workcell?kind=hardware`, `/api/microphones` `live: true`,
`/api/tracker/calibration`, one `/ws/telemetry` frame for `tracker.status`
(`tracking`/`searching`), and that `GET /` returns the SPA. Manual:

```bash
id "$OPS_USER"                                       # render plugdev input audio netdev present (+ sudo here)
loginctl show-user "$OPS_USER" -p Linger              # Linger=yes
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

From a mavis-v2 shell additionally (**verify on first deploy**): `pactl list short sources | grep NT-USB`
must list `alsa_input.usb-R__DE_Microphones_R__DE_NT-USB_Mini_750BFEE8-00.mono-fallback`
(needs `XDG_RUNTIME_DIR` exported; proves mavis-v2's PulseAudio sees the card via group `audio`).

Browser: the runtime binds `127.0.0.1` (no authentication anywhere) — open
`http://127.0.0.1:8765/` on the machine, or `ssh -L 8765:127.0.0.1:8765 apollo-pc-1` /
tailscale from elsewhere. Do **not** switch `host` to `0.0.0.0` without a reverse proxy
with auth: it would expose arm control to the LAN. Then: Welcome page shows the mic
waveform and both arms reachable; Debug page (`#/devices`, top-right link) → tracker
`tracking` when the controller is on → run **Yaw alignment** (7 clicks) so
`$DATA_ROOT/calibration/tracker_calibration.json` exists; start a **sim** session
on `mavis_v2` and teleop with the controller. A **hardware** session only after the
phase-09c/09d first-run procedure above, with the user present.

---

## S8. Daily operation and the dev-vs-ops split

### S8.1 Start / stop (as the ops account; exports as in S6)

```bash
systemctl --user start|stop|restart|status mavis-runtime
journalctl --user -u mavis-runtime -f
```

It does **not** start by itself at boot: linger is on and `WantedBy=default.target` is in
the unit, but the unit is not `enable`d (S6 explains why). `Restart=on-failure` still
applies once it is running. After power-cycling the arms, `reachable` goes
`unreachable → refused → open` over ~1-2 min.

### S8.1b The workcell's initial condition (2026-09-08)

The `R` key and the Cockpit's "End session" both walk the arms back to the **designated
initial-condition profile** of the running session's workcell kind, and both are no-ops
(with a reason in the UI) when none is designated. Seed the operator's default posture
once per machine, as `mavis-v2`, with the runtime STOPPED or at least with no session
running:

```bash
cd ~/apollo-mavis-v2-ws/apollo-mavis-v2-runtime
source ~/apollo-mavis-v2-ws/scripts/deploy/_common.sh   # so uv finds the shared interpreters
C=~/apollo-mavis-v2-ws/var/mavis_v2_lab.yaml
uv run python -m apollo_mavis_v2_runtime.profiles.seed_initial --config $C --dry-run   # look first
uv run python -m apollo_mavis_v2_runtime.profiles.seed_initial --config $C             # then write
# and the ordinary "Kitchen Interaction" profile (operator request 2026-09-09, NOT an initial
# condition; amended 2026-09-10 so only the Perception Arm differs from the default posture -
# a store seeded before that date holds the old grip entry, so re-run this after a pull):
uv run python -m apollo_mavis_v2_runtime.profiles.seed_kitchen --config $C
```

Alternatively copy an existing profile store across accounts — the files are content-free
JSON named by id, so `sudo install -m 664 -o mavis-v2 -g mavis-v2 ~xiatao/…/var/profiles/*.json
~/apollo-mavis-v2-ws/var/profiles/` preserves the operator's own saved profiles (that is how
this machine was seeded on 2026-09-09: five profiles, both initial conditions, `Kitchen
Interaction` for both kinds, and one captured `2026-09-09 FurnitureBench`). The runtime picks
new profile files up without a restart.

It writes one profile per workcell kind into `profiles_dir` and designates it (idempotent
— re-running rewrites the same two files). The postures are the operator's 2026-09-08
numbers: Manipulation Arm `[-180, -12, -20, 30, -5, 35, -8.9]°`, Perception Arm
`[0, 0.8, 0, 28.9, 0, 28.2, 0]°`, carriages left unset so a return never commands a
track onto its end stop. Prefer the Cockpit's "save current state as profile" + "use as
initial condition" when you want a posture measured on the real cell, carriages included
— the return then moves the carriages as a separate, separately gated second phase.
Designating an initial condition also changes what a collect session's per-episode
return-to-start aims at when no `start_from` profile is chosen (04-runtime §10.5).

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
U=$(id -u mavis-v2); OPS="sudo -u mavis-v2 env XDG_RUNTIME_DIR=/run/user/$U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus systemctl --user"
$OPS stop mavis-runtime          # releases dongle + mic stream + arms
# ... develop with tracker.backend libsurvive / mic auto on :8765 ...
$OPS start mavis-runtime
```

Heavy option: `sudo systemctl stop user@$U.service` stops the whole mavis-v2 manager (also its
PulseAudio). The root NM dispatcher keeps matching the arm NICs regardless of which instance runs.

### S8.5 Online DAgger trainer — the policy-node process (2026-09-08, phase-14; rewritten the same evening from the PRO-DAgger v1.0 wording)

Online DAgger (15-online-dagger v2.0) trains in **another process that the policy repo owns**:
the `mavis-policy-node` dora node (package `mavis_policy_node`, repo
`apollo-mavis-v2-policy-node` — on the developer machine at
`~/projects/apollo-mavis-v2-ws-p12/apollo-mavis-v2-policy-node`, no remote yet). The runtime
is an algorithm-agnostic shell: it creates the session directory, runs rollouts, exposes
take-over / hand-back, labels every frame novice / expert, relays the trainer's status and
serves the instructions — it knows nothing about iterations, reference gradients or
hyper-parameters (those live in the trainer's own config). Admitted on hardware since 2026-09-12
behind `hardware_session.policy_modes` (`HARDWARE_POLICY_MODES=true` in `var/lab.env`; 15-online-dagger
D7 as amended) — over REST for now: the Hardware tab's launcher still greys `dagger` out. Unverified on
the real arms: first trial = a recorded episode through the playback dialog at 10 %, E-stop in hand,
then a session with `wait_for_trainer_ready` on the Manipulation Arm alone.
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

As the ops account — nothing in this section needs sudo, and nothing needs a GitHub login:
every repo is public and every git call carries `GIT_TERMINAL_PROMPT=0`. **One command:**

```bash
bash ~/apollo-mavis-v2-ws/scripts/deploy/update.sh
```

It refuses while a teleop / collect / Online DAgger session is open on `:8765` (`FORCE=1`
overrides and tears it down), stops the unit only if it was active, runs
`UPDATE=1 install-stack.sh`, prints `workspace <before> -> <after>`, warns when
`submodule status` shows a `+` or `-`, re-renders the lab config **from `$DATA_ROOT/lab.env`**,
restarts only if it had been running, and finishes with the health check. Knobs: `FORCE=1`,
`NO_RESTART=1` (leave it stopped — e.g. a developer wants the cell next), `START=1` (start
even if it was not running before), plus `WITH_DEV` / `SKIP_UI` / `PYSURVIVE_WHEEL` /
`BUILD_PYSURVIVE` passed through to `install-stack.sh`.

**Never `git commit` in the ops checkout.** It has to stay clean so it can always
fast-forward; everything generated is gitignored (`/var/*`, `/.uv/`, the venvs, `dist/`).
Development happens in a developer's own clone and arrives here through GitHub. To look
before you leap: `git -C ~/apollo-mavis-v2-ws fetch --recurse-submodules && git -C ~/apollo-mavis-v2-ws status`.

Equivalent by hand, with the service stopped:

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus   # su -/sudo -iu only
systemctl --user stop mavis-runtime
UPDATE=1 bash ~/apollo-mavis-v2-ws/scripts/deploy/install-stack.sh     # git pull --ff-only, submodule update, uv sync --locked ×4, pysurvive check, npm ci + gen:check + build
bash ~/apollo-mavis-v2-ws/scripts/deploy/render-lab-config.sh          # re-render: new repo keys land, overrides stay; shows a diff; no sudo
systemctl --user start mavis-runtime && bash ~/apollo-mavis-v2-ws/scripts/deploy/healthcheck.sh
```

Manual equivalent of the update part:

```bash
source ~/apollo-mavis-v2-ws/scripts/deploy/_common.sh   # exports UV_PYTHON_INSTALL_DIR + git safe.directory; without it uv fetches private interpreters into ~
cd ~/apollo-mavis-v2-ws && git pull --ff-only && git submodule sync --recursive && git submodule update --init --recursive
for r in core sim hardware; do (cd apollo-mavis-v2-$r && uv sync --locked --no-dev); done
(cd apollo-mavis-v2-runtime && uv sync --locked --no-dev --extra sim --extra hardware --extra audio \
  && uv pip install --no-deps --force-reinstall ../third_party/wheels/pysurvive-*-cp312-*.whl \
  && .venv/bin/python -c "import pysurvive")
(cd apollo-mavis-v2-ui && npm ci --no-audit --no-fund && npm run gen:check && npm run build)
```

Schema regeneration check (protocol drift between core and the UI's generated types —
`gen:check` above fails on drift; the core side of the same guard):

```bash
(cd ~/apollo-mavis-v2-ws/apollo-mavis-v2-core && .venv/bin/python -m apollo_mavis_v2_core.protocol.export_schemas --check --out schemas/)
```

Rules: the ops clone tracks the workspace's pinned submodule commits (detached HEADs are
normal); upgrades happen by the developer pushing **all five** sub-repos in dependency order
and bumping the pointers in the ws (intro item 1), then `UPDATE=1` here — afterwards
`git -C $OPS_ROOT submodule status` must show no line starting with `+` or `-`.
Keep `--locked`: if it fails, the developer forgot to commit `uv.lock`. A pysurvive/Python bump needs a new wheel (S3). If `configs/mavis_v2.yaml`
gained keys, re-rendering picks them up; if the wheel or dist path moved, re-render too.

Phase-12 (dora), phase-13 (episode-directory datasets, keyboard peer, return to start), the
2026-09-08 follow-ups and phase-14 (Online DAgger) were **committed and pushed on
2026-09-09**, so a fresh deploy carries `dora:`, `datasets:`, `online_dagger:` and
`translate_frame`. Anything a developer has only in a working tree does NOT reach this
machine — that is the whole point of "pushed and pinned", and it is worth checking against
the developer's `git status -sb` when a feature you expect is missing here. The UI is built
with **npm** (`npm ci`; `package-lock.json` is the lockfile — pnpm's pre-run install fails on
this machine, and `pnpm-lock.yaml` / `pnpm-workspace.yaml` are never committed).

---

## S10. Backup and restore

What matters (everything else is rebuildable from git + PyPI):

| What | Path |
|---|---|
| Lighthouse calibration (+ wizard backups) | `$DATA_ROOT/libsurvive/config.json`, `config.json.bak-*` |
| Tracker yaw + base-station install record | `$DATA_ROOT/calibration/tracker_calibration.json`, `base_station-*.json` |
| Teleop profiles | `$DATA_ROOT/profiles/` |
| Datasets (episode directories since phase-13; `exports/lerobot_v3/` is a derived export), checkpoints | legacy / generic root `$DATA_ROOT/datasets/`; **since 2026-09-08 the demonstrations live in `~mavis-v2/data/bc_demo/<name>/` and Online DAgger sessions in `~mavis-v2/data/online_dagger/<session>/` (`session.json`, `rollouts/`, plus whatever the trainer writes there)** — back those two trees up too; `$DATA_ROOT/checkpoints/` (large) |
| Lab config, netsetup state | `$DATA_ROOT/mavis_v2_lab.yaml` (re-renderable, S4), `/etc/apollo-mavis-v2/nic_map.json` |
| **Render knobs** — NOT re-derivable: without it a re-render silently drops `HARDWARE_ARMED`, `HARDWARE_POLICY_MODES`, the tracker yaw, `CAMERA_SERIALS`, `DORA_BIND_HOST` | `$DATA_ROOT/lab.env` |
| Developer-side originals | `~$DEV_USER/.config/libsurvive/`, `~$DEV_USER/apollo/{calib,calibration,profiles}` |

### Moving recorded data between accounts

Recordings live in `~/data` of whichever account ran the runtime, and homes are 0750, so a
plain `cp` from a developer's tree lands unreadable (or fails outright). Use the script — it
rsyncs through sudo and `--chown`s to the receiving account:

```bash
DEV_USER=<their-account> bash ~/apollo-mavis-v2-ws/scripts/deploy/sync-data-from-dev.sh
DRY_RUN=1 DEV_USER=… bash …/sync-data-from-dev.sh        # list what would change first
DIRECTION=ops-to-dev DEV_USER=… bash …/sync-data-from-dev.sh   # ops -> developer
```

**Additive only** — it never passes `--delete`, so nothing on the receiving side is ever
removed. `DEV_USER` defaults to whoever invokes the script (`$SUDO_USER` under sudo), and
the script refuses when it resolves to the ops account itself. This replaces the old
"developers write into a group-shared tree" model: the two `~/data` trees stay separate and
you copy deliberately.

```bash
# calibration + config (small): tar to /home/shared (world-writable, exists) or removable media
sudo tar czf /home/shared/mavis-calib-$(date +%Y%m%d).tgz \
  ~/apollo-mavis-v2-ws/var/libsurvive ~/apollo-mavis-v2-ws/var/calibration ~/apollo-mavis-v2-ws/var/profiles \
  ~/apollo-mavis-v2-ws/var/mavis_v2_lab.yaml /etc/apollo-mavis-v2
# datasets/checkpoints (large): rsync
rsync -a --info=progress2 ~/apollo-mavis-v2-ws/var/datasets/ /media/backup/mavis-datasets/
# restore (service stopped)
sudo tar xzf /home/shared/mavis-calib-YYYYMMDD.tgz -C /
sudo chown -R mavis-v2:mavis-v2 ~/apollo-mavis-v2-ws/var/{libsurvive,calibration,profiles}
```

After every accepted base-station install (wizard → Install) copy the new
`config.json` into the runtime repo as `configs/libsurvive/mavis_v2-lighthouses-<date>.json`
and commit — that copy is how a fresh machine is restored (13-tracker §6.1). Restoring
a lighthouse config invalidates the yaw: redo the Yaw wizard.

---

## S11. Troubleshooting

> **Never run `uv run` in a sub-repo whose venv a live runtime is executing from** —
> least of all with a hardware session open. `uv run` re-syncs the environment: it
> rebuilds and REINSTALLS the package (`Building apollo-mavis-v2-runtime … Uninstalled 1
> package … Installed 1 package`), deleting and rewriting the very site-packages the
> running process imports from. On 2026-09-10 two concurrent `uv run pytest` invocations
> in `apollo-mavis-v2-runtime` killed the dev runtime **mid hardware session**: the log
> stopped mid-health-line with no traceback and no teardown, so the arms were left
> enabled rather than stopped-and-braked, and the next UI click answered 500 from a dead
> server. Stop the runtime first (`scripts/dev/mavis-dev.sh stop runtime`, or
> `systemctl --user stop mavis-runtime` on the shared account), or run the suite from a
> separate git worktree; `uv run --no-sync` is safe for read-only tools when the lockfile
> is unchanged. Never two test runs in the same tree at once. Same class of hazard as the
> 2026-09-05 test-suite incident (04-runtime §16).
>
> **The venv's own entry points are safe.** `$OPS_ROOT/apollo-mavis-v2-runtime/.venv/bin/pytest`,
> `.venv/bin/python -m apollo_mavis_v2_runtime.profiles.seed_kitchen`, `.venv/bin/python -m ruff`
> and friends do NOT re-sync the environment — only `uv run` does. So the practical form of
> the rule is: with a runtime live, call the venv's entry points directly instead of going
> through `uv run`. Verified 2026-09-10 (a full playback + orphan suite and ruff ran against a
> live dev runtime with no effect on it), and it is how `seed_kitchen` was re-run on the shared
> account while `mavis-runtime` was serving.
>
> **But a serving cell makes two runtime tests fail, permanently, on this host.** While
> `mavis-runtime` is up it runs the 100 Hz control loop, four camera encoders, twin sync and
> the EGL overlays (measured 2026-09-10: ~118 % CPU, host load average 2.8), and
> `tests/test_return_fuzz_mavis_v2.py` plans 24 two-arm RRT starts against a WALL-CLOCK
> budget. Its `MAX_HONEST_TIMEOUTS` cap of 2 is then exceeded by honest full-budget timeouts
> (`3 <= 2`), and `test_e2e_reset_pinched_sim.py::test_goto_profile_back_to_the_pinched_profile_is_a_goal_in_collision_refusal`
> goes the same way — while passing in isolation. The tell that this is load and not a
> regression: the failing assertion is a COUNT, every case is still classified an honest
> failure, `holds` is empty with `arrival 0.000 mrad / 0.00 mm`, and re-running the SAME seeds
> reports DIFFERENT failing pairs (the RRT's answer depends on how far it gets inside its
> budget, not on the geometry). **Run those two on a quiet host, or with the service stopped.**
> Do NOT raise `MAX_HONEST_TIMEOUTS` or the planner budget to make them pass: both are part of
> the return-flow safety proof the operator asked for (04-runtime §10.5, 11-safety §9).

| Symptom | Cause / fix |
|---|---|
| the whole UI answers `Internal Server Error` / `500`, or the browser cannot reach `:8765` at all | the runtime process is GONE, not erroring. `pgrep -af apollo_mavis_v2_runtime` empty and `curl :8765/api/health` refusing confirm it; the log's last line will be a mid-second health line with **no traceback and no teardown**. Most likely cause on a developer machine: a `uv run` in the runtime tree re-synced the venv under the live process (see the box above). Restart (`scripts/dev/mavis-dev.sh restart runtime` / `systemctl --user restart mavis-runtime`), then **check the arms** — a runtime that dies without `teardown()` never hands them back stopped-and-braked, so read `telemetry.hardware_monitor.arms[]` (`error_code`, `warn_code`) once the read-only monitor reconnects, and **Clear errors** on the card if anything latched. |
| tracker `error` with `LIBUSB_ERROR_BUSY` in `journalctl --user -u mavis-runtime` | another libsurvive holds the dongle: the developer's runtime, `survive-cli`, `scripts/tracker/03-…`. `sudo fuser -v /dev/bus/usb/$(lsusb -d 28de:2101 \| awk '{printf "%s/%s", $2, substr($4,1,3)}')` shows the pid; stop it (S8.4). A killed process can keep the interface claimed → replug the dongle. |
| tracker `no_backend` | pysurvive missing — a plain `uv sync` removed it. `(cd $OPS_ROOT/apollo-mavis-v2-runtime && uv pip install --no-deps --force-reinstall ../third_party/wheels/pysurvive-*-cp312-*.whl)`; restart. |
| tracker `error`: permission / cannot open device | mavis-v2 lacks `plugdev` or the udev rule is missing: `id mavis-v2`, `ls -la /dev/bus/usb/…` should be `root plugdev 0660`; `sudo udevadm trigger --subsystem-match=usb`; restart `user@<uid>` after group changes. |
| tracker `searching` forever | controller off/asleep, or stations off; `--lighthousecount 3` must match the powered stations. Yaw/base-station: Debug page (`#/devices`) wizard. |
| microphone `absent` / `error: pactl…` | mavis-v2's PulseAudio does not see the card: (a) `XDG_RUNTIME_DIR` unset → service must run under the user manager (it does) — from shells export it; (b) mavis-v2 not in `audio` (`/dev/snd/* root:audio 0660`); (c) the developer's PA has a stream open on the RØDE (S8.3, set its card profile off); (d) `pactl info` fails → `systemctl --user status pulseaudio.socket pulseaudio.service` as mavis-v2 (**verify on first deploy**: module-udev-detect for a seatless user). Never open `hw:CARD=Mini` directly: EBUSY and it stalls every Pulse recorder. |
| both wrist-cam tiles black after a reboot (`/api/cameras` `live: false`) | With `kind: realsense` (since 2026-09-11) the runtime's own librealsense pipeline opens the device, so the old cold-boot quirk does not apply: check that `rs-enumerate-devices -s` lists both DEVICE serials (`327122074467` grip, `243522071002` view — the serials in the config since 2026-09-11) and that no other process holds them (a developer's runtime, `realsense-viewer`; S8 — one owner per device, a UVC open on the same unit blocks librealsense), then read the camera's `hardware_reset()` retry in the runtime log (02-hardware §8). History, for a `kind: v4l2` entry (the 2026-09-04..09-10 lab config; log `select() timeout` / `cannot open`): the D435i colour UVC stream delivers nothing after a reboot until librealsense has opened the device once; `OpenCVCamera` runs `rs-enumerate-devices -s` automatically before the first RealSense open (`RealSense wake` in the log; `command -v rs-enumerate-devices`, librealsense2-utils from Intel's apt repo) — manual fallback: run it, then restart the service. In that layout the config held the USB iSerials, not the device serials the tool prints. |
| sim previews black / `stream died` in the log, EGL errors | render node permission: mavis-v2 needs `render` (`/dev/dri/renderD* root:render 0660`); `/dev/nvidia*` are 0666. Check `MUJOCO_GL=egl` in `systemctl --user show mavis-runtime -p Environment`; `egl_device_id: 0` = PCI 41:00.0. An EGL failure kills only the preview streams, not the runtime. |
| `POST /api/session` kind=hardware → 409 `<Arm>: rail not homed - home it from the Hardware tab (Home rail) before starting a session` | expected after every power-on (phase-09c): both tracks boot unhomed and a session needs the carriage position for the gate twin — and since phase-09d BOTH arms are always in a session, so both tracks must be homed. Card → **Home rail** → dry-run verdict → confirm (the carriage MOVES to the operator's left end, ≤ 45 s; or, phase-09d, the sheet says `pre-positioning planned` and the ARM MOVES FIRST along the planned path at 10 %, then the carriage — 202 job, watch the phases in the sheet) → `rail 0.000 m`; then check the `*_align` overlay before the session. Other 409s from the same matrix: `hardware sessions support teleop and data collection only (<mode> on hardware: not yet - hardware_session.policy_modes is false; the lab render sets it with HARDWARE_POLICY_MODES=true)` (collect is admitted on hardware since 2026-09-07 — 04-runtime §5 / §10.5; DAgger / Online DAgger and inference since 2026-09-12 behind `hardware_session.policy_modes` — put `HARDWARE_POLICY_MODES=true` in `var/lab.env`, re-render, restart; 15-online-dagger D7 as amended; with the knob true the same request can instead answer `unknown policy …` / `no promoted deploy checkpoint …` / `no external policy attached (…)` / `DAgger rollout recording needs at least one live hardware camera …`, all before any box is touched; the pre-2026-09-07 string was `hardware sessions support teleop only`), `hardware sessions include every configured arm (Manipulation Arm, Perception Arm) - missing [...]` (a client posted a subset — the UI never does since phase-09d; both arms always join, so the Perception Arm must be homed / error-free too), `no monitor sample` (box off / monitor paused), `controller error N is latched - clear errors first` (**Clear errors**; the Perception Arm's `C19` blocked every session until it was fixed in Studio on 2026-09-05), `rail homing in progress` (wait for the carriage / the job), `control box … is unreachable`, `hardware bring-up failed: <Arm>: <stage> - …` (the drivers were torn down again, the monitor resumed — read the stage), `profile motion not collision-free: <failure> (<pair>) - …` (phase-09d: `start_from: profile:<id>` was planned on the gate twin inside bring-up and no collision-free path exists from the measured posture — use `keep_current` or another profile; the session was torn down). |
| **Home rail** refused / failed (sheet shows a red verdict or an error, `ok: false`, 409) | `Sweep blocked — no safe pre-positioning path` (`status: refused`, phase-09d) = the twin sweep found a pair within 25 mm somewhere along the 0–0.65 m travel at the arm's current posture (`rail_sweep.first_blocked_m` / `first_blocked_pair`) AND no candidate posture (scene keyframe, `<arm>_home`) is reachable by a rail-position-agnostic path: fold the arm toward the factory-zero posture in xArm Studio (joints 2–7 near 0; or move the other arm) and re-open Home rail — nothing was written. (`Current posture blocks the sweep — pre-positioning planned` is NOT a refusal: confirm and the arm moves first; an older runtime shows `Sweep blocked — homing refused` instead.) 409 `clear errors first` → **Clear errors** first; 409 `end the session first` → end the hardware session; 409 `needs the digital twin` → the lab config lacks `digital_twin_scene` or the runtime venv lacks the sim extra. `ok: false … the arm moved since the sweep was checked` → keep the arm still between the dry run and the confirm. `ok: false … on_zero still 0` after the 30 s SDK wait → the track never reached its zero switch: check the track cable / `hardware_monitor.arms[].rail_*` registers, **Clear errors**, retry. UI `no answer after 60 s` → read the card's rail pill; the runtime may still have finished. While homing the arm reads `stale` + `maintenance_busy` and `POST /api/session` is 409. |
| after a hardware session an arm is not back at `state 4` / brakes not engaged | `XArmDriver.disconnect()` ends with `set_mode(0)` → `set_state(4)` → `motion_enable(False)` (phase-09c D6) and the track keeps its homed flag. Check `hardware_monitor.arms[].state` once the monitor resumes; if the box still reports enabled, the disconnect writes failed (runtime log) — disable it from xArm Studio, never leave the cell enabled unattended. |
| rail-homing job `failed` (phase-09d; the sheet marks a phase red, toast `<Arm> · rail homing job failed during <phase>: …`, `GET /api/hardware/arms/<id>/maintenance/last` → `ok: false`) | the runtime tore the job down (arm stopped + braked where it was, monitor resumed, `maintenance_busy` cleared — nothing half-connected). Read the detail: `arm moved since the sweep` (> 0.02 rad between dry run and confirm — keep it still), `session slipped in` / `rail homing in progress` (retry), a driver fault or the gate holding during `positioning` (30 s or 3× the estimate; the posture must land within 0.05 rad — an obstacle / the other arm is in the way: check the overlay, fold in Studio), `on_zero still 0` after `home_rail()` (track cable / registers, **Clear errors**, retry), register verification (`rail_homed` / `rail_enabled` not both true). The arm stays wherever the job stopped it — look before re-opening Home rail; the next dry run plans from that posture. |
| red `C<code>` chip on a Hardware-tab arm card (the Perception Arm's `C19` until 2026-09-05; `hardware_monitor.arms[].error_code != 0`) | a controller error is latched in the box. Click **Clear errors** on the card (phase-09b; `POST /api/hardware/arms/<id>/maintenance {"op":"clear_errors"}` = `clean_error` + `clean_warn` on the read-only monitor — no enable, no motion, no confirm dialog). Toast `<Arm> · errors cleared`; the chip clears with the next monitor sample. `C19` (End Effector Communication Error: the box expects an end effector on the tool RS-485 bus, the Perception Arm has none) returned after every clear until xArm Studio → Settings → Externals → End Effector → **None** (no SDK write for it) — done 2026-09-05, both boxes read `error_code` 0 since. Inside a hardware session the card buttons are disabled (`Use the Cockpit`): use the Cockpit fault banner's **Clear errors & resume**, then re-grip the clutch. 409 `… needs the read-only monitor connected` = box off / monitor paused; `ok: false … re-latched right after clearing` = a persisting hardware fault (cable, e-stop). |
| amber `sensitivity 1 · payload 0.00 kg` with `differs from config` on an arm card (`hardware_monitor.arms[].backstops_match: false`) | the controller lost its volatile safety settings (reboot) or never had them written. Click **Apply safety settings** (`{"op":"apply_backstops"}`: payload, gravity, collision sensitivity, self-collision model, rebound off — configuration writes only, no motion) → toast `<Arm> · safety settings applied (sensitivity 3, payload 0.95 kg)` and `backstops_match: true`. The driver re-applies the same values at every session connect; the values live in the lab config per arm (`tcp_load_kg` / `tcp_load_cog_mm` / `collision_sensitivity`; PROVISIONAL payloads until the tools are weighed — change them in `configs/mavis_v2.yaml`, then S9 re-render). |
| arms `unreachable` | boxes off (1-2 min after power-on), or the NIC lost its profile: `nmcli -t -f NAME,DEVICE con show --active \| grep mavis_`, `tail /var/log/mavis-netsetup.log` (dispatcher repairs on link events), `$PY -m apollo_mavis_v2_hardware.netsetup verify --arm grip=192.168.1.201 --arm view=192.168.2.219`, `… match --repair` (needs `netdev` + the `.pkla`, S5). Also `ip route get 192.168.2.219` must leave via `enp36s0f0`. |
| landing-page warning "polkit grant missing / user not in netdev / dispatcher hook missing" | S5 not run for this venv/user; `sudo $PY -m apollo_mavis_v2_hardware.netsetup install --check --python $PY --user mavis-v2 --arm … --arm …` (same `--arm` order as the install). Without sudo the `.pkla` cannot be read (`/etc/polkit-1/localauthority` is root-only) and is reported as a `note:` only. |
| `fatal: detected dubious ownership in repository at '$OPS_ROOT…'` | git 2.34.1 refuses a checkout owned by another uid. The deploy scripts export `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'` for their own git calls (`_common.sh`; verified to work with this git build). For ad-hoc git in the ops tree either `source $OPS_ROOT/scripts/deploy/_common.sh` or, once per account, `for d in $OPS_ROOT $OPS_ROOT/apollo-mavis-v2-{core,sim,hardware,runtime,ui}; do git config --global --add safe.directory $d; done`. |
| `EACCES` / `Permission denied` on `…/.venv/bin/python` when run by another account than the builder | the interpreters were installed into the builder's 0750 home (`readlink -f $OPS_ROOT/apollo-mavis-v2-runtime/.venv/bin/python` shows `/home/…`). Rebuild with the default `UV_PYTHON_INSTALL_DIR=$OPS_ROOT/.uv/python`: `rm -rf $OPS_ROOT/*/.venv && bash $OPS_ROOT/scripts/deploy/install-stack.sh`. |
| `systemctl --user` → "Failed to connect to bus" | export `XDG_RUNTIME_DIR=/run/user/$(id -u)` and `DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus`; if `/run/user/<uid>` is missing, linger is off (`loginctl show-user mavis-v2`) or the manager is down (`sudo systemctl start user@<uid>`). |
| `Address already in use` on 8765 | the developer's runtime (or a stale one) has the port: `ss -ltnp \| grep 8765`; use S8.3 ports for dev instances. |
| Vite: `ENOSPC: System limit for number of file watchers` | `sysctl fs.inotify.max_user_watches` should print 524288 (`/etc/sysctl.d/60-inotify.conf`, S1); `sudo sysctl --system`. |
| `uv sync --locked` fails | `uv.lock` drifted (developer must commit it) or no GitHub access (hardware's `xarm-python-sdk` git pin). |
| `npm run gen:check` fails | UI generated types or `schemas/` out of date with core — a developer must run `npm run gen:sync && npm run gen:types` and commit; not an ops fix. |
| UI shows the old title / stale bundle | `dist/` not rebuilt: `(cd apollo-mavis-v2-ui && npm run build)`, then `systemctl --user restart mavis-runtime` (StaticFiles is mounted at start). |
| `survive-cli` (developer tooling) fails to load `libsurvive.so.0` | its RUNPATH points at the wiped `/tmp/libsurvive-build`; run with `LD_LIBRARY_PATH=~/opt/libsurvive/lib` and the `SURVIVE_PLUGINS` trick from `scripts/tracker/03-lh-consistency-check.sh`, or rebuild with `LIBSURVIVE_SRC=~/opt/src/libsurvive scripts/tracker/02-build-pysurvive.sh`. The runtime's wheel is unaffected. |
| `GET /api/dora` → `enabled: false` / `external.state: disabled` although `DORA_BIND_HOST` was set | re-render and restart; `bind_host` was `0.0.0.0` or an arm-link address (the runtime refuses both), or the interface name is not up (`ip -4 addr show wlp38s0`). The token file is `<dora.var_dir>/.dora-token`. A dead remote daemon makes the coordinator answer 429 for ~50 s. |
| Online DAgger sheet: Start disabled / `POST /api/session` 409 (phase-14) | read the reason: `no external policy attached (...)` = no node / no `spec` heartbeat within 3 s (start the policy node, S8.5); `no Online DAgger trainer attached (the policy node does not report the online_dagger capability)` = node started without `--online-dagger`; `Online DAgger session '<s>' already exists - resume it or pick another name` (the sheet offers Resume) / `... not found` (resume of a name that does not exist) / `session.json is unreadable - fix or remove it`; `dataset 'online_dagger/<s>' is being exported - retry in a moment`; `hardware sessions support teleop and data collection only (… hardware_session.policy_modes is false …)` = the lab config was rendered without `HARDWARE_POLICY_MODES=true` (Online DAgger on hardware is admitted behind that knob since 2026-09-12, D7 as amended — re-render and restart). A trainer whose OWN config needs an offline dataset (the PRO-DAgger reference: `offline_dataset` under `~/data/bc_demo/<name>`) reports that as `trainer_status.state: error` — record demonstrations first, the runtime does not check it. Once running: `episode_new` refused with `waiting for the trainer to report ready (...)` until the trainer's first `ready` for this session, `training in progress (...)` while it trains, `trainer error: ...`, `no Online DAgger trainer attached` when its status went stale — expected. |
| Online DAgger session stuck in `WAITING FOR TRAINER` although the trainer says ready | the trainer's `trainer_status` does not echo the runtime's `session_id` (15-online-dagger §3; `null` counts as alive only) — fix the trainer (the shipped `OnlineDaggerLoop` / `FakeTrainer` do echo it); also check `spec` heartbeats are < 3 s apart (`telemetry.external.state`). |
| the service did not come back after a reboot | **by design**: linger is on but the unit is not `enable`d (S6). `systemctl --user start mavis-runtime`. `AUTOSTART=1 bash $OPS_ROOT/scripts/deploy/install-services.sh` if you do want it at boot. |
| `systemctl --user` says *"Failed to connect to bus"* | you reached the account with `su -` / `sudo -iu`, which does not set up its D-Bus: `export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus`, or use a real login (desktop / `ssh <ops>@localhost`). |
| git asks for a username / password | it never should: every repo is public and the scripts pass `GIT_TERMINAL_PROMPT=0`. Either a remote is wrong (`git -C $OPS_ROOT remote -v`, `git -C $OPS_ROOT submodule foreach 'git remote -v'` — all must be `https://github.com/Apollo-Lab-Yale/apollo-mavis-v2-*`) or a repo was made private. Fix the remote or make the repo public again; do **not** log a GitHub account into the ops account. |
| datasets copied from a developer are missing or unreadable in the UI | a plain `cp` cannot cross 0750 homes and leaves the wrong owner. Use `sync-data-from-dev.sh` (S10) — it rsyncs through sudo and `--chown`s to the receiving account. Then check `GET /api/datasets/layout` really points at `$OPS_HOME/data`. |
| `npm ci` / `npm run build` fails with a syntax error or an unsupported-engine message when run by hand | the shell picked up Ubuntu's node 12. `install-stack.sh` adds an nvm block to the ops account's `~/.bashrc` (2026-09-09) — open a NEW terminal, or `export NVM_DIR=~/.nvm && . $NVM_DIR/nvm.sh && nvm use 22`. |
| Hardware session started from a profile but the arms are still at the measured posture; amber `SESSION — start_from refused: <Arm> faulted (controller state <n>, code C<k>) - use Clear errors & resume, then Go to profile` in the Cockpit | 2026-09-08 evening: a controller fault (or a RECOVERING arm whose inputs are still held) outlasted `hardware_session.start_from_fault_grace_s` (3.0 s) — nothing moved, the session is RUNNING. Do what the banner says: **Clear errors & resume**, then Cockpit → profile row → **Go to profile** (twin-planned, gated, any input cancels). Before the grace existed the one-tick RECOVERING right after enabling refused the plan silently (03:25 / 18:44 logs). |

---

## S12. 中文速览（Chinese quick start）

目标：在实验室机器上用**共享运维账号**部署并运行 MAVIS v2（一个服务，:8765 同时提供 API、
已构建的网页 UI、Vive 追踪器、RØDE 麦克风、机械臂探测）；开发者账号保持不变。整套硬件
（接收器、麦克风、两个控制盒）和 8765 端口**同一时刻只能被一个实例占用**。

仓库里**不写死任何账号名或家目录**：路径一律用脚本真正使用的变量 `$OPS_ROOT` /
`$DATA_ROOT` / `$OPS_HOME` / `$DEV_USER`，或者在以运维账号执行的代码块里写 `~/…`；
systemd 单元用 systemd 自己的 `%h`。本机的取值是 `OPS_USER=mavis-v2`（uid 1001，家目录
`/home/mavis-v2`，本身就是 sudoer，管理员密码 **`ApolloLab#`**——经用户 2026-09-09 明确同意
写进这个公开仓库），`OPS_ROOT=~mavis-v2/apollo-mavis-v2-ws`，`DATA_ROOT=$OPS_ROOT/var`。
换成别的账号，把 `OPS_USER` 一改，下面每一步照样成立。

**更新怎么来：六个仓库（ws + 五个子仓库）全部 public，走匿名 HTTPS**，所有 git 调用都带
`GIT_TERMINAL_PROMPT=0`——运维账号上不需要、也不应该登录任何人的 GitHub 账号（没有
`~/.git-credentials`、没有 `~/.config/gh`、没有 credential helper）。哪个依赖变成 private，
解决办法是把它改回 public，而不是在这台机器上登录账号。运维 checkout 只拿到**已 push 且已被
workspace 指针 pin 住**的东西，所以开发者要按依赖顺序 core → sim/hardware → runtime → ui
push，再提交 ws 指针。

日常操作（启动/停止/更新/数据在哪）看 workspace 的 README「Running the cell」；这一节是首次部署。

```bash
# 1) 系统依赖 + udev + sysctl（需 sudo）
bash scripts/deploy/install-system-deps.sh
# 2) 账号：设备用户组 + linger（本机账号已存在，脚本只是补齐；家目录布局下不建任何 /opt、/var/lib 目录）
bash scripts/deploy/create-mavis-account.sh
sudo systemctl restart user@$(id -u mavis-v2).service      # 组变更需要重启它的 user manager
# 3) 以运维账号：克隆 + 构建（uv 四个 venv、pysurvive、UI）——不需要 sudo，也不需要 GitHub 登录
sudo -iu mavis-v2                                          # 或直接用该账号登录桌面
curl -LsSf https://astral.sh/uv/install.sh | sh && export PATH="$HOME/.local/bin:$PATH"
GIT_TERMINAL_PROMPT=0 git clone --recurse-submodules \
  https://github.com/Apollo-Lab-Yale/apollo-mavis-v2-ws.git ~/apollo-mavis-v2-ws
bash ~/apollo-mavis-v2-ws/scripts/deploy/install-stack.sh  # 解释器放 ~/apollo-mavis-v2-ws/.uv/python
# 3b) pysurvive wheel 不在 uv.lock 里，暂存目录在 checkout 内部，所以只能在 clone 之后放：
#     第一遍会提示 no pysurvive wheel，放好再跑一遍。运维账号是 sudoer，可以自己去开发者家目录取：
sudo install -m 664 -o mavis-v2 -g mavis-v2 \
  ~$DEV_USER/projects/apollo-mavis-v2-ws/third_party/wheels/pysurvive-*-cp312-*.whl \
  ~/apollo-mavis-v2-ws/var/wheels/
bash ~/apollo-mavis-v2-ws/scripts/deploy/install-stack.sh  # 这次会装上 pysurvive
# 4) 渲染配置 + 安装服务
bash ~/apollo-mavis-v2-ws/scripts/deploy/render-lab-config.sh  # -> ~/apollo-mavis-v2-ws/var/mavis_v2_lab.yaml
bash ~/apollo-mavis-v2-ws/scripts/deploy/install-services.sh   # 装单元 + libsurvive 目录/标定；开机自启默认【关闭】
#    要持久保留的渲染开关写进 ~/apollo-mavis-v2-ws/var/lab.env（HARDWARE_ARMED、HARDWARE_POLICY_MODES、TRACKER_YAW_DEG、
#    LOG_LEVEL、CAMERA_SERIALS、DORA_BIND_HOST…），否则每次 update.sh 重渲染会把它们悄悄丢掉
# 5) netsetup：把 NM dispatcher 钩子指向【运维账号的】hardware venv（机械臂开机；运维账号自己有 sudo）
PY=~/apollo-mavis-v2-ws/apollo-mavis-v2-hardware/.venv/bin/python
sudo $PY -m apollo_mavis_v2_hardware.netsetup install --yes   --python $PY --user mavis-v2 \
  --arm grip=192.168.1.201 --arm view=192.168.2.219
sudo $PY -m apollo_mavis_v2_hardware.netsetup install --check --python $PY --user mavis-v2 \
  --arm grip=192.168.1.201 --arm view=192.168.2.219      # 期望输出 ok
# 6) 先停掉开发者占用硬件（8765、接收器、麦克风）的运行时，再启动服务
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
systemctl --user start mavis-runtime && journalctl --user -u mavis-runtime -f
# 7) 验证 + 数据/工具
bash ~/apollo-mavis-v2-ws/scripts/deploy/healthcheck.sh    # 浏览器打开 http://127.0.0.1:8765/
DEV_USER=<开发者账号> bash ~/apollo-mavis-v2-ws/scripts/deploy/sync-data-from-dev.sh   # 把已采集数据同步过来
bash ~/apollo-mavis-v2-ws/scripts/deploy/install-ufactory-studio.sh /path/to/ufactory-studio-*.AppImage
```

要点：

- **开机不自启**，这是有意的：渲染出来的配置是 armed（可以连真机控制盒），没人在场时不该自己连上，
  而且会把接收器/麦克风/8765 从开发者实例手里抢走。要自启：
  `AUTOSTART=1 bash …/install-services.sh`。
- `su -` / `sudo -iu` **不会**给你那个账号的 D-Bus，`systemctl --user` 会报
  *Failed to connect to bus*，先 export 上面那两个变量（或者干脆用桌面 / ssh 真登录）。
- 升级：一条 `bash ~/apollo-mavis-v2-ws/scripts/deploy/update.sh`（有 session 打开时会拒绝，
  `FORCE=1` 强制；会停服务 → 拉取 → 重建 → 按 `var/lab.env` 重渲染 → 重启 → 体检）。
  **运维 checkout 里永远不要 git commit**，它必须能一直 fast-forward。
- 备份（S10）：`$DATA_ROOT/{libsurvive,calibration,profiles,mavis_v2_lab.yaml,lab.env}`、
  `/etc/apollo-mavis-v2/nic_map.json`，以及真正的录制数据 `~/data/{bc_demo,online_dagger}`。
- 示教数据在 `~/data/bc_demo/<name>`、Online DAgger session 在
  `~/data/online_dagger/<session>/{session.json,rollouts/}`（运行 runtime 那个账号的 HOME，
  用户决定放在 `var/` 之外，渲染脚本不改它们）。`DORA_BIND_HOST=wlp38s0` 才会打开 dora 外部接口
  （端口 6113 / 53391 / 7447，绝不 `0.0.0.0`）。Online DAgger 的训练在 policy 仓自己启动的
  `mavis-policy-node --online-dagger <fake|pkg.mod:make_trainer> [--trainer-config …]` 进程里（S8.5），
  skill 用 `curl -s http://<lab-host>:8765/api/online_dagger/skill.tgz | tar xz -C ~/.claude/skills/` 安装。
- **动之前先读 S7 开头那个方框**：孪生里没有现在这个房间（推车和整排厨房家具都不在 `mavis_v2` 场景里），
  两条臂和导轨本身也差 15–30 mm，碰撞门限已临时从 8 mm 提到 25 mm。任何规划出来的运动
  （回起始位、`R`、Go to profile、Home rail）都按**未验证**对待：10% 限速、手放急停。
- 改配置或升级后**必须重启** runtime。
