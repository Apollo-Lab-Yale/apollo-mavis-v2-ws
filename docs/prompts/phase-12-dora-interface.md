# Phase-12 — Dora 外部接口（进程级观测流输出 / 策略动作输入 / 外部策略节点仓 / 固定视角）

状态：**设计定稿 2026-09-07**（`docs/design/14-dora-interface.md` **v0.3** —— 用户 2026-09-03 的决定 + 2026-09-07
追加的"局域网订阅"要求已落入文档并经本机双 daemon 实验核实；本文件与 14-dora 一起是 core / hardware / sim /
runtime / policy-node / ui / docs 七处实现的唯一契约，冲突时以 14-dora 为准）。实现在隔离 worktree
`~/projects/apollo-mavis-v2-ws-p12/`（各子仓 `phase-12` 分支，自 2026-09-07 的 HEAD）中进行，与主工作树上的
phase-13 并行；合并由编排者完成。决策依据：用户 2026-09-03 的决定——dora-rs 1.0 只作 runtime 的**外部**
集成总线，runtime 内部架构不变；控制面由 runtime 独占拥有（唯一模式）；策略节点由策略仓自行启动（动态占位节点）；
参考包为独立 GitHub 仓 `apollo-mavis-v2-policy-node`（Apollo-Lab-Yale org，含 LeRobot adapter 与 CI fake 节点）；
**取消"三脚架模式"及全部外部视角命令面**（14-dora 附录 A 为 v2 候选），改为"进程级发布 + 操作员停好 Perception Arm
后结束会话"的固定视角模型；四个独立的 dora-rs 1.0.1 本机实验（`/tmp/dora-bench`、`/tmp/dora-exp-mavis`、
`/tmp/dora-tripod-exp`、`/tmp/dora-probe`）。

工作单元事实（2026-09-03）：**两台** xArm7 控制箱——**Perception Arm**（arm id `view`；腕部 Intel RealSense D435 +
RØDE NT-USB Mini）控制箱 `192.168.2.219`；**Manipulation Arm**（arm id `grip`；xArm Gripper G2 + 腕部相机）控制箱
`192.168.1.201`；两台均已上电、在网；两臂均无六维力传感器。

## 目标

把 runtime 进程作为一个 dora **动态节点** `mavis_runtime`（`path: dynamic`）接入 dora-rs 1.0 数据流，使得：

1. **进程级观测流输出**（有无会话都发）：两路腕部相机（`cam_view_wrist_cam`、`cam_grip_wrist_cam`，含 Perception
   Arm 深度 `cam_view_wrist_cam_depth`；腕部相机**每帧** metadata 带 `camera_pose_world` / `tcp_pose_world` / `q` /
   `intrinsics` / `pose_source`）、臂状态（`arm_state` **常发**——无会话时来自只读的 `IdleArmReader`；`arm_cmd` /
   `obs_state` 仅会话内）、RØDE 麦克风（`mic_mic_view`）、`telemetry`（与 `/ws/telemetry` 字节一致）、`session`
   契约消息、`events`、`heartbeat`。
2. **命令输入**：只有独立策略仓的策略动作（`policy_action` + `policy_spec` 心跳 + `policy_status`）；预留
   `weights_reload`/`weights_ack`、`cmd_request`/`cmd_response` 的 id。**没有**任何外部视角命令。
3. **固定视角模型**：操作员用 teleop（或 `start_from: profile:<id>`）把 Perception Arm 停到想要的视角后结束会话；
   发布器继续运行，他方程序（如另一台机器人的控制器）以 `viewer` 占位节点消费 Perception Arm 相机 + 每帧相机位姿。
   总线上没有任何东西能在会话外移动机械臂。
4. **内部不变**：单进程、100 Hz `ControlLoop`、twin 安全门、recorder、FastAPI REST + WS + video 全部照旧；
   控制线程**永不**调用 dora，本 phase **不给 `ControlLoop` 加任何新分支**；AsyncTrainer 仍是 runtime 拉起的
   GPU-1 子进程（ZMQ REQ/REP）。
5. **无真机可测**：fake 节点 + 私有端口的 dora 控制面测试夹具 + sim e2e；CI 在"装/不装 `[dora]` extra"两种
   配置下全绿。

## 用户决定（2026-09-07 追加，binding）

1. **发布无条件、无模式**：只要 runtime 进程在跑，就通过 dora 对外发布两个机械臂的观测（两路腕相机含每帧位姿、
   两臂状态、麦克风、telemetry、session 契约消息）；没有任何"三脚架模式"之类需要开启的东西。"停好视角再结束
   会话"只是这个模型的一种用法。
2. **订阅方可以在本机（另一个仓的程序）也可以在同一网络的另一台机器上**。跨机器是 v1 范围，不是 v2。
   机制 = dora 原生多 daemon（14-dora §9，2026-09-07 实验核实）：runtime 的私有控制面绑到配置的局域网地址
   `dora.bind_host`（实验室 Wi-Fi `wlp38s0`；**永不**绑主机在两条机械臂链路上的地址 192.168.1.11 / 192.168.2.12——
   与控制箱的 SDK 连接照旧走那两块网卡，这条规则只管 dora 在哪监听；不用 0.0.0.0，多播关），远端机器跑自己的
   `dora daemon --machine-id <id>` 加入同一 coordinator，数据流为每台已注册的远端机器渲染 `viewer_<id>` /
   `observer_<id>` 占位节点（`deploy: {machine: <id>}`），远端进程以 `Node("viewer_<id>")` 挂到自己的 daemon。
3. 保存 / 丢弃 episode 后默认回初始位（phase-13 范围，与本 phase 无关，此处只为对齐语境）。

## 前置条件

- phase-07/08 已完成；**phase-11 已落地**（`devices/microphone.py::MicrophoneReader`、`workcells.hardware`
  配置块、Welcome 页）——phase-12 触碰 `session/manager.py`、`config.py`、`dagger/loop.py`、
  `server/rest.py`、`configs/mavis_v2.yaml`，必须排在 phase-11 之后以免合并冲突。
- 必读（binding）：`docs/design/14-dora-interface.md`（全部）、`00-overview.md` §2/§4/§6/§8、
  `04-runtime.md` §3/§4/§5/§6/§11/§12/§13/§14/§15/§16、`12-dagger-protocol.md` §1/§6/§7/§8/§12/§13、
  `11-safety-collision.md` §4/§7/§10、`10-frames-and-data.md` §2/§6、`13-tracker-teleop.md` §4、
  `01-core.md` §5.2/§6/§11/§12/§14/§15/§19。参考：`docs/research/dora-middleware.md`（2026-09-01 结论 +
  本 phase 要补的 2026-09-03 状态更新）。
- 本机事实（2026-09-03）：runtime venv Python 3.12.11（uv），已有 pyarrow 25.0.1（lerobot 传递依赖）；
  PyPI `dora-rs==1.0.1`、`dora-rs-cli==1.0.1`（`cp311-abi3` wheel，`requires_python>=3.11`，CLI 是 Rust 二进制
  wheel，不需要 cargo）；`/tmp/dora-venv` 是可用的 3.12 一次性 venv（`dora-cli 1.0.1`）。实测（同机 loopback）：
  `send_output` 921,600 B 帧 p50 157 µs / p99 293 µs（首帧 10–12.5 ms，SHM 建立）；单跳 image@30 Hz p50 290 µs /
  p99 536 µs；单跳 state@100 Hz p50 236 µs / p99 437 µs；两跳 state→policy→action p50 524 µs / p99 775 µs
  （机器有负载时 p99 2.6 ms、max 8–9 ms；启动瞬间偶见 24–58 ms 尖峰）；动态节点 attach 21–31 ms；
  `dora/timer/hz/100` 实测 100.07 Hz。
- 本机隐患：默认端口 6013/53291 上**可能有别人的 coordinator**（本次实验三个 agent 互相踩到），`dora down`/
  `destroy` 对该端口是全机范围；默认 zenoh 会开 `224.0.0.224:7446` 多播、LAN/Tailscale UDP 与节点 `*:port`
  TCP 监听——所以本 phase 一律用私有端口 + `--zenoh-no-multicast --zenoh-listen 127.0.0.1:<port>`。
- 已知 dora 1.0.1 缺陷：coordinator 的 1 MiB WebSocket 上限（`ws_server.rs MAX_CONTROL_MESSAGE_BYTES`）+
  `enable_debug_inspection` + 对 ~1 MB topic 跑 `dora topic hz/echo` 会切断 daemon、泄漏订阅、数据流从
  `dora list` 消失、`dora down --force` 假成功（两次复现）；节点 API 向 **stdout** 打 JSON WARN 诊断
  （`dora-rs/dora#2742`，每个 ≥~600 KB 输出多条）。

## 范围

### 1. core（拼写权威；全部 additive；保持 dora / pyarrow-free）

- `bus.py`：`Command.source: Literal["ws", "rest", "internal", "dora"]`。
- `protocol/session.py`：`SessionSpec.policy_source: Literal["checkpoint", "external"] = "checkpoint"`
  （validator：`external` 要求 `mode ∈ {dagger, inference}` 且 `policy is None`）；`SessionInfo` 回显。
  **不加** `external_arms`、**不加** `CommandSource.EXTERNAL`（v0.2 决定，见 14-dora 附录 A）。
- 新模块 `protocol/external.py`（14-dora §4/§5/§13 是拼写权威）：`MAVIS_SCHEMA = 1`、
  `EXTERNAL_NODE_ID = "mavis_runtime"`、全部 stream/command id 常量、`ARM_STATE_LAYOUT`（32 个名字）、
  `PolicySpecModel`、`SessionAnnounce`、`CameraAnnounce`、`PolicySpecAnnounce`、`PolicyResetMsg`、
  `EventEnvelope`、`ExternalStatus`（含 `dataflow_restarts: int`）、`DoraMachineInfo{id, registered, placeholders}`、
  `DoraInfo`（v0.3 字段：`bind_host`、`machine_id`、`auth`、`coordinator_addr`、`machines`、`dataflow_restarts`）。
  **没有** `View*` 模型。
- `protocol/telemetry.py`：`DaggerStatus.policy_stale: bool = False`、`InferenceStatus.policy_stale: bool = False`
  （修正 04-runtime §15 已承诺但 core 缺失的漂移）、`TelemetryMsg.external: ExternalStatus | None = None`
  （位于 `microphone` 之后）。`ArmTelemetry` 不变。
- `state.py`：`CameraFrame.depth: np.ndarray | None = None`（(H,W) uint16，mm）、`CameraFrame.depth_scale_m: float = 0.001`；
  `schemas/config.py`：`CameraConfig.depth: bool = False`、`CameraConfig.align_depth_to_color: bool = True`。
- `EXPORTED_MODELS` += `SessionAnnounce`、`PolicySpecAnnounce`、`DoraInfo`（其余经 `TelemetryMsg`/`SessionAnnounce`
  的 `$defs`）；同步 `protocol/__init__.py`、`__all__`、`tests/test_schema_export.py` 精确集合、
  `tests/test_protocol.py::_WIRE_MODELS`。
- ruff `banned-api` += `"dora"`、`"pyarrow"`；import-guard 测试断言二者不可从 core 导入。
- `action_source` 标签表**不变**（不加标签 5；`apollo_schema` 仍为 1）；recorder features 不动。
- 命令：`cd apollo-mavis-v2-core && uv run pytest && uv run ruff check && uv run python -m
  apollo_mavis_v2_core.protocol.export_schemas --out schemas/ && ... --check`。

### 2. hardware

- `RealSenseCamera`：`CameraConfig.depth` 为 true 时 `enable_stream(rs.stream.depth, w, h, rs.format.z16, fps)`，
  `align_depth_to_color` 时在采集线程里 `rs.align(rs.stream.color)`，`CameraFrame.depth` 填 uint16 mm、
  `depth_scale_m` 取 `first_depth_sensor().get_depth_scale()`；FakeSDK 覆盖开/关两种路径；02-hardware §8 同步
  （"v1 ignores" 改为实现）。真机验证留给 phase-09 / 用户在场（哪台 RealSense 是 Perception Arm 的相机由用户给出）。
- `XArmDriver.connect(readonly=True)`（02-hardware §4 additive）：只开 report 流（`report_type='real'`）与只读轮询
  （`get_servo_angle(is_real=True)`、gripper/rail 读寄存器），**不**调用 `set_mode`/`set_state`/`motion_enable`/
  `set_servo_angle_j`、不写 gripper/rail；供 runtime 的 `IdleArmReader` 在会话间使用；FakeSDK 记录调用日志，测试断言
  只读模式下零写调用。
- sim/hardware 的 `pyproject.toml` ruff `banned-api` += `dora`、`pyarrow`。

### 3. sim

- `RenderService`：对 `StreamSpec.depth=True` 的相机增加深度兄弟流（`Renderer.enable_depth_rendering()`，米→uint16 mm，
  ≥ 65.535 m 截断），仅对显式列出的相机开启；03-sim §7 注明 "depth off in v1" 对这些流解除；测试：深度帧尺寸/dtype、
  与彩色帧 `seq` 对齐、未开启时无开销。

### 4. runtime（最大的一块）

**依赖与封禁**
- `pyproject.toml`：optional extra `dora = ["dora-rs>=1.0.1,<1.1", "dora-rs-cli>=1.0.1,<1.1", "pyarrow>=17"]`；
  `uv add --optional dora ... && uv sync --all-extras`，`uv.lock` 两个 dora 包钉同一精确版本。
- ruff `banned-api` += `"dora"`、`"pyarrow"`，per-file-ignore 仅 `src/apollo_mavis_v2_runtime/dora_bridge/*` 与
  `tests/dora/*`；新增 AST 扫描测试（仿 `tests/test_chokepoint.py`）。pytest marker `dora`（无 extra/CLI 时 skip）。

**新包 `apollo_mavis_v2_runtime/dora_bridge/`**（唯一的 dora / pyarrow 导入点，全部 lazy import；**不叫 `dora/`**）
- `control_plane.py::DoraControlPlane`：版本一致性检查（`dora.__version__ == dora --version`，否则 `disabled`）；
  校验 `dora.bind_host`（`0.0.0.0` 或落在 `workcells.hardware` 任一臂子网 → `disabled` + detail）；以 `setsid` 拉起
  `dora coordinator --interface <bind_host> --port <P> --store memory [--auth]` 与 `dora daemon --machine-id
  <machine_id> --coordinator-addr <bind_host> --coordinator-port <P> --local-listen-port <Q> --zenoh-no-multicast
  --zenoh-listen <bind_host>:<Z>`（cwd = `var_dir`），等 `dora status --coordinator-addr <bind_host>
  --coordinator-port <P>` ≤ 5 s（**`--interface` 非 loopback 时 coordinator 不再监听 127.0.0.1，runtime 的每一次
  dora CLI 调用都必须带 `--coordinator-addr`**），`dora start <yaml> --name mavis_v2 --detach --coordinator-addr …`；
  `auth` 为真时读 `<var_dir>/.dora-token`（coordinator 写在 cwd）供日志 INFO 一行与 `nodes/env.py` 打印，**绝不**进
  `GET /api/dora`；**机器注册表**：每 `dora.rescan_s` 查询已注册 daemon 集合（先找 CLI / coordinator 控制 API 里能列
  daemon 的方式——`dora status`/`dora list`/控制 WebSocket，写清依据；找不到就只靠下面的 REST 触发），与
  `dora.machines` 的交集变化时重新渲染 YAML → `dora stop mavis_v2 --grace-duration 2s` → `dora start` → 重新
  attach，`ExternalStatus.dataflow_restarts += 1`；`POST /api/dora/machines/{id}/join`（远端操作员起好 daemon 后
  显式触发同一流程，404 = 不在 `dora.machines`）；关闭：`dora stop mavis_v2 --grace-duration 2s` →
  `dora down --coordinator-port <P>` → SIGTERM/SIGKILL 自己拉起的两个 PID（`dora down` 会假成功）；**永不**对不是
  自己拉起的端口执行 `dora down`/`destroy`。这是**唯一**模式（用户 2026-09-03 决定）：没有
  `control_plane`/`zenoh_connect` 配置项，不支持共享/systemd 控制面。attach 前设
  `DORA_ZENOH_CONNECT=tcp/<bind_host>:<Z>`、`DORA_ZENOH_MULTICAST=off`、`DORA_ZENOH_LISTEN=tcp/127.0.0.1:0`（缺后两者时
  动态节点会开多播、在包括控制箱网卡的每个 NIC 上开 UDP、开通配 TCP 监听——2026-09-07 实测）；attach 后用
  `node.node_config()` 校验 id 集合。
- `dataflow.py::render_dataflow(cfg, camera_ids, mic_id, python, registered_machines) -> str`：按 14-dora §2.3 生成 YAML
  （每个本地节点 `deploy: {machine: <machine_id>}`；`dora.machines` 中**已注册**的每台远端机器加 `viewer_<id>` /
  `observer_<id>` 占位节点 `deploy: {machine: <id>}`，未注册的不渲染——`dora start` 会拒绝命名了缺席机器的数据流）
  （`mavis_runtime` 动态节点——inputs 恰为 `tick`/`probe_heartbeat`/`policy_action`/`policy_spec`/`policy_status`；
  `policy`/`viewer`/`observer` 占位动态节点，`viewer` 只有输入；唯一的 spawned `probe` 节点，解释器钉
  `sys.executable`）；所有输入 `queue_size: 1, drop_oldest`（`policy_status` 8、`events` 64 除外）；**不**写
  `input_timeout`、**不**写 `debug.enable_debug_inspection`；启动时 `dora validate --strict-types`。
- `bridge.py::DoraBridge`：状态机 `disabled | unavailable | attached | detached | closed`；`dora-bus` 单线程独占
  `Node` 句柄（出站：每 topic 深度 1 槽 + 事件 FIFO + Condition 唤醒；入站：`try_recv()` 直至空；`bus_poll_s` 2 ms）；
  事件分类：`INPUT`→分发，`INPUT_CLOSED`→标记，`STOP`→detached，`ERROR` 含 `Receiver timed out`→正常空闲
  （1.0.1 的 `next(timeout)` 超时返回的是 ERROR 事件而不是 None），`ERROR` 含 `daemon channel broken`/`fatal`→detached，
  `None`→detached；`tick`（`dora/timer/hz/10`）与 `probe_heartbeat` 同时静默 > 1 s→detached；attach 重试 1→10 s
  退避；`fcntl.flock(<var_dir>/mavis_runtime.lock)` 拒绝第二个 runtime 实例；`try_publish(id, payload, metadata)
  -> bool` 未 attached 时无副作用返回 False；attach 后每路相机先发一帧 dummy 预热 SHM。
- `codec.py`：纯 pyarrow 编解码（rgb8/mono16 扁平数组 + metadata、状态/观测向量、动作 K×D 行主序解码、JSON
  模型封装）；不 import dora，可单独单测。
- `publishers.py`：`SnapshotPublisher`（`dora-publisher` 线程，会话内由 `bus.snapshot.wait_fresh(0.1)` 驱动、会话外由
  `IdleArmReader` 驱动；`arm_state`（`state_hz` 抽样；会话外 `idle_state_hz`，metadata `source: idle`、`tick: -1`）/
  `arm_cmd`（仅会话内）、`obs_state`（`obs_hz`，`observation_id` 单调，`image_seq` 取各相机最新 `CameraFrame.seq`）、
  `events` 差分、`session` 变更 + 1 Hz、`telemetry`；自有 `RecorderKinematics` 实例算 `tcp_pose_world`/
  `camera_pose_world`，32 项 `(t_mono, q_by_arm)` 环）、`CameraTap`（挂在 `EncoderWorker.taps`，`seq` 去重之后、
  `cv2.cvtColor` 之前，只放引用，拷贝在 `dora-bus` 上做；腕部相机帧**有无会话都**附 `q`/`tcp_pose_world`/
  `camera_pose_world`/`intrinsics`/`distortion`/`pose_t_mono`/`pose_source`）、`MicPublisher`。
- `idle_state.py::IdleArmReader`（14-dora §4.2）：无会话且 bridge 启用时，对 `workcells.hardware` 每台控制箱持有
  **只读**连接（`connect(readonly=True)`），以 `idle_state_hz` 填充与会话内相同的 snapshot 槽；BRINGUP 前由
  `SessionManager` 暂停并释放连接、TEARDOWN 后 ≤ 1 s 恢复；断线 1→10 s 退避重连，期间该臂 `stale: 1` 且位姿冻结；
  sim 下 preview 场景的 `MjData` 在 preview 场景 == 会话场景时保留会话结束时的关节向量（否则 keyframe）。
- `policy_source.py::ExternalPolicySource`：实现 `dagger/policy_source.py::PolicySource` Protocol（新增，dora-free；
  `PolicyRunner` 也实现它；`GatedPolicyExecutor` 改为按 Protocol 类型标注，行为不变）；`latest()` 返回
  `(PolicyOutput, t_recv)`；`staleness_scale` 规则与进程内一致（`period + 0.05` 后 5 个 period 线性衰减到 0，
  15 Hz 时 0.45 s 全停）；`drop_and_requery()` 发布 `policy_reset{after_observation_id}` 并丢弃水位线之前的动作；
  观测年龄 > `dora.policy.max_obs_age_s`（0.5 s）的动作丢弃并计 `actions_late`；chunk：立即用第 0 行，之后每
  `chunk_dt_s` 前进一行直到新动作到达；`current_version()` 来自动作 metadata。
- `nodes/probe.py`（1 Hz keepalive）、`nodes/fake_policy.py`（echo / scripted / NaN / delay / chunk 模式，1 Hz `spec`
  心跳）、`nodes/viewer_probe.py`（以 `viewer` 订阅 `cam_view_wrist_cam` + `arm_state`，断言每帧位姿 metadata 齐全、
  统计 seq gap、写 JSON）、`nodes/rtt_probe.py`（两跳 RTT + seq gap 统计写 JSON）、`nodes/env.py`（打印
  `export DORA_*`）。
- `dataflows/mavis_v2.example.dora.yml`（sim 配置渲染结果，CI `dora validate --strict-types`）、
  `examples/viewer_node.py`（≈ 30 行：attach 为 `viewer`，取帧 + `camera_pose_world` + `intrinsics`——他方机器人代码
  消费固定视角的起点）。

**会话与服务**
- `session/manager.py::_build_policy_stack`：按 `spec.policy_source` 分支——`external`：要求 bridge `attached` 且
  `policy_spec` 年龄 ≤ `dora.policy.spec_stale_s`（3 s），否则 409 `no external policy attached`（不等待）；
  frame/space 检查逐字沿用（409 `policy/dataset frame mismatch`）；`spec.action_names` 必须与会话
  `arm_action_names` 拼接完全一致、`state_names` 为子集；**不**构造 `resolve_policy`/`MLPPolicy`/`PolicyReloaderImpl`/
  `AsyncTrainerClientImpl`（`trainer_alive: null`）；DAgger 仍建 recorder，每次 save 发 `events.episode_saved`
  （summary + spool parquet 路径 + dataset root + run_id）；`policy_version` 按动作 metadata 记录，episode 内变化计数。
- `server/rest.py`：`GET /api/dora -> DoraInfo`（14-dora §2.6 v0.3：`bind_host`、`machine_id`、`auth`、`coordinator_addr`、
  `coordinator_port`、`daemon_port`、`zenoh_connect`、`machines: [{id, registered, placeholders}]`、`dataflow_restarts`…；
  无 `control_plane` 字段、**无 token**）；`POST /api/dora/machines/{id}/join -> DoraInfo`（202 触发 rescan/重启；404）。`ws_telemetry.build_telemetry`
  填 `external` 块（含 `idle_reader` 状态）、`policy_stale`。
- `config.py`：`RuntimeConfig.dora: DoraConfig`（14-dora §12 全部字段与默认值：`enabled: false`、`bind_host: 127.0.0.1`、
  `machine_id: lab`、`machines: []`、`rescan_s: 5.0`、`auth: null`（= bind_host 非 loopback 时 true）…）；
  `bind_host` 接受 IPv4 地址**或网卡名**（启动时解析为该网卡当前 IPv4，数据流重启前重解析——实验室 Wi-Fi 是 DHCP）；
  `scripts/deploy/render-lab-config.sh` 加 `DORA_BIND_HOST` 旋钮（默认空 = 不渲染 dora 块；lab 用 `wlp38s0`，即
  SSID "APOLLO Lab" 的 Wi-Fi，2026-09-07 地址 192.168.0.88/24；此前实验室在 YaleSecure/10.66.241.33 上）；
  `configs/mavis_v2.yaml` 加注释掉/默认关闭的 `dora:` 示例块。
- 日志：`quiet_node_diagnostics` 先试 `RUST_LOG=error`（在 `import dora` 之前设置）；若 60 s 双相机发布时 stdout 仍
  > 1 行/s 诊断，则 attach 期间 `dup2` fd 1 到 `<var_dir>/node-stdout.log`（轮转），detach 时恢复；两种结果都写进
  04-runtime §15。
- `streams/hub.py::EncoderWorker`：`taps: list[Callable[[CameraFrame], None]]`（additive），`VideoHub.add_stream`
  透传。
- `Runtime.__init__/start/stop`：持有 `DoraBridge`（process-lifetime，位于 `start_previews()` 之后 attach）与
  `IdleArmReader`；`SessionManager` 在 BRINGUP 前 `idle_reader.pause()`（释放连接）、TEARDOWN 完成后
  `idle_reader.resume()`；`stop()` 里停 idle reader → `dora stop` → `dora down`（仅自己的端口）→ reap。

### 5. 参考策略节点仓（独立 GitHub 仓 `Apollo-Lab-Yale/apollo-mavis-v2-policy-node`，phase-12 创建；用户 2026-09-03 决定）

新目录 `apollo-mavis-v2-policy-node/`（ws 里与五个子仓并列、同样被 ws 仓 gitignore；本 phase 先建在
`~/projects/apollo-mavis-v2-ws-p12/apollo-mavis-v2-policy-node/`）：仅 `git init` + 本地提交结构；**`gh repo create` 与
首次 push 都等用户指令**（对外动作）。包 `mavis_policy_node/`：
`contract.py`（与 core `protocol/external.py` 相同拼写的常量 + `validate_action_metadata()`/`validate_spec()`，两仓各有
一份 golden 测试）、`types.py`（core `interfaces/policy.py` 的逐字段**复制**，加 `depth`、`observation_id`）、
`protocol.py`（duck-type `Policy`）、`messages.py`、`node.py::PolicyNode`（14-dora §6.2 事件循环：`obs_state` 为 lead、
按 `image_seq` 或 `max_image_age_s` 对齐相机帧、限速、1 Hz `spec` 心跳、`policy_reset` 处理、`INPUT_CLOSED`/`STOP`
后不退出等待重连）、`adapters/torch_bundle.py::MLPBundlePolicy`（现有 `MLPNet`/bundle 格式逐字搬入，extra `torch`）、
**`adapters/lerobot.py::LeRobotPolicy`**（`PreTrainedPolicy` + pre/post processors + sidecar `mavis_policy.json`
`{action_space, action_frame, action_names, state_names, camera_key_map, task}`；`select_action` /
`predict_action_chunk`；extra `lerobot`）、`fake.py::FakePolicy`（CI fake 节点：deterministic deltas、`FAKE_NAN_AT`、
`FAKE_CHUNK`、`FAKE_DELAY_MS`、echo 模式）、`__main__.py`（`mavis-policy-node --loader {fake,mlp_bundle,lerobot,entrypoint}
--path ... --entrypoint pkg.mod:make_policy --device cuda:0 --daemon-port ... --rate-hz ...`）。
`node.py` 在创建 `Node` 前默认设 `DORA_ZENOH_MULTICAST=off`、`DORA_ZENOH_LISTEN=tcp/127.0.0.1:0`（可用环境变量覆盖），
README 给出本机与远端两种接入配方（14-dora §9）。包本体只依赖 `dora-rs>=1.0.1,<1.1`（自带 `pyarrow`）与 `numpy`；
`torch`/`lerobot` 只是 adapter 的可选 extra；**绝不** import `apollo_mavis_v2_*`。该仓自己的 CI：私有端口控制面 + `fake.py` 对 `contract.py` golden 测试、`ruff`、`pytest`。

### 6. ui（最小）

`npm run gen`（新类型）；`telemetry.external` 驱动一枚 additive chip（DAgger/Inference 面板 "EXTERNAL POLICY
attached / stale"）；无布局改动；vitest 覆盖 attached / stale / disabled 三种渲染。`ArmIndicator` 不动。

### 7. docs

**本 phase 的实现 agent 只改** `14-dora-interface.md`（Status 改 v1.0 + 实现偏差记录）、`docs/research/dora-middleware.md`
（状态更新框）与 `docs/prompts/README.md` 状态行；下列其余文档的修订内容写进报告由编排者合并（主工作树上另有
phase-13 在改同一批文件）：按 14-dora §13 的清单：`00-overview.md` → v0.4（§1/§2/§4/§6/§8/§10）、`04-runtime.md`（§1/§2/§3/§4/§5/§11/§12/§13.1/§13.3/§14/§15/§16）、`12-dagger-protocol.md` → v1.1、
`01-core.md`（§5.2/§6/§11/§12/§14/§15/§19）、`02-hardware.md` §4/§8、`03-sim.md` §7、`05-ui.md` §12、`CLAUDE.md`
一行（两台控制箱及 IP；dora 只在边界）、ws `README.md` 拓扑一行（含 policy-node 仓）、`docs/prompts/README.md`
状态表 + 依赖图。**不改** `10-frames-and-data.md` §7.3/§9 与 `11-safety-collision.md` §4（无标签 5、无 `owners`、无
`EXTERNAL` source）。14-dora 自身 Status 改为 v1.0 并记录实现中的偏差。

### Out of scope

**任何外部视角命令面**（`view_lookat`/`view_goto`/`view_hold`/`view_rail`、所有权/租约、`CommandSource.EXTERNAL`、
标签 5、`ViewStatus`——14-dora 附录 A，v2 候选）；共享/systemd 控制面（不计划）；runtime 拉起策略节点（不计划）；
`dora cluster`（SSH 驱动的集群工具）、zenoh TLS / ACL（`--zenoh-config-overlay`）、多 coordinator；session/episode 操作走 dora（保留 `cmd_request`/
`cmd_response` id）；`weights_reload`/`weights_ack`（保留 id）；把 `MLPPolicy`/AsyncTrainer 迁出 runtime
（14-dora §11.2 Phase B）；音频入数据集；Welcome 页暴露 `policy_source`；`dora record/replay` 作为验收工具；
真机深度相机验证与真机只读连接验证（phase-09 / 用户在场）；policy-node 仓的首次 push。

## 交付物

七处代码 + 测试 + 文档修订 + 重新生成的 core `schemas/` 与 ui `src/gen`；`configs/mavis_v2.yaml` 的 `dora:` 示例块；
`dataflows/mavis_v2.example.dora.yml`、`examples/viewer_node.py`；`apollo-mavis-v2-policy-node/` 仓（GitHub 远端已建、
含 README、LeRobot adapter、fake 节点、`contract.py` golden 测试与 CI 工作流）；`docs/prompts/README.md` phase-12 行。
**不 commit、不 push**（等用户指令）。

## 验收标准（每条可执行、有数字；数字出自 14-dora §0/§12 的实测值，不得放宽）

**静态与 CI**
- [ ] core / sim / hardware / runtime 各自 `uv run pytest -q` 与 `uv run ruff check` 全绿；core
  `export_schemas --check` 通过；ui `npx tsc --noEmit && npx eslint . && npx vitest run && npm run gen:check` 全绿。
- [ ] core / sim / hardware 的 import-guard 测试断言 `dora`、`pyarrow` 不可导入；runtime 的 AST 扫描断言二者只在
  `dora_bridge/` 内被（lazy）导入。
- [ ] runtime 在**未安装** `[dora]` extra 的 venv 中 `uv run pytest -q -m "not dora"` 全绿；安装后 `-m dora` 全绿。
- [ ] `uv.lock` 中 `dora-rs` 与 `dora-rs-cli` 版本精确相同（1.0.x）；`python -c "import dora; print(dora.__version__)"`
  与 `dora --version` 一致；人为改成不一致时 runtime 启动成功且 `telemetry.external.state == "disabled"`、
  `detail` 含 "version"。
- [ ] `dora validate --strict-types dataflows/mavis_v2.example.dora.yml` 退出码 0，且渲染器输出与该文件逐字节一致
  （`render_dataflow` 快照测试）。

**生命周期**
- [ ] `dora.enabled: true`：runtime 启动后 ≤ 5 s 内 `GET /api/dora` 返回 `state: attached`、非空 `dataflow_id`、
  `placeholders == ["policy", "viewer", "observer"]`、无 `control_plane` 字段；`ps` 可见两个 dora 子进程
  （coordinator、daemon）且监听端口 = 配置的 6113 / 53391 / 7447；默认端口 6013 / 53291 上**无**本 runtime 拉起的进程。
- [ ] 控制面起不来（端口被占 / `dora` 二进制缺失）：runtime 启动不受阻（`GET /api/health` 200 的时间与关闭 dora 时
  相差 ≤ 1 s），`external.state == "unavailable"` 且 `detail` 说明原因；端口释放后 ≤ 10 s 内自动 `attached`。
- [ ] `dora stop mavis_v2` 后 ≤ 1.5 s `external.state == "detached"`，重新 `dora start` 后 ≤ 10 s 再次 `attached`；
  `kill -9` daemon 后 ≤ 2 s `detached`（tick + probe 心跳静默 1 s 判定），runtime 自动重建控制面并 attach，
  `reattach_count` 递增。
- [ ] 第二个 runtime 进程（同 `var_dir`）启动时 `external.state == "unavailable"`、`detail` 含 "another runtime"。
- [ ] `Runtime.stop()` 后 `ps` 中无残留 coordinator / daemon / probe 进程；`out/` 与 `mavis_v2.dora.yml` 位于 `var_dir`，
  仓库工作区无 `out/`。

**性能（私有控制面，sim workcell `mavis_v2`，机器无其他重负载）**
- [ ] `rtt_probe` 跑 ≥ 1000 次 `obs_state`（30 Hz）→ `fake_policy --mode echo` → `policy_action` 两跳往返：
  **p50 ≤ 1.5 ms、p99 ≤ 5 ms、max ≤ 60 ms、丢失 0**（实测 0.52–0.64 / 0.78–2.6 / 8–58 ms）。
- [ ] 两路 640×480 rgb8 @30 Hz + 一路 mono16 深度 @30 Hz，`observer` 侧 60 s：三路 `seq` **无缺口**，单跳延迟
  **p99 ≤ 3 ms**（实测 0.54–0.95 ms）；`send_output` 每帧成本 **p99 ≤ 1 ms**（实测 0.29 ms）。
- [ ] 上述满负载（2 rgb + depth + 50 Hz `arm_state` + 30 Hz `obs_state` + 25 Hz `telemetry` + 25 Hz `mic`）下
  `dora-bus` + `dora-publisher` 两线程 CPU 合计 **≤ 10 %** 单核（`psutil` 线程级 cpu_times；实测每节点 3–5 %）。
- [ ] 控制环无扰动：60 s sim teleop 会话在 bridge 开/关两种配置下 tick 率 100 Hz ± 1 %、`tick_overrun == 0`、
  tick p99 < 2 ms（沿用现有 perf 测试口径）。

**外部策略（sim；fake_policy 通过真实 dora 控制面）**
- [ ] `POST /api/session {mode: inference, policy_source: external}`：fake_policy 已发 `spec` → 会话 RUNNING 且 POST
  用时 ≤ 1 s；未发 `spec`（或 > 3 s 未刷新）→ 409 `no external policy attached`；`spec.action_frame` 与会话不符 →
  409 `policy/dataset frame mismatch`；`policy: "xyz"` 与 `policy_source: external` 同时给出 → 422。
- [ ] `safety_debug` 下 fake_policy 撞击脚本被 twin gate 在接触前 block，`CollisionEvent.source == "policy"`；Space
  接管 / 交还与进程内路径行为一致（复用 jump-free 测试，blend 窗内每 tick 位移不超 `SlewLimits`）。
- [ ] hold-on-stale：`kill -9` fake_policy → 所有策略驱动臂的 `q_cmd` 在 **≤ 0.45 s + 1 tick（0.46 s）** 内停止变化
  （15 Hz：`period + 0.05 + 5·period = 0.4500 s`），下一帧 telemetry `inference.policy_stale == true`、
  `external.action_age_s` 单调增长；3 s 后 `external.policy_attached == false`；重启 fake_policy 后收到新 `spec`
  之前的 `policy_action` 全部丢弃（`actions_late`/`dropped_inputs` 计数增加），收到后经 0.4 s slew 窗恢复。
- [ ] reset 水位线：脚本让 fake_policy 在收到 `policy_reset` 后仍发送 `observation_id <= after_observation_id` 的
  chunk → 全部丢弃、臂不动；`observation_id` 对应观测年龄 > 0.5 s 的动作丢弃并计数。
- [ ] 外部 DAgger（sim，2 个 episode）：`ps` 断言零 trainer 进程；recorder 正常；每次 save 后 `observer` 收到
  `events` `kind == "episode_saved"` 且 `summary` 与 core `EpisodeSummary` 字段一致、`spool_path` 存在；数据集
  `policy_version` 列 == 动作 metadata 的 `policy_version`；脚本在 episode 中途改版本 → `version_changes_mid_episode == 1`
  且 `events.policy_version_changed` 一条。

**无会话发布 / 固定视角（sim；`viewer_probe` 通过真实 dora 控制面）**
- [ ] runtime 启动后、**未创建任何会话**：`viewer_probe` 在 ≤ 5 s 内开始收到 `cam_view_wrist_cam`（preview fps 15 ± 1），
  每帧 metadata 含 `camera_pose_world`(7)、`tcp_pose_world`(7)、`q`(8)、`intrinsics`(4)、`pose_source == "idle"`；
  `arm_state` 以 `idle_state_hz` ± 10 % 到达，metadata `source == "idle"`、`session_id == ""`、`tick == -1`；
  `session` 流 `session_id: null`、`state: "idle"`。
- [ ] 停好再退出：sim teleop 会话（`arms: [grip, view]`）用脚本 twist 把 Perception Arm 移到新位姿后 `DELETE /api/session`；
  TEARDOWN 期间 `cam_view_wrist_cam` 相邻帧间隔 ≤ 2 个帧周期（发布不中断）；退出后 `camera_pose_world` 与会话内最后
  一帧一致（≤ 1e-6），`q` 逐项一致，`pose_source` 由 `loop` 变为 `idle`；随后 60 s 内位姿不变、`arm_state` 关节速度 == 0。
- [ ] 渲染的 YAML 中 `mavis_runtime` 的 inputs 恰为 `{tick, probe_heartbeat, policy_action, policy_spec, policy_status}`，
  没有任何 `view_*`；`viewer` 占位节点无 outputs；attach 后 `node.node_config()` 断言一致；`GET /api/dora`
  `placeholders` 含 `viewer`。
- [ ] `IdleArmReader`（FakeSDK 硬件 workcell）：会话间**零写调用**（无 `set_mode`/`set_state`/`motion_enable`/
  `set_servo_angle_j`/gripper/rail 写）；`POST /api/session` 前暂停并释放连接（BRINGUP 的 `connect()` 不与之冲突）、
  TEARDOWN 后 ≤ 1 s 恢复；拔线模拟（FakeSDK 停发 report）1 s 后该臂 `stale == 1` 且 `q` 冻结、相机帧继续带
  `pose_source: idle`；恢复后 ≤ 10 s 重连。
- [ ] 无会话时向总线注入 `policy_action`（`session_id: ""`）→ 全部丢弃（`dropped_inputs` 递增），任何臂的 `q` 不变。

**网络与日志**
- [ ] 按 14-dora §9 启动后：`ss -lunp | grep 224.0.0.224` 不含 runtime / dora / fake 节点 PID；`ss -ltnp` 中这些 PID
  仅有 `127.0.0.1` 监听；三个 NIC 上 `tcpdump -c 1 udp port 7446` 30 s 内无包（有真机 NIC 时执行，否则以 `ss` 为准）。
- [ ] 双相机 + 深度发布 60 s，runtime **stdout** 上 dora 诊断行 **≤ 60 行**（≤ 1 行/s）；记录采用的手段
  （`RUST_LOG=error` 或 fd 重定向）。

**局域网订阅（v0.3；本机模拟第二台机器）**
- [ ] `dora.bind_host: wlp38s0`（解析为本机 Wi-Fi 地址，2026-09-07 为 192.168.0.88；或本机任一非 loopback、非控制箱
      子网的地址）、`machines: [{id: remote,
      placeholders: [viewer]}]`：runtime 起来后 `ss -ltnp` 中 coordinator 与 zenoh 只监听该地址，daemon 节点端口与
      runtime 节点只监听 127.0.0.1，**没有任何** socket 在 192.168.1.11 / 192.168.2.12 上；`ss -lunp` 中 runtime /
      dora / 节点 PID 无 UDP、无 224.0.0.224。
- [ ] 起一个 `dora daemon --machine-id remote --coordinator-addr <bind_host> --coordinator-port <P>
      --local-listen-port <Q2> --zenoh-no-multicast --zenoh-listen <bind_host>:<Z2>`（同机模拟）：≤ `rescan_s` + 5 s 内
      `GET /api/dora` 的 `machines[0].registered == true`、`dataflow_restarts == 1`，渲染的 YAML 含 `viewer_remote`
      （`deploy: {machine: remote}`）；`viewer_probe` 以 `Node("viewer_remote", daemon_port=<Q2>)` 挂上并在 60 s 内收到
      `cam_view_wrist_cam` 无 seq 缺口，单跳延迟 **p99 ≤ 10 ms**（实测跨 daemon TCP 6.8 ms）；本机 `observer` 在重启
      窗口内最多 1 次 gap。`POST /api/dora/machines/remote/join` 在 daemon 已注册时幂等（202，不再重启）。
- [ ] `dora.auth` 生效：不带 token 的 `dora daemon --machine-id x` 被 coordinator 拒（日志 401），`GET /api/dora` 响应体
      不含 token；`nodes/env.py` 在本机能打印 `export DORA_AUTH_TOKEN=…`。
- [ ] `bind_host: 0.0.0.0` 或 `192.168.1.11` → `external.state == "disabled"`，`detail` 说明原因，runtime 其余功能正常。
- [ ] 远端 daemon 被 kill 后：数据流仍 `Running`，本机流不受影响；`machines[0].registered` 变 false（下一次 rescan），
      重新拉起 daemon 后再 attach 成功（`dataflow_restarts` 递增）。

**麦克风**
- [ ] `microphone.backend: fake` 下 `mic_mic_view` 25 Hz `Float32[1920]`，60 s 内 `block_seq` 连续，
  metadata `sample_rate == 48000`、`channels == 1`、`rms_dbfs` 与 telemetry `microphone.rms_dbfs` 同帧一致。

**文档**
- [ ] 14-dora §13 清单中的每个文件都已修订并在各自 Status 行注明 "amended 2026-xx-xx — phase-12"；
  `10-frames-and-data.md` 与 `11-safety-collision.md` **无**本 phase 改动；`docs/research/dora-middleware.md` 顶部有
  状态更新框；`docs/prompts/README.md` 状态表新增 phase-12 行、依赖图加 `phase-11 → phase-12`；ws `README.md` 列出
  `apollo-mavis-v2-policy-node` 仓。

## 注意事项

- **2026-09-07 双 daemon 实验的硬事实**（`/tmp/dora-lan-exp/`，14-dora §9）：多机部署键是 `deploy: {machine: <id>}`
  （`_unstable_deploy` / 顶层 `machine:` 被 validate 拒绝）；`dora start` 时被点名的机器 daemon **必须已注册**，否则
  `no matching daemon for machine id`；占位符不会迁移到后来注册的 daemon；`dora node add --from-yaml` 会忽略
  `deploy.machine` 落在本地 daemon 上——所以只能重渲染 + 重启数据流；`dora start` 对每个占位符固定打一行
  `ERROR … daemon failed to receive finished signal`，不是失败判据；coordinator `--interface <LAN IP>` 后不监听
  loopback；daemon 的 `--local-listen-port` 永远绑 127.0.0.1；auth 只覆盖 coordinator WebSocket，zenoh 数据面与
  daemon 节点端口零认证；`~/.config/dora/.dora-token` 会被同用户任何进程读到；`pgrep -f/pkill -f dora` 会匹配到
  自己的 shell（用 `pgrep -x dora` + `ps -o args=` 过滤）。
- **真机相机今天是纯 UVC 彩色**（`kind: v4l2`，pyrealsense2 未装）：§2 的 RealSense 深度路径只在 FakeSDK 与 sim 渲染
  上验证，lab 配置不发真机深度流；`CameraAnnounce.depth` 如实为 false。

- **控制线程永不调用 dora**：`ControlLoop`/`GatedPolicyExecutor` 只读 `ExternalPolicySource` 这个普通 Python 对象；
  发布全在 `dora-bus`/`dora-publisher`/EncoderWorker tap 线程。任何把 `send_output` 写进 tick 的实现直接判不合格；
  本 phase 不给 `_resolve_arms` 加分支。
- **会话间只读**：`IdleArmReader` 只读、永不写控制箱（无 mode/state/servo/gripper/rail 写）；BRINGUP 之前必须先
  `pause()` 释放连接，否则真机上两个 `XArmAPI` 客户端会抢 502 命令口；sim 下 preview `MjData` 保留会话末位姿。
- **`dora.Node` 单线程独占**：1.0.1 文档说方法内部 `try_lock`、另一线程在 GIL 释放期间重入会 panic；一个实验里并发
  send 没炸，不要赌——所有 Node 调用走 `dora-bus`。如实测证明 `next(timeout)` 与 `send_output` 跨线程安全，可把接收
  拆线程，但 `DoraBridge` 对外 API 不变，且要把证据写进 04-runtime §3。
- **`next(timeout)` 超时返回的是 `ERROR` 事件**（文本 `Receiver timed out`），`None` 才是"所有发送方已断开"；
  `send_output` 在 daemon/数据流消失后**不会抛异常**——所以必须靠 `tick` + `probe_heartbeat` 静默判定失联。
- **动态节点没有排他性**：同 id 的第二个进程会被 daemon 接受；runtime 用 flock 自保，消费者按 `epoch` 分辨；
  `dora node list` 对动态节点显示 `STATUS Unknown, PID -`，`dora logs -n policy` 拿不到动态节点 stdout（这是选择
  占位动态节点的代价——用户 2026-09-03 已确认此取舍：策略节点由策略仓自行启动）。
- **端口纪律**：测试夹具用 free-port 选私有端口，绝不碰 6013 / 53291，绝不裸跑 `dora up`/`dora down`/`dora destroy`
  （别人的 coordinator 可能在跑）；`dora down` 假成功——必须自己 reap 子 PID；`dora start` 会在 cwd 写 `out/` 与
  `<yaml>.dora-session.yaml`，cwd 必须是 `var_dir`。
- **不要开 `debug.enable_debug_inspection`，不要对图像 topic 跑 `dora topic hz/echo`**（coordinator 1 MiB 上限 bug 会
  让数据流消失、daemon 与节点成孤儿）；`dora topic echo` 只在 ≤ 4 KiB 的 topic 上、且只在 debug 数据流上用；
  `dora record/replay` 不作为验收工具。
- **metadata 值类型**只允许 bool / int / float / str / list[int|float|str]；dict / numpy / None 会被悄悄 `str()` 并
  WARN——嵌套结构进 JSON payload；`request_id` 会被 `send_service_request` 覆写。用我们自己的 `t_mono`/`wallclock_ns`，
  不要依赖 dora 的 HLC `timestamp` 做任何安全判断。
- **Arrow 形状**：扁平数组 + `width/height/encoding` metadata（与 dora-hub / dora-rerun 一致），不用 FixedSizeList/
  Struct；四元数 wxyz，字段名带 `_wxyz`；`send_output_raw` 是 bytes-only 且发送前必须释放所有 view，只作可选优化。
- **首帧 SHM 建立 10–12.5 ms**：attach 后每路相机先发一帧 dummy 预热；≥ ~600 KB 的输出每帧会打 WARN 诊断到 stdout
  （`dora-rs/dora#2742`），两位研究者对 `RUST_LOG=error` 是否有效结论相反——先测，无效就 fd 重定向。
- **`--zenoh-no-multicast` 下动态节点不继承 daemon 环境**：runtime 自己在建 Node 前 `os.environ["DORA_ZENOH_CONNECT"] =
  "tcp/127.0.0.1:<zenoh_port>"`，并通过 `GET /api/dora` / `nodes/env.py` 告诉外部客户端；`--zenoh-listen` 必须带端口
  才能被预先拨号。
- **staleness 用 runtime 接收时刻**，不用节点自报时间；`observation_id` 必填，是水位线与观测年龄的唯一依据。
- **深度 / 麦克风**的生产者依赖 additive 改动（`CameraFrame.depth`、`MicFrame.samples`）；生产者缺席时这些输出"已声明
  但静默"，消费者必须容忍 `INPUT_CLOSED`/无数据。硬件 D435i 必须走 `kind: realsense`，phase-11 的 `v4l2` by-id 路径
  只有 RGB 且会让 librealsense 打不开设备。
- **uuid7**：`uuid.uuid7()` 是 3.13+；goal_id 用 `uuid4().hex`，request_id 交给 `send_service_request`。
- **pyarrow 目前只是 lerobot 的传递依赖**：`[dora]` extra 必须显式列出，否则 lerobot 升级可能把它拿掉。
- **依赖版本**：`dora-rs>=1.0.1,<1.1` 与 `dora-rs-cli>=1.0.1,<1.1` 同锁；dora 1.0 刚 GA 一天，RC 期间 wire/store
  格式多次变化，升级时 coordinator/daemon/节点 wheel 必须一起升，`~/.dora/coordinator.redb` 不复用（runtime 自有控制面
  `--store memory`）。
- **anti-stall**：单次工具调用 ≤ 120 行；`dora_bridge/` 先写骨架再分节；先做 codec + fake-node 单测（无 daemon），
  再上私有控制面集成测试，最后 sim e2e。
