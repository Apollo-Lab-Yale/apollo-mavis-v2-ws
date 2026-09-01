# Phase 09 — 真机集成验证、twin 校准、netsetup reconcile、submodule 化、CI

## 目标

在目标机器（Ubuntu 22.04、2× RTX 4090、3 NIC、1–3 台真实 xArm7 ± rail）上做
hardware-in-the-loop 验证：跑通 netsetup reconcile、逐级点亮硬件 teleop/采集/DAgger、
校准数字孪生，并完成工程收尾 — 五个子仓转 git submodule、CI 接线。本 phase 大部分
是**执行清单**而非新代码；发现的缺陷回改对应仓库。

## 前置条件

- 依赖 phase：01–08 全部完成。
- 必读设计文档：
  - `docs/design/00-overview.md` §6（安全分层）、§7（bring-up）、§9（性能目标）
  - `docs/design/02-hardware.md`（netsetup/驱动真机行为）
  - `docs/design/11-safety-collision.md`（twin 校准与膨胀参数）
- 参考：`docs/research/network-manager.md` §2（目标机网络现状审计 — 待清理项清单）、
  `docs/research/xarm-python-sdk.md` §9（gotchas checklist）。
- 现场条件：真机臂上电、急停在手边、工作空间清场；操作者全程握物理急停。

## 范围

- **网络 reconcile（一次性，真机）**：`python -m apollo_xarm7_hardware.netsetup
  install`（polkit `.pkla` + `netdev` 组）→ `match` 自动匹配三臂 →
  `reconcile --apply` 清理目标机已知污染 — 去重两个同名 `xarm7_1` profile、剥离
  `xarm7_1`/`xarm7_2` 的 gateway（xarm7_2 的 gateway `192.168.1.1` 甚至在错误子网）、
  删除 `default via 192.168.1.1 dev enp36s0f0 metric 20100` 假默认路由、按 MAC +
  ifname 钉死 profile、`autoconnect yes` 优先级 50。
- **硬件逐级点亮**（每步通过才进下一步；顺序 = 风险递增；对照 11-safety §14.3
  硬件验收清单执行）：
  1. 单臂、无 rail、低速：bring-up、controller backstops 生效并**回读**
     （`set_tcp_load` 最先 → `set_collision_sensitivity(3)` → self-collision +
     tool model → 可选 reduced-mode TCP boundary → `set_collision_rebound(False)`；
     `get_reduced_states()` 回读入会话记录、手拍触发 C31）、100 Hz servo 流稳定性。
  2. rail 自动探测 + 归零 + `command_rail` 钳制验证。
  3. gripper（classic 与 G2 各验一台，若在场）。
  4. 数字孪生对真机：twin fidelity — 6 个示教位姿（贴近桌面/rail/他臂），twin
     `clearance()` 与卷尺实测一致到 **δ/2（4 mm）以内**，否则先修外参/网格；twin
     渲染 vs 真机相机画面对拍。
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
  0.1 s ramp，总停 ≤ 0.3 s）；触发一次 controller 错误（如轻推碰撞检测）⇒ 驱动自动
  恢复序列 + 流重播种，臂不跳变；物理急停中途按下 ⇒ 恢复后首个下发步距测量位
  < 1 mm + UI ack 流程。
- **submodule 化**：五个子仓各自打 tag / 推远端后，在 ws 仓
  `git submodule add <url> apollo-xarm7-<name>` × 5，更新 `.gitignore`
  （移除子仓忽略项）、`README.md`、`CLAUDE.md`（克隆说明改为
  `git clone --recurse-submodules`）。
- **CI 接线**（每仓 + ws 聚合）：core = ruff → pytest → schema `--check`；
  sim/hardware/runtime = `uv sync && uv run pytest`（sim 仓额外跑
  `test_mujoco_semantics.py` 膨胀语义哨兵；硬件相关测试全部 fake-SDK，CI 无真机）；
  guardrail 回归 `python -m apollo_xarm7_sim.tools.guardrail_check --all` 同时挂在
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
- [ ] rail：`get_linear_track_registers` 探测正确；每次上电归零一次；
      command 0.7 m 被钳到 0.650 m；rail 移动时 twin 中臂基座同步平移。
- [ ] 控制路径预算：hardware 模式 tick（IK + twin check + gate + SDK 下发）p99
      < 2 ms（overview §9），twin check 实测落在 0.24–0.75 ms 带内（3 臂时）。
- [ ] 双臂逼近课目（10% 速度）：gate 在 hull 接触前 block（UI 红横幅 + 被钳命令
      不下发）；解除后恢复顺滑；deep-penetration 课目 IK 恢复梯退出无 C24/C31。
- [ ] backstop 回读：`get_reduced_states()` 与配置一致；sensitivity 3 下手拍触发
      C31。
- [ ] watchdog 课目：断 WS 后臂总停 ≤ **0.3 s**（0.2 s deadman + 0.1 s ramp）；
      恢复连接后必须先空 held 集才恢复运动。
- [ ] 错误恢复课目：人为触发 C31/C22 后驱动自动恢复且**重播种自当前位姿**（无跳变）；
      物理急停恢复后首个下发步 < 1 mm；UI 错误码 chip 全程正确。
- [ ] twin 校准：6 个示教位姿上 twin `clearance()` 与实测差 ≤ **4 mm**（δ/2）；
      twin FK TCP vs 控制器上报 TCP 误差 < 5 mm；rail 移动时 twin rail 位姿跟踪
      实测 ≤ 5 mm；twin 渲染与真机相机对拍无明显姿态错位。
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
