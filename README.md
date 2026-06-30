# LoopOS

**AI Task Execution Operating System** — 解决 Claude Code / Codex 长会话上下文耗尽问题。

核心思想：主会话（Supervisor）只做调度，所有代码工作派发给短生命周期的 Worker Agent，主上下文永远不会被代码细节污染。

## 问题

AI 编程工具（Claude Code、Codex、Cursor）在复杂任务中会遇到：

1. **上下文窗口耗尽** — 代码内容、测试输出、错误日志撑满上下文，触发 auto-compact 丢失关键信息
2. **无法从崩溃中恢复** — 中断后丢失所有进度
3. **单模型瓶颈** — 简单任务用昂贵模型浪费，复杂任务用便宜模型质量差
4. **质量保障缺失** — 开发者自己测自己的代码，缺少独立审查

## 方案

```
                        ┌──────────────────┐
                        │   Supervisor     │
                        │ (只调度,不写代码) │
                        └────────┬─────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                   ▼
        ┌───────────┐    ┌───────────┐        ┌───────────┐
        │  Planner  │    │ Developer │ ×N     │  Verifier │
        │  拆解任务  │    │  实现代码  │ 并行   │  验证完成  │
        └───────────┘    └─────┬─────┘        └───────────┘
                               │
                    ┌──────────┼──────────┐
                    ▼          ▼          ▼
              ┌──────────┐ ┌────────┐ ┌──────────┐
              │  Tester  │ │ Tester │ │ Code     │
              │  Logic   │ │Quality │ │ Reviewer │
              └──────────┘ └────────┘ └──────────┘
```

- **Supervisor** 只看到 JSON 路径和状态码，永远不读代码
- **Worker** 在独立 worktree 中串行工作，dev/fix 完成即 merge 回 feature 分支并跑 `go build` 验证
- **状态持久化** 到 `.loopos/` 目录，中断可恢复
- **多模型路由** 根据任务复杂度自动分配最合适的模型

## 快速开始

### Claude Code 版

```bash
# 方式 1: 在目标项目中初始化
cd ~/code/my-project
bash ~/code/Axiom/init-loopos.sh

# 方式 2: 指定目标目录
bash ~/code/Axiom/init-loopos.sh ~/code/my-project
```

然后在 Claude Code 中：

```
# 需求明确时 — 直接执行
Workflow({ name: 'supervisor-worker', args: { request: '新增微信支付功能' } })

# 需求模糊时 — 先 /deep-interview 访谈澄清（原 workflow 已改为 Skill）
# 用 AskUserQuestion 逐维提问（goal/constraint/criteria/context），产出 .loopos/specs/interview-xxx.md
Workflow({ name: 'supervisor-worker', args: { request: '...', spec: '.loopos/specs/xxx.md' } })
```

### 运行时 Dashboard

实时查看 agent 运行状态 + token + 控制（另开一个终端，在目标项目根目录跑）。

**启动实时看板**：
```bash
bash .loopos/dashboard.sh watch
```
启动 tmux 4-pane 看板（`Ctrl-b d` detach 后台继续，`Ctrl-b x` 杀 session）：
```
┌─────────────────────┬─────────────────────┐
│ 事件流               │ 外部 worker 状态     │
│ tail -f loopos.jsonl │ (2s 刷新)            │
├─────────────────────┼─────────────────────┤
│ 控制提示             │ 全局 state           │
│ (命令列表)           │ (3s 刷新)            │
└─────────────────────┴─────────────────────┘
```

**命令一览**（普通终端跑）：
```bash
bash .loopos/dashboard.sh watch       # tmux 4-pane 实时看板
bash .loopos/dashboard.sh agents      # 外部 worker 状态快照（sid/provider/model/status/token）
bash .loopos/dashboard.sh events [N]  # 最近 N 条事件（默认 20）
bash .loopos/dashboard.sh state       # 全局 state.json
bash .loopos/dashboard.sh kill <sid>  # 停止外部 worker
bash .loopos/dashboard.sh resume      # 断点续连提示
```

**断点续连**：workflow 中断后，主会话跑：
```javascript
Workflow({ name: 'supervisor-resume', args: {} })
```
它读 `.loopos/state.json` + `manual_review_needed.json` + `current_plan.json`，续跑未完成 / 失败任务。数据持久化在 `.loopos/`（state.json + events.jsonl + workers/*.meta）。

**停整个 workflow**：用 harness 的 `/tasks`（LoopOS 代码层做不到）。

**盲区**：Claude 原生子 agent（analyst/planner/dev 等用 opus/sonnet/haiku）的实时状态和 token 拿不到——harness 不暴露 subagent 内部。dashboard 只能看：
- 外部 worker（gpt/gemini/glm 等）完整状态 + token
- workflow 事件层调用点（`dev_start` / `passed` / `failed` / `merge` / `build_failed`）

token 仅外部 worker 有（tmux-worker collect 时 best-effort 从 stdout 提取，依赖 CLI 输出格式）。

### Codex 版

```bash
cd ~/code/my-project
bash ~/code/Axiom/codex-version/init-codex.sh

# 运行
bash .codex/scripts/supervisor.sh "新增用户注册功能"
bash .codex/scripts/supervisor.sh "修复支付 bug" --branch fix/payment-null
```

## 最佳实践操作流程

### Phase 0: 环境准备

```bash
# 1. 初始化 LoopOS
cd ~/code/my-project
bash ~/code/Axiom/init-loopos.sh

# 2. (可选) 安装 opencode — 启用非 Claude 模型
# https://opencode.ai
# 验证: opencode run --format json -m deepseek/deepseek-chat "hello"

# 3. (可选) 按项目需求调整 Agent 模型
# 编辑 .loopos/agent-models.json
```

### Phase 1: 需求澄清 — 先想清楚再动手

```
 你的需求有多清楚？
       │
       ├── 模糊 ("做一个推荐系统")
       │     → /deep-interview Skill 先行
       │     → 产出 spec 再交给 supervisor-worker
       │
       ├── 中等 ("新增微信支付，支持退款")
       │     → 直接 supervisor-worker，但建议带 spec 或详细 request
       │
       └── 明确 ("在 src/auth.ts 加 JWT 刷新逻辑")
             → 直接 supervisor-worker，可跳过 critic (critic: false)
```

```javascript
// 模糊需求 — 务必先访谈
/deep-interview   # 主会话访谈 Skill（AskUserQuestion 逐维澄清）
// → 产出 .loopos/specs/interview-xxx.md
// → 人工审阅 spec，确认后再执行
Workflow({ name: 'supervisor-worker', args: {
  request: '基于协同过滤的推荐系统',
  spec: '.loopos/specs/interview-xxx.md'
}})
```

> **常见错误：** 跳过访谈直接执行模糊需求。Planner 会猜测你的意图，生成的任务可能方向错误，浪费整个 Dev-Test Loop 的成本。

### Phase 2: 执行 — 让系统工作

```javascript
// 标准执行
Workflow({ name: 'supervisor-worker', args: {
  request: '新增微信支付功能',
  branch: 'feat/add-wechat-pay'   // 建议显式指定分支名
}})
```

**执行期间你应该做什么：**

| 做 | 不做 |
|---|------|
| 看 `/workflows` 进度面板 | 去读代码文件 |
| 等 Workflow 完成 | 中途手动改文件（会冲突） |
| 如果卡住太久，`Ctrl+C` 中断 | 在同一分支开第二个 Workflow |

### Phase 3: 验收 — 人工确认

```bash
# Workflow 完成后
git log --oneline feat/add-wechat-pay   # 看提交历史
git diff main..feat/add-wechat-pay      # 看总变更

# 读验证报告
cat .loopos/reports/verify_final.json

# 有问题的任务
cat .loopos/manual_review_needed.json   # 如果存在
```

**三种结果及对应动作：**

| 结果 | 信号 | 下一步 |
|------|------|--------|
| 全部通过 | `verify_final.json` → passed: true | 创建 PR |
| 部分失败 | `manual_review_needed.json` 非空 | 针对失败点追加 Workflow |
| 全局不对 | 方向偏了 | 回到 Phase 1 重新访谈 |

### Phase 4: 迭代 — 增量修复

```javascript
// 从中断点恢复（Workflow 崩溃或手动中断后）
Workflow({ name: 'supervisor-resume', args: {} })

// 追加新需求（在同一分支上继续）
Workflow({ name: 'supervisor-worker', args: {
  request: '微信支付增加退款功能',
  branch: 'feat/add-wechat-pay'    // 复用已有分支
}})
```

> **增量执行的关键：** Planner 会读取 `state.json` 中的 `completed_tasks`，只规划增量任务。`lessons.jsonl` 中的经验也会传递给新的 Developer，避免重复犯错。

### Phase 5: 合并 — 收尾

```bash
# 确认一切就绪后
git checkout main
git merge feat/add-wechat-pay
# 或创建 PR 走 code review
```

### 模型选择指南

```
 你的任务是什么？
       │
       ├── 关键功能 / 安全敏感
       │     → 全 Claude (默认配置即可)
       │     → critic + code-reviewer 保持 opus
       │
       ├── 标准功能 / 控制成本
       │     → 测试用廉价模型
       │     agent_models: { "tester-*": "gpt-5.4-mini" }
       │
       ├── 需要特定模型能力
       │     → 中文理解: deepseek / glm
       │     → 大上下文: gemini
       │     → 强推理: o3 / opus
       │
       └── 交叉验证
             → analyst 用 GPT，critic 用 Claude
             → 不同模型视角减少盲区
```

```javascript
// 示例: 省钱配置 — 只在关键环节用 opus
Workflow({ name: 'supervisor-worker', args: {
  request: '重构用户模块',
  agent_models: {
    "analyst": "claude-sonnet-4-6",
    "critic": "claude-opus-4-6",
    "tester-logic": "gpt-5.4-mini",
    "tester-quality": "gpt-5.4-mini",
    "code-reviewer": "claude-opus-4-6"
  }
}})

// 示例: 多模型交叉验证 — 减少单一模型盲区
Workflow({ name: 'supervisor-worker', args: {
  request: '支付安全审计',
  agent_models: {
    "analyst": "gpt-5.4-pro",
    "critic": "claude-opus-4-6",
    "code-reviewer": "deepseek-v4-pro",
    "verifier": "gemini-2.5-pro"
  }
}})
```

### 常见陷阱

| 陷阱 | 后果 | 正确做法 |
|------|------|---------|
| 模糊需求直接执行 | Planner 猜错方向，浪费整轮 | 先 /deep-interview |
| 执行中手动改文件 | worktree merge 冲突 | 等 Workflow 完成再改 |
| 不看 `manual_review_needed.json` | 以为成功但实际有 3 个任务跳过 | 每次执行后必查 |
| 所有 Agent 都用 opus | 成本 ×5，速度 ×0.3 | 只在关键角色用 opus |
| 不指定 branch 名 | 自动生成的名字不直观 | 总是显式指定 |
| 一个 request 塞太多需求 | 任务拆解质量下降 | 拆成多次 Workflow |

## 工作流水线

### 完整流水线

```
主会话访谈 (可选)                    主流水线
AskUserQuestion                     supervisor-worker
  │                                   │
  ├── 探测项目上下文                    ├── Init: 建 feature 分支
  ├── 苏格拉底提问 ×N                  ├── Plan:
  ├── ambiguity 打分                  │   ├── Analyst 需求预检
  └── 输出 spec ──────────────→       │   ├── Planner 拆任务 + 模型分配
                                      │   └── Critic 审查计划
                                      ├── Dev-Test Loop (per DAG layer, 串行):
                                      │   ├── Developer (worktree) → 即 merge + go build
                                      │   ├── parallel(Tester×2, Code-Reviewer)
                                      │   └── Debugger (worktree) → 即 merge + go build (max 3)
                                      ├── Verify: 全局验证 (测试+构建+验收)
                                      └── Persist: 更新状态 → Ready for PR
```

### Git 分支模型

```
main ─────────────────────────────────────────
  │
  └─ feat/add-wechat-pay  (Init 创建)
       ├─ worktree/t1 ──commit──→ merge + go build  (Layer 1, 串行)
       ├─ worktree/t2 ──commit──→ merge + go build
       ├─ worktree/t3 ──commit──→ merge + go build  (Layer 2, 依赖 t1)
       └── [loopos] update state    (Persist)
            ↓
       Ready for PR → main
```

## Agent 系统

11 个专职 Agent，各司其职：

| Agent | 职责 | Claude 模型 | Codex 模型 |
|-------|------|------------|-----------|
| **explorer** | 代码库搜索、文件定位 | claude-haiku-4-5 | gpt-5.4-mini |
| **analyst** | 需求预检、缺口分析 | claude-opus-4-6 | gpt-5.4-pro |
| **planner** | 任务拆解 → DAG、模型分配 | claude-sonnet-4-6 | gpt-5.4-pro |
| **architect** | 架构分析、调试指导 | claude-opus-4-6 | gpt-5.4-pro |
| **critic** | 最终质量关、对抗性审查 | claude-opus-4-6 | gpt-5.4-pro |
| **developer** | 实现一个任务 | auto (按任务) | gpt-5.4-pro |
| **debugger** | 根因分析、最小 diff 修复 | auto (按任务) | gpt-5.4-pro |
| **tester-logic** | 逻辑、边界、错误处理 | claude-sonnet-4-6 | gpt-5.4-mini |
| **tester-quality** | 安全、性能、模式一致性 | claude-sonnet-4-6 | gpt-5.4-mini |
| **code-reviewer** | SOLID、安全、规格合规 | claude-opus-4-6 | gpt-5.4-pro |
| **verifier** | 证据驱动的完成验证 | claude-sonnet-4-6 | gpt-5.4-pro |

### 升级路径

- Developer 3 次修复失败 → 升级到 Architect
- Debugger 3 个假设失败 → 升级到 Architect
- Critic 拒绝计划 → 自动重新规划

## 多模型路由

### Claude Code 版

| 模型 | 运行方式 | 适用场景 |
|------|---------|---------|
| claude-opus | `agent(model: 'opus')` | 复杂架构、安全审查 |
| claude-sonnet | `agent(model: 'sonnet')` | 标准开发、测试 |
| claude-haiku | `agent(model: 'haiku')` | 简单编辑、桥接 |
| gpt-5.4-pro / o3 / deepseek / gemini / glm | opencode tmux worker | 统一网关，所有外部模型 |
| cursor | 独立 CLI tmux worker | 编辑器级任务 |

### Codex 版

| 模型 | 运行方式 | 适用场景 |
|------|---------|---------|
| gpt-5.4-pro | `codex exec -m gpt-5.4-pro` | 主力开发、审查 |
| gpt-5.4-mini | `codex exec -m gpt-5.4-mini` | 测试、简单任务 |
| o3 / o4-mini | `codex exec -m o3` | 推理密集、算法 |
| claude-opus | 跨 provider 调用 | 关键任务交叉验证 |

## 项目结构

```
Axiom/
├── .claude/
│   ├── agents/              # 11 个 Agent 定义 (Claude 版)
│   │   ├── analyst.md
│   │   ├── architect.md
│   │   ├── code-reviewer.md
│   │   ├── critic.md
│   │   ├── debugger.md
│   │   ├── developer.md
│   │   ├── explorer.md
│   │   ├── planner.md
│   │   ├── tester-logic.md
│   │   ├── tester-quality.md
│   │   └── verifier.md
│   └── workflows/           # Workflow 脚本
│       ├── supervisor-worker-demo.js   # 主工作流
│       ├── supervisor-with-memory.js   # 中断恢复
│       ├── iterative-fix.js            # 单 bug 迭代修复
│       └── PROTOCOL.md                 # 协议文档
├── .loopos/                  # 运行时状态 (两版共用)
│   ├── models.json           # 模型注册表
│   ├── tmux-worker.sh        # tmux worker 管理
│   ├── state.json            # 项目状态
│   ├── decisions.json        # 架构决策
│   ├── reports/              # Agent 报告
│   ├── workers/              # tmux worker 文件
│   └── specs/                # /deep-interview 输出
├── codex-version/            # Codex 版
│   ├── agents/               # 11 个 Agent 定义 (Codex 版)
│   ├── scripts/
│   │   └── supervisor.sh     # bash 编排脚本
│   ├── loopos/
│   │   └── models.json       # Codex 模型注册表
│   ├── codex.md              # 项目指令
│   └── init-codex.sh         # 初始化脚本
├── init-loopos.sh            # Claude 版初始化脚本
└── README.md
```

## 核心设计原则

### 1. 文件路径通信，不传代码内容

```
❌ prompt: "这是 payment.ts 的代码: function createOrder()..."
✅ prompt: "读取 src/payment.ts 了解现有实现"
```

### 2. 经验积累

Developer 和 Debugger 修完 bug 后，自动将经验追加到 `.loopos/lessons.jsonl`：

```json
{"task_id":"t1","lesson":"API 响应缺少 null check — 永远验证外部数据","category":"null_safety"}
```

后续任务自动读取，避免重复犯错。

### 3. 可中断恢复

所有状态持久化到 `.loopos/`。中断后运行 `supervisor-resume` 工作流：

```
Workflow({ name: 'supervisor-resume', args: {} })
```

自动评估已完成的任务，从断点继续。

## Claude Code 版详细说明

### 初始化

```bash
cd ~/code/my-project
bash ~/code/Axiom/init-loopos.sh
```

初始化后的目录结构：

```
my-project/
├── .claude/
│   ├── agents/           # 11 个 Agent 指令
│   └── workflows/        # 2 个 Workflow + 协议
├── .loopos/
│   ├── models.json       # 模型注册表
│   ├── tmux-worker.sh    # 外部模型 worker
│   ├── state.json        # 状态
│   ├── decisions.json    # 架构决策
│   ├── reports/          # Agent 报告输出
│   ├── workers/          # tmux worker 文件
│   └── specs/            # /deep-interview 规格
└── .gitignore            # 已追加 LoopOS 规则
```

### Agent 文件格式

Claude Code Agent 使用 YAML frontmatter 定义元信息：

```markdown
---
name: developer
model: claude-opus-4-6
description: Focused coding worker - executes exactly one task
tools:
  - Read
  - Edit
  - Write
  - Bash
  - LSP
---

# Role
你是一个 Developer Worker...

# Rules
- 只修改与任务直接相关的文件
- ...
```

| 字段 | 说明 |
|------|------|
| `name` | Agent 标识符，在 `agentType` 中引用 |
| `model` | 默认模型（可被 Workflow 覆盖） |
| `description` | Agent 职责描述 |
| `tools` | 允许使用的工具白名单 |

只读 Agent（analyst、architect、critic、code-reviewer、verifier、explorer）不包含 `Edit` 和 `Write` 工具。

### Workflow API

Claude Code 的 Workflow 工具提供确定性编排原语：

```javascript
// agent() — 派发一个子 Agent
const result = await agent(prompt, {
  label: 'dev:t1',           // 进度显示标签
  model: 'opus',             // 模型覆盖
  schema: BRANCH_SCHEMA,     // 强制结构化输出
  isolation: 'worktree',     // git worktree 隔离
  agentType: 'developer',    // 使用 .claude/agents/developer.md
  phase: 'Dev-Test Loop',    // 归属阶段
})

// parallel() — 并行执行，等待全部完成
const [logicResult, qualityResult, reviewResult] = await parallel([
  () => agent('逻辑测试...', { agentType: 'tester-logic' }),
  () => agent('质量测试...', { agentType: 'tester-quality' }),
  () => agent('代码审查...', { agentType: 'code-reviewer' }),
])

// pipeline() — 流水线，每个 item 独立穿过所有阶段
const results = await pipeline(
  tasks,                              // 输入列表
  async (task) => { /* stage 1 */ },  // 开发
  async (devResult) => { /* stage 2 */ },  // 测试
)

// phase() — 标记阶段（进度显示用）
phase('Dev-Test Loop')

// log() — 输出进度信息
log(`[t1] Passed [opus]`)
```

### 主 Workflow: supervisor-worker

文件：`.claude/workflows/supervisor-worker-demo.js`

```javascript
// 基本调用
Workflow({ name: 'supervisor-worker', args: {
  request: '新增微信支付功能'
}})

// 指定分支名
Workflow({ name: 'supervisor-worker', args: {
  request: '新增微信支付功能',
  branch: 'feat/add-wechat-pay'
}})

// 传入 /deep-interview 产出的 spec
Workflow({ name: 'supervisor-worker', args: {
  request: '新增微信支付功能',
  spec: '.loopos/specs/interview-add-wechat-pay.md'
}})

// 手动模型覆盖
Workflow({ name: 'supervisor-worker', args: {
  request: '新增微信支付功能',
  model_overrides: {
    "t1": "claude-opus",   // 强制用 opus
    "t3": "deepseek"       // 简单任务用 deepseek
  }
}})

// 跳过 critic 审查
Workflow({ name: 'supervisor-worker', args: {
  request: '简单的配置修改',
  critic: false
}})

// Agent 模型覆盖（全局调整 Agent 角色的模型，支持任意 LLM）
Workflow({ name: 'supervisor-worker', args: {
  request: '新增微信支付功能',
  agent_models: {
    "analyst": "gpt-5.4-pro",          // 用 GPT 做分析
    "tester-logic": "deepseek-v4-pro",  // 用 DeepSeek 做测试
    "critic": "claude-opus-4-6",        // 关键审查保留 Claude
    "developer": "claude-opus-4-6"      // 强制所有 developer 用 opus
  }
}})
```

**执行阶段：**

| 阶段 | 涉及 Agent | 说明 |
|------|-----------|------|
| Init | — | 建分支、初始化 `.loopos/` |
| Plan | analyst → planner → critic | 预检 → 拆任务 → 审查计划 |
| Dev-Test Loop | developer → tester×2 + code-reviewer → debugger | 逐 DAG 层执行，每层并行 |
| Verify | verifier | 全局测试 + 验收标准检查 |
| Persist | — | 更新 state、event log、commit |

### 需求澄清（/deep-interview Skill）

原 deep-interview 后台 workflow 已改为 Skill（后台 workflow 无法与人交互，会生成空 spec）。
主会话调用 `/deep-interview`，用 AskUserQuestion 逐维访谈（goal/constraint/criteria/context），
保留 ambiguity 打分，输出 `.loopos/specs/interview-<slug>.md`，再传入 supervisor-worker 的 `spec` 参数。
详见 `.claude/skills/deep-interview/SKILL.md`。

**苏格拉底提问维度：**

| 维度 | 权重（绿地） | 权重（棕地） | 问题风格 |
|------|------------|------------|---------|
| goal_clarity | 40% | 35% | "当用户点击 X 时，具体发生什么？" |
| constraint_clarity | 30% | 25% | "并发上限是多少？超过怎么办？" |
| criteria_clarity | 30% | 25% | "怎么验证这个功能正确工作？" |
| context_clarity | — | 15% | "这和现有的 auth 模块如何集成？" |

**模糊度公式：**

```
greenfield: ambiguity = 1 - (goal × 0.40 + constraints × 0.30 + criteria × 0.30)
brownfield: ambiguity = 1 - (goal × 0.35 + constraints × 0.25 + criteria × 0.25 + context × 0.15)
```

**挑战模式（自动激活）：**

| 轮次 | 模式 | 作用 |
|------|------|------|
| 4+ | CONTRARIAN | "如果反过来做会怎样？" |
| 6+ | SIMPLIFIER | "最简版本是什么？" |
| 8+ | ONTOLOGIST | "这个东西本质上是什么？" |

### tmux Worker（外部模型）

文件：`.loopos/tmux-worker.sh`

当任务分配给非 Claude 模型时，通过 tmux worker 执行：

```bash
# CLI 工具（codex/gemini/cursor）→ tmux 真实终端
# 有完整文件系统访问权限，可以直接读写文件、运行命令

# API 模型（deepseek/glm）→ curl 调用
# 同步返回，不需要 tmux

# 生命周期管理
.loopos/tmux-worker.sh spawn <provider> <model> <prompt_file> <workdir>
.loopos/tmux-worker.sh status <session_id>
.loopos/tmux-worker.sh collect <session_id>
.loopos/tmux-worker.sh kill <session_id>
.loopos/tmux-worker.sh list
```

**在 Workflow 中的调用路径：**

```
Claude 原生 (opus/sonnet/haiku)
  → agent() + model 参数 + worktree 隔离

外部模型 (gpt/deepseek/gemini/glm 等)
  → bridge agent (haiku)
    → tmux-worker.sh spawn opencode provider/model
    → 轮询 status
    → collect 结果
    → 应用变更

独立 CLI (cursor)
  → bridge agent (haiku)
    → tmux-worker.sh spawn cursor ...
    → 轮询 status
    → collect 结果
```

### Agent 模型配置

通过 `.loopos/agent-models.json` 集中配置每个 Agent 使用的模型，支持 Claude 全称/简称、外部 LLM 全称：

```json
{
  "agent_models": {
    "explorer":       "claude-haiku-4-5",
    "analyst":        "claude-opus-4-6",
    "planner":        "claude-sonnet-4-6",
    "critic":         "claude-opus-4-6",
    "developer":      "auto",
    "debugger":       "auto",
    "tester-logic":   "claude-sonnet-4-6",
    "tester-quality": "claude-sonnet-4-6",
    "code-reviewer":  "claude-opus-4-6",
    "verifier":       "claude-sonnet-4-6"
  }
}
```

**支持的模型名称：**

| 类别 | 模型名 | 运行方式 |
|------|--------|---------|
| Claude 全称 | `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5` | `agent()` 直连 |
| Claude 简称 | `opus`, `sonnet`, `haiku` | `agent()` 直连 |
| OpenAI | `gpt-5.4-pro`, `gpt-5.4-mini`, `gpt-5.5`, `o3`, `o4-mini` | opencode tmux |
| Google | `gemini-2.5-pro`, `gemini-3.1-pro`, `gemini-3.5-flash` | opencode tmux |
| DeepSeek | `deepseek-v4-pro`, `deepseek-v4-flash`, `deepseek-chat` | opencode tmux |
| 智谱 | `glm-5`, `glm-5.1`, `glm-5-turbo`, `glm-4-plus` | opencode tmux |
| Cursor | `cursor` | 独立 CLI tmux |

**`auto` 含义：** developer 和 debugger 设为 `auto` 时，使用 Planner 分配的任务模型（按任务复杂度路由）。

**覆盖优先级（从低到高）：**

| 优先级 | 配置方式 | 说明 |
|--------|---------|------|
| 1 (最低) | Workflow 内置默认值 | `AGENT_MODEL_DEFAULTS` 常量 |
| 2 | `.loopos/agent-models.json` | 项目级配置文件 |
| 3 | `args.agent_models` | 运行时全局覆盖 |
| 4 (最高) | `args.model_overrides` | 按任务 ID 覆盖（仅影响 developer/debugger） |

**外部模型路由原理：** 非 Claude 模型统一通过 opencode CLI（`opencode run --format json -m provider/model`）在 tmux 中运行，有完整文件系统访问。opencode 是统一网关，支持 OpenAI/Google/DeepSeek/智谱等所有主流 provider。桥接 agent (haiku) 负责写 prompt、spawn worker、轮询状态、收集结果。

```javascript
// 示例：降低成本 — 用 GPT 做测试
Workflow({ name: 'supervisor-worker', args: {
  request: '简单需求',
  agent_models: {
    "tester-logic": "gpt-5.4-mini",
    "tester-quality": "gpt-5.4-mini",
    "analyst": "claude-sonnet-4-6"
  }
}})

// 示例：多模型混用
Workflow({ name: 'supervisor-worker', args: {
  request: '关键功能',
  agent_models: {
    "analyst": "gpt-5.4-pro",
    "critic": "claude-opus-4-6",
    "verifier": "gemini-2.5-pro"
  }
}})
```

### 持久化文件详解

`.loopos/` 目录是所有 Agent 之间的通信总线：

```
.loopos/
├── state.json              # 全局状态
│   {
│     "completed_tasks": ["t1", "t2"],
│     "total_tasks_run": 5,
│     "current_branch": "feat/add-wechat-pay",
│     "project_summary": ""
│   }
│
├── current_plan.json       # 当前任务计划（Planner 写，Developer 读）
│   {
│     "request": "...",
│     "tasks": [
│       {
│         "id": "t1", "title": "...", "depends_on": [],
│         "complexity": "mid", "assigned_model": "claude-sonnet",
│         "status": "completed"
│       }
│     ]
│   }
│
├── models.json             # 模型注册表（9 个模型）
├── agent-models.json       # Agent 模型配置（每个 Agent 用哪个 Claude 模型）
├── decisions.json          # 架构决策记录
├── lessons.jsonl           # 经验积累（Developer/Debugger 追加）
├── events.jsonl            # 事件日志
├── tmux-worker.sh          # 外部模型 worker 管理
│
├── reports/
│   ├── analyst_*.json      # Analyst 分析报告
│   ├── dev_t1.json         # Developer 开发报告
│   ├── test_logic_t1.json  # 逻辑测试报告
│   ├── test_quality_t1.json # 质量测试报告
│   ├── review_t1.json      # 代码审查报告
│   ├── debug_t1.json       # Debugger 修复报告
│   ├── critic_plan.json    # Critic 计划审查
│   ├── architect_*.json    # Architect 架构报告
│   └── verify_final.json   # Verifier 最终验证
│
├── workers/                # tmux worker 运行时
│   ├── prompt_t1.txt       # 发给外部模型的 prompt
│   ├── <sid>.meta.json     # worker 元信息
│   ├── <sid>.stdout        # worker 输出
│   └── <sid>.exit_code     # 退出码
│
├── specs/                  # /deep-interview 产出
│   └── interview-add-wechat-pay.md
│
└── manual_review_needed.json  # 需人工介入的任务
```

### 中断恢复

```javascript
// 从中断点恢复
Workflow({ name: 'supervisor-resume', args: {} })
```

三阶段自动恢复：
1. **Assess** — 读取 `.loopos/state.json` + `current_plan.json`，判断哪些任务已完成
2. **Resume** — 只执行未完成的任务
3. **Persist** — 更新状态

---

## Codex 版详细说明

### 初始化

```bash
cd ~/code/my-project
bash ~/code/Axiom/codex-version/init-codex.sh
```

初始化后的目录结构：

```
my-project/
├── codex.md              # 项目指令（Codex 自动加载）
├── .codex/
│   ├── agents/           # 11 个 Agent 指令
│   └── scripts/
│       └── supervisor.sh # bash 编排脚本
├── .loopos/              # 运行时状态（与 Claude 版格式相同）
│   ├── models.json
│   ├── state.json
│   ├── decisions.json
│   ├── reports/
│   ├── workers/
│   └── specs/
└── .gitignore
```

### Agent 文件格式

Codex 版 Agent 使用 HTML 注释标注元信息（无 YAML frontmatter）：

```markdown
<!-- agent: developer | model: gpt-5.4-pro | mode: implement -->

# Developer — 任务执行

你是 Developer Worker，执行恰好一个任务...
```

| 字段 | 说明 |
|------|------|
| `agent` | Agent 标识符 |
| `model` | 默认模型 |
| `mode` | `read-only` / `implement` / `fix` / `verify` / `write-plan` |

### 编排方式

Codex 版使用 bash 脚本调用 `codex exec` 串联 Agent：

```bash
# 单个 Agent 调用
codex exec -m gpt-5.4-pro \
  --instructions .codex/agents/developer.md \
  --dangerously-bypass-approvals-and-sandbox \
  "TASK: 实现用户注册 API"

# 完整流水线
bash .codex/scripts/supervisor.sh "新增用户注册功能"
bash .codex/scripts/supervisor.sh "需求" --branch feat/user-register
bash .codex/scripts/supervisor.sh --spec .loopos/specs/xxx.md
bash .codex/scripts/supervisor.sh "需求" --model o3
```

### supervisor.sh 参数

| 参数 | 说明 | 示例 |
|------|------|------|
| 第一个位置参数 | 需求描述 | `"新增支付功能"` |
| `--branch` | 指定分支名 | `--branch feat/payment` |
| `--spec` | 使用 spec 文件 | `--spec .loopos/specs/xxx.md` |
| `--model` | 覆盖主模型 | `--model o3` |

### 环境变量

```bash
export LOOPOS_MODEL="gpt-5.4-pro"       # 主模型（默认）
export LOOPOS_FAST_MODEL="gpt-5.4-mini"  # 快速模型（测试用）
export LOOPOS_WORKER_TIMEOUT=600         # tmux worker 超时秒数

# 外部 API 模型需要的 key
export DEEPSEEK_API_KEY="sk-..."
export GLM_API_KEY="..."
```

---

## 两版对比

| 方面 | Claude Code 版 | Codex 版 |
|------|---------------|----------|
| 编排方式 | Workflow API (JS) | bash 脚本 |
| 并行能力 | `parallel()` / `pipeline()` | 串行（可扩展） |
| Agent 隔离 | `isolation: 'worktree'` | git branch |
| Agent 格式 | YAML frontmatter | HTML 注释 |
| 交互能力 | `AskUserQuestion` | stdin |
| 项目指令 | CLAUDE.md | codex.md |

## 前置要求

**Claude Code 版：**
- Claude Code CLI
- git
- tmux（使用外部模型时）
- opencode CLI（推荐，统一网关：`https://opencode.ai`）

**Codex 版：**
- Codex CLI (`npm i -g @openai/codex`)
- git
- python3（state 解析）

**可选 CLI 工具：**
- `cursor-agent`（Cursor CLI）

## License

MIT
