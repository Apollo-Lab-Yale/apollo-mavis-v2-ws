#!/usr/bin/env bash
# Vive tracker teleop: are the calibrated lighthouse poses mutually consistent?
# docs/design/13-tracker-teleop.md §6.  Diagnosis 2026-09-03: the "pose snaps back
# while moving" symptom was libsurvive flipping between per-lighthouse solutions
# that disagree by 10-25 cm (inconsistent LH calibration). A STILL controller hides
# this because MPFIT switches to a 1 s sensor window after 1 s of stillness; while
# MOVING it uses a 33.6 ms window, i.e. whichever station swept last decides the fix.
#
# This script records (or takes) a libsurvive raw capture of a STILL controller and
# replays it offline with the moving-mode window forced on, for all lighthouses and
# leave-one-out, and prints the scatter of the fixes. Consistent calibration =>
# std of a few mm in every column and near-zero offsets between the columns.
# Inconsistent => cm-level std / max steps with all LHs, collapsing when one LH is left out.
# Nothing here touches the live libsurvive config (temp copies, scene solver off).
# The config under test is $LIBSURVIVE_CONFIG, else the WORKSPACE copy the runtime hands
# libsurvive (<ws>/var/libsurvive/config.json, self-contained since 2026-09-07), else the
# legacy ~/.config/libsurvive/config.json.
#
# usage: 03-lh-consistency-check.sh [SECONDS | existing.rec]      (default: record 20 s)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="${APOLLO_HOME:-$(cd "$HERE/../.." && pwd)}"
LIBSURVIVE="${LIBSURVIVE_PREFIX:-$HOME/opt/libsurvive}"
CLI="$LIBSURVIVE/bin/survive-cli"
if [ -n "${LIBSURVIVE_CONFIG:-}" ]; then CFG="$LIBSURVIVE_CONFIG"
elif [ -f "$WS/var/libsurvive/config.json" ]; then CFG="$WS/var/libsurvive/config.json"
else CFG="$HOME/.config/libsurvive/config.json"; fi
LH_COUNT="${LIGHTHOUSE_COUNT:-3}"
WORK="$(mktemp -d /tmp/lh-check-XXXXXX)"
export LD_LIBRARY_PATH="$LIBSURVIVE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# survive-cli looks for <dir-of-$SURVIVE_PLUGINS>/plugins; the install puts them in lib/libsurvive.
ln -s "$LIBSURVIVE/lib/libsurvive" "$WORK/plugins"
export SURVIVE_PLUGINS="$WORK/x"

REC="${1:-20}"
if [[ ! -f "$REC" ]]; then
  SECS="$REC"; REC="$WORK/still.rec"
  echo "--- recording $SECS s (keep the controller STILL, powered on, dongle attached; the runtime must NOT be running)"
  cp "$CFG" "$WORK/cfg_record.json"
  timeout "$((SECS + 5))" "$CLI" --configfile "$WORK/cfg_record.json" --lighthousecount "$LH_COUNT" \
    --globalscenesolver 0 --disable-calibrate 1 --run-time "$SECS" --v 5 --record "$REC" \
    > "$WORK/record.log" 2>&1 || true
  grep -E "^Info: \s+LH\s+[0-9]|Syncs:|Hits:" "$WORK/record.log" | tr -s ' ' | paste - - - | sed 's/Info: //' || true
  echo "    (stations listed above are the ones the controller actually saw; recording: $REC)"
fi

replay() { # name, extra flags...
  local name="$1"; shift
  cp "$CFG" "$WORK/cfg_$name.json"
  "$CLI" --configfile "$WORK/cfg_$name.json" --playback "$REC" --playback-factor 0 --v 5 \
    --globalscenesolver 0 --disable-calibrate 1 --record "$WORK/rep_$name.rec" "$@" > "$WORK/rep_$name.log" 2>&1 || true
}
echo "--- replaying (rest window = what you see when still; moving window = what teleop sees)"
replay rest_window
replay moving_window --use-stationary-sensor-window 0
N_LH=$(grep -c '"lighthouse[0-9]"' "$CFG" || true)
for ((i = 0; i < N_LH; i++)); do
  replay "moving_without_lh$i" --use-stationary-sensor-window 0 --disable-lighthouse "$i"
done

python3 - "$WORK" "$CFG" <<'EOF'
import sys, glob, os, re, numpy as np
work, cfg = sys.argv[1], sys.argv[2]
modes = dict(re.findall(r'"lighthouse(\d)":\{[^}]*?"mode":"(\d+)"', open(cfg).read(), re.S))
def load(path):
    T, P = [], []
    for line in open(path, errors="replace"):
        f = line.split()
        if len(f) > 9 and f[1] == "WM0" and f[2] == "POSE":
            T.append(float(f[0])); P.append([float(x) for x in f[3:6]])
    T, P = np.array(T), np.array(P)
    if len(T) < 50: return None
    m = T > T[0] + 3.0  # skip convergence
    return P[m]
rows = {}
for path in sorted(glob.glob(os.path.join(work, "rep_*.rec"))):
    name = os.path.basename(path)[4:-4]
    P = load(path)
    if P is None: print(f"{name:22s} no poses"); continue
    d = np.linalg.norm(np.diff(P, axis=0), axis=1) * 1000
    rows[name] = P
    label = name
    m = re.match(r"moving_without_lh(\d)", name)
    if m: label = f"moving w/o LH{m.group(1)} (ch{modes.get(m.group(1), '?')})"
    print(f"{label:26s} n={len(P):5d}  std mm={np.round(P.std(0)*1000,1)}  steps>20mm={int((d>20).sum()):4d}  max step mm={d.max():6.1f}  mean={np.round(P.mean(0),3)}")
names = [n for n in rows if n.startswith("moving_without")]
for i in range(len(names)):
    for j in range(i + 1, len(names)):
        off = (rows[names[j]].mean(0) - rows[names[i]].mean(0)) * 1000
        print(f"offset {names[j]} - {names[i]}: {np.round(off,1)} mm  |{np.linalg.norm(off):.1f}| mm")
print("\nverdict: consistent calibration = all 'moving' rows within a few mm std and offsets < ~5 mm.")
print(f"work dir kept: {work}")
EOF
