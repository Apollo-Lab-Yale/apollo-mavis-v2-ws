#!/usr/bin/env bash
# S4: write the lab runtime config $LAB_CONFIG ($DATA_ROOT/mavis_v2_lab.yaml, i.e.
# /var/lib/apollo-mavis-v2/mavis_v2_lab.yaml) from the repo config
# apollo-mavis-v2-runtime/configs/mavis_v2.yaml, overriding only what differs between
# "developer sim defaults" and "operations on the real cell": absolute shared paths,
# ui_dist, host/port, the lab tracker settings that so far lived only in the developer's
# volatile /tmp/mavis_v2_live.yaml (backend libsurvive, --lighthousecount 3, yaw_deg
# 116.3, rail_in_ik false), the arm IPs and (when given) the camera USB serials. The
# result is validated with the runtime's own config model before it is installed.
# Idempotent. NO sudo: LAB_CONFIG lives in the mavis-owned $DATA_ROOT so the ops
# account can re-render alone (S9); sudo is used only if LAB_CONFIG points into a
# directory the caller cannot write (e.g. /etc).
#
#   bash scripts/deploy/render-lab-config.sh            # render, diff, validate, install
#   DRY_RUN=1 bash scripts/deploy/render-lab-config.sh  # render + diff only, print YAML
#   LAB_CONFIG=/tmp/x.yaml ...                          # install somewhere else
# Knobs (env): TRACKER_BACKEND=libsurvive LIGHTHOUSE_COUNT=3 TRACKER_YAW_DEG=116.3
#   RAIL_IN_IK=false MIC_ENABLED=true EGL_DEVICE_ID=0 RUNTIME_HOST RUNTIME_PORT UI_DIST
#   LIBSURVIVE_CONFIG=$DATA_ROOT/libsurvive/config.json GRIP_IP VIEW_IP
#   CAMERA_SERIALS="grip_wrist=349643062582,view_wrist=322143060792"
#                       override workcells.hardware.cameras[].serial by camera id (the repo
#                       maps the two RealSense USB serials to the arms; swap here as a
#                       stop-gap if the Hardware-tab tiles are crossed). Unknown id = error.
#   TRAINER_PORT=5758   dagger.trainer.port for a second (developer) instance
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

SRC_CONFIG="${SRC_CONFIG:-$RUNTIME_DIR/configs/mavis_v2.yaml}"
[ -f "$SRC_CONFIG" ] || die "source config not found: $SRC_CONFIG (run install-stack.sh first)"

# Prefer the runtime venv (validates with RuntimeConfig); fall back to any python3+PyYAML.
if [ -x "$RUNTIME_PY" ]; then PY="$RUNTIME_PY"; VALIDATE=1
else PY="$(command -v python3)"; VALIDATE=0; warn "runtime venv not found; rendering without model validation"; fi
"$PY" -c "import yaml" 2>/dev/null || die "$PY lacks PyYAML"

export SRC_CONFIG DATA_ROOT UI_DIST RUNTIME_HOST RUNTIME_PORT GRIP_IP VIEW_IP
export TRACKER_BACKEND="${TRACKER_BACKEND:-libsurvive}"
export LIGHTHOUSE_COUNT="${LIGHTHOUSE_COUNT:-3}"
export TRACKER_YAW_DEG="${TRACKER_YAW_DEG:-116.3}"
export RAIL_IN_IK="${RAIL_IN_IK:-false}"
export MIC_ENABLED="${MIC_ENABLED:-true}"
export EGL_DEVICE_ID="${EGL_DEVICE_ID:-0}"
export LIBSURVIVE_CONFIG="${LIBSURVIVE_CONFIG:-$DATA_ROOT/libsurvive/config.json}"
export CAMERA_SERIALS="${CAMERA_SERIALS:-}"
export TRAINER_PORT="${TRAINER_PORT:-}"
export SRC_COMMIT
SRC_COMMIT="$(git -C "$(dirname "$SRC_CONFIG")" rev-parse --short HEAD 2>/dev/null || echo unknown)"

TMP="$(mktemp --suffix=.yaml)"
trap 'rm -f "$TMP"' EXIT

log "render $SRC_CONFIG -> $TMP"
"$PY" - "$SRC_CONFIG" "$TMP" <<'PYEOF'
import datetime as dt
import os
import sys

import yaml

src, out = sys.argv[1], sys.argv[2]
env = os.environ
with open(src, encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

def flag(name):
    return env[name].strip().lower() in ("1", "true", "yes", "on")

overrides = []
def setv(path, value):
    node = data
    for key in path[:-1]:
        node = node[key] if isinstance(node, list) else node.setdefault(key, {})
    old = node[path[-1]] if isinstance(node, list) else node.get(path[-1], "<absent>")
    node[path[-1]] = value
    if old != value:  # list only real overrides; pinned-but-equal values stay quiet
        overrides.append((".".join(str(k) for k in path), old, value))

setv(("host",), env["RUNTIME_HOST"])
setv(("port",), int(env["RUNTIME_PORT"]))
setv(("ui_dist",), env["UI_DIST"])
for key, sub in (("profiles_dir", "profiles"), ("datasets_root", "datasets"),
                 ("checkpoints_root", "checkpoints"), ("calibration_dir", "calibration")):
    setv((key,), f"{env['DATA_ROOT']}/{sub}")
setv(("control", "rail_in_ik"), flag("RAIL_IN_IK"))
setv(("tracker", "backend"), env["TRACKER_BACKEND"])
args = list(data.get("tracker", {}).get("libsurvive_args") or [])
if "--lighthousecount" in args:
    args[args.index("--lighthousecount") + 1] = env["LIGHTHOUSE_COUNT"]
else:
    args = ["--lighthousecount", env["LIGHTHOUSE_COUNT"], *args]
for frozen in ("--globalscenesolver", "--disable-calibrate"):  # never let teleop recalibrate
    if frozen not in args:
        args += [frozen, "0" if frozen == "--globalscenesolver" else "1"]
setv(("tracker", "libsurvive_args"), args)
setv(("tracker", "libsurvive_config_path"), env["LIBSURVIVE_CONFIG"])
setv(("tracker", "yaw_deg"), float(env["TRACKER_YAW_DEG"]))
setv(("microphone", "enabled"), flag("MIC_ENABLED"))
setv(("egl_device_id",), int(env["EGL_DEVICE_ID"]))
if env["TRAINER_PORT"]:
    setv(("dagger", "trainer", "port"), int(env["TRAINER_PORT"]))

hw = data.get("workcells", {}).get("hardware")
if not hw:
    sys.exit("source config has no workcells.hardware block")
ips = {"grip": env["GRIP_IP"], "view": env["VIEW_IP"]}
for i, arm in enumerate(hw.get("arms", [])):
    if arm.get("id") in ips and arm.get("ip") != ips[arm["id"]]:
        setv(("workcells", "hardware", "arms", i, "ip"), ips[arm["id"]])
# Cameras are matched by USB serial (core CameraConfig.serial, sysfs lookup); the repo
# config carries the lab mapping. CAMERA_SERIALS only overrides serials of ids that exist.
cam_ids = [cam.get("id") for cam in hw.get("cameras", [])]
for item in filter(None, (s.strip() for s in env["CAMERA_SERIALS"].split(","))):
    cam_id, sep, serial = item.partition("=")
    if not sep or not serial:
        sys.exit(f"CAMERA_SERIALS: expected id=serial, got {item!r}")
    if cam_id not in cam_ids:
        sys.exit(f"CAMERA_SERIALS: no camera with id {cam_id!r} in {src} (have {cam_ids})")
    i = cam_ids.index(cam_id)
    if hw["cameras"][i].get("kind") not in ("v4l2", "realsense"):
        sys.exit(f"CAMERA_SERIALS: camera {cam_id!r} is kind {hw['cameras'][i].get('kind')!r}, has no serial")
    if hw["cameras"][i].get("serial") != serial:
        setv(("workcells", "hardware", "cameras", i, "serial"), serial)

header = [
    "# MAVIS v2 LAB runtime config -- GENERATED by scripts/deploy/render-lab-config.sh",
    f"# on {dt.date.today().isoformat()} from {src} (runtime commit {env['SRC_COMMIT']}).",
    "# Re-render instead of editing (S4/S9 in docs/deploy/DEPLOYMENT.md); the source",
    "# file carries the per-key documentation that yaml.safe_dump drops. Overrides:",
]
for path, old, new in overrides:
    header.append(f"#   {path}: {old!r} -> {new!r}")
body = yaml.safe_dump(data, sort_keys=False, default_flow_style=False, allow_unicode=True, width=100)
with open(out, "w", encoding="utf-8") as fh:
    fh.write("\n".join(header) + "\n" + body)
print("\n".join(header[4:]))
PYEOF

if [ "$VALIDATE" = "1" ]; then
  log "validate with apollo_mavis_v2_runtime.config.load_runtime_config"
  (cd "$RUNTIME_DIR" && "$PY" - "$TMP" <<'PYEOF'
import sys
from apollo_mavis_v2_runtime.config import load_runtime_config
cfg = load_runtime_config(sys.argv[1])
hw = cfg.workcells["hardware"]
print(f"    ok: host={cfg.host}:{cfg.port} ui_dist={cfg.ui_dist} tracker={cfg.tracker.backend} "
      f"yaw={cfg.tracker.yaw_deg} args={' '.join(cfg.tracker.libsurvive_args)}")
print(f"    arms: {', '.join(f'{a.id}@{a.ip}' for a in hw.arms)}; profiles_dir={cfg.profiles_dir}")
print(f"    cameras: {', '.join(f'{c.id}={c.kind}:{c.serial or c.device_path}:{c.fourcc}' for c in hw.cameras) or 'none'}")
for p in (cfg.ui_dist, cfg.tracker.libsurvive_config_path):
    if p is not None and not p.exists():
        print(f"    note: {p} does not exist yet")
PYEOF
  )
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "DRY_RUN: rendered YAML"
  cat "$TMP"
  exit 0
fi

log "install -> $LAB_CONFIG"
if [ -f "$LAB_CONFIG" ] && cmp -s <(grep -v '^# on ' "$TMP") <(grep -v '^# on ' "$LAB_CONFIG"); then
  note "unchanged"
else
  if [ -f "$LAB_CONFIG" ]; then
    log "diff (installed -> new)"
    diff -u "$LAB_CONFIG" "$TMP" || true
  fi
  DEST_DIR="$(dirname "$LAB_CONFIG")"
  [ -d "$DEST_DIR" ] || mkdir -p "$DEST_DIR" 2>/dev/null || true
  if [ -w "$DEST_DIR" ]; then run install -m 664 "$TMP" "$LAB_CONFIG"   # group mavis keeps write access
  else warn "$DEST_DIR is not writable by $(id -un): installing via sudo"; as_root install -m 644 -o root -g root "$TMP" "$LAB_CONFIG"; fi
fi
note "runtime reads it via --config / \$APOLLO_CONFIG (mavis-runtime.service sets both)"
log "done. Restart the service to apply: systemctl --user restart mavis-runtime   (as $OPS_USER)"
