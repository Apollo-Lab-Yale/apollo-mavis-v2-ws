# apollo-xarm7 分阶段开发提示词（Phased Development Prompts）

本目录是 apollo-xarm7 五仓栈的实施计划。每个 `phase-XX-*.md` 是一份**自包含**的
实施提示词：一个 phase = 一次 Claude Code 会话，工作目录固定为
`/home/xiatao/projects/apollo-xarm7-ws`（五个子仓并列在其下）。

## 使用方法

1. 在 `/home/xiatao/projects/apollo-xarm7-ws` 启动一次新的 Claude Code 会话。
2. 把对应 phase 文件的全文作为任务输入（或让会话直接读该文件）。
3. 会话内先读 phase 文件"前置条件"里列出的设计文档（`docs/design/` 是唯一事实来源，
   `docs/research/` 仅作参考），再动手实现。
4. 按"验收标准"逐条自验（列出的命令必须真实跑通），全部通过后勾选下表。
5. 阶段之间不要并行修改同一个子仓；严格按依赖图推进。

约定（来自 `CLAUDE.md` / `docs/design/00-overview.md`）：Python ≥3.10 + `uv`；
代码/注释/仓库文档用英文；依赖方向严格单向（core 不依赖栈内任何东西；
hardware/sim 只依赖 core；runtime 依赖 core，hardware/sim 为可选 extras；
ui 只通过 HTTP/WebSocket 与 runtime 通信）。版本锁定：MuJoCo 3.12.0、
mink 1.3.0、xArm-Python-SDK 1.18.5、lerobot ≥0.6（锁定小版本）、Node ≥20 + pnpm。

## 阶段顺序与依赖图

```
phase-01-core ──┬─→ phase-02-sim-workcell ─→ phase-03-ik-twin ──┐
                │                                               ├─→ phase-05-runtime-teleop ─→ phase-06-ui ─→ phase-07-data-collection ─→ phase-08-dagger-inference ─→ phase-09-integration
                └─→ phase-04-hardware ──────────────────────────┘
```

- phase-02/03（sim 仓两部分）与 phase-04（hardware 仓）在 phase-01 完成后可并行。
- phase-03 交付安全层 CI 回归脚本 `apollo_xarm7_sim/tools/guardrail_check.py`
  （四场景 + A1–A5 断言）；phase-05 实现 runtime `SafetyGate`/`ControlLoop`
  chokepoint 并把该脚本接入 runtime CI；phase-09 在真机上做最终安全验收。
- phase-05 需要 01+02+03 完成（sim 后端的端到端测试），phase-04 完成与否不阻塞
  phase-05 的落地（hardware 路径按接口对接、以 fake SDK 测试）。
- phase-06 需要 phase-05 的服务端协议已冻结（协议形状本身在 phase-01 的
  `core.protocol` 定稿，UI 类型由 core schemas 生成）。
- phase-07/08 顺序依赖 05/06；phase-08 的 trainer 是独立进程
  （`python -m apollo_xarm7_runtime.dagger.trainer`，GPU 1，ZMQ 5757）。
- phase-09 需要全部完成，且需要真机在场。

> 多 agent 自主开发的编排方案（波次 DAG、验证门、故障恢复）见
> [ORCHESTRATION.md](ORCHESTRATION.md)。

## 状态清单

| Phase | 文件 | 仓库 | 依赖 | 状态 |
|---|---|---|---|---|
| 01 | `phase-01-core.md` | apollo-xarm7-core | — | [x] 2026-09-01 完成（154 tests 全绿，schemas/ 已导出） |
| 02 | `phase-02-sim-workcell.md` | apollo-xarm7-sim | 01 | [x] 2026-09-01 完成（66 tests，benchmark 达标） |
| 03 | `phase-03-ik-twin.md` | apollo-xarm7-sim | 01, 02 | [ ] |
| 04 | `phase-04-hardware.md` | apollo-xarm7-hardware | 01 | [x] 2026-09-01 完成（105 tests，FakeSDK 全覆盖，SDK pin 见 repo README） |
| 05 | `phase-05-runtime-teleop.md` | apollo-xarm7-runtime | 01, 02, 03（04 接口对接） | [ ] |
| 06 | `phase-06-ui.md` | apollo-xarm7-ui | 05 | [ ] |
| 07 | `phase-07-data-collection.md` | apollo-xarm7-runtime (+ui) | 05, 06 | [ ] |
| 08 | `phase-08-dagger-inference.md` | apollo-xarm7-runtime (+ui) | 07 | [ ] |
| 09 | `phase-09-integration.md` | 全部（真机） | 01–08 | [ ] |

## 每个 phase 文件的固定结构

`目标` → `前置条件`（依赖 phase + 必读设计文档）→ `范围`（含明确 out-of-scope）→
`交付物` → `验收标准`（可执行命令 + 具体数字/行为）→ `注意事项`（研究阶段发现的
坑、固件怪癖、版本锁定）。验收数字均出自 `docs/design/` 与 `docs/research/`
的实测值，不得凭空放宽。
