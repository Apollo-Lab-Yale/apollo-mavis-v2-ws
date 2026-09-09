#!/usr/bin/env bash
# Vive tracker + gamepad teleop + GELLO leader arm: system side (needs sudo). Run once per
# machine; idempotent (the rule file is rewritten whole, groups are added with -aG).
# docs/design/13-tracker-teleop.md §6; GELLO (phase-15, 2026-09-09): docs/design/16-gello.md §9.3.
# On a machine that already has the rule file, scripts/deploy/install-system-deps.sh skips this
# script unless FORCE_UDEV=1 -- re-run it that way (or run this file directly) to land the GELLO rules.
set -euo pipefail
sudo apt-get update
sudo apt-get install -y build-essential cmake ninja-build pkg-config git zlib1g-dev libx11-dev \
  libusb-1.0-0-dev libeigen3-dev libopenblas-dev liblapacke-dev libatlas-base-dev libudev-dev
# udev: number < 70 so TAG+="uaccess" is honoured (73-seat-late.rules); MODE/GROUP is the headless fallback.
sudo tee /etc/udev/rules.d/60-apollo-teleop-input.rules >/dev/null <<'RULES'
# Valve Watchman dongle (Vive Tracker RF receiver). libsurvive opens the raw usb node via libusb.
SUBSYSTEM=="usb",    ATTRS{idVendor}=="28de", ATTRS{idProduct}=="2101", MODE="0660", GROUP="plugdev", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="28de", ATTRS{idProduct}=="2101", MODE="0660", GROUP="plugdev", TAG+="uaccess"
# Other lighthouse devices (libsurvive useful_files/81-vive.rules): wired tracker, tracker 2018, wired watchman, HMD
SUBSYSTEM=="usb",    ATTRS{idVendor}=="28de", ATTRS{idProduct}=="2022", MODE="0660", GROUP="plugdev", TAG+="uaccess"
SUBSYSTEM=="usb",    ATTRS{idVendor}=="28de", ATTRS{idProduct}=="2300", MODE="0660", GROUP="plugdev", TAG+="uaccess"
SUBSYSTEM=="usb",    ATTRS{idVendor}=="28de", ATTRS{idProduct}=="2012", MODE="0660", GROUP="plugdev", TAG+="uaccess"
SUBSYSTEM=="usb",    ATTRS{idVendor}=="28de", ATTRS{idProduct}=="2000", MODE="0660", GROUP="plugdev", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="28de", ATTRS{idProduct}=="2000", MODE="0660", GROUP="plugdev", TAG+="uaccess"
# XInput gamepad "ESM GAME FOR WINDOWS" (kernel xpad): group fallback for headless use of /dev/input/event*.
SUBSYSTEM=="input", ATTRS{idVendor}=="2f24", ATTRS{idProduct}=="00b7", MODE="0660", GROUP="input", TAG+="uaccess"
# GELLO leader arm (U2D2 / FT232H), phase-15: the runtime's GelloReader opens the FTDI serial adapter
# (/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_FTAKROCJ-if00-port0 -> ttyUSB0) as a member of dialout.
SUBSYSTEM=="usb", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6014", MODE="0660", GROUP="dialout", TAG+="uaccess"
# ftdi_sio latency_timer 1 ms: the kernel default 16 ms caps eight Dynamixel servos at ~30 Hz (the reader polls at 100 Hz).
ACTION=="add", SUBSYSTEM=="usb-serial", DRIVER=="ftdi_sio", ATTR{latency_timer}="1"
RULES
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb --subsystem-match=hidraw --subsystem-match=input
# The latency_timer rule fires on "add" only: apply it now to FTDI ports that are already plugged in.
for p in /sys/bus/usb-serial/drivers/ftdi_sio/ttyUSB*/latency_timer; do
  if [ -e "$p" ]; then echo 1 | sudo tee "$p" >/dev/null; fi
done
sudo usermod -aG plugdev,input,dialout "$USER"   # 'input' / 'dialout' take effect after re-login (or: newgrp input)
echo "--- verification (dongle usb node must be rw for you):"
for d in $(lsusb -d 28de:2101 | awk '{printf "/dev/bus/usb/%s/%s\n", $2, substr($4,1,3)}'); do ls -la "$d"; getfacl -p "$d" 2>/dev/null | grep -E "^user:$USER" || echo "  (no ACL yet; plugdev group applies after re-login)"; done
ls -la /dev/input/by-id/ | grep -i esm || true
echo "--- GELLO leader adapter (FT232H 0403:6014; expect root:dialout 0660 on the tty and latency_timer 1):"
lsusb -d 0403:6014 || echo "  (no FT232H adapter plugged in)"
ls -la /dev/serial/by-id/ 2>/dev/null || true
for p in /sys/bus/usb-serial/drivers/ftdi_sio/ttyUSB*/latency_timer; do
  if [ -e "$p" ]; then echo "  $p = $(cat "$p")"; fi
done
