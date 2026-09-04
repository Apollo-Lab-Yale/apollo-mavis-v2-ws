# Phase 01 — apollo-mavis-v2-core：接口、schema、协议（完整实现 + 测试）

## 目标

完整实现 `apollo-mavis-v2-core` 仓库：栈内所有共享类型（几何/SE3、配置、状态、命令）、
抽象接口（arm/camera/workcell/IK/twin/policy/recorder/teleop）、runtime↔UI 协议的
pydantic 模型、canonical keymap、DAgger 协议类型、`CommandBus`/`LatestSlot` 并发原语，
以及 JSON Schema 导出管线。
core 是整个栈的契约层，本 phase 结束后其公共 API 视为冻结（后续 phase 只允许加法式变更）。

## 前置条件

- 依赖 phase：无（这是第一个 phase）。
- 必读设计文档（按序）：
  - `docs/design/00-overview.md`（全文，尤其 §1 依赖规则、§3 domain model、§5 keymap、§8 协议）
  - `docs/design/01-core.md`（包布局与完整接口/schema 签名 — 事实来源）
  - `docs/design/10-frames-and-data.md`（FrameRef 约定、legacy flange/180°-about-X 兼容映射、数据集 feature 命名）
  - `docs/design/12-dagger-protocol.md`（core 侧 dagger 类型与 Protocol 定义）
- 参考：`docs/research/dagger-online-training.md` §4.4（core/runtime 切分的类型清单）。

## 范围

包内（Python 包名 `apollo_mavis_v2_core`，仓库 `apollo-mavis-v2-core/`，`uv` 管理）：

- **几何**（`types.py`/`se3.py`）：`Pose{position: vec3, orientation: quat}`、
  `Transform`（SE3 别名）、`Twist{v, w, rail_v, grip_v}` 及 `quat_*`/`pose_*`/
  `integrate_twist`/`clamp_pose_to_leash` 工具。内部单位：米、弧度；四元数
  `(w, x, y, z)`（MuJoCo 序，规范化且 `w >= 0`）。`FrameRef`：`world` |
  `arm_base:<arm_id>` | `camera:<camera_id>` | `ee:<arm_id>`，`parse_frame/frame_ref`。
  常量：`TCP_OFFSET_M = 0.172`、`LEGACY_FLANGE_QUAT_OFFSET = (0,1,0,0)`、
  `RAIL_TRAVEL_M = 0.65`。
- **状态**（`state.py`）：`ArmState{q, dq, ee_pose, gripper, rail_pos_m, error_code,
  warn_code, mode, state, stale, t_mono, wallclock_ns}` — `q` 为 `(7,)` 或 `(8,)`，
  **rail 恒在末位 `q[7]`（米）**；`GripperState{open_frac, moving?, grasped?, current?}`、
  `GripperCommand{open_frac: [0,1], force?, speed?}`（force 仅 xarm_g2 生效）、`CameraFrame`。
- **配置**（`schemas/config.py`、`schemas/safety.py`）：`WorkcellConfig`（kind:
  hardware|sim）、`ArmConfig{id, ip?, base_in_world, expect_rail: auto|yes|no,
  gripper: xarm|xarm_g2|none, tcp_load_kg, tcp_load_cog_mm}`、`CameraConfig{id, kind:
  v4l2|realsense|sim, device_path/serial, resolution, fps, intrinsics?,
  extrinsics_frame?, extrinsics_file?}`、`sim_scene?`、`digital_twin_scene?`、
  `SafetyConfig{enabled, safety_debug, geom_inflation_m: 0.008 默认（pair 总量 δ，
  每 geom δ/2）, min_clearance_m, warn_clearance_m: 0.025, hysteresis_m: 0.002,
  max_active_constraint_rows: 12, twin_staleness_s: 0.15, input_deadman_s: 0.2,
  input_ramp_s: 0.1, ...}`；`load_workcell_config`（YAML）+ 全部交叉字段校验
  （hardware ⇒ 每臂有 ip 且 `digital_twin_scene` 且 `safety.enabled`；sim ⇒ `sim_scene`）。
- **接口**（`apollo_mavis_v2_core.interfaces`，按 01-core.md §5 的签名）：`ArmInterface`
  （`connect/disconnect`、`get_state() -> ArmState`、`command_joints(q)`（len==dof，
  rail 在 `q[7]`）、`command_gripper(GripperCommand)`、`command_rail(pos_m)`
  （0–0.65 m 绝对值）、`clear_errors()`、`stop()`；属性 `dof`/`has_rail`/
  `gripper_force_capable`）、`CameraInterface`（`start/stop`、`latest() ->
  CameraFrame | None`）、`WorkcellInterface`、`IKSolver`（Protocol：`solve(arm_id,
  target, q_seed) -> IKResult{q, pos_err_m, rot_err_rad, diverged,
  active_collision_rows, solve_time_s}` + `solve_to_convergence`/`sync_passive`/
  `reset`）、`DigitalTwinInterface`（`sync/check/check_config/clearance/plan/render/
  set_grasp_whitelist`，`PairClearance`）、`Policy`（`reset/act/load_weights` +
  `PolicySpec{action_space: "delta_ee"|"abs_ee"|"joint", action_frame: 完整 FrameRef,
  action_names, state_names, camera_keys, version}`）、`EpisodeRecorder`
  （`start/add_frame/save/discard/finalize`）、`TeleopInput`（`HeldState{held, seq, rx_mono}`）。
- **StateProfile**（`schemas/profile.py`、`profiles/store.py`）：`ArmPosture{q: 7 floats
  （**绝不含 rail 槽位**）, rail_pos_m?, gripper_open_frac}`、`StateProfile{schema_version,
  profile_id, name, notes, workcell_kind, arms, created_at, is_initial_condition}`；
  `ProfileStore`：每 profile 一个 `<id>.json`，原子写（`.tmp` + `os.replace`），
  `set_initial` 保证同 kind 至多一个 initial（目标最后写入），拒绝删除 initial。
- **协议**（`apollo_mavis_v2_core.protocol`）：control（`HelloMsg{epoch, session_id,
  role: "controller"|"observer"}`、`KeysMsg{seq, ts, held}`、`ActionMsg{name, args}`、
  `AckMsg`、`JointTargetArgs{arm_id, positions（完整 q 含 rail 槽）, mode:
  "jog"|"goto"}`、`SaveProfileArgs`、`SetInitialConditionArgs{profile_id?}`）；
  telemetry（`TelemetryMsg/ArmTelemetry/ClearanceItem/EpisodeStatus/DaggerStatus/
  InferenceStatus/SessionTelemetry` + `CollisionReport/CollisionEvent`（schemas/safety.py））；
  session/REST（`SessionSpec{mode, kind, arms, frames, start_from: keep_current|
  profile:<id>, task?, policy?}`、`SessionInfo/WorkcellStatus/ArmStatusInfo/CameraInfo/
  SceneInfo/ProfileInfo/PolicyInfo`）；video（`pack_frame/unpack_header`，12 字节
  `<dI` 头 + JPEG，保留流 id `sim`/`twin`）；字段与 `docs/design/05-ui.md` §2 的 TS
  形状严格一致。`core.protocol.keymap`（overview §5 的 canonical 表，**恰好 25 条**：
  W/S、A/D、E/Q 平移，I/K roll、J/L pitch、U/O yaw、F/H gripper、←/→ rail
  （`requires_rail: true`）、Tab/Space/N/Enter/Backspace discrete；每条含
  `code/action/kind/label/group/requires_rail`；派生 `HELD_CODES/DISCRETE_CODES/axis_map()`）。
- **DAgger 类型**（`apollo_mavis_v2_core.dagger`）：`ControlMode{policy|human|
  takeover_transition}`（`to_int8()` → 0/1/2）、`GateEvent`、`FrameAnnotations{control_mode,
  executed_action, policy_action, policy_version, action_frame: 完整 FrameRef
  （`arm_base:<id>`|`world`|`camera:<id>`）}`、`CheckpointInfo`、`EpisodeSummary`、
  `TrainerStatus`；Protocol：`TakeoverGate`（`on_toggle/tick/reset/engaged_arm`）、
  `InterventionRecorder`、`PolicyReloader`、`AsyncTrainerClient`。
- **总线与并发原语**（`bus.py`）：`Command/CommandResult`、`CommandBus`
  （`submit(cmd) -> Future`，MPSC，单消费者 `drain`，队满立即 nack）、`LatestSlot`
  （深度 1 最新值槽，`put/get/wait_fresh`）— runtime 的 Dora 迁移接缝。
- **错误层级**（`errors.py`）与 **测试 fakes**（`testing.py`：`FakeArm/FakeCamera/
  FakeWorkcell`，全栈复用的唯一 fake 集）。
- **Schema 导出**：`python -m apollo_mavis_v2_core.protocol.export_schemas --out schemas/
  [--check]`，用 pydantic `model_json_schema()` 输出 draft 2020-12 JSON Schema 至仓内
  `schemas/`（每个导出模型一个 `<Name>.json` + `keymap.json` + `index.json`，
  `sort_keys` + 定长缩进保证字节级确定），文件入库；`--check` 在再生成有 diff 时退出 1。
- **Legacy 兼容**：`10-frames-and-data.md` §4 规定的映射工具（TCP site 在 link7 法兰后
  0.172 m；旧 xarm7-ik 目标为 flange 且隐含 180°-about-X 偏移，即
  `quat_offset = (0,1,0,0)` 预乘；关节序 `[rail, j1..j7]` → `[j1..j7, rail]`（rail 移到
  末位）；rail 上界 0.74 → `RAIL_TRAVEL_M = 0.65`）。

Out of scope：任何 MuJoCo / xArm SDK / FastAPI / lerobot / torch 依赖（core 只允许
numpy + pydantic v2 + PyYAML）；接口的具体实现；网络 I/O（除 ProfileStore/YAML/schema
导出的文件 I/O）；UI 类型生成（属 phase-06）。

## 交付物

- `apollo-mavis-v2-core/pyproject.toml`（`uv` 可安装，依赖仅 numpy + pydantic v2 + PyYAML，
  Python ≥3.10，ruff banned-imports 把依赖规则做成 lint）。
- `src/apollo_mavis_v2_core/`：`types.py se3.py state.py errors.py bus.py testing.py` +
  `interfaces/{arm,camera,workcell,ik,safety,policy,recorder,teleop}.py` +
  `schemas/{config,safety,profile}.py` + `profiles/store.py` + `dagger/{types,interfaces}.py` +
  `protocol/{control,telemetry,session,video,keymap,export_schemas}.py`（01-core.md §2 布局）。
- `schemas/*.json`（已生成并入库）+ `py.typed`。
- `tests/`：pytest 全覆盖（01-core.md §18）— import guard（子进程导入，禁 mujoco/xarm/
  fastapi/torch/lerobot/cv2/mink/zmq/websockets，导入 <500 ms）、SE3 往返/组合/求逆
  （hypothesis）、四元数 wxyz 序 + `w >= 0` 规范化、FrameRef 解析、`q[7] == rail_pos_m`、
  config 校验（每个交叉校验一个失败 fixture）、ProfileStore 原子写/`set_initial` 唯一性、
  keymap 25 条不变量 + 与 overview §5 字面相等、协议模型 round-trip +
  `JointTargetArgs`/`SessionSpec.start_from` 接受/拒绝表、video 打包往返、
  `CommandBus`/`LatestSlot` 并发语义、schema 导出幂等、legacy flange 映射数值用例、
  StateProfile 序列化版本兼容。
- 仓库 `README.md`（英文，简述包结构与契约角色）。

## 验收标准

在 `apollo-mavis-v2-core/` 内逐条执行：

- [ ] `uv sync && uv run python -c "import apollo_mavis_v2_core"` 成功。
- [ ] `uv run python -c "import apollo_mavis_v2_core, sys; assert not any(m.startswith(('mujoco','xarm','fastapi','lerobot','torch','cv2','mink','zmq','websockets')) for m in sys.modules)"`
      — 导入 core 不得拉入任何栈内重依赖。
- [ ] `uv run pytest` 全绿；测试数 ≥30。
- [ ] `uv run python -m apollo_mavis_v2_core.protocol.export_schemas --out schemas/ --check`
      退出码 0，且 `git diff --exit-code schemas/` — 导出幂等，schema 与代码不漂移。
- [ ] keymap 测试断言：恰好 25 条、code 唯一；`ArrowLeft/ArrowRight` 的
      `requires_rail == true`；Tab/Space/KeyN/Enter/Backspace 的 `kind == "discrete"`
      且 action 均为合法 `ActionName`；其余运动键 `kind == "held"`；W/S=translate ±x、
      I/K=roll、J/L=pitch、U/O=yaw（IJKL 决议，见 overview §5 注）。
- [ ] 几何测试断言：`Pose` 四元数为 `(w,x,y,z)` 序（对 90° 绕 Z 旋转给出
      `(0.7071, 0, 0, 0.7071)`）；legacy 映射测试：identity 用户四元数经 180°-about-X
      偏移后 gripper 朝下，flange↔TCP 平移差 0.172 m。
- [ ] `GripperCommand.open_frac` 校验拒绝 `[0,1]` 之外的值；`command_rail` 文档标注
      0–0.65 m（`RAIL_TRAVEL_M`）；`ArmState` 测试断言 8-DoF 时 `q[7] == rail_pos_m`。
- [ ] `SessionSpec` 校验：`start_from` 只接受 `keep_current` / `profile:<id>`；
      `frames` 值拒绝 `ee:<id>`；collect/dagger 模式要求 `task`。
- [ ] mypy（或 pyright）通过：接口全部带类型注解，`py.typed` 存在。

## 注意事项

- 四元数序是全栈第一坑：MuJoCo/内部为 **wxyz**，scipy 为 xyzw，xArm SDK 用 RPY/轴角。
  core 层只承认 wxyz，序转换只有 `xyzw_to_wxyz`/`wxyz_to_xyzw` 两个获准函数
  （01-core §3），并有测试钉死。
- keymap 决议已定案：用户原始 spec 中 K 同时映射 roll 和 pitch，最终决议为
  I/K = roll、J/L = pitch — 不要"更正"回去。
- 协议字段名必须与 `05-ui.md` §2 中的 TS 形状逐字段一致（如 `rail_pos_m: number | null`、
  `min_clearance_m`、`severity: "ok"|"warn"|"blocked"`、`control_mode` 三态），UI 的类型
  是从这里的 JSON Schema 生成的，任何命名不一致都会在 phase-06 的 `gen:check` 炸出来。
- `TelemetryMsg`/`KeysMsg` 须含 `seq` 单调递增字段（服务端丢弃乱序），`HelloMsg` 须含
  `epoch` 与 `role: "controller"|"observer"`。`takeover_toggle` 是**无参** discrete
  action（永远作用于服务端权威 active arm），绝不出现在 `KeysMsg.held` 里。
- 数据集相关常量（feature 名 `intervention`(bool)、`action_source`(int8, labels
  `{0: policy, 1: teleop, 2: joint_jog, 3: takeover, 4: planner}` — 镜像
  `CommandSource` 字符串值；2/4 保留、绝不出现在录制帧里）、`wallclock_ns`(int64)、
  feature 名禁止含 `/`）在 core 定义为常量/枚举，phase-07 直接引用。
- pydantic v2 的 `model_json_schema()` 输出受版本影响，锁 pydantic 小版本，否则
  schemas/ 的幂等验收会随环境漂移。
- 不要在 core 里放"方便函数"级别的 MuJoCo/SDK 胶水 — 那是 hardware/sim 的事；
  core 被两边同时依赖，任何泄漏都会破坏 §1 的硬规则。
