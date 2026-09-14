#!/bin/bash
# start | stop | status the PRIVATE SIM dry-run runtime of 14-dora §16.6 (port 8866, its own
# dora plane 6213 / 53491 / 7547, fake tracker + fake mic, no hardware workcell): it never
# touches the control boxes, PulseAudio, the Vive dongle or port 8765 of the production
# runtime, so it is safe to run beside one. Prove a replay configuration here first.
#
#   scripts/dev/dryrun_ctl.sh start | stop | status
#
# It seeds its own tree under ${APOLLO_HOME}/var/dryrun-inference (gitignored) from the
# tracked mavis_v2_dryrun.yaml beside this script. Never `uv run` (CLAUDE.md).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"          # absolute: survives any cwd
WS="$(cd "$HERE/../.." && pwd)"                # the workspace root, not an assumed $HOME path
D=$WS/var/dryrun-inference
CFG=$D/mavis_v2_dryrun.yaml
PIDF=$D/run/runtime.pid
mkdir -p "$D"/{run,logs,profiles,datasets,checkpoints,calibration,libsurvive,online_dagger,dora,runs}
[ -f "$CFG" ] || { cp "$HERE/mavis_v2_dryrun.yaml" "$CFG" && echo "seeded $CFG"; }
case "$1" in
  start)
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then echo "already running $(cat "$PIDF")"; exit 0; fi
    echo "=== start $(date -Is)" >> "$D/logs/runtime.stderr.log"
    ( cd "$WS/apollo-mavis-v2-runtime" && APOLLO_HOME="$WS" MUJOCO_GL=egl PYTHONUNBUFFERED=1 \
        OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 \
        exec nohup .venv/bin/python -m apollo_mavis_v2_runtime --config "$CFG" \
        >> "$D/logs/runtime.stderr.log" 2>&1 ) &
    echo $! > "$PIDF"
    echo "started $(cat "$PIDF"), waiting for :8866"
    for i in $(seq 1 60); do
      if curl -s -m 2 http://127.0.0.1:8866/api/health >/dev/null 2>&1; then
        echo "up after ${i}s: $(curl -s http://127.0.0.1:8866/api/health)"; exit 0; fi
      sleep 1
    done
    echo "NOT up after 60s; tail:"; tail -30 "$D/logs/runtime.stderr.log"; exit 1;;
  stop)
    [ -f "$PIDF" ] || { echo "no pidfile"; exit 0; }
    P=$(cat "$PIDF"); kill "$P" 2>/dev/null
    for i in $(seq 1 30); do kill -0 "$P" 2>/dev/null || break; sleep 1; done
    kill -0 "$P" 2>/dev/null && kill -9 "$P"
    rm -f "$PIDF"; echo "stopped $P";;
  status)
    [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null && echo "running $(cat "$PIDF")" || echo "not running"
    curl -s -m 3 http://127.0.0.1:8866/api/health; echo
    curl -s -m 3 http://127.0.0.1:8866/api/dora; echo;;
  *) echo "usage: $0 start|stop|status"; exit 2;;
esac
