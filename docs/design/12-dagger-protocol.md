# 12 — DAgger / Interactive Learning Protocol

Status: v1.0 (2026-09-01). Cross-cutting spec, consistent with `00-overview.md`
v0.3 (binding spine). Ground truth: `docs/research/dagger-online-training.md`,
`docs/research/lerobot-data.md`. HG-DAgger with continuous async training;
knobs mirror source-verified hil-serl / lerobot values.

## 1. Scope, module map, and process topology

Everything DAgger-specific: takeover gate (shared with inference mode),
recording schema, label extraction, jump-free action-space contract,
AsyncTrainer, checkpoint lifecycle/hot-swap, failure/test story. Frame
conventions + base schema: `10-frames-and-data.md`; twin gate:
`11-safety-collision.md`; session engine: `04-runtime.md`. Layout (exact):

```
apollo_mavis_v2_core/dagger/types.py        # ControlMode, GateEvent, FrameAnnotations,
                                         # CheckpointInfo, EpisodeSummary, TrainerStatus
apollo_mavis_v2_core/dagger/interfaces.py   # TakeoverGate, InterventionRecorder,
                                         # PolicyReloader, AsyncTrainerClient (Protocols)
apollo_mavis_v2_runtime/dagger/gate.py      # TakeoverGateImpl (per-arm state machines)
apollo_mavis_v2_runtime/dagger/loop.py      # GatedPolicyExecutor (shared), DaggerSession,
                                         # InferenceSession
apollo_mavis_v2_runtime/dagger/recorder.py  # DaggerRecorder (LeRobotDataset wrapper)
apollo_mavis_v2_runtime/dagger/reloader.py  # PolicyReloaderImpl
apollo_mavis_v2_runtime/dagger/trainer/     # AsyncTrainer process (python -m ...runtime.dagger.trainer)
    trainer.py                           #   TrainerMain, BCFineTuner
    sampling.py                          #   FiftyFiftySampler, LabelIndex
    checkpoints.py                       #   CheckpointStore (also imported by reloader)
    control.py                           #   ZMQ REP control endpoint
apollo_mavis_v2_runtime/dagger/client.py    # AsyncTrainerClientImpl (spawn/monitor/submit)
```

Process topology (single machine, 2× RTX 4090):

- **Runtime process** (GPU 0): 100 Hz servo loop, policy inference at
  10–30 Hz, twin gate, recorder, FastAPI. Owns the live policy object.
- **AsyncTrainer process** (GPU 1, `CUDA_VISIBLE_DEVICES=1`): spawned at
  DAgger-session start, killed at session end. Channels: (a) the DAgger
  dataset dir (trainer reads only), (b) the checkpoint dir (trainer writes,
  runtime reads), (c) a ZMQ REP control socket
  `tcp://127.0.0.1:${trainer_port}` (default 5757) for status/stop/train_now.
  Weight transfer is a filesystem path, never a byte stream (research §4.4).
- **Inference mode spawns no trainer and opens no dataset** (§3).

## 2. Takeover state machine (TakeoverGate)

One gate per participating arm. States map 1:1 onto the wire/dataset enum
`ControlMode` (`core.dagger.types`, mirrored in `core.protocol`):

| State | `ControlMode` | Who commands the arm | Recorded as label |
|---|---|---|---|
| AUTONOMOUS | `policy` | policy | no |
| TAKEOVER_TRANSITION | `takeover_transition` | human | no (excluded) |
| HUMAN | `human` | human | yes |

**Space is a discrete toggle** (binding decision): the UI sends
`ActionMsg{name: "takeover_toggle"}` (argless — it always applies to the
server-authoritative active arm, matching core §10 and 05-ui) exactly once per press
(`arm_id` defaults to the server-authoritative active arm); it is never a held
key and never appears in `KeysMsg.held`. Transitions (per arm, evaluated in
the 100 Hz control loop):

```
AUTONOMOUS --takeover_toggle--> TAKEOVER_TRANSITION   # human in control NOW
TAKEOVER_TRANSITION --t >= T_blend--> HUMAN           # auto-advance
TAKEOVER_TRANSITION --takeover_toggle--> AUTONOMOUS   # abort takeover
HUMAN --takeover_toggle--> AUTONOMOUS                 # explicit handback
any --episode boundary (N/save/discard)--> AUTONOMOUS # reset per episode
```

- `T_blend` = `dagger.t_blend_s` (RuntimeConfig, 04-runtime §14), default **0.3 s**, valid
  0.2–0.5 s (research §4.4 / Sirius: first human reactions are reflexive).
- Entry is **instantaneous in authority**: from the first tick after the
  toggle the human's twist drives the arm (re-anchor, §6); TRANSITION only
  changes the *labeling* flag. Exit is instantaneous state-wise; handback
  smoothness is the action-space contract's job (§6), not a gate state.
- Every transition emits `GateEvent{arm_id, mode, t_mono, seq, source}` →
  telemetry, recorder metadata, and the doubt logfile (takeover instants,
  HG-DAgger Eq. 3/4 hook — logged, not used for gating in v1).

**Per-arm gates + freeze-other-arms rule.** Exactly one arm may be in
HUMAN/TRANSITION at a time (one human, one keyboard). While engaged:

- All *other* policy-driven arms **freeze**: policy queries continue
  (counterfactual logging, §4) but the executed action is a hold (zero delta,
  current joint targets re-sent); `control_mode` stays `policy`,
  `frozen: true` in telemetry; frozen frames are ordinary policy frames.
- `Tab` (switch_arm) and a `takeover_toggle` naming a *different* arm are
  rejected (`AckMsg{ok: false, detail: "takeover active"}`) — retargeting the
  keyboard mid-takeover is unsafe.

**Deadman interplay.** In HUMAN, the overview-§6 stale-input deadman (~0.2 s
without a fresh `KeysMsg`) ramps the human twist to zero; the gate **stays in
HUMAN** (arm holds). Controller WS disconnect during HUMAN/TRANSITION: gate
stays engaged, zero twist, session pauses (policy must not resume unsupervised
after a disconnect); a reconnected controller sees the gate state in telemetry
and may toggle back.

Gate signatures (core Protocol + runtime impl):

```python
class TakeoverGate(Protocol):
    def mode(self, arm_id: str) -> ControlMode: ...
    def engaged_arm(self) -> str | None: ...    # arm in HUMAN/TRANSITION, else None
    def on_toggle(self, arm_id: str, t_mono: float) -> GateEvent | None: ...
        # ActionMsg handler; returns event iff accepted (else caller Nacks)
    def tick(self, t_mono: float) -> list[GateEvent]: ...
        # 100 Hz; auto-advances TRANSITION -> HUMAN after T_blend
    def reset(self) -> None: ...                # episode boundary -> all AUTONOMOUS
```

## 3. Inference-mode variant: safety-escape takeover

Inference mode reuses the **identical** `TakeoverGateImpl` and
Space→`takeover_toggle` path — no parallel implementation. The shared
executor forks only on recording:

```python
class GatedPolicyExecutor:
    """Per-arm policy/human mux used by BOTH DaggerSession and InferenceSession.
    Runs at policy rate (10-30 Hz); the 100 Hz servo loop interpolates."""
    def __init__(self, gate: TakeoverGate, policy: Policy, teleop: TeleopInput,
                 anchor: ActionAnchor,                            # §6
                 recorder: InterventionRecorder | None) -> None: ...
    def step(self, obs_by_arm: dict[str, Observation], t_mono: float) -> dict[str, np.ndarray]:
        """Post-gate executed joint targets per arm; if self.recorder is not
        None: recorder.add_frame(obs, FrameAnnotations(...))."""
```

- `DaggerSession` passes `recorder=DaggerRecorder(...)`; `InferenceSession`
  passes `recorder=None`. **No dataset object exists in inference mode** — no
  `LeRobotDataset.create`, no trainer process — so escape frames structurally
  cannot enter aggregation (nothing to write to; not a flag that could drift).
- Purpose (overview §4.4): takeover is a **safety escape** — the human steers
  back to a safe configuration and then **ends the session** (UI "End session"
  → `DELETE /api/session`) instead of letting a native reset / "return to
  initial" wreck a bad scene. A second toggle (handback to policy) is
  permitted; the UI labels the state "SAFETY ESCAPE (not recorded)" (05-ui.md).
- Episode keys (N/Enter/Backspace) are unbound (no episodes); `gate.reset()`
  runs only at session teardown. Optional eval logging (success tallies,
  takeover timestamps, policy_version) goes to plain JSONL, never a dataset.

## 4. Per-frame recording schema (DAgger datasets)

DAgger datasets are ordinary LeRobot v3 datasets (real `lerobot` library,
`streaming_encoding=True`, NVENC; base schema in `10-frames-and-data.md`),
recorded at 20–30 fps while the 100 Hz servo loop interpolates. Every
recording mode already carries `intervention`, `action_source`, `wallclock_ns`
(overview §4.2) so plain-teleop and DAgger datasets stay merge-compatible.
DAgger adds three features:

```python
# Exact feature dicts (N = action dim for this workcell; example: 1 arm + rail = 8:
# [ee.dx, ee.dy, ee.dz, ee.drx, ee.dry, ee.drz, gripper.pos, rail.dpos])
features["intervention"]  = {"dtype": "bool",  "shape": (1,), "names": None}   # upstream name/shape verbatim
features["action_source"] = {"dtype": "int8",  "shape": (1,), "names": None,
    "info": {"labels": {"0": "policy", "1": "teleop", "2": "joint_jog",
                        "3": "takeover", "4": "planner"}}}   # core CommandSource
                                                             #   (10-frames §7.3)
features["wallclock_ns"]  = {"dtype": "int64", "shape": (1,), "names": None}
# --- DAgger-only additions ---
features["control_mode"]  = {"dtype": "int8",  "shape": (1,), "names": None,
    "info": {"labels": {"0": "policy", "1": "human", "2": "takeover_transition"}}}
features["policy_action"] = {"dtype": "float32", "shape": (N,),
    "names": features["action"]["names"],       # identical layout to `action`
    "info": {"counterfactual": True}}
features["policy_version"] = {"dtype": "int32", "shape": (1,), "names": None,
    "info": {"run_id": "<dagger run_id>"}}      # version scoped to this run
```

Per-frame semantics (assembled in `GatedPolicyExecutor.step` → `DaggerRecorder`):

- `action` = **executed_action**: the post-twin-gate action actually sent to
  the servo layer, in the arm's **canonical action frame** (per-arm, fixed per
  dataset, declared in `features["action"]["info"]["frames"]`). Human teleop
  twist is converted into that frame *before* execution and recording
  (`RelativeFrame` precedent, research §3.1). If the twin gate clamped the
  command, the **clamped** value is recorded — the label is what the robot
  did, not what was asked.
- `policy_action` = counterfactual: the policy **is queried every policy tick
  even during HUMAN/TRANSITION** (cheap on GPU 0; needed for HG-DAgger doubt
  calibration and Sirius-style weighting later). Query failure / no fresh
  chunk → NaN fill.
- `control_mode` = gate state at the snapshot instant;
  `intervention = (control_mode != 0)`; `action_source = 3` (takeover) iff
  human executed, else `0` (policy); `4` (planner) is reserved — planner
  motions are never recorded inside an episode (10-frames §7.3).
  `policy_version` = checkpoint that produced
  `policy_action` (monotonic int within the run, §7).
- Multi-arm: vectors concatenate per-arm blocks in `WorkcellConfig` arm order;
  `control_mode`/`intervention` describe the engaged arm's gate state; per-arm
  mode is recoverable because at most one arm is ever non-`policy` (§2) and
  `GateEvent`s (arm_id + seq) are stored in `episode_meta["gate_events"]`.

One DAgger run appends to a **dedicated dataset repo**
`apollo/xarm7_{task}_{n}arm_{conv}_dagger_{run_id}` (grammar: 10-frames §8.1);
the seed/BC dataset is never mutated.

## 5. Label extraction

Training labels follow HG-DAgger Eq. 2 exactly: **only frames where the human
is in control** become supervised pairs — `label_mask(control_mode)` is
simply `control_mode == 1` (`1 = human`) over an episode's int8 column.

- `takeover_transition` frames (first `T_blend` = 0.2–0.5 s after each
  takeover, §2) are recorded but **excluded**: reflexive human reactions +
  the tail of a policy failure. At 25 fps, `T_blend = 0.3 s` discards ~7–8
  frames per takeover.
- Policy frames are never labels in v1 (no expert label exists for them) but
  are still recorded: Sirius pre-intervention down-weighting and IWR
  up-weighting are training-side reweightings needing no schema change.
- The label index is `(episode_index, frame_range)` pairs computed per
  submitted episode from its `control_mode` column
  (`sampling.py::build_label_index(...) -> LabelIndex`); the seed BC dataset
  contributes all frames (pure demos). A takeover **segment** = maximal run
  of `control_mode != 0`; segment count + takeover-instant doubt
  (policy_action variance) go into `EpisodeSummary` → UI + doubt logfile.

## 6. Action-space contract: jump-free switching

What makes human↔policy switches discontinuity-free (hil-serl mechanism,
research §3.1/§4.3); implemented by `ActionAnchor` in `runtime/dagger/loop.py`:

```python
class ActionAnchor:
    def __init__(self, workcell: WorkcellInterface, ik: IKSolver,
                 slew: SlewLimits) -> None: ...
    def on_gate_event(self, ev: GateEvent) -> None: ...
        # Re-seed: target pose := current MEASURED ee pose (get_state());
        # drop any pending policy chunk; start slew window on human->policy
    def apply_delta(self, arm_id: str, delta: np.ndarray, t_mono: float) -> np.ndarray: ...
        # delta = [dxyz(m), drotvec(rad), gripper, rail(m)] in canonical frame;
        # target = measured_pose ⊕ clamp(delta); returns joint targets via IK
    def apply_absolute(self, arm_id: str, pose: Pose, t_mono: float) -> np.ndarray: ...
        # abs/chunked policies: slew-limited approach toward pose

@dataclass(frozen=True)
class SlewLimits:
    lin_mps: float = 0.15      # blend-window cartesian speed cap
    ang_radps: float = 1.5
    rail_mps: float = 0.15
    window_s: float = 0.4      # slew window after human->policy handback (0.3-0.5)
```

Rules by policy action space (`CheckpointInfo.action_space`):
1. **`delta_ee` (canonical; required for new DAgger-intended policies).** Both
   human and policy emit per-tick deltas **applied to the current measured EE
   pose** (`target = currpos ⊕ Δ·scale`, then twin-gate clip — exactly
   hil-serl `franka_env.step`). Neither source carries an integrated setpoint
   across a switch → both directions jump-free by construction. The rail is
   one more delta dimension, clamped to [0, 0.65] m. The human twist
   integrator re-seeds from measured pose on takeover entry (`on_gate_event`).
2. **`abs_ee` / chunked (ACT, diffusion).** Policy→human: pending chunk
   **dropped immediately**; human deltas anchor to measured pose. Human→policy:
   **re-anchor + re-query** — `policy.reset()`, fresh chunk from the current
   observation, slew-limited execution toward it for `window_s` (0.3–0.5 s);
   after the window, raw chunk targets pass un-slewed (still twin-gated and ≤
   firmware per-tick step limits, <10 mm). Weight hot-swap obeys the same
   rule: never mid-chunk (§8).
3. **`joint`**: as `abs_ee` with joint-space slew (`max dq = 0.05 rad/tick`
   during the window).

A checkpoint carries `action_frame` + `action_space` in its manifest; the
runtime **refuses to start** a DAgger/inference session on a mismatch with the
session's dataset convention (`SessionError("policy/dataset frame mismatch")`,
runtime-local; 10-frames §5.3).

## 7. AsyncTrainer process

Separate OS process on **GPU 1**, crash-isolated from the servo loop.
**Spawn / monitor** (`runtime/dagger/client.py::AsyncTrainerClientImpl`):
`Popen([sys.executable, "-m", "apollo_mavis_v2_runtime.dagger.trainer",
"--config", cfg_path], env={**os.environ, "CUDA_VISIBLE_DEVICES": "1"})`; the
config JSON carries run_id, dataset roots, seed checkpoint, port, knobs below.
The client polls `proc.poll()` + the control socket (`{"cmd": "status"}`
REQ/REP, 1 Hz, 2 s timeout), republishing `TrainerStatus` into telemetry.
Teardown: `{"cmd": "stop"}` → graceful (finish burst, final checkpoint,
exit 0); SIGTERM after 30 s; SIGKILL after 45 s.

**Trigger (both conditions required):** an **episode boundary** — runtime
sends `{"cmd": "submit_episode", "summary": EpisodeSummary}` after every
`save_episode`, where `EpisodeSummary = {episode_index, n_frames,
n_intervention_frames, n_label_frames, takeover_segments, segment_doubts,
success}` (core §9, binding spelling) —
**and** `new_label_frames >= min_new_labels` (default **100**, cf. lerobot
`online_step_before_learning=100`). Then run one burst of
`K = clip(4 * new_label_frames, 200, 1000)` gradient steps (research §4.1)
and reset the new-label counter by the frames consumed.

**Sampling — 50/50 new vs aggregate** (`sampling.py::FiftyFiftySampler`):
each batch is half labels added since the last checkpoint ("new"), half from
the full aggregate = seed BC dataset ∪ all DAgger human-labeled frames
(lerobot `OnlineOfflineMixer`, `online_ratio=0.5`). Never train on only the
newest slice (forgetting; HG-DAgger trains on all of D). Data path: the live
dataset's parquet shard has **no footer until finalize** (lerobot research
§3.1), so after each `save_episode` the recorder also spools that episode's
non-video rows to `trainer_spool/ep_{index:06d}.parquet` (hil-serl
`demo_buffer/*.pkl` precedent); the trainer reads spool files + episode mp4s
(valid post-concatenation) read-only and keeps an in-RAM `LabelIndex`. It
never touches the LeRobot writer API.

**BC fine-tune loop sketch** (`trainer.py::BCFineTuner`):

```python
class BCFineTuner:
    def __init__(self, policy: torch.nn.Module, cfg: TrainerConfig) -> None:
        self.opt = torch.optim.AdamW(policy.parameters(), lr=cfg.lr,        # lr=1e-5 fine-tune
                                     weight_decay=cfg.weight_decay)         # 1e-4
    def burst(self, sampler: FiftyFiftySampler, k_steps: int) -> BurstStats:
        for _ in range(k_steps):
            batch = sampler.next(cfg.batch_size)        # 64; obs images decoded on GPU 1
            loss = self.policy.loss(batch)              # MSE (deterministic) / NLL (gaussian)
            loss.backward(); clip_grad_norm_(self.policy.parameters(), 1.0)
            self.opt.step(); self.opt.zero_grad()
        return BurstStats(mean_loss=..., n_steps=k_steps, nan_seen=...)
```

**Checkpoint layout & watermark** (`checkpoints.py::CheckpointStore`):

```
checkpoints/{run_id}/
  v{n:06d}/
    state_dict.pt            # weights ONLY (no optimizer) — what the runtime loads
    trainer_state.pt         # optimizer + counters, for trainer resume
    manifest.json            # CheckpointInfo (below) + sha256(state_dict.pt)
  LATEST                     # atomic pointer file: "v000012\n" (os.replace tmp->LATEST)
  LAST_KNOWN_GOOD            # pointer maintained by the RUNTIME (§8/§12)
  doubt.jsonl                # takeover-instant doubt log (HG-DAgger Eq. 4 input)
```

```python
@dataclass(frozen=True)
class CheckpointInfo:
    run_id: str
    version: int                       # monotonic within run
    path: str
    parent_version: int | None
    trained_on_frames: int             # dataset watermark: total label frames consumed
    trained_on_episodes: list[int]     # episode_index watermark
    action_frame: str                  # FrameRef: "arm_base:<id>" | "world" |
                                       #   "camera:<id>" (must match session)
    action_space: str                  # "delta_ee" | "abs_ee" | "joint"
    sanity_ok: bool
    mean_loss: float
    sha256: str
    created_wallclock_ns: int
```

Checkpoints are written after each burst, at most one per `push_period_s`
(default **5 s** — the hil-serl 50-steps / lerobot 4 s publish band);
`LATEST` advances only for `sanity_ok=True` versions.

**Sanity gate** (trainer-side, before advancing `LATEST`): (a) burst loss
finite, `nan_seen == False`; (b) forward pass on 256 held-out label frames →
all outputs finite; (c) per-dim actions within `[q01 - 3σ, q99 + 3σ]` of the
aggregate's `stats.json` quantiles. Failures write the version with
`sanity_ok=false` (kept for forensics) and training continues. The gate is
admittedly weak (research §5); the twin gate is the real safety net (§10).

**Rollback:** the trainer never rolls itself back. The runtime pins
`LAST_KNOWN_GOOD` (§12); on `{"cmd": "rollback", "version": v}` the trainer
reloads `v`'s `state_dict.pt` + `trainer_state.pt` and resumes, tagging the
next version's `parent_version = v`.

## 8. PolicyReloader (hot-swap)

`runtime/dagger/reloader.py::PolicyReloaderImpl` — the only code that changes live policy weights.

```python
class PolicyReloaderImpl:
    def __init__(self, policy: Policy, store: CheckpointStore,
                 session_action_frame: str, session_action_space: str) -> None: ...
    def poll(self) -> None:
        """1 Hz watcher thread: read LATEST; if newer sanity_ok version,
        verify sha256 + frame/space match, then stage()."""
    def stage(self, ckpt: CheckpointInfo) -> None: ...  # keeps ONLY the newest staged ckpt
    def maybe_swap(self, at_episode_boundary: bool,
                   current_mode: ControlMode) -> int | None:
        """Swap staged weights iff at_episode_boundary: policy.load_weights(path)
        under the policy lock (<100 ms; loop idle between episodes)."""
    def rollback(self) -> int:
        """Load LAST_KNOWN_GOOD now (allowed mid-episode: current weights are
        the emergency); notify trainer {"cmd": "rollback"}."""
    def mark_good(self) -> None:
        """Episode completed on current version, zero NaN ticks, no anomaly
        (§12) -> advance LAST_KNOWN_GOOD pointer."""
```

Rules (source-verified pattern, research §3.2/§4.2):

- **Advertisement** = filesystem: `LATEST` + `manifest.json` are the source of
  truth; the trainer also pushes a best-effort `{"event": "checkpoint",
  "version": n}` control-channel notice (poll latency ~0), but the 1 Hz
  poller alone is sufficient.
- **Staging** may happen any time; stale staged versions are dropped
  (drain-latest, like lerobot's `get_last_item_from_queue`).
- **Swap only at episode boundaries** — `DaggerSession` calls
  `maybe_swap(True, mode)` after `save_episode`/`clear_episode_buffer`, before
  arming the next episode; never mid-episode, never mid-chunk. The policy
  object is instantiated once; only `state_dict` bytes move
  (`torch.load(..., map_location="cuda:0")` + `load_state_dict`); no process
  restart, ever. After a swap, telemetry's `policy_version` becomes
  "{run_id}/v{n:06d}" and subsequent frames record the new int (§4).
- Inference mode constructs no reloader (fixed promoted checkpoint, §9).

## 9. Between-session round-based retraining

Online fine-tuning drifts (research §5); the promoted deployment artifact
comes from **round-based retraining from the aggregate** (HG-DAgger/IWR/
Sirius pattern), run offline between sessions:

```
apollo-dagger-retrain --run <run_id> --from {scratch|seed-checkpoint} \
    --weighting {uniform|iwr:<w>|sirius}          # v1 default: uniform
```

- Trains on the **full aggregate** — seed BC dataset (all frames) + every
  DAgger run's human-labeled frames (label mask, §5) — from scratch or
  warm-started from the pre-DAgger deployment checkpoint, never from an
  online-fine-tuned version (resets accumulated drift).
- Output: `checkpoints/{run_id}/deploy/v{k:03d}/` (same manifest schema,
  `parent_version=None`, watermark = full aggregate) + an eval report.
  Promotion is explicit: the operator registers the deploy checkpoint as the
  session seed policy; **inference sessions load only promoted deploy
  checkpoints**.
- Cadence (paper numbers): seed ~10k–20k BC frames; most benefit within 3–5
  rounds of ~1–2k human-labeled frames each (HG-DAgger §III-A, Sirius).
- `doubt.jsonl` is summarized here: τ = mean of the final 25% of
  takeover-instant doubts (HG-DAgger Eq. 4) — reported for risk-map analysis,
  not used for automatic gating in v1.

## 10. Safety interplay

Overview §6 invariant, restated because DAgger is where it is most tempting to
violate: **in hardware mode the twin gate is authoritative over BOTH the
policy and the human**, in every gate state. Per policy tick (per arm):

```
source action (policy | human) ──> canonical-frame delta/pose (§6)
  ──> ActionAnchor → IK (CollisionAvoidanceLimit rows active)
  ──> twin gate check on the COMMANDED q (clamp/hold + CollisionEvent)
  ──> servo stream (≤ firmware per-tick limits)
  ──> DaggerRecorder.add_frame(action = post-gate executed value)   # §4
```

- Takeover does **not** relax the gate: a panicking operator can command a
  collision as easily as a bad policy. Clamped human frames remain labels
  (the clamped action is what a safe expert "did").
- Sim mode: gate off by default; the `safety_debug` config runs the full
  hardware-mode stack against the sim workcell — how DAgger safety is
  CI-tested (§13).
- Twin-gate block streaks are an anomaly signal: ≥30 consecutive blocked
  policy ticks (~3 s) in AUTONOMOUS raises `PolicyAnomalyEvent` → UI banner
  suggesting takeover; with NaN detection it feeds rollback (§12).
- Drift/forgetting mitigations, layered: 50/50 aggregate mixing (§7), sanity
  gate + `LAST_KNOWN_GOOD` rollback (§7/§12), episode-boundary-only swaps
  (§8), between-session from-aggregate retrain (§9). None are safety features
  — the twin gate is; they protect label efficiency and progress.

## 11. UI protocol surface & metrics

All DAgger UI state rides existing channels: `ActionMsg` in
(`takeover_toggle`, episode ops), telemetry out. `DaggerStatus`
(`core.protocol`, inside `TelemetryMsg.dagger` at 20–30 Hz) — canonical shape,
mirrored by `05-ui.md` §2:

```python
class TrainerStatus(BaseModel):
    state: Literal["starting", "idle", "training", "dead"]
    steps_total: int
    last_burst_loss: float | None
    last_checkpoint_version: int | None
    last_checkpoint_ts: float | None      # server monotonic
    new_label_frames: int                 # accumulated since last burst (trigger progress /100)

class DaggerStatus(BaseModel):
    control_mode: Literal["policy", "human", "takeover_transition"]
    engaged_arm: str | None
    frozen_arms: list[str]
    policy_version: str | None            # "{run_id}/v{n:06d}"; updates only at swaps
    staged_version: str | None            # newer ckpt waiting for episode boundary
    episodes_labeled: int
    takeover_rate_ep: float               # human-frame fraction, current episode
    takeover_rate_run: float              # rolling mean, last 10 eps — operator's primary progress signal
    new_label_frames: int                 # mirror of trainer counter (UI meter)
    trainer: TrainerStatus | None         # None in inference mode
```

Inference mode: telemetry carries `dagger=None`; gate state travels in a
lightweight `inference: {control_mode, engaged_arm, policy_version}` field so
the UI renders "SAFETY ESCAPE (not recorded)" without recorder state.

UI obligations (`05-ui.md` DaggerPanel): control-mode chip, policy version +
"staged" badge, takeover-rate sparkline, new-label progress toward the
100-frame trigger, trainer state + loss, red banner on
`trainer.state == "dead"` or `PolicyAnomalyEvent`.

## 12. Failure handling & recovery

| Failure | Detection | Response |
|---|---|---|
| Trainer crash (OOM etc.) | `proc.poll() != None` or 3 missed status replies | Session continues with the **current frozen policy** (data collection is still valuable); `TrainerStatus.state="dead"` + UI banner; auto-restart once with `--resume` (trainer reloads `trainer_state.pt` of the newest version); if it dies again, stay degraded — never a third silent restart. |
| Corrupt checkpoint | `sha256` mismatch vs manifest, or `torch.load`/`load_state_dict` raises in `stage()`/`maybe_swap()` | Reject the version (log + telemetry warning), keep current weights, keep polling — the next version usually supersedes it. Never partially-applied: `load_state_dict` runs on a scratch copy of the state dict first. |
| NaN/Inf policy action | Per-tick guard in `GatedPolicyExecutor.step` before IK | Tick 1: hold arm (re-send current targets), record frame with `policy_action=NaN`. 3 NaN ticks in one episode: pause policy output (all arms hold), raise `PolicyAnomalyEvent`, UI prompts takeover; `reloader.rollback()` to `LAST_KNOWN_GOOD`; episode may be saved (human frames remain valid labels). |
| Anomaly streak (§10 block streak) | 30 consecutive twin-gate blocks in AUTONOMOUS | `PolicyAnomalyEvent` + suggest takeover; rollback only on operator action or NaN co-occurrence. |
| `LAST_KNOWN_GOOD` pointer maintenance | — | Advanced by `mark_good()` after each episode that completes on a version with zero NaN ticks and no anomaly event; initialized to the session seed checkpoint (v0). Rollback target therefore always exists. |
| Dataset writer failure (`save_episode` raises) | exception in recorder | Keep the episode buffer (do NOT `clear_episode_buffer`); retry once; on second failure mark session degraded (recording off), keep teleop/safety alive, surface error. `finalize()` is guarded by `VideoEncodingManager` + session-teardown `finally`. |
| Control-channel timeout but process alive | status timeout, `poll() is None` | Treat as trainer-busy (long burst); only 3 consecutive timeouts escalate to the crash path. |
| Runtime crash | — | Trainer detects the dead REQ peer only on next command; it keeps training to a final checkpoint, then exits after `orphan_timeout_s=120` without a status poll. Dataset is recoverable: LeRobot finalize-on-resume (`LeRobotDataset.resume`) after the parquet footers are rewritten by the recovery CLI (`apollo-dagger-fsck <dataset>` re-finalizes). |

## 13. Test strategy (hardware-free)

All tests are robot-free; hardware-mode safety paths run under sim `safety_debug` (overview §6).

1. **Gate unit tests** (`tests/dagger/test_gate.py`, pure logic, fake clock):
   scripted `(t, toggle/tick)` sequences → exact `ControlMode` timelines +
   `GateEvent` seq/source; TRANSITION auto-advance for `T_blend` ∈
   {0.2, 0.3, 0.5} s at 25/30 fps (frame-count assertions);
   abort-during-TRANSITION; per-arm exclusivity + Tab rejection while
   engaged; deadman-in-HUMAN holds state; episode-boundary reset.
2. **Scripted fake policy + fake human, full loop in sim**
   (`test_dagger_session.py`): `ScriptedPolicy` (deterministic deltas, NaN
   injectable at frame k) + `ScriptedHuman` (timed `KeysMsg`/`ActionMsg`
   script through the real WS bridge) drive a headless sim `DaggerSession`:
   3 short episodes, 2 takeovers. Assert on the written dataset: §4 feature
   dicts; `control_mode` runs match the script; `intervention ==
   (control_mode != 0)`; transition frame counts exact; `action` equals
   post-gate values (gate-clamp fixture under `safety_debug`);
   `policy_action` NaN exactly where scripted; `policy_version` constant
   within episodes, changes only after a staged swap; label-mask counts.
3. **Jump-free switching**: in sim, measure per-tick EE displacement across
   scripted switches in both directions (delta and chunked fake policies);
   no tick exceeds `SlewLimits` in the blend window; no discontinuity
   > firmware step limit ever.
4. **Toy-policy trainer integration** (`test_trainer_integration.py`,
   CPU-capable): 2-layer MLP, 8-dim synthetic delta task; 500-frame seed
   dataset + scripted "human" episodes following a known linear map. Spawn
   the real trainer process; assert: no burst before 100 new labels, burst
   after; `checkpoints/{run}/v000001..` with valid manifests + sha256; loss
   decreases; sanity gate flags a NaN-poisoned run (`sanity_ok=false`,
   `LATEST` not advanced); reloader swaps **only** via
   `maybe_swap(True, ...)`; rollback restores `LAST_KNOWN_GOOD` bit-exactly.
5. **Inference-mode fork**: same scripted inputs through `InferenceSession`;
   assert zero dataset files, zero trainer processes, gate telemetry
   present, Space toggling identical.
6. **Failure injection**: kill trainer mid-burst (frozen-policy degradation
   + single auto-restart); truncate `state_dict.pt` (corrupt-checkpoint
   rejection); scripted NaN policy (3-strike pause + rollback).

CI: 1, 2, 3, 5, 6 on every PR (sim + CPU); 4 CPU-mode on PR, GPU nightly.

## 14. Cross-references

Binding spine: `00-overview.md` §4–§6. Base schema + frames:
`10-frames-and-data.md`. Twin gate: `11-safety-collision.md`. Session engine:
`04-runtime.md`. UI panels: `05-ui.md` §8 (`DaggerStatus` shape per §11).
Research ground truth: `docs/research/dagger-online-training.md`,
`docs/research/lerobot-data.md`.
