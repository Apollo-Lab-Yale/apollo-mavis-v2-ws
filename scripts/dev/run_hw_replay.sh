#!/bin/bash
# Replay one recorded episode's ACTION COLUMN into the real cell through the EXTERNAL
# POLICY (dora) path - the exact invocation of the first policy-driven motion of the
# real arms, 2026-09-12 (14-dora §16.8).
#
#   scripts/dev/run_hw_replay.sh <abs_ee|delta_ee> <speed_scale> <node_speed> <rate_hz>
#   ... abs_ee   0.6 0.5 15     # the verified run: 5.0 mm rms, 0.0 mm final
#   ... delta_ee 0.6 0.5 15     # 4.1 mm rms BUT 195 mrad rotation drift (OPEN defect)
#
# THE RATE RULE (14-dora §16.8). The runtime spreads one delta_ee row over one ANNOUNCED
# period (period = 1/rate_hz), so the per-tick joint demand is row x rate_hz/100 against a
# cap of dq_max x speed_scale. This episode used 0.74 of the cap at speed_scale 1.0 / 25 fps,
# so keep
#         rate_hz ~= fps x speed_scale        and     node_speed ~= speed_scale
# At speed_scale 0.1 that is --rate-hz 2.5-3, NOT 30: at 30 the sim residual is 159 mm
# instead of 14.7 mm. Do NOT use --chunk-dt-s as a speed knob - for delta_ee the runtime
# rescales each row by period/chunk_dt and silently divides the total travel.
# None of this applies to a TRAINED policy: it is closed-loop on obs_state and needs only
# an honest rate_hz.
#
# PREREQS: run as the account that owns the data (the production episodes are 0600); no
# session open; /api/dora "attached"; hardware_session.policy_modes true; both rails homed;
# and for a GRASP to reproduce, the props must sit at their recorded pose - check with
# align_props.py (the shade was 22.6 mm out on 2026-09-12 and every replay closed on air).
# Hand on the E-stop: policy-driven motion on this cell is still young.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"          # absolute: the rest survives any cwd
WS="$(cd "$HERE/../.." && pwd)"                # the workspace root, not an assumed $HOME path
SPACE="${1:?action space: abs_ee | delta_ee}"
SCALE="${2:-0.6}"; SPEED="${3:-0.5}"; RATE="${4:-15}"
EP="${EPISODE:-20260911T214721.850Z-7b6028}"          # lamp_assembling: 425 frames, frame0 == the FurnitureBench profile
DS="${DATASET:-bc_demo/lamp_assembling}"
PROF="${START_FROM:-profile:e2d42f3418b74418b6d0db89e5add5ed}"   # "2026-09-09 FurnitureBench"
# Unset by default so replay_dryrun.py's own DEFAULT_NODE_BIN applies (it knows the
# developer layout); the lab account exports NODE_BIN=~/apollo-mavis-v2-policy-node/.venv/bin/mavis-policy-node
NODE="${NODE_BIN:-}"
DRIVER="${DRIVER:-$HERE/replay_dryrun.py}"
URL="${URL:-http://127.0.0.1:8765}"   # the PRODUCTION runtime; the sim dry-run one is :8866

cd "$WS"
echo "=== preflight $(date -Is)"
curl -sS -m 5 "$URL/api/session" || { rc=$?
  echo "preflight: nothing answered at $URL (curl exit $rc) - start the runtime, then retry" >&2
  exit 1; }
echo
echo "=== GO $SPACE  speed_scale=$SCALE node_speed=$SPEED rate_hz=$RATE  ep=$EP"
exec apollo-mavis-v2-runtime/.venv/bin/python "$DRIVER" \
  --episode "$EP" --dataset "$DS" --arms grip \
  --kind hardware --action-space "$SPACE" \
  --speed "$SPEED" --rate-hz "$RATE" --speed-scale "$SCALE" \
  --start-from "$PROF" --start-timeout-s 600 \
  --url "$URL" ${NODE:+--node-bin "$NODE"}
