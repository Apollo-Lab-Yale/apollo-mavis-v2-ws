# 14 — External interface over Dora (dora-rs 1.0) (binding once approved)

Status: **v1.2 (2026-09-08, evening, late) — phase-14 is the Online DAgger SHELL of
`15-online-dagger.md` v2.0 (operator decision 2026-09-08 evening: the runtime knows no DAgger
algorithm; PRO-DAgger is a reference implementation in the policy repo). Sections touched,
v1.1 text superseded in-body and kept: §4.1 / §4.2 `events` (`gate` now actually published,
`episode_saved.online_dagger`, `episode_discarded`, `train_now`; `iteration_complete` /
`pro_dagger_phase` REMOVED from `EVENT_KINDS` — never shipped), §4.2 `SessionAnnounce.
online_dagger`, §5 the `policy_trainer_status` row (the 10-field generic
`TrainerStatusAnnounce`), §6.1 the capability `"online_dagger"` + the 409s as shipped, §6.2
the generic trainer role → 15-online-dagger §3 / §9, §11.3, §13 `ExternalStatus.capabilities`
/ `.trainer_status` + the deltas, §16.5 note; late-evening spelling fix in §4.2 — the
`episode_discarded` hook is `DaggerRecorderThread.on_episode_discarded`.** v1.1 (2026-09-08, evening) — phase-12 MERGED
into the main working trees of the five sub-repos on top of phase-13 (§16.4: the two test
adaptations and the known flakes) and extended by phase-14 (then spelled PRO-DAgger; additive,
`mavis_schema` stays 1): §1 import confinement widened to the recorder. Superseded (2026-09-08
evening) — the v1.1 phase-14 list (`SessionAnnounce.pro_dagger`, `iteration_complete` /
`pro_dagger_phase`, the `pro_dagger` capability and 409s) and the late docs-pass note on the
`episode_discarded` scope: the scope rule itself stands (Online DAgger sessions only, §4.2),
the spelling is now `online_dagger`.
v1.0 (2026-09-08) — IMPLEMENTED in phase-12 (worktree branches `phase-12` of
core / hardware / sim / runtime / ui + the new `apollo-mavis-v2-policy-node` repo; §16 is the
implementation record with every deviation from the v0.3 contract and the acceptance numbers
measured on the lab host). v0.3 (2026-09-07) added the user's requirement that consumers on
OTHER MACHINES of the lab LAN can subscribe (§0 changelog, §2.2, §2.3, §2.6, §9, §12),
verified against a two-daemon dora 1.0.1 experiment on the lab host (artifacts
`/tmp/dora-lan-exp/`, `results/summary.json`).
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

**Changelog v0.2 → v0.3 (2026-09-07, user requirement + experiment):**

- **Publishing is process-lifetime, unconditional, no mode.** Restated because
  the wording "fixed viewpoint" was read as a switchable "tripod mode": there is
  none. Whenever the runtime process runs, every stream of §4 is published.
- **LAN subscribers are v1, not v2.** A consumer on another machine of the
  lab network (another repo's program, another robot's controller) subscribes
  through dora's own multi-daemon mechanism: the runtime's private control plane
  binds a configured LAN address (`dora.bind_host`, never a control-box NIC),
  the remote host runs its own `dora daemon --machine-id <id>` against that
  coordinator, and the rendered dataflow deploys per-machine placeholder nodes
  (`deploy: {machine: <id>}`) that the remote attaches to as dynamic nodes
  (§9). Verified 2026-09-07 with two daemons on one host over the LAN
  address and the TCP path: 921,600 B frames @30 Hz p50 4.7 ms / p99 6.8 ms,
  0 gaps; 28 B state @100 Hz p99 1.0 ms.
- Coordinator auth (`--auth`) is ON whenever the control plane is not
  loopback-only; the token is never served over REST (§9).
- Every dora node the runtime or its examples create (including
  `Node("mavis_runtime")`) sets `DORA_ZENOH_MULTICAST=off` and
  `DORA_ZENOH_LISTEN=tcp/127.0.0.1:0` — without them a dynamic node opens
  multicast and UDP sockets on every NIC including the control-box NICs
  (measured; §9).

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
**Amended 2026-09-08 (phase-13 merge; §16.4).** `dora` stays confined to
`dora_bridge/`. `pyarrow` has THREE sanctioned import sites since phase-13:
`dora_bridge/` (the bus codec), `dagger/` (the trainer spool parquet) and
`recorder/` (`episode_recorder.py` writes `episodes/<id>/frames.parquet`,
`export_lerobot.py` stacks them into the LeRobot v3 export — 10-frames §11, 04-runtime
§10); the runtime's `pyproject.toml` `TID251` message and
`tests/dora_bridge/test_import_confinement.py` (`PYARROW_ALSO_OK = {dagger, recorder}`)
both say so. Every import is still lazy (the import-time subprocess check is unchanged).

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
3. setsid  dora coordinator --interface <bind_host> --port <coordinator_port> --store memory
                            [--auth]                                             (cwd = var_dir)
   setsid  dora daemon --machine-id <machine_id> --coordinator-addr <bind_host>
                       --coordinator-port <coordinator_port>
                       --local-listen-port <daemon_port>
                       --zenoh-no-multicast --zenoh-listen <bind_host>:<zenoh_port>      (cwd = var_dir)
   wait for `dora status --coordinator-addr <bind_host> --coordinator-port <P>` ≤ 5 s
   (with `--interface <LAN IP>` the coordinator does NOT listen on loopback: every
   CLI call the runtime makes passes --coordinator-addr <bind_host>; v0.3)
4. dora start <yaml> --name mavis_v2 --detach --coordinator-addr <bind_host> --coordinator-port <P>
   → dataflow uuid7 (cwd = var_dir; out/ lands there). The rendered YAML deploys the
   local nodes on <machine_id> and, for every configured remote machine whose daemon
   is REGISTERED at this moment, its placeholders on that machine (§2.3, §9)
5. os.environ: DORA_ZENOH_CONNECT=tcp/<bind_host>:<zenoh_port>, DORA_ZENOH_MULTICAST=off,
   DORA_ZENOH_LISTEN=tcp/127.0.0.1:0 (v0.3 — a dynamic node otherwise opens multicast +
   per-NIC UDP + a wildcard TCP listener); Node("mavis_runtime", daemon_port=<daemon_port>)
   on the bus thread → state `attached`
6. every `dora.rescan_s`: re-read the set of registered daemons (`machines[].registered`);
   **v1.0 (§16.1): placeholders for a remote machine are rendered only on its explicit
   `POST /api/dora/machines/{id}/join`** (re-render, `dora stop mavis_v2 --grace-duration 2s`,
   `dora start`, wait for dora's start barrier = the remote consumer's attach, re-attach;
   `ExternalStatus.dataflow_restarts += 1`; attached consumers see STOP / INPUT_CLOSED and
   re-attach — the rule §6.2 already imposes on the policy node); a registered daemon that
   vanishes drops its placeholders on the next rescan
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

Since v0.3 every node above carries `deploy: {machine: <dora.machine_id>}` (the
key `dora validate --strict-types` accepts in 1.0.1; `_unstable_deploy` and a
top-level `machine:` are rejected), and for every configured remote machine
(`dora.machines`, §12) whose daemon is registered when the YAML is rendered the
renderer adds `viewer_<machine_id>` / `observer_<machine_id>` placeholders (ids
stay `[a-zA-Z0-9_]`) with `deploy: {machine: <machine_id>}` and the same inputs
as the local `viewer` / `observer`. A machine that is not registered gets no
node — `dora start` refuses a dataflow that names an absent machine (`no
matching daemon for machine id …`, verified) — and is picked up by the rescan
(§2.2 step 6).

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
 "bind_host": "192.168.0.88", "machine_id": "lab", "auth": true,
 "coordinator_addr": "192.168.0.88", "coordinator_port": 6113, "daemon_port": 53391,
 "zenoh_connect": "tcp/192.168.0.88:7447", "dataflow_name": "mavis_v2",
 "dataflow_id": "0199…", "node_id": "mavis_runtime",
 "placeholders": ["policy", "viewer", "observer"],
 "machines": [{"id": "gpubox", "registered": true,
               "placeholders": ["viewer_gpubox", "observer_gpubox"]}],
 "dataflow_restarts": 1,
 "dataflow_yaml": "/home/…/var/dora/mavis_v2.dora.yml", "mavis_schema": 1}
```

A **same-host** client does `export DORA_ZENOH_CONNECT=tcp/<bind_host>:7447
DORA_ZENOH_MULTICAST=off DORA_ZENOH_LISTEN=tcp/127.0.0.1:0` and
`Node("policy", daemon_port=53391)` (no coordinator env, no token — a dynamic
node only talks to its daemon's loopback port). A **remote** client follows the
§9 recipe (own daemon with `--machine-id`, then `Node("viewer_<id>")`). The
auth token is deliberately NOT in this response (§9). The same facts are printed
by `python -m apollo_mavis_v2_runtime.dora_bridge.nodes.env` for shell use;
`daemon_port` is only meaningful on the lab host (loopback).

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
    online_dagger: OnlineDaggerAnnounce | None = None   # phase-14 (additive, appended last):
                                             #   non-null iff spec.online_dagger —
                                             #   {session_name, session_dir, rollouts_dir}
                                             #   (15-online-dagger §6). Superseded (2026-09-08
                                             #   evening): v1.1's six-field pro_dagger:
                                             #   ProDaggerAnnounce (ref_grad_dir, offline_dataset,
                                             #   offline_dataset_dir) — the shell knows no anchor
```

**`events`** — `EventEnvelope{kind, t_mono, wallclock_ns, session_id, payload}`
with `kind` ∈ `collision` (`CollisionEvent`), `gate` (`GateEvent`),
`episode_saved` (`{episode_index, summary: EpisodeSummary, dataset_root,
spool_path, run_id}` — what an external trainer needs), `episode_discarded`,
`policy_anomaly` (`PolicyAnomalyEvent`), `policy_swap` (`{version,
checkpoint_path}`; in-process policies), `policy_version_changed`
(external policies, §6.5), `reset_watermark`, `session_error`. Unknown kinds
are additive.

**Events added / made real by phase-14 (2026-09-08 evening, additive; 15-online-dagger §3 /
§6 / §12; `EVENT_KINDS` is append-only — `collision, gate, episode_saved, episode_discarded,
policy_anomaly, policy_swap, policy_version_changed, reset_watermark, session_error,
train_now` (10), the goldens pin the order):**
- `gate` — declared since v0.3, **now actually published** (`{arm_id, mode, seq, source:
  keyboard | action | auto_advance | episode_reset, episode_id}`): every `TakeoverGate`
  transition — Space, the explicit `takeover` / `handback` actions (`source: "action"`,
  additive spelling), auto-advance, the episode-boundary reset (whose `episode_id` names
  the episode that just CLOSED). Published for EVERY policy session with the bridge on: an
  Online DAgger session through its coordinator's `SerialWorker` (ordered against
  `episode_saved` / `episode_discarded`), a plain external / checkpoint dagger or inference
  session through `SnapshotPublisher.enqueue_event()` (a 256-deep deque drained on the
  `dora-publisher` thread; `DoraWiring.publish_gate_events`) — never a bus call on the tick.
- `episode_saved` — the `summary` carries the capture-time `episode_id` and the
  `n_expert_frames` / `n_novice_frames` actor counts (the recorder does
  `dataclasses.replace(summary, episode_index=, episode_id=)` before publishing);
  in an Online DAgger session the payload gains `online_dagger: {episode_id,
  rollouts_saved, actor_counts: {novice, expert}, policy_version, spool_path}`
  (`rollouts_saved` includes this rollout; `spool_path` — also the top-level key — is
  `null` when the trainer spool could not be written, the rollout still counts).
  Superseded (2026-09-08 evening) — v1.1's `pro_dagger: {iteration, rollout_index,
  rollouts_per_iteration, …}` block.
- `episode_discarded` — declared since v0.3, **actually published in Online DAgger
  sessions ONLY** (the scope rule of the late docs pass stands; the code is the reality).
  The only publish site is `OnlineDaggerCoordinator.on_episode_discarded`
  (`dagger/online_dagger.py`), reached through the recorder-thread hook
  `SessionManager._online_dagger_discard_hook`, assigned only inside the Online DAgger
  branch of `_build_external_policy_stack`; the plain external-DAgger branch (and the
  in-process DAgger builder) leave `DaggerRecorderThread.on_episode_discarded` at its `None`
  default, and the collect builder's plain `RecorderThread` has no such hook at all, so a
  discard there is visible on `telemetry.episode` only (open item, 15-online-dagger §12.3
  item 3; spelling corrected 2026-09-08 late evening — the hook is defined on the dagger
  subclass `DaggerRecorderThread` in `dagger/recorder.py`, not on the base `RecorderThread`
  in `recorder/thread.py`). Inside an Online DAgger session it fires on every discard: `{episode_index,
  episode_id, reason}` with `reason` `""` (operator `episode_discard`), `"empty episode
  discarded"` (every frame filtered), `"session teardown"` (a rollout still open at
  teardown) or `"save failed twice - recording degraded (buffer kept)"` (the degraded-save
  path; the only discard whose temp directory is KEPT, 04-runtime §15). Nothing is
  persisted for a discarded rollout; a trainer that watched it live drops what it landed.
  The envelope's `session_id` is pinned at submit time (never `""` for a teardown discard).
- `train_now` (new) — the Cockpit's **Train now** (`ActionMsg train_now`; no key):
  `{rollouts_saved, requested_by: "operator"}`; the trainer decides whether to honour it
  (the fakes ignore it while no rollout is kept).
- Superseded (2026-09-08 evening) — v1.1's `iteration_complete` (`{iteration, session_name,
  episode_ids, spool_paths, rollouts_dir, ref_grad_dir, replay_buffer, hparams, …}`) and
  `pro_dagger_phase` (`{iteration, rollout_index, phase, detail}`): REMOVED from
  `EventKind`, never shipped. The shell publishes no iteration- or algorithm-level event;
  the trainer counts rollouts and decides when to train; the runtime reports what the
  trainer says (`telemetry.dagger.online_dagger`).

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
| `policy_trainer_status` (additive, phase-14, 2026-09-08; row reworded 2026-09-08 evening) | `policy/trainer_status` | `Utf8[1]` JSON `TrainerStatusAnnounce` — the 10-field GENERIC contract (15-online-dagger §6): `mavis_schema`, `trainer_id`, `node_version`, `state: idle \| preparing \| training \| ready \| error`, `session_id` echo (`null` = alive only), `policy_version` (acting version after the last swap), `progress` (0..1), `metrics: dict[str, float]` (free-form finite scalars, e.g. `loss`, `proj_rate`), `detail`, `uptime_s`; every float `allow_inf_nan=False`. Superseded (2026-09-08 evening): v1.1's algorithm fields (`iteration`, `ref_grad{…}`, epoch / step / `n_proj` / pool sizes / `scale_check`) — a trainer puts whatever it wants into `metrics` | — (the common inbound keys; same `seq` counter as the node's other outputs) | 8 |
| `tick` | `dora/timer/hz/10` | — | — | bridge watchdog |
| `probe_heartbeat` | `probe/heartbeat` | `Int64[1]` | — | dataflow liveness |

**Reserved ids (declared in the compatibility ledger, not implemented in v1):**
`weights_reload` / `weights_ack` (runtime-driven hot-swap of an external
policy via the dora service pattern, §11.3), `cmd_request` / `cmd_response`
(generic `CommandBus` exposure — session / episode ops stay REST + WS in v1).
Reserving the names keeps a later addition additive.

The `policy` placeholder's declared outputs are `[action, spec, status, trainer_status]`
(`POLICY_OUTPUTS`, append-only) since phase-14; the rendered dataflow and
`dataflows/mavis_v2.example.dora.yml` carry the new input as `policy_trainer_status:
{source: policy/trainer_status, queue_size: 8}`. A `policy_trainer_status` is cached by
the `ExternalPolicyHub` (newest wins, aged against `spec_stale_s`), surfaced as
`ExternalStatus.trainer_status` and handed to the running Online DAgger session's
coordinator (`ExternalPolicyHub.attach_trainer_sink` — the cached status is replayed on
attach; the coordinator applies its own session-id rule, 15-online-dagger §3); a
malformed one is dropped and counted like any other input.

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

**Online DAgger (phase-14, 2026-09-08 evening; 15-online-dagger §3 / §6 / §7 / §12).** A
`SessionSpec` with `mode: dagger`, `policy_source: external` and a non-null
`online_dagger: OnlineDaggerConfig{session_name, resume, pause_while_training,
wait_for_trainer_ready}` block is an Online DAgger session. `PolicySpecAnnounce.
capabilities: list[str] = []` (additive, appended last) is how a node declares the
trainer role — a trainer-capable node lists **`"online_dagger"`**;
`SessionAnnounce.online_dagger: OnlineDaggerAnnounce | None` (additive, appended last;
`{session_name, session_dir, rollouts_dir}`) is how the runtime tells it where the
session lives. `POST /api/session` adds, AFTER `_check_dataset_spec` and the hardware
refusal matrix (D7: `dagger` on hardware is still 409 there) and BEFORE the
return-to-start check (`SessionManager._check_online_dagger`, before any side effect),
the 409s `"Online DAgger session '<s>' already exists - resume it or pick another
name"`, `"Online DAgger session '<s>' not found"`, `"Online DAgger session '<s>':
session.json is unreadable - fix or remove it"`, `"dataset 'online_dagger/<s>' is being
exported - retry in a moment"` (or the legacy-tree 409), then the shared `"no external
policy attached (…)"` of step 1 and, with a fresh spec that lacks the capability, `"no
Online DAgger trainer attached (the policy node does not report the online_dagger
capability)"`. There is NO offline-dataset check (the trainer configures its own anchor).
Superseded (2026-09-08 evening) — v1.1's `pro_dagger` block, the `"pro_dagger"`
capability and the three `"offline dataset …"` 409s. `ExternalStatus.capabilities` /
`.trainer_status` (§13) let the launcher show this before the POST.

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
    capabilities: list[str] = []        # phase-14 (additive, appended last): ["online_dagger"]
                                        #   for a trainer-capable node (15-online-dagger §6;
                                        #   v1.1 spelled "pro_dagger", superseded 2026-09-08 evening)
```

**Trainer role (phase-14, 2026-09-08; generic since the same evening — 15-online-dagger §3 /
§9 / §10 are the contract).** A node that lists `"online_dagger"` also consumes `session`
announces carrying an `online_dagger` block and the `events` stream (`gate`,
`episode_saved` + `online_dagger` block, `episode_discarded`, `train_now`): on the
`running` announce it prepares itself (`trainer_status` `preparing` → `ready`, echoing the
served `session_id`; the runtime admits rollouts only after `ready` when
`wait_for_trainer_ready`), it counts kept rollouts ITSELF and decides when to train
(`train_if_due`), reports `training` (+ `progress`, `metrics`; the runtime refuses new
rollouts meanwhile when `pause_while_training`), swaps the weights into the acting policy,
bumps `spec.version` — the node publishes the new `spec` BEFORE the `ready` status that
carries the swapped `policy_version`, so the runtime's acting version never lags — and
heartbeats `trainer_status` at 1 Hz + on change; at session end one final `idle` with
`session_id: null`. WHICH algorithm it runs is its own business (PRO-DAgger is the shipped
reference implementation, `mavis_policy_node.pro_dagger`, on top of the generic
`mavis_policy_node.online_dagger` loop and its `OnlineDaggerTrainer` hooks). For a policy
repo: the policy-node README's "Online DAgger trainer role" section plus the skill the
runtime serves at `GET /api/online_dagger/skill[.tgz]` (`mavis-policy-node --online-dagger
fake|pkg.mod:make_trainer [--trainer-config <yaml|json>]`; `--selftest online-dagger`).
Superseded (2026-09-08 evening) — v1.1: "prepares the reference gradient from
`offline_dataset_dir` into `ref_grad_dir` … on `events.iteration_complete` it trains the
listed episodes … `GET /api/pro_dagger/skill[.tgz]`".

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

Binding for v1 (**lab host + LAN subscribers; v0.3, user requirement
2026-09-07**), verified with dora 1.0.1 on the lab host (`/tmp/dora-lan-exp/`):

- **Bind address.** `dora.bind_host` selects the ONE interface the private
  control plane listens on: `127.0.0.1` in the tracked config (same-host
  only, the v0.2 behaviour); in the rendered lab config the lab Wi-Fi LAN —
  SSID **APOLLO Lab**, `wlp38s0`, DHCP (192.168.0.88/24 on 2026-09-07; the lab
  was on YaleSecure / 10.66.241.33 earlier the same week) — or the Tailscale
  address. Because the Wi-Fi address is DHCP-assigned, `bind_host` also accepts
  an INTERFACE NAME (`wlp38s0`, `tailscale0`) that the bridge resolves to its
  current IPv4 at start (and re-resolves before a dataflow restart); the lab
  render uses the interface name. `0.0.0.0` is refused, and so is any address
  inside a control-box subnet (the HOST's own addresses on the two arm links,
  192.168.1.11 and 192.168.2.12 — `workcells.hardware` arm subnets) — the
  bridge goes `disabled` with a detail instead of binding the arm NICs.
  Multicast stays off everywhere. To be explicit about what this rule is NOT:
  the runtime keeps talking to the control boxes (192.168.1.201 / 192.168.2.219)
  over those two NICs exactly as before — that is the xArm SDK path and it is
  untouched. The rule only says where **dora listens**: on the Wi-Fi LAN where
  the consumers are, not on the point-to-point arm links, where nothing needs
  dora and where zenoh's default per-NIC sockets would otherwise appear
  (measured 2026-09-07). The two paths use different interfaces and do not
  conflict; binding one interface is what keeps them apart.
- **Control plane (runtime-owned):** `dora coordinator --interface <bind_host>
  --port <P> --store memory [--auth]` and `dora daemon --machine-id <machine_id>
  --coordinator-addr <bind_host> --coordinator-port <P> --local-listen-port <Q>
  --zenoh-no-multicast --zenoh-listen <bind_host>:<Z>` (§2.2). Facts measured:
  with `--interface <LAN IP>` the coordinator no longer listens on loopback, so
  every runtime CLI call carries `--coordinator-addr`; the daemon's dynamic-node
  port `<Q>` ALWAYS binds 127.0.0.1 (so `Node(...)` attaches are same-host by
  construction); zenoh advertises exactly the `--zenoh-listen` address and
  remote daemons dial it. Default ports 6113 / 53391 / 7447 (never the
  machine-global 6013 / 53291).
- **Own node hygiene.** Before `Node("mavis_runtime")` the runtime sets
  `DORA_ZENOH_CONNECT=tcp/<bind_host>:<Z>`, `DORA_ZENOH_MULTICAST=off`,
  `DORA_ZENOH_LISTEN=tcp/127.0.0.1:0`. Measured without the last two: the
  dynamic node joined multicast `224.0.0.224:7446`, opened UDP sockets on every
  NIC **including 192.168.1.11 and 192.168.2.12**, and a wildcard TCP listener;
  with them it has one loopback listener and no UDP. The same three variables
  are set by every example node, by the policy-node package and are part of
  the remote recipe below. (These are the variables the daemon itself injects
  into spawned nodes.)
- **Remote subscribers = dora multi-daemon.** The remote host runs the SAME
  dora version and its own daemon against the runtime's coordinator:
  `export DORA_COORDINATOR_ADDR=<bind_host> DORA_COORDINATOR_PORT=<P>
  [DORA_AUTH_TOKEN=<token>]`; `dora daemon --machine-id <remote_id>
  --coordinator-addr <bind_host> --coordinator-port <P> --local-listen-port
  <Q2> --zenoh-no-multicast --zenoh-listen <remote_lan_ip>:<Z2>`
  (`--zenoh-connect tcp/<bind_host>:<Z>` is optional — the coordinator hands
  daemons each other's endpoints); then a process on that host attaches with
  `export DORA_ZENOH_CONNECT=tcp/<remote_lan_ip>:<Z2> DORA_ZENOH_MULTICAST=off
  DORA_ZENOH_LISTEN=tcp/127.0.0.1:0` and `Node("viewer_<remote_id>",
  daemon_port=<Q2>)` (no token, no coordinator env — verified). `<remote_id>`
  must be one of `dora.machines` (§12) and its daemon must be registered when
  the dataflow is (re)started: `dora start` refuses a YAML naming an absent
  machine, `dora node add` cannot target a remote machine (it lands on the
  local daemon — verified), and a placeholder never migrates to a daemon that
  registers later. Hence the rescan / restart in §2.2 step 6 and the explicit
  `POST /api/dora/machines/{id}/join` trigger for a remote operator who has
  just started their daemon. When a remote daemon dies the dataflow keeps
  running for everyone else; its viewer gets `ERROR … Receiver timed out`.
  Firewall: remote → lab TCP `<P>` and `<Z>`; lab → remote TCP `<Z2>` (every
  daemon must be dialable by every other daemon).
- **Measured cross-daemon cost** (two daemons on the lab host, LAN address,
  SHM disabled by a zenoh overlay = the real TCP path): 921,600 B rgb8 @30 Hz
  p50 4.7 ms / p90 5.7 / p99 6.8 / max 23 ms, 0 gaps; 28 B float32 @100 Hz
  p50 0.42 / p99 0.97 ms; daemons ≈ 10–11 % of a core each. A real second
  host adds link time (two cameras ≈ 250 Mbit/s on gigabit, ~9 ms per frame
  pair). With SHM (same host) the image path is p50 3.9 / p99 5.2 ms.
- **Authentication.** `dora.auth` defaults to true whenever `bind_host` is not
  loopback. The coordinator writes a 64-character token to `<var_dir>/.dora-token`
  (its cwd) and `~/.config/dora/.dora-token`; daemons / CLI without it get
  `401 Unauthorized` (verified), same-user local clients read the home copy
  automatically. **The token is never served by `GET /api/dora`**; it is read
  from `<var_dir>/.dora-token` by the lab operator (`python -m
  apollo_mavis_v2_runtime.dora_bridge.nodes.env` prints the export line on the
  lab host) and handed to remote operators out of band (`DORA_AUTH_TOKEN`).
  Limits of 1.0.1: auth covers ONLY the coordinator WebSocket (daemon
  registration, CLI). The zenoh data plane `<Z>` and the daemon node ports have
  no authentication and no TLS: any host that can reach `<Z>` can subscribe to
  every stream with a raw zenoh client (verified: `dora/default/<uuid>/output/…`
  keys, Arrow IPC payloads) and can publish onto any key — the runtime accepts
  `policy_action` only inside a session with `policy_source: external` and a
  matching `session_id` / `epoch` (§3.2), which bounds what an injected message
  can do, but the observation streams are readable by anyone on the reachable
  network. Keep `bind_host` on the trusted lab LAN or Tailscale and firewall
  `<Z>` to the known consumer hosts; zenoh TLS / ACL via
  `--zenoh-config-overlay` is a v2 item.
- **Verification recipe (acceptance tests):** `ss -lunp` shows no UDP socket
  and no `224.0.0.224` membership for the runtime, dora and node PIDs;
  `ss -ltnp` for those PIDs lists only `<bind_host>` (coordinator, zenoh) and
  `127.0.0.1` (daemon node ports, node listeners) — never 192.168.1.11 /
  192.168.2.12; a second daemon with `--machine-id remote` on the lab host
  registers, its `viewer_remote` receives frames at the numbers above; a daemon
  without the token is rejected with 401. Phase-09 confirms on hardware that
  the xArm SDK report streams are unaffected.

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

**Addendum (2026-09-08, phase-14; reworded the same evening).** The external trainer
path sketched above is now SPECIFIED: `15-online-dagger.md` (the runtime's
`OnlineDaggerCoordinator` owns rollout-level control only — the recording, the
`episode_new` gate on the trainer's status, the `takeover` / `handback` / `train_now`
API, the gate events; the policy node owns training, the swap and every algorithm
decision; `trainer_status` / `events` / `PolicySpecAnnounce.capabilities` /
`SessionAnnounce.online_dagger` are the wire). The recommendations of the previous
paragraph became rules there: the swap happens between rollouts (rollouts are refused
while the trainer reports `training` with `pause_while_training`), the runtime tracks the
acting version from the spec heartbeat / action metadata and counts mid-episode changes
as before (the node re-announces `spec` before the `ready` status). `PolicyResetReason`
`"episode_boundary"` is now actually spelled at every episode boundary
(`episode_new` / save / discard — `GatedPolicyExecutor._episode_boundary` →
`drop_and_requery("episode_boundary")`); a handback inside an episode keeps
`"handback"` (before phase-14 both spelled `"handback"`). `LAST_KNOWN_GOOD` /
`weights_reload` stay the v2 route. Superseded (2026-09-08 evening) — the morning's
"`ProDaggerCoordinator` owns the iteration state machine … `events.iteration_complete`
… refused while `training` / `swapping`".

## 12. Configuration (`RuntimeConfig.dora`, 04-runtime §14 block)

```yaml
dora:
  enabled: false                 # default off until phase-12 lands; true + missing extra = disabled + warning
  node_id: mavis_runtime
  dataflow_name: mavis_v2
  bind_host: 127.0.0.1           # v0.3: the ONE interface the private control plane listens on —
                                 #   an IPv4 address OR an interface name resolved at start
                                 #   (lab render: wlp38s0 = the APOLLO Lab Wi-Fi, 192.168.0.88 on
                                 #   2026-09-07, DHCP; or tailscale0); 0.0.0.0 and any control-box
                                 #   subnet address are refused (§9)
  machine_id: lab                # this daemon's id; every local node deploys here
  machines: []                   # remote consumer machines allowed to join, e.g.
                                 #   [{id: gpubox, placeholders: [viewer, observer]}] -> nodes
                                 #   viewer_gpubox / observer_gpubox deployed on that daemon (§2.3, §9)
  rescan_s: 5.0                  # poll registered daemons; a change restarts the dataflow (§2.2 step 6)
  auth: null                     # null = true when bind_host is not loopback; token in <var_dir>/.dora-token
  coordinator_port: 6113         # private ports (never the machine-global 6013/53291); the runtime
  daemon_port: 53391             #   always owns coordinator + daemon (§2.2) — there is no other mode
  zenoh_port: 7447               # daemon --zenoh-listen <bind_host>:<zenoh_port>; exported to self and
                                 #   to foreign clients as DORA_ZENOH_CONNECT=tcp/<bind_host>:<zenoh_port>
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
    # v1.0 (§16.1): + dataflow_restarts: int = 0, spec_age_s: float | None = None
    # phase-14 (2026-09-08, additive, appended last; 15-online-dagger §6/§8):
    capabilities: list[str] = []            # the FRESH spec's PolicySpecAnnounce.capabilities
                                            #   (["online_dagger"]); [] when no spec is fresh —
                                            #   gates "Start Online DAgger" in the launch sheet
    trainer_status: TrainerStatusAnnounce | None = None   # newest policy_trainer_status while
                                            #   fresh (the session-less trainer pill); None once the
                                            #   node detaches / falls silent > spec_stale_s
```

**Phase-14 deltas (2026-09-08, additive; as shipped the same evening — 15-online-dagger
§5 / §6 / §12).** core `protocol/external.py`: `IN_POLICY_TRAINER_STATUS =
"policy_trainer_status"` appended to `RUNTIME_INPUTS`, `POLICY_OUT_TRAINER_STATUS =
"trainer_status"` appended to `POLICY_OUTPUTS`, `EventKind` += `train_now` (10 kinds),
`PolicySpecAnnounce.capabilities`, `OnlineDaggerAnnounce{session_name, session_dir,
rollouts_dir}` + `SessionAnnounce.online_dagger`, `TrainerStatusAnnounce` (10 fields:
`mavis_schema, trainer_id, node_version, state, session_id, policy_version, progress,
metrics, detail, uptime_s`), the two `ExternalStatus` fields above; `EXPORTED_MODELS` +=
`OnlineDaggerAnnounce`, `TrainerStatusAnnounce` (+ `OnlineDaggerConfig` /
`OnlineDaggerSessionInfo` of 01-core §12; `OnlineDaggerStatus` rides `TelemetryMsg`
`$defs`). Superseded (2026-09-08 evening) — the morning's `iteration_complete` /
`pro_dagger_phase` kinds, `ProDaggerAnnounce`, `RefGradStatus` (deleted, not aliased). runtime:
`dora_bridge/dataflow.py` renders the input (queue 8) and the output (the example dataflow
is byte-identical to the morning's — the ids did not change); `ExternalPolicyHub` caches
`trainer_status`, exposes `trainer_capable()` (`"online_dagger"` in the FRESH spec) /
`trainer_status(now)` / `trainer_age_s(now)` and replays the cached status + spec version to a
coordinator that attaches later (`attach_trainer_sink` / `detach_trainer_sink`);
`DoraWiring.external_status` fills the two fields; `SessionFacts.online_dagger` rides the
announce; `SnapshotPublisher.publish_event(kind, payload, session_id)` carries the kinds and
`enqueue_event()` (deque 256) takes gate events from the tick. Both contract goldens
(runtime `tests/dora_bridge/golden/contract_golden.json`, policy-node
`tests/golden/contract_golden.json`) carry the two keys `TrainerStatusAnnounce` /
`OnlineDaggerAnnounce` (field-name lists, inserted after `event_envelope_fields`),
`event_kinds` ending `train_now`, `session_announce_fields` ending `online_dagger`,
`policy_spec_announce_fields` ending `capabilities`; byte-identical (sha256 `4dc67e12…997d`,
3698 B).

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

**Resolved 2026-09-07 (user):** LAN subscribers are v1 — publishing is
unconditional for the process lifetime and consumers on other machines of the
lab network subscribe through dora's multi-daemon mechanism (§9); there is no
"tripod mode" of any kind.

Still open:

1. **Camera encoding for remote consumers** — raw rgb8 at 30 Hz is fine on
   one host; do you want a JPEG/downscaled variant in v1? (Resolved 2026-09-04:
   the Perception Arm's camera is USB serial `322143060792` = `view_wrist`, the
   Manipulation Arm's is `349643062582` = `grip_wrist`.)
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

## 16. Implementation record (phase-12, 2026-09-08)

Everything in §1–§13 is implemented as written unless listed here. Spelling authority is
now core `protocol/external.py` (this document and that module agree; the policy-node repo
copies the spellings and both repos pin them with the shared golden
`tests/dora_bridge/golden/contract_golden.json` / `tests/golden/contract_golden.json`).

### 16.1 Deviations from v0.3 and why

| Item | v0.3 said | Implemented | Why |
|---|---|---|---|
| `dora.var_dir` default | `~/apollo/dora` | `${APOLLO_HOME}/var/dora` | the 2026-09-07 self-contained-paths rule (04-runtime §14): nothing under `~/apollo` |
| Arm states between sessions on hardware (§4.2) | `IdleArmReader` holds its own read-only `XArmDriver.connect(readonly=True)` per box \| `dora.publish.idle_source: monitor \| driver` (default **`monitor`**): the reader re-publishes the phase-09a read-only `HardwareStateMonitor` samples — zero additional SDK clients; `driver` uses the new `connect(readonly=True)` (hardware §16.3) and is the path when the monitor is disabled \| "two SDK clients on one control box are unevidenced" (CLAUDE.md, 04-runtime §13.3); the monitor already pauses itself around hardware sessions. Both sources publish the same idle `StateSnapshot` (`tick == -1`, `session_extra.source == "idle"`) into `bus.snapshot` |
| Registered-daemon discovery (§2.2 step 6) | "find the CLI / control API that lists daemons" | **`dora doctor --coordinator-addr … --coordinator-port …`** parsed (`Connected machines:` block, ids `<machine_id>-<uuid7>`; a dead daemon disappears within ≤ 5 s); run on a helper thread `dora-rescan` every `rescan_s` and on `POST /api/dora/machines/{id}/join`, never on `dora-bus` | `dora status --format json` reports one `daemon.status` only and `dora list` lists dataflows only (verified 2026-09-07); a subprocess spawn on the bus thread cost camera frames (measured slot overwrites) |
| Idle `session` announce | `arm_ids` / `has_rail` only | also `frames` (`arm_base:<id>`), `action_space: delta_ee`, `action_names`, `state_names` of the delta_ee layout over ALL configured arms, `camera_ids` seen | a policy node must declare a matching spec BEFORE the operator starts the session (§6.1 step 2 is checked at `POST /api/session`); the fake node learns the layout from this announce |
| Per-client `seq` (§3.2) | non-monotonic ⇒ dropped | `seq == 1` resets the per-`(input, client)` counter; nodes append their pid to `client` (`mavis-policy-node#<pid>`, `fake_policy#<pid>`) | a restarted node otherwise stays dropped until it overtakes the dead process's counter |
| Microphone output (§2.5) | depth-1 slot | the ordered bounded FIFO (shared with `events` / `policy_reset`, 64 deep ≈ 2.5 s of audio) | `block_seq` must stay gap-free across a GIL stall of the bus thread; a slot overwrite is a lost block, a FIFO entry is a late one |
| Every output metadata | §3.2 keys | + `send_t_mono` (the publish instant; `t_mono` is the frame's capture time for cameras) and `prewarm: true` on the one dummy frame per camera output sent right after attach | consumers measure hop latency against `send_t_mono`; `viewer_probe` skips prewarm frames |
| stdout diagnostics (§8) | try `RUST_LOG=error` first, fd redirect as fallback | `RUST_LOG=error` is set before `import dora` AND fd 1 is `dup2`'d to `<var_dir>/node-stdout.log` (20 MB rotate) for the node's lifetime when `dora.log.quiet_node_diagnostics` | measured 2026-09-07: with `RUST_LOG=error` the node API still printed JSON WARN lines (`dora-rs/dora#2742` diagnostics, zenoh SHM watchdog) — 11 lines in the first second of two 640×480 cameras; with the redirect 0 lines reach the runtime's stdout (`PYTHON_PRINT_STILL_VISIBLE` test: Python's `sys.stdout` is re-opened on the saved fd) |
| Detach → re-attach (§2.4) | "retry 1 s → 10 s backoff" | a detach waits `attach_retry_s[0]` (1 s) before re-running steps 3–5 even when the control plane is healthy | consumers (and `GET /api/dora`) observe `detached`; a dying daemon gets a moment to die before the respawn check |
| `SnapshotPublisher` wake-up | driven by `bus.snapshot.wait_fresh(0.1)` | `wait_fresh(min(0.1, 0.5 / telemetry_hz))` (≥ 50 Hz), idle `arm_state` publishes EVERY idle snapshot (paced by the reader at `idle_state_hz`), loop `arm_state` decimated to `state_hz` | between sessions only 10 Hz snapshots arrive — telemetry (25 Hz) and heartbeat must not wait for them; decimating a 10 Hz stream by a 10 Hz gate lost ~10 % on jitter |
| `viewer` / `viewer_<id>` inputs (§2.3) | `cam_view_wrist_cam` (+ depth) | `arm_state`, `session`, EVERY published `cam_*` (+ its depth sibling) | a fixed-viewpoint consumer may want either wrist camera; additive (queue 1 drop_oldest) |
| Example dataflow interpreter | `sys.executable` | the committed `dataflows/mavis_v2.example.dora.yml` pins `python3`; the runtime's rendered `<var_dir>/mavis_v2.dora.yml` pins `sys.executable` | a byte-identical committed example cannot contain a machine-specific path |
| Test package name | `tests/dora/` | `tests/dora_bridge/` (a package) | a top-level `tests/dora` package on `sys.path` would shadow the `dora` PyPI module |
| Sim depth (§4.2) | "depth sibling stream" | the same `CameraFrame` carries `.depth` (uint16 mm, `depth_scale_m` 0.001); `SimWorkcell(depth_cameras=…)` / `SimCamera(depth=True)` render it with `Renderer.enable_depth_rendering()` (≈ +1.15 ms/frame at 640×480); the bridge publishes it as `cam_<id>_depth` with the SAME `frame_seq` | seq alignment by construction; `RenderService` keeps one renderer per (source, h, w) with the depth toggle wrapped in try/finally |
| `GatedPolicyExecutor` telemetry | — | `DaggerStatus.policy_stale` / `InferenceStatus.policy_stale` = `staleness_scale(now) < 1` or the external node gone; `policy_version` string from `PolicySource.version_label()` (`"<policy_id>/v000002"` for external); the recorded `policy_version` from `current_version()` | the promised 04-runtime §15 drift, closed |
| `SessionManager._validate` | — | skips `resolve_policy` for `policy_source: external` (no checkpoint exists) and `SessionInfo` echoes `policy_source` | otherwise every external session 409'd "no promoted deploy checkpoint" |
| Parked pose in sim (§4.2) | preview `MjData` keeps the session's final joints | the manager captures the LAST loop snapshot's joints at teardown, `submit_state`s them to the recreated preview render source and serves them through `SimIdleSource`; the built preview scene is cached per process (a MuJoCo compile is ~0.3–0.5 s) | the parked camera pose equals the last in-session frame's pose exactly (the test asserts ≤ 1e-6) |
| `rtt_probe` | "two-hop RTT node" | plays the RUNTIME's role (`Node("mavis_runtime")`) on a runtime-less private dataflow against `fake_policy --mode echo` | dynamic node ids are not exclusive: two `mavis_runtime` attaches would split the inputs |
| `ExternalStatus` | as §13 | + `dataflow_restarts`, `spec_age_s` | join/rescan visibility; the spec heartbeat age |
| **Remote machines: explicit JOIN, not registration** (§2.2 step 6, §9) | a registered remote daemon ⇒ rescan renders `viewer_<id>` / `observer_<id>` and restarts the dataflow | **dora 1.0.1 start barrier (measured 2026-09-08)**: with a dynamic placeholder deployed on another machine, `dora start` leaves EVERY node of the dataflow unstarted — the lab daemon does not spawn `probe` and a `Node("mavis_runtime")` attach on the lab daemon **blocks forever, holding the GIL** (the whole runtime process froze; a `Node()` started before the remote consumer attaches never unblocks even when it attaches later) — until the remote dynamic node has been attached. Hence: (1) registration only sets `machines[].registered` (rescan, `dora doctor`); (2) `POST /api/dora/machines/{id}/join` restarts the dataflow with that machine's placeholders and the bridge waits up to `dora.join_attach_timeout_s` (30 s) for the barrier to clear before it attaches — detected by attaching a lab-side dynamic node `canary` (declared in the rendered YAML, `nodes/canary.py`) in a SUBPROCESS: it returns 0 the moment dora lets it through and is killed at the deadline, so a closed barrier can only ever block a child process (an earlier check via `dora node list` `probe` = `Running` was fooled once by the previous same-named dataflow's probe after an unclean stop and froze the runtime — `node_status` now filters by dataflow UUID and is diagnostic only); the remote consumer must attach `viewer_<id>` inside that window; (3) an expired join rolls back to a dataflow without the machine (`machines[].detail`: "join timed out …") so local publishing never depends on a remote; (4) ANY other restart (daemon death, `dora stop`, a vanished remote daemon) renders WITHOUT remote placeholders — remotes re-join (they receive STOP / INPUT_CLOSED anyway); (5) `DoraMachineInfo` gained `joined` and `detail`. The remote recipe (§9) becomes: start `dora daemon --machine-id <id> …`, `POST /api/dora/machines/<id>/join`, attach `Node("viewer_<id>", daemon_port=<Q2>)` within 30 s (measured: joined + re-attached 0.4 s after the viewer attached) | the v0.3 flow deadlocked the runtime in the LAN acceptance test |
| Attach churn | — | dora 1.0.1 leaks its `dora-node-runtime` Rust threads on every `Node()` (64 threads after a 6-minute restart loop) — the bridge never restarts a dataflow on a rescan unless a joined daemon vanished, and the first attach never re-queries `dora doctor` mid-restart (the query raced `dora stop` and rendered the remote out again) | observed while diagnosing the freeze above |
| **Remote daemon loss: no automatic restart** (§9) | a joined machine whose daemon vanished loses its placeholders at the next rescan (stop + re-render + start) | **measured 2026-09-08**: the dataflow with a placeholder on a dead machine keeps Running, the lab daemon drops frames to the dead peer without ever stalling `send_output`, local consumers keep every frame — but the `dora stop` + `dora start` the v0.3 rule issued ~2 s after the loss made the dora 1.0.1 coordinator answer **`429 Too Many Requests` to every CLI call for ~50 s** (reproduced WITHOUT the runtime: a bridge-like publisher + `dora doctor`/`dora list` at ~1 call/s after the death → 429 from +15 s on, while a lone `dora list` every 4 s or a `dora doctor` every 2.5 s without a publisher stayed fine, and the same CLI at 5–20 req/s with no dead machine never tripped it — so it is the coordinator's handling of a dataflow that still deploys nodes on a dead machine, and CLI calls in that state hasten it; the exact rule is inside dora, see the report's open problems). During that window the bridge could neither `dora start` nor `dora list`, sat `unavailable`, and local consumers lost the stream. Hence v1.0: a vanished daemon only marks the machine **lost** (`machines[].registered: false`, `joined: false`, detail "daemon unregistered: its placeholders stay in the running dataflow …"); its placeholders are rendered out at the next restart for another reason (a join, a re-attach — `_attach` renders lost machines out before re-attaching, since re-attaching under a dead-machine placeholder is unverified against the start barrier); a returning daemon is `registered` again and its `POST join` is the (non-idempotent) restart that re-deploys `viewer_<id>` on the new daemon | v0.3 rule wedged the control plane |
| Observer input queues (§2.3, §4) | every placeholder input `queue_size: 1, drop_oldest` except `events` 64 | the `observer` (a logger) keeps latest-wins only for the high-rate image / state streams; `mic_*` gets `queue_size: 32` (1.3 s at 25 Hz), `session` / `telemetry` / `policy_reset` / `heartbeat` 8, `events` 64 — with `queue_size: 1` one 40 ms consumer hiccup in a 60 s window cost one mic block (measured 2026-09-08; the runtime's own FIFO had not dropped it). Viewer and policy inputs are unchanged | a log must not lose mic blocks to a scheduler hiccup |
| Consumer-side first-frame stall (§7, §9 recipes) | — | every camera input of a viewer/observer is `queue_size: 1, drop_oldest` (latest wins, by design), so a consumer that stalls ~200 ms loses the 2-3 frames behind it with dora's `Discarding event for input … due to queue size limit`. The one stall every Python consumer pays is **pyarrow's numpy interop set-up on the first `Array.to_numpy()` of the process** (measured 2026-09-08 with per-iteration timing in `viewer_probe`: a 190 ms "body" stall on the first steady-state event; it produced exactly one 2-frame seq gap 0.07-0.4 s after the probes' warm-up ended, on the local and the remote viewer alike, and was first misread as a transport / `dora doctor` / daemon stall — all three ruled out by experiment: rescan on/off gave identical gaps, the bridge's own `send_output` never exceeded 0.9 ms, no slot overwrite). Consumers call `pa.array([0.0]).to_numpy()` once before attaching; the repo's probes and the policy node do; after that: 0 discards, 0 gaps. `dora doctor` every `rescan_s` (27 ms per call) does NOT disturb delivery | measured |
| Policy-node repo | package deps `dora-rs`, `numpy` | + `dev` extra carries `dora-rs-cli` (its CI e2e needs the binary); `spec` messages carry the common inbound metadata keys; `LeRobotPolicy` is written against lerobot 0.6.x API names but never executed on a real checkpoint (none on this host) | — |

### 16.2 Threading facts verified (§2.5)

`dora.Node` stays single-owner on `dora-bus` (no experiment moved `next()` to a second thread).
`try_recv()` returns `None` when the queue is empty and never blocks; `next(timeout)` returns
`{"type": "ERROR", "error": "Timeout event stream error: Receiver timed out …"}` on timeout.
`node_config()` on 1.0.1 returns `{"inputs": {...}, "outputs": [...]}` for a dynamic node —
the bridge checks the input set == `RUNTIME_INPUTS` and the declared outputs ⊇ the expected
set and reports a mismatch in `ExternalStatus.detail` (empty when it matches).
- **Control-loop interference is a tail effect, cause not yet pinned (2026-09-08, 60 s sim teleop, safety
  twin on, 4 rgb + depth + mic + telemetry, `tests/dora_bridge/test_perf_bridge.py`)**: with the bridge
  OFF the live loop runs 100.0 Hz, 0 overruns, control-path (non-sweep) tick median 1.89–2.05 ms, p99
  3.0–3.2 ms; with the bridge ON 99.9–100.0 Hz, 0 overruns (1 in one of four runs), median +0.06–0.38 ms,
  **p99 5.4–7.9 ms, 5–12 % of ticks > 5 ms, max 8.5–12.9 ms**. The v0.3 "tick p99 < 2 ms" is not met by
  the live loop even with the bridge off (the synchronous `tests/test_perf.py` yardstick is: it stops
  the loop thread and the hub first). Ruled out by measurement: GC (≤ 7 gen-0 passes ≤ 0.45 ms per
  minute, no gen-1/2), the 5 ms GIL switch interval (`sys.setswitchinterval(0.001)` changed nothing —
  reverted), dora holding the GIL in `send_output` (a pure-Python spinner thread saw max 0.94 ms gaps
  while 921 KB frames went out at 60 Hz, identical to idle; `send_output` itself peaked at 5.4 ms but
  released the GIL). The bridge's own per-message costs are small (camera build 0.14–0.83 ms mean /
  ≤ 4.1 ms max — the wrist cameras carry the one-pass FK —, send 0.2–0.3 ms mean / ≤ 1.8 ms max,
  `arm_state` send 0.12 ms). Remaining suspects: many sub-millisecond Python-level GIL holds across the
  bus / publisher / encoder-tap threads adding up against the 100 Hz thread, and lock contention on the
  bus snapshot. An out-of-process bridge would remove it by construction (open problem). Mitigations
  available today without code: lower `dora.publish.obs_hz` / `state_hz` / `telemetry` rate, publish
  fewer cameras (`dora.publish.cameras`).
- **First-call set-up is paid before "attached"**: the first `mic_*` build of a process cost 312 ms on
  the bus thread (pyarrow / numpy interop) — with a session running that is a 312 ms control-loop stall;
  `codec.warm_up()` now exercises every encoder once in `_attach()` before the bridge reports attached.
- **dora 1.0.1 `Node()` monkeypatches the stdlib `logging.basicConfig` of the HOST process** (found
  2026-09-08 through an order-dependent test failure): after the first `Node()` in a process,
  `logging.basicConfig` is a function compiled from `<string>` (constants `handlers`, `level`) that
  calls the real one with `handlers=[...]`, so any later `logging.basicConfig(stream=…)` or
  `(filename=…)` — the runtime's own entry point, or a library configuring logging lazily — raises
  `ValueError: 'stream' or 'filename' should not be specified together with 'handlers'`. The bridge
  saves the function before `Node()` and puts the stdlib one back if it changed (INFO log
  "dora Node() replaced logging.basicConfig; restored the stdlib one");
  `tests/dora_bridge/test_live_control_plane.py` asserts it. Foreign node processes (policy node,
  viewers) live with the wrapper — they never call `basicConfig` with `stream`/`filename` after
  attaching, or they attach first.


### 16.3 Acceptance numbers (lab host, 2026-09-08, sim `mavis_v2` unless noted)

Filled from the phase-12 test run — see the phase-12 report (`docs/prompts/phase-12-dora-interface.md`
验收标准 checklist) for the per-item PASS/FAIL table; the headline numbers:

- attach after control-plane start: **0.12–0.17 s** (`GET /api/dora` attached ≤ 5 s ✓);
- control-loop non-interference (60 s sim teleop, bridge off → on): tick rate 100.0 → 99.9–100.0 Hz,
  overruns 0 → 0 (1 in one of four runs), control-path median 1.89–2.05 → +0.06–0.38 ms, **p99 3.0–3.2 →
  5.4–7.9 ms** (§16.2 for the analysis; the v0.3 "< 2 ms" is not met by the live loop in either
  configuration);
- two-hop RTT `obs_state → fake_policy(echo) → policy_action`, 1000 samples @30 Hz (final run):
  **p50 0.69 ms / p90 0.82 / p99 0.94 ms / max 1.07 ms, 0 lost** (an earlier 300-sample run: p50 0.79 /
  p99 2.3 / max 5.0 ms);
- `dora-bus` + `dora-publisher` CPU over the 60 s acceptance window: **7.0 % of one core** (bus 2.97 s +
  publisher 1.42 s / 60.2 s) at 4 rgb × 15 Hz + depth 15 Hz + mic 25 Hz + telemetry 25 Hz + arm_state
  10 Hz (idle), mic `block_seq` 25.0 Hz with **0 gaps** at the observer (its `mic_*` input is
  `queue_size: 32`; at `queue_size: 1` one 40 ms consumer hiccup in 60 s cost one block); an earlier
  12 s window read 5.2 % + 1.7 %;
- `send_output` per 921 KB frame: mean 0.19–0.29 ms, max ≤ 1.0 ms; payload build 0.05 ms (static
  camera) / 0.30 ms (wrist camera incl. the one-pass FK);
- one-hop latency at a same-host `viewer` (`send_t_mono` → receive): p50 ≈ 1–8 ms (SHM path),
  frame age (capture → receive, includes the encoder's 15 Hz poll): p50 ≈ 58 ms;
- stdout: 0 dora diagnostic lines on the runtime's stdout over 20 s of two cameras + depth
  (11 lines/s went to `node-stdout.log`);
- LAN two-daemon (`bind_host: wlp38s0` → 192.168.0.88/24 on the "APOLLO Lab" Wi-Fi, auth on, a
  second `dora daemon --machine-id remote` on the same host, `tests/dora_bridge/test_live_lan.py`):
  coordinator + zenoh listen on 192.168.0.88 only, node port on 127.0.0.1, no UDP socket; a
  token-less daemon gets **401**; the remote daemon is REST-visible (`machines[].registered`)
  **1.8 s** after it starts (rescan 2 s) with `dataflow_restarts` still 0; `POST …/join` →
  dataflow restarted with `viewer_remote` (`deploy: {machine: remote}`), the remote viewer attached
  and the bridge was **joined + re-attached 0.3–0.4 s after the viewer started** (start barrier
  cleared; the `canary` subprocess reported it open **1.6 s** after `dora start`, python + dora import
  included); the remote viewer then received `cam_view_wrist_cam` at **15.0 Hz, 0 seq gaps,
  cross-daemon latency p50 3.7 / p90 4.6 / p99 5.95 / max 6.9 ms** (`send_t_mono` → receive),
  frame age p50 25.7 ms, inter-arrival max 72.6 ms over the 10 s window (a concurrent second
  local viewer raised the remote p99 to 8–12 ms — the two-consumer number, not the acceptance
  one); a second `POST join` while joined is a 202 no-op (no restart); the runtime showed **zero
  slot overwrites** during the window; after the remote daemon was SIGKILLed the local viewer kept
  15 Hz with 0 gaps, `registered` flipped false **0.0 s or 47.6 s** after the kill (two runs — the
  coordinator's 429 window, next bullet), a new daemon under the same id was `registered` again
  **1.8 s or 41.5 s** later (same reason), and its `POST join` re-deployed `viewer_remote` with one
  restart (canary 1.6 s, re-joined viewer 0 gaps); the whole LAN test: 72 s;
- `dora doctor` costs **25–30 ms** per call and does not disturb delivery; the coordinator's
  websocket API never answered 429 to **5 req/s (412 calls) or 20 req/s (1314 calls)** of `dora
  list`, auth on or off — so the 429 below is a state, not a request-rate limit;
- REMOTE DAEMON DEATH (SIGKILL of the joined daemon, runtime publishing to it): the dataflow stays
  Running and local consumers keep receiving; `dora doctor` drops the machine within **≤ 2 s**;
  publishing to the dead peer never stalled `send_output`; BUT a `dora stop` + `dora start` issued
  right after (the v0.3 "drop its placeholders" restart) failed, because once a machine with deployed
  nodes has died while the dataflow runs the dora 1.0.1 coordinator soon answers **`429 Too Many
  Requests` (`dora doctor`: "Coordinator: not reachable") to every CLI call for ~50 s** — measured 4×
  with the runtime (`registered` flipped 47.6 s after the kill in the passing LAN run) and once without
  it (bridge-like publisher + doctor/list polls at ~1/s → 429 from +15 s), `dora stop`/`start` inside
  that window fail too, then it recovers by itself — see §16.1 "remote daemon loss" for what the
  bridge does about it (no restart on loss, 10 s rescan back-off while `dora doctor` fails,
  `registered` lags up to ~60 s, a returning daemon re-joins with one restart).

### 16.4 Phase-12 merged into the main trees (2026-09-08)

The `phase-12` worktrees were merged onto the uncommitted phase-13 working trees of the five
sub-repos (3-way `git merge-file` per overlapping file, index untouched, nothing committed).
Overlaps were reconciled without dropping a line of either side — core `SessionSpec`
(`policy_source` next to `policy`, then the phase-13 dataset / filter / return block; both
validator groups in sequence), `TelemetryMsg` field order `…, microphone, external,
hardware_monitor, datasets`, runtime `manager.create()` (every phase-13 409 check → the
phase-12 `dora.before_bringup()` bracket → bring-up), `MicrophoneReader._publish` (phase-13
`sinks` then phase-12 `taps`), `ws_telemetry` (both builders), `rest.py` imports, the UI
`Cockpit` (`external=` chips + `onTerminate={endSessionWithReturn}`); generated artifacts
(core `schemas/`, ui `schemas/` + `src/gen/protocol.ts`, sim `ASSET_MANIFEST.json`) were
regenerated, never hand-merged. Verification after the merge: core 423 passed, hardware 293,
sim 155 (13 egl), runtime 632 passed / 2 skipped (all dora-marked live tests on a private
control plane), ui 355 / 39 files, `gen:check` OK.

**Two phase-12 tests asserted pre-phase-13 shapes and were adapted** (the only test edits of
the merge):

1. `tests/dora_bridge/test_import_confinement.py` — the AST scan sanctioned `pyarrow` only
   under `dagger/`; phase-13's recorder imports it lazily for `episodes/<id>/frames.parquet`
   and the LeRobot export. `PYARROW_ALSO_OK = {dagger, recorder}`, matching the widened
   `pyproject.toml` `TID251` message (§1 amendment above). `dora` stays confined.
2. `tests/dora_bridge/test_e2e_external_policy.py::test_external_dagger_two_episodes` — read
   the dataset as a vanilla LeRobot v3 tree (`data/**/*.parquet` + `episode_index`); rewritten
   to the episode-directory contract: `sorted(root.glob("episodes/*/frames.parquet"))`, exactly
   two files (capture order), the same `policy_version` assertions per file.

**Known flakes (host-dependent, not merge defects; left as they are):**

- `test_e2e_external_policy.py::test_409_422_matrix_then_running_fast` asserts
  `POST /api/session` → RUNNING within **1.0 s**; `SessionManager.create()` costs 0.6–0.85 s
  on this host (`_servo_faithful_scene` ~310 ms + the first `DoraWiring.camera_announces`
  kinematics build ~230 ms + sim / twin / EGL bring-up), identically in the merged and the pure
  phase-12 tree, so the ~150 ms headroom trips under load (1.53–1.66 s seen twice at the end of
  a full run; 12 of 13 isolated runs 0.71–0.80 s). Either pre-build the announce kinematics /
  the servo-faithful scene or treat the budget as soft.
- The live tests' leak check is a **machine-wide `pgrep -x dora`** (`harness.dora_pids()`,
  `test_live_streams.py`, `test_live_control_plane.py`): a concurrent dora control plane on the
  host — here a policy-node test run in `~/projects/apollo-mavis-v2-ws-p12` spawning
  `dora coordinator/daemon --machine-id ci` — fails them with `dora processes left behind:
  {…}` (and its load pushed a 15 Hz probe to 11.9–13.5 Hz). Two dora suites on one host is
  unsupported; scoping the check to the venv path / process groups would weaken the rule and
  was not done.
- `test_e2e_fixed_viewpoint.py::test_park_the_perception_arm_then_end_the_session` failed once
  right after the 72 s LAN test (joint creep 2.5e-5 rad vs the 1e-6 PD-settle tolerance),
  green in isolation in both trees; `test_live_control_plane.py::test_control_plane_port_busy_…`
  failed once on a busy port and passed on re-run.
- `test_perf_bridge.py::test_teleop_tick_rate_with_bridge_on_and_off`: the `overruns == 0`
  guard fails 1-in-2 in isolation (one overrun per 5 s window) with the old AND the new encoder
  loop — the documented GIL-tail open problem (§16.2), not loosened.
- Also fixed on the way (phase-14 verification): `streams/hub.py` `EncoderWorker` sampled the
  depth-1 slot once per fixed 1/fps grid tick and aliased against the sim `RenderService`'s
  equal-rate grid (pre-session `cam_view_wrist_cam` at 11.9–14.5 Hz with contiguous seqs); the
  poll now waits inside its period for the next distinct seq and re-anchors (14.98 Hz, 0 gaps,
  frame-age p99 62–67 → 11.7 ms; `tests/test_video_hub_pacing.py`).
- Docs drift the merge surfaced and this revision closes: §1 import confinement (above);
  the `events.episode_saved` payload does carry the capture-time `episode_id` (inside
  `summary`, §4.2).

### 16.5 Phase-14 on top (2026-09-08 evening) — pointer

The Online DAgger shell rides this bridge unchanged: no new stream or command id beyond
`policy_trainer_status` / `trainer_status` (already in v1.1), `EVENT_KINDS` + `train_now`,
`SessionAnnounce.online_dagger`, `PolicySpecAnnounce.capabilities`; the private control plane,
the "never on the tick" rule (§2.5 — the coordinator's `SerialWorker` and the publisher's
`enqueue_event` deque are the two new off-tick paths) and the goldens are the mechanism.
Its own implementation record — deviations, the e2e `tests/dora_bridge/
test_e2e_online_dagger.py` (3 tests, 30.9–32.3 s on the private control plane), the refusal
strings, `session.json`, open items — is `15-online-dagger.md` §12; the morning's PRO-DAgger
v1.0 record is `15-pro-dagger.md` §15 (history only, never shipped).

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
