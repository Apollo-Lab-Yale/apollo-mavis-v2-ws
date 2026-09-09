# Phase 05 — apollo-mavis-v2-runtime（一）：会话引擎、控制环、teleop、安全监督、FastAPI 服务

## 目标

实现 runtime 的骨架与 teleop 模式：session 生命周期（bring-up → `start_from` 解析 →
控制环 → teardown）、100 Hz `ControlLoop` 线程（全栈唯一命令 chokepoint）、held-key →
twist → 微分 IK → servo 的 teleop 管线、直接关节控制路径（`joint_target` jog/goto）、
模式无关的安全监督（twin gate + watchdog）、StateProfile 管理（含 set-as-initial
覆盖语义），以及承载 control/telemetry/video 三类 WS + REST 的单端口 FastAPI 服务。
以 sim workcell 跑通无浏览器的端到端测试。

## 前置条件

- 依赖 phase：01、02、03（04 完成更好，但本 phase 用 sim 后端即可落地；hardware
  路径只需按 core 接口对接、不实跑）。
- 必读设计文档：
  - `docs/design/00-overview.md` §2（进程模型）、§4（模式）、§5（keymap）、§6（安全）、§8（协议）、§9（性能）
  - `docs/design/04-runtime.md`（本仓事实来源：session engine、控制环、server）
  - `docs/design/11-safety-collision.md`（gate 语义、safety_debug）
  - `docs/design/05-ui.md` §12（UI 侧契约点 — 服务端必须满足）
- 参考：`docs/research/web-teleop-stack.md`（WS 协议/视频/watchdog 全部依据）。

## 范围

包内（`apollo_mavis_v2_runtime`，依赖 core，extras：`[hardware,sim]`；单进程、单 uvicorn worker）：

- **SessionManager**（`session/manager.py`）：状态机 `IDLE → BRINGUP → START_FROM →
  RUNNING → TEARDOWN`（+ `FAULT/RECOVERING`），状态经 telemetry `session.state` 广播；
  `POST /api/session` 收 core `SessionSpec{mode, kind, arms, frames, sim_scene?/
  digital_twin_scene?, start_from, task?, policy?}`（kind 仅当对应 config 存在才受理，
  否则 409）。`start_from: keep_current` ⇒ 不动、目标从测量态播种；`profile:<id>` ⇒
  twin `plan`（RRT-Connect、逐臂顺序）规划安全路径、waypoint 走同一 gated servo 流
  执行，进度经 `session.start_from_progress`；**绝不**调 xArm 原生 gohome/reset。
  会话单例 + 进程 `epoch`（UUID）。
- **ControlLoop**（`control/loop.py`，专用线程，100 Hz，monotonic 绝对期限配速，
  过载跳过不补发）：**全栈唯一**调用 `ArmInterface.command_*` 的 chokepoint
  （11-safety §4，AST 扫描测试钉死）。tick 固定顺序：drain `CommandBus` → 读
  `held_keys` slot + watchdog → 读臂状态缓存 → `twin.sync` → 各源算动作 → 目标位姿
  积分 + leash（测量 EE 周围 ≤0.025 m / ≤0.2 rad）→ `IKSolver.solve`（residual >
  0.01 m / 0.1 rad ⇒ 目标冻回已达位姿，glide 不上弦）→ 每 tick 关节限幅
  （`dq_max = 0.04 rad/tick`）→ `gate.filter` → 写 `q_cmd[arm_id]` slot（每臂一个
  `ArmSender` 线程消费，慢臂不拖 tick）→ 发布 `StateSnapshot`。TeleopRates 默认：
  线速 0.12 m/s、角速 0.6 rad/s、rail 0.10 m/s、gripper 1.2 frac/s。非活动臂 hold
  上次命令值；Tab 循环活动臂（**服务端权威**，`switch_arm` 不带参数）；rail 键恒发、
  活动臂无 rail 时服务端忽略。
- **直接关节控制路径**（`control/joint_panel.py`，`ActionMsg{name:"joint_target",
  args:{arm_id, positions（完整 q 含 rail 槽）, mode:"jog"|"goto"}}`）：
  `jog` = 逐 tick 限斜率直趋目标（0.02 rad/tick、rail 2 mm/tick，关节空间不走 IK），
  `max|Δq| > 0.15 rad`（goto_threshold）⇒ Ack `ok=false` 要求走 goto
  （**2026-09-07 修订：该门槛已取消** —— jog 目标是"终点"而非"步长"，任意 Δq 都接受并按
  固定速率趋近，UI 面板也随之删掉了 "Go to" 按钮，见 05-ui §8.3 / 04-runtime §7）；`goto` = 组
  `PlanRequest` → `twin.plan` → waypoint 流经同一限斜率 gated 路径执行，Ack 立回
  `"accepted"`、完成/失败经 telemetry `session.plan_status`；plan 执行中按任何运动键
  或 takeover ⇒ 减速取消；录制中（`EpisodeStatus.state == "recording"`）一律 nack。
  两条路径全部过 gate。
- **SafetySupervisor**（`safety/{gate,supervisor,watchdog}.py`）：
  - `SafetyGate.filter(q_cmd, q_meas, source) -> GateDecision{q_out, blocked, report,
    events}` — 语义 = 11-safety §7.1（binding）：**hold-last-safe，不做线段二分**
    （二分最坏 +2.3 ms 超预算）；violations 用 `dist ≤ min_clearance_m`（blocked 期间
    +`hysteresis_m` 防抖）；escape 规则（严格拉开每个违规对 ≥1e-5 m 且不产生新违规
    才放行）；twin 陈旧（>0.15 s）⇒ 全臂 fail-closed + `stale_twin`；`_last_safe`
    错误恢复后重置为测量值。每 4 tick 在**测量**配置上 `clearance()` 扫一次 →
    telemetry（<25 mm ⇒ `warn`）。
  - gate 选择在会话构建时定死：hardware ⇒ `SafetyGate`（无 twin/`enabled:false` ⇒
    拒绝启动）；sim ⇒ `NullGate`，除非 `safety.safety_debug` — 此时完整 hardware 安全栈
    （独立 twin 实例 + gate + IK 碰撞行 + watchdog）架在 sim workcell 上。
    hardware 模式**模式无关不变量**：teleop/joint-jog/policy/takeover/planner 每个
    命令源每 tick 都过 gate。
  - `InputWatchdog`：输入陈旧 **0.2 s**（deadman）⇒ twist 线性斜坡归零 **0.1 s**
    （ramp）；恢复前**必须**先收到一个空 held-key 集（AWAIT_EMPTY）；控制 WS 断开 ⇒
    立即按 deadman 路径归零、丢 held 状态；驱动错误恢复后 re-seed + AWAIT_EMPTY。
  - CI：把 phase-03 的 `python -m apollo_mavis_v2_sim.tools.guardrail_check --all` 接进
    runtime CI（integration job），且 runtime `SafetyGate` 语义与其一致。
- **StateProfile 服务**（`profiles/store.py`）：re-export core `ProfileStore` +
  `save_from_snapshot(store, snap, name, notes)`；`save_profile`/`set_initial_condition`
  走 control WS ActionMsg（`set_initial_condition` 无 `profile_id` 时 = 先把当前状态
  存为名 `"initial"` 的 profile（**覆盖**）再指定为 initial）；管理性 CRUD 走 REST；
  删除 designated initial ⇒ 409。
- **FastAPI 服务（单端口 8765）**：
  - REST `/api`（响应模型全部来自 `core.protocol`）：`GET /api/health`（epoch）、
    `GET /api/workcell`（`WorkcellStatus` 含 per-arm 连接/rail/gripper +
    `policies_available`）、`GET /api/cameras`、`GET /api/scenes?kind=sim|twin`、
    `GET /api/keymap`（来自 `core.protocol.keymap`）、profiles `GET/PATCH/DELETE`、
    `GET /api/policies`、`GET/POST/DELETE /api/session`（无会话 404；已有会话/kind
    不可用/场景臂不匹配 ⇒ 409）、`GET /api/episodes`。episode 操作、profile 保存/
    set-initial、joint_target、switch_arm、takeover **不走 REST** — 全走 control WS。
  - `/ws/control`（`server/ws_control.py`）：单 writer（第二连接降级
    `role:"observer"`，不用 1008 关闭，其 keys/action 一律 `ok=false,
    detail="observer"`）；accept 后立发 `HelloMsg{epoch, session_id, role}`；hybrid
    协议 — 每次键变立即 `KeysMsg` + 25 Hz 全量心跳（协议带宽 20–50），`seq` 乱序
    丢弃；`ActionMsg` 经 `CommandBus.submit` → `AckMsg`；**permessage-deflate 禁用**
    （`ws_per_message_deflate=False`）；handler 里绝不做运动学。
  - `/ws/telemetry`：25 Hz（20–30 带）广播 `TelemetryMsg`（arms、collision、
    clearances top-5、episode/dagger/inference、`session` 附加块），每客户端
    latest-wins，慢消费者丢帧不背压。
  - `/ws/video/{stream_id}`（`streams/hub.py` VideoHub）：二进制帧
    `struct.pack("<dI", ts, len(jpeg)) + jpeg`（12 字节头，core `pack_frame`）；
    每客户端 depth-1 latest slot；stream id = camera id + 保留的 `"sim"`/`"twin"`
    （**仅会话期间存在**，其余时间连接关 1008；未知 id 关 1008）；真实相机流
    **会话前**即可用，**~15 fps** 预览（Landing 网格），会话中切到配置 fps（30）、
    teardown 回 15；`/video/{stream_id}.mjpg` MJPEG 调试端点**共享同一份**已编码
    buffer。JPEG 编码在 EncoderWorker 线程（`cv2.imencode` q80，1–3 ms/帧）。
  - SPA 静态托管：`StaticFiles(directory=..., html=True)` **最后** mount 在 `/`；
    `MUJOCO_GL=egl` 在 `__main__.py` 里、任何 mujoco import 之前设置；
    `MUJOCO_EGL_DEVICE_ID = egl_device_id`（默认 **0** — 渲染/推理共享 GPU 0，
    trainer 独占 GPU 1）。
- **线程/异步边界**（04-runtime §3）：ControlLoop、ArmSender×N、相机捕获、
  RenderThread（唯一线程持有全部 Renderer，托管 sim 的 `RenderService`）、
  EncoderWorker、sim stepping 都是线程；asyncio 只搬 JSON 与 JPEG bytes；线程 → loop
  用 `call_soon_threadsafe` + `LatestSlot`；asyncio → 线程只经 `CommandBus.submit`
  （core `bus.py` 原语，`runtime.bus` 接线命名槽：`held_keys/q_cmd[arm]/snapshot/
  policy_action/encoded[stream]`）。`RuntimeConfig`（`config.py`，YAML，§14 键名）。

Out of scope：episode 录制/lerobot（phase-07）；DAgger/inference 模式（phase-08）；
UI 本体（phase-06，本 phase 用 Python WS 客户端测试）；WebRTC / MuJoCo-WASM（v1 明确排除）。

## 交付物

- `apollo-mavis-v2-runtime/pyproject.toml`（extras `[hardware] [sim] [trainer]`）+
  `src/apollo_mavis_v2_runtime/`：`__main__.py config.py runtime.py bus.py` +
  `session/ control/ safety/ profiles/ streams/ server/`（04-runtime §2 布局；
  `recorder/` 属 phase-07、`dagger/` 属 phase-08）。
- 启动入口：`uv run python -m apollo_mavis_v2_runtime --config <runtime.yaml>`
  （uvicorn 内嵌，端口默认 8765，`ws_per_message_deflate=False`）。
- `tests/`：单元（watchdog 状态机穷举、seq 去重、单 writer/observer、gate
  hold-last-safe/hysteresis/escape、jog/goto、start_from 解析、chokepoint AST 扫描）
  + WS/REST 契约（starlette TestClient + FakeWorkcell）+ **sim-backed e2e**
  （无浏览器，`httpx`/`websockets` 客户端）。
- CI 配置：pytest + guardrail 回归（`python -m apollo_mavis_v2_sim.tools.guardrail_check
  --all`，integration job，装 `[sim]` extra）。

## 验收标准

在 `apollo-mavis-v2-runtime/` 内执行：

- [ ] `uv sync --extra sim && uv run pytest` 全绿。
- [ ] e2e：起服务（sim workcell，1 臂带 rail 场景）→ `POST /api/session
      {mode:"teleop", ...}` 200 → 连 `/ws/control` 收到 `HelloMsg`（epoch 非空、
      role=="controller"）→ 发 `{t:"keys", held:["KeyW"]}` + 心跳 2 s → 断言
      telemetry 中 ee_pose.position.x 单调增加；松键后停止。
- [ ] watchdog e2e：held 非空时停发心跳 — **0.2 s** 后触发 deadman、twist 在
      **0.1 s** 斜坡内归零（telemetry 速度→0）；恢复心跳但 held 仍非空 ⇒ **不**恢复
      运动（AWAIT_EMPTY）；发一次空 held 后再按键 ⇒ 恢复。
- [ ] 单 writer：第二个 `/ws/control` 连接收到 `role:"observer"`，其 keys/action 被
      忽略（`AckMsg{ok:false, detail:"observer"}`）。
- [ ] joint panel e2e：`joint_target mode:"jog"` 逐 tick 限斜率到位（0.02 rad/tick）；
      **任意大小的增量都接受**（2026-09-07 起 `goto_threshold_rad` 已删除，原 `> 0.15 rad`
      被 nack 的验收项作废）；`mode:"goto"`（profile `start_from` / 导轨归零路径仍用）
      ⇒ Ack `"accepted"`、经 twin planner 到位、`session.plan_status` 走完生命周期；
      plan 执行中按住 KeyW ⇒ plan 取消。
- [ ] profile e2e：`save_profile` Ack 带 `profile_id`；无参 `set_initial_condition`
      把当前状态存成 `"initial"`（重复调用**覆盖**同名 profile）并置
      `is_initial_condition`（同 kind 唯一）；`DELETE /api/profiles/{initial_id}`
      返回 409。
- [ ] 视频：**会话前** `/ws/video/<camera_id>` 即出帧且实测 ≈15 fps（preview_fps），
      此时连 `/ws/video/sim` 被关 1008；建会话后连 `/ws/video/sim` 收帧，头解析
      ts/len 正确；故意不读 2 s 后恢复读，收到的是**最新**帧（latest-wins）；
      `curl /video/sim.mjpg` 出 multipart 流且 JPEG payload 与 WS 逐字节相同。
- [ ] 性能（sim 3 臂场景，压 30 s）：控制环 tick 总耗时（IK + gate + servo 下发）
      p99 **< 2 ms**（overview §9 预算：IK ~0.12 ms/臂 + twin 0.24–0.75 ms）；
      tick 率 100 Hz ± 1%；telemetry 实测 20–30 Hz。
- [ ] safety_debug e2e（CI 回归）：`uv run python -m
      apollo_mavis_v2_sim.tools.guardrail_check --all` 退出码 0（runtime CI job）；
      另起 `safety_debug` 会话走 WS 复演 `env_table_descend`：gate 在接触前 block，
      `/ws/telemetry` 的 `collision.severity` 经历 `warn → blocked`，blocked 时
      被钳命令不到达 workcell（hold-last-safe）。
- [ ] `start_from: profile:<id>` e2e：从非 home 位姿创建会话，臂经规划路径到达
      profile 位姿，全程 gate 无 block。
- [ ] `GET /api/keymap` 返回与 core 一致的 `KeymapEntry[]`；`GET /api/session` 无会话
      时 404。

## 注意事项

- **UI 永远不在控制路径里**：WS handler 只更新共享状态（held set + last_rx），
  运动全部在控制环线程 — 不要在 WS 回调里做 IK 或下发命令。
- 心跳丢失 ≠ 按键释放：watchdog 触发后如果直接用旧 held 集恢复，机器人会"自己动起来"
  — 必须等空集。这个状态机是安全评审重点，测试要穷举转移。
- uvicorn 默认 `ws_per_message_deflate=True` — 对 100 Hz 小消息只添 CPU 和缓冲，
  必须显式关掉。
- `StaticFiles(html=True)` 对深路径 404 — UI 用 hash 路由（phase-06），mount 顺序
  必须在所有 API 路由之后。
- 渲染线程亲和：`mujoco.Renderer` 只能在创建线程使用；sim 渲染、twin 渲染都归
  phase-02 的渲染线程，runtime 只从它拿 RGB 帧。
- twin gate 检查的是 **commanded** 配置（不是测量配置）— 顺序：IK 输出 → gate →
  下发；planner 轨迹逐 waypoint 也过 gate。
- 恢复流（hardware 对接点）：驱动错误恢复后 servo 流必须重播种 — runtime 侧的目标
  位姿积分器也要同步重置到测量位姿，否则恢复瞬间跳变。
- MJPEG 调试端点与 WS 视频共享编码 buffer — 双路各自编码会白白翻倍 CPU。
- HTTP/1.1 每 origin 6 连接上限只影响 MJPEG（`<img>`），WS 不受限 — 所以 WS-JPEG
  是主路径、MJPEG 只是调试。
- epoch 语义：进程重启 ⇒ 新 epoch ⇒ UI 检测后回 Landing；不要试图跨重启恢复会话。
