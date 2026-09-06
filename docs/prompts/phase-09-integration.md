# Phase 09 — 真机集成验证、twin 校准、netsetup reconcile、submodule 化、CI

## 目标

在目标机器（Ubuntu 22.04、2× RTX 4090、3 NIC、1–3 台真实 xArm7 ± rail）上做
hardware-in-the-loop 验证：跑通 netsetup reconcile、逐级点亮硬件 teleop/采集/DAgger、
校准数字孪生，并完成工程收尾 — 五个子仓转 git submodule、CI 接线。本 phase 大部分
是**执行清单**而非新代码；发现的缺陷回改对应仓库。

## 前置条件

- 依赖 phase：01–08 全部完成；**phase-09a**（`phase-09a-hardware-twin-overlay.md`，2026-09-04：
  真机只读状态监视 `telemetry.hardware_monitor` + 孪生叠加窗口 `grip_wrist_align` /
  `view_wrist_align`）已落地——本阶段所有"twin 渲染 vs 真机相机"的对拍都用这两个窗口判断，
  不再另写渲染脚本。
- **phase-09b**（`phase-09b-error-recovery.md`，2026-09-04：控制器错误清除 / 恢复接口 + 控制器侧安全
  参数）已落地——本阶段的"错误恢复课目"与 backstops 回读都以它的 UI 按钮 / REST 为操作入口：无 session
  时 Hardware 页签臂卡片 **Clear errors**（`clean_error` + `clean_warn`，不使能）与 **Apply safety
  settings**（`apply_backstops`，参数来自 `configs/mavis_v2.yaml` 的 `ArmConfig`，监视器回读
  `backstops_match`）；真机 session 中 Cockpit 故障横幅 **Clear errors & resume**（驱动
  `request_recovery`：清错 → 使能 → servo → 从实测位置重播种，之后重新握持 clutch 才恢复运动）。
  三者都不产生运动（2026-09-04 实测）。
- **phase-09c**（`phase-09c-hardware-session.md`，2026-09-05：真机 session bring-up）已落地（fake 全链路；真机
  从未跑过）——本阶段"硬件逐级点亮"的 session 都由它启动：Hardware 页签 **Speed** 10% / 30% / 100%（默认 10%）
  → Teleop（**phase-09d 起两臂常驻 session**：无 Include 开关，`SessionSpec.arms` 不等于全部臂时 409）；
  `POST /api/session kind=hardware` 只支持 teleop，在任一臂导轨未归零、控制器有错误、监视器无样本或归零进行中时
  409。**导轨归零不再隐式发生**：驱动
  connect 见 `on_zero == 0` 直接拒绝（`RailNotHomedError`），归零只能由操作员在臂卡片点 **Home rail** 触发
  （维护操作 `home_rail`，仓库里唯一会让机械部件运动的维护操作）：先 dry-run 显示孪生对整段 0–0.65 m 行程、
  以该臂当前姿态、0.025 m 余量的扫掠判定，clear 才有确认按钮，滑台开到操作员**左**端（+X），≤ 45 s，
  只按寄存器（`on_zero`/`is_enabled`/`error`）判定成功。**phase-09d**（`phase-09d-rail-homing-planning.md`）：当前
  姿态挡住扫掠时不再直接拒绝——dry-run 同时用孪生规划一条与导轨位置无关的路径（每个路点对全部 131 个导轨位置
  无碰撞），面板说明"臂先按规划路径以 10% 折叠、再归零、然后保持该姿态"，确认后 `RailHomingJob`（REST 202，
  进度实时可见）只连该臂执行；D1"按最后一次监视样本冻结另一臂"只用于这一维护运动（teleop session 没有未选中臂）。
  session 结束时驱动 `set_mode(0) → set_state(4) → motion_enable(False)`，臂交还为停止、抱闸（D6），导轨保持
  归零标志。首次真机运行严格按 09c 文件末尾的"真机验收步骤"（按其 09d 头注修订）。
- 必读设计文档：
  - `docs/design/00-overview.md` §6（安全分层）、§7（bring-up）、§9（性能目标）
  - `docs/design/02-hardware.md`（netsetup/驱动真机行为）
  - `docs/design/11-safety-collision.md`（twin 校准与膨胀参数）
- 参考：`docs/research/network-manager.md` §2（目标机网络现状审计 — 待清理项清单）、
  `docs/research/xarm-python-sdk.md` §9（gotchas checklist）。
- 现场条件：真机臂上电、急停在手边、工作空间清场；操作者全程握物理急停。

## 范围

- **网络 reconcile（一次性，真机）**：`python -m apollo_mavis_v2_hardware.netsetup
  install`（polkit `.pkla` + `netdev` 组）→ `match` 自动匹配三臂 →
  `reconcile --apply` 清理目标机已知污染 — 去重两个同名 `xarm7_1` profile、剥离
  `xarm7_1`/`xarm7_2` 的 gateway（xarm7_2 的 gateway `192.168.1.1` 甚至在错误子网）、
  删除 `default via 192.168.1.1 dev enp36s0f0 metric 20100` 假默认路由、按 MAC +
  ifname 钉死 profile、`autoconnect yes` 优先级 50。**2026-09-04 已完成**（`netsetup install` + `match`，两条 profile
  `mavis_manipulation_arm`(enp36s0f1) / `mavis_viewpoint_arm`(enp36s0f0) 已按 MAC + ifname 钉死，
  旧 `xarm7_*` profile 与 metric 20100 假默认路由已不存在，`/etc/apollo-mavis-v2/nic_map.json`
  含两臂；见 `phase-09-todo.md` A1 与 `docs/deploy/DEPLOYMENT.md` S5——dispatcher 钩子仍指向开发者
  venv，部署到 ops 账号时要重跑 install）。
- **硬件逐级点亮**（每步通过才进下一步；顺序 = 风险递增；对照 11-safety §14.3
  硬件验收清单执行）：
  1. 只动 Manipulation Arm、不动导轨、低速（phase-09c/09d：Hardware 页签 **Speed** 10%；09d 起 session 必含
     两臂——Perception Arm 一起连上、由门禁孪生看护、不握 clutch 就只保持，其 C19 须先清掉；两条导轨都必须先按
     步骤 2 归零，否则 session 409 "rail not homed"——所以步骤 2 的归零在时间上先于首次 session）：bring-up、
     controller backstops 生效并**回读**
     （`set_tcp_load` 最先 → `set_collision_sensitivity(3)` → self-collision +
     tool model → 可选 reduced-mode TCP boundary → `set_collision_rebound(False)`；
     参数来自 `ArmConfig`（phase-09b：`configs/mavis_v2.yaml` grip 0.95 kg @ (0, 0, 60) mm、
     view 0.55 kg @ (0, 0, 90) mm、灵敏度 3——**暂定值，先称重再定**）；会话前可在 Hardware 页签
     **Apply safety settings** 一键应用，监视器回读 `hardware_monitor.arms[*].collision_sensitivity /
     tcp_load_kg / backstops_match`；会话中 `get_reduced_states()` 回读入会话记录、手拍触发 C31）、
     100 Hz servo 流稳定性。
  2. rail 自动探测 + **操作员触发归零**（phase-09c：臂卡片 **Home rail** → `HomeRailSheet` dry-run 扫掠判定
     clear → 确认 → 滑台开到操作员左端，卡片显示 `rail 0.000 m`；09d：判定不 clear 时面板给出预定位规划，确认后
     臂先以 10% 沿位置无关路径折叠、再归零、归零后保持该姿态——看面板里的阶段进度；**立刻看 `*_align` 叠加窗口**，孪生导轨/基座
     与真机不重合、镜像则改 `hardware_session.rail_flip: true` 重启再看；两臂各归零一次，每次上电后重做）+
     `command_rail` 钳制验证（session 中，导轨跟随留到步骤 7 之后）。
  3. gripper（classic 与 G2 各验一台，若在场）。
  4. 数字孪生对真机：twin fidelity — 6 个示教位姿（贴近桌面/rail/他臂），twin
     `clearance()` 与卷尺实测一致到 **δ/2（4 mm）以内**，否则先修外参/网格；twin
     渲染 vs 真机相机画面对拍——**方法 = phase-09a 的叠加窗口**：Hardware 页签的
     `grip_wrist_align` / `view_wrist_align`（孪生按真机关节角/导轨位置正运动学后，从同一台
     腕部相机、用 D435i 彩色内参渲染，只保留臂/导轨/夹爪/麦克风/相机体像素，淡黄半透明叠在
     真机画面上；蓝色细线 = 孪生的桌沿/障碍物边缘）。导轨归零 + 使能后叠加窗口下沿的小字
     "rail not homed · twin assumes 0.65 m" 应消失（`rail_pos_m` 取代 `rail_fallback_m`）；
     若孪生臂整体转 180° 或导轨方向反了，用 `twin_overlay.joint1_offset_rad` /
     `hardware_session.rail_flip`（phase-09c 起叠加与门禁 / 扫掠孪生共用一个键，旧键
     `twin_overlay.rail_flip` 仍作别名）诊断（默认恒等，关节约定已在 2026-09-04 验证为恒等）。
  5. 双臂 + gate：10% 速度逼近课目验证 clamp/block 在接触前发生；
     deep-penetration 课目 — free-drive 进膨胀带后重新使能，IK 恢复梯退出且无
     C24/C31。
  6. 完整 teleop → collection → DAgger 各一个短会话。
- **digital-twin 校准**：真机各臂 `base_in_world` 与 rail 原点实测录入
  `WorkcellConfig`；相机外参标定文件接入；对拍验证 — 真机摆若干标定位姿，比较
  twin FK 的 TCP 与控制器上报 TCP；验证 rail 位置回填 world TF 后 twin 跟手；
  按现场布局复核 `geom_inflation_m`（默认 0.008，紧凑桌面误报则考虑对凹形链节
  做凸分解而不是砍膨胀）。
- **watchdog/恢复真机课目**：拔控制 WS（模拟浏览器崩溃）⇒ 斜坡停（0.2 s deadman +
  0.1 s ramp，总停 ≤ 0.3 s）；触发一次 controller 错误（如轻推碰撞检测 C31）⇒ session 进入
  FAULT、该臂停发、另一臂继续，Cockpit 出现红色 `FaultBanner`（"CONTROLLER FAULT — <臂> C31 …"）；
  可恢复码在驱动预算内（3 次 / 30 s）自动走恢复序列 + 从实测位置重播种（横幅转琥珀 RECOVERING），
  预算耗尽 / 不可恢复码 / 急停后 LATCHED 则点横幅的 **Clear errors & resume**（phase-09b，
  `POST /api/hardware/arms/{arm_id}/maintenance {op: recover}`）；两种情况都要**重新握持 clutch /
  松开所有键**才回到 RUNNING，臂不跳变。物理急停中途按下 ⇒ 松开急停后点 **Clear errors & resume**，
  恢复后首个下发步距测量位 < 1 mm + UI ack 流程。无 session 时的控制器错误（如 Perception Arm 的
  C19）用 Hardware 页签臂卡片的 **Clear errors**（不使能、不运动）。
- **submodule 化**：五个子仓各自打 tag / 推远端后，在 ws 仓
  `git submodule add <url> apollo-mavis-v2-<name>` × 5，更新 `.gitignore`
  （移除子仓忽略项）、`README.md`、`CLAUDE.md`（克隆说明改为
  `git clone --recurse-submodules`）。
- **CI 接线**（每仓 + ws 聚合）：core = ruff → pytest → schema `--check`；
  sim/hardware/runtime = `uv sync && uv run pytest`（sim 仓额外跑
  `test_mujoco_semantics.py` 膨胀语义哨兵；硬件相关测试全部 fake-SDK，CI 无真机）；
  guardrail 回归 `python -m apollo_mavis_v2_sim.tools.guardrail_check --all` 同时挂在
  sim CI 与 runtime CI（integration job，<30 s）；ui = `pnpm lint && pnpm gen:check
  && pnpm test && pnpm build`；需要 GPU/EGL 的 job 标注 self-hosted runner。

Out of scope：新功能；多操作员/远程访问；性能调优超出 §9 目标的部分；
NVENC 视频编码优化（除非验收不达标）。

## 交付物

- `docs/acceptance/<cell_id>-<date>.md`（11-safety §14.3 清单的执行记录：每项勾选 +
  实测数字 + 签核；未验收的 cell 上跑会话时 UI/日志要打醒目警告）。
- 更新后的 `WorkcellConfig` 真机配置文件（含标定值）与 netsetup state JSON。
- ws 仓 submodule 结构 + 各仓 CI 配置文件（GitHub Actions 或等价）。
- 发现缺陷的回改 commit（各子仓）。

## 验收标准

网络（真机执行）：

- [ ] `nmcli -g NAME,UUID connection show` 无重名 arm profile；
      `ip route show default` 只剩真实 internet 路由（无 metric 20100 假路由）。
- [ ] SSH（非本地会话）下 `netsetup verify` 免 sudo、免弹窗全绿；重启机器后
      autoconnect 生效，`verify` 快速路径直接通过（无需重新探测）。
- [ ] 三臂 TCP 502 全部可连；`arm.sn` 与 config 匹配（无插线错位）。

硬件控制（真机执行，急停在手）：

- [ ] 100 Hz servo 流 30 min 无 C24（速度超限）/无静默 mode 0 掉落未被恢复；
      每 tick cartesian 步进实测 < 10 mm（日志统计）。
- [ ] rail：`get_linear_track_registers` 探测正确；每次上电由操作员在 UI 上归零一次（phase-09c **Home rail**：
      dry-run 扫掠判定 clear → 确认 → 滑台到操作员左端 → 卡片 `rail 0.000 m`，`hardware_monitor.arms[*]`
      `rail_homed / rail_enabled true`；归零前 `POST /api/session kind=hardware` 必须 409 "rail not homed"；
      驱动 connect 从不调用 `set_linear_track_back_origin`）；command 0.7 m 被钳到 0.650 m；rail 移动时 twin 中臂
      基座同步平移；session 结束后臂回到 `state 4`、抱闸（D6），导轨保持归零标志。
- [ ] 控制路径预算：hardware 模式 tick（IK + twin check + gate + SDK 下发）p99
      < 2 ms（overview §9），twin check 实测落在 0.24–0.75 ms 带内（3 臂时）。
- [ ] 双臂逼近课目（10% 速度）：gate 在 hull 接触前 block（UI 红横幅 + 被钳命令
      不下发）；解除后恢复顺滑；deep-penetration 课目 IK 恢复梯退出无 C24/C31。
- [ ] backstop 回读：`get_reduced_states()` 与配置一致；无 session 时监视器回读
      `hardware_monitor.arms[*].backstops_match true`（灵敏度 3、`tcp_load_kg` ≈ 配置，
      phase-09b **Apply safety settings** 之后）；sensitivity 3 下手拍触发 C31。
- [ ] watchdog 课目：断 WS 后臂总停 ≤ **0.3 s**（0.2 s deadman + 0.1 s ramp）；
      恢复连接后必须先空 held 集才恢复运动。
- [ ] 错误恢复课目：人为触发 C31/C22 后驱动自动恢复且**重播种自当前位姿**（无跳变），
      Cockpit `FaultBanner` FAULT（红）→ RECOVERING（琥珀）→ 重新握持 clutch 后消失；预算耗尽 /
      物理急停后用横幅的 **Clear errors & resume**（phase-09b）恢复，首个下发步 < 1 mm；
      无 session 时 Hardware 页签 **Clear errors** 清 C19 后 `error_code` 回 0、关节不动
      （< 1e-3 rad）；UI 错误码 chip（红色 `C<code>`）全程正确。
- [ ] twin 校准：6 个示教位姿上 twin `clearance()` 与实测差 ≤ **4 mm**（δ/2）；
      twin FK TCP vs 控制器上报 TCP 误差 < 5 mm；rail 移动时 twin rail 位姿跟踪
      实测 ≤ 5 mm；twin 渲染与真机相机对拍无明显姿态错位——以 phase-09a 的 `*_align` 叠加窗口为准：
      两臂/导轨/夹爪的淡黄轮廓与真机画面重合，导轨归零、使能后小字不再显示 fallback。
- [ ] 真机 collection 会话：录 3 个 episode（save×2 discard×1），数据集回读通过
      phase-07 的全部断言；`robot_type` 无 `_mujoco` 后缀。
- [ ] 真机 DAgger 短会话：接管/交还无跳变；trainer 在 GPU 1（`nvidia-smi` 验证）、
      控制端点 `tcp://127.0.0.1:5757` 可查 status，控制环 tick 率不受训练影响。
- [ ] 真机 inference 短会话：Space 安全逃生接管有效且被 gate 约束；会话目录零
      dataset 产物；"steer to safe → terminate" 路径演练一次。
- [ ] 视频：真机 3–5 路 640×480@30（相机 + twin）单观看者流畅，UI latency badge
      稳定。

工程收尾：

- [ ] `git clone --recurse-submodules <ws>` 后按各仓 README 可完整构建。
- [ ] 五仓 CI 全绿（含 core 的 schema `--check`、sim 的 `test_mujoco_semantics.py`
      与 sim/runtime 双侧的 `guardrail_check --all` 回归）。
- [ ] `docs/acceptance/<cell_id>-<date>.md` 全部条目有实测数字与签核。

## 注意事项

- **顺序即安全**：先单臂低速、后双臂、最后全速；每级课目前用 sim 的同场景预演一遍。
  reduced-mode/fence 是控制器侧独立后备（错误 C35），不要因为有 twin gate 就跳过配置。
- reconcile 绝不触碰当前承载 SDK 流量的活动 profile；改网络时确保没有会话在跑。
- "ping 通但 502 拒绝" = 控制箱还在启动（IP 栈先于控制服务 ~1–2 min 起来）——
  轮询等待，不要判为匹配失败去重探 NIC。
- 别在 SDK 会话期间开 UFACTORY Studio Live control（抢 mode/state）。
- `emergency_stop()` 是软件停（state 4 循环、不清错、非 STO）— 课目里所有"急停"
  一律指物理按钮；软件路径只是补充。
- twin 校准的已知风险：mavis rail mesh 几何可能与实物线性电机有差 — rail 附近的
  clearance 数字在实测复核前不要信任（`docs/research/mujoco-xarm7-sim.md` §8）；
  菜单库 actuator 增益未辨识 — 如需高保真 sim-DAgger，记录真机阶跃响应回调
  `gainprm/biasprm/frictionloss/armature`（可开 issue 延后）。
- rail 掉线表现为控制器错误 **111**（控制箱外部 485 通信）— 恢复路径要覆盖。
- 固件差异检查：gripper 电流流入观测需 fw ≥ 2.7.100；servo cartesian 需 ≥1.4.1；
  记录每台臂的固件版本入 checklist。
- submodule 转换后 `docs/prompts/` 与 `docs/design/` 留在 ws 仓 — 子仓 README 链接
  回 ws 仓文档，不复制。
- CI 里任何需要 GPU/EGL 的任务（渲染、guardrail e2e）标注清楚 runner 要求；
  纯 CPU 测试与 GPU 测试分 job，避免全线红。
