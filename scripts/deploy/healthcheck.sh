#!/usr/bin/env bash
# S7: read-only verification of a running runtime (ops or dev). Exit 0 = every check
# passed, 1 = something to look at. Uses curl + the system python3 (json) and, when
# the runtime venv is present, one telemetry frame over /ws/telemetry for the tracker.
#   bash scripts/deploy/healthcheck.sh                 # 127.0.0.1:8765
#   RUNTIME_HOST=... RUNTIME_PORT=8766 bash scripts/deploy/healthcheck.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"
BASE="http://$RUNTIME_HOST:$RUNTIME_PORT"
FAIL=0
ok()   { printf '[OK ] %s\n' "$*"; }
bad()  { printf '[BAD] %s\n' "$*"; FAIL=1; }
get()  { curl -sS -m 5 "$BASE$1"; }

log "runtime at $BASE"
H="$(get /api/health)" || { bad "GET /api/health failed (service down? port?)"; exit 1; }
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["status"]=="ok"; print("    version", d["version"], "epoch", d["epoch"][:8])' "$H" && ok "/api/health" || bad "/api/health: $H"

W="$(get '/api/workcell?kind=hardware')"
python3 - "$W" <<'PYEOF' || FAIL=1
import json, sys
d = json.loads(sys.argv[1])
rc = 0
for a in d.get("arms", []):
    mark = "OK " if a["reachable"] == "open" else "BAD"
    if mark == "BAD": rc = 1
    print(f"[{mark}] arm {a['arm_id']} {a['ip']} reachable={a['reachable']} gripper={a['gripper']} rail={a['has_rail']}")
for c in d.get("cameras", []):
    print(f"[{'OK ' if c['live'] else 'note'}] camera {c['camera_id']} live={c['live']}" + ("" if c["live"] else " (camera unplugged, or its USB serial is not the one in configs/mavis_v2.yaml)"))
print(f"[{'OK ' if d.get('hardware_ready') else 'BAD'}] hardware_ready={d.get('hardware_ready')}")
sys.exit(rc)
PYEOF

M="$(get /api/microphones)"
python3 - "$M" <<'PYEOF' || FAIL=1
import json, sys
mics = json.loads(sys.argv[1])
if not mics:
    print("[note] no microphone configured"); sys.exit(0)
rc = 0
for m in mics:
    mark = "OK " if m["live"] else "BAD"; rc |= (mark == "BAD")
    print(f"[{mark}] microphone {m['mic_id']} status={m['status']} source={m.get('source','')} {m.get('detail','')}")
sys.exit(rc)
PYEOF

C="$(get /api/tracker/calibration)"
python3 - "$C" <<'PYEOF' || FAIL=1
import json, sys
d = json.loads(sys.argv[1])
mark = "OK " if d["yaw_valid"] else "BAD"
src = "wizard" if d["yaw_calibrated_at"] else "YAML yaw_deg (estimate; run the Yaw alignment wizard)"
print(f"[{mark}] tracker yaw_valid={d['yaw_valid']} applied_yaw_deg={d['applied_yaw_deg']} "
      f"source={src} base_station_installed_at={d['base_station_installed_at']}")
sys.exit(0 if d["yaw_valid"] else 1)
PYEOF

if [ -x "$RUNTIME_PY" ]; then
  "$RUNTIME_PY" - "ws://$RUNTIME_HOST:$RUNTIME_PORT/ws/telemetry" <<'PYEOF' || FAIL=1
import asyncio, json, sys
import websockets
async def main():
    async with websockets.connect(sys.argv[1], max_size=None, open_timeout=5) as ws:
        d = json.loads(await asyncio.wait_for(ws.recv(), 5))
    t = d.get("tracker") or {}
    good = t.get("status") in ("tracking", "searching")  # searching = controller off/asleep, backend fine
    print(f"[{'OK ' if good else 'BAD'}] tracker backend={t.get('backend')} status={t.get('status')} rate_hz={t.get('rate_hz', 0):.0f} {t.get('detail','')}")
    return 0 if good else 1
sys.exit(asyncio.run(main()))
PYEOF
else
  note "runtime venv not at $RUNTIME_PY: tracker status not checked (see telemetry in the UI)"
fi

S="$(curl -sS -m 5 -o /dev/null -w '%{http_code} %{content_type}' "$BASE/")"
case "$S" in 200*text/html*) ok "UI served by the runtime at $BASE/ ($S)";; *) bad "GET $BASE/ -> $S (ui_dist unset or dist missing: API-only)";; esac

[ "$FAIL" = 0 ] && log "all checks passed" || log "some checks FAILED (see above; S11 troubleshooting)"
exit "$FAIL"
