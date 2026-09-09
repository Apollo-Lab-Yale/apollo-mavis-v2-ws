# Phase-13 — 键盘遥操回归、episode 三键、按 episode 组织的数据集（LeRobot v3 变为导出）

状态：设计定稿 2026-09-07。本文件是 core / runtime / ui / sim（仅字串）/ docs 五层实现的**唯一契约**。
设计权威：`docs/design/10-frames-and-data.md` §11（目录布局与导出）、§9（sidecar）、
`04-runtime.md` §10（录制器 / DatasetStore / 导出任务）、§13.1（REST）、`00-overview.md` §5
"Input interfaces"、`13-tracker-teleop.md` §1.1（键盘与手柄并列）、`05-ui.md` §8.1 项 6–7 / §8.2
EpisodeControls / §12 项 26、`01-core.md` §12 / §13——这些章节已于 2026-09-07 按本契约改写，
实现与文档冲突时以文档为准并在报告中注明。

## 用户决定（2026-09-07，binding）

1. **键盘是与 Vive controller 平级的遥操接口**，不再是"辅助"。键位：`W/S` 末端 ±x（前/后）、
   `A/D` 左/右、`Q/E` 下/上、`I/K` roll、`J/L` pitch、`U/O` yaw、`F/H` 夹爪关/开、`Tab` 切换
   被遥操的机械臂、`←/→` 导轨左/右——即 `00-overview.md` §5 的原表；原来 2026-09-07 早些时候
   "teleop 只用 Vive、键盘只做辅助"的决定作废。
2. **三个 episode 按键**：开始新 episode；标记当前 episode 结束并存入数据集；丢弃当前 episode
   不存入。
3. **数据集不按 vanilla LeRobot 的方式把所有 episode 的视频拼在一起**，而是以 episode 为单位
   组织每个 episode 的视频等文件——否则每次删除都要重新编译视频。参考主流方案（已调研：
   LeRobot v2.1 逐 episode 文件、DROID raw 逐轨迹目录、UMI 逐 demo 目录 + 可再生的 plan、RH20T
   逐相机 mp4 + 时间戳 + 音频、rosbag2 逐录制目录；结论见 10-frames §11 开头）。
4. **保存或丢弃一个 episode 后，默认回归初始位**（2026-09-07 用户追加确认）：每次 `episode_save` /
   `episode_discard` 之后机械臂自动回到本 session 的起始 profile；这是默认行为，不是可选项。

## 主代理代用户定的决策（实现按此执行；用户可推翻）

- **D1 episode 三键 = `N`（新建）/ `Enter`（保存）/ `Backspace`（丢弃）**——即 phase-01 的原表。
  用户未指定具体键；`S`/`F` 已被 −x / 夹爪关占用，上会话把 episode 键改到 `S`/`F` 造成同码冲突。
  三键只在键盘 capture armed 时生效（与今天一致，不做页面级快捷键——Enter/Backspace 在
  JointPanel 数字框与对话框里有原生语义）。全表 code 唯一由 core 测试强制。
- **D2 键盘与手柄同时在线的优先级不变**：任一来源按住 clutch（trigger / `KeyC` / 手柄 RT）时由
  tracker 位姿驱动平移与旋转、键盘平移/旋转键该 tick 被忽略，夹爪与导轨的 held code 各来源取并集
  （逐 code 取最大 scale）；松开 clutch 键盘直接驱动。这是 runtime 自 2026-09-02 已实现并有测试
  的规则（`test_keyboard_translate_ignored_but_rail_and_gripper_work_while_clutched`），**零改动**。
- **D3 删除 `KeymapEntry.keyboard` 标志、`_d()` 与 `KEYBOARD_CODES`**：没有任何消费者读它，
  留着就是线上的一句谎话。
- **D4 目录布局按 10-frames §11**：`episodes/<episode_id>/{episode.json, frames.parquet,
  video/<camera_id>.mp4, audio.wav}`，`episode_id = <episode_new 时刻的 UTC 时间 %Y%m%dT%H%M%S.fffZ>-<6 hex>`
  （10-frames §11.3；首帧墙钟另存 `episode.json.recorded_at`）永不复用、不重编号；数据集级 `manifest.json`（可由目录重建）；`sessions/`、`scenes/` 提到
  数据集根；`exports/lerobot_v3/` 是派生物。删除 = 删一个目录。
- **D5 导出 = 批任务 + CLI**（`POST /api/datasets/{ns}/{name}/export` → 202 + telemetry 进度；
  `python -m apollo_mavis_v2_runtime.tools.export_lerobot`），算法照抄 lerobot 自己的
  `convert_dataset_v21_to_v30`（逐 episode 文件 → v3：ffconcat 流拷贝拼接、pd/pyarrow 叠 parquet、
  `aggregate_stats`、`info.json`），**不重编码**。只有导出任务允许 `import lerobot.datasets`
  （会拉起 torch）；REST 列表 / 删除路径只读 `manifest.json` / `episode.json`。
- **D6 保存/丢弃后回初始位 = 默认开**（用户决定 4；`SessionSpec.return_to_start: bool = True`，Collect
  LaunchSheet 复选框默认勾选，可按 session 取消）。上会话的半成品（`EpisodeStatus.returning`、
  `RecorderThread.set_returning`）沿用，走 `start_from` 同一条 `twin.plan → execute_plan` 门禁路径、
  以 session 的速度倍率执行、任何操作输入即取消（held 键 / clutch / jog / 手柄边沿 → `detail`
  "return cancelled: movement key"，臂停在原地）、规划失败无运动只报 `detail`。回位 profile =
  `start_from: profile:<id>` 若有，否则该 kind 的 initial-condition profile；**两者都没有**且勾选着时
  POST 409 `"return_to_start needs a start_from profile or an initial-condition profile - set an
  initial condition or untick 'Return to start'"`（LaunchSheet 在这种情况下先禁用 Start 并给出同一原因，
  直到操作员选 profile 或取消勾选）。与 overview §4 第 4 项"推理模式绝不盲目回初始位"不冲突：
  只在 collect，孪生规划、门禁、可取消。
- **D7 旧的 phase-07 LeRobot v3 树（`meta/info.json`，无 `manifest.json`）只读列出**
  （`layout: lerobot_v3`），不追加、不删除；导入器不在本 phase。
- **D8 麦克风音频 sidecar 接通**：上会话写了 `EpisodeAudioSink` 但 `Runtime` 从未把
  `MicrophoneReader` 交给 `SessionManager`，音频从未录上。
- **D9 DAgger**：DAgger 数据集同样按 episode 目录录制。trainer（`dagger/trainer/sampling.py::
  read_spool` / `LabelIndex`）**只读 `trainer_spool/*.parquet`**，从不读视频或 `LeRobotDataset`
  （12-dagger §7 本来就这么写；其 "episode mp4s (valid post-concatenation)" 一句作废）——本 phase
  **不**为 trainer 重建导出。spool 文件名改 `ep_<episode_id>.parquet`；`EpisodeSummary` /
  `submit_episode` 增加 `episode_id`，`LabelIndex` 与 trainer 的 `trained_on_episodes` 水位改以
  `episode_id` 为键（或保留 capture-order `index` 并在 summary 里同时携带两者——选一种，写进
  12-dagger §7）。12-dagger §1/§3/§4/§7/§8/§12 关于 LeRobot writer / finalize / fsck 的陈述实现后同步
  （文件头已有 2026-09-07 注）。

## 补充需求（2026-09-07 晚，用户；binding）：录制时过滤静止 / 停顿 / 小幅动作

人做 demonstration 时会迟疑、停顿。Data Collection 启动面板加一个**默认勾选**的复选框"过滤静止 / 停顿 / 小幅动作"，
下面是过滤参数输入框；机制与默认参数取自用户此前的项目 pro-dagger（`M4D-SC1ENTIST/pro-dagger`，分支
`prodg-lbm-anzu`，已克隆在 `/tmp/pro-dagger`；`scripts/teleop_server.py:1667-1704 _land_chunk`、
`src/pro_dagger/envs/benchmarks.py:359-383 _anzu_chunk_first_idle / _anzu_chunk_grip_toggle`），那里的 heuristic
实测有效（原始管线越学越差 SR 0.16 → 清洗后 0.58）。**pro-dagger 的规则**：以 H=16 步 chunk 为单位，chunk 首步
desired 位姿的逐分量变化 < 1 mm（xyz）、rot6d 分量 < 1e-3、夹爪 < 1 mm ⇒ "犹豫 chunk"，**除非** chunk 内任一相邻步
夹爪宽度变化 > 1 mm（夹爪翻转 chunk 一律保留）；另有 stride-3 去重（滑窗 chunk 重叠的去重，与逐帧 episode 数据集无关，
**不移植**）。默认全部开启；已知盲区：慢速迟疑过滤不掉（只比较相邻步）。

**移植到 MAVIS 的逐帧 episode 录制（binding，10-frames §11.4 / 04-runtime §10.5 已写入）：**

- `SessionSpec.action_filter: ActionFilterConfig`（collect / dagger；01-core §12）：
  ```python
  class ActionFilterConfig(BaseModel):
      enabled: bool = True
      pos_eps_m: float = 0.001          # pro-dagger _ANZU_IDLE_POS_EPS: 1 mm, Chebyshev over xyz of the commanded TCP
      rot_eps_rad: float = 0.001        # pro-dagger's literal 1e-3 on rot6d components ≈ 1e-3 rad (geodesic angle here)
      gripper_eps_frac: float = 0.01    # pro-dagger _ANZU_GRIP_EPS 1 mm ≈ 0.012 of the G2's 86 mm stroke -> 0.01 open-frac
      rail_eps_m: float = 0.001         # rail slot, same 1 mm
      gripper_context_s: float = 1.6    # pro-dagger's gripper exemption spans one H=16 chunk at 10 Hz = 1.6 s
  ```
- **判据（每个待录帧 t）**：以**上一个已保留帧**的命令为参照（不是相邻帧——相邻帧比较会把慢速真实运动整段丢掉再在下一
  个保留帧上产生跳变；参照上一保留帧则慢速运动每累计 1 mm 保留一帧，动作有界），`idle(t)` = 双臂 xyz 每分量 |Δ| <
  `pos_eps_m` 且 旋转测地角 < `rot_eps_rad` 且 |Δgripper| < `gripper_eps_frac` 且 |Δrail| < `rail_eps_m`（所有 session
  臂都静止才算静止）。`idle(t)` 为真且 **±`gripper_context_s` 内没有夹爪变化**（|Δgripper| > `gripper_eps_frac`
  于任一相邻帧对）⇒ 该帧**不写入**（不入 parquet、不喂编码器、不写音频对齐点）；否则写入。前视需要缓冲：录制线程延迟
  `round(gripper_context_s·fps)` 帧做决定（25 fps ⇒ 40 帧 ≈ 2 相机 × 40 × 921 KB ≈ 74 MB），保存 / 丢弃时冲刷缓冲。
  DAgger 只过滤人控帧（`action_source ∈ {teleop, takeover}`，pro-dagger 的 corrective-only 精神），策略驱动帧永不过滤。
  `enabled: false` ⇒ 逐帧全录（今天的行为）。
- **数据形态**：保留帧连续写入，LeRobot `timestamp = frame_index / fps` 照旧合成——时间间隙在数据里是隐藏的（与
  pro-dagger 相同），真实时间仍在 `wallclock_ns` 列；`episode.json.filter = {enabled, params, frames_seen,
  frames_skipped, gaps: [[kept_frame_index, n_skipped_before_it], …]}` 记录每处间隙；`EpisodeStatus.frames_skipped`
  （additive）实时显示；`manifest.json` 不变。第一帧永远保留。
- **UI**：LaunchSheet（Data Collection / DAgger）复选框 "Filter idle / small-motion frames"（默认勾选，testid
  `action-filter`）+ 参数输入 `pos (mm)` / `rot (mrad)` / `gripper (%)` / `rail (mm)` / `gripper context (s)`（默认
  1 / 1 / 1 / 1 / 1.6，`buildSpec` 换算成 SI 写进 `action_filter`；未勾选时输入禁用）；EpisodeControls 的 REC 行显示
  "skipped N"。
- 验收：sim collect e2e——驱动 2 s（KeyS）、停 3 s、反向驱动 2 s（KeyW；同向两段会在 ~1.4 s 后到臂展极限，命令饱和 =
  静止，是过滤器的正确行为）：`frames_seen ≈ 7 s·fps`、`frames_skipped ≈ 3 s·fps − 少量`、停顿处恰一个 gap（首键晚于
  首帧时另有一个起始 gap：第 0 帧总保留）、parquet 行数 == mp4 帧数 == `length`；录制中只动夹爪（KeyF 1 s）的帧全部
  保留；`enabled: false` 时 `frames_skipped == 0`。**`audio.wav` 时长 = 墙钟录制时长**（≈ `frames_seen/fps`，对齐
  `wallclock_ns`），不是 `length/fps`。单元测试覆盖前视缓冲（夹爪变化前 1.6 s 内的静止帧被保留）、多臂、
  DAgger 策略帧不过滤。

## 事实（现状，2026-09-07）

- **三个子仓有大量未提交改动**（上会话），其中数采部分**是断的**：`session/manager.py` 引用了
  不存在的 `_return_profile_for` / `_on_episode_done` / `_return_home_worker`（约 L1478 / L1552 /
  L50 docstring），任何 collect session（sim 或真机）在 writer 与 session sidecar 已创建之后
  抛 AttributeError → REST 500；`server/rest.py` 没有任何 `/api/datasets*` 路由（`GET /api/episodes`
  仍是返回零的 stub）；`RecorderThread.mark_delete` / `EpisodeStatus.pending_delete` 无调用者，
  `teardown()` 从不应用；`SessionManager._dataset_busy` 只读不写；`SessionManager.microphone` 从
  未被 `runtime.py` 赋值；UI 未重新生成 schema / `gen/protocol.ts`（`SessionSpec` 无 `dataset`，
  `EpisodeStatus` 无 `returning`）；`tests/test_hardware_session.py:904` 仍断言真机 collect 被拒。
  这些都在本 phase 内收拾——**先让 collect session 能启动，再谈布局**。
- **键盘遥操今天其实没有被真正关掉**：只有 core `protocol/keymap.py` 把 17 个 held 行标成
  `keyboard=False`、把 episode 保存/丢弃改到 `KeyS`/`KeyF`（与 held 行同码）；runtime、UI 都不读
  该标志，UI 的 `buildBindings` 只看 `kind`。若把当前 core 表端出去：W/A/D/E/Q/I/J/K/L/U/O/H/
  箭头/C 仍能遥操，但按 `S` 会发 `episode_save`（−x 从键盘不可达）、按 `F` 发 `episode_discard`
  （夹爪关不可达），collect / dagger 模式下（episode 行可见时）KeymapOverlay 出现重复 React key
  `KeyS` / `KeyF`（testid `keyrow-KeyS` 亦重复）。UI 的
  `schemas/keymap.json`、`schemas/KeymapEntry.json` 与 `src/gen/protocol.ts` 尚未同步（仍是
  Enter/Backspace），`gen:check` 对当前 core 会失败。core HEAD（6c7dafc）的 keymap 就是用户要的
  完整键盘表。
- **runtime 对键盘零改动**：`held_to_twist`（`control/teleop.py`）、`HeldSources`（`loop.py`）、
  `_teleop_step` 已完整实现 WASD/QE/IJKL/UO/F/H/箭头/C 与 Tab/Z/Space/episode_*；`devices/tracker.py`
  按 action 查 code，不受表变动影响。
- **lerobot 0.6.1（已装，`apollo-mavis-v2-runtime/.venv`）关键事实**（读源码核实）：
  - v3 writer 用 `StreamingVideoEncoder`（公开类：`start_episode(video_keys, temp_dir)` /
    `feed_frame` / `finish_episode() -> {key: (path, stats)}` / `cancel_episode`）把每个 episode 编成
    独立临时 mp4（`pts = k`、`time_base = 1/fps`、从 0 开始），再 `shutil.move` 或
    `concatenate_video_files`（ffconcat demuxer + packet remux，**不重编码**）拼进分片；
    `finish_episode` 不删文件——直接拿来当 `video/<cam>.mp4`。
  - 读取端要求：`episode_index` 恰为 `0..n-1` 且 `meta/episodes` 第 i 行 = episode i（位置索引，有
    缺口就回落到 Hub 下载）；`index` 列 = 全局行号；`tasks.parquet` 行序 = `task_index`；data parquet
    **只能**含 `info.json` 的 features + 五个 bookkeeping 列（多一列 `task` 字符串就 `CastError`，
    datasets 4.8.5 实测）；解码容差 `|from_timestamp + timestamp − pts| < 1e-4 s`（reader）；
    `length == round(to·fps) − round(from·fps)` 是 `dataset_tools`（delete/split）的断言。
  - `delete_episodes` 对混有删除 episode 的视频分片**解码重编码**、重写所有 parquet 并重编号；
    `dataset_tools.py:37` / `lerobot_dataset.py:22` / `video_utils.py:37` 顶层 `import torch`，而
    `lerobot.datasets.__init__` 把它们全部 import 进来——任何 `from lerobot.datasets.<x> import …`
    都会先执行 `__init__`，即拉起 torch；`aggregate_stats`（`compute_stats.py`）同样如此。
  - `aggregate_datasets` 要求各源 `robot_type` 相同（与 10-frames §8.3 的 sim+real 合并承诺冲突，
    §8.3 已改注：多数据集导出是后续项，目前用 `merge_datasets` 合并两个导出前先改写其一的 `robot_type`）。
  - `feed_frame` 在某相机队列满 0.1 s 时丢帧（有 warning，计数在私有 `_dropped_frames`，
    `finish_episode` 不返回它；不足 2 帧时 `stats` 为 `None`）——视频可能比 parquet 短，保存时必须
    用自己的 `feed_frame` 计数减去丢帧数与行数比对；编码器返回的视频 stats 是 `(C,)`、0..255 的
    原始值，要像 lerobot writer 一样 reshape `(3,1,1)` 并 /255。`finish_episode` 会把 mp4 留在
    `temp_dir` 下的 `tmp*/` 子目录里，搬走 mp4 后要删掉这些子目录。
  - v2.1→v3.0 转换脚本 `lerobot/scripts/convert_dataset_v21_to_v30.py` 就是"逐 episode 文件 →
    v3"的现成范本（累计到 `>= cap` 才开新文件、`from/to_timestamp` 累加、单文件 `meta/episodes`、
    `aggregate_stats`）；它假定逐 episode 统计量与视频 info 已存在——所以 `episode.json` 里要有
    `stats`。
- 文档侧已在 2026-09-07 完成：10-frames §1/§7/§8.3/§9/§11、04-runtime §5/§10/§13.1/§13.3/§14/§16、
  00-overview §3.3/§4/§5/§8、13-tracker §1.1、05-ui §2/§6.1/§8.1/§8.2/§9/§11/§12、01-core §5.2/§11/§12/§13，
  12-dagger 文件头注，CLAUDE.md 精简。实现后需同步的：12-dagger §1/§3/§4/§7/§8/§12（D9）与
  `docs/prompts/README.md` 状态表。

## 范围

### 1. core（`apollo-mavis-v2-core`）

- `protocol/keymap.py`：还原 HEAD 的 23 行表（held 行全部是键盘行；episode 行
  `KeyN episode_new "start new episode"` / `Enter episode_save "save current episode"` /
  `Backspace episode_discard "discard current episode"`）；删除 `keyboard` 字段、`_d()`、
  `KEYBOARD_CODES` 与 "KEYBOARD TELEOP IS GONE" docstring，换成两句话记录 2026-09-07 的决定
  （键盘与手柄平级；code 全表唯一）。`tests/test_keymap.py`：恢复全表 code 唯一断言，删
  `test_keyboard_teleop_is_gone`，`_SPINE_TABLE` 按 code 键；`tests/test_schema_export.py` 去掉
  `keyboard` 断言。**保留**同一工作树里无关的改动（`SwitchArmArgs`、`SaveProfileArgs.set_initial`、
  `filter_beta ≤ 200`、controller-link 字段）。
- `protocol/session.py`：`SessionSpec.return_to_start: bool = True`（collect 专属；显式设置在非 collect
  模式 → validation error，与 `dataset` 同规则；默认值只对 collect 生效）；`dataset: str | None = Field(None, pattern=DATASET_RE)`
  （保留 validator）使 `schemas/SessionSpec.json` 带 `pattern`，UI 从 schema 读正则而不硬编码；`DatasetInfo` 加 `layout`、`export: DatasetExportInfo |
  None`；新 `DatasetExportInfo`、`DatasetExportRequest`；`EpisodeInfo` 改为
  `{episode_id, index, frames, duration_s, task, session_id, recorded_at, frames_dropped, audio,
  export_ok, export_note, open}`（删 `pending_delete`）。字段注释照 01-core §12。
- `protocol/telemetry.py`：`EpisodeStatus` 删 `pending_delete`，保留 `returning` / `repo_id` /
  `total_episodes` / `total_frames` / `detail`；新 `DatasetExportTelemetry` 与
  `TelemetryMsg.datasets: DatasetsTelemetry | None`（additive）。`TrackerSettingsMsg.filter_beta`
  的协议回显 pydantic 默认改为 5.0（仅对齐 `configs/mavis_v2.yaml` 已有的 5.0，01-core §11 该字段注释
  已说明；**不改任何 runtime 配置或 pose_filter 数值**）。
- `export_schemas` 重新导出（`schemas/keymap.json`、`KeymapEntry.json`、`SessionSpec.json`、
  `TelemetryMsg.json`、`DatasetInfo.json`、`EpisodeInfo.json`、新增两个、`index.json`）。

### 2. runtime（`apollo-mavis-v2-runtime`）

- **先修断点**：实现 `SessionManager._return_profile_for(spec)`、`_on_episode_done(outcome, index)`、
  `_return_home_worker(...)`（D6：`spec.return_to_start` 为真（默认）时每次 save / discard 后启动；复用
  `_start_from_worker` 的 `twin.plan → Command(op="execute_plan")` 路径，session 速度倍率；
  `RecorderThread.set_returning(True, detail)` / `(False, ...)`；任何 held code / clutch / jog / device
  edge 取消；planner 失败 → detail、无运动；取消勾选的 session 完全不触发）。
- **`recorder/episode_recorder.py` → `EpisodeDirRecorder`**（替换 `LeRobotEpisodeRecorder`，
  04-runtime §10.1）：manifest 打开/创建（10-frames §11.5）、`dataset_incompatibility(manifest, …)`
  改读 manifest 并比较 info block（`apollo_schema` / `action_space` / `frames` / `rail`）、编码器按
  manifest.video 钉家族、`StreamingVideoEncoder` 直接驱动（`temp_dir = episodes/.tmp-<id>/`）、
  `frames.parquet`（pyarrow，一个 row group，列 = §7 特征 + `timestamp` float32 + `frame_index`
  int64 + `task` str）、逐 episode 非视频 stats（照 lerobot `compute_episode_stats` 语义，含
  quantiles）、`episode.json` 最后写、`os.replace` 发布、manifest 计数刷新 + `last_export.stale`。
  `frames != rows` → `export_ok: false` + `export_note`（不丢弃）。`finalize()` 幂等清理。
  `repair_unfinalized_datasets` → `sweep_incomplete_episodes(datasets_root)`（`Runtime.start()`、
  session 启动、`DatasetStore` 扫描时调用）；`recorder_state.json` 与 `write_recorder_state` 删除。
- **`recorder/datasets.py::DatasetStore` 重写**（04-runtime §10.6）：只读 `manifest.json` /
  `episode.json`（legacy 识别 `meta/info.json`）；`list/describe/episodes/delete_episode/
  delete_dataset/export`；删除不 import lerobot；`_carry_sidecars` / `_restore_caps` /
  `delete_episodes` 调用全部删除。
- **`recorder/export_lerobot.py`**（新）+ `tools/export_lerobot.py`（CLI）：10-frames §11.8 的六步；
  视频拼接用 `av`（照 lerobot `concatenate_video_files` 的 ~50 行）以便任务本体不依赖 torch，最后
  一步校验 `LeRobotDataset(repo_id, root=<export>)` 允许 import lerobot；`meta/stats.json` 的聚合同样
  不 import lerobot——照抄 `compute_stats.py::aggregate_stats`（约 60 行 numpy），否则一 import 就拉起
  torch（若决定接受 torch 常驻，则直接用 lerobot 的 `concatenate_video_files` / `aggregate_stats`，
  并删掉"不依赖 torch"这一目标——二选一写进报告）；编码器身份变化即开新文件；`export_ok == false`
  的 episode 跳过并在 `detail` 报数；写 `meta/apollo/episode_map.json`；进度经
  `telemetry.datasets.export`（`TelemetryMsg.datasets` 由 `server/ws_telemetry.py` 从导出任务的进度
  对象构造，做法同 `build_hardware_monitor_telemetry(runtime)`；不存在 `RuntimeState` 类）。一次只跑
  一个任务；与录入同一数据集的 session 互斥（409）。
- **`server/rest.py`**：`GET /api/datasets`、`GET /api/datasets/{ns}/{name}`、
  `GET …/episodes`、`DELETE …/episodes/{episode_id}`（204 / 404 / 409 open / 409 legacy）、
  `DELETE /api/datasets/{ns}/{name}`（204 / 409 in use or exporting）、`POST …/export`（202 / 409 /
  404）；`GET /api/episodes` 标记 deprecated（从 telemetry 的 EpisodeStatus 取值）。`DatasetError.
  not_found` → 404，其余 409。
- `session/manager.py`：`_check_dataset_spec` 加 legacy 与 exporting 409；`_build_collect_recorder`
  改建 `EpisodeDirRecorder`；`Runtime` 把 `MicrophoneReader` 赋给 `manager.microphone`（D8）；
  `_validate_hardware` 保留 `mode ∈ {teleop, collect}`；`RecorderThread` 去 `mark_delete` /
  `pending_delete`。`dagger/recorder.py` spool 文件名改 `ep_<episode_id>.parquet`。
- `config.py`：`RecorderConfig` 删 `video_file_size_mb`，保留 `audio: bool = True`，加
  `export: ExportConfig{video_file_mb: 200, data_file_mb: 100}`；`configs/mavis_v2.yaml` 目前没有
  `recorder:` 块（如加则写 `audio` / `export` 两键），其 L26 注释 "`speed_scale` (default 10 %)" →
  50 %；UI `src/pages/Landing.tsx:9` 的 "10 % / 30 % / 100 % (default 10 %)" 注释同样改 10/50/100、50。
- 测试（`uv run pytest -q` 全绿）：`test_recorder_thread.py` 改用 `EpisodeDirRecorder` 假件；新
  `test_episode_dir_recorder.py`（真 lerobot 编码器 + 真 pyarrow：目录结构、`frames == rows`、
  `.tmp-*` 崩溃清扫、manifest 计数、encoder 身份记录、`export_ok` 假件）；新 `test_dataset_store.py`
  （列表 / 删除不 import lerobot——用 `monkeypatch.setitem(sys.modules, "lerobot", None)` 包住调用，
  任何 `import lerobot…` 立即 ImportError，与测试执行顺序无关；legacy 只读、open episode 409）；新
  `test_export_lerobot.py`（两个 episode → 导出 → `LeRobotDataset` 读回：`num_episodes`、每帧
  `timestamp`、首尾帧解码、`stats.json` 存在、`episode_map.json`；删一个 episode 后重导出结果
  与"只录了另一段"逐字节一致的 parquet 行）；`test_e2e_collect.py` 改断言（04-runtime §16 3(b)）；
  `test_hardware_session.py:904` 改为正向用例（fake 相机 + FakeRecorder 缝）；`test_audio_sink.py`
  （stub reader）；`test_server_contract.py` 加 `/api/datasets*` 路由，已有的 23 行 keymap 断言改为同时
  断言 code 全表唯一与 `KeyN/Enter/Backspace`；`test_return_to_start.py`（可选功能：开/关、取消、
  默认开、取消勾选、取消回位、既无 start_from profile 也无 initial-condition profile 时 409）。

### 3. ui（`apollo-mavis-v2-ui`）

- `npm run gen:sync && npm run gen:types`（core schema 重导出后）；`gen:check` 绿。
- `EpisodeControls`：加 `bindings` prop，提示用 `codeForAction(bindings, action)` + `keycapLabel`
  （05-ui §8.2）；`returning` 琥珀 chip + `detail`；标题行 `repo_id` / `total_episodes`。
  `KeymapOverlay`：无重复 code（core 修好即无需改）。测试按 05-ui §11。
- `LaunchSheet`（Data Collection）：**Dataset** 双面板（New dataset 名字实时 slug 到 `DATASET_RE`、
  预览 `apollo/<slug>`；Continue existing 单选自 `GET /api/datasets` 按 `kind` 与 `layout:
  episode_dirs` 过滤）+ **Return to start after save / discard** 复选框（**默认勾选**；既无 start_from
  profile 也无 initial-condition profile 时 Start 禁用并给原因，直到选 profile 或取消勾选）；
  `buildSpec` 输出 `dataset` / `dataset_resume` / `return_to_start`；`validateLaunch` 要求新建名非空。
- `DatasetsPanel`（05-ui §8.1 项 7）：数据集行 + 展开 episode 行 + 删除 episode（ConfirmDialog）+
  Export LeRobot v3（202 + telemetry 进度条）+ 删除数据集（双确认、输入名字）；legacy 行动作禁用；
  `in_use` 锁；随 `telemetry.episode.total_episodes` 变化刷新。`src/api/rest.ts` 加对应函数。
- README：`apollo-mavis-v2-ui/README.md:61-62` 控制器手势表改为 **operator 的表**（与
  `tracker.controller_map` / 13-tracker §1.1 一致：clutch → trigger click, gripper_open → pad ▲,
  gripper_close → pad ▼, rail_neg/pos → pad ◀/▶, switch_arm → menu；现在印的是已撤销的改法）；
  L71 `filter_beta 0–5` → `0–200`。只改文字，不改 YAML。

### 4. sim（`apollo-mavis-v2-sim`，仅字串，可选）

- `assets/scenes/mavis_v2.yaml` `description:` "39.5 cm inward" → 39.0（头部已是 39.0）；
  `assets/xarm7_on_rail.xml` L96-97 注释 "leaves the FAR end 0.3 cm long" → 止于台面 −X 边缘前
  0.24 cm（x0 = 0.2800）；`README.md:54` 39.5 → 39.0。核对 `docs/prompts/phase-09a-hardware-twin-overlay.md:27`
  的 "`<arm>_link_tcp` 168.6 mm"：模型里 gripper 臂的 `link_tcp` 在 `0 0 .172`（03-sim §3 已写明），
  168.6 来源不明——查清是 G2 控制器侧 TCP 偏置还是笔误，改其一。

### 5. docs

- 实现后：`12-dagger-protocol.md` §7（D9 的读取路径）；`docs/prompts/README.md` 状态表勾选；
  CLAUDE.md "Work in progress" 段删除。

### Out of scope

legacy v3 → episode 目录的导入器；Hub 上传；删除的回收站 / 撤销；腕相机逐帧外参；DAgger trainer
直接读逐 episode 文件的 torch Dataset；非 `lerobot_v3` 的导出格式（ALOHA HDF5 仍按 10-frames 附录 A
另立）。

## 交付物

- core：keymap 还原 + 新模型 + schemas；runtime：`EpisodeDirRecorder`、`DatasetStore`、导出任务与
  CLI、REST、`return_to_start`（可选）、麦克风接线、修复 collect 500；ui：`EpisodeControls` /
  `LaunchSheet` / `DatasetsPanel` + 类型重生成；测试全部更新；12-dagger §7 与 README 状态表同步。

## 验收标准

- [ ] core `uv run pytest -q` 全绿；`GET /api/keymap` 23 行，code 全表唯一，episode 行
      `KeyN` / `Enter` / `Backspace`，无 `keyboard` 字段（`schemas/KeymapEntry.json` 无该键）。
- [ ] runtime `uv run pytest -q` 全绿；ui `npm run lint && npm run gen:check && npm test && npm run build`
      全绿（build 含 `tsc --noEmit`；仓库是 npm 管理，不是 pnpm）。
- [ ] e2e（sim，1 臂 + 1 相机）：起 collect session（`dataset: "pick_cube"`，`dataset_resume: false`）
      → `episode_new` → 遥操 5 s（**用键盘 `KeysMsg` 按 KeyW**，不用 tracker）→ `episode_save` →
      再录一段 → `episode_discard` → 结束 session。断言：`var/datasets/apollo/pick_cube/` 下恰有一个
      `episodes/<id>/`（`frames.parquet` 行数 = `episode.json.length`，`video/<cam>.mp4` 帧数相等，
      `episode.json` 有 `stats`、`video` 块），无 `.tmp-*`，`manifest.json.episodes == 1`，
      `sessions/session_*.json` 与 `scenes/<sha>.xml` 存在；没有 `meta/info.json`、`recorder_state.json`。
- [ ] 导出：`POST /api/datasets/apollo/pick_cube/export` → 202，`telemetry.datasets.export.phase`
      走到 `done`；`uv run python -c "from lerobot.datasets import LeRobotDataset; ds=LeRobotDataset(
      'apollo/pick_cube', root='<root>/exports/lerobot_v3'); assert ds.meta.info['codebase_version']==
      'v3.0'; assert ds.num_episodes==1; ds[0]; ds[len(ds)-1]"` 通过；`meta/apollo/episode_map.json`
      存在；`telemetry.datasets.export` 的 videos / data / meta 三阶段合计 < 2 s（remux，无解码；
      validating 阶段的首次 lerobot import 不计）；`fps == 25`、`action_source` 全 1、`wallclock_ns`
      严格递增、`features['action']['info']` 含 `apollo_schema: 1`。
- [ ] 删除：录第二个 episode 后 `DELETE …/episodes/<id1>` → 204，目录消失，另一 episode 目录
      **mtime 不变**（无重编码、无重写），`DatasetInfo.export.state == "stale"`；重导出后
      `num_episodes == 1`。删除正在录制的 episode → 409。REST 列表 / 删除路径不 import lerobot
      （测试用 `monkeypatch.setitem(sys.modules, "lerobot", None)` 包住调用；`lerobot.datasets` 一旦被
      recorder 测试加载就常驻 `sys.modules`，"未加载"断言只会碰运气）。
- [ ] 续录：`dataset_resume: true` 同 schema → 允许并追加为第二个目录；改 fps 或换 sim/hardware
      `robot_type` → 409 文案含 `cannot be continued`；对 legacy v3 树 → 409 `read-only`。
- [ ] 键盘：Cockpit capture armed 后按住 `W` 1 s 末端 +x 前进；按住 `C`（无 tracker）无动作、松开后
      `W` 仍有效；同时按 `F` 夹爪关闭；`Tab` 切臂；`N` / `Enter` / `Backspace` 与 EpisodeControls
      按钮同路径且按钮提示文字随 keymap（用改键 fixture 验证）。
- [ ] `return_to_start`（默认开）：collect session 不带该字段、`start_from: profile:<id>` 时，保存与丢弃后
      `EpisodeStatus.state` 都走 `saving → returning → idle`（丢弃：`idle → returning → idle`），臂回到
      profile（每关节 < 0.02 rad）；期间 `episode_new` 被 nack；发一帧 `KeyW` 取消并 `detail` 含
      `cancelled`、臂停在原地；只有 initial-condition profile 时回到它；既无 `start_from: profile:<id>`
      也无 initial-condition profile 时 POST 409（文案含 `untick`）。显式 `return_to_start: false` 的
      session 保存后不产生任何运动。
- [ ] 真机（用户在场；`hardware_session.armed` 已渲染为 true）：Hardware 页签起 collect（两臂、50 %），
      两路腕相机进 `episodes/<id>/video/`，`audio.wav` 存在且 `duration_s` ≈ episode 时长，
      `episode.json.extrinsics[*].intrinsics` = 配置的 D435 内参；session 期间 `DatasetsPanel` 删除
      前一个 episode 成功。

## 注意事项

- **先修 500 再动布局**：把 `manager.py` 三个缺失方法补上（或在 `return_to_start` 为假时不调用）
  才能跑任何 collect e2e。
- lerobot 读取端全是**位置索引**：导出的 `episode_index` 必须 0..n−1 连续、`index` 等于全局行号、
  `tasks.parquet` 行序等于 `task_index`；`total_episodes / total_frames / total_tasks` 与数据不一致
  会让 `LeRobotDataset` 回落到 Hub 下载报网络错——测试要盯住这一点。
- 拼接只能拼**同一编码器身份**的文件（lerobot 的 `concatenate_video_files` 默认
  `compatibility_check=False` 什么都不查；开了也只查 codec / pix_fmt / 尺寸 / fps，不检查 GOP / SPS——
  编码器身份分组是我们自己的规则）；编码器身份变化就开新文件。`bf=0`（NVENC）等 `extra_options` 要写进 `info.json` 的
  `video.*`，否则 lerobot 后续 re-encode 路径重建不出正确编码器。
- `StreamingVideoEncoder.feed_frame` 会在队列满时丢帧（私有 `_dropped_frames`，`finish_episode` 不返回）：
  保存时用自己的 feed 计数减丢帧数与 parquet 行数比对，不一致或 `stats is None`（< 2 帧）标
  `export_ok: false`，不要静默导出。`finish_episode` 后先 `shutil.move` 各 mp4 到 `video/<cam>.mp4`，
  再 rmtree 编码器留下的 `tmp*/` 子目录，最后写 `episode.json` 与 `os.replace`。
- 任何 `from lerobot.datasets… import` 都会加载 torch（`lerobot/datasets/__init__.py`）：REST 路径、
  `DatasetStore`、`EpisodeDirRecorder` 之外（后者已在 recorder 包内懒加载）不得 import。
- 文件名与目录：`episode_id` 含 `.` 与 `Z`，在 URL 路径里原样传（`[0-9TZ.\-a-f]+`），路由用正则限制。
- **不要改 operator 的东西**：Vive controller 映射、pose filter 数值、速度默认 0.5、arm 名字。
  键盘表是 00-overview §5 的原表，episode 三键按 D1；若用户改主意，只改 core 表与文档，其余层从
  served keymap 派生。
- Enter / Backspace 只在 capture armed 时被 `useKeyCapture` 拦截；JointPanel 数字框的 Enter 提交、
  对话框里的 Enter/Backspace 都在 capture 未 armed 时发生，互不影响——不要加页面级 Enter 快捷键。
- 12-dagger §4 说 DAgger 数据集"是普通的 LeRobot v3 数据集"——实现后改为"按 §11 录制、按需导出"。

## 补充需求（2026-09-08，用户；binding）：键盘坐标系、`R` 回位键、退出前自动回位

三项都已在 phase-13 的工作树上实现（core / runtime / ui / docs，未提交）。真机未验证。

### E1 键盘平移改到腕相机坐标系（用户报的 bug）

用户报告："只要转动了 end effector，WASD 就错位了；转 90° 后按 D 变成向后、按 A 变成向前。"

- 复现结论：**已提交的代码里键盘平移走的是基座系，不随末端旋转**（探针实测 W 方向在末端 yaw/roll 90°
  前后夹角 0.0°）。真正的两个问题是：(a) 本 cell 的 `base_quat` 是绕 z 的 +90°、joint 1 = π，基座系
  相对操作者视角**整体反了 180°**（W 朝向操作者、A 朝操作者的右手）；(b) 操作者是看着腕相机流遥操的，
  世界固定的方向在末端一转之后在画面里就指向别处——这才是"错位"的来源。
- 决定（用户在两个选项里选了"工具/相机系"）：`ControlConfig.translate_frame`，默认 `"camera"`。
  `W/S` 沿相机光轴，`A/D` 画面左右，`E/Q` 画面上下；`"world"` = 操作者系（固定于桌面），
  `"base"` = 2026-09-08 前的行为。**旋转键 I/K/J/L/U/O 不变，仍绕 TCP 轴。**
- **2026-09-08 晚追加（用户决定）：默认改为 `"world"`**——W 远离操作者（−Y）、A 操作者左手（+X）、E 向上，
  不随末端转动；`"camera"` / `"base"` 仍可选，语义不变。已同步到 `ControlConfig` 默认、`configs/mavis_v2.yaml`
  （`sim.yaml` 继承默认）、`tests/test_configs.py`（断言两份配置都是 `world`）、KeymapOverlay 说明文字
  （`world` 标 "(the default)"）及各设计文档。上午的 `camera` 决定保留在上文作为历史。
- **相机姿态必须按臂从模型取**：`SceneKinematics.wrist_cam_quat_world(arm, tcp_quat) =
  quat_mul(tcp_quat, cam_from_tcp)`，`cam_from_tcp` 在构造时由 `site_xmat`/`cam_xmat` 算一次。
  原因：`xarm_gripper_base_link` 相对 link7 带 `quat="0 0 0 1"`（绕工具轴 180°），所以夹爪臂的 TCP 系
  与只带相机的臂差 180°——用一个常量 key→TCP 矩阵会把**默认遥操臂**的 `A/D`、`E/Q` 反过来。实测：
  常量矩阵在 grip 上误差 180°、在 view 上 0°；模型路径两臂都 < 1e-5°。见 `tests/test_camera_frame.py`。
- 没有腕相机的臂（`guardrail_env` 等测试场景）退回 TCP 系，前向轴相同。
- runtime 的 e2e / rig 测试都断言世界轴位移，统一钉在 `translate_frame: "base"`（conftest 与
  `test_e2e_safety_debug` 各有注释），坐标系本身由 `test_teleop_math.py` + `test_camera_frame.py` 覆盖。

### E2 `R` 键回初始条件

`reset_to_initial`（core keymap 第 24 行、`ActionName`）。loop 内联校验后交给
`SessionManager.request_reset_to_initial`，ack 只表示"已开始"。没有指定初始条件 / 无 profile store 时
**只报原因不动**（`ok=false`，UI 弹 toast）；录制中、已有 plan 在跑也拒绝。

### E3 退出主页面前自动回位

`POST /api/session/return_home` → `ReturnHomeResult{ok, status, detail, arms, profile_id}`，**同步**。
Cockpit 的 "End session" / "Terminate session" 先调它，`ok` 才 DELETE + 回主页；`ok=false` 留在页面上
弹 `ConfirmDialog`（"Arms did not return home"，正文 = twin 给的原因 + "先结束 session，再用 UFACTORY
Studio 手调"——Studio live control 不能在 session 中开，02-hardware §16），按钮 "Stay in session" /
"End session anyway"。`status: "skipped"` 算成功（没指定初始条件的 workcell 行为不变）。

回位动作 = **两段各自规划与门禁**（用户要求"先 arm 再 linear rail"，导轨可选）：① 关节到 profile 姿态、
各自导轨保持不动；② 导轨到 profile 的 `rail_pos_m`、关节保持。起点已等于目标的那一段跳过；第一段没到位
就不走第二段；profile 不带导轨（`rail_pos_m: None`）就没有第二段。两段都是可打断的 `execute_plan`。
`teardown()` 不变——自身不产生任何运动。

### E4 默认姿态的落地

`python -m apollo_mavis_v2_runtime.profiles.seed_initial [--kind …] [--dry-run]`：每种 workcell 写一份
initial-condition profile（按名字幂等），Manipulation Arm `[-180, -12, -20, 30, -5, 35, -8.9]°`、
Perception Arm `[0, 0.8, 0, 28.9, 0, 28.2, 0]°`，**导轨不写**（回位时保持当前位置；travel 上限是硬限位，
不盲发）。孪生已验证：导轨在两端、麦克风开与关四种组合下都无碰撞（最近监控对 107 mm），且能从 cell 的
keyframe 规划到达。2026-09-08 已写进 `var/profiles/`。不自动执行——指定初始条件会改变所有回位的目标。
