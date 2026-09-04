# 多 Agent 开发编排方案（ORCHESTRATION）

本文档记录如何驱动 phase-02 ~ phase-09 的开发：既可以**手动**（每个 Claude Code
session 跑一个 phase），也可以**自主编排**（一个 orchestrator session 派发
sub-agent 并行/顺序开发）。两种模式的验收标准完全相同，都以
`docs/design/` 为唯一事实来源。

## 依赖 DAG 与波次

```
Wave 1:  phase-02 (sim: assets/scenes/SimWorkcell)   ∥   phase-04 (hardware: 全部, FakeSDK 落地)
Wave 2:  phase-03 (sim: MinkIK + DigitalTwin + planner + guardrail)      ← 02
Wave 3:  phase-05 (runtime: ControlLoop/teleop/safety/server)            ← 03 (+04 接口)
Wave 4:  phase-06 (ui: SPA + landing + cockpit)                          ← 05
Wave 5:  phase-07 (runtime+ui: LeRobot v3 数采)                          ← 05, 06
Wave 6:  phase-08 (runtime+ui: DAgger + AsyncTrainer + inference)        ← 07
手动:    phase-09 (真机验收 + submodule 转换 + CI)                        ← 01–08，需人在场
```

## 模式 A：手动（每 session 一个 phase）

在 `apollo-mavis-v2-ws` 目录启动 Claude Code，粘贴：

```
请执行 docs/prompts/phase-0X-<name>.md。先读 CLAUDE.md 和
docs/design/00-overview.md，再读该 phase 文件里列出的必读设计文档。
完成后：验收标准逐条通过 → 在对应子 repo 里 commit + push →
勾选 docs/prompts/README.md 状态表并 commit ws repo。
```

## 模式 B：自主编排（orchestrator + sub-agents）

orchestrator（主 session）职责：按波次派发 phase agent、做**验证门**、
commit + push、推进下一波。已于 2026-09-01 由本模式启动。

### Phase agent 标准任务模板

每个 phase 一个 sub-agent（模型统一 **Claude Fable 5**），prompt 要点：

1. 必读：`docs/prompts/phase-0X-*.md`（任务书）+ 其列出的设计文档（binding）
   + `CLAUDE.md`。设计文档与任务书冲突时以设计文档为准，并在报告中注明。
2. 只在指定子 repo 内写代码；core 以 editable path dep 引入
   （`uv add --editable ../apollo-mavis-v2-core`）；版本 pin 按设计文档。
3. **反 stall 规则**：单次工具调用生成 ≤120 行；大文件先写骨架再分节 Edit。
4. 迭代到「验收标准」全部通过（跑真实命令，贴输出），`ruff check` clean。
5. **不 commit**——orchestrator 验证后统一 commit + push。
6. 返回：文件清单、验收结果逐条对照、未决问题。

### 验证门（orchestrator 在每个 phase 后亲自执行）

- 在子 repo 里跑 `uv run pytest -q`（ui: `pnpm test`）与该 phase 的验收命令；
- 抽查与设计文档的符合性（接口签名、端点、数值）；
- 通过 → commit + push 子 repo，勾选 README 状态表，commit ws repo；
- 失败 → 用 SendMessage 把失败输出发回原 agent 续跑（上下文保留），
  或另派修复 agent。

### 故障恢复

- agent stall（长时间无进展）：SendMessage 原 agent「从断点继续」通常即可恢复；
- agent 结果不可用：新开 agent，附上已有文件清单与失败原因；
- orchestrator session 中断：新 session 读本文件 + README 状态表即可接管
  （状态表是唯一进度事实）。

### 提交规范

- 每个 phase 在其子 repo 一个 commit（信息含 phase 编号与验收摘要），
  commit footer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`；
- ws repo 在每波结束后 commit（状态表 + 文档修订）；
- phase-09 完成前不做 submodule 转换（各 repo 独立开发更顺）。

## 大 phase 的拆分先例

phase-01 实际执行方式（可复用）：orchestrator 亲写地基模块（数学/类型），
再按依赖分层并行派发 2-3 个 implementer agent（文件集互不相交），最后
orchestrator 集成（`__init__`、全量测试、schema 导出）+ 一个对抗性审查
agent（独立复现验证，抓到 5 个真实 bug）。phase-05/08 这类大 phase 建议
同样拆分；02/03/04/06/07 单 agent 可承担。
