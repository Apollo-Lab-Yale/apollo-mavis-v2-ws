#!/usr/bin/env bash
# Vite dev server wrapper for mavis-ui-dev.service (DEVELOPER accounts only).
# The operations UI is the built bundle served by the runtime (ui_dist); Vite is
# only for hot-reload development against a second runtime on another port.
#   UI_DIR   (default: the ui repo next to this script's workspace)
#   UI_HOST / UI_PORT      (127.0.0.1 / 5173)
#   APOLLO_RUNTIME_URL     runtime the dev server proxies /api /ws /video to
#                          (default http://localhost:8765 -- set 8766 for a dev instance)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="${UI_DIR:-$(cd "$HERE/../.." && pwd)/apollo-mavis-v2-ui}"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if ! command -v node >/dev/null 2>&1 && [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm use --silent 22 >/dev/null || nvm use --silent default >/dev/null
fi
command -v node >/dev/null 2>&1 || { echo "node not found (install node 22 via nvm)" >&2; exit 1; }
cd "$UI_DIR"
exec npm exec vite -- --host "${UI_HOST:-127.0.0.1}" --port "${UI_PORT:-5173}"
