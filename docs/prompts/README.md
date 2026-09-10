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
mink 1.3.0、xArm-Python-SDK 1.18.5、lerobot ≥0.6（锁定小版本）、Node ≥20 + pnpm（2026-09-08 起 UI 实际以 **npm** 管理：`package-lock.json` 是唯一 lockfile，本机 pnpm 11 的 pre-run 安装因未批准的 esbuild 构建脚本失败，`pnpm-lock.yaml` / `pnpm-workspace.yaml` 不得提交；见 CLAUDE.md "Machine"）。

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

- phase-13（2026-09-07 插入）：**键盘遥操回归**（与 Vive controller 平级，00-overview §5 原表；撤销同日
  core 里把 held 行标成 `keyboard=False`、episode 键改 S/F 的未提交改动）、**episode 三键**
  N / Enter / Backspace、**数据集改为每个 episode 一个目录**（`episodes/<episode_id>/{episode.json,
  frames.parquet, video/<cam>.mp4, audio.wav}`，10-frames §11），**LeRobot v3 变为派生导出**（流拷贝
  remux，不重编码；`POST /api/datasets/{ns}/{name}/export` + CLI），删除 = 删一个目录（`DELETE …/
  episodes/{episode_id}`），`/api/datasets*` REST 与 Welcome 页 `DatasetsPanel`，麦克风音频 sidecar 接通，
  保存/丢弃后回初始位（用户 2026-09-07 确认：默认开，按 session 可取消）。前置：修复上会话未提交的数采代码
  （collect session 曾 500，已修）。契约见 `phase-13-keyboard-episode-datasets.md`。

- **2026-09-08 用户三项追加需求（已在 phase-13 工作树实现，未提交）**：
  1. **键盘平移坐标系可配置**（`control.translate_frame`：`world` / `camera` / `base`；旋转键仍绕 TCP 轴）。
     上午先把默认改到腕相机系 `camera`：旧的基座系相对操作者视角 yaw 了 180°，且末端一转键就与画面错位。
     相机姿态**按臂**从模型取（夹爪底座相对 link7 绕工具轴转了 180°，用一个常量矩阵会把默认臂的 A/D、E/Q
     反过来）。**2026-09-08 晚用户决定：默认改为世界系 `world`**（W 远离操作者 = −Y，A 操作者左手 = +X，
     E 向上；`camera` 仍可选）。04-runtime §6、`tests/test_camera_frame.py`、`tests/test_configs.py`。
  2. **`R` 键回初始条件**（`reset_to_initial`，01-core §13 / 00-overview §5）：孪生规划 + 门禁 + 任意运动输入
     可打断；没有指定初始条件时按键只报原因、不动。
  3. **退出主页面前自动回位**：Cockpit "End session" / "Terminate session" 先同步调
     `POST /api/session/return_home`（先关节、后导轨，两段各自规划与门禁），到位才拆 session；回不去就弹窗
     （"Arms did not return home"，正文含 twin 给的原因 + 先结束 session 再用 UFACTORY Studio 手调），
     可选 "End session anyway"。04-runtime §10.5、05-ui §8.2。
  用户给的默认姿态（度）由 `python -m apollo_mavis_v2_runtime.profiles.seed_initial` 写成每种 workcell 一份
  initial-condition profile：Manipulation Arm `[-180, -12, -20, 30, -5, 35, -8.9]`、Perception Arm
  `[0, 0.8, 0, 28.9, 0, 28.2, 0]`，导轨不写（回位时保持当前位置）。孪生已验证该姿态在两端导轨位置、
  麦克风开关两种情况下都无碰撞（最近监控对 107 mm）且可从 keyframe 规划到达。

- **phase-12（dora 外部接口）——2026-09-08 合并进主工作树**：曾在隔离 worktree `~/projects/apollo-mavis-v2-ws-p12/`
  （各子仓 `phase-12` 分支）实现；2026-09-08 05:52 三方合并到主树的 phase-13 未提交改动之上（core / runtime / ui / sim /
  hardware 五仓，冲突 13 处手工合并，生成物——core `schemas/`、ui `schemas/` + `src/gen/protocol.ts`、sim
  `ASSET_MANIFEST.json`、runtime `dataflows/*.yml`——一律重生成；两边的 patch + untracked tgz 备份在
  `~/projects/.merge-backup-20260908/{main,p12}/`）。合并后五仓全绿（core 423 → 现 470、runtime 632 passed / 2 skipped 含全部
  dora live 测试、ui 355、sim 155、hardware 293）。**该 worktree 现在只剩 policy-node 仓的家**：
  `~/projects/apollo-mavis-v2-ws-p12/apollo-mavis-v2-policy-node/`（独立 git 仓，尚无 remote）；其余五个 `phase-12` 子仓 worktree
  已无用途。`~/projects/apollo-mavis-v2-ws-merge/`（分支 `merge-13-12`）是更早一次合并的过期半成品，未使用，删除由用户决定。
  合并阶段发现并修好的两条 phase-12 测试（import-confinement 放行 `recorder/` 的 pyarrow；external-DAgger e2e 改读
  `episodes/*/frames.parquet`）与遗留问题见 `phase-14-online-dagger.md` "实施记录"。
- **phase-14（Online DAgger，2026-09-08 插入；同日晚由 PRO-DAgger 改为算法无关外壳）**：landing 第三张卡片叫 **Online DAgger**
  （wire `mode` 仍 `dagger`）。runtime 只保留 **rollout 级外壳**：执行 rollout、`takeover` / `handback` 动作（幂等，Space 之外）+
  `events.gate`、每帧 `actor` 标签（0 novice / 1 expert）、保存 rollout 并发 `events.episode_saved`（含 `online_dagger` 块）、丢弃**不落盘**
  只发 `events.episode_discarded`、操作员 **Train now** → `events.train_now`、trainer 报 `training` 时暂停新 rollout、`wait_for_trainer_ready`；
  **不数 iteration、不存任何算法产物、UI 不配超参也没有离线数据集选择器**。训练在**外部 policy 节点**（`apollo-mavis-v2-policy-node`，
  `mavis-policy-node --online-dagger <fake|pkg.mod:make_trainer> [--trainer-config …]`，`--selftest online-dagger`），经**一条**通用输入
  `trainer_status`（`idle | preparing | training | ready | error` + 自由 `metrics`，必须回显 `session_id`）回报。session 目录
  `~/data/online_dagger/<s>/{session.json, rollouts/}`（trainer 的产物放哪由它定，runtime 不读）；数据集根按 namespace 映射
  （`bc_demo/<name>` → `~/data/bc_demo/<name>`；`GET /api/datasets/layout`）；回初始位对 rollout 默认开（D6）；真机仍 409（D7）；skill
  `mavis-online-dagger-trainer` 由 runtime 打包（`GET /api/online_dagger/skill(.tgz)`）并逐字节镜像到 policy-node 仓（D8）。
  **PRO-DAgger 降为 policy 仓的参考实现**（`mavis_policy_node.pro_dagger` 架在通用 `mavis_policy_node.online_dagger` loop 上；默认
  offline pool 只供 reference gradient、online buffer 累积每次干预并每个 iteration 都训练）。UI：两视图 `OnlineDaggerSheet` + `OnlineDaggerPanel`
  （Take over / Hand back / Train now）。同日附带：**键盘平移系默认改为 `world`**。上午的 PRO-DAgger 版（`15-pro-dagger.md` v1.0、
  `ProDaggerCoordinator`、`~/data/pro_dagger`、`/api/pro_dagger/*`、`iteration_complete`）从未提交、已删除不留别名。
  契约 `docs/design/15-online-dagger.md` v2.0；实现记录见 `phase-14-online-dagger.md`。依赖 phase-12 + phase-13（同一棵树上）。
- **2026-09-08 晚追加两项操作员问题（已在同一棵树实现，未提交）**：Welcome 的 profile 列表**按页签 kind 过滤**（两种 workcell 各有
  initial condition 后预选不再落到不可见的另一 kind）；真机 `start_from=profile` 因使能后一个 tick 的瞬时 RECOVERING 被 `execute_plan`
  拒绝并无声丢弃 → `hardware_session.start_from_fault_grace_s`（3.0 s）内等臂清空再提交、被拒后重试一次、最终拒绝文案上 wire
  （`session.fault_detail`，Cockpit `SESSION —` 横幅）+ 新动作 **`goto_profile`**（Cockpit "Go to profile"，与 R 同一条孪生规划 + 门禁 +
  可中断路径）。见 `phase-14-online-dagger.md` "同晚追加"。

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
| 11 | `phase-11-mavis-ui.md` | 全部五层（core / sim / runtime / ui / docs） | 06, 07, 08, 10 | [x] 2026-09-03 设计定稿，2026-09-04 五层实现并提交（core 5fd7cfd、sim 5c58840、runtime 3a4fe90/f7e9868、ui 6e8cead，ws 22313d4 钉住）：Welcome 页 APOLLO MAVIS V2、Hardware 与 Sim 两页签、RØDE 麦克风实时声波、单场景 `mavis_v2`、页内 `<dialog>` 启动弹窗；真机侧 2026-09-04 已在 Hardware 页签看到麦克风波形与两路腕相机画面（相机↔臂映射据此确认）。后续在其上叠加了 09a–09d、Setting 页签（2026-09-07） |
| 12 | `phase-12-dora-interface.md` | runtime（+ 外部 policy 仓 `apollo-mavis-v2-policy-node`） | 07, 08, 11 | [x] 设计定稿 2026-09-07（v0.3），2026-09-08 七处实现完成（14-dora v1.0 §16 为实现记录；局域网订阅端到端通过）；**2026-09-08 05:52 已三方合并进主工作树的 phase-13 改动之上，与 phase-13 / phase-14 同在一棵未提交的树里**（隔离 worktree `~/projects/apollo-mavis-v2-ws-p12/` 现只是 policy-node 仓的所在地；`~/projects/apollo-mavis-v2-ws-merge/` 为过期半成品）。合并后 runtime 全量 632 passed / 2 skipped（含 dora live / perf），后随 phase-14 一起验证。**真机只读连接与深度、实验室 Wi-Fi 上的 dora 控制面均未在真机验证**；policy-node 仓仍无 remote |
| 13 | `phase-13-keyboard-episode-datasets.md` | core / runtime / ui（+ sim 字串、docs） | 05, 06, 07, 10, 11；上会话未提交的数采改动 | [ ] 2026-09-07 设计定稿（docs 已按契约改写：10-frames §9/§11、04-runtime §10/§13.1、00-overview §5、13-tracker §1.1、05-ui §8.1/§8.2/§12、01-core §12/§13）；2026-09-07 三层实现完成、待审阅提交（core：keymap 还原 23 行 / N·Enter·Backspace、`SessionSpec.dataset`（schema 带 pattern）/ `dataset_resume` / `return_to_start`（默认开）、`DatasetInfo.layout/export`、`DatasetExportInfo/Request`、`EpisodeInfo` 按 episode_id、`EpisodeStatus.returning`、`TelemetryMsg.datasets`、`EpisodeRecorder` ABC、schemas 重导出；runtime：`EpisodeDirRecorder` + `manifest.py` + `stats.py`（torch-free）、`DatasetStore` 只读 manifest/episode.json、`export_lerobot.py`（av remux + numpy aggregate_stats + `LeRobotDataset` 校验）+ CLI、`/api/datasets*` 六条路由、`telemetry.datasets`、`return_to_start` 三方法（可中断的 execute_plan）、麦克风接线、DAgger spool 按 `episode_id`；ui：`EpisodeControls` 提示随 served keymap、LaunchSheet Dataset 双面板 + Return-to-start、`DatasetsPanel`、真机页签放开 collect、类型重生成；12-dagger §1/§3/§4/§7/§8/§12 同步）；**Round 2（同日晚）**：补充需求"录制时过滤静止 / 停顿 / 小幅动作"落地（core `ActionFilterConfig` / `SessionSpec.action_filter` / `EpisodeStatus.frames_skipped` / `ProfileInfo.workcell_kind`；runtime `recorder/action_filter.py`（对上一保留帧判静止 + ±gripper_context_s 前视缓冲、DAgger 只滤人控帧、`episode.json.filter`）、编码器在 N 时于录制线程打开、控制环进程停顿检测 + deadman 不误判、可中断回位的取消规则（任一来源的运动码 / 手柄断开 / jog / 切臂）、回位预算与 `cancel_plan`、夹爪到位再动、manifest 锁 + 计数重建、导出先校验再切换、`DatasetStore` 导出中 409 / 坏 manifest 跳过；ui LaunchSheet 过滤复选框 + 5 个参数输入、EpisodeControls "skipped N"、按页签 kind 判初始条件）；**2026-09-08 用户三项追加**（键盘平移系可配置、`R` 回初始条件、退出前回位 + 失败弹窗，见上文依赖节）同树实现；**2026-09-08 晚 `control.translate_frame` 默认从上午的 `camera` 翻到 `world`**（`ControlConfig` 默认 + `mavis_v2.yaml`，`sim.yaml` 继承，`tests/test_configs.py` 钉住；`camera` / `base` 仍可选）。**状态：已实现、未提交，2026-09-08 起与 phase-12 / phase-14 合在同一棵主工作树里**；真机验收（两臂 50 %、两路腕相机 + audio.wav、D435 内参、session 中删前一集、回位、`world` 键位手感）待用户在场——**真机尚未跑过任何 phase-13 代码；开发机上的 dev runtime（PID 2144376，18:00:02 启动）跑的是 18:00 快照——合并后、18:38 v2.0 重构前的代码，配置里已是 `translate_frame: world`，但晚间追加（grace / `goto_profile` / `session.fault_detail`）未生效，需重启（2026-09-08 深夜更正：此前误记为"01:27 启动、合并前代码"，该进程已不存在）** |
| 14 | `phase-14-online-dagger.md`（原 `phase-14-pro-dagger.md`，2026-09-08 晚改名） | core / runtime / ui / docs + 外部 policy 仓 `apollo-mavis-v2-policy-node`（sim / hardware 未改） | 12, 13（同一棵树） | [ ] 2026-09-08 上午按 `15-pro-dagger.md` v1.0 实现 PRO-DAgger 外壳（四份审查 11 major + 38 minor 全修，含 `streams/hub.py` 编码器相位 bug），**同日 18:38 用户改口 → `15-online-dagger.md` v2.0 定稿并当晚重构完成、未提交**：core `OnlineDaggerConfig` / `SessionSpec.online_dagger` / `OnlineDaggerStatus` / `OnlineDaggerAnnounce` / 10 字段 `TrainerStatusAnnounce` / `EVENT_KINDS` 十种（+`train_now`）/ `ActionName += takeover, handback, train_now`，`ProDagger*` / `RefGradStatus` 删除，schemas 43 个（**464 tests**，含追加需求）；runtime `dagger/online_dagger.py::OnlineDaggerCoordinator`（`waiting_trainer | rollout | training | error`，四条拒绝文案，只认回显本 `session_id` 的状态）、`takeover` / `handback` 幂等 op + `events.gate`、discard 只发事件不落盘、`train_now`、`_check_online_dagger` 409 矩阵、`datasets.namespaces.online_dagger`（`~/data/online_dagger/<s>/rollouts`）+ `online_dagger:` 块、`GET /api/online_dagger/{skill,skill.tgz,sessions}`、skill `mavis-online-dagger-trainer` 作为包数据（与 policy-node 镜像逐字节一致）、fake 节点通用 trainer 角色、`test_e2e_online_dagger.py` 3 条 ~31 s；三份审查（ui 1 major + 10 minor、policy-node 2 major + 6 minor、runtime 1 major + 8 minor）全部修复（**全量 713 passed / 1 flake / 2 skipped；追加需求后非 dora 715 passed，共 737 条**）；ui `OnlineDaggerSheet` 两视图（无数据集选择器、无超参）+ `OnlineDaggerPanel`（Take over / Hand back / Train now、`metrics` 表 + `loss` sparkline）+ `DatasetsPanel` 分组（**44 files / 436 tests**，含追加需求）；policy-node 通用 `mavis_policy_node/online_dagger/`（`OnlineDaggerTrainer` 八个 hook、`OnlineDaggerLoop`、`FakeTrainer`）+ 参考实现 `mavis_policy_node/pro_dagger/`（`freeze_offline_gref: true`、`replay_buffer: true`）+ `--online-dagger` / `--trainer-config` / `--selftest online-dagger` + skill 镜像（**141 tests** 非 dora + 2 dora e2e）。**同晚追加**：profile 列表按 kind、`start_from_fault_grace_s` + `goto_profile` + `session.fault_detail` 上 wire（1 份审查 2 major + 7 minor 全修）。**仿真 + 两个 fake trainer 已跑通；真机仍 409（D7），真 policy 仓的 trainer 尚未接过外壳；设计文档的 PRO-DAgger → Online DAgger 措辞改写已于同日深夜完成（12-dagger v1.3 / 14-dora v1.2 / 04-runtime / 05-ui / 10-frames / 01-core / 00-overview v0.4；PRO-DAgger 只剩带日期的历史注、policy 仓参考实现与 skill 示例）；一切需重启 runtime 才生效** |

## 2026-09-09 的两条状态更正

- **phase-12 / 13 / 14 及 2026-09-08/09 的追加项已于 2026-09-09 05:46 提交并推送**
  （core `7d9400a`、hardware `0e33d45`、sim `fb1a4af`、runtime `17d8bc7`、ui `eca22df`，
  ws `e16d2c1` 钉住五仓）。上表 phase-12 / 13 / 14 各条里"未提交"的描述到此为止；
  **但这些代码仍未在真机上跑过任何一次**。
- **phase-15（GELLO Manipulation）当天实现、当天全部回退**。用户在 2026-09-09 晚决定砍掉这个
  模式：leader 的 Dynamixel 总线在舵机供电接通后依然完全无应答（9600 … 4 M、协议 2.0 / 1.0、
  广播 ping 与手工封包全试过，适配器本身枚举与打开都正常），不再继续 debug。回退提交：
  core `236a769`、runtime `629002f`、ui `2704aaf`（部分回退——clearance 修复保留）、
  policy-node `20e3c2f`；`docs/design/16-gello.md` 与 `docs/prompts/phase-15-gello.md` 已删除，
  历史留在被回退的 `0654570` / `0eeb681` / `a40df01` / `30f06ab` 里。**保留下来的两样**：
  厨房孪生 `mavis_v2_kitchen`（03-sim §4.4；电器是真实存在的，门禁本来看不到它们）与
  Cockpit clearance 读数修复（05-ui §8.2，本来是用户同一条消息里的另一个要求）。
- 同晚测得孪生与真机的**两臂 + 导轨**差 15–30 mm（03-sim §4.5 附录），据此把真机门禁的
  `geom_inflation_m` 从 0.008 抬到 0.025（11-safety §6.2 记了代价与测试影响）——这是权宜之计，
  真正的修法是重新测量 cell。

## 每个 phase 文件的固定结构

`目标` → `前置条件`（依赖 phase + 必读设计文档）→ `范围`（含明确 out-of-scope）→
`交付物` → `验收标准`（可执行命令 + 具体数字/行为）→ `注意事项`（研究阶段发现的
坑、固件怪癖、版本锁定）。验收数字均出自 `docs/design/` 与 `docs/research/`
的实测值，不得凭空放宽。
