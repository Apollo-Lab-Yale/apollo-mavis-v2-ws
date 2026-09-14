#!/usr/bin/env python3
"""Record the runtime's MJPEG preview of one or more cameras to PNGs while something else runs.

    grab_preview_frames.py --out DIR --streams grip_wrist,view_wrist --seconds 120 [--fps 5]

Read-only on the runtime: it is the same preview stream the Hardware tab shows, no session
needed. Each PNG is named <stream>-<ms since start>.png so a frame can be matched to the
replay's own clock afterwards.
"""
from __future__ import annotations

import argparse
import io
import os
import threading
import time
import urllib.request
from pathlib import Path


def record(url: str, stream: str, out: Path, seconds: float, fps: float) -> None:
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()
    period = 1.0 / max(0.5, fps)
    next_save = 0.0
    try:
        with urllib.request.urlopen(f"{url}/video/{stream}.mjpg", timeout=20.0) as r:
            buf = b""
            while time.monotonic() - t0 < seconds:
                chunk = r.read(8192)
                if not chunk:
                    break
                buf += chunk
                while True:
                    s = buf.find(b"\xff\xd8")
                    e = buf.find(b"\xff\xd9", s + 2)
                    if s < 0 or e < 0:
                        break
                    jpg = buf[s:e + 2]
                    buf = buf[e + 2:]
                    el = time.monotonic() - t0
                    if el >= next_save:
                        next_save = el + period
                        (out / f"{stream}-{int(el * 1000):07d}.jpg").write_bytes(jpg)
                if len(buf) > 4_000_000:
                    buf = buf[-1_000_000:]
    except Exception as exc:  # noqa: BLE001
        (out / f"{stream}-ERROR.txt").write_text(f"{type(exc).__name__}: {exc}\n")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--url", default="http://127.0.0.1:8765")
    p.add_argument("--streams", default="grip_wrist,view_wrist")
    p.add_argument("--out", required=True)
    p.add_argument("--seconds", type=float, default=120.0)
    p.add_argument("--fps", type=float, default=5.0)
    a = p.parse_args()
    threads = [threading.Thread(target=record, args=(a.url, s.strip(), Path(a.out), a.seconds, a.fps),
                                daemon=False)
               for s in a.streams.split(",") if s.strip()]
    for t in threads:
        t.start()
    print(f"recording {a.streams} -> {a.out} for {a.seconds:.0f}s at {a.fps:g} fps", flush=True)
    for t in threads:
        t.join()
    n = len(list(Path(a.out).glob("*.jpg")))
    print(f"done: {n} frames in {a.out}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
