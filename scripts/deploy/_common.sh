#!/usr/bin/env bash
# Shared defaults for scripts/deploy/*.sh — sourced, never executed.
# Every value can be overridden from the environment; the guide
# (docs/deploy/DEPLOYMENT.md) and the workspace README use the defaults verbatim.
#
# Layout (2026-09-09, operator decision): the stack runs under the SHARED lab account
# `mavis-v2` and lives entirely inside that account's HOME — one workspace checkout with
# the five submodules, its runtime data in <checkout>/var (gitignored, the same layout the
# developer launcher scripts/dev/mavis-dev.sh uses), demonstrations in ~/data. Nothing under
# /opt, /var/lib or another account's home; the ops tree is refreshed from the PUBLIC GitHub
# repos over anonymous HTTPS (scripts/deploy/update.sh), so no GitHub login of any person
# ever sits on the shared account. The pre-2026-09-09 FHS layout (`mavis`,
# /opt/apollo-mavis-v2, /var/lib/apollo-mavis-v2) is still reachable through these knobs.
#
#   OPS_USER   shared account that owns the hardware at boot                 (mavis-v2)
#   OPS_HOME   its home                                                      (/home/$OPS_USER)
#   OPS_ROOT   workspace checkout with the five submodules                   ($OPS_HOME/apollo-mavis-v2-ws)
#   DATA_ROOT  profiles / datasets / checkpoints / calibration / libsurvive / logs / dora
#                                                                            ($OPS_ROOT/var)
#   LAB_CONFIG rendered runtime config                                       ($DATA_ROOT/mavis_v2_lab.yaml)
#   LAB_ENV    optional env file of render knobs (DORA_BIND_HOST, CAMERA_SERIALS, ...) that
#              render-lab-config.sh sources; variables already in the environment win
#                                                                            ($DATA_ROOT/lab.env)
#   ETC_DIR    netsetup system state nic_map.json (root-owned)               (/etc/apollo-mavis-v2)
#   UV_PYTHON_INSTALL_DIR  uv-managed interpreters the four venvs symlink to  ($OPS_ROOT/.uv/python)
#
# The side-by-side layout under OPS_ROOT is mandatory: the sub-repo pyprojects
# declare path dependencies on ../apollo-mavis-v2-core (and ../-sim, ../-hardware),
# so the venvs cannot be relocated independently of each other.

OPS_USER="${OPS_USER:-mavis-v2}"
OPS_GROUP="${OPS_GROUP:-$OPS_USER}"
OPS_HOME="${OPS_HOME:-$(getent passwd "$OPS_USER" 2>/dev/null | cut -d: -f6)}"
OPS_HOME="${OPS_HOME:-/home/$OPS_USER}"
OPS_ROOT="${OPS_ROOT:-$OPS_HOME/apollo-mavis-v2-ws}"
DATA_ROOT="${DATA_ROOT:-$OPS_ROOT/var}"
ETC_DIR="${ETC_DIR:-/etc/apollo-mavis-v2}"
LAB_CONFIG="${LAB_CONFIG:-$DATA_ROOT/mavis_v2_lab.yaml}"
LAB_ENV="${LAB_ENV:-$DATA_ROOT/lab.env}"

WS_URL="${WS_URL:-https://github.com/Apollo-Lab-Yale/apollo-mavis-v2-ws.git}"
WS_REF="${WS_REF:-main}"

# Lab cell facts (CLAUDE.md "Hardware facts"): two control boxes, one NIC each.
GRIP_IP="${GRIP_IP:-192.168.1.201}"   # Manipulation Arm (grip): Gripper G2 + wrist cam
VIEW_IP="${VIEW_IP:-192.168.2.219}"   # Perception Arm (view): D435 + RØDE NT-USB Mini

RUNTIME_HOST="${RUNTIME_HOST:-127.0.0.1}"
RUNTIME_PORT="${RUNTIME_PORT:-8765}"

# Interpreters next to the venvs (gitignored /.uv/). uv 0.8.x honours this for `python
# install` AND for discovery, so it must be exported for every uv command against $OPS_ROOT.
# With the checkout inside the ops account's home only that account uses the venvs, which
# is the point of the layout; anyone else works from their own clone.
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$OPS_ROOT/.uv/python}"

# Cross-account git: Ubuntu 22.04's git 2.34.1 carries the CVE-2022-24765 patches and
# refuses to work in a checkout owned by another uid ("detected dubious ownership").
# Harmless for the single-account layout; needed when a sudoer inspects the ops tree.
# Appends to an existing GIT_CONFIG_COUNT list instead of clobbering it.
_gc="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${_gc}=safe.directory" "GIT_CONFIG_VALUE_${_gc}=*" GIT_CONFIG_COUNT="$((_gc + 1))"
unset _gc

RUNTIME_DIR="$OPS_ROOT/apollo-mavis-v2-runtime"
HARDWARE_DIR="$OPS_ROOT/apollo-mavis-v2-hardware"
SIM_DIR="$OPS_ROOT/apollo-mavis-v2-sim"
CORE_DIR="$OPS_ROOT/apollo-mavis-v2-core"
UI_DIR="$OPS_ROOT/apollo-mavis-v2-ui"
RUNTIME_PY="$RUNTIME_DIR/.venv/bin/python"
HARDWARE_PY="$HARDWARE_DIR/.venv/bin/python"
UI_DIST="${UI_DIST:-$UI_DIR/dist}"

# Data subdirectories the runtime expects under DATA_ROOT (created by install-stack.sh
# after the clone and by install-services.sh; all gitignored via /var/*).
DATA_SUBDIRS=(profiles datasets checkpoints calibration libsurvive logs wheels)

log()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# Print the command, then run it (scripts must show what they do).
run()  { printf '+ %s\n' "$*"; "$@"; }
# Run as root: directly when already root, otherwise through sudo.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else run sudo "$@"; fi
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1 ($2)"; }
# systemctl --user against the ops account's user manager. `su -` / `sudo -iu` do not export
# the bus address; a lingering or logged-in account has /run/user/<uid>.
ops_user_env() {
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
}
# True when path $1 lies inside directory $2 (both taken literally, no symlink resolution).
path_inside() { case "$1" in "$2"|"$2"/*) return 0;; *) return 1;; esac; }
