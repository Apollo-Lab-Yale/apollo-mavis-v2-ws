# Phase 03 — apollo-mavis-v2-sim（二）：MinkIKSolver、DigitalTwin、ResetPlanner、基准复现

## 目标

在 phase-02 的场景/模型基础上实现运动与安全的核心算法层：mink QP 微分 IK
（7/8-DoF + 碰撞约束 + 四项 RelaxedIK 移植改进）、kinematic-only 数字孪生
（gap 膨胀 + 碰撞检查 + clearance）、RRT-Connect 复位规划器、safety-layer CI 回归
脚本 `tools/guardrail_check.py`，并用基准脚本复现研究阶段在本机测得的性能数字。

## 前置条件

- 依赖 phase：01、02。
- 必读设计文档：
  - `docs/design/00-overview.md` §3.3（IKSolver / DigitalTwinInterface 契约）、§3.4（planner）、§6（分层安全）
  - `docs/design/03-sim.md`（IK solver 与 twin 的实现规格）
  - `docs/design/11-safety-collision.md`（膨胀语义、allowed-pair 过滤、planner 校验 — 事实来源）
- 参考：`docs/research/collision-ik.md`（mink 用法与移植清单）、
  `docs/research/xarm7-ik.md`（legacy solver 兼容约定与 mink 基准）、
  `docs/research/mujoco-xarm7-sim.md` §4（twin 配方与实测成本）。

## 范围

- **MinkIKSolver**（`ik.py`，实现 core `IKSolver` Protocol，mink==1.3.0 + daqp）：
  每 workcell 一个 `mink.Configuration`（共享复合 twin/sim 模型）；每臂
  `FrameTask(frame_name=f"{arm_id}_link_tcp", frame_type="site")` + `PostureTask`
  （`posture_cost_joint=5e-2`、`posture_cost_rail=5.0` — rail 昂贵、臂优先动关节；
  非活跃臂钉死：posture cost 1e4 指向 `sync_passive` 的测量值 + Δq 切片清零）+
  `ConfigurationLimit` + `VelocityLimit` + `CollisionAvoidanceLimit`（geom_pairs 覆盖
  自碰/跨臂/环境，`gain=0.85`，`minimum_distance_from_collisions =
  safety.geom_inflation_m + 0.002`（10 mm — 刻意**高于** gate 阈值 2 mm，收敛解永远
  不触 gate），`collision_detection_distance=0.05`）。纯 sim 模式（gate 默认关）
  **省略** CollisionAvoidanceLimit；`safety_debug` 与 hardware 模式包含。返回 core
  `IKResult{q（core 序，rail 末位 q[7]）, pos_err_m, rot_err_rad, diverged,
  active_collision_rows, solve_time_s}`；residual 监控：`pos_err > 0.02 m` 或
  `rot_err > 0.35 rad` 连续 10 tick ⇒ `diverged=True`（速度级 IK 静默收敛，runtime
  据此重锚 teleop 目标）。另有 `solve_to_convergence(max_steps=50, n_restarts=4)`
  （one-shot 远目标：goto/planner 端点，收敛判据 <1 mm ∧ <0.01 rad，全败抛
  `IKUnreachableError(best_result)`）与 `reset(arm_id, q_measured)`（重播种 + 清
  accel/jerk 历史 — 恢复/takeover 后强制）。
- **四项 RelaxedIK 移植**（solve 内的薄层）：
  1. 关节空间 accel/jerk 正则（3 深 Δq 历史，`w_accel=1e-2`、`w_jerk=1e-3`，线性入
     QP cost；`reset()` 清历史）；
  2. 近障碍自适应姿态权重松弛（ECAA）：`s = max(0, (d_warn − d_min)/d_warn)`
     （`d_warn=0.05 m`，d_min 取上一 tick twin clearance），目标权重
     `orientation_cost·a/(a+s)`（`a=0.05`），每 tick 变化 ≤ 基准的 2%，下限 10%；
     位置跟踪永不松弛；
  3. 逐 DoF 平底容差（QP 前对 6-D 误差做 shrinkage；如采集时 `tol[5]=π` 放开 tool roll）；
  4. 每 tick 活跃碰撞约束行数上限 `max_collision_rows = 12`
     （= `safety.max_active_constraint_rows`，取 `dist − dmin` 最小的 top-12 对）。
- **不可行 QP 恢复梯**（11-safety §8）：① 去 FrameTask 只留 PostureTask@q_meas 的
  retreat-only 重解 → ② `bound_relaxation = -0.002` 重试 → ③ hold + `penetration`
  事件；每级输出仍过 gate。
- **DigitalTwin**（`twin.py`，实现 core `DigitalTwinInterface`）：与 sim 独立的
  model/data 对（同 scene id 重建，`apply_inflation(model, total_gap_m)` 膨胀）；
  kinematic-only — `sync(states)` 写测量 qpos，`check(q_by_arm)` 在 **commanded**
  配置上 `mj_kinematics` + `mj_collision` 后恢复测量值（无状态，+15 µs），
  **永不 `mj_step`**。膨胀：`margin = 0`、每 geom `gap = δ/2`（detection-only 无力；
  配对阈值是两 geom 值之**和**，故 δ/2/geom 达成 δ 总裕度；默认
  `geom_inflation_m = 0.008`（8 mm 总量），`safety_debug` 场景用 0.025）。
  `check_config(q_full)`（planner 快路径）、`clearance(distmax=0.05) ->
  list[PairClearance]`（`mj_geomDistance`，telemetry 频率调用、不进 100 Hz gate）、
  `set_grasp_whitelist`。`build_monitored_pairs(model)` + `AllowedPairs`（MJCF
  `<exclude>` + 每臂 `link_base↔link1` + rail 链 + `safety.allowed_pairs_extra` +
  会话级抓取白名单）；init 审计：home keyframe 下有未解释接触 ⇒ **拒绝武装 gate**。
- **ResetPlanner**（`planner.py`）：joint-space RRT-Connect，收发 core 的
  `PlanRequest{q_start, q_goal, arm_order?, timeout_s=5.0/臂, max_step_rad=0.05
  （rail 0.01 m）}` / `PlanResult{ok, waypoints, failure: goal_in_collision|
  start_in_collision|timeout, failing_pair}`。**逐臂顺序**规划（v1 策略）：臂 k 规划时
  `<k` 冻在 goal、`>k` 冻在 start；顺序默认"最深入 warn 带者先"，失败反序重试；
  validity = `twin.check_config`（planner 私有 `MjData`）；起点在膨胀壳内的对做
  hysteresis 白名单（首次超出 inflation+5 mm 后重新武装）；50 次随机 shortcut +
  时间参数化（0.6 rad/s、2 rad/s²，rail 0.1 m/s）。执行在 runtime（phase-05）；
  本 phase 只出轨迹并验证全程无碰。
- **guardrail 脚本**（`tools/guardrail_check.py` — 本 phase 交付、即安全层的 CI
  回归，规格 = 11-safety §5.1，binding）：headless、虚拟 tick 配速、固定种子；四个
  场景 `env_table_descend` / `env_pedestal_sweep`（臂↔环境）、`cross_arm_head_on` /
  `cross_arm_rail_converge`（臂↔臂），每个按 `safety_debug` 组合（SimWorkcell 演真机
  + 独立 twin + gate 语义（hold-last-safe，11-safety §7）+ IK 避障行），断言 A1–A5
  （见验收）；ground truth = 零膨胀物理模型的 `dist <= 0` 接触。phase-05 的 runtime
  `SafetyGate` 必须与本脚本的 gate 语义一致并把脚本接入 runtime CI。
- **benchmarks/**：复现研究数字的脚本（见验收）。

Out of scope：runtime `SafetyGate`/`ControlLoop` chokepoint 接线与 `CollisionEvent`
WS 广播（phase-05）；真机 twin 校准与硬件验收清单（phase-09）。

## 交付物

- `src/apollo_mavis_v2_sim/{ik,twin,planner}.py` + `tools/guardrail_check.py`；
  `MinkIKSolver`、`DigitalTwin`、`ResetPlanner`、`apply_inflation`、
  `build_monitored_pairs` 公共符号（03-sim §1 布局）。
- `python -m apollo_mavis_v2_sim.tools.guardrail_check --all [--no-ik-avoidance]`
  可独立运行，退出码 0 = 全部断言通过（CI 直接接）。
- `benchmarks/bench_ik.py`、`benchmarks/bench_twin.py`（打印均值/p99，README 记录本机数字）。
- `tests/`：IK 收敛与 residual/diverged、rail 冗余（posture 权重下 rail 不吸收小平移）、
  ECAA 权重单调性与 2%/tick 限速与 10% 下限、约束行数上限（12）、
  `test_inflation_semantics.py`（MuJoCo 版本钉哨兵：margin=0/gap 无接触力、
  `efc_address == -1`、阈值求和）、`test_twin_excludes` + at-home 审计、
  grasp 白名单、planner 轨迹无碰 + 失败分类、guardrail 全场景 A1–A5。

## 验收标准

在 `apollo-mavis-v2-sim/` 内执行（本机 = Threadripper PRO 5975WX + RTX 4090，单线程基准）：

- [ ] `uv run pytest` 全绿。
- [ ] `uv run python benchmarks/bench_ik.py`：servo 式 warm-start 循环，7-DoF
      ≈ 116 µs/步（~8.6 kHz），8-DoF rail ≈ 113 µs/步（~8.8 kHz）；验收阈值：
      **单臂 ≤ 0.5 ms/步均值**（overview §9 预算 ~0.12 ms/臂），跟踪误差 ≤ 0.1 mm。
- [ ] one-shot 远目标（rail 链，迭代收敛）：18–28 QP 步、2–4 ms、<0.1 mm，rail 自动就位
      （阈值 ≤ 10 ms）。
- [ ] `uv run python benchmarks/bench_twin.py`：3 臂 + gripper，`gap` 膨胀开启 —
      home 位姿 ≈ 240 µs/tick、对抗性贴近位姿 ≈ 750 µs/tick；验收阈值：**3 臂
      twin check ≤ 1 ms/tick**（overview：0.24–0.75 ms 实测带）。`mj_geomDistance`
      全 arm0×arm1 扫描（289 对，distmax=0.2）≈ 0.29 ms。
- [ ] 膨胀语义单元测试（CI 常驻，防 MuJoCo 版本漂移）：`margin=0, gap=δ` 时
      `mjData.contact` 出现 `efc_address == -1` 的 detection-only 接触且约束力为零；
      配对阈值 = 两 geom gap 之和。
- [ ] 不可达目标测试：连续 10 tick 超 residual 阈值（0.02 m / 0.35 rad）后
      `IKResult.diverged == True` 且不抛异常（静默冻结 = 错误行为）。
- [ ] `uv run python -m apollo_mavis_v2_sim.tools.guardrail_check --all` 退出码 0，
      总耗时 < 30 s（虚拟 tick）。四场景（env_table_descend / env_pedestal_sweep /
      cross_arm_head_on / cross_arm_rail_converge）× {IK 避障开, 关} 全部满足：
      **A1** 先于任何真接触发出 `CollisionEvent(kind="blocked")`（零膨胀 ground-truth
      接触数 = 0）；**A2** 首次 blocked 时目标对 clearance ∈ `(0, geom_inflation_m +
      min_clearance_m]` 且事件的 `min_clearance_m` 与 `mj_geomDistance` 复算差
      ≤ 1e-6 m；**A3** block 期间 `max |q_sent − q_sent(t_block)| ≤ 1e-4`（hold 就是
      hold）；**A4** 反向 twist 后 100 tick 内 `cleared`、clearance 不减；
      **A5** `--no-ik-avoidance` 下 gate 单独仍满足 A1–A4，IK 开时擦边变体 0 次 block。
- [ ] ResetPlanner 测试：双臂贴近场景（相距 30 mm）互换/回 home，≤2 种顺序内规划
      成功，全 waypoint 经膨胀 twin `check_config` 无碰；不可能变体返回
      `goal_in_collision` + 正确 `failing_pair`；单臂规划 wall-time < 5 s（timeout_s）。

## 注意事项

- **`link_base↔link1` 永久近接触坑**：MuJoCo 的 parent-child 自动过滤在 parent 焊死到
  world 时失效 — base 固定后 `armK_link_base` vs `armK_link1` 在 qpos=0 时 dist≈0.0002 m。
  必须每臂加显式 `<exclude>`/allowed-pair，并在膨胀下审计其它相邻 hull 对。
- mesh geom 无法按实例膨胀（`mesh scale` 是编译期属性）— `gap` 是正道；环境 mesh 需要
  更强膨胀时另烘焙放大的凸包碰撞副本（`contype/conaffinity` 只碰撞、`group="3"`、alpha 0）。
- `mj_geomDistance` 的正距离需要默认的 native CCD 管线；legacy CCD 给错误距离 — 不要
  禁用 `mjDSBL_NATIVECCD`。
- mink 的 `CollisionAvoidanceLimit` 对负距离（浅穿透）只允许张开速度 — 这是想要的
  "修复"行为；不要模仿 CollisionIK 的 "already penetrating ⇒ skip solve"（会冻死）。
- relaxed_ik_core 一律不要作为运行时依赖（main 分支无环境避障 + chain-0 自碰 bug；
  collision-ik 分支在现代 Rust 上编译不过）— 只移植上面四个想法。
- legacy xarm7-ik 的约定（flange 目标 + 隐含 180°-about-X、rail 0.74 m 界）不进入本层；
  兼容转换在 core（phase-01 已做），本层只认 `link_tcp` + 0.65 m。
- twin 与 sim 必须是**两套** model/data：twin 的 proximity 接触绝不能扰动 teleop 物理。
- daqp/qpsolvers 与 mink==1.3.0 一起锁版本；QP 求解器换实现会改 residual 数值特性。
- planner 的 validity check 吞吐 ~4k–60k checks/s/核 — 多线程时每线程一个 `MjData`。
