#!/usr/bin/env python3
"""How far are the table props from the pose a recorded episode expects?

Replaying a recorded episode's action column reproduces the ARM's trajectory, not the
scene: a grasp only comes back if the object sits where it sat during the recording. On
2026-09-12 (14-dora §16.8) three hardware replays of a FurnitureBench lamp episode all
tracked to 5 mm yet closed the gripper on air, because the lamp shade stood 22.6 mm from
its recorded pose. This tool measures that offset so the operator can put the prop back.

How it is valid with ZERO motion: pick an episode whose OBSERVING arm does not move
(``action`` block all zeros, carriage fixed - true of the Perception Arm in every
lamp/drawer/cabinet episode), and compare one live frame of that arm's wrist camera with
frame 0 of the episode's recorded video. Same camera, same pose, so a pixel offset is a
real offset. The arm may sit anywhere on its own trajectory: it never moved.

    align_props.py --episode <id> [--dataset bc_demo/lamp_assembling] [--camera view_wrist]
                   [--region y0,y1,x0,x1 ...] [--mm-per-px 0.818] [--overlay OUT.png]
                   [--url http://127.0.0.1:8765] [--ref-out DIR]

Regions are image boxes holding one saturated-colour prop each; the default pair is the
lamp task's (shade in the bench's lower left, bulb + base above it). Print reads
``dx``/``dy`` in pixels and mm: move the prop OPPOSITE the reported offset. ``--overlay``
writes the live frame with each prop's RECORDED bounding box drawn on it - put the prop
inside the box. Needs ffmpeg (frame extraction) and the runtime's preview stream; run it
as the account that owns the dataset (production episodes are mode 0600).
"""

from __future__ import annotations

import argparse
import io
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image

# The lamp task, in the Perception Arm's wrist view: (y0, y1, x0, x1).
DEFAULT_REGIONS = [(200, 480, 0, 320), (60, 200, 220, 380)]
# The shade's wide end is ~90 mm across and ~110 px at this depth. Re-measure for another
# prop or another viewpoint; it only scales the printed mm, never the pixel offsets.
DEFAULT_MM_PER_PX = 90.0 / 110.0


def blob(im: np.ndarray, box: tuple[int, int, int, int]) -> dict | None:
    """Centroid + bbox of the saturated-red pixels inside ``box`` (the FurnitureBench
    props are saturated red/orange on a white bench, which is why a colour threshold is
    enough and no detector is needed)."""
    a = im.astype(np.int16)
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    mask = (r > 110) & (r - g > 55) & (r - b > 55)
    keep = np.zeros(mask.shape, bool)
    y0, y1, x0, x1 = box
    keep[y0:y1, x0:x1] = True
    mask &= keep
    ys, xs = np.nonzero(mask)
    if len(xs) < 50:
        return None
    return dict(n=int(len(xs)), cx=float(xs.mean()), cy=float(ys.mean()),
                x0=int(xs.min()), x1=int(xs.max()), y0=int(ys.min()), y1=int(ys.max()))


def episode_dir(api_url: str, dataset: str, episode: str) -> Path:
    """Resolve the episode directory through ``GET /api/datasets/layout`` so the roots stay
    the runtime's business (04-runtime §10.6) and no namespace is hard-coded."""
    with urllib.request.urlopen(f"{api_url}/api/datasets/layout", timeout=10.0) as r:
        layout = __import__("json").load(r)
    ns, name = dataset.split("/", 1)
    mapped = (layout.get("namespaces") or {}).get(ns) or {}
    root = Path(mapped["root"]) if mapped.get("root") else \
        Path(layout.get("generic_root") or (Path.home() / "data")) / ns
    return root / name / "episodes" / episode


def recorded_frame0(ep_dir: Path, camera: str, out_dir: Path) -> np.ndarray:
    """Frame 0 of the episode's recorded video for ``camera`` (never shipped in the repo -
    it is lab imagery, and it is one ffmpeg call away)."""
    src = ep_dir / "video" / f"{camera}.mp4"
    if not src.is_file():
        raise SystemExit(f"no recorded video at {src}")
    out_dir.mkdir(parents=True, exist_ok=True)
    png = out_dir / f"ref-{camera}-f000.png"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(src),
                    "-vf", "select=eq(n\\,0)", "-vframes", "1", str(png)], check=True)
    return np.asarray(Image.open(png).convert("RGB"))


def live_frame(api_url: str, camera: str, timeout: float = 20.0) -> np.ndarray:
    """One JPEG out of the runtime's multipart MJPEG preview (session-less, read-only)."""
    with urllib.request.urlopen(f"{api_url}/video/{camera}.mjpg", timeout=timeout) as r:
        buf = b""
        for _ in range(4000):
            chunk = r.read(4096)
            if not chunk:
                break
            buf += chunk
            s, e = buf.find(b"\xff\xd8"), -1
            if s >= 0:
                e = buf.find(b"\xff\xd9", s + 2)
            if s >= 0 and e > s:
                return np.asarray(Image.open(io.BytesIO(buf[s:e + 2])).convert("RGB"))
    raise SystemExit("no complete JPEG in the preview stream")


def parse_region(text: str) -> tuple[int, int, int, int]:
    parts = [int(x) for x in text.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("a region is y0,y1,x0,x1")
    return tuple(parts)  # type: ignore[return-value]


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--episode", required=True)
    p.add_argument("--dataset", default="bc_demo/lamp_assembling")
    p.add_argument("--camera", default="view_wrist",
                   help="the wrist camera of the arm that does NOT move in this episode")
    p.add_argument("--region", type=parse_region, action="append", metavar="y0,y1,x0,x1")
    p.add_argument("--mm-per-px", type=float, default=DEFAULT_MM_PER_PX)
    p.add_argument("--url", default="http://127.0.0.1:8765")
    p.add_argument("--overlay", default=None)
    p.add_argument("--ref-out", default=None, help="where to keep the extracted reference frame")
    a = p.parse_args()
    regions = a.region or DEFAULT_REGIONS

    tmp = Path(a.ref_out) if a.ref_out else Path(tempfile.mkdtemp(prefix="align_props-"))
    ep = episode_dir(a.url, a.dataset, a.episode)
    ref = recorded_frame0(ep, a.camera, tmp)
    live = live_frame(a.url, a.camera)
    if live.shape != ref.shape:
        print(f"note: live {live.shape} vs recorded {ref.shape}", file=sys.stderr)

    worst = 0.0
    for i, box in enumerate(regions):
        r, l = blob(ref, box), blob(live, box)
        if not r or not l:
            print(f"region {i} {box}: prop not found (recorded={bool(r)} live={bool(l)})")
            continue
        dx, dy = l["cx"] - r["cx"], l["cy"] - r["cy"]
        dist = float(np.hypot(dx, dy)) * a.mm_per_px
        worst = max(worst, dist)
        print(f"region {i}: dx {dx:+6.1f} px ({dx * a.mm_per_px:+5.1f} mm)   "
              f"dy {dy:+6.1f} px ({dy * a.mm_per_px:+5.1f} mm)   "
              f"off {dist:5.1f} mm   area {l['n'] / r['n']:.2f}x")

    if a.overlay:
        out = live.copy()
        for i, box in enumerate(regions):
            r = blob(ref, box)
            if not r:
                continue
            col = (0, 255, 0) if i == 0 else (0, 160, 255)
            for t in range(2):
                out[max(0, r["y0"] - t):r["y0"] - t + 1, r["x0"]:r["x1"]] = col
                out[r["y1"] + t:r["y1"] + t + 1, r["x0"]:r["x1"]] = col
                out[r["y0"]:r["y1"], max(0, r["x0"] - t):r["x0"] - t + 1] = col
                out[r["y0"]:r["y1"], r["x1"] + t:r["x1"] + t + 1] = col
        Image.fromarray(out).save(a.overlay)
        print(f"overlay: {a.overlay}  (boxes = each prop's RECORDED outline; move the prop inside)")

    print(f"\nworst offset {worst:.1f} mm. Move each prop OPPOSITE its reported offset until every "
          f"line is within ~3 mm,\nthen replay: a reproduced grasp shows up as the gripper STALLING on the "
          f"object\n(the lamp episode of §16.8: commanded 15.5 mm, stalls at 59.0 mm; 14-15 mm means it "
          f"closed on air).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
