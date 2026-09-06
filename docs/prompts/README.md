# apollo-mavis-v2 分阶段开发提示词（Phased Development Prompts）

本目录是 apollo-mavis-v2 五仓栈的实施计划。每个 `phase-XX-*.md` 是一份**自包含**的
实施提示词：一个 phase = 一次 Claude Code 会话，工作目录固定为
`/home/xiatao/projects/apollo-mavis-v2-ws`（五个子仓并列在其下）。

## 使用方法

1. 在 `/home/xiatao/projects/apollo-mavis-v2-ws` 启动一次新的 Claude Code 会话。
2. 把对应 phase 文件的全文作为任务输入（或让会话直接读该文件）。
3. 会话内先读 phase 文件"前置条件"里列出的设计文档（`docs/design/` 是唯一事实来源，
   `docs/research/` 仅作参考），再动手实现。
4. 按"验收标准"逐条自验（列出的命令必须真实跑通），全部通过后勾选下表。
5. 阶段之间不要并行修改同一个子仓；严格按依赖图推进。

约定（来自 `CLAUDE.md` / `docs/design/00-overview.md`）：Python ≥3.10 + `uv`；
代码/注释/仓库文档用英文；依赖方向严格单向（core 不依赖栈内任何东西；
hardware/sim 只依赖 core；runtime 依赖 core，hardware/sim 为可选 extras；
ui 只通过 HTTP/WebSocket 与 runtime 通信）。版本锁定：MuJoCo 3.12.0、
mink 1.3.0、xArm-Python-SDK 1.18.5、lerobot ≥0.6（锁定小版本）、Node ≥20 + pnpm。

## 阶段顺序与依赖图

```
phase-01-core ──┬─→ phase-02-sim-workcell ─→ phase-03-ik-twin ──┐
                │                                               ├─→ phase-05-runtime-teleop ─→ phase-06-ui ─→ phase-07-data-collection ─→ phase-08-dagger-inference ─→ phase-09-integration
                └─→ phase-04-hardware ──────────────────────────┘
```

- phase-02/03（sim 仓两部分）与 phase-04（hardware 仓）在 phase-01 完成后可并行。
- phase-03 交付安全层 CI 回归脚本 `apollo_mavis_v2_sim/tools/guardrail_check.py`
  （四场景 + A1–A5 断言）；phase-05 实现 runtime `SafetyGate`/`ControlLoop`
  chokepoint 并把该脚本接入 runtime CI；phase-09 在真机上做最终安全验收。
- phase-05 需要 01+02+03 完成（sim 后端的端到端测试），phase-04 完成与否不阻塞
  phase-05 的落地（hardware 路径按接口对接、以 fake SDK 测试）。
- phase-06 需要 phase-05 的服务端协议已冻结（协议形状本身在 phase-01 的
  `core.protocol` 定稿，UI 类型由 core schemas 生成）。
- phase-07/08 顺序依赖 05/06；phase-08 的 trainer 是独立进程
  （`python -m apollo_mavis_v2_runtime.dagger.trainer`，GPU 1，ZMQ 5757）。
- phase-09 需要全部完成，且需要真机在场。
- phase-09a（2026-09-04 插入）是 phase-09 的**只读**前置步骤：不发任何运动指令，runtime 无 session 时
  持续读取两台真机的关节角/导轨/夹爪/错误码（`telemetry.hardware_monitor`），并把 `mavis_v2` 孪生按真机
  状态渲染、淡黄半透明叠加在两路腕部相机画面上（Hardware 页签 `grip_wrist_align` / `view_wrist_align`）。
  phase-09 的"twin 渲染 vs 真机相机对拍"验收项以这两个窗口为方法。
- phase-09b（2026-09-04 插入）建立在 09a 之上：控制器错误清除 / 恢复接口 + 控制器侧安全参数。无 session 时
  Hardware 页签臂卡片的 **Clear errors**（`clean_error` + `clean_warn`，不使能）与 **Apply safety settings**
  （`apply_backstops`：末端负载 / 碰撞灵敏度等，参数进 core `ArmConfig`，监视器回读 `backstops_match`）；真机
  session 中 Cockpit 故障横幅的 **Clear errors & resume**（驱动 `request_recovery`，从实测位置重播种，之后重新握持
  clutch 才继续）；runtime 消费驱动 FaultEvent / RecoveredEvent → session FAULT → RECOVERING → RUNNING（fake
  测试）。三个操作都不产生运动（2026-09-04 实测）。phase-09 的"错误恢复课目"以这些按钮为操作入口。
- phase-09c（2026-09-05 插入）是 phase-09"代码部分"的落地：真机 session bring-up（`_bringup_hardware`：监视器
  暂停 + join → 子集臂 `WorkcellConfig` → 限速驱动 → `bring_up` → 全新门禁孪生 + **无条件** `SafetyGate` →
  预览相机**接管**不重开 UVC）、`SessionSpec.speed_scale`（Hardware 页签 10% / 30% / 100%，默认 10%）、子集臂
  （默认只带 Manipulation Arm，未选中臂按最后一次监视样本冻结在门禁孪生里——**09d 起取消**：两臂常驻 session，
  冻结机制只留给归零维护运动）、`SessionInfo.kind / speed_scale` 与 `telemetry.session.bringup` 进度。**没有任何隐式运动**：驱动 connect 不再归零（`RailNotHomedError` →
  session 409 "rail not homed"）；导轨归零改为操作员在臂卡片点 **Home rail** 触发的维护操作 `home_rail`——
  仓库里唯一会让机械部件运动的维护操作，先由专用孪生对整段 0–0.65 m 行程、以该臂当前姿态做 0.025 m 余量的
  扫掠门禁（dry-run 先显示判定），再在只读监视器线程上执行并只按寄存器判定成功；拆除时臂交还为停止、抱闸
  （D6）。真机验收步骤见该文件末尾（用户在场；步骤 4 已被 09d 修订，见该文件头注）。
- phase-09d（2026-09-05 插入）修订 09c 的三个决定：**两臂永远都在真机 session 里**（去掉 "Include in session" 开关与
  `hardware_session.default_arms`；`SessionSpec.arms` 必须等于硬件 workcell 的全部臂，否则 409 "hardware sessions
  include every configured arm"；D1 冻结机制只保留给维护运动）；**归零前先规划**（`home_rail` 的 dry-run 在当前姿态
  扫掠不通过时用孪生 RRT-Connect 规划到导轨安全姿态（场景 keyframe → `<arm>_home`）的路径，路径每个致密化路点都对
  131 个导轨位置无碰撞——位置无关，因为滑台位置未知——结果在 `RailSweepVerdict.pre_position`；操作员确认后
  `RailHomingJob` 以 10% 只连该臂（`rail_homing: allow_unhomed`）、门禁下执行路径、`XArmDriver.home_rail()` 归零、
  寄存器验证、拆除时抱闸**保持折叠姿态**，REST 202 + `job_id`，进度在 `telemetry.hardware_monitor.arms[].maintenance`，
  结果 `GET …/maintenance/last`；找不到路径才 `refused`）；**真机 `start_from=profile` 在 bring-up 内基于门禁孪生
  规划**（失败 409 "profile motion not collision-free"）；Welcome 页右上 "Devices" 改名 **Debug**（路由 `#/devices`
  不变）。

> 多 agent 自主开发的编排方案（波次 DAG、验证门、故障恢复）见
> [ORCHESTRATION.md](ORCHESTRATION.md)。

## 状态清单

| Phase | 文件 | 仓库 | 依赖 | 状态 |
|---|---|---|---|---|
| 01 | `phase-01-core.md` | apollo-mavis-v2-core | — | [x] 2026-09-01 完成（154 tests 全绿，schemas/ 已导出） |
| 02 | `phase-02-sim-workcell.md` | apollo-mavis-v2-sim | 01 | [x] 2026-09-01 完成（66 tests，benchmark 达标） |
| 03 | `phase-03-ik-twin.md` | apollo-mavis-v2-sim | 01, 02 | [x] 2026-09-01 完成（105 tests，guardrail 12/12 PASS，IK p99 590µs/3臂） |
| 04 | `phase-04-hardware.md` | apollo-mavis-v2-hardware | 01 | [x] 2026-09-01 完成（105 tests，FakeSDK 全覆盖，SDK pin 见 repo README） |
| 05 | `phase-05-runtime-teleop.md` | apollo-mavis-v2-runtime | 01, 02, 03（04 接口对接） | [x] 2026-09-01 完成（60 tests，e2e 全过；hardware 组装留 phase-09） |
| 06 | `phase-06-ui.md` | apollo-mavis-v2-ui | 05 | [x] 2026-09-01 完成（93 tests，真 runtime 协议闭环验证） |
| 07 | `phase-07-data-collection.md` | apollo-mavis-v2-runtime (+ui) | 05, 06 | [x] 2026-09-01 完成（105 tests，e2e 录/弃/回读；runtime 需 Py3.12） |
| 08 | `phase-08-dagger-inference.md` | apollo-mavis-v2-runtime (+ui) | 07 | [x] 2026-09-01 完成（145 tests，真实 trainer 进程集成） |
| 09 | `phase-09-integration.md` | 全部（真机） | 01–08, 09a, 09b, 09c, 09d | [ ] 代码部分已由 09a/09b/09c/09d 落地；真机执行清单待现场 |
| 09a | `phase-09a-hardware-twin-overlay.md` | 全部五层（core / hardware / runtime / ui / docs）；phase-09 的只读前置步骤 | 01–08, 11；控制盒开着即可（只读，零运动指令） | [ ] 2026-09-04 设计定稿并五层实现完成（core +5 tests、hardware `monitor.py` 18 tests + 首次真机只读接触发现的 6 个 SDK 1.18.5 bug 修复、runtime 21 tests（EGL）、ui tsc/eslint/vitest/gen:check 全绿；01/02/03/04/05 设计文档同步）；真机只读验收（两臂 `running`、`q` 与 `get_servo_angle` 一致、Perception Arm C19、`/api/cameras` 两路 `*_align` kind `twin` live、`/ws/video/grip_wrist_align` 12 fps、监视前后 state/mode/error 不变）待主 agent 现场检查 |
| 09b | `phase-09b-error-recovery.md` | 全部五层（core / hardware / runtime / ui / docs）；建立在 09a 之上 | 01–08, 09a；控制盒开着即可（配置类写入，零运动指令） | [ ] 2026-09-04 设计定稿并五层实现完成（core `protocol/maintenance.py` + `ArmConfig.collision_sensitivity / reduced_tcp_boundary_mm / expected_sn` + `ArmMonitorTelemetry` 安全参数回读 + `ArmTelemetry.fault_detail / recovering`，schemas 重生成；hardware `ArmStateMonitor.maintenance` 维护通道（"没有维护请求时零写入"）+ `request_recovery` / `recovery_result` / `drain_events`；runtime `POST /api/hardware/arms/{arm_id}/maintenance` 三条路径 + 控制环 FAULT → RECOVERING → RUNNING（fake 事件测试）+ `configs/mavis_v2.yaml` 暂定负载；ui 臂卡片按钮 + Cockpit `FaultBanner` + 红色 `C<code>` chip；各仓 pytest / ruff / tsc / eslint / vitest / gen:check 全绿；01/02/04/05 设计文档同步）；真机验收（无 session：`view` `clear_errors` → `after.error_code 0`；两臂 `apply_backstops` → 回读灵敏度 3、`tcp_load_kg` ≈ 配置、`backstops_match true`；state/mode 不变、关节变化 < 1e-3 rad；Hardware 页签按钮与 toast）待主 agent 现场检查 |
| 09c | `phase-09c-hardware-session.md` | 全部五层（core / hardware / runtime / ui / docs）；phase-09"代码部分"的落地 | 01–08, 09a, 09b；fake 全链路，真机步骤需用户在场（急停在手） | [ ] 2026-09-05 设计定稿并五层实现完成（core `home_rail` / `dry_run` / `RailSweepVerdict` / `speed_scale` / `SessionInfo.kind` / `ArmBringupTelemetry` / `RailNotHomedError`，schemas 重生成；hardware `require_homed()`（connect 永不归零）+ 监视器 `home_rail` op（写集合精确、姿态校验、`auto_enable=False`、只按寄存器判定、归零中不断开）+ D2 上限 + D6 `disconnect()` 停止抱闸，241 tests；runtime `_bringup_hardware` + `RailSweepChecker`（131 步 ≈ 32 ms）+ 拒绝矩阵 + 相机接管 + 冻结臂 + 限速，`tests/test_hardware_session.py` 含真 `HardwareWorkcell + XArmDriver` 过 FakeXArmAPI 的 unhomed → 409 → home_rail → running 全链路；ui 臂卡片 `rail not homed` 药丸 + **Home rail** → `HomeRailSheet`、**Include in session**（09d 移除）、**Speed**、`BringupProgress`、冻结臂提示，257 tests；01/02/03/04/05/11 设计文档、CLAUDE.md、DEPLOYMENT.md 同步）；**真机验收步骤（该文件末尾，步骤 4 按 09d 头注修订）待用户在场执行——真机上从未跑过驱动连接与归零** |
| 09d | `phase-09d-rail-homing-planning.md` | 全部五层（core / hardware / runtime / ui / docs）；修订 09c 的三个决定 | 01–08, 09a, 09b, 09c；fake 全链路，真机步骤需用户在场（急停在手） | [ ] 2026-09-05 设计定稿并五层实现完成（core `PrePositionPlan` / `RailSweepVerdict.pre_position` / `MaintenanceStatus` + `ArmMaintenanceResult.status / job_id` / `MaintenancePhase` + `MaintenanceProgress` / `ArmMonitorTelemetry.maintenance`（共享名定义在 `hardware_monitor` 叶模块、`maintenance` 再导出），schemas 重生成、`EXPORTED_MODELS` 不变；hardware `XArmDriverConfig.rail_homing: allow_unhomed`（未归零也能连：位置未知，`q[7]` 0.0 占位 + `rail_position_known`，`command_rail` 拒绝）+ `XArmDriver.home_rail()`（已连接驱动、调用方线程、发流保持关节、只按寄存器判定）；runtime 删 `default_arms`、`spec.arms` 必须等于全部臂（409）、`RailSweepChecker.plan_path / check_path`（位置无关：致密化到 0.05 rad 的每个配置 × 131 个导轨位置，起始姿态滞回）、`RailHomingJob` + `RailHomingService`（202 + `job_id`，七个阶段进 telemetry，`GET …/maintenance/last`，job 期间一切 op 与 `POST /api/session` 409）、`RailHoldArm` 适配器、真机 `start_from=profile` 在 bring-up 内规划（失败 409）、`PlanExecutor` 改为沿直线段比例插补（修正门禁永久 hold）；ui Devices → **Debug**、去掉 Include 开关与 `DEFAULT_HARDWARE_ARMS`、启动器原因点名臂、`HomeRailSheet` 预定位说明 + 202 进度视图 + `/maintenance/last`；01/02/04/05/11 设计文档、CLAUDE.md、DEPLOYMENT.md、09c 头注同步）；真机验收（Home rail 面板会先说明是否需要预先移动机械臂）待用户在场 |
| 10 | `phase-10-tracker-calibration.md` | apollo-mavis-v2-core / -runtime / -ui | 05, 06（13-tracker v0.1 真机路径可用） | [ ] 2026-09-03 设计定稿（基站标定 + 航向对齐向导，REST + telemetry），三层并行实现中；真机验收待用户在场 |
| 11 | `phase-11-mavis-ui.md` | 全部五层（core / sim / runtime / ui / docs） | 06, 07, 08, 10 | [ ] 2026-09-03 设计定稿（Welcome 页 APOLLO MAVIS V2、Hardware 与 Sim 两页签、RØDE 麦克风实时声波、单场景 `mavis_v2`、页内 `<dialog>` 启动弹窗、§6 视觉与动效规范），五层并行实现中；真机验收（仅麦克风、无机械臂）待用户在场 |

## 每个 phase 文件的固定结构

`目标` → `前置条件`（依赖 phase + 必读设计文档）→ `范围`（含明确 out-of-scope）→
`交付物` → `验收标准`（可执行命令 + 具体数字/行为）→ `注意事项`（研究阶段发现的
坑、固件怪癖、版本锁定）。验收数字均出自 `docs/design/` 与 `docs/research/`
的实测值，不得凭空放宽。
