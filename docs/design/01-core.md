# 01 — apollo-xarm7-core (`apollo_xarm7_core`)

Status: v1.0 (2026-09-01; amended 2026-09-03 — phase-10 tracker calibration:
`protocol/tracker.py`, `TrackerTelemetry.charging`/`.calibration`, §10-§12, §14).
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
  mm/deg/pulses exist only inside `apollo_xarm7_hardware`.
- Wire-visible/persisted ⇒ pydantic `BaseModel`; hot-path (100 Hz, numpy) ⇒
  frozen `dataclass`. Python ≥ 3.10, managed with `uv`.

## 2. Package layout

```
apollo-xarm7-core/
├── pyproject.toml             # §17
├── schemas/                   # CHECKED-IN JSON Schema output of §14 (UI vendors these)
├── src/apollo_xarm7_core/
│   ├── __init__.py            # re-exports public API + __version__
│   ├── types.py se3.py        # §3      state.py                 # §4
│   ├── errors.py bus.py       # §16 §15 testing.py               # fakes, §18
│   ├── interfaces/            # arm.py camera.py workcell.py ik.py safety.py
│   │                          #   policy.py recorder.py teleop.py  (§5)
│   ├── schemas/               # config.py (§7)  safety.py (§6)  profile.py (§8)
│   ├── profiles/store.py      # ProfileStore (§8)
│   ├── dagger/                # types.py interfaces.py (§9)
│   └── protocol/              # control.py (§10) telemetry.py (§11) session.py (§12)
│                              #   video.py keymap.py (§13) export_schemas.py (§14)
└── tests/                     # §18
```

`__init__.py` re-exports stable names (`from apollo_xarm7_core import
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
rpy_to_quat(rpy); quat_to_rpy(q)      # xArm SDK RPY (intrinsic XYZ) — hardware/units.py
rotvec_to_quat(r); quat_to_rotvec(q)  # log map; delta-EE action rotations
quat_geodesic(a,b) -> [0,pi]; quat_slerp(a,b,t)
xyzw_to_wxyz(q); wxyz_to_xyzw(q)      # ONLY sanctioned order-swap helpers (scipy/ROS)
pose_mul(a,b); pose_inv(a); pose_between(a,b)        # a⁻¹ ⊕ b
pose_error(a,b) -> (pos_err_m, geodesic_rad)
integrate_twist(p, tw, dt) -> Pose    # translation along twist axes, rotation about
                                      #   pose origin (04-runtime §6 teleop semantics)
clamp_pose_to_leash(target, anchor, max_pos_m, max_rot_rad) -> Pose  # geodesic clamp

TCP_OFFSET_M = 0.172                  # link7 flange -> link_tcp along tool +Z (MJCF)
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
    def clearance(self, distmax: float = 0.05) -> list[PairClearance]: ...
        # measured config, ascending; ~1 µs/pair; telemetry rate, not gate rate
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

# interfaces/recorder.py — runtime implements over LeRobotDataset v3
class EpisodeRecorder(ABC):
    def start(self, meta: dict[str, object]) -> None       # open episode buffer
    def add_frame(self, frame: dict[str, object]) -> None  # -> LeRobotDataset.add_frame
    def save(self) -> int                # episode_index (save_episode)
    def discard(self) -> None            # clear_episode_buffer
    def finalize(self) -> None           # MANDATORY (parquet footers)
    recording: bool                      # property

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

class PlanResult(BaseModel):
    ok: bool
    waypoints: dict[str, list[list[float]]] = {}
    failure: Literal["goal_in_collision", "start_in_collision", "timeout"] | None = None
    failing_pair: tuple[str, str] | None = None
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
class EpisodeSummary:                    # runtime -> trainer at every save_episode
    episode_index: int; n_frames: int
    n_intervention_frames: int           # control_mode != POLICY
    n_label_frames: int                  # control_mode == HUMAN (HG-DAgger Eq. 2)
    takeover_segments: int               # maximal runs of control_mode != POLICY
    segment_doubts: list[float]          # policy-action variance at takeover instants
    success: bool | None

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
    "save_profile", "set_initial_condition", "joint_target",
    "tracker_settings",
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
    filter_beta: float | None = None     # 0 <= x <= 5 (speed coefficient)

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
runtime owns the defaults (`min_cutoff_hz 1.0`, `beta 0.05`) via
`TrackerConfig.filter`. A settings change while the clutch is engaged makes
the runtime re-anchor (13-tracker §4 "Anchor and re-seed rules"); it never
moves the arm.

Tracker calibration (phase-10; 13-tracker §3/§4) adds **no** `ActionName`: the
Devices page has no session and `/ws/control` nacks actions without one, and
`AckMsg` carries no payload. Calibration commands ride REST
(`TrackerCalibrationCommand`, §12) and progress rides telemetry
(`TrackerTelemetry.calibration`, §11). `_ARGS_MODELS` and the 23-row keymap
(§13) are unchanged — the controller trigger is re-purposed by the runtime as
the yaw-gesture capture click while a yaw calibration is active.

## 11. Protocol: telemetry (`protocol/telemetry.py`)

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

class ClearanceItem(BaseModel):
    pair: tuple[str, str]; dist_m: float

class EpisodeStatus(BaseModel):
    state: Literal["idle", "recording", "saving"]
    index: int | None; frames: int; duration_s: float

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

class InferenceStatus(BaseModel):        # same gate machinery; takeover = SAFETY ESCAPE
    control_mode: ControlMode
    engaged_arm: str | None = None       # additive vs 05-ui
    policy_version: str | None

class SessionTelemetry(BaseModel):       # additive block (04-runtime §13.3)
    state: str                           # SessionState value
    start_from_progress: float | None = None    # 0-1 during START_FROM
    plan_status: str | None = None; trainer_alive: bool | None = None

class TrackerSettingsMsg(BaseModel):     # live tracker settings (13-tracker §3.5, §4)
    yaw_deg: float; pos_scale: float; follow_rotation: bool
    filter_enabled: bool = True          # effective One Euro pose-filter settings; defaults
    filter_min_cutoff_hz: float = 1.0    #   = the runtime's TrackerConfig.filter defaults
    filter_beta: float = 0.05            #   (additive; pre-filter producers still parse)

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
```

## 12. Protocol: session & REST models (`protocol/session.py`, `protocol/tracker.py`)

Bodies for the `/api` surface (04-runtime §13.1); runtime defines no wire
model of its own. Session models live in `protocol/session.py`; the phase-10
tracker-calibration models in `protocol/tracker.py` (below).

```python
Mode = Literal["teleop", "collect", "dagger", "inference"]
START_FROM_RE = r"^(keep_current|profile:[A-Za-z0-9_\-]+)$"

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

class SessionInfo(BaseModel):            # POST/GET /api/session response
    session_id: str; epoch: str; mode: Mode; arms: list[str]
    streams: list[str]                   # video ids: camera ids + "sim" and/or "twin"
    state: str                           # SessionState value

class ArmStatusInfo(BaseModel):          # landing-page card
    arm_id: str; ip: str | None; connected: bool; has_rail: bool
    gripper: Literal["xarm", "xarm_g2", "none"]; gripper_force_capable: bool
    error_code: int
    joint_limits: list[tuple[float, float]]  # 7 rad pairs; + [0.0, 0.65] m appended for
                                             #   rail arms (joint-panel slider ranges)

class CameraInfo(BaseModel):
    camera_id: str; kind: Literal["v4l2", "realsense", "sim"]; label: str
    resolution: tuple[int, int]; fps: int
    live: bool                           # pre-session preview available (~15 fps)

class WorkcellStatus(BaseModel):         # GET /api/workcell
    kind: Literal["hardware", "sim"]
    available_kinds: list[Literal["hardware", "sim"]]
    arms: list[ArmStatusInfo]; cameras: list[CameraInfo]
    policies_available: bool = False     # enables DAgger/Inference launch (05-ui §8.1)

class SceneInfo(BaseModel):              # GET /api/scenes?kind=sim|twin
    scene_id: str; label: str; num_arms: int
    rail_flags: list[bool]; cameras: list[str]
    kind: Literal["sim", "twin"]

class ProfileInfo(BaseModel):            # GET /api/profiles rows (full posture via
    profile_id: str; name: str           #   GET /api/profiles/{id} -> StateProfile)
    arms: list[str]; notes: str; created_at: str
    is_initial_condition: bool

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
`arms`; each value `parse_frame()`s and is not `ee:`; collect/dagger ⇒ `task`.

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

KEYMAP: tuple[KeymapEntry, ...]          # exactly these 23 entries:
# held/translate: KeyW translate_x_pos "+x (forward)" | KeyS translate_x_neg "-x (back)"
#                 KeyA translate_y_pos "left" | KeyD translate_y_neg "right"
#                 KeyE translate_z_pos "up"   | KeyQ translate_z_neg "down"
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
# discrete/episode: KeyN episode_new | Enter episode_save | Backspace episode_discard

HELD_CODES: frozenset[str]; DISCRETE_CODES: dict[str, str]   # derived views
HELD_MODIFIER_ACTIONS: frozenset[str] = frozenset({"tracker_clutch"})
    # held actions that are NOT axes: excluded from axis_map(); runtime's
    # held_to_twist ignores them (13-tracker §3.3)
def axis_map() -> dict[str, tuple[str, float]]
    # held axis action -> (axis, sign), e.g. "translate_x_pos" -> ("x", +1.0);
    # single source of signs for runtime's held_to_twist
```

Invariants (tested §18): 23 entries (6 translate + 6 rotate + 2 gripper +
2 rail + 1 tracker + 3 session + 3 episode — matches spine §5), unique codes;
every discrete `action` is a valid `ActionName`; exactly the rail entries have
`requires_rail=True`; every held action is either an axis (in `axis_map()`,
with a ± partner on the same axis) or a member of `HELD_MODIFIER_ACTIONS`,
never both; exactly the seven 13-tracker §1 rows carry a `gamepad` label; no
browser-owned chords. Episode keys are always listed; runtime nacks them in
modes without a recorder.

## 14. JSON-schema export for TS generation (`protocol/export_schemas.py`)

UI pipeline (05-ui §2): core exports JSON Schema → UI `pnpm gen:sync` copies
`../apollo-xarm7-core/schemas/*.json` → `json-schema-to-typescript` emits
`src/gen/*.ts`. Root `schemas/` is checked in, regenerated in CI.

```python
EXPORTED_MODELS: dict[str, type[BaseModel]] = {
  # control:  HelloMsg, KeysMsg, ActionMsg, AckMsg, JointTargetArgs,
  #           SaveProfileArgs, SetInitialConditionArgs, TrackerSettingsArgs
  # telemetry: TelemetryMsg (embeds ArmTelemetry/CollisionReport/EpisodeStatus/
  #           DaggerStatus/TrainerStatus/InferenceStatus/TrackerTelemetry/ControllerTelemetry/
  #           TrackerCalibrationStatus/LighthouseStatus/CalibrationValidation/YawGesturePoint
  #           via $defs)
  # tracker:  TrackerCalibrationStatus, TrackerCalibrationCommand (REST
  #           /api/tracker/calibration; the other protocol.tracker models ride $defs only)
  # session:  SessionSpec, SessionInfo, WorkcellStatus, ArmStatusInfo,
  #           CameraInfo, SceneInfo, ProfileInfo, PolicyInfo
  # misc:     StateProfile, KeymapEntry, CollisionEvent
}
def export(out_dir: Path) -> list[Path]
    # one <Name>.json via model_json_schema(ref_template="#/$defs/{model}"),
    # draft 2020-12; json.dumps(sort_keys=True, indent=2) + trailing newline
    # => byte-deterministic. Also writes keymap.json (the KEYMAP table) and
    # index.json (exported names + core __version__).
def main(argv: list[str] | None = None) -> int
# CLI: python -m apollo_xarm7_core.protocol.export_schemas --out schemas/
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
class GripperInitError(BringupError): ...
class CameraInitError(BringupError): ...
class WorkcellBringupError(ApolloError):
    statuses: dict[str, BringupError | None]     # per-arm/camera (landing page)
```

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
name = "apollo-xarm7-core"
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
`uv run python -m apollo_xarm7_core.protocol.export_schemas --out schemas/`.
Siblings use an editable path dep in dev (`uv add --editable
../apollo-xarm7-core`), pin `apollo-xarm7-core==x.y.*` when published.
CI order: ruff → pytest → schema `--check`.

## 18. Test strategy (hardware-free)

All of core tests with no robot, no MuJoCo, no network.

- **Import guard**: subprocess imports `apollo_xarm7_core` (+ `.protocol`,
  `.dagger.types`), prints `sorted(sys.modules)`; assert intersection with
  `{mujoco, xarm, fastapi, torch, lerobot, cv2, mink, zmq, websockets}` is
  empty and import time < 500 ms.
- **SE3** (hypothesis): quat↔mat/rpy/rotvec round trips; canonical `w >= 0`
  after every op; `pose_mul(a, pose_inv(a)) ≈ id`; `integrate_twist` vs finite
  differences; slerp endpoints; leash clamp bounded + idempotent.
- **State**: shape/dtype rejection; `q[7] == rail_pos_m` when rail present;
  GripperCommand range checks.
- **Config**: YAML fixtures (1/2/3-arm hardware + sim) load; one failing
  fixture per cross-field validator; errors carry file + loc.
- **ProfileStore** (`tmp_path`): CRUD round trip; atomic overwrite (fault
  injected before `os.replace` leaves the old file intact); `set_initial`
  uniqueness incl. crash-ordering (target-last ⇒ never two flags);
  delete-initial refusal; foreign-file tolerance.
- **Protocol**: every wire model round-trips `model_dump_json →
  model_validate_json`; discriminated-union parse of a mixed control
  transcript; the literal JSON fixtures of 04-runtime §13.2 parse;
  `JointTargetArgs` / `SessionSpec.start_from` accept/reject tables.
- **Keymap**: §13 invariants + literal table equality against spine §5 — any
  keymap edit is a conscious spine change.
- **Video**: pack/unpack round trip; `struct.calcsize("<dI") == 12`;
  truncation/mismatch errors; reserved-id predicate.
- **Schema export**: export twice → byte-identical; `--check` vs checked-in
  `schemas/` (drift fails CI); no numpy leakage.
- **Bus**: N producer threads × 1 drainer — every Future resolves exactly
  once, corr_ids match; bus-full immediate nack; handler exception →
  ok=False; `LatestSlot` overwrite + `wait_fresh` timeout semantics.
- **`apollo_xarm7_core.testing`**: `FakeArm`/`FakeCamera`/`FakeWorkcell` —
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

No spine concerns: this document implements `00-overview.md` v0.3 as written.
