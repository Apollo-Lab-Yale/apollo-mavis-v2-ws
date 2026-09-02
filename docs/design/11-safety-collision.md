# 11 — Safety & Collision System (cross-cutting)

Status: v1.0 (2026-09-01). Conforms to `00-overview.md` v0.3 §6 (binding). Research
ground truth: `docs/research/{mujoco-xarm7-sim,collision-ik,xarm-python-sdk}.md`.

## 1. Scope, ownership map, module layout

Specifies every safety-relevant mechanism: digital twin, command gate, IK-level
avoidance, controller backstops, watchdogs, reset planning, degraded modes, tests.
Units m/rad, quats wxyz; mm/deg only inside `hardware`.

```
core:     interfaces/safety.py  DigitalTwinInterface (Protocol), PairClearance
          schemas/safety.py     SafetyConfig, CollisionReport, CollisionEvent,
                                PlanRequest/PlanResult, CommandSource enum
sim:      twin.py               DigitalTwin (implements DigitalTwinInterface);
                                apply_inflation(model, total_gap_m),
                                build_monitored_pairs(model), AllowedPairs (03-sim §8)
          planner.py            ResetPlanner (RRT-Connect, joint-space,
                                twin-validated; 03-sim §10)
          tools/guardrail_check.py   CI guardrail regression script (§5)
runtime:  safety/gate.py        SafetyGate, NullGate, GateDecision
          safety/supervisor.py  SafetySupervisor (twin sync + gate + events + telemetry)
          safety/watchdog.py    InputWatchdog, ArmReportWatchdog
          control/loop.py       ControlLoop — ONLY caller of ArmInterface.command_* (§4)
hardware: backstops.py          apply_backstops(api, cfg) (§11; 02-hardware §6)
ui:       CollisionBanner, ClearanceReadout (§13; detail in 05-ui.md)
```

Composition (spine §1): `core` defines interfaces/schemas, `sim` implements twin + planner,
`runtime` composes (hardware mode with twin safety requires both extras); `hardware` never
imports MuJoCo. `SafetyConfig` (pydantic, in `WorkcellConfig.safety`):

```python
class SafetyConfig(BaseModel):
    enabled: bool = True                  # hardware REFUSES to start if False (§4)
    safety_debug: bool = False            # sim only: run the FULL hardware-mode stack (§5)
    geom_inflation_m: float = 0.008       # TOTAL pair inflation δ (per-geom δ/2), §6
    min_clearance_m: float = 0.0          # extra gate block threshold above inflated surface
    warn_clearance_m: float = 0.025      # UI amber threshold
    hysteresis_m: float = 0.002          # unblock requires dist ≥ threshold + this
    max_active_constraint_rows: int = 12  # IK CollisionAvoidanceLimit row cap, §8
    twin_staleness_s: float = 0.15; rail_staleness_s: float = 0.5   # twin sync age limits, §6.1
    input_deadman_s: float = 0.2;   input_ramp_s: float = 0.1      # deadman, §10
    allowed_pairs_extra: list[tuple[str, str]] = []                 # body-name pairs, §6.3
```

## 2. Threat model

| # | Threat | Primary mitigation (layer, §3) | Backup |
|---|---|---|---|
| T1/T2 | Arm↔arm and arm↔environment collision (2–3 arms share the workcell; controllers know nothing of each other, the rail, or the scene) | Twin gate on cross-arm + arm↔env pairs (L1) | IK constraints (L2); torque-based collision stop C31, reduced-mode TCP boundary → C35 (L3) |
| T3 | Sim/real discrepancy: twin geometry ≠ real cell (rail mesh unverified vs hardware; convex hulls over-approximate; base extrinsics wrong) | 8 mm inflation absorbs small error; hardware acceptance checklist (§14.3) validates clearances before trust | Controller backstops (L3) are twin-independent |
| T4/T5 | Stale input / network loss: tab freeze with keys held, control WS drop, arm report drop, 502 socket errors | Input deadman 0.2 s → ramp to zero + empty-held-set resume (L4); ArmReportWatchdog fails the gate closed on stale twin state (§6.1) | SDK report thread auto-reconnect; hold-on-error |
| T6 | Policy misbehavior: NaNs, out-of-range actions, runaway targets, inference latency spikes | Action sanitation + per-tick step clamp in ControlLoop; twin gate treats policy exactly like a human (L1) | Space takeover (inference safety escape); firmware C24 speed limit |
| T7 | E-stop / controller error recovery: controller silently drops to mode 0; naive resume replays an old target → jump | Recovery sequence with mandatory servo re-seed from measured state (§10.3) | Gate re-checks first command after recovery against measured config |
| T8 | Deep-penetration infeasibility: measured state already inside inflated (or real) contact — post e-stop, manual repositioning, free-drive | Gate escape rule: only clearance-increasing commands pass (§7 step 6); IK opening-velocity recovery ladder (§8) | Operator: joint-jog small deltas are gated but escape-permitted; worst case hardware e-stop + free-drive |
| T9 | Concurrent controllers: UFACTORY Studio live-control grabs mode/state under the SDK | External mode/state-change detection → hold + operator ack (§10.2) | — |
| T10 | Runtime bug bypassing safety (new mode / code path sends commands directly) | Single architectural chokepoint + import-boundary test (§4) | Controller backstops still active |

## 3. The four safety layers (spine §6)

| Layer | What it does | Semantics | Owner (repo) | Failure stance |
|---|---|---|---|---|
| **L1 Twin gate** (authoritative) | Every outgoing command tick checked against the inflated kinematic twin at the *commanded* configuration (arm↔arm + arm↔env). Violations → clamp/hold + `CollisionEvent`. Governs human AND policy equally. | Hard veto; §7 algorithm | twin: `sim`; gate: `runtime` | Fails **closed**: no twin / stale twin ⇒ no motion (hardware mode, §12) |
| **L2 IK-level avoidance** | `mink.CollisionAvoidanceLimit` inequality rows make teleop/policy targets glide along obstacles so L1 rarely fires. Comfort layer, not trusted for safety. | Soft-ish (QP-feasible sliding); §8 | `sim` (solver lives on twin model), invoked by `runtime` | May be degraded/disabled without loss of safety (L1 still vetoes) |
| **L3 Controller backstops** | Per-arm firmware limits, twin-independent: collision sensitivity, self-collision model + tool model, reduced-mode TCP boundary, `set_tcp_load`. | Controller-enforced; error C22/C31/C35 halts the arm | `hardware` | Independent of the whole Python stack; last line before physics |
| **L4 Watchdogs** | Stale-input deadman, arm-report staleness, WS single-writer, servo re-seed after recovery, external-controller detection. | Time-based holds + resume preconditions; §10 | `runtime` | Fails closed (hold) |

Layer independence: L1 must block even with L2 disabled (guardrail A5, §5.1); L3 is set
at bring-up and survives a runtime crash; L4 acts even with no collision in sight.

## 4. The mode-independence invariant and the gate chokepoint

**Invariant (hardware mode)**: in teleop, data collection, DAgger, AND inference, every
command from every source — keyboard twist, joint-jog panel (`jog` and `goto`), policy
actions, DAgger/inference takeover input, planner trajectories (resets, profile loads,
`goto` jumps) — passes the twin gate before reaching a real arm. No mode, feature, or
recovery path may bypass it. Enforcement is architectural:

1. **Single dispatch point.** `runtime.control.loop.ControlLoop` is the only code in the
   stack calling `ArmInterface.command_joints` / `command_rail` / `command_gripper`. Mode
   logic (teleop mapper, policy runner, DAgger takeover mux, planner executor, joint-jog
   handler) never holds an `ArmInterface`; each is a **command source** for the tick.
2. **Gate call is inline in the tick**, between source resolution and dispatch — no
   queue exists that a command could slip around:

```python
class CommandSource(str, Enum):
    TELEOP = "teleop"; JOINT_JOG = "joint_jog"; POLICY = "policy"
    TAKEOVER = "takeover"; PLANNER = "planner"

@dataclass
class TickCommand:
    q_cmd: dict[str, np.ndarray]     # arm_id → full commanded q (7/8 incl. rail slot), rad/m
    gripper: dict[str, GripperCommand]
    source: CommandSource

# ControlLoop.tick(), 100 Hz thread — the chokepoint (04-runtime §6)
cmd  = self._active_source.resolve(obs)              # TickCommand
cmd.q_cmd = sanitize(cmd.q_cmd, obs.q_meas, limits)  # NaN/None→hold; limit clip; step clamp (T6)
dec  = self._gate.filter(cmd.q_cmd, obs.q_meas, cmd.source)  # §7; SafetyGate or NullGate
for arm_id, q in dec.q_out.items():
    self._workcell.arms[arm_id].command_joints(q)    # rail slot → sparse command_rail
self._supervisor.publish(dec.report, dec.events)     # telemetry snapshot + event log
```

3. **Gate selection is fixed at session build**, not per mode: `kind == "hardware"` ⇒
   `SafetyGate` always (hardware refuses to start ungated — `enabled: false` is a
   startup error); `kind == "sim"` ⇒ `NullGate` unless `safety_debug` (§5).
   `NullGate.filter()` is a pass-through with an "ok" report — identical tick path.
4. **Enforcement tests**: AST scan asserts `command_joints|command_rail|command_gripper`
   call sites exist only in `runtime/control/loop.py` (plus interface defs/mocks), and
   `ControlLoop.__init__` raises `SafetyConfigError` (runtime-local, subclasses core
   `ConfigError`) on hardware kind without a `SafetyGate` bound to a live twin.
5. Gripper commands are not collision-gated (they open/close in place; fingertip geoms
   remain monitored pairs) but ARE deadman-gated (§10.1).

## 5. Sim policy: gate off by default, `safety_debug`, guardrail script

**Default sim policy**: gate **off** (`NullGate`) — collisions are harmless, physics
stops penetration, scene colliders constrain the arm naturally. Sim teleop/inference
run plain differential IK (posture + configuration/velocity limits; no
`CollisionAvoidanceLimit`, no twin), keeping sim "honest" for policy training:
policies learn not to collide, not to lean on a guardrail.

**`safety_debug`** (`kind: sim`, `safety_debug: true`): the FULL hardware-mode stack
against a sim workcell playing the real robot — a **separate** twin instance from the
same scene id (own `MjModel`/`MjData`, inflated per §6.2; never the physics data, so
detection-only contacts cannot perturb dynamics), `SafetyGate` at the §4 chokepoint,
IK avoidance rows, watchdogs, full event/telemetry/banner path; twin sync consumes the
sim state stream exactly like the 100 Hz hardware report. The only way to exercise the
gate end-to-end without arms.

### 5.1 Guardrail debugging script (`apollo_xarm7_sim/tools/guardrail_check.py`)

The CI regression test for the safety layer: headless, virtual-tick paced (no
sleeps/wall-clock), fixed seeds ⇒ deterministic.

```python
@dataclass
class GuardrailScenario:
    scenario_id: str; scene_id: str; driven_arm: str
    twist: np.ndarray                      # (6,) constant world-frame twist via the teleop path
    target_pair_prefixes: tuple[str, str]  # e.g. ("arm0/", "table") or ("arm0/", "arm1/")
    max_ticks: int = 2000                  # 20 s virtual @ 100 Hz
    escape_after_block_ticks: int = 50     # then reverse twist
def run_scenario(s: GuardrailScenario, ik_avoidance: bool) -> ScenarioResult: ...
def main(argv: list[str]) -> int: ...      # exit 0 = all assertions pass; nonzero = CI fail
```

Scenarios: `env_table_descend` (−z into table), `env_pedestal_sweep` (+x into
pedestal) for arm↔environment; `cross_arm_head_on` (+y toward arm1),
`cross_arm_rail_converge` (rail drive toward arm1) for arm↔arm;
`mavis_v2_rail_sweep` (the lab cell's gripper arm along the channel into its
obstacle, 03-sim §4.3) as the deployment cell's own regression. Each builds a
`safety_debug` session programmatically (no server), injects a synthetic `TeleopInput`
holding the twist, and steps the control loop tick-by-tick. **Ground truth** = the
*physics* model with zero inflation: any tick with a `mj_collision` contact `dist <=
0` between geoms matching `target_pair_prefixes` counts as a real-contact failure.

**Assertion contract** (all must hold; failures name the scenario):

- **A1 Pre-contact trigger**: ≥1 `CollisionEvent(kind="blocked")` emitted AND
  ground-truth contact count for the target pair is 0 over the whole run.
- **A2 Inside the inflation band**: at the first `blocked` event, twin clearance of an
  offending pair matching `target_pair_prefixes` is in `(0, geom_inflation_m +
  min_clearance_m]`, and the event's `min_clearance_m` matches a direct
  `mj_geomDistance` recomputation (|Δ| ≤ 1e-6 m).
- **A3 Hold is a hold**: while blocked with twist still applied,
  `max |q_sent(t) − q_sent(t_block)| ≤ 1e-4` (rad; rail slot m) per driven arm.
- **A4 Escape works**: after twist reversal, `kind="cleared"` within 100 ticks, min
  pair clearance non-decreasing (tol 1e-4 m), motion resumes.
- **A5 Layer independence**: each scenario runs three times — gate-only main
  (`--no-ik-avoidance`: L1 alone must satisfy A1–A4), IK-on main, and the IK-on
  graze variant, which must produce **0 blocked events** (L2 glides).

CI wiring: `uv run python -m apollo_xarm7_sim.tools.guardrail_check --all` in sim CI +
runtime CI (integration job, both extras); < 30 s total (virtual ticks, 0.75 ms/tick max).

## 6. Digital twin: sync loop, staleness, inflation, pair management

The twin is a **kinematic-only** MuJoCo model of the workcell (`digital_twin_scene`
from the scene registry, composed via `MjSpec.attach(child, prefix=f"{arm_id}_",
frame=...)`): per tick only `mj_kinematics` + `mj_collision`, never `mj_step`.
Measured: 0.24–0.75 ms/tick for 3 inflated arms; `mj_geomDistance` ≈ 1 µs/pair.
`DigitalTwin(scene, inflation_m=safety.geom_inflation_m)` (03-sim §8) implements
`DigitalTwinInterface` exactly as in core §5.2 (`sync` / `check` / `check_config` /
`clearance` / `plan` / `render` / `set_grasp_whitelist`) and precomputes at
init: `qpos_adr: dict[str, np.ndarray]` (arm_id → qpos indices, 7/8 incl. rail
slide) and `monitored_pairs: list[tuple[int, int]]` (geom-id pairs after §6.3
filtering). Threading: `plan` on a worker thread with its own `MjData`; `render` on the
render thread; `sync`/`check`/`clearance` on the control-loop thread only — one thread
per `MjData`, `MjModel` shared read-only after inflation.

### 6.1 Sync loop and staleness

- **Joints**: each arm streams `actual_joint_angle[7]` at **100 Hz** on report port
  30003 (`report_type='real'`); the per-arm driver thread timestamps each frame
  (`time.monotonic()`). `SafetySupervisor` copies the latest states into the twin at
  the top of every control tick (`twin.sync` = write `data.qpos[qpos_adr[arm]]`; the
  gate's `check()` runs kinematics itself on the *commanded* config).
- **Rail**: no streaming interface (blocking modbus): poll `get_linear_track_pos()` at
  5 Hz on the driver's monitor thread (02-hardware §5); mm → m into the rail qpos slot
  and world TF. Gripper
  opening (0–850 pulses ↔ 0.085 m) mirrors at 1–2 Hz; finger pads stay monitored pairs.
- **Staleness** (`ArmReportWatchdog`): joint report age > 0.15 s (`twin_staleness_s`,
  ≈15 missed frames) or rail poll age > 0.5 s for ANY arm ⇒ gate **fails closed for all
  arms** (a stale arm is an unknown obstacle to the others): `q_out = hold`, emit
  `kind="stale_twin"`. Auto-recovers on fresh reports; all-keys-up (§10.1) still applies.

### 6.2 Inflation spec

**`geom_gap = δ/2` per geom, `geom_margin = 0`** on every collidable geom
(`geom_contype|geom_conaffinity != 0`), applied once at load by `apply_inflation(model,
total_gap_m=safety.geom_inflation_m)`. MuJoCo 3.12.0 semantics (verified in
`engine_collision_driver.c`): contacts are *detected* at `margin + gap`, forces act only
inside `margin`, and the per-pair threshold is the **SUM** of both geoms' values — so
`margin=0` gives detection-only contacts (`efc_address == -1`, zero dynamics effect) and
per-geom δ/2 makes every robot↔robot and robot↔env pair detect at exactly δ total. Geoms
that must legitimately touch (finger pads on grasps) go through allowed pairs.

**Default δ = 0.008 m (8 mm total)**, knob `safety.geom_inflation_m`: hulls already
over-approximate, per-tick steps are < 10 mm cartesian, and 8 mm absorbs report latency
(≤ 1.5 ticks × TCP speed) + small extrinsic error. Raise to 0.0125–0.025 for un-surveyed cells.

**Version pin `mujoco==3.12.0`**: margin/gap semantics changed across MuJoCo versions
and are load-bearing for L1. CI sentinel `test_inflation_semantics.py` (§14.1): two
spheres with `gap=δ/2, margin=0` must (a) contact iff `dist < δ`, (b) show
`efc_address == -1`, (c) produce zero constraint force after `mj_forward`. The pin
moves only with this test green.

### 6.3 Collision pair management

`build_monitored_pairs(model)` builds the geom-pair list once at init from all
cross-body pairs surviving MuJoCo's own filters (contype/conaffinity,
same-body/weld/parent-child auto-exclusion, MJCF `<exclude>` — menagerie already
excludes gripper-knuckle pairs). Then:

- **Mandatory per-arm exclude `{arm}_link_base ↔ {arm}_link1`**: the parent-child
  auto-filter is disabled when the parent is welded to the world, giving a permanent
  false near-contact (measured dist ≈ 0.0002 m at qpos=0). Added as MJCF `<exclude>` by
  the scene builder; the twin's pair builder re-asserts it (`test_twin_excludes`,
  03-sim §8). Init audit: any pair in contact at the `home`
  keyframe under inflation must be allowed or fixed — the twin **refuses to arm the
  gate** with unexplained at-home contacts.
- **AllowedPairs** (body-name granularity): `frozenset({body_a, body_b})` from
  (a) the scene descriptor's `allowed_pairs` (scene-authored structural pairs,
  validated against the built model at build time and carried on
  `SceneMeta` — 03-sim §4.2; e.g. `mavis_v2`'s carriages 24 mm above the table
  and ~2 mm from the neighbouring rail), (b) `safety.allowed_pairs_extra`,
  (c) session-scoped additions (fingertips ↔ named grasp object).
- **Convex hulls** over-approximate — conservative but can false-alarm in tight
  layouts. Escape hatch: decompose the offending link mesh with **CoACD** into a few
  convex pieces as collision-only geoms (`group="3"`, alpha 0) in a scene-local
  override, recorded in the registry. Never shrink inflation to hide hull slop.
- **Budget**: `check()` uses the full list (contacts are cheap); the sweep uses all
  cross-arm + arm↔env pairs at `distmax=0.05`; IK uses the top
  `max_active_constraint_rows` (12) nearest pairs from the last sweep (§8).

## 7. Per-tick command gate algorithm

```python
@dataclass
class GateDecision:
    q_out: dict[str, np.ndarray]   # what may be dispatched (cmd, held, or escape-limited)
    blocked: bool
    report: CollisionReport        # severity ok|warn|blocked, pairs, min_clearance_m
    events: list[CollisionEvent]   # transitions only (edge-triggered)

class SafetyGate:                  # state: _last_safe per arm, _blocked, _block_pairs
    def __init__(self, twin: DigitalTwinInterface, cfg: SafetyConfig): ...
    def filter(self, q_cmd: dict[str, np.ndarray], q_meas: dict[str, np.ndarray],
               source: CommandSource) -> GateDecision: ...
```

### 7.1 Algorithm (control-loop thread, every tick)

```
1. staleness: ArmReportWatchdog stale → q_out = _last_safe (init q_meas at session
   start), blocked=True, emit stale_twin. STOP.
2. write q_cmd (ALL arms, incl. rail slots) into twin qpos; mj_kinematics; mj_collision.
3. violations = [contacts with body pair ∉ AllowedPairs and
                 dist ≤ min_clearance_m + (hysteresis_m if _blocked else 0)]
   (detection window is δ from inflation; min_clearance_m=0 default ⇒ block on any
    inflated-surface contact; unblock needs +hysteresis_m clearance — no chattering).
4. no violations → q_out = q_cmd; _last_safe = q_cmd; if _blocked: emit "cleared";
   _blocked = False. DONE.
5. blocked: offending arms = arms owning ≥1 violating geom. Non-offending arms keep
   q_cmd (step 2 checked all arms jointly — proven safe against the commanded world).
6. escape test (T8): accept an offending arm's q_cmd iff it strictly opens EVERY
   violating pair p: mj_geomDistance(p|q_cmd) ≥ mj_geomDistance(p|q_meas) + 1e-5, and
   creates no new violating pair. Cost ≤ |violating pairs| calls (~1 µs each).
7. else q_out[arm] = _last_safe[arm] (hold). Emit "blocked" (pairs, dists, source) on
   the rising edge or when the offending pair set changes.
```

Clamp/hold policy is **hold-last-safe**, not segment bisection: bisection costs up to
3 extra collision passes (~2.3 ms worst case — over the 2 ms/tick budget), and L2 makes
near-boundary commands slide instead of jump, so holds are rare and short. `_last_safe`
is per-arm and re-seeds to `q_meas` after error recovery (§10.3) — a hold can never
replay a pre-e-stop target.

### 7.2 Warn level and clearance readout

Every 4th tick (25 Hz) the supervisor runs `twin.clearance(distmax=0.05)` on the
*measured* config: `severity="warn"` when `min_clearance_m < warn_clearance_m` (25 mm)
while unblocked; top-5 pairs go to telemetry (`TelemetryMsg.clearances`). The sweep
runs in the control thread (≈ 0.29 ms per 289-pair set) — gate + sweep ticks stay < 2 ms.

### 7.3 CollisionEvent schema (`core.schemas.safety`)

```python
class CollisionEvent(BaseModel):
    t: Literal["collision_event"] = "collision_event"
    ts: float                                  # server monotonic, s
    kind: Literal["blocked", "cleared", "warn", "penetration", "stale_twin"]
    pairs: list[tuple[str, str]]               # body names, e.g. ("arm0/link5", "arm1/link3")
    dists_m: list[float]; min_clearance_m: float   # signed clearances (inflated twin geoms)
    source: CommandSource | None               # command source that hit the gate
    arm_ids: list[str]                         # offending arms
```

`kind="penetration"` fires when the *measured* config itself violates (dist ≤ 0 on real
hulls): the cell is already in contact — UI shows the wedged state (§13), only escape
commands pass (step 6).

## 8. IK-level avoidance interplay and infeasible-QP recovery

Setup (mink 1.3.0; the solver shares the twin `MjModel`, owns its own
`mink.Configuration`; detail in `03-sim.md`):

```python
mink.CollisionAvoidanceLimit(
    model, geom_pairs=[(arm_i_geoms, arm_j_geoms) for i<j] + [(arm_geoms, env_geoms)],
    gain=0.85,
    minimum_distance_from_collisions=cfg.geom_inflation_m + 0.002,  # 10 mm: sit OUTSIDE the gate
    collision_detection_distance=0.05, bound_relaxation=0.0)
```

`minimum_distance_from_collisions` sits 2 mm above the gate threshold, so a converged IK
solution never trips L1 — the gate only fires on IK failure modes, direct joint-jog, or
planner bugs. The limit is rebuilt each tick from the top `max_active_constraint_rows`
(12) nearest pairs of the last sweep (active-set filtering) to bound QP latency at 100 Hz.

**Infeasible-QP recovery ladder.** mink permits only opening velocity once `dist <
minimum_distance`; deep penetration or conflicting rows can still make the QP
infeasible. Per tick:

1. **Retreat-only retry**: drop the FrameTask; keep PostureTask targeted at `q_meas`
   + all limits — the QP finds pure opening velocities if any exist.
2. **Retry with `bound_relaxation = -0.002`**: 2 mm relaxation restores feasibility when
   numerical noise pins rows against each other (still subject to the gate's escape rule).
3. **Hold**: return `q_meas`; emit `CollisionEvent(kind="penetration")`.

Every rung's output still passes the §7 gate — the ladder is recovery comfort, never
trusted. **Must be tested on the real cell**: rungs 1–2 are sim-designed; §14.3 item 3
is the supervised hardware drill.

**Teleop divergence clamp.** Velocity-level IK converges silently to the nearest
reachable pose; a blocked target ray lets the integrated target pose drift. If FrameTask
position residual > 0.05 m or orientation residual > 0.5 rad, the target integrator
re-anchors to the current EE pose (prevents the rubber-band lunge when the obstacle clears).

## 9. Reset / profile-load planning

Used by `start_from: profile:<id>`, in-session profile loads, joint-jog `goto` (large
jumps), and inference-abort repositioning. The stack **never** calls xArm native
`move_gohome()`/reset (factory-fixed, no cross-arm awareness).
`ResetPlanner(twin, addr).plan(req)` (03-sim §10, seeded for determinism):

```python
class PlanRequest(BaseModel):
    q_start: dict[str, list[float]]     # measured, full q incl. rail slot
    q_goal:  dict[str, list[float]]     # from StateProfile (joint-space: no IK needed)
    arm_order: list[str] | None = None  # None → heuristic below
    timeout_s: float = 5.0; max_step_rad: float = 0.05  # per arm; edge check resolution (rail 0.01 m)

class PlanResult(BaseModel):
    ok: bool
    waypoints: dict[str, list[list[float]]]  # per-arm joint waypoints (post-shortcut)
    failure: Literal["goal_in_collision", "start_in_collision", "timeout"] | None = None
    failing_pair: tuple[str, str] | None = None
```

- **Per-arm sequential** over the composite twin model: plan arm k with arms `<k` frozen
  at *goal*, arms `>k` frozen at *start*, as static obstacles. Order: deepest-in-warn-band
  arm first; on failure retry reverse order. Composite 16–24 DoF planning is a v1
  non-goal; two-arm swap deadlocks fail loudly (§14.2).
- Validity checker: candidate q → **planner-private `MjData`**, `mj_kinematics` +
  `mj_collision`, violations per §7 step-3 semantics on inflated geoms. Measured 4k–60k
  checks/s/core ⇒ the 5 s budget is generous.
- Edges interpolated at `max_step_rad` per joint (rail 0.01 m); post-process: 50 random
  shortcut passes, then time-parameterization with per-joint velocity/accel caps
  (defaults 0.6 rad/s, 2 rad/s²; rail 0.1 m/s).
- **Execution**: the ControlLoop planner source streams waypoints at 100 Hz — joint-space
  interpolation → slew-limited `command_joints`, rail as sparse absolute mm targets —
  through the §4 gate every tick like any other source. A mid-execution gate block (e.g.
  a human jogs the other arm) pauses, resumes when cleared; > 5 s blocked aborts with a UI error.
- Planning runs in a worker thread; session state shows `loading_profile` and rejects
  teleop for the planned arms. Failure UX: toast with failure kind + failing pair;
  arms stay held; options: retry / other profile / jog-clear. `start_in_collision`
  routes to the §7.3 wedged flow; `goal_in_collision` marks the profile unreachable.

## 10. Watchdogs

### 10.1 Stale-input deadman (`InputWatchdog`)

```python
class InputWatchdog:
    def __init__(self, timeout_s: float = 0.2, ramp_s: float = 0.1): ...
    def on_keys(self, msg: KeysMsg) -> None: ...  # transitions + 25 Hz heartbeats; rejects non-monotonic seq
    def scale(self, now: float) -> float: ...     # 1.0 fresh; → 0.0 over ramp_s after timeout_s; latches 0.0
    @property
    def needs_all_up(self) -> bool: ...           # latched until a KeysMsg with EMPTY held set
```

Teleop twist, joint-jog slew, and gripper held-keys are multiplied by `scale()` each tick;
rail held-keys are covered identically (always sent; server drops them for rail-less
arms). After a latch, held keys are ignored until the client sends an empty held-key set
— a reconnecting/un-frozen tab cannot resume motion with keys still down (T4/T5). 25 Hz
heartbeats mean `timeout_s=0.2` tolerates 4 lost messages.

### 10.2 Other watchdogs

- **Control-WS single-writer**: first `/ws/control` connection gets `role="controller"`
  in `HelloMsg` (core §10 enum); later ones are `role="observer"` with KeysMsg/ActionMsg
  ops discarded server-side. Controller disconnect ⇒ deadman latch (no heartbeats); the
  next connection may claim the controller role under a fresh session epoch. Never two
  live input streams per tick.
- **External-controller conflict (T9)**: driver registers `register_mode_changed_callback`
  / `register_state_changed_callback`; a mode/state change not initiated by the driver
  (UFACTORY Studio live-control) ⇒ hold that arm, health event + red banner, operator
  ack + §10.3 recovery to reclaim. Never fight Studio for mode/state in a loop.
- **Policy watchdog (T6)**: `Policy.act()` past deadline (policy period + 50 ms) ⇒ keep
  interpolating toward the last action for ≤ 5 periods, then hold + telemetry flag.
  NaN/inf/out-of-range actions sanitize to hold at the §4 chokepoint.

### 10.3 Servo-stream recovery + re-seed

Any nonzero code from `set_servo_angle_j`/state watch (the controller silently drops to
mode 0 on error) triggers, on the per-arm driver thread:

```
stop sending → get_err_warn_code() → clean_error(); clean_warn()
→ motion_enable(True) → set_mode(1) → set_state(0)
→ RE-SEED: q_seed = measured joints (report stream); target-pose integrator
  re-anchored from FK(q_seed); gate._last_safe[arm] = q_seed
→ resume streaming (input watchdog forces all-keys-up first)
```

Re-seeding is mandatory (SDK gotcha #4): resuming the old integrated target commands a
large jump ⇒ C24 / violent motion. The same sequence handles e-stop recovery (T7);
after a *hardware* e-stop the operator must also ack in the UI before `motion_enable`.

## 11. Controller backstops (per-arm, xArm SDK)

Applied at every session bring-up by
`apollo_xarm7_hardware.backstops.apply_backstops(api, cfg)` (02-hardware §6); values are
volatile by design — never call `save_conf()` (don't mutate controller persistent state).

Field mapping onto `XArmDriverConfig` (02-hardware §3.1, the actual schema):
`tcp_load_kg`/`tcp_cog_mm` = `tcp_load_kg`/`tcp_load_cog_mm`;
`collision_sensitivity` and `reduced_tcp_boundary_mm` map 1:1; `tool_model` +
`tool_model_params` are DERIVED from `gripper`; `self_collision_detection=True`
and `collision_rebound=False` are fixed defaults in `apply_backstops`, not config.

```python
class ArmSafetyParams(BaseModel):           # the L3 knob set — conceptual view; see the
                                            #   XArmDriverConfig field mapping above
    collision_sensitivity: int = 3          # 3–4; 5 false-triggers under payload
    self_collision_detection: bool = True
    tool_model: Literal["none","xarm_gripper","xarm_g2","cylinder","cuboid"] = "xarm_gripper"
    tool_model_params: dict = {}            # radius/height/xyz + offsets (mm at the boundary)
    tcp_load_kg: float; tcp_cog_mm: tuple[float, float, float]   # REQUIRED — torque-based
                                                                 # collision detection needs it
    reduced_tcp_boundary_mm: tuple[int, ...] | None = None  # [x_max,x_min,y_max,y_min,z_max,z_min], base frame
    collision_rebound: bool = False         # we own recovery; rebound fights re-seed
```

Call order: `set_tcp_load` → `set_collision_sensitivity(3)` →
`set_self_collision_detection(True)` → `set_collision_tool_model(1|9|21|22,…)` → if
boundary set: `set_reduced_tcp_boundary(...)`, `set_fence_mode(True)`,
`set_reduced_mode(True)` (master switch last — re-set after any reduced-* change) →
`set_collision_rebound(False)`. Verify via `get_reduced_states()`; log the echo into
the session record. Backstops are per-controller — blind to other arms and the rail;
L3 never substitutes for the twin gate.

## 12. Degraded modes

Fail-closed matrix (hardware mode):

| Degradation | Detection | Behavior |
|---|---|---|
| Twin unavailable at session start (`sim` extra missing, `digital_twin_scene` missing/uncompilable) or unexplained at-home contact (§6.3 audit) | session build / twin init | `POST /api/session` rejected 409 with reason (or the offending pair list); hardware sessions cannot exist ungated (§4 item 3) |
| Twin crashes mid-session (exception in check/sync) | supervisor try/except around twin calls | Immediate hold all arms; gate reports blocked + `stale_twin`; session drops to "safety-halted" — operator may only disconnect or restart |
| Arm report stale (> 0.15 s) / rail poll stale (> 0.5 s) | `ArmReportWatchdog` | Gate fails closed for ALL arms (§6.1) until fresh; auto-resume + all-keys-up |
| IK repeatedly infeasible after §8 ladder, or planner failure | per-tick / `PlanResult.failure` | Arm holds; teleop degraded to joint-jog escape; banner hint; planner UX per §9 |
| Controller error latched (C22/C31/C35/C24…) | report stream / API code 1 | Per-arm hold + §10.3 recovery; other arms keep operating (the halted arm's measured pose stays in the twin) |

Sim mode (default, `NullGate`): none of the above block motion — the only degradations
are physics-thread stalls, handled by the sim workcell. `safety_debug` follows the
hardware rows by construction.

## 13. UI surfacing contract

The UI is never in the control path; it renders safety state from `/ws/telemetry`
(20–30 Hz). Wire shape fixed by 05-ui.md: `TelemetryMsg.collision: CollisionReport{
blocked, pairs, min_clearance_m, severity: "ok"|"warn"|"blocked" }` (latest
`GateDecision` merged with the 25 Hz sweep, §7.2) and `TelemetryMsg.clearances: {pair,
dist_m}[]` (top-5 smallest, for `ClearanceReadout` — mm, monospace, color-graded).

Banner states (`CollisionBanner`): `"warn"` → amber "CLEARANCE LOW arm0/link5 ↔
arm1/link3 (12 mm)"; `"blocked"` → red "COMMAND BLOCKED BY TWIN GATE" + offending
pair, twin/sim `StreamView` tiles flash their border. `stale_twin` and
external-controller conditions surface via the health fields (05-ui.md degraded table).

**Blocked / wedged UX**: while blocked, the keybinding overlay dims the held direction
keys and the banner shows "reverse input to open clearance" (§7 step 6 guarantees
reversal passes when kinematically possible). Blocked > 3 s with input still held, or
active `kind="penetration"` ⇒ WEDGED state: names the pair, points to the joint-jog
panel (small deltas pass the escape rule joint-by-joint), offers "plan escape to
profile…" (§9 — `start_in_collision` is expected: the planner refuses; never auto-move
a wedged real arm). `CollisionEvent`s append to a session log pane (last 50) so
DAgger/inference blocks are auditable after the fact.

## 14. Validation plan & test strategy

### 14.1 Hardware-free unit tests

- `sim/tests/test_inflation_semantics.py` — MuJoCo version-pin sentinel (§6.2):
  sphere-pair detection distance, `efc_address == -1`, zero force.
- `sim/tests/test_pairs.py` — `link_base↔link1` exclude present per arm; at-home audit
  flags a deliberately bad scene; AllowedPairs filtering across `armK_` prefixes.
- `runtime/tests/test_gate.py` — `SafetyGate` vs a scripted fake twin: block on
  violation, hold == last-safe, hysteresis (no chatter across ±0.5 mm oscillation),
  escape-rule accept/reject, stale ⇒ fail-closed, edge events, non-offending arms unaffected.
- `runtime/tests/test_watchdogs.py` — deadman timing (0.2 s + 0.1 s ramp),
  seq-regression rejection, all-keys-up latch, observer-input discard.
- `runtime/tests/test_chokepoint.py` — §4 item-4 AST scan; hardware session w/o twin raises.
- `sim/tests/test_planner.py` — straight-line-free, obstacle detour, `goal_in_collision`,
  `start_in_collision`, timeout; edges re-validated at 2× resolution.

### 14.2 Sim integration (CI, `safety_debug`)

- Guardrail script §5.1, all scenarios × {IK on, IK off} — the safety regression gate
  for every PR touching sim/runtime.
- **Two-arms-close reset**: `cell_2arm`, arms scripted to interleaved poses 30 mm apart;
  request `start_from: profile:home_wide`. Assert: sequential plan succeeds within ≤ 2
  orderings; execution has zero gate blocks and zero ground-truth contacts; both arms
  land within 1e-3 rad. An impossible variant (goal overlapping the other arm) must
  return `goal_in_collision` with the correct pair.
- Recovery drill: kill the fake report stream mid-motion → hold within 1 tick of
  staleness, `stale_twin` event, clean resume + all-keys-up.

### 14.3 Hardware acceptance checklist (per cell, supervised, e-stop in hand)

1. Twin fidelity: jog to 6 taught poses near table/rail/other arm; twin `clearance()`
   vs tape measure must agree within δ/2 (4 mm), else fix extrinsics/meshes first.
2. Gate live test at 10% speed toward table and other arm: block before contact, banner + event.
3. Deep-penetration drill (§8): free-drive into the inflated band, re-engage; ladder retreats without C24/C31.
4. Deadman: yank client network mid-motion → ramp-to-zero ≤ 0.3 s; resume only after all-keys-up.
5. E-stop recovery: e-stop mid-stream → §10.3 + UI ack → no jump (first resumed step < 1 mm from measured).
6. Backstop echo: `get_reduced_states()` matches `ArmSafetyParams`; hand-tap triggers C31 at sensitivity 3.
7. Rail: over-travel clamped to [0, 0.65] m in our layer (don't rely on linear-motor
   errors 25/26); twin rail pose tracks measured within 5 mm.

Results recorded in `docs/acceptance/<cell_id>-<date>.md`; sessions on an unsurveyed
cell print a prominent "cell not accepted" warning in UI and logs.
