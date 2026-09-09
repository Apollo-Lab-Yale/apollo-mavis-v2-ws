# Phase-11 — MAVIS v2 前台重设计（Welcome 页 / Hardware 与 Sim 两页签 / 麦克风 / 单场景）

状态：设计定稿 2026-09-03。本文件是 core / sim / runtime / ui / docs 五层实现的**唯一契约**；
设计文档（05-ui、04-runtime、01-core、03-sim）随实现同步修订，冲突时以修订后的设计文档为准。
设计依据：`docs/design/` 现状、2026-09-03 的代码梳理（/tmp/mavis_ui_map.json）以及本机可用的
四个设计 skill（emil-design-eng、apple-design、review-animations、improve-animations），下文 §6 是
从中提炼出的、对本项目**有约束力**的视觉与动效规范。

## 目标

把目前偏调试/开发气质的前台改造成面向 MAVIS v2 这一台具体设备的、美观且 user-friendly 的产品界面：

1. Welcome 页顶部大标题 **APOLLO MAVIS V2**，小标题 **Manipulation and Viewpoint Selection**；浏览器
   标题改为 **APOLLO MAVIS V2**（模式页追加 " · Teleop" 等）。
2. Welcome 页有 **Hardware** 与 **Sim** 两个页签。两页签都显示两路腕部相机观测；Sim 额外显示
   **Environment Cam Front** 与 **Environment Cam Top**（保留现有仿真环境相机预览）。
3. **Hardware 页签在没有真机连接时也能打开**：相机 `camera1` / `camera2` 无信号时纯黑；麦克风
   （RØDE NT-USB Mini，装在 view 臂相机前）即使没有机械臂也要显示**实时声波预览**；但 Teleop /
   Data Collection / DAgger / Inference 四个模式只有在检测到真机机械臂后才可点击。
4. Sim 只提供一个场景：**APOLLO MAVIS V2 Digital Twin**（registry id `mavis_v2`）；其他场景对 UI 和
   API 隐藏（保留在 sim 包内供 CI/测试使用，不删除）。
5. "从当前状态开始 / 从 profile 开始" 保留但重新设计；**task 与 policy 的选择不出现在 Welcome 页**，
   在点击 Data Collection / DAgger / Inference 时以**页内弹窗**（原生 `<dialog>`，不是浏览器窗口）
   收集。
6. 仿真：view 臂上可选的**麦克风碰撞体**（默认关闭；硬件数字孪生打开）。

## 前置条件

- phase-06/07/08/10 已落地；submodule 结构；runtime 运行在 :8765，Vite 在 :5173。
- 必读：`docs/design/05-ui.md` §3/§7/§8/§9/§10/§11/§12，`04-runtime.md` §5/§13/§14，`03-sim.md`
  §3/§4/§8，`01-core.md` §11/§12/§14；`/tmp/mavis_ui_map.json`（五个 reader 的 file:line 地图）。
- 本机事实：RØDE NT-USB Mini = ALSA card `Mini`（USB 19f7:0015，序列号 750BFEE8），PulseAudio 源
  `alsa_input.usb-R__DE_Microphones_R__DE_NT-USB_Mini_750BFEE8-00.mono-fallback`，仅 S24_3LE 单声道
  48 kHz；PulseAudio 15.99 持有设备，直接打开 `hw:` 会 EBUSY，**必须经 Pulse**。runtime venv 里
  `sounddevice==0.5.6` 可纯 wheel 安装，libportaudio2 已在系统里；PortAudio 无 Pulse host API，只能用
  ALSA `pulse` 插件并用 `PULSE_SOURCE` 环境变量钉定源。现有 runtime 配置只有 `sim` workcell。

## 范围

### 1. core（拼写权威；改动全部 additive）

`protocol/session.py`
- `ArmStatusInfo.reachable: Literal["open", "refused", "unreachable", "unknown"] = "unknown"`
  （硬件探针结果：TCP 502 可连 / 拒绝（控制盒启动中）/ 不可达 / 未探测）。
- `WorkcellStatus.hardware_ready: bool = False`（所有配置的硬件臂 `reachable == "open"`）。
- `CameraInfo` 不变（`live: false` 表示已配置但未接入）。
- 新增 `MicrophoneInfo(BaseModel)`：`mic_id: str`，`label: str`，`kind: Literal["pulse", "fake", "none"]`，
  `source: str | None`，`sample_rate: int`，`channels: int = 1`，`live: bool`，`status: MicStatus`，`detail: str = ""`。
  `MicStatus = Literal["no_backend", "starting", "absent", "live", "stalled", "error"]`。

`protocol/telemetry.py`
- 新增 `MicrophoneTelemetry(BaseModel)`（全部字段有默认值）：`mic_id: str = "mic_view"`，
  `status: MicStatus = "no_backend"`，`detail: str = ""`，`seq: int = 0`，`age_s: float | None = None`，
  `rate_hz: float = 0.0`，`sample_rate: int = 48000`，`rms_dbfs: float | None = None`，
  `peak_dbfs: float | None = None`，`clipping: bool = False`，`env_min: list[int] = []`，
  `env_max: list[int] = []`（64 个 int8，-127..127，按时间顺序的最小/最大包络），`overruns: int = 0`。
- `TelemetryMsg.microphone: MicrophoneTelemetry | None = None`（additive，位于 `tracker` 之后）。

`schemas/config.py`
- `ArmConfig.microphone: bool = False`（硬件 workcell 里 view 臂设 true → 数字孪生带麦克风体）。

`EXPORTED_MODELS` += `MicrophoneInfo`；`MicrophoneTelemetry` 经 `TelemetryMsg` 的 `$defs`。同步
`__init__`/`__all__`、`tests/test_schema_export.py` 精确集合与属性集合、`tests/test_protocol.py`
`_WIRE_MODELS` 与 legacy-dict 断言。命令：`uv run pytest && export_schemas --out schemas/ && --check`。

### 2. sim

- `SceneDescriptor.title: str | None = None`、`SceneDescriptor.hidden: bool = False`；`SceneMeta` 同步
  （`title`、`hidden`、`microphones: dict[str, bool]`）；`SceneRegistry.list(include_hidden: bool = False)`
  默认过滤 hidden；`descriptor()/meta()/build()` 保持按 id 不过滤。8 个非实验室场景 YAML 加
  `hidden: true`；`mavis_v2.yaml` 加 `title: APOLLO MAVIS V2 Digital Twin`。
- 麦克风体：`ArmSpec.microphone: bool = False`（after-validator：要求 `wrist_cam` 为 true 且
  `gripper == "none"`）；`SceneOverrides.microphones: dict[str, bool]`（按臂覆盖，与 base_pose 同形）；
  `_customize_child` 在 link7 下加无关节 body `microphone`，一个圆柱 geom：**半径 0.040 m（直径 8 cm，
  用户 2026-09-03 纠正）**，轴 = link7 +z（法兰轴），从法兰面 z=0 到腕部相机平面 z=0.05 再向前 0.14 →
  `size=[0.040, 0.095]`，`pos=[0, 0, 0.095]`，`contype=conaffinity=1`，深灰 rgba，显式 mass
  （NT-USB Mini 约 0.35 kg + 支架，取 0.45 kg，注明待称重）。相机侧装在 x=0.055..0.080，径向间隙
  1.5 cm，不相交（测试用编译后网格顶点复核）。`mavis_v2.yaml` 的 view 臂写 `microphone: false`
  并在头部注释说明选项与数字。
- 数字孪生/门禁自动纳入（addressing 子树扫描）；新增 guardrail 场景 `mavis_v2_rail_sweep_mic`
  （`GuardrailScenario.overrides`），更新 `tests/test_guardrail.py` 的场景集合与 PASS 计数。
- 测试：hidden 过滤与 title；麦克风 flag 加 body/几何/焊接/nq·nu 不变/xml 往返；非相机臂拒绝；
  同一场景 override 开关；间隙复核。`docs/renders/mavis_v2/render_mavis_v2.py` 加 `--microphone`。
- 03-sim.md §3/§4.1/§4.3/§8/§14 同步，并注明 view 腕部相机画面底部约 12% 会被麦克风遮挡属正常（早先估算 7–8%，03-sim §4.3 实测 12%）。

### 3. runtime

**配置**
- `RuntimeConfig.microphone: MicrophoneConfig`：`enabled: bool = False`，`mic_id: str = "mic_view"`，
  `label: str = "View arm microphone"`，`backend: Literal["auto", "sounddevice", "parec", "fake", "none"] = "auto"`，
  `source_match: str = "NT-USB Mini"`（在 `pactl -f json list sources` 的 name/description 里子串匹配），
  `sample_rate: int = 48000`，`bins: int = 64`，`stale_s: float = 0.5`。帧率 = `telemetry_hz`
  （25 Hz → 1920 样本/帧 = 64 × 30，包络分箱精确）。
- `RuntimeConfig.scenes_visible: list[str] | None = None` **不做**——可见性由 sim 的 `hidden` 决定。
- `HardwareProbeConfig`（`RuntimeConfig.hardware_probe`）：`enabled: bool = True`，`period_s: float = 2.0`，
  `timeout_s: float = 1.0`，`port: int = 502`。
- `configs/mavis_v2.yaml` 与 `/tmp/mavis_v2_live.yaml`：新增 `workcells.hardware` 块（kind hardware，
  `digital_twin_scene: mavis_v2`，`safety.enabled: true`，arms `grip`（gripper xarm，ip 占位
  `192.168.1.185`）、`view`（gripper none，`microphone: true`，ip 占位 `192.168.1.186`），
  cameras `camera1`/`camera2`（kind v4l2，`device_path: /dev/v4l/by-id/TODO-camera1|2`，注明待用户给出
  真实映射）），`microphone.enabled: true`。占位 IP/路径只会让探针报 `unreachable`、相机报 `live: false`。

**场景**：`scene_infos()` 只列 `REGISTRY.list()`（默认已过滤 hidden），`label = meta.title or meta.description`。
`_validate` 对 `sim_scene`/`digital_twin_scene` 用 `REGISTRY.meta(id)`（不过滤），测试仍可用 `single_rail`。
重写 `tests/test_server_contract.py::test_scenes_listing`（只剩 mavis_v2；label 为 title）。

**硬件探针** `devices/hardware_probe.py`（Runtime 持有）：配置了 hardware workcell 时，后台线程每
`period_s` 对每臂 `ip:502` 做 connect-and-close（复用 `apollo_mavis_v2_hardware.netsetup.probe.tcp_probe`
若可导入，否则本地 socket 实现；永不写字节），发布 `{arm_id: reachable}` 快照；有硬件 session 运行时暂停。

**REST**
- `GET /api/workcell?kind=hardware|sim`（可选参数；缺省 = 现行为）：hardware → arms 来自配置
  （`ip` 填入，`reachable` 来自探针，`connected` 保持"有 session"语义），cameras 来自硬件相机配置
  （`live` 由预览是否成功打开决定），`hardware_ready`；sim → 现行为。
- `GET /api/microphones -> list[MicrophoneInfo]`：始终列出已配置的麦克风（absent 时 `live: false`）。
- `GET /api/cameras` 同时列出 sim 预览相机与硬件相机（硬件相机 `live: false` 时 UI 不开 WS）。

**硬件相机预览**：`start_previews()` 在存在 hardware workcell 时，逐个尝试
`apollo_mavis_v2_hardware.cameras.make_camera(cfg).start()`（失败隔离：`CameraInitError`/任何异常 →
`live: false`，不影响其他相机与 sim 预览），成功的注册到 VideoHub（`video.preview_fps`）。
`_bringup_sim` 的 `stop_previews()` 只停 sim 预览源，硬件相机预览保留（未连接时无副作用）。

**麦克风** `devices/microphone.py`（`MicrophoneReader`，镜像 `TrackerReader`）：
- 后台线程；`auto` 顺序：(1) `sounddevice.InputStream(device="pulse", samplerate=48000, channels=1,
  dtype="float32", blocksize=frame)`，打开前解析源名并设置 `os.environ["PULSE_SOURCE"]`；(2) `parec`
  子进程（`-d <source> --format=s16le --rate=48000 --channels=1 --raw --latency-msec=50`）；(3) `fake`
  合成（调幅正弦，测试用）。`sounddevice` 只在本模块内 lazy import（ruff banned-api + AST 守卫，与
  pysurvive 同款）。作为 runtime optional extra `audio = ["sounddevice>=0.5"]`，并在 venv 安装。
- 每帧：`peak`、`rms`（dBFS）、`clipping = peak >= -1 dBFS`、64 箱 min/max 包络（int8）、`seq`、
  `t_mono` → `LatestSlot`；`status(now)`：`absent`（1 Hz 探测 `/proc/asound/Mini` 或 pactl 源列表）、
  `stalled`（>stale_s 无帧）、`error`（打开失败，退避 0.5→5 s）；拔插用存在性探测 + 源索引校验。
- telemetry：`build_telemetry` 填 `microphone=`；`GET /api/microphones` 由同一 status 生成。
- 测试：backend none / fake（seq 推进、包络长度、rms 在合成包络内、停止后 stalled）、导入守卫、
  contract test（`/ws/telemetry` 与 `/api/microphones` 在 fake 下有块）、sounddevice 缺失 → 退到 parec/`no_backend`。

**其他**：`Runtime.__init__` 持有 `microphone` 与 `hardware_probe`，`stop()` 依次关闭；文档 04-runtime
§2 树、§13.1 路由、§13.3 telemetry 块、§14 配置。

### 4. ui（最大的一块；按 §6 规范执行）

**设计系统（先做，独立可测）**
- `src/styles/global.css` 令牌层：primitives → semantic → component；保留旧名（`--bg --panel --panel-2
  --border --fg --fg-dim --green --amber --red --blue --accent`）为新令牌的别名，避免一次性重写全部规则。
  新增 `--space-1..9`（4 px 基）、`--radius-1..4/pill`、`--shadow-1..3`、`--edge`、`--text-*` 字阶、
  `--dur-*`、`--ease-*`、`--stagger`，`color-scheme: dark`。`@media (prefers-reduced-motion: reduce)`
  统一降级（保留 opacity/color，去掉位移/缩放）、`prefers-reduced-transparency`、`prefers-contrast: more`。
- 字体：自托管 `public/fonts/InterVariable.woff2`（从 rsms/inter 最新 release 下载；下载失败则退回
  系统栈并在报告中注明），`@font-face` `font-display: swap`，`<link rel=preload>`；等宽用
  `"JetBrains Mono", ui-monospace, "SF Mono", Menlo, "Noto Sans Mono", monospace`（不下载）。所有实时数字
  `font-variant-numeric: tabular-nums`。
- `.btn` 体系：`.btn-primary`（`--accent-fill #0A84FF` + 白字，仅用于 ≥15 px/600 的大按钮）、
  `.btn-secondary`、`.btn-ghost`、`.btn-destructive`（`#C62828` + 白字，5.6:1）；`:active` 缩放 0.97
  仅在 `(hover:hover) and (pointer:fine)`；`:focus-visible` 2 px `--focus` 环；保留 `.btn-danger-big`
  行为（急停按钮不得加任何延迟）。
- `Sheet` 原语（`src/components/Sheet.tsx`）：原生 `<dialog>` + `showModal()`（焦点陷阱、Escape、top
  layer、inert 背景），`::backdrop` `--scrim` + `backdrop-filter: blur(8px)`，`@starting-style` 进场
  240 ms（opacity + translateY(8px) + scale(.98)）、退场 160 ms，`transform-origin: center`；头部
  （标题 + 上下文副标题 + 关闭 ×）、可滚动主体、固定底栏（左次要右主要）。`ConfirmDialog`、
  `ProfileActions` 的保存对话框、`TrackerCalibrationWizard` 改为基于 Sheet（保留 testid 与行为）。
- Toasts：玻璃面板、语气图标（info/success/warning/error，store 的 `tone` 扩展为四值）、显式 ×，
  `@starting-style` 进场 240 ms / 退场 160 ms（transition，不用 keyframes），info/success 6 s、warning
  10 s 自动消失（hover 与 `document.hidden` 时暂停），error 常驻。
- `StreamView` 重皮：16/9、`--radius-3`、1 px 边框、`data-state = live|connecting|stale|closed|absent`；
  左上标题药丸（`title` prop 显示名，stream id 保持规范 id），右上状态药丸（LIVE 为**静止**绿点；
  connecting 12 px spinner 700 ms linear；stale 灰纱 + STALE，**保留最后一帧**；closed 黑底文字）；
  新增 `absent` 态：纯黑 + 相机划线图标 + "camera1 · no signal"，**不建立 WebSocket**。
- `SegmentedControl`（`role=tablist`，一个 thumb 用 `transform: translateX` 200 ms `--ease-out`，
  键盘切换 0 ms）；`MicTile`（`<canvas>`，rAF 仅在新帧时绘制 3 s 滚动示波器 + 右侧电平条 + 峰值保持
  + dBFS 读数；`role=meter` 可访问性；数据来自 `telemetry.microphone`，按 `seq` 去重）。
- 图标：手绘内联 SVG（24 px 网格，1.5 px 描边），不引入图标库；不引入动画库/CSS 框架。

**信息架构（Welcome = `src/pages/Landing.tsx` 重写）**
- 顶部 hero：眉题 `--text-label` "Apollo Lab · Yale"；`<h1>` **APOLLO MAVIS V2**（`--text-display`）；
  副标题 **Manipulation and Viewpoint Selection**（`--text-title-2`，400，`--fg-2`）；同一行右侧：
  `SegmentedControl` Hardware | Sim + 低调的 "Devices" 幽灵链接（保留 `#/devices`）。
- 页签内容（crossfade 120/160 ms，键盘切换无动画）：
  - **Sim**：观测网格 2×2：`grip_wrist_cam` "Grip · wrist cam"、`view_wrist_cam` "View · wrist cam"、
    `cam_front` "Environment · front"、`cam_top` "Environment · top"（来自 `/api/cameras` 的 sim 预览流，
    `live` 才挂 `StreamView`）。状态行："APOLLO MAVIS V2 Digital Twin · 2 arms on rails"。
  - **Hardware**：观测网格 3 格：`camera1`、`camera2`（`/api/cameras` 中 `live:false` 或不存在 → `absent`
    黑块）+ `MicTile`（`/api/microphones` 有条目即显示；Sim 页签不显示）。状态行来自
    `GET /api/workcell?kind=hardware`（每 2 s 轮询，仅在该页签可见时）："No arms detected · camera1,
    camera2 · mic: RØDE NT-USB Mini (live)"；有臂时列出 `reachable` 状态。臂状态卡片保留但改为
    "Searching for arms…" 占位态（无臂）/ 已连接态。
- **Start from**：两行大单选（"Keep current state" / "Load a profile"，图标 + 标题 + 说明），选中行
  `--accent` 描边；选第二项时下方以 opacity 展开 profile 列表（名称、臂 chips、备注、"Initial
  condition" 药丸、勾选标记；不可用行灰显并给出原因；空态 "No saved profiles — save one from Teleop"）。
  语义与 05-ui §8.1 一致（`start_from = keep_current | profile:<id>`）。
- **Scene**：只读摘要行 "Scene · APOLLO MAVIS V2 Digital Twin · 2 arms · rails · 4 cameras"（UI 端
  过滤到 `scene_id === "mavis_v2"` 并自动选中；hardware 的 `digital_twin_scene` 同样隐式为 mavis_v2）。
- **模式启动卡片** `ModeLauncher`（4 张：Teleop "Drive both arms live" / Data Collection "Record
  episodes for a task" / DAgger "Policy drives, you correct" / Inference "Run a promoted checkpoint"）：
  整卡可点，`role=button`，键盘可达；禁用时保留在 tab 顺序中，图标/标题 55% 不透明，**可见的原因行**
  （"Requires real arms — none detected"、"No promoted checkpoint"、"Keymap unavailable — retry"、
  "Hardware workcell not configured"）。Teleop 直接启动；其余三个打开 `LaunchSheet`。
  Hardware 页签：四个模式的可用性 = `hardware_ready`（且 `available_kinds` 含 hardware）；Sim 页签：
  现有 `validateLaunch` 规则。
- **`LaunchSheet`**（基于 Sheet，宽 480）：标题 = 模式名，副标题 = 固定上下文（"Sim · APOLLO MAVIS V2
  Digital Twin · Keep current state"）；字段：Task（Data Collection/DAgger 必填，blur 时内联校验）、
  Policy（Inference：仅 promoted 的单选行 + "Promoted" 药丸；DAgger：加 "Latest" 行，默认 Latest）、
  "Advanced" 折叠里放每臂 recording frame 选择（`FrameSelector`）；底栏 "Cancel" / "Start Data
  Collection"（动词 + 模式名）；主按钮禁用时在其下方给出原因；提交即 `createSession(buildSpec(...))`，
  409 detail 显示在弹窗内（"no promoted deploy checkpoint"、"a session already exists"、
  "tracker calibration in progress"…）。`validateLaunch/buildSpec` 保持纯函数，扩展 `LandingSelection`
  加 `tab` 与 `hardwareReady`。
- `src/lib/streams.ts`：`STREAM_LABELS`、按页签的槽位顺序、`SCENE_ID`、`SCENE_DISPLAY_NAME`、
  `MODE_LABELS`（Teleop / Data Collection / DAgger / Inference）——Landing、Cockpit（侧栏标题、流标签、
  网格顺序：腕部相机 → 环境相机 → "Digital Twin"（`sim`）→ `twin`）、Devices（SessionControls 文案）共用。
- `document.title`：`useDocumentTitle` hook；Welcome "APOLLO MAVIS V2"，模式页 "APOLLO MAVIS V2 · Teleop" 等。
- Devices 页与 Cockpit 不重做布局，但自动继承令牌、按钮体系、Sheet、toast；Cockpit 的 Slash 键盘覆盖层
  **无动画**。
- 首次进入 Welcome 的 hero 渐显 320 ms + 卡片 40 ms stagger（sessionStorage 标记，只跑一次）。

**测试（vitest + RTL）**：fixtures 改为 MAVIS（view/grip、4 sim 相机、mavis_v2 同时在 sim/twin 列表、
硬件 workcell 含 camera1/camera2 与 hardware_ready）；Landing：页签切换的槽位集合与黑块、单场景自动选中、
Hardware 无臂时四模式禁用且原因可见、`hardware_ready` 为 true 时启用、Data Collection 弹窗收集 task 并
POST 正确 SessionSpec、Inference 弹窗仅列 promoted、409 显示在弹窗、Escape 关闭、标题字符串；
SegmentedControl 键盘；Sheet 焦点/Escape；MicTile 在 fake telemetry 下绘制并按 seq 去重（jsdom 需
stub `HTMLDialogElement.showModal/close` 与 `ResizeObserver`）；Toast 自动消失与 hover 暂停（fake timers）。
保留/更新 testid：`launch-<mode>`、`kind-<kind>`、`task-input`、`policy-select`（改为单选组亦保留该
testid 于容器）、`start-keep-current`、`start-profile`、`profile-<id>`、`initial-badge-<id>`、
`frame-selector-<arm>`、`keymap-retry`、`scene-picker-*`（只读摘要行）。
`npx tsc --noEmit && npx eslint . && npx vitest run && npm run gen:check` 全绿；`npx prettier --check` 对
改动文件通过。

### 5. docs

- 05-ui.md：§1 加"设计令牌与动效规范"（§6 摘要，binding）；§3 路由标题；§8.1 重写为新 IA；§8.4 注明
  Devices 继承令牌；§9 新组件 props（Sheet、SegmentedControl、ModeLauncher、LaunchSheet、MicTile、
  StreamView 的 `title`/`data-state`）；§10 退化态表（camera absent、mic absent/stalled、hardware not
  configured、no arms、no promoted checkpoint）；§11 测试；§12 契约点（`/api/workcell?kind`、
  `/api/microphones`、`telemetry.microphone`、`hardware_ready`、`reachable`）。
- 04-runtime.md：§2 树（devices/microphone.py、devices/hardware_probe.py）、§13.1 路由、§13.3 telemetry
  块、§14 配置（microphone、hardware_probe、workcells.hardware 示例）、§6 不变。
- 01-core.md：§11 `MicrophoneTelemetry`、§12 `MicrophoneInfo`、`ArmStatusInfo.reachable`、
  `WorkcellStatus.hardware_ready`、§7 `ArmConfig.microphone`、§14 EXPORTED_MODELS。
- 03-sim.md：见 §2。CLAUDE.md：场景文件路径修正为 `assets/scenes/mavis_v2.yaml`。
- `docs/prompts/README.md` 状态表加 phase-11 行。

### 6. 视觉与动效规范（binding，来自四个设计 skill 的提炼）

**人格**："crisp lab instrument"——专业仪表盘，不是消费级 app。动效快（≤240 ms）、临界阻尼（**任何地方
都不弹跳**）、只用于进出场/状态变化/按压反馈；层次靠表面明度阶梯 + 一套柔和阴影，不靠重玻璃。
文案短、具体、句首大写；只有安全状态（blocked / disconnected / terminate）允许"大声"。

**颜色（暗色默认；对比度已校验）**：`--bg #0A0C10`，`--surface-1 #12151B`，`--surface-2 #1A1F27`，
`--surface-3 #232934`，`--border #2A313C`，`--border-strong #3A4350`，`--fg #EEF1F5`，`--fg-2 #A7B0BD`，
`--fg-3 #7B8694`（仅 ≥12 px 辅助文字），`--accent #5AC8FA`（选中、焦点、波形），`--accent-fill #0A84FF`
（主按钮填充，白字只配 ≥15 px/600），`--on-accent #0A0C10`，状态三色沿用 05-ui 的 binding：
`--ok #2ecc71`、`--warn #f5a623`、`--danger #e74c3c`；`--danger-fill #C62828`；`--scrim rgba(0,0,0,.55)`；
`--glass rgba(26,31,39,.72)`；`--tile-bg #000`。浅色主题只定义为"light-safe 语义"，不出开关。

**字体**：Inter（自托管）→ 系统栈；字阶 display 44/1.05/700/-0.025em（clamp 32–44）、title-1 28、
title-2 20、title-3 16、body 14/1.5、callout 13、caption 12/500/+0.01em、label 11/600/+0.06em 大写、
mono 12–13 tabular。

**间距/圆角/阴影**：4 px 基；圆角 6/10/14/20/pill，内圆角 = 外圆角 − 内边距；阴影只做 y 偏移低 alpha
三档 + `--edge` 顶部 1 px 亮边；1 px 细边框；页面 max-width 1120、24 px 边距、16 px 网格间距；观测块 16/9。

**动效令牌**：`--dur-press 120ms`、`--dur-hover 150ms`、`--dur-fast 160ms`、`--dur-base 200ms`、
`--dur-enter 240ms`、`--dur-slow 320ms`（仅首屏 hero）；`--ease-out: cubic-bezier(0.23,1,0.32,1)`、
`--ease-in-out: cubic-bezier(0.77,0,0.175,1)`（仅屏内位移）、`--ease-drawer: cubic-bezier(0.32,0.72,0,1)`；
**禁止 ease-in**；`--stagger 40ms`（最多 6 项）。

**动什么 / 不动什么**：动：首屏 hero 与卡片进场（一次）、页签 thumb 与内容 crossfade、Sheet 进出场、
按压缩放（pointer-down 触发）、选中环颜色、toast 进出、STALE 纱进场。**不动**：视频 canvas、波形与电平
数值（每帧重绘，不用 CSS transition）、LIVE 圆点（静止）、键盘触发的一切（Slash 覆盖层、方向键切页签、
Escape）、hover 位移（只允许颜色/边框/阴影）。

**反模式清单**（评审时逐条查）：`transition: all`；`ease-in`/内建 `ease-in-out` 用于进出场；`scale(0)` 或
纯淡入的进场；对 width/height/margin/padding/top/left 做动画；父级 CSS 变量驱动子级 transform；
未 gating 的 `:hover` 位移；缺 `prefers-reduced-motion`；toast/toggle 用 keyframes；trigger 锚定的
popover 用 `transform-origin: center`（modal 除外）；对称的按压/释放时长；本该 stagger 的一起出现。

### Out of scope

- 真机 session 启动路径（`_bringup_hardware`，phase-09）；camera1/camera2 的真实设备映射（用户后续给出）；
  把音频录进数据集；浅色主题开关；Devices/Cockpit 的布局重做；policy service（另立 phase-12）。

## 交付物

五层代码 + 测试 + 文档修订 + 重新生成的 schemas / `src/gen`；`configs/mavis_v2.yaml` 与
`/tmp/mavis_v2_live.yaml` 的 hardware/microphone 配置块；`docs/renders/mavis_v2` 的 `--microphone` 变体。
不 commit（等用户指令）。

## 验收标准

- core / sim / hardware / runtime 全部 `uv run pytest` 与 ruff 全绿；`export_schemas --check` 通过。
- ui：`npx tsc --noEmit && npx eslint . && npx vitest run && npm run gen:check` 全绿。
- 真机（无机械臂，只有麦克风）：runtime 以 live 配置重启后，`GET /api/workcell?kind=hardware` 返回
  `hardware_ready: false`、两臂 `reachable: unreachable`；`GET /api/microphones` 返回 RØDE 条目
  `live: true`；telemetry 每帧含 `microphone`（`status: live`，`env_*` 64 项，对着麦克风说话 `rms_dbfs`
  显著升高）；Welcome 页 Hardware 页签：两块纯黑相机 + 实时波形，四个模式禁用且显示原因；Sim 页签：
  四路预览正常，Teleop 可直接启动，Data Collection 弹窗输入 task 后能启动并跳转。
- 动效评审：按 §6 反模式清单逐项通过；`prefers-reduced-motion` 下无位移动画。

## 注意事项

- 绝不直接打开 `hw:CARD=Mini`（PulseAudio 独占 → EBUSY 且会让系统其他录音卡死）；一律经 Pulse。
- 20 Hz 麦克风帧塞进 25 Hz telemetry 会出现重复帧——所以帧率对齐 `telemetry_hz`，UI 仍按 `seq` 去重。
- 不为缺席的相机挂 `StreamView`：`/ws/video/<id>` 对未知 id 返回 1008，客户端会无限重连并显示
  "Stream unavailable — retrying…"，与"纯黑"要求相悖。
- `ArmStatusInfo.connected` 的语义（"有 session"）不改；新增 `reachable` 承载探针结果。
- 把 `sounddevice` 装进 runtime venv 时用 `uv add --optional audio sounddevice` 后 `uv sync --all-extras`。
- 首次动效应该在 Chrome DevTools Animations 面板 10% 速度下逐个核对，第二天再看一遍（apple-design 的建议）。
