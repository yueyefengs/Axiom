# LoopOS / Axiom 代码审计 — 验证后结论

> 本文件是对 `review.md`（含外部 reviewer 6 条结论 + 此前 A1-A7/B1-B8）的**逐条原文核实**结果。
> 验证方式：重新读取每条结论引用的文件与行号，独立判断成立 / 部分成立 / 不成立，并修正表述不精确之处。
> 验证日期：2026-06-29。范围：架构合理性与正确性（个人项目标准，不含注入类安全问题）。

---

## 优先级总览

| 优先级 | 编号 | 标题 | 验证结论 |
|---|---|---|---|
| **P0** | C1 | DAG 无运行时依赖门控 + 孤儿任务静默丢弃 | ✅ 成立（此前盲点） |
| **P0** | C2 | dev-test-fix 循环 worktree 隔离断裂 | ✅ 成立（合并原结论2 + A2） |
| **P0** | C3 | verify FAIL 不影响 passed，验证形同虚设 | ✅ 成立 |
| **P0** | C4 | 用非确定性 LLM 执行确定性编排（外部模型链路） | ✅ 成立 |
| **P1** | H1 | PRD 承诺 SQLite+events 真相源，实现是散落 JSON | ✅ 成立 |
| **P1** | H2 | Codex 编排器 grep 子串依赖 bug（t1/t10 混淆） | ✅ 成立 |
| **P1** | H3 | 三份模型真相源不一致 + 静默降级 | ✅ 成立 |
| **P1** | H4 | 状态机靠 LLM 维护，非确定性 | ✅ 成立 |
| **P2** | M1 | deep-interview 把"未澄清"伪装成"已澄清" | ✅ 成立 |
| **P2** | M2 | 同层并行 merge 必冲突 + "prefer incoming" 危险 | ✅ 成立 |
| **P2** | M3 | supervisor-resume 未被 init 复制，恢复能力默认缺失 | ✅ 成立 |
| **P2** | M4 | PROTOCOL 文档与实现脱节 | ✅ 成立 |
| **P3** | L1 | MAX_FIX_RETRIES off-by-one（实际 4 次） | ✅ 成立（两处同款） |
| **P3** | L2 | 未知/拼错的 Claude 模型名静默接受 | ✅ 成立 |
| **P3** | L3 | 桥接 agent 的 prompt 文件名含冒号 | ✅ 成立 |
| **P3** | L4 | Plan reader 多一次 LLM 调用 | ✅ 成立 |
| **P3** | L5 | deep-interview slug 中文碰撞 | ✅ 成立 |
| **P3** | L6 | iterative-fix 反馈截断可能丢失错误信息 | ✅ 成立 |

> **外部 reviewer 6 条结论全部核实成立**，其中结论2 的字面证据需修正（见 C2）。**结论1 是我上一轮审计的盲点**——此前 B2 只指出"孤儿任务丢弃"，未发现更严重的"失败依赖不门控"，本次核实后提升为 P0。

---

## P0 — Critical（核心流程跑不对，"假成功"风险）

### C1. DAG 无运行时依赖门控 + 孤儿任务静默丢弃
**来源**：原 review 结论1 + 此前 B2（合并，结论1 更全面）
**验证结论**：✅ 成立。**这是上一轮审计的盲点，本次修正。**

**证据**（`supervisor-worker-demo.js:570-597`）：
```js
const done = {}
while (remaining.length > 0) {
  const ready = remaining.filter(t => (t.depends_on || []).every(dep => done[dep]))
  if (ready.length === 0) { log('ERROR: circular dependency...'); break }  // 孤儿静默丢
  layers.push(ready)
  ready.forEach(t => { done[t.id] = true; ... })   // ← 分层阶段就标 done，不看执行结果
}
...
for (const layer of layers) {                        // ← :597 无条件逐层，无门控
  const layerResults = await pipeline(layer, ...)
  const passedInLayer = layerResults.filter(r => r.status === 'passed' && r.worktreeBranch)
  if (passedInLayer.length > 0) { /* merge */ }
  allResults.push(...layerResults)
}
```

**两个独立问题**：
1. **无运行时门控**：`done[t.id]=true` 在拓扑分层时就标记，执行循环 `for (layer of layers)` 不检查上一层是否真成功。**t1 执行失败（dev_failed/needs_manual_review）后，依赖它的 t2 照样跑**。t2 基于 featureBranch（不含 t1 未合并的改动）开发，读到的是没有 t1 成果的旧代码 → 实现错误。DAG 沦为"静态分层装饰"。
2. **孤儿静默丢弃**：`depends_on` 引用不存在的 task id（planner 笔误）→ 该任务永不 ready → `ready.length===0` → break，剩余任务静默消失，不报错、不标记失败。

**修复方向**：执行循环内增加门控——上一层有失败任务时，其下游任务标记 `blocked` 跳过并进 manual_review，而非继续执行；分层前校验所有 `depends_on` 引用的 id 存在。

---

### C2. dev-test-fix 循环 worktree 隔离断裂
**来源**：原 review 结论2 + 此前 A2（合并）
**验证结论**：✅ 成立，但**原结论字面证据不精确，需修正**。

**对原结论2 的修正**：
- 原文说"代码里没有 `git worktree add`，也没有为每个任务显式建隔离分支"——**这部分不准确**。`executeWithExternal` 调用处（`:638, :767`）传了 `isolation: 'worktree'`，由 Claude Code harness 隐式创建 worktree + 独立分支，桥接 agent 返回的 `git branch --show-current`（`:325`）即该 worktree 分支。代码无需显式 `git worktree add`。
- 但原结论的**实质担忧成立**，体现在两处：

**实质问题1 — fix 循环 worktree 断裂**（`supervisor-worker-demo.js:600-785`）：
- Stage1 dev：`isolation: 'worktree'` → 在 worktree **W1** 提交，返回 W1 分支。
- Stage2 fix：`isolation: 'worktree'`（`:759, :767`）→ 开**新** worktree **W2**。
- W2 基于 `origin/main` 或当前 HEAD（featureBranch），而 dev 的提交仍在 W1 分支上、尚未 merge 回 featureBranch（merge 在整层结束后 `:790` 才发生）。**W2 看不到 dev 的改动** → fix agent 在干净 base 上"修"，与 dev 成果脱节，修复循环基本空转。

**实质问题2 — 外部路径隔离可靠性存疑**：外部模型路径 = 桥接 haiku agent（worktree）+ 它 spawn 的 tmux 子进程（workdir `.`）。tmux 是独立 shell 进程，其 cwd 是否真的落在桥接 agent 的 worktree 内，依赖 harness 对 `isolation:worktree` 下子进程 cwd 的处理，静态代码无法 100% 确认。README:40 "Worker 在独立 worktree 中工作" 对外部模型路径是否成立需运行时验证。注意 PROTOCOL:135 其实**只承诺 Claude 原生用 worktree**，外部模型（:136）只说"完整文件系统访问"——文档自身就不一致。

**修复方向**：fix 阶段不开新 worktree（在同 worktree 继续），或 dev 完成立即 merge 回 featureBranch 再 fix。二选一，当前两不靠。

---

### C3. verify FAIL 不影响 passed 状态，验证形同虚设
**来源**：此前 B1
**验证结论**：✅ 成立。

**证据**（`supervisor-worker-demo.js:832-859`）：
```js
if (passed.length > 0) {
  const verifyResult = await routeAgent(... /* verifier */)
  log(`Verification: ${verifyResult.verdict} ...`)
  if (verifyResult.verdict === 'FAIL') {
    log('Verification FAILED. Check .loopos/reports/verify_final.json')  // ← 只 log
  }
}
// Persist 阶段（:877）仍把 passed 列表计入 state.completed_tasks 并 commit
```
verify 返回 FAIL 时**不修改 passed 列表、不写 manual_review**。Persist 仍把 passed 任务计入 `completed_tasks` 并报告 "Ready for PR"。**全局验证失败的任务照样被记为完成**。Codex 版同款（`codex-version/scripts/supervisor.sh:339-344`，verify 不通过只 warn，Persist `:352-364` 仍写入 state）。

**修复方向**：verify FAIL 时把对应任务移出 passed、写入 `manual_review_needed.json`，且 Persist 不将其计入 `completed_tasks`。

---

### C4. 用非确定性 LLM 执行确定性编排
**来源**：此前 A1
**验证结论**：✅ 成立。

**证据**（`supervisor-worker-demo.js:196-369` routeAgent / executeWithExternal；`iterative-fix.js:47-90`）：
`spawn → 轮询 status → collect → 读 stdout → 产出结构化结果` 这条本该用 JS `while` 循环确定性完成的流水线，被写成自然语言 WORKFLOW 交给 haiku 桥接 agent 执行。haiku 可能跳步、解析 session_id 错误、忘记 collect、提前放弃轮询。`iterative-fix.js:86` 连 `verify_cmd` 的 exit code 都靠 agent 自己 "note"——agent 漏跑或谎报则 `verify_passed` 不可信。

Workflow 脚本是 JS，有能力写 `while (status==='running') { await sleep }` 确定性轮询，却选择了"用 prompt 哄 LLM 跑 shell"。这是外部模型链路可靠性的根本薄弱点。

**修复方向**：JS 里写确定性轮询循环，LLM 只负责"理解 worker stdout 产出结构化结果"。

---

## P1 — High（架构承诺未兑现 / 状态不可信）

### H1. PRD 承诺 SQLite + events 真相源，实现是散落 JSON
**来源**：原 review 结论3
**验证结论**：✅ 成立。引用准确。

**证据**：
- PRD 承诺：`LoopOS  AxiomOS PRD v1.1.md:80`（结构化状态优先）、`:99`（Boring Tech 列 SQLite）、`:216-219`（架构图 State Layer: SQLite + events.jsonl）、`:571`（MVP 采用 SQLite 主状态库）、`:802-810`（风险3：SQLite 做主状态库）、`:927`（状态主库改为 SQLite）。
- 实际实现：`init-loopos.sh:64-77` 与 `codex-version/scripts/supervisor.sh:98-103` 只初始化 `state.json` / `decisions.json`（JSON）；`supervisor-worker-demo.js:877`、`supervisor-with-memory.js:196` 让 LLM 写 JSON；`codex-version/scripts/supervisor.sh:353` 用临时 python3 改写 JSON。**全程无 SQLite，无 .db 文件，无 sqlite 调用**；`events.jsonl` 也靠 LLM append（不可信）。

PRD 把"可回放、可恢复的结构化状态"作为核心论点（:53 "真正长期存在的应是系统状态"），实现却退回"让 agent 猜着维护 JSON"，恢复与回放不可信。

---

### H2. Codex 编排器 grep 子串依赖 bug（t1/t10 混淆）
**来源**：原 review 结论4
**验证结论**：✅ 成立。已读原文核实，引用准确。

**证据**（`codex-version/scripts/supervisor.sh:223, 230, 238`）：
```bash
echo "$COMPLETED" | grep -q "$tid" && continue        # :223 检查已完成
...
echo "$COMPLETED" | grep -q "$dep" || { all_deps_done=false; break; }  # :230 依赖检查
...
[ -z "$READY_TASKS" ] && break                         # :238 无 ready 即退出
```
`grep -q` 无单词边界，子串匹配。复现：`printf ' t10 ' | grep -q 't1'` 命中。两个方向都有 bug：
- :230 若 `COMPLETED="t10"`，检查 `dep="t1"` → `echo "t10" | grep -q "t1"` 命中 → **t1 误判已完成**（实际完成的是 t10），依赖 t1 的任务被错误放行。
- :223 若 `COMPLETED="t10"`，检查 `tid="t1"` → 同样命中 → **t1 误判已完成而跳过执行**。

:238 break 静默跳过：剩余任务若都依赖某个失败任务（失败任务不在 COMPLETED），永远不 ready → READY 空 → break → 被静默丢弃，不进 waiting/manual_review。

**修复方向**：用空格分隔的精确匹配（`grep -qw` 或数组 contains），或干脆用 python3 解析（脚本已依赖 python3）。

---

### H3. 三份模型真相源不一致 + 静默降级
**来源**：此前 A3
**验证结论**：✅ 成立。

**证据**：模型信息分散在三处独立维护——`models.json`（planner 读）/ `agent-models.json`（运行时读）/ `MODEL_REGISTRY`（`supervisor-worker-demo.js:93-144` 硬编码，路由用）。已发现不一致：

| 模型名 | models.json | MODEL_REGISTRY 实际路由 |
|---|---|---|
| `codex` | gpt-5.4-pro (codex CLI) | opencode `openai/o3` |
| `glm-5.2` | 存在（agent-models.json 示例也用） | **不存在** → fallback sonnet |
| `glm` | model_id `glm-5.2` | opencode `zhipuglm/glm-5` |

失败模式：`lookupModel` 返回 null 时，`routeAgent:200` 和 `executeWithExternal:290` **静默 fallback 到 sonnet**，不抛错、不告警。对以"多模型混用省钱"为卖点的系统，这意味着"以为在用 deepseek 省钱，实际在烧 sonnet，且无人告知"。`models.json` 的 `auto_assignment`/`defaults`/`cost_per_1k`/`context_window` 字段无任何代码消费，纯装饰。

**修复方向**：单一真相源（MODEL_REGISTRY），未知模型名直接抛错而非降级。

---

### H4. 状态机靠 LLM 维护，非确定性
**来源**：此前 A6（与 H1 互补：H1 讲 PRD 偏离，H4 讲实现脆弱）
**验证结论**：✅ 成立。

**证据**：`state.json` / `events.jsonl` / `current_plan.json` / `lessons.jsonl` 的读写全部由 agent 按自然语言指令完成（`supervisor-worker-demo.js:877` Persist、developer "append lesson" 等）。LLM 可能写错格式、覆盖而非 append、漏字段。`state.json` 模板有 `last_updated` 字段但 Persist prompt 没要求更新它。根因是 Workflow 脚本无 fs 访问（harness 限制），只能靠 agent。

**修复方向**：关键状态（completed_tasks、total_tasks_run）由 JS 通过 agent 的结构化返回值拼装，配严格 schema + 读回校验，而非让 agent 自由写文件。

---

## P2 — Medium（正确性细节 / 文档不一致）

### M1. deep-interview 把"未澄清"伪装成"已澄清"
**来源**：原 review 结论5 + 此前 A5（合并）
**验证结论**：✅ 成立。引用准确。

**证据**（`deep-interview.js:146, 185-189, 241`）：
- `:146` 拓扑问题自动记为 `[topology confirmed by proceeding]`。
- `:187-189` answer 来自 `args.answers[round]`，否则填 `[Pending user answer for round N]`。workflow 后台运行，主会话不在线，`args.answers` 永远为空。
- `:241` Crystallize 基于含占位符的 transcript 生成正式 spec。

把"未澄清"伪装成"已澄清"，对后续 planner 是误导。这是把需要人机交互的 interview 错放进异步后台 workflow——设计上跑不通。

---

### M2. 同层并行 merge 必冲突 + "prefer incoming" 危险
**来源**：此前 A4
**验证结论**：✅ 成立。

**证据**（`supervisor-worker-demo.js:787-816`）：同层多任务基于同一 base 在各自 worktree 并行，planner 只约束"每任务 3-5 文件"，不保证不重叠 → touch 同一文件必冲突。merge prompt（`:807`）写 "prefer incoming branch's changes"——后合并的覆盖先合并的，可能静默回退前一个任务的改动。冲突解决交给未指定 model 的普通 agent，无冲突检测/升级机制。

---

### M3. supervisor-resume 未被 init 复制，恢复能力默认缺失
**来源**：原 review 结论6
**验证结论**：✅ 成立。引用准确。

**证据**：
- `README.md:170, 395-398, 770` 多处告诉用户中断后运行 `Workflow({ name: 'supervisor-resume', args: {} })`。
- `supervisor-with-memory.js:2` 的 `meta.name = 'supervisor-resume'`（文件名与 workflow name 不一致，但功能存在）。
- `init-loopos.sh:47` 只复制 `supervisor-worker-demo.js deep-interview.js PROTOCOL.md`，**不含 supervisor-with-memory.js**。

新项目 init 后，README 承诺的恢复 workflow 文件不存在，恢复能力默认缺失。

**修复方向**：init 脚本改为通配复制 `*.js`，或显式加入 `supervisor-with-memory.js`。

---

### M4. PROTOCOL 文档与实现脱节
**来源**：此前 A7
**验证结论**：✅ 成立。

**证据**：
- PROTOCOL 写"developer 3 次修复失败 → 升级到 architect"，代码里**没有 architect 升级**，只有 max retries → manual_review。
- PROTOCOL agent 表说 `developer: opus`，但 `agent-models.json` 与 `AGENT_MODEL_DEFAULTS` 都是 `developer: auto`。
- `architect` agent 定义存在（`.claude/agents/architect.md`），但 supervisor-worker 全流程**从未调用** architect。

文档作为"系统规格"不可信。

---

## P3 — Low（小 bug）

### L1. MAX_FIX_RETRIES off-by-one（两处同款）
**验证**：✅ 成立。`supervisor-worker-demo.js:593` 定义 `=3`，`:665` `for (attempt=0; attempt<=MAX_FIX_RETRIES; attempt++)` → 实际 4 次（1 dev + 3 fix）。Codex 版同款：`codex-version/scripts/supervisor.sh:265` `for attempt in $(seq 0 $MAX_FIX_RETRIES)` → 同样 4 次。

### L2. 未知/拼错的 Claude 模型名静默接受
**验证**：✅ 成立。`supervisor-worker-demo.js:152` `isClaude` fallback 正则 `/^(opus|sonnet|haiku|claude)/i` 会让任何以 `claude` 开头的字符串（如拼错的 `claude-opus-4-9`）被判 Claude → `toShorthand` 返回 `opus`。无效模型名不报错。

### L3. 桥接 agent 的 prompt 文件名含冒号
**验证**：✅ 成立。`supervisor-worker-demo.js:211` `safeLabel` 正则 `[^a-z0-9_:-]` 保留 `:`，label 形如 `test-logic:t1:0` → 文件名 `prompt_test-logic:t1:0.txt`。冒号在 macOS 上是路径分隔符别名，会触发错误或写到意外位置。

### L4. Plan reader 多一次 LLM 调用
**验证**：✅ 成立。`supervisor-worker-demo.js:538` 单独起 agent 读 `current_plan.json` 返回 tasks，本可由 planner 直接在 PLAN_SCHEMA 里返回。多一次 LLM 调用 = 多一次解析出错机会 + 成本。

### L5. deep-interview slug 中文碰撞
**验证**：✅ 成立。`deep-interview.js:235` slug 由 `args.request` 生成，`replace([^a-z0-9])` 删掉所有中文 → 中文需求 slug 为空 → 文件名 `deep-interview-.md`，多个中文需求互相覆盖。

### L6. iterative-fix 反馈截断可能丢失错误信息
**验证**：✅ 成立。`iterative-fix.js:89` `verify_output` 只取最后 2000 字符作为下一轮反馈。若关键错误信息在输出前部/中部，反馈丢失，worker 下一轮盲修。

---

## 总评

**外部 reviewer 的 6 条结论全部核实成立**，质量较高，尤其是结论1（DAG 无运行时门控）和结论4（Codex grep 子串 bug）指出了此前审计的盲点。结论2 的字面证据（"没有 git worktree add / 没有显式建分支"）不够精确，但实质问题成立，已在 C2 修正表述。

**最危险的不是单点 bug，而是 P0 四条的叠加效应**：
1. DAG 不门控失败依赖（C1）→ 上游失败下游照跑，基于错误基础实现；
2. worktree 修复循环断裂（C2）→ fix 看不到 dev 改动，修复空转；
3. verify 不拦失败（C3）→ 验证失败仍记为完成；
4. 编排靠 LLM 自觉（C4）→ 外部模型链路本身不可靠。

四者叠加的结果：**系统会以"看起来成功"的方式失败**——任务全跑完、state 记录完成、报告 Ready for PR，但实际依赖断裂、修复空转、验证没拦。这比报错危险得多。

**建议修复顺序**（个人项目，按性价比）：
1. **C1 + C3**：最小改动、最大收益——加运行时门控 + verify 拦截，堵住"假成功"。
2. **C2**：dev-test-fix 的 worktree 模型重做，主流程正确性核心。
3. **H2**：Codex grep 改 `grep -qw` 或 python3 解析，一行修复。
4. **H3**：单一模型真相源 + 未知模型抛错，防止"省钱变烧钱"。
5. **C4**：外部模型链路改 JS 确定性轮询，工作量最大但收益根本。
6. **M3**：init 脚本补复制 supervisor-with-memory.js，一行修复。
