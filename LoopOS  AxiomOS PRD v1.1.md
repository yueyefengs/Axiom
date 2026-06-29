# LoopOS / AxiomOS PRD v1.1

## 0. 文档目标

这不是对 `v1.0` 的润色版，而是一次 **MVP 收口**。

目标只有一个：

> 把 LLM 从“持续聊天的编程助手”变成“可调度、可回放、可终止的短生命周期 Worker”。

`v1.1` 的原则是：

- 保留方向
- 砍掉过大的首发范围
- 把最容易失控的部分改成确定性设计

---

## 1. 产品定义

### 1.1 产品名称

- 内部产品名：`LoopOS`
- 商业品牌名：`AxiomOS`

### 1.2 产品定位

LoopOS 是一个 **AI Task Execution Runtime**。

它不是新的聊天 IDE，也不是新的大模型。

它是一个调度层，负责：

- 接收任务
- 拆分任务
- 构建上下文
- 启动短生命周期 Worker
- 校验结果
- 记录项目进展

### 1.3 核心问题

当前 Codex / Claude Code / Cursor Agent 在长任务中的常见问题：

- 上下文越聊越长，最终触发 compact 或质量下降
- 单 Agent 长时间运行，状态污染严重
- 关键记忆存在 prompt 里，不是结构化状态
- 任务执行是线性的，不利于调度和恢复
- 失败后缺少可回放的系统状态

### 1.4 核心结论

真正要“长期存在”的不应该是 Worker 会话，而应该是系统状态。

因此：

- Worker 是短生命周期的
- 状态是外置且结构化的
- 主程序不参与编程，只参与调度与状态管理

---

## 2. 设计原则

### 2.1 短生命周期优先

- `1 task = 1 worker process`
- Worker 完成、失败或阻塞后必须退出
- 不依赖长聊天历史续命

### 2.2 主控不写代码

Supervisor 不能直接做实现，只能：

- 分派
- 记录
- 校验
- 决策是否重规划

### 2.3 结构化状态优先于聊天记忆

系统真相源必须是结构化状态，而不是“上一轮聊了什么”。

### 2.4 先确定性，后智能化

MVP 优先使用：

- 明确的状态机
- 明确的任务契约
- 明确的检索链

而不是一开始就依赖“一个很聪明的总 Agent”。

### 2.5 Boring Tech

MVP 尽量使用简单、稳定、可调试的方案：

- Node.js
- SQLite
- JSONL 审计日志
- Git worktree
- 单机场景

---

## 3. 非目标（MVP 明确不做）

以下内容 **不在 v1.1 MVP 范围内**：

### 3.1 不做多后端首发

不同时支持 Claude / Codex / OpenCode 三套生产级执行链。

MVP 只选一个 Worker Backend 首发，推荐 `Codex Adapter`。

### 3.2 不做自动并行 DAG 编排

MVP 默认串行执行。

只有在任务被显式标注为独立且模块不重叠时，后续版本才允许并发。

### 3.3 不做完全自动 merge 到主分支

MVP 只合并到集成分支或输出待审核变更。

默认保留人工审核闸门。

### 3.4 不做聊天历史型 Memory

不保存完整对话作为主记忆层。

只保留：

- 事件
- 决策
- 摘要
- 构件

### 3.5 不做分布式/多租户/云平台

MVP 只解决：

- 单用户
- 单仓库
- 单机
- 本地执行

---

## 4. MVP 范围

## 4.1 必须解决的问题

MVP 必须证明下面这件事成立：

> 对一个真实代码仓库，系统可以把用户需求拆成任务，给每个任务生成有限上下文，启动独立 Worker 完成修改，记录结果，并在失败后进入重规划或人工接管。

### 4.2 支持的任务类型

首发只支持中小型 coding task：

- bug fix
- 小型重构
- 单模块功能补充
- 测试补齐

暂不支持：

- 跨系统大改造
- 多仓库协同
- 长周期产品规划

### 4.3 首发后端选择

`v1.1` 推荐首发：

- Worker Backend: `Codex Adapter`
- 运行方式：`codex exec`

原因：

- 更适合非交互脚本化执行
- 更容易由主控进程统一调度
- 后续仍可保留 Adapter 接口，为 Claude Code 预留扩展位

---

## 5. 系统架构（MVP）

```text
User
 │
 ▼
Supervisor CLI / API
 │
 ├── Planner / Replanner
 ├── Scheduler
 ├── Context Builder
 ├── Validation Gate
 └── Merge Gate
 │
 ▼
Worker Manager
 │
 └── Codex Adapter
      └── codex exec
 │
 ▼
Execution Layer
 ├── Git Worktree
 ├── File System
 ├── Test Runner
 └── Artifact Writer
 │
 ▼
State Layer
 ├── SQLite (authoritative state)
 ├── events.jsonl (append-only audit)
 └── summaries/ decisions/ artifacts
```

### 5.1 架构结论

- 真正的核心不是 Planner，而是 `Context Builder + State Layer`
- Worker 只是执行器
- 主程序的价值在于“知道现在发生了什么”

---

## 6. 核心模块

## 6.1 Supervisor

### 职责

- 接收用户请求
- 触发 Planner
- 创建任务状态
- 启动/停止 Worker
- 接收执行结果
- 决定校验、重规划、人工接管

### 输入

```json
{
  "request": "为支付模块增加微信支付并补齐测试"
}
```

### 输出

```json
{
  "run_id": "run_001",
  "status": "planned",
  "tasks": ["t1", "t2", "t3"]
}
```

### 约束

- 不允许直接写代码
- 不允许持有长聊天记忆作为核心状态
- 不允许绕过任务状态机直接合并结果

---

## 6.2 Planner / Replanner

### 目标

把用户请求拆成 **可执行、可校验、可重试** 的任务。

### 输入

- user request
- project summary
- existing decisions
- latest blocked/failed result（若有）

### 输出

```json
{
  "tasks": [
    {
      "id": "t1",
      "title": "设计支付入口与接口边界",
      "depends_on": [],
      "module_scope": ["payments/"],
      "done_when": [
        "接口定义已落盘",
        "不修改业务逻辑"
      ]
    },
    {
      "id": "t2",
      "title": "实现微信支付服务",
      "depends_on": ["t1"],
      "module_scope": ["payments/"],
      "done_when": [
        "代码通过单元测试"
      ]
    }
  ]
}
```

### 设计要求

- 任务必须带 `done_when`
- 任务必须带 `module_scope`
- 任务失败后允许由 Replanner 重新拆分

### 不做的事

- 不要求 Planner 一次拆对所有任务
- 不把 Planner 当长期记忆体

---

## 6.3 Scheduler

### MVP 策略

默认串行。

只有满足以下条件，未来版本才允许并发：

- 无依赖关系
- `module_scope` 不重叠
- 不共享迁移、配置、公共类型等高冲突目录

### 调度输出

```json
{
  "task_id": "t2",
  "strategy": "sequential",
  "worker_backend": "codex",
  "worktree_id": "wt_t2"
}
```

### 设计结论

MVP 先解决“可靠执行一个任务链”，不先解决“聪明地并发很多任务”。

---

## 6.4 Context Builder（MVP 核心）

### 目标

为单个 Worker 构建 **有限、相关、可追溯** 的上下文。

### 约束

- 总预算控制在 `10k ~ 20k tokens`
- 不能把全项目直接塞给 Worker
- 不能把聊天历史直接当上下文

### 输入

```json
{
  "task_id": "t2",
  "title": "实现微信支付服务",
  "module_scope": ["payments/"]
}
```

### 输出结构

```text
SYSTEM CONTEXT

1. Task Brief
2. Project Summary
3. Relevant Files
4. Related Decisions
5. Recent Events
6. Recent Git Changes
7. Constraints
8. Validation Requirements
```

### MVP 检索链

`v1.1` 不做向量检索，不做智能全库索引。

MVP 采用确定性检索：

1. 任务标题和关键词归一化
2. 根据 `module_scope` 选主目录
3. `rg` 命中相关符号/关键词的文件
4. 补充 import / dependency 邻居文件
5. 补充最近 Git 改动文件
6. 读取相关 decision / summary / event
7. 按 token budget 截断并生成最终 prompt

### Token Budget 建议

```text
Task Brief                10%
Project Summary           15%
Relevant Files            45%
Decisions + Events        15%
Constraints + Validation  15%
```

### 明确不做

- 不给全量文件树
- 不给全量聊天记录
- 不把“记忆检索”设计成黑盒

---

## 6.5 Worker Manager

### 职责

- 创建 worktree
- 启动 worker process
- 注入上下文
- 收集 stdout / stderr / patch / artifacts
- 超时后终止

### 生命周期

```text
create_worktree
  -> run_worker
  -> collect_output
  -> persist_artifacts
  -> exit
```

### 输出契约

```json
{
  "task_id": "t2",
  "status": "completed",
  "summary": "新增微信支付服务并补齐对应单元测试",
  "files_changed": [
    "payments/service.ts",
    "payments/service.test.ts"
  ],
  "patch_ref": "artifacts/t2.patch",
  "risks": [
    "依赖现有支付配置格式"
  ]
}
```

---

## 6.6 Worker Adapter

### 统一接口

```ts
interface WorkerAdapter {
  run(task: Task, context: BuiltContext): Promise<WorkerResult>;
}
```

### v1.1 只实现

- `CodexAdapter`

### 执行方式

- 使用非交互命令执行
- 由主控进程捕获退出码、输出、修改结果

### 后续可扩展

- `ClaudeCodeAdapter`
- `OpenCodeAdapter`

但这些不进入 MVP 交付要求。

---

## 6.7 Execution Layer

### 组成

- Git worktree
- 本地文件系统
- 测试执行器
- 构件目录

### 关键结论

`git worktree` 是 **工作区隔离**，不是完整安全沙箱。

因此 `v1.1` 中：

- 用 worktree 解决并行编辑和 Git 隔离
- 不把 worktree 误称为权限沙箱

如果未来需要更强隔离，再增加：

- Docker
- macOS sandbox
- 受限权限执行器

---

## 6.8 Validation Gate

### 目标

把“Worker 说自己完成了”变成“系统确认它完成了”。

### 校验内容

- 目标文件是否存在
- diff 是否为空
- 测试是否通过
- lint / typecheck 是否通过（若项目提供）
- 是否超出允许修改范围

### 输出状态

- `validated`
- `needs_repair`
- `needs_replan`
- `needs_human`

### 设计原则

不把修复逻辑塞回同一个长会话。

如果需要修复，应创建新的 repair task，再启动新的 Worker。

---

## 6.9 Merge Gate

### v1.1 默认策略

- 不直接自动合并到 `main`
- 先合并到集成分支或输出待审补丁
- 保留人工批准闸门

### 自动化前提

只有满足以下条件，后续版本才考虑自动 merge：

- Validation Gate 全绿
- 变更范围小
- 无冲突
- 无高风险目录变更

---

## 6.10 Memory Engine

### 设计原则

不存聊天，存系统事实。

### Authoritative State

MVP 采用 `SQLite` 作为主状态库：

- `runs`
- `tasks`
- `workers`
- `artifacts`
- `decisions`
- `summaries`

### Audit Log

同时写入 `events.jsonl`：

```json
{"type":"run_created","run_id":"run_001"}
{"type":"task_created","task_id":"t1"}
{"type":"worker_started","task_id":"t1"}
{"type":"worker_completed","task_id":"t1"}
{"type":"validation_passed","task_id":"t1"}
```

### Summary 层

Summary 不是系统真相源，只是压缩视图：

- `project_summary.md`
- `module_summaries/*.md`
- `decisions.json`

### Memory 分层

```text
L1: SQLite state        -> 真相源
L2: JSONL events        -> 审计与回放
L3: Summaries/decisions -> 压缩阅读层
```

---

## 7. 任务状态机

```text
requested
  -> planned
  -> ready
  -> running
  -> completed
  -> validating
  -> validated
  -> merged

running
  -> blocked
  -> failed

blocked / failed
  -> needs_replan
  -> replanned
  -> ready

validated
  -> needs_human
  -> approved
  -> merged
```

### 必须支持的状态

- `blocked`
- `failed`
- `needs_replan`
- `needs_human`

这是 `v1.0` 里缺失但 MVP 必须有的闭环。

---

## 8. 进程间通信设计

### 目标

主程序永远不参与编程，但必须知道项目进展。

### 通信方式

MVP 采用持久化文件 + SQLite 状态更新：

- `state.db`
- `events.jsonl`
- `artifacts/<task_id>/result.json`
- `artifacts/<task_id>/stdout.log`
- `artifacts/<task_id>/stderr.log`
- `artifacts/<task_id>/patch.diff`

### 设计原则

- 进程间通信优先可落盘、可回放
- 不依赖内存态消息作为唯一真相源
- 允许 supervisor 重启后恢复

---

## 9. 目录结构建议

```text
loopos/
 ├── apps/
 │   └── supervisor/
 ├── packages/
 │   ├── planner/
 │   ├── scheduler/
 │   ├── context-builder/
 │   ├── worker-runtime/
 │   ├── adapters/
 │   │   └── codex/
 │   ├── validation/
 │   ├── memory/
 │   ├── git/
 │   └── shared/
 ├── artifacts/
 ├── state/
 │   ├── state.db
 │   └── events.jsonl
 └── docs/
```

### 说明

相比 `v1.0`，这里故意少做目录拆分。

先围绕执行链拆包，而不是围绕抽象概念拆包。

---

## 10. 完整执行流程（MVP）

```text
1. User 提交需求
2. Supervisor 创建 run
3. Planner 生成 task list
4. Scheduler 选出下一个 ready task
5. Context Builder 生成该 task 的有限上下文
6. Worker Manager 创建 worktree
7. Codex Adapter 启动 worker
8. Worker 输出 patch / summary / risks
9. Validation Gate 执行测试与范围校验
10. 通过:
      -> 写入 state + event
      -> 等待人工批准 / 合并到集成分支
11. 未通过:
      -> 标记 needs_repair 或 needs_replan
12. 若 blocked / failed:
      -> Replanner 重新拆任务
13. 全部任务完成:
      -> 更新 project summary
```

---

## 11. MVP 验收标准

### 11.1 系统能力

- 能接收一个真实 coding request
- 能拆成至少两个任务
- 能完成至少一个任务的独立执行

### 11.2 Worker 能力

- 每个 task 启动独立进程
- 执行完成后自动退出
- 不依赖长聊天历史

### 11.3 状态能力

- 所有任务状态可查询
- Supervisor 重启后可恢复
- events 可回放

### 11.4 Context 能力

- 单次上下文不超过 20k tokens
- 上下文可追溯到具体文件、事件、决策

### 11.5 Git 能力

- 每个任务使用独立 worktree
- 能产出 patch / commit
- 不直接污染主工作区

### 11.6 校验能力

- 能自动跑测试或至少执行配置好的验证命令
- 校验失败时不会直接 merge

### 11.7 调度能力

- Worker 失败后能进入 `needs_replan` 或 `needs_human`
- 不会因为一个 Worker 失败导致整次 run 状态丢失

---

## 12. 风险与缓解

### 风险 1：Context Builder 仍然退化成聊天摘要

#### 后果

- 上下文不可控
- 相关性越来越差
- compact 问题换了个外壳继续出现

#### 缓解

- 先做确定性检索链
- 先做 token budget
- 先做 file/event/decision 可追溯性

### 风险 2：主控偷偷变成“大总 Agent”

#### 后果

- 状态重新回到 prompt
- 系统不可调试

#### 缓解

- Supervisor 禁止直接实现任务
- 任何代码修改都必须经过 Worker

### 风险 3：状态只在 JSONL，后期难查询

#### 后果

- 很难做恢复、筛选、统计

#### 缓解

- SQLite 做主状态库
- JSONL 只做审计和导出

### 风险 4：过早并发导致冲突地狱

#### 后果

- merge 冲突频繁
- 验证链变复杂

#### 缓解

- MVP 默认串行
- 并发后置

### 风险 5：自动 merge 误伤主分支

#### 后果

- 主分支被低质量改动污染

#### 缓解

- MVP 保留人工闸门
- 自动 merge 不进入首发范围

---

## 13. 里程碑建议

### Milestone 1：单任务执行闭环

交付：

- Supervisor
- Codex Adapter
- Worktree 创建
- 单任务运行
- 结果落盘

### Milestone 2：结构化状态闭环

交付：

- SQLite state
- events.jsonl
- 任务状态查询
- run 恢复

### Milestone 3：Context Builder MVP

交付：

- module_scope 检索
- rg 命中
- Git 最近变更
- decision / summary 注入

### Milestone 4：验证与重规划

交付：

- Validation Gate
- blocked / failed / needs_replan
- Replanner

### Milestone 5：人工批准与集成分支合并

交付：

- Merge Gate
- 审批状态
- 集成分支写入

---

## 14. v1.1 的产品本质

一句话：

> LoopOS 不是“让一个 Agent 一直聊下去”，而是“让很多短生命周期 Worker 在结构化状态之上接力工作”。

再具体一点：

> Worker 负责做事，Supervisor 负责记账，Context Builder 负责只给它做这件事需要知道的东西。

---

## 15. v1.2+ 方向（明确后置）

这些方向保留，但不进入 MVP：

- Claude Code Adapter
- 多后端路由
- 智能代码索引
- 并行 DAG 调度
- Docker / VM 级沙箱
- Web UI
- 多仓库支持
- 向量检索 Memory
- 自动 merge 策略

---

## 16. 最终决策摘要

### 保留

- 短生命周期 Worker
- 外置 Memory
- Context Builder
- Supervisor 调度
- Git worktree 隔离

### 调整

- MVP 改为单 backend
- 调度改为默认串行
- 状态主库改为 SQLite
- merge 改为默认人工批准
- 增加 replanning 闭环

### 删除或后置

- 多后端同时首发
- 全自动 merge
- 聊天历史型 memory
- 把 worktree 当完整沙箱
- 过早并发
