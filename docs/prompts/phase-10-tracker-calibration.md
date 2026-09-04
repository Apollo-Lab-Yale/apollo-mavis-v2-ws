# Phase-10 — 追踪器标定向导（基站标定 + 航向对齐，前端页内弹窗）

状态：设计定稿 2026-09-03（本文件既是任务书也是三层实现的**唯一契约**；设计文档
`docs/design/13-tracker-teleop.md` §3/§4/§5/§6 随实现同步修订，冲突时以修订后的设计文档为准）。

## 目标

让实验室操作员不再需要命令行就能完成 Vive 控制器追踪的两种标定，全部在 UI 的
Devices 页（`#/devices`）通过**页内弹窗向导**（复用现有 `.modal-backdrop/.modal` 样式，
不是浏览器原生对话框）完成：

1. **Base-station calibration（基站标定）**：重新求解三个 Lighthouse 基站的相互位姿。
   2026-09-03 的根因分析证明：单点标定得到的基站位姿互不一致（同一物理点两站解相差
   26 cm），控制器一动 libsurvive 就在各站解之间跳变（"往一个方向走一段就跳回"）；
   多位置标定（全局场景求解器 GSS 收集 ≥ 6 个静止场景）后一致性达到毫米级。向导要
   把这套流程（采集 → 验证 → 安装）产品化，并且**遥操作时冻结标定**
   （`--globalscenesolver 0 --disable-calibrate 1`）。
2. **Yaw alignment（航向对齐）**：用 7 次点击手势（起点、左、前、右、后、上、下）拟合
   lighthouse 世界 → MJCF 世界的 yaw（`tracker_settings.yaw_deg`），替代手填数字；
   基站重标定后世界坐标系会重新锚定，yaw 必须重做，向导要把这个依赖显式化。

## 前置条件

- Phase 05/06 完成；13-tracker-teleop v0.1 的 tracker 路径（reader、TrackerTeleop、
  Devices 页、`tracker_settings`）已在真机上工作。
- 必读：`docs/design/13-tracker-teleop.md`（全部）、`04-runtime.md` §6/§13/§14、
  `05-ui.md` §4/§7/§8.4/§9-12、`01-core.md` §10-12/§14/§19、
  `scripts/tracker/03-lh-consistency-check.sh`（验证步骤的命令行原型）。
- 实测依据（2026-09-03，`~/apollo/calib/`）：单点标定后异地验证 —— 运动模式窗口
  下定位 std 61/62/53 mm、最大台阶 248 mm、单站解偏移 259 mm；多位置标定
  （14 个场景，光学残差 RMS 0.22 mrad）后 std ≤ 0.1 mm、最大台阶 0.1 mm、
  留一法偏移 ≤ 3.1 mm。验收阈值由此而来：**std < 5 mm 且最大台阶 < 20 mm**。

## 范围

### 1. 命名与传输（binding）

- 两种标定统一叫 **tracker calibration**，`kind ∈ {base_station, yaw}`。
- 传输走 **REST**（`/api/tracker/calibration`），进度走 **telemetry**
  （`TrackerTelemetry.calibration`）。理由：Devices 页无 session；`/ws/control` 的动作在
  无 session 时被 nack（`ws_control.py` "no session"），且 AckMsg 没有载荷。这是对
  04-runtime §13.1 "REST = management CRUD" 的**补充 binding 决定**：无 session 的
  设备管理操作走 REST，进度经 telemetry 广播。
- 两种标定都要求**没有活动 session**（409 `"stop the session first"`）：基站标定要重启
  reader，航向手势的触发器点击会在 session 中触发 clutch。标定进行中 `POST /api/session`
  返回 409 `"tracker calibration in progress"`。

### 2. core（`apollo_mavis_v2_core/protocol/tracker.py`，新模块；core 是拼写权威）

```python
CalibrationKind  = Literal["none", "base_station", "yaw"]
CalibrationPhase = Literal["idle", "starting", "capturing", "validating", "fitting",
                           "installing", "done", "failed", "aborted"]
CalibrationOp    = Literal["start", "capture", "validate", "install", "apply", "abort"]
YawPointLabel    = Literal["start", "left", "forward", "right", "back", "up", "down"]

class LighthouseStatus(BaseModel):
    index: int
    channel: int | None = None
    serial: str | None = None
    pose: PoseMsg | None = None      # lighthouse-world pose (m, wxyz)
    scenes: int = 0                  # GSS scenes solved for this station
    reference: bool = False          # "Using LH i as reference lighthouse"

class CalibrationValidation(BaseModel):
    samples: int = 0
    std_mm: tuple[float, float, float] = (0.0, 0.0, 0.0)
    max_step_mm: float = 0.0
    threshold_std_mm: float = 5.0
    threshold_step_mm: float = 20.0
    passed: bool = False

class YawGesturePoint(BaseModel):
    label: YawPointLabel
    pose: PoseMsg                    # RAW lighthouse-world pose at the click

class TrackerCalibrationStatus(BaseModel):
    kind: CalibrationKind = "none"
    phase: CalibrationPhase = "idle"
    detail: str = ""
    started_at: float | None = None  # unix s
    elapsed_s: float | None = None
    # base-station
    scenes: int = 0                  # max over stations
    lighthouses: list[LighthouseStatus] = Field(default_factory=list)
    stations_visible: int = 0
    controller_still: bool | None = None
    validation: CalibrationValidation | None = None
    installed_path: str | None = None
    backup_path: str | None = None
    # yaw
    yaw_points: list[YawGesturePoint] = Field(default_factory=list)
    next_point: YawPointLabel | None = None
    fitted_yaw_deg: float | None = None
    fit_residual_deg: float | None = None
    fit_checks: list[str] = Field(default_factory=list)  # failed checks; empty = ok
    applied_yaw_deg: float | None = None
    # persisted calibration state (always filled)
    yaw_valid: bool = True
    yaw_calibrated_at: float | None = None
    base_station_installed_at: float | None = None

class TrackerCalibrationCommand(BaseModel):
    kind: Literal["base_station", "yaw"]
    op: CalibrationOp
    point: YawPointLabel | None = None   # yaw 'capture' label; None = next_point
```

- `TrackerTelemetry.calibration: TrackerCalibrationStatus | None = None`（additive；子模型随
  `TelemetryMsg.json` 的 `$defs` 导出，UI 生成器自动得到同名接口）。
- `EXPORTED_MODELS` 增加 `TrackerCalibrationStatus`、`TrackerCalibrationCommand`
  （REST 直接使用；其余子模型经 `$defs`）。`protocol/__init__.py`、`__all__` 同步；
  `tests/test_schema_export.py` 精确集合、`tests/test_protocol.py::_WIRE_MODELS`、
  `TrackerTelemetry` 属性集合断言同步更新（附带把已在代码里的 `charging` 一起钉住）。
- 类名唯一，避免 json-schema-to-typescript 别名重编号；不要新增 keymap 行。
- 命令：`cd apollo-mavis-v2-core && uv run pytest && uv run python -m apollo_mavis_v2_core.protocol.export_schemas --out schemas/ && ... --check`。

### 3. runtime

**配置**（`config.py`）
- `RuntimeConfig.calibration_dir: Path = Path("~/apollo/calibration")`（加入 expanduser 元组）。
- `TrackerConfig.libsurvive_config_path: Path = Path("~/.config/libsurvive/config.json")`。
- `TrackerConfig.calibration: TrackerCalibrationConfig`：`min_scenes: int = 6`、
  `validation_seconds: float = 10.0`、`validation_skip_seconds: float = 3.0`、
  `validation_std_mm: float = 5.0`、`validation_step_mm: float = 20.0`、
  `still_window_s: float = 0.5`、`still_threshold_mm: float = 3.0`、
  `yaw_min_leg_m: float = 0.10`、`yaw_max_residual_deg: float = 15.0`、
  `yaw_capture_average_s: float = 0.3`。

**`devices/tracker.py`（pysurvive 唯一 import 点，不变）**
- `TrackerReader.restart(libsurvive_args: list[str]) -> None`：`stop()`（join，
  `simple_close` 释放 dongle）→ `self.cfg = self.cfg.model_copy(update={"libsurvive_args": args})`
  （**不得**原地改共享的 `TrackerConfig`）→ `start()`。
- libsurvive INFO 行接收：`_on_survive_log` 中 level ≥ 2 的行去掉 ANSI 转义后进入
  `self.info_lines: deque[tuple[float, str]]`（maxlen 256）并调用可选 `on_info` 回调；
  回调在 C 线程上执行，绝不能抛异常。
- `TrackerReader.lighthouses() -> list[LighthouseSnapshot]`：reader 线程每 0.5 s 在
  `_libsurvive_events` 循环里遍历 `simple_get_first_object/next_object`，取
  `simple_object_get_type == ps.SurviveSimpleObject_LIGHTHOUSE` 的对象（永远用 `ps.<常量>`
  比较，测试桩的枚举值不同），记录 name、`simple_serial_number`、
  `simple_object_get_latest_pose`；锁保护快照。
- reader 重启期间 `status()` 正常返回 `starting/searching`，loop 靠样本过期自然 hold。

**`devices/tracker_calibration.py`（新，Runtime 持有，不进 ControlLoop/SessionManager）**
- `class TrackerCalibration(reader, settings, cfg: RuntimeConfig, slot: LatestSlot[TrackerSample],
  session_active: Callable[[], bool], clock=time.monotonic, wall=time.time)`；
  `status() -> TrackerCalibrationStatus`（廉价、锁保护，25 Hz 调用）；
  `command(cmd: TrackerCalibrationCommand) -> TrackerCalibrationStatus`，非法迁移抛
  `CalibrationError(detail)`（REST → 409）；`active` 属性；`close()`（进程退出时若在标定中
  先恢复正常参数再停 reader）。工作线程负责计时相关阶段。
- 正常参数 = `cfg.tracker.libsurvive_args`；派生"采集参数"时先剥掉其中的
  `--globalscenesolver X`、`--disable-calibrate X`、`--configfile X`、`--force-calibrate X`、
  `--use-stationary-sensor-window X` 成对项。
- **base_station 状态机**
  - `start`：检查 backend == libsurvive（否则 409 `"backend is not libsurvive"`）、无 session、
    未在标定中。备份当前 `libsurvive_config_path` 到 `calibration_dir/base_station-<ts>.json`
    作为**临时配置**（libsurvive 会改写 `--configfile` 指向的文件，绝不直接指向正式路径）；
    `reader.restart(capture_args)`，`capture_args = 正常参数剥离项 + ["--configfile", tmp,
    "--force-calibrate", "1", "--globalscenesolver", "1"]`；phase `starting` → 收到第一条
    `Force calibrate flag set` 或首个位姿后 `capturing`。
  - `capturing` 期间工作线程解析 INFO 行：`Global solve with (\d+) scenes for (\d+)`
    → 每站 scenes（`scenes` 取最大值）；`Using LH (\d+) \((\w+)\) as reference lighthouse`
    → `reference`；`OOTX not set for LH in channel (\d+)` / lighthouse 快照 → `channel`、
    `stations_visible`；`controller_still` = 最近 `still_window_s` 内样本位置 std <
    `still_threshold_mm`。`detail` 给操作员看：`"scenes 3/6 — park the controller still ≥ 3 s at another spot"`。
  - `capture`（在 done/validating 之后想继续采）：`reader.restart(正常剥离项 + ["--configfile",
    tmp, "--globalscenesolver", "1"])`（**不带** `--force-calibrate`，保留已有解继续细化）。
  - `validate`：要求 `scenes ≥ min_scenes`（否则 409 说明差几个）。`reader.restart(剥离项 +
    ["--configfile", tmp, "--globalscenesolver", "0", "--disable-calibrate", "1",
    "--use-stationary-sensor-window", "0"])`；等 tracking，丢弃前 `validation_skip_seconds`，
    收集 `validation_seconds` 的有效样本，算三轴 std（mm）与相邻样本最大台阶（mm）；
    `passed = all(std) < validation_std_mm and max_step < validation_step_mm`；phase → `done`
    （`validation` 填好，`detail` 为 "validation passed — install" 或 "validation failed — capture more spots"）。
  - `install`：要求 `validation.passed`。备份正式文件为 `<path>.bak-YYYYMMDD-HHMMSS`
    （沿用既有命名）→ 复制 tmp 字节到正式路径 → 复制一份到
    `calibration_dir/base_station-<ts>-installed.json` → 持久化文件写
    `base_station_installed_at`、`lighthouse_config_sha256`、`yaw_valid=false` →
    `reader.restart(正常参数)` → phase `done`，`detail = "installed — run Yaw alignment"`。
  - `abort`（任何阶段）：`reader.restart(正常参数)`，phase `aborted`，tmp 保留在
    `calibration_dir` 供排查。
- **yaw 状态机**
  - `start`：无 session、未在标定中；`yaw_points=[]`，`next_point="start"`，phase `capturing`。
  - 采集：两种触发等价 —— 工作线程以 ~50 Hz 读 `slot`，在新鲜有效样本上检测
    `controller.trigger_pressed` 的**上升沿**；或 REST `op=capture`（UI 按钮；fake backend
    无按钮时唯一途径）。记录点 = 最近 `yaw_capture_average_s` 内有效样本原始位置的均值
    （姿态取最新）。7 点齐后 phase `fitting` 立即完成拟合并回到 `done`（等待 `apply`）。
  - 拟合 `fit_yaw(points, cfg) -> (yaw_deg, residual_deg, checks)`（纯函数，独立单测）：
    水平四腿 `left = P1−P0, forward = P2−P1, right = P3−P2, back = P4−P3`，操作员坐标约定
    （CLAUDE.md "Hardware facts"、13-tracker §6）：`left→+X, forward→−Y, right→−X, back→+Y`；
    单位向量 `u_i`（取 xy 分量归一化）与期望 `e_i`，
    `θ = atan2(Σ(u_x e_y − u_y e_x), Σ(u_x e_x + u_y e_y))`，即 `Rz(θ)·u_i ≈ e_i`，
    与 `align_pose(raw, yaw_deg)` 的定义一致（`p_world = Rz(yaw)·p_raw`）；
    `residual` = 四腿 `Rz(θ)u_i` 与 `e_i` 夹角的均值（deg）。检查（任一失败 → `fit_checks`
    非空、`fitted_yaw_deg` 仍给出但 `apply` 被 409 拒绝）：每条水平腿长 ≥ `yaw_min_leg_m`；
    水平腿 `|dz| ≤ 0.5|d|`；`up = P5−P4` 满足 `dz > 0` 且 `dz ≥ 0.5|d|`，`down = P6−P5`
    满足 `dz < 0`（确认 lighthouse 世界 z 朝上且手势没做反）；`residual ≤ yaw_max_residual_deg`。
  - `apply`：`settings.update(yaw_deg=fitted)` → 持久化 `yaw_deg`、`yaw_valid=true`、
    `yaw_calibrated_at` → phase `done`、`applied_yaw_deg`。
  - `capture` 在 `done` 阶段（全部 7 点已采）返回 409；`start` 可重来；`abort` 清空。
- **持久化** `calibration_dir/tracker_calibration.json`：
  `{"yaw_deg": float|null, "yaw_valid": bool, "yaw_calibrated_at": float|null,
  "base_station_installed_at": float|null, "lighthouse_config_sha256": str|null}`；
  `Runtime.__init__` 在 `TrackerSettings.from_config` 之前读取：若存在且 `yaw_valid` 且
  `yaw_deg` 非空 → 覆盖 `cfg.tracker.yaw_deg`（YAML 只是启动默认值）。`yaw_valid=false`
  时 telemetry 照实报告，UI 显示"需要航向对齐"。
- **接线**：`Runtime.__init__` 创建 `self.tracker_calibration`，`Runtime.stop()` 先 `close()`；
  `server/rest.py`：`GET /api/tracker/calibration -> TrackerCalibrationStatus`、
  `POST /api/tracker/calibration (TrackerCalibrationCommand) -> TrackerCalibrationStatus`
  （`CalibrationError` → 409 `{detail}`）；`post_session` 在标定中返回 409；
  `ws_telemetry.build_tracker_telemetry` 填 `calibration=runtime.tracker_calibration.status()`。
- **测试**：`fit_yaw` 单测（合成手势、+180° 陷阱、腿太短、上下反向、噁声）；状态机单测用
  duck-typed 假 reader（记录每次 `restart` 参数、可注入 INFO 行与 lighthouse 快照）+ 手工喂
  `LatestSlot` 样本，覆盖 base_station 全流程（参数逐阶段断言、场景计数、验证通过/失败、
  安装的备份与字节复制在 `tmp_path`、`yaw_valid` 置假、abort 恢复正常参数）与 yaw 全流程
  （触发器上升沿 + REST capture、apply 持久化、启动覆盖 yaw）；`test_tracker_controller.py`
  的 StubPS 增加 LIGHTHOUSE 对象与 INFO 行，验证 `restart`/`lighthouses()`/INFO 队列；
  e2e（LiveServer + backend=fake）：`GET` 初始状态、base_station `start` → 409
  "backend is not libsurvive"、yaw 全流程经 REST、telemetry 含 `calibration` 块、有 session
  时 409。真机测试门 `APOLLO_TRACKER_HW=1`。

### 4. UI（apollo-mavis-v2-ui）

- 类型：`npm run gen:sync && npm run gen:types && npm run gen:check`（pnpm 的 gen:* 目前在
  预检就失败，用 npm）。
- `src/api/rest.ts`：`getTrackerCalibration()`、`postTrackerCalibration(cmd)`（非 2xx 抛
  带 `detail` 的错误）。
- 新组件 `src/components/TrackerCalibrationWizard.tsx`：props
  `{ kind: "base_station" | "yaw"; onClose(): void }`；状态全部来自
  `useStore(selectTracker)?.calibration`（不自持流程状态，刷新页面不丢）；页内弹窗：
  `.modal-backdrop > .modal[role=dialog][aria-modal][aria-labelledby]`，打开时聚焦主按钮，
  `Escape` 与背景点击 = Close；进行中（capturing/validating/starting/installing）Close 先
  显示一行内联确认 "Abort calibration?"。步骤条 `.wizard-steps`。
  - base_station 步骤：**Intro**（要求：控制器开机、三站可见、无 session；按钮 Start）→
    **Capture**（大字 `scenes N / min_scenes`，基站表 index/channel/serial/scenes/reference，
    `controller_still` 指示，操作提示；按钮 Validate（scenes ≥ min 才可用）、Abort）→
    **Validate**（`.analog` 进度条、结果表 std/max step 与阈值、pass/fail 徽标；按钮 Install
    （passed 才可用）、Capture more、Abort）→ **Done**（installed/backup 路径，amber 提示
    "Yaw alignment required"，按钮 Start yaw alignment（切 kind）、Close）。
  - yaw 步骤：**Intro**（操作员站位与四个方向的含义：left=+X 等；按钮 Start）→
    **Points**（大字下一点标签 + 指令 "Move LEFT 20–30 cm, hold still, pull the trigger or
    click Capture"，已采点列表；按钮 Capture、Restart、Abort）→ **Fit**（yaw、residual、
    checks 列表；按钮 Apply（checks 为空才可用）、Redo、Cancel）→ **Done**（applied yaw）。
  - 失败/中止阶段显示 `detail` 与 Retry/Close。
- Devices 页侧栏新增 **CalibrationPanel**（`src/components/devices.tsx` 或新文件）：
  状态行（`yaw_valid` → 绿 chip "yaw aligned <date>" / 琥珀 chip "yaw alignment needed"；
  上次基站安装日期）+ 两个按钮；禁用条件与原因：tracker 为空 / backend none / 有 session
  （"Stop the session first"）；REST 409 → toast。`Devices.tsx` 持有 `wizard: null | kind`。
- 样式只加最少 class（`.wizard-steps`、`.wizard-step.is-active`、`.stations-table`），沿用
  tokens/chips/analog。
- 测试（vitest + testing-library，mock fetch + 直接写 store）：面板禁用原因、按钮 → POST
  body 正确、各 phase 渲染、Escape 关闭、进行中 Close 需二次确认、409 → toast。
  `npx tsc --noEmit && npx eslint . && npx vitest run && npm run gen:check` 全绿。

### 5. 文档

- `13-tracker-teleop.md` 升 v0.2：头部日期修订；§3 追加第 7/8 项（新模型、REST）；§4 增
  "Calibration modes" 块（状态机、参数、INFO 行解析契约——依赖 pinned 的 libsurvive commit、
  临时 configfile、安装/备份、恢复正常参数、持久化文件与启动覆盖）；§5 增向导；§6 改写为
  "向导是操作流程，CLI（survive-cli --force-calibrate、03-lh-consistency-check.sh）是后备"，
  修正过时地标（rail zero 现在在操作员**左**侧 +X），记录正常模式参数与 2026-09-03 依据；
  §7 删除"手势代替数字"。
- `01-core.md` §10/§11/§12/§14（含 `charging`）；`04-runtime.md` §2 树、§6 新 bullet、
  §13.1 两行路由 + "Not REST" 段补充 binding、§14 新配置键；`05-ui.md` §4/§8.4/§9/§10/§11/§12；
  `00-overview.md` §10 doc map 加 13-tracker 一行；`docs/prompts/README.md` 状态表加 phase-10 行。

### Out of scope

- 基站的物理摆位建议、修复 ch7 基站；多控制器；把 yaw 写回 YAML；SteamVR。

## 交付物

core 新模块 + schemas；runtime `tracker_calibration.py`、reader 扩展、REST、telemetry、配置、
测试；UI 向导 + 面板 + 测试 + 重新生成的 `src/gen/protocol.ts`；文档修订。不 commit
（等用户指令）。

## 验收标准

- `cd apollo-mavis-v2-core && uv run pytest && uv run python -m apollo_mavis_v2_core.protocol.export_schemas --out schemas/ --check` 全绿。
- `cd apollo-mavis-v2-runtime && uv run ruff check src tests && MUJOCO_GL=egl uv run pytest -q` 全绿
  （e2e 在负载下偶发超时不算，需单独重跑通过）。
- `cd apollo-mavis-v2-ui && npm run gen:check && npx tsc --noEmit && npx eslint . && npx vitest run` 全绿。
- fake backend e2e：yaw 向导用 7 次 `capture` 走完并 `apply`，telemetry `settings.yaw_deg` 变为
  拟合值，重启进程后 `yaw_deg` 来自持久化文件。
- 真机（用户在场）：基站向导采集 ≥ 6 场景 → 验证 std < 5 mm、最大台阶 < 20 mm → 安装后
  `~/.config/libsurvive/config.json` 更新且备份存在 → 航向向导 7 点 → 地标验证（控制器朝基座
  移动，末端朝基座移动）。

## 注意事项

- libsurvive 在 `--record` 且未显式 `--configfile` 时会把配置切到 `<rec>.json`；本设计始终
  显式传 `--configfile`。`--run-time` 在此构建无效。
- `simple_close` 未完成前不得再次 `simple_init`（LIBUSB_ERROR_BUSY）；`restart` 必须先 join。
- INFO 行含 ANSI 转义；正则前先剥离。GSS 只在控制器**静止 ≥ 0.54 s、间隔 > 3 s**时收场景。
- 采集阶段临时配置会被 libsurvive 反复改写，属正常；正式文件只在 `install` 时被替换。
- 操作员坐标约定是拟合的核心：操作员站在 +Y 外沿面向 −Y，左 = +X，前 = −Y（CLAUDE.md）。
  站位不同则 yaw 差 180°（2026-09-02 的 −77.9 → 102.1 教训）。
