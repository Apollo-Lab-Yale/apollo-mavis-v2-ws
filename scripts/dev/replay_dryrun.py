#!/usr/bin/env python3
"""Replay one recorded MAVIS v2 episode through the external-policy (dora) interface in SIM.

The dry run of 2026-09-11 (14-dora §16.6): a `mavis-policy-node --loader replay` process
attaches as the `policy` placeholder, subscribes the perception streams (obs_state, the two
wrist cameras, the microphone) and publishes the dataset's recorded actions on the per-arm
stream `action_<arm>` as if it were a trained policy - in the `delta_ee` space (the recorded
`action` column, 8/7 dims per arm) or in `abs_ee` (the commanded TCP per frame, `[x, y, z,
rot6d x 6, gripper, rail]` = 11/10 dims, from the dataset's `action.abs_ee` column or derived
from the deltas when the column is absent); this script drives the runtime side over REST/WS:
start an inference session (`policy_source: external`), walk the arms to the episode's first
frame with the playback `goto_initial`, watch telemetry while the node replays, end the
session, and print the node's fidelity report (the displacement errors of the delta path and,
whenever abs rows exist, the direct errors against the recorded commanded TCP). The node also
saves one decoded RGB frame per camera and the depth frame (if any) as PNG into `<out>/frames`.

    scripts/dev/replay_dryrun.py --episode 20260910T024317.864Z-8a4220 \
        [--dataset bc_demo/drawer_assembling] [--arms grip] [--mode step|chunk] \
        [--action-space delta_ee|abs_ee] [--timeline dense|wallclock] [--speed 1.0] \
        [--rate-hz 30] [--url http://127.0.0.1:8866] [--node-bin .../mavis-policy-node] \
        [--out DIR]

Prerequisites: a runtime with the dora bridge ON (the private sim instance of
`var/dryrun-inference/mavis_v2_dryrun.yaml`, never the production one on :8765) and the
policy-node venv (`--node-bin`). Runs with the RUNTIME venv's python (httpx + websockets):
    apollo-mavis-v2-runtime/.venv/bin/python scripts/dev/replay_dryrun.py ...
Never `uv run`.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import httpx
from websockets.sync.client import connect as ws_connect

WS = Path(__file__).resolve().parents[2]
DEFAULT_NODE_BIN = (
    Path.home() / "projects/apollo-mavis-v2-ws-p12/apollo-mavis-v2-policy-node/.venv/bin/mavis-policy-node"
)


def parse() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--episode", required=True, help="episode id (directory name under episodes/)")
    p.add_argument("--dataset", default="bc_demo/drawer_assembling", help="<ns>/<name>")
    p.add_argument("--arms", default="grip", help="comma list of arms the replay DRIVES")
    p.add_argument("--mode", default="step", choices=["step", "chunk"])
    p.add_argument("--action-space", default="delta_ee", choices=["delta_ee", "abs_ee"],
                   help="the space the node announces and streams (the session's recording stays delta_ee)")
    p.add_argument("--timeline", default="dense", choices=["dense", "wallclock"])
    p.add_argument("--speed", type=float, default=1.0)
    p.add_argument("--rate-hz", type=float, default=30.0)
    p.add_argument("--url", default="http://127.0.0.1:8866")
    p.add_argument("--node-bin", default=str(DEFAULT_NODE_BIN))
    p.add_argument("--out", default=None, help="output dir (default var/dryrun-inference/runs/<stamp>)")
    p.add_argument("--settle-s", type=float, default=0.5)
    p.add_argument("--timeout-margin-s", type=float, default=90.0)
    return p.parse_args()


def episode_dir(api: httpx.Client, dataset: str) -> Path:
    ns, name = dataset.split("/", 1)
    layout = api.get("/api/datasets/layout").json()  # DatasetLayoutInfo (04-runtime §10.6)
    mapped = (layout.get("namespaces") or {}).get(ns)
    if mapped and mapped.get("root"):
        root = Path(mapped["root"])
    else:
        root = Path(layout.get("generic_root") or (Path.home() / "data")) / ns
    return root / name / "episodes"


class Telemetry:
    def __init__(self, ws_url: str) -> None:
        self.sock = ws_connect(ws_url, max_size=None)

    def latest(self, timeout: float = 5.0) -> dict:
        t0 = time.monotonic()
        deadline = t0 + timeout
        msg = None
        while time.monotonic() < deadline:
            msg = json.loads(self.sock.recv(timeout=max(0.01, deadline - time.monotonic())))
            if msg.get("ts", 0.0) >= t0:
                return msg
        return msg or {}

    def close(self) -> None:
        self.sock.close()


def main() -> int:
    a = parse()
    arms = [x.strip() for x in a.arms.split(",") if x.strip()]
    stamp = time.strftime("%Y%m%dT%H%M%S")
    out = Path(a.out) if a.out else WS / "var" / "dryrun-inference" / "runs" / f"{stamp}-{a.action_space}-{a.mode}-{a.timeline}-x{a.speed:g}"
    out.mkdir(parents=True, exist_ok=True)
    report_path = out / "report.json"
    frames_dir = out / "frames"
    api = httpx.Client(base_url=a.url, timeout=120.0)
    health = api.get("/api/health").json()
    dora = api.get("/api/dora").json()
    if dora.get("state") != "attached":
        print(f"dora bridge is {dora.get('state')}: {dora.get('detail')}", file=sys.stderr)
        return 2
    if api.get("/api/session").status_code != 404:
        print("a session is already active - end it first", file=sys.stderr)
        return 2
    ep_dir = episode_dir(api, a.dataset) / a.episode
    if not (ep_dir / "frames.parquet").is_file():
        print(f"no frames.parquet under {ep_dir}", file=sys.stderr)
        return 2
    ns, name = a.dataset.split("/", 1)
    info = api.get(f"/api/datasets/{ns}/{name}/episodes/{a.episode}/playback").json()
    print(f"runtime {health['version']} epoch {health['epoch'][:8]}; episode {a.episode}: "
          f"{info['frames']} frames @ {info['fps']} fps ({info['duration_s']} s); arms {arms}; "
          f"action_space {a.action_space}, mode {a.mode}, timeline {a.timeline}, speed x{a.speed:g}")
    ws_url = a.url.replace("http://", "ws://") + "/ws/telemetry"

    # -- 1. the replay node (attaches as `policy`, waits at frame 0) ---------------------------
    env = dict(os.environ)
    env.update({
        "DORA_ZENOH_CONNECT": dora["zenoh_connect"],
        "DORA_ZENOH_MULTICAST": "off",
        "DORA_ZENOH_LISTEN": "tcp/127.0.0.1:0",
        "RUST_LOG": "error",
    })
    env.pop("DORA_COORDINATOR_ADDR", None)
    env.pop("DORA_COORDINATOR_PORT", None)
    cmd = [
        a.node_bin, "--loader", "replay", "--path", str(ep_dir), "--arms", ",".join(arms),
        "--replay-mode", a.mode, "--timeline", a.timeline, "--speed", str(a.speed),
        "--rate-hz", str(a.rate_hz), "--daemon-port", str(dora["daemon_port"]),
        "--settle-s", str(a.settle_s), "--report", str(report_path), "--log-level", "INFO",
        "--action-space", a.action_space, "--save-frames", str(frames_dir),
    ]
    (out / "node.cmd").write_text(" ".join(cmd) + "\n")
    node_log = open(out / "node.log", "ab")  # noqa: SIM115
    node = subprocess.Popen(cmd, env=env, stdout=node_log, stderr=subprocess.STDOUT, start_new_session=True)
    tele = Telemetry(ws_url)
    trace_rows: list[dict] = []
    session_id = None
    t_run0 = None
    try:
        deadline = time.monotonic() + 20.0
        ext = {}
        while time.monotonic() < deadline:
            ext = tele.latest().get("external", {})
            if ext.get("policy_attached") and ext.get("policy_arms") == arms:
                break
            time.sleep(0.2)
        else:
            print(f"replay node did not attach: external={ext}", file=sys.stderr)
            return 3
        print(f"policy attached: {ext['policy_id']} v{ext['policy_version']} @ {ext['policy_rate_hz']} Hz, drives {ext['policy_arms']}")

        # -- 2. the inference session with the external policy --------------------------------
        # SessionSpec has no action_space key: the session records delta_ee and the runtime
        # sizes the per-arm blocks from the ANNOUNCED spec (delta_ee 8/7 or abs_ee 11/10).
        spec = {
            "mode": "inference", "kind": "sim", "arms": ["grip", "view"],
            "frames": {"grip": "arm_base:grip", "view": "arm_base:view"},
            "sim_scene": "mavis_v2", "policy_source": "external", "start_from": "keep_current",
        }
        r = api.post("/api/session", json=spec)
        if r.status_code != 200:
            print(f"POST /api/session -> {r.status_code} {r.text}", file=sys.stderr)
            return 4
        session_id = r.json()["session_id"]
        t0 = time.monotonic()
        while api.get("/api/session").json()["state"] != "running":
            time.sleep(0.05)
            if time.monotonic() - t0 > 30:
                print("session never reached running", file=sys.stderr)
                return 4
        print(f"session {session_id[:8]} running ({time.monotonic() - t0:.2f} s)")

        # -- 3. walk the arms to the episode's first frame ------------------------------------
        t0 = time.monotonic()
        r = api.post("/api/session/playback", json={"repo_id": a.dataset, "episode_id": a.episode, "action": "goto_initial"})
        res = r.json()
        print(f"goto_initial -> {res['status']} ({time.monotonic() - t0:.1f} s) {res.get('detail', '')}")
        if not res.get("ok"):
            print("could not reach frame 0 - aborting", file=sys.stderr)
            return 5

        # -- 4. the node starts by itself once the arms sit at frame 0; watch telemetry --------
        expected_s = float(info["frames"]) / float(info["fps"]) / a.speed
        t_run0 = time.monotonic()
        budget = expected_s + a.settle_s + a.timeout_margin_s
        last_print = 0.0
        while time.monotonic() - t_run0 < budget:
            msg = tele.latest(timeout=2.0)
            if not msg:
                continue
            ext = msg.get("external", {})
            inf = msg.get("inference") or {}
            arms_t = {x["arm_id"]: x for x in msg.get("arms", [])}
            row = {
                "t": round(time.monotonic() - t_run0, 3),
                "policy_stale": inf.get("policy_stale"),
                "control_mode": inf.get("control_mode"),
                "action_age_s": ext.get("action_age_s"),
                "actions_late": ext.get("actions_late"),
                "dropped_inputs": ext.get("dropped_inputs"),
            }
            for arm_id, x in arms_t.items():
                pos = (x.get("ee_pose") or {}).get("position") or [None] * 3
                row[f"{arm_id}_ee_x"], row[f"{arm_id}_ee_y"], row[f"{arm_id}_ee_z"] = pos
                row[f"{arm_id}_rail_m"] = x.get("rail_pos_m")
                row[f"{arm_id}_grip"] = x.get("gripper_open_frac")
                row[f"{arm_id}_q"] = json.dumps([round(v, 5) for v in x.get("q", [])])
            trace_rows.append(row)
            if time.monotonic() - last_print > 5.0:
                last_print = time.monotonic()
                print(f"  t={row['t']:6.1f}s stale={row['policy_stale']} age={row['action_age_s']} "
                      f"late={row['actions_late']} dropped={row['dropped_inputs']}")
            if report_path.is_file():
                time.sleep(1.0)
                break
            time.sleep(0.15)
        else:
            print("timed out waiting for the replay report", file=sys.stderr)
    finally:
        # -- 5. end: the session first (no motion), then the node -----------------------------
        if session_id is not None:
            api.delete("/api/session")
        if node.poll() is None:
            os.killpg(node.pid, signal.SIGTERM)
            try:
                node.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(node.pid, signal.SIGKILL)
        node_log.close()
        tele.close()
        if trace_rows:
            keys = sorted({k for r in trace_rows for k in r})
            with open(out / "telemetry_trace.csv", "w", newline="") as fh:
                w = csv.DictWriter(fh, fieldnames=keys)
                w.writeheader()
                w.writerows(trace_rows)
    # -- 6. the verdict -------------------------------------------------------------------------
    if not report_path.is_file():
        print(f"no report at {report_path}; see {out / 'node.log'}", file=sys.stderr)
        return 6
    rep = json.loads(report_path.read_text())
    summary = rep.get("summary", rep)
    print(json.dumps(summary, indent=2, default=str))
    print(f"action_space {summary.get('action_space')} (abs rows: {summary.get('abs_source')}, "
          f"action_dim {summary.get('action_dim')}); phase {summary.get('phase')}, "
          f"{summary.get('n_rows_published')} rows in {summary.get('n_actions_published')} publishes")
    for arm_id, e in (summary.get("per_arm") or {}).items():
        if not e:
            continue
        pos, rot = e.get("position_error_mm") or {}, e.get("rotation_error_mrad") or {}
        line = (f"  {arm_id}: displacement err pos rms {pos.get('rms', float('nan')):.1f} / max "
                f"{pos.get('max', float('nan')):.1f} / final {pos.get('final', float('nan')):.1f} mm, "
                f"rot rms {rot.get('rms', float('nan')):.1f} mrad")
        apos, arot = e.get("abs_position_error_mm"), e.get("abs_rotation_error_mrad")
        if apos and arot:
            line += (f"; vs commanded TCP pos rms {apos['rms']:.1f} / max {apos['max']:.1f} / final "
                     f"{apos['final']:.1f} mm, rot rms {arot['rms']:.1f} / max {arot['max']:.1f} mrad, "
                     f"rail max {e.get('abs_rail_error_max_m')} m, start offset "
                     f"{e.get('abs_start_offset_mm', float('nan')):.1f} mm, r6 residual max "
                     f"{e.get('r6_residual_max')}")
        else:
            line += "; no abs rows (no action.abs_ee column and no derivation)"
        print(line)
    saved = summary.get("frames_saved") or {}
    if saved:
        print("frames saved: " + ", ".join(f"{k} -> {v.get('file', v.get('error'))}" for k, v in saved.items()))
    else:
        print(f"no frames saved (no camera frame reached the node); expected under {frames_dir}")
    stale = [r for r in trace_rows if r.get("policy_stale")]
    late = max((r.get("actions_late") or 0) for r in trace_rows) if trace_rows else None
    dropped = max((r.get("dropped_inputs") or 0) for r in trace_rows) if trace_rows else None
    print(f"telemetry: {len(trace_rows)} samples, policy_stale in {len(stale)}, actions_late max {late}, dropped_inputs max {dropped}")
    print(f"outputs in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
