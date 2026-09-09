# Phase-09a — 真机只读状态监视 + 数字孪生叠加窗口（phase-09 的前置步骤）

状态：设计定稿 2026-09-04。本文件是 core / hardware / runtime / ui / docs 五层实现的**唯一契约**；
设计文档（01-core、02-hardware、04-runtime、05-ui、03-sim）随实现同步修订，冲突时以修订后的设计文档为准。
不写任何运动指令：本阶段对控制盒**只读**，是 phase-09 真机接入前验证数字孪生几何的工具。

## 目标

1. runtime 在没有 session 时也持续读取两台真机的状态（关节角、导轨、夹爪、错误码），
   经 telemetry 暴露（`telemetry.hardware_monitor`），Welcome 页 Hardware 页签的臂卡片显示真实错误码。
2. Hardware 页签新增**两个独立的渲染窗口**（不是叠在腕部相机预览上）：`grip_wrist_align` 与
   `view_wrist_align`。每个窗口 = 对应腕部相机的真机画面 + 数字孪生（mavis_v2 场景，Perception Arm
   带麦克风体）按真机关节角/导轨位置做正运动学后，从孪生里同一台腕部相机、用 D435i 彩色内参渲染，
   只保留机械臂/导轨/夹爪/麦克风/相机体的像素，染成**淡黄色半透明**叠加。页签总共五个窗口：
   两路腕部相机、两路叠加、一路麦克风波形。
3. 用叠加图判断孪生（导轨位置与朝向、基座位姿、相机外参、关节约定）与真机是否对齐。

## 前置条件（2026-09-04 在真机上只读测得，实现时视为事实）

- 两台控制盒固件 v1.12.10（`7,7,XS1305,MC1303`），SDK xarm-python-sdk 1.18.5（pinned git rev）。
  两臂 `state 4`（未使能）、`mode 0`。**Perception Arm（view，192.168.2.219）持续报控制器错误 C19
  "End Module Communication Error"**（末端模块通信）；Manipulation Arm 无错误。
- **关节约定已验证为恒等映射**：把控制器的 7 个关节弧度原样写进 `mavis_v2` 模型的 `<arm>_joint1..7`，
  `<arm>_link7` 相对 `<arm>_link_base` 的位姿与控制器 `get_position()`（tcp_offset 为零 = 法兰）一致到
  0.0 mm / 0.00°（两臂）。**不加 π 偏移**（q1+π 会差 180°）。`mavis_v2` keyframe 的 joint1 = π 表示初始
  状态时真机 joint1 本身就转到 180°（用户决定），不是坐标偏移。link7 原点 = 控制器法兰 TCP；
  `<arm>_link_tcp` site 在法兰下方 172 mm（模型值 `link_tcp` pos 0 0 .172，03-sim §3；2026-09-07 更正，此前误写 168.6）（夹爪指尖）。
- **导轨（linear track）目前未归零、未使能**：`get_linear_track_registers` →
  `{pos: 0, status: 2, error: 0, is_enabled: 0, on_zero: 0}`（两臂相同）。此时 `pos` 无意义。归零
  （`set_linear_track_back_origin`）是运动指令，属 phase-09。SDK 1.18.5 的 `XArmAPI` 实例**没有**
  `get_linear_track_sn` / `get_linear_track_version`（`rail.py:77` 调用它会 AttributeError）；有
  `get_linear_track_registers/pos/status/on_zero/is_enabled/error`、`set_linear_track_*`、
  `clean_linear_track_error`、`get_linear_motor_registers`。
- 离线原型（`~/apollo/camera_mapping/overlay_proto_*.png`）表明：在当前姿态下，Manipulation Arm 腕部
  相机看到两条导轨；孪生按 grip rail = 0.65、view rail = 0.0 渲染时两条导轨与真机画面大致重合，另一臂
  基座出现在画面下方、与真机一致；取 grip rail = 0 时孪生会在画面上方多出一截手臂，与真机不符。
  即真机 Manipulation Arm 滑台当前物理上在操作员右端（sim q≈0.65）——尽管它的导轨寄存器读 0。
  Perception Arm 相机当前朝外（厨房），孪生里它看到自己的麦克风体占据画面下方一大块，而真机画面**没有**
  任何遮挡：麦克风体的几何/位置与真机不符，叠加窗口会直观显示这一点。
- D435i 彩色内参（`rs-enumerate-devices -c`，640×480，Inverse Brown-Conrady，畸变忽略）：
  - `grip_wrist`（USB 序列号 349643062582，RS ASIC 序列号 327122074467）：fx 608.19 fy 608.23 cx 327.39 cy 247.90
  - `view_wrist`（USB 序列号 322143060792，RS ASIC 序列号 243522071002）：fx 606.36 fy 606.38 cx 311.90 cy 249.45
  fovy = 2·atan(240/fy) ≈ 43.2°，**不是** MJCF 里的 fovy 57（那是深度视场）。
- 渲染事实（sim reader 在本机 MuJoCo 3.12.0 + EGL 验证）：分割渲染必须 `spec.visual.quality.offsamples = 0`，
  否则多重采样把边缘像素混成别的合法 geom id（掩膜面积膨胀、质心偏 37 px）。相机内参用
  `cam.resolution=[640,480]`、`cam.sensor_size`、`cam.focal_pixel=[fx,fy]`、`cam.principal_pixel`，
  **MuJoCo 的主点偏移符号与 OpenCV 相反**（`principal_pixel = [320-cx, 240-cy]`，验证到 <0.5 px）。
  地面/桌子/障碍物是 geom 0,1,2（`Addressing.env_geom_ids`），臂/导轨/夹爪/麦克风/相机体与之同在 group 0，
  要把 env geoms 移到 group 4 后用 `MjvOption.geomgroup[4]=0` 隐藏，或用分割 id → `geom_bodyid` 判定。
  GL 上下文线程亲和：`mujoco.Renderer` 必须在使用它的线程里创建和关闭；一个 `MjData` 只归一个线程。
- 真机相机节点已被 runtime 的预览 `OpenCVCamera` 打开（UVC 不能二次打开）：叠加只能复用
  `SessionManager._hw_cameras[cam_id].latest()` 的帧。
- 现有 hardware 代码从未连过真机。**已确认的 bug**（同一 SDK 源码核对）：
  1. `driver.py:398-405` `register_report_callback(..., report_mode=True)` — SDK 1.18.5 无此关键字 → TypeError
     （`FakeXArmAPI` 接受 `**kwargs` 所以测试通过）；
  2. `driver.py:488` `_on_report` 读 `data["mode"]` — 30003 报文不含 mode（只有 `mode_changed` 回调有）→
     `snap.mode==0` 触发 Studio 冲突检测 → 连上约 1.2 s 后被 `_latch`；应用 `api.mode` 属性或
     `register_mode_changed_callback`；
  3. `driver.py:373` `parse_fw(str(api.version))` 解析的是 `7,7,XS1305,MC1303,v1.12.10` 这种串 → 主版本号错误，
     应用 `api.version_number`；
  4. `rail.py:77` `get_linear_track_sn` 不存在（见上）；
  5. `workcell.py:241-249` 未把 `driver.connect_warnings` 复制进 `ArmBringupStatus.warnings`；
  6. `grippers.py:213` G2 `set_gripper_g2_position` 未传 `wait_motion=False` 会阻塞 5 Hz 监视线程。

## 范围

### 1. core（拼写权威；全部 additive）

- `protocol/session.py`：`CameraInfo.kind` 增加 `"twin"`（叠加流在 `/api/cameras` 里的种类）。
- 新模块 `protocol/hardware_monitor.py`：
  ```python
  ArmMonitorStatus = Literal["off", "connecting", "running", "stale", "paused", "error"]
  class ArmMonitorTelemetry(BaseModel):
      arm_id: str
      status: ArmMonitorStatus = "off"
      detail: str = ""                  # e.g. "controller error 19: End Effector Communication Error"
                                        #   (the SDK's title for C19; xArm Studio: "End Module Communication Error")
      seq: int = 0
      age_s: float | None = None
      q: list[float] = []               # 7 joint angles, rad, controller order (identity to the twin)
      tcp_pose: list[float] = []        # controller flange pose [x,y,z m, roll,pitch,yaw rad] in base frame
      rail_present: bool | None = None  # registers readable
      rail_homed: bool | None = None    # on_zero == 1
      rail_enabled: bool | None = None
      rail_pos_m: float | None = None   # None unless homed AND enabled (position meaningless otherwise)
      rail_raw_mm: float | None = None  # raw register, always reported when present
      gripper_open_frac: float | None = None  # 0 closed .. 1 open; None for gripper "none"
      gripper_raw: float | None = None  # raw SDK reading for diagnosis
      error_code: int = 0
      warn_code: int = 0
      state: int | None = None          # controller state (4 = stopped / not enabled)
      mode: int | None = None
  TwinOverlayStatus = Literal["off", "waiting", "live", "stale", "error"]
  class TwinOverlayTelemetry(BaseModel):
      stream_id: str                    # grip_wrist_align / view_wrist_align
      camera_id: str                    # grip_wrist / view_wrist
      arm_id: str
      status: TwinOverlayStatus = "off"
      detail: str = ""                  # e.g. "rail not homed - twin assumes 0.65 m" (metres, 2 decimals)
      fps: float = 0.0
      rail_fallback_m: float | None = None   # set when the fallback is in use
      joint1_offset_rad: float = 0.0
      mask_fraction: float = 0.0        # robot pixels / image pixels of the last frame
  class HardwareMonitorTelemetry(BaseModel):
      enabled: bool = False
      paused: bool = False              # a hardware session owns the boxes
      arms: list[ArmMonitorTelemetry] = []
      overlays: list[TwinOverlayTelemetry] = []
  ```
- `protocol/telemetry.py`：`TelemetryMsg.hardware_monitor: HardwareMonitorTelemetry | None = None`
  （additive，位于 `microphone` 之后）。`EXPORTED_MODELS` 不变（子模型经 `TelemetryMsg` 的 `$defs`）；
  `__init__`/`__all__`、`tests/test_schema_export.py`、`tests/test_protocol.py` 同步；
  `uv run pytest && export_schemas --out schemas/ && --check`。

### 2. hardware

**修 bug（先做，独立提交）**：上面 6 条。`tests/fakes/fake_xarm_api.py` 改成镜像真实 SDK：
`register_report_callback` 只接受 SDK 1.18.5 的关键字（`report_cartesian/report_joints/report_state/
report_error_code/report_warn_code/report_cmd_num/report_mtable/report_mtbrake/report_cmd_num`… 以源码为准，
**不接受** `report_mode`）；报文 payload 不含 `mode`；提供 `mode`/`version_number` 属性；
不提供 `get_linear_track_sn`（用 `hasattr` 检查的代码路径要能在无该方法时工作）。`rail.detect()` 改为：
registers 可读即 present；若 `get_linear_track_sn` 存在再校验 `AL13` 前缀，否则记一条 warning。

**新模块 `monitor.py`（只读）**：
```python
@dataclass(frozen=True)
class ArmMonitorSample:   # 与 core ArmMonitorTelemetry 字段一一对应 + t_mono
class ArmStateMonitor:
    def __init__(self, arm_id, ip, *, gripper: Literal["xarm","xarm_g2","none"], expect_rail: bool,
                 poll_hz=10.0, stale_s=0.5, reconnect_s=2.0, api_factory=None, clock=time.monotonic)
    def start(self) -> None; def stop(self, timeout=2.0) -> None
    def snapshot(self) -> ArmMonitorSample | None; @property status; @property detail
    def disconnect(self) -> None  # release the box (hand-over); start() again reconnects
```
- 连接：`XArmAPI(ip, is_radian=True, do_not_open=True)` → `connect()`；线程以 `poll_hz` 轮询：
  `get_servo_angle(is_radian=True)`、`get_position(is_radian=True)`（mm→m 经 `units`）、
  `get_err_warn_code()`、`state`/`mode` 属性；每第 N 轮（≈2 Hz）：`get_linear_track_registers()`
  （`rail_pos_m` 仅当 `on_zero==1 and is_enabled==1`，经 `units.rail_mm_to_m`；`rail_raw_mm` 始终给），
  夹爪（G2：与 `grippers.py` 的 G2 后端同一条读路径与同一 open_frac 换算；`none` 跳过）。
- **零写入**：允许调用的 SDK 名单写在模块顶部；测试用带调用日志的 fake 断言除名单外无任何调用
  （尤其无 `motion_enable/set_mode/set_state/clean_error/clean_warn/set_*`）。
- 断线：异常 → status `error` + detail，`reconnect_s` 起指数退避到 10 s；`stale` = 最近样本超过 `stale_s`。
- 事实注释：SDK `connect()` 可能在有 warn 时自行 `clean_warn`（`base.py:520`）；首次读导轨/夹爪寄存器
  可能改写 RS-485 波特率并软重启末端模块（`base.py:2597`）——写进 docstring 与 02-hardware。
- 测试：fake 注入；样本字段与单位；导轨未归零 → `rail_pos_m is None`、`rail_raw_mm` 有值；
  `stop()`/`disconnect()` 后 `disconnect` 被调用一次；重连退避；零写入断言。

### 3. sim

无强制改动。可选：`docs/design/03-sim.md` §7 记录叠加渲染配方（offsamples=0、内参属性与主点符号、
env geoms 分组）。**不要**改 MJCF 的 link_base 朝向或 keyframe——关节约定已验证。

### 4. runtime

**配置（`config.py`）**
```python
class HardwareMonitorConfig(BaseModel):
    enabled: bool = True; poll_hz: float = 10.0; stale_s: float = 0.5; reconnect_s: float = 2.0
class TwinOverlayConfig(BaseModel):
    enabled: bool = True
    fps: float = 12.0
    alpha: float = 0.5                          # robot tint opacity
    tint_rgb: tuple[int,int,int] = (255, 235, 140)   # pale yellow, shaded by the twin's own luminance
    edge_rgb: tuple[int,int,int] = (255, 220, 60)    # 1 px robot outline
    env_outline: bool = True                    # table / obstacle edges as thin lines (alignment cue)
    env_rgb: tuple[int,int,int] = (90, 200, 250)
    stale_tint_rgb: tuple[int,int,int] = (170, 170, 170)  # monitor stale/error -> grey
    joint1_offset_rad: float = 0.0              # diagnostic knob; identity is verified
    rail_flip: bool = False                     # q_sim = 0.65 - q_track when true
    rail_fallback_m: dict[str, float] = {"grip": 0.65, "view": 0.0}  # used while the track is not homed
    stream_suffix: str = "_align"
RuntimeConfig.hardware_monitor / .twin_overlay
```
`configs/mavis_v2.yaml`：两台相机加 `intrinsics: {fx, fy, cx, cy}`（上面的数值）；新增两个配置块；
头部注释记录导轨未归零、view 臂 C19。`tests/test_configs.py` 同步。

**`devices/hardware_monitor.py`**：`HardwareStateMonitor(cfg: HardwareMonitorConfig, workcell: WorkcellConfig,
paused: Callable[[], bool], monitor_factory=<seam, default ArmStateMonitor>)`。每臂一个
`ArmStateMonitor`；线程每 0.5 s 检查 `paused()`：变 true → 对所有臂 `disconnect()`（**暂停 = 释放连接**，
两个 SDK 客户端共用一台控制盒没有证据可行）；变 false → 重新 `start()`。`snapshot() -> dict[str, ArmMonitorSample]`、
`telemetry() -> HardwareMonitorTelemetry`（arms 部分）。`paused` 谓词 = `Runtime._hardware_session_active`。
hardware 包不可导入时 `enabled` 自动为 false，status `off`，detail 说明。

**`streams/twin_overlay.py`**：
- `TwinOverlayRenderer(cfg: TwinOverlayConfig, workcell: WorkcellConfig, twin_scene: str, monitor: HardwareStateMonitor,
  frame_source: Callable[[str], CameraFrame | None], hub: VideoHub, clock)`，一个线程拥有
  `BuiltScene`（`REGISTRY.build(twin_scene, SceneOverrides(microphones={a.id: a.microphone for a in arms}, base_pose=<若配置>))`）
  的 spec 副本：`offsamples=0`，每个腕部相机按 `CameraConfig.intrinsics` 设置 `resolution/sensor_size/focal_pixel/principal_pixel`
  （无内参时 fovy 用 2·atan(H/2/fy) 的默认 43.2° 并记 warning），env geoms 移到 group 4；`spec.compile()` 后
  `Addressing`；`Renderer` RGB + 分割各一个，在线程内创建与关闭。
- 每帧（`cfg.fps`）：取 `monitor.snapshot()`；每臂 `qpos[7 joints] = q + [joint1_offset, 0...]`，
  `qpos[rail] = rail_pos_m`（`rail_flip` → 0.65−pos）或 `rail_fallback_m[arm]`（此时 telemetry
  `rail_fallback_m` 置值，detail "rail not homed - twin assumes X m"），夹爪手指 qpos 由 `gripper_open_frac`
  经 sim 的 gripper 换算（`(1-f)*0.85`）；`mj_forward`。
- 合成：`real = frame_source(camera_id).rgb`（None → 该流 status `waiting`，不发帧）；RGB 渲染 + 分割掩膜
  （robot = 非 env geoms）；`shade = lum(twin)`，`tint = tint_rgb * (0.55 + 0.45*shade)`；
  `out[mask] = alpha*tint + (1-alpha)*real`；robot 轮廓 1 px `edge_rgb`；`env_outline` 时另做一遍
  env-only 分割并画 Canny 边缘 `env_rgb`；monitor 该臂 `stale/error` → 用 `stale_tint_rgb`。
  发布 `CameraFrame(camera_id=stream_id, rgb=out, t_mono=real.t_mono, wallclock_ns, seq)` 到该流的
  `FrameSource`；`hub.add_stream(stream_id, source, cfg.fps)` 在启动时注册两路流。
- telemetry：每流 `TwinOverlayTelemetry`（fps 用 1 s 滑窗；`mask_fraction`）。
- 停止：先停线程（关闭 Renderer），再 `hub.remove_stream`。

**接线**：`session/manager.py` 增 `hardware_camera(cam_id) -> CameraInterface | None`；
`hardware_camera_infos()` 追加两行 `CameraInfo(camera_id=<cam>_align, kind="twin", label, resolution=(640,480),
fps=int(cfg.fps), live = 真机相机 live and overlay status in (live, stale))`；`_hardware_arm_infos` 的
`error_code` 取自 monitor（无样本则 0）；`_twin_scene`/所有 `REGISTRY.build` 传 `SceneOverrides(microphones=...)`。
`runtime.py`：在 `start_previews()` 之后构造并启动 monitor → overlay；`stop()` 顺序：overlay → monitor →
其余。`server/ws_telemetry.py`：`hardware_monitor=build_hardware_monitor_telemetry(runtime)`。

**测试**：`tests/test_hardware_monitor.py`（fake 工厂：pause → disconnect → resume）；
`tests/test_twin_overlay.py`（MUJOCO_GL=egl；FakeCamera 给一帧 640×480；fake monitor 样本让 grip 臂处于
keyframe 姿态；断言两流在 hub、`/api/cameras` 两行 kind twin、`/ws/video/grip_wrist_align` 收到 `<dI` JPEG、
`mask_fraction > 0`、导轨 fallback 生效时 telemetry 字段与 detail、monitor stale → 灰色（抽样像素）、
有硬件 session 谓词时 `live:false`）。契约测试 `test_server_contract.py` 的 telemetry 断言加 `hardware_monitor`。

### 5. ui

- `src/lib/streams.ts`：`HARDWARE_OVERLAY_SLOTS = ["grip_wrist_align", "view_wrist_align"]`，
  `HARDWARE_GRID_SLOTS = ["grip_wrist", "grip_wrist_align", "view_wrist", "view_wrist_align"]`
  （`HARDWARE_CAMERA_SLOTS` 保持两路真机相机，录制帧选择等处继续用它）；`STREAM_LABELS` 加
  `grip_wrist_align: "Manipulation · twin overlay"`、`view_wrist_align: "Perception · twin overlay"`；
  `orderStreams` 让叠加排在对应腕部相机之后。
- `src/components/landing.tsx` `ObservationGrid`：Hardware 页签渲染 `HARDWARE_GRID_SLOTS` + `MicTile` = 5 格，
  class `obs-grid-5`：三列，第 1 列两路真机相机、第 2 列两路叠加、第 3 列麦克风跨两行（波形更高，
  canvas 随高度自适应）；≤1100 px 时两列，麦克风占满一行。叠加格是普通 `StreamView`（`title` 为显示名，
  `live:false` → 黑色 absent，不开 WebSocket）。叠加格下沿显示一行小字（`tile-badge`）：来自
  `telemetry.hardware_monitor.overlays[stream_id]` 的 `detail`（如 "rail not homed · twin assumes 0.65 m"、
  "monitor stale"），无 detail 不显示。
- `hardwareCaption`：在相机段后追加 `· twin: <Manipulation Arm 状态>, <Perception Arm 状态>`，状态取
  `hardware_monitor.arms` 的 `status`，`error_code != 0` 时写 `error C<code>`（如 `Perception Arm error C19`）。
- 臂卡片：`error_code != 0` 时显示红色 chip `C19`（数据来自 `/api/workcell?kind=hardware`，已由 runtime 填好）。
- `npm run gen:sync && npm run gen:types && npm run gen:check`；fixtures 加 `HARDWARE_OVERLAY_IDS`、
  `makeOverlayCameras(live)`（kind `twin`）、`makeHardwareMonitor()`；Landing 测试：五格与 class、叠加
  absent 而相机 live 的情形、caption 精确字符串、detail 小字、C19 chip；`streams.test.ts` 同步。
  `npx tsc --noEmit && npx eslint . && npx vitest run && npm run gen:check` 全绿。

### 6. docs

- 本文件；`docs/prompts/README.md` 状态表加 09a 行；`phase-09-integration.md` 把"渲染 vs 相机叠加"验收项
  指向本阶段的窗口；`phase-09-todo.md` 勾掉已完成的 netsetup 行并加 09a 行。
- `01-core.md` §11（`HardwareMonitorTelemetry` 等）、§12（`CameraInfo.kind` twin）。
- `02-hardware.md`：§8 之后新增 "read-only monitor" 小节（零写入名单、暂停=断开、SDK 副作用事实）；
  §5 导轨：SDK 1.18.5 无 `get_linear_track_sn`、未归零时 pos 无意义；记录本次修的 6 个 bug。
- `04-runtime.md`：§2 树（`devices/hardware_monitor.py`、`streams/twin_overlay.py`）、§13.3 telemetry 块、
  §13.4 流 id（`*_align` 保留）、§14 配置块与 intrinsics。
- `05-ui.md`：§8.1 五格布局、§9 组件 props、§10 退化态（overlay waiting/stale/error）、§12 契约点。
- `03-sim.md` §7：叠加渲染配方（可选）。
- `CLAUDE.md` Hardware facts：D435i 彩色内参；导轨当前未归零读 0；view 臂 C19；关节约定恒等已验证；
  SDK 1.18.5 的 API 缺口。
- `docs/deploy/DEPLOYMENT.md` S7：`/api/cameras` 检查加两路 `*_align`。

### Out of scope

- 任何运动指令（归零导轨、使能、set_mode）；`_bringup_hardware`（phase-09）；G2 夹爪模型；
  相机外参标定算法（叠加是目测工具）；把叠加流放进 Cockpit。

## 交付物

五层代码 + 测试 + 文档修订 + 重新生成的 schemas / `src/gen`；`configs/mavis_v2.yaml` 新块；
`~/apollo/mavis_v2_live.yaml` 由 `scripts/deploy/render-lab-config.sh` 重新渲染。不 commit（等用户指令）。

## 验收标准

- core / hardware / runtime 全部 `uv run pytest` 与 ruff 全绿；`export_schemas --check` 通过；
  ui 四项全绿。
- 真机（只读，控制盒开着即可）：runtime 重启后 `telemetry.hardware_monitor.arms` 两臂 `running`，
  `q` 与 `get_servo_angle` 一致（±1e-3 rad），Perception Arm `error_code 19`；`/api/cameras` 列出
  `grip_wrist_align`/`view_wrist_align` kind `twin` live；`/ws/video/grip_wrist_align` 12 fps JPEG；
  Hardware 页签五个窗口，叠加窗口里导轨/机械臂淡黄半透明，小字显示 "rail not homed · twin assumes 0.65 m"；
  臂卡片显示 C19。
- 对控制盒零写入（fake 调用日志断言 + 真机上 `state/mode/error` 在监视前后不变）。

## 注意事项

- 叠加流 id 不得以 `_wrist_cam` 结尾、不得与任何相机 id 相同（`04-runtime.md` §13.4 的保留规则）。
- 不要在叠加线程外触碰它的 `MjData`/`Renderer`；不要复用 phase-09 门禁的 `DigitalTwin` 实例。
- 主点符号：`principal_pixel = [W/2 - cx, H/2 - cy]`。渲染分辩率必须恰好 640×480。
- 真机相机帧为 RGB uint8 (480,640,3)（`OpenCVCamera` 已做 BGR→RGB），合成不再翻转。
- 麦克风体在孪生里遮挡 view 相机画面下方一大块而真机没有：这是要向用户展示的差异，不要"修掉"。
