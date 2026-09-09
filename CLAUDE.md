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
  geometry + wrist-camera extrinsics → 03-sim §4.3 and the header of
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
  12-dagger, 14-dora; dora bus + external policy → 14-dora; **GELLO Manipulation**
  (leader device, engage state machine, launch check / plan / sequential execution,
  viewpoint node, kitchen twin measurements, REST, UI, implementation record) →
  16-gello §0–§16 (§3 = the 2026-09-09 kitchen measurement log, §15 = what shipped
  and how it deviates); per-repo amendments → 04-runtime §5.1 / §6.1 / §13 / §14,
  05-ui §8.1 6b / §8.2, 03-sim §4.4, 11-safety §2 T11 / §13, 14-dora §4–§5 / §7.
- `docs/prompts/phase-XX-*.md` — the phased plan; one phase = one session's work,
  status table in `docs/prompts/README.md`.
  **Next: commit phase-15 when the operator says so; then, with the operator
  present, power the GELLO servos, render the lab config with the GELLO knobs,
  restart the runtime and run the phase-15 acceptance steps (first ever hardware
  run of phase-12 / 13 / 14 / 15 code); the first policy-repo trainer on the
  Online DAgger shell (sim); admitting Online DAgger on hardware is the operator's
  call (D7).** Plan: `docs/prompts/phase-15-gello.md` (phase-12 / 13 / 14 were
  committed and pushed 2026-09-09 05:46, ws `e16d2c1`).
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
- Driver caps at speed scale 1.0: `max_joint_vel` 0.6 rad/s, `max_cart_step_m`
  0.004 (= 4 mm/tick, deliberately HALF the gate's 8 mm inflation — do not raise
  it without changing the gate), rail 50 mm/s. Hardware tab picks 10 / 50 / 100 %,
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

## GELLO Manipulation (operator decisions 2026-09-09; 16-gello v1.0 is the contract)

- The landing page's **fifth card is "GELLO Manipulation"** (wire `mode: gello`,
  route `#/gello`). GELLO = the passive xArm7-shaped leader (Dynamixel servos over
  the FTDI FT232H / U2D2 at `/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_
  FTAKROCJ-if00-port0`, `root:dialout`). It drives the **Manipulation Arm only, in
  joint space**; the operator keeps **←/→ for that arm's rail** (every source, in
  every GELLO state); every other held key is ignored for it; the gripper follows
  the leader's trigger; Tab / Z / Space / episode keys / joint panel are nacked.
  No recording in v1. **The Perception Arm's action comes from an external
  viewpoint node** over dora (`SessionAnnounce.external_arms == ["view"]`,
  view-only delta_ee layout, attached only while RUNNING and no plan owns the
  arm) and otherwise **holds the GELLO hold posture** J1–J7 `[2.646, -1.598,
  0.018, 1.637, 0.25, 2.007, 0.029]` rad, rail 0.0 (`gello.view_posture_rad`,
  NOT the seeded initial condition). `SessionSpec.gello.viewpoint: auto |
  external | hold` (default `auto`); `start_from` must be `keep_current`.
- **Engagement state machine (D3), no implicit motion**: `no_leader |
  out_of_sync | tracking | paused | motion`; only `tracking` streams the leader
  (through the uniform cap — 0.006 rad/tick at 100 %, also in sim — and the gate);
  engage tolerance 0.10 rad, leash 0.80 rad; joints 1/3/5/7 unwrapped to the
  nearest branch at engagement; fault / `R` / Go to profile / the exit return
  force `paused`; **Resume** is the operator's button (Pause / Resume are Cockpit
  buttons, actions `gello_pause` / `gello_resume` — the keymap stays 24 rows).
- **Launch = check → plan → ONE ARM AT A TIME → engage**: `POST /api/session`
  refuses in order `GELLO leader not available (…)` → joint limits → `GELLO posture
  collides: <a> / <b> at <mm> mm - move GELLO and retry` → viewpoint node (only
  `external`); the session-less `POST /api/gello/preview` returns the same verdict
  plus a PNG of `cam_kitchen` with the colliding bodies red; the GELLO sheet polls
  it at 2 Hz and enables Start only on `clear`. **GELLO is admitted on hardware
  (D8)** — the refusal text is now `hardware sessions support teleop, data
  collection and GELLO Manipulation only`; Online DAgger stays refused (D7).
- **Kitchen twin `mavis_v2_kitchen`** (`hidden: true` — `GET /api/scenes` still
  lists only `mavis_v2`; the GELLO card selects it via `GET /api/gello .scene_id`):
  the cell + GE GDE21ESKSS fridge, GE 30" coil range, counter, upper cabinets,
  wall as dimensioned BOXES on the faces measured 2026-09-09 from the Perception
  Arm's wrist RealSense at the hold posture (16-gello §3: fridge left side
  x = 0.075, fridge door y = −1.027, range door y = −1.222, counter top z = 0.926,
  yaw 0, ±3 cm; tags tagStandard41h12 ids 0/4 fridge side, 1 fridge door, 3 range
  door, quad 0.093 m → 0.205 m plates). Handles are `graspable` (finger ↔ handle
  whitelisted per session); appliance bodies gate every arm link. The sim test
  re-detects the four tags on a render from `view_wrist_cam` within 1 px of the
  real frame. Edit the numbers in `mavis_v2_kitchen.yaml` and 16-gello §3 together.
  The `*_align` overlays outline the appliances only when `twin_overlay.scene`
  (render knob `TWIN_OVERLAY_SCENE`) names the kitchen.
- **Leader device** = `apollo_mavis_v2_runtime.devices.gello.GelloReader`
  (tracker pattern; extra `[gello]` = dynamixel-sdk + pyserial, imported only
  there; never writes a servo register — AST-pinned). Calibration is session-less
  REST: `POST /api/gello/calibrate {op: match_arm | gripper_open | gripper_closed |
  clear, kind}` → `var/gello_calibration.json` (offsets = nearest π/2, the GELLO
  convention); `gello.joint_signs` is operator config (default all +1 — unverified).
  **On 2026-09-09 no servo answered any baud** (57600 … 4 M, protocol 2.0 / 1.0):
  almost certainly servo power off; ids / baud / signs are unverified, the FTDI
  `latency_timer` was 16 ms (the udev rule in `01-sudo-udev-and-deps.sh` sets 1 ms
  and `dialout` + `uaccess` for `0403:6014`).
- Config: `gello:` block (repo `backend: none`; lab render `GELLO_BACKEND=dynamixel
  GELLO_USB_SERIAL=FTAKROCJ [GELLO_BAUD]`), `twin_overlay.scene`; `install-stack.sh`
  syncs `--extra gello`. Clearance readout (the operator's complaint): the row
  COUNT was always ≤ 5 — long labels wrapped and the panel sat above the episode
  buttons; now 4 one-line rows with their own scroll and the episode controls above
  (16-gello §12.4).

## Work in progress (2026-09-09)

- **Phase-12 / 13 / 14 and the 2026-09-08 follow-ups are COMMITTED and PUSHED**
  (2026-09-09 05:46: core `7d9400a`, hardware `0e33d45`, sim `fb1a4af`, runtime
  `17d8bc7`, ui `eca22df`, ws `e16d2c1`). None of it has run on the real arms.
- **Phase-15 GELLO Manipulation is implemented and UNCOMMITTED** in core / sim /
  runtime / ui and the policy-node repo (`~/projects/apollo-mavis-v2-ws-p12/
  apollo-mavis-v2-policy-node`, still without a remote), plus the workspace docs
  and deploy scripts. Test state: core 482 + `export_schemas --check` clean; sim
  213 + 1 skip (EGL); runtime `-m "not dora"` 860 passed / 2 skips / 2 pre-existing
  failures (`test_return_fuzz_mavis_v2[mic|nomic]`, an RRT-timeout budget that
  fails identically without phase-15 — planner owner's call; `test_e2e_reset_
  pinched_sim` flakes 1-in-2 under full-suite load and passes alone);
  `test_e2e_gello_viewpoint` 1 (dora, alone); ui 47 files / 486; policy-node 142;
  hardware 293 untouched. A sim smoke instance on port 8766 exercised the whole
  GELLO REST / WS flow before and after the review fixes (16-gello §15.3). The
  adversarial review (6 dimensions, 26 raw → 21 confirmed, all fixed) is
  16-gello §15.5; the fixes' own deviations are §15.2 items 11–19. Commit only
  when the user says so.
- **The dev runtime (PID 3869832, started 04:45:20 on 2026-09-09 with
  `var/mavis_v2_local.yaml`) runs exactly the 05:46 commit** — nothing of
  phase-15 (the `gello:` block, `/api/gello*`, the kitchen twin, the fifth card's
  backend) is live in it. Before the first GELLO run: `uv sync --extra gello` in
  the runtime (the venv already has dynamixel-sdk / pyserial from this session),
  add `GELLO_BACKEND=dynamixel GELLO_USB_SERIAL=FTAKROCJ TWIN_OVERLAY_SCENE=
  mavis_v2_kitchen` to `scripts/dev/local.env` (operator's file), `mavis-dev.sh
  render`, restart. The Vite dev server (:5173) serves the current UI source.
- `var/gello_smoke.yaml` (port 8766, `gello.backend: fake`) is the throwaway
  smoke config; `var/gello-kitchen-20260909/` holds the raw kitchen captures
  (colour frame, aligned depth, tag detections, camera calibration) — keep them,
  16-gello §3 is derived from them.
- `~/projects/apollo-mavis-v2-ws-merge/` (branch `merge-13-12`) is a stale
  leftover — unused; deleting it is the operator's call.
- Known follow-ups: lerobot's `StreamingVideoEncoder` start / finish hold the
  GIL 160–330 ms at `start_episode` and up to 324 ms at `finish_episode` with
  `h264_nvenc` (04-runtime §10.5 "GIL stall"; an encoder subprocess is the fix);
  `test_perf_bridge` `overruns == 0` flakes 1-in-2 (not loosened); dora live tests
  leak-check with a machine-wide `pgrep -x dora`, so never run two dora suites on
  this host at once; the twin's microphone body hides AprilTag 4 in the kitchen
  render while the real frame shows it — the mic mount geometry (03-sim §4.3) is
  wrong and needs a measurement.

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
