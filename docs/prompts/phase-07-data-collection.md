# Phase 07 — apollo-mavis-v2-runtime（二）：LeRobot v3 录制器、collection 模式、episode 端到端

## 目标

实现数据采集：基于真实 `lerobot` 库的 LeRobot dataset v3 `EpisodeRecorder`、
collection 模式（teleop + 20–30 fps 录制、100 Hz servo 插值）、经 control WS 的
episode 控制（N/Enter/Backspace 与 UI 按钮同路径），并激活 UI 的 EpisodeControls，
端到端产出可被 `LeRobotDataset` 读回的数据集。

## 前置条件

- 依赖 phase：05、06。
- 必读设计文档：
  - `docs/design/00-overview.md` §3.3（EpisodeRecorder）、§4.2（collection 模式与固定 features）
  - `docs/design/04-runtime.md`（recorder 集成与 session 编排）
  - `docs/design/10-frames-and-data.md`（feature 命名、frame 约定入元数据 — 事实来源）
- 参考：`docs/research/lerobot-data.md`（v3 格式与 API 全部依据）。

## 范围

- **LeRobotEpisodeRecorder**（`recorder/episode_recorder.py`，实现 core
  `EpisodeRecorder`；依赖 `lerobot`≥0.6，锁小版本）：
  - `LeRobotDataset.create(repo_id, fps=cfg.fps（默认 **25**，带宽 20–30）, features,
    root, robot_type, use_videos=True, streaming_encoding=True)`；已有目录用
    `LeRobotDataset.resume`。
  - 每帧 `add_frame({observation.state, observation.images.<cam>..., action,
    intervention, action_source, wallclock_ns, task})` — **不要**手动放 5 个
    bookkeeping features（`timestamp/frame_index/episode_index/index/task_index`
    由库自动加，手放会被 `validate_frame` 拒绝）；`task` 字符串每帧必填。
  - `save_episode()` / `clear_episode_buffer()`（discard 免费）/ 会话结束**必须**
    `finalize()`（否则 parquet footer 缺失、数据集不可读）；`VideoEncodingManager`
    式守卫兜 TEARDOWN/SIGINT/异常三条路径；会话目录维护 `recorder_state.json`
    `{repo_id, episodes_saved, finalized}`，下次启动检测未 finalize 的数据集并用
    `resume()` + `finalize()` 修复。
  - 视频编码：`streaming_encoding=True` + `rgb_encoder.vcodec="auto"`（4090 上走
    NVENC `h264_nvenc`），save_episode 近乎即时。
- **Schema**（`recorder/features.py`，10-frames §6–§7 — 事实来源；所有录制模式统一，
  保证可 merge）：逐维 `names` 用 **`<arm_id>_` 前缀**（config 臂 id），块按
  `WorkcellConfig.arms` 顺序拼接；`action_space` 用 core `PolicySpec` 字面量
  `"delta_ee" | "abs_ee" | "joint"`，**delta_ee 为 canonical**（有 rail 8 维/臂：
  `[ee.dx, ee.dy, ee.dz, ee.drx, ee.dry, ee.drz, gripper.pos, rail.dpos]`）；
  `observation.state` 16/15 维/臂：`[joint1..7.pos, gripper.pos, rail.pos,
  ee.x..ee.qz]`；每相机一个 `observation.images.<camera_id>`。固定附加列（binding）：
  `intervention`{bool,(1,)}（普通 collect 恒 False）、`action_source`{int8,(1,)}
  （labels **`{0: policy, 1: teleop, 2: joint_jog, 3: takeover, 4: planner}`**，
  镜像 core `CommandSource`；collect 恒写 1；**2/4 保留、绝不出现在录制帧**——
  录制中 `joint_target` 被 nack、planner 运动不在 episode 内录制）、
  `wallclock_ns`{int64,(1,)}（取 `ArmState.wallclock_ns`）。
  `features["action"]["info"]` 写 `{apollo_schema: 1, action_space, frames:
  {arm_id: FrameRef}, rail: {axis: "y", travel_m: 0.65, arms: [...]}}`；
  `features["observation.state"]["info"]` 写同一 `frames` map。`robot_type` =
  `xarm7_{n}arm_rail`（sim 加 `_mujoco` 后缀）。**每个 dataset repo 固定一种
  (task × arm-count × frame convention)**，repo 名文法
  `apollo/xarm7_{task}_{n}arm_{conv}`（conv = `dee|aee|jnt` + `-` + 逐臂
  `base|world|cam.<id>` 以 `+` 连接）— 名字只是镜像，权威在 `info` dict。
- **采集环**：控制环保持 100 Hz 不录制；`RecorderThread` 是 LeRobot writer 的
  **唯一属主**，按 `cfg.fps` 从 `snapshot` LatestSlot 取帧（executed action 与 obs
  对齐），每帧从各录制相机 `latest()` 取图（age > 2/fps ⇒ 丢帧 + `frames_dropped`
  计数），EE 量（action 块 + state 的 `ee.*` 维）在 `add_frame` **之前**转换到该臂
  声明的 recording frame（10-frames §3；joint/gripper/rail 维 frame-free 直通）；
  编码抖动绝不反压 100 Hz 环。
- **Sidecar 元数据**（10-frames §9，binding — LeRobot 顶层 info.json 会丢自定义键）：
  `<root>/meta/apollo/`：`session_{session_id}.json`（SessionSpec/workcell/软件版本/
  SafetyConfig 快照）、`episodes/episode_{index:06d}.json`（scene_xml_sha256、
  start_from、initial_condition_profile_id、frames map、**相机外参快照**（T_W_C +
  intrinsics + calibration sha）、arm_bases、frames_dropped）、
  `scenes/{sha256[:16]}.xml`（`spec.to_xml()` 去重归档）。原子写（.tmp + os.replace）。
- **Collection 模式接线**：`POST /api/session {mode:"collect", task 必填}`；episode
  操作由 control WS `ActionMsg`（`episode_new/episode_save/episode_discard`）触发，
  服务端回 `AckMsg`、状态经 telemetry 的 `EpisodeStatus{state: idle|recording|saving,
  index, frames, duration_s}` 广播；非法转移（recording 时 `episode_new`）回
  `ok:false`；`save_episode` 异常 ⇒ **保留 buffer** 重试一次，再失败降级为只停录制。
- **UI 激活**：Collect 页 EpisodeControls 按 05-ui §8.2 行为矩阵接真（idle 只有 New；
  recording 有 Save/Discard + REC 红点 + 帧数/时长；saving 全禁 + spinner；
  无乐观 UI）；键 N/Enter/Backspace 与按钮同路径。

Out of scope：DAgger 特有列的**写入逻辑**（`control_mode/policy_action/
policy_version`，phase-08 — 但 `intervention/action_source` 列本 phase 起就在
schema 里）；`tools/convert_legacy` 与 ALOHA 导出器；训练/数据集浏览工具；
push_to_hub 自动化。

## 交付物

- `src/apollo_mavis_v2_runtime/recorder/{episode_recorder,features}.py` +
  `RecorderThread` 集成（04-runtime §2/§10 布局）。
- collection 模式完整可用（sim 后端）；sidecar 写入 `meta/apollo/`。
- UI：Collect 页接线 + 测试更新。
- `tests/`：recorder 单元（fake workcell 喂帧）、frame 转换（10-frames §3.5 恒等式：
  to/from 往返 <1e-9、delta 一致性）、discard 语义、finalize 崩溃兜底 +
  `recorder_state.json` 修复、schema/命名断言、sidecar 内容断言、e2e 采集回读。

## 验收标准

- [ ] runtime：`uv run pytest` 全绿；UI：`pnpm test` 全绿。
- [ ] e2e（sim，1 臂 + 1 相机 + sim 渲染流）：起会话 → WS 发 `episode_new` → teleop
      驱动 5 s → `episode_save` → 再录一段 → `episode_discard` → 结束会话。然后：
      `uv run python -c "from lerobot.datasets import LeRobotDataset; ds=LeRobotDataset('<repo_id>', root='<root>'); assert ds.meta.info['codebase_version']=='v3.0'; assert ds.num_episodes==1"`
      — 只有 save 的 episode 存在，discard 的无痕迹。
- [ ] 回读断言：`fps == 25`（配置默认；∈ [20,30]）；`features` 含 `intervention`
      （全 False）、`action_source`（全 1 = teleop，labels dict 与 core
      `CommandSource` 五值逐字相等）、`wallclock_ns`（严格递增）；
      `features['action']['info']` 含 `apollo_schema: 1`、`action_space:
      "delta_ee"`、`frames` map 与 `rail.travel_m == 0.65`；per-dim `names` 前缀为
      臂 id 且 delta_ee 块序正确；repo id 符合
      `apollo/xarm7_{task}_{n}arm_{conv}` 文法；`observation.images.<cam>` 的 mp4
      可解码且帧数 == episode length。
- [ ] 时序：录制 20–30 fps 期间控制环仍稳 100 Hz ± 1%（录制不偷控制预算）；
      `save_episode()`（streaming_encoding）耗时 < 1 s，期间 telemetry 的
      `episode.state == "saving"`。
- [ ] AckMsg 语义：recording 状态下发 `episode_new` 回 `ok:false`；recording 状态下
      发 `joint_target` 回 `ok:false, detail:"recording"`（数据集中 `action_source`
      永远见不到 2/joint_jog 或 4/planner）；UI 按钮矩阵与 telemetry 状态一致。
- [ ] 相机帧超时：相机停止出帧（age > 2/fps）时该帧被丢弃并计入 `frames_dropped`
      （episode sidecar 可见），不写坏帧。
- [ ] Sidecar 归档：`<root>/meta/apollo/session_*.json`、
      `episodes/episode_000000.json`（含 `frames` map、`scene_xml_sha256`、相机外参
      快照、`start_from`）与 `scenes/<sha>.xml`（可 `MjModel.from_xml_string` 重编译）
      全部存在；discard 的 episode 无 sidecar。

## 注意事项

- **`finalize()` 是硬要求**：没有它 parquet footer 缺失、整个数据集不可读。会话
  teardown、异常、SIGINT 三条路径都要走到；测试模拟崩溃后验证。
- 写入期不可读：`LeRobotDataset` 读一个正在录的数据集会抛
  "Cannot read ... Call finalize() first" — 单进程单 writer，任何"边录边看"需求
  走 telemetry，不碰数据集。
- feature 名禁含 `/`（点是命名空间分隔符）；`add_frame` 的 key 集必须与 features
  **精确相等**（多/少键都被 `validate_frame` 拒绝）。
- `timestamp` 由库以 `frame_index / fps` 合成 — 真实抓帧时刻只活在我们自己的
  `wallclock_ns` 列里；读取端会按 `fps ± 1e-4 s` 校验间距，所以录制循环要真按
  节拍快照，不能突发补帧。
- 一个 repo 一种 schema：delta_ee 下 1 臂（带 rail）action 8 维、3 臂 24 维，不能混
  （`merge_datasets` 要求 feature 集/`apollo_schema`/`action_space`/`frames`/fps
  全同，10-frames §8.3；`robot_type` 允许不同 — sim+real 合并合法）；普通 teleop
  从第一天就写 `intervention=False` 列，否则与 DAgger 数据集 schema 不合、日后
  merge 要整库重写（`add_features` 复制一遍）。
- frame 混写有毒：一个 dataset 的 `action` 列只允许一种 frame（归一化统计是全列
  共享的）— 转换发生在采集时（runtime 转到会话声明的 frame），不落异构行。
- `streaming_encoding=True` 时 discard 要取消流式编码器（库的
  `clear_episode_buffer` 已处理，但要测）；PNG 路径的 `image_writer_threads`
  仅作 fallback。
- 录制线程与控制环之间用有界队列：编码抖动绝不能反压 100 Hz 环；丢帧计数进
  telemetry。
- 锁 `lerobot` 小版本：v2.1→v3.0 是破坏性变更史，`CODEBASE_VERSION="v3.0"`
  在测试里断言。
