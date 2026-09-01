# Phase 06 — apollo-xarm7-ui：SPA、Landing + teleop 座舱、WS 客户端、视频、键盘捕获

## 目标

实现 `apollo-xarm7-ui`（React 18 + Vite 5 + TypeScript strict SPA）：类型生成管线、
三类 WS 客户端（control/telemetry/video）、Landing 页与共享 Cockpit 布局、teleop 页
（含直接关节控制面板）、键盘捕获，以及全套 jsdom 测试。本 phase 交付 teleop 可用的
座舱；Collect/DAgger/Inference 页面只出骨架（面板在 07/08 激活）。

## 前置条件

- 依赖 phase：05（服务端协议已冻结、`GET /api/keymap` 等端点可用）。
- 必读设计文档：
  - `docs/design/05-ui.md`（本仓事实来源 — 全文，含目录结构、组件 props、测试清单）
  - `docs/design/00-overview.md` §5（keymap）、§8（协议/页面）
  - `docs/design/04-runtime.md`（REST/WS 端点契约核对）
- 参考：`docs/research/web-teleop-stack.md` §1–§4。

## 范围

严格按 `05-ui.md` 的目录树与 §9 组件清单实现（pnpm、Node ≥20、Vite 5、TS strict +
`noUncheckedIndexedAccess`、ESLint 9 flat + Prettier 3、Vitest + @testing-library/react +
mock-socket、zustand v5、react-router-dom v6 `createHashRouter`、CSS modules）：

- **类型生成管线**：`pnpm gen:sync`（从 `../apollo-xarm7-core/schemas` 拷贝到
  `./schemas/`，缺 sibling 即报错）→ `pnpm gen:types`（json-schema-to-typescript →
  `src/gen/`，全部入库）→ `pnpm gen:check`（重生成 + `git diff --no-index`，CI 防漂移）。
- **路由**：hash 路由 `#/`、`#/teleop`、`#/collect`、`#/dagger`、`#/inference`；
  `sessionLoader` guard（无会话或 mode 不符 ⇒ 重定向 `#/`）。
- **WS 客户端**（`src/api/ws/`，`WebSocket` 构造器注入 `wsFactory` 供测试）：
  - `ReconnectingWS`：250 ms 起步、full jitter、5 s 封顶、成功即重置；`onerror → close()`。
  - `ControlClient`：hybrid 协议 — 每次键变立即 `KeysMsg` + **25 Hz**（40 ms）armed 时
    心跳；`seq` 单调；disarm 时同步发一次 `{held: []}`；hello 的 `epoch` 与存储不符 ⇒
    toast "Runtime restarted" + 清 store + 回 `#/`；重连后第一条 keys 必是空集，
    永不重放断线前 held 集；`role:"observer"` ⇒ 只读横幅 + 禁捕获。
  - `TelemetryClient`：`seq` ≤ last 丢弃；`store.setState` 直写（React 之外）；
    1000 ms 无消息 ⇒ `telemetryStale`。
  - `VideoStream`：`/ws/video/{id}`，little-endian 12 字节头（`f64 ts` + `u32 len`），
    `createImageBitmap` → `drawImage`，decode 期间丢新帧（客户端也 latest-wins）；
    500 ms 无帧 ⇒ 灰罩 + "STALE" chip；latency badge 用 `src/lib/time.ts` 的
    skew 估计（5 s 窗口 min offset）。Worker + OffscreenCanvas 路径按 §5.5 实现，
    默认关（`?worker=1` / `VITE_VIDEO_WORKER=1`）。
- **键盘捕获**（`src/input/`）：bindings 从 `GET /api/keymap` 构建（**无硬编码副本**）；
  `useKeyCapture` — 点击 `TeleopSurface` armed、`KeyboardEvent.code`、bound 键一律
  `preventDefault`、`e.repeat` 忽略、discrete 每次物理按下恰好一次 `ActionMsg`、
  release-all（blur / visibilitychange / Escape / unmount / control WS ≠ open）。
- **页面**：Landing（workcell 切换、4 槽相机预览网格（`live` 相机 ~15 fps 会话前
  预览流）、ArmStatusCard×1–3 含 include 勾选 + FrameSelector（`arm_base:<id>`/
  `world`/`camera:<id>`，默认 arm_base）、ScenePicker（hardware 无 twin scene 拒绝
  提交、臂数不匹配的场景禁用）、`StartFromChoice` 双选 radio — **"Keep current
  state"（默认）** vs **"Load selected profile"**（选后 ProfilePicker 才可用，
  `is_initial_condition` 徽标 + 默认预选 designated initial）、task 文本框
  （Collect/DAgger 必填）、policy 选择器（DAgger/Inference，来自 `GET /api/policies`；
  DAgger 默认 latest、Inference 只列 `promoted`）、四个模式按钮 + 校验
  （`policies_available == false` 时 DAgger/Inference 禁用））；Cockpit 共享布局
  （StreamGrid、TeleopSurface（四模式都有）、KeymapOverlay（Slash 切换、rail 行按
  活动臂 has-rail 显隐、episode 行仅 collect/dagger、Space 行在 dagger/inference
  分别标注 "recorded as intervention" / "safety escape — never recorded"）、
  CollisionBanner + ClearanceReadout（k=5 最小间隙，mm 单位色阶）、ArmIndicator、
  ConnectionBanner）。
- **Teleop 页专属**：`JointPanel` **直接关节控制面板** — 全 7 关节滑条 + 数值输入，
  rail 行（0–0.65 m）仅活动臂有 rail 时渲染（无则整行隐藏）；滑条范围来自
  `ArmStatusInfo.joint_limits`；拖动 ~20 Hz 节流发 `joint_target mode:"jog"`
  （完整 positions 向量，rail 追加在末位）；数值 + "Go to" 按钮发一次 `mode:"goto"`，
  生命周期读 `ArmTelemetry.goto`（planning → executing → failed）；
  `episode.state === "recording"` 时整面板锁定；空闲时值随 telemetry 播种、拖动中的
  行归用户所有；接近限位 2% 内的行变琥珀色。`ProfileActions` — "Save profile…" 与
  **"Set current state as initial condition"**（破坏性 — 覆盖 designated initial，
  必须过确认对话框，发无参 `set_initial_condition`）。
- **状态**：单 zustand store（§7 的 AppState 形状）；像素与 held 集**不进 store**。
- **降级状态矩阵**：按 §10 表逐条实现（CONTROL LINK DOWN、epoch 变更、observer、
  telemetry stale、video stale、arm disconnected、collision blocked、无相机、
  keymap 失败、无 policy 时 DAgger/Inference 禁用）。

Out of scope：EpisodeControls 的真实接线与录制流（phase-07 激活）；DaggerPanel /
InferencePanel 真实接线（phase-08）；WebRTC、MuJoCo-WASM、SSR（明确排除）。

## 交付物

- `apollo-xarm7-ui/` 完整工程：`package.json`（scripts：dev/build/preview/lint/format/
  test/gen:sync/gen:types/gen:check）、`vite.config.ts`（dev 代理 `/api` `/ws` `/video`
  → `APOLLO_RUNTIME_URL ?? http://localhost:8000`）、`schemas/`（vendored）、`src/gen/`
  （生成并入库）。
- `tests/mocks/mockWs.ts`（讲 runtime 协议的 mock-socket 服务器：hello、记录
  KeysMsg/ActionMsg、推 telemetry fixture 与二进制视频帧）。
- 按 §11 清单的全部单测/组件测/集成 smoke。

## 验收标准

在 `apollo-xarm7-ui/` 内执行：

- [ ] `pnpm install && pnpm lint && pnpm gen:check && pnpm test && pnpm build` 全过
      （即 CI 全链）。
- [ ] `useKeyCapture` 测试：`repeat: true` 忽略；bound 键 preventDefault、非 bound 不；
      Tab ⇒ `switch_arm` 恰一次且**从不**进 held 集；Space ⇒ `takeover_toggle` 每次
      按下一次；blur/hidden/Escape 均清空 held + 触发空集发送；unmount 摘除监听。
- [ ] `ControlClient` 测试（fake timers）：键变 ⇒ 立即 KeysMsg；心跳 40 ms ± 节拍；
      `seq` 跨转换/心跳严格递增；disarm 发最终空集；重连后等 hello、首条 keys 为空集；
      epoch 不符触发 reset。
- [ ] `ReconnectingWS` 测试：退避序列 250→500→…→5000（含 jitter 上下界）；成功后
      重置 250；`close()` 取消重连。
- [ ] `binary.parseFrameHeader`：little-endian 往返、截断 buffer 抛错。
- [ ] `StreamView`：两帧二进制 ⇒ 两次 `drawImage`；decode 挂起时丢帧；fake-timer
      推 500 ms 出 STALE chip。
- [ ] Landing 测试：无臂/无 scene 时模式按钮禁用；hardware kind 缺 twin scene 阻止
      提交；"Load selected profile" 未选 profile 阻止提交；task 为空阻止 Collect/
      DAgger；`FrameSelector` 序列化 `arm_base:<id>`/`world`/`camera:<id>`；
      `POST /api/session` payload 快照（含 `kind`、`start_from`、`task`、`policy`）；
      initial-condition 徽标渲染在 flagged profile 上。
- [ ] `JointPanel` 测试：连续拖动在 fake timers 下发送 ≤ ~20 Hz 的 `mode:"jog"`；
      "Go to" 恰发一次 `mode:"goto"`；`rail_pos_m === null` 时无 rail 行；
      `episode.state === "recording"` 时全部输入禁用；限位处行变琥珀；
      `goto:"failed"` fixture 出错误 UI；空闲值跟随 telemetry、拖动中的行不跟随。
- [ ] `ProfileActions` 测试："set initial condition" 必须先确认才发 `ActionMsg`。
- [ ] `KeymapOverlay` 测试：rail 行随活动臂 has-rail 显隐；episode 行 teleop 不渲染；
      Space 行在 dagger 与 inference 页均渲染且语义标签各自正确。
- [ ] 集成 smoke：挂 Cockpit + mock control/telemetry/2×video ⇒ arm 捕获、按住 KeyW、
      服务端收到转换 + 心跳；推 `blocked` collision fixture ⇒ 红横幅 + tile 边框闪；
      杀 control server ⇒ CONTROL LINK DOWN + 自动 disarm。
- [ ] 对着真 runtime（phase-05 sim 后端）手动验证一次：`pnpm dev` + 代理，Landing →
      teleop → 按 W 臂动、Esc 释放、断 runtime 出横幅。

## 注意事项

- 生成类型是唯一事实来源（core pydantic → JSON Schema → TS）：**禁止手改 `src/gen/`**，
  banner 注明 AUTO-GENERATED；`gen:check` 挂 CI 后 core 协议漂移 = 构建失败。
- hash 路由不是偏好而是必须：runtime 用 `StaticFiles(html=True)` 托管，深路径 404。
- `event.code` 而非 `event.key`（AZERTY 上 WASD 语义不变）；浏览器专属组合键
  （Ctrl+W/Ctrl+T）不可拦截 — keymap 里没有也不要加。
- Active arm 是**服务端权威**：Tab 只发 `switch_arm` 不带索引，UI 不本地预测 —
  否则和 telemetry 打架。
- 后台 tab 定时器节流会饿死心跳，但 `visibilitychange` 先 disarm — 被节流的心跳
  只可能发空集；这个不变量写进测试。
- 像素路径绝不过 React/zustand：WS → createImageBitmap → canvas；`onStats` ≤4 Hz
  只写小数字。
- jsdom 没有 `createImageBitmap`/`OffscreenCanvas`/canvas 2D — 在 `tests/setup.ts`
  统一 stub，别在各测试里散落。
- rail 键始终在 `bound`（防箭头滚屏）也始终随 held 发送 — 服务端对无 rail 臂忽略；
  UI 只负责 overlay 显隐。
- Episode 操作与 profile-save 走 control WS 的 `ActionMsg`（非 REST）；按钮与快捷键
  同一路径；不做乐观 UI — 状态以 telemetry 确认为准。
- 深浅色不做主题切换：固定暗色高对比座舱（绿 `#2ecc71`、琥珀 `#f5a623`、红 `#e74c3c`）。
