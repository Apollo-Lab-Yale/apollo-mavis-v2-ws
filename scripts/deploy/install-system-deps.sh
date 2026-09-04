#!/usr/bin/env bash
# S1 + S5 (system side): apt packages, inotify sysctl, udev rules for the Vive
# dongle / gamepad (via scripts/tracker/01-sudo-udev-and-deps.sh), toolchain checks.
# Run as a sudo-capable user (NOT as root): every privileged step goes through
# sudo explicitly. Idempotent: re-running changes nothing that is already in place.
#
#   bash scripts/deploy/install-system-deps.sh
#   FORCE_UDEV=1 ...      re-run scripts/tracker/01 even if the rule file exists
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

[ "$(id -u)" -ne 0 ] || die "run as your own account (the script calls sudo itself)"
need_cmd sudo "apt install sudo"

# Everything the stack links against or shells out to. All of these are already
# installed on apollo-pc-1 (dpkg-query 2026-09-04); the list is the reproducible record.
APT_PKGS=(
  # build tools (libsurvive / pysurvive wheel, native Python deps)
  build-essential cmake ninja-build pkg-config git curl ca-certificates
  zlib1g-dev libx11-dev libusb-1.0-0-dev libeigen3-dev libopenblas-dev liblapacke-dev
  libatlas-base-dev libudev-dev
  # audio: the RØDE is captured through PulseAudio only (pactl/parec + PortAudio 'pulse' plugin)
  libportaudio2 pulseaudio pulseaudio-utils alsa-utils
  # headless rendering (MuJoCo EGL on the NVIDIA driver) + video encode
  libegl1 libgl1 libgles2 libglvnd0 ffmpeg
  # v4l2-ctl --list-devices: list the RealSense v4l2 nodes when checking the serial->arm mapping (S4)
  v4l-utils
  # arm NICs are NetworkManager profiles; acl for the shared-directory defaults
  network-manager udev acl
)

log "apt packages (${#APT_PKGS[@]})"
run sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${APT_PKGS[@]}"

log "inotify watch limit (Vite dev servers / large checkouts; system-wide, all accounts)"
SYSCTL_FILE=/etc/sysctl.d/60-inotify.conf
if grep -qs '^fs.inotify.max_user_watches=524288' "$SYSCTL_FILE"; then
  note "$SYSCTL_FILE already sets fs.inotify.max_user_watches=524288"
else
  printf 'fs.inotify.max_user_watches=524288\n' | run sudo tee "$SYSCTL_FILE" >/dev/null
  run sudo sysctl -q -p "$SYSCTL_FILE"
fi
note "current: $(sysctl -n fs.inotify.max_user_watches) watches, $(sysctl -n fs.inotify.max_user_instances) instances"

log "udev rules for the Watchman dongle (28de:2101 -> group plugdev) and the gamepad (-> group input)"
UDEV_RULES=/etc/udev/rules.d/60-apollo-teleop-input.rules
if [ "${FORCE_UDEV:-0}" != "1" ] && grep -qs 'idProduct}=="2101".*GROUP="plugdev"' "$UDEV_RULES"; then
  note "$UDEV_RULES already installed (FORCE_UDEV=1 re-runs scripts/tracker/01)"
else
  # 01 apt-installs its build deps (already covered above), writes the rule file,
  # reloads udev and adds *the invoking user* to plugdev,input. The ops account
  # gets its groups from create-mavis-account.sh instead.
  run bash "$WS/scripts/tracker/01-sudo-udev-and-deps.sh"
fi
# RealSense nodes come from librealsense2-udev-rules (0666, group plugdev) — nothing to add.

log "NVIDIA driver / EGL"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=driver_version,name --format=csv,noheader >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,driver_version,pci.bus_id --format=csv,noheader | sed 's/^/    GPU /'
else
  warn "nvidia-smi missing or failing: install the NVIDIA driver (580.x is deployed on apollo-pc-1) before continuing"
fi
if [ -f /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]; then
  note "EGL vendor ICD present: /usr/share/glvnd/egl_vendor.d/10_nvidia.json"
else
  warn "EGL vendor ICD /usr/share/glvnd/egl_vendor.d/10_nvidia.json missing (MUJOCO_GL=egl will fail)"
fi
note "render nodes: $(ls -l /dev/dri/renderD* 2>/dev/null | awk '{print $1, $3":"$4, $NF}' | paste -sd ';')"
note "(root:render 0660 -> the ops account needs group 'render'; uaccess ACLs only cover the seat owner)"

log "toolchain notes (per-user tools are installed by install-stack.sh, not here)"
if command -v uv >/dev/null 2>&1; then note "uv: $(uv --version) at $(command -v uv)"; else note "uv: not on PATH for $(id -un) (install-stack.sh installs it per user)"; fi
if command -v node >/dev/null 2>&1; then
  note "node: $(node --version) at $(command -v node) (need >= 20; Ubuntu's apt nodejs 12 is unusable)"
else
  note "node: not on PATH for $(id -un) (install-stack.sh installs node 22 via nvm per user)"
fi
note "python3: $(python3 --version 2>&1) (system; uv manages 3.10 + 3.12 for the venvs)"

log "done. Next: sudo -v && bash scripts/deploy/create-mavis-account.sh"
