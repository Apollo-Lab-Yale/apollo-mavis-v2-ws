#!/usr/bin/env bash
# S2: the operations account, its device groups, lingering user manager, and the
# shared directories. Run as a sudo-capable user (NOT as root). Idempotent.
#
#   bash scripts/deploy/create-mavis-account.sh
#   DEV_USER=alice ...     developer account to add to group mavis (default: you)
#   DEV_USER= ...          add nobody
#
# Why these groups (verified against real device ownership on apollo-pc-1, 2026-09-04):
#   render   /dev/dri/renderD128, renderD129   root:render 0660  MuJoCo EGL opens them
#   video    /dev/dri/card*                    root:video  0660  not opened today; harmless
#   plugdev  /dev/bus/usb/<bus>/<dev> dongle   root:plugdev 0660 (60-apollo-teleop-input.rules); RealSense
#   input    /dev/input/event* gamepad         root:input  0660  (same rule file)
#   audio    /dev/snd/*                        root:audio  0660  the account's own PulseAudio opens the RØDE
#   netdev   nmcli via the netsetup polkit .pkla grant (Identity=unix-group:netdev)
#   dialout  serial adapters, if ever attached
# The developer's devices work through uaccess ACLs (seat owner); a lingering
# account never owns a seat, so it MUST rely on the group fallback.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"

[ "$(id -u)" -ne 0 ] || die "run as your own account (the script calls sudo itself)"
need_cmd sudo "apt install sudo"
need_cmd setfacl "apt install acl"

OPS_GROUPS=(render video plugdev input audio netdev dialout)
DEV_USER="${DEV_USER-$(id -un)}"

log "account $OPS_USER"
if getent passwd "$OPS_USER" >/dev/null; then
  note "exists: $(getent passwd "$OPS_USER")"
else
  # No password: log in via `sudo -iu mavis` or an SSH key; `sudo passwd mavis` if a
  # console login is wanted. Home is 0750 by /etc/adduser.conf (DIR_MODE), which is
  # fine: everything shared lives under $OPS_ROOT and $DATA_ROOT, not in the home.
  run sudo useradd --create-home --user-group --shell /bin/bash \
    --comment "MAVIS v2 operations" "$OPS_USER"
fi
for g in "${OPS_GROUPS[@]}"; do
  getent group "$g" >/dev/null || die "group '$g' does not exist on this machine"
done
run sudo usermod -aG "$(IFS=,; echo "${OPS_GROUPS[*]}")" "$OPS_USER"

if [ -n "$DEV_USER" ] && [ "$DEV_USER" != "$OPS_USER" ] && [ "$DEV_USER" != root ]; then
  log "developer $DEV_USER joins group $OPS_GROUP (write access to $OPS_ROOT and $DATA_ROOT; re-login to pick it up)"
  run sudo usermod -aG "$OPS_GROUP" "$DEV_USER"
fi

log "lingering user manager (starts systemd --user for $OPS_USER at boot, no login needed)"
run sudo loginctl enable-linger "$OPS_USER"

log "shared directories (setgid + default ACL: new files stay group-writable)"
run sudo install -d -m 2775 -o "$OPS_USER" -g "$OPS_GROUP" "$OPS_ROOT"
run sudo install -d -m 2775 -o "$OPS_USER" -g "$OPS_GROUP" "$DATA_ROOT" \
  "$DATA_ROOT/profiles" "$DATA_ROOT/datasets" "$DATA_ROOT/checkpoints" \
  "$DATA_ROOT/calibration" "$DATA_ROOT/libsurvive" "$DATA_ROOT/wheels"
# $DATA_ROOT/wheels: staging area for the pysurvive wheel (S3). The developer drops it
# there because mavis cannot read /home/<dev> (0750) and $OPS_ROOT must be EMPTY for git clone.
for d in "$OPS_ROOT" "$DATA_ROOT"; do
  run sudo setfacl -m "d:u::rwX,d:g::rwX,d:o::rX" "$d"
done
for d in "$DATA_ROOT"/*/; do
  run sudo setfacl -m "d:u::rwX,d:g::rwX,d:o::rX" "$d"
done
# root-owned: netsetup's nic_map.json (S5) lives here. The rendered lab config (S4) is
# $LAB_CONFIG in $DATA_ROOT, so the ops account can re-render it without sudo.
run sudo install -d -m 755 -o root -g root "$ETC_DIR"

log "result"
note "$(id "$OPS_USER")"
note "$(loginctl show-user "$OPS_USER" -p Linger 2>/dev/null || echo 'Linger=? (user manager starts at next boot or first login)')"
ls -ld "$OPS_ROOT" "$DATA_ROOT" "$DATA_ROOT"/* "$ETC_DIR" | sed 's/^/    /'
note "group changes apply to NEW sessions only: the $OPS_USER user manager must be (re)started"
note "after this step -> sudo systemctl restart user@$(id -u "$OPS_USER").service  (or reboot)"

log "done. Next (as $OPS_USER or as a developer in group $OPS_GROUP): bash scripts/deploy/install-stack.sh"
