#!/usr/bin/env bash
# Copy recorded data between a developer's ~/data and the shared account's ~/data.
# Demonstrations (bc_demo/<name>) and Online DAgger sessions (online_dagger/<session>) are
# one directory per episode under ~/data of the account that ran the runtime (CLAUDE.md
# "Datasets"); this mirrors that tree with rsync. ADDITIVE ONLY: nothing is ever deleted
# on the receiving side. Homes are 0750, so the copy runs through sudo and re-owns the
# files for the receiving account. Run as any sudoer (the shared account is one).
#
#   bash scripts/deploy/sync-data-from-dev.sh                 # <you>/data -> <ops account>/data
#   DEV_USER=alice ...                                        # a developer other than you
#   DIRECTION=ops-to-dev ...                                  # the other way round
#   DRY_RUN=1 ...                                             # list what would change
# No account name is hard-coded: DEV_USER defaults to whoever invoked the script (through
# sudo: $SUDO_USER) and OPS_USER comes from _common.sh, so the same command works for any
# pair of accounts on any machine.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$HERE/_common.sh"
need_cmd rsync "apt install rsync"
need_cmd sudo "apt install sudo"

DEV_USER="${DEV_USER:-${SUDO_USER:-$(id -un)}}"
DEV_HOME="$(getent passwd "$DEV_USER" | cut -d: -f6)"
[ -n "$DEV_HOME" ] || die "no such user: $DEV_USER"
[ "$DEV_USER" != "$OPS_USER" ] || die "DEV_USER equals OPS_USER ('$OPS_USER'): name the developer account with DEV_USER=<name>"
OPS_HOME_REAL="$(getent passwd "$OPS_USER" | cut -d: -f6)"
[ -n "$OPS_HOME_REAL" ] || die "no such user: $OPS_USER"

case "${DIRECTION:-dev-to-ops}" in
  dev-to-ops) SRC="$DEV_HOME/data"; DEST="$OPS_HOME_REAL/data"; OWNER="$OPS_USER:$(id -gn "$OPS_USER")";;
  ops-to-dev) SRC="$OPS_HOME_REAL/data"; DEST="$DEV_HOME/data"; OWNER="$DEV_USER:$(id -gn "$DEV_USER")";;
  *) die "DIRECTION must be dev-to-ops or ops-to-dev";;
esac

RSYNC=(rsync -a --info=stats1,name1 --chown="$OWNER" --exclude '.Trash*' --exclude '*.tmp' --exclude '*.partial')
[ "${DRY_RUN:-0}" = "1" ] && RSYNC+=(--dry-run)

log "${DRY_RUN:+DRY RUN: }$SRC/ -> $DEST/ (owner $OWNER, additive: no --delete)"
# Two different failures deserve two different messages: "cannot become root" and "no such
# source tree". sudo needs a terminal for its password prompt, so from a pipeline, a cron
# job or a non-interactive shell either prime it first (`sudo -v`) or set SUDO_ASKPASS +
# use sudo -A; otherwise run this from a real terminal.
if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null && ! sudo -v; then
  die "cannot become root here: run this from a terminal, or prime sudo first with 'sudo -v'"
fi
as_root test -d "$SRC" || die "$SRC does not exist"
[ "${DRY_RUN:-0}" = "1" ] || as_root install -d -m 755 -o "${OWNER%%:*}" -g "${OWNER##*:}" "$DEST"
as_root "${RSYNC[@]}" "$SRC/" "$DEST/"
# Closing size, best-effort: a long rsync can outlive the sudo timestamp, and losing the
# summary must not report failure for a copy that already succeeded.
if [ "${DRY_RUN:-0}" != "1" ]; then
  SIZE="$(sudo -n du -sh "$DEST" 2>/dev/null | cut -f1 || true)"
  note "${SIZE:-(size unread: sudo timestamp expired)} now in $DEST"
fi
log "done."
