#!/usr/bin/env bash
# S9: bring the ops checkout up to what is pushed AND pinned on GitHub, rebuild, re-render
# the lab config, restart the service, run the health check. Run AS THE OPS ACCOUNT
# (`mavis-v2`); no sudo, no GitHub login (public repos, anonymous HTTPS). Refuses to touch
# anything while a teleop / collect / Online DAgger session is running on the local runtime.
#
#   bash ~/apollo-mavis-v2-ws/scripts/deploy/update.sh
#   FORCE=1        proceed even if a session is running (it will be torn down by the stop)
#   NO_RESTART=1   leave the service stopped afterwards (e.g. the developer needs the cell next)
#   START=1        start the service afterwards even if it was not running before
#   WITH_DEV=1 / SKIP_UI=1 / PYSURVIVE_WHEEL=... / BUILD_PYSURVIVE=1  pass through to install-stack.sh
#   DORA_BIND_HOST=... etc.  one-off render knobs (persistent ones belong in $LAB_ENV, see _common.sh)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

[ "$(id -u)" -ne 0 ] || die "never as root (the checkout, venvs and dist belong to $OPS_USER)"
[ -d "$OPS_ROOT/.git" ] || die "$OPS_ROOT is not a checkout: run install-stack.sh first"
ops_user_env
UNIT=mavis-runtime.service
have_unit() { systemctl --user cat "$UNIT" >/dev/null 2>&1; }

log "local runtime state"
SESSION="$(curl -s -m 3 "http://$RUNTIME_HOST:$RUNTIME_PORT/api/session" || true)"
if printf '%s' "$SESSION" | grep -q '"state"'; then
  note "a session is open on :$RUNTIME_PORT: $(printf '%s' "$SESSION" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("kind"), d.get("mode"), d.get("state"))' 2>/dev/null || echo '?')"
  [ "${FORCE:-0}" = "1" ] || die "end the session first (Cockpit -> End session), or FORCE=1 to stop the runtime under it"
else
  note "no session open (or no runtime answering on :$RUNTIME_PORT)"
fi

WAS_ACTIVE=0
if have_unit && systemctl --user is-active --quiet "$UNIT"; then
  WAS_ACTIVE=1
  log "stop $UNIT"
  run systemctl --user stop "$UNIT"
elif ! have_unit; then
  note "$UNIT not installed for $(id -un) (install-services.sh) - updating the tree only"
fi

BEFORE="$(git -C "$OPS_ROOT" rev-parse --short HEAD)"
log "update + rebuild (install-stack.sh UPDATE=1)"
UPDATE=1 bash "$HERE/install-stack.sh"
AFTER="$(git -C "$OPS_ROOT" rev-parse --short HEAD)"
note "workspace $BEFORE -> $AFTER"
if git -C "$OPS_ROOT" submodule status | grep -q '^[+-]'; then
  warn "a submodule is not on the pinned commit (+ ahead / - missing): git -C $OPS_ROOT submodule status"
fi

log "re-render the lab config"
bash "$HERE/render-lab-config.sh"

if have_unit && { [ "$WAS_ACTIVE" = 1 ] && [ "${NO_RESTART:-0}" != "1" ] || [ "${START:-0}" = "1" ]; }; then
  log "start $UNIT"
  run systemctl --user start "$UNIT"
  sleep 5
  systemctl --user --no-pager --lines=0 status "$UNIT" || true
  log "health check"
  bash "$HERE/healthcheck.sh" || warn "health check reported problems (see above; DEPLOYMENT.md S11)"
else
  note "service left stopped (start: systemctl --user start $UNIT)"
fi
log "done."
