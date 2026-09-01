# Phase 04 — apollo-xarm7-hardware：netsetup、XArmDriver、相机、HardwareWorkcell

## 目标

实现 `apollo-xarm7-hardware` 仓库：NetworkManager 网络自动匹配（netsetup）、
xArm7 驱动（mode-1 servo 流、错误恢复、rail、双种 gripper）、V4L2/RealSense 相机后端、
以及组装成 core `WorkcellInterface` 的 `HardwareWorkcell`。**全部功能不依赖真机即可落地**：
交付一个 fake-SDK 测试骨架（模拟 `XArmAPI` 行为，含错误注入），真机验证留到 phase-09。

## 前置条件

- 依赖 phase：01（可与 02/03 并行）。
- 必读设计文档：
  - `docs/design/00-overview.md` §3.3（ArmInterface）、§6（controller backstops、watchdog 恢复序列）、§7（bring-up 全节）
  - `docs/design/02-hardware.md`（本仓事实来源：驱动/网络/相机规格）
- 参考：`docs/research/xarm-python-sdk.md`（SDK 全部行为细节与坑）、
  `docs/research/network-manager.md`（nmcli 契约、目标机审计、polkit）、
  `docs/research/web-teleop-stack.md` §5（相机抽象）。

## 范围

包内（`apollo_xarm7_hardware`，依赖 core + `xarm-python-sdk==1.18.5` + opencv +
可选 pyrealsense2）：

- **units.py**：**唯一**的 m/rad ↔ mm、pulses/开度、rail m↔mm 转换点
  （`GRIPPER_PULSE_MAX=850`、`GRIPPER_G2_MM_MAX=84.0`、`RAIL_MM_MAX=650`；
  `pose_to_sdk/sdk_to_pose`（RPY = intrinsic XYZ，用 `core.se3` 的 quat↔RPY）；
  `rail_m_to_mm` 钳制 [0, 650] — SDK 不钳，超程触发 rail 错误 25/26）。
- **netsetup/**（`NetSetup` facade + `nmcli.py/probe.py/match.py/reconcile.py/
  install.py/state.py/__main__.py`；subprocess + `nmcli -t/-g`、`LC_ALL=C`、
  profile 一律按 **UUID** 寻址、`-w 10..15`；`NmcliRunner` 注入点做测试缝）：
  - `verify()`（每次会话启动，~1 s）/`match()`：从 config 读臂 IP → 算子网 →
    find-or-create manual-IPv4 profile（`ipv4.never-default yes`、无 gateway、
    `ipv6.method disabled`）→ 串行探测 carrier-on 且**不是**最低 metric 默认路由设备
    的 ethernet NIC（internet NIC 与非 ethernet 设备硬 denylist）→ `ping -c1 -W1 -I`
    重试 ≥3 + `ip neigh` 交叉验证 + TCP connect `(ip, 502)`（只连不写）→ 持久化
    `{arm → MAC, ifname, profile UUID}` 到 `~/.config/apollo-xarm7/nic_map.json`。
  - `reconcile(apply=False)`（一次性清理，先出 `ReconcilePlan` 再执行）：按 MAC +
    interface-name 钉死、去重/禁用 stale profile、剥离 gateway 污染、强制 manual；
    **绝不**碰正在承载 SDK 流量的活动 profile。
  - `install`/`install --check`：polkit `.pkla`（Ubuntu 22.04 = polkit 0.105，
    **JS `.rules` 无效**）+ `netdev` 组，headless 免 sudo。
- **XArmDriver**（`driver.py` + `config.py`，实现 `ArmInterface`；每臂一个
  `XArmAPI(ip, is_radian=True, report_type='real')`，`api_factory` 注入；
  `XArmDriverConfig`/`ServoLimits`（`max_cart_step_m=0.009`、joint-limit margin
  0.5°、lever-arm 保守 TCP 步长界））：
  - bring-up（`connect()`，02-hardware §3.2 顺序）：identity（`arm.sn` vs
    `expected_sn`，抓线缆插错）→ `clean_warn/clean_error` →
    `apply_backstops`（**backstops.py**：`set_tcp_load` 最先 →
    `set_collision_sensitivity(3)` → `set_self_collision_detection(True)` +
    `set_collision_tool_model` → 可选 reduced boundary → `set_collision_rebound(False)`；
    易失、每次 connect 重设、绝不 `save_conf()`）→ `motion_enable(True); set_mode(0);
    set_state(0)` → rail 探测 → gripper 初始化 → report 回调 → `set_mode(1);
    set_state(0)`，从 `get_servo_angle(is_real=True)` 播种流。
  - `_ServoStreamer`：mode 1 + `set_servo_angle_j`，100 Hz 专用线程/臂，latest-wins
    目标；每 tick 依次 vel/acc 限幅 + lever-arm TCP 步长估计 ≤ 9 mm + 限位 margin
    钳制；停顿后**重锚不补发**（catch-up 突发 = 速度尖峰 = C24）；`reseed(q)`。
  - 恢复状态机（`DriverPhase`：IDLE→CONNECTING→READY→STREAMING→FAULT→RECOVERING/
    LATCHED）：任何错误后控制器静默掉回 mode 0 — `clean_error → motion_enable →
    set_mode(1) → set_state(0) → 从测量位重播种` + 发 `ReseedEvent`（runtime 必须
    重锚 IK 目标）。错误分类：RECOVERABLE（22/31/35/24/23/25；预算 30 s 内 ≤3 次；
    C24 恢复后限速减半 10 s）/ UNRECOVERABLE（急停/伺服/通信 ⇒ LATCHED）/
    EXTERNAL（Studio 抢 mode/state ⇒ `StudioConflictWarning`）；**111 只闩 rail**，
    臂继续流。
  - rail（`rail.py::RailController`）：存在性 = `get_linear_track_registers()`
    code==0 **且** `get_linear_track_sn()` 有效（sim 模式控制器会静默吞 track 调用）；
    每次上电 `ensure_homed()`（`on_zero == 0` 时 `set_linear_track_back_origin(
    wait=True)`；未归零下发返回 code 82）；目标经 `command_joints` 的 `q[7]` 槽进入，
    5 Hz monitor 线程 `step()` 下发绝对 int mm（钳 [0, 650]、`wait=False`、
    |Δ| < 1 mm 跳过）；测得 rail 位置回填 `ArmState.q[7]`/`rail_pos_m`。
  - gripper（`grippers.py`：`GripperBackend` ABC + Classic/G2/No）：classic = 位置式
    0–850 pulses ↔ 0–0.085 m（`open_frac` 归一化，10 Hz 限频、|Δpulse|<5 跳过、
    绝不 `wait=True`；fw ≥ 2.7.100 可选 30000 端口电流监控）；G2 =
    `set_gripper_g2_position(mm, speed, force)`（0–84 mm、force 1–100%）—
    `GripperCommand.force` 只有 G2 生效；`gripper_force_capable` 正确上报。
  - 状态：30003 push 流（100 Hz，87 字节帧）经 report 回调写 `_StateSnap`（引用
    原子交换，`get_state()` 永不阻塞）；dq 有限差分 + EMA(α=0.5)；err/warn 由 5 Hz
    `_MonitorThread` 轮询（30003 不带）；report 静默 > **0.15 s** ⇒ `stale=True`。
- **相机**（`cameras/`，实现 `CameraInterface`，LeRobot 式）：每相机后台捕获线程 +
  latest-frame slot；`OpenCVCamera`（按 `/dev/v4l/by-id/` 路径打开，
  `CAP_PROP_FOURCC="MJPG"` **先设**、再 fps、再宽高，逐项 read-back 验证；连续 5 次
  read 失败 → reopen 一次再标记失败，不炸 workcell）；`RealSenseCamera`（按 serial，
  ≥1 s warmup，`hardware_reset()` 重试路径，`[realsense]` extra + import guard）；
  `find_all_cameras()` 合并两后端并**去重**（RealSense 也出现在 /dev/video*，RS 优先）。
- **HardwareWorkcell**（`workcell.py`）：装配 arms + cameras；`bring_up(status_cb,
  timeout_s=180)` 按臂并行、`ArmBringupStatus`（network/connected/rail/gripper/
  warnings）逐步回调（landing page 数据源）；probe `refused` ⇒ "臂在启动"，每 2 s
  轮询 502 而非重探 NIC；单臂失败不拖垮其它臂；`start_cameras()` **独立于臂
  bring-up**（会话开始前 landing page 就要 ~15 fps 实时预览）；Studio live-control
  冲突检测。
- **fake-SDK 测试骨架**：`tests/fakes/fake_xarm_api.py`（模拟 `set_mode/set_state/
  set_servo_angle_j/get_linear_track_registers/...`，`FaultScript` 错误注入 — 如
  servo 中途置 error_code=24、rail 未归零返回 82、错误后 mode 掉 0）+
  `tests/fakes/report_replayer.py`（回放 `fixtures/report/*.bin` 的 30003 流）。
  netsetup 测试用录制的 nmcli stdout fixture（含 `\:` 转义、重名 profile 等目标机实况）。

Out of scope：控制环/安全门/teleop（runtime）；真机/真网卡验证与 reconcile 实跑
（phase-09）；JPEG 编码推流（phase-05）。

## 交付物

- `apollo-xarm7-hardware/pyproject.toml`（依赖 core + `xarm-python-sdk==1.18.5` +
  opencv-python；extras：`realsense`）。
- `src/apollo_xarm7_hardware/`：`config.py units.py driver.py grippers.py rail.py
  backstops.py events.py workcell.py` + `netsetup/` + `cameras/`（02-hardware §1 布局）。
- `tests/` + `tests/fakes/{fake_xarm_api,report_replayer}.py` +
  `tests/fixtures/nmcli/*.txt` + `tests/fixtures/report/*.bin`。
- netsetup CLI：`python -m apollo_xarm7_hardware.netsetup
  {verify|match|reconcile|install|status}`（reconcile 默认只出 plan，`--apply` 才执行）。
- 安装文档：`docs/netsetup-install.md`（.pkla 内容 + `usermod -aG netdev`）。

## 验收标准

在 `apollo-xarm7-hardware/` 内执行（**无真机、无 root**）：

- [ ] `uv sync && uv run pytest` 全绿（全程不触网、不真调 nmcli — fixture/fake 驱动）。
- [ ] netsetup 单测覆盖：terse 输出 `\:` 反转义；两个同名 `xarm7_1` profile 场景下
      仍按 UUID 选对；internet NIC（最低 metric 默认路由设备）绝不进入候选池；
      "ping OK + 502 refused" 判定为"臂在启动 — 轮询 502 而非重新探测 NIC"；
      profile 创建参数含 `ipv4.never-default yes` 且无 gateway。
- [ ] 驱动恢复测试：fake SDK 注入错误（C24）后，驱动按序执行
      `clean_error → motion_enable → set_mode(1) → set_state(0)` 并**从当前位姿重播种**
      （fake 断言恢复后第一个 servo 目标 == 当前位姿，非旧目标）且发出 `ReseedEvent`；
      C24 恢复后限速减半 10 s；30 s 内第 4 次可恢复错误 ⇒ `LATCHED`。
- [ ] staleness 测试：report replayer 暂停 200 ms，`ArmState.stale` 在 0.15 s 处翻转
      为 True 并发事件，恢复推流后自动清除。
- [ ] rail 测试：`get_linear_track_registers` code!=0（或 sn 无效）⇒ `has_rail ==
      False` 且 `dof == 7`；code==0 且 sn 有效 ⇒ `dof == 8`；`command_rail(0.7)` 被钳
      到 0.650 m（650 mm）；未归零（on_zero==0）时 bring-up 先归零而非直接下发；
      注入错误 111 只闩 rail，servo 流不停。
- [ ] gripper 测试：classic 收到带 force 的 `GripperCommand` 时忽略 force 并只发位置
      （0.5 开度 ↔ 425 pulses）；G2 透传 force；`gripper_force_capable` 分别为
      False/True。
- [ ] 单位边界测试：`command_joints` 输入 rad，fake 收到 rad（`is_radian=True`）；
      cartesian 相关值 m ↔ mm 转换恰好一次、有测试钉死 1.0 m == 1000.0 mm。
- [ ] 100 Hz 流软实时测试：fake SDK 下 servo 线程 1000 tick 的节拍 p99 < 12 ms；
      逐 tick 断言 `sent_joints` 满足 vel/acc 限幅与 lever-arm TCP 步长 ≤ 9 mm
      （`max_cart_step_m=0.009`）；mock `monotonic` 停顿 50 ms 后无补发突发。
- [ ] `uv run python -m apollo_xarm7_hardware.netsetup reconcile`（fixture 注入的
      `NmcliRunner`）输出的 `ReconcilePlan` 恰好 = 去重 + 剥 gateway + 按 MAC 钉死 +
      优先级；不带 `--apply` 不执行任何 mutating nmcli 命令。

## 注意事项

- `XArmAPI` 构造必须 `is_radian=True` — 默认是**度**；mode 1 忽略 speed/mvacc，
  平滑完全归调用方，**每 tick cartesian 步进 < 10 mm（固件极限）**，官方推荐固定
  20–100 Hz 频率发送。
- `set_state(0)` 必须跟在每次 `set_mode()` 之后 — 换模式会把 state 挪出 ready。
- `report_type='real'`（30003, 100 Hz）时 rich-report 独有缓存（温度、reduced-mode）
  不更新 — 需要时开第二个 raw socket 到 30002 或低速轮询。
- rail 是控制箱 RS-485 上的 modbus 从设备：**没有高速流接口**，位置式 move-and-wait
  语义；当慢轴处理（稀疏绝对目标 + `wait=False`），测得位置软件回填 TF。掉线表现为
  控制器错误 **111**。
- 控制器 simulation mode 下 gripper/track 调用被 `@xarm_is_not_simulation_mode`
  静默吞掉返回成功 — bring-up 时读 `arm.mode`/version 甄别。
- `emergency_stop()` 只是软件 `set_state(4)`，不清错、非 STO — 真正的急停是物理按钮；
  文档里写清楚。
- 不要与 UFACTORY Studio "Live control" 同时跑 — 它会抢 mode/state。
- nmcli 侧：profile 一律 UUID 寻址（目标机现存两个同名 `xarm7_1`）；probe 前要临时
  清掉 `connection.interface-name` 否则 `ifname` 覆盖会失败；profile 单活 — 串行探测、
  失败即 `con down`；首个 ping 常被 ARP 吃掉 — 重试 ≥3。
- 锁 `xarm-python-sdk==1.18.5`；`*_linear_track_*` 与 `*_linear_motor_*` 是别名
  （SDK 1.17.0+），代码统一用一种拼写。
