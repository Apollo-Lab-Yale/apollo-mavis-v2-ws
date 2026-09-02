#!/usr/bin/env bash
# Vive tracker teleop: build libsurvive's Python bindings into the runtime venv (no sudo).
# docs/design/13-tracker-teleop.md §6. Re-run after a Python or libsurvive bump.
set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${LIBSURVIVE_SRC:-$HOME/opt/src/libsurvive}"
COMMIT="${LIBSURVIVE_COMMIT:-f1e6eddb669320f2a30760f4b42936bdb4306da0}"   # 2026-08-27, v1.01-204
WHEELS="$WS/third_party/wheels"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$(dirname "$SRC")"
  git clone --recurse-submodules https://github.com/cntools/libsurvive "$SRC"   # FULL clone: setup.py runs `git describe`
fi
git -C "$SRC" fetch --tags --quiet || true
git -C "$SRC" checkout --quiet "$COMMIT"
git -C "$SRC" submodule update --init --recursive --quiet
mkdir -p "$WHEELS"
echo "--- building pysurvive wheel (cp312) ..."
(cd "$WS/apollo-xarm7-runtime" && uv build --wheel --python 3.12 -o "$WHEELS" "$SRC")
WHEEL="$(ls -t "$WHEELS"/pysurvive-*-cp312-*.whl | head -1)"
echo "--- installing $WHEEL into the runtime venv (no deps: pysurvive declares the GUI package gooey)"
(cd "$WS/apollo-xarm7-runtime" && uv pip install --no-deps --force-reinstall "$WHEEL")
(cd "$WS/apollo-xarm7-runtime" && uv run python -c "import pysurvive, sys; print('pysurvive OK from', pysurvive.__file__)")
if [ "${BUILD_SURVIVE_CLI:-1}" = "1" ]; then
  echo "--- building survive-cli (calibration / inspection) into ~/opt/libsurvive ..."
  cmake -G Ninja -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOME/opt/libsurvive" >/dev/null
  ninja -C "$SRC/build" install >/dev/null
  echo "    ~/opt/libsurvive/bin/survive-cli --v 100 --lighthousecount 2   # first run = calibration (~10-20 s, tracker still)"
fi
echo "--- done. Set  tracker: {backend: libsurvive}  in the runtime config (configs/mavis_v2.yaml)."
