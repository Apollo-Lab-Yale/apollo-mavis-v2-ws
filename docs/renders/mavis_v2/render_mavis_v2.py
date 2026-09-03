"""Render mavis_v2 reference images -> docs/renders/mavis_v2/ (operator convention).

Usage (from the workspace root, sim repo's uv env)::

    cd apollo-xarm7-sim && MUJOCO_GL=egl uv run python \
        ../docs/renders/mavis_v2/render_mavis_v2.py [out_dir]

Writes the scene cameras (cam_front, cam_top, view_wrist_cam, grip_wrist_cam), a
2x2 contact sheet, and ``operator_view.png`` from MuJoCo's free camera using the
scene's default ``view`` (azimuth +90 / elevation -30: camera at -Y looking +Y),
which frames the red obstacle (the -X end) on the LEFT, matching the operator's
real view of the cell (the gripper arm renders nearer, the camera-only arm far).
The older ``facing_outer_edge*.png`` in this directory are NOT regenerated.
"""

from __future__ import annotations

import os
import struct
import sys
import zlib
from pathlib import Path

os.environ.setdefault("MUJOCO_GL", "egl")

import mujoco  # noqa: E402
import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "apollo-xarm7-sim" / "src"))
from apollo_xarm7_sim import REGISTRY  # noqa: E402

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


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent)
    out.mkdir(parents=True, exist_ok=True)
    built = REGISTRY.build("mavis_v2")
    model, data = built.model, mujoco.MjData(built.model)
    mujoco.mj_resetDataKeyframe(model, data, 0)
    mujoco.mj_forward(model, data)
    opt = mujoco.MjvOption()
    opt.geomgroup[:] = 1
    opt.geomgroup[3] = 0  # hide collision-only pads
    rendered: dict[str, np.ndarray] = {}

    def save(img: np.ndarray, name: str) -> None:
        img = np.ascontiguousarray(img)
        _png(out / name, img)
        rendered[name] = img
        print("wrote", out / name, img.shape)

    with mujoco.Renderer(model, 720, 1280) as r:
        cam = mujoco.MjvCamera()
        cam.type = mujoco.mjtCamera.mjCAMERA_FREE
        cam.lookat[:] = OPERATOR_VIEW["lookat"]
        cam.distance = OPERATOR_VIEW["distance"]
        cam.azimuth = model.vis.global_.azimuth  # +90: at -Y looking +Y (obstacle on the left)
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
