#!/usr/bin/env bash
# Developer-instance control for the MAVIS v2 runtime + Vite dev server, fully
# self-contained: the workspace root is derived from THIS script's own location and
# exported as $APOLLO_HOME, so every path the runtime touches (profiles, datasets,
# checkpoints, calibration, libsurvive config, logs, pidfiles) resolves under <ws>/var
# and NOTHING is read from or written to ~/apollo. This is the developer path; the ops
# path is the systemd units (scripts/deploy/install-services.sh) on the FHS layout.
#
#   scripts/dev/mavis-dev.sh render                 # (re)build <ws>/var/mavis_v2_local.yaml
#   scripts/dev/mavis-dev.sh start|stop|restart|status [runtime|ui]
#
# Config precedence: $MAVIS_CONFIG, else <ws>/var/mavis_v2_local.yaml if present, else
# the tracked apollo-mavis-v2-runtime/configs/mavis_v2.yaml (sim defaults: fake tracker,
# hardware_session.armed:false). `render` builds the local config from the tracked one
# plus the machine knobs in <ws>/scripts/dev/local.env (gitignored) via the deploy
# renderer with KEEP_REPO_PATHS=1, so the local config stays workspace-relative too.
# Machine-specific / safety-sensitive values (tracker yaw, libsurvive, armed) live ONLY
# in local.env + the rendered local config, both gitignored — never in a tracked file.
#
# Logs: <ws>/var/logs/runtime.log is the runtime's own rotating log (20 MB x 10, level from
# the config's `logging:` block); runtime.stderr.log is the raw process stderr (libsurvive /
# MuJoCo C prints + a pre-logging crash), vite.log the dev server.
#
# Pidfiles/logs live in <ws>/var so nothing has to pattern-match process lists (a
# `pgrep -f`/`ps | grep` from a shell whose own command line mentions the runtime kills
# that shell — it happened twice on 2026-09-04).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
export APOLLO_HOME="$WS"
VAR="$WS/var"; LOGS="$VAR/logs"; RUN="$VAR/run"; mkdir -p "$LOGS" "$RUN"
LOCAL_CONFIG="$VAR/mavis_v2_local.yaml"
REPO_CONFIG="$WS/apollo-mavis-v2-runtime/configs/mavis_v2.yaml"
if [ -n "${MAVIS_CONFIG:-}" ]; then CONFIG="$MAVIS_CONFIG"
elif [ -f "$LOCAL_CONFIG" ]; then CONFIG="$LOCAL_CONFIG"
else CONFIG="$REPO_CONFIG"; fi
what=${2:-all}
_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

render() {
  # Machine knobs (tracker backend/yaw/lighthouse count, arming) in a gitignored env
  # file so nothing machine-specific or safety-sensitive is committed. Absent -> a safe
  # sim render (fake tracker, armed:false) for a fresh clone on another machine.
  [ -f "$HERE/local.env" ] && { set -a; . "$HERE/local.env"; set +a; }
  export TRACKER_BACKEND="${TRACKER_BACKEND:-fake}" HARDWARE_ARMED="${HARDWARE_ARMED:-false}"
  # UI_DIST empty -> ui_dist:null (API-only, `start ui` runs Vite on :5173); set it in
  # local.env to serve a built SPA from the runtime instead. OPS_ROOT=$WS points the
  # deploy renderer at THIS checkout's runtime (source config + venv) instead of /opt.
  OPS_ROOT="$WS" KEEP_REPO_PATHS=1 LAB_CONFIG="$LOCAL_CONFIG" DATA_ROOT="$VAR" UI_DIST="${UI_DIST:-none}" \
    bash "$WS/scripts/deploy/render-lab-config.sh"
  echo "rendered $LOCAL_CONFIG (tracker=$TRACKER_BACKEND armed=$HARDWARE_ARMED)"
  # Seed the libsurvive lighthouse calibration from the tracked copy when the workspace has
  # none yet (self-contained fresh clone). Never overwrite: libsurvive rewrites this file on
  # every run and the wizard's install step is the only legitimate writer of a NEW one.
  local seed
  seed="$(ls -1 "$WS"/apollo-mavis-v2-runtime/configs/libsurvive/mavis_v2-lighthouses-*.json 2>/dev/null | sort | tail -1 || true)"
  if [ ! -f "$VAR/libsurvive/config.json" ] && [ -n "$seed" ]; then
    mkdir -p "$VAR/libsurvive" && cp "$seed" "$VAR/libsurvive/config.json"
    echo "seeded $VAR/libsurvive/config.json from $(basename "$seed")"
  fi
}

# Raw process stderr capture, size-guarded (one rotation at 50 MB). The runtime writes its
# OWN rotating $LOGS/runtime.log through Python logging (RuntimeConfig.logging, 2026-09-07);
# this file is the rest: libsurvive's C-side prints (the `WM0 handle_input needed 1 bytes`
# flood that marked the 2026-09-06 dead-button state lands ONLY here), MuJoCo/EGL prints,
# and a crash traceback from before logging is configured. Python log lines appear in both.
_rotate_raw() { if [ -f "$1" ] && [ "$(stat -c%s "$1")" -gt 52428800 ]; then mv -f "$1" "$1.1"; fi; }
start_runtime() {
  if _alive "$RUN/runtime.pid"; then echo "runtime already running (pid $(cat "$RUN/runtime.pid"))"; return; fi
  _rotate_raw "$LOGS/runtime.stderr.log"
  echo "=== start $(date -Is) APOLLO_HOME=$WS config $CONFIG" >> "$LOGS/runtime.stderr.log"
  ( cd "$WS/apollo-mavis-v2-runtime" && APOLLO_HOME="$WS" MUJOCO_GL=egl PYTHONUNBUFFERED=1 \
      exec nohup .venv/bin/python -m apollo_mavis_v2_runtime --config "$CONFIG" >> "$LOGS/runtime.stderr.log" 2>&1 ) &
  echo $! > "$RUN/runtime.pid"; echo "runtime started pid $(cat "$RUN/runtime.pid") config $CONFIG (log $LOGS/runtime.log, raw stderr $LOGS/runtime.stderr.log)"
}
start_ui() {
  if _alive "$RUN/vite.pid"; then echo "vite already running (pid $(cat "$RUN/vite.pid"))"; return; fi
  echo "=== start $(date -Is)" >> "$LOGS/vite.log"
  ( cd "$WS/apollo-mavis-v2-ui" && exec nohup node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 5173 >> "$LOGS/vite.log" 2>&1 ) &
  echo $! > "$RUN/vite.pid"; echo "vite started pid $(cat "$RUN/vite.pid") (log $LOGS/vite.log)"
}
stop_one() {  # $1 pidfile $2 name
  if _alive "$1"; then pid=$(cat "$1"); kill "$pid"; for _ in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid"; echo "$2 stopped (pid $pid)"; else echo "$2 not running"; fi
  rm -f "$1"
}
status() {
  echo "APOLLO_HOME=$WS  config=$CONFIG"
  for n in runtime vite; do if _alive "$RUN/$n.pid"; then echo "$n: running pid $(cat "$RUN/$n.pid")"; else echo "$n: not running"; fi; done
  curl -s -m 2 127.0.0.1:8765/api/health && echo || echo "runtime API :8765 not answering"
  curl -s -m 2 -o /dev/null -w "vite :5173 http %{http_code}\n" 127.0.0.1:5173/ || true
}
# Plain if-blocks, not `[ … ] && cmd` lists — a false test as the last command of a
# case branch makes the script exit 1 under `set -e`, so `restart` never reaches `start`.
case "${1:-status}" in
  render)  render ;;
  start)   if [ "$what" != ui ]; then start_runtime; fi; if [ "$what" != runtime ]; then start_ui; fi ;;
  stop)    if [ "$what" != ui ]; then stop_one "$RUN/runtime.pid" runtime; fi; if [ "$what" != runtime ]; then stop_one "$RUN/vite.pid" vite; fi ;;
  restart) "$0" stop "$what"; sleep 1; "$0" start "$what" ;;
  status)  status ;;
  *) echo "usage: $0 render|start|stop|restart|status [runtime|ui]"; exit 2 ;;
esac
