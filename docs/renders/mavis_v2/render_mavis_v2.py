"""Render mavis_v2 reference images -> docs/renders/mavis_v2/ (operator convention).

Usage (from the workspace root, sim repo's uv env)::

    cd apollo-mavis-v2-sim && MUJOCO_GL=egl uv run python \
        ../docs/renders/mavis_v2/render_mavis_v2.py [out_dir] [--microphone]

Writes the scene cameras (cam_front, cam_top, view_wrist_cam, grip_wrist_cam), a
2x2 contact sheet, and ``operator_view.png`` from MuJoCo's free camera using the
scene's default ``view`` (azimuth -90 / elevation -30: camera at +Y looking -Y),
which frames the red obstacle (the +X end, operator's left) and the Perception Arm
(``view``, rail q = 0) on the LEFT and the Manipulation Arm (``grip``, rail q = 0.65,
the -X end) on the RIGHT, matching the operator's real view of the cell (the
Perception Arm renders nearest). The scene keyframe is the cell's initial state
(2026-09-04): both arms folded at the xArm7 factory zero with joint 1 = pi, rails at
opposite ends -- so both wrist cams look straight down at the table. The older
``facing_outer_edge*.png`` in this directory are NOT regenerated.

``--microphone`` builds the hardware digital-twin variant
(``SceneOverrides(microphones={"view": True})``: the RODE NT-USB Mini cylinder in
front of the view arm's wrist camera, 03-sim §3) and writes ``*_mic.png``. In
``view_wrist_cam_mic.png`` the mic occludes ~12 % of the frame as a dark silhouette
centred on the bottom edge -- by design, as on the real mount; not a rendering bug.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import zlib
from pathlib import Path

os.environ.setdefault("MUJOCO_GL", "egl")

import mujoco  # noqa: E402
import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "apollo-mavis-v2-sim" / "src"))
from apollo_mavis_v2_sim import REGISTRY, SceneOverrides  # noqa: E402

OPERATOR_VIEW = {"lookat": [0.1, 0.0, 0.9], "distance": 2.4}  # azimuth/elevation from the scene


def _png(path: Path, img: np.ndarray) -> None:
    """Minimal RGB8 PNG writer (no PIL dependency)."""
    h, w, _ = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("out_dir", nargs="?", default=Path(__file__).resolve().parent, type=Path)
    parser.add_argument(
        "--microphone",
        action="store_true",
        help="hardware-twin variant: microphone body on the view arm; files get a _mic suffix",
    )
    args = parser.parse_args(argv)
    out: Path = args.out_dir
    out.mkdir(parents=True, exist_ok=True)
    suffix = "_mic" if args.microphone else ""
    overrides = SceneOverrides(microphones={"view": True}) if args.microphone else None
    built = REGISTRY.build("mavis_v2", overrides)
    model, data = built.model, mujoco.MjData(built.model)
    mujoco.mj_resetDataKeyframe(model, data, 0)
    mujoco.mj_forward(model, data)
    opt = mujoco.MjvOption()
    opt.geomgroup[:] = 1
    opt.geomgroup[3] = 0  # hide collision-only pads
    rendered: dict[str, np.ndarray] = {}

    def save(img: np.ndarray, name: str) -> None:
        img = np.ascontiguousarray(img)
        stem, ext = name.rsplit(".", 1)
        path = out / f"{stem}{suffix}.{ext}"
        _png(path, img)
        rendered[name] = img
        print("wrote", path, img.shape)

    with mujoco.Renderer(model, 720, 1280) as r:
        cam = mujoco.MjvCamera()
        cam.type = mujoco.mjtCamera.mjCAMERA_FREE
        cam.lookat[:] = OPERATOR_VIEW["lookat"]
        cam.distance = OPERATOR_VIEW["distance"]
        cam.azimuth = model.vis.global_.azimuth  # -90: at +Y looking -Y (obstacle on the left)
        cam.elevation = model.vis.global_.elevation  # -30
        r.update_scene(data, camera=cam, scene_option=opt)
        save(r.render(), "operator_view.png")
    with mujoco.Renderer(model, 480, 640) as r:
        for cam_name in built.meta.cameras:
            r.update_scene(data, camera=cam_name, scene_option=opt)
            save(r.render(), f"{cam_name}.png")
    imgs = [rendered[f"{c}.png"] for c in built.meta.cameras]
    if len(imgs) == 4:  # 2x2 contact sheet of the scene cameras
        save(np.vstack([np.hstack(imgs[:2]), np.hstack(imgs[2:])]), "scene_cameras_2x2.png")


if __name__ == "__main__":
    main()
