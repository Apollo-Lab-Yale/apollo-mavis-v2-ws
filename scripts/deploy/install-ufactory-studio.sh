#!/usr/bin/env bash
# Install UFACTORY Studio (the xArm controller's desktop client; a Linux AppImage) for the
# account running this script: copies the AppImage(s) into ~/Applications, makes them
# executable and integrates them into the desktop menu — through AppImageLauncher's
# `ail-cli` when it is installed (it is on apollo-pc-1), otherwise with a hand-written
# .desktop entry. No sudo. Idempotent (re-running replaces the copy and the entry).
#
#   bash scripts/deploy/install-ufactory-studio.sh /path/to/UfactoryStudio-*.AppImage [more.AppImage ...]
#
# Where the file comes from: https://www.ufactory.cc/ufactory-studio/ (Linux download), or
# the copy in a developer's ~/Applications. The client is Electron and needs `--no-sandbox`
# (AppImageLauncher adds it; the manual entry below adds it too).
#
# ONE version is kept on this machine: `ufactory-studio-client-linux-1.0.2` (operator
# decision 2026-09-09 — 1.0.1 was removed from every account, so do not re-install it).
# Firmware on the two lab control boxes: v1.12.10. Rules for using it: NEVER open
# "Live control" while a MAVIS session is running (CLAUDE.md "Rules that protect the cell").
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <AppImage> [<AppImage> ...]" >&2; exit 2; }
[ "$(id -u)" -ne 0 ] || { echo "run as the account that should get the menu entry, not root" >&2; exit 1; }
APPS="$HOME/Applications"
DESK="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$APPS" "$DESK" "$ICONS"

for src in "$@"; do
  [ -f "$src" ] || { echo "not a file: $src" >&2; exit 1; }
  name="$(basename "$src")"
  dest="$APPS/$name"
  printf '\n==> %s\n' "$name"
  if [ "$(readlink -f "$src")" != "$(readlink -f "$dest")" ]; then
    install -m 755 "$src" "$dest"
  else
    chmod 755 "$dest"
  fi
  ver="$(printf '%s' "$name" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if command -v ail-cli >/dev/null 2>&1 && [ "${NO_AIL:-0}" != "1" ]; then
    # AppImageLauncher: writes the .desktop + icon under ~/.local/share and keeps the file in
    # ~/Applications (its default destination on this machine).
    if ail-cli integrate "$dest"; then
      echo "    integrated with ail-cli"
      continue
    fi
    echo "    ail-cli integrate failed; writing a plain .desktop entry instead"
  fi
  # Manual integration: pull the icon out of the AppImage, write a .desktop entry.
  tmp="$(mktemp -d)"
  icon_dst="$ICONS/ufactory-studio${ver:+-$ver}.png"
  if (cd "$tmp" && "$dest" --appimage-extract '*.png' >/dev/null 2>&1 || "$dest" --appimage-extract .DirIcon >/dev/null 2>&1); then
    icon_src="$(find "$tmp/squashfs-root" -maxdepth 1 \( -name '*.png' -o -name '.DirIcon' \) -print -quit 2>/dev/null || true)"
    [ -n "$icon_src" ] && cp "$icon_src" "$icon_dst"
  fi
  rm -rf "$tmp"
  entry="$DESK/ufactory-studio${ver:+-$ver}.desktop"
  cat > "$entry" <<DESKTOP
[Desktop Entry]
Type=Application
Name=UFACTORY Studio${ver:+ ($ver)}
Comment=xArm controller client (control boxes 192.168.1.201 / 192.168.2.219)
Exec=$dest --no-sandbox %U
TryExec=$dest
Icon=${icon_dst%.png}
Terminal=false
Categories=Utility;
StartupWMClass=UFACTORY-Studio
X-AppImage-Version=${ver}
DESKTOP
  [ -f "$icon_dst" ] || sed -i "s|^Icon=.*|Icon=applications-engineering|" "$entry"
  echo "    wrote $entry"
done
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESK" 2>/dev/null || true
printf '\n==> done. Menu entry "UFACTORY Studio"; from a terminal: %s --no-sandbox\n' "$APPS/<file>.AppImage"
