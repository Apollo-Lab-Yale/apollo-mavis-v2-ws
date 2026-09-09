# 15 — PRO-DAgger: online interactive learning over the external policy interface

> **Superseded (2026-09-08 evening) by `15-online-dagger.md` v2.0.** The operator decided that
> the runtime keeps only an algorithm-agnostic *Online DAgger* shell (rollout control,
> take-over / hand-back API, novice-vs-expert labelling, generic trainer status) and that
> PRO-DAgger's iteration logic, hyper-parameters and reference-gradient artefacts live in the
> policy repo. This file is kept for history only; its §15 records the code that v2.0 replaced.

Status: **v1.0, binding for phase-14 (2026-09-08).** Written by the main agent from the
operator's 2026-09-08 request; decisions the operator did not make are marked
"main-agent decision" and are theirs to overturn. Spelling authority for wire ids stays
core `protocol/external.py`; for session / telemetry models core `protocol/session.py` /
`protocol/telemetry.py`; this document must agree with them (a disagreement is a bug in
whichever was edited last). Cross-references: 12-dagger (takeover gate, recording schema,
label rule), 14-dora (bus, external policy contract), 04-runtime §10 (recorder / datasets),
10-frames §11 (episode-directory store), 05-ui §8 (Cockpit / launcher).
**Amended 2026-09-08 (evening) — IMPLEMENTED in phase-14** (main working trees of core /
runtime / ui + the `apollo-mavis-v2-policy-node` checkout under `~/projects/apollo-mavis-v2-ws-p12/`,
uncommitted): §15 is the implementation record — the deviation table, the verified facts
(test counts, e2e wall time, the exact refusal strings, the REST routes) and the open items.
Sections touched in-body by that pass, v1.0 text kept and marked "Superseded": §4 (the
2026-09-08 review paragraphs were already there — session-id rule, swap criterion, Train now
refusals, resume, `SerialWorker`), §5 (the `_do_discard` fix landed), §6 (`ProDaggerConfig`
hardening, `DatasetLayoutInfo` order, the refusal strings as spelled), §7 item 1 / §9
(`SessionAnnounce.pro_dagger` is a six-field `ProDaggerAnnounce`, no `paths` object), §7 item 2
(cache layout), §8 (`ProDaggerStatus.session_dir` default, the history row's fields,
`ExternalStatus.capabilities` / `.trainer_status`), §10 (the UI as shipped), §11–§13 (modules and
tests as shipped). Where this document and the code disagreed, the code won and the deviation
is recorded here.
**Docs pass 2026-09-08 (late; code unchanged, verified against the working trees):** §4 the
`session.json` document as `to_session_json` actually writes it (v1.0 shape marked superseded)
and the `episode_discarded` publish scope (the coordinator is the ONLY publisher — PRO-DAgger
sessions only; 14-dora §4.2 corrected the same day); §9 likewise; §15.1 two new rows
(`session.json` shape, `episode_discarded` scope); §15.2 the wire bullet; §15.3 item 2 closed
(the shipped `contract.md` already states the session-id rule in both byte-identical copies),
item 11 added.

The reference implementation is the operator's `M4D-SC1ENTIST/pro-dagger` repo, branch
`prodg-lbm-anzu` (cloned at `/tmp/pro-dagger` on 2026-09-08; TRI/anzu specifics are not
ported). Its naming rule is kept: **"PGrad", "projected gradient", "reference gradient"
— never "A-GEM"**.

## 0. Operator decisions (2026-09-08, binding)

1. The landing page's middle mode (between Data Collection and Inference) is **PRO-DAgger**,
   online, following the reference repo's algorithm and functional structure.
2. The policy and its training live in **another repo, as a dora node**; the runtime exposes
   the interfaces PRO-DAgger needs; the policy repo calls them.
3. Clicking PRO-DAgger first shows **usage instructions and an agentic skill** that the policy
   repo's coding harness uses to set up the online training loop against the MAVIS runtime.
4. The PRO-DAgger launch panel configures: the **offline dataset** (whose reference gradient is
   cached), **epochs per iteration, rollouts per iteration, lr** and the other reference
   defaults, and **whether the online replay buffer is enabled** (aggregate every online expert
   sample across iterations vs. train on the current iteration only).
5. Online sessions **save their data** with the same idle / small-motion post-processing as
   demonstrations, and **every step carries one extra key: novice inference vs. expert
   demonstration**.
6. Data Collection asks for a dataset name before recording; datasets live in
   `$HOME/data/bc_demo/<name>`. PRO-DAgger asks for a session name; the session lives in
   `$HOME/data/pro_dagger/<session_name>/` with two sub-folders `ref_grad/` and `rollouts/`.
7. The UI follows the MAVIS design system (not the reference repo's UI), polished to the
   Emil-Kowalski / Apple bar already set by 05-ui.
8. (Same day, separate item.) The keyboard translate frame default becomes **`world`**
   (04-runtime §6; `camera` stays available).

## 1. Main-agent decisions (implementation follows these; the operator can overturn)

- **D1 Wire mode stays `dagger`.** Route `#/dagger`, `SessionSpec.mode: "dagger"`, the takeover
  gate, `TelemetryMsg.dagger` are unchanged; PRO-DAgger is `mode: "dagger"` +
  `policy_source: "external"` + a non-null `SessionSpec.pro_dagger` block. The user-facing name
  is "PRO-DAgger" everywhere a person reads it (launcher card, sheet, Cockpit title, keymap
  overlay). The legacy in-process path (`policy_source: checkpoint` + AsyncTrainer, 12-dagger
  §7) keeps working for tests and is not reachable from the launcher.
- **D2 The iteration state machine lives in the runtime**; **training lives in the policy
  node** (same process as inference, as in the reference — rollouts are paused while it trains,
  so sharing the GPU is free). The node tells the runtime what it is doing over ONE new input,
  `trainer_status`.
- **D3 Session directory** `$HOME/data/pro_dagger/<session_name>/`:
  `session.json` (runtime-owned), `rollouts/` (a standard MAVIS episode-directory dataset, repo
  id `pro_dagger/<session_name>`), `ref_grad/` (trainer-owned cache; the runtime only creates the
  directory and reports the trainer's view of it). Anything else the trainer writes (per-iteration
  checkpoints, logs) is its own business; the skill recommends `<session>/checkpoints/` and the
  runtime never reads it.
- **D4 Dataset roots become per-namespace.** `RuntimeConfig.datasets` gains a namespace → root
  map (§6); repo ids keep the `<ns>/<name>` grammar, so REST, the store, the export and the UI
  addressing do not change shape. `bc_demo/<name>` → `~/data/bc_demo/<name>`,
  `pro_dagger/<s>` → `~/data/pro_dagger/<s>/rollouts`, everything else → `<datasets_root>/<ns>/<name>`
  (the existing `var/datasets/apollo/...` data stays listable).
- **D5 The per-step key is a new column `actor`** (int8, `{0: novice, 1: expert}`, `actor = 1
  iff control_mode != policy`) added to every DAgger recording next to `control_mode` /
  `intervention` (which stay for merge-compatibility). Training labels are still
  `control_mode == human` (HG-DAgger Eq. 2, transition frames excluded) — `actor` is the
  operator's readable key, not a change of the label rule.
- **D6 Return-to-start applies to PRO-DAgger rollouts** (default ON, per-session opt-out, same
  twin-planned, gated, cancellable path as collect; 04-runtime §10.5). Between rollouts the arms
  go back to the start profile / initial condition. This is not the "blind return" 00-overview §4
  forbids for inference: dagger is recorded, planned and cancellable, and inference is untouched.
- **D7 Hardware stays refused for dagger** (`409 hardware sessions support teleop and data
  collection only`, 04-runtime §5). Admitting PRO-DAgger on the real cell is an operator go
  after a sim session has validated the loop; the change is one refusal-matrix line and is listed
  as the first follow-up.
- **D8 Hyperparameter defaults = the reference `SessionConfig` dataclass defaults** (sim
  recipe): R 5, epoch mode, 8 epochs, lr 1e-4, batch 8, PGrad on, g_ref EMA β 0.9, 32 reference
  batches, grad clip 1.0, current-iteration-only training (replay buffer OFF), unbounded FIFO,
  chunk stride 3, seed 0. The sheet's help text names the reference's real-robot preset
  (lr 2e-6, batch 16) so the operator can pick it.
- **D9 The skill is shipped by the runtime** (package data, served by REST) and mirrored
  byte-for-byte into the policy-node repo; the reference PGrad math ships in the policy-node
  repo as a small framework-agnostic module so a policy repo only implements the model hooks.
- **D10 Offline anchor is mandatory** (reference rule): the trainer must report the reference
  gradient cache `ready` before the runtime lets the first rollout start; the runtime refuses
  `episode_new` with a reason until then.

## 2. Roles and process picture

```
 operator ──keys/Vive──▶ mavis runtime (this stack)                policy node (policy repo)
                          ├─ takeover gate (Space)                  ├─ inference: obs_state ─▶ action
                          ├─ ProDaggerCoordinator (§4)              ├─ PRO-DAgger trainer (§7)
                          ├─ DaggerRecorder → rollouts/ (§5)  events▶│   ref_grad cache, PGrad update
                          ├─ session.json (§6)                       │   weight swap at iteration end
                          └─ telemetry.dagger.pro_dagger (§8) ◀trainer_status┘
```

The runtime owns the clock, the arms, the operator and the data; the node owns the model,
the reference gradient and the optimiser. The two never share a filesystem contract beyond
the session directory (the node reads `rollouts/`, writes `ref_grad/`).

## 3. The algorithm, as the runtime must support it (port of the reference)

Preserved (else it is not PRO-DAgger; reference `docs/VERIFIED_PG_PIPELINE.md`):

1. **Corrective-only labels**: only expert steps train (`actor == expert` ∧ `control_mode ==
   human`); the label is the operator's commanded action (the runtime's `action` column is the
   post-gate executed command — 12-dagger §4 — which is the MAVIS analogue of TRI's "record
   desired, never actual").
2. **Mandatory offline anchor**: a replay pool of (features, normalised target) pairs from the
   offline dataset; `g_ref` = mean flat gradient over a bounded random subset (`max_ref_batches ×
   batch_size` pairs) recomputed at each iteration start; per-step EMA (`β = 0.9`) toward one
   random replay-batch gradient; **project** `g ← g − (g·g_ref / ‖g_ref‖²) g_ref` when
   `g·g_ref < 0`; then `clip_grad_norm_(1.0)` and AdamW (0.9, 0.95, wd 1e-6). The replay pool
   never enters the training loss. `freeze_offline_gref` decides whether past interventions join
   the pool.
3. **Cleaning layer**: the runtime's idle-frame filter (10-frames §11.4; human frames only)
   plus the trainer's chunk-level `chunk_stride` (3) over kept chunks per intervention window.
4. **Iteration = R kept rollouts → blocking training (epoch mode: `n_epochs` over the pool;
   steps mode: `min(S, max(10, steps_per_batch · n_batches))`) → new weights act immediately**
   — never a swap mid-episode; a discarded rollout's samples are rolled back.
5. **Training pool**: `replay_buffer: false` = this iteration's expert samples only (reference
   default since 2026-08-20); `true` = accumulate every online expert sample (FIFO `max_demos`,
   0 = unbounded).
6. Seeded determinism, the `scale_check` std-ratio guard, no in-loop evaluation, no early stop,
   no keep-best, no weight EMA.
7. Metrics: per step `loss, projected`; per iteration `n_expert_frames (n_fire), n_proj,
   proj_rate, wall_s, train_steps, replay_size, roll_sr`.

Dropped: the LBM/CLIP feature cache machinery, S3, anzu bridge, pedals, tape interpolation,
method-rotation experiment, HG/DRIFT baselines.

## 4. Runtime: `ProDaggerCoordinator` (session-scoped, no motion of its own)

Lives in `apollo_mavis_v2_runtime/dagger/pro_dagger.py`, owned by `GatedPolicyExecutor` when
`spec.pro_dagger` is set. Pure state + publishing; never on the tick thread for I/O: events and
the session file both leave through the coordinator's own one-thread `SerialWorker` (events
keep their order, `session.json` never races itself), never on the tick or the recorder thread.

**Which trainer status counts (2026-09-08 review).** Only a `trainer_status` whose
`session_id` echoes THIS session's id drives a transition. A status for another session (the
previous session's heartbeats still in flight, the hub's cached status replayed when the
coordinator attaches) is ignored outright — it is not this session's trainer, so it neither
refreshes `trainer_alive` nor moves anything. A status with `session_id: null` (the trainer is
up, serving nobody yet) counts as alive and is shown verbatim, but drives nothing; while
`preparing` the refusal then reads `"reference gradient not ready (the trainer has not picked up
this session yet)"`. A status older than the newest one already seen is dropped (the attach
replay racing a fresh heartbeat), so the trainer view never runs backwards. Consequence for the
node: echo the announce's `session_id` in every status you publish while serving it (the
skill's contract says so), else the runtime never leaves `preparing`.

State: `iteration` (1-based), `rollout_index` (kept rollouts in this iteration, 0..R),
`phase ∈ {"preparing", "rollout", "training", "swapping", "error"}`, `episode_ids` of the
current iteration, `trainer` (last `TrainerStatusAnnounce`, with age), `policy_version_acting`.

Transitions:

- Session start → `preparing`. Leaves it when the trainer reports `ref_grad.state == "ready"`
  (and `state != "error"`) for THIS session → `rollout`, iteration 1. While `preparing`,
  `episode_new` is refused: `"reference gradient not ready (<detail>)"`; when no trainer status
  is fresh (≤ `dora.policy.spec_stale_s`): `"no PRO-DAgger trainer attached"`.
- `episode_new` while `rollout` → normal DAgger episode (policy drives, Space takes over).
- Kept rollout (`episode_save`) → `rollout_index += 1`; `events.episode_saved` gains
  `pro_dagger: {iteration, rollout_index, rollouts_per_iteration, episode_id, actor_counts:
  {novice, expert}, policy_version}`. If `rollout_index == R` (or the operator pressed **Train
  now** with ≥ 1 kept rollout) → publish `events.iteration_complete` (§9) → `training`. The
  same block is written to `episode.json["pro_dagger"]` BEFORE the video finalise; the
  coordinator reserves the slot then and files the episode by the same rule afterwards (a
  disagreement — the phase moved during the save — is logged, never silent). A save while
  the trainer is in `error` after a `rollout` outage still counts into the CURRENT iteration
  (the operator finished a rollout the policy started); if it fills the iteration,
  `iteration_complete` is published when the trainer recovers, never into the void. Only a
  save during `training` / `swapping` (`pause_while_training: false`) is carried into the
  next iteration.
- Discarded rollout → `events.episode_discarded {episode_index, episode_id, iteration, reason}`
  (the coordinator is the ONLY publisher of this kind — a non-PRO-DAgger session never
  announces a discard on the bus; 14-dora §4.2, corrected 2026-09-08); the counter
  does not move; the trainer drops anything it landed for that episode id. A rollout still
  open at **End session** is discarded the same way with `reason: "session teardown"`. On the
  executor a discard is the episode LEAVING `recording` / `saving` whatever follows — `idle`,
  or `returning` while return-to-start (D6) drives the arms back — and runs the same boundary
  as a save (gate reset, runner resume, `policy_reset(episode_boundary)`).
- `training`: `episode_new` refused `"training in progress (iteration k, epoch e/E)"`. Return-
  to-start still runs after the save that closed the iteration (arms park while it trains).
- Trainer reports `state == "ready"` with `iteration == k` (for this session) → `swapping`
  until the ANNOUNCED policy version — `PolicySpecAnnounce.policy_version` or an action's
  `policy_version` — differs from `policy_version_acting` → `rollout`, `iteration = k+1`,
  `rollout_index = 0`, `policy_version_acting` updated. The trainer's own `policy_version`
  claim never completes the swap (the acting policy is what the runtime hears on the spec
  heartbeat; a 2026-09-08 review dropped the earlier "OR trainer.policy_version equals the
  announced version" clause because it let a `ready` without a real swap open the next
  iteration on the old weights). The runtime also sends `policy_reset(reason=
  "episode_boundary")` (already at every boundary). A node that reports `ready` and never
  bumps its version leaves the UI in "waiting for the new policy" — that is the honest
  picture, surfaced with the age.
- Trainer `state == "error"` → `error` (rollouts refused with the detail; **End session** or
  the trainer recovering clears it: back to the phase it interrupted). Trainer status stale >
  `spec_stale_s` → `phase` keeps its value, `trainer_alive` false, banner.
- **Train now** = `ActionMsg{name: "pro_dagger_train_now"}` (new `ActionName`, no key binding;
  a Cockpit button). Refused while an episode is open (`"save or discard the episode first"`;
  the executor reads the recorder directly, so an `episode_new` handled in the same tick
  counts), with no fresh trainer (`"no PRO-DAgger trainer attached"`), while `preparing` /
  `training` / `swapping` / `error` (the phase's own reason), or with 0 kept rollouts
  (`"no kept rollout in this iteration yet"`).

`session.json` (`$HOME/data/pro_dagger/<s>/session.json`, rewritten atomically on every
transition, runtime-owned). Superseded (2026-09-08, docs pass) — v1.0 spelled it
`{session_name, created_at, session_id, task, spec: SessionSpec, paths: {rollouts, ref_grad,
offline_dataset}, iterations: [{iteration, episode_ids, n_expert_frames, n_novice_frames,
started_at, training: {started_at, finished_at, metrics}, policy_version_before,
policy_version_after}], current: {iteration, rollout_index, phase}}`. **As shipped
(`ProDaggerCoordinator.to_session_json`, `dagger/pro_dagger.py`; 10-frames §11.10):**
`{session_name, created_at, session_id, task, spec: SessionSpec | null,
paths: {session_dir, rollouts, ref_grad, offline_dataset, offline_dataset_dir}` (absolute
paths as strings; `offline_dataset` is the RESOLVED repo id, §15.1 "§6 offline repo id"),
`iterations: [{iteration, episode_ids, spool_paths, n_expert_frames, n_novice_frames,
started_at, training: {started_at, finished_at, metrics}, policy_version_before,
policy_version_after}]` (one entry per FINISHED iteration, appended when the swap completes),
`current: {iteration, rollout_index, phase, episode_ids, spool_paths, n_expert_frames,
n_novice_frames, started_at, training | null, policy_version_before, policy_version_acting,
carry: [{episode_id, spool_path, n_expert_frames, n_novice_frames}]}` (the in-flight
iteration in full — a resume needs its kept rollouts and the saves carried into k+1),
plus top-level `ref_grad_ready: bool`, `trainer: TrainerStatusAnnounce | null` (the last
status seen) and `last_used_at` (ISO, rewritten with the file — `GET /api/pro_dagger/sessions`
orders by it and reads `ref_grad_ready` without a coordinator).
A second session with the same name **resumes** it (`dataset_resume: true` on the rollouts
dataset; iteration continues from `current.iteration`; a training / swap that was in flight —
R rollouts, or fewer closed with **Train now** — is re-issued once the new trainer's anchor is
ready); `pro_dagger.resume: false` on an existing name is 409 `"PRO-DAgger session '<s>'
already exists - resume it or pick another name"`; `resume: true` with an unreadable
`session.json` is 409 `"PRO-DAgger session '<s>': session.json is unreadable - fix or remove
it"` — the file is the only record of the rollouts' iteration assignment and is never
overwritten by a fresh document. A bring-up that fails anywhere after the directory was
created (recorder, executor, a `start()`) removes a FRESH directory again, so the name stays
usable.

## 5. Recording: the rollouts dataset

`rollouts/` is a normal episode-directory dataset (10-frames §11) recorded by
`DaggerRecorderThread`: `manifest.json`, `episodes/<episode_id>/{episode.json, frames.parquet,
video/<cam>.mp4, audio.wav}`, `trainer_spool/ep_<episode_id>.parquet`, `sessions/`, `scenes/`.
The idle-frame filter applies (human frames only, 12-dagger §4 addendum); policy frames are
never dropped.

Additive per-frame column (12-dagger §4, `dagger_features()`):

```python
features["actor"] = {"dtype": "int8", "shape": (1,), "names": None,
    "info": {"labels": {"0": "novice", "1": "expert"},
             "derived_from": "control_mode != 0"}}
```

`SPOOL_COLUMNS` gains `actor`. `episode.json` gains `pro_dagger: {session_name, iteration,
rollout_index, policy_version, actor_counts: {novice, expert}, offline_dataset}` and
`EpisodeSummary` gains `n_expert_frames`, `n_novice_frames` (additive, defaults 0). The
export (LeRobot v3) carries `actor` automatically because it is in `manifest.features`.
`apollo_schema` (10-frames §8.2) is NOT bumped: additive column, only present in DAgger repos.

Fix on the way: `DaggerRecorderThread._do_discard` must accept `reason: str = ""` (the base
class calls it with one; today a DAgger save with zero kept frames raises `TypeError`).
**Landed (2026-09-08; §15):** `_do_discard(reason: str = "")` is in `dagger/recorder.py`; the
`actor` column is in `dagger_features()`, every DAgger frame, `SPOOL_COLUMNS` (appended last),
`EpisodeSummary.n_expert_frames` / `.n_novice_frames` (the former counts transition frames
too, unlike `n_label_frames`) and, through `manifest.features`, the LeRobot v3 export. The
`episode.json["pro_dagger"]` block is written only when a `ProDaggerCoordinator` is attached
(a plain external-DAgger run has the `actor` column but no block); a rollout still open at
teardown is discarded with `reason: "session teardown"` and announced (§4).

## 6. Configuration and paths

Core `SessionSpec` (additive):

```python
class ProDaggerConfig(BaseModel):
    """PRO-DAgger session parameters (15-pro-dagger §6). Validated for type / range here;
    honoured by the trainer node, which receives the whole SessionSpec in SessionAnnounce."""
    session_name: str = Field(pattern=SLUG_RE)          # $HOME/data/pro_dagger/<session_name>
    offline_dataset: str = Field(pattern=DATASET_RE)    # repo id, e.g. "bc_demo/pick_cube"
    resume: bool = False                                # existing session dir: continue it
    rollouts_per_iteration: int = Field(5, ge=1, le=100)            # R
    train_mode: Literal["epoch", "steps"] = "epoch"
    n_epochs: int = Field(8, ge=1, le=1000)
    steps_per_iteration: int = Field(200, ge=1)                     # S (steps mode cap)
    steps_per_batch: int = Field(10, ge=1)
    lr: float = Field(1e-4, gt=0)
    batch_size: int = Field(8, ge=1)
    replay_buffer: bool = False        # True = aggregate every online expert sample (the
                                      #   reference's train_current_iter_only == False)
    max_demos: int = Field(0, ge=0)   # FIFO cap of the aggregated pool; 0 = unbounded
    use_pgrad: bool = True
    gref_ema_beta: float = Field(0.9, ge=0, le=1)
    max_ref_batches: int = Field(32, ge=1)
    grad_clip: float = Field(1.0, ge=0)
    freeze_offline_gref: bool = False  # True = the g_ref pool stays offline-only
    offline_stride: int = Field(5, ge=1)  # every k-th offline frame seeds the pool
    chunk_stride: int = Field(3, ge=1)    # trainer-side cleaning over kept chunks
    chunk_horizon: int | None = Field(None, ge=1)  # None = the policy's own horizon
    seed: int = 0
    require_ref_grad: bool = True     # refuse rollouts until the trainer reports it ready
    pause_while_training: bool = True # refuse episode_new while the trainer trains
```

Validators: `pro_dagger` requires `mode == "dagger"` and `policy_source == "external"`;
`dataset` / `dataset_resume` must be None/False when `pro_dagger` is set (the rollouts repo id
is derived: `pro_dagger/<session_name>`); `return_to_start` is now a collect **or dagger**
field (the "collect-only" rule is relaxed to `mode in ("collect", "dagger")`).
`SessionInfo` echoes `pro_dagger: ProDaggerConfig | None`.

**As implemented (2026-09-08, core review; §15).** The listing above is the shape; the shipped
model is stricter: `model_config = ConfigDict(extra="forbid")` (an unknown hyper-parameter key —
`n_epoch`, `learning_rate` — is a 422, never silently the default), `session_name` carries
`max_length=64` and `offline_dataset` `max_length=128` (a directory the runtime itself creates
must not turn a 422 into `ENAMETOOLONG`), every float refuses inf / nan (`allow_inf_nan=False`
on `lr`, `gref_ema_beta`, `grad_clip`; likewise on `RefGradStatus.progress` and every
`TrainerStatusAnnounce` float incl. `scale_check` values — a `null` on the bus would poison every
`SessionAnnounce` of the session), and `seed` is `Field(0, ge=0, le=2**31 - 1)` (the reference
derives its generators as `RandomState(seed + <offset>)`, whose argument must stay below 2^32).
The three cross-field messages are spelled `"pro_dagger requires mode dagger"`, `"pro_dagger
requires policy_source 'external'"`, `"pro_dagger derives the rollouts dataset - leave dataset
unset"` and are evaluated BEFORE the older `"dataset is a collect-mode field"` rule; the relaxed
rule reads `"return_to_start is a collect / dagger-mode field"`.

Runtime `RuntimeConfig` (additive; `configs/mavis_v2.yaml` + `sim.yaml`):

```yaml
datasets_root: ${APOLLO_HOME}/var/datasets      # generic <root>/<ns>/<name>, unchanged
datasets:
  default_namespace: bc_demo                    # a bare `dataset: "<name>"` resolves here
  namespaces:                                    # namespace -> where its datasets live
    bc_demo:    {root: ~/data/bc_demo}                       # ~/data/bc_demo/<name>
    pro_dagger: {root: ~/data/pro_dagger, subdir: rollouts}  # ~/data/pro_dagger/<s>/rollouts
pro_dagger:
  skill_dir: null            # null = the package's shipped skill; a path overrides it
  session_file_hz: 1.0       # max rewrite rate of session.json outside transitions
```

`DatasetStore(root, *, default_namespace, namespaces)`: `resolve()` prefixes
`default_namespace`; `root_of(repo_id)` consults the map (`root/<name>/<subdir>` for a mapped
namespace, `datasets_root/<ns>/<name>` otherwise); `list()` globs the generic root AND every
mapped root; `DatasetInfo` gains `path: str` and `namespace: str`. New REST
`GET /api/datasets/layout → DatasetLayoutInfo{default_namespace, namespaces: {ns: {root,
subdir}}, generic_root}` so the UI shows the real folder (the sheet's preview) and never
hard-codes a namespace. Tests may keep `datasets_root=tmp/...` with `default_namespace="apollo"`
and no mapped namespaces (pinned by `make_runtime_config`), so the existing e2e expectations
hold; new tests cover the mapped layout.
Superseded in detail (2026-09-08) — the model spells `DatasetLayoutInfo{default_namespace,
generic_root, namespaces: {ns: DatasetNamespaceInfo{root, subdir}}}` in THAT order (the UI types
were generated from it); the `DatasetStore` constructor keeps `DEFAULT_NAMESPACE = "apollo"` and
a read-only `.namespace` alias, the runtime's effective default comes from
`RuntimeConfig.datasets.default_namespace` (`bc_demo`). Two store rules the design did not
state: `list()` SKIPS a directory that sits under the generic root in a namespace that is
MAPPED (`root_of` could never address it — every follow-up would 404; logged at DEBUG), and
`delete_dataset` prunes an emptied `<ns>` directory only under the generic root — a mapped
root (`~/data/bc_demo`) and a PRO-DAgger session directory (the rollouts' parent, next to
`ref_grad/` + `session.json`) are never removed by a dataset delete. `Runtime.start()` sweeps
`.tmp-*` episodes across the generic AND every mapped root.

PRO-DAgger session dir creation (at `POST /api/session`, before bring-up, no motion):
`~/data/pro_dagger/<s>/` + `ref_grad/` + `rollouts/` (mkdir -p), `session.json` written; the
offline dataset must exist, be an episode-directory layout (not `lerobot_v3` legacy) and have
≥ 1 episode → else 409 `"offline dataset '<id>' not found / has no episodes"`.
Superseded in detail (2026-09-08) — three separate 409s, spelled with the RESOLVED repo id:
`"offline dataset '<id>' not found"`, `"offline dataset '<id>' is a legacy lerobot_v3 tree"`,
`"offline dataset '<id>' has no episodes"`; `resume: true` on a missing name is 409
`"PRO-DAgger session '<s>' not found"`. The checks run in `SessionManager._check_pro_dagger`
AFTER the hardware refusal matrix (so hardware + dagger keeps the D7 line) and BEFORE
`_check_return_to_start`, in the order offline anchor → session directory → trainer; the
directories are created only inside the sim bring-up (`_build_pro_dagger`), never by a
refused request. Layout rule: the rollouts dataset is `DatasetStore.root_of("pro_dagger/<s>")`;
the session directory is its PARENT when the namespace maps a `subdir` (the shipped
`~/data/pro_dagger/<s>/rollouts`) and the dataset directory ITSELF when `pro_dagger` is not
mapped (tests pin `namespaces={}`: `session.json` + `ref_grad/` then sit next to `manifest.json`).
The coordinator is built from a copy of the config whose `offline_dataset` is the resolved id
(`demo` → `bc_demo/demo`), so `SessionAnnounce.pro_dagger`, `episode.json["pro_dagger"]`,
`iteration_complete.hparams` and `session.json["paths"]` spell a repo id; `SessionInfo.pro_dagger`
and `session.json["spec"]` keep the operator's raw body.

## 7. The trainer contract (what the policy repo implements)

The policy node process (14-dora §6; `mavis-policy-node`) adds a **trainer role**. It:

1. Consumes `session` (announce) — reads `spec.pro_dagger`, `pro_dagger.paths`
   (`session_dir, rollouts_dir, ref_grad_dir, offline_dataset_dir`) — and `events`.
   Superseded (2026-09-08) — there is no `paths` sub-object: `SessionAnnounce.pro_dagger` is a
   flat `ProDaggerAnnounce{session_name, session_dir, rollouts_dir, ref_grad_dir,
   offline_dataset, offline_dataset_dir}` in that order (core `protocol/external.py`; both
   contract goldens pin it). Non-null iff `spec.pro_dagger` is set; appended last.
2. On session start (announce with `pro_dagger` present, `state` RUNNING): **prepares the
   reference gradient** from `offline_dataset_dir` (episode dirs: `frames.parquet` rows with
   `actor` absent = all expert; `video/<cam>.mp4` frames if the model uses images), caching in
   `ref_grad_dir` (recommended: `registry.json` + `<cache_id>/pairs.pt` + `gref0.pt`, identity
   = (policy id, weights sha, offline dataset manifest `modified_at` + episode count,
   `offline_stride`)), publishing `trainer_status.ref_grad.state: building → ready` with
   progress. Any failure → `state: "error"`, `detail`. Superseded in detail (2026-09-08): the
   shipped cache (`mavis_policy_node.pro_dagger.pgrad.save_ref_grad` / `load_ref_grad`; the
   runtime's fake trainer writes the same layout) is `registry.json` keyed by identity at the
   `ref_grad_dir` root + `<cache_id>/gref0.npy` (numpy, torch-free save / load) +
   `<cache_id>/meta.json`; `pairs.pt` is optional and trainer-owned; `cache_id = sha256[:16]` of
   the identity; `weights_sha` hashes every torch dtype (bf16 included) via a `uint8` view.
3. On `events.iteration_complete {iteration, episode_ids, rollouts_dir, spool_paths, replay_buffer,
   hparams}`: loads the listed episodes (spool parquet is enough for state-only policies; the
   episode dirs for image policies), keeps rows with `control_mode == 1`, chunks (`chunk_horizon`
   or the model's), applies `chunk_stride`, trains per §3 with `trainer_status.state:
   "training"` updates (≥ 1 Hz: `epoch, n_epochs, step, n_steps, loss, n_proj, proj_rate,
   n_samples, replay_size, wall_s`), then swaps the weights into the acting policy, bumps
   `spec.version` / `policy_version`, writes a checkpoint (its choice of place), and publishes
   `state: "ready", iteration, policy_version`.
4. On `events.episode_discarded` drops any landed chunks for that `episode_id` (the runtime
   never publishes `iteration_complete` with a discarded id, so a stateless trainer can ignore
   this).
5. Heartbeats `trainer_status` at 1 Hz whenever it has anything to say (always while a
   PRO-DAgger session is announced), like `spec`, with `session_id` echoing the announce it
   serves — the runtime ignores a status that echoes another session and lets one with
   `session_id: null` count as alive only (§4), so a node that never echoes it leaves the
   session in `preparing`.

`TrainerStatusAnnounce` (core `protocol/external.py`, JSON on the new `policy/trainer_status`
output → runtime input `policy_trainer_status`, queue 8):

```python
class RefGradStatus(BaseModel):
    state: Literal["missing", "building", "ready", "error"] = "missing"
    progress: float = 0.0          # 0..1 while building
    n_pairs: int = 0
    cache_id: str | None = None
    path: str | None = None        # under ref_grad_dir
    detail: str = ""

class TrainerStatusAnnounce(BaseModel):
    mavis_schema: int = MAVIS_SCHEMA
    trainer_id: str                # e.g. "my-policy-repo/pro_dagger"
    node_version: str
    state: Literal["idle", "preparing", "training", "ready", "error"] = "idle"
    session_id: str | None = None  # echo of the announce it is serving
    iteration: int = 0             # iteration being / last trained
    policy_version: int = 0        # version the acting policy runs after the last swap
    ref_grad: RefGradStatus = RefGradStatus()
    epoch: int = 0
    n_epochs: int = 0
    step: int = 0
    n_steps: int = 0
    loss: float | None = None
    n_proj: int = 0
    proj_rate: float | None = None
    n_samples: int = 0             # expert samples in this iteration's pool
    replay_size: int = 0           # g_ref pool size
    train_buf: int = 0             # aggregated pool size (replay_buffer)
    wall_s: float = 0.0            # training wall time of the current / last iteration
    scale_check: dict[str, float] = {}   # std-ratio guard, when computed
    detail: str = ""
    uptime_s: float = 0.0
```

Metadata: the common inbound keys (`client`, `seq`, `t_mono`, `wallclock_ns`, `mavis_schema`).
Same `seq` counter as the node's other outputs (one per client).

## 8. Telemetry and REST (runtime → UI)

`DaggerStatus.pro_dagger: ProDaggerStatus | None` (additive):

```python
class ProDaggerStatus(BaseModel):
    session_name: str
    phase: Literal["preparing", "rollout", "training", "swapping", "error"]
    iteration: int
    rollout_index: int
    rollouts_per_iteration: int
    detail: str = ""                       # why episode_new is refused, trainer detail
    trainer_alive: bool = False            # a fresh trainer_status (<= spec_stale_s)
    trainer_age_s: float | None = None
    trainer: TrainerStatusAnnounce | None = None   # verbatim last status
    policy_version_acting: int | None = None
    expert_frames_iter: int = 0            # kept expert frames this iteration
    novice_frames_iter: int = 0
    session_dir: str
    history: list[ProDaggerIterationSummary] = []  # finished iterations (loss, proj_rate,
                                                   #   n_expert_frames, wall_s, policy_version)
```

Superseded in detail (2026-09-08; core `protocol/telemetry.py` wins): `session_dir: str = ""`
(defaulted, the coordinator always fills it) and the history row is
`ProDaggerIterationSummary{iteration, episode_ids, n_expert_frames, n_novice_frames, loss,
proj_rate, n_proj, train_steps, wall_s, policy_version_before, policy_version_after,
started_at, finished_at}` — the version BEFORE and AFTER the swap, not one `policy_version`.
`ProDaggerStatus` / `ProDaggerIterationSummary` ride `TelemetryMsg` `$defs` (not exported as
their own schema files); the executor rebuilds the block every `PD_STATUS_EVERY_N = 4` ticks
(25 Hz, the telemetry rate), never per 100 Hz tick. Two additive `ExternalStatus` fields the
runtime added for the launcher (14-dora §13, `telemetry.external`, session-less):
`capabilities: list[str] = []` (the FRESH spec's `PolicySpecAnnounce.capabilities`, `[]` when
no spec is fresh) and `trainer_status: TrainerStatusAnnounce | None = None` (the newest
`policy_trainer_status` while fresh, `None` once the node detaches or falls silent) — the
pre-launch "Trainer · <id> · pro_dagger · idle · ref_grad missing" pill reads them. With a
PRO-DAgger session running the verbatim 22-field status therefore rides every telemetry frame
twice (`external.trainer_status` and `dagger.pro_dagger.trainer`) — open item, §15.

`SessionTelemetry.trainer_alive` is set from the same freshness for PRO-DAgger sessions.
`history` rides every 25 Hz telemetry frame, so the runtime caps it to the newest 12 finished
iterations (`HISTORY_TELEMETRY_MAX`, rebuilt only when an iteration lands); the full record is
`session.json` (`iterations`) and the `GET /api/pro_dagger/sessions` row.

REST (additive, session-less): `GET /api/pro_dagger/skill` → `text/markdown` (the SKILL.md);
`GET /api/pro_dagger/skill.tgz` → the whole skill directory as a tarball (`SKILL.md` +
`references/`), so the install one-liner is
`curl -s http://<host>:<port>/api/pro_dagger/skill.tgz | tar xz -C ~/.claude/skills/`;
`GET /api/pro_dagger/sessions` → `list[ProDaggerSessionInfo{session_name, path, created_at,
task, offline_dataset, iteration, rollouts, ref_grad_ready, last_used_at}]` (reads `session.json`
files under the `pro_dagger` root; used by the sheet's resume picker); `GET /api/datasets/layout`
(§6).
`GET /api/dora` (existing) supplies the connection facts the instructions sheet prints.
(v1.0 spelled the sessions row `{…, iterations, rollouts, offline_dataset, task, ref_grad_ready}`;
the model — `iteration` (the one a resume would continue), `task` nullable, `last_used_at`
appended — is what is listed above since the 2026-09-08 review; rows are sorted newest
`last_used_at` first and a missing root lists nothing.) Status codes as shipped (`server/rest.py`):
`GET /api/pro_dagger/skill` 200 `text/markdown; charset=utf-8` or 404 `"PRO-DAgger skill not
found: <OSError>"` (an overridden `skill_dir` without a `SKILL.md`); `GET /api/pro_dagger/skill.tgz`
200 `application/gzip` with `Content-Disposition: attachment; filename="mavis-pro-dagger-trainer.tgz"`
(deterministic member order, rooted at `mavis-pro-dagger-trainer/`) or the same 404 — never an
empty tarball; `GET /api/pro_dagger/sessions` 200 (`[]` without a root); `GET /api/datasets/layout`
200, declared BEFORE `/api/datasets/{ns}/{name}` so the literal segment is never read as a
namespace (`/api/datasets/layout/x` is 404).

## 9. Wire additions (14-dora, additive, `mavis_schema` stays 1)

- `EVENT_KINDS` += `iteration_complete`, `pro_dagger_phase`; `episode_discarded` (declared) is
  now published — **in PRO-DAgger sessions only** (corrected 2026-09-08: the coordinator is the
  only publisher; a plain external-DAgger / collect session never emits it — 14-dora §4.2,
  §15.1). Payloads:
  - `episode_saved` (existing) + `pro_dagger: {...}` (§4).
  - `episode_discarded {episode_index, episode_id, iteration, reason}`.
  - `iteration_complete {iteration, session_name, episode_ids, spool_paths, rollouts_dir,
    ref_grad_dir, replay_buffer, hparams: ProDaggerConfig, n_expert_frames, n_novice_frames,
    policy_version}`.
  - `pro_dagger_phase {iteration, rollout_index, phase, detail}` on every transition.
- `PolicyResetReason` `"episode_boundary"` is actually spelled at boundaries (today both the
  handback and the boundary publish `"handback"`).
- `POLICY_OUTPUTS` += `trainer_status`; `RUNTIME_INPUTS` += `policy_trainer_status` (queue 8);
  the `policy` placeholder's declared outputs and the rendered dataflow follow;
  `dataflows/mavis_v2.example.dora.yml` regenerated; both `contract_golden.json` files and the
  policy-node `contract.py` updated in the same change.
- `SessionAnnounce.pro_dagger: {session_dir, rollouts_dir, ref_grad_dir, offline_dataset_dir,
  offline_dataset} | None`. Superseded (2026-09-08) — `ProDaggerAnnounce{session_name,
  session_dir, rollouts_dir, ref_grad_dir, offline_dataset, offline_dataset_dir} | None`, six
  fields in the model's order (the goldens pin it; §7 item 1). Also additive on the runtime →
  UI side: `ExternalStatus.capabilities` and `ExternalStatus.trainer_status` (§8).
- `PolicySpecAnnounce.capabilities: list[str] = []` — a trainer-capable node lists
  `"pro_dagger"`; the runtime's 409 at launch reads `"no PRO-DAgger trainer attached (the
  policy node does not report the pro_dagger capability)"` when the spec is fresh but the
  capability is missing, and `"no external policy attached"` when nothing is attached.

## 10. UI (05-ui amendment; the design system is binding)

**Launcher.** Card 3: icon `project` (new glyph: a vector and its projection onto a reference
line), label **PRO-DAgger**, description "Novice drives, you correct — trains between
iterations". Reasons: hardware tab → the existing teleop/collect-only reason; sim → "Set up and
start".

**PRO-DAgger sheet** (replaces the dagger LaunchSheet; `Sheet` width `wide`, two views with a
segmented step header, `data-view`):

1. *Connect a trainer* — status card: external policy chip (attached / stale / none), trainer
   pill (`pro_dagger` capability, `ref_grad` state), connection facts from `GET /api/dora`
   (bind host, daemon port, zenoh connect) each with a copy button; the **skill install**
   one-liner (copy button) and a disclosure "What the skill tells your coding harness" showing
   the SKILL.md text in a scrollable `pre`; a short numbered "how it works" (3 lines). The
   primary button is **Continue** (never gated — the operator may configure while the node
   attaches); a quiet caption says whether Start will be possible.
2. *Configure* — fields, in this order, grouped with `fieldset` legends:
   - **Session**: name (slug, required, autofocus) with live path preview
     `~/data/pro_dagger/<slug>`; if a session with that name exists, a "Resume iteration k
     (n rollouts)" pill and `resume` becomes true; a picker of existing sessions
     (`GET /api/pro_dagger/sessions`).
   - **Offline dataset**: radio rows from `GET /api/datasets` filtered to episode-dir layouts
     (default namespace first), each with episodes / frames / task; required. Task is prefilled
     from the dataset's newest session task; editable.
   - **Iteration**: rollouts per iteration (R), `SegmentedControl` epoch | steps, epochs (or
     steps + steps per batch).
   - **Optimiser**: lr, batch size; a quiet caption "Reference real-robot preset: lr 2e-6 ·
     batch 16 (bike study 2026-08-20)".
   - **Replay buffer**: check row "Aggregate every online expert sample across iterations
     (replay buffer)"; when on, `max_demos` input (0 = unbounded).
   - **Recording**: the existing idle-frame filter fieldset; the existing Return-to-start row
     (now available for dagger).
   - **Advanced** (`disclosure`): PGrad on/off, β, reference batches, grad clip, freeze offline
     g_ref, offline stride, chunk stride, chunk horizon, seed, require ref grad, pause while
     training; the per-arm frame selectors.
   Footer: Cancel / **Start PRO-DAgger** (disabled with the reason underneath: no trainer, no
   capability, name missing, dataset missing, task missing, hardware). 409 → in-sheet error.
   The sheet's `buildSpec` emits `policy_source: "external"`, `pro_dagger: {...}` (SI / raw
   units as the schema says), `action_filter`, `return_to_start`, no `dataset`.

**Cockpit (dagger mode)**: title "PRO-DAgger · <session_name>"; `ProDaggerPanel` replaces the
body of `DaggerPanel`:
- header row: **Iteration k** · rollout n / R (tabular numerals) · phase pill
  (`preparing` amber "PREPARING REFERENCE m %", `rollout` blue "ROLLOUT", `training` accent
  "TRAINING epoch e/E" with a thin progressbar, `swapping` amber "WAITING FOR NEW POLICY",
  `error` danger);
- the existing control-mode chip (POLICY DRIVING / HUMAN TAKEOVER / TRANSITION) and the
  external-policy chip;
- meters: loss (mono, last) with a 60-point sparkline canvas (per §5 rules: canvas via
  `useStore.subscribe` + rAF, never CSS-animated), projection rate, expert frames this iteration,
  replay / aggregated pool sizes, acting policy version (+ "swapped" flash on change, 240 ms,
  no bounce);
- history: one compact row per finished iteration (k · loss · proj % · expert frames · wall s);
- actions: **Train now** (primary quiet button; disabled with reason while an episode is open or
  training), `<kbd>Space</kbd> takeover`, `<kbd>N</kbd>/<kbd>Enter</kbd>/<kbd>Backspace</kbd>` hints
  via `codeForAction`;
- banner (`.banner-red` in `.cockpit-main`) when the trainer is dead / stale > 3 s / `error`.
- `EpisodeControls` shows "skipped N" (existing) and, in dagger, the actor split "expert e ·
  novice n" of the open episode. Superseded (2026-09-08): the wire carries only the
  ITERATION's kept counts (`expert_frames_iter` / `novice_frames_iter`), so the line reads
  "expert e · novice n (this iteration)".

**Data Collection sheet**: dataset name required (existing); the preview shows the REAL folder
from `GET /api/datasets/layout` (`~/data/bc_demo/<slug>`), not a hard-coded namespace.
**DatasetsPanel**: groups by namespace (Demonstrations `bc_demo` · PRO-DAgger rollouts
`pro_dagger` · Other), shows the folder path in the row's help text.

Motion: everything ≤ 240 ms, `--ease-out`, `@starting-style` enters, no `transition: all`, no
height animation; keyboard-initiated changes never animate; `prefers-reduced-motion` honoured;
status colours always paired with a word. Buttons press to `scale(.97)` under
`(hover:hover) and (pointer:fine)`.

**As shipped (2026-09-08; ui review fixes applied; §15).** `Sheet` takes a pixel width, so
"wide" = `PRO_DAGGER_SHEET_WIDTH` 640 px (the calibration wizard uses 620); the step header is a
compact `SegmentedControl` "1 Connect · 2 Configure" (tabs carry ids, both `tabpanel`s
`aria-labelledby`), both views stay mounted (`hidden`, no height animation). The trainer pill
reads the session-less `telemetry.external.capabilities` / `.trainer_status` (§8): "Trainer ·
<trainer_id> · pro_dagger | no pro_dagger capability · <state> · ref_grad <state>[ — detail]",
tone `warn` on a trainer / ref_grad `error`; "capability unknown (this runtime predates
telemetry.external.capabilities)" only when the field is absent. Start reasons (`REASON` in
`lib/launch.ts`, in `validateLaunch` order for the dagger branch after the common rules: name →
dataset → resume mismatch → first bad number → return target → trainer → capability → trainer
error): `sessionName` "Session name is required", `sessionNameTooLong` "Session name must be at
most 64 characters" (read from the schema's `maxLength`), `offlineDataset` "Pick an offline
dataset — its reference gradient anchors every update", `resumeMismatch` "This session was
started with another offline dataset — keep that one, or pick a new name", a per-field numeric
message "<label> must be <range>" (ranges READ from the vendored `ProDaggerConfig.json`; every
numeric field is judged, hidden-by-mode ones included, and `proDaggerToSpec` THROWS on an invalid
input instead of substituting a default), `returnNeedsProfile`, `noTrainer` "Attach a PRO-DAgger
trainer first (policy node with the pro_dagger capability)", `trainerNoCapability` "The attached
policy node does not report the pro_dagger capability — start it with a trainer",
`trainerError` "Trainer reports an error — fix the policy node first[: <detail>]". The dagger card
no longer depends on `WorkcellStatus.policies_available` (D1). The sessions list is re-read on
every view switch and after a 409, so the "already exists" refusal surfaces the resume pill. The
install one-liner uses the runtime's REAL origin: the page origin in production, the Vite proxy
target only under `vite serve` (`__APOLLO_RUNTIME_PROXY__` is `undefined` in builds and
`scripts/check-dist.ts` fails `npm run build` if `localhost:8765` or the dev-proxy note leaks into
`dist/`). Cockpit: `newRolloutReason(pd)` (the telemetry `detail`, else `PHASE_BLOCK_REASON`) is
shared by Train now, the `N` hint (greyed, `aria-disabled`) and `EpisodeControls.newEpisodeReason`,
so **New episode is disabled with its reason** whenever the runtime is guaranteed to refuse
`episode_new` (preparing / training / swapping / error); the panel's history shows the last
`HISTORY_ROWS = 6` finished iterations (the wire carries 12, `session.json` all); an observer
sees "observer — another client controls this session" (`readOnly`), not "control link down";
the Train-now ack toast shows the runtime's detail ("training iteration k on n rollouts") or
"Training now — the iteration closes with the kept rollouts"; the banner reads "PRO-DAGGER
TRAINER ERROR — <detail>" / dead / stale > `TRAINER_STALE_S` 3 s; the "swapped" pill stays
`SWAPPED_NOTE_MS` 1200 ms, opacity only; the sparkline grid colour comes from `--border`.
`DatasetsPanel` groups Demonstrations = `layout.default_namespace` (fallback `bc_demo` while the
layout is unknown; group key `demos`) · PRO-DAgger rollouts `pro_dagger` · Other; the collect
sheet previews `…/<slug>` and "the runtime's default dataset folder" until `GET /api/datasets/
layout` answers, then the real folder — the stale `DATASET_NAMESPACE = "apollo"` constant is gone.

## 11. The skill (`apollo_mavis_v2_runtime/pro_dagger/skill/`)

```
SKILL.md                    # frontmatter: name: mavis-pro-dagger-trainer, description
references/contract.md      # wire spellings, message schemas, state machine, dataset layout
references/algorithm.md     # PGrad recipe, defaults, pitfalls, acceptance checklist
```

SKILL.md tells a coding harness in the policy repo, step by step: install `mavis-policy-node`
(with the `pro_dagger` extra), implement the `Policy` protocol (already documented in that repo)
and the `ProDaggerTrainer` protocol (`prepare_reference(offline_dir, ref_grad_dir, hparams,
progress) -> RefGradState`, `train_iteration(request, ref_grad, progress) -> IterationResult`,
`swap_weights() -> int`), reuse `mavis_policy_node.pro_dagger.pgrad` (flatten / EMA / projection
/ AdamW step) and `mavis_policy_node.pro_dagger.datasets` (episode-dir reader with the
`actor` / `control_mode` masks and chunking), run `mavis-policy-node --loader entrypoint
--entrypoint pkg:make_policy --pro-dagger pkg:make_trainer --daemon-port <Q>`, and test
against the fake runtime harness before touching the lab (`mavis-policy-node --selftest
pro-dagger`). It ends with the acceptance checklist (the runtime shows `ref_grad ready`, a
rollout saves with `actor` counts, `iteration_complete` produces `training` → `ready` and a
version bump the runtime observes). The same directory is mirrored to
`apollo-mavis-v2-policy-node/skills/mavis-pro-dagger-trainer/`.

As shipped (2026-09-08): `SKILL.md` §1 Prerequisites (`pip install "mavis-policy-node[pro_dagger,
torch]"`, `curl -s http://<lab-host>:8765/api/dora` — the runtime's REST port, not 8000), §2
`Policy`, §3 `ProDaggerTrainer` + a complete minimal torch example (state-only MLP) that trains a
DEEP COPY of the acting module and installs it in `swap_weights` under the policy's lock — the
in-place shortcut is documented as valid ONLY while `pause_while_training` is true —, §4 Run the
node, §5 Test before touching the cell (pre-launch the sheet shows only the attached policy +
capability; `ref_grad ready` first appears in the Cockpit's PREPARING REFERENCE pill after Start),
§6 Acceptance checklist; `references/contract.md` §1–§6 (streams, the five messages, the state
machine, the hparams dict, the dataset layout, every refusal) and `references/algorithm.md`
§1–§4. `cmp` of the three files against the policy-node mirror: identical (a runtime test,
`tests/test_pro_dagger_package.py::test_skill_mirror_in_the_policy_node_repo_is_byte_identical`,
enforces it when the mirror is checked out). The wheel ships the directory as package data
(`importlib.resources`); `RuntimeConfig.pro_dagger.skill_dir` overrides it.

## 12. Policy-node repo additions (`apollo-mavis-v2-policy-node`)

`mavis_policy_node/pro_dagger/`: `messages.py` (build / validate `TrainerStatusAnnounce`),
`protocol.py` (`ProDaggerTrainer` duck type, `IterationRequest`, `IterationResult`,
`RefGradState`), `loop.py` (`ProDaggerLoop`: consumes `session` + `events`, drives the trainer
on a worker thread, publishes `trainer_status` at 1 Hz and on change, handles discard / resume,
never blocks the node's `act()` path except while `pause_while_training` is on — then `act()` is
not called because the runtime stops rollouts), `datasets.py` (reads MAVIS episode dirs:
`frames.parquet` via pyarrow, optional mp4 decode via `av`, masks, chunk windows with stride and
padding at handback), `pgrad.py` (torch, imported lazily: `flat_grad`, `RefGradEMA`,
`project`, `pgrad_step`, `save/load_ref_grad`), `fake.py` (`FakeTrainer`: numpy-only, sleeps
`per_epoch_s`, fabricates loss / proj_rate, bumps the fake policy's version — the e2e stand-in
for both repos). CLI: `--pro-dagger <fake|pkg:make_trainer>`, `--selftest pro-dagger`.
`contract.py` constants + `tests/golden/contract_golden.json` updated; tests for the loop
against the repo's private-control-plane harness.

As shipped (2026-09-08): no separate `pro_dagger/messages.py` — `build_trainer_status`,
`trainer_status_announce`, `ref_grad_status` and the validators live in the top-level
`messages.py` / `contract.py` (as the other wire builders do) and are re-exported from
`mavis_policy_node.pro_dagger`; `pgrad.py` adds `ReferenceSubset(seed).indices(n_pool, cap)` (one
RNG per session, one draw per pool state), `pgrad_iteration` (epoch + steps modes),
`reference_gradient`, `scale_check`, `weights_sha`, `save_ref_grad(ref_grad_dir, identity, *,
g_ref, n_pairs, meta, arrays) -> RefGradState` / `load_ref_grad(dir, identity)` / `load_gref`
(§7 item 2 layout); `datasets.py` adds `dataset_identity`, `mask_windows`, `decode_video_frames`
(lazy `av`) and `IterationRequest.spool_paths` stays index-aligned with `episode_ids` (`""`
placeholder); `synthetic.py` (episode-dir datasets with real Arrow types) and `selftest.py`
(`--selftest pro-dagger`: states `idle → preparing → ready → training → ready → idle`, version
1 → 2, a discarded id dropped) exist; `loop.py` starts preparing only on a `running` announce
with the block, keeps the context across same-id `recovering` / `fault` announces
(`PRE_RUNNING_STATES = ("bringup", "start_from")`, `ENDING_STATES = ("idle", "teardown")`),
drops `iteration_complete` / `episode_discarded` for another session id, echoes the served
`session_id` in every status, and an `iteration_complete` whose every episode was discarded
publishes `ready` (iteration k, current version) without training. `node.py`: `PolicyNode(...,
trainer=None)`, statuses queued by the worker and sent on the node thread (`_pump_trainer`, the
first pump after an attach sends only the newest), undeclared `trainer_status` output detected
from `node_config()` and dropped with one warning. CLI `--pro-dagger <fake|pkg.mod:make_trainer>`
(factory `make_trainer(policy=, path=, device=)`), `--selftest pro-dagger`. Extras `pro_dagger =
["pyarrow>=17"]`, `video = ["av>=12"]`, `torch`; CI installs `.[dev,pro_dagger]` + CPU torch so
the PGrad tests run there. The runtime's own fake node (`dora_bridge/nodes/fake_policy.py`) gained
the same trainer role (`FAKE_TRAINER=1` or `--trainer`; knobs `FAKE_TRAINER_PREPARE_S` 0.5 s,
`FAKE_TRAINER_EPOCH_S` 0.2 s, `FAKE_TRAINER_FAIL_AT_ITER`, `FAKE_TRAINER_FAIL_PREPARE`; a plain
fake announces `capabilities: []`) for the sim e2e (§13).

## 13. Tests (hardware-free)

- core: `ProDaggerConfig` defaults / ranges / cross-field rules; `SessionInfo` echo; schema
  export; `actor` labels; `EVENT_KINDS` / `RUNTIME_INPUTS` / goldens.
- runtime unit: `ProDaggerCoordinator` state machine (R rollouts → `iteration_complete`; discard
  does not count; Train now; resume from `session.json`; trainer `ready` + version bump → next
  iteration; refusals' reasons); `DatasetStore` mapped namespaces (`root_of`, `list`, layout REST);
  session dir creation + 409s; `actor` column in parquet and spool; `_do_discard(reason)`.
- runtime e2e (sim, `tests/dora_bridge/test_e2e_pro_dagger.py`, marker `dora`): the fake node
  in trainer mode; POST a PRO-DAgger session; assert `preparing` → `rollout` after the fake
  reports `ref_grad ready`; drive 2 kept rollouts (R = 2) with one takeover each and one discard;
  assert `iteration_complete` payload, `training` → `ready` → iteration 2 with the new version,
  `session.json` content, `rollouts/episodes/*/frames.parquet` has `actor` with both values,
  `events.episode_discarded` seen, `episode_new` refused while training with the documented
  reason, return-to-start ran (episode state walked `returning`).
- ui: `launch.test` (buildSpec exact body, validation reasons), `ProDaggerSheet.test`
  (two views, copy buttons, gating reasons, 409 in sheet), `ProDaggerPanel.test` (phase pills,
  meters, Train now ack path, banner), `DatasetsPanel.test` (groups + path), Landing string
  assertions, `gen:check`, `tsc`, eslint, prettier.
- policy-node: `FakeTrainer` loop against the harness (ref grad → iteration → status
  sequence), `pgrad` math (projection zeroes the negative component, EMA), dataset reader on a
  synthetic episode dir, contract golden.

As shipped (2026-09-08; counts in §15): core `tests/test_protocol.py` / `test_schema_export.py` /
`test_dagger_types.py`; runtime `tests/dagger/test_pro_dagger_coordinator.py` (30 cases: exact
payloads, discard, Train now, ready + bump, never-bumps stays `swapping`, stale, error,
save-during-error incl. recovery hand-over, session-id rule, older-status drop, resume ×3 incl.
the Train-now re-issue, history cap, `scan_sessions`, `SerialWorker`, atomic writer),
`tests/dagger/test_executor.py` (coordinator gating, `episode_boundary` vs `handback`, the discard
boundary under return-to-start with a held takeover, same-tick `episode_new` + `train_now`),
`tests/dagger/test_recorder_schema.py` (actor column, teardown announces the open episode),
`tests/test_pro_dagger_session.py` (a real sim server + fake dora wiring + real `ExternalPolicyHub`:
lifecycle, a failed fresh bring-up removes its directory, an unreadable `session.json` is refused
twice and never overwritten, a `start()` failure rolls the bring-up back),
`tests/test_pro_dagger_package.py` (package data, tarball rooted at the skill name, mirror
byte-identity, config block), `tests/test_dataset_layout.py` (mapped roots, `list()` across roots,
delete keeps mapped roots, sweep, `GET /api/datasets/layout`, a real collect session into
`bc_demo/<name>`), `tests/test_server_contract.py` (+5 routes / 409 matrix / nack),
`tests/dora_bridge/test_external_status.py`, `test_policy_source.py` (+2), `test_return_manager_units.py`
(+1, D6 through the real loop) and the sim e2e `tests/dora_bridge/test_e2e_pro_dagger.py` (markers
`dora` + `egl`; `test_409_matrix_before_any_trainer`, `test_pro_dagger_iteration_over_the_bus`,
`test_skill_endpoints_are_session_less`); `tests/dagger/test_e2e_dagger.py` and
`tests/dora_bridge/test_e2e_external_policy.py` pin `return_to_start: False` (D6 made the default
ON for dagger and they have no initial-condition profile). ui: `launch.test.ts`,
`ProDaggerSheet.test.tsx`, `ProDaggerPanel.test.tsx`, `DatasetsPanel.test.tsx`,
`EpisodeControls.test.tsx`, `runtimeOrigin.test.ts`, `Landing.test.tsx`, `cockpit.smoke.test.tsx`
(a PRO-DAgger session case, preparing / training gating, the ok ack toast). policy-node:
`tests/test_pro_dagger_pgrad.py` (torch; 14), `test_pro_dagger_datasets.py`, `test_pro_dagger_loop.py`,
`test_node_e2e.py::test_pro_dagger_trainer_end_to_end` (real private control plane).

## 14. Follow-ups (not in phase-14)

1. Admit PRO-DAgger on hardware (D7) after the first sim session — one refusal-matrix line in
   `SessionManager._validate_hardware` and 05-ui `REASON.hardwareTeleopOnly`.
2. `weights_reload` / `weights_ack` (14-dora reserved) so the runtime can pin `LAST_KNOWN_GOOD`
   for external trainers.
3. Per-iteration success marking (the reference's GOOD/BAD pedals): today every kept rollout is
   `success: null`; a Cockpit toggle at save time would fill `episode.json.success` and
   `roll_sr`.
4. An out-of-process dora bridge (14-dora §16.2 open problem) — unchanged by this design.

## 15. Implementation record (phase-14, 2026-09-08)

Everything in §0–§13 is implemented as written unless listed here. Read the code, not the
design, for the shape of what ships: core `protocol/{session,telemetry,external,control}.py`
+ `dagger/types.py`; runtime `dagger/pro_dagger.py` (coordinator), `dagger/loop.py`,
`dagger/recorder.py`, `recorder/datasets.py`, `session/manager.py`, `server/rest.py`,
`server/ws_telemetry.py`, `dora_bridge/{wiring,policy_source,publishers,dataflow}.py`,
`dora_bridge/nodes/fake_policy.py`, `config.py`, `configs/{mavis_v2,sim}.yaml`,
`pro_dagger/skill/`; ui `components/ProDagger{Sheet,Panel}.tsx`, `lib/launch.ts`,
`lib/streams.ts`, `pages/{Landing,Cockpit}.tsx`; policy-node `mavis_policy_node/pro_dagger/*`,
`skills/mavis-pro-dagger-trainer/`. The work is UNCOMMITTED in the five sub-repos' working
trees (on top of the merged phase-12 + phase-13 trees, 14-dora §16) and in the policy-node
checkout at `~/projects/apollo-mavis-v2-ws-p12/apollo-mavis-v2-policy-node`; nothing was
exercised on the real cell or the lab dora plane (sim + fake trainer only; the runtime must be
restarted to pick any of it up).

### 15.1 Deviations from v1.0 and why

| Item | v1.0 said | Implemented | Why |
|---|---|---|---|
| §4 swap criterion | `swapping` ends when the announced version differs from the acting one **or** `trainer.policy_version` equals the announced spec version | only the ANNOUNCED version (`policy_spec` heartbeat or an action's `policy_version`) `!= policy_version_acting` completes the swap; the trainer's own claim never does | taken literally the second clause completed the swap immediately for a `ready` without a version bump (both equal the acting version) — the next iteration then ran on the old weights while the UI said "swapped" |
| §4 which status counts | any fresh `trainer_status` | a status whose non-null `session_id` is another session's is ignored outright (no freshness, no transition); `session_id: null` counts as alive and is shown verbatim but drives nothing (`preparing` reads `"reference gradient not ready (the trainer has not picked up this session yet)"`); a status older than the newest seen is dropped | the hub replays its cached status on `attach_trainer_sink` and the previous session's heartbeats are still in flight — a resumed session went `preparing → rollout` on the OLD session's `ref_grad ready` (D10 bypass, demonstrated); the replay also raced a fresh heartbeat (`trainer_age_s` ran backwards) |
| §4 Train now refusals | open episode / phase / 0 rollouts | + `"no PRO-DAgger trainer attached"` first (no fresh status: publishing `iteration_complete` to nobody would lose the iteration); `"phase <name>"` outside `rollout` with `pause_while_training: false` (the phase refusals are `None` there); the executor reads `recorder.status().state` directly so an `episode_new` handled in the same tick counts as open | the loop's cached `episode_state` refreshes at the END of the tick |
| §4 save while the trainer is in `error` | (unstated) | counts into the CURRENT iteration when the outage hit during `rollout` (`_counts_into_current`); a full iteration then publishes `iteration_complete` on the trainer-recovered transition, never into the void; only a save during `training` / `swapping` (pause off) is carried to k+1 | the first cut filed it into k+1 and never merged the carry back — the operator's rollout trained one iteration late |
| §4 discard boundary (executor) | `recording\|saving → idle` | the episode LEAVING `recording` / `saving` whatever follows (`idle`, or `returning` under D6), with a `_boundary_taken` latch against double firing | with return-to-start ON the walk is `recording → saving → returning → idle`; the old rule never fired after a discard: gate not reset (a held takeover stayed engaged into the next rollout), runner never resumed after a NaN pause, no `policy_reset(episode_boundary)` |
| §4 open rollout at End session | (unstated) | `RecorderThread._shutdown` discards it through `_episode_discarded(index, id, "session teardown")` → `events.episode_discarded` before the coordinator closes | every operator discard is announced; the teardown one was not |
| §4 `session.json` writer | "on the recorder thread" (early draft) | the coordinator's one-thread `SerialWorker` (events keep their order, the file never races itself); tmp + `os.replace`; `session_file_hz` caps rewrites outside transitions | nothing on the tick or the recorder thread does bus / file I/O |
| §4 `session.json` shape | `paths: {rollouts, ref_grad, offline_dataset}`, `current: {iteration, rollout_index, phase}`, `iterations[]` rows without `spool_paths` | `to_session_json` writes `paths: {session_dir, rollouts, ref_grad, offline_dataset, offline_dataset_dir}`, `iterations[]` rows + `spool_paths`, `current: {iteration, rollout_index, phase, episode_ids, spool_paths, n_expert_frames, n_novice_frames, started_at, training, policy_version_before, policy_version_acting, carry}`, plus top-level `ref_grad_ready`, `trainer`, `last_used_at` (§4 as amended 2026-09-08; 10-frames §11.10) | a resume needs the in-flight iteration's rollouts and the saves carried into k+1; `GET /api/pro_dagger/sessions` reads `ref_grad_ready` / `last_used_at` from the file without a coordinator |
| §4 resume | continue from `current`; re-issue an in-flight training | + `_train_pending` when the file's phase is `training` / `swapping` with `rollout_index > 0` (an iteration closed early with Train now is re-issued); `resume: true` with an unreadable / non-dict `session.json` is 409 `"…: session.json is unreadable - fix or remove it"` (checked pre-bring-up AND before mkdirs), never overwritten; a FRESH directory is removed again when ANY step of the bring-up fails (recorder, `GatedPolicyExecutor`, the three `start()` calls — moved inside the rollback scope) | the file is the only record of the rollouts' iteration assignment; a burned name after a late bring-up failure was a 409 "already exists" for a session that never ran |
| §4 `on_session_start` | → `preparing` | announces the CURRENT phase (detail `"session start"`) when a replayed trainer status already moved it | the manager calls `on_session_start` before `hub.attach_trainer_sink`; the replay may land first |
| §8 telemetry cadence / history | every frame carries `history` (finished iterations) | `ProDaggerStatus` rebuilt every `PD_STATUS_EVERY_N = 4` ticks (25 Hz); `history` capped to the newest `HISTORY_TELEMETRY_MAX = 12`, cached per change of `iterations`; the full record is `session.json` / `GET /api/pro_dagger/sessions` | measured 14.5 KB / frame at 50 iterations (361 KB/s), 56 KB at 200 — unbounded growth on the tick thread |
| §6 `ProDaggerConfig` | ranges as listed, `seed: int = 0` | `extra="forbid"`, `session_name` `max_length=64`, `offline_dataset` `max_length=128`, `allow_inf_nan=False` on every float (also `RefGradStatus.progress` and every `TrainerStatusAnnounce` float incl. `scale_check` values), `seed` `ge=0, le=2**31-1` | core review: `+inf` validated and serialised as `null` (every trainer failed to parse the announce for the whole session); an unknown key trained with the default; a 300-char slug turned a 422 into `ENAMETOOLONG`; `RandomState(seed + offset)` needs `< 2**32` |
| §6 `DatasetLayoutInfo` | `{default_namespace, namespaces, generic_root}` | `{default_namespace, generic_root, namespaces}` | the model was written first and the UI types generated from it; the goldens do not pin it, the model wins |
| §6 offline-anchor 409 | `"offline dataset '<id>' not found / has no episodes"` | three strings: `… not found` / `… is a legacy lerobot_v3 tree` / `… has no episodes`, with the RESOLVED repo id; `resume: true` on a missing name → `"PRO-DAgger session '<s>' not found"` | one message per cause |
| §6 session directory | `~/data/pro_dagger/<s>/` | the rollouts dataset is `root_of("pro_dagger/<s>")`; the session dir is its parent iff the namespace maps a `subdir`, else the dataset dir itself (tests pin `namespaces={}`) | `DatasetStore.root_of` must keep addressing the rollouts in both layouts |
| §6 store rules | "everything else stays listable" | `list()` skips a generic-root directory of a MAPPED namespace (DEBUG log); `delete_dataset` never prunes a mapped root or the PRO-DAgger session dir; `Runtime.start()` sweeps every root | an unaddressable row would 404 on every follow-up; the operator's `~/data/bc_demo` must never be `rmdir`'d by a dataset delete |
| §6 offline repo id | the operator's `offline_dataset` | the coordinator holds a copy with the RESOLVED id (`demo` → `bc_demo/demo`): announce, sidecar, `iteration_complete.hparams`, `session.json["paths"]`; `SessionInfo.pro_dagger` / `session.json["spec"]` keep the raw body | §9 says the trainer receives a repo id |
| §7 item 1 | `pro_dagger.paths {session_dir, rollouts_dir, ref_grad_dir, offline_dataset_dir}` | flat `ProDaggerAnnounce{session_name, session_dir, rollouts_dir, ref_grad_dir, offline_dataset, offline_dataset_dir}` | the model was written with the session name and the repo id the trainer logs; both goldens pin the order, so the doc moved |
| §7 item 2 cache | `registry.json` + `<cache_id>/pairs.pt` + `gref0.pt` | `registry.json` + `<cache_id>/gref0.npy` + `<cache_id>/meta.json`; `pairs.pt` optional; `save_ref_grad(ref_grad_dir, identity, *, g_ref, n_pairs, meta, arrays)` | torch-free save / load; `cache_id` / `path` derive from the identity so the caller has no state before saving |
| §8 `ProDaggerStatus.session_dir` | required | `str = ""` | the coordinator always fills it; the exported schema / TS type say optional |
| §8 history row | `(loss, proj_rate, n_expert_frames, wall_s, policy_version)` | `ProDaggerIterationSummary{iteration, episode_ids, n_expert_frames, n_novice_frames, loss, proj_rate, n_proj, train_steps, wall_s, policy_version_before, policy_version_after, started_at, finished_at}` | the version before AND after the swap is what the Cockpit and `session.json` show |
| §8 `ProDaggerSessionInfo` | `{session_name, path, created_at, iterations, rollouts, offline_dataset, task, ref_grad_ready}` | `{session_name, path, created_at, task, offline_dataset, iteration, rollouts, ref_grad_ready, last_used_at}` — `iteration` = the one a resume continues; rows newest `last_used_at` first | the model's spelling; a resume picker needs the last use |
| §8 / §9 `ExternalStatus` | unchanged | + `capabilities: list[str] = []`, `trainer_status: TrainerStatusAnnounce \| None` (session-less) | the launcher must gate Start and show the trainer pill BEFORE a session exists; the design's pill had no wire source |
| §9 `SessionAnnounce.pro_dagger` | `{session_dir, rollouts_dir, ref_grad_dir, offline_dataset_dir, offline_dataset}` | the six `ProDaggerAnnounce` fields above, appended last | see §7 item 1 |
| §9 `episode_saved` payload | `+ pro_dagger {…}` | `{episode_index, summary (EpisodeSummary incl. `episode_id`, `n_expert_frames`, `n_novice_frames`), dataset_root, spool_path, run_id, pro_dagger: {iteration, rollout_index, rollouts_per_iteration, episode_id, actor_counts: {novice, expert}, policy_version}}` | `DaggerRecorderThread._episode_saved` does `dataclasses.replace(summary, episode_index=, episode_id=)`, so the capture-time id rides `summary` (closes the 14-dora merge concern) |
| §9 / 14-dora §4.2 `episode_discarded` scope | published on every discard in every session (14-dora v1.1: "`iteration` 0 / `reason` `""` outside PRO-DAgger") | published in PRO-DAgger sessions ONLY: the single publish site is `ProDaggerCoordinator.on_episode_discarded`, wired by `SessionManager._pro_dagger_discard_hook` inside the PRO-DAgger branch of `_build_external_policy_stack`; the plain external-DAgger branch chains `_episode_saved_hook` (saves only) and leaves `on_episode_discarded` unset, so `iteration` is always the coordinator's (≥ 1) | recorded by the 2026-09-08 docs pass; announcing discards for every session is §15.3 item 11 |
| §10 sheet width | `wide` | `PRO_DAGGER_SHEET_WIDTH = 640` px | `Sheet` takes pixels |
| §10 trainer pill / gating | "trainer pill (`pro_dagger` capability, `ref_grad` state)" | reads `external.capabilities` + `external.trainer_status ?? dagger.pro_dagger.trainer`; `REASON.trainerError` refuses Start for an erroring trainer; "capability unknown" only for a pre-phase-14 runtime | first cut read `capabilities` through a cast and never looked at `trainer_status` — an erroring trainer showed a green pill and Start stayed enabled |
| §10 numeric fields | (unstated) | per-field validation from the vendored `ProDaggerConfig.json` ranges, `aria-invalid` + `.field-error`, Start disabled with "<label> must be <range>"; `proDaggerToSpec` throws on invalid input | the first cut silently substituted defaults for out-of-range values (0 epochs launched 8) |
| §10 New episode | (Cockpit unchanged) | disabled with `newRolloutReason(pd)` outside `rollout`; the `N` hint greys out | the runtime is guaranteed to refuse `episode_new` then; a control that cannot succeed is disabled with its reason |
| §10 actor split | "of the open episode" | "(this iteration)" | the wire has no per-episode split (`expert_frames_iter` / `novice_frames_iter`) |
| §10 history | one row per finished iteration | `HISTORY_ROWS = 6` in the panel (`data-total` keeps the count); the wire carries 12 | side-panel space; §8 cap |
| §10 observer | — | `readOnly` → "observer — another client controls this session" | folding the role into `controlDown` said "control link down", a false statement |
| §10 DatasetsPanel | Demonstrations `bc_demo` | Demonstrations = `layout.default_namespace` (fallback `bc_demo`), group key `demos` | the block is the operator's; a remapped default must not land in Other |
| §10 collect preview | `~/data/bc_demo/<slug>` from the layout | `…/<slug>` + "the runtime's default dataset folder" until the layout answers, then the real folder; `DATASET_NAMESPACE = "apollo"` deleted | the hard-coded namespace §10 forbids survived in the fallback |
| §10 dagger card gating | — | no longer gated on `WorkcellStatus.policies_available` (D1: the policy is external) | the old Landing tests asserted "No policies available" for dagger |
| §10 install one-liner | "the runtime's real origin" | page origin in production; the Vite proxy target only under `vite serve` (`define` conditional on `command`); `scripts/check-dist.ts` runs after `vite build` | the define was baked into the production bundle (`localhost:8765` + the dev-proxy note in `dist/`, verified) |
| §11 SKILL.md | as drafted | port 8765 (was 8000 = gohttpserver on the lab host); the example trains a deep copy and installs it under the policy lock (in-place only while `pause_while_training`); `getattr(policy, "policy_id", "policy")`; `prepare_reference` resets its pools; §5.3 / acceptance 2 no longer expect `ref_grad: ready` pre-launch (impossible: preparation starts on the `running` announce) | four harness-misleading inaccuracies found by the skill review |
| §12 module layout | `pro_dagger/messages.py` | builders / validators in top-level `messages.py` / `contract.py`, re-exported; + `synthetic.py`, `selftest.py`, `ReferenceSubset` | the repo's other wire builders live there |
| §12 `ProDaggerLoop` | consumes `session` + `events` | + same-id `recovering` / `fault` keep the context; foreign-session `iteration_complete` / `episode_discarded` dropped (`LoopStats.ignored_events`); an all-discarded `iteration_complete` publishes `ready` without training; the first pump after an attach sends only the newest status | review findings; the runtime's "trainer.policy_version equals the announced spec version" rule needs the `ready` to advance the phase |
| §13 fake node | policy-node `FakeTrainer` only | the runtime's `dora_bridge/nodes/fake_policy.py` gained the same trainer role (`FAKE_TRAINER=1` / `--trainer`, `FAKE_TRAINER_PREPARE_S` / `_EPOCH_S` / `_FAIL_AT_ITER` / `_FAIL_PREPARE`; plain fake `capabilities: []`) | the sim e2e spawns the runtime's fake, not the other repo's |
| §13 e2e | `test_e2e_pro_dagger.py` as sketched | + an `observer` node logging `events` to JSON lines; the offline anchor is a REAL collect session (`bc_demo/demo1`), the return target the initial-condition profile designated by a teleop `set_initial_condition`; `FAKE_TRAINER_PREPARE_S` 3 s / `_EPOCH_S` 2 s so the `preparing` / `training` refusal windows are observable at 25 Hz; `swapping` may be missed on telemetry and is asserted on the bus | timing |
| §13 D6 in tests | — | `tests/dagger/test_e2e_dagger.py` and `tests/dora_bridge/test_e2e_external_policy.py` pass `return_to_start: False`; the dagger return case is a unit test (`tests/test_return_manager_units.py`) | those e2es have no initial-condition profile; a dagger return e2e needs a policy stack (the PRO-DAgger e2e covers it: the episode state walks `returning` after every save) |
| §13 policy-node CI | `.[dev]` | `.[dev,pro_dagger]` + CPU torch (`--index-url https://download.pytorch.org/whl/cpu`) | the 14 PGrad tests skipped in CI otherwise |
| — (discovered) | — | `SessionInfo` echoes `policy_source` and `pro_dagger` but neither `dataset` nor `return_to_start` (phase-13 design: those ride `telemetry.episode` / `session`); the recorder's `episode_index` counts SAVED episodes only (a discarded rollout consumes no index) | recorded as observed by the e2e |

### 15.2 Verified facts (lab host, 2026-09-08)

- **core**: `uv run pytest` 466 passed (final implementer run, 3.7 s) — 470 tests collected
  after the review fixes; `uv run ruff check .` clean; `export_schemas --out schemas/ --check`
  clean, **43 schema files** (36 + 7 new: `ProDaggerConfig`, `ProDaggerSessionInfo`,
  `ProDaggerAnnounce`, `TrainerStatusAnnounce`, `RefGradStatus`, `DatasetLayoutInfo`,
  `DatasetNamespaceInfo`; `ProDaggerStatus` / `ProDaggerIterationSummary` ride `TelemetryMsg`
  `$defs`). The two contract goldens (runtime `tests/dora_bridge/golden/contract_golden.json`,
  policy-node `tests/golden/contract_golden.json`) are byte-identical (sha256 `3dae3df0…f9e4`,
  4093 bytes) and both golden tests pass against their live code.
- **runtime**: **713 tests collected**; the last full `uv run pytest` (dora + egl + perf tests,
  real private control plane) 710 passed / 1 failed / 2 skipped in 11 min 20 s — the failure was
  `test_skill_mirror_in_the_policy_node_repo_is_byte_identical` after a one-line note in the
  shipped `contract.md`, reverted (`cmp` identical again; 56 targeted tests green); the 2 skips
  are the `APOLLO_MIC_HW=1` / `APOLLO_TRACKER_HW=1` real-device probes. Stage-C baseline 695
  passed / 2 skipped in 666 s. `uv run ruff check .` clean. **The PRO-DAgger e2e file
  (`tests/dora_bridge/test_e2e_pro_dagger.py`, 3 tests) takes 32.75–33.61 s wall (3/3 runs, no
  flake)**: module setup (LiveServer + private control plane + the teleop profile session + the
  offline collect session) 12.55 s, `test_pro_dagger_iteration_over_the_bus` 18.59 s,
  `test_409_matrix_before_any_trainer` 1.33 s, `test_skill_endpoints_are_session_less` 0.01 s.
  Iteration timing inside it: `FAKE_TRAINER_PREPARE_S` 3 s + 2 epochs × 2 s, history row
  `wall_s ≥ 3.6 s`, exactly one `policy_version_changed` 1 → 2 with `mid_episode: false`.
  `uv build --wheel` ships `apollo_mavis_v2_runtime/pro_dagger/skill/{SKILL.md,references/*.md}`.
  A pre-existing encoder pacing bug found on the way (`streams/hub.py` `EncoderWorker` aliasing
  against the equal-rate sim render grid: 11.9–14.5 Hz with contiguous seqs) was fixed
  (phase-locked poll; probe 14.98 Hz, frame-age p99 62–67 → 11.7 ms; `tests/test_video_hub_pacing.py`).
- **ui**: `npm run gen:check` OK (schemas byte-identical to core), `npm run lint` clean,
  `prettier --check .` clean, **43 files / 415 tests** (`vitest run`, 8.9 s; 413 at the review
  fix, 400 before it), `npm run build` = `tsc --noEmit` + `vite build` (~432 kB main chunk) +
  `check-dist OK — no dev-proxy leak`. pnpm cannot run scripts on this host
  (`ERR_PNPM_IGNORED_BUILDS`); `npm run …` is the authoritative form (`package-lock.json`).
- **policy-node**: **128 tests collected**; the last run 125 passed, 0 skipped (torch and the
  dora e2e both ran; CPU torch 2.14.0+cpu hand-installed into `.venv`, `uv.lock` untouched);
  `ruff check .` and `ruff format --check .` clean (`[tool.ruff.format] exclude = ["*.md"]`);
  `python -m mavis_policy_node --pro-dagger fake --selftest pro-dagger` exit 0.
- **hardware / sim** (merge verification, unchanged by phase-14): 293 passed; 155 passed
  (13 egl).
- **Refusals, exact strings.** `POST /api/session` 409 (`SessionError`): `"offline dataset
  '<ns>/<name>' not found"`, `"offline dataset '<ns>/<name>' is a legacy lerobot_v3 tree"`,
  `"offline dataset '<ns>/<name>' has no episodes"`, `"PRO-DAgger session '<s>' already exists -
  resume it or pick another name"`, `"PRO-DAgger session '<s>' not found"`, `"PRO-DAgger session
  '<s>': session.json is unreadable - fix or remove it"`, `"no external policy attached (dora
  bridge is not attached)"`, `"no external policy attached (no policy_spec heartbeat within 3 s)"`,
  `"no PRO-DAgger trainer attached (the policy node does not report the pro_dagger capability)"`,
  `"return_to_start needs a start_from profile or an initial-condition profile - set an initial
  condition or untick 'Return to start'"` (now for dagger too), and on hardware the unchanged
  `"hardware sessions support teleop and data collection only (dagger on hardware: not yet)"`
  (D7). 422 (pydantic): `"pro_dagger requires mode dagger"`, `"pro_dagger requires policy_source
  'external'"`, `"pro_dagger derives the rollouts dataset - leave dataset unset"`,
  `"return_to_start is a collect / dagger-mode field"`, unknown keys, non-finite floats, over-long
  names, `seed` out of range. `/ws/control` nacks — `episode_new`: `"no PRO-DAgger trainer
  attached"`, `"reference gradient not ready (<detail>)"` with detail `no trainer status yet` /
  `the trainer has not picked up this session yet` / `building NN%` / `error: <detail>` /
  `<state>[: <trainer detail>]`, `"training in progress (iteration k, epoch e/E)"`, `"waiting for
  the new policy (iteration k)"`, `"trainer error: <detail|unknown>"`, plus the existing
  `"returning to the initial configuration"`; `pro_dagger_train_now`: `"save or discard the
  episode first"`, the `episode_new` reasons above, `"phase <name>"`, `"no kept rollout in this
  iteration yet"`, and outside a PRO-DAgger session `"not a PRO-DAgger session"`; the ack's
  success detail is `"training iteration k on n rollout(s)"`.
- **REST routes and status codes.** `GET /api/datasets/layout` → 200 `DatasetLayoutInfo`
  (declared before `/api/datasets/{ns}/{name}`; `/api/datasets/layout/x` → 404);
  `GET /api/pro_dagger/skill` → 200 `text/markdown; charset=utf-8` | 404 `"PRO-DAgger skill not
  found: …"`; `GET /api/pro_dagger/skill.tgz` → 200 `application/gzip`, `Content-Disposition:
  attachment; filename="mavis-pro-dagger-trainer.tgz"` | 404; `GET /api/pro_dagger/sessions` →
  200 `list[ProDaggerSessionInfo]` (`[]` without a root); `POST /api/session` → 200 `SessionInfo`
  with `pro_dagger` echoed | 409 / 422 as above; `GET /api/dora` unchanged. `GET /api/datasets`
  rows carry `namespace` + `path`.
- **Wire.** `RUNTIME_INPUTS` = `(tick, probe_heartbeat, policy_action, policy_spec,
  policy_status, policy_trainer_status)`; `POLICY_OUTPUTS` = `(action, spec, status,
  trainer_status)`; `EVENT_KINDS` += `iteration_complete`, `pro_dagger_phase` (appended);
  `dataflows/mavis_v2.example.dora.yml` renders `policy_trainer_status: {source:
  policy/trainer_status, queue_size: 8}` and the placeholder's `outputs: [action, spec, status,
  trainer_status]`; `PolicyResetReason` `"episode_boundary"` is spelled at boundaries
  (`GatedPolicyExecutor._episode_boundary` → `runner.drop_and_requery("episode_boundary")`;
  a handback keeps `"handback"`); `events.episode_discarded` is published on every discard
  of a PRO-DAgger session (operator, empty-episode save or teardown) — and ONLY there (§15.1,
  14-dora §4.2; corrected 2026-09-08). The `pro_dagger_phase` sequence of one iteration on the bus:
  `preparing → rollout → training → swapping → rollout` with details `"waiting for the reference
  gradient"` / `"reference gradient ready"` / `"iteration 1: 2 rollouts handed to the trainer"` /
  `"trainer ready (policy v2)"` / `"iteration 2, policy v2"`.
- **Skill mirror**: `cmp` of `SKILL.md`, `references/contract.md`, `references/algorithm.md`
  between the runtime package and the policy-node repo → identical.

### 15.3 Open items

1. **Hardware stays 409 for PRO-DAgger** (D7) — admitting it is one refusal-matrix line +
   `REASON.hardwareTeleopOnly` after the first sim session validated the loop (§14 item 1).
2. **Done (2026-09-08, verified by the docs pass)** — the shipped skill's
   `references/contract.md` states the session-id rule in §2.3 (the `session_id` row: "The
   runtime drives its PRO-DAgger phase ONLY from statuses whose `session_id` echoes its current
   session: `null` counts as 'trainer alive' but drives nothing; another session's id is
   ignored outright") and §3 ("a trainer MUST echo the served `SessionAnnounce.session_id` in
   every `trainer_status`"); `cmp` of `SKILL.md` / `references/contract.md` /
   `references/algorithm.md` against the policy-node mirror is identical. Superseded text: "The
   shipped skill's `references/contract.md` §2.3 / §3 should state the session-id rule (the
   runtime drives its phase only from statuses echoing its own `session_id`; `null` = alive
   only); both copies must change together — `test_skill_mirror_…` enforces byte identity. The
   policy-node `ProDaggerLoop` already echoes the served id."

3. `ExternalStatus.trainer_status` duplicates the 22-field status in every 25 Hz frame while a
   PRO-DAgger session runs (`dagger.pro_dagger.trainer` carries it too); a compact subset
   (`state`, `ref_grad.state`, `iteration`, `policy_version`) would do for the pill.
4. Not covered by an e2e: `FAKE_TRAINER_FAIL_AT_ITER` / `FAKE_TRAINER_FAIL_PREPARE` (the `error`
   phase + recovery are unit-tested only); the Cockpit smoke covers `preparing` / `training`
   gating, `swapping` / `error` at the unit level.
5. Pre-existing, observed in the e2e log: the runtime logs `Discarding event for input
   'policy_spec' due to queue size limit` about once a second while a fake is attached (the fake
   re-publishes `spec` on every 1 Hz `session` announce AND its own heartbeat against the
   `queue_size: 1` input) — harmless, noisy; and one lerobot encoder GIL stall (`process stall
   318 ms`, WS watchdog latched) during a takeover — the encoder-subprocess fix stays open.
6. The two contract goldens insert the three CamelCase keys (`TrainerStatusAnnounce`,
   `RefGradStatus`, `ProDaggerAnnounce`) after `event_envelope_fields`, breaking the file's
   alphabetical order; both sides must keep rendering in insertion order (`indent=2`, trailing
   newline) or the byte identity silently breaks.
7. `scripts/deploy/render-lab-config.sh` rewrites `datasets_root` but does not template
   `datasets.namespaces` — the lab render keeps `~/data/bc_demo` / `~/data/pro_dagger`
   (the operator's decision; a `DATASETS_HOME` knob is an option).
8. `tests/dora_bridge/harness.py::dora_runtime_config()` does not pin `translate_frame`, so the
   phase-12 dora e2e teleop holds run under the `world` default (no dora test asserts a world
   axis; all pass).
9. `ruff format --check` flags pre-existing unformatted hunks in `dagger/pro_dagger.py` and
   `session/manager.py` (the runtime does not enforce the formatter).
10. Per-iteration success marking (`roll_sr`), `weights_reload` / `weights_ack`, the
    out-of-process bridge — unchanged from §14.
11. `events.episode_discarded` is published by the PRO-DAgger coordinator ONLY (§15.1; 14-dora
    §4.2 corrected 2026-09-08): a plain external-DAgger session (or any other mode) never
    announces a discard on the bus, although `RecorderThread` already calls the
    `_episode_discarded(index, episode_id, reason)` hook on every discard path (operator,
    empty-episode save, teardown). Making the kind session-wide is one publisher method
    (`publish_episode_discarded`, sibling of `publish_episode_saved`) plus assigning
    `recorder_thread.on_episode_discarded` in the non-PRO-DAgger builders; the payload's
    `iteration` would then be `0` there, as 14-dora v1.1 already described. Not an operator
    decision either way (§0 is silent) — main-agent call when it is wired.
