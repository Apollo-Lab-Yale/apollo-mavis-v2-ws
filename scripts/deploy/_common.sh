#!/usr/bin/env bash
# Shared defaults for scripts/deploy/*.sh — sourced, never executed.
# Every value can be overridden from the environment; the guide
# (docs/deploy/DEPLOYMENT.md) uses the defaults verbatim.
#
#   OPS_USER   operations account that owns the hardware at boot      (mavis)
#   OPS_ROOT   workspace checkout with the five submodules            (/opt/apollo-mavis-v2)
#   DATA_ROOT  profiles / datasets / checkpoints / calibration / libsurvive
#   ETC_DIR    netsetup system state nic_map.json (root-owned)        (/etc/apollo-mavis-v2)
#   LAB_CONFIG rendered runtime config; lives in DATA_ROOT (not /etc) so the ops account
#              can re-render it without sudo (S4/S9)               ($DATA_ROOT/mavis_v2_lab.yaml)
#   UV_PYTHON_INSTALL_DIR  uv-managed interpreters. MUST be shared: the venvs symlink to
#              them and homes are 0750, so a per-user copy breaks the ops venv for every
#              other account                                      ($OPS_ROOT/.uv/python)
#
# The side-by-side layout under OPS_ROOT is mandatory: the sub-repo pyprojects
# declare path dependencies on ../apollo-mavis-v2-core (and ../-sim, ../-hardware),
# so the venvs cannot be relocated independently of each other.

OPS_USER="${OPS_USER:-mavis}"
OPS_GROUP="${OPS_GROUP:-$OPS_USER}"
OPS_ROOT="${OPS_ROOT:-/opt/apollo-mavis-v2}"
DATA_ROOT="${DATA_ROOT:-/var/lib/apollo-mavis-v2}"
ETC_DIR="${ETC_DIR:-/etc/apollo-mavis-v2}"
LAB_CONFIG="${LAB_CONFIG:-$DATA_ROOT/mavis_v2_lab.yaml}"

WS_URL="${WS_URL:-https://github.com/Apollo-Lab-Yale/apollo-mavis-v2-ws.git}"
WS_REF="${WS_REF:-main}"

# Lab cell facts (CLAUDE.md "Hardware facts"): two control boxes, one NIC each.
GRIP_IP="${GRIP_IP:-192.168.1.201}"   # Manipulation Arm (grip): Gripper G2 + wrist cam
VIEW_IP="${VIEW_IP:-192.168.2.219}"   # Perception Arm (view): D435 + RØDE NT-USB Mini

RUNTIME_HOST="${RUNTIME_HOST:-127.0.0.1}"
RUNTIME_PORT="${RUNTIME_PORT:-8765}"

# Shared interpreters (gitignored /.uv/). uv 0.8.x honours this for `python install`
# AND for discovery, so it must be exported for every uv command against $OPS_ROOT.
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$OPS_ROOT/.uv/python}"

# Cross-account git: Ubuntu 22.04's git 2.34.1 carries the CVE-2022-24765 patches and
# refuses to work in a checkout owned by another uid ("detected dubious ownership").
# The ops clone is legitimately shared (mavis + developers in group mavis), so pass
# safe.directory=* through the environment (git >= 2.31 syntax; verified to be honoured
# by this git build). Appends to an existing GIT_CONFIG_COUNT list instead of clobbering it.
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
