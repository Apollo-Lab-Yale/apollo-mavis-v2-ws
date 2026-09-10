# apollo-mavis-v2-ws — guidance for Claude

## What this is

Development workspace for **MAVIS v2** (Manipulation And Viewpoint Selection v2),
the Apollo Lab (Yale) dual-arm cell: two UFACTORY xArm7 arms on 0.65 m linear
tracks over one table — the **Manipulation Arm** (id `grip`: xArm Gripper G2 +
wrist camera) and the **Perception Arm** (id `view`: wrist RealSense D435i + RØDE
NT-USB Mini microphone, no gripper). Use those names everywhere a person reads
them; the ids stay internal. The stack targets exactly this cell, real or as its
MuJoCo digital twin (scene `mavis_v2`, the only scene the UI exposes), not xArm7 in
general. Five repos: `apollo-mavis-v2-core` (interfaces/schemas/protocols) ←
`apollo-mavis-v2-hardware` (real xArm7 + track drivers) and `apollo-mavis-v2-sim`
(MuJoCo) ← `apollo-mavis-v2-runtime` (teleop / collect / DAgger / inference +
server) ← `apollo-mavis-v2-ui` (React + Vite + TS).

The five sub-repos are **git submodules** of this workspace, each tracking its own
`main`; a ws commit pins a known-good combination. Work inside a sub-repo on `main`
(never a detached HEAD — `git -C <sub> switch main` if `git submodule status` shows
one), commit + push there first, then bump the pointer here. Fresh checkout:
`git clone --recurse-submodules <ws-url>`.

## Where truth lives

- `docs/design/00-overview.md` — the spine: system contract and architecture
  decisions. Read it before touching any sub-repo.
- `docs/design/` — per-repo designs and cross-cutting protocols. **Measurement
  histories and root-cause write-ups live there, not here.** Pointers: cell
  geometry + wrist-camera extrinsics → 03-sim §4.3, the 2026-09-09 overlay-alignment
  root cause → **03-sim §4.5**, and the header of
  `apollo-mavis-v2-sim/src/apollo_mavis_v2_sim/assets/scenes/mavis_v2.yaml`;
  cameras → 02-hardware §8, 04-runtime §14; microphone → 04-runtime §14/§14.1,
  05-ui §8.1, `docs/deploy/DEPLOYMENT.md`; control boxes, SDK quirks, the first
  live session → 02-hardware §12–§16; hardware session
  bring-up / rail homing → 04-runtime §5, §13.1; teleop pipeline, servo caps,
  pose filter → 04-runtime §6, 13-tracker §4; joint panel + WS deadman →
  04-runtime §7, 05-ui §5.2/§8.3, 11-safety §10.1; logging → 04-runtime §14;
  libsurvive / controller link → 13-tracker §3 item 7b, §6, §7; datasets → 10-frames
  §7–§11, 04-runtime §10; keyboard translate frame + return-to-initial →
  04-runtime §6 and §10.5, 05-ui §8.2; **Online DAgger** (operator decisions,
  coordinator phases + refusals, core models, wire, config / REST, UI, skill,
  policy-node, implementation record) → 15-online-dagger §0, §3, §5–§10, §12
  (`15-pro-dagger.md` v1.0 is history only — superseded the evening of
  2026-09-08); the per-repo Online
  DAgger amendments → 04-runtime §10.7, 05-ui §8, 10-frames §7.4 / §11.10,
  12-dagger, 14-dora; dora bus + external policy → 14-dora; the **kitchen twin**
  `mavis_v2_kitchen` and its 2026-09-09 measurement → 03-sim §4.4 and the header of
  `apollo-mavis-v2-sim/.../assets/scenes/mavis_v2_kitchen.yaml`.
- `docs/prompts/phase-XX-*.md` — the phased plan; one phase = one session's work,
  status table in `docs/prompts/README.md`.
  **Next: re-measure the cell so the twin matches the room (03-sim §4.5 — the
  overlay residual is ~18 px / 15–30 mm and the gate cannot see the kitchen or the
  cart), then the first hardware run of phase-12 / 13 / 14 code with the operator
  present; the first policy-repo trainer on the Online DAgger shell (sim);
  admitting Online DAgger on hardware is the operator's call (D7).** Phase-15
  (GELLO Manipulation) was implemented on 2026-09-09 and then CUT the same evening
  at the operator's request — see "GELLO Manipulation was cut" below.
- `docs/deploy/DEPLOYMENT.md` — the lab machine, services, network profiles,
  troubleshooting. `docs/research/` — background notes, reference only.

## Conventions

- Converse with the user in Chinese; write code, comments and repo docs in English.
- Python ≥3.10 for core / sim / hardware, **3.12 for runtime** (lerobot floor);
  all `uv`-managed. Each sub-repo is an installable package (`apollo_mavis_v2_*`).
- Dependency direction is strict: core depends on nothing in the stack; hardware /
  sim depend only on core; runtime depends on core (+ hardware / sim as extras);
  ui talks to runtime over HTTP / WebSocket only.
- Commit / push in sub-repos only when the user asks. Never rewrite the
  operator's settings unasked (next section).

## Rules that protect the cell

- **No implicit motion.** The driver's `connect()` never homes a track; `home_rail`
  (Hardware-tab arm card, twin-gated, session-less) is the ONLY motion-class
  maintenance op. Error clearing, `apply_backstops` and `recover` produce no
  motion. Teardown leaves the arms stopped with brakes engaged; tracks keep their
  homed state.
- **`hardware_session.armed` gates every real driver connection.** The repo config
  is `false`; only a RENDERED config arms it (lab render `render-lab-config.sh` with
  `HARDWARE_ARMED=true`, or the dev render `mavis-dev.sh render` with the gitignored
  `scripts/dev/local.env`). Never set `armed: true` in a tracked config. Never run
  the runtime test suite on the lab machine without the `tests/conftest.py`
  guard (on 2026-09-05 a test without the fake seam started a rail-homing job on the
  real Manipulation Arm; 04-runtime §16).
- **Never run `uv run` in a sub-repo whose venv a live runtime is executing from.**
  `uv run` re-syncs the environment: it rebuilds and REINSTALLS the package
  (`Building apollo-mavis-v2-runtime … Uninstalled 1 package … Installed 1 package`),
  which deletes and rewrites the site-packages the already-running process is importing
  from. On 2026-09-10 two `uv run pytest` invocations (two Claude sessions at once) in
  `apollo-mavis-v2-runtime` killed the dev runtime **mid hardware session**: the log
  stopped mid-health-line with no traceback and no teardown, so the arms were left
  enabled instead of stopped-and-braked, and the operator's next click answered 500 from
  a dead server. Same class of hazard as the 2026-09-05 test-suite incident. Rules:
  **stop the runtime first** (`scripts/dev/mavis-dev.sh stop runtime`), or run the tests
  from a separate git worktree, or use `uv run --no-sync` for read-only tools when you
  are certain the lockfile is unchanged. Never with a session open. And **never two test
  runs in the same tree at once** — that is how the venv got rewritten under a live
  process in the first place.
  **The venv's own entry points are safe** — `.venv/bin/pytest`, `.venv/bin/python -m …`,
  `.venv/bin/python -m ruff` do NOT re-sync; only `uv run` does. That is the usable form
  of this rule: you can test and lint with a runtime live, you just must not go through
  `uv run` to do it (verified 2026-09-10 — the whole playback suite plus ruff ran against
  a live dev runtime this way with no effect on it).
- Never open UFACTORY Studio "Live control" during a session. Controller
  `state 2` (standby) is HEALTHY for a mode-1 arm holding a posture; `clean_error`
  returning 1/2/9 is a status echo, not a failure (02-hardware §16).
- Both arms are always in a hardware session; the default active arm is ALWAYS
  the Manipulation Arm (hardware and sim).
- **Twin-planned multi-arm motions execute ONE ARM AT A TIME in the planner's
  `arm_order`** (`SessionManager._execute_arms`: return phases, per-episode return,
  `start_from`, `goto_profile`; 2026-09-08 incident: simultaneous execution of
  sequentially planned paths blocked the gate at 5 mm). A plan the gate holds for
  `hardware_session.plan_gate_hold_s` (3 s) is cancelled by the loop with the
  blocking pair in the reason — never wait out the 30 s budget to learn the pair.
- **A plan from inside the inflation shell starts with an OPENING escape that mirrors
  the gate's T8 rule (2026-09-09)**: every pinched pair opens every tick, no new pair
  enters the shell, `no_escape` when that is impossible; the finished path is
  re-verified at the executor's tick resolution (11-safety §9, 03-sim §10). Never
  whitelist a violating pair in the planner again — the gate is the safety authority.
- **The twin does NOT model the room the cell now sits in (measured 2026-09-09, 03-sim
  §4.5).** The blue cart with the toy food stands at table height ~0.29 m inside the twin
  table's operator-side edge, and the kitchen run of 03-sim §4.4 is absent from `mavis_v2`
  — the scene the gate, the planner AND the overlays use. The gate is therefore blind
  there: at 19:05 on 2026-09-09 a twin-planned, gate-approved `return_home` on the
  Manipulation Arm was cancelled 10 s in by `controller error 31: Collision Caused
  Abnormal Current`, twice. Until the cart and the appliances are in the scene, treat
  every planned motion (return-to-start, `R`, `goto_profile`, `home_rail`) as unverified:
  10 % speed, hand on the E-stop. And it is not only the furniture — **the arms and their
  rails themselves are ~15–30 mm out** in the twin (03-sim §4.5 addendum), which is why the
  gate's shell was raised to 25 mm. Careful with the `*_align` overlays as evidence: at a
  posture whose twin frustum holds only floor, the Manipulation Arm's overlay draws NOTHING
  (`mask_fraction` 0.0 exactly) and the Perception Arm's draws only its known-wrong
  microphone body — judge alignment only where the twin predicts geometry in frame.
- Driver caps at speed scale 1.0: `max_joint_vel` 0.6 rad/s, `max_cart_step_m`
  0.004 (= 4 mm/tick, once deliberately HALF the gate's 8 mm inflation — the lab cell's
  shell is 25 mm since 2026-09-09, so the step is well inside it; do not raise the step
  without re-checking the gate), rail 50 mm/s. Hardware tab picks 10 / 50 / 100 %,
  default 100 % (operator decision 2026-09-08 evening; 50 % was the 2026-09-07 call).

## Operator-owned settings — do not change unasked

- The Vive controller map (`tracker.controller_map`: clutch trigger, gripper
  pad up/down, rail pad left/right, arm_next menu) — code default and lab YAML
  are identical. A 2026-09-07 remap "to work around" a pad bug was wrong and was
  reverted; the bug was in `note_edges` (13-tracker §1.1).
- The keymap (00-overview §5) and the input-interface decision below.
- Pose filter values (`beta 5.0`, `d_cutoff_hz 1.0`, `deadband_m 0.001`): re-run
  the two experiments in `control/pose_filter.py`'s docstring before touching them.
- Speed default 100 % (operator decision 2026-09-08 evening; 50 % was 2026-09-07),
  the user-facing arm names, the `mavis_v2` scene as the only exposed scene.

## Teleop input interfaces (operator decisions, 2026-09-07 / 09-08)

- The **Vive controller and the keyboard are peers**; the gamepad mirrors a subset.
  Keyboard (00-overview §5, 01-core §13): `W/S` forward/back, `A/D` left/right,
  `E/Q` up/down, `I/K` roll, `J/L` pitch, `U/O` yaw, `F/H` gripper close/open,
  `←/→` rail, `Tab` / `Z` switch arm, `C` clutch (hold), `Space` takeover (DAgger /
  inference), **`R` return to the initial condition**, **`N` new episode, `Enter`
  save, `Backspace` discard**.
- **Keyboard translate frame default = WORLD** (`control.translate_frame`,
  default `world`: `W` away from the operator = −Y, `A` operator's left = +X,
  `E` up; operator decision 2026-09-08 evening — that morning's default `camera`
  was superseded the same day). `camera` = the active arm's WRIST CAMERA (W along
  the optical axis, A/D, E/Q image left/right, up/down — follows the tool so the
  keys match the wrist stream); `base` = the pre-2026-09-08 arm-base axes.
  Rotations stay about the TCP axes in every frame. Under `camera` the camera
  orientation is read from the model PER ARM — the gripper base is mounted 180°
  about the tool axis under link7, so one constant key→TCP matrix reverses `A/D`
  and `E/Q` on the Manipulation Arm (04-runtime §6; `tests/test_camera_frame.py`).
  The runtime e2e suites pin `translate_frame: "base"` because they assert
  displacement along their test scenes' base axes; `tests/test_configs.py` pins
  the `world` default on both shipped configs. **Property of `camera` to say out
  loud: `E`/`Q` are up/down in the WRIST IMAGE, not world up/down** — with the
  tool aimed at the table they run nearly horizontal and `W` runs into the table.
  The live frame is captioned above the keymap overlay
  (`telemetry.session.translate_frame`; `world` reads "(the default)").
- Precedence: while any source holds the clutch (trigger / `C` / RT) the tracker
  pose drives translation and rotation and keyboard translate / rotate keys are
  ignored; gripper and rail inputs from every source merge; clutch released ⇒ the
  keyboard drives. Unchanged runtime rule.
- **Do not remove keyboard teleop again.** An uncommitted 2026-09-07 core change
  flagged every held row `keyboard=False` and put episode save / discard on
  `KeyS` / `KeyF` (colliding with −x / gripper close); phase-13 reverts it.

## Datasets (operator decisions, 2026-09-07 / 09-08)

- **One directory per episode** (`episodes/<episode_id>/{episode.json,
  frames.parquet, video/<camera_id>.mp4, audio.wav}`); ids are capture-time
  stamps, never reused or renumbered. **Roots are per namespace (operator
  decision 2026-09-08, 15-online-dagger §0 item 6 / D5)**: demonstrations
  `bc_demo/<name>` → `~/data/bc_demo/<name>` (the default namespace — a bare
  `dataset: "<name>"` resolves there), Online DAgger rollouts
  `online_dagger/<session>` → `~/data/online_dagger/<session>/rollouts` (next to
  `session.json`; whatever the trainer writes beside them, e.g. `trainer/`, the
  runtime never reads), every other namespace → the generic `datasets_root`
  (`var/datasets/<ns>/<name>`, where the old `apollo/...` data stays listable /
  deletable). `~` is the HOME of the account running the runtime; the roots live
  OUTSIDE `var/` on purpose. `GET /api/datasets/layout` publishes the map — the
  UI never hard-codes a namespace. Repo ids keep the `<ns>/<name>` grammar
  everywhere. **LeRobot v3 is a derived export** (`exports/lerobot_v3/`, built by
  stream-copy remux — never a re-encode). Deleting an episode removes one
  directory (409 for a saved rollout of the RUNNING Online DAgger session).
  Spec: 10-frames §11, 04-runtime §10, 15-online-dagger §7; UI: 05-ui §8.1
  items 6–7. (`~/data/pro_dagger` never shipped — the morning-of-2026-09-08 name.)
- After every episode save / discard the arms **return to the start profile by
  default** (twin-planned, gated, cancelled by any input; per-session opt-out;
  409 at launch when no start / initial-condition profile exists) — 04-runtime
  §10.5. Operator decision 2026-09-07. **Applies to Online DAgger rollouts too**
  (`return_to_start` is a collect-or-dagger field since 2026-09-08, D6).
- Every DAgger / Online DAgger frame carries the **`actor` column** (int8, `0`
  novice / `1` expert, `actor = 1 iff control_mode != policy`) next to
  `control_mode` / `intervention`; `EpisodeSummary.n_expert_frames /
  n_novice_frames` count it; `episode.json` and `events.episode_saved` carry the
  per-rollout actor counts. Training labels stay `control_mode == human`
  (12-dagger). Operator decision 2026-09-08 (§0 item 3 / D4).
- **Return to the initial condition (operator request 2026-09-08)**: the `R` key
  (`reset_to_initial`, fire-and-forget) and `POST /api/session/return_home`
  (synchronous — the Cockpit's "End session" runs it BEFORE the DELETE and shows
  a dialog if the arms did not get there, offering "End session anyway"). Two
  separately planned + gated phases: joints first with the carriages held, then
  the carriages. Both are no-ops with a reason when no initial condition is
  designated. `teardown()` still produces NO motion of its own. 04-runtime §10.5.
- The default posture lives in the profile store, seeded by `python -m
  apollo_mavis_v2_runtime.profiles.seed_initial` (one initial-condition profile
  per workcell kind, idempotent): Manipulation Arm
  `[-180, -12, -20, 30, -5, 35, -8.9]°`, Perception Arm
  `[0, 0.8, 0, 28.9, 0, 28.2, 0]°`, carriages left unset (kept where they are).
  Twin-verified collision-free at both carriage ends, mic on and off, and
  plannable from the keyframe. Seeded into `var/profiles/` on 2026-09-08.
- **`Kitchen Interaction` is an ORDINARY profile, not an initial condition**
  (operator request 2026-09-09 evening; `python -m
  apollo_mavis_v2_runtime.profiles.seed_kitchen`, 04-runtime §10.5). **Only the
  Perception Arm differs from the default posture** (operator request 2026-09-10): it
  goes to `[2.646, -1.598, 0.018, 1.637, 0.25, 2.007, 0.029]` rad with its **carriage
  pinned at 0.0** (the kitchen numbers were deprojected from a frame taken there, so
  the appliances only line up from that carriage position), while the Manipulation
  Arm's entry is DERIVED from `seed_initial` with its carriage unset — so a goto from
  the default moves the Perception Arm and NOTHING else. Before 2026-09-10 the grip
  entry was the kitchen SCENE's keyframe (factory zero, carriage 0.65) whose joint 1
  is `+π` where the default's is `−π`: same orientation, 360° of joint travel, so
  every kitchen goto rotated the Manipulation Arm a full circle first. Verified
  collision-free on both twins, mic on and off, at the 25 mm shell, at EVERY grip
  carriage position 0.000–0.650 m (tightest pair 75.3 mm) — that sweep is why the pin
  could go. Re-seeded into `var/profiles/` for both kinds on 2026-09-10; the live
  runtime picked it up with no restart. **A store seeded earlier holds the old
  numbers — re-run the seed.**
- Never write a vanilla LeRobot v3 dataset from the recorder again; never edit an
  export in place — regenerate it.
- Recording filters idle / small-motion frames by default (`SessionSpec.
  action_filter`, checkbox in the Collect launch sheet): the pro-dagger
  hesitation heuristic and its defaults (1 mm / 1 mrad / 1 % / 1 mm vs the last
  kept frame, gripper changes exempt within 1.6 s) — operator decision
  2026-09-07; 04-runtime §10.5, 10-frames §11.4.

## Online DAgger (operator decisions 2026-09-08 evening; 15-online-dagger v2.0 is the contract)

- The landing page's third card is **Online DAgger** — an algorithm-agnostic
  shell. The runtime knows NO DAgger algorithm: no iterations, hyper-parameters,
  reference gradients or offline-dataset picker anywhere in core / runtime / ui
  (§0 items 1–3). That morning's PRO-DAgger shell (`15-pro-dagger.md` v1.0,
  `ProDaggerCoordinator`, `~/data/pro_dagger`, `/api/pro_dagger/*`,
  `iteration_complete`) never shipped and was deleted, not aliased.
- **D1** wire: `mode: dagger` + `policy_source: external` + a non-null
  `SessionSpec.online_dagger` (`session_name` slug ≤ 64, `resume`,
  `pause_while_training`, `wait_for_trainer_ready`; `extra="forbid"`); people
  read "Online DAgger" everywhere (card, sheet, Cockpit title, keymap overlay).
- **D2** ONE generic inbound stream `trainer_status` (`idle | preparing |
  training | ready | error`, free-form finite `metrics`, MUST echo the announced
  `session_id` — `null` counts as alive only); ONE generic gate: `episode_new`
  is refused while the trainer reports `training` and, with
  `wait_for_trainer_ready`, until it has reported `ready` once for this session
  (`"waiting for the trainer to report ready (…)"`, `"training in progress (…)"`,
  `"trainer error: …"`, `"no Online DAgger trainer attached"`).
- **D3** the runtime publishes `events.gate {arm_id, mode, seq, source,
  episode_id}` on every take-over / hand-back and accepts explicit `takeover` /
  `handback` actions (idempotent) beside `Space`; keymaps untouched. Cockpit
  buttons Take over / Hand back / **Train now** (`train_now` →
  `events.train_now`; refused only while an episode is open or the trainer
  status is stale; the trainer may ignore it).
- **D4** rollout bookkeeping stays in the recorder (`actor` column, counts in
  `episode.json` + `events.episode_saved.online_dagger`); a **discard leaves
  nothing on disk** and publishes `events.episode_discarded` only (§0 item 5).
- **D5** session dir `~/data/online_dagger/<session>/{session.json, rollouts/}`
  (namespace `online_dagger`, subdir `rollouts`); the trainer's artefacts are
  its own business (skill suggests `<session>/trainer/`). **D6** return-to-start
  applies to rollouts (default ON). **D7 hardware still refuses dagger**
  (`409 hardware sessions support teleop and data collection only`) until the
  operator says go.
- **D8** the skill is **`mavis-online-dagger-trainer`** (the generic
  `OnlineDaggerTrainer` hooks + `references/contract.md` + a worked
  `references/pro-dagger-example.md`), shipped INSIDE the runtime wheel
  (`GET /api/online_dagger/skill` + `/skill.tgz`) and mirrored byte-for-byte in
  the policy-node repo (a runtime test enforces it — edit both copies together).
  One-liner shown in the sheet: `curl -s http://<lab-host>:8765/api/
  online_dagger/skill.tgz | tar xz -C ~/.claude/skills/` (port **8765**, never 8000).
- REST: `GET /api/online_dagger/{skill,skill.tgz,sessions}`; `POST /api/session`
  409s in order: session-dir rules (`"Online DAgger session '<s>' already exists -
  resume it or pick another name"` / `… not found` / `… session.json is
  unreadable`), exporting / legacy tree, `no external policy attached (…)`,
  `no Online DAgger trainer attached (the policy node does not report the
  online_dagger capability)`.
- Policy-node repo: `~/projects/apollo-mavis-v2-ws-p12/apollo-mavis-v2-policy-node`
  (independent git repo, no remote yet). Generic shell `mavis_policy_node.
  online_dagger` (`OnlineDaggerTrainer` hooks, `OnlineDaggerLoop`, `FakeTrainer`,
  `selftest`); CLI `mavis-policy-node --online-dagger <fake|pkg.mod:make_trainer>
  [--trainer-config <yaml|json>]`, `--selftest online-dagger` (no dora needed);
  `spec.capabilities` lists `online_dagger`. **PRO-DAgger = the reference
  implementation on top** (`mavis_policy_node.pro_dagger`, `--online-dagger
  mavis_policy_node.pro_dagger:make_trainer --trainer-config pro_dagger.yaml`;
  `offline_dataset` required in ITS config, resolved under `datasets_home`
  `~/data`) with the corrected defaults: `freeze_offline_gref: true` (offline
  pool → reference gradient only) and `replay_buffer: true`, `max_demos: 0`
  (the online buffer accumulates every intervention and trains every iteration)
  — §0 item 7. Say "PGrad" / "projected gradient", never "A-GEM". The runtime's
  `nodes/fake_policy.py` (`FAKE_TRAINER=1`, knobs `FAKE_TRAINER_PREPARE_S /
  _TRAIN_S / _EVERY / _FAIL_AT`) is the e2e stand-in; sim e2e
  `tests/dora_bridge/test_e2e_online_dagger.py`.

## GELLO Manipulation was CUT (operator decision, 2026-09-09 evening)

- Phase-15 shipped a fifth mode "GELLO Manipulation" on 2026-09-09 and it was
  **reverted the same evening at the operator's request** — they did not want to keep
  debugging the leader. Reverts: core `236a769`, runtime `629002f`, ui `2704aaf`
  (partial — the clearance fix stayed), plus this file and the docs. `16-gello.md`
  and `phase-15-gello.md` are DELETED; the history is in the reverted commits
  (`0654570`, `0eeb681`, `a40df01`, `30f06ab`). **Do not re-add any of it unasked.**
- Why: the leader's Dynamixel bus is **silent**. The adapter is a genuine U2D2-class
  FTDI FT232H (`0403:6014`, descriptors `FTDI / USB <-> Serial Converter / FTAKROCJ`,
  `/dev/ttyUSB0`) and it enumerates and opens fine, but on 2026-09-09 — twice, with
  the servo supply OFF and then ON — no id answered a per-id or BROADCAST ping at
  9600 … 4 M on protocol 2.0 or 1.0, a hand-built protocol-2.0 broadcast packet read
  back 0 bytes, and toggling RTS / DTR changed nothing. So it is not the host, the
  driver or the baud. Remaining suspects are physical: the servo supply board and its
  LED, the chain plugged into the U2D2's 3-pin TTL port rather than the 4-pin RS-485
  one, a dead first servo blocking the daisy chain, or a supply voltage wrong for the
  servo model. The FTDI `latency_timer` is still 16 ms — the 1 ms udev rule was never
  installed (the agent has no passwordless sudo) and its GELLO lines were reverted
  out of `scripts/tracker/01-sudo-udev-and-deps.sh` with the rest.
- **KEPT deliberately, because it has nothing to do with the leader:**
  - the **kitchen twin** `mavis_v2_kitchen` (03-sim §4.4 + the YAML header): the
    fridge / range / counter / cabinets / wall that really do stand in front of the
    cell, plus the four AprilTag plates. Still `hidden` — `GET /api/scenes` lists
    only `mavis_v2` — but now selected EXPLICITLY in config with
    `workcells.<kind>.digital_twin_scene` (hardware) or `sim_scene` (sim), which
    points the GATE and the PLANNER at the appliances too, not just the overlays.
    Its `graspable` handles and the textured / mesh / non-collidable
    `EnvironmentSpec` support stay with it.
  - the **clearance readout fix** (05-ui §8.2, the operator's other request that
    day): the row COUNT was always ≤ 5 — long labels wrapped in the 320 px column
    and the panel sat above the episode buttons; now 4 one-line rows with their own
    `max-height` + scroll and `EpisodeControls` ABOVE the readout.

## Work in progress (2026-09-09)

- **Phase-12 / 13 / 14 and the 2026-09-08 follow-ups are COMMITTED and PUSHED**
  (2026-09-09 05:46: core `7d9400a`, hardware `0e33d45`, sim `fb1a4af`, runtime
  `17d8bc7`, ui `eca22df`, ws `e16d2c1`). **None of it has run on the real arms.**
- **Phase-15 (GELLO) was implemented, pushed, and then reverted the same evening** —
  see the section above. What remains of it: the kitchen twin and the clearance fix.
- **The two arms and their rails are ~15–30 mm out in the twin, measured 2026-09-09
  (03-sim §4.5 + its addendum).** The operator's "alignment" complaint is about the
  ARMS AND RAILS, not the props. Measured on a posture where both are in frame: two
  structures in ONE `grip_wrist` frame want shifts differing by 14 px x / 16 px y, so
  no camera model can satisfy both — it is geometry, and intrinsics, extrinsics and
  the SDK state were each ruled out with numbers. The `view_wrist` `[21, 13]` nudge
  **over-corrects by the full 21 px in x** at rail range, so it is a depth-dependent
  patch for what should be a per-arm 6-DOF extrinsic. Consequently the hardware gate
  inflation was raised **0.008 → 0.025 m** with `warn_clearance_m` 0.045 in
  `configs/mavis_v2.yaml` (operator decision after a grazing collision; 11-safety
  §6.2 has the cost and the test consequences). That is a STOP-GAP — an 8 mm shell was
  smaller than the geometry error. **Re-measure the cell and bring the shell back
  down.** Judge alignment only at a posture where the twin predicts geometry in frame.
- **The dev runtime (PID 3869832, started 04:45:20 on 2026-09-09) predates all of
  this** — it holds the trees as of 04:45, so no phase-15 and none of the reverts,
  and it will NOT pick up the new inflation until the config is re-rendered
  (`mavis-dev.sh render`) and the process restarted. The Vite dev server (:5173)
  serves the current UI source.
- `var/gello-kitchen-20260909/` holds the raw kitchen captures (colour frame,
  aligned depth, tag detections, camera calibration) and `var/alignment-20260909/`
  + `var/align2/` the alignment evidence — keep both, 03-sim §4.4 / §4.5 are derived
  from them. `var/gello_smoke.yaml` is a dead throwaway config.
- `~/projects/apollo-mavis-v2-ws-merge/` (branch `merge-13-12`) and
  `~/projects/apollo-mavis-v2-ws-p12/apollo-mavis-v2-policy-node` (the GELLO
  viewpoint node lives there) are leftovers — deleting them is the operator's call.
- **C31 re-fault under load (2026-09-09 late evening; COMMITTED + PUSHED 2026-09-10 as
  hardware `bf1217a`, ui `1a958c1`, ws `1d33bb0`, and deployed to the shared account).**
  Opening the fridge door tripped `C31 Collision Caused Abnormal Current` on the
  Manipulation Arm, and every burst ended in `recovery budget exhausted (3 in 30 s)` —
  self-inflicted: each 20 ms auto-recovery re-enabled the servos with the door still
  pulling on the gripper, the arm re-faulted ~200 ms later WITHOUT moving (four C31 in
  660 ms, `held=[]`, identical reseed angles), and the budget was gone before the
  operator had a turn. The driver now LATCHES at once when the same recoverable code
  re-fires within `REFAULT_WINDOW_S` (1.5 s) of an auto-recovery with no new target
  (`re-latched … holding still: the collision load is still on the arm - back it off or
  let go of the object, then Recover`; one budget slot; 02-hardware §3.5). What it does
  NOT do: make the door openable — the seal / hinge force is a real external torque and
  sensitivity 3 reads it as a collision. Lowering the Manipulation Arm's
  `collision_sensitivity` to 2 (then 1), weighing the payload, pulling along the door's
  arc at 10–50 % speed are the operator's calls, not yet made. Same evening, UI:
  **Continue existing prefills Task from `DatasetInfo.task`** (05-ui §8.1 item 6) so a
  resume is one click. A long-running dev runtime started before that does NOT have the
  driver fix — restart it to pick it up (the shared account's copy has it).
- Known follow-ups: lerobot's `StreamingVideoEncoder` start / finish hold the
  GIL 160–330 ms at `start_episode` and up to 324 ms at `finish_episode` with
  `h264_nvenc` (04-runtime §10.5 "GIL stall"; an encoder subprocess is the fix);
  `test_perf_bridge` `overruns == 0` flakes 1-in-2 (not loosened); dora live tests
  leak-check with a machine-wide `pgrep -x dora`, so never run two dora suites on
  this host at once; the twin's microphone body is off by ≥ 20–30 mm (03-sim §4.5)
  and the carriage mesh is 42 / 32 mm short per end — both need a tape measure.

- **In flight, NOT pushed (2026-09-10): core's `SessionAutoEndNotice` + the three additive
  `SessionTelemetry` fields (`session_id`, `mode`, `kind`, `auto_ended`) for an
  "orphaned session" watch** — a session the runtime ends by itself after
  `control.orphan_session_grace_s` with no `/ws/control` connection, so the Welcome page can
  say the arms were released while nobody was watching. Core-only so far: the runtime has no
  such config key and no implementation, the UI does not read the fields, and 04-runtime has
  no §13.2 for it. Another session owns this — do not push or bump core's pointer until its
  runtime half lands (the ws commit of 2026-09-10 deliberately left core's pointer alone).

## The shared lab account `mavis-v2` (production deployment, 2026-09-09)

- **The cell runs from `mavis-v2`, not from a developer account.** Home `/home/mavis-v2`
  (uid 1001, a sudoer, admin password `ApolloLab#` — the operator explicitly authorised
  publishing it in this public repo on 2026-09-09), linger enabled. Checkout
  `~mavis-v2/apollo-mavis-v2-ws`, data tree in its gitignored `var/`, rendered config
  `var/mavis_v2_lab.yaml`, persistent render knobs `var/lab.env`, demonstrations in
  `~mavis-v2/data/{bc_demo,online_dagger}` (outside `var/`, so `git clean` can never
  reach recorded data). Day-to-day commands: the workspace README, "Running the cell";
  first-time install and troubleshooting: `docs/deploy/DEPLOYMENT.md`.
- **All six repos are PUBLIC and the account holds NO GitHub credentials** (no
  `~/.git-credentials`, no `~/.config/gh`, no credential helper): every clone and pull is
  anonymous HTTPS with `GIT_TERMINAL_PROMPT=0`, verified on the ws and all five
  submodules. `apollo-mavis-v2-runtime` was flipped private → public on 2026-09-09 to
  make this work. Updates: `scripts/deploy/update.sh`. Keep that checkout CLEAN — it must
  always fast-forward; development happens in a developer's clone and arrives via GitHub.
- One service, `systemd --user` `mavis-runtime.service` (API + built UI on 8765, tracker,
  mic, arm probes). **Autostart is deliberately NOT enabled**: the lab config is armed and
  nothing should connect the boxes with no operator present, nor take the dongle / mic /
  port from a developer's runtime (`AUTOSTART=1 install-services.sh` opts in). **One
  runtime at a time** owns the dongle, the mic, each control box and 8765.
- **No account name or home path is hard-coded in the repo** (operator requirement
  2026-09-09): the scripts default to `OPS_USER` `mavis-v2`, `OPS_ROOT`
  `$OPS_HOME/apollo-mavis-v2-ws`, `DATA_ROOT` `$OPS_ROOT/var` (`scripts/deploy/_common.sh`)
  but every one is an env knob; the systemd unit uses systemd's **`%h`** so it carries no
  account name at all (`install-services.sh` only rewrites it for a layout that breaks the
  `~/apollo-mavis-v2-ws` relation, and refuses to install a unit holding another account's
  literal path); `sync-data-from-dev.sh`'s `DEV_USER` defaults to the invoking user, not to
  `xiatao`. Docs write `$OPS_ROOT` / `$DATA_ROOT` / `$DEV_USER` or `~/…`, and name
  `mavis-v2` / `xiatao` only as *this machine's* values. The legacy FHS layout
  (`mavis` + `/opt` + `/var/lib`) is still reachable through the same env vars. New scripts: `update.sh` (S9 upgrade, refuses while a session is open),
  `sync-data-from-dev.sh` (additive rsync of `~/data` between accounts, either
  direction), `install-ufactory-studio.sh` (AppImage + desktop entry).
- The NetworkManager dispatcher hook `/etc/NetworkManager/dispatcher.d/90-mavis-netsetup`
  now bakes in the PRODUCTION hardware venv, so arm-NIC repair no longer depends on a
  developer's checkout existing. Re-render it with `netsetup install --dispatcher-only`
  from whichever venv should own it. Nothing else on the machine is per-account except
  the udev rules (`60-apollo-teleop-input.rules`, already installed) and `mavis-v2`'s
  device groups (plugdev, input, audio, video, render, dialout — all present).
- **UFACTORY Studio: version 1.0.2 ONLY** (operator decision 2026-09-09 evening). 1.0.1
  was deleted from every account, its desktop entries and icons with it. Do not
  re-install it.

## Hardware facts (not discoverable from code)

- Two control boxes on two NICs; NetworkManager profiles matched programmatically:
  `mavis_manipulation_arm` on `enp36s0f1` (192.168.1.11/24) → Manipulation Arm box
  192.168.1.201; `mavis_viewpoint_arm` on `enp36s0f0` (192.168.2.12/24) →
  Perception Arm box 192.168.2.219. Firmware v1.12.10, xarm-python-sdk 1.18.5
  (API gaps in 02-hardware §12). `arm.sn` reads `XS1305` on both — the NIC ↔
  profile mapping is the swapped-cable check. No F/T sensor. The Perception Arm's
  C19 was fixed for good in xArm Studio (Externals → End Effector → None, 2026-09-05).
- Rails: 0.65 m travel, presence auto-detected via the SDK, both homed since
  2026-09-05. Rail zero is at the operator's LEFT (+X); after any re-homing check
  the `*_align` overlay and `hardware_session.rail_flip`. Frame = the operator's
  view: +Y = operator side, operator's right = −X. Joint mapping controller ↔ twin
  is an identity (joint 1 = π is the real posture). Geometry was tape- and
  camera-measured 2026-09-02..06 (03-sim §4.3); still unverified: the carriage mesh
  is ~7.5 cm short along the rail, the microphone body pose, the Perception Arm's
  bracket (its overlay carries an overlay-only principal-point nudge).
- Wrist cameras: both D435i (USB `8086:0b3a`) as plain UVC YUYV 640×480@30, addressed
  by USB serial (349643062582 → `grip_wrist`, 322143060792 → `view_wrist`), never
  by `/dev/v4l/by-id`. Cold-boot quirk: no frames until librealsense has opened the
  device once — `OpenCVCamera` runs `rs-enumerate-devices -s`; keep it installed.
  Colour intrinsics are in `configs/mavis_v2.yaml` (fovy ≈ 43.2°, not the MJCF 57;
  MuJoCo's principal-point sign is opposite to OpenCV's).
- Microphone: RØDE NT-USB Mini via PulseAudio ONLY (direct `hw:CARD=Mini` gives
  EBUSY and stalls other recorders); source
  `alsa_input.usb-R__DE_Microphones_R__DE_NT-USB_Mini_750BFEE8-00.mono-fallback`,
  48 kHz mono; exposed session-less (`GET /api/microphones`, `telemetry.microphone`).
- Tracker: libsurvive REWRITES `var/libsurvive/config.json` on every run and the
  file degrades (extra lighthouse blocks, a station demoted, cm-scale wander) —
  restore `apollo-mavis-v2-runtime/configs/libsurvive/mavis_v2-lighthouses-20260903.json`
  and restart (13-tracker §6.1; making it read-only is OPEN). The controller's
  button path can die while poses keep flowing — restart the runtime before
  suspecting the controller (13-tracker §3 item 7b).

- Dora external interface (phase-12, 2026-09-08; 14-dora v1.0 + §16; **merged
  into the main trees 2026-09-08**): the runtime publishes observations over a
  PRIVATE dora 1.0.1 control plane; the policy node returns `action` / `spec` /
  `status` and, since phase-14, **`trainer_status`** (runtime input
  `policy_trainer_status`, queue 8; 10-field generic `TrainerStatusAnnounce`;
  `PolicySpecAnnounce.capabilities` lists `online_dagger`,
  `SessionAnnounce.online_dagger` carries `{session_name, session_dir,
  rollouts_dir}`, `EVENT_KINDS` = the phase-12 nine + `train_now`;
  `iteration_complete` / `pro_dagger_phase` never shipped). Spelling authority:
  core `protocol/external.py`; both contract goldens (runtime + policy-node) are
  byte-identical and tested (sha256 `4dc67e12…`, 3698 B).
  `dora.enabled` is FALSE in the repo config; the lab render turns it on with
  `DORA_BIND_HOST=wlp38s0` (the "APOLLO Lab" Wi-Fi, 192.168.0.88/24 on
  2026-09-07, DHCP) — never `0.0.0.0`, never the arm links. Ports 6113 / 53391
  / 7447, token in `${APOLLO_HOME}/var/dora/.dora-token` (never served by REST).
  Never run `dora up/down/destroy` without `--coordinator-addr/--coordinator-port`;
  never `pkill -f dora` (matches your own shell) — `pgrep -x dora`. dora 1.0.1
  quirks we work around: `Node()` blocks holding the GIL until every remote
  placeholder attached (join handshake + `canary` subprocess); a dead remote
  daemon makes the coordinator answer 429 for ~50 s (no automatic restart on
  loss); `Node()` replaces `logging.basicConfig` (restored); the first
  `to_numpy()` costs 190 ms (warm-up before attaching). Tick median unchanged
  with the bridge on, p99 3 → 5–8 ms (open).

## Debugging first steps

- `grep 'loop:' var/logs/runtime.log` — the 1 Hz health line (tick rate, held
  codes, tracker pose age vs controller age, `leash_slips`, gate, `ik_slips`,
  `dq_capped` = ticks the uniform step cap bound this window, watchdog) plus
  edge lines; `var/logs/runtime.stderr.log` holds libsurvive / MuJoCo prints.
- Joint panel dead while Vive works ⇒ `watchdog=LATCHED` next to `src=joint_jog`
  (11-safety §10.1). Buttons dead while poses flow ⇒ restart the runtime.
- Teleop caps and the pose-filter retune are measured offline and **not yet
  verified live**; the runtime must be restarted to pick up config changes.

## Machine

- **Run the runtime with `OPENBLAS_NUM_THREADS=1` (also OMP/MKL)**: numpy's OpenBLAS is built for 64
  threads and spin-waits between the loop's tiny matrix ops — measured 2026-09-09: an IDLE runtime at
  4390 % CPU / 63 hot threads, tick p99 50–78 ms in the live session. `__main__` setdefaults it; the dev
  launcher and the systemd unit export it.

Ubuntu 22.04, 2× RTX 4090 (NVIDIA 580.173.02, NVENC works; lerobot's `g=2` needs
`bf=0` on NVENC — the recorder injects it, else `vcodec: auto` falls back to
libsvtav1), node 22, nmcli available. **npm is the UI package manager**
(`package-lock.json` is the lockfile; pnpm 11's pre-run `pnpm install` fails here
with `ERR_PNPM_IGNORED_BUILDS` for esbuild — use `npm run <script>` or
`pnpm --config.verify-deps-before-run=false <script>`; never commit
`pnpm-lock.yaml` / `pnpm-workspace.yaml`). Lab host details:
`docs/deploy/DEPLOYMENT.md`.
