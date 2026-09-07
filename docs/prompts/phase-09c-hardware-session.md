# Phase-09c — 真机 session bring-up（导轨归零门禁、相机接管、限速、子集臂）

状态：设计定稿 2026-09-05。本文件是 core / hardware / runtime / ui / docs 五层实现的**唯一契约**，是
`phase-09-integration.md` 里"代码部分"的落地；真机验收步骤见文末，需要用户在场。建立在 phase-09a
（只读监视器、叠加窗口）与 phase-09b（维护通道、故障状态机、安全参数）之上，二者均已提交。
代码级锚点见 `~/apollo/logs/phase-09c-map.md`（实现前必读）。

> **phase-09d 修订（2026-09-05，`phase-09d-rail-homing-planning.md`，已实现）**：(1) **两臂永远都在真机 session
> 里**——UI 的 "Include in session" 开关与 `hardware_session.default_arms` 已移除，`SessionSpec.arms` 必须等于硬件
> workcell 的全部臂（否则 409 "hardware sessions include every configured arm"）；本文用户规则 2 的"只用
> Manipulation Arm"与文末真机验收步骤 4 的"Include in session 只勾 Manipulation Arm"不再适用：两臂都连、10% 限速，
> 默认 active 臂仍是 Manipulation Arm，Perception Arm 的 C19 须先清掉（拒绝矩阵对已锁存错误 409）。(2) **D1（未选中
> 臂按最后一次样本冻结）只保留给维护运动**——`RailHomingJob` 归零一臂时冻结另一臂；teleop session 不再有未选中臂。
> (0) **armed 开关（2026-09-05 事件后加）**：`hardware_session.armed` 为 true 时 runtime 才会连接真实驱动 /
> 归零导轨；仓库配置默认 false，只有 lab 渲染配置置 true。
> (3) `home_rail` 在当前姿态扫掠不通过时**不再直接拒绝**：dry-run 同时用孪生规划一条与导轨位置无关的路径
> （`RailSweepVerdict.pre_position`），操作员确认后 REST 202 + `job_id`，job 只连该臂、门禁下以 10% 折叠、
> `XArmDriver.home_rail()` 归零、拆除时抱闸**保持折叠姿态**。其余（D2–D6、监视器交接、相机接管、寄存器判定）不变。

## 用户规则（binding）

1. **没有任何隐式运动。** 导轨归零（`set_linear_track_back_origin`，滑台开到归零端）只能由操作员在 UI 上
   显式触发（维护操作 `home_rail`），并且必须先由数字孪生确认：以该臂**当前**关节姿态、对另一臂当前姿态，
   整段行程 0–0.65 m 的导轨扫掠无碰撞，否则拒绝（零写入）。真机 session 在任一所选臂的导轨未归零时拒绝启动
   （位置未知 → 孪生无法门禁）。
2. **第一次真机运行只用 Manipulation Arm、大幅限速。** `SessionSpec.arms` 已支持子集；新增 `speed_scale`。
3. 驱动连接前必须先同步暂停监视器（释放控制盒连接），session 结束后恢复。
4. 预览已打开的两路 `OpenCVCamera` 由 session **接管**，不重新打开 UVC 节点。
5. 末端负载按 0.95 / 0.55 kg（用户 2026-09-05 决定，不称重）。

## 决策（主代理代用户定，实现按此执行）

- **D1 未选中的臂**：所有监视器一起暂停（沿用现有整体 pause）；未选中臂在门禁孪生里按其**最后一次**监视样本
  （q7 + 导轨位置或 `rail_fallback_m`）摆一次并冻结；telemetry 记录 "Perception Arm frozen at last sample"；
  该臂抱闸、未使能，物理上不会动；操作员在 session 中不得用 Studio 动它（UI 提示）。
- **D2 限速**：`SessionSpec.speed_scale: float = Field(1.0, gt=0, le=1)`；Hardware 页签提供 10% / 30% / 100%
  分段控件，**默认 10%**。主机侧：`teleop.linear_mps/angular_rps/rail_mps`、`target_rate.v_mps/w_radps`、
  `dq_max_rad`、`jog.slew_rad_per_tick/rail_m_per_tick` 乘以 scale。驱动侧（经 `driver_factory` 闭包）：
  `servo.max_joint_vel`、`max_cart_step_m`、`rail_speed_mm_s` 乘以 scale；hardware 在 scale 1.0 的上限改为
  `max_joint_vel 0.3 rad/s`、`max_cart_step_m 0.002`（0.2 m/s）、`rail_speed_mm_s 50`（2026-09-07 首次真机后
  按操作者反馈上调为 0.6 rad/s / 0.004 = 0.4 m/s，导轨不变；4 mm/tick 刻意保持为门禁 8 mm 膨胀的一半）。`SessionInfo`/telemetry
  回显 `speed_scale`。
- **D3 `home_rail` REST**：同步 POST，服务端超时 45 s，UI 显示进行中；REST 处理器对该 op 用长超时。
- **D4 扫掠余量**：归零扫掠用 `inflation 0.025 m`（起点未知的盲扫，取 guardrail 的调试余量），步长 5 mm
  （131 步）；门禁孪生自身仍用 `safety.geom_inflation_m`。
- **D5 进度遥测**：做。`SessionInfo.kind`、`SessionInfo.speed_scale`、`SessionTelemetry.bringup:
  list[ArmBringupTelemetry] | None`（arm_id、step、status、detail），`GET /api/session` 在 bring-up 期间已可返回
  `state: bringup`。
- **D6 拆除时使能状态**：`XArmDriver.disconnect()` 末尾 `set_state(4)` + `motion_enable(False)`，把臂交还为
  上电后的"停止、抱闸"状态；导轨保持归零标志（不再需要归零），`set_linear_track_enable(False)` 不调。
- **未选中臂的监视器暂停期间若有人用 Studio 移动它**：本阶段不检测；写进 UI 提示与 02-hardware 风险。
- **`rail_flip`**：把 `twin_overlay.rail_flip` 提升为 `hardware.rail_flip`（runtime 配置，默认 false），叠加与门禁
  孪生共用；`twin.sync` 前对导轨位置应用同一变换。归零后先看叠加窗口再开 session。

## 范围

### 1. core（additive）

- `protocol/maintenance.py`：`ArmMaintenanceOp` += `"home_rail"`；`ArmMaintenanceRequest.dry_run: bool = False`
  （dry-run = 只做扫掠判定，零写入）；新模型
  ```python
  class RailSweepVerdict(BaseModel):
      scene_id: str; inflation_m: float; step_m: float; travel_m: float = 0.65
      clear: bool
      first_blocked_m: float | None = None; first_blocked_pair: list[str] = []
      min_clearance_m: float | None = None; min_clearance_at_m: float | None = None; min_clearance_pair: list[str] = []
      q_checked: list[float] = []            # the 7 joints the sweep assumed (must match at execution)
      other_arms: dict[str, list[float]] = {} # arm_id -> q7 + rail used for the other arm(s)
      assumptions: list[str] = []            # e.g. "view rail unknown - used fallback 0.00 m"
      sample_seq: int = 0
  ArmMaintenanceResult.rail_sweep: RailSweepVerdict | None = None
  ```
  文档字符串改为 "`home_rail` is the ONE motion op: operator-triggered, twin-gated, session-less"。
- `protocol/session.py`：`SessionSpec.speed_scale: float = Field(1.0, gt=0, le=1)`；`SessionInfo.kind`、
  `SessionInfo.speed_scale`（additive）；`SessionState` 已有 `bringup`。
- `protocol/telemetry.py`：`ArmBringupTelemetry(arm_id, step: str, status: Literal["pending","ok","warning","error"],
  detail: str = "")`；`SessionTelemetry.bringup: list[ArmBringupTelemetry] | None = None`。
- `errors.py`：`RailNotHomedError(BringupError, step="rail")`。
- `ArmBringupStatus.rail` 字面量加 `"unhomed"`（若该模型在 core；否则在 hardware）。
- `EXPORTED_MODELS` 不变（`RailSweepVerdict` 经 `$defs`）；schemas、`__init__`、测试同步。

### 2. hardware

- **连接永不归零**：`RailController.ensure_homed()` → `require_homed()`：读 `get_linear_track_registers`，
  `on_zero == 0` → 抛 `RailNotHomedError`（`_bring_up_arm` 映射为 `status.rail = "unhomed"`，session 拒绝）；
  `on_zero == 1` → `set_linear_track_enable(True)` + `set_linear_track_speed(cfg.rail_speed_mm_s)`（非运动）并
  用寄存器值**播种 `pos_m`**（否则第一个 5 Hz 周期前门禁孪生会看到滑台在 0）。`RailPhase.HOMING` 从驱动路径移除。
- `XArmDriverConfig`：hardware 上限改为 D2 的数值；`disconnect()` 按 D6。
- `monitor.py` 新 op `home_rail`（轮询线程执行）：`MAINTENANCE_SDK_METHODS["home_rail"] =
  {set_linear_track_back_origin, set_linear_track_enable, set_linear_track_speed}`（不含 `motion_enable`）；
  请求携带 `expected_q`（扫掠时的姿态）与 `q_tol_rad = 0.02`：执行前取样，`q` 偏离或 `error_code != 0` →
  拒绝、零写入；否则 `set_linear_track_back_origin(wait=True, timeout=30, auto_enable=False)` →
  `set_linear_track_enable(True)` → `set_linear_track_speed(cfg.rail_speed_mm_s)` → 取样；**判定只看寄存器**
  （`on_zero == 1 and is_enabled == 1 and error == 0`），不信返回码（SDK 1.18.5 在 `auto_enable=True` 时会用
  enable 的返回码覆盖等待结果）。`HOME_RAIL_TIMEOUT_S = 45`；`_shutdown` 对进行中的 `home_rail` 等待到完成
  （上限 45 s）再释放连接，绝不在归零中途断开。归零期间该臂 status `stale`、`maintenance_busy` true（文档写明）。
- `FakeXArmAPI`：`homing_duration_s`（阻塞、尊重 timeout 与 `connected`）、`homing_result_code`、
  `auto_enable` 覆盖返回码的行为、`inject_track_error`、`rail_homed` 可设。
- `HardwareWorkcell`：只为 `cfg.arms` 里的臂建驱动（子集配置天然满足）；`ArmBringupStatus.rail == "unhomed"`；
  `bring_up` docstring 更新。
- 测试：连接未归零 → `RailNotHomedError` 且从未调用 `set_linear_track_back_origin`；已归零 → enable + speed +
  `pos_m` 播种；`home_rail` 写集合精确、姿态不符拒绝、`auto_enable=False`、仅按寄存器判定、归零中 hand-over 等待；
  `disconnect()` 的 `set_state(4)` + `motion_enable(False)`。

### 3. runtime

- **谓词修正（先做）**：`SessionManager` 在 `create()` 一开始记录 `_creating_kind`；
  `Runtime._hardware_session_active` = `manager.session_active and (creating_kind or session.spec.kind) == "hardware"`，
  否则监视器的 0.5 s 巡检会在 bring-up 中途重连控制盒。
- `config.py`：`HardwareSessionConfig(default_arms: list[str] = ["grip"], default_speed_scale: float = 0.1,
  rail_flip: bool = False, home_rail_inflation_m: float = 0.025, home_rail_step_m: float = 0.005,
  bringup_timeout_s: float = 60.0)` → `RuntimeConfig.hardware_session`；`twin_overlay.rail_flip` 改为读
  `hardware_session.rail_flip`（保留旧键作别名一版）。`configs/mavis_v2.yaml` 加块；`tracker.backend` 注释指明
  真机运行用 live 配置里的 libsurvive。
- `devices/rail_sweep.py`：`RailSweepChecker(workcell_cfg, twin_scene, inflation_m, step_m)`，懒建一个专用
  `DigitalTwin`（`SceneOverrides(microphones, base_pose)`，`inflation_m`），加锁；`check(arm_id, samples,
  rail_fallback_m) -> RailSweepVerdict`：其他臂按样本 q7 + 导轨位置（None → fallback，记 assumption，应用
  `rail_flip`）；目标臂 q7 = 样本；对 `s in linspace(0, 0.65, 131)`：`check_config_violations`，记录首个阻塞
  与最小间隙（`pair_distance`）。单测：keyframe 姿态 clear；把 grip 臂工具压到桌面以下 → 阻塞对含 `table`；
  另一臂导轨 None → assumptions；步数 131。
- `devices/hardware_monitor.py`：`maintenance(arm_id, op="home_rail", dry_run)`：先 `RailSweepChecker.check`，
  `dry_run` 或 verdict 不 clear → 直接返回（`ok = clear and dry_run`，携带 verdict，零写入）；clear 且非 dry-run →
  `mon.maintenance("home_rail", cfg, expected_q=sample.q, timeout_s=45)`，结果附 verdict。
- `server/rest.py`：`home_rail` 在有真机 session 时 409 "end the session first"；REST 对 `home_rail` 用 45 s；
  任一臂 `maintenance_busy` 时 `POST /api/session` 409 "rail homing in progress"。
- **`_bringup_hardware`**（镜像 `_bringup_sim`，顺序与锚点见 map §1）：校验（§3 拒绝矩阵）→ 监视器 `pause()` +
  每臂 `join(15)`（仍活着 → 409）→ 子集 `WorkcellConfig`（`cameras: []`）→ `HardwareWorkcell(session_cfg,
  driver_factory=限速闭包, netsetup=None)` → `bring_up(status_cb, timeout)`（进度进 `SessionTelemetry.bringup`）；
  任一臂 error → 拆除 + 409（detail 含臂名与步骤）→ 一致性断言（`driver.dof == twin dof`，首个状态非 stale）
  → **新建**门禁孪生 `DigitalTwin(REGISTRY.build(twin_scene, SceneOverrides(microphones, base_pose)), inflation,
  allowed_pairs_extra)` → **无条件** `SafetyGate` + `default_collision_pairs`（否则 `SafetyConfigError`）→
  未选中臂按 D1 摆位冻结 → `MinkIKSolver`（`lock_rail=not control.rail_in_ik`）、`SceneKinematics`、
  `SafetySupervisor(twin, ArmReportWatchdog)` → `ControlLoop(workcell_kind="hardware", gripper_arms 按 ArmConfig,
  scaled control cfg)` → `loop.start()` → `ActiveSession(kind hardware, speed_scale, adopted_streams)` →
  相机接管：对 `_hw_cameras` 每路 `hub.set_fps(cam_id, video.session_fps)`，id 记入 `adopted_streams`
  （不进 `session.streams`，拆除不删）；叠加流继续存在但监视器已暂停 → 叠加改从 `workcell.states()` 取
  session 臂的状态（`frame/state provider` 切换），未选中臂用冻结姿态。`rail_flip` 在 `twin.sync` 前应用。
- 拆除（镜像 sim）：loop.stop → 流 → `workcell.stop()`（驱动 D6）→ 接管相机 `set_fps(preview_fps)` →
  `session = None` → `hardware_monitor.resume()`；每条失败路径同样恢复。**不得**让 `HardwareWorkcell.shutdown()`
  碰相机。
- Recorder / DAgger 在真机上的适配不在本阶段（只做 teleop）；`spec.mode != teleop` 且 kind hardware → 409
  "hardware sessions support teleop only (phase-09c)"。
- 测试：`tests/test_hardware_session.py`（`workcell_factory` seam + EventFakeWorkcell 8-dof 臂 + FakeMonitor）：
  调用顺序（pause/join → bring_up → … → stop → resume；巡检不会在 bring-up 中重连）、相机接管（hub id 不变、
  fps 切换与恢复、`hardware_camera()` 同一对象）、门禁是 `SafetyGate`、`speed_scale 0.1` 的主机与驱动侧数值、
  失败路径恢复、§3 409 矩阵逐条 detail；`test_rail_sweep.py`；`test_maintenance_api.py` 的 `home_rail`
  从 422 改为 200(dry-run)/409(session)/409(busy)；改写 `test_hardware_workcell_api.py:218-224` 的 409 钉子；
  可选：把 `FakeXArmAPI` 作为 `apollo_mavis_v2_hardware.testing` 发布，让 runtime 用真 `HardwareWorkcell +
  XArmDriver` 跑一遍 POST /api/session（unhomed → 409 → home_rail → 启动）。

### 4. ui

- Hardware 页签臂卡片：`rail not homed` 琥珀药丸（`rail_present && !(rail_homed && rail_enabled)`），
  **Home rail** 按钮（可用条件：未归零、无 session、无 busy、`error_code == 0`）→ `HomeRailSheet`
  （基于 `Sheet`）：先 POST `dry_run: true`，显示判定（clear / 首个阻塞位置与碰撞对 / 最小间隙 / assumptions /
  "carriage drives to the operator's LEFT (+X) end at 50 mm/s"）；clear 时 `.btn-destructive` 确认 → POST 正式 op
  （长超时）→ toast。不 clear 时只显示原因，无确认按钮。
- 臂卡片新增 **Include in session** 开关（Hardware 页签），默认按 `hardware_session.default_arms`（grip）；
  不可选条件：未归零、`error_code != 0`、监视器非 running/stale（显示原因）。`LaunchSheet`/直接启动构造
  `SessionSpec.arms` 为选中集合。
- Hardware 页签 **Speed** 分段控件 10% / 30% / 100%（默认 10%）→ `SessionSpec.speed_scale`；Cockpit 头部显示
  当前 scale。
- 启动器原因：`REASON.railNotHomed = "Rail not homed — use Home rail on the arm card"`（对选中臂）、
  `REASON.homingInProgress`、`REASON.noArmsSelected`；`Data Collection / DAgger / Inference` 在 Hardware 页签
  显示 "Hardware sessions support teleop only for now"。
- Cockpit：bring-up 进度（`telemetry.session.bringup`）以列表显示直到 running；冻结臂提示
  "Perception Arm frozen at last sample — do not move it from Studio"。
- 测试与 `gen:*` 同步；`docs/design/05-ui.md` §8.1/§8.2/§9/§10/§12。

### 5. docs

- 本文件；`docs/prompts/README.md` 09c 行；`phase-09-integration.md` 步骤 2 改为"操作员触发归零"，验收
  "每次上电归零一次"改为 UI 触发；`phase-09-todo.md` B1。
- `02-hardware.md` §3.2/§5/§9/§10；`04-runtime.md` §5/§13.1/§13.3/§13.4/§15；`01-core.md` §12；
  `03-sim.md` §8 扫掠配方；`11-safety-collision.md` §4；`05-ui.md`；`CLAUDE.md` Hardware facts（归零是唯一
  的运动类维护操作、门禁化、D1–D6）。

### Out of scope

- 真机上的 collect / DAgger / inference；导轨归零速度寄存器（SDK 无公开 setter）；per-arm 监视器暂停；
  移动中的未选中臂检测；Reduced-mode 边界盒数值。

## 交付物

五层代码 + 测试 + 文档 + schemas / `src/gen`；`~/apollo/mavis_v2_live.yaml` 由主代理重渲染。不 commit。

## 验收标准

- 各仓库测试与 ruff / tsc / eslint / gen:check 全绿；`export_schemas --check` 通过。
- fake 全链路：unhomed → `POST /api/session kind=hardware` 409 "rail not homed"；`home_rail dry_run` 返回
  verdict；`home_rail` 后 session 启动到 running，`speed_scale` 生效，相机流 id 不变，拆除后监视器恢复。
- 真机（用户在场，急停在手边）：见下。

## 真机验收步骤（用户在场；每一步都可停）

> **2026-09-05 首次真机 session 的结果（已修，见 `docs/design/02-hardware.md` §14.4）**：两臂
> 归零 + bring-up 都成功，但随后两臂每 ~0.5 s 反复被latch成
> `CONTROLLER FAULT — external mode/state conflict persisted (UFACTORY Studio?)`，而**当时并没有开
> Studio**（18333 无人监听，两个控制箱的 502/30003 只有 runtime 一个客户端）。三个都是我们自己读错
> 控制器：(1) 保持姿态的 mode-1 臂报 **state 2**（standby，不是 0），旧检测器只接受 `{0,1}`；
> (2) `set_mode(1); set_state(0)` 返回后控制箱还没准备好收 `move_servoj`（回包 0x10 → APIState 9），
> 固定 `sleep(0.1)` 抢跑，第一个 servo tick 就把 Perception Arm 打成 FAULT；(3) `clean_error` 返回 2
> （WAR_CODE，状态回显）被当成失败，Clear errors 明明清掉了却报 FAILED。重跑本验收前先
> **重启 runtime** 让修复生效；第 6 步的 Clear errors 现在应报成功。

1. 重启 runtime，Hardware 页签两臂 running、err 0；叠加窗口正常。
2. Manipulation Arm 卡片 → **Home rail** → 看 dry-run 判定（应 clear；若不 clear，按提示先在 Studio 里把臂
   折叠到更紧的姿态，再试）→ 确认 → 滑台开到操作员**左**端归零 → 卡片显示 `rail 0.000 m`。
   **立刻看叠加窗口**：孪生导轨/基座应与真机重合；若镜像，改 `hardware_session.rail_flip: true` 重启再看。
3. Perception Arm 同样归零（其相机朝外，孪生里自己看不到；靠 Manipulation Arm 的叠加窗口看它的基座位置）。
4. Speed 10%，Include in session 只勾 Manipulation Arm → Teleop → 观察 bring-up 进度直到 running；
   Cockpit 显示 `speed 10%`；不握 clutch 时臂静止 10 s。
5. 握 clutch，缓慢移动控制器 5 cm，臂应同向、约 1/10 速度跟随；松开 clutch 停。
6. 试一次 Clear errors & resume（如有错误）；结束 session → 臂回到停止抱闸状态、监视器恢复、卡片正常。
7. 之后再考虑 30%、双臂、导轨跟随。

## 注意事项

- `home_rail` 是本仓库里**唯一**会让机械部件运动的维护操作；REST 处理器、UI 文案、日志都要写明。
- 门禁孪生、叠加孪生、扫掠孪生是三个独立实例（各自的 MjData 与线程）；`_twin_scene` 缓存不得用于门禁。
- 首次驱动连接是从未跑过的写序列（clean → backstops → motion_enable → mode 0 → mode 1 → 100 Hz 发流），
  连接失败必须完整拆除并恢复监视器，不能留下半连接。
- 显示名一律 "Manipulation Arm" / "Perception Arm"。
