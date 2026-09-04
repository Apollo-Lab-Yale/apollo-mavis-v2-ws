#!/usr/bin/env bash
# S3: clone the workspace (with submodules) under $OPS_ROOT and build everything:
# four uv venvs, the out-of-lock pysurvive wheel, the UI bundle. No sudo.
# Run as the ops account or as a developer who is in group mavis (both can write
# $OPS_ROOT after create-mavis-account.sh). Whoever builds, the tree stays usable by
# the OTHER account: interpreters go to the shared $UV_PYTHON_INSTALL_DIR and git gets
# safe.directory=* (both exported by _common.sh). Idempotent: existing clone / venvs /
# wheel / dist are reused; UPDATE=1 pulls first (see S9).
#
#   bash scripts/deploy/install-stack.sh
#   UPDATE=1                  git pull --ff-only + submodule update before building
#   WITH_DEV=1                keep the dev dependency groups (pytest, ruff) in the venvs
#   PYSURVIVE_WHEEL=/path.whl use this wheel (default: newest under $OPS_ROOT/third_party/wheels,
#                             then $DATA_ROOT/wheels -- the staging dir S2 creates for the developer)
#   BUILD_PYSURVIVE=1         no wheel found -> build one with scripts/tracker/02 (network + build deps)
#   REINSTALL_PYSURVIVE=1     reinstall the wheel even if `import pysurvive` already works
#   SKIP_UI=1                 do not touch node / npm
#   UV_CACHE_DIR              point uv at a shared download cache (default: ~/.cache/uv, ~5 GB)
#   UV_PYTHON_INSTALL_DIR     interpreters (default $OPS_ROOT/.uv/python; keep it shared, see _common.sh)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

[ "$(id -u)" -ne 0 ] || die "do not run as root (venvs and dist must belong to the ops user / group)"
need_cmd git "apt install git"
need_cmd curl "apt install curl"
export PATH="$HOME/.local/bin:$PATH"

# --- uv (per user; standalone installer) -----------------------------------------------
log "uv"
if ! command -v uv >/dev/null 2>&1; then
  run sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
  hash -r
fi
note "$(uv --version) at $(command -v uv)"

# --- workspace checkout -----------------------------------------------------------------
log "workspace checkout at $OPS_ROOT"
if [ ! -d "$OPS_ROOT/.git" ]; then
  [ -d "$OPS_ROOT" ] && [ -w "$OPS_ROOT" ] || die "$OPS_ROOT missing or not writable: run create-mavis-account.sh first (and re-login if you were just added to group $OPS_GROUP)"
  [ -z "$(ls -A "$OPS_ROOT")" ] || die "$OPS_ROOT is not empty and not a git checkout"
  run git clone --recurse-submodules --branch "$WS_REF" "$WS_URL" "$OPS_ROOT"
elif [ "${UPDATE:-0}" = "1" ]; then
  run git -C "$OPS_ROOT" pull --ff-only
  run git -C "$OPS_ROOT" submodule sync --recursive
fi
# Ops checkouts stay on the commits the ws pins (detached HEAD is expected here);
# a ws commit is one known-good combination of the five repos.
run git -C "$OPS_ROOT" submodule update --init --recursive
[ -w "$OPS_ROOT" ] || die "$OPS_ROOT is not writable by $(id -un)"
note "ws $(git -C "$OPS_ROOT" rev-parse --short HEAD); submodules:"
git -C "$OPS_ROOT" submodule status | sed 's/^/    /'

# --- Python venvs ----------------------------------------------------------------------
DEV_FLAG=(--no-dev)
[ "${WITH_DEV:-0}" = "1" ] && DEV_FLAG=()
log "uv-managed interpreters (hardware pins 3.10, runtime needs >= 3.12) -> $UV_PYTHON_INSTALL_DIR"
# NOT ~/.local/share/uv/python: homes are 0750 and the venvs symlink to the interpreter,
# so a home-private copy would give EACCES to mavis-runtime.service / every other account.
case "$UV_PYTHON_INSTALL_DIR" in
  "$HOME"/*) warn "UV_PYTHON_INSTALL_DIR=$UV_PYTHON_INSTALL_DIR is inside your home: the venvs will be unusable by other accounts";;
esac
mkdir -p "$UV_PYTHON_INSTALL_DIR"
run uv python install 3.10 3.12
for repo in "$CORE_DIR" "$SIM_DIR" "$HARDWARE_DIR"; do
  log "uv sync $(basename "$repo")"
  # --locked: refuse silently drifting from uv.lock. hardware needs GitHub for the
  # xarm-python-sdk git pin.
  (cd "$repo" && run uv sync --locked "${DEV_FLAG[@]}")
done
log "uv sync apollo-mavis-v2-runtime (sim + hardware + audio extras; ~5 GB of torch/CUDA wheels on first run)"
(cd "$RUNTIME_DIR" && run uv sync --locked "${DEV_FLAG[@]}" --extra sim --extra hardware --extra audio)

# --- pysurvive (OUT of uv.lock: every plain `uv sync` above removes it) ------------------
log "pysurvive (libsurvive Python bindings, self-contained wheel)"
WHEELS_DIR="$OPS_ROOT/third_party/wheels"   # gitignored; survives git pull
STAGING_DIR="$DATA_ROOT/wheels"             # created by S2; where the developer drops the wheel
mkdir -p "$WHEELS_DIR"
WHEEL="${PYSURVIVE_WHEEL:-}"
if [ -z "$WHEEL" ]; then
  # newest wheel across the checkout and the staging dir
  WHEEL="$(ls -t "$WHEELS_DIR"/pysurvive-*-cp312-*.whl "$STAGING_DIR"/pysurvive-*-cp312-*.whl 2>/dev/null | head -1 || true)"
fi
if [ -n "$WHEEL" ] && [ "$(dirname "$(readlink -f "$WHEEL")")" != "$(readlink -f "$WHEELS_DIR")" ]; then
  run cp -n "$WHEEL" "$WHEELS_DIR/"   # keep a copy next to the venvs (S9 re-installs from there)
fi
if [ -z "$WHEEL" ] && [ "${BUILD_PYSURVIVE:-0}" = "1" ]; then
  # 02 clones cntools/libsurvive at the pinned commit, builds the cp312 wheel into
  # $WS/third_party/wheels and installs it; BUILD_SURVIVE_CLI=0 skips the CLI build.
  LIBSURVIVE_SRC="${LIBSURVIVE_SRC:-$OPS_ROOT/third_party/src/libsurvive}" \
  BUILD_SURVIVE_CLI="${BUILD_SURVIVE_CLI:-0}" \
    run bash "$OPS_ROOT/scripts/tracker/02-build-pysurvive.sh"
  WHEEL="$(ls -t "$WHEELS_DIR"/pysurvive-*-cp312-*.whl | head -1)"
fi
if [ -z "$WHEEL" ]; then
  warn "no pysurvive wheel: tracker.backend libsurvive will report status no_backend."
  warn "developer: install -m 664 <ws>/third_party/wheels/pysurvive-*.whl $STAGING_DIR/  then re-run this script (idempotent);"
  warn "or PYSURVIVE_WHEEL=/readable/path.whl, or BUILD_PYSURVIVE=1 to build one"
else
  if [ "${REINSTALL_PYSURVIVE:-0}" != "1" ] && "$RUNTIME_PY" -c "import pysurvive" 2>/dev/null; then
    note "already importable; REINSTALL_PYSURVIVE=1 forces $(basename "$WHEEL")"
  else
    # --no-deps: pysurvive declares the GUI package gooey, which the runtime never needs.
    (cd "$RUNTIME_DIR" && run uv pip install --no-deps --force-reinstall "$WHEEL")
  fi
  run "$RUNTIME_PY" -c "import pysurvive; print('    pysurvive OK from', pysurvive.__file__)"
fi

# --- UI bundle (served by the runtime via ui_dist) ----------------------------------------
if [ "${SKIP_UI:-0}" != "1" ]; then
  log "node >= 20"
  node_ok() { command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ]; }
  if ! node_ok; then
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
      run sh -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | PROFILE=/dev/null bash'
    fi
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    run nvm install 22 --no-progress
    nvm use --silent 22
  fi
  node_ok || die "node >= 20 still not available"
  note "node $(node --version), npm $(npm --version) at $(command -v node)"
  log "UI build -> $UI_DIST"
  # package-lock.json is the authoritative lockfile (pnpm-lock.yaml is a stale leftover).
  # gen:check fails on protocol drift between core's schemas and the UI's generated types.
  (cd "$UI_DIR" && run npm ci --no-audit --no-fund && run npm run gen:check && run npm run build)
  [ -f "$UI_DIST/index.html" ] || die "UI build produced no $UI_DIST/index.html"
fi

# --- smoke -----------------------------------------------------------------------------
log "import smoke tests"
run "$RUNTIME_PY" -c "import apollo_mavis_v2_core, apollo_mavis_v2_sim, apollo_mavis_v2_hardware, apollo_mavis_v2_runtime, mujoco, mink; print('    runtime venv OK; mujoco', mujoco.__version__)"
run "$HARDWARE_PY" -m apollo_mavis_v2_hardware.netsetup --help >/dev/null
note "hardware venv OK (netsetup CLI importable)"
[ "${SKIP_UI:-0}" = "1" ] || note "ui dist: $(ls -1 "$UI_DIST" | paste -sd' ')"

log "done. Next: bash scripts/deploy/render-lab-config.sh   (S4), then S5 (udev/netsetup) and S6 (services)"
