LoopOS / AxiomOS PRD v1.0
1. 🧠 产品定义
1.1 产品名称
LoopOS（推荐）
AxiomOS（可作为商业品牌）
1.2 产品定位

LoopOS 是一个 AI Task Execution Operating System（AI任务执行操作系统）

它的本质不是 AI 编程工具，而是：

把 LLM 变成无状态 Worker，由系统调度执行任务

1.3 核心问题

当前 Claude Code / Codex / Cursor Agent 的问题：

❌ 上下文过长 → compact
❌ 单 Agent 长时间运行 → 状态膨胀
❌ Memory 在 prompt 中 → 不稳定
❌ 无任务调度 → 线性执行
❌ 无结构化状态 → 不可控
1.4 LoopOS 解决方案
Worker 短生命周期（1 task = 1 process）
Memory 外置（Event + Summary + Git）
Context 动态构建（Context Builder）
Supervisor 统一调度
Git Worktree 作为执行隔离层
2. 🧱 系统架构（MVP）
User
 │
 ▼
Supervisor (Node.js)
 │
 ├── Planner (LLM)
 ├── Scheduler
 ├── Memory Engine
 ├── Context Builder ⭐
 │
 ▼
Worker Manager
 │
 ├── Claude Code Adapter
 ├── Codex Adapter
 ├── OpenCode Adapter
 │
 ▼
Execution Layer
 ├── Git Worktree
 ├── File System
 ├── Test Runner
 │
 ▼
Result Normalizer
 │
 ▼
Event Store (JSONL)
3. 🧩 核心模块需求
3.1 Supervisor（系统核心）
职责
接收用户任务
调用 Planner 拆解任务
调度 Worker
更新 Memory
管理 Task 生命周期
输入
{
    "request": "新增微信支付"
}
输出
{
    "tasks": [
    "design api",
    "implement service",
    "write tests"
    ]
}
约束
❌ 不允许写代码
❌ 不允许直接调用 LLM 做实现
✔ 只做调度
3.2 Planner（一次性 LLM）
职责

把需求拆成 DAG

输入
user request
project summary
输出
{
  "tasks": [
    {
      "id": "t1",
      "title": "设计支付API",
      "depends_on": []
    },
    {
      "id": "t2",
      "title": "实现支付服务",
      "depends_on": ["t1"]
    }
  ]
}
特点
stateless
one-shot
no memory
3.3 Scheduler（任务调度器）
职责
管理 task queue
处理依赖 DAG
分配 worker
输入
tasks[]
输出
task → worker assignment
规则
允许并行 task
必须满足 dependency
3.4 Context Builder ⭐（核心模块）
职责

生成 Worker Prompt（控制在 10k~20k tokens）

输入
{
  "task": "implement payment",
  "task_id": "t2"
}
输出
SYSTEM CONTEXT:

1. Project Summary
2. Architecture snapshot
3. Related code files
4. Git history (recent changes)
5. Event history
6. Task constraints
数据来源
1. Git
git log -n 5 payment.ts
2. Event Store
events.jsonl
3. Memory Summary
architecture.json
decisions.json
4. Code Index (optional MVP+)
file tree
dependency map
设计原则
❌ 不给全项目
✔ 只给 task 相关 2%
✔ 可追溯
✔ 可压缩
3.5 Worker Manager
职责
spawn process
kill process
capture output
Worker 生命周期
start → execute → output → exit
输入
{
    "task": "...",
    "context": "..."
}
输出
{
    "summary": "",
    "files_changed": [],
    "patch": ""
}
3.6 Worker Adapter Layer
统一接口
interface WorkerAdapter {
    run(task, context): Promise<Result>
}
实现
Claude Adapter
claude --print
Codex Adapter
codex exec
OpenCode Adapter
POST /run
3.7 Execution Layer（沙箱）
职责
git worktree isolation
file changes
test execution
结构
repo/
 ├── main/
 ├── worker_001/
 ├── worker_002/
规则
每个 worker 一个 branch
不允许共享 state
3.8 Memory Engine（MVP版）
设计原则

不存聊天，只存事实

数据结构
events.jsonl（核心）
{"type":"task_created"}
{"type":"worker_started"}
{"type":"file_changed"}
{"type":"task_completed"}
summaries.json
{
  "payment_module": "...",
  "user_module": "..."
}
decisions.json
{
  "use_strategy_pattern": true
}
3.9 Result Normalizer
输入

worker output

输出标准化
{
  "summary": "",
  "files": [],
  "decisions": [],
  "risks": []
}
4. 🔁 完整执行流程（MVP）
User Request
 ↓
Supervisor
 ↓
Planner (LLM)
 ↓
Task DAG
 ↓
Scheduler
 ↓
Context Builder ⭐
 ↓
Worker Adapter
 ↓
Execution (Git Worktree)
 ↓
Result Normalizer
 ↓
Memory Engine (append event)
 ↓
Git merge
5. 📁 项目结构（建议直接照抄）
loopos/
 ├── supervisor/
 ├── planner/
 ├── scheduler/
 ├── context/
 │    ├── builder.ts
 │    ├── retriever.ts
 ├── worker/
 │    ├── manager.ts
 │    ├── adapters/
 │         ├── claude.ts
 │         ├── codex.ts
 │         ├── opencode.ts
 ├── memory/
 │    ├── event_store.ts
 │    ├── summary_store.ts
 ├── git/
 │    ├── worktree.ts
 ├── execution/
 │    ├── sandbox.ts
 ├── api/
 ├── types/
6. 🚀 MVP验收标准（非常重要）
必须满足：
✔ 系统能力
能执行一个 coding task
自动拆任务
自动调 worker
✔ Worker能力
每个 task = 1 process
自动退出
不依赖 chat history
✔ Memory能力
event store 可回放
summary 可更新
不超过 20k context
✔ Git能力
worktree隔离
自动 commit
自动 merge
✔ LLM能力
Claude / Codex 可切换
不影响系统结构
7. ⚠️ MVP风险点
1. Context Builder 做成聊天历史 ❌

→ 必须结构化

2. Worker 太聪明 ❌

→ Worker 只能执行

3. Memory 无限增长 ❌

→ 必须 summary + event

4. Git 没隔离 ❌

→ 必须 worktree

8. 💡 产品本质总结

一句话：

LoopOS 是一个把 LLM 从“有状态聊天系统”变成“无状态任务执行器”的操作系统。