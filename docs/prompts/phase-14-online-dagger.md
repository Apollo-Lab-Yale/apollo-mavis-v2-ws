# Phase-14 — Online DAgger 外壳（算法无关的在线交互学习；PRO-DAgger 作为 policy 仓的参考实现）

状态：**v2.0 契约 = `docs/design/15-online-dagger.md`（2026-09-08 晚定稿，binding）**；实现与本文件冲突时以 15-online-dagger 为准并在报告中注明。
`docs/design/15-pro-dagger.md` v1.0 是**上午**的契约，已于同日晚被取代，只作历史保留（其 §15 记录的是 v2.0 **替换掉**的那份代码）。
本文件原名 `phase-14-pro-dagger.md`（2026-09-08 晚改名；两份文件都未曾提交）。
本 phase 建立在 phase-12（dora 外部接口，已于 2026-09-08 05:52 合并进主工作树）与 phase-13（键盘遥操回归、按 episode 组织的数据集、回初始位）之上。
同日附带的两项非 DAgger 需求——**phase-12 合并进主树**与**键盘平移坐标系默认改为世界系**——不受本次改名影响，仍然有效（见"事实"与"已被取代的上午决定"第 8 条）。

## 用户决定（2026-09-08 晚，binding）

1. landing 第三张卡片（数据收集与推理之间）叫 **Online DAgger**，不叫 PRO-DAgger；wire 上 `mode` 仍是 `dagger`。
2. **训练与一切算法相关的产物**（投影梯度、reference pool、EMA 状态、超参数）**都在 policy 仓**。runtime 不存、UI 不配——特别是
   **没有 offline-dataset 选择器**（trainer 自己配它的锚点）。
3. runtime 只保留 **rollout 级别的外壳**：执行 rollout、提供 **take-over / hand-back API**、保存 rollout、给每一步打 **novice / expert**
   标签。**不数 iteration**。
4. **训练期间暂停新 rollout**（`pause_while_training`）与操作员的 **Train now** 请求保留（两者都是通用语义，trainer 可忽略 Train now）。
5. **被丢弃的 rollout 永不落盘**：discard 删掉该 episode 的临时目录（视频 / 帧 / 音频），只发一条通知事件，让在线看过这条 rollout 的
   trainer 把已接收的部分丢掉。
6. session 目录 `$HOME/data/online_dagger/<session_name>/`，内含 `rollouts/`（标准的 episode 目录数据集）与 `session.json`；trainer 的
   产物放哪里由它自己定（skill 建议 `<session>/trainer/`，runtime 永不读）。
7. PRO-DAgger 参考实现（policy-node 仓）的默认值：**offline pool 只提供 reference gradient**（`freeze_offline_gref: true`），**online
   buffer 累积每一次 expert 干预并在每个 iteration 都拿来训练**（`replay_buffer: true`，无上限）。上午"只训练本 iteration、之后丢弃"的默认
   作废。

## 主代理代用户定的决策（实现按此执行；用户可推翻）——摘自 15-online-dagger §1

- **D1** wire：`mode: "dagger"` + `policy_source: "external"` + 非空 `SessionSpec.online_dagger`；人读到的名字全是 "Online DAgger"
  （卡片、Sheet、Cockpit 标题、键位覆盖层）。
- **D2** **一条**通用入站流 `trainer_status`（状态机 `idle | preparing | training | ready | error`，自由格式 `metrics`）；**一个**通用门禁：
  trainer 报 `training` 时拒绝 `episode_new`（`pause_while_training`），`wait_for_trainer_ready` 打开时在 trainer 对本 session 报过一次
  `ready` 之前也拒绝。
- **D3** runtime 在总线上发布 **gate 事件**（take-over / hand-back 的瞬间），并在操作员的 `Space` 之外接受显式的 **`takeover` /
  `handback`** 动作（幂等）。Vive / 键盘映射不动。
- **D4** rollout 记账留在 runtime 的 recorder：`actor` 列、`episode.json` 与 `events.episode_saved` 里的 actor 计数；何时训练由 trainer 决定。
- **D5** 数据集 namespace `online_dagger` → `~/data/online_dagger/<s>/rollouts`（`RuntimeConfig.datasets.namespaces`）；`pro_dagger`
  namespace、配置块、REST 前缀、skill 与 coordinator **删除、不做别名**（从未发布）。
- **D6** 回初始位对 rollout 同样生效（默认开、按 session 可关）——不变。
- **D7** 真机仍然 409 `dagger`（`hardware sessions support teleop and data collection only`），直到用户放开。
- **D8** skill 叫 `mavis-online-dagger-trainer`：通用契约 + 一份放在 policy-node 仓里的 PRO-DAgger 实例（`mavis_policy_node.pro_dagger`
  作为参考实现，架在通用的 `mavis_policy_node.online_dagger` loop 之上）。

## 已被取代的上午决定（2026-09-08 上午；保留作历史，标注取代关系）

**上午用户决定（1–8）**——Superseded (2026-09-08 晚) — see 15-online-dagger §0，除注明者外：

1. ~~中间模式叫 **PRO-DAgger**，功能与算法结构按 `M4D-SC1ENTIST/pro-dagger`（分支 `prodg-lbm-anzu`）的 PGrad 实现~~ → 卡片叫 Online DAgger；
   PGrad 只存在于 policy 仓的参考实现（晚间决定 1、2、7）。
2. policy 推理与 policy 本身在另一个 repo 的另一个 dora 节点；runtime 暴露接口 —— **仍然有效**（v2.0 §2）。
3. 前端点按钮先出现使用说明并给出 agentic skill —— **仍然有效**，skill 改名 `mavis-online-dagger-trainer`（D8）。
4. ~~面板配置 offline dataset 位置、每个 iteration 的 epoch / rollout 数 / lr、是否启用 replay buffer~~ → runtime / UI 不配任何算法参数、
   没有 offline-dataset 选择器（晚间决定 2）。
5. 在线交互学习时数据同样被保存、同样的质量后处理、每步多一个 novice / expert 标签 —— **仍然有效**（`actor` 列，v2.0 §4 / D4）。
6. 数据收集要指定数据集名字并保存到 `$HOME/data/bc_demo/<name>` —— **仍然有效**；~~PRO-DAgger session 目录
   `$HOME/data/pro_dagger/<session>`，内含 `ref_grad/` 与 `rollouts/`~~ → `$HOME/data/online_dagger/<session>/{rollouts/, session.json}`，
   没有 `ref_grad/`（晚间决定 6）。
7. UI 不照搬参考 repo，符合 mavis 风格 —— **仍然有效**。
8. **键盘遥操平移坐标系默认改为世界系**（`control.translate_frame: world`；`camera` / `base` 仍可选）—— **仍然有效**，与 DAgger 无关。

**上午主代理决策 D1–D10（摘自 15-pro-dagger §1）**——Superseded (2026-09-08 晚) — see 15-online-dagger §1 D1–D8：

- D1 `mode: dagger` + `policy_source: external` + `SessionSpec.pro_dagger` → v2.0 D1（`SessionSpec.online_dagger`）。
- D2 迭代状态机 `ProDaggerCoordinator` 在 runtime、新输入 `trainer_status` → v2.0 D2：runtime 不数 iteration，`trainer_status` 保留但改为
  10 字段通用形状（`state / progress / metrics / detail …`，`RefGradStatus` 删除）。
- D3 session 目录含 `ref_grad/` → v2.0 §0 item 6（无 `ref_grad/`）。
- D4 数据集根按 namespace 映射、`GET /api/datasets/layout` → **保留**（v2.0 D5，namespace 改名 `online_dagger`）。
- D5 逐步 `actor` 列 → **保留**（v2.0 D4 / §4）。
- D6 回初始位对 rollout 生效 → **保留**（v2.0 D6）。
- D7 真机仍 409 → **保留**（v2.0 D7）。
- D8 23 个超参默认 = 参考 `SessionConfig`（replay buffer 关） → 超参不再在 runtime / wire 上；policy 仓 `ProDaggerConfig` 默认改为
  `replay_buffer: true` + `freeze_offline_gref: true`（晚间决定 7）。
- D9 skill `mavis-pro-dagger-trainer` 经 `GET /api/pro_dagger/skill(.tgz)` 发布 → v2.0 D8（`mavis-online-dagger-trainer`，
  `GET /api/online_dagger/skill(.tgz)`）。
- D10 `ref_grad.state == ready` 之前拒绝 `episode_new`（`require_ref_grad`） → v2.0 D2 的通用门禁 `wait_for_trainer_ready`
  （只看 trainer 的 `ready`，不知道什么是 reference gradient）。

## 事实（现状，2026-09-08 晚）

- phase-12 曾在隔离工作树 `~/projects/apollo-mavis-v2-ws-p12/`（分支 `phase-12`）实现，2026-09-08 05:52 三方合并到主工作树的 phase-13
  未提交改动之上（core / runtime / ui / sim / hardware 五仓；生成物一律重生成；备份在 `~/projects/.merge-backup-20260908/`）。
  `~/projects/apollo-mavis-v2-ws-merge/`（分支 `merge-13-12`）是上一会话遗留的**过期半成品**，未使用，删除与否由用户决定。
- `apollo-mavis-v2-policy-node`（参考 policy 节点仓库，独立 git 仓，尚无 remote，HEAD `c1a5843`）位于
  `~/projects/apollo-mavis-v2-ws-p12/apollo-mavis-v2-policy-node/`。
- UI 以 **npm** 管理（`package-lock.json` 唯一 lockfile）；本机 pnpm 11 的 pre-run 依赖检查因未批准的 esbuild 构建脚本失败，要用就
  `pnpm --config.verify-deps-before-run=false <script>`。
- runtime 的 `pro_dagger` 一族（`dagger/pro_dagger.py`、`/api/pro_dagger/*`、`pro_dagger:` 配置块、`ProDagger*` 模型、
  `iteration_complete` / `pro_dagger_phase` 事件、skill `mavis-pro-dagger-trainer`）**从未提交、从未发布**，v2.0 直接删除、不留别名；
  代码里不再有任何把 PRO-DAgger 说成 runtime 行为的文字；剩下的提法（2026-09-08 深夜 grep 四棵代码树核实，全部允许）：两条历史注释
  （core `protocol/external.py`、runtime `dagger/online_dagger.py`）、几条"确已删除"的负断言（`/api/pro_dagger/*` 404、golden 里没有
  `RefGradStatus` / `ProDaggerAnnounce`）、core `protocol/telemetry.py` 的 `translate_frame` 注释把 `world` 默认的决策出处写成
  "15-pro-dagger §0 item 8"（指向已被取代的文档；决定本身仍有效，见 04-runtime §6 与本文件"已被取代的上午决定"第 8 条）、policy-node
  `mavis_policy_node/online_dagger/{__init__,config,datasets}.py` 对 PRO-DAgger **参考实现**的指称，以及 ui `lib/launch.ts`、core
  `protocol/session.py`、runtime `recorder/action_filter.py`（连带生成物 ui `src/gen/protocol.ts`）对 pro-dagger 静止过滤启发式
  **来源**的引用。此前"只剩两条历史注释"的说法少算了后三类。

## 范围（v2.0）

### 1. core（`apollo-mavis-v2-core`，15-online-dagger §5–§6）
`OnlineDaggerConfig`（`extra="forbid"`：`session_name` SLUG ≤ 64、`resume`、`pause_while_training`、`wait_for_trainer_ready`）、
`SessionSpec.online_dagger` 三条交叉校验（需 `mode dagger`、需 `policy_source external`、不得同时给 `dataset`）、`SessionInfo.online_dagger`
回显、`OnlineDaggerSessionInfo`、`OnlineDaggerStatus`（`DaggerStatus.online_dagger`：`phase waiting_trainer | rollout | training | error`、
`rollouts_saved`、`trainer`、`policy_version_acting`、两个 actor 计数）、`protocol/external.py`：`OnlineDaggerAnnounce {session_name,
session_dir, rollouts_dir}`、`SessionAnnounce.online_dagger`、10 字段 `TrainerStatusAnnounce`、`EVENT_KINDS` = phase-12 九种 + `train_now`、
`PolicySpecAnnounce.capabilities`（`"online_dagger"`）、`ExternalStatus.capabilities / trainer_status`；`ActionName += takeover, handback,
train_now`（无参、无键位）；`ProDagger*` / `RefGradStatus` 模型与 `pro_dagger_train_now` 删除；schemas 重生成。保留 phase-14 上午已落地
且与算法无关的部分：`DatasetLayoutInfo` / `DatasetNamespaceInfo`、`DatasetInfo.namespace / path`、`SLUG_RE`、`EpisodeSummary.n_expert_frames /
n_novice_frames`、`return_to_start` 放开到 dagger。

### 2. runtime（`apollo-mavis-v2-runtime`，§3、§4、§6、§7）
`dagger/online_dagger.py::OnlineDaggerCoordinator`（四个 phase、四条 `episode_new` 拒绝文案、只认回显本 `session_id` 的 trainer 状态、
`events.episode_saved` 的 `online_dagger` 块、discard 只发 `events.episode_discarded`、`train_now` → `events.train_now`、
`policy_version_acting` 跟随公告版本并记 "swapped"、`session.json` §3 形状、resume、`scan_sessions`）；`TakeoverGate` 的 `takeover` /
`handback` 幂等 op 与 gate 事件（`events.gate {arm_id, mode, seq, source, episode_id}`，永不在 tick 线程上调总线）；
`_check_online_dagger` 409 矩阵（session 目录三条 → 导出中 / legacy 树 → 无外部 policy → 无 `online_dagger` capability）；
`datasets.namespaces.online_dagger`（`~/data/online_dagger`，`subdir: rollouts`）与 `online_dagger:` 配置块；
`GET /api/online_dagger/{skill,skill.tgz,sessions}`；skill 作为包数据 `online_dagger/skill/`（与 policy-node 镜像逐字节一致）；
fake 节点的**通用** trainer 角色；`tests/dora_bridge/test_e2e_online_dagger.py`。`actor` 列、`DatasetStore` 根映射、
`GET /api/datasets/layout`、D6 回位保留自上午。

### 3. ui（`apollo-mavis-v2-ui`，§8）
卡片 **Online DAgger**（icon `project`）；两视图 `OnlineDaggerSheet`（① Connect a trainer：external chip、trainer pill、连接事实、
skill 一行安装命令、SKILL.md 预览；② Configure：Session name + 目录预览 + resume、Task、Recording、Advanced）——**无数据集选择器、
无超参**；`OnlineDaggerPanel`（phase pill、rollouts saved、actor 拆分、trainer 状态 + `metrics` 键值表 + `loss` sparkline、acting
version + "swapped"、**Take over / Hand back / Train now**、红色 trainer 横幅）；`DatasetsPanel` 分组 Demonstrations · Online DAgger
rollouts · Other；`launch.ts` / `rest.ts` / fixtures / 测试。

### 4. policy-node（`apollo-mavis-v2-policy-node`，§9、§10）
通用层 `mavis_policy_node/online_dagger/`（`protocol.py` 的 `OnlineDaggerTrainer` 八个 hook、`loop.py`、`fake.py`、`config.py`、
`datasets.py`、`synthetic.py`、`selftest.py`）；参考实现 `mavis_policy_node/pro_dagger/`（`config.py` 的 `ProDaggerConfig`、`trainer.py`、
`pgrad.py`；`offline_dataset` 必填，`freeze_offline_gref: true` + `replay_buffer: true`）；CLI `--online-dagger <fake|pkg.mod:make_trainer>`、
`--trainer-config <yaml|json>`、`--selftest online-dagger`；契约常量 + golden；`skills/mavis-online-dagger-trainer/`（runtime 副本的镜像）。

### 5. docs
15-online-dagger（契约）、15-pro-dagger 头注标 Superseded；12-dagger、14-dora、04-runtime、05-ui、10-frames、01-core、00-overview 上午写的
PRO-DAgger 增补改写为 Online DAgger（保留一行带日期的历史注）；CLAUDE.md；README 状态表；DEPLOYMENT.md；本文件。

### Out of scope
真机上的 Online DAgger（D7）；任何具体 DAgger 算法在 runtime 侧的实现；`weights_reload / weights_ack`；per-rollout 成功标记；进程外
dora bridge；编码器子进程。

## 交付物

五仓工作树中的未提交改动（用户说 commit 才 commit）、policy-node 仓改动、`docs/design/15-online-dagger.md`、本文件、README 状态表一行、
CLAUDE.md 指针、DEPLOYMENT.md 的数据根与 trainer 启动段。

## 验收标准（命令必须真实跑通；只勾本记录亲自复核过的项）

- [x] core：`uv run python -m apollo_mavis_v2_core.protocol.export_schemas --out schemas/ --check && uv run ruff check . && uv run pytest`
      全绿；`OnlineDaggerConfig()` 默认 `resume False / pause_while_training True / wait_for_trainer_ready True`；`SessionSpec(mode="teleop",
      online_dagger=...)`、`policy_source="checkpoint"` + `online_dagger`、`online_dagger` + `dataset` 均 422；`ActionName` 尾部
      `takeover, handback, train_now, goto_profile`。
      **✓ 2026-09-08 晚复核**：`--out schemas/ --check` rc 0（裸 `--check` 报 argparse 用法错误，必须带 `--out`）、ruff 全过、
      **464 passed in 3.54 s**；`schemas/` 43 个文件（`OnlineDaggerConfig` / `OnlineDaggerSessionInfo` / `OnlineDaggerAnnounce` /
      `TrainerStatusAnnounce` + 追加需求的 `GotoProfileArgs`；`ProDagger*` / `RefGradStatus` 四个已删）。三条交叉规则由
      `tests/test_protocol.py` 钉住（据 core 重构报告）。
- [ ] runtime：`uv run ruff check . && uv run pytest`（默认 addopts，含 `dora` 标记）全绿；`tests/dagger/test_online_dagger_coordinator.py`
      覆盖 §3 每条转移与拒绝文案；`tests/dora_bridge/test_e2e_online_dagger.py`（仿真 + fake trainer）：`waiting_trainer → rollout`，
      两次 kept rollout（一次经 `takeover` / `handback` 动作、一次经 `Space`）→ fake 训练 → `training` 期间 `episode_new` 按文案被拒 →
      `ready` 且 `policy_version_acting` 2，一次 discard **不留目录、不留 spool、只发事件**，Train now → 第二次训练 → v3，`session.json`
      两行 rollouts + trainer_log，`rollouts/episodes/*/frames.parquet` 有 `actor` 且两个取值都出现，`GET /api/online_dagger/sessions`
      列出 s1，`GET /api/online_dagger/skill` 以 `---\nname: mavis-online-dagger-trainer` 开头，`skill.tgz` 含 `SKILL.md`，
      `/api/pro_dagger/*` 404。
      **据报告（本记录未复跑 runtime 套件，另一任务占用 dora 控制面；只做了 `--co`：737 条）**：v2.0 stage 2 全量
      `708 passed / 1 failed / 3 skipped，683 s`（失败 = 已知 perf flake；skip = 两个真设备探针 + 当时尚不存在的 policy-node 镜像）；
      runtime 审查修复后全量 `713 passed / 1 failed / 2 skipped，689 s`（失败 = `test_return_to_start.py::test_initial_condition_profile_is_the_
      fallback_return_target` 的 WS deadman 计时 flake，单跑 4/4 通过）；`test_e2e_online_dagger.py` 3 passed，单独 30.9–32.3 s，三次复跑
      无 flake；追加需求后非 dora 子集 `715 passed / 2 skipped / 20 deselected`（715 + 2 + 20 = 737 与本次 `--co` 一致）。
- [x] runtime golden `tests/dora_bridge/golden/contract_golden.json` 与 policy-node `tests/golden/contract_golden.json` **逐字节一致**；
      skill 三个文件与 policy-node `skills/mavis-online-dagger-trainer/` 逐字节一致。
      **✓ 2026-09-08 晚复核**：`cmp` 一致，sha256 `4dc67e123bdfcd31…`（3698 字节）；`event_kinds` 十种、以 `train_now` 收尾；
      `TrainerStatusAnnounce` 10 字段、`OnlineDaggerAnnounce` 3 字段紧跟 `event_envelope_fields`；`diff -r` skill 目录无差异。
- [x] runtime 默认配置：`ControlConfig().translate_frame == "world"`；两份 YAML `datasets.default_namespace == "bc_demo"`，
      `bc_demo → ~/data/bc_demo`、`online_dagger → ~/data/online_dagger` + `subdir rollouts`；`online_dagger.skill_dir null`、
      `session_file_hz 1.0`；`dora.enabled False`、`hardware_session.armed False`。
      **✓ 2026-09-08 晚复核**：`load_runtime_config` 两份配置逐项如上（展开为 `/home/xiatao/data/...`）；
      `HardwareSessionConfig().start_from_fault_grace_s == 3.0`（追加需求）。
- [x] ui：`npm run gen:check && npm run lint && npx vitest run && npm run build` + `npx prettier --check src tests` 全绿；第三张卡片文字
      "Online DAgger"；`buildSpec("dagger", …)` 产出 `policy_source: "external"` + `online_dagger` 块、无 `dataset` / `policy` / 超参；
      Sheet 两视图、无数据集选择器；Panel 的 Take over / Hand back / Train now 发 `takeover` / `handback` / `train_now`。
      **✓ 2026-09-08 晚复核**：gen:check OK（schemas 与 core 逐字节一致）、eslint 0、**vitest 44 files / 436 tests passed**、
      build = tsc + vite + `check-dist OK — 2 JS asset(s), no dev-proxy leak`、prettier 全过；`MODE_LABELS.dagger = "Online DAgger"`
      （`src/lib/streams.ts`）；POST body 由 `lib/launch.test.ts` 对照 `schemas/OnlineDaggerConfig.json` 钉住（据 ui 重构报告）。
- [x] policy-node：`ruff check . && ruff format --check . && pytest -q -m "not dora"` 全绿；`python -m mavis_policy_node --online-dagger fake
      --selftest online-dagger` exit 0 并打出 `idle → preparing → ready → training → ready` 子序列 + 版本 bump。
      **✓ 2026-09-08 晚复核**：ruff / format 全过；**141 passed, 2 deselected in 9.55 s**；selftest exit 0，
      `states ['idle','preparing','ready','training','ready','training','ready','idle']; 12 statuses; policy version 1 -> 3`。
      dora e2e `tests/test_node_e2e.py`（2 条，含 `test_online_dagger_trainer_end_to_end` 与 spec-先于-status 的 seq 断言）据 policy-node
      修复报告在私有控制面上 2 passed / 9.9 s——本记录未复跑。
- [x] 文档：15-online-dagger 为契约；15-pro-dagger 标 Superseded；12-dagger / 14-dora / 04-runtime / 05-ui / 10-frames / 01-core /
      00-overview 上午的 PRO-DAgger 增补改写；README 状态表、CLAUDE.md、DEPLOYMENT.md、ws README 改写。
      **部分完成（2026-09-08 晚）**：15-online-dagger v2.0 已定稿、15-pro-dagger 头注已标 Superseded；本文件、`docs/prompts/README.md`、
      CLAUDE.md、DEPLOYMENT.md、ws README 由本任务改写；设计文档（12-dagger v1.2 / 14-dora v1.1 / 04-runtime §10.7 / 05-ui §8 / 10-frames
      §11.10 / 01-core / 00-overview §4）截至本记录收笔仍是 PRO-DAgger 措辞，由并行的文档任务改写——全部到位后勾选此项。
      **✓ 2026-09-08 深夜复核**：并行文档任务已到位——12-dagger v1.3、14-dora v1.2、04-runtime §10.6 / §10.7 / §13.1 / §14 / §15 / §16、
      05-ui §8 / §9 / §12 第 28 点、10-frames §7.4 / §9 / §11.10、01-core §9–§12 / §14 / §19 / §20、00-overview v0.4 均为 Online DAgger
      措辞（grep 只剩带日期的历史注、policy 仓参考实现与 skill 示例）；CLAUDE.md 已写 `translate_frame` 默认 `world`。

## 注意事项

- 不新增任何运动路径：rollout 之间的回位复用 phase-13 的孪生规划 + 门禁 + 可取消路径；`teardown()` 依旧不产生运动。
- dora 一律不在 tick 线程上；gate 事件、`episode_saved` / `episode_discarded` / `train_now` 与 `session.json` 写入走 coordinator 的
  `SerialWorker`（Online DAgger session）或 `SnapshotPublisher.enqueue_event()`（普通 external / checkpoint 的 policy session）。
- `hardware_session.armed` 规则、操作员自有设置（控制器映射、键位表、滤波参数、速度默认、臂名、唯一场景）不动。
- runtime 不知道任何算法：不要在 runtime / core / ui 里再出现 iteration、reference gradient、EMA、超参。命名参考实现时写 "PGrad" /
  "projected gradient" / "reference gradient"，不写 "A-GEM"。
- 与用户用中文交流；代码、注释、仓库文档英文。

## 实施记录（2026-09-08）

全部改动**未提交**，位于五个子仓的主工作树与 policy-node 仓（无 remote）。当日顺序：05:52 phase-12 三方合并到 phase-13 树 →
上午 PRO-DAgger v1.0 三阶段实现 + 五仓验证 + 四份审查 + 修复 + 文档（见末尾"历史"）→ **18:38 用户改口、15-online-dagger v2.0
定稿** → v2.0 重构：core → runtime stage 1（coordinator / gate API / 接线 / REST / skill）→ ui → policy-node → runtime stage 2（fake trainer
角色 + dora e2e）→ 跨仓验证（core / ui 各一份）→ ui / policy-node / runtime 三份审查 → 三份修复 → **同晚追加**操作员的两个问题
（Welcome profile 列表按页签 kind 过滤；`start_from` 遇瞬时 RECOVERING 被拒 + "Go to profile"）→ 一份审查 + 修复 → 本文档轮。
**代码为准**：下文"偏差"记录实现与 15-online-dagger v2.0 原文不一致之处（15-online-dagger §12 是同一份清单的英文版实现记录，
含逐字的拒绝 / 409 / nack 文案、事件载荷键与 `session.json` 的实际写法）。

### 各仓落地内容（`git diff HEAD --stat`，含同树上的 phase-12 / phase-13 改动；untracked 另计）

> 计数口径（2026-09-08 深夜补注）："N 个 untracked" 是 `git status --short` 的 `??` **行数**——未跟踪的**目录**折叠成一行
> （如 runtime 的 `tests/dora_bridge/`、`src/apollo_mavis_v2_runtime/dora_bridge/`、policy-node 的 `mavis_policy_node/online_dagger/`）；
> 括号里另给 `git ls-files --others --exclude-standard | wc -l` 的**文件数**。HEAD 与 `files changed / +/−` 数字均与工作树逐项核对一致。

- **core**（`6c7dafc` 上，28 files, +2646/−56，17 个 untracked 行 = 17 个文件）：`protocol/external.py`（`EVENT_KINDS` = phase-12 九种 + `train_now`，
  `OnlineDaggerAnnounce`、`SessionAnnounce.online_dagger`（末位）、10 字段 `TrainerStatusAnnounce`（`progress` ∈ [0,1]、`metrics`
  有限浮点、`uptime_s ≥ 0`，均 `allow_inf_nan=False`）、`PolicySpecAnnounce.capabilities`、`ExternalStatus.capabilities / trainer_status`
  末两位；一条历史注 "v1.0 PRO-DAgger shell superseded 2026-09-08"）、`protocol/session.py`（`OnlineDaggerConfig`、`OnlineDaggerSessionInfo`、
  `SessionSpec.online_dagger` / `SessionInfo.online_dagger` 三条规则先于 dataset 规则；`SessionInfo.fault_detail`——追加需求，additive）、
  `protocol/telemetry.py`（`OnlineDaggerStatus`、`DaggerStatus.online_dagger`；`SessionTelemetry.fault_detail`——追加需求）、
  `protocol/control.py`（`ActionName` 去 `pro_dagger_train_now`、加 `takeover / handback / train_now / goto_profile`；`GotoProfileArgs`
  `{profile_id}` extra=forbid、id 字符集 `^[A-Za-z0-9_\-]+$`；`KEYMAP` 仍 24 行不动）、`dagger/types.py`、`protocol/__init__.py` /
  `export_schemas.py`；`schemas/` 43 个文件。测试：删 26 条 PRO-DAgger 专用（含 14 条参数化范围用例）、加 12 条 Online DAgger + 3 条
  wire 往返；追加需求 +5（459 → 464）。
- **runtime**（`a11cdd2` 上，63 files, +6864/−1132，32 个 untracked 行 = 74 个文件）：新 `dagger/online_dagger.py`（`OnlineDaggerCoordinator`、
  `OnlineDaggerPaths = session_dir + rollouts_dir`、`SerialWorker`、原子写 `session.json`、`scan_sessions`；`dagger/pro_dagger.py` 删除）；
  `dagger/gate.py`（`on_toggle(arm, t, source)`、`reset()` 返回 `episode_reset` 事件）；`dagger/loop.py`（`_op_takeover` / `_op_handback`
  幂等、`_op_train_now`、每个 gate 事件 → `on_gate_events` hook；`_settle_boundary` 统一保存 / 丢弃边界并缓存打开中的 `episode_id`；
  `POLICY_DRIVING` 拒绝 R / goto——追加需求）；`control/loop.py`（基类对 `takeover / handback` 沿用 `takeover not available in teleop`、
  `train_now` → `not an Online DAgger session`；`_op_goto_profile`；`_op_execute_plan` 在已有 plan 时 nack `plan executing`）；
  `dagger/recorder.py` / `recorder/thread.py`（spool 写失败仍触发 `on_episode_saved(..., "")`；第二次保存失败发 `episode_discarded` 但按
  04-runtime §15 保留缓冲）；`recorder/datasets.py`（`episode_delete_refusal` hook：运行中 Online DAgger session 的已保存 rollout 409）；
  `dora_bridge/{policy_source,publishers,wiring,dataflow}.py`（capability `online_dagger`、`SnapshotPublisher.enqueue_event()` 有界队列 256、
  `DoraWiring.publish_gate_events`）；`dora_bridge/nodes/fake_policy.py`（通用 trainer 角色：`TRAINER_ID "runtime-fake/online_dagger"`，
  旋钮 `FAKE_TRAINER_PREPARE_S` 0.5 / `FAKE_TRAINER_TRAIN_S` 1.0 / `FAKE_TRAINER_EVERY` 2 / `FAKE_TRAINER_FAIL_AT`，不落盘）；
  `session/manager.py`（`_OnlineDagger` holder、`_check_online_dagger`、`_build_online_dagger` 只建 `<root>/<s>/rollouts` + `session.json`、
  resume 不再同步重写 `session.json`、publish 闭包钉住 `session_id`、`_online_dagger_saved_hook` 先 coordinator 后 executor；追加需求：
  `_start_from_worker` 的 `_await_arms_clear` + 一次重试、`_start_from_refusal` 文案、`request_goto_profile` 与 `request_reset_to_initial`
  共用 `_start_profile_motion`、`_claim_profile_motion` / `MOTION_BUSY` 串行化四条 profile 运动、`ActiveSession.motion_detail` + `notice()`）；
  `server/rest.py`（`GET /api/online_dagger/{skill,skill.tgz,sessions}`；`/api/pro_dagger/*` 404）、`server/ws_telemetry.py`
  （`DaggerStatus.online_dagger` 25 Hz、`SessionTelemetry.trainer_alive`、`session.fault_detail`）；`config.py`（namespaces
  `{bc_demo, online_dagger}`、`OnlineDaggerRuntimeConfig`、`HardwareSessionConfig.start_from_fault_grace_s = 3.0`、
  `ControlConfig.translate_frame = "world"`）、`configs/mavis_v2.yaml` / `sim.yaml`；`online_dagger/__init__.py` + `online_dagger/skill/
  {SKILL.md, references/contract.md, references/pro-dagger-example.md}`（`SKILL_NAME = "mavis-online-dagger-trainer"`；`pro_dagger/` 目录
  与 `algorithm.md` 删除）；每条 `15-pro-dagger` 引用改指 15-online-dagger。测试：`tests/dagger/test_online_dagger_coordinator.py`（22+）、
  `tests/test_online_dagger_session.py`、`tests/test_online_dagger_package.py`（含镜像逐字节一致）、`tests/dora_bridge/test_e2e_online_dagger.py`
  （3）、`tests/dora_bridge/test_fake_trainer_role.py`（3）、`tests/test_goto_profile.py`（8+）、`tests/test_return_manager_units.py`，
  `test_pro_dagger_*` 三个文件与 `test_e2e_pro_dagger.py` 删除；golden 重生成。保留自上午：`recorder/datasets.py` 的 namespace 根映射 +
  `layout()`、`actor` 列、`GET /api/datasets/layout`、D6、`streams/hub.py` 编码器相位修复 + `tests/test_video_hub_pacing.py`。
- **ui**（`1716a5a` 上，54 files, +6178/−507，35 个 untracked 行 = 35 个文件）：新 `OnlineDaggerSheet(.test).tsx`、`OnlineDaggerPanel(.test).tsx`
  （`ProDagger{Sheet,Panel}` 删除；testid `od-*` / `online-dagger-*`；CSS `.od-*`）；`lib/launch.ts`（`OnlineDaggerInputs`、
  `onlineDaggerToSpec`、SLUG / 长度取自 `schemas/OnlineDaggerConfig.json`，删除超参、范围解析、离线数据集选择与 `REASON.offlineDataset /
  resumeMismatch / trainerError`）、`lib/streams.ts`（`MODE_LABELS.dagger = "Online DAgger"`，描述 "Novice drives, you correct — your trainer
  learns between rollouts"）、`api/rest.ts`（`getOnlineDaggerSkill / getOnlineDaggerSessions / ONLINE_DAGGER_SKILL_TGZ_PATH`）、
  `EpisodeControls.tsx`（去 actor 拆分，只留 `newEpisodeReason`）、`DatasetsPanel.tsx`（每行只归一组）、`pages/Cockpit.tsx` / `Landing.tsx`、
  `styles/global.css`、fixtures、smoke；追加需求：`lib/profiles.ts`（`profilesForKind` / `initialConditionFirst` / `hasInitialCondition` /
  `profileDeleteErrorText`）、`StartFrom` 按 kind 过滤 + 空态文案、`ProfileActions` 的 "Go to profile"、`FaultBanner` 的 `SESSION —` 行
  （`sessionFaultDetail`）、`api/clients.ts` 暴露 `handleAck`；`src/gen/protocol.ts` / `schemas/` 重生成。
- **sim**（`536c4ba` 上，9 files, +198/−17）与 **hardware**（`c1ff172` 上，6 files, +640/−13）：只有合并进来的 phase-12 / phase-13
  改动，**phase-14 两轮都未触碰这两个仓**。
- **policy-node**（`c1a5843` 上，14 files, +1084/−49，7 个 untracked 行 = 20 个文件）：`contract.py`（`EVENT_KINDS` 十种、`SESSION_ANNOUNCE_FIELDS` 以
  `online_dagger` 收尾、`ONLINE_DAGGER_ANNOUNCE_FIELDS`、10 字段 trainer status、`CAPABILITY_ONLINE_DAGGER`、`validate_trainer_status`；
  `RefGradStatus` / `ProDaggerAnnounce` / `PRO_DAGGER_HPARAM_DEFAULTS` / `validate_ref_grad_status` 删除）、`messages.py`
  （`build_trainer_status`：非有限 / 非数值 metrics 丢弃、`progress` 夹到 [0,1]）、`types.py`（`PolicySpec.bump()`）、`node.py`
  （`--online-dagger` 角色、`_last_spec_version_sent`：换权后的 `spec` 一定先于 `ready v2` 状态发出、trainer_id 默认
  `<policy_id>/online_dagger`）、`__main__.py`；新 `mavis_policy_node/online_dagger/{protocol,loop,fake,config,datasets,synthetic,selftest}.py`
  （`OnlineDaggerTrainer` 八个 hook、`OnlineDaggerLoop` 单 worker 线程、`_publish_lock`、粘性的 `on_session` 失败、`FakeTrainer`
  旋钮同 runtime 的 fake）；参考实现 `mavis_policy_node/pro_dagger/{config,trainer,pgrad,datasets}.py`（`ProDaggerConfig`：`offline_dataset`
  必填、`rollouts_per_iteration 5`、`n_epochs 8`、`lr 1e-4`、`batch_size 8`、`replay_buffer True`、`max_demos 0`、`freeze_offline_gref True`、
  `gref_ema_beta 0.9`、`max_ref_batches 32`、`grad_clip 1.0`、`offline_stride 5`、`chunk_stride 3`、`seed 0`，另 `datasets_home ~/data`、
  `save_checkpoints True`、`steps_per_batch`；未知键拒绝；`_prepared` 闩）；v1.0 的 `pro_dagger/{loop,protocol,fake,selftest,synthetic}.py`
  删除；`skills/mavis-online-dagger-trainer/`（runtime 副本的逐字节镜像）、`skills/mavis-pro-dagger-trainer/` 删除；`tests/golden/
  contract_golden.json`、`test_contract` / `test_messages` / `test_online_dagger_loop` / `test_pro_dagger_trainer` / `test_pro_dagger_pgrad` /
  `test_pro_dagger_datasets` / `test_fake_policy`（非 dora 共 141 条）、`test_node_e2e`（2 条，dora）；README、pyproject 注释、CI。

### 真实测试数

| 仓 | 命令 | 结果 |
|---|---|---|
| core | `uv run python -m apollo_mavis_v2_core.protocol.export_schemas --out schemas/ --check`；`uv run ruff check .`；`uv run pytest -o addopts=""` | **本记录复跑**：`--check` rc 0；ruff 全过；**464 passed in 3.54 s**（v2.0 重构后 459；追加需求 +5） |
| runtime | `uv run ruff check .`；`uv run pytest`（含 `dora`，真私有控制面） | **据报告，本记录只复跑 `--co`：737 条**。v2.0 stage 2 全量 708 passed / 1 failed（perf flake）/ 3 skipped，683 s；审查修复后全量 **713 passed / 1 failed（`test_return_to_start` deadman 计时 flake，单跑 4/4）/ 2 skipped，689 s**；`test_e2e_online_dagger.py` **3 passed，单独 30.9–32.3 s**（module setup 4.5–5.5 s，`test_online_dagger_rollouts_over_the_bus` 20.7–24.2 s）；追加需求后非 dora 子集 **715 passed / 2 skipped / 20 deselected** |
| ui | `npm run gen:check && npm run lint && npx vitest run && npm run build`；`npx prettier --check src tests` | **本记录复跑**：gen:check OK；eslint 0；**44 files / 436 tests passed**（v2.0 重构 415 → 审查修复 418 → 追加需求 435 → 其审查修复 436）；build = tsc + vite + `check-dist OK`；prettier 全过 |
| policy-node | `.venv/bin/ruff check . && .venv/bin/ruff format --check . && .venv/bin/pytest -q -m "not dora"`；`python -m mavis_policy_node --online-dagger fake --selftest online-dagger` | **本记录复跑**：ruff / format 全过；**141 passed, 2 deselected in 9.55 s**（v2.0 重构 139 → 审查修复 141）；selftest exit 0，states `[idle, preparing, ready, training, ready, training, ready, idle]`，12 statuses，version 1 → 3。dora e2e 2 条据修复报告 2 passed / 9.9 s（未复跑） |
| sim / hardware | `uv run pytest` | 155 passed（含 13 个 `egl`）/ 293 passed——合并验证时的数字，phase-14 未改这两个仓 |

### 审查发现：已修复（v2.0 轮）

- **ui**（1 major + 10 minor）：`newRolloutReason` 只看 `phase`，trainer 死掉而 phase 停在 `rollout` 时 New episode 仍可点 → 先判
  `trainer_alive === false || !trainer`（与 runtime `_refuse_locked` 同序）。minor：error pill 重复 "trainer error:" 前缀；resume 的 task
  预填在改名后残留；`validateLaunch` 对 session-less 的 trainer `error` 硬拦（runtime 并不 409）→ 改为警告；Take over / Hand back 在非
  `recording` 状态被禁用而 runtime 任何时候都接受 → 只看 `control_mode`；JSON schema `as` 断言遮蔽形状漂移 → 直读类型化 JSON；
  `default_namespace` 改成 `online_dagger` 时同一行出现在两组 → 每行只归一组；resume 只能靠 sessions 列表 → 409 / 列表失败时给出
  显式 "Resume the existing session" 复选框；UI 自带 `TRAINER_STALE_S` 与 runtime `spec_stale_s` 重复 → 删除，只信 `trainer_alive`；
  `onlineDaggerModel` 忽略的 `external` 参数与常显的 sparkline → 删参、`useLossHistory`、无 loss 时不画；actor 拆分显示两次 → 只留 Panel。
- **policy-node**（2 major + 6 minor）：`on_session` 失败后任一后续 hook 成功就把 `error` 翻成 `ready`，没有 reference pool 的
  PRO-DAgger 照样训练并换权 → `_error_kind` 记住失败的是哪个 job，`on_session` 失败**粘性**（该 session 的事件在 loop 层丢弃并计数，
  只有新 session id 才离开 `error`），非 session 错误只在一次成功 `train_if_due` + 换权后清除；`swap_weights` 后节点不重发 `spec`，
  runtime 的 `policy_version_acting` 落后 `ready v2` 最多 1 s，窗口内开的 rollout 会在 episode 中途换版本 → `_last_spec_version_sent`，
  `_serve` / `_pump_trainer` 在发送任何 trainer 状态前先发脏 `spec`（e2e 断言 `seq(spec v2) < seq(first ready v2)`）。minor：
  `_publish` 快照与入队之间无锁 → `_publish_lock`；SKILL.md / protocol.py / README 对线程模型说法不一 → 统一为"除 `status_metrics` 外
  八个 hook 都在一个 worker 线程；`status_metrics` 在发布线程上、可能与 `train_if_due` 重叠"；`FakeTrainer.on_train_now` 空 buffer 也训练
  且 `n_rollouts` 误报 → `_train_now` 标志、空 buffer 忽略、报实际数量；`replay_buffer` 是死旋钮 → 实现（`false` 每个 iteration 后清空）；
  pro-dagger-example.md 与代码漂移（`datasets_home` 本地解析而非 `GET /api/datasets`、缺 `steps_per_batch / datasets_home / save_checkpoints`、
  指标名 `scale_check_ratio`、首次公告前没有 `trainer_status`）→ 改文档（两份副本同步）；`_count_expert` 两条路径口径不同 → 统一用
  `datasets.actor_counts`。
- **runtime**（1 major + 8 minor）：`episode_new` 落在 recorder 刚从 `saving → idle` 翻转的同一 tick 时丢弃边界被跳过（命令在 tick 第 1 步
  排空、边界检查在之后；回位关闭或被跳过时会发生）→ `_settle_boundary` 在 `_op_episode_new` 打开新 episode 前先结清上一条的边界，
  并在重开 tick 消费保存标志时不把 `_boundary_taken` 留给新 episode；两条回归测试。minor：spool 写失败跳过 `on_episode_saved` →
  try/except 后仍调用（`spool_path: null`）；coordinator 事件的 `session_id` 在发布时才解析 → 闭包钉住；保存边界的 gate 事件先于
  `episode_saved` 且 `episode_id` 为 null → 先 coordinator 后 executor、缓存打开时的 id；运行中删除已保存 rollout 不通知 trainer →
  409 "dataset 'online_dagger/<s>' is in use by the running Online DAgger session - end the session first"；resume 绕过 "being exported"
  拒绝 → `_check_online_dagger` 调 `_refuse_exporting_or_legacy`；resume 同步重写 `session.json` 在后续 409 时留下脏记录 → 只在 RUNNING
  后写；第二次保存失败不发 `episode_discarded` → 发（缓冲按 04-runtime §15 保留）；9 处 `15-pro-dagger` 引用 → 改指 15-online-dagger。
- **core**：跨仓核对无发现（schemas `--check` rc 0、ui schemas 逐字节一致、两份 golden 一致、skill 镜像一致、四仓 grep 无 `pro_dagger`
  代码级残留）。

### 审查发现：已修复（同晚追加需求轮，2 major + 7 minor）

- major：`start_from` 被拒的文案写进 manager 内部字段 `session.fault_detail`，wire 上没有 → core `SessionTelemetry.fault_detail` /
  `SessionInfo.fault_detail`（additive）+ runtime `ActiveSession.motion_detail` / `notice()`（fault 回调把 `fault_detail` 清掉时提示
  不再丢失）+ ui `FaultBanner` `SESSION —` 行 + e2e `test_start_from_refused_by_a_latched_fault_reaches_the_wire_and_survives_recovery`；
  `goto_profile` / `reset_to_initial` ok ack 之后规划失败无声 → `_profile_motion_reported` 把每个非 `done` 结果写进 `motion_detail`。
- minor：RECOVERING 臂被当成 faulted 并叫人 "Clear errors" → 分支文案 "<arm> is recovering - release every input (clutch / keys)…"；
  `_op_execute_plan` 允许第二个 plan 覆盖运行中的 plan → nack `plan executing` + manager 层 `_claim_profile_motion`；POLICY 模式下 R /
  goto 无声抢占 policy → `GatedPolicyExecutor` nack `policy driving - take over (Space) first`；`_start_from_worker` 以 `state == START_FROM`
  驱动进度、瞬时故障后 `_bringup` 不清 → 改跟 `plans.active_arms`、每条退出路径都清；测试缺口（回调已挂载的 RECOVERING → RUNNING、
  文案上 wire、两段之间故障）→ 补齐；"still recording" 在 saving 时也这么说 → "an episode is still saving - wait for it to finish"；
  ui `hasInitialCondition` 不计无 kind 的行 → 计入。

### 审查发现：未修复 / 遗留

- `tests/dora_bridge/test_perf_bridge.py::test_teleop_tick_rate_with_bridge_on_and_off` 的 `overruns == 0` 守卫在本机 2/4 概率失败
  （一次是 74.7 ms 的 gen-2 GC；操作员的 dev runtime 同时以 94 % CPU 跑着），与已知 GIL 尾延迟同源，**未放宽**。
- `tests/test_return_to_start.py::test_initial_condition_profile_is_the_fallback_return_target` 在整模块连跑时偶发：编码器收尾的 GIL 停顿
  触发 WS deadman → 回位被跳过（"browser input latched"）；单跑 / 复跑通过。根治仍是编码器子进程。
- dora live 测试的泄漏检查是机器级 `pgrep -x dora`：同一台机器同时跑第二个 dora 套件会互相误报，未改。
- 每 1 s 一条 `Discarding event for input policy_spec due to queue size limit`（fake 在公告与心跳上都重发 `spec`，runtime `policy_spec`
  队列为 1）：无害但吵，未再检查。
- policy-node：`--trainer-config` 的 YAML 分支需要 pyyaml，`.venv` 里有、`pyproject` 未声明（JSON 总是可用；加 extra 会动 `uv.lock`，未动）；
  `pro_dagger` extra 名字保留（它只是 pyarrow）。
- 普通（非 Online DAgger）session 仍不发 `events.episode_discarded`（只有 `events.gate` 变成了所有 policy session 都发）。
- `scripts/deploy/render-lab-config.sh` 不模板化 `datasets.namespaces`（用户决定数据在 `var/` 之外；`DATASETS_HOME` 旋钮待定）。
- `ruff format --check` 在 core（16 个既有文件）与 runtime `manager.py` 既有块报未格式化——两仓不强制 formatter，未动。
- ui：`src/gen/protocol.ts` 保留 core 生成的 docstring 里 "iterations" 一词（core 所有）；`sessions` 列表没有 `kind`，resume 另一种
  workcell 的 session 不在客户端拒绝。
- 设计文档层面可补的三条契约细节（据 runtime 修复报告）：边界的 `events.gate{source: episode_reset}` 带关闭的 episode id、spool 写不出时
  `episode_saved.spool_path` 为 null；运行中 `DELETE …/online_dagger/<s>/episodes/<id>` 409；导出中的 `online_dagger/<s>` 不能被 POST 复用。
- `start_from_fault_grace_s` 默认 3.0 s 对实测 ~10 ms 的瞬态很宽松，用户看过真机表现后可调低。
- **真机上尚未跑过任何 phase-12 / 13 / 14 代码；真 policy 仓的 trainer 尚未接过外壳（只有两个 fake）；一切需重启 runtime 才生效。**
- ~~12-dagger / 14-dora / 04-runtime / 05-ui / 10-frames / 01-core / 00-overview 的 PRO-DAgger 措辞待并行文档任务改写~~ → 已于
  2026-09-08 深夜完成（见验收最后一项的 ✓ 行）。

### 与 15-online-dagger v2.0 原文的偏差（代码为准）

- gate 事件的发布路径：Online DAgger session 经 coordinator 的 `SerialWorker`（与 `episode_saved` / `episode_discarded` 保序），普通
  external / checkpoint 的 dagger / inference session 经新增的 `SnapshotPublisher.enqueue_event()`（有界 256）在 publisher 线程排空。
- `GateEvent.source` 多一个拼写 `"action"`（显式 `takeover` / `handback` 动作；字段是普通 str，additive），出现在 sidecar 与 `events.gate`。
- `train_now` 只在 episode 打开或 trainer 状态陈旧时拒绝（§3 原文）；`waiting_trainer` / `training` / `error` 期间**允许**（trainer 决定）。
  ack 文案 "asked the trainer to train (<n> rollout(s) saved)"。
- phase 是"最新的本 session 状态 + `trainer_seen_ready` 闩"的纯函数：`ready` 之后收到 `idle` / `preparing` 仍算 `rollout`；
  `pause_while_training=False` 时 `training` 保持基础 phase。§3 未写这些情况。
- sidecar 块的 `rollouts_saved` **包含**正在保存的这条（与 `events.episode_saved` 一致）；v1.0 的槽位预留 / 不一致告警机制删除。
- 基类 `ControlLoop` 对 `takeover` / `handback` 的 nack 沿用 `takeover not available in teleop`；teleop 下 `takeover` 取消 plan（像 Space）、
  `handback` 不取消。
- skill 由 runtime 侧先写成、policy-node 逐字节镜像并按其记录的 API 实现（`SessionInfo` / `Rollout` / `GateEvent` / `TrainResult`
  出自 `online_dagger.protocol`，`make_trainer(policy, config, device)`，`PolicySpec.bump()`）。
- policy-node：`on_session` 收到的是 `SessionInfo`（`SessionAnnounce` JSON 的 Mapping 视图 + `.session_id / .session_dir / .rollouts_dir /
  .spec / .resume / .pause_while_training` 属性），`on_gate` 收到 `GateEvent`（Mapping 视图 + 属性）；`TrainResult` 全部字段有默认值；
  `training` 从 trainer 第一次调 `progress()` 或 `train_if_due` 进入 0.1 s 后可见；`error` 的退出规则见"已修复"；`ProDaggerConfig`
  多 `datasets_home`（repo id 在本地文件系统解析）与 `save_checkpoints` 两个键；selftest 对任何 `error` 状态都 exit 1、要求
  `idle → preparing → ready → training → ready` 子序列 + 版本 bump，并额外发一次 discard 与一次 train_now（fake 训两次，v1 → v3）；
  loop 在每条状态（含 session 结束后的最终 `idle`）合并 `status_metrics()`。
- runtime fake trainer：拿到 session 后第一条状态是 `preparing`（v1.0 先发 `idle`）；空 buffer 上的 `train_now` 忽略（detail
  "train_now ignored: no rollouts saved yet"）；rollout 计数来自 `events.episode_saved` 的 `actor_counts` 块而非读 spool；不落盘。
- dora e2e 去掉了 v1.0 "`POST /api/session` ≤ 3.0 s" 的 bring-up 上界（冷启动第一个 policy session 3.8 s；RUNNING-fast 由
  `test_e2e_external_policy.py` 覆盖）；rig 里不再有离线 collect session；discard 在 expert 持臂时进行以覆盖 `episode_reset`；
  phases 钉为 `[waiting_trainer, rollout, training, rollout, training, rollout]`。
- ui：`training` pill 只在 `trainer.progress > 0` 时显示百分比与确定进度条（0 = 不定进度条）；Take over 在 `takeover_transition` 也禁用；
  Take over / Hand back 共用一行原因；trainer pill 只在 `error` 时附 `detail`；resume pill 写 "Resume (N rollouts saved)"；metrics 按 wire
  顺序、非有限值丢弃；trainer `error` 在启动前是警告不是门禁；横幅只有 dead（missing / lost）与 error 两种（`trainer_alive` 唯一新鲜度来源，
  设计里的 "stale" 无 UI 自有窗口）；actor 拆分只在 Panel。
- REST：运行中 Online DAgger session 的已保存 rollout `DELETE` 409；`POST /api/session` 对正在导出的 `online_dagger/<s>` 409（§7 未列）。

### 同晚追加：操作员的两个问题（2026-09-08 晚，已落地、已审查、未提交）

1. **Welcome 的 profile 列表按页签 kind 过滤**：两种 workcell 各有一份 initial-condition profile 后，旧列表把两份都列出、预选的可能是另一
   种 kind 的（不可见的选择）。新 `src/lib/profiles.ts`；`StartFrom` 只列本 kind + 无 `workcell_kind` 的旧行；空态 "No Sim profiles — 1
   saved profile belongs to the Hardware workcell"；DELETE 409 toast "'<name>' is the initial condition of the <Hardware|Sim> workcell —
   designate another profile as the initial condition first"。
2. **`start_from` 被瞬时 RECOVERING 拒绝**：日志（03:25:36 `grip`、18:44:52 `view`）显示使能后一个 tick 的 Reseed / RecoveredEvent 让臂在
   `_recovering` 里恰好一个 tick，预规划的 `execute_plan` 在该 tick 顶部排空、被 `_op_execute_plan` 以 "arm 'view' is faulted" 拒绝并丢弃，
   而 `on_fault_state` 尚未挂载所以 manager 无记录。修复：`hardware_session.start_from_fault_grace_s`（默认 3.0 s）内每 50 ms 轮询到
   `faulted | recovering` 清空再提交、被拒且剩余宽限内清空则**重试一次**；最终拒绝写 "start_from refused: <arm names> faulted (controller
   state <n>, code C<k>) - use Clear errors & resume, then Go to profile"（RECOVERING 臂另有文案），并**上 wire**
   （`session.fault_detail`，Cockpit `FaultBanner` 黄色 `SESSION —` 行，`GET /api/session` 同）。**Go to profile**：core `goto_profile` +
   `GotoProfileArgs {profile_id}`；runtime `_op_goto_profile`（录制中 / 无 store / 未知 id / kind 不符 / 不覆盖本 session 任何臂 / plan
   在跑 / 无 manager 各有文案）→ `request_goto_profile` → 与 R 相同的两段孪生规划 + 门禁 + 可中断路径，ack "going to profile '<name>'"；
   ui `ProfileActions` 的下拉 + 按钮，禁用时给可见原因，无确认对话框，nack → "Go to profile refused: <reason>"。同时：四条 profile 运动
   （每集回位 / R / goto / 退出回位）在 manager 层串行（`MOTION_BUSY`），`_op_execute_plan` 对已有 plan nack，POLICY 模式下 R / goto 被
   `GatedPolicyExecutor` 以 "policy driving - take over (Space) first" 拒绝（04-runtime §10.5 已记）。测试：core 459 → 464；runtime 694 →
   706 → 715（非 dora）；ui 418 → 435 → 436。**未在真机上验证。**

### 同晚追加（二）：真机首次 `reset_to_initial` 暴露的两处（2026-09-08 深夜，已落地、未提交、未在真机验证）

**现象**（`var/logs/runtime.log` 23:16:52）：真机 `reset_to_initial` 由 `ResetPlanner` **顺序**规划（第 k 臂规划时，前面的臂冻结在
GOAL、后面的臂冻结在 START），但 `SessionManager._run_return_plan` 把两臂的 waypoints 塞进**同一个** `execute_plan`，`PlanExecutor`
让两臂**同时**走过从未校验过的组合；孪生门禁在 5.2 mm（`grip_right_finger` / `view_link3`）处 hold，回位卡住约 30 s 直到预算耗尽才
报 "timed out"。操作员当晚决定：按规划器顺序**逐臂执行**；默认速度 **100 %**。

1. **逐臂顺序执行**（core `PlanResult.arm_order` + sim 规划器填值见上一节；runtime 消费端本轮）：新 `SessionManager._execute_arms`
   成为所有孪生规划多臂运动的唯一执行入口 —— 回位两阶段（R / 退出回位 / Go to profile）、每集回位、sim 与 hardware 的 `start_from`：
   按 `PlanResult.arm_order`（`_ordered_waypoints` 重排 dict；无 `arm_order` 的 fake 回退到 dict 顺序）每臂提交一个只含该臂 waypoints
   的 `execute_plan`，等 `plans.active_arms` 清空再提交下一臂；规划器原地不动的臂（每个 waypoint 与首点差 ≤ 1e-6）不提交；gripper
   目标随**最后一个移动的臂**提交，可中断 plan 的 gripper 在该臂到达时才生效（loop `_op_execute_plan` 现在把可中断 plan 的**全部**
   gripper 目标延迟到 plan 完成，含不在本次 waypoints 里的臂）；任一臂被拒 / 取消 / 故障 / 超时即停止序列，其余臂不启动，文案点名
   `"<原因> - <Arm>; <其余臂> not moved"`（单臂序列文案与从前逐字相同）；预算 `_return_budget_s` 改为**按臂**（`start_from` 取
   `max(120 s, 预算)`）；`start_from_progress` 仍按全部臂的 waypoints 计数；`start_from` 半途被取消 / hold / 超时现在也写 notice
   `"start_from cancelled: … (Go to profile retries it)"`。hardware `_plan_profile_start` 返回的 waypoints 已按 `arm_order` 键序。
2. **门禁 hold 即时中止**：`HardwareSessionConfig.plan_gate_hold_s`（默认 3.0 s，`ge=0`，sim 同样生效）。loop 新增 `_plan_gate_watch`
   （控制线程，门禁之后、下发之前，每 tick O(活动臂数) 无分配）：门禁 blocked 且所有执行中臂的门禁输出等于上一 tick 命令（无 waypoint
   进展）即计时，任一有进展的 tick 归零，超时 `_cancel_plans("held by the safety gate: <a> / <b> at <mm> mm")`（`GATE_HOLD_PREFIX`；
   pair 取本 tick 门禁报告，回退 merged report，再回退门禁 `_block_pairs`；stale twin 写 "stale digital twin"），telemetry
   `plan_status: cancelled`，臂原地 hold。manager 映射为内部状态 `held`：每集回位报 `"return stopped - held by the safety gate: …"`，
   R / 退出对话框文案 `"the motion was held by the safety gate[ while moving the joints] and stopped (<pair> at <mm> mm - <Arm>; …
   not moved). The arms hold where they are."`，wire 状态复用 `ReturnHomeResult` 的 `timeout`（字面量无 `held`）；真正预算超时的
   `timeout` 分支文案不变。`0` = 第一个 hold tick 即取消。
3. **默认速度 100 %**：`HardwareSessionConfig.default_speed_scale = 1.0`、`configs/mavis_v2.yaml`（含 `plan_gate_hold_s: 3.0`）、
   `tests/test_configs.py` / `tests/test_hardware_monitor.py` 的 pin；显式 `speed_scale: 0.5` 的用例不动；ui `DEFAULT_SPEED_SCALE`
   已是 1.0（`src/lib/launch.ts`），两端不再漂移。dev render 未动。
4. **测试**：新增 `tests/test_sequential_plan_execution.py`（两臂回位按 `arm_order` 先后到达、第二臂在第一臂到达前 q 不变；反序
   `arm_order` 生效；gripper 仅在最后一臂到达后生效；第一臂期间按键取消 → 第二臂未动且文案点名；单臂行为不变；`start_from` 两臂顺序 +
   进度覆盖全部 waypoints；`start_from` 首臂被取消的 notice；脚本化 HoldingGate：0.2 s 内取消并带 pair、`plan_status cancelled`、
   短暂 hold 不取消、`0` 首 tick 取消、默认 3.0 s；manager 层即时报 pair 与对话框文案）；更新 `test_return_manager_units` /
   `test_goto_profile` / `test_hardware_session` 的 `execute_plan` 调用次数（每臂一次）。runtime 非 dora：715 → 728 收集（+13），`uv run pytest -o addopts="" -m "not dora"` = **727 passed, 1 failed, 2 skipped, 20 deselected**；唯一红的是 `tests/test_perf.py::test_control_tick_budget_and_rate` 的 p99 断言（三次 8.3–10.1 ms > 4 ms，median 1.8 ms 达标），跑测时本机 load 55 / 64 核、操作员的 dev runtime（`python -m apollo_mavis_v2_runtime --config var/mavis_v2_local.yaml`）占约 36 核；该用例走的是无 plan 的键盘 teleop tick，本轮在该路径上只多了一个 `if self.plans.active_arms:` 空判断，判定为环境噪声，未改阈值。core / sim 各 465 / 146 见上一节。
5. **文档**：ws `CLAUDE.md`（保护规则新增"逐臂执行"一条；速度默认 100 %）、04-runtime §5 / §10.5（"Sequential execution" +
   "Gate-held abort" + 事故记录）/ §14 配置块、05-ui 速度默认段两处、11-safety §9、03-sim §10。

### 历史：v1.0（2026-09-08 上午）实施记录摘要 —— Superseded (2026-09-08 晚) — see 15-online-dagger

上午按 15-pro-dagger v1.0 实现了 PRO-DAgger 外壳：core `ProDaggerConfig`（23 个超参，D8 默认 = 参考 `SessionConfig`，replay buffer 关）/
`SessionSpec.pro_dagger` / `ProDaggerStatus` + `ProDaggerIterationSummary` / `RefGradStatus` / 六字段 `ProDaggerAnnounce` /
`EVENT_KINDS += iteration_complete, pro_dagger_phase` / `ActionName += pro_dagger_train_now`；runtime `dagger/pro_dagger.py::ProDaggerCoordinator`
（`preparing → rollout → training → swapping → rollout`，R 个 kept rollout 触发 `iteration_complete`，`_maybe_finish_swap` 只看公告版本）、
session 目录 `~/data/pro_dagger/<s>/{session.json, ref_grad/, rollouts/}`、`GET /api/pro_dagger/{skill,skill.tgz,sessions}`、skill
`mavis-pro-dagger-trainer`（`SKILL.md` + `contract.md` + `algorithm.md`）、fake 节点的 PRO-DAgger trainer 角色（`FAKE_TRAINER_EPOCH_S /
_FAIL_AT_ITER / _FAIL_PREPARE`，写 `registry.json` + `gref0.npy`）、`test_e2e_pro_dagger.py`（3 条，33.6 s）；ui `ProDaggerSheet`（两步、
离线数据集单选、超参范围校验取自 `ProDaggerConfig.json`）+ `ProDaggerPanel`（阶段 / 指标 / 历史 6 行）；policy-node
`mavis_policy_node/pro_dagger/{protocol,loop,datasets,pgrad,fake,synthetic,selftest}.py`、`--pro-dagger` / `--selftest pro-dagger`、
`skills/mavis-pro-dagger-trainer/`。当时的数字：core 470、runtime 713 条（全量 710 passed / 2 skipped）、ui 415、policy-node 128、golden
sha256 `3dae3df0…f9e4`（4093 字节）；四份审查 11 major + 38 minor 全部修复（含 verify 阶段发现的 `streams/hub.py` 编码器相位锁定 bug——
`EncoderWorker` 固定网格轮询与等速 sim 渲染网格相位重合导致预览 11.9–14.5 Hz，改为周期内等下一帧并重锚定，探针 14.98 Hz、帧龄 p99
62 → 11.7 ms，`tests/test_video_hub_pacing.py` 钉住，**该修复在 v2.0 树上保留**）。合并阶段修好的两条 phase-12 测试
（`test_import_confinement.py` 放行 `recorder/` 的 pyarrow；`test_e2e_external_policy.py::test_external_dagger_two_episodes` 读
`episodes/*/frames.parquet`）与 14-dora §1 "Import confinement" 的 2026-09-08 增补同样保留。v1.0 中**与算法无关、v2.0 原样保留**的部分：
namespace 根映射与 `GET /api/datasets/layout`、`actor` 列与 `EpisodeSummary` 的两个计数、`return_to_start` 放开到 dagger、
`ExternalStatus.capabilities / trainer_status`、`POLICY_OUTPUTS += trainer_status` / `RUNTIME_INPUTS += policy_trainer_status`（queue 8）、
`control.translate_frame: world`、`scripts/check-dist.ts`、`CopyButton` / `runtimeOrigin`、`SLUG_RE`、`DatasetLayoutInfo`。其余（迭代状态机、
超参、`ref_grad/`、两个事件、`/api/pro_dagger/*`、旧 skill、旧 fake 角色、旧 e2e）被 v2.0 删除，未做别名。

### 环境事实（撰写时）

- 开发机上的 dev runtime 是 **PID 2144376，2026-09-08 18:00:02 启动**（cwd `apollo-mavis-v2-runtime/`，`--config var/mavis_v2_local.yaml`，
  该配置 17:59 渲染、已含 `translate_frame: world`），跑的是 18:00 的工作树快照——05:52 合并**之后**、18:38 v2.0 重构**之前**，即上午
  PRO-DAgger v1.0 期的代码；本 phase 的一切（Online DAgger 外壳、`start_from_fault_grace_s`、Go to profile、`session.fault_detail`）都要
  重启 runtime 才生效；**真机上尚未跑过任何 phase-12 / 13 / 14 代码**。（2026-09-08 深夜更正：此前误记为"01:27 启动、PID 3749060、
  合并前代码"——该进程已不存在。）
- runtime `.venv` 用 `uv sync --locked --inexact --extra sim --extra hardware --extra audio --extra dora` 同步（`--inexact` 保住不在 lock
  里的 pysurvive 1.1.204）。policy-node `.venv` 里手工装了 CPU torch 2.14.0（`uv.lock` 未动，无 torch 时 14 条 PGrad 测试 skip）。
- 本机同一时刻只能跑一个 dora 套件（机器级 `pgrep -x dora` 泄漏检查）。

### 验收核对（本记录撰写时逐项核实的方式）

- core：复跑 `--out schemas/ --check` / ruff / pytest 464 全绿；`schemas/` 43 个文件清单确认新四个模型 + `GotoProfileArgs`、旧四个已删。
- golden / skill：`cmp` 两份 golden 一致（sha256 `4dc67e12…`，3698 字节），`python` 读出 `event_kinds` 十种以 `train_now` 收尾、
  `TrainerStatusAnnounce` 10 字段、`OnlineDaggerAnnounce` 3 字段；`diff -r` 两份 skill 目录无差异；`SKILL.md` 首行
  `name: mavis-online-dagger-trainer`。
- runtime 默认配置：`load_runtime_config` 两份 YAML 逐项读出（`world` / `bc_demo` / 两个 namespace 根 + `rollouts` / `online_dagger`
  块 / `dora.enabled False` / `armed False`）；`ControlConfig().translate_frame == "world"`；`HardwareSessionConfig().start_from_fault_grace_s
  == 3.0`；grep 确认 `SKILL_NAME`、`/api/online_dagger/{skill,skill.tgz}` 路由、`POLICY_DRIVING` / `MOTION_BUSY` / `_op_goto_profile`、
  fake 旋钮名、四条 coordinator 拒绝常量；`pytest --co` 737 条。**runtime 套件本身未复跑**。
- ui：复跑 gen:check / eslint / vitest 436 / build + check-dist / prettier；grep 确认 `MODE_LABELS.dagger`、skill 一行命令、
  `goto-profile` testid、`fault-row-session-detail`。
- policy-node：复跑 ruff / format / pytest 141（非 dora）/ selftest；grep 确认 `--online-dagger` / `--trainer-config` / `--selftest`
  参数、README 的 8765 与 CLI、`ProDaggerConfig` 默认值、`skills/mavis-online-dagger-trainer/` 三个文件、trainer_id 默认。
- 各仓 `git log -1` / `git diff HEAD --stat` / untracked 计数如"各仓落地内容"所列（含同树上的 phase-12 / 13 改动）。
