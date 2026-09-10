#!/usr/bin/env bash
# S6: install the systemd --user units for the operations account, seed its
# libsurvive calibration directory, install the runtime unit (autostart is opt-in). Run AS THE OPS ACCOUNT
# (a `mavis-v2` terminal, or `su - mavis-v2`). No sudo inside. Idempotent.
#
#   bash ~/apollo-mavis-v2-ws/scripts/deploy/install-services.sh
#   START=1            also (re)start mavis-runtime now (default: install only — the
#                      developer's instance may still own the dongle/port, see S8)
#   AUTOSTART=1        `systemctl --user enable` it so a reboot brings the cell up
#                      unattended. DEFAULT 0, deliberately: the lab config is ARMED, and
#                      starting on boot would connect the real control boxes with nobody
#                      present and take the dongle / mic / port 8765 away from a
#                      developer account. The operator starts it by hand (see the README).
#   WITH_UI_DEV=1      also install mavis-ui-dev.service (developer accounts only)
#   LIBSURVIVE_SEED=/path/config.json   lighthouse calibration to seed when none exists
#                      (default: the repo copy configs/libsurvive/mavis_v2-lighthouses-*.json;
#                       the developer's ~/.config/libsurvive/config.json may be NEWER — prefer it)
#   ALLOW_ANY_USER=1   skip the "am I $OPS_USER" check (developer installing the ui-dev unit)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

ME="$(id -un)"
if [ "$ME" != "$OPS_USER" ] && [ "${ALLOW_ANY_USER:-0}" != "1" ]; then
  die "run as $OPS_USER (sudo -iu $OPS_USER), you are $ME (ALLOW_ANY_USER=1 to override)"
fi
[ "$(id -u)" -ne 0 ] || die "never as root: these are user units"

# A lingering account has a running user manager but `su -` / `sudo -iu` do not export
# its bus address; point systemctl --user at it explicitly.
ops_user_env
[ -d "$XDG_RUNTIME_DIR" ] || die "$XDG_RUNTIME_DIR missing: loginctl enable-linger $ME not applied yet (create-mavis-account.sh), or the user manager is not running (sudo systemctl start user@$(id -u))"

UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

if [ "$ME" = "$OPS_USER" ]; then
  # libsurvive itself ignores tracker.libsurvive_config_path (that key is only for the
  # calibration wizard): the library reads $XDG_CONFIG_HOME/libsurvive/config.json,
  # i.e. ~/.config/libsurvive/config.json. Make that directory the shared one so both
  # paths are the same file.
  log "data tree $DATA_ROOT"
  for d in "${DATA_SUBDIRS[@]}"; do mkdir -p "$DATA_ROOT/$d"; done
  log "libsurvive calibration dir: ~/.config/libsurvive -> $DATA_ROOT/libsurvive"
  LS_DIR="$DATA_ROOT/libsurvive"
  [ -d "$LS_DIR" ] && [ -w "$LS_DIR" ] || die "$LS_DIR missing or not writable"
  mkdir -p "$HOME/.config"
  if [ -L "$HOME/.config/libsurvive" ]; then
    note "symlink present -> $(readlink "$HOME/.config/libsurvive")"
  elif [ -e "$HOME/.config/libsurvive" ]; then
    warn "$HOME/.config/libsurvive exists and is not a symlink; leaving it alone (move it aside and re-run)"
  else
    run ln -s "$LS_DIR" "$HOME/.config/libsurvive"
  fi
  if [ -f "$LS_DIR/config.json" ]; then
    note "calibration present: $LS_DIR/config.json ($(stat -c %y "$LS_DIR/config.json" | cut -d. -f1))"
  else
    SEED="${LIBSURVIVE_SEED:-$(ls -t "$RUNTIME_DIR"/configs/libsurvive/mavis_v2-lighthouses-*.json 2>/dev/null | head -1 || true)}"
    if [ -n "$SEED" ] && [ -f "$SEED" ]; then
      run install -m 664 "$SEED" "$LS_DIR/config.json"
      note "seeded from $SEED -- redo the Yaw alignment wizard (Devices page) after first start"
    else
      warn "no lighthouse calibration seed found; libsurvive will start uncalibrated (LIBSURVIVE_SEED=...)"
    fi
  fi
  for d in profiles datasets checkpoints calibration; do
    [ -w "$DATA_ROOT/$d" ] || warn "$DATA_ROOT/$d is not writable by $ME"
  done
fi

render_unit() { # template -> installed unit, with the layout substituted
  # The template bakes in NO account name: it uses systemd's %h (the home of the user the
  # unit runs as), so it is already correct whenever the checkout is ~/apollo-mavis-v2-ws
  # and the config its var/mavis_v2_lab.yaml. Only a layout that breaks that relation --
  # the legacy /opt + /var/lib one, or a renamed checkout -- needs rewriting. The config
  # path is replaced first so the checkout substitution cannot touch it twice.
  local tpl_root='%h/apollo-mavis-v2-ws' tpl_cfg='%h/apollo-mavis-v2-ws/var/mavis_v2_lab.yaml'
  if [ "$OPS_ROOT" = "$OPS_HOME/apollo-mavis-v2-ws" ] && [ "$LAB_CONFIG" = "$OPS_ROOT/var/mavis_v2_lab.yaml" ]; then
    cat "$1"                       # %h resolves to OPS_HOME: nothing to substitute
  else
    sed -e "s|$tpl_cfg|$LAB_CONFIG|g" -e "s|$tpl_root|$OPS_ROOT|g" "$1"
  fi
}
log "units -> $UNIT_DIR"
UNITS=(mavis-runtime.service)
[ "${WITH_UI_DEV:-0}" = "1" ] && UNITS+=(mavis-ui-dev.service)
for u in "${UNITS[@]}"; do
  render_unit "$HERE/systemd/$u" > "$UNIT_DIR/$u.tmp"
  # %h is fine (systemd resolves it); a LITERAL other-account path never is.
  if grep -qE '/home/[a-z0-9_-]+/apollo-mavis-v2-ws' "$UNIT_DIR/$u.tmp" \
     && ! grep -q "$OPS_HOME/apollo-mavis-v2-ws" "$UNIT_DIR/$u.tmp"; then
    rm -f "$UNIT_DIR/$u.tmp"
    die "$u would carry a hard-coded path for another account; check OPS_ROOT / LAB_CONFIG"
  fi
  if cmp -s "$UNIT_DIR/$u.tmp" "$UNIT_DIR/$u" 2>/dev/null; then
    note "$u unchanged"; rm -f "$UNIT_DIR/$u.tmp"
  else
    mv "$UNIT_DIR/$u.tmp" "$UNIT_DIR/$u"; note "$u installed"
  fi
done
run systemd-analyze --user verify "${UNITS[@]/#/$UNIT_DIR/}"
run systemctl --user daemon-reload
if [ "${AUTOSTART:-0}" = "1" ]; then
  run systemctl --user enable mavis-runtime.service
else
  run systemctl --user disable mavis-runtime.service 2>/dev/null || true
  note "autostart OFF (AUTOSTART=1 enables it): an armed runtime should not connect the"
  note "real boxes on boot with nobody present, and it would take the dongle / mic /"
  note "port $RUNTIME_PORT from a developer account. Start it by hand instead."
fi
if [ "${WITH_UI_DEV:-0}" = "1" ]; then note "mavis-ui-dev.service installed but NOT enabled (developer tool; start it by hand)"; fi

if [ "${START:-0}" = "1" ]; then
  [ -f "$LAB_CONFIG" ] || die "$LAB_CONFIG missing: run render-lab-config.sh first"
  run systemctl --user restart mavis-runtime.service
  sleep 3
  systemctl --user --no-pager status mavis-runtime.service || true
else
  note "not started (START=1 does). Before starting make sure no other runtime owns"
  note "the dongle / mic / port $RUNTIME_PORT (S8), then:"
  note "  systemctl --user start mavis-runtime && journalctl --user -u mavis-runtime -f"
fi
log "done."
