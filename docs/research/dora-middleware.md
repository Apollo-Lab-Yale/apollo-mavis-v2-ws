# Research note: dora-rs (Dora) as middleware for the apollo-mavis-v2 stack

**Date:** 2026-09-01
**Sources:** github.com/dora-rs/dora @ `b37f8fc` (main, 2026-08-31), repo docs (`docs/*.md`), PyPI `dora-rs`, github.com/dora-rs/dora-hub, github.com/dora-rs/dora-lerobot.
**Question:** Should the xArm7 teleop / data-collection / DAgger / inference stack use Dora dataflow middleware, and if so where?

> **Status update (2026-09-03, implemented 2026-09-08 — phase-12).** The boundary half of this
> verdict is superseded; the interior half stands. dora-rs **1.0.1** is now the runtime's EXTERNAL
> integration bus (`docs/design/14-dora-interface.md`, v1.0): the runtime process attaches as one
> dynamic node `mavis_runtime` for its whole lifetime and publishes both wrist cameras (+ the sim
> depth sibling) with the camera pose stamped on every frame, both arms' states (read-only between
> sessions), the microphone, telemetry, the `session` contract message and `events`; the only
> inbound command family is the external policy's (`policy_action` / `policy_spec` /
> `policy_status`, `SessionSpec.policy_source: external`). Nothing inside the 100 Hz control loop
> touches dora, the AsyncTrainer stays a ZMQ subprocess and the browser UI never speaks dora.
> What changed since 2026-09-01: the runtime moved to Python **3.12** (phase-07), dora 1.0 went GA
> (1.0.0 on 2026-09-02, 1.0.1 on 2026-09-03; `dora-rs` + `dora-rs-cli` are pip wheels, no cargo);
> the "no reusable nodes" point is irrelevant at the boundary (the runtime IS the node). Measured on
> the lab host (phase-12 acceptance, 2026-09-08): two-hop `obs_state -> policy -> action` RTT at
> 30 Hz over 1000 samples p50 0.8 ms / p99 2.3 ms / max 5 ms, 0 lost; one-hop 921 KB rgb8 frames
> in-process send p99 <= 1 ms; `dora-bus` + `dora-publisher` threads 5–7 % of one core at the
> full publish load. New observations worth keeping (all in 14-dora §8/§9/§16): zenoh opens
> multicast scouting + per-NIC UDP + a wildcard TCP listener unless `DORA_ZENOH_MULTICAST=off` /
> `DORA_ZENOH_LISTEN=tcp/127.0.0.1:0` are set in EVERY node process; dynamic nodes need a
> coordinator-hosted dataflow (`dora up/start`, not `dora run`); interpreters must be pinned in the
> YAML; the coordinator's 1 MiB WebSocket cap breaks `dora topic echo/hz` on image topics; the node
> API prints JSON WARN diagnostics to **stdout** per >= 600 KB output and `RUST_LOG=error` does NOT
> silence them (the runtime dup2s fd 1 to a log while attached); `dora doctor` is the one CLI
> surface that lists registered daemons (`dora status --format json` and `dora list` do not);
> `next(timeout)` returns an `ERROR "Receiver timed out"` event on timeout, `None` only when every
> sender is gone. Versions table erratum: "0.5.0 = latest stable" was true on 2026-09-01 only;
> 1.0.1 is the pinned version (`runtime[dora]` extra, `uv.lock`).

**TL;DR recommendation (2026-09-01, interior verdict unchanged): not for v1 INSIDE the runtime.** Build the planned single-process runtime (option A) with transport-agnostic core interfaces. Two hard blockers today: (1) Dora 1.0 (the version with services, fault tolerance, record/replay — everything you'd want it for) requires **Python >= 3.11**, and our machine is 3.10; the 3.10-compatible stable release (0.5.0) is a different, older codebase missing those features. (2) The Dora ecosystem provides **no xArm node, no maintained LeRobot recorder, no MuJoCo digital-twin collision checker** — i.e. almost none of our hard work is reusable; we would write the same code plus YAML plumbing and pay a cross-process hop inside the 100–250 Hz safety-critical path (arm -> twin collision check -> arm). Dora slots in cleanly later at exactly the seams identified in section 8.

---

## 1. What Dora is, current state

Dora ("Dataflow-Oriented Robotic Architecture") models an application as a directed graph declared in YAML. Each **node** is a separate OS process (Rust, Python, C, C++, mixable); a Rust **daemon** routes messages between them; a **coordinator** manages dataflow lifecycle (single-machine `dora run` embeds both). Messages are **Apache Arrow** arrays; payloads >= 4 KB go through **zero-copy shared memory**, smaller ones over TCP (postcard encoding); cross-machine transport is Zenoh.

### Version status (as of 2026-09-01) — important

| Line | Version | Python | Notes |
|---|---|---|---|
| Stable on PyPI | `dora-rs` **0.5.0** (2026-03-25) | **>= 3.8** (abi3-py37 wheels) | Last release of the *old* codebase |
| 1.0 release candidates | **1.0.0-rc.5** (PyPI 2026-08-27; repo main) | **>= 3.11** (abi3-py311) | New codebase; hard break from 0.x |

The 1.0 line is a **ground-up consolidation/rewrite** (`docs/migration-from-0.x.md`: "1.0 is a hard break from 0.x... shares no git history"). Everything attractive below — service/action patterns, restart policies, record/replay, `dora top`, runtime params, zero-copy Python sends — is **1.0-only**. The Python ABI floor was bumped to `abi3-py311` in the RC line ("Users on Python 3.7–3.10 can stay on dora 0.5.0 during the transition", Changelog). **On our Python 3.10 box we cannot run the version of Dora worth adopting** without first moving the stack to 3.11+ (also check xArm SDK / LeRobot pins before doing that; Python 3.10 EOLs 2026-10 anyway, so an interpreter bump is coming regardless).

Maturity signals: repo is very active (pushed daily; 1.0-rc.5 tagged Aug 2026), ~3.9k stars, Apache-2.0, Linux x86_64 first-class. Caveats the project itself states: Node Hub is *unstable*, ROS2 bridge *experimental*, and the README notes the 2026 codebase is built by "agentic engineering — AI agents handle much of the code work while humans set direction and gate every merge". The RC changelog shows wire-format and on-disk schema breaks between RCs (bincode -> postcard, coordinator store `SCHEMA_VERSION` 2->3->4->5). Treat 1.0 as *promising but freshly rewritten*; re-evaluate ~1–2 stable releases after 1.0.0 final.

### Install story

```bash
# CLI (Rust binary — required to run dataflows)
cargo install dora-cli                       # or the GitHub-releases installer:
curl -fsSL https://github.com/dora-rs/dora/releases/latest/download/dora-cli-installer.sh | sh
# Python node API
pip install dora-rs                          # NOT `pip install dora` (unrelated package)
# optional: pip install dora-rs-cli          # pip-installable CLI, requires-python >= 3.11
```

`dora build --uv` can create a per-node uv venv (`.dora/python-envs/<node-id>/`) so each node gets hermetic deps — genuinely nice for keeping e.g. a torch-pinned policy node separate from an opencv camera node.

---

## 2. Core concepts with exact syntax

### Dataflow YAML (1.0, `docs/yaml-spec.md`)

```yaml
# dataflow.yml
nodes:
  - id: camera-0
    path: nodes/camera.py            # Python file, shebang-free, runs as its own process
    env: { DEVICE: /dev/video0 }
    inputs:
      tick: dora/timer/hz/30         # built-in timer, no code needed
    outputs: [image]

  - id: arm-driver
    path: nodes/xarm_driver.py
    restart_policy: on-failure       # never | on-failure | always
    max_restarts: 3
    restart_delay: 1.0               # exponential backoff, capped by max_restart_delay
    inputs:
      cmd:
        source: controller/cartesian_cmd
        queue_size: 1                # keep only the freshest command
        queue_policy: drop_oldest    # or `backpressure` (lossless, blocks at 10x)
      tick: dora/timer/millis/4      # 250 Hz
    outputs: [state]

  - id: recorder
    path: nodes/recorder.py
    inputs:
      image: camera-0/image
      state: arm-driver/state
```

Run with `dora run dataflow.yml` (single machine, embedded daemon) or `dora up` + `dora start` (detached coordinator/daemon; supports multi-machine via Zenoh).

### Python node API (`docs/python-guide.md`, `docs/api-python.md`)

```python
import pyarrow as pa
from dora import Node

node = Node()                        # identity injected via env vars by the daemon
for event in node:                   # blocking iterator; also: node.next(timeout=...),
    match event["type"]:             #   node.try_recv(), await node.recv_async()
        case "INPUT":
            if event["id"] == "cmd":
                cmd = event["value"].to_numpy()      # Arrow -> numpy, zero-copy for fixed-width
                ...
            node.send_output("state", pa.array(state_vec), metadata={"t": stamp})
        case "INPUT_CLOSED": ...
        case "STOP":
            break
```

Other 1.0 API surface worth knowing:

- **Dynamic nodes:** `Node(node_id="ui-bridge")` lets an *externally started* process (e.g. our FastAPI server) attach to a running dataflow (`path: dynamic` in YAML). This is how a web UI bridge would join without being spawned by the daemon.
- **Zero-copy send (Python >= 3.11 only):** `node.send_output_raw("frame", h*w*3)` yields a buffer you write frames into directly — removes the one copy `send_output` makes. On 0.5.0 you always pay one copy per camera frame.
- **Hot reload:** `dora start dataflow.yml --hot-reload` watches Python **operator** files (in-process operators, not standalone node processes) and reloads on change.
- **Runtime parameters:** `dora param set <node> key value` surfaces as `ParamUpdate` events in the node — a ready-made "tuning knobs" channel.
- **Timers:** `dora/timer/millis/N`, `dora/timer/hz/N` as YAML inputs.
- **CUDA:** a `dora_tensor_pool` extension provides CUDA IPC (ctypes-based) for passing GPU tensors between processes.

---

## 3. Request/reply and stateful commands (our "load profile / start episode / reset with planning")

Dora is fundamentally pub/sub. 1.0 adds **service** (request/reply), **action** (goal/feedback/result + cancel), and **streaming** patterns — implemented as *metadata conventions*, not a new transport (`docs/patterns.md`):

- Service: client stamps `request_id` (UUIDv7) into message metadata; server must echo it back. Rust/C++ get helpers (`send_service_request`, `EventStream::recv_service_response(rid, server, timeout)` with `PatternError::Timeout | ServerRestarted`).
- Action: `goal_id` + terminal `goal_status` in {`succeeded`,`aborted`,`canceled`}; cancel is a message on a `cancel` output. This maps well to "reset with planning" (long-running, cancelable, with feedback).

```python
# Python service client — NOTE: Python has no recv_service_response helper;
# you correlate manually in your event loop (docs/patterns.md §7)
import uuid
params = {"request_id": str(uuid.uuid4())}
node.send_output("request", payload, metadata={"parameters": params})
# ...then loop over events until a response with matching request_id arrives,
# implementing your own timeout and NodeRestarted handling.
```

Assessment: workable but **DIY in Python** (helpers are Rust/C++ only as of rc.5), and the docs themselves warn that when a server node crashes mid-request, in-flight correlations are orphaned — clients must watch for `NodeRestarted` and retry. In our baseline architecture the same operations are just… method calls. Request/reply is the weakest part of the Dora fit for us; it is also exactly what our mode-switching runtime (idle -> teleop -> record -> DAgger) does constantly.

---

## 4. Fault tolerance and observability (1.0)

Genuinely strong, and the best argument *for* Dora:

- Per-node `restart_policy` / `max_restarts` / exponential backoff / `restart_window`; downstream nodes get a `NodeRestarted` event; `input_timeout` acts as a circuit breaker that closes a stale input (`InputClosed`) so consumers can degrade gracefully (`docs/fault-tolerance.md`).
- Debug tooling (`docs/debugging.md`): `dora doctor`, `dora top` (TUI of nodes/CPU/mem), `dora logs <node>`, `dora topic echo|hz|pub`, `dora graph` (visualize), `dora node restart|replace|connect|disconnect` (live topology edits), `dora trace` (OpenTelemetry, no external infra needed).
- **Record/replay:** `dora record` captures topics to `.drec`; `dora replay --speed 2` re-runs them, including *selective* replay ("replace the sensor node, keep camera live"). For offline debugging of a robot pipeline this is a feature we would never build ourselves.

---

## 5. Ecosystem: what exists that we'd otherwise write

Node Hub moved to **github.com/dora-rs/dora-hub** (`hub: dora-yolo@^0.5` in YAML resolves against a git-based index; feature marked **unstable**, and hub nodes largely target the 0.x line).

| Need (ours) | Dora ecosystem | Verdict |
|---|---|---|
| USB/V4L2 cameras | `opencv-video-capture` (supported), kornia V4L/GStreamer nodes (external repo) | Reusable, but it's ~50 lines of cv2 we'd write anyway |
| RealSense | `dora-pyrealsense` (Linux: "works") | Reusable |
| Keyboard teleop | `dora-keyboard` (char listener) | Too primitive for our teleop (we need key-down/up state for velocity control); we'd write our own |
| **xArm7 driver** | **Nothing.** No xArm node in dora-rs org (only a vendored LeRobot `xarm_pkl` dataset converter in a GSoC repo) | We write it either way |
| LeRobot episodes | `dora-rs/dora-lerobot`: **dormant — last commit 2024-09, last push 2025-01**; recorder marked experimental; predates current LeRobotDataset format | We write it either way |
| MuJoCo sim | `dora-mujoco`, `mujoco-client` nodes in dora-hub (maturity unclear) | Possibly a starting point; our digital-twin collision gating is custom regardless |
| Policy inference | `dora-rdt-1b` (RDT-1B VLA), YOLO/SAM2/VLM nodes | Wrong policies; ours is custom |
| Visualization | `dora-rerun` (Rerun bridge, supported) | Nice-to-have; our UI is a web app either way |

**Bottom line:** the four hardest components of our stack (xArm driver, digital-twin collision gate, LeRobot-format recorder, DAgger orchestration) have no reusable Dora node. Dora would give us camera capture, plumbing, and ops tooling — not domain logic.

---

## 6. Latency / throughput vs. our requirements

Dora's own benchmark (`examples/benchmark/`, Rust nodes, single machine; representative numbers from its README):

| Payload | Latency (avg) | Throughput |
|---|---|---|
| 0–8 B (TCP + postcard, < 4 KB threshold) | ~0.86 ms (p99 ~1.5 ms) | ~125 k msg/s |
| 4 KB (shared memory kicks in) | ~0.41 ms | ~95 k msg/s |
| 4 MB (shared memory, zero-copy) | ~0.53 ms | ~2.1 k msg/s (~8.4 GB/s) |

Claimed 10–17x lower latency than ROS2 rclpy; "flat latency 4 KB -> 4 MB". Python nodes add interpreter overhead on top.

**Control loop (100–250 Hz, small messages):** period is 4–10 ms. Each inter-node hop costs ~0.4–0.9 ms (small command messages ironically take the *slower* TCP path; padding messages past 4 KB to hit shared memory is a documented trick). A teleop path `keyboard -> controller -> twin-gate -> arm-driver` is 3 hops ≈ 1.5–2.5 ms plus Python scheduling jitter — *feasible at 100 Hz, tight at 250 Hz*, vs. essentially 0 (µs-scale, and jitter-free ordering) for function calls inside one process. Critically, our collision gate sits *inside* this path, so option B puts IPC in the safety loop.

**Cameras (2–5 x 640x480 RGB @ 30 fps):** 640x480x3 = 0.92 MB/frame; 5 streams = ~138 MB/s. Shared-memory transport handles this with large headroom (~8 GB/s measured at 4 MB payloads), and per-camera processes sidestep the GIL — this is the one place Dora (or any multiprocess design) beats naive threads. Note: full zero-copy from Python (`send_output_raw`) needs Python 3.11; on 0.5.0 each frame is copied once (still fine: ~138 MB/s memcpy is trivial).

**Threads baseline for comparison:** `cv2.VideoCapture.read()`, turbojpeg encode, numpy ops, and xArm SDK socket I/O all release the GIL, so a single process with 3–6 threads sustains this workload on a modern CPU; the risk is a Python-heavy recorder or policy pre/post-processing hogging the GIL and adding jitter to the control thread — mitigate by keeping the control thread's Python work minimal and measuring loop jitter from day one.

---

## 7. Pain points to expect with Dora (option B)

1. **Python version wall** (3.11+ for 1.0) — blocker today on our 3.10 machine.
2. **RC-era churn:** breaking wire/schema changes between rc releases; hub "unstable"; a freshly rewritten codebase whose ecosystem nodes mostly target 0.x.
3. **Debugging across processes:** good CLI tooling (section 4), but no single pdb/debugpy session, stack traces scattered across node logs, and IDE-attach means picking the right process among 8+.
4. **Request/reply is convention-based and Python has no correlation helpers**; server crash orphans in-flight requests (documented; daemon-side synthesis is a future item).
5. **State fragmentation:** "current mode", "active profile", "episode index" must be replicated via messages/params instead of living in one object; every mode transition becomes a distributed-consistency exercise.
6. **Per-node process overhead:** each Python node re-imports its stack (a torch-importing policy node takes seconds to start; daemon restart-policies mask but don't remove this).
7. **Deployment/dev-loop friction:** `dora build` / `dora run` lifecycle, YAML + lockfiles, a Rust CLI in the toolchain, per-node venvs to keep straight; `--hot-reload` covers operators, not standalone node processes.

---

## 8. Comparison for our stack

### (A) Single Python process + threads (planned baseline)

- **Latency:** function-call; collision gate inline in the control loop. Deterministic ordering (read state -> gate -> command) is trivial.
- **State/request-reply:** plain method calls; FastAPI handlers call the runtime directly.
- **Risks:** GIL jitter (measure!, mitigations in §6); one crash takes everything down (an SDK segfault in the xArm C bindings kills the UI too); cameras+recorder+policy contend for one interpreter.
- **Cost:** lowest. Everything is importable, unit-testable, debuggable in one pdb.

### (B) Full Dora dataflow (node per camera/arm/policy/recorder/UI-bridge)

- **Wins:** process isolation + auto-restart per node; per-node hermetic venvs; cameras parallel by construction; `dora record/replay` for free; `dora top`/`topic hz` ops tooling; scales to multi-machine later.
- **Losses:** ~0.5–1 ms/hop in the 100–250 Hz loop with the collision gate behind IPC; DIY request/reply in Python for all mode/profile/episode commands; state fragmentation; Python 3.11 wall; RC churn; none of our domain nodes exist. Roughly: all our v1 code, plus middleware integration work, minus one camera process pool.

### (C) Hybrid: single-process core + IPC only for cameras and training worker

- Core control loop, twin gate, recorder, FastAPI stay in-process (A's semantics where they matter).
- Cameras: per-camera child processes shipping frames via `multiprocessing.shared_memory` ring buffers (or ZMQ `PUB` with `zmq.SNDHWM=1` + shared memory for pixels) — ~150 lines, no framework.
- DAgger trainer: separate process anyway (it owns GPU #2); a ZMQ `PAIR/DEALER` socket or even a filesystem episode-handoff + checkpoint-reload protocol suffices — training is not latency-sensitive.
- Using *Dora* just for this slice buys little over plain ZMQ/shm while importing the whole coordinator/daemon/YAML apparatus.

### Verdict table

| Criterion | A: threads | B: Dora | C: hybrid |
|---|---|---|---|
| 100–250 Hz loop latency/jitter | best | workable at 100 Hz, tight at 250 | best |
| Collision gate in-path | in-process | cross-process | in-process |
| Request/reply, mode state | trivial | weakest point | trivial |
| Camera scaling (2–5 streams) | OK (GIL risk) | best | best |
| Crash isolation | worst | best | good (cameras/trainer isolated) |
| Reuse of existing nodes | n/a | low (see §5) | n/a |
| Python 3.10 today | yes | no (1.0) | yes |
| Eng. cost for v1 | lowest | highest | +~1 week over A |
| Debuggability | one pdb | CLI tooling, multi-process | mostly one pdb |

---

## 9. Recommendation

**v1: option A**, with option C's camera/trainer split as the pre-planned escape hatch (apply it the moment profiling shows GIL-induced control-loop jitter > ~1 ms p99, or when adding camera #3+). **Do not adopt Dora for v1**: it is mid-1.0-RC, requires Python 3.11, supplies none of our domain nodes, and its weakest pattern (request/reply, distributed state) is our most common one, while its strongest wins (multi-machine, crash isolation, record/replay) are not v1 requirements.

**Keep the door open — design rules that make a later Dora (or ZMQ) migration mechanical rather than a redesign:**

1. **Transport-agnostic core interfaces.** `ArmController`, `CameraSource`, `Sim`, `Recorder`, `Policy` as Python protocols/ABCs whose methods exchange **plain numpy arrays / dataclasses of primitives** (Arrow-representable) — never framework objects, sockets, or callbacks that assume shared memory space.
2. **One message schema module.** Define `CartesianCmd`, `ArmState`, `Frame`, `EpisodeEvent` etc. once (dataclass + `to_arrow()/from_arrow()` or plain dict-of-ndarray). Dora nodes, ZMQ sockets, and in-process queues all speak it. Dora is Arrow-native, so this is the exact seam it plugs into.
3. **Hub-and-spoke inside the process.** Have threads communicate through explicit typed queues owned by a small runtime object — not by calling each other directly. A Dora node later is then a ~50-line wrapper: `for event in node: queue.put(from_arrow(event))`.
4. **Command bus with correlation IDs from day one.** Route "load profile / start episode / reset with planning" through a single `submit(cmd) -> Future[Result]` entry point with a request-id, even in-process. That is literally Dora's service pattern, and it also cleanly serves FastAPI/WebSocket handlers.
5. **Trainer behind a process boundary already in v1** (it needs its own GPU + torch lifecycle). Its channel (ZMQ or file handoff) is the first place Dora could be dropped in with zero redesign.

**Where Dora slots in later without redesign** (in rough order of payoff, once on Python 3.11 and dora 1.0 is a few stable releases old): (a) camera nodes + `dora record/replay` for debugging data pipelines; (b) trainer/policy nodes for GPU/venv isolation (`dora_tensor_pool` CUDA IPC); (c) multi-arm scale-out across machines via Zenoh; (d) full dataflow-ization of the control loop last, and only if 100 Hz-class loops with one extra hop prove acceptable on our hardware (benchmark first with `examples/benchmark`-style measurement).
