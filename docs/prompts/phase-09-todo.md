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
- [ ] **twin 对拍用 phase-09a 的叠加窗口**（已交付，无需运动指令即可先看）：Welcome 页
      Hardware 页签 `grip_wrist_align` / `view_wrist_align`——孪生按真机关节角淡黄半透明叠在
      腕部相机画面上，蓝线 = 孪生桌沿/障碍物边缘。现在两条导轨未归零，窗口小字
      "rail not homed · twin assumes 0.65 m"（grip）/ "0.00 m"（view）表示导轨位置是配置假设；
      归零 + 使能（步骤 2）后小字应消失、孪生导轨/臂与真机重合。Perception Arm 窗口里孪生的
      麦克风体遮住画面下方一大块而真机画面**没有**遮挡——这是要现场量出来的几何差异
      （麦克风体位置/尺寸，03-sim §4.3），先量再改场景，不要"修掉"叠加。
- [ ] 物理测量项：6 个示教位姿的卷尺实测 clearance（对 twin ≤4 mm）、
      各臂 `base_in_world` 与 rail 原点实测、相机外参标定（标定板）。
- [ ] **mavis_v2 场景校准**（`apollo-mavis-v2-sim/.../scenes/mavis_v2.yaml` 头部有全部
      假设）：① mavis 轨道网格长 1.0926 m、零位端到基座中心 0.2476 m——按"右端与台面
      齐平"反推 x0=0.3599，滑块右边距右沿 15.0 cm（口述 14）；实测轨长/零位端悬出后回调；
      ② 障碍物（左端、纵深 27.5 起）内角与 gripper 轨网格左端有 1.4×3.8 cm 静态重叠，
      说明网格轨比实物长/宽一点；③ 两轨 base 间距 39.5、相机轨外沿 2.6、轨宽 19.2 已确认，
      复核即可；④ 臂法兰安装面高出台面 0.107188 m 是否属实；⑤ 电机盒在哪一端。
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
- [ ] runtime：`HardwareWorkcell` 组装进 session manager（hardware kind 目前
      409；代码 + FakeSDK 测试先落地，真机验证留 A2）。
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
