# DAgger-family interactive imitation learning — protocol design for the apollo-mavis-v2 runtime

Research note, 2026-09-01.
Sources: Ross et al. 2011 (DAgger, arXiv 1011.0686), Kelly et al. 2019 (HG-DAgger, arXiv 1810.02890, full PDF read),
`rail-berkeley/hil-serl` (source read, incl. `examples/train_hgdagger.py`), `huggingface/lerobot` HIL-SERL port
(source read: `src/lerobot/rl/{actor,learner}.py`, `src/lerobot/processor/hil_processor.py`,
`src/lerobot/transport/services.proto`), Sirius (Liu et al., RSS 2023), IWR (Mandlekar et al. 2020).

---

## 1. TL;DR

- **HG-DAgger, not vanilla DAgger, is the right template.** The human holds full control authority during a
  takeover (no β coin-flip mixing); **only frames where the human is in control become training labels**
  (HG-DAgger Alg. 1 / Eq. 2; identical rule in `hil-serl/examples/train_hgdagger.py`).
- **When to retrain:** two proven patterns. (a) *Round-based*: retrain from the aggregate at round boundaries
  (HG-DAgger: 5 rounds × ~2k labels after 10k-label BC init; IWR/Sirius: ~3 rounds). (b) *Continuous async*
  (HIL-SERL/lerobot): a separate learner process takes gradient steps the whole time, publishes weights every
  ~50 optimizer steps (hil-serl `steps_per_update=50`) or every ~4 s (lerobot
  `ActorLearnerConfig.policy_parameters_push_frequency=4`), and **the actor swaps weights only at episode
  boundaries**. Recommend (b) for the live loop with an episode-boundary + min-new-samples trigger, plus (a)
  as an offline "hygiene" retrain between sessions.
- **How to retrain:** round-based systems retrain *from the aggregate* (fresh or warm-start — HG-DAgger trains
  π_{N,i+1} on all of D each epoch); the async systems *fine-tune continuously* and fight forgetting by
  sampling **50/50 from (new interventions+demos) vs (everything)** (lerobot `OnlineOfflineMixer`,
  `online_ratio=0.5`).
- **Action space:** use **delta EE actions applied to the current *measured* pose** for both human and policy;
  this is what makes human↔policy switches jump-free (hil-serl `franka_env.py:step` does
  `nextpos = currpos + Δ·scale` + safety-box clip). Record the **executed action, expressed in the policy's
  canonical per-arm frame** (hil-serl `RelativeFrame` even inverse-transforms the human's action into the
  policy frame before recording).
- **Data schema:** a per-frame `control_mode ∈ {policy, human, takeover_transition}` flag plus
  `policy_action` (what the policy *would* have done), `executed_action`, and `policy_version`. Practical
  systems store a boolean `is_intervention` per frame; Sirius additionally exploits the *pre-intervention*
  frames (the human implicitly labeled them "bad") — a 3-state flag lets us derive both.

---

## 2. The algorithms

### 2.1 DAgger (Ross, Gordon, Bagnell — AISTATS 2011)

Loop: roll out mixture π_i = β_i·π*(expert) + (1−β_i)·π̂_i; query the expert for the correct action at *every*
visited state; aggregate `D ← D ∪ D_i`; **retrain π̂_{i+1} by supervised learning on the entire aggregate D
every iteration** (from-scratch batch training is the canonical form — the theory is a reduction to a
no-regret online learner over the aggregated data). β_1 = 1, decays; in practice β_i = 0 for i > 1 often works.
Guarantee: cost degrades **O(T)** in horizon vs **O(T²)** for behavioral cloning.

Why raw DAgger fails with human experts on real robots (HG-DAgger §I, confirmed experimentally):

- The expert must provide labels **without being in control** → "perceived actuator lag" degrades label
  quality; with β=0 the human gets *no feedback at all* from their own inputs.
- Stochastic per-timestep switching (β coin flip) can destabilize the combined human+robot system
  (pilot-induced-oscillation analogy) and compromises safety while the novice is bad.
- In HG-DAgger's driving experiments, DAgger's learning curves *destabilize in later epochs* as β decays —
  they attribute it to degrading human label quality.

### 2.2 HG-DAgger (Kelly, Sidrane, Driggs-Campbell, Kochenderfer — ICRA 2019, arXiv 1810.02890)

The human is the **gating function**: the novice policy runs until the human judges the state unsafe, takes
control, guides the system back to a safe region, then **manually hands control back**. Rollout policy (Eq. 1):

```
π_i(x_t) = g(x_t)·π_H(x_t) + (1 − g(x_t))·π_N_i(o_t),   g(x_t) = 1[x_t ∉ P]  (human-controlled)
```

**What is recorded** (Eq. 2) — *only* the frames where the human has control:

```
D_i = { (O(x_t), π_H(x_t)) | g(x_t) = 1, x_t ∈ ξ_i }
```

Policy-controlled frames are **not** labeled/aggregated (no expert label exists for them in a pure IL setting).

**Algorithm 1 (verbatim structure):**

```
procedure HG-DAGGER(π_H, π_N1, D_BC):
    D ← D_BC                       # init with behavioral-cloning demos
    I ← []                         # intervention "doubt" logfile
    for epoch i = 1..K:
        for rollout j = 1..M:
            for timestep t in rollout j:
                if expert has control:      record expert labels into D_j
                if expert is taking control: record doubt into I_j     # at the takeover instant
            D ← D ∪ D_j;  append I_j to I
        train π_N,i+1 on D          # ← retrain at EPOCH boundary, on the full aggregate
    τ ← f(I)                        # learned risk threshold
    return π_N,K+1, τ
```

- **When/how to retrain:** "At the end of epoch i, D_i is added to the training data set D and the next
  novice policy is trained on the aggregated data." Epoch = M rollouts. Retraining is on the **full
  aggregate** (BC init data + all interventions so far), not on the new slice alone.
- **Training schedule used:** BC init on **10,000 expert labels**; then **5 epochs**, each accumulating
  **~2,000 additional expert labels** (intervention frames only). DAgger baseline used β=0.85 decayed ×0.85
  per epoch.
- **Risk metric ("doubt"):** novice = ensemble of NNs; C_t = covariance of ensemble outputs;
  `d_N(o_t) = ||diag(C_t)||₂` (Eq. 3). Doubt is logged **at the instant the human initiates a takeover**;
  threshold `τ = mean of the final 25% of the intervention-doubt logfile` (Eq. 4) — later interventions come
  from better-trained novices, so they are most relevant. τ is used post-hoc to map risky state-space regions;
  proposed future use: automatic gating.
- **Takeover UX on the test vehicle:** expert *takes* control by physically turning the steering wheel
  (input-activity gating) and *returns* control by **pressing a button** (explicit release).
- Caveat noted in the paper: HG-DAgger is unsuitable when the human cannot identify and react to unsafe
  situations quickly (footnote 1).

### 2.3 What round-based practical systems add (IWR, Sirius, robomimic tooling)

- **IWR** (Mandlekar et al. 2020, arXiv 2012.06733): humans monitor a policy remotely and take over at
  bottlenecks; iterative rounds; policies retrained on aggregated data with **intervention-weighted
  regression** — intervention samples are up-weighted relative to autonomous samples so the (fewer) correction
  labels are not drowned out. Their key empirical finding: intervention data beats an equal budget of full
  demonstrations.
- **Sirius** (Liu et al., RSS 2023, "Robot Learning on the Job"): deployment → data → **round-boundary policy
  update** → redeploy, evaluated over **3 rounds**; **weighted BC** where per-sample weights approximate
  "human trust": intervention samples up-weighted, and the frames *immediately preceding* an intervention are
  treated as implicit failure labels (down-weighted / pruned). They also do memory management (reject/prioritize
  samples; ~85% memory reduction) since the aggregate grows without bound.
- **robomimic** is the offline-training half of such pipelines (round-based retraining from HDF5 aggregates);
  it has no online loop of its own.

Takeaway: *round-based* systems all retrain from the aggregate between rounds (the aggregate is small enough
that from-scratch or warm-start retraining is cheap and avoids drift/forgetting debates entirely), and the
useful extra signal is **what happened right before a takeover**, which requires knowing per-frame who was in
control — hence the 3-state mode flag.

---

## 3. What HIL-SERL-style continuous systems actually do (source-verified)

### 3.1 `rail-berkeley/hil-serl` — `examples/train_hgdagger.py` (a literal online HG-DAgger)

Two processes connected by **agentlace** (`TrainerServer`/`TrainerClient`, TCP):

**Actor process** (owns robot env + policy copy):

```python
# examples/train_hgdagger.py (abridged)
actions = agent.sample_actions(observations=obs, seed=key)     # policy always proposes
next_obs, reward, done, truncated, info = env.step(actions)
if "intervene_action" in info:                                  # human moved the spacemouse
    actions = info.pop("intervene_action")                      # executed action := human action
    already_intervened = True
else:
    already_intervened = False
transition = dict(observations=obs, actions=actions, ...)
if already_intervened:
    data_store.insert(transition)          # ← ONLY intervention frames are streamed to the learner
    demo_transitions.append(copy.deepcopy(transition))          # + persisted to pkl for resume
...
if done or truncated:
    client.request("send-stats", {...intervention_count, intervention_steps...})
    client.update()                        # ← pull latest weights AT EPISODE BOUNDARY
```

**Learner process** (BC agent on GPU): pretrains **20k steps** (`--pretrain_steps`) on demos, then loops
forever: `batch = next(demo_iterator); agent.update(batch)` — i.e. **continuous fine-tuning** of the same
network on a buffer = initial demos + streamed interventions (uniform sampling; capacity 50k). It publishes
weights with `server.publish_network(agent.state.params)` every **`steps_per_update = 50`** gradient steps
(`examples/experiments/config.py`), checkpoints every `checkpoint_period`, and the actor also dumps its
intervention transitions to `checkpoint_path/demo_buffer/transitions_{step}.pkl` every `buffer_period` steps
so a crashed run resumes with its aggregate intact.

**Gating** (`serl_robot_infra/franka_env/envs/wrappers.py::SpacemouseIntervention`): *implicit, activity-based*
— intervention is active on any frame where `np.linalg.norm(expert_a) > 0.001` (deadband). No explicit
button for takeover; gripper via buttons. This works for a spacemouse (springs back to zero); for keyboard
teleop lerobot uses "any movement key held" (below).

**Action space / frames** (`serl_robot_infra/franka_env/envs/`):

- `franka_env.py::step`: `action ∈ [-1,1]^7` (Δxyz, Δrotvec, gripper); target =
  `currpos + xyz_delta * ACTION_SCALE`, rotation composed onto **current measured pose**, then
  `clip_safety_box(...)` before the servo command. Deltas-off-measured-pose ⇒ **no jump at control switch**
  in either direction, because neither controller carries an integrated setpoint.
- `relative_env.py::RelativeFrame`: observations and actions expressed in the EE frame; crucially, when the
  human intervenes it records `info["intervene_action"] = self.transform_action_inv(info["intervene_action"])`
  — **the human's action is converted into the policy's action frame before it is recorded**. This is the
  frame-consistency rule to copy.

### 3.2 `huggingface/lerobot` HIL-SERL port (`src/lerobot/rl/`)

Distributed **gRPC** actor/learner (`src/lerobot/transport/services.proto`):

```proto
service LearnerService {
  rpc StreamParameters(Empty) returns (stream Parameters);      // learner → actor weight stream
  rpc SendTransitions(stream Transition) returns (Empty);       // actor → learner experience
  rpc SendInteractions(stream InteractionMessage) returns (Empty); // actor → learner episode stats
  rpc Ready(Empty) returns (Empty);
}
```

**Actor** (`src/lerobot/rl/actor.py`): main loop `act_with_policy` + three helper threads/processes
(`receive_policy`, `send_transitions`, `send_interactions`) sharing `torch.multiprocessing.Queue`s. Policy is
instantiated on *both* sides; only `state_dict` bytes cross the wire. Per step:

- policy proposes; `InterventionActionProcessorStep` (`src/lerobot/processor/hil_processor.py`) overrides the
  action with the teleop action when `info[TeleopEvents.IS_INTERVENTION]` is set, and mirrors the *executed*
  action into `complementary_data["teleop_action"]`;
- the transition stored for the learner uses `action = executed_action` and
  `complementary_info = {"is_intervention": bool, "discrete_penalty": ...}` — **per-frame gating flag in the
  data**;
- on `done|truncated`: `update_policy_parameters(...)` drains the **latest** weights from the queue
  (`get_last_item_from_queue`, stale ones dropped) — i.e. **weight hot-swap happens only at episode
  boundaries**; the buffered episode is flushed to the learner; episode stats
  (`Episode intervention`, `Intervention rate`) are sent for logging.

**Learner** (`src/lerobot/rl/learner.py::add_actor_information_and_train`, single thread by design — GIL):

- `process_transitions(...)`: every incoming transition → online `ReplayBuffer`; **if
  `complementary_info["is_intervention"]` → ALSO appended to the offline/demo buffer** (learner.py:984-988).
  This is the HIL-SERL trick: human corrections join the demonstration distribution permanently.
- Training gate: `if len(replay_buffer) < cfg.policy.online_step_before_learning: continue`
  (default **100** transitions, `configuration_gaussian_actor.py`).
- `OnlineOfflineMixer(online_buffer, offline_buffer, online_ratio=cfg.online_ratio)` — default **0.5**
  (`src/lerobot/rl/train_rl.py`): every batch is 50% fresh online data, 50% demos+interventions.
- Weight publication: `push_actor_policy_to_queue(...)` when
  `time.time() - last_time_policy_pushed > policy_parameters_push_frequency` (**default 4 seconds**,
  `ActorLearnerConfig` in `src/lerobot/policies/gaussian_actor/configuration_gaussian_actor.py`).
- Checkpointing: `save_training_checkpoint(...)` every `save_freq` optimization steps — saves policy,
  optimizers, and **both replay buffers** (the aggregate), enabling resume with
  `load_training_state(...)`.

**Gating UX** (`src/lerobot/teleoperators/`): `TeleopEvents` enum (`utils.py`) =
`IS_INTERVENTION, SUCCESS, FAILURE, RERECORD_EPISODE, TERMINATE_EPISODE`. Gamepad: intervention while the
upper-right trigger is held (`gamepad.should_intervene()`); keyboard: **intervention = any movement key
currently pressed** (`teleop_keyboard.py::get_teleop_events`), i.e. activity-based like the spacemouse.
Success/terminate/rerecord are explicit buttons — these double as the episode-boundary and reward signals.

**Recording mode** (`src/lerobot/rl/gym_manipulator.py::control_loop`): in `record` mode the executed action
(`complementary_data["teleop_action"]`, falling back to the policy action) is what is written into the
`LeRobotDataset` `action` column; `RERECORD_EPISODE` clears the episode buffer. Action features for the
gamepad env are `["delta_x", "delta_y", "delta_z", "gripper"]` — same delta space as the policy.

### 3.3 Convergent design facts (the "what practical systems do" answer)

| Question | HG-DAgger (paper) | hil-serl `train_hgdagger.py` | lerobot HIL-SERL (RL) | IWR / Sirius |
|---|---|---|---|---|
| Who gates | human, explicit take/release | human, spacemouse deadband | human, trigger/keys held | human |
| What is recorded as labels | only human-controlled frames | only intervention frames streamed | all frames; intervention frames dual-routed to demo buffer | all frames, intervention-weighted |
| When retrain | epoch boundary (M rollouts) | continuous (async learner) | continuous (async learner) | round boundary (~3 rounds) |
| How retrain | from aggregate | fine-tune, uniform over demos+interventions | fine-tune, 50/50 online/offline mix | retrain from weighted aggregate |
| Weight handoff | between epochs | publish every 50 grad steps; actor pulls at episode end | push every 4 s; actor swaps at episode end | new policy per round |
| Warm start | BC on 10k labels | BC pretrain 20k steps | offline dataset → offline buffer | BC on demos |

---

## 4. Answers for the apollo-mavis-v2 stack

### 4.1 WHEN and HOW to retrain

Recommendation — a hybrid, matching both traditions:

1. **Live (within a session): continuous async fine-tuning, episode-gated swap.**
   - Trainer runs in its **own process on the second RTX 4090** (inference/render on GPU 0, training on
     GPU 1 via `CUDA_VISIBLE_DEVICES`), never blocking the ≥100 Hz servo loop or the ~10-30 Hz policy loop.
   - Trigger training-step bursts on **episode boundaries** with a **min-new-labels threshold** (e.g. start
     only after ≥100 recorded intervention frames, cf. lerobot `online_step_before_learning=100`; then after
     each episode run `K ≈ 200–1000` gradient steps, scaled to how many new frames arrived). A pure
     "N new samples" trigger also works but episode boundaries are when the actor can safely swap anyway.
   - Batches sampled **50/50: (interventions + seed demos) vs (full aggregate)** — for pure IL (no critic)
     the aggregate *is* the demos+interventions, so this reduces to "always mix old data in"; never train on
     only the newest slice (catastrophic forgetting; this is why HG-DAgger trains on all of D).
   - Publish a checkpoint at most every `T_push ≈ 4–10 s` *and* only after a sanity gate (finite loss,
     action-norm within bounds); the policy process swaps **only at episode boundaries** (or while
     `control_mode == human`), never mid-chunk for chunked policies (ACT/diffusion-style).
2. **Between sessions: round-based retrain from the aggregate** (HG-DAgger/IWR/Sirius style): retrain from
   scratch or from the pre-DAgger checkpoint on all data, optionally with intervention up-weighting and
   pre-intervention down-weighting (Sirius). This resets any drift accumulated by online fine-tuning and is
   the checkpoint you promote to "deployment".

Rules of thumb from the papers: seed with roughly 10k–20k BC frames (HG-DAgger used 10k labels ≈ ~30 min of
driving; hil-serl pretrains 20k gradient steps); expect most of the benefit within ~3–5 intervention rounds
of ~1–2k human-labeled frames each.

### 4.2 What the runtime protocol needs (evidence-backed)

- **Policy process with hot-swappable weights** — both hil-serl (`client.recv_network_callback(update_params)`
  + `client.update()` at episode end) and lerobot (`StreamParameters` → queue → drain-latest at episode end)
  instantiate the network once and swap `state_dict`s. Same-process `load_state_dict` under a lock is enough
  for us; no process restart.
- **Training worker as a separate process with its own GPU** — universal (agentlace TCP / lerobot gRPC).
  Being crash-isolated from the robot loop matters: a trainer OOM must not stop a 3-arm servo stream.
- **Dataset aggregation with durability** — lerobot checkpoints both replay buffers with the trainer state;
  hil-serl pickles intervention transitions every `buffer_period` steps. Our aggregate should be
  LeRobot-format episodes on disk (the same format as the data-collection mode), with the trainer keeping an
  in-RAM index; DAgger episodes append to a dedicated dataset, never mutate the seed dataset.
- **Checkpoint versioning** — monotonically increasing `version` per run
  (`checkpoints/{run_id}/v{n:06d}/`), with each version recording the **dataset watermark** (which episodes /
  frame count it was trained on) and the parent version. Every frame recorded during DAgger stores the
  `policy_version` that produced the policy action, so we can later attribute failures to a checkpoint.
  Keep `last_known_good` and support rollback.
- **Per-frame gating flag** — a boolean `is_intervention` is what lerobot/hil-serl store; we should store the
  3-state `control_mode: policy | human | takeover_transition` plus both actions (`policy_action` even when
  overridden — hil-serl discards it, but Sirius-style weighting and HG-DAgger-style doubt calibration need
  the policy's counterfactual and the takeover instants).

### 4.3 Action space and frames

- **Delta EE actions, applied to the current measured pose, shared by human and policy.** This is the
  hil-serl mechanism and directly matches our ~100 Hz cartesian servo streaming: the servo layer receives
  small pose increments off the last measured pose; when the gate flips, the source of increments changes but
  the reference (current pose) does not ⇒ no discontinuity. The rail axis is just one more delta dimension
  (clip to the 0.65 m travel exactly like hil-serl's `clip_safety_box`).
- **If a policy emits absolute poses or chunks** (ACT/diffusion): on human→policy handback, re-anchor — drop
  the stale chunk, query a fresh one from the current observation, and slew-rate-limit the first ~0.3–0.5 s
  toward the new trajectory. Policy→human is trivially smooth with delta teleop. Prefer delta/relative action
  parameterization for any policy intended for DAgger.
- **Frame consistency rule (copy `RelativeFrame`):** each arm has a **canonical action frame** chosen at
  data-collection time (`base` | `camera:<cam_id>`), stored in episode metadata. *Everything recorded as an
  action label is expressed in that frame*, including human corrections: the runtime converts the teleop
  device's frame into the canonical frame before both execution and recording
  (`transform_action_inv` precedent). A policy checkpoint carries its canonical frame in metadata, and the
  runtime refuses to run it on an arm configured with a different frame. Camera-frame actions additionally
  require the camera extrinsics snapshot to be stored with the episode.

### 4.4 Concrete minimal v1 protocol

**Core repo (`apollo-mavis-v2-core`)** — pure types + `typing.Protocol` interfaces, no I/O:

```python
# apollo_mavis_v2_core/dagger/types.py
from dataclasses import dataclass, field
from enum import Enum
import numpy as np

class ControlMode(str, Enum):
    POLICY = "policy"
    HUMAN = "human"
    TAKEOVER_TRANSITION = "takeover_transition"   # first T_blend frames after a switch

class ActionFrame(str, Enum):
    BASE = "base"          # arm base / world (incl. rail offset)
    CAMERA = "camera"      # requires camera_id + extrinsics in episode meta

@dataclass(frozen=True)
class GateEvent:                      # emitted on every mode change, per arm
    arm_id: str
    mode: ControlMode                 # new mode
    t_mono: float                     # monotonic clock
    seq: int
    source: str                       # "keyboard" | "gamepad" | "auto_release" | ...

@dataclass(frozen=True)
class FrameAnnotations:               # extra per-frame dataset columns during DAgger
    control_mode: ControlMode
    executed_action: np.ndarray       # canonical frame; this is the training label
    policy_action: np.ndarray | None  # counterfactual (None if policy not queried)
    policy_version: int               # checkpoint that produced policy_action
    action_frame: ActionFrame

@dataclass(frozen=True)
class CheckpointInfo:
    run_id: str
    version: int                      # monotonic within run
    path: str                         # weights dir (state_dict + preprocess stats + config)
    parent_version: int | None
    trained_on_frames: int            # dataset watermark
    action_frame: ActionFrame
    action_space: str                 # "delta_ee" | "abs_ee" | "joint"
    sanity_ok: bool                   # passed trainer-side gate

@dataclass(frozen=True)
class EpisodeSummary:                 # sent trainer-ward at episode end
    episode_id: str
    n_frames: int
    n_intervention_frames: int
    intervention_count: int           # number of takeover segments
    success: bool | None
```

```python
# apollo_mavis_v2_core/dagger/interfaces.py
from typing import Protocol
from .types import *

class TakeoverGate(Protocol):
    def mode(self, arm_id: str) -> ControlMode: ...
    def update(self, arm_id: str, teleop_active: bool, toggle_pressed: bool,
               t_mono: float) -> GateEvent | None:
        """Debounced state machine; returns an event iff the mode changed."""

class InterventionRecorder(Protocol):
    def start_episode(self, meta: dict) -> str: ...
    def add_frame(self, obs: dict, ann: FrameAnnotations) -> None: ...
    def end_episode(self, success: bool | None, rerecord: bool) -> EpisodeSummary: ...

class PolicyReloader(Protocol):
    def stage(self, ckpt: CheckpointInfo) -> None:
        """Called from the trainer-listener thread; keeps only the newest staged ckpt."""
    def maybe_swap(self, at_episode_boundary: bool, current_mode: ControlMode) -> int | None:
        """Swap staged weights into the live policy if safe; returns new version or None."""
    def rollback(self) -> int: ...

class AsyncTrainerClient(Protocol):
    def submit_episode(self, episode_path: str, summary: EpisodeSummary) -> None: ...
    def poll_checkpoint(self) -> CheckpointInfo | None: ...
    def request_stop(self) -> None: ...
```

**Runtime repo (`apollo-mavis-v2-runtime`)** — implementations and wiring:

- `TakeoverGate` impl: **explicit engage** (dedicated key/gamepad trigger *press* engages HUMAN; matches
  lerobot UX) with optional activity-engage (any teleop motion key, spacemouse-style deadband) as config;
  **explicit release** (key release or a "handback" key — HG-DAgger used an explicit button); on each switch
  the gate emits `TAKEOVER_TRANSITION` for `T_blend ≈ 0.2–0.5 s` worth of frames (these frames are recorded
  but flagged; excluded from labels by default — the human's first reactions are reflexive and the
  pre-switch frames are implicated as failures, per Sirius). Per-arm gates; a global "all arms" takeover key.
- `DaggerLoop` (per arm, at policy rate 10–30 Hz, riding on the 100 Hz servo): query policy → gate decides
  executed source → convert teleop action to canonical frame → clip via digital-twin safety layer → send to
  servo → `InterventionRecorder.add_frame(obs, FrameAnnotations(...))`. At episode end: write LeRobot-format
  episode, `submit_episode`, then `PolicyReloader.maybe_swap(at_episode_boundary=True, ...)`.
- `AsyncTrainer` process (GPU 1): watches the DAgger dataset dir + seed dataset; on `submit_episode`, if
  `new_label_frames ≥ min_new_labels` (default 100) runs `K` gradient steps with 50/50 sampling
  (new-round labels vs full aggregate; for v1 uniform-over-aggregate is acceptable — that is exactly
  hil-serl's HG-DAgger); every `push_period` seconds writes `checkpoints/{run}/v{n}/`, runs the sanity gate,
  and advertises `CheckpointInfo`. Transport for v1: **filesystem + a small ZeroMQ/gRPC control channel**
  (advertise/submit/stop) — we are single-machine, so weight transfer can be a path, not a byte stream
  (unlike lerobot's `StreamParameters`, which exists for multi-host).
- Loss: plain BC (MSE / NLL) on `executed_action` where `control_mode == HUMAN`. v1 does **not** train on
  policy-controlled frames (HG-DAgger Eq. 2); v2 options: IWR/Sirius weighting, or the lerobot RL route
  (SAC + reward classifier) reusing the identical transport and flags.

**Core vs runtime split:** core owns the enums/dataclasses above, the dataset schema extension
(`control_mode`, `policy_action`, `policy_version`, `action_frame` columns), and the Protocols; runtime owns
gate/recorder/reloader/trainer implementations and process management; hardware/sim repos are untouched (the
gate sits above the servo interface they already implement); UI subscribes to `GateEvent` + trainer metrics
(intervention rate per episode — the operator's primary progress signal, per lerobot docs) and renders a
per-arm mode badge.

---

## 5. Risks / open questions

- **Online fine-tuning drift:** continuous fine-tuning without the between-session aggregate retrain can
  degrade (loss of plasticity / overfitting to recent corrections). Mitigations: 50/50 old-data mixing,
  sanity gate + rollback, periodic full retrain. HG-DAgger's from-aggregate-each-round is the safe fallback.
- **Chunked policies:** ACT/diffusion policies emit multi-step chunks; takeover mid-chunk and weight swap
  mid-chunk both need explicit handling (drop chunk, re-query, slew-limit). hil-serl/lerobot sidestep this
  with single-step gaussian policies.
- **Keyboard as correction device:** HG-DAgger's label-quality argument assumes the human can actually steer
  well. Keyboard delta teleop at ~100 Hz is coarse; corrections will be lower-quality than spacemouse/leader
  arm. Consider a spacemouse for the DAgger operator even if keyboard remains for plain teleop.
- **Multi-arm gating:** with 2–3 arms one human can only correct one arm at a time. Per-arm gates imply the
  non-corrected arms keep running the policy; a "pause other arms on takeover" policy (freeze deltas at zero)
  is probably wanted and is trivially expressible in the gate.
- **Camera-frame policies:** if the canonical frame is a camera frame, any camera move invalidates the
  policy; extrinsics must be snapshotted per episode and checked at load time.
- **Sanity gate is weak:** finite-loss + action-norm checks won't catch a policy that confidently does the
  wrong thing; the digital-twin collision layer remains the real safety net and must stay authoritative over
  both human and policy actions.

## 6. Source index

- DAgger: arXiv 1011.0686 (Ross, Gordon, Bagnell, AISTATS 2011).
- HG-DAgger: arXiv 1810.02890v2 (Kelly et al., ICRA 2019) — Alg. 1, Eqs. 1–4, §III-A training schedule.
- `rail-berkeley/hil-serl`: `examples/train_hgdagger.py`, `examples/train_rlpd.py`,
  `examples/experiments/config.py` (`steps_per_update=50`, `training_starts=100`, `cta_ratio=2`),
  `serl_robot_infra/franka_env/envs/wrappers.py` (`SpacemouseIntervention`),
  `serl_robot_infra/franka_env/envs/relative_env.py` (`RelativeFrame`),
  `serl_robot_infra/franka_env/envs/franka_env.py` (delta action + `clip_safety_box`).
- `huggingface/lerobot`: `src/lerobot/rl/actor.py`, `src/lerobot/rl/learner.py` (buffer routing at
  L984-988), `src/lerobot/rl/gym_manipulator.py`, `src/lerobot/rl/data_sources/data_mixer.py`
  (`OnlineOfflineMixer`), `src/lerobot/processor/hil_processor.py` (`InterventionActionProcessorStep`),
  `src/lerobot/teleoperators/utils.py` (`TeleopEvents`),
  `src/lerobot/policies/gaussian_actor/configuration_gaussian_actor.py` (`ActorLearnerConfig`,
  `online_step_before_learning=100`, `policy_parameters_push_frequency=4`),
  `src/lerobot/transport/services.proto` (`LearnerService`), `docs/source/hilserl.mdx`.
- Sirius: arXiv 2211.08416 + ut-austin-rpl.github.io/sirius (3 rounds, weighted BC, memory management).
- IWR: arXiv 2012.06733 (intervention-weighted regression; interventions > equal-budget demos).
