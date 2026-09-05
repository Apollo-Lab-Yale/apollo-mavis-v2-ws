# Phase-09b — 控制器错误清除 / 恢复接口 + 控制器侧安全参数（phase-09 前置步骤）

状态：设计定稿 2026-09-04；同日五层实现完成（未 commit），真机验收待主代理现场执行（实现记录见文末）。
本文件是 core / hardware / runtime / ui / docs 五层实现的**唯一契约**；
设计文档随实现同步修订，冲突时以修订后的设计文档为准。建立在 phase-09a（只读监视器、叠加窗口）之上。

## 目标

1. 操作员能在 UI 里**不产生任何运动**地清除 xArm 控制器错误：
   - 无 session 时在 Welcome 页 Hardware 页签的臂卡片上（"Clear errors"）；
   - 真机 session 中在 Cockpit 的故障横幅上（"Clear errors & resume"）——运动环停发、清错、使能、回到 servo 模式、
     从**实测位置**重新播种，再要求操作员重新握持 clutch 才继续。
2. 把控制器侧安全参数（末端负载 `tcp_load`、碰撞灵敏度、自碰撞检测 + 工具模型、碰撞反弹关闭、可选
   Reduced-mode 边界盒）作为**每臂配置**写进 core `ArmConfig`，hardware 驱动在接入时应用（现有
   `apply_backstops`），并允许无 session 时从 UI 一键应用（"Apply safety settings"），监视器回读当前值并标出与配置不一致。
3. runtime 消费驱动的故障/恢复事件：真机 session 里出现控制器错误（如关节超限 C23/速度超限 C24、碰撞 C31、
   边界 C35）时 session 进入 FAULT，该臂停止发流，其他臂保持；恢复后 RECOVERING → RUNNING。
   （04-runtime §15 已设计、从未实现；本阶段用 fake 实现并测试，真机 session 本身仍属 phase-09。）

## 前置条件（事实）

- 2026-09-04 实测：对 Perception Arm（view，192.168.2.219）调 `clean_error()` 即清除 C19，之后六秒未复现，
  七个关节读数变化 ≤ 5e-5 rad（编码器噪声）——**清错不产生运动**。恢复序列
  `clean_error → clean_warn → motion_enable(True) → set_mode(x) → set_state(0)` 同样不产生运动：只让臂进入
  ready / servo 状态；运动只来自显式运动指令。导轨归零（`set_linear_track_back_origin`）**是**运动，不属于清错，
  本阶段不做（phase-09 用孪生导轨扫掠检查后再低速归零）。
- C19 = SDK 标题 "End Effector Communication Error"（Studio 叫 "End Module Communication Error"）：
  该控制盒工具口 RS-485 上找不到末端设备；Perception Arm 无夹爪，`get_tgpio_modbus_baudrate` 返回 (1, -1)。
  一次性修法在 Studio：Settings → Externals → End Effector → None（SDK 1.18.5 没有对应写接口）。
- 控制器当前值（只读监视器）：两臂 `tcp_load` 0 kg（错——碰撞检测靠电流估计，负载必须正确）；碰撞灵敏度
  Manipulation Arm 3、Perception Arm 1（太低）；两臂 `arm.sn` 都读作 `XS1305`（型号码，不是唯一序列号，
  `expected_sn` 校验无用，保持 None）。
- 末端负载**暂定值**（待称重；写进配置并注明）：Manipulation Arm = xArm Gripper G2 + D435i + 支架 ≈ 0.95 kg，
  质心约 (0, 0, 60) mm；Perception Arm = D435i（0.072 kg）+ RØDE NT-USB Mini（≈0.35 kg）+ 支架 ≈ 0.55 kg，
  质心约 (0, 0, 90) mm。碰撞灵敏度两臂配置为 3。
- 已有代码：`hardware/driver.py` `_recover(user_initiated)`（完整恢复序列 + `ReseedEvent`，在监视线程上跑，
  受 3 次/30 s 预算限制；`user_initiated=True` 绕过分类与预算）、`events.py`（FaultEvent / RecoveredEvent /
  ReseedEvent / StudioConflictWarning / RailEvent / GripperFaultEvent / StaleEvent）、`backstops.apply_backstops(api, cfg)`
  （tcp_load → gravity → sensitivity → self-collision + tool model → 可选 reduced boundary → rebound off）、
  `workcell._driver_cfg` 只映射 id/ip/expect_rail/gripper/tcp_load（缺 sensitivity/boundary）、
  runtime `SessionState.FAULT/RECOVERING` 有定义无消费者、`ControlLoop.reseed_arm()` 存在但无人调用、
  Cockpit `ArmIndicator` 显示 `err N`。
- phase-09a 的 `ArmStateMonitor` 是零写入的；本阶段给它加**显式、由用户触发**的维护操作通道，
  零写入保证改为"没有维护请求时零写入"。

## 范围

### 1. core（additive）

- `schemas/config.py` `ArmConfig`：`collision_sensitivity: int = Field(3, ge=0, le=5)`、
  `reduced_tcp_boundary_mm: tuple[int, int, int, int, int, int] | None = None`、`expected_sn: str | None = None`。
- 新模块 `protocol/maintenance.py`：
  ```python
  ArmMaintenanceOp = Literal["clear_errors", "apply_backstops", "recover"]
  MaintenancePath = Literal["monitor", "session"]
  class ArmMaintenanceRequest(BaseModel):
      op: ArmMaintenanceOp
  class ArmMaintenanceResult(BaseModel):
      arm_id: str
      op: ArmMaintenanceOp
      path: MaintenancePath
      ok: bool
      detail: str = ""                       # human-readable outcome
      sdk_codes: dict[str, int] = {}         # SDK call -> return code, in call order
      warnings: list[str] = []               # apply_backstops non-fatal codes
      before: ArmMonitorTelemetry | None = None
      after: ArmMonitorTelemetry | None = None
  ```
  语义：`clear_errors` = `clean_error` + `clean_warn`，**不使能**（无 session，经监视器）；`apply_backstops` =
  `backstops.apply_backstops`（无 session，经监视器；session 中 409）；`recover` = 驱动 `_recover(user_initiated=True)`
  （仅真机 session 中；无 session 409 "no hardware session — use clear_errors"）。
- `protocol/hardware_monitor.py` `ArmMonitorTelemetry` 增加回读：`collision_sensitivity: int | None = None`、
  `tcp_load_kg: float | None = None`、`tcp_load_cog_mm: list[float] = []`、`backstops_match: bool | None = None`
  （runtime 按配置比较：灵敏度相等且负载 |Δ| ≤ 0.05 kg、质心 |Δ| ≤ 10 mm）、`maintenance_busy: bool = False`。
- `protocol/telemetry.py` 的每臂遥测（`ArmTelemetry` 或现有等价模型）增加 `fault_detail: str = ""`
  （如 "controller error 24: Speed Exceeds Limit"）与 `recovering: bool = False`；`SessionInfo.state` 已含
  `fault`/`recovering`。
- `interfaces` 的 `WorkcellInterface`（若无）增加 `drain_events(self) -> list[Any]`，默认返回 `[]`（additive）。
- `EXPORTED_MODELS` += `ArmMaintenanceRequest`、`ArmMaintenanceResult`；schemas、`__init__`/`__all__`、测试同步。

### 2. hardware

- `monitor.py`：`ArmStateMonitor.maintenance(op: ArmMaintenanceOp, driver_cfg: XArmDriverConfig | None = None,
  timeout_s: float = 10.0) -> MaintenanceOutcome`（dataclass：ok、detail、sdk_codes、warnings、before/after 样本）。
  请求放入队列，由**轮询线程**执行（同一 `XArmAPI` 不跨线程并发）；执行前后各取一次样本；执行后立刻刷新
  慢速字段（导轨、夹爪、灵敏度、负载）。`clear_errors` 只调 `clean_error`、`clean_warn`；`apply_backstops` 调
  `backstops.apply_backstops(api, driver_cfg)`；`recover` 在监视器上返回 ok=False, detail "recover needs a session"。
  监视器未连接/暂停 → ok=False。回读：每慢轮读 `api.collision_sensitivity` / `api.tcp_load`（或 SDK 的 `get_*`，
  以源码为准）。测试：无请求时零写入不变；`clear_errors` 的写集合恰为 {clean_error, clean_warn}；`apply_backstops`
  的写集合与 `backstops.py` 顺序一致；超时/断线路径。
- `driver.py`：公开 `request_recovery() -> None`（设置 `_user_recovery_pending`，监视线程调 `_recover(user_initiated=True)`），
  `recovery_result()`/事件经 `drain_events()`；`workcell.py`：`HardwareWorkcell.request_recovery(arm_id)`、
  `drain_events()` 汇总各驱动事件（已有则复用）；`_driver_cfg` 映射 `collision_sensitivity`、
  `reduced_tcp_boundary_mm`、`expected_sn`。
- `docs/design/02-hardware.md`：维护通道（写集合、线程模型、"零写入除非显式维护请求"）、§6 backstops 参数来源改为
  `ArmConfig`。

### 3. runtime

- `devices/hardware_monitor.py`：`HardwareStateMonitor.maintenance(arm_id, op) -> ArmMaintenanceResult`
  （查配置构造 `XArmDriverConfig`；填 `path="monitor"`；计算 `backstops_match`；同一臂并发请求 → 409 语义）。
- `server/rest.py`：`POST /api/hardware/arms/{arm_id}/maintenance`（body `ArmMaintenanceRequest`）：
  404 未知臂；有真机 session → `op in (clear_errors, recover)` 走 session 驱动 `request_recovery`（等待
  RecoveredEvent/LATCHED ≤ 10 s，`path="session"`），`apply_backstops` → 409；无 session → 监视器路径；
  监视器 off/paused/未连接 → 409。写一条 INFO 日志（谁、哪臂、什么 op、结果）。
- 控制环（`control/loop.py` + `session/manager.py`）：每 tick `workcell.drain_events()`：`FaultEvent` → 该臂
  `fault_detail`、`ArmSender` 停发该臂、session state `fault`；`RecoveredEvent`/`ReseedEvent` → `reseed_arm`、
  state `recovering` → 需要"空 held 集 / clutch 重新握持"后 → `running`；`StudioConflictWarning` → telemetry 警告。
  用 `tests/fakes.py` 的 FakeWorkcell 加可脚本化事件测试（无真机）。
- `configs/mavis_v2.yaml` hardware workcell：grip `tcp_load_kg: 0.95, tcp_load_cog_mm: [0, 0, 60], collision_sensitivity: 3`；
  view `tcp_load_kg: 0.55, tcp_load_cog_mm: [0, 0, 90], collision_sensitivity: 3`；注释说明为估计值（用户 2026-09-05 决定不称重，直接采用）。
  `tests/test_configs.py` 同步。`~/apollo/mavis_v2_live.yaml` 由主代理重新渲染。
- telemetry：`hardware_monitor.arms[*]` 新字段；`arms[*].fault_detail/recovering`。
- 测试：REST 三条路径（monitor / session / 409）、fake 监视器 maintenance、控制环 FAULT→RECOVERING→RUNNING、契约测试。
- `docs/design/04-runtime.md` §13.1 路由、§15 状态"已实现（fake）"、§14 配置。

### 4. ui

- `src/api/rest.ts`：`postArmMaintenance(armId, op) -> ArmMaintenanceResult`（非 2xx 抛带 detail 的错误）。
- Hardware 页签臂卡片（`landing.tsx`）：元数据行加 `sensitivity N · payload X kg`（来自
  `telemetry.hardware_monitor.arms`；`backstops_match === false` 时琥珀色并加 title "differs from config"）；
  按钮 **Clear errors**（`error_code != 0 || warn_code != 0` 时可用；有真机 session 时禁用并提示 "Use the Cockpit"）、
  **Apply safety settings**（`backstops_match === false` 且无 session 时可用）。点击 → 按钮 busy 态 → toast
  （成功：`Manipulation Arm · errors cleared` / `safety settings applied (sensitivity 3, payload 0.95 kg)`；
  失败：detail）。无确认弹窗（两者都不产生运动）。
- Cockpit：新 `FaultBanner`（`src/components/FaultBanner.tsx`）：任一臂 `fault_detail` 非空或 session state
  `fault/recovering` 时显示：臂显示名 + `C<code> <title>` + 按钮 **Clear errors & resume**（POST `recover`；
  `recovering` 时 busy；成功后提示 "re-grip the clutch to continue"）。仅真机 session 显示；sim session 的故障
  （若有）只显示不提供按钮。`ArmIndicator` 的 `err N` 改成与 Landing 一致的红色 `C<code>` chip。
- 测试：按钮可用性矩阵、POST body、toast 文案、FaultBanner 渲染与按钮；`gen:sync/types/check`。
- `docs/design/05-ui.md` §8.1/§8.3（Cockpit）/§9/§10/§12。

### 5. docs

- 本文件；`docs/prompts/README.md` 09b 行；`phase-09-integration.md` 恢复演练指向本阶段按钮；
  `CLAUDE.md` Hardware facts：C19 原因与 Studio 修法、清错不产生运动（实测）、暂定负载、灵敏度配置 3。
- `docs/deploy/DEPLOYMENT.md` S11：控制器错误 → UI 的 Clear errors 按钮；S7 验收加一条。

### Out of scope

- 导轨归零；`_bringup_hardware`；自动恢复（无操作员点击不恢复）；在 session 中修改 backstops；
  Reduced-mode 边界盒的具体数值（等用户给场景边界）。

## 交付物

五层代码 + 测试 + 文档 + schemas / `src/gen` 重生成；不 commit（等用户指令）。

## 验收标准

- 各仓库测试与 ruff / tsc / eslint / gen:check 全绿。
- 真机（无 session，控制盒开着；允许配置类写入，禁止运动）：
  `POST /api/hardware/arms/view/maintenance {op: clear_errors}` → ok，`after.error_code == 0`；
  `POST .../grip/maintenance {op: apply_backstops}` 与 `view` 同 → ok，回读 `collision_sensitivity == 3`、
  `tcp_load_kg` ≈ 配置值、`backstops_match true`；两臂 `state`/`mode` 与之前一致（4 / 0），关节读数变化 < 1e-3 rad；
  Hardware 页签按钮与 toast 正常；Cockpit 横幅在 fake 事件测试里出现并可点。

## 注意事项

- 一切维护操作都在监视器/驱动自己的线程上执行；REST 处理线程只等待结果。
- `motion_enable(True)` 会松开抱闸让电机主动保持位置（仍不运动）——只在 `recover`（session 中）使用，
  `clear_errors` 绝不使能。
- `apply_backstops` 是易失配置（控制器重启后丢失），驱动接入时会重新应用；UI 按钮只是无 session 时的便捷入口。
- 显示名一律 "Manipulation Arm" / "Perception Arm"；错误标题用 SDK 的 `x_code` 表。

## 实现记录（2026-09-04，五层完成，未 commit）

与本契约字面的差异（均已写进修订后的设计文档 01/02/04/05，冲突时以设计文档为准）：

- `StudioConflictWarning` → "telemetry 警告"：core `TelemetryMsg` 没有 warnings 字段，警告以
  `arms[*].fault_detail = "warning: close UFACTORY Studio live control"` 的形式停留 5 s
  （`STUDIO_WARNING_LINGER_S`），`recovering=false`、session state 不变；真正的 FaultEvent 会覆盖它。
  UI 的 `FaultBanner` 以非空 `fault_detail` 触发，因此也会显示这条警告（04-runtime §13.3 / §15）。
- RECOVERING → RUNNING 的判据实现为"重播种之后的 tick 里没有任何**活**输入源持有按键"
  （`HeldSources.scale_for > 0`）：设备 clutch 必须松开（下一次握持是上升沿、零增量接合）；仍被按住但已被
  watchdog 锁存（AWAIT_EMPTY）的 WS 键不阻塞，因为 watchdog 本身已挡住 WS 运动直到收到空 KeysMsg。
  RECOVERING 至少持续一个 tick。
- session 路径等待的是 `workcell.recovery_result().seq` 递增（≤ 10 s），而不是消费 RecoveredEvent /
  LATCHED 事件（事件由控制环消费）。session 中 `clear_errors` 与 `recover` 等价（都走驱动的完整用户恢复，
  含 `motion_enable`）；`before` / `after` 为 null（session 期间监视器已断开）。
- 监视器路径的 `recover` 409 由 `HardwareStateMonitor.maintenance` 抛出
  （`MaintenanceUnavailableError("no hardware session - use clear_errors")`，连字符），REST 映射为 409；
  同臂并发请求 → 409 "a maintenance op is already running on '<arm>'"。
- runtime 原本没有 `tests/fakes.py`（FakeWorkcell 在 core.testing）；新建 `tests/fakes.py` 提供
  `EventFakeWorkcell` + 与 hardware `events.py` 同名同字段的 duck-typed 事件 / `RecoveryResult`（有测试钉住）。
- `POST /api/session kind=hardware` 仍是 409（phase-09）；session 路径经 `SessionManager.attach_fault_state`
  seam 手工装入的 hardware `ActiveSession` 测试。
- 驱动原有的自动恢复（可恢复码 3 次 / 30 s 预算）保留；"无操作员点击不恢复"指 runtime / UI 不自行恢复，
  预算耗尽 / 不可恢复码 / 急停后的 LATCHED 只能靠点击 `recover`；任何情况下都要重新握持 clutch /
  松开所有键才恢复运动。
- hardware `apply_backstops` 的写序列没有 `set_reduced_max_tcp_speed`（02-hardware §6 已同步为
  `set_reduced_tcp_boundary` → `set_reduced_mode`）；`FaultEvent.source` 实际还会出现 `"user"`（用户恢复）
  与 `"latch"`（锁存），hardware `events.py` 的字段注释未列出。
- 额外的健壮性改动：`SessionManager._start_from_worker` 不再用 RUNNING 覆盖 FAULT / RECOVERING；
  `backstops_match` 容差带 1e-9 epsilon（0.95 + 0.05 vs 1.0 算在容差内）。
- 真机验收命令（无 session、控制盒开着；配置类写入、零运动）见 `docs/deploy/DEPLOYMENT.md` S7；
  `~/apollo/mavis_v2_live.yaml` 需由主代理用 `scripts/deploy/render-lab-config.sh` 重新渲染。

### 评审修正（2026-09-04，同日代码评审后，未 commit）

- hardware `monitor.py`：已弹出、正在执行的维护请求在 before 样本之后**重新检查交接**
  （`stop()`/`disconnect()` 期间到达 → 不写任何 SDK、以 "monitor paused: released for hand-over"
  拒绝）；写入已发出时只跳过 after 样本（`after=None`，detail 后缀 "(… before the read-back)"）；
  `_shutdown()` 遇到写入中的操作会等它结束（上限 `STALE_THREAD_JOIN_S`）再断开客户端，绝不在写入
  中途拔掉连接。原先偶发失败的交接测试改为三条确定性测试（排队中 / 执行中拒写 / 写入中等待）。
- runtime `control/loop.py` + `arm_sender.py`：FAULT / RECOVERING 的臂**不再接受夹爪按键**
  （不积分、不入队），`ArmSender.pause()` 丢弃故障前排队的夹爪目标，`reseed_arm()` 把夹爪目标
  同步到实测开度；`session/manager.py` 的 session 路径只接受 `user_initiated` 的
  `RecoveryResult`（驱动自动恢复也会递增 seq）；`devices/hardware_monitor.py` 监视器关闭
  （`enabled: false` / 无 hardware extra）时 `paused` 直接跟随谓词，UI 的 "真机 session 存在"
  信号不再丢失。
- ui：`faultLabel` 绝不输出 `C0`（RECOVERING 线上 `error_code` 已为 0、detail 保留 —— 取 detail
  里的码；无码的驱动文本原样显示）；`FaultBanner` 把 `warning:` 前缀的 StudioConflictWarning
  渲染为琥珀色只读 **WARNING** 行（无 C 码、无按钮、不参与红/琥珀判定）；`apply_backstops`
  toast 显示**写入**的值（解析 runtime detail），`after.backstops_match === false` 时琥珀并附
  "read-back not yet reflected" 说明；臂卡片只有被按下的按钮 busy，服务端在跑的操作改为一个共享
  "maintenance running…" 指示。
- docs：`clear_errors` "never motion_enable" 一律限定为**监视器路径（无 session）**；session 内它
  等价于 `recover`（会使能）。DEPLOYMENT 原文 "两者在 session 中 409" 更正为仅 `apply_backstops` 409。


### 真机验收补记（2026-09-04 23:3x，主代理）

- `clear_errors`（view）：ok，`clean_error`/`clean_warn` 各返回 0，无运动。
- 第一次 `apply_backstops` 两臂都报 "TypeError: int() argument ... 'list'"：SDK 1.18.5 的
  `set_collision_rebound` 返回的是原始回复列表 `[code, ...]` 而不是像其他 setter 那样返回 `ret[0]`；
  同时 `set_tcp_load` 在臂处于停止态（state 4/5）时返回 APIState 9（STATE_NOT_READY），但控制器**已经存下了**
  负载值（回读 0.95 / 0.55 kg 一致）。修复：`backstops._check` 归一化列表回复，`set_tcp_load`/`set_gravity_direction`/
  `set_collision_sensitivity` 显式 `wait=False`，code 9 记为带说明的 warning；fake SDK 镜像列表回复。
- 副作用观察：`apply_backstops` 后两臂控制器 state 从 4 变为 5。SDK 对 4 与 5 同样处理为"停止、未就绪"
  （`_is_ready=False`，`wait_move` 把 5 当作可能的过渡态），关节读数变化 ≤ 1.5e-5 rad，**没有运动**；
  具体是哪一条 set_* 触发的状态切换尚未定位，phase-09 使能前再核对。
