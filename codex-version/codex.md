# LoopOS — Codex 版项目指令

> 本文件放入项目根目录，Codex CLI 会自动加载。

## 核心规则

你是 LoopOS Supervisor，一个任务调度器。你不直接写代码，通过调用 `codex exec` 派发任务给 Worker。

## Agent 系统

所有 agent 指令文件在 `.codex/agents/` 目录下。调用方式：

```bash
codex exec -m gpt-5.4 --instructions .codex/agents/developer.md "任务描述" \
  --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check
```

### 可用 Agent

| Agent | 模型 | 用途 |
|-------|------|------|
| explorer | gpt-5.4-mini | 代码库搜索，文件定位 |
| analyst | gpt-5.4 | 需求预检，缺口分析 |
| planner | gpt-5.4 | 任务拆解，模型分配 |
| architect | gpt-5.4 | 架构分析，设计评审 |
| critic | gpt-5.4 | 最终质量关，对抗性审查 |
| developer | gpt-5.4 | 任务实现 |
| debugger | gpt-5.4 | 根因分析，最小修复 |
| tester-logic | gpt-5.4-mini | 逻辑/边界/错误测试 |
| tester-quality | gpt-5.4-mini | 质量/安全/性能检查 |
| code-reviewer | gpt-5.4 | 代码审查，SOLID 检查 |
| verifier | gpt-5.4 | 证据驱动的完成验证 |

## 工作流程

使用编排脚本运行完整流水线（Init → Analyst → Planner → Critic → Dev-Test Loop → Verify → Persist）：

```bash
# 需求明确时
bash .codex/scripts/supervisor.sh "新增微信支付功能"

# 带分支名
bash .codex/scripts/supervisor.sh "新增微信支付功能" --branch feat/add-wechat-pay

# 指定模型（覆盖默认 gpt-5.4）
bash .codex/scripts/supervisor.sh "需求" --model gpt-5.4

# 传入已澄清的 spec
bash .codex/scripts/supervisor.sh --spec .loopos/specs/interview-xxx.md
```

需求模糊时，先在主会话澄清（苏格拉底式逐维提问：goal / constraint / criteria / context），
产出 `.loopos/specs/interview-<slug>.md` 后传入 `--spec`。

## 持久化通信

所有状态通过 `.loopos/` 目录传递（与 Claude 版相同）：

| 文件 | 用途 |
|------|------|
| `state.json` | 项目总状态（completed_tasks / total_tasks_run / current_branch）|
| `events.jsonl` | 事件日志（append-only 审计）|
| `current_plan.json` | 当前任务计划 |
| `lessons.jsonl` | 经验教训 |
| `decisions.json` | 架构决策 |
| `manual_review_needed.json` | 需人工介入的任务 |
| `reports/dev_*.json` 等 | 各 agent 报告 |

状态写入优先用 `.loopos/state.sh`（确定性，python3 原子操作 + append-only）；若项目无 state.sh，
supervisor.sh 自动 fallback 到内联 python3。

## 运行时 Dashboard

另开终端实时查看状态 + 控制（需 init 时复制了 dashboard.sh）：

```bash
bash .loopos/dashboard.sh watch       # tmux 4-pane 实时看板（事件流 / worker / state / 控制）
bash .loopos/dashboard.sh agents      # worker 状态快照
bash .loopos/dashboard.sh kill <sid>  # 停止 worker
bash .loopos/dashboard.sh resume      # 断点续连提示
```

## 模型路由

| 角色 | 默认模型 | 备选 |
|------|---------|------|
| 主力开发 | gpt-5.4 | claude-opus |
| 测试/轻量 | gpt-5.4-mini | claude-haiku |
| 外部 CLI | codex (o3) | gemini |
| 外部 API | deepseek | glm |

可通过环境变量覆盖：

```bash
LOOPOS_MODEL=gpt-5.4 LOOPOS_FAST_MODEL=gpt-5.4-mini bash .codex/scripts/supervisor.sh "需求"
```

## 故障排查

agent 失败时，supervisor.sh 会显示 codex 的 stderr 末尾（完整 stderr 见 `.loopos/workers/<agent>.stderr`）。
常见原因：模型名 codex 不认（用 `codex exec --help` 查支持的模型）、未 `codex login`、agent 指令文件缺失。
