# Phase-09 分工清单（你 vs Claude）

完整的执行手册与验收标准在 `phase-09-integration.md`（本文件只做分工拆分，
不重复细节）。执行记录最终落 `docs/acceptance/<cell_id>-<date>.md`。

## A. 需要你亲自做的（物理在场 / sudo / 决策）

**A0. 前置环境（去实验室前就可以做）**
- [ ] **升级 NVIDIA 驱动并重启**（当前 565.77，源里已有 580.159.03；解锁
      torch CUDA cu130 + NVENC）：
      `sudo apt update && sudo apt full-upgrade` → 重启 →
      `nvidia-smi` 确认 580.x。在 Claude Code 里可用 `! sudo apt ...` 交互执行。
- [ ] **处理 8000 端口占用**：查明占用进程（`ss -ltnp | grep :8000`），
      释放它或告知 Claude 把 runtime 默认端口改掉。
- [ ] （可选）确认三臂 IP 各在**不同子网**（UFACTORY Studio 里查/改）——
      同子网会破坏 NIC 探测（research/network-manager.md 风险 #1）；
      顺手记录每台臂固件版本（gripper 电流需 fw ≥ 2.7.100）。

**A1. 网络 reconcile（一次性，需 sudo）**
- [ ] `python -m apollo_xarm7_hardware.netsetup install`（写 polkit .pkla +
      加 netdev 组，需要 sudo）→ 重新登录使组生效。
- [ ] `... netsetup match` → 审阅 `... reconcile`（默认 plan-only 输出）→
      确认无误后 `reconcile --apply`。Claude 可以陪跑生成/解读，执行是你按回车。

**A2. 硬件逐级点亮（你握物理急停，Claude 操作软件）**
- [ ] 按 phase-09-integration.md「硬件逐级点亮」1→6 顺序陪跑：单臂低速 →
      rail → gripper → twin 对拍 → 双臂 gate 课目 → 完整 teleop/采集/DAgger。
- [ ] 物理测量项：6 个示教位姿的卷尺实测 clearance（对 twin ≤4 mm）、
      各臂 `base_in_world` 与 rail 原点实测、相机外参标定（标定板）。
- [ ] watchdog/急停课目（拔 WS、手拍碰撞、物理急停）需要你现场触发。
- [ ] 验收表逐项签核。

## B. Claude 的待办

**B1. 无需真机（随时可做，说一声即开工）**
- [ ] runtime：`HardwareWorkcell` 组装进 session manager（hardware kind 目前
      409；代码 + FakeSDK 测试先落地，真机验证留 A2）。
- [ ] 五仓转 **git submodule** + 各仓 tag + ws 仓 .gitignore/README/CLAUDE.md 更新。
- [ ] **CI 接线**：五仓 GitHub Actions（core schema --check、sim 膨胀语义哨兵、
      guardrail --all 双侧回归、ui lint/gen:check/test/build；GPU job 标注
      self-hosted）。
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
