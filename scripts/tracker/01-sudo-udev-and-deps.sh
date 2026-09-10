#!/usr/bin/env bash
# Vive tracker + gamepad teleop: system side (needs sudo). Run once per machine.
# docs/design/13-tracker-teleop.md §6
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
RULES
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb --subsystem-match=hidraw --subsystem-match=input
sudo usermod -aG plugdev,input "$USER"   # 'input' takes effect after re-login (or: newgrp input)
echo "--- verification (dongle usb node must be rw for you):"
for d in $(lsusb -d 28de:2101 | awk '{printf "/dev/bus/usb/%s/%s\n", $2, substr($4,1,3)}'); do ls -la "$d"; getfacl -p "$d" 2>/dev/null | grep -E "^user:$USER" || echo "  (no ACL yet; plugdev group applies after re-login)"; done
ls -la /dev/input/by-id/ | grep -i esm || true
