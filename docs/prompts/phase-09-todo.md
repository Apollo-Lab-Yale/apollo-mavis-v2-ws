# Phase-09 分工清单（你 vs Claude）

完整的执行手册与验收标准在 `phase-09-integration.md`（本文件只做分工拆分，
不重复细节）。执行记录最终落 `docs/acceptance/<cell_id>-<date>.md`。

## A. 需要你亲自做的（物理在场 / sudo / 决策）

**A0. 前置环境（去实验室前就可以做）**
- [x] ~~升级 NVIDIA 驱动~~ 2026-09-01 已由 Claude 完成到 **580.173.02** 并在你
      重启后验证通过：`nvidia-smi` 580.173.02、torch 2.11+cu130 双卡 CUDA 可用、
      EGL 渲染测试与 guardrail --all 全过、NVENC 可开。（同时清理了 409 个 ROS 包、
      修复 librealsense 源 key、恢复 Pop systemd 渠道、移除坏的 librealsense2-dkms
      ——udev rules 保留。）顺带修了 recorder 的 NVENC 探测 bug（真因是 lerobot 的
      `g=2` 需配 `bf=0`，与驱动无关）。
- [ ] **改 sudo 密码**：密码曾在聊天记录里出现过，尽快 `passwd` 换掉。
- [x] ~~处理 8000 端口占用~~ 2026-09-02 runtime 默认端口改为 **8765**（8000 由
      gohttpserver 服务占用，不再需要释放）。UI Vite 代理默认值、设计文档同步。
- [x] ~~（可选）确认三臂 IP 各在**不同子网**~~ 2026-09-04 确认：现在只有两台控制盒，
      Manipulation Arm 192.168.1.201/24、Perception Arm 192.168.2.219/24，两个子网
      （同子网会破坏 NIC 探测，research/network-manager.md 风险 #1）；固件两台均为
      **v1.12.10**（`7,7,XS1305,MC1303`，SDK 1.18.5 只读读出）——低于 gripper 电流读取所需的
      2.7.100，B2 的 port-30000 电流线程在这两台上不可用。

**A1. 网络 reconcile（一次性，需 sudo）**
- [x] ~~`python -m apollo_mavis_v2_hardware.netsetup install`~~ 2026-09-04 01:30 已从开发者
      tree 执行：polkit .pkla、`netdev` 组（含 xiatao）、NM dispatcher 钩子
      `/etc/NetworkManager/dispatcher.d/90-mavis-netsetup`（PYTHON 烤进的是开发者 venv——
      部署到 `mavis` 账号时按 DEPLOYMENT.md S5 重跑 install 指向 ops venv）。
- [x] ~~`... netsetup match` → 审阅 `... reconcile` → `reconcile --apply`~~ 2026-09-04 完成并
      验证：`/etc/apollo-mavis-v2/nic_map.json` 含两臂（grip→enp36s0f1 08:BF:B8:89:4F:3B，
      view→enp36s0f0 08:BF:B8:89:4F:3A），profile `mavis_manipulation_arm` /
      `mavis_viewpoint_arm` 已按 MAC + ifname 钉死并 active；`nmcli connection show` 已无
      `xarm7_*` 旧 profile，`ip route show default` 只剩 Wi-Fi 真路由（无 metric 20100 假路由）；
      `/var/log/mavis-netsetup.log` 最近一次 `repair done rc=0`，两臂 `[OK ]`。

**A2. 硬件逐级点亮（你握物理急停，Claude 操作软件）**
- [ ] 按 phase-09-integration.md「硬件逐级点亮」1→6 顺序陪跑：单臂低速 →
      rail → gripper → twin 对拍 → 双臂 gate 课目 → 完整 teleop/采集/DAgger。
      **首次真机 session 严格按 `phase-09c-hardware-session.md`「真机验收步骤」**（2026-09-05 代码落地，真机
      从未跑过；步骤 4 按其 09d 头注修订）：两臂 running、err 0 → Manipulation Arm 卡片 **Home rail**（dry-run
      扫掠 clear → 确认 → 滑台到操作员左端 → `rail 0.000 m`；09d：不 clear 则面板给出预定位规划，确认后臂先以
      10% 折叠再归零并保持该姿态，202 进度在面板里；立刻看叠加窗口，镜像则 `hardware_session.rail_flip: true`）→
      Perception Arm 同样归零 → Speed 10% → Teleop（09d：两臂都在 session 里，无 Include 开关）→ bring-up 进度到
      running、Cockpit `speed 10%`、不握 clutch 两臂静止 10 s → 握 clutch 移 5 cm（Manipulation Arm 跟随）→ 结束
      session（两臂停止抱闸、监视器恢复）。驱动 connect 写序列（clean → backstops → motion_enable → mode 0 →
      mode 1 → 100 Hz 发流）在真机上从未跑过，09d 起两臂都要连，所以 Perception Arm 的 C19 必须先清掉 / 在 Studio
      关掉末端设备（拒绝矩阵对已锁存错误 409；连上也会让驱动 LATCH）。
- [ ] **twin 对拍用 phase-09a 的叠加窗口**（已交付，无需运动指令即可先看）：Welcome 页
      Hardware 页签 `grip_wrist_align` / `view_wrist_align`——孪生按真机关节角淡黄半透明叠在
      腕部相机画面上，蓝线 = 孪生桌沿/障碍物边缘。现在两条导轨未归零，窗口小字
      "rail not homed · twin assumes 0.65 m"（grip）/ "0.00 m"（view）表示导轨位置是配置假设；
      归零（phase-09c：臂卡片 **Home rail**，孪生扫掠门禁的 `home_rail` 维护操作——唯一会动的维护操作）+
      使能后小字应消失、孪生导轨/臂与真机重合（不重合 / 镜像 → `hardware_session.rail_flip`）。Perception Arm 窗口里孪生的
      麦克风体遮住画面下方一大块而真机画面**没有**遮挡——这是要现场量出来的几何差异
      （麦克风体位置/尺寸，03-sim §4.3），先量再改场景，不要"修掉"叠加。
- [ ] 物理测量项：6 个示教位姿的卷尺实测 clearance（对 twin ≤4 mm）、
      各臂 `base_in_world` 与 rail 原点实测、相机外参标定（标定板）。
- [ ] **mavis_v2 场景校准**（`apollo-mavis-v2-sim/.../scenes/mavis_v2.yaml` 头部有全部
      假设）：① **2026-09-05 关闭、09-06 修正端面定义**——归零后实测"台面 +X 边缘到轨道
      **宽大端面** 14.5 cm、宽端面到基座圆柱中心 18.5–19 cm、凸台尖约 12 cm"。操作员说的
      "零位端"一直是那块 14 cm 宽的端板，**不是**再伸出 2.0 cm 的方形凸台；09-05 错把凸台
      当锚点，画出来的轨偏了 20 mm。现在轨网格偏移 y = **0.365093**、`base_pos` x0 = **+0.2800**
      （推导值 +0.2375 → 卷尺链 0.2750 → 09-06 腕相机残差回归 +5 mm：相机钉在台面上的四个卷尺
      参考点后，两轨零位端面仍比孪生多出 4–7 mm，两条台面参考读数互差 4.5 mm，以图像为准，
      臂轨一起移；端面到基座保持实测 18.7）；两轨间距按同一网格边在外轨对齐、内轨差 5 mm 定为
      **39.0 cm**（grip y0 −0.1786），卷尺的 39.5 在其误差内。**两臂原先都离障碍
      物端远了约 4 cm，即此前所有靠 +X 端的间距与扫掠判定都偏乐观**。仍偏乐观且需要更好
      网格才能修：网格滑台沿轨约短 7.5 cm（真机约 26 cm、以基座为中心），网格轨 1.0926 m 对
      真机 1.075 m（画出来的轨越过台面 −X 边缘 0.26 cm，故意把零位端对准——那一端有障碍物）；
      ⑥ **腕相机外参已于 2026-09-06 实测**：`wrist_cam` 由参考模型的猜测 (0.07, 0, 0.05)
      改为 (0.07294, −0.01709, 0.03019)，横向 17 mm、离法兰近 20 mm——这就是叠加图对不齐的
      全部原因；焦距（607±4 对配置 608.19）与转动（透视收敛比 1.0226 对 1.0226）都验证正确。
      麦克风体与相机位姿已解耦，仍待单独测量；
      ② 障碍物内角与 gripper 轨网格左端的静态重叠现为 1.4×2.0 cm，两者都焊在世界上、
      MuJoCo 会过滤，门禁与扫掠都碰不到；③ 相机轨外沿 2.6、轨宽 19.2 已确认；两轨 base 间距由腕相机定为 39.0（卷尺 39.5）；④ 臂法兰安装面高出台面 0.107188 m 是否属实；⑤ 电机盒在哪一端。
- [ ] watchdog/急停课目（拔 WS、手拍碰撞、物理急停）需要你现场触发。
- [ ] 验收表逐项签核。

## B. Claude 的待办

**B1. 无需真机（随时可做，说一声即开工）**
- [x] 2026-09-04 **phase-09a**（`phase-09a-hardware-twin-overlay.md`）：真机只读状态监视
      （hardware `monitor.py` `ArmStateMonitor`，零写入名单 + 调用日志断言；runtime
      `devices/hardware_monitor.py`，暂停 = 断开连接）+ 孪生叠加流 `streams/twin_overlay.py`
      （`*_align`，offsamples 0、D435i 彩色内参、env geoms → group 4）+ core
      `protocol/hardware_monitor.py` / `CameraInfo.kind "twin"` + UI 五格 Hardware 页签、
      C19 chip、caption twin 段；顺带修了首次真机只读接触发现的 6 个 SDK 1.18.5 bug
      （02-hardware §12）。五层测试全绿。
- [ ] phase-09a **真机只读验收**（主 agent 现场，控制盒开着即可）：runtime 重启后
      `telemetry.hardware_monitor.arms` 两臂 `running`、`q` 与 `get_servo_angle` 一致（±1e-3 rad）、
      Perception Arm `error_code 19`；`/api/cameras` 两路 `*_align` kind `twin` live；
      `/ws/video/grip_wrist_align` 12 fps；五个窗口 + 小字 + C19 chip；监视前后
      state/mode/error 不变（注意 02-hardware §8.5：SDK connect 在有 warn 时会 `clean_warn`，
      首次读寄存器可能改 RS-485 波特率——决定是否 `baud_checkset=False`）。
- [x] ~~runtime：`HardwareWorkcell` 组装进 session manager（hardware kind 目前
      409；代码 + FakeSDK 测试先落地，真机验证留 A2）~~ 2026-09-05 **phase-09c**
      （`phase-09c-hardware-session.md`）：`SessionManager._bringup_hardware`（拒绝矩阵 → 监视器 pause + join →
      子集臂 `WorkcellConfig`、`cameras: []` → 限速驱动工厂 → `bring_up` → 全新门禁孪生 + 无条件 `SafetyGate` →
      未选中臂冻结 → `ControlLoop(workcell_kind="hardware")` → 预览相机接管）、`SessionSpec.speed_scale`、
      `hardware_session` 配置块；hardware 驱动 connect 永不归零（`require_homed()` → `RailNotHomedError`），
      新维护操作 `home_rail`（只读监视器线程执行，`RailSweepChecker` 全程扫掠门禁，只按寄存器判定），
      `disconnect()` 停止 + 抱闸（D6）；ui **Home rail** / **Include in session**（09d 已移除：两臂常驻）/
      **Speed** / bring-up 进度。fake 全链路（unhomed → 409 → home_rail → running）通过；真机验证留 A2（该文件
      末尾的验收步骤）。**phase-09d**（`phase-09d-rail-homing-planning.md`，2026-09-05）在其上：`spec.arms` 必须等于
      全部臂、`default_arms` 删除；`home_rail` 姿态不 clear 时孪生规划位置无关路径 → `RailHomingJob`（202，
      `allow_unhomed` 连该臂、10% 门禁下折叠、`XArmDriver.home_rail()`、抱闸保持姿态）；真机 `start_from=profile`
      在 bring-up 内规划；Devices 页改名 Debug。
- [x] ~~五仓转 **git submodule** + ws 仓 .gitignore/README/CLAUDE.md 更新~~ 2026-09-03 完成
      （ws commit `baddf1d`，五个子仓各 tracking `main`）；[ ] 各仓 **tag** 尚未打（五仓目前无 tag）。
- [ ] **CI 接线**：五仓 GitHub Actions（core schema --check、sim 膨胀语义哨兵、
      guardrail --all 双侧回归、ui lint/gen:check/test/build；GPU job 标注
      self-hosted）。注意 runtime 的 `tests/dagger/test_trainer_integration.py`
      每步等 trainer 子进程 20 s（import torch），CPU 重负载下会抖动——CI 里
      单独串行跑，不与其他 job 抢核。
- [ ] dagger：checkpoint 外参快照校验（10-frames §5.3 的 TODO）；
      `apollo-dagger-retrain` / `apollo-dagger-fsck` CLI。
- [ ] 设计定案：无 gripper 时 TCP 约定（10-frames 增补一节）。

**B2. 需真机在场（A2 期间穿插）**
- [ ] 用一次真机抓包钉死 30003 报文 87 字节帧格式（replayer/fixture 钩子已备）。
- [ ] port-30000 gripper 电流读取线程（fw ≥ 2.7.100 的臂）。
- [ ] twin rail mesh / actuator 增益按实测回调（若对拍超差）。
- [ ] 现场发现缺陷的回改 commit。

## C. 建议顺序

A0（驱动+端口，实验室外即可）→ B1（Claude 先把无真机项清掉）→ 进实验室：
A1 → A2 × B2 穿插 → 验收签核 → 完成。
