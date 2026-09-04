# Phase 08 — DAgger 模式 + AsyncTrainer + PolicyRunner + Inference 模式

## 目标

实现 HG-DAgger 语义的在线数据聚合与异步训练闭环：TakeoverGate（Space 切换、三态
control_mode）、DAgger 录制（executed/policy 双 action + policy_version）、独立进程
AsyncTrainer（GPU 1，checkpoint 版本化 + episode 边界热换）、PolicyRunner，以及复用
同一 TakeoverGate 的 inference 模式（安全逃生、永不录制）。激活 UI 的 DaggerPanel
与 takeover 指示。

## 前置条件

- 依赖 phase：07（schema 已含 `intervention/action_source`）。
- 必读设计文档：
  - `docs/design/12-dagger-protocol.md`（本 phase 事实来源：gate/聚合/训练/热换协议）
  - `docs/design/00-overview.md` §4.3–4.4（DAgger/Inference 模式）、§6（gate 对 policy 同样权威）
  - `docs/design/04-runtime.md`（PolicyRunner 与 session 编排）
- 参考：`docs/research/dagger-online-training.md`（HG-DAgger/hil-serl/lerobot 依据）、
  `docs/research/lerobot-data.md` §6。

## 范围

- **TakeoverGateImpl**（`dagger/gate.py`，实现 core `TakeoverGate` Protocol）：
  Space = 显式 toggle（`ActionMsg{takeover_toggle}`，**无参** — 永远作用于服务端
  权威 active arm；绝不进 `KeysMsg.held`）；转移图：`AUTONOMOUS → TRANSITION
  →(T_blend 自动)→ HUMAN`，TRANSITION 中再按 = 中止回 AUTONOMOUS，HUMAN 再按 =
  交还；`T_blend = dagger.t_blend_s` 默认 **0.3 s**（合法 0.2–0.5）；每次切换发
  `GateEvent{arm_id, mode, t_mono, seq, source}`；episode 边界 `reset()` 全回
  AUTONOMOUS。**同一时刻至多一臂** engaged：其余 policy 臂冻结（继续查询 policy 记
  反事实、执行 hold，帧仍是普通 policy 帧，telemetry `frozen_arms`）；engaged 期间
  Tab / 指向他臂的 toggle 一律 `AckMsg{ok:false, detail:"takeover active"}`；
  HUMAN 中 deadman 只归零 twist、gate **停留在 HUMAN**。
- **GatedPolicyExecutor / PolicyRunner / ActionAnchor**（`dagger/loop.py` +
  `dagger/policy_runner.py`）：policy 率 10–30 Hz 推理（GPU 0）、100 Hz servo 插值；
  **delta-EE（canonical）动作施加于当前测量位姿**（`target = measured ⊕ Δ`，
  hil-serl 机制 — 人↔策略双向切换无跳变）；`ActionAnchor.on_gate_event` 在切换时
  重锚到测量位姿并清 pending chunk；`abs_ee`/chunk 型策略交还时 `policy.reset()` +
  以当前观测重查询 + `SlewLimits{lin 0.15 m/s, ang 1.5 rad/s, window_s 0.4}` 限斜率
  过渡；`joint` 型窗口内 `max dq = 0.05 rad/tick`。policy 动作与人类动作一样逐 tick
  过 twin gate（gate 钳过的值才是记录值）。policy 超时（period + 50 ms）⇒ 向最后
  动作插值 ≤5 个周期后 hold；NaN 3 次/episode ⇒ 全臂 hold + `PolicyAnomalyEvent` +
  建议 takeover + `rollback()`；AUTONOMOUS 中连续 30 tick 被 gate block 同样报警。
- **DaggerRecorder**（`dagger/recorder.py`，叠在 phase-07 recorder 上）：附加列
  （12-dagger §4 逐字）— `control_mode`{int8, labels `{0: policy, 1: human,
  2: takeover_transition}`}、`policy_action`{float32 (D,), names 与 `action` 相同，
  info `counterfactual: true`，未查询 tick 置 **NaN**}、`policy_version`{int32,
  info 带 run_id}；`action` = **executed_action**（post-twin-gate、已转换到该臂
  canonical frame 的实际执行值，人类修正在执行与录制**之前**转换）；
  `intervention = (control_mode != 0)`；`action_source` = 3（takeover）当人执行、
  否则 0（policy）。DAgger episodes 追加到**专用** repo
  `apollo/xarm7_{task}_{n}arm_{conv}_dagger_{run_id}`，永不改动 seed 数据集；
  episode sidecar 存 `gate_events` 与 `EpisodeSummary`。
- **AsyncTrainer**（`dagger/trainer/` 包，**独立进程** `python -m
  apollo_mavis_v2_runtime.dagger.trainer --config <json>`，`CUDA_VISIBLE_DEVICES=1`
  — GPU 1；渲染/推理占 GPU 0）：通道 = dataset 目录（只读）+ checkpoint 目录 +
  ZMQ REP 控制端点 **`tcp://127.0.0.1:5757`**（`dagger.trainer.port` 默认值；
  status/submit_episode/train_now/rollback/stop，client 1 Hz 轮询、2 s 超时）。
  - 触发：episode 边界（每次 `save_episode` 后 `submit_episode` + `EpisodeSummary`）
    **且** `new_label_frames ≥ min_new_labels`（默认 **100**）；每 burst
    `K = clip(4 × new_label_frames, 200, 1000)` 梯度步（BCFineTuner：AdamW
    lr=1e-5、batch 64、grad clip 1.0）。
  - 采样（`FiftyFiftySampler`）：50/50 — 上次 checkpoint 以来的新标签帧 vs 全
    aggregate（seed BC ∪ 全部 human 标签帧）；标签 = `control_mode == 1` 的帧
    （HG-DAgger Eq. 2；transition 帧排除）；数据经 `trainer_spool/ep_*.parquet`
    副本读取（live 写入器的 parquet 无 footer），绝不碰 LeRobot writer API。
  - 产出：`checkpoints/{run_id}/v{n:06d}/{state_dict.pt, trainer_state.pt,
    manifest.json(CheckpointInfo + sha256)}` + 原子 `LATEST` 指针 + `doubt.jsonl`；
    checkpoint 节流 `push_period_s = 5`；sanity gate（burst loss 有限、256 held-out
    帧前向有限、动作在 aggregate 分位界内）通过才推进 `LATEST`；trainer 自己**从不**
    回滚 — `LAST_KNOWN_GOOD` 由 runtime 维护。teardown：stop → 30 s SIGTERM →
    45 s SIGKILL；崩溃 ⇒ 冻结策略继续采集 + **仅一次** `--resume` 自动重启。
- **PolicyReloaderImpl**（`dagger/reloader.py`）：1 Hz 轮询 `LATEST`，校验 sha256 +
  `action_frame`/`action_space` 匹配后 `stage()`（只留最新）；`maybe_swap()`
  **只在 episode 边界**换权重（`load_state_dict` + policy 锁，<100 ms；绝不
  mid-episode、绝不 mid-chunk）；`rollback()` 回 `LAST_KNOWN_GOOD`（允许
  mid-episode）；`mark_good()` 在零 NaN、无 anomaly 的完整 episode 后推进指针。
- **InferenceSession**（`dagger/loop.py`）：与 DaggerSession 共用
  `GatedPolicyExecutor`，唯一分叉 = **`recorder=None`**（结构性保证：无
  `LeRobotDataset.create`、无 trainer 进程 — 逃生帧无处可写，不是靠 flag）；
  Space 仍走同一 TakeoverGate 作**安全逃生** — 人接管把系统带回安全构型后交还或
  终止会话；episode 键一律 nack；可选 eval 日志 = 纯 JSONL 标量。会话启动只接受
  **promoted deploy checkpoint**（`policy=None` 解析为已 promote 者，无则 409）；
  checkpoint 的 `action_frame`/`action_space` 与会话数据集约定不符 ⇒ 拒绝启动
  （camera-frame 策略还要按 10-frames §5.3 校验外参快照：pos ≤3 mm 且 rot
  ≤0.010 rad 加载、≤10 mm/0.035 rad 加载+警告、否则拒绝）。
- **UI 激活**：DaggerPanel（三态 chip：policy 蓝 "POLICY DRIVING" / human 绿
  "HUMAN TAKEOVER — recording intervention" / transition 琥珀 "TRANSITION — frames
  unlabeled"、`policy_version` + staged 徽标、takeover-rate、new-label 进度（/100）、
  trainer 状态 + loss、`trainer.state == "dead"` 红横幅）；Inference 页
  TeleopSurface **保持可用**（运动键照常流、服务端只在 `control_mode == "human"`
  时应用），常驻 chip "Policy driving — Space = takeover (safety escape)"；
  `InferencePanel` — takeover 时红色警示条纹 chip **"SAFETY ESCAPE — NOT
  RECORDED"**（绝不绿色/REC 图形）+ "Terminate session" 按钮（policy 驱动时带确认、
  **takeover 期间放大免确认**）；Landing 已按 phase-06 处理 policy 可用性禁用。

Out of scope：具体策略架构/训练超参调优（AsyncTrainer 用简单 BC/MSE 打通即可）；
会话间 round-based 全量重训 CLI（`apollo-dagger-retrain`，12-dagger §9 — 离线脚本
留 TODO）；`apollo-dagger-fsck` 恢复工具；多机分布式（明确单机）。

## 交付物

- `src/apollo_mavis_v2_runtime/dagger/{gate,loop,policy_runner,recorder,reloader,
  client}.py` + `dagger/trainer/{trainer,sampling,checkpoints,control}.py`
  （12-dagger §1 精确布局；trainer 以 `python -m apollo_mavis_v2_runtime.dagger.trainer`
  独立启动；InferenceSession 在 `dagger/loop.py`，无独立 inference 包）。
- 一个可在 sim 上端到端跑的玩具 policy（2 层 MLP delta-EE），用于测试与验收。
- UI：Dagger/Inference 页接线（DaggerPanel、InferencePanel）+ 测试。
- `tests/`：gate 状态机（纯逻辑 fake clock，12-dagger §13-1）、无跳变切换、
  reloader 边界换权重 + sha256/frame 校验、trainer 集成（触发/采样/sanity-gate/
  rollback，CPU 可跑）、inference 分叉（零 dataset、零 trainer）、故障注入
  （kill trainer / 截断 checkpoint / NaN policy）、e2e。

## 验收标准

- [ ] runtime `uv run pytest` 全绿；UI `pnpm test` 全绿。
- [ ] gate 状态机测试（fake clock）：toggle ⇒ `policy → takeover_transition
      →(0.3 s 自动)→ human`；transition 中再 toggle = 中止；human 再 toggle = 交还；
      `T_blend` ∈ {0.2, 0.3, 0.5} s 在 25/30 fps 下 transition 帧数精确
      （0.3 s@25 fps ≈ 7–8 帧）；`GateEvent` 每次切换恰一条且 seq 单调；engaged
      期间 Tab 与他臂 toggle 被拒（detail "takeover active"）；其余臂冻结且其帧
      `control_mode == policy`；deadman 在 HUMAN 中不改 gate 状态。
- [ ] 无跳变测试（sim e2e）：policy 驱动中接管、再交还 — 双向切换窗口内每 tick EE
      位移不超过 `SlewLimits`，任何 tick 不超固件步限（<10 mm）；chunk 策略交还时
      旧 chunk 被丢弃、重查询后 0.4 s 限斜率。
- [ ] 数据正确性：录一段含 2 次接管的 DAgger episode，回读断言 — `control_mode`
      labels == `{0: policy, 1: human, 2: takeover_transition}` 且三值都出现；
      `intervention == (control_mode != 0)`（transition 计 intervention）；human 帧
      `action_source == 3`、policy 帧 `== 0`；human 帧的 `action` 是 post-gate 人类
      动作且已转换到 canonical frame；`policy_action` 全程有值（未查询 tick 为
      NaN）；`policy_version` 仅在热换后变化；repo 名带 `_dagger_{run_id}` 后缀；
      sidecar 有 `gate_events`。
- [ ] AsyncTrainer e2e：spawn 真 trainer 进程（`python -m
      apollo_mavis_v2_runtime.dagger.trainer`，控制端点 `tcp://127.0.0.1:5757`）；
      <100 新标签帧不触发 burst；喂 ≥100 → episode 边界触发 → 产出
      `checkpoints/{run}/v000001/{state_dict.pt, trainer_state.pt, manifest.json}`、
      manifest sha256 与文件一致、`LATEST` 推进 → runtime 在**下一个** episode 边界
      （而非立刻）swap，telemetry `dagger.policy_version` 更新为
      `{run_id}/v000001`；标签索引只含 `control_mode == 1` 帧；checkpoint 频率
      ≤ 1 个 / `push_period_s`(5 s)。
- [ ] 崩溃隔离：kill -9 AsyncTrainer 进程，控制环 tick 率无扰动（100 Hz ± 1%），
      runtime 冻结策略继续跑、`trainer.state == "dead"` 上报、**恰一次** `--resume`
      自动重启；再杀一次 ⇒ 保持降级不再重启。
- [ ] rollback：注入 NaN 的 burst 产出 `sanity_ok=false` 版本且 `LATEST` 不推进、
      runtime 不 swap；截断 `state_dict.pt` ⇒ sha256 校验拒绝、权重不变；
      `rollback()` 精确恢复 `LAST_KNOWN_GOOD`。
- [ ] frame 校验：`CheckpointInfo.action_frame` 与会话约定不符 ⇒ 会话拒绝启动
      （`policy/dataset frame mismatch`）；staged checkpoint 不符 ⇒ 拒绝 stage。
- [ ] Inference 模式：会话全程零 dataset 文件、零 trainer 进程；Space 接管有效且
      同样被 twin gate 约束（`safety_debug` 下断言钳制）；episode 键回
      `ok:false`；接管后 "Terminate session" 路径工作；`policy=None` 且无 promoted
      deploy checkpoint ⇒ `POST /api/session` 409。
- [ ] UI：DaggerPanel 三态渲染/new-label 进度/trainer-dead 红横幅与 telemetry 一致；
      Inference 页 takeover 时渲染 "SAFETY ESCAPE — NOT RECORDED" 警示 chip（非绿、
      无 REC），Terminate 按钮 takeover 期间免确认；KeymapOverlay Space 行两页语义
      标签正确。

## 注意事项

- **HG-DAgger 而非 vanilla DAgger**：人接管期间拥有完全控制权（无 β 混合）；
  只有 human 帧成为训练标签 — policy 帧没有专家标签，不训。
- 反事实 `policy_action` 上游（hil-serl/lerobot）不存但我们要存 — Sirius 式加权与
  doubt 校准都需要它；HUMAN/TRANSITION 期间照常每个 policy tick 查询（GPU 0 便宜）；
  未查询/查询失败的 tick 写 **NaN 行**，不要伪造。
- 权重热换只在 episode 边界：mid-episode/mid-chunk 换权重会产生不可归因的行为跳变；
  接收线程 drain-latest（丢陈旧 checkpoint），swap 点单一。
- 训练进程隔离是硬要求：trainer OOM 绝不能停掉 servo 流 — 这就是它从第一天就是
  独立进程的原因（overview §2）。
- 在线微调会漂移：50/50 混采 + sanity gate + rollback 是防线；README 记录"会话间
  从 aggregate 全量重训"为推荐 hygiene（HG-DAgger 每轮全量重训是安全回退）。
- inference 接管永不录制是**语义约定**不是实现巧合 — 用测试钉死（此模式无 recorder
  实例化路径）。
- camera-frame canonical 策略：相机一动策略即失效 — checkpoint 元数据带 frame，
  加载时与会话配置核对，不符即拒绝（12-dagger-protocol.md 规则）。
- 键盘修正质量低于 spacemouse/leader arm（HG-DAgger 标签质量论证）— 不影响实现，
  但在 README 风险节记录。
- sim 里 gate 默认关闭，但 DAgger 的 e2e 要在 `safety_debug` 下至少跑一次，验证
  policy 动作同样被 gate 钳制（overview §6：gate 对人与策略一视同仁）。
