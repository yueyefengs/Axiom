1. Critical 依赖 DAG 在 Claude 工作流里并没有被运行时正确执行。layers 是在执行前一次性拓扑分层时就把任务标成“done”的，.claude/
     workflows/supervisor-worker-demo.js:574 到 .claude/workflows/supervisor-worker-demo.js:587 完全不看真实执行结果；后面又无条件
     逐层执行 .claude/workflows/supervisor-worker-demo.js:597。这意味着 t1 失败后，依赖它的 t2 仍然会继续跑，DAG 只做了“静态分
     层”，没有做“运行时依赖门控”。

  2. Critical 文档承诺的“每个 Worker 独立 worktree、并行后再合并”在外部模型路径上并未真正实现。README 明确写了独立 worktree
     README.md:40，协议也把它当成核心隔离手段 .claude/workflows/PROTOCOL.md:135；但外部执行路径只是让桥接 agent 在当前仓库 . 下
     spawn worker .claude/workflows/supervisor-worker-demo.js:315，然后读 git branch --show-current .claude/workflows/supervisor-
     worker-demo.js:325。代码里没有 git worktree add，也没有为每个任务显式建隔离分支，但后面又假定这些任务有各自分支可
     merge .claude/workflows/supervisor-worker-demo.js:787。这会让“并行开发 + 层内合并”这个核心架构失真。

  3. High PRD 说 MVP 的真相源应是 SQLite + append-only events LoopOS  AxiomOS PRD v1.1.md:80 LoopOS  AxiomOS PRD v1.1.md:216，但实
     际实现只有散落的 JSON 文件初始化 init-loopos.sh:64 codex-version/init-codex.sh:55，持久化还依赖 LLM 或临时 Python 改
     写 .claude/workflows/supervisor-worker-demo.js:877 .claude/workflows/supervisor-with-memory.js:196 codex-version/scripts/
     supervisor.sh:353。这不是“结构化状态优先”，而是“让 agent 猜着维护状态”，恢复和回放都不够可信。

  4. High Codex 版编排器的依赖判断有确定性 bug。它把完成任务拼成字符串，再用 grep 判定依赖是否完成 codex-version/scripts/
     supervisor.sh:223 codex-version/scripts/supervisor.sh:230；t1 会匹配 t10，我本地用 printf ' t10 ' | grep -q 't1' 已能复现。再
     加上当没有 ready task 时直接 break codex-version/scripts/supervisor.sh:238，被失败任务阻塞的后续任务会被静默跳过，而不是进入
     waiting/manual-review 状态。

  5. Medium deep-interview 目前并不是真正的访谈流。它把拓扑问题自动记成“已确认” .claude/workflows/deep-interview.js:146，没有用户
     答案时就写占位符 [Pending user answer...] .claude/workflows/deep-interview.js:185，随后仍然据此生成正式 spec .claude/
     workflows/deep-interview.js:241。这会把“未澄清”伪装成“已澄清”，对后续 planner 是误导。

  6. Medium 安装产物和文档不一致。README 多次告诉用户中断后运行 supervisor-resume README.md:170，工作流本身也存在 .claude/
     workflows/supervisor-with-memory.js:2，但初始化脚本只复制 supervisor-worker-demo.js、deep-interview.js、PROTOCOL.md init-
     loopos.sh:47。新项目初始化后，文档里承诺的恢复能力默认是缺的。

     一、架构层面（合理性）

  🔴 A1. 核心矛盾：用"非确定性 LLM"执行"确定性编排"

  routeAgent / executeWithExternal（supervisor-worker-demo.js:196-369）把 spawn → 轮询 status → collect → 读 stdout →
  产出结构化结果 这条本该用 JS while 循环确定性完成的流水线，写成自然语言 WORKFLOW，交给一个 haiku 桥接 agent 去执行。

  这是整套"外部模型"链路的根本脆弱点：
  - haiku 可能跳步、把 session_id 解析错、忘记 collect、提前放弃轮询、或无意义地反复 poll。
  - Workflow 脚本明明有能力写 while (status==='running') { await sleep } 的确定性轮询（脚本是 JS），却选择了"用 prompt 哄 LLM 去跑
  shell"。
  - 同样的问题在 iterative-fix.js 里也有：spawn/resume/poll/verify 全靠桥接 agent 自觉执行，连 verify_cmd 的 exit code 都靠 agent
  自己"note"（iterative-fix.js:86）——agent 漏跑或谎报，verify_passed 就不可信。

  正确方向：JS 里写确定性轮询循环（bash tmux-worker.sh status 直到 completed/failed），LLM 只负责"理解 worker stdout
  并产出结构化结果"这一步。把编排还给代码，把语义理解留给模型。

  🔴 A2. dev-test-fix 循环的 worktree 模型是断裂的（严重）

  执行流程（supervisor-worker-demo.js:600-785）：
  1. Stage1 dev：isolation: 'worktree' → 在新 worktree W1 提交，返回 W1 的 branch。
  2. Stage2 修复循环：fix 也用 isolation: 'worktree'（:759, :767）→ 开新 worktree W2。

  问题：W2 的 base 是 origin/main 或当前 HEAD（featureBranch），而 dev 的提交还在 W1 的分支上、尚未 merge 回 featureBranch（merge
  在整层结束后 :790 才发生）。所以 W2 看不到 dev 刚做的改动——fix agent 在干净 base 上"修"，与 dev 成果完全脱节；test
  报告说"改了文件 X"，fix 去读 X 发现是旧的。

  结论：worktree 隔离与同任务多轮 fix 不兼容。要么 fix 在同一 worktree 继续（不开新 worktree），要么 dev 完成立即 merge 回
  featureBranch 再 fix。当前实现两不靠，修复循环基本是空转。这是把"并发隔离"和"迭代修复"两个需求硬塞进同一个 worktree
  原语导致的架构错误。

  🔴 A3. 三份模型真相源不一致，失败模式是静默降级

  模型信息分散在三处独立维护：models.json（planner 读）/ agent-models.json（运行时读）/ MODEL_REGISTRY（JS
  硬编码，路由用）。已发现的不一致：

  ┌─────────┬────────────────────────────────────┬──────────────────────────┐
  │ 模型名  │           models.json 说           │ MODEL_REGISTRY 实际路由  │
  ├─────────┼────────────────────────────────────┼──────────────────────────┤
  │ codex   │ gpt-5.4-pro (codex CLI)            │ opencode openai/o3       │
  ├─────────┼────────────────────────────────────┼──────────────────────────┤
  │ glm-5.2 │ 存在（agent-models.json 示例也用） │ 不存在 → fallback sonnet │
  ├─────────┼────────────────────────────────────┼──────────────────────────┤
  │ glm     │ model_id glm-5.2                   │ opencode zhipuglm/glm-5  │
  └─────────┴────────────────────────────────────┴──────────────────────────┘

  更糟的是失败模式：lookupModel 返回 null 时，routeAgent:200 和 executeWithExternal:290 静默 fallback 到
  sonnet，不抛错、不告警。对一个以"多模型混用省钱"为核心卖点的系统，这意味着你以为在用 deepseek 省钱，实际在烧
  sonnet，且无人告知。

  另外 models.json 里的 auto_assignment / defaults / cost_per_1k / context_window
  字段没有任何代码消费——纯装饰，却让维护者误以为它们生效（planner 被口头要求"读 models.json 分配模型"，实际全靠 LLM
  自由发挥，rules 是死代码）。

  修复：单一真相源（MODEL_REGISTRY），models.json 从中生成或废弃；未知模型名直接抛错而非降级。

  🟠 A4. 同层并行 worktree 合并必然冲突，且解冲突策略危险

  同层多任务都基于同一 base 在各自 worktree 并行开发。planner 只约束"每任务 3-5 文件"，不保证文件不重叠。两个任务 touch 同一文件 →
  merge 冲突。而 merge prompt（:807）写的是 "prefer incoming branch's
  changes"——后合并的会覆盖先合并的，可能静默回退前一个任务的改动。冲突解决交给一个未指定 model 的普通
  agent，无冲突检测/升级机制（失败不会回退到串行或人工）。

  🟠 A5. deep-interview 作为后台 workflow 跑不通（架构错位）

  deep-interview.js:187：用户回答来自 args.answers[round]，否则填 [Pending user answer for round N]。但 workflow
  是后台运行的，主会话不在线，args.answers 永远为空 → interview 生成了一串问题却没答案 → Crystallize 基于空答案生成 spec → spec
  没有价值。

  PROTOCOL 说"用户通过 AskUserQuestion 在主会话回答"，但后台 workflow 无法暂停等人。这是把需要人机交互的 interview
  错放进了异步后台 workflow。要么 interview 不该是 workflow（在主会话线性做），要么需要 workflow 支持暂停-续跑（当前 harness
  不支持）。现状是设计上跑不通的。

  🟡 A6. 状态机靠 LLM 维护（非确定性）

  state.json / events.jsonl / current_plan.json / lessons.jsonl 的读写全部由 agent 按自然语言指令完成（Persist 阶段
  :877、developer "append lesson" 等）。LLM 可能写错格式、覆盖而非 append、漏字段。state.json 模板有 last_updated 字段但 Persist
  prompt 没要求更新它。

  根因是 Workflow 脚本无 fs 访问（harness 限制），只能靠 agent。缓解方向：用更严格的 schema +
  读回校验，关键状态（completed_tasks、total_tasks_run）应由 JS 通过 agent 的结构化返回值拼装，而非让 agent 自由写文件。

  🟡 A7. PROTOCOL 文档与实现脱节

  - PROTOCOL 写"developer 3 次修复失败 → 升级到 architect"，代码里没有 architect 升级，只有 max retries → manual_review。
  - PROTOCOL agent 表说 developer: opus，但 agent-models.json 和 AGENT_MODEL_DEFAULTS 都是 developer: auto。
  - architect agent 定义存在（.claude/agents/architect.md），但 supervisor-worker 全流程从未调用 architect。

  文档作为"系统规格"不可信，维护者会按 PROTOCOL 理解行为，实际是另一套。

  ---
  二、正确性层面（bug）

  🔴 B1. verify FAIL 不影响 passed 状态——验证形同虚设

  :856 verify 返回 FAIL 时只 log 一行，不修改 passed 列表、不写 manual_review。随后 Persist（:877）仍把 passed 列表里的任务计入
  state.completed_tasks 并 commit、报告 "Ready for PR"。即全局验证失败的任务照样被记为完成。Verifier
  这个角色在正确性上是空转的。修复：verify FAIL 时把对应任务移出 passed、写入 manual_review_needed。

  🔴 B2. DAG 依赖解析静默丢任务

  :578 当 ready.length === 0（有环或 depends_on 指向不存在的 task id）时，只 log +
  break，剩余任务被静默丢弃，不报错、不标记失败。planner 笔误写错一个依赖 id → 该任务永不 ready → 用户以为跑了 N
  个，实际少了。修复：校验所有 depends_on 引用的 id 存在；循环终止时若有 remaining，显式标记失败并报错。

  🟠 B3. MAX_FIX_RETRIES off-by-one

  :593 定义 =3，:665 循环 for (attempt = 0; attempt <= MAX_FIX_RETRIES; attempt++) → 实际跑 4 次（1 dev + 3 fix）。命名暗示 3
  次修复，实际 4 次尝试。要么改 <，要么改名。

  🟠 B4. 未知/拼错的 Claude 模型名静默接受

  isClaude:152 的 fallback 正则 /^(opus|sonnet|haiku|claude)/i 会让任何以 claude 开头的字符串（如拼错的 claude-opus-4-9）被判为
  Claude → toShorthand 返回 opus → 实际跑 opus。无效模型名不报错。

  🟡 B5. 桥接 agent 的 prompt 文件名含冒号

  routeAgent:211 的 safeLabel 正则 [^a-z0-9_:-] 保留了 :，而 dev/test/review 的 label 形如 test-logic:t1:0 → 生成文件名
  prompt_test-logic:t1:0.txt。冒号在 macOS HFS+/APFS 上是路径分隔符的别名，会触发错误或写到意外位置。应把 : 也替换掉。

  🟡 B6. Plan reader 多一次 LLM 调用且引入解析误差

  :538 单独起一个 agent 读 current_plan.json 返回结构化 tasks。本可由 planner 直接在 PLAN_SCHEMA 里返回 tasks 数组。多一次 LLM
  调用 = 多一次解析出错机会 + 成本。

  🟡 B7. deep-interview 的 slug 可能碰撞

  :235 slug 由 args.request 生成，replace([^a-z0-9]) 会删掉所有中文 → 中文需求 slug 为空 → 文件名
  deep-interview-.md，多个中文需求互相覆盖。

  🟡 B8. iterative-fix 反馈截断可能丢失错误信息

  iterative-fix.js:89 verify_output 只取最后 2000
  字符作为下一轮反馈。若关键错误信息在输出前部（编译错误常在中间），反馈丢失，worker 下一轮盲修。