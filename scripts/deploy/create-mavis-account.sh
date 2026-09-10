#!/usr/bin/env bash
# S2: the shared operations account (`mavis-v2`), its device groups, lingering user
# manager, and the root-owned netsetup state dir. Run as a sudo-capable user (NOT as
# root) — the shared account itself is a sudoer, so it can run this on itself. Idempotent.
#
#   bash scripts/deploy/create-mavis-account.sh
#   DEV_USER=alice ...     additionally put that developer into group $OPS_GROUP (only
#                          useful for a shared FHS layout outside the ops home; default: nobody)
#
# Why these groups (verified against real device ownership on apollo-pc-1, 2026-09-04):
#   render   /dev/dri/renderD128, renderD129   root:render 0660  MuJoCo EGL opens them
#   video    /dev/dri/card*                    root:video  0660  not opened today; harmless
#   plugdev  /dev/bus/usb/<bus>/<dev> dongle   root:plugdev 0660 (60-apollo-teleop-input.rules); RealSense
#   input    /dev/input/event* gamepad         root:input  0660  (same rule file)
#   audio    /dev/snd/*                        root:audio  0660  the account's own PulseAudio opens the RØDE
#   netdev   nmcli via the netsetup polkit .pkla grant (Identity=unix-group:netdev)
#   dialout  serial adapters, if ever attached
# A desktop login of the account gets its devices through uaccess ACLs (seat owner); the
# boot-time service (linger, no seat) MUST rely on the group fallback.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

[ "$(id -u)" -ne 0 ] || die "run as your own account (the script calls sudo itself)"
need_cmd sudo "apt install sudo"

OPS_GROUPS=(render video plugdev input audio netdev dialout)
DEV_USER="${DEV_USER-}"

log "account $OPS_USER"
if getent passwd "$OPS_USER" >/dev/null; then
  note "exists: $(getent passwd "$OPS_USER")"
else
  # Created here without a password: set one with `sudo passwd $OPS_USER` so people can log
  # in at the desktop (the lab's shared account has one; see the workspace README).
  run sudo useradd --create-home --user-group --shell /bin/bash \
    --comment "MAVIS V2" "$OPS_USER"
  note "set a login password now: sudo passwd $OPS_USER"
fi
for g in "${OPS_GROUPS[@]}"; do
  getent group "$g" >/dev/null || die "group '$g' does not exist on this machine"
done
run sudo usermod -aG "$(IFS=,; echo "${OPS_GROUPS[*]}")" "$OPS_USER"

if [ -n "$DEV_USER" ] && [ "$DEV_USER" != "$OPS_USER" ] && [ "$DEV_USER" != root ]; then
  log "developer $DEV_USER joins group $OPS_GROUP (re-login to pick it up)"
  run sudo usermod -aG "$OPS_GROUP" "$DEV_USER"
fi

log "lingering user manager (starts systemd --user for $OPS_USER at boot, no login needed)"
run sudo loginctl enable-linger "$OPS_USER"

OPS_HOME_REAL="$(getent passwd "$OPS_USER" | cut -d: -f6)"
if path_inside "$OPS_ROOT" "$OPS_HOME_REAL"; then
  log "layout: checkout $OPS_ROOT and data $DATA_ROOT live inside $OPS_HOME_REAL"
  note "nothing to create: install-stack.sh clones into $OPS_ROOT (it must not exist yet or be a checkout)"
  note "and makes the var/ subdirectories; demonstrations go to $OPS_HOME_REAL/data at first use"
else
  # Legacy shared FHS layout (/opt + /var/lib): setgid dirs with default ACLs so the ops
  # account and developers in its group can both write.
  need_cmd setfacl "apt install acl"
  log "shared directories (setgid + default ACL: new files stay group-writable)"
  run sudo install -d -m 2775 -o "$OPS_USER" -g "$OPS_GROUP" "$OPS_ROOT"
  run sudo install -d -m 2775 -o "$OPS_USER" -g "$OPS_GROUP" "$DATA_ROOT"
  for sub in "${DATA_SUBDIRS[@]}"; do
    run sudo install -d -m 2775 -o "$OPS_USER" -g "$OPS_GROUP" "$DATA_ROOT/$sub"
  done
  for d in "$OPS_ROOT" "$DATA_ROOT" "$DATA_ROOT"/*/; do
    run sudo setfacl -m "d:u::rwX,d:g::rwX,d:o::rX" "$d"
  done
fi
# root-owned: netsetup's nic_map.json (S5) lives here.
run sudo install -d -m 755 -o root -g root "$ETC_DIR"

log "result"
note "$(id "$OPS_USER")"
note "$(loginctl show-user "$OPS_USER" -p Linger 2>/dev/null || echo 'Linger=? (user manager starts at next boot or first login)')"
note "group changes apply to NEW sessions only. The account's running user manager (and any"
note "desktop session it has open) keeps the old groups until it is restarted: log the account"
note "out and in again, or reboot, or — with nobody logged in as $OPS_USER —"
note "  sudo systemctl restart user@$(id -u "$OPS_USER").service"
note "Check from a fresh login: id -nG | tr ' ' '\\n' | grep -E '^(render|audio|plugdev|input|netdev)$'"

log "done. Next (as $OPS_USER): bash scripts/deploy/install-stack.sh"
