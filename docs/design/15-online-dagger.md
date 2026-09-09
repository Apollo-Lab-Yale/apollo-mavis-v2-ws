# 15 — Online DAgger: the algorithm-agnostic shell for interactive learning

Status: **v2.0, binding for phase-14 (2026-09-08, evening).** Supersedes `15-pro-dagger.md`
v1.0 (kept for history; its §15 implementation record describes the code this version
REPLACES). Operator decision 2026-09-08 (evening): the runtime keeps only the **rollout-level
shell** — perform rollouts, expose take-over / hand-back, record who acted at every step,
report what the trainer says — and knows nothing about any particular DAgger algorithm.
PRO-DAgger (projected reference gradient, EMA, reference pool), HG-DAgger, DRIFT-DAgger and
friends are implemented in the **policy repo** on top of this shell; the skill this runtime
ships tells a coding harness how. Spelling authority for wire ids: core `protocol/external.py`;
for session / telemetry models: core `protocol/session.py` / `protocol/telemetry.py`. This
document must agree with them.
**Amended 2026-09-08 (evening, late) — IMPLEMENTED** in the main working trees of core /
runtime / ui (uncommitted) and the `apollo-mavis-v2-policy-node` checkout under
`~/projects/apollo-mavis-v2-ws-p12/` (uncommitted), then reviewed and fixed the same
evening: §12 is the implementation record (deviation table, verified facts — test counts,
the e2e name and wall time, the exact refusal / 409 / nack strings, the REST routes, the
event payload keys, `session.json` as `to_session_json` writes it — and the open items).
Sections touched in-body with dated lead-ins, v2.0 text kept: §3 (phase derivation, the
`(<detail>)` texts, `spool_path: null`, the boundary's `episode_id`, the two new 409s, the
delete refusal, `source: "action"`), §5 (`ActionName` tail — `goto_profile` landed after
`train_now`; `SessionInfo.fault_detail`), §7 (the 409 list as shipped), §8 (the UI as shipped:
explicit resume checkbox, no stale window, Take over / Hand back gated by `control_mode`
only, the actor split shown once), §10 (policy-node module names, fake knobs, `ProDaggerConfig`
extra keys, the loop's error semantics), §11 (the test files as named). Where this document
and the code disagreed, the code won and the deviation is recorded in §12.

## 0. Operator decisions (2026-09-08 evening, binding)

1. The third launcher mode is **Online DAgger** (not PRO-DAgger). Wire `mode` stays `dagger`.
2. Training and every algorithm-specific artefact (projected gradients, reference pools, EMA
   state, hyper-parameters) belong to the **policy repo**. The runtime stores none of it and
   its UI configures none of it — in particular **no offline-dataset picker** (the trainer
   configures its own anchor).
3. The shell keeps **rollout-level control only**: perform the rollout, provide the
   **take-over** and **hand-back** API, save the rollout, and label every step **novice** vs
   **expert**. It does not count iterations.
4. **Pause new rollouts while the trainer trains** and the operator's **Train now** request are
   kept (both generic).
5. **Discarded rollouts are never saved**: a discard removes the episode's temporary directory
   (video, frames, audio); only a notification event is published so a trainer that watched
   the rollout live can drop what it landed.
6. Session directory `$HOME/data/online_dagger/<session_name>/` with `rollouts/` (a standard
   episode-directory dataset) and `session.json`; the trainer puts its own artefacts wherever
   it likes (the skill suggests `<session>/trainer/`; the runtime never reads it).
7. PRO-DAgger reference implementation (policy-node repo) defaults: the **offline pool
   provides the reference gradient only** (`freeze_offline_gref: true`), the **online buffer
   accumulates every expert intervention and is trained on at every iteration**
   (`replay_buffer: true`, unbounded). The previous "current iteration only, then drop"
   default is gone.

## 1. Main-agent decisions (implementation follows these; the operator can overturn)

- **D1** Wire: `mode: "dagger"` + `policy_source: "external"` + `SessionSpec.online_dagger`.
  People read "Online DAgger" everywhere (card, sheet, Cockpit title, keymap overlay).
- **D2** ONE generic inbound stream `trainer_status` (state machine `idle | preparing |
  training | ready | error`, free-form `metrics`), ONE generic gate: `episode_new` is refused
  while the trainer reports `training` (`pause_while_training`) and, until the trainer has
  reported `ready` once for this session, when `wait_for_trainer_ready` is on.
- **D3** The runtime publishes **gate events** on the bus (take-over / hand-back instants) and
  accepts explicit **`takeover` / `handback`** actions (idempotent) beside the operator's
  `Space` toggle. The Vive / keyboard maps are untouched.
- **D4** Rollout bookkeeping stays with the runtime's recorder: `actor` column, actor counts in
  `episode.json` and in `events.episode_saved`; the trainer decides when to train.
- **D5** Dataset namespace `online_dagger` → `~/data/online_dagger/<s>/rollouts`
  (`RuntimeConfig.datasets.namespaces`); `pro_dagger` namespace, config block, REST prefix,
  skill and coordinator are REMOVED, not aliased (never shipped).
- **D6** Return-to-start applies to rollouts (default ON, per-session opt-out) — unchanged.
- **D7** Hardware still refuses `dagger` (`409 hardware sessions support teleop and data
  collection only`) until the operator says go.
- **D8** The skill is `mavis-online-dagger-trainer`: the generic contract plus a worked
  PRO-DAgger example that lives in the policy-node repo (`mavis_policy_node.pro_dagger`, kept
  as the reference implementation ON TOP of the generic `mavis_policy_node.online_dagger`
  loop).

## 2. Roles

```
 operator ──keys/Vive/UI──▶ mavis runtime                              policy node (policy repo)
                            ├─ takeover gate + takeover/handback API     ├─ inference (obs_state → action)
                            ├─ DaggerRecorder → rollouts/ (actor col)    ├─ trainer (ANY DAgger variant)
                            ├─ events: gate, episode_saved,      events▶│   counts rollouts, decides when
                            │          episode_discarded, train_now      │   to train, swaps its weights
                            └─ telemetry.dagger.online_dagger ◀──trainer_status── (state, metrics)
```

## 3. Runtime: `OnlineDaggerCoordinator` (`dagger/online_dagger.py`)

Session-scoped, owned by `GatedPolicyExecutor` when `spec.online_dagger` is set. Pure state;
publishing and `session.json` writes go through the serial worker (never on the tick).

State: `phase ∈ {"waiting_trainer", "rollout", "training", "error"}`, `rollouts_saved`,
`expert_frames_session`, `novice_frames_session`, last `TrainerStatusAnnounce` + receive time,
`policy_version_acting`, `trainer_seen_ready` (bool).

Rules:
- Start → `waiting_trainer` if `wait_for_trainer_ready` else `rollout`. A trainer status that
  echoes THIS `session_id` with `state == "ready"` sets `trainer_seen_ready` → `rollout`.
  Statuses with another session's id are ignored; `session_id: null` counts as alive only.
- `state == "training"` (this session) → `training` (if `pause_while_training`, else the phase
  stays `rollout` and the pill just shows it). `ready` again → `rollout`. `error` → `error`
  until a non-error status arrives.
  **As shipped (2026-09-08 evening; `OnlineDaggerCoordinator._phase_for`):** the phase is a
  PURE FUNCTION of the latest same-session status plus the `trainer_seen_ready` latch —
  `error` → `error`; `training` → `training` only with `pause_while_training`; `ready` →
  `rollout` (latches); `idle` / `preparing` (and `training` without the pause) → `rollout` once
  ready was seen or `wait_for_trainer_ready` is off, else `waiting_trainer`. v2.0 did not spell
  the idle / preparing-after-ready case. A status older than the newest seen is dropped (the
  attach replay racing a heartbeat).
- `episode_new` refusals: `"no Online DAgger trainer attached"` (no fresh status),
  `"waiting for the trainer to report ready (<detail>)"`, `"training in progress (<detail>)"`,
  `"trainer error: <detail>"`.
  **As shipped:** `<detail>` (`_trainer_detail`) is `no trainer status yet` (no status at all),
  `the trainer has not picked up this session yet` (a status with `session_id: null`), the
  trainer's own `detail` when non-empty, else `<progress>%` while `training`, else `trainer
  <state>`; the error text falls back to `trainer error: unknown` when the trainer sent no
  detail. Aliveness is checked BEFORE the phase (a dead trainer in `rollout` is refused with
  `"no Online DAgger trainer attached"`, not admitted).
- Kept rollout → `rollouts_saved += 1`, counts added; `events.episode_saved` gains
  `online_dagger: {episode_id, rollouts_saved, actor_counts: {novice, expert},
  policy_version, spool_path}`. `session.json` appends a rollouts row.
  **As shipped:** `rollouts_saved` in the block, the `episode.json` sidecar and the row is the
  count INCLUDING this rollout; `spool_path` is `null` (event, block, row) when the trainer
  spool could not be written — the rollout is still on disk and still counted (the recorder
  wraps `_write_spool` and fires the hook regardless, review fix 2026-09-08). The coordinator
  runs BEFORE the executor's boundary callback, so `episode_saved` precedes the boundary's
  `events.gate{source: episode_reset}` on the wire.
- Discard → `events.episode_discarded {episode_index, episode_id, reason}`; **nothing on
  disk** (the recorder deletes `episodes/.tmp-<id>/`).
  **As shipped:** `reason` is `""` for the operator's discard, `"empty episode discarded"`
  (every frame filtered), `"session teardown"` (a rollout still open at teardown) and — new,
  review fix 2026-09-08 — `"save failed twice - recording degraded (buffer kept)"` (the
  recorder degrades per 04-runtime §15 and KEEPS the temp directory in that one case; the
  event still tells the trainer). A `DELETE /api/datasets/online_dagger/<s>/episodes/<id>`
  of a SAVED rollout while that session runs is 409 `"dataset 'online_dagger/<s>' is in use
  by the running Online DAgger session - end the session first (the trainer is told about
  discards, not deletions)"` (`DatasetStore.episode_delete_refusal`); every other dataset
  keeps the phase-13 rule (only the open episode is protected).
- `train_now` action (Cockpit button) → `events.train_now {rollouts_saved, requested_by:
  "operator"}`; refused while an episode is open (`"save or discard the episode first"`) or
  when no fresh trainer status exists. The trainer may ignore it.
- `takeover` / `handback` actions → `TakeoverGate` (idempotent: `takeover` in HUMAN /
  TRANSITION is a no-op ack, `handback` in POLICY is a no-op ack); every gate event (Space,
  actions, auto-advance, episode reset) is published as `events.gate {arm_id, mode, seq,
  source, episode_id}`.
  **As shipped (`GatedPolicyExecutor._op_takeover` / `_op_handback`, `dagger/gate.py`):**
  `GateEvent.source` gained the spelling `"action"` for the two explicit actions (core's
  comment lists `keyboard | auto_advance | episode_reset`; the field is a plain `str`,
  additive); the ack detail is the new mode (`"takeover_transition"` / `"policy"`), the
  idempotent acks are `"already taken over"` / `"policy already driving"`, the nacks
  `"takeover active"` (another arm is engaged) and `"no active arm"`; `handback` hands back the
  ENGAGED arm. The base `ControlLoop` (teleop / collect) nacks both with `"takeover not
  available in teleop"` and `train_now` with `"not an Online DAgger session"`. The boundary's
  `episode_reset` event names the episode that just CLOSED (`_ep_id`, cached when it opened;
  review fix — before it re-read the recorder and got `null`). Publication path: an Online
  DAgger session hands the payloads to `coordinator.on_gate_events` (its `SerialWorker`, so
  they stay ordered against `episode_saved` / `episode_discarded`); a plain external or
  checkpoint dagger / inference session with the bridge on uses the new
  `SnapshotPublisher.enqueue_event()` deque (256) drained on the `dora-publisher` thread
  (`DoraWiring.publish_gate_events`) — gate events are therefore session-wide for policy
  sessions, `episode_discarded` stays Online DAgger only (§12 open items). Both keep the bus
  off the tick. Under POLICY with no arm engaged, `reset_to_initial` (`R`) and `goto_profile`
  are nacked `"policy driving - take over (Space) first"` (04-runtime §10.5).
- `policy_version_acting` follows the announced spec / action version; a change is logged in
  `session.json.trainer_log` and shows as "swapped" in the panel.
  **As shipped:** the row is `{at, state: "swapped", policy_version: <new>, detail: "policy
  v<old> -> v<new>"}`; the trainer's own `policy_version` claim never moves the acting version
  (the policy node now re-publishes `spec` BEFORE the `ready` status that carries the swap, so
  the two agree — §12). `DaggerStatus.online_dagger` is rebuilt every `OD_STATUS_EVERY_N = 4`
  ticks (25 Hz) and `SessionTelemetry.trainer_alive` mirrors its `trainer_alive`.

`session.json`: `{session_name, created_at, session_id, task, spec, paths: {session_dir,
rollouts}, rollouts: [{episode_id, saved_at, actor_counts, policy_version, spool_path}],
trainer_log: [{at, state, policy_version, detail}] (last 200), current: {phase,
rollouts_saved, expert_frames_session, novice_frames_session}, last_used_at}`. Resume
(`resume: true`, name exists) continues the counters; `resume: false` on an existing name is
409 `"Online DAgger session '<s>' already exists - resume it or pick another name"`;
unreadable file → 409 `"... session.json is unreadable - fix or remove it"`.
**As shipped (`SessionManager._check_online_dagger`, evaluated in `create()` after
`_check_dataset_spec` and the hardware matrix, before `_check_return_to_start`, before any
side effect):** also 409 `"Online DAgger session '<s>' not found"` (`resume: true` on a
missing name) and, new (review fix 2026-09-08), the rollouts dataset is a dataset like any
other — `"dataset 'online_dagger/<s>' is being exported - retry in a moment"` / the legacy
LeRobot v3 409 of `_check_dataset_spec` — then the trainer checks. `session.json` is written
`json.dumps(doc, indent=2, sort_keys=True)` via tmp + `os.replace`; a FRESH directory gets
its first document during bring-up (removed again by `_OnlineDagger.abandon()` if the bring-up
fails later), a RESUMED record is NOT rewritten until the session is RUNNING
(`on_session_start()`), so a resume that still 409s leaves the file byte-identical. The
`trainer_log` keeps the newest 200 rows; `last_used_at` is refreshed on every write and once
more at `close()`.

## 4. Recording

Unchanged from v1.0 §5: `actor` int8 `{0 novice, 1 expert}` (= `control_mode != 0`) in
`dagger_features`, every DAgger frame, `SPOOL_COLUMNS`, `EpisodeSummary.n_expert_frames /
n_novice_frames`; `episode.json` gains `online_dagger: {session_name, rollouts_saved,
policy_version, actor_counts}` (the v1.0 `pro_dagger` block is gone).

## 5. Core models

```python
class OnlineDaggerConfig(BaseModel):            # SessionSpec.online_dagger (extra="forbid")
    session_name: str = Field(pattern=SLUG_RE, max_length=64)
    resume: bool = False
    pause_while_training: bool = True
    wait_for_trainer_ready: bool = True

# validators: online_dagger set => mode == "dagger", policy_source == "external",
#   dataset is None / dataset_resume False ("online_dagger derives the rollouts dataset")
# SessionInfo.online_dagger: OnlineDaggerConfig | None

class OnlineDaggerSessionInfo(BaseModel):       # GET /api/online_dagger/sessions
    session_name: str; path: str; created_at: str; task: str | None
    rollouts: int; last_used_at: str | None = None

class OnlineDaggerStatus(BaseModel):            # DaggerStatus.online_dagger
    session_name: str
    phase: Literal["waiting_trainer", "rollout", "training", "error"]
    rollouts_saved: int
    detail: str = ""
    trainer_alive: bool = False
    trainer_age_s: float | None = None
    trainer: TrainerStatusAnnounce | None = None
    policy_version_acting: int | None = None
    expert_frames_session: int = 0
    novice_frames_session: int = 0
    session_dir: str = ""
```

`ProDaggerConfig`, `ProDaggerStatus`, `ProDaggerIterationSummary`, `ProDaggerSessionInfo`,
`ProDaggerAnnounce`, `RefGradStatus` are deleted. `DatasetLayoutInfo`, `DatasetNamespaceInfo`,
`DatasetInfo.namespace/path`, `SLUG_RE` stay. `ActionName`: `pro_dagger_train_now` →
`train_now`; new `takeover`, `handback` (argless; no keymap rows).
**As shipped (core `protocol/`, 2026-09-08 evening):** the models above are spelled exactly
so; the validator texts are `"online_dagger requires mode dagger"`, `"online_dagger requires
policy_source 'external'"`, `"online_dagger derives the rollouts dataset - leave dataset
unset"` (evaluated before the dataset rule). `ActionName` ends `…, "takeover", "handback",
"train_now", "goto_profile"` — `goto_profile` (`GotoProfileArgs{profile_id}`, the profile
row's "Go to profile" button, 04-runtime §10.5) landed later the same evening and is appended
LAST; the three Online DAgger actions keep their order. `SessionInfo` also gained
`fault_detail: str = ""` (inserted before `online_dagger`, which stays last) for the
session-level notice of 04-runtime §13.3 — unrelated to this shell. KEYMAP stays 24 rows.

## 6. Wire (core `protocol/external.py`; goldens on both repos must match byte-for-byte)

- `POLICY_OUTPUTS = ("action", "spec", "status", "trainer_status")`; `RUNTIME_INPUTS` ends with
  `policy_trainer_status` (queue 8) — unchanged from v1.0.
- `EVENT_KINDS` = the phase-12 list (`collision, gate, episode_saved, episode_discarded,
  policy_anomaly, policy_swap, policy_version_changed, reset_watermark, session_error`)
  + `train_now` appended. `iteration_complete` / `pro_dagger_phase` are removed.
- `PolicySpecAnnounce.capabilities: list[str] = []` — a trainer-capable node lists
  `"online_dagger"`.
- `SessionAnnounce.online_dagger: OnlineDaggerAnnounce | None = None` (last field):

```python
class OnlineDaggerAnnounce(BaseModel):
    session_name: str
    session_dir: str
    rollouts_dir: str

class TrainerStatusAnnounce(BaseModel):          # policy/trainer_status, JSON, 1 Hz + on change
    mavis_schema: int = MAVIS_SCHEMA
    trainer_id: str
    node_version: str
    state: Literal["idle", "preparing", "training", "ready", "error"] = "idle"
    session_id: str | None = None                # echo of the served SessionAnnounce
    policy_version: int = 0                      # acting version after the last swap
    progress: float = Field(0.0, ge=0, le=1, allow_inf_nan=False)
    metrics: dict[str, float] = {}               # free-form finite scalars (loss, proj_rate …)
    detail: str = ""
    uptime_s: float = Field(0.0, ge=0, allow_inf_nan=False)
```

- `ExternalStatus.capabilities` / `ExternalStatus.trainer_status` stay (session-less pill).
- Golden keys: `TrainerStatusAnnounce`, `OnlineDaggerAnnounce` (field-name lists) after the
  `event_envelope_fields` entry; `RefGradStatus` / `ProDaggerAnnounce` removed.
- Event payloads: `gate {arm_id, mode, seq, source, episode_id}`; `episode_saved` +
  `online_dagger` block (§3); `episode_discarded {episode_index, episode_id, reason}`;
  `train_now {rollouts_saved, requested_by}`. `PolicyResetReason "episode_boundary"` at
  boundaries (v1.0 fix, kept).

## 7. Configuration, paths, REST

```yaml
datasets:
  default_namespace: bc_demo
  namespaces:
    bc_demo:       {root: ~/data/bc_demo}
    online_dagger: {root: ~/data/online_dagger, subdir: rollouts}
online_dagger:
  skill_dir: null          # null = the shipped skill
  session_file_hz: 1.0
```

REST: `GET /api/online_dagger/skill` (markdown), `GET /api/online_dagger/skill.tgz`,
`GET /api/online_dagger/sessions → list[OnlineDaggerSessionInfo]`, `GET /api/datasets/layout`.
`POST /api/session` 409s: the session-dir rules (§3), `"no external policy attached (...)"`,
`"no Online DAgger trainer attached (the policy node does not report the online_dagger
capability)"`. `/api/pro_dagger/*` is gone.
**As shipped:** `GET /api/online_dagger/skill` → `text/markdown; charset=utf-8` | 404 `"Online
DAgger skill not found: <OSError>"`; `GET /api/online_dagger/skill.tgz` → `application/gzip`,
`Content-Disposition: attachment; filename="mavis-online-dagger-trainer.tgz"`, members rooted
at `mavis-online-dagger-trainer/` | 404; `GET /api/online_dagger/sessions` → 200 always
(`[]` without the root; an unreadable file is skipped with a warning; newest `last_used_at`
first). `/api/pro_dagger/{skill,sessions}` → 404 (pinned by `tests/test_server_contract.py`
and the dora e2e). The full 409 list is in §12 "Verified facts". `RuntimeConfig.online_dagger
{skill_dir: null, session_file_hz: 1.0}` (`OnlineDaggerRuntimeConfig`; both YAMLs carry the
block); `RuntimeConfig.datasets.namespaces` = `{bc_demo: {root: ~/data/bc_demo},
online_dagger: {root: ~/data/online_dagger, subdir: rollouts}}`, `default_namespace: bc_demo`.

## 8. UI

- Card 3: icon `project`, label **Online DAgger**, description "Novice drives, you correct —
  your trainer learns between rollouts".
- `OnlineDaggerSheet` (two views): ① *Connect a trainer* — external-policy chip, trainer pill
  (`capabilities` includes `online_dagger`, `trainer_status.state`), connection facts + copy,
  skill install one-liner `curl -s http://<host>:8765/api/online_dagger/skill.tgz | tar xz -C
  ~/.claude/skills/`, SKILL.md preview, 3-line how-it-works; ② *Configure* — Session name (path
  preview `~/data/online_dagger/<slug>`, resume pill from `GET /api/online_dagger/sessions`),
  Task, Recording (idle filter, Return-to-start), Advanced (pause while training, wait for
  trainer ready, frames). NO dataset picker, NO hyper-parameters. Footer Start Online DAgger.
- `OnlineDaggerPanel`: phase pill (WAITING FOR TRAINER / ROLLOUT / TRAINING with progress /
  TRAINER ERROR), rollouts saved, actor split (session), control-mode + external chips,
  trainer state + `metrics` as a key/value list (a `loss` metric gets the sparkline),
  acting policy version (+ "swapped" flash), buttons **Take over** / **Hand back** (send
  `takeover` / `handback`), **Train now**, key hints; red banner when the trainer is dead /
  stale / error. `EpisodeControls` new-episode reason from the phase.
- `DatasetsPanel` groups: Demonstrations (default namespace) · Online DAgger rollouts · Other.

**As shipped (2026-09-08 evening, after the UI review; `components/OnlineDaggerSheet.tsx`,
`components/OnlineDaggerPanel.tsx`, `lib/launch.ts`):**
- Sheet ①: the trainer pill reads `Trainer <trainer_id> · online_dagger | no online_dagger
  capability · <state>[ — <detail>]` (detail + tone `warn` only while erroring), else
  `Trainer · none attached` / `Trainer · online_dagger capability` / `Trainer · no online_dagger
  capability` / `Trainer · capability unknown (this runtime predates telemetry.external.
  capabilities)`. An erroring SESSION-LESS `trainer_status` is a WARNING caption
  (`"Trainer reports an error — you can start, but check the policy node[: <detail>]"`), never
  a Start refusal — the runtime does not 409 on it and a new session is the recovery path.
- Sheet ②: `resume` is derived from the listing (`existing !== null`) OR an explicit
  **"Resume the existing session of this name"** checkbox (`od-resume-existing`, bound to
  `od.resume`) that appears only for the slug the runtime 409ed "already exists" for, or for
  any name while the listing itself failed (`od-sessions-error` caption) — never for a name a
  healthy listing knows is new (`resume: true` on a missing name is the runtime's own 409). The
  Task prefill follows the picked session and clears when the name moves to a NEW one.
  `validateLaunch` order for dagger: name → name length → return target → trainer attached →
  capability (`REASON.sessionName` / `.sessionNameTooLong` / `.returnNeedsProfile` /
  `.noTrainer` / `.trainerNoCapability`). `SESSION_PATTERN` / `SESSION_MAX_LENGTH` are read
  from the vendored `OnlineDaggerConfig.json` without casts (drift is a `tsc` error).
- Panel: phase pill `WAITING FOR TRAINER` (amber) / `ROLLOUT` (blue) / `TRAINING` (accent; the
  percentage + determinate `progressbar` only when `trainer.progress > 0`, else an
  indeterminate bar) / `TRAINER ERROR — <detail>` (danger; prefers `trainer.detail`, else
  strips the runtime's `trainer error:` prefix). **Take over / Hand back are gated by
  `control_mode` alone** (plus observer / link down) — the v2.0 draft's "no episode open"
  reason is gone because the runtime accepts both at any time, like Space; both share ONE
  reason line (`od-gate-reason`). **Train now** reasons: `observer — another client controls
  this session`, `control link down`, `save or discard the episode first`, `wait for the return
  to start to finish`, `no Online DAgger trainer attached`, the training phase text; ok ack →
  the runtime's detail (fallback `Train now sent — the trainer decides whether to act on it`),
  nack → `Train now refused: <detail>`. `newRolloutReason` checks `trainer_alive` / `trainer`
  BEFORE the phase (mirrors `_refuse_locked`) and feeds `EpisodeControls.newEpisodeReason`
  and the `N` hint. The banner (`online-dagger-banner`, `role="alert"`) reads `ONLINE DAGGER
  TRAINER MISSING — …` / `ONLINE DAGGER TRAINER LOST — no status from <id> for <age>` /
  `ONLINE DAGGER TRAINER ERROR — <detail>`; the UI keeps NO stale window of its own
  (`TRAINER_STALE_S` removed — `trainer_alive` from telemetry, i.e. the runtime's
  `dora.policy.spec_stale_s`, is the only freshness source; v2.0's "dead / stale / error"
  collapses to dead / error). The session actor split is shown ONCE, in the panel
  (`od-expert-frames`, "<expert> / <novice> novice"); `EpisodeControls` lost its `actorSplit`
  prop entirely. The `loss` sparkline (`useLossHistory`, 60 points) renders only once a
  `loss` metric exists (`aria-label` "training loss — no loss reported yet" before). Metric
  rows keep the trainer's wire order; non-finite values are dropped.
- `DatasetsPanel.groupDatasets` claims each row ONCE (first matching group wins), so a
  `default_namespace` remapped to `online_dagger` lists the rollouts under Demonstrations and
  not twice.
- Landing passes `onlineDaggerStatus` and no `datasets` to the sheet; `MODE_LABELS.dagger =
  "Online DAgger"`, the page title `APOLLO MAVIS V2 · Online DAgger`, the Cockpit title
  `Online DAgger · <session_name>`.

## 9. Skill (`mavis-online-dagger-trainer`, shipped in the runtime, mirrored in policy-node)

`SKILL.md` (frontmatter name/description) — for a coding harness in a policy repo: the roles,
prerequisites, the generic `OnlineDaggerTrainer` hooks (`on_session(announce)`,
`on_episode_saved(rollout)`, `on_episode_discarded(episode_id)`, `on_gate(event)`,
`on_train_now()`, `train_if_due() -> TrainResult | None`, `swap_weights() -> int`,
`status_metrics() -> dict`), how the node publishes `trainer_status`, the pause semantics,
the dataset layout (`actor` column, spool), running with `mavis-policy-node --online-dagger
pkg:make_trainer`, testing with the selftest / private control plane, acceptance checklist.
`references/contract.md` — spellings, payloads, refusals, state machine.
`references/pro-dagger-example.md` — implementing PRO-DAgger on the shell with
`mavis_policy_node.pro_dagger` (rollouts per iteration counted trainer-side, offline pool →
reference gradient only, online buffer accumulates every intervention and trains every
iteration, EMA β 0.9, projection, defaults table), plus HG-DAgger in five lines as the trivial
case.

## 10. Policy-node repo

`mavis_policy_node/online_dagger/` (generic: `protocol.py` hooks above, `loop.py` consuming
`session` / `events`, publishing generic `trainer_status`, `fake.py` FakeTrainer: `ready` after
`FAKE_TRAINER_PREPARE_S`, trains for `FAKE_TRAINER_TRAIN_S` after every `FAKE_TRAINER_EVERY`
(2) saved rollouts or on `train_now`, bumps the fake policy's version). `mavis_policy_node/
pro_dagger/` becomes the reference implementation of the hooks (its own config via
`--trainer-config <yaml|json>` or env: `offline_dataset`, `rollouts_per_iteration`, epochs,
lr, batch, `replay_buffer: true`, `max_demos: 0`, `freeze_offline_gref: true`, β, ref
batches, clip, strides, seed). CLI `--online-dagger <fake|pkg:make_trainer>`,
`--selftest online-dagger`. Contract constants + golden updated; skill mirrored.
**As shipped (2026-09-08 evening, after the policy-node review):** `mavis_policy_node/
online_dagger/{protocol, loop, fake, config, datasets, synthetic, selftest}.py` — `protocol.py`
has the `OnlineDaggerTrainer` duck type + `check_trainer`, `TrainResult{policy_version_before=0,
metrics={}, wall_s=0.0, detail=""}`, `RolloutInfo` (alias `Rollout`) built from the
`episode_saved` payload, `SessionInfo` / `GateEvent` Mapping views over the announce / payload
with attribute access, `OnlineDaggerTrainerBase`; `loop.py` — `OnlineDaggerLoop` (ONE worker
thread for every hook except `status_metrics()`, which runs on the publishing thread and may
overlap `train_if_due`; `DEFAULT_TRAINER_ID = "mavis-policy-node/online_dagger"`, the node
passes `trainer.trainer_id or "<policy_id>/online_dagger"`; `TRAINING_VISIBLE_AFTER_S = 0.1`;
a failed `on_session` is STICKY — that session's events are dropped, counted in
`LoopStats.events_dropped_in_error`, only a NEW session id re-runs `on_session`; an event /
poll error clears only when a later `train_if_due` returns a `TrainResult` and the weights
were swapped; `_publish_lock` keeps snapshot order == enqueue order); `fake.py` — `FakeTrainer`
knobs `FAKE_TRAINER_PREPARE_S` 0.5, `FAKE_TRAINER_EVERY` 2, `FAKE_TRAINER_TRAIN_S` **0.5**,
`FAKE_TRAINER_FAIL_AT` 0 (the runtime's own fake in `dora_bridge/nodes/fake_policy.py` uses the
same names with `FAKE_TRAINER_TRAIN_S` default **1.0**), Train now ignored while no rollout is
kept, `n_rollouts` = the rollouts actually trained on. `mavis_policy_node/pro_dagger/{config,
trainer, pgrad, datasets}.py`: `ProDaggerConfig` = the §0 item 7 table plus two undocumented-
in-v2.0 keys `datasets_home` (`~/data`; repo ids resolve LOCALLY as `<datasets_home>/<ns>/<name>`
— the node has no HTTP client) and `save_checkpoints` (true; `<session_dir>/trainer/checkpoints/
iter_<k>.pt`); `offline_dataset` is REQUIRED (empty → `on_session` raises → sticky `error`);
`replay_buffer: false` IS implemented (buffer cleared after each iteration); `ProDaggerTrainer`
raises `"on_session did not complete"` from `on_episode_saved` / `train_if_due` until
`on_session` succeeded; metrics `loss, proj_rate, n_proj, train_steps, n_samples, replay_size,
train_buf, wall_s, scale_check_ratio, iteration`. `node.py` re-publishes `spec` BEFORE any
drained `trainer_status` whenever the version changed (`_last_spec_version_sent`), so the
runtime's acting version never lags the `ready` status. No `trainer_status` is published before
the first announce (the sheet's pill shows only the capability). YAML `--trainer-config` needs
`pyyaml` (present in the venv, NOT declared in `pyproject`); JSON always works.

## 11. Tests

core: config / validators / models / wire / schemas. runtime: coordinator unit (phases,
refusals, discard = event only + no files, train_now, takeover/handback ops, gate events,
resume), recorder `actor` (unchanged), REST, `test_e2e_online_dagger.py` (fake trainer:
waiting → ready → 2 kept rollouts with take-over via the new actions + Space → fake trains →
training refusal → ready with a version bump; one discard leaves NO directory and publishes
the event; session.json rows; `~/…/rollouts/episodes/*/frames.parquet` has `actor`). ui: sheet,
panel, launch.ts, DatasetsPanel, smoke. policy-node: generic loop, fake, pro_dagger example on
top (aggregated buffer default), goldens, e2e on the private control plane.
**As shipped:** the runtime files are `tests/dagger/test_online_dagger_coordinator.py` (23),
`tests/dagger/test_executor.py` (takeover / handback / train_now ops, gate payloads incl. the
closed episode's id, the discard boundary reached from `_op_episode_new`), `tests/dagger/
test_recorder_schema.py`, `tests/test_online_dagger_session.py` (4: in-runtime sim lifecycle
over a fake dora, fresh-directory rollback, unreadable `session.json`, a `start()` failure),
`tests/test_online_dagger_package.py` (4 incl. the byte-identity mirror test), `tests/
test_server_contract.py`, `tests/test_configs.py`, `tests/test_dataset_layout.py`, `tests/
dora_bridge/test_fake_trainer_role.py` (3, no dora) and the dora e2e `tests/dora_bridge/
test_e2e_online_dagger.py` (3: `test_409_matrix_before_any_trainer`,
`test_online_dagger_rollouts_over_the_bus`, `test_skill_endpoints_are_session_less`). Counts and
wall times: §12.

## 12. Implementation record (2026-09-08 evening)

Everything in §0–§11 is implemented as written unless listed here. Written from the code in
the uncommitted working trees (core / runtime / ui on `main`, policy-node under
`~/projects/apollo-mavis-v2-ws-p12/`), the agents' implementation reports and the review /
fix rounds of the same evening; where the reports and the code differed, the code was read.
Spelling authority stays core `protocol/external.py` (dora ids), `protocol/session.py` /
`protocol/telemetry.py` (models); both contract goldens pin the wire.

### 12.1 Deviations from v2.0 and why

| Item | v2.0 said | Implemented | Why |
|---|---|---|---|
| §3 phase rule | `training` → `training` (pause) / `ready` → `rollout` / `error` → `error`; idle / preparing after ready unspecified | `_phase_for(state)` is a pure function of the latest same-session status + the `trainer_seen_ready` latch: `idle` / `preparing` (and `training` without the pause) → `rollout` once ready was seen or `wait_for_trainer_ready` is off, else `waiting_trainer` | the trainer's heartbeat between trainings is `ready` or `idle`; a phase that could only move on `ready` would stick |
| §3 refusal detail | `(<detail>)` | `no trainer status yet` / `the trainer has not picked up this session yet` / the trainer's detail / `<progress>%` (training) / `trainer <state>`; `trainer error: unknown` without a detail | the operator must see WHY the pill is amber |
| §3 aliveness | refusals listed by phase | `_refuse_locked` checks `trainer_alive` FIRST; the UI's `newRolloutReason` does the same | the phase stays `rollout` when the trainer dies; a `rollout` phase alone proves nothing (UI review major) |
| §3 `spool_path` | a string | `null` (event, block, `session.json` row) when the spool write failed; the rollout is still counted and `episode_saved` still fires | a pyarrow / disk error must not turn a save into a silent discard (runtime review) |
| §3 discard reasons | `reason` free | `""` (operator), `"empty episode discarded"`, `"session teardown"`, `"save failed twice - recording degraded (buffer kept)"` | the degraded-save path now tells the trainer; the temp directory is KEPT there per 04-runtime §15 (the only discard that leaves files) |
| §3 gate `episode_id` at the boundary | the open episode's id | the id of the episode that just CLOSED (`_ep_id`, cached at open) | `open_episode_id` is already `None` after `save()`; the e2e pins `== eid` (was `in (eid, None)`) |
| §3 boundary | "fires on the episode leaving recording / saving" | `_settle_boundary` runs on the tick AND from `_op_episode_new` before the new episode opens | commands drain before the tick's boundary check; with return-to-start off an `N` in the next tick hid the discard boundary (runtime review major) |
| §3 discard event pin | — | the coordinator's `publish` closure pins `session_id` at submit | an event still queued at `session_ended()` would spell `""` and be filtered by every trainer |
| §3 `GateEvent.source` | keyboard / auto_advance / episode_reset | `+ "action"` for the explicit `takeover` / `handback` actions (additive `str`) | the trainer can tell a button from Space; rides `episode.json.gate_events` too |
| §3 gate-event scope | "the runtime publishes gate events" (Online DAgger) | ALSO plain external / checkpoint dagger / inference sessions with the bridge on, via `SnapshotPublisher.enqueue_event()` (deque 256, drained on the `dora-publisher` thread); Online DAgger sessions via the coordinator's `SerialWorker` | one hook (`on_gate_events`) for every executor build site; both keep the bus off the tick |
| §3 409 list | already exists / unreadable | `+ "Online DAgger session '<s>' not found"` (`resume: true`, missing name), `+ "dataset 'online_dagger/<s>' is being exported - retry in a moment"` / legacy-tree 409 (`_refuse_exporting_or_legacy`), evaluated after the session-dir rules and before the trainer check | a resume bypassed the export refusal every other recording session gets (runtime review) |
| §3 resume write | `session.json` continues the counters | a RESUMED record is not rewritten until RUNNING (`on_session_start()`); only a FRESH directory gets its first document during bring-up | a resume that 409s later must not point the record at a session that never ran, nor reorder the listing |
| §3 / §7 saved-rollout deletion | — | `DELETE …/online_dagger/<s>/episodes/<id>` is 409 while THAT session runs (`DatasetStore.episode_delete_refusal` hook); other datasets keep "only the open episode is protected" | the coordinator's counters and the trainer's buffer are told about discards, never deletions |
| §3 `R` / Go to profile under POLICY | — | `GatedPolicyExecutor` nacks `reset_to_initial` / `goto_profile` with `"policy driving - take over (Space) first"` while the policy is active and no arm is engaged (recording nack wins) | decided 2026-09-08, 04-runtime §10.5: the planned motion would pre-empt the rollout arm by arm with nothing announced |
| §4 sidecar slot | v1.0 reserved the block before the video finalise and re-checked | `sidecar_block()` is computed once at save; `rollouts_saved` = the count INCLUDING this rollout | the counter only moves on saves, which the single recorder thread serialises |
| §5 `ActionName` tail | `takeover, handback, train_now` last | `…, takeover, handback, train_now, goto_profile` | `goto_profile` (profile row "Go to profile") landed later the same evening, appended last |
| §5 `SessionInfo` | `+ online_dagger` last | `+ fault_detail: str = ""` before it (the 04-runtime §13.3 session notice), `online_dagger` still last | unrelated same-day fix; additive |
| §6 golden | keys after `event_envelope_fields` | `TrainerStatusAnnounce` then `OnlineDaggerAnnounce`; sha256 `4dc67e12…997d`, 3698 B, byte-identical in both repos | — |
| §8 sheet resume | resume pill from the listing | + an explicit "Resume the existing session of this name" checkbox for the 409ed slug or while the listing failed | `resume: true` was unreachable when `GET /api/online_dagger/sessions` failed (UI review) |
| §8 trainer error at launch | — (v1.0 refused Start) | a WARNING caption, never a `validateLaunch` refusal | the runtime does not 409 on a session-less error; a new session is the recovery path |
| §8 Take over / Hand back | "buttons" | gated by `control_mode` (+ observer / link down) only — no "no episode open" reason | `_op_takeover` / `_op_handback` accept at any time, like Space; the return is cancelled by any input |
| §8 banner | dead / stale / error | MISSING / LOST / ERROR; no UI stale window (`TRAINER_STALE_S` removed) | with the default 3 s the STALE branch was unreachable (the runtime flips `trainer_alive` at the same instant); telemetry is the single freshness source |
| §8 actor split | panel + `EpisodeControls` | panel only (`od-expert-frames`); `EpisodeControls.actorSplit` removed with its `"episode"` scope | it was rendered twice in one side panel |
| §8 sparkline | "a `loss` metric gets the sparkline" | rendered only once a `loss` metric exists; `useLossHistory` ring outside React state | an always-on empty canvas with an `img` role was dishonest a11y |
| §8 `DatasetsPanel` | groups by namespace | rows claimed once (first group wins) | `default_namespace: online_dagger` listed the rollouts twice |
| §9 skill threading | "hooks on the node thread, train on ONE worker" (first draft) | ALL hooks except `status_metrics()` run on ONE worker thread; `status_metrics()` runs on the publishing thread and may overlap `train_if_due` | the code; a trainer author following the first text could iterate a dict `train_if_due` mutates |
| §9 skill facts | `offline_dataset` "resolved through `GET /api/datasets`"; metric `std_ratio`; pill shows `idle` before an announce | `datasets_home` local resolution; `scale_check_ratio` (+ `train_buf`, `iteration`); NO `trainer_status` before the first announce — the pill shows only the capability | the code (both skill copies byte-identical) |
| §10 loop error exit | "`error` until a non-error status arrives" (runtime side) | node side: a failed `on_session` is sticky until a NEW session id; an event / poll error clears only on a successful `train_if_due` + swap; "recovered (hook accepted)" is gone | a trainer whose `on_session` failed could be flipped to `ready` by any later event and then train without its reference pool (policy-node review major) |
| §10 spec ordering | — | `node.py` publishes a dirty `spec` BEFORE any drained `trainer_status` (`_last_spec_version_sent`) | the runtime's acting version follows the spec / action metadata only; a rollout opened between `ready v2` and the spec carried v1 and flipped mid-episode |
| §10 `ProDaggerConfig` | the §0 item 7 table | + `datasets_home`, `save_checkpoints`; `offline_dataset` REQUIRED; `replay_buffer: false` implemented | the node has no HTTP client; a declared no-op knob was worse than a working one |
| §10 fakes | one `FakeTrainer` | two fakes with the same knob names: policy-node `FAKE_TRAINER_TRAIN_S` 0.5, runtime `dora_bridge/nodes/fake_policy.py` 1.0; both ignore Train now on an empty buffer | the runtime's e2e needs a stand-in without the policy-node checkout |
| §11 e2e bring-up bound | (v1.0) `POST /api/session` ≤ 3.0 s | dropped from `test_e2e_online_dagger.py` | without the v1.0 offline collect session warming the stack the first policy session took 3.8 s cold; `test_e2e_external_policy.py` keeps the RUNNING-fast requirement |

### 12.2 Verified facts

**Tests (2026-09-08 evening, lab host).** core `uv run pytest -o addopts=""` → **464 passed**
in 3.80 s (re-run read-only for this record); `export_schemas --out schemas/ --check` clean,
43 schema files (`OnlineDaggerConfig`, `OnlineDaggerSessionInfo`, `OnlineDaggerAnnounce`,
`TrainerStatusAnnounce`, `GotoProfileArgs` new; the four `ProDagger*` / `RefGradStatus` files
gone). runtime full suite `uv run pytest -o addopts="" -q -p no:cacheprovider` (dora + egl +
perf, private control plane) → **713 passed, 1 failed, 2 skipped in 688.79 s** after the review
fixes (the failure is the pre-existing `tests/test_return_to_start.py::
test_initial_condition_profile_is_the_fallback_return_target` WS-deadman flake, green alone
and 4/4 on re-run); the non-dora tier after the same-evening `goto_profile` work → **715
passed, 2 skipped, 20 deselected**. The dora e2e **`tests/dora_bridge/test_e2e_online_dagger.py`
3 passed in 30.9–32.3 s** for the file (module setup incl. a teleop initial-condition session
4.5–5.5 s; `test_online_dagger_rollouts_over_the_bus` 23.9–24.2 s alone, 20.7 s inside the
full run; `test_409_matrix_before_any_trainer` 1.4 s; `test_skill_endpoints_are_session_less`
0.01 s). `tests/dagger/test_online_dagger_coordinator.py` 23 tests in 0.2 s;
`tests/test_online_dagger_session.py` 4; `tests/dora_bridge/test_fake_trainer_role.py` 3 in
0.9 s. ui `npx vitest run` → **44 files / 436 tests passed** (re-run for this record);
`gen:check` OK (schemas byte-identical to core), eslint clean, `npm run build` + `check-dist`
OK. policy-node `.venv/bin/pytest -m "not dora"` → **141 passed, 2 deselected in 9.62 s**
(re-run for this record); the dora-marked `tests/test_node_e2e.py` (2, private control plane)
→ 2 passed in 9.9 s incl. the spec-before-status `seq` assertions for v2 and v3; `python -m
mavis_policy_node --online-dagger fake --selftest online-dagger` exit 0, states `[idle,
preparing, ready, training, ready, training, ready, idle]`, policy v1 → v3. Goldens
byte-identical (sha256 `4dc67e123bdfcd314b1f8a764a9d307f3cfa138d1b03a1aa0edf54888c69997d`,
3698 B); the three skill files byte-identical between `apollo-mavis-v2-runtime/src/
apollo_mavis_v2_runtime/online_dagger/skill/` and `apollo-mavis-v2-policy-node/skills/
mavis-online-dagger-trainer/` (`cmp`, re-run).

**`POST /api/session` for an Online DAgger body — the 409s in evaluation order**
(`SessionManager.create()`: `_check_dataset_spec` → hardware matrix → `_check_online_dagger` →
`_check_return_to_start`): on hardware `"hardware sessions support teleop and data collection
only (dagger on hardware: not yet)"` (D7, before anything else); `"Online DAgger session '<s>'
already exists - resume it or pick another name"`; `"Online DAgger session '<s>' not found"`;
`"Online DAgger session '<s>': session.json is unreadable - fix or remove it"`; `"dataset
'online_dagger/<s>' is being exported - retry in a moment"` (or the legacy-tree text); `"no
external policy attached (dora bridge is not attached)"` / `"no external policy attached (no
policy_spec heartbeat within 3 s)"`; `"no Online DAgger trainer attached (the policy node does
not report the online_dagger capability)"`; then the shared return-to-start 409. 422s are
core's: `"online_dagger requires mode dagger"`, `"online_dagger requires policy_source
'external'"`, `"online_dagger derives the rollouts dataset - leave dataset unset"`, unknown
keys (`extra="forbid"`), `session_name` > 64 chars or off `SLUG_RE`.

**WS nacks / acks while running.** `episode_new`: `"no Online DAgger trainer attached"`,
`"waiting for the trainer to report ready (<detail>)"`, `"training in progress (<detail>)"`,
`"trainer error: <detail>"`, then the recorder's own (returning / busy). `train_now`: ok
`"asked the trainer to train (<n> rollout(s) saved)"`; nack `"save or discard the episode
first"`, `"no Online DAgger trainer attached"`, `"not an Online DAgger session"` (any other
session). `takeover`: ok `"takeover_transition"` / `"already taken over"`; nack `"takeover
active"`, `"no active arm"`, `"takeover not available in teleop"`. `handback`: ok `"policy"` /
`"policy already driving"`; nack `"takeover active"`, `"takeover not available in teleop"`.
`reset_to_initial` / `goto_profile` under POLICY: `"policy driving - take over (Space) first"`.
`DELETE /api/datasets/online_dagger/<s>/episodes/<id>` mid-session: 409 `"dataset
'online_dagger/<s>' is in use by the running Online DAgger session - end the session first
(the trainer is told about discards, not deletions)"`.

**REST.** `GET /api/online_dagger/skill` → 200 `text/markdown; charset=utf-8` | 404 `"Online
DAgger skill not found: <OSError>"`; `GET /api/online_dagger/skill.tgz` → 200 `application/gzip`
+ `Content-Disposition: attachment; filename="mavis-online-dagger-trainer.tgz"` | 404;
`GET /api/online_dagger/sessions` → 200 `OnlineDaggerSessionInfo[]`; `GET /api/datasets/layout`
→ 200 `DatasetLayoutInfo`; `GET /api/pro_dagger/{skill,sessions}` → 404. Config:
`RuntimeConfig.online_dagger: OnlineDaggerRuntimeConfig{skill_dir: Path | None = None,
session_file_hz: float = 1.0 (> 0)}`; `RuntimeConfig.datasets{default_namespace: "bc_demo",
namespaces: {bc_demo: {root: ~/data/bc_demo}, online_dagger: {root: ~/data/online_dagger,
subdir: rollouts}}}` — identical in `configs/mavis_v2.yaml` and `configs/sim.yaml`.

**Event payloads (`EventEnvelope.payload`; `session_id` pinned on every coordinator event).**
`gate {arm_id, mode, seq, source: keyboard | action | auto_advance | episode_reset,
episode_id}`; `episode_saved {episode_index, summary: EpisodeSummary (with episode_id,
n_expert_frames, n_novice_frames), dataset_root, spool_path | null, run_id | null,
online_dagger: {episode_id, rollouts_saved, actor_counts: {novice, expert}, policy_version,
spool_path | null}}`; `episode_discarded {episode_index, episode_id, reason}`; `train_now
{rollouts_saved, requested_by: "operator"}`. `EVENT_KINDS` = `collision, gate, episode_saved,
episode_discarded, policy_anomaly, policy_swap, policy_version_changed, reset_watermark,
session_error, train_now` (10). The e2e observed, for two kept + one discarded rollout: 9 gate
events with one session-wide `seq`, `reset_watermark` reasons `episode_boundary` + `handback`,
`policy_version_changed` (1 → 2), (2 → 3) never mid-episode.

**`session.json` as `to_session_json()` writes it** (`json.dumps(indent=2, sort_keys=True)`,
tmp + `os.replace`, ≤ `session_file_hz` outside transitions):

```json
{
  "session_name": "s1", "created_at": "<ISO-8601 Z>", "session_id": "<uuid>", "task": "…",
  "spec": { "<SessionSpec.model_dump(mode='json')>": "…" },
  "paths": { "session_dir": "~/data/online_dagger/s1", "rollouts": "~/data/online_dagger/s1/rollouts" },
  "rollouts": [ { "episode_id": "…", "saved_at": "<ISO>", "actor_counts": { "novice": 812, "expert": 143 },
                  "policy_version": 1, "spool_path": "…/rollouts/trainer_spool/ep_<id>.parquet" } ],
  "trainer_log": [ { "at": "<ISO>", "state": "preparing | ready | training | error | idle | swapped",
                     "policy_version": 1, "detail": "policy v1 -> v2" } ],
  "current": { "phase": "rollout", "rollouts_saved": 2, "expert_frames_session": 286, "novice_frames_session": 1624 },
  "last_used_at": "<ISO>"
}
```

`trainer_log` keeps the newest 200 rows (one per trainer STATE change + one `swapped` row per
acting-version change). `OnlineDaggerSessionInfo.rollouts` = `current.rollouts_saved`. The
session directory holds `rollouts/` + `session.json` ONLY; the e2e asserts no trainer artefact
appears in it (the fake writes nothing; the PRO-DAgger reference implementation writes under
`<session_dir>/trainer/` by its own choice). `episode.json["online_dagger"] = {session_name,
rollouts_saved, policy_version, actor_counts}`; `frames.parquet.actor == (control_mode != 0)`;
the spool `trainer_spool/ep_<id>.parquet` carries the nine `SPOOL_COLUMNS` with `actor` last.

**Threads.** Coordinator side effects (events + `session.json`) leave through ONE
`SerialWorker` thread; measured lock-hold cost on the tick is negligible (`to_session_json`
0.04 ms, `status()` 2 µs — runtime review); plain-session gate events go through the publisher
deque. `trainer_status` arrives on the `dora-bus` thread (`ExternalPolicyHub._on_trainer_status`
→ `coordinator.on_trainer_status(msg, t_recv)`; the cached status is replayed on
`attach_trainer_sink`); `policy_version_acting` moves on `on_spec_version` from the spec
heartbeat or an action's metadata.

### 12.3 Open items

1. **Perf flake** — `tests/dora_bridge/test_perf_bridge.py::test_teleop_tick_rate_with_bridge_on_and_off`
   (`perf` marker) failed 2/4 today with ONE overrun (one from a 74.7 ms gen-2 GC pass) while
   the operator's dev runtime (`python -m apollo_mavis_v2_runtime --config var/mavis_v2_local.yaml`,
   94 % CPU) shared the host; the test's own comment already records 1-in-4. Not a regression
   of this work (it spawns no fake node). Accept, gate on load, or rerun with the dev runtime
   stopped. The `test_return_to_start.py` flake is the encoder GIL-stall / WS-deadman follow-up
   in CLAUDE.md.
2. **Hardware (D7)** — `dagger` on hardware is still 409 before any Online DAgger check runs;
   nothing here was exercised on the real cell or the lab dora plane (sim + the two fakes
   only). The runtime must be restarted to pick any of it up.
3. **Gate-event publication scope** — `events.gate` is now session-wide for every policy
   session with the bridge on; `events.episode_discarded` is still published by Online DAgger
   sessions ONLY (plain external / checkpoint dagger and collect sessions publish nothing on
   a discard — 15-pro-dagger §15.3 item 11, a main-agent call).
4. `render-lab-config.sh` rewrites `datasets_root` but does not template
   `datasets.namespaces` (the lab render keeps the YAML's `~/data/…` roots).
5. The two fakes disagree on `FAKE_TRAINER_TRAIN_S` (runtime 1.0 s, policy-node 0.5 s); the
   runtime fake's `n_expert_frames` fallback mixes `actor_counts.expert` with
   `summary.n_expert_frames` (same actor semantics, no mismatch today).
6. `ExternalStatus.trainer_status` is `null` until a trainer serves its first session (neither
   fake nor the policy-node loop heartbeats before an announce); the launch sheet's pill shows
   only the capability then — documented in the skill, not changed.
7. The policy-node loop merges `status_metrics()` into every status incl. the final `idle`
   after a session ends (informational); the runtime ignores null-session metrics.
8. `pyyaml` is not declared in the policy-node `pyproject` (YAML `--trainer-config` works only
   in the dev venv; JSON always works).
9. The pre-existing "Discarding event for input policy_spec due to queue size limit" log noise
   (the fake re-publishes `spec` on every session announce) was not re-examined.
10. Core's `SessionTelemetry.translate_frame` comment and the runtime default say `world`
    (operator decision 2026-09-08 evening, 15-pro-dagger §0 item 8); CLAUDE.md still said
    `camera` when this was written — **closed 2026-09-08 late evening**: CLAUDE.md now reads
    "Keyboard translate frame default = WORLD" (its "Teleop input interfaces" section). The
    core comment's pointer into the superseded `15-pro-dagger` is a code comment (not
    touched here); the decision it cites is recorded in 04-runtime §6 and CLAUDE.md
    ("Teleop input interfaces"), not in this document.
11. The runtime keeps no per-session log of `train_now` requests the trainer ignored; only the
    trainer's `detail` (e.g. the fake's `train_now ignored: no rollouts saved yet`) says so.
