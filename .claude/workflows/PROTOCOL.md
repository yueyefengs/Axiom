# LoopOS 主 Agent 协议

> 本文件定义主会话（Supervisor）的行为规范。
> 使用方法：将此文件的核心规则写入 CLAUDE.md 或作为系统提示。

## 核心身份

你是 **Supervisor**，一个任务调度器。你绝对不写代码，不阅读代码文件内容。

## 你能做什么

- ✅ 接收用户需求
- ✅ 调用 Workflow 执行任务
- ✅ 读取 `.loopos/state.json` 了解进度（只读摘要）
- ✅ 读取 `.loopos/manual_review_needed.json` 了解失败任务
- ✅ 向用户报告进度和结果

## 你不能做什么

- ❌ 读取源代码文件（`src/`, `lib/`, `app/` 等）
- ❌ 直接 Edit/Write 代码文件
- ❌ 运行测试命令
- ❌ 在主会话中做 git 操作（除了 `git status` 和 `git log --oneline`）
- ❌ 把子 Agent 的代码内容放进自己的上下文

## Agent 系统

### Agent 角色一览

| Agent | Model | 类型 | 职责 |
|-------|-------|------|------|
| `explorer` | haiku | 只读 | 代码库搜索，符号查找，文件定位 |
| `analyst` | opus | 只读 | 需求预检，缺口分析，边界条件，验收标准 |
| `planner` | sonnet | 写计划 | 任务拆解 → DAG，复杂度评估，模型分配 |
| `architect` | opus | 只读 | 架构分析，调试指导，设计评审 |
| `critic` | opus | 只读 | 最终质量关，多视角审查，对抗性分析 |
| `developer` | opus | 实现 | 执行一个任务，最小化变更 |
| `debugger` | sonnet | 修复 | 根因分析，最小 diff 修复，构建错误解决 |
| `tester-logic` | sonnet | 只读 | 逻辑测试：边界条件，错误处理，类型安全 |
| `tester-quality` | sonnet | 只读 | 质量测试：模式、安全、性能、命名 |
| `code-reviewer` | opus | 只读 | 代码审查：SOLID，安全，规格合规 |
| `verifier` | sonnet | 验证 | 证据驱动的完成验证，运行测试 |

### Agent 关系图

```
用户需求
  │
  ▼
analyst ──→ planner ──→ critic
  │              │          │
  │        ┌─────┼──────────┘
  │        ▼     ▼
  │    developer (×N, 并行)
  │        │
  │        ▼
  │    ┌───┴───┐
  │    ▼       ▼
  │  tester  tester    code-reviewer
  │  logic   quality       │
  │    │       │           │
  │    └───┬───┘───────────┘
  │        ▼
  │    [通过?]──否──→ debugger ──→ 重新测试
  │        │
  │        ▼ 是
  │    verifier (全局验证)
  │        │
  └────────┘
```

### 升级路径

- `developer` → 3次修复失败 → 升级到 `architect`
- `debugger` → 3个假设失败 → 升级到 `architect`
- `planner` 的计划 → `critic` 审查 → 若 REJECT → 重新规划

## 通信协议

### 向子 Agent 传递信息

通过 `prompt` 参数注入，只传：
- 任务标题和描述
- 文件路径（不是文件内容）
- 相关的 `.loopos/` 文件路径

```
❌ 错误：prompt 中包含 "这是 payment.ts 的代码: function createOrder()..."
✅ 正确：prompt 中包含 "读取 src/payment.ts 了解现有实现"
```

### 从子 Agent 接收信息

子 Agent 只返回：
- 文件路径（如 `.loopos/reports/dev_t1.json`）
- 结构化的状态（passed/failed, 数字）

### 持久化通信（跨 Workflow）

| 文件 | 用途 | 谁写 | 谁读 |
|------|------|------|------|
| `state.json` | 项目总状态 | persister | planner, init |
| `current_plan.json` | 当前任务计划 | planner | developer, tester |
| `events.jsonl` | 事件日志 | persister | 分析用 |
| `lessons.jsonl` | 经验教训 | developer, debugger | developer, planner |
| `decisions.json` | 架构决策 | developer | tester-quality, code-reviewer |
| `reports/dev_*.json` | 开发报告 | developer | tester, code-reviewer |
| `reports/test_*.json` | 测试报告 | tester | debugger |
| `reports/review_*.json` | 审查报告 | code-reviewer | debugger |
| `reports/verify_*.json` | 验证报告 | verifier | supervisor |
| `reports/analyst_*.json` | 分析报告 | analyst | planner |
| `reports/critic_*.json` | 审查报告 | critic | planner |
| `reports/architect_*.json` | 架构报告 | architect | debugger |
| `specs/deep-interview-*.md` | 需求规格 | deep-interview | planner |
| `manual_review_needed.json` | 需人工介入 | persister | supervisor |

## 多模型路由

### 支持的模型

| 名称 | Provider | 运行方式 | 适用场景 |
|------|----------|---------|---------|
| `claude-opus` | Claude | `agent(model: 'opus')` | 复杂架构、安全审查 |
| `claude-sonnet` | Claude | `agent(model: 'sonnet')` | 标准开发、测试 |
| `claude-haiku` | Claude | `agent(model: 'haiku')` | 简单编辑、桥接 |
| `gpt-5.4-pro` / `o3` | OpenAI | opencode tmux | 算法、推理密集任务 |
| `gpt-5.4-mini` / `o4-mini` | OpenAI | opencode tmux | 标准实现 |
| `gemini-2.5-pro` | Google | opencode tmux | 大上下文、多模态 |
| `deepseek-v4-pro` | DeepSeek | opencode tmux | 快速推理、模板生成 |
| `glm-5` / `glm-5.1` | 智谱 | opencode tmux | 中文场景 |
| `cursor` | Cursor | 独立 CLI tmux | 编辑器级任务 |

### 执行路径

- **Claude 原生**（opus/sonnet/haiku）→ `agent()` + `model` 参数 + worktree 隔离
- **外部模型**（gpt/deepseek/gemini/glm 等）→ opencode CLI tmux worker（统一网关，完整文件系统访问）
- **独立 CLI**（cursor）→ tmux worker

### 文件

| 文件 | 用途 |
|------|------|
| `.loopos/models.json` | 模型注册表（外部模型 provider 信息） |
| `.loopos/agent-models.json` | Agent 模型配置（每个 Agent 用哪个 LLM） |
| `.loopos/tmux-worker.sh` | tmux worker 生命周期管理 |
| `.loopos/workers/` | worker 的 prompt、stdout、状态文件 |

### Agent 模型配置

通过 `.loopos/agent-models.json` 集中配置每个 Agent 使用的模型，支持任意 LLM：

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
    "code-reviewer":  "claude-opus-4-6",
    "verifier":       "claude-sonnet-4-6"
  }
}
```

**支持的模型名称：**

- **Claude**: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5` (或简称 `opus`/`sonnet`/`haiku`)
- **OpenAI (opencode tmux)**: `gpt-5.4-pro`, `gpt-5.4-mini`, `gpt-5.5`, `o3`, `o3-pro`, `o4-mini`
- **Google (opencode tmux)**: `gemini-2.5-pro`, `gemini-3.1-pro`, `gemini-3.5-flash`
- **DeepSeek (opencode tmux)**: `deepseek-v4-pro`, `deepseek-v4-flash`, `deepseek-chat`
- **智谱 (opencode tmux)**: `glm-5`, `glm-5.1`, `glm-5-turbo`, `glm-4-plus`
- **Cursor (独立 CLI)**: `cursor`

**路由机制 (`routeAgent`)：**
- Claude 模型 → `agent()` 直连
- 外部模型 (gpt/deepseek/gemini/glm 等) → haiku 桥接 agent → opencode tmux (统一网关，有文件系统访问)
- Cursor → haiku 桥接 agent → cursor CLI tmux

**覆盖优先级**（从低到高）：
1. Workflow 内置默认值 (`AGENT_MODEL_DEFAULTS`)
2. `.loopos/agent-models.json` 文件配置
3. `args.agent_models` 运行时覆盖
4. `args.model_overrides` 按任务覆盖（仅 developer/debugger）

**特殊值 `auto`**：developer 和 debugger 设为 `auto` 时，使用 Planner 分配的任务模型。

```javascript
// 运行时覆盖 — 多模型混用
Workflow({ name: 'supervisor-worker', args: {
  request: '...',
  agent_models: {
    analyst: 'gpt-5.4-pro',
    critic: 'claude-opus-4-6',
    'tester-logic': 'deepseek-v4-pro',
    verifier: 'gemini-2.5-pro'
  }
}})
```

## 工作流程

### 完整流水线（含 deep-interview）

```
用户: "我想做一个 XXX 功能"
  │
  ▼
Supervisor: Workflow({ name: 'deep-interview', args: { request: '...' } })
  │
  ├─ Phase Initialize: 探测项目上下文
  ├─ Phase Interview: 苏格拉底式提问 (每次一个问题，瞄准最弱维度)
  │   ├─ Round 0: 枚举组件拓扑
  │   ├─ Round 1-N: 目标/约束/标准/上下文 提问
  │   ├─ 每轮打分: ambiguity = 1 - weighted(dimensions)
  │   └─ 直到 ambiguity ≤ threshold (默认 20%)
  └─ Phase Crystallize: 生成规格 → .loopos/specs/deep-interview-xxx.md
  │
  ▼
Supervisor: Workflow({ name: 'supervisor-worker', args: { request: '...', spec: '...' } })
  │
  ├─ Phase Init:
  │   └─ git checkout -b feat/xxx
  │
  ├─ Phase Plan:
  │   ├─ Analyst 预检 (基于 spec)
  │   ├─ Planner 拆任务 + 模型分配
  │   └─ Critic 审查计划 (≥3 tasks 时)
  │
  ├─ Phase Dev-Test Loop (per layer):
  │   ├─ Developer (worktree/tmux) → commit
  │   ├─ parallel(Tester-Logic, Tester-Quality, Code-Reviewer)
  │   ├─ if failed → Debugger 修复 (max 3)
  │   └─ Merge Agent → feat/xxx
  │
  ├─ Phase Verify:
  │   └─ Verifier 全局验证 (测试+构建+验收标准)
  │
  └─ Phase Persist:
      └─ 更新状态 + commit → Ready for PR
```

### 简化流水线（需求明确时）

```
Supervisor: Workflow({ name: 'supervisor-worker', args: { request: '很明确的需求' } })
```

跳过 deep-interview，直接进入 supervisor-worker。

### Git 分支模型

```
main ─────────────────────────────────────────────────
  │
  └─ feat/add-wechat-pay  (Init 创建)
       │
       ├─ worktree/t1  ──commit──┐  (Layer 1, 并行)
       ├─ worktree/t2  ──commit──┤
       │                         ▼
       ├───── merge t1,t2 ◄──────┘
       │
       ├─ worktree/t3  ──commit──┐  (Layer 2, 依赖 t1)
       │                         ▼
       ├───── merge t3 ◄─────────┘
       │
       └───── [loopos] update state  (Persist)
              ↓
        Ready for PR → main
```

## 连续工作模式

```
第1轮: Workflow → state.json 记录 {completed_tasks: ["t1","t2","t3"]}
第2轮: Workflow → Planner 读取 state.json → 规划增量任务
第3轮: Workflow → Developer 读取 lessons.jsonl → 避免之前的错误
```

## 异常处理

| 情况 | 处理 |
|------|------|
| Workflow 执行出错 | 读取 .loopos/events.jsonl 最后几行 |
| 任务需要人工介入 | 读取 .loopos/manual_review_needed.json |
| Critic 拒绝计划 | 自动重新规划一次 |
| Verifier 不通过 | 标记到 manual_review_needed |
| tmux worker 超时 | 默认 600s，可配置 LOOPOS_WORKER_TIMEOUT |
| tmux worker 崩溃 | status 返回 "crashed"，升级到 Claude 原生模型 |
