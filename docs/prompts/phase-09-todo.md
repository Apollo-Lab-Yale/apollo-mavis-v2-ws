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
- [ ] （可选）确认三臂 IP 各在**不同子网**（UFACTORY Studio 里查/改）——
      同子网会破坏 NIC 探测（research/network-manager.md 风险 #1）；
      顺手记录每台臂固件版本（gripper 电流需 fw ≥ 2.7.100）。

**A1. 网络 reconcile（一次性，需 sudo）**
- [ ] `python -m apollo_mavis_v2_hardware.netsetup install`（写 polkit .pkla +
      加 netdev 组，需要 sudo）→ 重新登录使组生效。
- [ ] `... netsetup match` → 审阅 `... reconcile`（默认 plan-only 输出）→
      确认无误后 `reconcile --apply`。Claude 可以陪跑生成/解读，执行是你按回车。

**A2. 硬件逐级点亮（你握物理急停，Claude 操作软件）**
- [ ] 按 phase-09-integration.md「硬件逐级点亮」1→6 顺序陪跑：单臂低速 →
      rail → gripper → twin 对拍 → 双臂 gate 课目 → 完整 teleop/采集/DAgger。
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
- [ ] runtime：`HardwareWorkcell` 组装进 session manager（hardware kind 目前
      409；代码 + FakeSDK 测试先落地，真机验证留 A2）。
- [ ] 五仓转 **git submodule** + 各仓 tag + ws 仓 .gitignore/README/CLAUDE.md 更新。
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
