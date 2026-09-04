# 14 — External interface over Dora (dora-rs 1.0) (binding once approved)

Status: **draft v0.2 (2026-09-03) — decisions applied, pending final review.**
Written from four independent dora-rs 1.0.1 experiments run on the lab machine
on 2026-09-03 (artifacts: `/tmp/dora-bench`, `/tmp/dora-exp-mavis`,
`/tmp/dora-tripod-exp`, `/tmp/dora-probe`; throwaway venv `/tmp/dora-venv`)
and the code as of 2026-09-03; v0.2 applies the user's decisions of
2026-09-03 (changelog in §0). Conforms to `00-overview.md` v0.3 except for the
§2 "no Dora in v1" bullet, which §13 below amends. Spelling authority for dora
node / stream / command ids and for the JSON payloads is **this document**;
Python symbols are owned by `01-core.md` / `04-runtime.md` once the §13
amendments land. Extends 04-runtime §3/§4/§5/§11/§12/§14, 12-dagger
§1/§7/§8/§12, 11-safety §4/§10, 10-frames §2/§6. Everything here is additive:
with `dora.enabled: false` (the default) the runtime is byte-for-byte the
phase-11 runtime.

## 0. Decision record

**Decision (user, 2026-09-03): dora-rs 1.0 becomes the runtime's EXTERNAL
integration bus.** Observation streams go out for the whole **process
lifetime** — with or without a session — (both wrist cameras including the
Perception Arm's depth image, arm states, the RØDE microphone, telemetry);
commands come in (policy actions from an independent policy repo). It
replaces the home-grown ZMQ protocol that would otherwise have been written
for the same purpose. **The runtime's internals do not change**: one process,
the 100 Hz `ControlLoop`, the twin safety gate, the recorder, FastAPI REST +
WS + video for the browser UI, and the AsyncTrainer as a runtime-spawned GPU-1
process on its private ZMQ REQ/REP channel (12-dagger §7). Dora is a
boundary, not a skeleton.

**Fixed viewpoint without a command surface (user, 2026-09-03).** Other
programs (e.g. another robot's controller) that need the Perception Arm's
camera as a viewpoint do **not** command the arm over dora. An operator parks
the Perception Arm by teleop (or a `start_from: profile:<id>`) and ends the
session; the publishers keep running, so the consumer reads
`cam_view_wrist_cam` (+ depth) with the camera pose stamped on every frame
(§4.2, §7). No external viewpoint-command surface exists in v1 (Appendix A
lists it as a v2 candidate).

**Cell facts (2026-09-03).** Two xArm7 control boxes, both powered and on the
wire as of 2026-09-03: the **Perception Arm** (arm id `view`; wrist Intel
RealSense D435 + RØDE NT-USB Mini microphone) on control box
`192.168.2.219`, and the **Manipulation Arm** (arm id `grip`; xArm Gripper G2
+ wrist camera) on control box `192.168.1.201`. Neither arm carries a 6-axis
F/T sensor. Prose below uses these names; the ids appear in stream layouts
and config.

**Changelog v0.1 → v0.2 (2026-09-03, user decisions applied):**

- Control plane: the runtime-owned private coordinator/daemon is *the* design;
  the `external` / shared-systemd mode is dropped (§2.2, §12, §13).
- Policy node lifecycle: dynamic placeholder started by the policy repo itself;
  the runtime-spawned alternative is withdrawn (§6, §14).
- Reference package: decided — separate small GitHub repo
  `apollo-mavis-v2-policy-node` in the Apollo-Lab-Yale org, created in
  phase-12, depending only on `dora-rs` + `numpy`, shipping the LeRobot
  adapter and the CI fake node (§6.4).
- "Tripod mode" and the whole external viewpoint-command surface
  (`view_lookat` / `view_goto` / `view_hold` / `view_rail`, ownership/lease,
  `CommandSource.EXTERNAL` label 5, `ViewStatus` as a command result) are
  removed from v1 and parked in Appendix A. Replacement: process-lifetime
  publishers + parked Perception Arm (§7). Camera pose stays as *output*
  metadata on every camera frame (§4.2); `arm_state` is published between
  sessions by a read-only idle arm reader (§4.2).
- §5 reduced to `policy_action` / `policy_spec` / `policy_status` (+ reserved
  `weights_reload`).
- Unattended-motion caps: proposed defaults accepted; the AABB workspace
  boundary will be replaced by the digital-twin scene boundary the user will
  provide later (Appendix A).
- Cell facts corrected: two control boxes (not three), IPs above, no F/T
  sensor; user-facing arm names introduced.

Why the 2026-09-01 verdict ("not for v1", `docs/research/dora-middleware.md`)
is reversed *at the boundary only*:

| 2026-09-01 blocker | 2026-09-03 status |
|---|---|
| dora 1.0 needs Python ≥ 3.11; the stack ran 3.10 | The runtime moved to **Python 3.12** in phase-07 (lerobot floor). core / sim / hardware stay ≥ 3.10 and therefore *cannot* import dora — a structural guarantee, not a convention |
| 1.0 was an RC with breaking wire changes | **dora-rs 1.0.0 GA 2026-09-02, 1.0.1 on 2026-09-03**; PyPI `dora-rs` + `dora-rs-cli` 1.0.1, `cp311-abi3` wheels, `pip`-installable CLI (no cargo). The 1.x freeze covers wire format (postcard), node APIs, CLI and YAML schema; Arrow major and PyO3 are explicitly outside it |
| No Python request/reply helpers | `send_service_request` / `send_service_response` exist (send side); receive-side correlation is still manual — which is why §5 uses pub/sub semantics for the policy path and keeps request/reply out of v1 |
| No xArm / twin / LeRobot nodes to reuse | Still true — and irrelevant at the boundary: the runtime *is* the node; foreign code only needs Arrow + a YAML stanza |
| Cross-process hop inside the 100 Hz safety loop | Not proposed. The loop never touches dora (§2.5); measured hop latency (below) is fine for 10–30 Hz policy actions and 25 Hz status, and useless for the servo path — this is stated as a hard rule |

Measured on the lab machine (Threadripper PRO 5975WX, Python 3.12, loopback,
another agent's dora load running concurrently at times; full JSON under
`/tmp/dora-bench/results/`):

| Path | p50 | p90 | p99 | max | notes |
|---|---|---|---|---|---|
| `send_output` cost, 921,600 B rgb8 frame | 157 µs | — | 293 µs | 10–12.5 ms first send (SHM setup) | one memcpy; `send_output_raw` 56 µs |
| `send_output` cost, 28 B float32 state | 90 µs | — | 156 µs | — | TCP path (< 4 KiB) |
| one hop, image @30 Hz | 290 µs | 407 µs | 536 µs | 58 ms once at startup | 601/601 delivered |
| one hop, state @100 Hz | 236 µs | 323 µs | 437 µs | 24 ms once | 2002/2002 delivered |
| two hops state → policy node → action @100 Hz | 524 µs | 662 µs | 775 µs | 6.2 ms | 0 seq gaps, `queue_size` 4/20 |
| two hops, same, box loaded | 520 µs | 739 µs | 2.58 ms | 8–9 ms | 1000 samples |
| two hops with two 921 KB images in flight, n=40 | 1.4–1.8 ms | — | 16–17 ms | 23 ms | small sample, unpinned |
| dynamic-node attach `Node("mavis_runtime")` | 21–31 ms | | | | re-attach after exit works repeatedly |
| service RTT dynamic client ↔ spawned server, 32 B | 182 µs | 216 µs | 455 µs | 1.5 ms | 300 serial calls |

CPU: ≈ 3–5 % of one core per Python node for 100 Hz state + 30 Hz 1 MB image.
Built-in timers `dora/timer/hz/30|100` ran at 30.04 / 100.07 Hz over 20 s.

## 1. Scope, vocabulary, pins

**In scope (v1 of the external interface):**

1. The runtime attaches to a dora dataflow as one **dynamic node**
   `mavis_runtime` for the whole process lifetime and publishes the streams of
   §4 — cameras, microphone, arm states and telemetry flow **with or without
   a session**; it consumes the commands of §5.
2. An **external policy** (independent repo, its own venv / GPU / language)
   drives a DAgger or inference session through `policy_action`, with the
   runtime keeping every safety and provenance rule of 12-dagger.
3. **Fixed viewpoint for other programs**: an operator parks the Perception
   Arm (teleop or profile), ends the session, and any external consumer
   (e.g. another robot's controller) reads the Perception Arm's camera frames
   with the camera pose stamped on each frame (§7). No arm is moved by
   anything other than the browser UI or `policy_action`.
4. Fake nodes, a private-port test harness and the reference policy-node
   repo so all of this is tested without hardware.

**Out of scope (v1):** any external viewpoint-command surface (look-at / goto /
hold / rail goals, per-arm ownership — Appendix A, v2 candidates); session
lifecycle / episode ops / profiles over dora (they stay REST + `/ws/control`;
04-runtime §13); the browser UI speaking dora; cross-machine daemons
(`--zenoh-peer`, `dora cluster`); a shared / operator-owned control plane
(not planned — §2.2); moving the AsyncTrainer or the in-process MLP policy
out of the runtime (§11 sketches the path); `dora record/replay` as a trusted
tool (§8, coordinator bug); audio into the dataset; anything inside the
100 Hz loop.

**Vocabulary.** *Node* = one OS process attached to the daemon. *Dynamic node*
= a node the daemon does not spawn (`path: dynamic`); it attaches with
`Node(node_id=...)`. *Placeholder* = a dynamic node declared in the runtime's
YAML so foreign processes can attach under a known id. *Control plane* = the
`dora coordinator` + `dora daemon` pair. *Bridge* = `DoraBridge`, the runtime
object owning the node handle.

**Version pins (binding).** Runtime optional extra
`dora = ["dora-rs>=1.0.1,<1.1", "dora-rs-cli>=1.0.1,<1.1", "pyarrow>=17"]`;
`uv.lock` pins one exact version for both dora packages (1.0.1 today) and the
bridge refuses to spawn / attach when `dora.__version__ != dora --version`
(0.x and 1.x do not interoperate; patch releases have changed on-disk
formats). `pyarrow` is pinned explicitly (it is only transitive via lerobot
today; Arrow is outside dora's 1.x freeze). Python 3.12 (runtime). The
reference policy-node repo depends on `dora-rs` (which itself requires
`pyarrow`) and `numpy` only (§6.4).

**Import confinement (binding).** `dora` and `pyarrow` are imported lazily and
only inside `apollo_mavis_v2_runtime/dora_bridge/` (ruff `TID251` bans both
names runtime-wide with a per-file-ignore for that package; an AST scan test
like `tests/test_chokepoint.py` enforces it). core / sim / hardware add `dora`
and `pyarrow` to their `banned-api` lists. The package is deliberately *not*
named `dora/` so it can never shadow the PyPI module.

## 2. Topology & lifecycle

### 2.1 Process picture

```
 ┌─────────────────────────── runtime process (GPU 0, Python 3.12) ───────────────────────────┐
 │ ControlLoop 100 Hz ─ twin gate ─ ArmSender ×N ─ RecorderThread ─ FastAPI (REST/WS/video) │
 │        │ snapshot (LatestSlot)          ▲ CommandBus.submit            ▲ LatestSlots        │
 │        ▼                                │                               │                    │
 │  DoraBridge (bus thread) ── Node("mavis_runtime") ── publishers/taps ── ExternalPolicySrc  │
 └──────────────┬────────────────────────────────────────────────────────────────────────────┘
                │ TCP 127.0.0.1:<daemon_port> (control) + zenoh SHM/TCP 127.0.0.1 (data)
   ┌────────────┴────────────┐        ┌──────────────┐   ┌──────────────────┐   ┌───────────────┐
   │ dora daemon + coordinator│        │ policy node  │   │ viewpoint        │   │ probe node    │
   │ (owned children, private │        │ (dynamic id  │   │ consumer (dyn.   │   │ (spawned,     │
   │  ports, loopback only)   │        │  `policy`)   │   │  id `viewer`)    │   │  keepalive)   │
   └──────────────────────────┘        └──────────────┘   └──────────────────┘   └───────────────┘
   AsyncTrainer (GPU 1) stays a runtime child on ZMQ tcp://127.0.0.1:5757 — not a dora node.
```

### 2.2 Who owns the control plane — decision

The researchers split three ways (runtime spawns coordinator + daemon; runtime
runs `dora up` iff `dora status` fails; operator/systemd owns a shared
instance). **Decision (user, 2026-09-03): the runtime owns a private control
plane — coordinator + daemon are runtime children on pinned non-default
ports. This is the only mode.** A shared / operator-owned (`systemd`) control
plane is not planned. Reasons:

- `dora up` binds the machine-global defaults (coordinator 6013, daemon
  53291), has no flag for the daemon's dynamic-node port and none of the zenoh
  flags, and `dora down`/`destroy` on those ports is **machine-wide**. Three
  agents collided on exactly this during the 2026-09-03 experiments.
- Localhost-only operation (§9) needs `dora daemon --zenoh-no-multicast
  --zenoh-listen 127.0.0.1:<port>`; only an explicit daemon start can pass it.
- The runtime must survive daemon death anyway (§8), so it already has to
  know how to re-run bring-up.

Bring-up (`dora_bridge/control_plane.py::DoraControlPlane`), run from
`Runtime.start()` after `start_previews()` (all steps are best-effort and never
block serving; failures leave the bridge `unavailable`):

```
1. check versions: python `dora.__version__` == `dora --version` (else disabled + detail)
2. render <var_dir>/mavis_v2.dora.yml from RuntimeConfig (§2.3); `dora validate --strict-types` it
3. setsid  dora coordinator --port <coordinator_port> --store memory            (cwd = var_dir)
   setsid  dora daemon --coordinator-port <coordinator_port>
                       --local-listen-port <daemon_port>
                       --zenoh-no-multicast --zenoh-listen 127.0.0.1:<zenoh_port>   (cwd = var_dir)
   wait for `dora status` (DORA_COORDINATOR_PORT exported) ≤ 5 s
4. dora start <yaml> --name mavis_v2 --detach   → dataflow uuid7 (cwd = var_dir; out/ lands there)
5. os.environ["DORA_ZENOH_CONNECT"] = "tcp/127.0.0.1:<zenoh_port>"; Node("mavis_runtime",
   daemon_port=<daemon_port>) on the bus thread → state `attached`
```

Shutdown (`Runtime.stop()`): `dora stop mavis_v2 --grace-duration 2s`, then
`dora down --coordinator-port <own>`, then SIGTERM → SIGKILL the two child
PIDs the runtime spawned (verified: `dora down` reports success even when the
daemon link is broken and leaves daemon + nodes running). The runtime never
issues `dora down`/`destroy` against a port it did not spawn.

After attaching, the bridge validates `node.node_config()` against its
expected ids (outputs missing from the YAML are not published, unknown inputs
are ignored and counted) — a cheap guard against a stale rendered YAML.

`dora run` (coordinator-less) is not used: it ends when all spawned nodes
exit and does not host dynamic attaches reliably (one experiment attached,
another failed with `no node with ID`); `dora up/start` also unlocks `dora
list/node/logs`.

### 2.3 The dataflow YAML (generated, versioned)

`dora_bridge/dataflow.py::render_dataflow(cfg, camera_ids, mic_id, python)`
writes `<var_dir>/mavis_v2.dora.yml`; the rendered text is also committed as
`apollo-mavis-v2-runtime/dataflows/mavis_v2.example.dora.yml` for the sim
config (`dora validate --strict-types` clean in CI). Shape (ids of §4/§5):

```yaml
# generated by apollo_mavis_v2_runtime.dora_bridge.dataflow — do not edit
nodes:
  - id: mavis_runtime            # the runtime attaches here (Node("mavis_runtime"))
    path: dynamic
    inputs:
      tick: dora/timer/hz/10                                   # bridge watchdog
      probe_heartbeat: probe/heartbeat                         # dataflow liveness
      policy_action: {source: policy/action, queue_size: 1, queue_policy: drop_oldest}
      policy_spec:   {source: policy/spec,   queue_size: 1}
      policy_status: {source: policy/status, queue_size: 8}
    outputs: [heartbeat, session, telemetry, events, arm_state, arm_cmd, obs_state,
              policy_reset,
              cam_view_wrist_cam, cam_view_wrist_cam_depth, cam_grip_wrist_cam,   # per config
              mic_mic_view]
  - id: policy                   # placeholder: the policy repo attaches as Node("policy")
    path: dynamic
    inputs:
      obs_state:    {source: mavis_runtime/obs_state,    queue_size: 1, queue_policy: drop_oldest}
      session:      mavis_runtime/session
      policy_reset: mavis_runtime/policy_reset
      events:       {source: mavis_runtime/events, queue_size: 64}
      cam_view_wrist_cam: {source: mavis_runtime/cam_view_wrist_cam, queue_size: 1, queue_policy: drop_oldest}
      cam_grip_wrist_cam: {source: mavis_runtime/cam_grip_wrist_cam, queue_size: 1, queue_policy: drop_oldest}
    outputs: [action, spec, status]
  - id: viewer                   # placeholder: a fixed-viewpoint consumer (e.g. another robot's
    path: dynamic                #   controller) attaches as Node("viewer"); inputs only, no outputs
    inputs:
      arm_state:   {source: mavis_runtime/arm_state,   queue_size: 1, queue_policy: drop_oldest}
      session:     mavis_runtime/session
      cam_view_wrist_cam:       {source: mavis_runtime/cam_view_wrist_cam,       queue_size: 1, queue_policy: drop_oldest}
      cam_view_wrist_cam_depth: {source: mavis_runtime/cam_view_wrist_cam_depth, queue_size: 1, queue_policy: drop_oldest}
  - id: observer                 # placeholder: loggers / rerun bridges; receives everything
    path: dynamic
    inputs: { <every mavis_runtime output>: {source: mavis_runtime/<id>, queue_size: 1, queue_policy: drop_oldest} }
  - id: probe                    # the ONLY spawned node: keeps the dataflow Running and
    path: <sys.executable of the runtime venv>      # is the daemon-liveness canary
    args: -m apollo_mavis_v2_runtime.dora_bridge.nodes.probe
    inputs: {tick: dora/timer/hz/1}
    outputs: [heartbeat]
```

Rules baked into the renderer: every runtime input is `queue_size: 1,
drop_oldest` except `events`-like fan-in (`policy_status`); `input_timeout` is
never set (it would close request-style inputs); `debug.enable_debug_inspection`
is **never** emitted (§8); interpreters are always pinned (`dora` spawns `.py`
nodes with the system python otherwise); env values are strings. The `probe`
node exists because the daemon finishes a dataflow when its spawned nodes exit
and nobody verified an all-dynamic dataflow stays `Running` — a 1 Hz spawned
node settles the question by construction and doubles as the liveness canary
(§8). Ids use `[a-zA-Z0-9_]` only: `dora validate` accepted dotted ids too
(checked 2026-09-03), but only underscore ids were exercised end-to-end, and
`/` is the `node/output` separator. Ids are opaque tokens; consumers subscribe
to declared ids and never parse them.

### 2.4 `DoraBridge` state machine

`apollo_mavis_v2_runtime/dora_bridge/bridge.py::DoraBridge` is owned by
`Runtime` for the **process lifetime** (like `TrackerReader` and
`MicrophoneReader`): cameras preview before any session, the microphone and
tracker are process devices, arm states are read between sessions (§4.2
"Arm states without a session"), and a fixed-viewpoint consumer must keep
receiving frames after the session that parked the arm has ended (§7).
Session-scoped facts travel in the `session` stream (§4.2), never in the
node's lifecycle.

```
disabled ──(enabled & extra present & versions match)──► unavailable
unavailable ──(control plane up, dataflow started, Node() ok)──► attached
attached ──(STOP | ERROR "daemon channel broken" | tick+probe silent > 1 s)──► detached
detached ──(retry: 1 s → 10 s backoff; re-runs §2.2 steps 3–5)──► attached
any ──(Runtime.stop)──► closed
```

- **disabled**: `dora.enabled: false`, or the `[dora]` extra is missing, or the
  python/CLI versions differ. A startup warning carries the reason; the
  runtime is fully functional; `telemetry.external.state == "disabled"`.
- **unavailable / detached**: nothing may block on the bridge. Every publish is
  `bridge.try_publish(id, payload, metadata) -> bool` and returns `False`
  without side effects; every consumer of inbound data sees "no data" (hold
  semantics, §8).
- **attached**: the bus thread runs; inbound events are classified:
  `INPUT` → dispatch by id; `INPUT_CLOSED` → mark that input closed (policy:
  `policy_attached=false` ⇒ hold, §6.3); `STOP` (id `MANUAL` or
  `ALL_INPUTS_CLOSED`) → `detached`; `ERROR` whose text contains `Receiver
  timed out` → normal idle (this is what `next(timeout)` returns on timeout in
  1.0.1, **not** `None`); `ERROR` containing `daemon channel broken` / `fatal`
  → `detached`; `None` from `next()` = all senders dropped → `detached`.
  Watchdog: the `tick` timer input (10 Hz) and `probe_heartbeat` (1 Hz) are
  the dataflow's pulse — both silent for > 1 s ⇒ `detached` even without an
  ERROR (a spawned node whose daemon dies can otherwise block forever in
  `next()`; verified).
- **Instance exclusivity**: dora accepts duplicate node ids silently (three
  concurrent `Node("policy")` were all accepted). The bridge therefore takes an
  `fcntl.flock` on `<var_dir>/mavis_runtime.lock` before attaching and refuses
  (state `unavailable`, detail `another runtime holds the node id`) if it is
  held. Every outbound message carries `epoch` so consumers can detect a
  runtime restart, and every inbound command must echo `session_id` (§3.2).

### 2.5 Threads and the "never on the tick" rule

| Thread | Rate | Owns | Notes |
|---|---|---|---|
| `dora-bus` | event-driven, 2 ms poll | the `dora.Node` handle; **all** `send_output` / `try_recv` / `drain` calls | Node methods take an internal `try_lock` and the 1.0.1 docstring says re-entry from a second thread while the GIL is released panics; one experiment saw concurrent sends succeed, another did not test it. Binding: single owner thread. Outbound: producers put into per-topic depth-1 slots (images, state, telemetry) or a bounded FIFO (events, policy_reset) and set a `Condition`; the bus thread drains slots newest-first, then `node.try_recv()` until empty, then waits ≤ `bus_poll_s` (2 ms). Inbound latency therefore adds ≤ 2 ms — irrelevant at 10–30 Hz. If phase-12 verifies that `next(timeout)` on one thread plus `send_output` on another is safe, the receive side may move to its own thread without changing `DoraBridge`'s API |
| `dora-publisher` | driven by `bus.snapshot.wait_fresh(0.1)` in a session; by the idle arm reader (§4.2) otherwise | `arm_state`/`arm_cmd`/`obs_state` decimation, `events` diffing, `session` 1 Hz, `telemetry` at `telemetry_hz` | reads snapshots only; owns its own `RecorderKinematics` instance (one `MjData` per thread — 03-sim §8) for `tcp_pose_world` / `camera_pose_world` |
| `EncoderWorker` ×streams (existing) | stream fps | JPEG encode | gains `taps: list[Callable[[CameraFrame], None]]` invoked after the `seq` dedup and before `cv2.cvtColor` (hub.py); the bridge's `CameraTap` just drops the frame reference into the topic slot — the copy into Arrow happens on `dora-bus` |
| `MicrophoneReader` (existing) | telemetry_hz | mic capture | calls `bridge.try_publish("mic_<id>", …)` per `MicFrame` once `MicFrame.samples` exists (phase-11 additive) |
| `ControlLoop` | 100 Hz | — | **never calls the bridge.** It reads the plain Python object the bridge filled (`ExternalPolicySource`) exactly as it reads `bus.tracker` today; phase-12 adds **no** new branch to the loop |

Cost budget on `dora-bus`: 2 × 30 fps × 0.16 ms (rgb) + 30 fps × 0.11 ms
(depth) + 50 Hz × 0.09 ms (state) + 30 Hz obs + 25 Hz telemetry + 25 Hz mic ≈
25 ms/s ≈ 3 % of one core (matches the measured 3–5 % per node). The SHM path
is pre-warmed at attach by sending one dummy frame per camera output (first
send costs 10–12.5 ms).

### 2.6 Discovery for foreign clients — `GET /api/dora`

Foreign code needs the connection facts of a private control plane. The
runtime exposes them over the existing REST surface (additive route, core
model `DoraInfo`):

```json
{"enabled": true, "state": "attached",
 "coordinator_port": 6113, "daemon_port": 53391,
 "zenoh_connect": "tcp/127.0.0.1:7447", "dataflow_name": "mavis_v2",
 "dataflow_id": "0199…", "node_id": "mavis_runtime",
 "placeholders": ["policy", "viewer", "observer"],
 "dataflow_yaml": "/home/…/apollo/dora/mavis_v2.dora.yml", "mavis_schema": 1}
```

A client does `export DORA_COORDINATOR_PORT=6113 DORA_ZENOH_CONNECT=tcp/127.0.0.1:7447`
and `Node("policy", daemon_port=53391)`. The same facts are printed by
`python -m apollo_mavis_v2_runtime.dora_bridge.nodes.env` for shell use.

## 3. Wire conventions

### 3.1 Payloads

- **Typed data is a flat Arrow array + metadata** (dora-hub / dora-rerun
  convention): images `UInt8[H*W*3]` with `width/height/encoding` metadata,
  depth `UInt16[H*W]`, vectors `Float32`/`Float64` flat. No `FixedSizeList`,
  no `Struct` on the hot streams (both work, neither is what hub nodes read).
  Consumers reshape: `event["value"].to_numpy(zero_copy_only=True).reshape(h, w, 3)`
  (14 µs measured).
- **Structured / low-rate data is one `Utf8` scalar holding JSON** whose
  schema is an exported core pydantic model (`SessionAnnounce`,
  `PolicySpecAnnounce`, …, §13). Consumers in TS/Python/Rust read the JSON schemas from core
  `schemas/`. dora metadata cannot carry nested dicts (they are silently
  stringified with a WARN), so anything nested lives in the payload.
- Units: metres, radians, seconds; quaternions **wxyz** (spine §3.1) — every
  quaternion field name ends in `_wxyz` or the metadata carries
  `quat_order: "wxyz"`, because dora's optional `std/math/v1/Pose` type uses
  xyzw. Frames are `FrameRef` strings (10-frames §2). Rail is always the last
  joint slot (10-frames §2.5).
- Every runtime output is sent with `send_output(id, pa.array(...), metadata)`;
  `send_output_raw` (bytes-only, needs all views released before `send()`) is
  an optimisation the bridge may adopt for images later without changing the
  wire shape.

### 3.2 Metadata carried by every message

Runtime → bus (all outputs): `mavis_schema: 1` (int), `epoch` (str,
`Runtime.epoch`), `session_id` (str, `""` when no session), `seq` (int,
per-topic monotonic from attach), `t_mono` (float, runtime `time.monotonic()`
— comparable with the WS video header and `StateSnapshot.t_mono`),
`wallclock_ns` (int). dora adds `timestamp` (daemon HLC, UTC datetime);
consumers may use it for cross-process latency, the runtime never reads it.

Bus → runtime (all inputs): `mavis_schema` (int; a different major is dropped
and counted), `session_id` (str; **must equal the current session for anything
that moves an arm** — mismatch or no session ⇒ dropped, `dropped_inputs++`,
mirroring the WS hello-epoch rule), `client` (str, free-form id of the sending
process), `seq` (int, per-client monotonic; non-monotonic ⇒ dropped, like
`KeysMsg.seq`). Timestamps supplied by clients are informational only — every
staleness decision uses the runtime's receive time.

### 3.3 Compatibility rules

`mavis_schema` (int) rides every metadata dict and every JSON payload
(`SessionAnnounce.mavis_schema`). **Additive, no bump:** new metadata keys,
new optional streams, new JSON fields with defaults, new `events.kind` values,
new placeholder nodes. **Breaking, bump + refuse:** renaming/removing ids or
required keys, changing dtype/shape semantics (flat f32 actions, HWC rgb8,
wxyz, per-arm block order), changing the meaning of `observation_id`,
changing the `action_source`/`control_mode` label maps. Deprecated keys are
kept for one minor and listed in `SessionAnnounce.deprecated_keys`.

## 4. Stream catalogue (runtime outputs)

### 4.1 Table

| id | rate | Arrow payload | extra metadata (beyond §3.2) | when published |
|---|---|---|---|---|
| `heartbeat` | 1 Hz | `Int64[1]` = seq | `attached_since` (float), `dataflow_id` (str), `state` (str) | always while attached |
| `session` | on every `SessionState` change + 1 Hz | `Utf8[1]` JSON `SessionAnnounce` | — | always (`session_id: null` when idle) |
| `telemetry` | `telemetry_hz` (25) | `Utf8[1]` JSON `TelemetryMsg` | — | always; byte-identical to `/ws/telemetry` |
| `events` | on event | `Utf8[1]` JSON `EventEnvelope` | `kind` (str) | always |
| `arm_state` | `dora.publish.state_hz` (50; ≤ 100) | `Float64[N_arms × 32]` | `arm_ids` (list[str]), `layout` (list[str], 32 names), `has_rail` (list[int]), `error_code`/`warn_code` (list[int]), `stale` (list[int]), `arm_source` (list[str]), `active_arm` (str), `gate_severity` (str), `gate_blocked` (bool), `watchdog_tripped` (bool), `tick` (int), `source` (`"loop"` \| `"idle"`) | **always**: from the loop snapshot while a session is RUNNING, from the idle arm reader otherwise (§4.2; gate/watchdog fields `false`, `tick` −1, `arm_source` / `active_arm` `""`) |
| `arm_cmd` | same ticks as `arm_state` | `Float64[Σ dof]` | `arm_ids`, `dof` (list[int]) | session RUNNING |
| `obs_state` | `dora.publish.obs_hz` (30; 10–100) | `Float32[S]` | `observation_id` (int, monotonic per session from 1), `tick`, `state_names` (list[str]), `arm_ids`, `frames` (list[str], per-arm FrameRef), `has_rail`, `image_camera_ids` (list[str]), `image_seq` (list[int]), `engaged_arm` (str, `""`), `episode_state` (str) | session RUNNING, modes dagger/inference (and collect when `publish.obs_in_collect`) |
| `policy_reset` | on reset | `Utf8[1]` JSON `PolicyResetMsg` | — | session RUNNING with `policy_source: external` |
| `cam_<camera_id>` | camera stream fps (preview 15 / session 30) | `UInt8[H*W*3]` | `camera_id`, `encoding: "rgb8"`, `width`, `height`, `primitive: "image"`, `frame_seq` (`CameraFrame.seq`), `frame_t_mono`, `frame_wallclock_ns`, `frame_ref: "camera:<id>"`, `mount` (`"ee:<arm>"` or `"world"`), `intrinsics` (list[float] `[fx,fy,cx,cy]`, when known), `distortion` (list[float]); wrist cams **always** (in and out of sessions) `q` (list[float], 8), `tcp_pose_world` (7), `camera_pose_world` (7, OpenCV convention), `pose_t_mono` (float, snapshot time used for the FK), `pose_source` (`"loop"` \| `"idle"`) | always (process-lifetime previews included) |
| `cam_<camera_id>_depth` | camera fps | `UInt16[H*W]` | as above with `encoding: "mono16"`, `depth_scale_m: 0.001`, `aligned_to: "color"`, same `frame_seq` as the rgb frame | when `CameraConfig.depth` (hardware) or the sim depth stream is on; else declared but silent |
| `mic_<mic_id>` | `telemetry_hz` (25) | `Float32[1920]` mono PCM in [−1, 1] | `sample_rate: 48000`, `channels: 1`, `sample_type: "f32"`, `block_seq`, `t_mono_first_sample`, `rms_dbfs`, `peak_dbfs`, `overruns`, `status` (MicStatus) | when `microphone.enabled` and the reader retains samples |

### 4.2 Details

**`arm_state` block (32 per arm, `layout` spells the names):**
`q1..q7, rail_pos` (rail slot `0.0` when `has_rail == 0`), `dq1..dq7, drail`
(`0.0`; rail velocity unobservable), `ee_base.x,y,z,qw,qx,qy,qz` (TCP in
`arm_base:<id>`, = `ArmState.ee_pose`), `ee_world.x,y,z,qw,qx,qy,qz` (TCP in
`world` via `SceneKinematics.tcp_world`), `gripper_open_frac`, `rail_pos_m`
(`NaN` when no rail). Frame-free and session-layout-independent so a
fixed-viewpoint consumer or a logger never needs the dataset conventions.

**Arm states without a session.** 04-runtime §5 tears the workcell down at
session end (`arm.stop()` + `disconnect()`), so publishing `arm_state` for
the process lifetime needs one additive piece: an **idle arm reader**
(`dora_bridge/idle_state.py::IdleArmReader`, hardware only) that, while no
session exists and the bridge is enabled, holds a *read-only* connection to
each configured control box (`XArmAPI(..., report_type='real')` report
stream, or polled `get_servo_angle(is_real=True)` + gripper/rail reads at
≤ `publish.idle_state_hz`; never a mode/state write, never a command) and
feeds the same snapshot slot the loop feeds in a session. It is paused before
BRINGUP and resumed after TEARDOWN, like the phase-11 `HardwareProbe`. In sim
the preview scene's `MjData` keeps the last session's final joint vector when
the preview scene equals the session scene (keyframe otherwise), so the parked
pose survives session end there too. Consequence for consumers: `arm_state`
and the per-frame camera pose are valid whenever the bridge is `attached`;
`session.session_id == null` tells them nothing is moving the arm.

**`obs_state`** is exactly `Observation.state` as `make_obs_fn` builds it
today (10-frames §6.1: per-arm `[joint1..7.pos, gripper.pos, rail.pos,
ee.x,y,z,qw,qx,qy,qz]` with `ee.*` in the arm's **recording frame**), so a
policy sees the dataset layout. It is the **lead input** for policy nodes
(dora-hub `dora-policy-inference` pattern): the node buffers the newest
`cam_*` frame per camera and, on each `obs_state`, aligns by
`image_seq[i] == frame_seq` (or by `t_mono` within `max_image_age_s`).
Images are never copied into `obs_state`.

**`session`** — `SessionAnnounce` is the contract message; a client that
joins late learns everything from the next 1 Hz repeat:

```python
class SessionAnnounce(BaseModel):            # core protocol/external.py
    mavis_schema: int = 1
    epoch: str
    session_id: str | None
    state: str                               # SessionState value or "idle"
    spec: SessionSpec | None
    kind: Literal["hardware", "sim"] | None
    arm_ids: list[str] = []                  # WorkcellConfig order (block order everywhere)
    has_rail: dict[str, bool] = {}
    frames: dict[str, FrameRef] = {}         # recording frames actually in force
    action_space: str | None = None          # "delta_ee" (v1 requirement, 12-dagger §6)
    action_names: list[str] = []
    state_names: list[str] = []
    camera_ids: list[str] = []
    cameras: dict[str, CameraAnnounce] = {}  # {resolution, fps, frame_ref, mount,
                                             #  intrinsics?, T_E_C? | T_W_C?, depth: bool}
    policy_source: Literal["checkpoint", "external"] | None = None
    dataset_root: str | None = None          # collect / dagger
    run_id: str | None = None                # dagger
    deprecated_keys: list[str] = []
```

**`events`** — `EventEnvelope{kind, t_mono, wallclock_ns, session_id, payload}`
with `kind` ∈ `collision` (`CollisionEvent`), `gate` (`GateEvent`),
`episode_saved` (`{episode_index, summary: EpisodeSummary, dataset_root,
spool_path, run_id}` — what an external trainer needs), `episode_discarded`,
`policy_anomaly` (`PolicyAnomalyEvent`), `policy_swap` (`{version,
checkpoint_path}`; in-process policies), `policy_version_changed`
(external policies, §6.5), `reset_watermark`, `session_error`. Unknown kinds
are additive.

**Cameras.** The publish point is a tap in `EncoderWorker` right after the
`frame.seq` dedup — per-stream fps pacing and the pre-session previews come
for free with zero extra threads. `camera_pose_world` is the FK of the
snapshot whose `t_mono` is nearest `frame_t_mono` (the publisher keeps a
32-entry `(t_mono, q_by_arm)` ring = 320 ms) composed with the camera-in-TCP
transform: sim `T_E_C = {p (0.070, 0.000, 0.050) m, q_wxyz (0.7071, 0, 0,
0.7071)}` derived from `xarm7_on_rail.xml` (optical axis = tool +Z exactly;
camera 7 cm along tool +X, 5 cm along +Z); hardware from
`CameraConfig.extrinsics_file` with `extrinsics_frame: ee:<arm>` (10-frames
§2.3). The pose metadata is stamped on every frame, in and out of sessions
(§7 relies on it). `CameraFrame.t_mono` is receive time — RealSense colour
has tens of ms of pipeline latency, so consumers doing metric geometry should
use frames taken while the arm is at rest (`arm_state` joint velocities ≈ 0,
which is the parked-arm case) rather than mid-motion (`t_capture_mono` is a
later additive field). `intrinsics` (`[fx, fy, cx, cy]`; sim
`fx = fy = 240/tan(28.5°) = 442.0 px` at 640×480 for `fovy 57`; hardware
`CameraConfig.intrinsics` or the RealSense profile read once) and
`distortion` ride the same metadata, so with `camera_pose_world` a consumer
back-projects its own depth pixels into world without any other channel.

**Depth** needs additive plumbing that does not exist yet: core
`CameraFrame.depth: np.ndarray | None` ((H, W) uint16, mm) +
`depth_scale_m: float = 0.001`, `CameraConfig.depth: bool = False` +
`align_depth_to_color: bool = True`; hardware `RealSenseCamera` enabling
`rs.stream.depth` z16 and `rs.align(rs.stream.color)` in its capture thread
(02-hardware §8 already reserves `depth`); sim `RenderService` gaining a depth
sibling (`Renderer.enable_depth_rendering()`, metres → uint16 mm) for cameras
in `dora.publish.depth_cameras`, lifting 03-sim §7's "depth off in v1" for
those streams only. The Perception Arm's wrist camera on hardware must then be
configured `kind: realsense, serial: <RealSense serial>, depth: true` — **not** the phase-11
`v4l2` by-id path (UVC open blocks librealsense on the same device). Recorder
and VideoHub ignore `depth` (datasets unchanged).

**Microphone** re-publishes the phase-11 `MicrophoneReader` cadence (one
frame per telemetry tick = 1920 samples at 48 kHz) rather than inventing a
second ring; it requires `MicFrame.samples: np.ndarray | None` (float32,
additive) — coordinate with the phase-11 owner.

**`policy_reset`** — `PolicyResetMsg{reason: "handback" | "episode_boundary" |
"session_start" | "anomaly" | "session_stop", after_observation_id: int,
session_id}` is sent wherever `PolicyRunner.drop_and_requery()` / `pause()`
fire today (12-dagger §6 handback rule). The runtime then drops every
`policy_action` whose `observation_id <= after_observation_id` (the
watermark) — this replaces the in-process lock that prevents a pre-handback
chunk from moving the arm after `reset()`.

## 5. Command catalogue (runtime inputs)

v1 has exactly one command family — the external policy's. Nothing else on
the bus can move an arm (the viewpoint-command surface is a v2 candidate,
Appendix A).

| id | producer placeholder / output | Arrow payload | required metadata (beyond §3.2) | queue |
|---|---|---|---|---|
| `policy_action` | `policy/action` | `Float32[K*D]` row-major, K chunk rows × D dims | `observation_id` (int), `chunk_len` K (int ≥ 1), `action_dim` D (int), `chunk_dt_s` (float), `policy_id` (str), `policy_version` (int), `compute_ms` (float), optional `image_seq_used` (list[int]), `finite` (bool) | 1, drop_oldest |
| `policy_spec` | `policy/spec` | `Utf8[1]` JSON `PolicySpecAnnounce` | — | 1 |
| `policy_status` | `policy/status` | `Utf8[1]` free text (dora-hub `status` convention) | — | 8 |
| `tick` | `dora/timer/hz/10` | — | — | bridge watchdog |
| `probe_heartbeat` | `probe/heartbeat` | `Int64[1]` | — | dataflow liveness |

**Reserved ids (declared in the compatibility ledger, not implemented in v1):**
`weights_reload` / `weights_ack` (runtime-driven hot-swap of an external
policy via the dora service pattern, §11.3), `cmd_request` / `cmd_response`
(generic `CommandBus` exposure — session / episode ops stay REST + WS in v1).
Reserving the names keeps a later addition additive.

**Validation on receipt (bus thread, before anything reaches a slot):** JSON
parses into the pydantic model (else dropped + `dropped_inputs++`, reason in
`policy_status`-style log); `mavis_schema` major matches; `session_id`
matches; `seq` monotonic per `client`; numeric payloads finite where required
(`policy_action` NaN rows are *passed through* — the executor's NaN 3-strike
is the guard, 12-dagger §12); `action_dim == len(session action_names)` and
`chunk_len × action_dim == len(payload)` else dropped. A dropped input never
raises and never blocks.

## 6. External policy contract

### 6.1 Session selection

`SessionSpec.policy_source: Literal["checkpoint", "external"] = "checkpoint"`
(core, additive). Validator: `external` requires `mode ∈ {dagger,
inference}` and `policy is None`. `SessionInfo` echoes it. Bring-up
(`SessionManager._build_policy_stack`) for `external`:

1. The bridge must be `attached` and a `policy_spec` must have been received
   within `dora.policy.spec_stale_s` (3 s; the node heartbeats it at 1 Hz) —
   otherwise **409 `no external policy attached`**. No waiting: the spec is
   cached, so `POST /api/session` stays fast.
2. Frame / space check, verbatim as for checkpoints: `spec.action_space ==
   "delta_ee"` and every session frame equals `spec.action_frame` — else 409
   `policy/dataset frame mismatch`. `spec.action_names` must equal the
   session's `arm_action_names(...)` concatenation exactly; `spec.state_names`
   must be a subset of the session's state names (the node selects dims by
   name; `obs_state` always carries the full layout).
3. Construct `ExternalPolicySource` (§11.1) instead of `PolicyRunner`; **no
   `resolve_policy`, no `MLPPolicy`, no `PolicyReloaderImpl`, no
   `AsyncTrainerClientImpl`** (§11.3). DAgger still creates the recorder, the
   run store's `v000000` is skipped, `TrainerStatus` is absent
   (`trainer_alive: null`), and `events.episode_saved` carries what an external
   trainer needs. Inference is unchanged apart from the source.
4. Publish `policy_reset{reason: "session_start"}` and start `obs_state`.

### 6.2 What the policy node must do

```
attach  Node("policy", daemon_port=…)   (facts from GET /api/dora)
loop:
  ev = node.next(timeout=1.0)
  INPUT session        -> cache SessionAnnounce; (re)validate own spec against it; publish spec
  INPUT cam_<id>       -> keep newest frame per camera (frame_seq, t_mono, ndarray view)
  INPUT obs_state      -> if rate-limit allows: build Observation (select state dims by name,
                          attach images whose frame_seq == image_seq[i] or age <= max_image_age_s),
                          act(), publish `action` echoing observation_id, publish `status` on error
  INPUT policy_reset   -> policy.reset(); drop pending chunks; ignore obs older than after_observation_id
  INPUT events         -> optional (episode_saved for training; policy_anomaly for logging)
  timer 1 Hz           -> publish `spec` (heartbeat)
  INPUT_CLOSED / STOP  -> keep running and wait for the runtime to re-attach (do not exit)
```

- `action` payload: `Float32[K*D]`; `K == 1` for per-step policies. The
  runtime consumes row 0 immediately and advances one row every `chunk_dt_s`
  until a newer action arrives (implements 12-dagger §6.2 chunked behaviour
  without touching `ActionAnchor`). `chunk_dt_s` defaults to the policy's own
  period; a policy trained on dataset-frame deltas at `fps` should send
  `chunk_dt_s = 1/fps` (open question §14).
- Deltas are per-`chunk_dt_s` increments in the session's recording frame,
  gripper absolute (10-frames §6). The runtime scales row 0 by
  `(dt / chunk_dt_s) × staleness_scale` exactly as it scales in-process
  outputs by `(dt / period)`.
- `observation_id` is **mandatory**: it is how the runtime applies the reset
  watermark and computes `obs_age = now − t_mono(observation_id)`; actions
  whose observation is older than `dora.policy.max_obs_age_s` (0.5 s) are
  dropped and counted (`actions_late`).
- `policy_version` (int, monotonic within `policy_id`) is recorded verbatim
  into DAgger frames (`policy_version` column) and shown as
  `DaggerStatus.policy_version = f"{policy_id}/v{version:06d}"`.

`PolicySpecAnnounce` (JSON, exported core model):

```python
class PolicySpecAnnounce(BaseModel):
    mavis_schema: int = 1
    policy_id: str                      # e.g. "act-pick-2026-09-03"
    policy_version: int
    node_version: str                   # package version of the node
    spec: PolicySpecModel               # pydantic mirror of core PolicySpec (action_space,
                                        #   action_frame, action_names, state_names, camera_keys, version)
    rate_hz: float                      # the node's own act() rate (10-30)
    chunk_len: int = 1
    chunk_dt_s: float | None = None
    loader: str = "custom"              # "mlp_bundle_v1" | "lerobot_pretrained" | "custom"
    device: str = ""
    supports_reload: bool = False       # reserved (weights_reload, §11.3)
    health: Literal["ok", "degraded", "error"] = "ok"
    detail: str = ""
    uptime_s: float = 0.0
    acts_total: int = 0
    last_compute_ms: float | None = None
    extrinsics_sha: str | None = None   # camera-frame policies: 10-frames §5.3 check
```

### 6.3 Staleness and hold (unchanged rule, runtime clock)

`ExternalPolicySource.staleness_scale(now)` keeps the in-process rule
verbatim: `1.0` while `now − t_recv ≤ period + 0.05 s`, then linear decay to
`0` over `5 × period`, then hold (`period = 1 / dagger.policy_rate_hz`; at
15 Hz the arm is fully held **0.45 s** after the last action). `t_recv` is
the bus thread's receive time. Two additional hold triggers: `policy_spec`
silent > `spec_stale_s` (3 s) ⇒ `policy_attached = false` ⇒ hold; the
bridge leaving `attached` ⇒ hold. Telemetry: `DaggerStatus.policy_stale` /
`InferenceStatus.policy_stale` (fixing an existing 04-runtime §15 drift) and
the `external` block (§13). Resume after a gap goes through the handback slew
window like a takeover handback (12-dagger §6).

### 6.4 Reference repo `apollo-mavis-v2-policy-node` (decided)

**Decision (user, 2026-09-03):** a separate small GitHub repo
`apollo-mavis-v2-policy-node` in the **Apollo-Lab-Yale** org, created in
phase-12 (first push when the user asks, per workspace conventions). Its
package `mavis_policy_node` depends only on `dora-rs` (which itself pulls
`pyarrow` and `numpy`) and `numpy`; it never imports `apollo_mavis_v2_*`.
The policy repo starts the node process itself (dynamic placeholder
`policy`, §2.3) — the runtime never spawns policy nodes. The repo ships the
**LeRobot adapter** and the **CI fake node** from day one; `torch` /
`lerobot` are optional extras of the adapters, not of the package:

```
mavis_policy_node/
  contract.py      MAVIS_SCHEMA, stream/command ids, metadata keys, validate_action_metadata(),
                   validate_spec() — pure Python; the runtime's tests import the same spellings
  types.py         Observation / PolicyOutput / PolicySpec dataclasses — field-for-field COPIES
                   of core interfaces/policy.py (comment: "copy, do not import"), plus
                   depth: dict[str, np.ndarray] and observation_id
  protocol.py      Policy duck-type Protocol: spec, reset(), act(obs) -> PolicyOutput,
                   load_weights(path); optional act_chunk(obs) -> (K, D)
  messages.py      events -> Observation; PolicyOutput -> (pa.array, metadata); spec JSON
  node.py          PolicyNode event loop (§6.2), rate limiting, image alignment, heartbeat
  adapters/torch_bundle.py   MLPBundlePolicy — today's MLPNet/bundle format, moved verbatim
  adapters/lerobot.py        LeRobotPolicy — PreTrainedPolicy + pre/post processors +
                             sidecar mavis_policy.json {action_space, action_frame, action_names,
                             state_names, camera_key_map, task}; select_action / predict_action_chunk
  fake.py          FakePolicy (ScriptedPolicy port: deterministic deltas, FAKE_NAN_AT, FAKE_CHUNK,
                   FAKE_DELAY_MS, echo mode)
  __main__.py      mavis-policy-node --loader {fake,mlp_bundle,lerobot,entrypoint} --path …
                   --entrypoint pkg.mod:make_policy --device cuda:0 --daemon-port … --rate-hz …
```

The runtime repo ships its own minimal `dora_bridge/nodes/fake_policy.py`
(numpy + pyarrow) so runtime CI never depends on the other repo; the
policy-node repo's CI runs `fake.py` against a private control plane of its
own; a shared `contract.py` golden-metadata test runs in both repos.

## 7. Fixed viewpoint: the parked Perception Arm (no command surface)

**Model (user, 2026-09-03).** The runtime publishes cameras, microphone, arm
states and telemetry for the whole process lifetime (§2.4, §4) — with a
session and without one. To give another program (e.g. another robot's
controller) a viewpoint, an operator:

1. opens a teleop session, drives the Perception Arm (arm id `view`) to the
   wanted viewpoint with the tracker / keyboard (or uses `start_from:
   profile:<id>` to reach a saved pose), and
2. ends the session (`DELETE /api/session`).

TEARDOWN holds the arm where it is (zero-twist ramp, no native gohome —
04-runtime §5), the publishers keep running, and the consumer reads
`cam_view_wrist_cam` (+ `cam_view_wrist_cam_depth`) at preview fps with
`camera_pose_world`, `tcp_pose_world`, `q`, `intrinsics` and `distortion` on
every frame (§4.2). Nothing on the bus can move the arm afterwards: the only
inbound command family is the policy's (§5), and it is accepted only inside
a DAgger / inference session whose `session_id` it echoes (§3.2).

Consequences and rules:

- **No ownership, no lease, no goal state machine** in v1. The browser UI is
  the only human control surface; the `viewer` placeholder (§2.3) has inputs
  only.
- **Parked-arm pose is stable by construction**: between sessions the
  hardware arm is not commanded (the idle reader is read-only, §4.2); the
  controller keeps whatever `arm.stop()` left. A consumer that needs to detect
  a re-park watches `arm_state` (joint velocities, `session_id` transitions)
  or simply uses the pose stamped on each frame.
- **Multiple viewpoints** = multiple sessions parking the arm at different
  poses over time; there is no simultaneous multi-viewpoint in v1.
- **Recording is untouched**: no new `action_source` label, no sidecar
  `owners` block; viewpoint changes are ordinary teleop frames of the session
  that made them.
- **Digital-twin scene boundary**: when the user provides the twin scene
  boundary (Appendix A), it becomes the workspace check for any future
  externally commanded motion; the parked-arm model needs no such check.

What a consumer does (also `examples/viewer_node.py`, ≈ 30 lines):

```
export $(python -m apollo_mavis_v2_runtime.dora_bridge.nodes.env)   # or GET /api/dora
node = Node("viewer", daemon_port=…)
for ev in node:
    if ev["type"] == "INPUT" and ev["id"] == "cam_view_wrist_cam":
        m = ev["metadata"]; img = ev["value"].to_numpy().reshape(m["height"], m["width"], 3)
        T_W_C = m["camera_pose_world"]   # [x, y, z, qw, qx, qy, qz], OpenCV convention
        K = m["intrinsics"]              # [fx, fy, cx, cy]
```

## 8. Failure & staleness semantics

| Failure | Detection | Runtime response |
|---|---|---|
| `[dora]` extra missing / version mismatch / `dora.enabled: false` | import + `dora --version` at start | bridge `disabled`, warning with reason; runtime fully standalone; `telemetry.external.state` |
| Control plane cannot start (port busy, binary missing) | spawn / `dora status` timeout 5 s | `unavailable`; retry 1 → 10 s backoff; serving never blocked |
| Daemon dies while attached | `ERROR daemon channel broken`, or `tick` + `probe_heartbeat` silent > 1 s | `detached`; external policy holds via staleness (§6.3); the runtime reaps its children and re-runs bring-up; `reattach_count++` |
| Dataflow stopped underneath (`dora stop`, coordinator restart) | `STOP` event (id `MANUAL`) or `INPUT_CLOSED` on every input | same as daemon death; a restarted dataflow has a new `dataflow_id` and re-attach works (verified) |
| Duplicate `mavis_runtime` (second runtime instance / stale process) | `flock` on `<var_dir>/mavis_runtime.lock` | second instance stays `unavailable` with detail; consumers key on `epoch` |
| Idle arm reader loses a control box (cable, power) between sessions | report stream silent > 1 s / poll raises | that arm's `arm_state` block marks `stale: 1` and freezes; camera frames keep flowing with `pose_source: idle` and the last good `q`; reconnect with the same 1 → 10 s backoff; session BRINGUP is unaffected (it owns the connection while a session exists) |
| Policy node crash / `kill -9` | no `policy_action`: `staleness_scale` → 0 after `period + 0.05 + 5·period` (0.45 s at 15 Hz); `policy_spec` silent > 3 s | arms hold; `policy_stale: true`, `external.policy_attached: false`; DAgger/inference session continues (takeover works; recorder keeps recording human frames); on a fresh spec + actions the handback slew window applies |
| Policy node restarts with a different `policy_version` mid-episode | metadata diff | recorded as received; `events.policy_version_changed` + `external.version_changes_mid_episode++` (12-dagger §4 invariant becomes advisory for external policies — accepted trade-off, §11.3) |
| Late / duplicate / pre-watermark action | `observation_id` ≤ watermark or obs age > `max_obs_age_s` | dropped, `actions_late++`; never applied |
| Malformed input (bad JSON, wrong dims, non-monotonic `seq`, wrong `session_id`, other `mavis_schema` major) | validation on the bus thread | dropped, `dropped_inputs++`, rate-limited WARN |
| Back-pressure (slow consumer) | depth-1 slots on the runtime side; `queue_size: 1` on the daemon side | runtime drops oldest, never blocks; control thread never touches dora ⇒ tick rate unchanged by construction |
| Bridge thread exception | try/except around dispatch | log + count; `detached` + re-attach; motion unaffected |
| Log flood: dora 1.0.1 prints JSON WARN diagnostics to **stdout** per ≥ ~600 KB output (`dora-rs/dora#2742`), per `queue_size` discard, and zenoh SHM watchdog priority warnings | observed in all four experiments; one experiment found `RUST_LOG=error` suppresses them, another found neither `RUST_LOG=error` nor YAML `min_log_level: error` does | phase-12 verifies `RUST_LOG=error` set before `import dora`; if insufficient, the bridge `dup2`s fd 1 to `<var_dir>/node-stdout.log` (rotating) while attached and restores it at detach (uvicorn logs go to stderr; Python's own `sys.stdout` is re-opened on the saved fd). Acceptance: ≤ 1 dora diagnostic line/s on the runtime's stdout with two cameras publishing |
| Coordinator control-plane bug (**reproduced twice**): `debug.enable_debug_inspection: true` + `dora topic echo/hz` on a ~1 MB topic hits the coordinator's 1 MiB WebSocket cap (`ws_server.rs MAX_CONTROL_MESSAGE_BYTES`), resets the daemon socket, leaks a subscription, the dataflow vanishes from `dora list`, `dora down --force` reports success while daemon + nodes keep running | — | never emit `debug.enable_debug_inspection`; never run `dora topic` against image topics; treat `dora record`/`replay` as untrusted for image streams until the fix; report upstream with the `/tmp/dora-bench` repro (open question §14). For live inspection use the browser UI or the `observer` placeholder |
| `/dev/shm/*.zenoh` segments after abrupt kills | count at start | logged; the runtime cleans segments whose creator PID is dead (best effort) |

Everything that moves an arm degrades to **hold** — never to a ramp of stale
commands, never to a native reset. The twin gate remains the last word on
every external command (11-safety §4): dora is a transport, not authorisation.

## 9. Networking & security

Observed with plain `dora run` / `dora up` on this machine: coordinator and
daemon bind loopback, **but** zenoh in the daemon and in every Python node
opened UDP multicast scouting on `224.0.0.224:7446`, UDP sockets on the LAN
IP (`192.168.0.88`) and the Tailscale IP (`100.121.64.104`), and one node had
a TCP listener on `*:34329`. Left alone, any process on the LAN / tailnet
could inject `policy_action` messages; the twin gate bounds the physical
damage, not the intent.

Binding for v1 (**single host**):

- Control plane (runtime-owned): `dora coordinator --port <P> --store memory` (binds
  loopback in 1.0) and `dora daemon --coordinator-port <P> --local-listen-port
  <Q> --zenoh-no-multicast --zenoh-listen 127.0.0.1:<Z>`; the runtime exports
  `DORA_ZENOH_CONNECT=tcp/127.0.0.1:<Z>` to itself before creating the node
  (dynamic nodes do not inherit the daemon's env — `dora daemon --help`) and
  publishes the same facts in `GET /api/dora` for foreign clients. Default
  ports 6113 / 53391 / 7447 (never the machine-global 6013 / 53291).
- Verification recipe (also an acceptance test): `ss -lunp | grep 224.0.0.224`
  shows no dora / runtime / fake-node PID; `ss -ltnp` for those PIDs lists only
  `127.0.0.1` listeners.
- No coordinator auth in v1 (`--auth` is an operator option); the NICs facing
  the two control boxes (Perception Arm `192.168.2.219`, Manipulation Arm
  `192.168.1.201`) must never see zenoh traffic — `--zenoh-no-multicast` is
  what guarantees it. Phase-09 confirms on hardware that the xArm SDK report
  streams are unaffected.
- Cross-machine (policy on another GPU box, other robots' code elsewhere) is
  **v2**: `--zenoh-peer` / `--zenoh-listen <lab LAN IP>:<port>` plus an
  allow-list or `--auth`, decided explicitly by the user; nothing in this
  document assumes it.

## 10. Testing without hardware

Four tiers; markers `dora` (needs the extra + CLI; skipped otherwise) and the
existing `egl`/`perf`. CI runs the matrix with and without the `[dora]` extra.

1. **Codec / contract unit tests (pyarrow only, no daemon).** `codec.py`
   round-trips: rgb8/mono16 images (shape via metadata), state/obs vectors,
   action decoding incl. chunk rows, JSON models; golden metadata dicts shared
   with `mavis_policy_node.contract`; `render_dataflow` output is stable and
   `dora validate --strict-types` clean (CLI is offline-capable).
2. **Fake-node unit tests (no daemon).** `DoraBridge` takes a `node` duck type
   (`try_recv`, `send_output`, `node_config`, `dataflow_id`); `tests/dora/fake_node.py`
   implements it with in-memory queues. Covers: state machine transitions on
   `STOP`/`ERROR`/silence; `try_publish` no-op when not attached; input
   validation matrix (schema major, `session_id`, `seq`, dims, NaN
   pass-through); reset watermark; `ExternalPolicySource.staleness_scale`
   timeline (fresh → decay → hold at 0.45 s for 15 Hz); camera-pose metadata
   (`T_E_C` composition against `RecorderKinematics.camera_world`, ≤ 1e-6;
   `pose_source` flips `loop` ↔ `idle` across session start/stop);
   `IdleArmReader` with the FakeSDK (read-only: no `set_mode` / `set_state` /
   `set_servo_angle_j` / gripper writes recorded; pause before BRINGUP,
   resume after TEARDOWN); `INPUT_CLOSED` on `policy_*` ⇒
   `policy_attached=false`.
3. **Private-daemon integration (`-m dora`).** Fixture `dora_control_plane`
   picks three free ports, starts coordinator + daemon exactly as §9, `dora
   start`s the rendered YAML, yields `DoraInfo`, and tears down with `dora stop
   --name` + SIGTERM of its own PIDs — it **never** calls `dora down`/`destroy`
   without its own `--coordinator-port` (a colleague's coordinator may be
   running). Nodes: `nodes/fake_policy.py` (echo / scripted / NaN / delay /
   chunk modes), `nodes/viewer_probe.py` (subscribes `cam_view_wrist_cam` +
   `arm_state` as `viewer`, asserts the pose metadata is present on every
   frame and counts seq gaps, writes JSON), `nodes/rtt_probe.py` (measures
   two-hop RTT and seq gaps, writes JSON), `nodes/probe.py`. Cases: attach /
   re-attach after `dora stop` + restart; bring-up ≤ 5 s; RTT thresholds (§12
   numbers); image + depth seq continuity over 60 s; publishers alive with
   **no session** (viewer_probe receives frames + `camera_pose_world` before
   any session exists); `ss` loopback assertions; stdout diagnostics
   ≤ 1 line/s.
4. **Sim e2e (`-m "dora and egl"`).** Real sessions over HTTP/WS on the
   `mavis_v2` sim scene: (a) external inference — fake_policy hello → RUNNING;
   no hello → 409; frame mismatch → 409; `safety_debug` collision course
   blocked with `CollisionEvent.source == policy`; Space takeover/handback
   identical to the in-process path (jump-free test reused); `kill -9`
   fake_policy → `q_cmd` frozen ≤ 0.45 s + 1 tick, `policy_stale` true;
   restart → actions ignored until a fresh spec, then slew window; (b)
   external DAgger — zero trainer processes, recorder on, `events.episode_saved`
   per save, dataset `policy_version` equals the action metadata, mid-episode
   version change counted; (c) fixed viewpoint — with **no session** the
   `viewer_probe` receives `cam_view_wrist_cam` at preview fps with
   `camera_pose_world` / `q` / `intrinsics` metadata and `arm_state` at
   ≤ `idle_state_hz`; a teleop session then moves the Perception Arm to a new
   pose and is deleted; frames keep flowing across TEARDOWN (gap ≤ 2 frame
   periods), the post-session `camera_pose_world` equals the last in-session
   pose (≤ 1e-6 in sim), `pose_source` flips `loop` → `idle` and `session_id`
   is `""`; the rendered YAML's `mavis_runtime` inputs are exactly `{tick,
   probe_heartbeat, policy_action, policy_spec, policy_status}`
   (`node_config()` assertion); (d) control-loop non-interference — 60 s
   teleop with the
   bridge on vs off: tick p99 < 2 ms and `tick_overrun == 0` in both.

## 11. Migration of the in-process policy path and the DAgger trainer

### 11.1 `PolicySource` — one seam, two implementations

`GatedPolicyExecutor` touches the runner only through `latest()`,
`staleness_scale(now)`, `period`, `paused`, `pause()`, `resume()`,
`drop_and_requery()` and `policy.spec.version`; `_PolicySessionBase` adds
`start()/stop()`. Phase-12 names that surface:

```python
# apollo_mavis_v2_runtime/dagger/policy_source.py  (dora-free)
class PolicySource(Protocol):
    period: float
    spec: PolicySpec
    def start(self) -> None: ...
    def stop(self) -> None: ...
    def latest(self) -> tuple[PolicyOutput | None, float]: ...   # (output, t_recv)
    def staleness_scale(self, now: float) -> float: ...
    def drop_and_requery(self) -> None: ...                        # handback / boundary
    def pause(self) -> None: ...
    def resume(self) -> None: ...
    @property
    def paused(self) -> bool: ...
    def version_label(self) -> str: ...                            # telemetry string
    def current_version(self) -> int: ...                          # recorded per frame
```

`PolicyRunner` (in-process; unchanged behaviour, GPU 0) and
`dora_bridge/policy_source.py::ExternalPolicySource` (fed by the bridge;
`drop_and_requery()` publishes `policy_reset` and sets the watermark;
`current_version()` returns the metadata of the action in use) both satisfy
it; `GatedPolicyExecutor` is typed against the Protocol with no behaviour
change; `_build_policy_stack` branches on `spec.policy_source`. The recorder
takes `policy_version` from `source.current_version()` for the frame's
counterfactual (falls back to the last known version for NaN rows).

### 11.2 Phases

- **Phase A (phase-12, additive):** everything above; `policy_source:
  checkpoint` stays the default; both sources run the existing e2e suites.
- **Phase B (after the first hardware DAgger session validates dora latency
  under load; separate phase):** `MLPPolicy` + `MLPNet` + the bundle format
  move into `mavis-policy-node/adapters/torch_bundle.py`; the runtime's
  `torch` sanction narrows to `dagger/trainer`; `PolicyRunner` and
  `ScriptedPolicy` are deleted in favour of the fake node; `policy_source:
  external` becomes the default and the LaunchSheet gains the choice. A
  cross-repo bundle-format test guards `load_state_dict` compatibility
  between the trainer and the node.

### 11.3 The AsyncTrainer

**Stays a runtime-spawned ZMQ REQ/REP subprocess for `policy_source:
checkpoint`** (12-dagger §7 verbatim): the weight transport is already the
filesystem, the one-auto-restart semantics are implemented and tested, and
dora's Python service pattern is DIY correlation with orphaned in-flight
requests on server restart — the weakest pattern in the 2026-09-01 note, now
confirmed. It does not become a node.

For `policy_source: external` the runtime **does not run** `AsyncTrainer` or
`PolicyReloaderImpl`: training and hot-swap belong to the policy repo, fed by
`events.episode_saved` (summary + spool parquet path + dataset root) and the
dataset directory. Consequences, accepted as a trade-off and surfaced in
telemetry: the sanity gate, `LAST_KNOWN_GOOD` rollback and swap-only-at-
episode-boundary become recommendations to the policy repo (swap after
`episode_saved`); the runtime records `policy_version` as received and counts
mid-episode changes. The reserved `weights_reload`/`weights_ack` service pair
(runtime asks the node to load a checkpoint path, node replies with sha256 +
version; `PolicyReloaderImpl._load` maps a timeout / `ok: false` onto its
existing `_reject` path) is the v2 route to restore runtime-driven rollback
for nodes that share the checkpoint filesystem.

## 12. Configuration (`RuntimeConfig.dora`, 04-runtime §14 block)

```yaml
dora:
  enabled: false                 # default off until phase-12 lands; true + missing extra = disabled + warning
  node_id: mavis_runtime
  dataflow_name: mavis_v2
  coordinator_port: 6113         # private ports (never the machine-global 6013/53291); the runtime
  daemon_port: 53391             #   always owns coordinator + daemon (§2.2) — there is no other mode
  zenoh_port: 7447               # daemon --zenoh-listen 127.0.0.1:<zenoh_port>; exported to self and
                                 #   to foreign clients as DORA_ZENOH_CONNECT=tcp/127.0.0.1:<zenoh_port>
  var_dir: ~/apollo/dora         # rendered YAML, out/ logs, lock file, node-stdout.log
  attach_retry_s: [1.0, 10.0]    # backoff bounds
  bus_poll_s: 0.002
  publish:
    state_hz: 50                 # arm_state / arm_cmd (<= control.rate_hz) while a session runs
    idle_state_hz: 10            # arm_state between sessions (IdleArmReader, read-only; hardware)
    obs_hz: 30                   # obs_state (10-100); policy nodes rate-limit themselves
    obs_in_collect: false        # also publish obs_state in collect sessions
    cameras: all                 # all | [camera ids]
    depth_cameras: [view_wrist_cam]   # sim depth stream / hardware depth publish list
    image_pose: true             # q / tcp_pose_world / camera_pose_world / intrinsics on wrist-cam
                                 #   frames, in and out of sessions (the fixed-viewpoint contract, §7)
    audio: true
    telemetry: true
    events: true
  policy:
    spec_stale_s: 3.0            # no policy_spec heartbeat -> policy_attached=false -> hold
    max_obs_age_s: 0.5           # actions referencing older observations are dropped
  log:
    quiet_node_diagnostics: true # RUST_LOG=error; fd-1 redirect fallback (§8)
```

Acceptance numbers derived from §0 measurements (used by phase-12): two-hop
RTT `obs_state → fake_policy → policy_action` over ≥ 1000 samples **p50 ≤
1.5 ms, p99 ≤ 5 ms, max ≤ 60 ms, 0 lost** (measured 0.52–0.64 / 0.78–2.6 /
8–58 ms); one-hop 640×480 rgb8 **p99 ≤ 3 ms** and **0 seq gaps** for two
cameras + one depth stream over 60 s (measured 0.54–0.95 ms p99, 0 gaps);
`send_output` cost per 921,600 B frame **p99 ≤ 1 ms** (measured 0.29 ms);
`dora-bus` + `dora-publisher` CPU **≤ 10 % of one core** at full publish
load (measured 3–5 % per node); attach **≤ 5 s** after control-plane start
(measured 21–31 ms for the attach itself); hold after policy death **≤ 0.45 s
+ one tick** at 15 Hz.

## 13. Additive deltas per repo and the amendments this document requires

**core (01-core; spelling authority; all additive, dora/pyarrow-free):**
`bus.py` `Command.source: Literal["ws", "rest", "internal", "dora"]`;
`protocol/session.py` `SessionSpec.policy_source` (+ validator, echoed in
`SessionInfo`); new `protocol/external.py`: `MAVIS_SCHEMA = 1`,
`EXTERNAL_NODE_ID = "mavis_runtime"`, id constants for §4/§5,
`ARM_STATE_LAYOUT` (32 names), `PolicySpecModel`, `SessionAnnounce`,
`CameraAnnounce`, `PolicySpecAnnounce`, `PolicyResetMsg`, `EventEnvelope`,
`ExternalStatus`, `DoraInfo`; `protocol/telemetry.py`
`DaggerStatus.policy_stale: bool = False`, `InferenceStatus.policy_stale: bool
= False`, `TelemetryMsg.external: ExternalStatus | None = None` (after
`microphone`); `state.py` `CameraFrame.depth`, `CameraFrame.depth_scale_m`;
`schemas/config.py` `CameraConfig.depth`, `CameraConfig.align_depth_to_color`;
`EXPORTED_MODELS` += `SessionAnnounce`, `PolicySpecAnnounce`, `DoraInfo` (the
rest ride `$defs`); ruff `banned-api` += `dora`, `pyarrow`; §19 drift ledger
row (`policy_stale` promised by 04-runtime §15). **Not added** (v0.2):
`CommandSource.EXTERNAL`, `SessionSpec.external_arms`, `ArmTelemetry.owner`,
the `View*` models, `action_source` label 5 — see Appendix A.

```python
class ExternalStatus(BaseModel):            # telemetry.external
    enabled: bool = False
    state: Literal["disabled", "unavailable", "attached", "detached", "closed"] = "disabled"
    detail: str = ""
    node_id: str = "mavis_runtime"
    dataflow_id: str | None = None
    reattach_count: int = 0
    publish_hz: dict[str, float] = {}       # measured per topic
    dropped_inputs: int = 0
    actions_late: int = 0
    policy_attached: bool = False
    policy_id: str | None = None
    policy_version: int | None = None
    policy_rate_hz: float | None = None
    action_age_s: float | None = None
    version_changes_mid_episode: int = 0
    idle_reader: Literal["off", "running", "paused", "stale"] = "off"   # §4.2
```

**hardware (02-hardware §8, §4):** `RealSenseCamera` enables the depth stream +
`rs.align` when `CameraConfig.depth` (FakeSDK coverage); `~2 ms/frame` align
budget noted; `XArmDriver.connect(readonly=True)` (report stream only — no
`set_mode` / `set_state` / `set_servo_angle_j`, no gripper / rail writes) for
the idle arm reader (§4.2), asserted by a FakeSDK call-log test. **sim (03-sim §7):** optional depth sibling stream in
`RenderService` for listed cameras. **runtime (04-runtime):** `[dora]` extra;
`dora_bridge/` package (§2, §11) incl. `idle_state.py::IdleArmReader` (§4.2),
`dagger/policy_source.py`, `EncoderWorker.taps`, `StateSnapshot.arm_source`
(published in `arm_state`), `GET /api/dora`, telemetry `external`,
`RuntimeConfig.dora`, dataflow example + `examples/viewer_node.py`, tests
§10; `SessionManager` pauses the idle reader before BRINGUP and resumes it
after TEARDOWN — the `ControlLoop` gains **no** new branch. **ui (05-ui
§12):** regenerate types; one additive chip (`EXTERNAL POLICY attached /
stale` on the DAgger / Inference panel) — no layout work.

**Doc amendments to make when this draft is approved (history is kept, never
deleted):**

- `00-overview.md` → v0.4: §2 keep the 2026-09-01 bullet, prefix it
  "Superseded in part (2026-09-03) — see next bullet", add the amendment
  bullet ("Dora at the boundary, not inside" + the §0 table's essence + the
  hard rule that no dora call runs on the control thread); §1 hard rules:
  `runtime[dora]` adds dora-rs + pyarrow, ui never speaks dora; §4 items 3/4:
  policy may be in-process or external (`policy_source`); §6 command-source
  list += external policy actions (no external viewpoint goals — Appendix A);
  §8 retitled "Runtime ↔ UI protocol (browser) and runtime ↔ external
  interface (Dora)" with one bullet on process-lifetime publishers and the
  parked-arm viewpoint model; §10 map += `14-dora-interface.md`.
- `docs/research/dora-middleware.md`: a dated "Status update (2026-09-03)"
  box under the header (boundary recommendation superseded, interior verdict
  unchanged; what changed; measured numbers; new observations: multicast
  scouting, dynamic nodes need `dora up/start`, interpreter pinning, the
  1 MiB coordinator bug, stdout diagnostics); version-table errata line.
- `04-runtime.md`: §1 deps, §2 tree, §3 thread table (`dora-bus`,
  `dora-publisher`, idle arm reader), §4 slots (`external_policy`), §5
  bring-up/teardown steps (idle reader pause/resume; arm connection handed to
  the read-only reader after TEARDOWN), §11 `PolicySource`, §12, §13.1
  `GET /api/dora`, §13.3 `external`, §14 `dora:` block, §15 rows, §16 tier.
- `12-dagger-protocol.md` → v1.1: §1 external variant, §7 "spawned only for
  in-process policies", §8 external hot-swap note, §11/§12/§13 rows.
- `01-core.md`, `02-hardware.md` §4/§8 (read-only connect; depth),
  `03-sim.md` §7, `05-ui.md` §12, `CLAUDE.md` (one line: two control boxes
  and their IPs; dora at the boundary), ws `README.md` topology line,
  `docs/prompts/README.md` status row + dependency graph. `10-frames` §7.3/§9
  and `11-safety` §4 are **not** touched — no label 5, no `owners`, no
  `EXTERNAL` source in v1.

## 14. Open questions for the user

**Resolved 2026-09-03 (user):** control plane — runtime-owned private
coordinator + daemon is the only mode; policy node — dynamic placeholder
started by the policy repo itself; reference package — separate repo
`apollo-mavis-v2-policy-node` (Apollo-Lab-Yale), created in phase-12, with
the LeRobot adapter and the CI fake node; tripod mode / external viewpoint
commands — removed from v1 (Appendix A), replaced by the parked-arm model
(§7); recording under external control — moot (no external arm control in
v1); unattended-motion caps — proposed defaults accepted, the AABB to be
replaced by the digital-twin scene boundary the user will provide (Appendix
A); cell — two control boxes (Perception Arm `view` 192.168.2.219,
Manipulation Arm `grip` 192.168.1.201), no F/T sensor.

Still open:

1. **Camera encoding for remote consumers** — raw rgb8 at 30 Hz is fine on
   one host; do you want a JPEG/downscaled variant in v1, and which RealSense
   (serial `322143060792` or `349643062582`) is the Perception Arm's camera?
2. **Upstream bug report** — file the coordinator 1 MiB WebSocket-cap /
   leaked-subscription / `dora down` false-success issue with the
   `/tmp/dora-bench` repro before we rely on any `dora topic`/`record` tooling?
3. **Session control over dora** — keep REST/WS-only (proposed). With the
   parked-arm model a viewpoint consumer needs no session at all; only
   *changing* the viewpoint needs an operator (or an HTTP client) to open one.
4. **How long to keep the in-process default** — until the first hardware
   DAgger session validates dora latency under load (proposed), or a fixed
   number of phases?
5. **Idle arm reader on hardware** — confirm that holding a read-only
   `XArmAPI` connection to each control box between sessions is acceptable
   (xArm Studio will show a connected client; phase-09 verifies that the
   read-only client does not disturb the 100 Hz servo stream once a session
   starts, and that the controller accepts the reconnect).

## 15. Cross-references

Spine: `00-overview.md` §2 (amended), §4, §6, §8. Session engine and threads:
`04-runtime.md` §3/§4/§5/§6/§11/§12/§13/§14/§15/§16. DAgger: `12-dagger-protocol.md`
§1/§6/§7/§8/§12/§13. Safety chokepoint and watchdogs: `11-safety-collision.md`
§4/§7/§10. Frames, layouts: `10-frames-and-data.md` §2/§6. Teleop path used
to park the Perception Arm: `13-tracker-teleop.md` §4, `04-runtime.md` §6.
Core spellings: `01-core.md` §5.2/§6/§11/§12/§14/§15.
Research: `docs/research/dora-middleware.md` (2026-09-01 + status update).
Implementation plan: `docs/prompts/phase-12-dora-interface.md`.

## Appendix A — v2 candidates: external viewpoint-command surface (removed from v1)

Removed from v1 by the user on 2026-09-03 in favour of the parked-arm model
(§7); recorded here so a later phase can pick it up as an additive change.
Nothing in this appendix is implemented, reserved as an id, or exported as a
schema in v1.

- **Commands** (were §5 rows; producer placeholder `tripod`): `view_lookat`
  (`ViewLookAt{arm_id, target, frame, ref_frame_seq, standoff_m ∈ [0.15, 1.5],
  approach, up, roll_rad, rail_m}`), `view_goto` (`ViewGoto{position,
  orientation_wxyz, frame incl. ee:<id> resolved once, target: camera|tcp,
  rail_m}`), `view_hold`, `view_rail` (`pos_m ∈ [0, 0.65]`, `speed_mps ≤
  0.10`); metadata `goal_id`, `ttl_s`, `speed_scale ∈ (0, 1]`; goals only,
  never velocities.
- **Ownership** per arm (`none | human | external`), `SessionSpec.external_arms`
  (teleop / collect only), lease `owner_lease_s` 5 s with `view_hold` as
  keepalive, human always preempts via `switch_arm`, no ownership change while
  recording; telemetry `ArmTelemetry.owner`, UI lock glyph + toast.
- **Motion path**: a `_external_step` branch of `_resolve_arms` reusing the
  tracker path — leash `clamp_pose_to_leash` at 25 mm / 0.2 rad, IK
  `_solve_target`, common `dq_max` clamp, `supervisor.filter`; look-at
  geometry with camera-defined `standoff_m`, `up` fallback `−Y_world` when
  `|z_C·up| > 0.95`, `T_W_E* = T_W_C* ⊕ inv(T_E_C)`.
- **Unattended-motion caps (defaults accepted by the user 2026-09-03):**
  `max_v_mps 0.25`, `max_w_radps 1.0`, `rail_mps 0.10`, `standoff_m
  {min 0.15, max 1.5, default 0.6}`, `reach_tol {0.005 m, 0.02 rad, 10
  ticks}`, `blocked_after_s 1.0`, `require_ttl false`. The proposed
  `workspace_aabb_world [[-0.75, -0.45, 0.80], [0.75, 0.45, 2.0]]` +
  `table_top_clearance_m 0.05` **will be replaced by the digital-twin scene
  boundary the user will provide later**; until then no external motion
  exists that would need it.
- **Status / provenance**: `view_status` JSON (`state ∈ idle | approaching |
  reached | blocked | unreachable | held | preempted | rejected`, reasons,
  pose, intrinsics, gate) as a *command result*; `CommandSource.EXTERNAL`
  with dataset `action_source` label `"5": "external"` and the sidecar
  `owners` block. In v1 the camera pose that `view_status` carried rides the
  camera frames instead (§4.2).
- **Failure rules that would come back with it**: hold within one control
  tick on `INPUT_CLOSED` / detach / lease expiry; `rejected: workspace | nan |
  bad_frame | owned_by_* | recording | stale_twin | fault:<code>`.
- **Open point carried over**: a policy driving the Manipulation Arm while a
  foreign node drives the Perception Arm in one dagger/inference session
  changes the obs/action layout rules (was §14 Q4 in v0.1).
