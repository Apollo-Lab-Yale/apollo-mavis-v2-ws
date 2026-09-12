# 01 — apollo-mavis-v2-core (`apollo_mavis_v2_core`)

Status: v1.0 (2026-09-01; amended 2026-09-03 — phase-10 tracker calibration:
`protocol/tracker.py`, `TrackerTelemetry.charging`/`.calibration`, §10-§12, §14;
amended 2026-09-03 — phase-11 MAVIS UI: `protocol/microphone.py`
(`MicrophoneInfo`, `MicStatus`), `MicrophoneTelemetry` / `TelemetryMsg.microphone`,
`ArmStatusInfo.reachable`, `WorkcellStatus.hardware_ready`, `ArmConfig.microphone`;
§7, §11, §12, §14; amended 2026-09-04 — phase-09a hardware twin overlay:
`protocol/hardware_monitor.py` (`ArmMonitorTelemetry`, `TwinOverlayTelemetry`,
`HardwareMonitorTelemetry`, `ArmMonitorStatus`, `TwinOverlayStatus`),
`TelemetryMsg.hardware_monitor`, `CameraInfo.kind` `"twin"`; §11, §12, §14, §18;
amended 2026-09-04 — phase-09b error recovery: `protocol/maintenance.py`
(`ArmMaintenanceRequest`, `ArmMaintenanceResult`, `ArmMaintenanceOp`,
`MaintenancePath`), `ArmConfig.collision_sensitivity` / `.reduced_tcp_boundary_mm` /
`.expected_sn`, `ArmMonitorTelemetry` safety read-back + `.maintenance_busy`,
`ArmTelemetry.fault_detail` / `.recovering`, `WorkcellInterface.drain_events`;
§5.1, §7, §11, §12, §14, §18 — all additive; amended 2026-09-05 — phase-09c
hardware session: `ArmMaintenanceOp` `home_rail`, `ArmMaintenanceRequest.dry_run`,
`RailSweepVerdict` / `ArmMaintenanceResult.rail_sweep`, `SessionSpec.speed_scale`,
`SessionInfo.kind` / `.speed_scale`, `ArmBringupTelemetry` /
`SessionTelemetry.bringup`, `RailNotHomedError`; §11, §12, §14, §16, §18 — all
additive; amended 2026-09-05 — phase-09d rail homing with twin planning:
`PrePositionPlan` / `RailSweepVerdict.pre_position`, `MaintenanceStatus` /
`ArmMaintenanceResult.status` / `.job_id`, `MaintenancePhase` /
`MaintenanceProgress` / `ArmMonitorTelemetry.maintenance` (the shared names
defined in the `hardware_monitor` leaf, re-exported by `maintenance`); §11,
§12, §14, §18 — all additive; amended 2026-09-08 — phase-12 dora boundary
(`protocol/external.py`, §20) and phase-14 **Online DAgger** (`15-online-dagger.md`
v2.0; the same evening's operator decision replaced the morning's PRO-DAgger v1.0
models — `ProDaggerConfig` / `ProDaggerStatus` / `ProDaggerIterationSummary` /
`ProDaggerSessionInfo` / `ProDaggerAnnounce` / `RefGradStatus` / `pro_dagger_train_now`
were DELETED, not aliased; superseded in-body with dated notes, kept in
`15-pro-dagger.md` as history): §9 `EpisodeSummary.n_expert_frames` /
`.n_novice_frames`, `GateEvent.source` `"action"`, §10 `ActionName` `takeover`,
`handback`, `train_now` (+ `goto_profile`, appended last the same evening), §11
`DaggerStatus.online_dagger` + `OnlineDaggerStatus`, §12 `OnlineDaggerConfig`,
`SessionSpec.online_dagger`, `SLUG_RE`, `DatasetLayoutInfo` / `DatasetNamespaceInfo`,
`OnlineDaggerSessionInfo`, `DatasetInfo.namespace` / `.path`, `SessionInfo.online_dagger`,
§14 the exported models, §19 ledger rows 11–14, §20 the external additions
(`OnlineDaggerAnnounce`, the 10-field `TrainerStatusAnnounce`, `EVENT_KINDS` + `train_now`)
— all additive, `mavis_schema` stays 1; amended 2026-09-12 — `WorkcellStatus.policy_modes`
(the runtime's `hardware_session.policy_modes` on the wire, always true for sim; §12, §14) —
additive).
Conforms to `00-overview.md` v0.3 (binding spine).
Research ground truth: `docs/research/{dagger-online-training, lerobot-data,
xarm-python-sdk, xarm7-ik}.md`. Message shapes mirror `05-ui.md` §2 exactly.
Sibling design docs defer exact spellings of core symbols to THIS document.

## 1. Scope & dependency rules

Core owns: geometry + SE3 math, domain state dataclasses, all spine-§3.3
interfaces, config/profile/safety schemas, DAgger core types/Protocols, the
wire protocol (canonical keymap + JSON-schema export for TS), the
`submit(cmd) -> Future` bus, and the `LatestSlot` queue primitive.

- **Deps: `numpy`, `pydantic` v2, `PyYAML` — nothing else** (no MuJoCo /
  xArm-SDK / FastAPI / torch / lerobot / OpenCV); enforced by the
  import-guard test (§18) and ruff banned-imports (§17).
- No I/O except `ProfileStore` (JSON dir), `load_workcell_config` (YAML), the
  `export_schemas` CLI. No sockets; no threads started by core (bus/slot are
  thread-*safe*, not thread-*owning*); no work at import time.
- Units: **m, rad**, quaternions **(w,x,y,z)** canonical `w >= 0`.
  mm/deg/pulses exist only inside `apollo_mavis_v2_hardware`.
- Wire-visible/persisted ⇒ pydantic `BaseModel`; hot-path (100 Hz, numpy) ⇒
  frozen `dataclass`. Python ≥ 3.10, managed with `uv`.

## 2. Package layout

```
apollo-mavis-v2-core/
├── pyproject.toml             # §17
├── schemas/                   # CHECKED-IN JSON Schema output of §14 (UI vendors these)
├── src/apollo_mavis_v2_core/
│   ├── __init__.py            # re-exports public API + __version__
│   ├── types.py se3.py        # §3      state.py                 # §4
│   ├── errors.py bus.py       # §16 §15 testing.py               # fakes, §18
│   ├── interfaces/            # arm.py camera.py workcell.py ik.py safety.py
│   │                          #   policy.py recorder.py teleop.py  (§5)
│   ├── schemas/               # config.py (§7)  safety.py (§6)  profile.py (§8)
│   ├── profiles/store.py      # ProfileStore (§8)
│   ├── dagger/                # types.py interfaces.py (§9)
│   └── protocol/              # control.py (§10) telemetry.py (§11) session.py (§12)
│                              #   tracker.py microphone.py maintenance.py (§12)
│                              #   hardware_monitor.py (§11)
│                              #   video.py keymap.py (§13) export_schemas.py (§14)
└── tests/                     # §18
```

`__init__.py` re-exports stable names (`from apollo_mavis_v2_core import
ArmState, Pose, ArmInterface, ...`). Adding fields to wire models is allowed
(UI ignores unknowns); rename/removal requires a §14 `--check` schema diff.

## 3. Geometry & frames (`types.py`, `se3.py`)

```python
# types.py
Vec3 = np.ndarray   # (3,) float64
Quat = np.ndarray   # (4,) float64, (w,x,y,z), canonical w >= 0

@dataclass(frozen=True)
class Pose:
    position: Vec3; orientation: Quat        # m; wxyz normalized, w >= 0
    # identity() / compose(other) / inverse() / to_matrix() -> (4,4) / from_matrix(m)

Transform = Pose    # SE3 alias: maps child-frame coords to parent

@dataclass(frozen=True)
class Twist:
    v: Vec3; w: Vec3                          # m/s, rad/s
    rail_v: float = 0.0; grip_v: float = 0.0  # m/s; open-fraction/s
    # zero()

FrameRef = str  # "world" | "arm_base:<arm_id>" | "camera:<camera_id>" | "ee:<arm_id>"
class ParsedFrame(NamedTuple):
    kind: Literal["world", "arm_base", "camera", "ee"]; ident: str | None
def parse_frame(ref: FrameRef) -> ParsedFrame     # raises FrameRefError
def frame_ref(kind: str, ident: str | None = None) -> FrameRef
```

`se3.py` — pure-numpy; THE quaternion convention functions (no repo rolls its own):

```python
quat_normalize(q)                     # unit norm AND w >= 0 (negate if w < 0)
quat_mul(a,b); quat_conj(q); quat_rotate(q,v)
quat_to_mat(q); mat_to_quat(m)        # Shepperd; canonical w >= 0
rpy_to_quat(rpy); quat_to_rpy(q)      # xArm SDK RPY: extrinsic XYZ, R = Rz(yaw)·Ry(pitch)·Rx(roll)
                                      #   (verified 2026-09-11 on 15 hardware episodes; the
                                      #   old Rx·Ry·Rz was wrong) — hardware/units.py
mat_to_rot6d(m) -> (6,); rot6d_to_mat(r6)  # Zhou et al. 2019: first two COLUMNS of R,
                                      #   column-major [R00,R10,R20,R01,R11,R21]; decode =
                                      #   Gram-Schmidt (ValueError on a ~zero / parallel pair)
quat_to_rot6d(q); rot6d_to_quat(r6)   # canonical w >= 0 — the abs_ee action codec
rotvec_to_quat(r); quat_to_rotvec(q)  # log map; delta-EE action rotations
quat_geodesic(a,b) -> [0,pi]; quat_slerp(a,b,t)
xyzw_to_wxyz(q); wxyz_to_xyzw(q)      # ONLY sanctioned order-swap helpers (scipy/ROS)
pose_mul(a,b); pose_inv(a); pose_between(a,b)        # a⁻¹ ⊕ b
pose_interp(a, b, t) -> Pose          # lerp position + slerp orientation, t clipped [0,1]
flange_to_tcp(pose, *, gripper); tcp_to_flange(pose, *, gripper)  # link7 flange <-> link_tcp:
                                      #   gripper=True: pose ⊕ (Trans(0,0,0.172), Rz(π));
                                      #   gripper=False: unchanged (link_tcp IS the flange)
pose_error(a,b) -> (pos_err_m, geodesic_rad)
integrate_twist(p, tw, dt) -> Pose    # translation along twist axes, rotation about
                                      #   pose origin (04-runtime §6 teleop semantics)
clamp_pose_to_leash(target, anchor, max_pos_m, max_rot_rad) -> Pose  # geodesic clamp

TCP_OFFSET_M = 0.172                  # link7 flange -> link_tcp along tool +Z (MJCF)
FLANGE_TO_TCP_QUAT = (0.,0.,0.,1.)    # Rz(π) wxyz: the gripper base is mounted 180° about
                                      #   tool z under link7 (MJCF xarm_gripper_base_link
                                      #   quat "0 0 0 1"); gripper arms only (2026-09-11)
LEGACY_FLANGE_QUAT_OFFSET = (0.,1.,0.,0.)  # legacy xarm7-ik 180°-about-X ("identity =
                                      #   gripper down") flange convention, 10-frames doc
RAIL_TRAVEL_M = 0.65                  # SDK does NOT clamp; legacy solver hardcoded 0.74
```

## 4. State dataclasses (`state.py`)

Hot-path snapshots (≤100 Hz); frozen dataclasses with numpy; never serialized
directly (telemetry converts to §11 models at 25 Hz).

```python
@dataclass(frozen=True)
class GripperState:
    open_frac: float                    # [0,1]; classic gripper pulses/850 (0.085 m span)
    moving: bool | None = None          # None = unknowable (gripper fw < 3.4.3)
    grasped: bool | None = None         # grasp status bit / convergence heuristic
    current: float | None = None        # A; only fw >= 2.7.100 monitor stream

@dataclass(frozen=True)
class GripperCommand:
    open_frac: float                    # target [0,1]; 1 = fully open
    force: float | None = None          # [0,1]; honored ONLY by force-capable grippers
    speed: float | None = None          #   (G2 -> 1-100 %); classic silently ignores

@dataclass(frozen=True)
class ArmState:
    arm_id: str
    q: np.ndarray; dq: np.ndarray       # (7,)|(8,) rad; q[7] = rail pos (m);
                                        #   dq rail slot 0.0 (vel unobservable)
    ee_pose: Pose                       # TCP in arm_base frame
    gripper: GripperState
    rail_pos_m: float | None            # None = no rail; == q[7] otherwise
    error_code: int; warn_code: int     # xArm codes (0 ok; 22 self-coll, 31 collision,
                                        #   35 boundary, 111 rail comms)
    mode: int; state: int               # controller mode (1 = servo) / state (0 ready)
    stale: bool                         # report age > 0.15 s (≈15 frames) -> gate holds
    t_mono: float; wallclock_ns: int    # source report frame timestamps

@dataclass(frozen=True)
class CameraFrame:
    camera_id: str
    rgb: np.ndarray                     # (H,W,3) uint8, RGB
    t_mono: float; wallclock_ns: int; seq: int = 0
```

Sim fills `error_code = warn_code = 0, mode = 1, state = 0` (`stale` from its
stepping-thread heartbeat). Constructors validate shape/dtype; published
arrays are immutable by convention (§16).

## 5. Interfaces (`interfaces/`)

Implementation facades = **ABCs** (all methods `@abstractmethod`); consumer
contracts = `@runtime_checkable` `typing.Protocol`s.

### 5.1 Arm / camera / workcell (ABCs)

```python
# interfaces/arm.py
class ArmInterface(ABC):
    def connect(self) -> None            # blocking bring-up; typed exceptions §16
    def disconnect(self) -> None         # idempotent
    def get_state(self) -> ArmState      # lock-free latest snapshot, never blocks
    def command_joints(self, q: np.ndarray) -> None
        # len(q) == dof; rad, q[7] = rail (m). Non-blocking latest-wins target for the
        # 100 Hz servo streamer; rail slot -> sparse rail path. NaN/shape -> CommandError
        # (runtime ControlLoop — the single gate chokepoint — sanitizes first).
    def command_gripper(self, cmd: GripperCommand) -> None   # queued; <=10 Hz advised
    def command_rail(self, pos_m: float) -> None
        # absolute, clamped to [0, RAIL_TRAVEL_M]; RailUnavailableError if !has_rail
    def clear_errors(self) -> None       # user-initiated recovery (LATCHED -> RECOVERING)
    def stop(self) -> None               # software stop; safe twice
    dof: int; has_rail: bool; gripper_force_capable: bool    # properties; dof = 7|8
                                         # fixed at connect; force-capable = xarm_g2 only

# interfaces/camera.py — LeRobot-style Camera ABC (background capture thread)
class CameraInterface(ABC):
    def start(self) -> None              # spawn capture thread; CameraInitError
    def stop(self) -> None               # join; idempotent
    def latest(self) -> CameraFrame | None    # non-blocking; None if never/stale
    camera_id: str; resolution: tuple[int, int]; fps: float  # properties

# interfaces/workcell.py
class WorkcellInterface(ABC):
    arms: dict[str, ArmInterface]        # keyed by ArmConfig.id, config order
    cameras: dict[str, CameraInterface]
    kind: Literal["hardware", "sim"]     # property
    def start(self) -> None
        # parallel per-arm bring-up; failures collected into WorkcellBringupError
        # .statuses (not fatal to siblings). Sim also starts its monotonic-paced
        # mj_step thread so runtime treats sim exactly like hardware (spine §3.3).
    def stop(self) -> None               # reverse order; idempotent
    def states(self) -> dict[str, ArmState]
    def drain_events(self) -> list[Any]  # NON-abstract, default []: the driver events (fault /
                                         #   recovered / reseed / Studio conflict / rail /
                                         #   gripper / stale) queued since the last call;
                                         #   the hardware workcell overrides, the runtime loop
                                         #   drains once per tick (04-runtime §15; phase-09b)
```

### 5.2 IK, digital twin, policy, recorder, teleop (Protocols + support types)

```python
# interfaces/ik.py
@dataclass(frozen=True)
class IKResult:
    q: np.ndarray                        # full config (7|8, incl. rail slot)
    pos_err_m: float; rot_err_rad: float
    diverged: bool                       # velocity IK converges silently to nearest
                                         #   reachable pose; runtime re-anchors on True
    active_collision_rows: int; solve_time_s: float

class IKSolver(Protocol):
    def solve(self, arm_id: str, target: Pose, q_seed: np.ndarray) -> IKResult: ...
        # one differential step; mink QP measured ~0.12 ms/arm (~8.6 kHz)
    def solve_to_convergence(self, arm_id: str, target: Pose, q_seed: np.ndarray,
                             max_steps: int = 50, n_restarts: int = 4) -> IKResult: ...
        # one-shot far targets (goto/planner endpoints); 2-4 ms measured
    def sync_passive(self, states: Mapping[str, ArmState]) -> None: ...  # pin non-active
    def reset(self, arm_id: str, q_measured: np.ndarray) -> None: ...
        # re-seed + clear accel/jerk history; MANDATORY after recovery/takeover

# interfaces/safety.py
@dataclass(frozen=True)
class PairClearance:
    geom1: str; geom2: str; body_pair: tuple[str, str]
    dist_m: float                        # signed; <= 0 = hulls touching
    fromto: np.ndarray | None = None     # (6,) witness segment (mj_geomDistance)

class DigitalTwinInterface(Protocol):
    def sync(self, states: Mapping[str, ArmState]) -> None: ...    # measured q -> qpos
    def check(self, q_by_arm: Mapping[str, np.ndarray]) -> CollisionReport: ...
        # COMMANDED config, all arms jointly; kinematic-only; 0.24-0.75 ms / 3 arms
    def check_config(self, q_full: np.ndarray) -> bool: ...        # planner fast path
    def clearance(self, distmax: float = 0.10) -> list[PairClearance]: ...
        # measured config, ascending; ~1 µs/pair; telemetry rate, not gate rate
        #   (distmax was 0.05; 0.10 since 2026-09-07 = SafetyConfig.clearance_sweep_m)
    def plan(self, req: PlanRequest) -> PlanResult: ...            # RRT-Connect (§6)
    def render(self, view: str) -> CameraFrame | None: ...         # render thread only
    def set_grasp_whitelist(self, arm_id: str, body_names: list[str]) -> None: ...

# interfaces/policy.py
@dataclass(frozen=True)
class Observation:
    state: np.ndarray                    # float32, layout per PolicySpec.state_names
    images: dict[str, np.ndarray]        # camera_id -> (H,W,3) uint8
    t_mono: float; wallclock_ns: int

@dataclass(frozen=True)
class PolicyOutput:
    actions: np.ndarray                  # float32; per-arm blocks in WorkcellConfig arm
    version: int; t_mono: float          #   order, layout per PolicySpec.action_names
    chunk_remaining: int = 0             # >0 for chunked policies (ACT/diffusion)

@dataclass(frozen=True)
class PolicySpec:                        # metadata carried by every checkpoint
    action_space: Literal["delta_ee", "abs_ee", "joint"]
    action_frame: str                    # full FrameRef: "arm_base:<arm_id>" | "world" |
                                         #   "camera:<camera_id>" (per-arm; never bare
                                         #   "base" — 10-frames §1.3)
    action_names: list[str]; state_names: list[str]
    camera_keys: list[str]; version: int

class Policy(Protocol):
    spec: PolicySpec                     # property
    def reset(self) -> None: ...         # drop chunks/history (takeover handback)
    def act(self, obs: Observation) -> PolicyOutput: ...
    def load_weights(self, path: str) -> None: ...   # state_dict hot-swap;
                                                     #   episode boundaries only

# interfaces/recorder.py — runtime implements the episode-directory store
# (10-frames §11; until 2026-09-07 it wrapped LeRobotDataset v3 directly)
class EpisodeRecorder(ABC):
    def start(self, meta: dict[str, object]) -> None       # open an episode (mint episode_id)
    def add_frame(self, frame: dict[str, object]) -> None  # buffer rows + feed the video encoder
    def save(self, sidecar: dict[str, object],
             audio: object | None = None) -> tuple[int, str]
                                         # publish episodes/<episode_id>/ atomically:
                                         #   videos, frames.parquet, stats, audio.wav,
                                         #   episode.json (sidecar + video/audio/stats
                                         #   blocks) LAST, then rename; returns
                                         #   (ordinal in capture order, episode_id)
    def discard(self) -> None            # cancel the encoder, rmtree the temp dir
    def finalize(self) -> None           # idempotent close: discard an open episode,
                                         #   close the encoder, sweep .tmp-*
    recording: bool                      # property
    episode_id: str | None               # property: the open episode's id

# interfaces/teleop.py — held-key provider (runtime's WS bridge implements)
@dataclass(frozen=True)
class HeldState:
    held: frozenset[str]                 # KeyboardEvent.code, movement keys only
    seq: int                             # KeysMsg.seq (monotonic; stale dropped)
    rx_mono: float                       # SERVER receive time — the watchdog feed

class TeleopInput(Protocol):
    def latest(self) -> HeldState | None: ...   # None = no controller connected
```

## 6. Safety schemas (`schemas/safety.py`)

All pydantic (wire-visible). Semantics in `11-safety-collision.md`.

```python
class CommandSource(str, Enum):
    TELEOP = "teleop"; JOINT_JOG = "joint_jog"; POLICY = "policy"
    TAKEOVER = "takeover"; PLANNER = "planner"

class CollisionEvent(BaseModel):
    t: Literal["collision_event"] = "collision_event"
    ts: float                            # server monotonic, s
    kind: Literal["blocked", "cleared", "warn", "penetration", "stale_twin"]
    pairs: list[tuple[str, str]]         # body names ("arm0/link5", "arm1/link3")
    dists_m: list[float]                 # signed clearance per pair (inflated geoms)
    min_clearance_m: float
    source: CommandSource | None = None
    arm_ids: list[str] = []              # offending arms

class CollisionReport(BaseModel):
    blocked: bool                        # gate clamping/holding
    severity: Literal["ok", "warn", "blocked"]
    pairs: list[tuple[str, str]] = []    # UI shape (05-ui §2)
    min_clearance_m: float = 1.0
    violations: list[CollisionEvent] = []      # rich detail; additive
    ts: float = 0.0
    # CollisionReport.ok() -> the NullGate / sim-default constant

class SafetyConfig(BaseModel):           # WorkcellConfig.safety
    enabled: bool = True                 # hardware REFUSES to start if False
    safety_debug: bool = False           # sim only: run FULL hardware-mode stack
                                         #   (twin + gate + IK rows) vs sim workcell
    geom_inflation_m: float = 0.008      # TOTAL pair inflation δ (per-geom δ/2)
    min_clearance_m: float = 0.0         # extra block threshold above inflation
    warn_clearance_m: float = 0.025      # UI amber
    clearance_sweep_m: float = 0.10      # pairs farther apart than this are not published
                                         #   in `clearances` (raised from 0.05 on 2026-09-07
                                         #   for the Cockpit ProximityFrame, 05-ui §8.2)
    hysteresis_m: float = 0.002          # unblock needs dist >= δ + this
    max_active_constraint_rows: int = 12 # IK CollisionAvoidanceLimit row cap
    twin_staleness_s: float = 0.15; rail_staleness_s: float = 0.5   # gate fails closed
    input_deadman_s: float = 0.2; input_ramp_s: float = 0.1
    allowed_pairs_extra: list[tuple[str, str]] = []

class PlanRequest(BaseModel):
    q_start: dict[str, list[float]]      # measured, full q incl. rail slot
    q_goal: dict[str, list[float]]       # e.g. from StateProfile (joint space)
    arm_order: list[str] | None = None   # None -> planner heuristic
    timeout_s: float = 5.0               # per arm
    max_step_rad: float = 0.05           # edge-check resolution (rail 0.01 m)
    speed_scale: float = 0.1             # the SessionSpec.speed_scale the plan runs at
                                         #   (2026-09-09): a pinched start's escape is judged
                                         #   per executor tick at it; default = the slowest
                                         #   speed offered (valid at any faster one)

class PlanResult(BaseModel):
    ok: bool
    waypoints: dict[str, list[list[float]]] = {}
    failure: Literal["goal_in_collision", "start_in_collision", "no_escape", "timeout"] | None = None
    failing_pair: tuple[str, str] | None = None
    arm_order: list[str] = []            # the ONLY order the arms may execute in; [] on failure
```

Validators: `blocked ⇔ severity == "blocked"`; `geom_inflation_m > 0`;
`safety_debug=True` with `enabled=False` rejected.

## 7. Configuration models (`schemas/config.py`, YAML-loadable)

```python
class PoseModel(BaseModel):              # JSON/YAML-friendly Pose
    position: tuple[float, float, float] = (0.0, 0.0, 0.0)
    orientation_wxyz: tuple[float, float, float, float] = (1.0, 0.0, 0.0, 0.0)
    # to_pose() (normalizes, w >= 0) / from_pose(p)

class ArmConfig(BaseModel):
    id: str                              # unique; MJCF attach prefix ("arm0_")
    ip: str | None = None                # required when kind == hardware
    base_in_world: PoseModel             # rail arms: the RAIL ORIGIN (fixed);
                                         #   base pose = rail origin ⊕ rail travel
    expect_rail: Literal["auto", "yes", "no"] = "auto"
    gripper: Literal["xarm", "xarm_g2", "none"] = "xarm"
    tcp_load_kg: float = 0.82            # -> set_tcp_load (L3 collision detection)
    tcp_load_cog_mm: tuple[float, float, float] = (0.0, 0.0, 48.0)
    microphone: bool = False             # microphone body mounted ahead of the wrist
                                         #   camera (hardware view arm: true) -> the
                                         #   digital twin adds its collision body
                                         #   (03-sim §4); additive, phase-11
    collision_sensitivity: int = Field(3, ge=0, le=5)
                                         # -> set_collision_sensitivity, 0 = off .. 5 = most
                                         #   sensitive; MAVIS: 3 on both arms (phase-09b).
                                         #   The CONTROLLER DEFAULT, re-applied at every
                                         #   connect; the operator may override it to 1..3
                                         #   at run time (§12 set_collision_sensitivity,
                                         #   2026-09-11) - volatile, this value returns at
                                         #   the next connect
    reduced_tcp_boundary_mm: tuple[int, int, int, int, int, int] | None = None
                                         # Reduced-mode TCP box [x_max, x_min, y_max, y_min,
                                         #   z_max, z_min] mm (SDK set_reduced_tcp_boundary
                                         #   order); None = leave Reduced mode off
    expected_sn: str | None = None       # controller SN verified at connect; None = skip
                                         #   (both MAVIS boxes read the model code "XS1305",
                                         #   not a unique serial)

class CameraIntrinsics(BaseModel):
    fx: float; fy: float; cx: float; cy: float
    distortion: list[float] = []         # OpenCV k1..k5

class CameraConfig(BaseModel):
    id: str
    kind: Literal["v4l2", "realsense", "sim"]
    device_path: str | None = None       # v4l2 (stable by-id path)
    serial: str | None = None            # realsense
    resolution: tuple[int, int] = (640, 480); fps: int = 30
    intrinsics: CameraIntrinsics | None = None
    extrinsics_frame: FrameRef | None = None   # frame the calibration is expressed in
    extrinsics_file: str | None = None         # calibration file path (spine §3.1)

class WorkcellConfig(BaseModel):
    kind: Literal["hardware", "sim"]
    arms: list[ArmConfig]                # 1-3
    cameras: list[CameraConfig] = []     # <= 4 (3 wrist + 1 env typical)
    sim_scene: str | None = None         # scene-registry id (sim mode)
    digital_twin_scene: str | None = None      # scene-registry id (hardware mode)
    safety: SafetyConfig = SafetyConfig()

def load_workcell_config(path: str | Path) -> WorkcellConfig
    # yaml.safe_load + model_validate; ConfigError carries path + JSON-pointer loc
```

Cross-field validators (`model_validator(mode="after")`): sim ⇒ `sim_scene`;
hardware ⇒ every arm has `ip`, `digital_twin_scene` set, `safety.enabled`
True; ids unique; v4l2 ⇒ `device_path`, realsense ⇒ `serial`, sim cameras
only in sim configs; `extrinsics_frame` parses and references a declared id.
`ArmConfig.microphone` carries no core validator — the sim's `ArmSpec`
after-validator (03-sim §4: requires `wrist_cam` and `gripper == "none"`)
rejects it on a non-camera arm when the twin is built.
`collision_sensitivity` is bounded 0..5 (`Field(ge=0, le=5)`) and
`reduced_tcp_boundary_mm` is exactly six ints or absent; together with
`tcp_load_kg` / `tcp_load_cog_mm` they are the controller-side backstops the
hardware driver applies at connect (`backstops.apply_backstops`, 02-hardware
§6: tcp_load → gravity → sensitivity → self-collision + tool model → optional
Reduced boundary → rebound off), the UI re-applies session-less
(`ArmMaintenanceOp` `apply_backstops`, §12) and the monitor reads back
(`ArmMonitorTelemetry.backstops_match`, §11). They are volatile on the
controller (lost at reboot), never `save_conf()`ed. `collision_sensitivity` is
also the one the operator may override at run time to 1, 2 or 3 (§12
`set_collision_sensitivity`, 2026-09-11) — the config value stays the default
that every connect restores, and `backstops_match` compares against the
requested level while an override is in force (§11). MAVIS values are estimates
the user accepted on 2026-09-05 without weighing (whole-arm collision detection
is the goal; provisional since 2026-09-04): Manipulation Arm 0.95 kg @ (0, 0,
60) mm, Perception Arm 0.55 kg @ (0, 0, 90) mm, collision sensitivity 3 on both
(04-runtime §14).
Config files (`configs/hardware.yaml`, `configs/sim.yaml`) live in the runtime
deployment dir; `POST /api/session` honors requested `kind` iff that config
exists and validates (binding; else 409).

## 8. State profiles (`schemas/profile.py`, `profiles/store.py`)

```python
class ArmPosture(BaseModel):
    q: list[float]                       # 7 floats, rad (NEVER includes rail slot)
    rail_pos_m: float | None = None      # None = no rail
    gripper_open_frac: float = 1.0

class StateProfile(BaseModel):
    schema_version: int = 1              # store migrates old files on read
    profile_id: str                      # uuid4 hex, assigned by the store
    name: str; notes: str = ""
    workcell_kind: Literal["hardware", "sim"]
    arms: dict[str, ArmPosture]          # may cover a subset of the workcell
    created_at: str                      # ISO 8601 UTC
    is_initial_condition: bool = False   # AT MOST one per workcell_kind (invariant)

class ProfileStore:
    """One file per profile `<profile_id>.json` under root. Every write is
    atomic: `<id>.json.tmp` then os.replace — a crashed save never corrupts."""
    def __init__(self, root: str | Path) -> None       # mkdir -p
    def list(self) -> list[StateProfile]               # sorted by created_at
    def get(self, profile_id: str) -> StateProfile     # ProfileNotFoundError
    def save(self, profile: StateProfile) -> StateProfile
        # assigns id/created_at when empty; existing id = atomic overwrite
        # ("save current state as initial condition" overwrite path, spine §3.4)
    def delete(self, profile_id: str) -> None          # refuses on designated initial
    def rename(self, profile_id: str, name: str, notes: str | None = None) -> StateProfile
    def set_initial(self, profile_id: str) -> None
        # set flag here, clear on all others of the same kind; target written LAST
        # (crash mid-op -> zero flags, never two)
    def initial_for(self, kind: Literal["hardware", "sim"]) -> StateProfile | None
```

Runtime wraps this with `save_from_snapshot(StateSnapshot, ...)` (§19-3).
Loading a profile is always runtime-side twin-planned motion
(`DigitalTwinInterface.plan`) — never xArm native gohome. Unreadable/foreign
files are skipped into `store.errors: list[tuple[Path, str]]`, never fatal.

## 9. DAgger core types & protocols (`dagger/`)

Shared by DAgger **and** inference: the identical `TakeoverGate` gates Space
in both; the *presence of a recorder* — not a flag — distinguishes them
(`InferenceSession` passes `recorder=None`, so safety-escape frames
structurally cannot be recorded; 12-dagger §3, binding).

```python
# dagger/types.py
class ControlMode(str, Enum):
    POLICY = "policy"; HUMAN = "human"; TAKEOVER_TRANSITION = "takeover_transition"
    # to_int8(): dataset encoding 0 / 1 / 2 (12-dagger §4)

@dataclass(frozen=True)
class GateEvent:                         # emitted on every mode change, per arm
    arm_id: str; mode: ControlMode       # mode = NEW mode
    t_mono: float; seq: int              # seq monotonic per session
    source: str                          # "keyboard" | "auto_advance" | "episode_reset"

@dataclass(frozen=True)
class FrameAnnotations:                  # extra per-frame dataset columns
    control_mode: ControlMode
    executed_action: np.ndarray          # post-twin-gate value, canonical frame = LABEL
    policy_action: np.ndarray | None     # counterfactual; None -> NaN row in dataset
    policy_version: int
    action_frame: str                    # FrameRef: "arm_base:<id>" | "world" | "camera:<id>"

@dataclass(frozen=True)
class CheckpointInfo:                    # manifest.json payload (12-dagger §7)
    run_id: str; version: int            # version monotonic within run
    path: str                            # checkpoints/{run_id}/v{n:06d}/
    parent_version: int | None
    trained_on_frames: int               # dataset watermark (label frames consumed)
    trained_on_episodes: list[int]
    action_frame: str; action_space: str # must match session; FrameRef "arm_base:<id>"|
                                         #   "world"|"camera:<id>"; "delta_ee"|"abs_ee"|"joint"
    sanity_ok: bool; mean_loss: float
    sha256: str                          # of state_dict.pt (verified before swap)
    created_wallclock_ns: int

@dataclass(frozen=True)
class EpisodeSummary:                    # runtime -> trainer at every episode save
    episode_index: int; n_frames: int
    n_intervention_frames: int           # control_mode != POLICY
    n_label_frames: int                  # control_mode == HUMAN (HG-DAgger Eq. 2)
    takeover_segments: int               # maximal runs of control_mode != POLICY
    segment_doubts: list[float]          # policy-action variance at takeover instants
    success: bool | None
    episode_id: str = ""                 # 10-frames §11.3 directory id (2026-09-07); the spool is
                                         #   trainer_spool/ep_<episode_id>.parquet; episode_index
                                         #   stays the capture-order watermark (12-dagger §7)
    n_expert_frames: int = 0             # phase-14 (2026-09-08; 15-online-dagger §4, additive): frames
    n_novice_frames: int = 0             #   with actor == 1 (control_mode != POLICY — transition
                                         #   frames too, unlike n_label_frames) / actor == 0.
                                         #   GateEvent.source (dagger/types.py) is a plain str spelled
                                         #   "keyboard" | "auto_advance" | "episode_reset" and, since
                                         #   2026-09-08 evening, "action" (the explicit takeover /
                                         #   handback actions; additive — the comment lists three)

class TrainerStatus(BaseModel):          # pydantic — rides telemetry (§11)
    state: Literal["starting", "idle", "training", "dead"]
    steps_total: int = 0
    last_burst_loss: float | None = None
    last_checkpoint_version: int | None = None
    last_checkpoint_ts: float | None = None
    new_label_frames: int = 0            # progress toward the 100-frame trigger

# dagger/interfaces.py — all @runtime_checkable Protocols
class TakeoverGate(Protocol):            # impl: runtime/dagger/gate.py (12-dagger §2)
    def mode(self, arm_id: str) -> ControlMode: ...
    def engaged_arm(self) -> str | None: ...    # arm in HUMAN/TRANSITION, else None
    def on_toggle(self, arm_id: str, t_mono: float) -> GateEvent | None: ...
        # ActionMsg{takeover_toggle} handler; None -> caller Nacks
    def tick(self, t_mono: float) -> list[GateEvent]: ...
        # 100 Hz; auto-advances TRANSITION -> HUMAN after T_blend (0.3 s)
    def reset(self) -> None: ...                # episode boundary -> all AUTONOMOUS

class InterventionRecorder(Protocol):    # impl: runtime DaggerRecorder (LeRobot v3)
    def start_episode(self, meta: dict[str, object]) -> str: ...
    def add_frame(self, obs: dict[str, object], ann: FrameAnnotations) -> None: ...
    def end_episode(self, success: bool | None, rerecord: bool) -> EpisodeSummary: ...

class PolicyReloader(Protocol):          # impl: runtime reloader (12-dagger §8)
    def stage(self, ckpt: CheckpointInfo) -> None: ...   # keeps only the newest
    def maybe_swap(self, at_episode_boundary: bool,
                   current_mode: ControlMode) -> int | None: ...  # new version | None
    def rollback(self) -> int: ...       # LAST_KNOWN_GOOD; allowed mid-episode
    def mark_good(self) -> None: ...     # clean episode completed on current version

class AsyncTrainerClient(Protocol):      # impl: runtime client (ZMQ + filesystem)
    def submit_episode(self, episode_path: str, summary: EpisodeSummary) -> None: ...
    def poll_checkpoint(self) -> CheckpointInfo | None: ...  # newest sanity_ok > current
    def status(self) -> TrainerStatus | None: ...            # None = unreachable/dead
    def request_stop(self) -> None: ...                      # graceful; impl escalates
```

## 10. Protocol: control WS messages (`protocol/control.py`)

Binding decisions mirrored exactly (05-ui §2 / 04-runtime §13.2); `t`
discriminators let one `TypeAdapter` parse the channel.

```python
ActionName = Literal[
    "switch_arm", "switch_arm_prev", "takeover_toggle",
    "episode_new", "episode_save", "episode_discard",
    "reset_to_initial",                  # 2026-09-08 (key R): walk the workcell back to
                                         #   the designated initial condition; no args.
                                         #   04-runtime §10.5
    "save_profile", "set_initial_condition", "joint_target",
    "tracker_settings",
    "takeover", "handback", "train_now", # phase-14 (2026-09-08 evening; 15-online-dagger D3 / §3):
                                         #   the Online DAgger shell's three Cockpit buttons —
                                         #   explicit take-over of the active arm (idempotent: a
                                         #   no-op ack "already taken over" in HUMAN / TRANSITION),
                                         #   hand control back to the policy (idempotent: "policy
                                         #   already driving"), ask the trainer to train on the
                                         #   rollouts saved so far (events.train_now; the trainer
                                         #   may ignore it). No args, NO key binding (Space keeps
                                         #   takeover_toggle; the KEYMAP stays 24 rows); nacked
                                         #   "takeover not available in teleop" / "not an Online
                                         #   DAgger session" elsewhere. Superseded (2026-09-08
                                         #   evening): the morning's "pro_dagger_train_now"
    "goto_profile",                      # 2026-09-08 (later the same evening): drive the arms to a
                                         #   SAVED profile — args GotoProfileArgs{profile_id}
                                         #   (extra="forbid", ProfileStore id charset, REQUIRED);
                                         #   twin-planned, gated, cancellable execute_plan path
                                         #   (04-runtime §10.5); no key. Appended LAST (additive)
]

class HelloMsg(BaseModel):               # server -> client, immediately after accept
    t: Literal["hello"] = "hello"
    epoch: str                           # runtime process UUID (client detects restarts)
    session_id: str | None
    role: Literal["controller", "observer"]  # first connection = controller;
                                             #   later = read-only observer (binding)

class KeysMsg(BaseModel):                # controller -> server: IMMEDIATE on every key
    t: Literal["keys"] = "keys"          #   transition + 25 Hz full-state heartbeat
    seq: int                             # monotonic; server drops seq <= last_seq
    ts: float                            # client wall clock s — latency metric ONLY;
                                         #   watchdog feeds on server rx time
    held: list[str]                      # held movement KeyboardEvent.codes. Rail codes
                                         #   always sent; server ignores them when the
                                         #   active arm has no rail (binding)

class ActionMsg(BaseModel):              # client -> server, once per press/click
    t: Literal["action"] = "action"
    name: ActionName
    args: dict[str, Any] = {}            # validated per-name via models below

class AckMsg(BaseModel):                 # server -> client, one per ActionMsg
    t: Literal["ack"] = "ack"
    name: ActionName; ok: bool
    detail: str = ""                     # "observer", "takeover active", planner reason

class JointTargetArgs(BaseModel):        # name == "joint_target"
    arm_id: str
    positions: list[float]               # FULL q incl. rail slot (rad; rail m); len == dof
    mode: Literal["jog", "goto"]         # jog: slew-limited streaming (~20 Hz slider drag)
                                         # goto: large jump via twin planner (binding)

class SaveProfileArgs(BaseModel):
    name: str; notes: str = ""

class SetInitialConditionArgs(BaseModel):
    profile_id: str | None = None        # None: save current state first (name "initial",
                                         #   overwrite), then designate (04-runtime §9)

class TrackerSettingsArgs(BaseModel):    # name == "tracker_settings" (13-tracker §3.4, §4)
    yaw_deg: float | None = None         # fields omitted (None) = unchanged
    pos_scale: float | None = None       # 0.1 <= pos_scale <= 3.0
    follow_rotation: bool | None = None
    filter_enabled: bool | None = None   # One Euro pose filter (13-tracker §4 "Pose filter")
    filter_min_cutoff_hz: float | None = None   # 0.05 <= x <= 50 (0 would freeze the filter)
    filter_beta: float | None = None     # 0 <= x <= 200 (speed coefficient, Hz per (m/s);
                                         #   ceiling raised from 5 on 2026-09-07, 13-tracker §4)

ControlClientMsg = Annotated[KeysMsg | ActionMsg, Field(discriminator="t")]
ControlServerMsg = Annotated[HelloMsg | AckMsg, Field(discriminator="t")]
```

Normative: **Space = discrete takeover toggle** — one
`ActionMsg{takeover_toggle}` per physical press, never in `KeysMsg.held`;
recorded intervention in DAgger, never-recorded safety escape in inference.
`switch_arm` / `switch_arm_prev` carry no index; the server cycles the
authoritative active arm forward / backward (`(i ± 1) mod n`). `validate_action_args`
requires `args == {}` for every action without an args model.

`tracker_settings` is a partial update: every field is optional and `None`
means "unchanged", so the UI settings form can send only the field it
committed (Enter/blur). The `filter_*` fields tune the runtime's One Euro pose
filter live (devices/debug page); the bounds are wire-level guards only — the
runtime owns the defaults (`min_cutoff_hz 1.0`, `beta 5.0` since 2026-09-07 —
was 0.05, 13-tracker §4) via `TrackerConfig.filter`. A settings change while
the clutch is engaged makes the runtime re-anchor (13-tracker §4 "Anchor and
re-seed rules"); it never moves the arm.

Tracker calibration (phase-10; 13-tracker §3/§4) adds **no** `ActionName`: the
Devices page has no session and `/ws/control` nacks actions without one, and
`AckMsg` carries no payload. Calibration commands ride REST
(`TrackerCalibrationCommand`, §12) and progress rides telemetry
(`TrackerTelemetry.calibration`, §11). `_ARGS_MODELS` and the 23-row keymap
(§13) are unchanged — the controller trigger is re-purposed by the runtime as
the yaw-gesture capture click while a yaw calibration is active.

## 11. Protocol: telemetry (`protocol/telemetry.py`, `protocol/hardware_monitor.py`)

Server → all `/ws/telemetry` clients at 25 Hz (20–30 band). Shapes match
05-ui §2; *additive* fields extend the UI shape (UI ignores unknowns).

```python
class PoseMsg(BaseModel):
    position: tuple[float, float, float]                # m
    orientation: tuple[float, float, float, float]      # wxyz

class ArmTelemetry(BaseModel):
    arm_id: str; connected: bool
    q: list[float]                       # rad, len 7
    rail_pos_m: float | None             # None = no rail; 0-0.65
    ee_pose: PoseMsg; gripper_open_frac: float
    error_code: int                      # 0 = ok (xArm code otherwise)
    warn_code: int = 0; stale: bool = False             # additive
    goto: Literal["planning", "executing", "failed"] | None = None
                                         # joint-panel lifecycle; "failed" transient
    fault_detail: str = ""               # controller fault the arm is stopped for, e.g.
                                         #   "controller error 24: Speed Exceeds Limit" (SDK
                                         #   x_code title); "" = none (additive, phase-09b)
    recovering: bool = False             # recovery ran (session RECOVERING); streaming resumes
                                         #   once the operator re-grips the clutch (additive)

class ClearanceItem(BaseModel):
    pair: tuple[str, str]; dist_m: float

class EpisodeStatus(BaseModel):
    state: Literal["idle", "recording", "saving", "returning"]
                                         # returning (2026-09-07): a return_to_start motion
                                         #   is running (04-runtime §10.5); episode_new nacked
    index: int | None; frames: int; duration_s: float
    repo_id: str | None = None           # additive (2026-09-07): the session's dataset
    total_episodes: int = 0; total_frames: int = 0   # manifest counters (saved episodes)
    detail: str = ""                     # "returning to profile 'ready'", "return
                                         #   cancelled: movement key", "recorder degraded …"
    frames_skipped: int = 0              # additive (2026-09-07): idle frames the action filter
                                         #   dropped in the open episode (04-runtime §10.5)

class DatasetExportTelemetry(BaseModel): # TelemetryMsg.datasets.export (additive, 2026-09-07)
    repo_id: str; format: str
    phase: Literal["scanning", "videos", "data", "meta", "validating", "done", "failed"]
    done: int = 0; total: int = 0; detail: str = ""

class DatasetsTelemetry(BaseModel):      # TelemetryMsg.datasets (additive, 2026-09-07; session-less
    export: DatasetExportTelemetry | None = None   #   like microphone): the running / last export

class OnlineDaggerStatus(BaseModel):     # DaggerStatus.online_dagger (phase-14, 2026-09-08 evening;
    session_name: str                    #   15-online-dagger §3/§5): the runtime's ROLLOUT-LEVEL shell
    phase: Literal["waiting_trainer", "rollout", "training", "error"]   # a pure function of the last
                                         #   trainer status echoing THIS session + the ready latch
    rollouts_saved: int                  # kept rollouts of the session (a resume continues the count)
    detail: str = ""                     # the exact episode_new refusal, or the trainer's detail
    trainer_alive: bool = False          # a fresh trainer_status (<= dora.policy.spec_stale_s)
    trainer_age_s: float | None = None
    trainer: TrainerStatusAnnounce | None = None   # verbatim last status (protocol.external, §20)
    policy_version_acting: int | None = None       # follows the announced spec / action version
    expert_frames_session: int = 0; novice_frames_session: int = 0   # kept frames this SESSION (actor)
    session_dir: str = ""                # ~/data/online_dagger/<session_name>
# Superseded (2026-09-08 evening): the morning's ProDaggerIterationSummary (a finished iteration's
# loss / proj_rate / n_proj / train_steps / wall_s / versions / timestamps) and ProDaggerStatus
# (phases preparing | rollout | training | swapping | error, iteration, rollout_index,
# rollouts_per_iteration, per-iteration frame counts, history[12]) — the shell counts kept
# rollouts and the session's actor split, never iterations; every metric is the trainer's
# free-form TrainerStatusAnnounce.metrics. Deleted, not aliased (never shipped).

class DaggerStatus(BaseModel):           # full shape per 12-dagger §11 (canonical)
    control_mode: ControlMode; engaged_arm: str | None
    frozen_arms: list[str] = []
    policy_version: str | None           # "{run_id}/v{n:06d}"; updates only at swaps
    staged_version: str | None = None
    episodes_labeled: int = 0
    takeover_rate_ep: float = 0.0        # human-frame fraction, current episode
    takeover_rate_run: float = 0.0       # rolling mean, last 10 episodes
    new_label_frames: int = 0
    trainer: TrainerStatus | None = None
    policy_stale: bool = False           # additive (phase-12; §20): the policy output is past its
                                         #   staleness window -> policy arms hold (12-dagger §6.3)
    online_dagger: OnlineDaggerStatus | None = None   # additive (phase-14; 15-online-dagger §5):
                                         #   non-null iff the session's SessionSpec.online_dagger is
                                         #   set; last (the morning's pro_dagger field superseded)

class InferenceStatus(BaseModel):        # same gate machinery; takeover = SAFETY ESCAPE
    control_mode: ControlMode
    engaged_arm: str | None = None       # additive vs 05-ui
    policy_version: str | None

class ArmBringupTelemetry(BaseModel):    # one hardware bring-up step of one arm (phase-09c)
    arm_id: str
    step: str                            # stage: monitor / network / connect / rail / gripper /
                                         #   report / warnings / gate / frozen / loop (the hardware
                                         #   ArmBringupStatus stages + the runtime's own rows)
    status: Literal["pending", "ok", "warning", "error"]
    detail: str = ""                     # e.g. "Perception Arm frozen at last sample"

class SessionTelemetry(BaseModel):       # additive block (04-runtime §13.3)
    state: str                           # SessionState value
    start_from_progress: float | None = None    # 0-1 during START_FROM
    plan_status: str | None = None; trainer_alive: bool | None = None
    bringup: list[ArmBringupTelemetry] | None = None
                                         # hardware bring-up progress fed from the workcell's
                                         #   status_cb while state == "bringup"; None for sim
                                         #   sessions / once running (additive, phase-09c)
    translate_frame: Literal["camera", "world", "base"] | None = None
                                         # additive 2026-09-08: the frame this session's
                                         #   keyboard TRANSLATE keys act in (runtime
                                         #   control.translate_frame; rotations are always
                                         #   about the TCP axes). The keymap labels the KEY
                                         #   axes ("forward", "up"), never a frame, so the
                                         #   overlay needs this to say what they mean.
                                         #   None = no session. 04-runtime §6

class TrackerSettingsMsg(BaseModel):     # live tracker settings (13-tracker §3.5, §4)
    yaw_deg: float; pos_scale: float; follow_rotation: bool
    filter_enabled: bool = True          # effective One Euro pose-filter settings; defaults
    filter_min_cutoff_hz: float = 1.0    #   = the runtime's TrackerConfig.filter defaults
    filter_beta: float = 5.0            #   (additive; pre-filter producers still parse;
                                         #   the runtime's effective default is 5.0 since
                                         #   2026-09-07 — the protocol echo default still
                                         #   reads 0.05 in code, to be aligned)

class ControllerTelemetry(BaseModel):    # raw Vive-controller inputs (13-tracker §1.1)
    trigger: float = 0.0                 # analog pull 0..1
    trigger_pressed: bool = False        # trigger click (libsurvive button 0)
    trackpad_touch: bool = False         # finger on pad (TOUCH_DOWN/UP)
    trackpad_click: bool = False         # pad pressed (button 1)
    trackpad_x: float = 0.0; trackpad_y: float = 0.0   # -1..1, +y = top
    grip: bool = False; menu: bool = False; system: bool = False   # buttons 7/6/3

class TrackerTelemetry(BaseModel):       # additive block (13-tracker §3.5)
    backend: Literal["libsurvive", "fake", "none"]
    status: Literal["no_backend", "starting", "searching", "tracking", "stale", "error"]
    detail: str = ""; object_name: str = ""
    seq: int = 0; rate_hz: float = 0.0; age_s: float | None = None
    pose_raw: PoseMsg | None = None      # lighthouse world
    pose_world: PoseMsg | None = None    # after yaw alignment
    pose_filtered: PoseMsg | None = None # world, after alignment + One Euro filter (§4);
                                         #   the pose the anchor/delta math consumes
    clutch: bool = False; engaged_arm: str | None = None
    anchor_tcp: PoseMsg | None = None    # EE pose at engagement (world)
    target_tcp: PoseMsg | None = None    # tracker-derived EE target (world)
    settings: TrackerSettingsMsg         # device fields populated even without a
                                         #   session; session fields None otherwise
    controller: ControllerTelemetry | None = None   # None = backend reports no controller
    device_held: list[str] = []          # key codes injected from the controller (§1.1
                                         #   table, e.g. ["KeyC", "KeyH"]); [] when stale
    device_action: str | None = None     # last device-sourced discrete action ("switch_arm"
                                         #   / "switch_arm_prev"); runtime clears it ~1 s later
    charging: bool | None = None         # controller on external (USB) power; None = not
                                         #   reported (additive)
    calibration: TrackerCalibrationStatus | None = None
                                         # phase-10 calibration snapshot (protocol.tracker,
                                         #   §12) — same object as GET /api/tracker/calibration
                                         #   (additive; sub-models ride TelemetryMsg $defs)
    controller_age_s: float | None = None
                                         # now − ControllerState.rx_mono of the newest
                                         #   button/axis event (independent of age_s, the
                                         #   POSE age); 2026-09-07, 13-tracker §3 item 7b
    objects: list[str] = []              # libsurvive OBJECT-type codenames, e.g. ["WM0"];
                                         #   [] = nothing paired / interface not openable
    dongle_present: bool | None = None   # USB 28de:2101 in sysfs; None = not checked
                                         #   (all three additive; UI reads None/undefined as
                                         #   UNKNOWN, never as unplugged / unpaired)

class MicrophoneTelemetry(BaseModel):    # additive block (phase-11; 04-runtime §13.3);
    mic_id: str = "mic_view"             #   EVERY field defaults (no-mic producers validate)
    status: MicStatus = "no_backend"     # MicStatus shared with MicrophoneInfo (§12)
    detail: str = ""                     # reason for absent/error/no_backend
    seq: int = 0; age_s: float | None = None; rate_hz: float = 0.0
    sample_rate: int = 48000             # Hz; one frame per telemetry tick
                                         #   (48000 / 25 Hz = 1920 samples = 64 x 30)
    rms_dbfs: float | None = None        # frame RMS, 0 dBFS = |1.0|; None = no frame yet
    peak_dbfs: float | None = None
    clipping: bool = False               # peak >= -1 dBFS
    env_min: list[int] = []              # 64 x int8 (-127..127) RELATIVE to the frame peak,
    env_max: list[int] = []              #   time-ordered per-bin min / max envelope; absolute =
                                         #   env / 127 * 10 ** (peak_dbfs / 20) (oscilloscope)
    overruns: int = 0                    # backend overruns / dropped blocks since start

ArmMonitorStatus  = Literal["off", "connecting", "running", "stale", "paused", "error"]
    # protocol/hardware_monitor.py (phase-09a). off = monitor disabled / hardware package
    # not importable; connecting = opening the box (incl. reconnect backoff); running =
    # samples within stale_s; stale = connected, last sample older than stale_s; paused =
    # a hardware session owns the box (connection RELEASED, never shared); error =
    # connect / read failure (runtime retries with exponential backoff)

ArmMaintenanceOp  = Literal["clear_errors", "apply_backstops", "recover", "home_rail"]
    # the §12 maintenance-op vocabulary. DEFINED in protocol/hardware_monitor.py (the leaf)
    # and re-exported by protocol/maintenance.py because MaintenanceProgress.op below needs
    # it here while maintenance.py embeds ArmMonitorTelemetry - the two modules would
    # otherwise import each other (phase-09d); import it from either module

MaintenancePhase  = Literal["queued", "sweeping", "planning", "connecting", "positioning",
                            "homing", "verifying", "done", "failed"]
    # phase-09d: phases of the asynchronous RailHomingJob (one arm at a time), in execution
    # order - queued = accepted (202), thread not started; sweeping = full-travel twin sweep
    # at the CURRENT posture; planning = twin RRT-Connect to a rail-safe posture + the
    # position-agnostic path check (every waypoint clear for EVERY rail position);
    # connecting = monitor paused + joined, this arm's driver connected with the rail still
    # unhomed at speed_scale 0.1, the other arm frozen at its last sample (09c D1);
    # positioning = the planned path executes under the gate (ControlLoop._op_execute_plan);
    # homing = driver.home_rail(), joints held; verifying = registers homed + enabled + no
    # error, monitor sample, driver torn down (state 4 + brakes -> posture HELD), monitor
    # resumed; done / failed = terminal, the final ArmMaintenanceResult (§12) is at
    # GET .../maintenance/last

class MaintenanceProgress(BaseModel):    # phase-09d: rides ArmMonitorTelemetry.maintenance
    op: ArmMaintenanceOp                 #   while a RailHomingJob runs (None otherwise)
    job_id: str                          # matches the 202 ArmMaintenanceResult.job_id
    phase: MaintenancePhase
    detail: str = ""                     # operator-facing progress / failure reason
    progress: float = 0.0                # 0..1 coarse estimate (phase index + waypoint
                                         #   fraction while positioning)
    started_at: float | None = None      # unix s

class ArmMonitorTelemetry(BaseModel):    # one arm as seen by the READ-ONLY monitor
    arm_id: str                          # the only required field
    status: ArmMonitorStatus = "off"
    detail: str = ""                     # e.g. "controller error 19: End Effector
                                         #   Communication Error" (the SDK's title for C19;
                                         #   xArm Studio calls it "End Module Communication
                                         #   Error")
    seq: int = 0; age_s: float | None = None
    q: list[float] = []                  # 7 joint angles, rad, controller order = IDENTITY
                                         #   onto the twin's <arm>_joint1..7 (no pi offset;
                                         #   verified 2026-09-04)
    tcp_pose: list[float] = []           # controller flange pose [x,y,z m, roll,pitch,yaw
                                         #   rad] in the arm base frame (tcp_offset zero)
    rail_present: bool | None = None     # linear-track registers readable
    rail_homed: bool | None = None       # on_zero == 1
    rail_enabled: bool | None = None
    rail_pos_m: float | None = None      # None unless homed AND enabled (the register is
                                         #   meaningless otherwise)
    rail_raw_mm: float | None = None     # raw register, always reported when present
    gripper_open_frac: float | None = None     # 0 closed .. 1 open; None for gripper "none"
    gripper_raw: float | None = None     # raw SDK reading for diagnosis
    error_code: int = 0; warn_code: int = 0    # controller codes (19 = End Effector Comm Error)
    state: int | None = None             # controller state (4 = stopped / not enabled)
    mode: int | None = None
    # phase-09b read-back (slow poll) + maintenance flag — all additive
    collision_sensitivity: int | None = None   # controller's CURRENT value 0..5 (unbounded
                                         #   here: it is what the box reports)
    tcp_load_kg: float | None = None     # controller's CURRENT tcp_load mass
    tcp_load_cog_mm: list[float] = []    #   ... and centre of gravity [x, y, z] mm
    backstops_match: bool | None = None  # runtime: read-back == ArmConfig (sensitivity equal,
                                         #   |Δ load| <= 0.05 kg, |Δ cog| <= 10 mm); None = not
                                         #   compared yet
    maintenance_busy: bool = False       # a maintenance op (§12) is executing on this arm
                                         #   (true for a RailHomingJob's whole life)
    maintenance: MaintenanceProgress | None = None
                                         # phase-09d: live progress of the asynchronous
                                         #   RailHomingJob on this arm; None = no job
                                         #   (additive - every pre-09d row still parses)

TwinOverlayStatus = Literal["off", "waiting", "live", "stale", "error"]
    # off = overlay disabled / twin scene failed to build; waiting = nothing published (no
    # real camera frame yet, NO monitor sample for this arm yet — box off / connecting: the
    # twin is never drawn at an unmeasured keyframe posture — or a hardware session owns the
    # boxes, monitor paused); live = compositing at ~cfg.fps; stale = this arm HAS a sample
    # but its monitor is not running (sample aged out / error / connecting / paused; twin
    # drawn from that last sample in the stale tint); error = render / composite failure

class TwinOverlayTelemetry(BaseModel):   # one "<camera_id>_align" stream (04-runtime §13.4)
    stream_id: str                       # grip_wrist_align / view_wrist_align
    camera_id: str                       # grip_wrist / view_wrist (the real frame underneath)
    arm_id: str
    status: TwinOverlayStatus = "off"
    detail: str = ""                     # e.g. "rail not homed - twin assumes 0.65 m"
    fps: float = 0.0                     # measured publish rate (1 s window)
    rail_fallback_m: float | None = None # set while the track is not homed and the twin
                                         #   assumes the configured position instead
    joint1_offset_rad: float = 0.0       # diagnostic knob echo (0 = the verified identity)
    mask_fraction: float = 0.0           # robot pixels / image pixels of the last frame

class HardwareMonitorTelemetry(BaseModel):   # additive block (phase-09a; 04-runtime §13.3);
    enabled: bool = False                #   EVERY field defaults (no-hardware producers
    paused: bool = False                 #   validate); paused = a hardware session owns the
    arms: list[ArmMonitorTelemetry] = [] #   boxes (monitor connections released)
    overlays: list[TwinOverlayTelemetry] = []

class TelemetryMsg(BaseModel):
    t: Literal["telemetry"] = "telemetry"
    seq: int; ts: float; epoch: str      # ts = server monotonic, s
    active_arm: str | None               # server-authoritative (Tab cycles it)
    controller_connected: bool
    arms: list[ArmTelemetry]
    collision: CollisionReport           # §6 model
    clearances: list[ClearanceItem]      # top-5 monitored pairs, measured config
    episode: EpisodeStatus | None        # None in teleop/inference
    dagger: DaggerStatus | None          # None outside DAgger
    inference: InferenceStatus | None    # None outside inference
    session: SessionTelemetry | None = None     # additive
    tracker: TrackerTelemetry | None = None     # additive (13-tracker §3.5)
    microphone: MicrophoneTelemetry | None = None   # additive (phase-11); the UI
                                                #   de-duplicates frames on ``seq``
    hardware_monitor: HardwareMonitorTelemetry | None = None
                                                # additive (phase-09a); session-less like
                                                #   tracker / microphone
    datasets: DatasetsTelemetry | None = None   # additive (2026-09-07); the export job's
                                                #   progress (§11 DatasetsTelemetry)
```

**Hardware monitor / twin overlay (`protocol/hardware_monitor.py`; phase-09a,
`docs/prompts/phase-09a-hardware-twin-overlay.md`).** While no hardware session
owns the control boxes the runtime polls both xArm7 controllers *read-only*
(joints, flange pose, linear-track and gripper registers, error/warn codes)
and renders the `mavis_v2` digital twin from each wrist camera's viewpoint as
a tinted overlay on the real frame — the `<camera_id>_align` streams
(`grip_wrist_align`, `view_wrist_align`), listed in `/api/cameras` with
`CameraInfo.kind == "twin"` (§12). The block rides
`TelemetryMsg.hardware_monitor` next to `tracker` / `microphone`; a hardware
session *pauses* the monitor (connections released — one box is never shared
between two SDK clients) rather than stopping it, and the Welcome page's arm
cards take their `error_code` from it. The module is a dependency-free leaf
(pure pydantic) imported by `telemetry.py` and `maintenance.py`; its models
(the three phase-09a blocks plus, since phase-09d, `MaintenanceProgress` and
the `ArmMaintenanceOp` / `MaintenancePhase` vocabularies, kept in the leaf so
`maintenance.py` and `hardware_monitor.py` never import each other) ride
`TelemetryMsg`'s `$defs` and none exports top-level (§14). Polling, reconnect
backoff, the rail fallback and the compositing recipe are hardware / runtime
territory (02-hardware "read-only monitor", 04-runtime §13.3 / §13.4); core
only fixes the spellings.

**Phase-09b (`docs/prompts/phase-09b-error-recovery.md`).** The monitor's
zero-write guarantee becomes *"zero writes unless an explicit maintenance
request"* (§12): its polling thread also executes the operator-triggered
`clear_errors` / `apply_backstops` ops and, every slow poll, reads back the
controller-side safety parameters (`collision_sensitivity`, `tcp_load_kg`,
`tcp_load_cog_mm`) so the Hardware tab can flag a box whose volatile settings
differ from `ArmConfig` (`backstops_match == false`; `maintenance_busy` while
an op runs). Inside a hardware session the driver's fault / recovered / reseed
events (`WorkcellInterface.drain_events`, §5.1) drive `ArmTelemetry.fault_detail`
/ `.recovering` and `SessionTelemetry.state` `fault` → `recovering` →
`running` (04-runtime §15); the faulted arm stops streaming, its siblings keep
going. The driver's own bounded auto-recovery (02-hardware §3.5: ≤ 3 per 30 s
for RECOVERABLE codes) still runs; beyond it (LATCHED after the budget, an
unrecoverable code, the e-stop) only the operator's `recover` click recovers,
and motion never resumes before the operator releases every input / re-grips
the clutch.

**Phase-09c (`docs/prompts/phase-09c-hardware-session.md`, D5).** A hardware
session's bring-up is observable: `GET /api/session` already answers `state:
bringup` while the drivers connect, and `SessionTelemetry.bringup` carries one
`ArmBringupTelemetry` row per arm / step (`status_cb` of the hardware workcell
plus the runtime's own rows — in 09c e.g. the then-unselected arm "frozen at
last sample"; since 09d every arm connects and that row is not produced);
the Cockpit lists them until `running`. `SessionInfo.kind` / `.speed_scale`
(§12) echo what the session drives and how fast.

**Phase-09d (`docs/prompts/phase-09d-rail-homing-planning.md`).** Rail homing
may now be preceded by a twin-planned pre-positioning motion, executed as an
asynchronous per-arm `RailHomingJob`; its live phase rides
`ArmMonitorTelemetry.maintenance` (`MaintenanceProgress`, above) so the UI's
Home-rail sheet lists queued → sweeping → planning → connecting → positioning
→ homing → verifying → done / failed as they happen, with `maintenance_busy`
true throughout and the monitor `paused` while the job's driver owns the box
(the other arm reports "frozen at last sample"). The `job_id` ties the rows to
the `202` response and to the final `ArmMaintenanceResult` at
`GET .../maintenance/last` (§12). A hardware session always includes BOTH arms
since 09d (`SessionSpec.arms` must equal every configured arm — runtime 409
otherwise; the model is unchanged).

## 12. Protocol: session & REST models (`protocol/session.py`, `protocol/tracker.py`, `protocol/microphone.py`, `protocol/maintenance.py`)

Bodies for the `/api` surface (04-runtime §13.1); runtime defines no wire
model of its own. Session models live in `protocol/session.py`; the phase-10
tracker-calibration models in `protocol/tracker.py`, the phase-11
microphone row + `MicStatus` vocabulary in `protocol/microphone.py` and the
phase-09b/09c/09d arm-maintenance request / result / plan models in
`protocol/maintenance.py` (all below).

```python
Mode = Literal["teleop", "collect", "dagger", "inference"]
START_FROM_RE = r"^(keep_current|profile:[A-Za-z0-9_\-]+)$"
DATASET_RE = r"^(?:[A-Za-z0-9][A-Za-z0-9_\-]*/)?[A-Za-z0-9][A-Za-z0-9_\-]*$"   # <ns>/<name> | <name>
SLUG_RE = r"^[A-Za-z0-9][A-Za-z0-9_\-]*$"     # 2026-09-08 (15-online-dagger §5): one bare slug — the name
                                         #   half of DATASET_RE; an Online DAgger session name is a
                                         #   directory under the online_dagger root, so the UI slugs
                                         #   against it too (it rides the schema `pattern`)

class OnlineDaggerConfig(BaseModel):     # SessionSpec.online_dagger (phase-14, 2026-09-08 evening;
    model_config = ConfigDict(extra="forbid")   #   15-online-dagger §5). An unknown key is a 422, never
                                         #   silent — a hyper-parameter typed here by mistake would
                                         #   otherwise vanish (the runtime forwards NONE; the trainer
                                         #   configures itself)
    session_name: str = Field(pattern=SLUG_RE, max_length=64)      # ~/data/online_dagger/<session_name>/
    resume: bool = False                 # an existing session dir: continue it (else 409 "already exists")
    pause_while_training: bool = True    # refuse episode_new while the trainer reports `training` (D2)
    wait_for_trainer_ready: bool = True  # refuse episode_new until the trainer has reported `ready`
                                         #   once for THIS session (D2)
# Superseded (2026-09-08 evening): the morning's ProDaggerConfig (offline_dataset, rollouts_per_
# iteration, train_mode, n_epochs, steps_*, lr, batch_size, replay_buffer, max_demos, use_pgrad,
# gref_ema_beta, max_ref_batches, grad_clip, freeze_offline_gref, offline_stride, chunk_stride,
# chunk_horizon, seed, require_ref_grad) — every algorithm setting belongs to the trainer node
# (operator decision 2026-09-08 §0 item 2; the PRO-DAgger reference implementation keeps its OWN
# `ProDaggerConfig` in mavis_policy_node/pro_dagger/config.py, fed by --trainer-config). Deleted.

class SessionSpec(BaseModel):            # POST /api/session body
    mode: Mode
    kind: Literal["hardware", "sim"]     # honored iff config available (binding; else 409)
    arms: list[str]                      # participating arm ids
    frames: dict[str, FrameRef]          # per-arm RECORDING frame (arm_base:<id> | world |
                                         #   camera:<id>); never affects control math
    sim_scene: str | None = None         # required when kind == "sim"
    digital_twin_scene: str | None = None      # required when kind == "hardware"
    start_from: str = "keep_current"     # START_FROM_RE: keep arms where they are, or
                                         #   twin-PLANNED safe motion to profile:<id>
    task: str | None = None              # dataset task string (collect/dagger: required)
    policy: str | None = None            # checkpoint id (dagger/inference); None = latest
                                         #   (dagger) / promoted deploy ckpt (inference;
                                         #   409 if none promoted — 12-dagger §9)
    speed_scale: float = Field(1.0, gt=0, le=1)
                                         # phase-09c (D2): multiplies the host-side
                                         #   teleop.linear_mps/angular_rps/rail_mps,
                                         #   target_rate.v_mps/w_radps, dq_max_rad,
                                         #   jog.slew_rad_per_tick/rail_m_per_tick AND the
                                         #   driver-side servo.max_joint_vel /
                                         #   max_cart_step_m / rail_speed_mm_s; 0 and > 1
                                         #   are 422. Hardware tab offers 10 / 50 / 100 %,
                                         #   default 1.0 (`hardware_session.default_speed_scale`;
                                         #   operator's call 2026-09-08 evening — 0.5 from
                                         #   2026-09-07, 10 / 30 / 100 % default 0.1 before);
                                         #   additive (runtime applies it when
                                         #   building the session's control config, 04-runtime
                                         #   §5; pre-09c bodies parse at 1.0)
    dataset: str | None = None           # collect only (2026-09-07; 04-runtime §10.5):
                                         #   repo id to record into — DATASET_RE
                                         #   ^(?:[A-Za-z0-9][A-Za-z0-9_\-]*/)?[A-Za-z0-9][A-Za-z0-9_\-]*$,
                                         #   a bare name is prefixed "apollo/"; None = the
                                         #   task-derived phase-07 grammar (10-frames §8.1);
                                         #   set on a non-collect mode → validation error
    dataset_resume: bool = False         # False = must NOT exist yet; True = must exist
                                         #   and match (fps / robot_type / features) — 409
    action_filter: ActionFilterConfig = ActionFilterConfig()
                                         # collect / dagger (2026-09-07; 04-runtime §10.5): skip
                                         #   idle / small-motion frames at record time; the
                                         #   pro-dagger heuristic and defaults (enabled True,
                                         #   pos_eps_m 0.001, rot_eps_rad 0.001, gripper_eps_frac
                                         #   0.01, rail_eps_m 0.001, gripper_context_s 1.6)
    return_to_start: bool = True         # collect only (DEFAULT ON, operator 2026-09-07; a
                                         #   NON-default value on a non-collect mode is a
                                         #   validation error, the default is inert there):
                                         #   twin-planned, gated, cancellable return to the
                                         #   start_from / initial-condition profile after
                                         #   every save / discard (04-runtime §10.5); 409 at
                                         #   POST when no such profile exists and it is on.
                                         #   Superseded (2026-09-08, 15-online-dagger D6): collect
                                         #   OR dagger — "return_to_start is a collect /
                                         #   dagger-mode field" elsewhere
    policy_source: Literal["checkpoint", "external"] = "checkpoint"
                                         # additive (phase-12, 14-dora §6.1; sits right after
                                         #   speed_scale in the model): external = the policy
                                         #   drives through the dora bus; dagger / inference only,
                                         #   policy must be None
    online_dagger: OnlineDaggerConfig | None = None
                                         # additive (phase-14, 2026-09-08 evening; 15-online-dagger
                                         #   §5): non-null = an Online DAgger session against an
                                         #   external trainer node. Rules (evaluated BEFORE the
                                         #   dataset rule, in order): "online_dagger requires mode
                                         #   dagger", "online_dagger requires policy_source
                                         #   'external'", "online_dagger derives the rollouts
                                         #   dataset - leave dataset unset" (the repo id is
                                         #   online_dagger/<session_name>, resumed iff .resume).
                                         #   Superseded: the morning's pro_dagger field

class ActionFilterConfig(BaseModel):     # idle-frame filter parameters (10-frames §11.4)
    enabled: bool = True
    pos_eps_m: float = Field(0.001, ge=0)        # Chebyshev over the commanded TCP xyz, vs LAST KEPT frame
    rot_eps_rad: float = Field(0.001, ge=0)      # geodesic angle of the commanded TCP orientation
    gripper_eps_frac: float = Field(0.01, ge=0)  # open fraction (≈ 1 mm of the G2's 86 mm stroke)
    rail_eps_m: float = Field(0.001, ge=0)
    gripper_context_s: float = Field(1.6, ge=0)  # keep idle frames within ± this of a gripper change

class DatasetInfo(BaseModel):            # GET /api/datasets row (2026-09-07; 04-runtime §10.6)
    repo_id: str; root: str              # "<ns>/<name>", absolute directory
    layout: Literal["episode_dirs", "lerobot_v3"] = "episode_dirs"
                                         #   lerobot_v3 = a legacy phase-07 tree, read-only
    total_episodes: int; total_frames: int; fps: int
    robot_type: str | None = None; kind: Literal["hardware", "sim"] | None = None
    task: str | None = None; cameras: list[str] = []; arms: list[str] = []
    modified_at: str                     # ISO-8601 UTC
    in_use: bool = False                 # the running session records into it
    export: DatasetExportInfo | None = None
    namespace: str = ""                  # additive (2026-09-08; 15-online-dagger D5): the <ns> half
    path: str = ""                       #   of repo_id / the folder the operator sees (== root);
                                         #   "" on an older runtime

class DatasetNamespaceInfo(BaseModel):   # DatasetLayoutInfo.namespaces[ns] (2026-09-08; 15-online-dagger §7)
    root: str                            # absolute directory the namespace's datasets live under
    subdir: str | None = None            # per-dataset sub-folder holding the dataset (online_dagger: "rollouts")

class DatasetLayoutInfo(BaseModel):      # GET /api/datasets/layout (2026-09-08; 04-runtime §13.1)
    default_namespace: str               # a bare `dataset: "<name>"` resolves here (bc_demo on the lab)
    generic_root: str                    # datasets_root: <generic_root>/<ns>/<name> for unmapped namespaces
    namespaces: dict[str, DatasetNamespaceInfo]

class OnlineDaggerSessionInfo(BaseModel): # GET /api/online_dagger/sessions row (2026-09-08 evening;
    session_name: str; path: str         #   15-online-dagger §3/§5); absolute session directory
                                         #   (~/data/online_dagger/<session_name>)
    created_at: str                      # ISO-8601 UTC
    task: str | None
    rollouts: int                        # kept rollouts of the session (session.json current.rollouts_saved)
    last_used_at: str | None = None      # ISO-8601 UTC of the last session that ran it
# Superseded (2026-09-08 evening): the morning's ProDaggerSessionInfo (offline_dataset, iteration,
# ref_grad_ready) — the shell knows no anchor, iteration or reference gradient. Deleted.

class DatasetExportInfo(BaseModel):      # manifest.last_export (10-frames §11.5)
    state: Literal["none", "stale", "fresh", "running", "failed"]
    format: str = "lerobot_v3"; path: str | None = None
    at: str | None = None; episodes: int = 0; detail: str = ""

class EpisodeInfo(BaseModel):            # GET /api/datasets/{ns}/{name}/episodes row
    episode_id: str                      # directory name (10-frames §11.3); the API key
    index: int                           # position in capture order (UI label only)
    frames: int; duration_s: float
    task: str | None = None; session_id: str | None = None
    recorded_at: str | None = None       # ISO-8601 UTC
    frames_dropped: int = 0; audio: bool = False
    export_ok: bool = True; export_note: str | None = None
    open: bool = False                   # currently being recorded (delete → 409)

class DatasetExportRequest(BaseModel):   # POST /api/datasets/{ns}/{name}/export body
    format: Literal["lerobot_v3"] = "lerobot_v3"
    out: str | None = None               # None = <root>/exports/lerobot_v3

class SessionInfo(BaseModel):            # POST/GET /api/session response
    session_id: str; epoch: str; mode: Mode; arms: list[str]
    streams: list[str]                   # video ids: camera ids + "sim" and/or "twin"
    state: str                           # SessionState value
    kind: Literal["hardware", "sim"] = "sim"
                                         # which workcell the session drives; defaults to
                                         #   "sim" because every pre-09c session was one
                                         #   (hardware was 409) — the UI no longer infers
                                         #   it from hardware_monitor.paused; additive,
                                         #   phase-09c
    speed_scale: float = Field(1.0, gt=0, le=1)   # echo of SessionSpec.speed_scale
                                         #   (additive, phase-09c; the Cockpit header shows it)
    policy_source: Literal["checkpoint", "external"] = "checkpoint"   # additive (phase-12): echo
    fault_detail: str = ""               # additive (2026-09-08 evening; 04-runtime §13.3): the same
                                         #   session-level notice as SessionTelemetry.fault_detail (a
                                         #   refused / unplannable start_from, a Go to profile / R
                                         #   return that did not arrive); "" = nothing to say
    online_dagger: OnlineDaggerConfig | None = None   # additive (phase-14, 2026-09-08 evening): echo
                                         #   of SessionSpec.online_dagger (the operator's raw body);
                                         #   None for every other session; LAST. SessionInfo echoes
                                         #   neither dataset nor return_to_start (they ride
                                         #   telemetry.episode / session). Superseded: the
                                         #   morning's pro_dagger echo

class ArmStatusInfo(BaseModel):          # landing-page card
    arm_id: str; ip: str | None
    connected: bool                      # "a session exists" (unchanged semantics)
    reachable: Literal["open", "refused", "unreachable", "unknown"] = "unknown"
                                         # hardware probe, TCP 502 connect-and-close
                                         #   (never writes): open = box up; refused =
                                         #   box booting; unreachable = no route /
                                         #   timeout; unknown = not probed (sim);
                                         #   additive, phase-11
    has_rail: bool
    gripper: Literal["xarm", "xarm_g2", "none"]; gripper_force_capable: bool
    error_code: int
    joint_limits: list[tuple[float, float]]  # 7 rad pairs; + [0.0, 0.65] m appended for
                                             #   rail arms (joint-panel slider ranges)

class CameraInfo(BaseModel):
    camera_id: str
    kind: Literal["v4l2", "realsense", "sim", "twin"]
                                         # twin = digital-twin overlay stream
                                         #   "<camera_id>_align" (phase-09a, §11): the twin
                                         #   rendered from the real wrist camera's viewpoint,
                                         #   tinted over the real frame; additive
    label: str
    resolution: tuple[int, int]; fps: int
    live: bool                           # pre-session preview available (~15 fps); a twin
                                         #   row is live iff the real camera is live AND the
                                         #   overlay status is live / stale

class WorkcellStatus(BaseModel):         # GET /api/workcell[?kind=hardware|sim]
    kind: Literal["hardware", "sim"]
    available_kinds: list[Literal["hardware", "sim"]]
    arms: list[ArmStatusInfo]; cameras: list[CameraInfo]
    policies_available: bool = False     # enables DAgger/Inference launch (05-ui §8.1)
    hardware_ready: bool = False         # every configured hardware arm reachable ==
                                         #   "open"; gates the Hardware-tab mode
                                         #   launchers (05-ui §8.1); additive, phase-11
    policy_modes: bool = False           # 2026-09-12, additive: hardware = the RENDERED
                                         #   config's hardware_session.policy_modes
                                         #   (inference / dagger sessions + action-column
                                         #   playback admitted on the real arms); always
                                         #   true for sim. Opens the Hardware-tab DAgger /
                                         #   Inference cards (05-ui §8.1); an older
                                         #   runtime omits it = refused

class SceneInfo(BaseModel):              # GET /api/scenes?kind=sim|twin
    scene_id: str; label: str; num_arms: int
    rail_flags: list[bool]; cameras: list[str]
    kind: Literal["sim", "twin"]

class ProfileInfo(BaseModel):            # GET /api/profiles rows (full posture via
    profile_id: str; name: str           #   GET /api/profiles/{id} -> StateProfile)
    arms: list[str]; notes: str; created_at: str
    is_initial_condition: bool
    workcell_kind: Literal["hardware", "sim"] = "sim"
                                         # additive (2026-09-07): lets the Welcome page gate
                                         #   return_to_start per tab kind (05-ui §8.1 item 6)

class PolicyInfo(BaseModel):             # GET /api/policies rows (04-runtime §13.1)
    policy_id: str                       # "{run_id}/v{n:06d}" | "{run_id}/deploy/v{k:03d}"
    path: str
    action_space: Literal["delta_ee", "abs_ee", "joint"]
    action_frame: str                    # FrameRef: "arm_base:<id>" | "world" | "camera:<id>"
    policy_version: int
    promoted: bool = False               # deploy checkpoints only (12-dagger §9);
                                         #   inference sessions load only promoted ones
```

`SessionSpec` validators: `start_from` matches the regex; `frames` keys ⊆
`arms`; each value `parse_frame()`s and is not `ee:`; collect/dagger ⇒ `task`;
`speed_scale` ∈ (0, 1] (pydantic `Field` bounds → 422). The hardware-session
refusal matrix (rail not homed, no monitor sample, rail homing job in
progress, `arms` ≠ every configured hardware arm — since phase-09d both arms
are ALWAYS in a hardware session, the 09c subset switch is gone —, error
latched, box unreachable, teleop-only, `start_from=profile:<id>` not
collision-free in the twin) is runtime territory (04-runtime §13.1); core only
fixes the spellings.

**Tracker calibration (`protocol/tracker.py`; phase-10, 13-tracker §3/§4).**
Two calibrations share one REST endpoint — `GET /api/tracker/calibration ->
TrackerCalibrationStatus`, `POST /api/tracker/calibration
(TrackerCalibrationCommand) -> TrackerCalibrationStatus`; illegal transitions
are 409 `{detail}` — and the same status object rides
`TrackerTelemetry.calibration` (§11). `PoseMsg` is imported from
`protocol/telemetry.py`; `telemetry.py` in turn imports
`TrackerCalibrationStatus` right after `PoseMsg` is defined (the package
`__init__` loads `telemetry` before `tracker`). Session-less REST for device
management is a binding addition to 04-runtime §13.1 ("REST = management
CRUD").

```python
CalibrationKind  = Literal["none", "base_station", "yaw"]
CalibrationPhase = Literal["idle", "starting", "capturing", "validating", "fitting",
                           "installing", "done", "failed", "aborted"]
CalibrationOp    = Literal["start", "capture", "validate", "install", "apply", "abort"]
YawPointLabel    = Literal["start", "left", "forward", "right", "back", "up", "down"]

class LighthouseStatus(BaseModel):       # one base station during base_station capture
    index: int                           # libsurvive LH index
    channel: int | None = None           # OOTX channel; None until reported
    serial: str | None = None
    pose: PoseMsg | None = None          # lighthouse-world pose (m, wxyz)
    scenes: int = 0                      # GSS scenes solved for this station
    reference: bool = False              # "Using LH i as reference lighthouse"

class CalibrationValidation(BaseModel):  # stationary-controller check (13-tracker §4)
    samples: int = 0
    std_mm: tuple[float, float, float] = (0.0, 0.0, 0.0)   # per-axis position std
    max_step_mm: float = 0.0             # largest jump between adjacent samples
    threshold_std_mm: float = 5.0        # acceptance: all(std) < 5 mm and
    threshold_step_mm: float = 20.0      #   max_step < 20 mm (2026-09-03 measurements)
    passed: bool = False

class YawGesturePoint(BaseModel):
    label: YawPointLabel
    pose: PoseMsg                        # RAW lighthouse-world pose at the click

class TrackerCalibrationStatus(BaseModel):   # GET response; TrackerTelemetry.calibration
    kind: CalibrationKind = "none"       # every field defaults: {} = idle snapshot
    phase: CalibrationPhase = "idle"
    detail: str = ""                     # operator-facing progress / failure reason
    started_at: float | None = None      # unix s
    elapsed_s: float | None = None
    # base-station
    scenes: int = 0                      # max over stations
    lighthouses: list[LighthouseStatus] = []
    stations_visible: int = 0
    controller_still: bool | None = None # None = no fresh samples
    validation: CalibrationValidation | None = None
    installed_path: str | None = None    # libsurvive config replaced on install
    backup_path: str | None = None       # <installed_path>.bak-YYYYMMDD-HHMMSS
    # yaw
    yaw_points: list[YawGesturePoint] = []
    next_point: YawPointLabel | None = None     # None once all seven are captured
    fitted_yaw_deg: float | None = None
    fit_residual_deg: float | None = None
    fit_checks: list[str] = []           # failed checks; empty = ok (apply allowed)
    applied_yaw_deg: float | None = None
    # persisted calibration state (always filled from tracker_calibration.json)
    yaw_valid: bool = True               # False after a base-station install until yaw redone
    yaw_calibrated_at: float | None = None
    base_station_installed_at: float | None = None

class TrackerCalibrationCommand(BaseModel):  # POST body
    kind: Literal["base_station", "yaw"] # "none" is a status kind only
    op: CalibrationOp
    point: YawPointLabel | None = None   # yaw 'capture' label; None = next_point
```

State machines, INFO-line parsing, file layout and the yaw fit are runtime
territory (04-runtime §6, 13-tracker §4); core only fixes the spellings above.

**Microphone (`protocol/microphone.py`; phase-11, 05-ui §8.1).** The RØDE
NT-USB Mini on the view arm is a session-less device like the tracker:
`GET /api/microphones -> list[MicrophoneInfo]` always lists every configured
microphone (`live: false` when absent), and the same `MicStatus` vocabulary
rides `TelemetryMsg.microphone` (§11) so REST snapshot and telemetry never
disagree on spelling. The module is a dependency-free leaf (pure pydantic);
`telemetry.py` imports `MicStatus` from it, nothing imports `telemetry` back.

```python
MicStatus = Literal["no_backend", "starting", "absent", "live", "stalled", "error"]
    # no_backend = disabled / no capture backend; starting = opening the source;
    # absent = configured but unplugged; live = frames within stale_s;
    # stalled = present, no frame for > stale_s; error = open/read failure
    #   (runtime retries with backoff)

class MicrophoneInfo(BaseModel):         # GET /api/microphones row
    mic_id: str                          # e.g. "mic_view"
    label: str                           # operator-facing name
    kind: Literal["pulse", "fake", "none"]     # capture route in use (ALSA hw: is
                                               #   never used — PulseAudio owns the card)
    source: str | None                   # PulseAudio source name; None = unresolved /
                                         #   fake / none
    sample_rate: int                     # Hz (48000 for the NT-USB Mini)
    channels: int = 1
    live: bool                           # status == "live" (waveform preview available)
    status: MicStatus
    detail: str = ""                     # reason for absent/error/no_backend
```

Capture backends, source resolution, envelope binning and stall detection are
runtime territory (04-runtime §13.1/§13.3/§14); core only fixes the spellings.

**Arm maintenance (`protocol/maintenance.py`; phase-09b,
`docs/prompts/phase-09b-error-recovery.md`; phase-09c
`docs/prompts/phase-09c-hardware-session.md`; phase-09d
`docs/prompts/phase-09d-rail-homing-planning.md`).** `POST
/api/hardware/arms/{arm_id}/maintenance (ArmMaintenanceRequest) ->
ArmMaintenanceResult` lets the operator clear xArm controller errors,
(re)apply the controller-side safety parameters (§7) and home the linear
track from the UI. Three of the four ops produce **no motion** — measured
2026-09-04 on the Perception Arm: `clean_error` cleared C19 and moved no joint
by more than 5e-5 rad; the full recovery sequence (`clean_error → clean_warn →
motion_enable(True) → set_mode → set_state(0)`) only puts the arm in ready /
servo state — C19 did not recur for 6 s after the clear; `motion_enable(True)`
releases the brakes so the motors hold the posture actively, and motion comes
only from explicit motion commands. **`home_rail` is the ONE motion op: operator-triggered,
twin-gated, session-less** (phase-09c, user rule 1 — no implicit motion; the
driver's connect never homes). The carriage drives to the homing end (the
operator's LEFT, +X) at the track's own homing speed (no SDK setter; the
positioning cap `rail_speed_mm_s` is written after homing), so before a single write the
runtime sweeps a dedicated digital twin over the full 0–0.65 m travel at the
arm's CURRENT 7-joint posture, the other arm posed at its last monitor sample,
and refuses unless every step is clear (D4: `inflation 0.025 m`, `step 0.005 m`
→ 131 positions). `dry_run: true` returns that verdict alone (zero writes) so
the UI's `HomeRailSheet` can show it before the destructive confirm; the real
op re-samples on the monitor thread and refuses if the joints moved
(`q_checked`) or an error is latched, then judges success from the track
registers only (`on_zero == 1`, `is_enabled == 1`, `error == 0`). A hardware
session is refused while any arm's rail is unhomed (since phase-09d every
configured arm is in the session; position unknown → the gate twin cannot be
posed), so this op is how the operator makes a session possible. 404 = unknown arm; 409 = the op is not available on the
current path (below), the monitor is off / paused / not connected, or (for
`home_rail`) a hardware session exists ("end the session first") / the sweep
cannot run (no monitor sample, no track on the arm, a controller error latched
— "clear errors first", no twin scene); otherwise 200 with the result whether
or not `ok` — a BLOCKED sweep is `ok=False` with the verdict and empty
`sdk_codes` (zero writes). The REST handler blocks up to 45 s for a
synchronous `home_rail` (D3); the UI gives that POST a 60 s client deadline.

*Planning before homing (phase-09d).* A posture that is not sweep-clear is no
longer a flat refusal. The runtime tries candidate postures in order — the
scene keyframe's 7 joints for the arm, then the `<arm>_home` keyframe
(`"search"`, a sampled posture around a candidate, is reserved) — and keeps
the first that is sweep-clear over the full travel AND reachable by a twin
RRT-Connect plan (`DigitalTwin.plan`) from the current posture whose EVERY
waypoint is collision-free for EVERY one of the 131 rail positions (the
carriage is unknown, so the path must be position-agnostic; that check is the
ONLY safety basis of the motion — a gate-twin "pass" never replaces it). The
outcome rides `RailSweepVerdict.pre_position` (`PrePositionPlan`): `needed ==
False` → the 09c synchronous path (joints untouched, 200); `needed and clear`
→ on the operator's confirm the op starts an asynchronous per-arm
`RailHomingJob` and answers **202** with `status: "accepted"` + `job_id`
(nothing written yet); `needed and not clear` → `status: "refused"`,
`ok=False`, an operator suggestion in `detail` (e.g. fold the arm toward the
factory-zero posture in Studio and retry). The job connects that arm's driver
alone (rail still unhomed, `speed_scale` 0.1, the other arm frozen at its last
sample — 09c D1 now serves maintenance motion only), executes the planned path
under the gate (`ControlLoop._op_execute_plan`), homes the rail with the joints
held, verifies the registers, tears the driver down (state 4 + brakes → the
folded posture is HELD; no automatic return) and resumes the monitor; its
phases ride `ArmMonitorTelemetry.maintenance` (§11) and its final result — an
`ArmMaintenanceResult` with `status: "done"` and the same `job_id` — is
`GET /api/hardware/arms/{arm_id}/maintenance/last -> ArmMaintenanceResult |
404`. While a job runs `POST /api/session` and every other maintenance op are
409 "rail homing in progress". `dry_run` returns the verdict with
`pre_position` filled (zero writes) so the sheet can announce the motion
before the destructive confirm.

The module is pure pydantic; the request and result export top-level (§14)
while `RailSweepVerdict`, `PrePositionPlan` and (via the embedded monitor row)
`MaintenanceProgress` ride the result's `$defs`. `ArmMaintenanceOp`,
`MaintenancePhase` and `MaintenanceProgress` are *defined* in
`protocol/hardware_monitor.py` (the dependency-free leaf, §11) and re-exported
here: the progress block rides `ArmMonitorTelemetry.maintenance` while this
module embeds `ArmMonitorTelemetry` in the result, so defining them here would
make the two modules import each other. Import them from either module.

```python
ArmMaintenanceOp = Literal["clear_errors", "apply_backstops", "recover", "home_rail",
                           "set_collision_sensitivity"]           # 2026-09-11
    # (defined in protocol/hardware_monitor.py, re-exported here - §11)
    # clear_errors:    no session: clean_error + clean_warn, NEVER motion_enable — on the
    #                  read-only monitor's polling thread (its zero-write guarantee becomes
    #                  "zero writes unless an explicit maintenance request"); INSIDE a hardware
    #                  session the runtime routes it to the driver's user-initiated recovery
    #                  (= recover below, which DOES enable) — 04-runtime §13.1
    # apply_backstops: backstops.apply_backstops(api, cfg) from ArmConfig (§7 order) — no
    #                  session; 409 inside a hardware session (the driver re-applies the
    #                  volatile settings at connect anyway)
    # recover:         the driver's full user-initiated recovery + reseed from the MEASURED
    #                  position — hardware session only; 409 without one ("no hardware
    #                  session - use clear_errors"); the operator re-grips the clutch after
    # home_rail:       set_linear_track_back_origin(wait, auto_enable=False) ->
    #                  set_linear_track_enable(True) -> set_linear_track_speed on the monitor
    #                  thread (never motion_enable) — no session; 409 inside a hardware
    #                  session ("end the session first"); twin-gated (RailSweepVerdict);
    #                  the ONE op that moves a mechanical part (phase-09c); since phase-09d
    #                  it may first run a planned pre-positioning motion as an asynchronous
    #                  RailHomingJob (status "accepted", 202)
    # set_collision_sensitivity: the operator's collision-sensitivity override (operator
    #                  decision 2026-09-11) - ONE write, set_collision_sensitivity(level) with
    #                  level = the body's collision_sensitivity, 1 / 2 / 3 ONLY (0 = off, 4 / 5
    #                  false-trigger under payload: 422 at the wire); NO motion. The one op
    #                  that runs on BOTH paths: session-less on the read-only monitor's poll
    #                  thread (the Hardware-tab arm card, judged from the rich-frame
    #                  read-back) and inside a hardware session on the session driver's
    #                  monitor thread (the Cockpit control; before/after None - the real
    #                  30003 stream has no read-back). VOLATILE: the controller default is the
    #                  config value 3, re-applied at EVERY connect, so the override lasts
    #                  until the next connect; the UI shows the controller's read-back, never
    #                  the value it asked for (02-hardware §6 / §8.6, 05-ui §8.1 / §8.2,
    #                  11-safety §11)
MaintenancePath = Literal["monitor", "session"]   # which thread executed the op (the
                                                  #   RailHomingJob drives the arm through
                                                  #   its own driver connection; no "job"
                                                  #   value - runtime picks the spelling)
MaintenanceStatus = Literal["done", "accepted", "refused"]   # phase-09d, how the op ran
    # done:     ran to completion synchronously (ok says whether it succeeded; dry-run
    #           verdicts are "done" too) - 200
    # accepted: an asynchronous RailHomingJob was started (the posture needs a planned
    #           pre-positioning motion first) - 202, job_id set, progress on
    #           ArmMonitorTelemetry.maintenance (§11), final result at GET .../maintenance/last
    # refused:  nothing ran, nothing written (the sweep is blocked and no rail-safe plan was
    #           found) - ok False, an operator suggestion in detail

class ArmMaintenanceRequest(BaseModel):  # POST body
    op: ArmMaintenanceOp
    dry_run: bool = False                # home_rail only: sweep verdict alone, zero writes
                                         #   (additive, phase-09c)
    collision_sensitivity: int | None = Field(None, ge=1, le=3)
                                         # set_collision_sensitivity only: the level to write
                                         #   (additive, 2026-09-11); the bound is in the JSON
                                         #   Schema, and an after-validator makes it REQUIRED
                                         #   for that op ("set_collision_sensitivity needs
                                         #   collision_sensitivity (1, 2 or 3)" -> 422); every
                                         #   other op ignores it

class PrePositionPlan(BaseModel):        # phase-09d: twin-planned motion before homing
    needed: bool                         # False = current posture already sweep-clear
    source: Literal["current", "keyframe", "home", "search"] = "current"
                                         # which candidate posture won: the scene keyframe's
                                         #   7 joints / the <arm>_home keyframe; "search"
                                         #   (sampled around a candidate) is reserved
    target_q: list[float] = []           # 7 joints, rad - the posture the arm HOLDS after
                                         #   homing
    waypoints: int = 0                   # planned joint-space waypoints (0 = not needed)
    duration_s: float = 0.0              # estimated execution time at speed_scale 0.1
    checked_rail_positions: int = 0      # 131 when the position-agnostic validation ran
    clear: bool = True                   # path clear for EVERY rail position (the ONLY
                                         #   safety basis); needed and not clear = refused
    detail: str = ""                     # operator-facing summary / why no plan was found

class RailSweepVerdict(BaseModel):       # twin sweep that gates home_rail (phase-09c, D4)
    scene_id: str                        # twin scene swept (mavis_v2)
    inflation_m: float; step_m: float    # 0.025 m debug margin; 5 mm steps (131 positions)
    travel_m: float = 0.65               # full rail travel swept (carriage position unknown)
    clear: bool                          # no step violates -> the op may write
    first_blocked_m: float | None = None          # rail position of the first violation
    first_blocked_pair: list[str] = []            #   and its [geom_a, geom_b]
    min_clearance_m: float | None = None          # tightest pair over the sweep
    min_clearance_at_m: float | None = None       #   (rail position; None = none measured)
    min_clearance_pair: list[str] = []
    q_checked: list[float] = []          # the 7 joints the sweep assumed (must match at
                                         #   execution: the monitor re-samples, q_tol 0.02 rad)
    other_arms: dict[str, list[float]] = {}       # arm_id -> q7 + rail used for the other
                                                  #   arm(s) (last monitor sample)
    assumptions: list[str] = []          # e.g. "view rail unknown - used fallback 0.00 m"
    sample_seq: int = 0                  # monitor sample the posture came from
    pre_position: PrePositionPlan | None = None   # phase-09d plan / "not needed"; None =
                                                  #   pre-09d producer / not evaluated

class ArmMaintenanceResult(BaseModel):   # response (200 / 202 whether or not ok)
    arm_id: str; op: ArmMaintenanceOp; path: MaintenancePath; ok: bool
    detail: str = ""                     # human-readable outcome
    sdk_codes: dict[str, int] = {}       # SDK call -> return code, in call order
    warnings: list[str] = []             # apply_backstops non-fatal codes
    before: ArmMonitorTelemetry | None = None   # monitor samples around the op (None on
    after: ArmMonitorTelemetry | None = None    #   the session path / monitor unconnected)
    rail_sweep: RailSweepVerdict | None = None  # home_rail verdict, dry-run or real (None
                                                #   for the other ops; additive, phase-09c)
    status: MaintenanceStatus = "done"   # phase-09d: accepted = async job started (202);
                                         #   the job's final result is "done" again
    job_id: str | None = None            # RailHomingJob id when status == "accepted" and on
                                         #   the job's final result (additive, phase-09d)
    collision_sensitivity: int | None = None    # set_collision_sensitivity: the level WRITTEN
                                                #   (1..3; None for every other op and for a
                                                #   refusal) - the session path has no monitor
                                                #   sample, so the UI toasts this (additive,
                                                #   2026-09-11)
```

Queueing on the monitor thread, the recovery budget, the 409 matrix, the
`home_rail` sweep recipe (`RailSweepChecker` on `check_config_violations` /
`pair_distance`, 03-sim §8), the position-agnostic path check
(`RailSweepChecker.check_path`), the candidate order and the `RailHomingJob`
state machine, the `job_id` format, the 45 s synchronous timeout and the INFO
audit line are hardware / runtime territory (02-hardware "maintenance channel"
+ §5, 04-runtime §5 / §13.1 / §15); core only fixes the spellings.

## 13. Protocol: video framing & keymap (`protocol/video.py`, `protocol/keymap.py`)

**Video framing (binding).** `/ws/video/{stream_id}` frames = 12-byte
little-endian header (f64 timestamp seconds + u32 JPEG length) then JPEG.

```python
HEADER_FMT = "<dI"; HEADER_SIZE = 12            # struct.calcsize == 12
RESERVED_STREAM_IDS = ("sim", "twin")           # session-only renders; real-camera ids
                                                #   are live PRE-session at ~15 fps
def pack_frame(ts: float, jpeg: bytes) -> bytes # header + payload, one buffer
def unpack_header(buf: bytes | memoryview) -> tuple[float, int]
    # (ts, jpeg_len); VideoFramingError on len < 12 or length mismatch
def is_reserved_stream(stream_id: str) -> bool
```

**Canonical keymap.** `GET /api/keymap` serves exactly this table; the UI
builds its bound-key set — and its gamepad mapping — from it; no hardcoded
duplicate (binding; 13-tracker §1/§3).

```python
class KeymapEntry(BaseModel):
    code: str                            # KeyboardEvent.code
    action: str                          # held: axis name or held modifier; discrete: ActionName
    kind: Literal["held", "discrete"]
    label: str                           # overlay text
    group: Literal["translate", "rotate", "gripper", "rail", "session", "episode", "tracker"]
    requires_rail: bool = False
    gamepad: str | None = None           # XInput control mirrored on this row:
                                         #   DpadLeft/DpadRight/A/B/LB/RB/RT (additive)

KEYMAP: tuple[KeymapEntry, ...]          # exactly these 24 entries:
# held/translate: KeyW translate_x_pos "forward"
#                 KeyS translate_x_neg "back"
#                 KeyA translate_y_pos "left" | KeyD translate_y_neg "right"
#                 KeyE translate_z_pos "up"   | KeyQ translate_z_neg "down"
#                 (the axis names and labels are the KEY axes — x forward, y left,
#                  z up — and never name a frame; the physical frame is the runtime's
#                  control.translate_frame: default the operator-fixed world frame
#                  since 2026-09-08 evening, `camera` = the active arm's wrist camera
#                  (that morning's default), `base` = pre-2026-09-08 — 04-runtime §6)
# held/rotate:    KeyI roll_pos  | KeyK roll_neg      (about TCP axes; spine §5:
#                 KeyJ pitch_pos | KeyL pitch_neg      I/K roll, J/L pitch, U/O yaw)
#                 KeyU yaw_pos   | KeyO yaw_neg
# held/gripper:   KeyF gripper_close (gamepad B) | KeyH gripper_open (gamepad A)
# held/rail:      ArrowLeft rail_neg (DpadLeft) | ArrowRight rail_pos (DpadRight)
#                 (requires_rail=True)
# held/tracker:   KeyC tracker_clutch "tracker clutch (hold)" (gamepad RT) — a held
#                 MODIFIER, not an axis (13-tracker §1)
# discrete/session: KeyZ switch_arm_prev "previous arm" (gamepad LB)
#                 | Tab switch_arm (gamepad RB) | Space takeover_toggle
#                 (label: "takeover toggle (DAgger: recorded; inference: safety
#                  escape, never recorded)")
#                 | KeyR reset_to_initial "return to the initial condition"
#                   (2026-09-08; twin-planned, gated, cancelled by any movement
#                    input — a no-op with a reason when no initial condition is
#                    designated for the workcell kind. 04-runtime §10.5)
# discrete/episode: KeyN episode_new | Enter episode_save | Backspace episode_discard

HELD_CODES: frozenset[str]; DISCRETE_CODES: dict[str, str]   # derived views
HELD_MODIFIER_ACTIONS: frozenset[str] = frozenset({"tracker_clutch"})
    # held actions that are NOT axes: excluded from axis_map(); runtime's
    # held_to_twist ignores them (13-tracker §3.3)
def axis_map() -> dict[str, tuple[str, float]]
    # held axis action -> (axis, sign), e.g. "translate_x_pos" -> ("x", +1.0);
    # single source of signs for runtime's held_to_twist
```

Invariants (tested §18): 24 entries (6 translate + 6 rotate + 2 gripper +
2 rail + 1 tracker + 4 session + 3 episode — matches spine §5), unique codes;
every discrete `action` is a valid `ActionName`; exactly the rail entries have
`requires_rail=True`; every held action is either an axis (in `axis_map()`,
with a ± partner on the same axis) or a member of `HELD_MODIFIER_ACTIONS`,
never both; exactly the seven 13-tracker §1 rows carry a `gamepad` label; no
browser-owned chords. Episode keys are always listed; runtime nacks them in
modes without a recorder. Re-affirmed 2026-09-07: whole-table code uniqueness
is what keeps a key from being both a held and a discrete row — a short-lived
uncommitted change that flagged every held row `keyboard=False` ("teleop is
the Vive only") and put episode save / discard on `KeyS` / `KeyF` (colliding
with translate −x / gripper close) is reverted by phase-13; `KeymapEntry` has
no `keyboard` field and the keyboard is a full teleop interface (overview §5
"Input interfaces").

## 14. JSON-schema export for TS generation (`protocol/export_schemas.py`)

UI pipeline (05-ui §2): core exports JSON Schema → UI `pnpm gen:sync` copies
`../apollo-mavis-v2-core/schemas/*.json` → `json-schema-to-typescript` emits
`src/gen/*.ts`. Root `schemas/` is checked in, regenerated in CI.

```python
EXPORTED_MODELS: dict[str, type[BaseModel]] = {
  # control:  HelloMsg, KeysMsg, ActionMsg, AckMsg, JointTargetArgs,
  #           SaveProfileArgs, SetInitialConditionArgs, TrackerSettingsArgs
  # telemetry: TelemetryMsg (embeds ArmTelemetry/CollisionReport/EpisodeStatus/
  #           DaggerStatus/TrainerStatus/InferenceStatus/TrackerTelemetry/ControllerTelemetry/
  #           TrackerCalibrationStatus/LighthouseStatus/CalibrationValidation/YawGesturePoint/
  #           MicrophoneTelemetry/HardwareMonitorTelemetry/ArmMonitorTelemetry/
  #           TwinOverlayTelemetry/SessionTelemetry/ArmBringupTelemetry via $defs)
  # tracker:  TrackerCalibrationStatus, TrackerCalibrationCommand (REST
  #           /api/tracker/calibration; the other protocol.tracker models ride $defs only)
  # session:  SessionSpec, SessionInfo, WorkcellStatus, ArmStatusInfo,
  #           CameraInfo, SceneInfo, ProfileInfo, PolicyInfo,
  #           ReturnHomeResult (REST POST /api/session/return_home, 2026-09-08),
  #           DatasetInfo, EpisodeInfo, DatasetExportInfo, DatasetExportRequest, SwitchArmArgs
  #           (2026-09-07), OnlineDaggerConfig, OnlineDaggerSessionInfo, DatasetLayoutInfo,
  #           DatasetNamespaceInfo (phase-14, 2026-09-08 evening — OnlineDaggerStatus rides
  #           TelemetryMsg $defs; the morning's ProDaggerConfig / ProDaggerSessionInfo /
  #           ProDaggerStatus / ProDaggerIterationSummary files are deleted)
  # control:  + GotoProfileArgs (2026-09-08 evening)
  # external: SessionAnnounce, PolicySpecAnnounce, DoraInfo (phase-12, §20), TrainerStatusAnnounce,
  #           OnlineDaggerAnnounce (phase-14; RefGradStatus / ProDaggerAnnounce deleted) — 43 schema
  #           files in total on 2026-09-08 evening (`export_schemas --check` clean)
  # microphone: MicrophoneInfo (REST /api/microphones; phase-11 — MicrophoneTelemetry
  #           rides TelemetryMsg $defs only)
  # maintenance: ArmMaintenanceRequest, ArmMaintenanceResult (REST POST
  #           /api/hardware/arms/{arm_id}/maintenance; phase-09b — the result embeds
  #           ArmMonitorTelemetry via $defs, the same class TelemetryMsg nests, and
  #           RailSweepVerdict via $defs; phase-09c — EXPORTED_MODELS unchanged;
  #           phase-09d — PrePositionPlan + MaintenanceProgress join the result's $defs and
  #           MaintenanceProgress the TelemetryMsg $defs; EXPORTED_MODELS / index.json
  #           unchanged again)
  # misc:     StateProfile, KeymapEntry, CollisionEvent
}
def export(out_dir: Path) -> list[Path]
    # one <Name>.json via model_json_schema(ref_template="#/$defs/{model}"),
    # draft 2020-12; json.dumps(sort_keys=True, indent=2) + trailing newline
    # => byte-deterministic. Also writes keymap.json (the KEYMAP table) and
    # index.json (exported names + core __version__).
def main(argv: list[str] | None = None) -> int
# CLI: python -m apollo_mavis_v2_core.protocol.export_schemas --out schemas/
#      --check -> exit 1 if regeneration would change any file (CI drift guard)
```

Enums/Literals export as JSON-schema enums (TS unions); tuples as fixed-length
`prefixItems`; numpy never appears in exported models (export test enforces).

## 15. Command bus & typed queues (`bus.py`)

The Dora-migration seam (spine §2): discrete ops flow through one bus with
correlation IDs; high-rate data through depth-1 `LatestSlot`s. Core owns both;
runtime instantiates and wires them (04-runtime §4 imports these).

```python
@dataclass(frozen=True)
class Command:
    op: str                              # ActionName values + internal ops
                                         #   ("end_session", "load_profile", ...)
    args: dict[str, Any] = field(default_factory=dict)
    corr_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    source: Literal["ws", "rest", "internal"] = "ws"

@dataclass(frozen=True)
class CommandResult:
    corr_id: str; ok: bool
    detail: str = ""                     # surfaces as AckMsg.detail

class CommandBus:
    """Thread-safe MPSC. Producers: any thread/asyncio loop. Consumer: ONE
    thread (runtime ControlLoop's thread) drains at each tick boundary."""
    def __init__(self, maxsize: int = 256) -> None
    def submit(self, cmd: Command) -> Future[CommandResult]
        # enqueue + concurrent.futures.Future keyed by corr_id. Full queue ->
        # resolve immediately ok=False detail="bus full" (never blocks a WS
        # handler). asyncio callers await via asyncio.wrap_future.
    def drain(self, handler: Callable[[Command], CommandResult]) -> int
        # consumer: pop all, run handler synchronously, resolve each Future
        # (exception -> ok=False detail=repr). Long ops resolve immediately
        # ok=True detail="accepted"; progress rides telemetry.

class LatestSlot(Generic[T]):
    """Depth-1 latest-value slot (lock + threading.Event); the ONLY
    inter-thread structure besides CommandBus. put() overwrites."""
    def put(self, value: T) -> None
    def get(self) -> tuple[T, float] | None           # (value, put_mono) | None
    def wait_fresh(self, timeout: float) -> tuple[T, float] | None
```

Conventions (normative for all repos): one writer per slot; readers never
mutate; slot payloads carry their own `t_mono` (staleness uses value time, not
put time); no unbounded queues in the control path (bursty events: bounded
`deque(maxlen=...)` drained at telemetry rate); payloads are
Arrow-representable schemas or numpy-bearing frozen dataclasses — keeps a
later Dora migration mechanical.

## 16. Errors, threading & data ownership (`errors.py`)

```python
class ApolloError(Exception): ...
class ConfigError(ApolloError): ...              # carries path + JSON-pointer loc
class FrameRefError(ApolloError, ValueError): ...
class CommandError(ApolloError): ...             # bad command_joints/gripper input
class RailUnavailableError(CommandError): ...
class ProfileError(ApolloError): ...
class ProfileNotFoundError(ProfileError, KeyError): ...
class VideoFramingError(ApolloError, ValueError): ...
class SchemaExportError(ApolloError): ...
class BringupError(ApolloError): step: str       # raised by hardware/sim impls; typed
class ArmConnectError(BringupError): ...         #   here so runtime catches without
class ArmIdentityError(BringupError): ...        #   importing hardware
class RailExpectedError(BringupError): ...
class RailNotHomedError(BringupError): ...       # track detected but on_zero == 0: position
                                                 #   unknown -> connect fails at step "rail"
                                                 #   (default), the hardware session is
                                                 #   refused, the operator homes from the UI
                                                 #   (home_rail, §12); phase-09c
class GripperInitError(BringupError): ...
class CameraInitError(BringupError): ...
class WorkcellBringupError(ApolloError):
    statuses: dict[str, BringupError | None]     # per-arm/camera (landing page)
```

`BringupError` subclasses take `(step, message)` positionally; `RailNotHomedError`
defaults `step` to `"rail"` so `RailNotHomedError(message=...)` reads naturally.
Rules: typed exceptions for *caller* mistakes (shape, range, missing
capability); degraded-but-valid data for *environment* problems
(`ArmState.stale=True`, `latest() -> None`) — the control loop must keep
ticking. Threading: core is passive; `CommandBus`/`LatestSlot`/`ProfileStore`
are thread-safe, everything else single-thread-owned by convention. Data
ownership: numpy arrays in frozen dataclasses or slots are frozen by
convention — producers never mutate after publishing, consumers copy before
mutating; `APOLLO_CORE_DEBUG=1` enforces via `arr.setflags(write=False)`.
Event-like models set `model_config = ConfigDict(frozen=True)`.

## 17. Package tooling (uv, pyproject, pytest, ruff)

```toml
[project]
name = "apollo-mavis-v2-core"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = ["numpy>=1.24,<3", "pydantic>=2.5,<3", "PyYAML>=6.0"]

[dependency-groups]
dev = ["pytest>=8", "pytest-cov", "ruff>=0.6", "mypy>=1.10", "hypothesis>=6"]

[build-system]
requires = ["hatchling"]; build-backend = "hatchling.build"

[tool.ruff]
line-length = 100; target-version = "py310"
[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "TID251"]
[tool.ruff.lint.flake8-tidy-imports.banned-api]  # dependency rule as lint:
"mujoco".msg = "core must not import mujoco"     #   + xarm, fastapi, torch,
                                                 #   lerobot, cv2 (same pattern)
[tool.pytest.ini_options]
testpaths = ["tests"]; addopts = "-q --strict-markers"
```

Workflow: `uv sync` → `uv run pytest` → `uv run ruff check src tests` →
`uv run python -m apollo_mavis_v2_core.protocol.export_schemas --out schemas/`.
Siblings use an editable path dep in dev (`uv add --editable
../apollo-mavis-v2-core`), pin `apollo-mavis-v2-core==x.y.*` when published.
CI order: ruff → pytest → schema `--check`.

## 18. Test strategy (hardware-free)

All of core tests with no robot, no MuJoCo, no network.

- **Import guard**: subprocess imports `apollo_mavis_v2_core` (+ `.protocol`,
  `.dagger.types`), prints `sorted(sys.modules)`; assert intersection with
  `{mujoco, xarm, fastapi, torch, lerobot, cv2, mink, zmq, websockets}` is
  empty and import time < 500 ms.
- **SE3** (hypothesis): quat↔mat/rpy/rotvec round trips; canonical `w >= 0`
  after every op; `pose_mul(a, pose_inv(a)) ≈ id`; `integrate_twist` vs finite
  differences; slerp endpoints; leash clamp bounded + idempotent.
- **State**: shape/dtype rejection; `q[7] == rail_pos_m` when rail present;
  GripperCommand range checks.
- **Config**: YAML fixtures (1/2/3-arm hardware + sim) load; one failing
  fixture per cross-field validator; errors carry file + loc;
  `ArmConfig.collision_sensitivity` bounds (0..5, ints only, loc
  `/arms/i/collision_sensitivity`), `reduced_tcp_boundary_mm` exactly six ints,
  `expected_sn` optional string.
- **ProfileStore** (`tmp_path`): CRUD round trip; atomic overwrite (fault
  injected before `os.replace` leaves the old file intact); `set_initial`
  uniqueness incl. crash-ordering (target-last ⇒ never two flags);
  delete-initial refusal; foreign-file tolerance.
- **Protocol**: every wire model round-trips `model_dump_json →
  model_validate_json`; discriminated-union parse of a mixed control
  transcript; the literal JSON fixtures of 04-runtime §13.2 parse;
  `JointTargetArgs` / `SessionSpec.start_from` accept/reject tables;
  `model_fields` pinned per wire model (core is the spelling authority) and
  legacy-dict additivity for every additive field (`TrackerTelemetry.*`,
  `TelemetryMsg.microphone`, `TelemetryMsg.hardware_monitor`,
  `ArmStatusInfo.reachable`, `WorkcellStatus.hardware_ready`,
  `WorkcellStatus.policy_modes` (2026-09-12),
  `ArmTelemetry.fault_detail` / `.recovering`, the `ArmMonitorTelemetry`
  safety read-back + `maintenance_busy`); `MicStatus` identical on
  `MicrophoneTelemetry` and `MicrophoneInfo`; `ArmMonitorStatus` /
  `TwinOverlayStatus` / `ArmMaintenanceOp` / `MaintenancePath` vocabularies and
  `CameraInfo.kind` (incl. `"twin"`) pinned as exact tuples;
  `ArmMaintenanceResult` fixtures pin the `clear_errors` write set
  (`clean_error`, `clean_warn` — never `motion_enable`) and the
  `apply_backstops` call order; phase-09c: `ArmMaintenanceOp` incl.
  `home_rail`, `ArmMaintenanceRequest.dry_run` default, `RailSweepVerdict`
  fields / defaults / D4 numbers, `home_rail` fixtures (dry-run = verdict +
  empty `sdk_codes`; real = exactly the three track methods; blocked = `ok
  False` + verdict), `SessionSpec.speed_scale` accept / reject table (0 and 1.5
  are rejected), `SessionInfo.kind` / `.speed_scale` and
  `SessionTelemetry.bringup` / `ArmBringupTelemetry` additivity; phase-09d:
  exact field sets + defaults of `PrePositionPlan`, `MaintenanceProgress`,
  `MaintenanceStatus` / `MaintenancePhase`, `ArmMaintenanceResult.status` /
  `.job_id` and `ArmMonitorTelemetry.maintenance`, wire fixtures for a
  dry-run-planned verdict, a 202 `accepted` result, a job's `done` (ok / failed)
  result, a `refused` result and progress rows, and that every name imports
  from both `protocol.maintenance` and `protocol.hardware_monitor`.
- **Errors** (`tests/test_errors.py`): `BringupError` `(step, message)`
  convention; `RailNotHomedError` defaults `step="rail"`, is a `BringupError`
  distinct from `RailExpectedError`, aggregates in `WorkcellBringupError` and
  is exported at the package top level.
- **Keymap**: §13 invariants + literal table equality against spine §5 — any
  keymap edit is a conscious spine change.
- **Video**: pack/unpack round trip; `struct.calcsize("<dI") == 12`;
  truncation/mismatch errors; reserved-id predicate.
- **Schema export**: export twice → byte-identical; `--check` vs checked-in
  `schemas/` (drift fails CI); no numpy leakage; `EXPORTED_MODELS` pinned as
  an exact set; per-model property/required/enum/default sets pinned for the
  tracker, microphone, hardware-monitor / twin-overlay, arm-maintenance
  (`ArmMaintenanceRequest.json` flat incl. `dry_run`, `ArmMaintenanceResult.json`
  nesting the same `ArmMonitorTelemetry` `$defs` as `TelemetryMsg.json` plus
  `RailSweepVerdict`), `SessionSpec.speed_scale` (`exclusiveMinimum 0`,
  `maximum 1`, default 1.0) and `SessionInfo.kind` / `.speed_scale`,
  `SessionTelemetry.bringup` / `ArmBringupTelemetry` in the telemetry `$defs`
  (neither `RailSweepVerdict` nor `ArmBringupTelemetry` exports top-level),
  phase-09d: `PrePositionPlan` + `MaintenanceProgress` in the
  `ArmMaintenanceResult.json` `$defs` and `MaintenanceProgress` in the
  `TelemetryMsg.json` `$defs` with `index.json` unchanged,
  `ArmTelemetry` fault and phase-11 workcell fields; `CameraInfo.kind` enum incl. `"twin"` in both `CameraInfo.json` and
  the `WorkcellStatus.json` `$defs`.
- **Bus**: N producer threads × 1 drainer — every Future resolves exactly
  once, corr_ids match; bus-full immediate nack; handler exception →
  ok=False; `LatestSlot` overwrite + `wait_fresh` timeout semantics.
- **`apollo_mavis_v2_core.testing`**: `FakeArm`/`FakeCamera`/`FakeWorkcell` —
  deterministic pure-python stubs (`command_joints` slews q toward target at a
  configurable rate); the one canonical fake set for hardware/sim/runtime
  suites instead of four ad-hoc mocks.

## 19. Cross-doc drift ledger

Core is the spelling authority (03-sim §2 defers explicitly). Known drift in
sibling docs, resolved here — siblings adopt these on next edit:

| # | Drift | Resolution (canonical, this doc) |
|---|---|---|
| 1 | 05-ui ActionName `set_initial_condition` vs 04-runtime `set_initial_profile` | `set_initial_condition` (§10); runtime Command `op` uses the same string |
| 2 | 04-runtime has `SessionSpec` as a runtime dataclass; spine §8 wants pydantic in core.protocol | pydantic `SessionSpec` in `core.protocol.session` (§12); runtime imports it |
| 3 | 04-runtime hosts `ProfileStore` in `runtime/profiles/store.py` | CRUD/atomicity in `core.profiles.store` (§8); runtime keeps a thin `save_from_snapshot` wrapper |
| 4 | 04-runtime defines bus primitives in `runtime/bus.py` | primitives in `core.bus` (§15); `runtime.bus` re-exports + wires named slots |
| 5 | 03-sim `ClearanceEntry` vs 11-safety `PairClearance` | `PairClearance` (§5.2) |
| 6 | 11-safety `DigitalTwinInterface.render -> np.ndarray` vs 03-sim `CameraFrame \| None` | `CameraFrame \| None` (§5.2), uniform with camera streams |
| 7 | 04-runtime `HeldState` in `runtime/control/teleop.py` | defined in `core.interfaces.teleop` (§5.2); runtime imports it |
| 8 | research-note `EpisodeSummary` fields vs 12-dagger §5 doubt additions | §9 shape (episode_index, label/intervention counts, segments, `segment_doubts`) |
| 9 | 05-ui `InferenceStatus` lacks `engaged_arm`; 12-dagger telemetry includes it | included, additive (§11) |
| 10 | 11-safety `SafetyConfig` listing omits `safety_debug`; spine §6 requires the flag | `safety_debug: bool = False` on `SafetyConfig` (§6), sim-only semantics |
| 11 | 15-pro-dagger v1.0 (2026-09-08 morning) — `ProDaggerConfig`, `ProDaggerStatus`, `ProDaggerIterationSummary`, `ProDaggerSessionInfo`, `ProDaggerAnnounce`, `RefGradStatus`, `pro_dagger_train_now`, `EventKind iteration_complete` / `pro_dagger_phase` | DELETED the same evening (operator decision: the runtime is the algorithm-agnostic Online DAgger shell, `15-online-dagger.md` v2.0) — replaced by `OnlineDaggerConfig` / `OnlineDaggerStatus` / `OnlineDaggerSessionInfo` / `OnlineDaggerAnnounce` / the 10-field `TrainerStatusAnnounce` / `takeover`, `handback`, `train_now` / `EventKind train_now` (§10–§12, §20). Superseded: the previous rows 11–12 recorded the v1.0 model hardening (`iteration` + `last_used_at`, the flat six-field announce, `seed` bounds) — none of it shipped |
| 12 | 15-online-dagger v2.0 §5 `OnlineDaggerConfig` / `OnlineDaggerStatus` / `OnlineDaggerSessionInfo` / §6 `TrainerStatusAnnounce`, `OnlineDaggerAnnounce` | spelled exactly as designed (`extra="forbid"`, `session_name` `max_length` 64, `allow_inf_nan=False` on every float incl. `metrics` values, `progress` in [0, 1], `uptime_s ≥ 0`) — no deviation (15-online-dagger §12) |
| 13 | 12-dagger §4 / 05-ui: `DaggerStatus` without `policy_stale` | `policy_stale: bool = False` (phase-12, promised by 04-runtime §15) and `online_dagger` (phase-14) on `DaggerStatus`, `policy_stale` on `InferenceStatus` (§11) |
| 14 | 15-online-dagger v2.0 §5 `ActionName` ends `takeover, handback, train_now`; `SessionInfo` ends `online_dagger` | `goto_profile` (`GotoProfileArgs{profile_id}`) appended after `train_now` later the same evening; `SessionInfo.fault_detail` inserted before `online_dagger` (which stays last) — both additive, both outside the Online DAgger shell (§10, §12; 04-runtime §10.5 / §13.3) |

No spine concerns: this document implements `00-overview.md` v0.3 as written.

## 20. dora boundary spellings (`protocol/external.py`, phase-12, 2026-09-08)

`protocol/external.py` is the spelling authority for the dora boundary (node /
stream / command ids, metadata keys, `ARM_STATE_LAYOUT` = 32 names, the JSON
payload models `SessionAnnounce`, `CameraAnnounce`, `PolicySpecAnnounce`,
`PolicyResetMsg`, `EventEnvelope`, `ExternalStatus`, `DoraMachineInfo`,
`DoraInfo`); `SessionAnnounce`, `PolicySpecAnnounce` and `DoraInfo` are exported
as schemas. Additive fields elsewhere: `SessionSpec.policy_source`
(`checkpoint | external`; external ⇒ dagger / inference with `policy: null`),
`SessionInfo.policy_source`, `DaggerStatus.policy_stale`,
`InferenceStatus.policy_stale`, `TelemetryMsg.external: ExternalStatus | None`
(after `microphone`, before `hardware_monitor`), `CameraFrame.depth` (H×W
uint16 mm) + `depth_scale_m`, `CameraConfig.depth` / `align_depth_to_color`,
`Command.source` may be `"dora"`. core stays free of dora and pyarrow (ruff
`banned-api` + `tests/test_import_guard.py`). Details: 14-dora §3–§5, §13.

**Phase-14 additions (2026-09-08; as shipped the same evening — 15-online-dagger §6 / §12;
all additive, appended last, `MAVIS_SCHEMA` stays 1, the order is the contract goldens'):**
`IN_POLICY_TRAINER_STATUS = "policy_trainer_status"` appended to `RUNTIME_INPUTS`
(source `policy/trainer_status`, queue 8); `POLICY_OUT_TRAINER_STATUS =
"trainer_status"` appended to `POLICY_OUTPUTS`; `EventKind` / `EVENT_KINDS` +=
`"train_now"` (10 kinds; payload keys documented in the module: `gate {arm_id, mode, seq,
source, episode_id}`, `episode_saved.online_dagger {episode_id, rollouts_saved,
actor_counts: {novice, expert}, policy_version, spool_path}`, `episode_discarded
{episode_index, episode_id, reason}`, `train_now {rollouts_saved, requested_by}`);
`PolicyResetReason` unchanged but `"episode_boundary"` is now what the runtime spells at
episode boundaries (`"handback"` only inside an episode); `PolicySpecAnnounce.capabilities:
list[str] = []` (a trainer-capable node lists `"online_dagger"`);
`OnlineDaggerAnnounce{session_name, session_dir, rollouts_dir}` + `SessionAnnounce.
online_dagger: OnlineDaggerAnnounce | None` (last); `TrainerStatusAnnounce{mavis_schema,
trainer_id, node_version, state: idle | preparing | training | ready | error, session_id,
policy_version, progress, metrics: dict[str, float], detail, uptime_s}` — ten fields, every
float `allow_inf_nan=False`, `progress` in [0, 1], `uptime_s ≥ 0`, `metrics` free-form finite
scalars; `ExternalStatus.capabilities: list[str] = []` and `.trainer_status:
TrainerStatusAnnounce | None` (session-less, for the launcher). Exported as schemas:
`TrainerStatusAnnounce`, `OnlineDaggerAnnounce` (§14). `protocol/__init__.py` re-exports the
new names plus `SLUG_RE`, `POLICY_OUTPUTS`, `EVENT_KINDS`. Superseded (2026-09-08 evening) —
the morning's `EventKind iteration_complete` / `pro_dagger_phase`, the six-field
`ProDaggerAnnounce`, `RefGradStatus` and the 23-field `TrainerStatusAnnounce`: deleted, not
aliased (never shipped; the one permitted history note is the module docstring's "v1.0
PRO-DAgger shell superseded 2026-09-08").
