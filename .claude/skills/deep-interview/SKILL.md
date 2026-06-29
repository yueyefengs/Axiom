---
name: deep-interview
description: 需求模糊时进行苏格拉底式访谈，逐维澄清 goal/constraint/criteria/context，输出 crystal-clear spec。触发：/deep-interview，或用户需求模糊、歧义高时。
---

# Deep Interview — 需求澄清

把模糊想法变成 crystal-clear spec。在**主会话**执行（不通过后台 workflow——后台 workflow 无法与人交互，会生成空 spec）。

## 4 维度清晰度模型

| 维度 | 含义 | 提问风格 |
|------|------|---------|
| goal | 要发生什么 | "具体发生什么？用户/系统的行为是？" |
| constraint | 边界/限制 | "硬性限制？性能/兼容/范围边界？" |
| criteria | 如何验证 | "怎样算成功？可测量的验收标准？" |
| context | 与现有代码集成（仅 brownfield） | "如何与 [file:line] 的现有实现集成？" |

## ambiguity 打分

每轮后评估各维度 0.0~1.0，计算 overall ambiguity：

- brownfield：`ambiguity = 1 - (goal*0.35 + constraints*0.25 + criteria*0.25 + context*0.15)`
- greenfield：`ambiguity = 1 - (goal*0.40 + constraints*0.30 + criteria*0.30)`

阈值默认 **20%**。ambiguity ≤ 阈值，或用户表示足够清晰，即止。

## 执行流程

1. **探测上下文**：判断 brownfield（有代码）/ greenfield（新项目），识别 tech stack 与相关文件。
2. **拓扑枚举**（Round 0）：枚举 1-6 个顶层组件，用 `AskUserQuestion` 请用户确认组件列表。
3. **逐维深挖**（Round 1-N）：每次用 `AskUserQuestion` 提**一个问题**，瞄准当前最弱维度：
   - 提供 2-4 个建议选项（applicable 时）
   - brownfield：引用 repo 证据（file:line）触发提问
   - Round ≥ 4：可用 contrarian 模式（"如果反过来呢？"）
   - Round ≥ 6：可用 simplifier 模式（"最简版本是什么？"）
   - 每轮后重新评估 ambiguity，记录 transcript
4. **结晶化**：ambiguity 达标后，输出 spec 到 `.loopos/specs/interview-<slug>.md`：

```
---
interview_id: di-<slug>
rounds: <N>
ambiguity: <0.xxx>
type: brownfield|greenfield
status: crystallized
---

## Goal
## Components（表：Component | Type | Description | Priority）
## Constraints
## Non-Goals
## Acceptance Criteria
## Technical Context
## Edge Cases
## Assumptions
## Interview Summary
```

## 关键约束

- **每次只问一个问题**（`AskUserQuestion` 单问题），瞄准最弱维度，不要一次问多个。
- **不替用户回答**——无答案时用 `AskUserQuestion` 问，绝不填占位符（如 "[Pending user answer]"）。
- spec 必须基于用户实际回答；未澄清的维度标注为 **Assumption**，而非假装已定。
- 完成后提示用户：
  ```
  Workflow({ name: 'supervisor-worker', args: { request: '...', spec: '.loopos/specs/interview-<slug>.md' } })
  ```

## 与原 deep-interview.js 的区别

原 deep-interview.js 是后台 workflow，`args.answers` 永空 → 生成空 spec 伪装已澄清。
本 Skill 在主会话执行，用 `AskUserQuestion` 真实交互，方法论（4 维度 + 打分 + 苏格拉底提问）保留。
打分从 JS 确定性改为 LLM 执行（打分本就主观，可接受）。
