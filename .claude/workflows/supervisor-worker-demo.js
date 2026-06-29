export const meta = {
  name: 'supervisor-worker',
  description: 'Supervisor-Worker: interview → plan → develop → test → review → verify → persist (multi-model, tmux workers)',
  whenToUse: 'For any multi-step coding task. Main session stays clean, never compacts.',
  phases: [
    { title: 'Init', detail: 'Create feature branch, initialize .loopos/ state' },
    { title: 'Plan', detail: 'Analyst gap-check → Planner decomposes into DAG → Critic reviews plan' },
    { title: 'Dev-Test Loop', detail: 'For each layer: develop (worktree/tmux) → test → review → fix → merge' },
    { title: 'Verify', detail: 'Verifier evidence-based completion check' },
    { title: 'Persist', detail: 'Update state, log events, report branch ready for PR' },
  ],
}

// ============================================================
// Schemas
// ============================================================

const PATH_SCHEMA = {
  type: 'object',
  properties: { path: { type: 'string' } },
  required: ['path'],
}

const BRANCH_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    branch: { type: 'string' },
  },
  required: ['path', 'branch'],
}

const MERGE_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    branch: { type: 'string' },
    build_ok: { type: 'boolean' },
  },
  required: ['path', 'branch'],
}

const TEST_RESULT_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    passed: { type: 'boolean' },
    critical_issues: { type: 'number' },
  },
  required: ['path', 'passed'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    verdict: { type: 'string' },
    critical_count: { type: 'number' },
    high_count: { type: 'number' },
  },
  required: ['path', 'verdict'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    verdict: { type: 'string' },
    gaps: { type: 'number' },
  },
  required: ['path', 'verdict'],
}

const PLAN_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    task_count: { type: 'number' },
    task_ids: { type: 'array', items: { type: 'string' } },
    tasks: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          title: { type: 'string' },
          description: { type: 'string' },
          depends_on: { type: 'array', items: { type: 'string' } },
          relevant_files: { type: 'array', items: { type: 'string' } },
          acceptance_criteria: { type: 'string' },
          complexity: { type: 'string' },
          assigned_model: { type: 'string' },
          model_reason: { type: 'string' },
        },
        required: ['id', 'title'],
      },
    },
  },
  required: ['path', 'task_count', 'task_ids', 'tasks'],
}

const CRITIC_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    verdict: { type: 'string' },
    critical_findings: { type: 'number' },
    major_findings: { type: 'number' },
  },
  required: ['path', 'verdict'],
}

// ============================================================
// 模型注册表 — 统一管理所有 LLM 的路由信息
// type: 'claude' → agent() 直连
//       'opencode' → opencode run via tmux (推荐，统一网关，所有模型都有文件系统访问)
//       'cli' → 独立 CLI (codex/gemini/cursor) via tmux (需单独安装)
//       'api' → curl 调用 (无文件系统访问，桥接 agent 代读文件)
// ============================================================

const MODEL_REGISTRY = {
  // Claude — 简称 (向后兼容)
  'opus':   { type: 'claude', shorthand: 'opus' },
  'sonnet': { type: 'claude', shorthand: 'sonnet' },
  'haiku':  { type: 'claude', shorthand: 'haiku' },

  // Claude — 全称
  'claude-opus-4-6':   { type: 'claude', shorthand: 'opus' },
  'claude-opus-4-8':   { type: 'claude', shorthand: 'opus' },
  'claude-sonnet-4-6': { type: 'claude', shorthand: 'sonnet' },
  'claude-haiku-4-5':  { type: 'claude', shorthand: 'haiku' },

  // Claude — 旧名称 (planner 的 models.json 使用)
  'claude-opus':   { type: 'claude', shorthand: 'opus' },
  'claude-sonnet': { type: 'claude', shorthand: 'sonnet' },
  'claude-haiku':  { type: 'claude', shorthand: 'haiku' },

  // OpenAI — 通过 opencode (推荐) 或 codex CLI
  'gpt-5.4-pro':  { type: 'opencode', opencode_model: 'openai/gpt-5.4-pro' },
  'gpt-5.4-mini': { type: 'opencode', opencode_model: 'openai/gpt-5.4-mini' },
  'gpt-5.4':      { type: 'opencode', opencode_model: 'openai/gpt-5.4' },
  'gpt-5.5':      { type: 'opencode', opencode_model: 'openai/gpt-5.5' },
  'gpt-5.5-pro':  { type: 'opencode', opencode_model: 'openai/gpt-5.5-pro' },
  'o3':           { type: 'opencode', opencode_model: 'openai/o3' },
  'o3-pro':       { type: 'opencode', opencode_model: 'openai/o3-pro' },
  'o4-mini':      { type: 'opencode', opencode_model: 'openai/o4-mini' },
  'codex':        { type: 'opencode', opencode_model: 'openai/o3' },
  'codex-mini':   { type: 'opencode', opencode_model: 'openai/o4-mini' },

  // Google — 通过 opencode
  'gemini-2.5-pro':  { type: 'opencode', opencode_model: 'google/gemini-2.5-pro' },
  'gemini-3.1-pro':  { type: 'opencode', opencode_model: 'google/gemini-3.1-pro' },
  'gemini-3.5-flash': { type: 'opencode', opencode_model: 'google/gemini-3.5-flash' },
  'gemini':          { type: 'opencode', opencode_model: 'google/gemini-2.5-pro' },

  // DeepSeek — 通过 opencode (有文件系统访问，比 curl 更强)
  'deepseek-v4-pro':  { type: 'opencode', opencode_model: 'deepseek/deepseek-v4-pro' },
  'deepseek-v4-flash': { type: 'opencode', opencode_model: 'deepseek/deepseek-v4-flash' },
  'deepseek-chat':    { type: 'opencode', opencode_model: 'deepseek/deepseek-chat' },
  'deepseek-coder':   { type: 'opencode', opencode_model: 'deepseek/deepseek-chat' },
  'deepseek':         { type: 'opencode', opencode_model: 'deepseek/deepseek-chat' },

  // 智谱 GLM — 通过 opencode
  'glm-5':        { type: 'opencode', opencode_model: 'zhipuglm/glm-5' },
  'glm-5.1':      { type: 'opencode', opencode_model: 'zhipuai-coding-plan/glm-5.1' },
  'glm-5-turbo':  { type: 'opencode', opencode_model: 'zhipuai-coding-plan/glm-5-turbo' },
  'glm-4-plus':   { type: 'opencode', opencode_model: 'zhipuai-coding-plan/glm-4.7' },
  'glm':          { type: 'opencode', opencode_model: 'zhipuglm/glm-5' },

  // Cursor — 独立 CLI (tmux)
  'cursor': { type: 'cli', provider: 'cursor', model_id: 'default' },
}

function lookupModel(name) {
  return MODEL_REGISTRY[name] || null
}

function isClaude(name) {
  const m = lookupModel(name)
  return m ? m.type === 'claude' : false
}

function toShorthand(name) {
  const m = lookupModel(name)
  return m && m.type === 'claude' ? m.shorthand : 'sonnet'
}

// ============================================================
// Agent 模型配置 — 集中管理每个 Agent 使用的模型 (任意 LLM)
// 优先级: AGENT_MODEL_DEFAULTS < .loopos/agent-models.json < args.agent_models
// ============================================================

const AGENT_MODEL_DEFAULTS = {
  'explorer':       'claude-haiku-4-5',
  'analyst':        'claude-opus-4-6',
  'planner':        'claude-sonnet-4-6',
  'architect':      'claude-opus-4-6',
  'critic':         'claude-opus-4-6',
  'developer':      'auto',
  'debugger':       'auto',
  'tester-logic':   'claude-sonnet-4-6',
  'tester-quality': 'claude-sonnet-4-6',
  'code-reviewer':  'claude-opus-4-6',
  'verifier':       'claude-sonnet-4-6',
}

let agentModels = { ...AGENT_MODEL_DEFAULTS }

// resolveModel: 返回模型全称 (可以是任意 LLM)
// "auto" 角色跟随 planner 分配的 taskModel
function resolveModel(role, taskModel) {
  const configured = agentModels[role]
  if (!configured || configured === 'auto') {
    return taskModel || 'claude-sonnet-4-6'
  }
  return configured
}

// ============================================================
// 通用路由 — 根据模型类型自动选择执行方式
// Claude → agent() 直连 | CLI → tmux 桥接 | API → curl 桥接
// ============================================================

async function routeAgent(prompt, opts) {
  const modelName = opts.model || 'claude-sonnet-4-6'
  const entry = lookupModel(modelName)

  if (!entry) {
    // H3: 未知模型 fail fast，不静默降级（防止"以为省钱实际烧 sonnet"）
    throw new Error(`Unknown model "${modelName}" — register it in MODEL_REGISTRY or fix .loopos/agent-models.json. Refusing silent fallback.`)
  }

  // Claude 直连
  if (entry.type === 'claude') {
    return await agent(prompt, { ...opts, model: entry.shorthand })
  }

  // 外部模型 — 通过 haiku 桥接 agent 路由
  const safeLabel = (opts.label || 'ext').replace(/[^a-z0-9_-]/gi, '_')

  if (entry.type === 'opencode') {
    // OpenCode CLI — 统一网关，支持所有 provider/model，有文件系统访问
    return await agent(
      `You are a bridge agent. Execute this task via OpenCode CLI (universal LLM gateway).

EXTERNAL MODEL: ${entry.opencode_model}
AGENT TYPE: ${opts.agentType || 'generic'}

ORIGINAL TASK:
${prompt}

WORKFLOW (execute exactly these steps — do not improvise or poll manually):
1. Write the complete task prompt to .loopos/workers/prompt_${safeLabel}.txt
   Include all context the external model needs (file paths, instructions, output format)
2. Run ONCE: bash .loopos/tmux-worker.sh spawn opencode ${entry.opencode_model} .loopos/workers/prompt_${safeLabel}.txt .
   Parse session_id (loopos-...) from the JSON output.
3. Run: bash .loopos/tmux-worker.sh wait <session_id>
   This blocks at the shell level until a terminal state (completed/failed/timeout/crashed) and returns the status JSON.
   If it returns status "running" (internal wait timed out), run \`wait <session_id>\` again. Repeat until status is NOT "running".
4. Run: bash .loopos/tmux-worker.sh collect <session_id>
5. Read .loopos/workers/<session_id>.stdout
6. Process the external model's output and produce the required structured result
7. Return the structured output exactly as instructed in the ORIGINAL TASK`,
      { ...opts, model: 'haiku', label: `oc:${safeLabel}` }
    )
  }

  if (entry.type === 'cli') {
    // 独立 CLI 工具 (cursor) — 在 tmux 终端中运行，有文件系统访问
    return await agent(
      `You are a bridge agent. Execute this task via an external CLI tool.

EXTERNAL MODEL: ${entry.provider} / ${entry.model_id}
AGENT TYPE: ${opts.agentType || 'generic'}

ORIGINAL TASK:
${prompt}

WORKFLOW (execute exactly these steps — do not improvise or poll manually):
1. Write the complete task prompt to .loopos/workers/prompt_${safeLabel}.txt
   Include all context the external model needs (file paths, instructions, output format)
2. Run ONCE: bash .loopos/tmux-worker.sh spawn ${entry.provider} ${entry.model_id} .loopos/workers/prompt_${safeLabel}.txt .
   Parse session_id (loopos-...) from the JSON output.
3. Run: bash .loopos/tmux-worker.sh wait <session_id>
   This blocks at the shell level until a terminal state (completed/failed/timeout/crashed) and returns the status JSON.
   If it returns status "running" (internal wait timed out), run \`wait <session_id>\` again. Repeat until status is NOT "running".
4. Run: bash .loopos/tmux-worker.sh collect <session_id>
5. Read .loopos/workers/<session_id>.stdout
6. Process the external model's output and produce the required structured result
7. Return the structured output exactly as instructed in the ORIGINAL TASK`,
      { ...opts, model: 'haiku', label: `cli:${safeLabel}` }
    )
  }

  // API 模型 (fallback) — 桥接 agent 先读文件，再转发 API
  return await agent(
    `You are a bridge agent. Execute this task via an external LLM API.

EXTERNAL MODEL: ${entry.provider} / ${entry.model_id}
AGENT TYPE: ${opts.agentType || 'generic'}

ORIGINAL TASK:
${prompt}

WORKFLOW (execute exactly these steps — do not improvise or poll manually):
1. Read all files referenced in the ORIGINAL TASK to gather context
2. Compose a comprehensive prompt including file contents and full task instructions
3. Write to .loopos/workers/prompt_${safeLabel}.txt
4. Run ONCE: bash .loopos/tmux-worker.sh spawn ${entry.provider} ${entry.model_id} .loopos/workers/prompt_${safeLabel}.txt .
   Parse session_id (loopos-...) from the JSON output.
5. Run: bash .loopos/tmux-worker.sh wait <session_id>
   Blocks at shell level until a terminal state (completed/failed/timeout/crashed). If it returns "running", run \`wait\` again until NOT "running".
6. Run: bash .loopos/tmux-worker.sh collect <session_id>
7. Read .loopos/workers/<session_id>.stdout
8. Process the external model's response and produce the required output (write reports, etc.) as instructed in the ORIGINAL TASK
9. Return the structured output exactly as instructed`,
    { ...opts, model: 'haiku', label: `api:${safeLabel}` }
  )
}

// Dev/Debugger 专用外部路由（需要 worktree + git commit）
async function executeWithExternal(task, modelName, devPrompt, opts) {
  const entry = lookupModel(modelName)
  if (!entry) {
    throw new Error(`Unknown model "${modelName}" — register it in MODEL_REGISTRY or fix .loopos/agent-models.json. Refusing silent fallback.`)
  }
  if (entry.type === 'claude') {
    return await agent(devPrompt, { ...opts, model: entry.shorthand })
  }

  // opencode 和 cli 都走 tmux 路径
  if (entry.type === 'opencode' || entry.type === 'cli') {
    const providerCmd = entry.type === 'opencode'
      ? `opencode ${entry.opencode_model}`
      : `${entry.provider} ${entry.model_id}`
    const labelPrefix = entry.type === 'opencode' ? 'oc' : 'tmux'
    return await agent(
      `You are a tmux bridge agent. Route this coding task to an external CLI worker.

TASK: ${task.title}
DESCRIPTION: ${task.description || ''}
RELEVANT FILES: ${(task.relevant_files || []).join(', ')}
EXTERNAL CLI: ${providerCmd}

WORKFLOW:
1. Read the relevant files to understand context
2. Read .loopos/lessons.jsonl (if exists) for past mistakes
3. Compose a detailed coding prompt including:
   - File contents that need modification
   - Clear task description and acceptance criteria
   - Expected output format
4. Write prompt to .loopos/workers/prompt_${task.id}.txt
5. Run ONCE: bash .loopos/tmux-worker.sh spawn ${providerCmd} .loopos/workers/prompt_${task.id}.txt .
   Parse the session_id (loopos-...) from the spawn output.
6. Run: bash .loopos/tmux-worker.sh wait <session_id>
   This blocks at the shell level until a terminal state (completed/failed/timeout/crashed). If it returns "running" (internal wait timed out), run \`wait <session_id>\` again. Repeat until status is NOT "running".
7. Run: bash .loopos/tmux-worker.sh collect <session_id>
8. Read the worker's stdout file for the output
9. Verify changes with git diff
10. Write dev report to .loopos/reports/dev_${task.id}.json
11. Git commit: "[${task.id}] ${task.title}"
12. Run: git branch --show-current
13. Return { path: report_path, branch: current_branch }

IMPORTANT:
- CLI workers run in a real terminal with full filesystem access
- Check git diff to verify what changed
- If the worker timed out or crashed, report status as failed`,
      {
        ...opts,
        model: 'haiku',
        label: opts.label ? `${labelPrefix}:${opts.label}` : `${labelPrefix}:${task.id}`,
        schema: BRANCH_SCHEMA,
      }
    )
  }

  // API model for dev work
  return await agent(
    `You are an API bridge agent. Route this coding task to an external LLM via API.

TASK: ${task.title}
DESCRIPTION: ${task.description || ''}
RELEVANT FILES: ${(task.relevant_files || []).join(', ')}
EXTERNAL MODEL: ${entry.provider} / ${entry.model_id}

WORKFLOW:
1. Read the relevant files
2. Read .loopos/lessons.jsonl (if exists)
3. Compose a coding prompt → write to .loopos/workers/prompt_${task.id}.txt
4. Run ONCE: bash .loopos/tmux-worker.sh spawn ${entry.provider} ${entry.model_id} .loopos/workers/prompt_${task.id}.txt .
   Parse the session_id (loopos-...) from the spawn output.
5. Run: bash .loopos/tmux-worker.sh wait <session_id>
   Blocks at shell level until a terminal state (completed/failed/timeout/crashed). If it returns "running", run \`wait\` again until NOT "running".
6. Run: bash .loopos/tmux-worker.sh collect <session_id>
7. Read .loopos/workers/<session_id>.stdout
8. Apply the external model's changes to actual files
9. Run tests if available
10. Write dev report to .loopos/reports/dev_${task.id}.json
11. Git commit: "[${task.id}] ${task.title}"
12. Run: git branch --show-current
13. Return { path: report_path, branch: current_branch }`,
    {
      ...opts,
      model: 'haiku',
      label: opts.label ? `api:${opts.label}` : `api:${task.id}`,
      schema: BRANCH_SCHEMA,
    }
  )
}

// ============================================================
// mergeBranchToFeature — 把任务 worktree 分支 merge 回 featureBranch（C2）
// dev/fix 完成即调用，使后续 worktree(base=head=featureBranch) 能看到前序改动
// merge 是确定性 git 操作，由 agent 执行（JS 无 shell）
// ============================================================
async function mergeBranchToFeature(branch, taskId, kind) {
  if (!branch) {
    log(`[LOOPLOG] {"event":"merge_skip","task":"${taskId}","kind":"${kind}","reason":"no_branch"}`)
    return { build_ok: true }
  }
  if (branch === featureBranch) {
    log(`[LOOPLOG] {"event":"merge_skip","task":"${taskId}","kind":"${kind}","reason":"same_as_feature"}`)
    return { build_ok: true }
  }
  log(`[LOOPLOG] {"event":"merge","task":"${taskId}","kind":"${kind}","branch":"${branch}"}`)
  return await agent(
    `Merge a task worktree branch into the current feature branch, then verify the build.

FEATURE BRANCH: ${featureBranch}
BRANCH TO MERGE: ${branch} (task ${taskId}, ${kind})

WORKFLOW:
1. Run: git checkout ${featureBranch}
2. Run: git merge ${branch} --no-edit
3. If merge conflict:
   - Read the conflicted files
   - Resolve preferring the incoming branch ${branch} for this task's changes, keep ${featureBranch} content elsewhere
   - git add the resolved files
   - git commit --no-edit
4. Run build verification: go build ./...
   - If go build fails (compile errors): record build_ok=false and a short error summary
   - If go build succeeds OR the project is not Go (no go.mod): build_ok=true
5. Clean up: git branch -d ${branch}  (only if merge succeeded; ignore error if not)
6. Return { path: ".loopos/state.json", branch: "${featureBranch}", build_ok: <true|false> }

Stay on ${featureBranch} when done.`,
    { label: `merge:${taskId}:${kind}`, phase: 'Dev-Test Loop', schema: MERGE_SCHEMA }
  )
}

// ============================================================
// Phase 1: Init — 创建 feature 分支 + 加载状态
// ============================================================
phase('Init')

const branchName = args.branch || null

const initResult = await agent(
  `Initialize the project for a new workflow run.

USER REQUEST: ${args.request}
REQUESTED BRANCH NAME: ${branchName || 'auto-generate from request'}

DO:
1. mkdir -p .loopos/reports .loopos/workers

2. Run: bash .loopos/state.sh init   (creates/validates state.json + decisions.json + manual_review_needed.json + events.jsonl)

3. Read .loopos/lessons.jsonl if exists (last 20 lines)

4. Run: git log --oneline -5

5. Run: find . -type f \\( -name '*.ts' -o -name '*.tsx' -o -name '*.py' -o -name '*.go' -o -name '*.js' -o -name '*.jsx' \\) -not -path '*/node_modules/*' -not -path '*/.next/*' -not -path '*/dist/*' | head -40

6. Create a feature branch:
   ${branchName
     ? `git checkout -b ${branchName}`
     : `Generate a short branch name from the request (e.g. "feat/add-wechat-pay").
      Rules: lowercase, ascii-only, max 50 chars, prefix with feat/ or fix/.
      Run: git checkout -b <branch_name>`}

7. Run: git branch --show-current

8. Return { path: ".loopos/state.json", branch: "<actual branch name>" }`,
  { label: 'init', schema: BRANCH_SCHEMA }
)

const featureBranch = initResult.branch
log(`Feature branch: ${featureBranch}`)

// 加载 agent 模型配置 (.loopos/agent-models.json)
const agentModelConfig = await agent(
  `Read .loopos/agent-models.json and return its content.
If the file does not exist, return { "agent_models": {} }.
Only return the value of the "agent_models" field.`,
  {
    label: 'config:models',
    model: 'haiku',
    schema: {
      type: 'object',
      properties: {
        agent_models: { type: 'object' },
      },
      required: ['agent_models'],
    },
  }
)
if (agentModelConfig && agentModelConfig.agent_models) {
  agentModels = { ...AGENT_MODEL_DEFAULTS, ...agentModelConfig.agent_models, ...(args.agent_models || {}) }
}
log(`Agent models: ${Object.entries(agentModels).map(([k, v]) => `${k}:${v}`).join(', ')}`)

// ============================================================
// Phase 2: Plan — 分析 → 规划 → 审查
// ============================================================
phase('Plan')

// Step 2a: Analyst 预检（如有 spec 文件则基于 spec）
const specFile = args.spec || null
const analystInput = specFile
  ? `Read the spec at ${specFile} and analyze for gaps.`
  : `Analyze this request for implementability gaps: "${args.request}"`

const analystReport = await routeAgent(
  `${analystInput}

Also read .loopos/state.json for project context.
Search the codebase for relevant existing code.
Write your analysis to .loopos/reports/analyst_pre_plan.json.
Return the report path.`,
  { label: 'analyst', schema: PATH_SCHEMA, agentType: 'analyst', model: resolveModel('analyst') }
)

log(`Analyst: ${analystReport.path}`)

// Step 2b: Planner 拆解任务
const modelOverrides = args.model_overrides
  ? `\n\nUSER MODEL OVERRIDES:\n${JSON.stringify(args.model_overrides, null, 2)}\nApply these overrides to matching tasks.`
  : ''

const plan = await routeAgent(
  `You are a task planner. Decompose the request into tasks and assign models.

USER REQUEST: ${args.request}
ANALYST REPORT: ${analystReport.path}
${specFile ? `SPEC FILE: ${specFile}` : ''}
${modelOverrides}

INSTRUCTIONS:
1. Read the analyst report for gap analysis and recommendations
2. Read .loopos/models.json for available models
3. Read .loopos/state.json for completed work
4. Read .loopos/lessons.jsonl for past mistakes (if exists)
5. Analyze the project structure
6. Decompose into tasks with complexity + model assignment
7. Address analyst's recommendations in your task design
8. Write to .loopos/current_plan.json
9. Return path + task info

RULES:
- Each task completable in ONE session, touching at most 3-5 files
- Maximize parallelism, minimize dependencies
- Include complexity and assigned_model for every task
- Available external models: codex, codex-mini, gemini, cursor, deepseek, glm
- Return the FULL tasks array in your structured output (each task with id/title/description/depends_on/relevant_files/acceptance_criteria/complexity/assigned_model/model_reason)`,
  { label: 'planner', schema: PLAN_SCHEMA, agentType: 'planner', model: resolveModel('planner') }
)

log(`Plan: ${plan.task_count} tasks → ${plan.task_ids.join(', ')}`)

let finalPlan = plan  // L4: 复用 planner 返回的 tasks，避免再起 plan-reader 读文件

// Step 2c: Critic 审查计划（可选 — 仅当任务数 ≥ 3 或涉及高复杂度时）
if (plan.task_count >= 3 || args.critic !== false) {
  const criticReport = await routeAgent(
    `Review this work plan for flaws, gaps, and risky assumptions.

PLAN FILE: .loopos/current_plan.json
ANALYST REPORT: ${analystReport.path}
ORIGINAL REQUEST: ${args.request}

Focus on:
- Are tasks properly scoped? (not too large, not too small)
- Are dependencies correct? (no circular deps, no missing deps)
- Are model assignments appropriate for complexity?
- Are there missing tasks that the plan doesn't cover?
- Could two developers interpret any task differently?

Write report to .loopos/reports/critic_plan.json. Return path + verdict.`,
    { label: 'critic:plan', schema: CRITIC_SCHEMA, agentType: 'critic', model: resolveModel('critic') }
  )

  log(`Critic: ${criticReport.verdict} (critical: ${criticReport.critical_findings}, major: ${criticReport.major_findings})`)

  if (criticReport.verdict === 'REJECT') {
    log('Plan REJECTED by critic. Replanning...')

    const replan = await routeAgent(
      `The plan was rejected by the critic. Revise the plan.

CRITIC REPORT: ${criticReport.path}
ORIGINAL PLAN: .loopos/current_plan.json
ANALYST REPORT: ${analystReport.path}

Read the critic's findings and address each one.
Write revised plan to .loopos/current_plan.json.
Return path + task_count + task_ids + FULL tasks array (each task with id/title/description/depends_on/relevant_files/acceptance_criteria/complexity/assigned_model/model_reason).`,
      { label: 'replanner', schema: PLAN_SCHEMA, agentType: 'planner', model: resolveModel('planner') }
    )

    log(`Revised plan: ${replan.task_count} tasks`)
    finalPlan = replan
  }
}

// ============================================================
// Phase 3: Dev-Test Loop (多模型 + worktree/tmux + 层级合并)
// ============================================================
phase('Dev-Test Loop')

// L4: 直接复用 planner/replanner 返回的 tasks，不再起 plan-reader 读文件
const fullPlan = finalPlan

// DAG 分层（静态拓扑）+ 孤儿依赖校验（C1）
const allTaskIds = new Set(fullPlan.tasks.map(t => t.id))
const orphanDeps = []
for (const t of fullPlan.tasks) {
  for (const dep of (t.depends_on || [])) {
    if (!allTaskIds.has(dep)) orphanDeps.push({ task: t.id, bad_dep: dep })
  }
}
if (orphanDeps.length > 0) {
  log(`[LOOPLOG] {"event":"dag_orphan_deps","count":${orphanDeps.length}}`)
  log(`ERROR: ${orphanDeps.length} orphan dependency reference(s): ${orphanDeps.map(o => o.task + '→' + o.bad_dep).join(', ')}`)
}

const done = {}
const layers = []
const remaining = [...fullPlan.tasks]
const allResults = []  // 提前定义：分层阶段也要写入被阻塞任务

while (remaining.length > 0) {
  const ready = remaining.filter(t =>
    (t.depends_on || []).every(dep => done[dep])
  )
  if (ready.length === 0) {
    // C1: 不静默丢弃 — 把无法解析的任务（环或孤儿下游）标记为 blocked，加入结果
    log(`[LOOPLOG] {"event":"dag_unresolvable","blocked":${JSON.stringify(remaining.map(t => t.id))}}`)
    log(`ERROR: circular/unresolvable deps — ${remaining.length} task(s) blocked: ${remaining.map(t => t.id).join(', ')}`)
    for (const t of remaining) {
      allResults.push({ task: t, status: 'blocked_unresolvable', worktreeBranch: null, model_used: t.assigned_model || null })
    }
    break
  }
  layers.push(ready)
  ready.forEach(t => {
    done[t.id] = true
    const idx = remaining.indexOf(t)
    if (idx !== -1) remaining.splice(idx, 1)
  })
}

log(`DAG: ${layers.length} layers, ${fullPlan.tasks.length} tasks`)
log(`[LOOPLOG] {"event":"dag_layers","count":${layers.length},"tasks":${fullPlan.tasks.length}}`)
log(`Models:\n${fullPlan.tasks.map(t => `  ${t.id}: ${t.assigned_model || 'claude-sonnet'} (${t.complexity || '?'})`).join('\n')}`)

const MAX_FIX_RETRIES = 3

// ---- 逐层执行（C1 运行时依赖门控：上游失败则下游 blocked）----
const failedTaskIds = new Set()

for (const layer of layers) {
  // 门控：依赖了已失败任务的本层任务，标记 blocked 不跑
  const blocked = layer.filter(t => (t.depends_on || []).some(d => failedTaskIds.has(d)))
  const runnable = layer.filter(t => !(t.depends_on || []).some(d => failedTaskIds.has(d)))

  for (const t of blocked) {
    log(`[LOOPLOG] {"event":"task_blocked","task":"${t.id}","reason":"upstream_failed"}`)
    log(`[${t.id}] BLOCKED — upstream task failed, skipping`)
    allResults.push({ task: t, status: 'blocked_upstream', worktreeBranch: null, model_used: t.assigned_model || null })
  }

  if (runnable.length === 0) {
    log(`[LOOPLOG] {"event":"layer_skipped","layer":${JSON.stringify(layer.map(t => t.id))}}`)
    continue
  }

  log(`\n=== Layer: ${runnable.map(t => t.id).join(', ')} ===`)

  const layerResults = []

  for (const task of runnable) {
    // ---- Stage 1: dev（worktree 隔离，base=head=featureBranch）----
    const modelKey = task.assigned_model || 'claude-sonnet'
    log(`[LOOPLOG] {"event":"dev_start","task":"${task.id}","model":"${modelKey}"}`)
    log(`[${task.id}] Dev: ${task.title} → ${modelKey}`)

    const devPrompt = `You are a developer. Execute this task on the current branch.

TASK ID: ${task.id}
TITLE: ${task.title}
DESCRIPTION: ${task.description || ''}
ACCEPTANCE CRITERIA: ${task.acceptance_criteria || 'Correct implementation'}
RELEVANT FILES: ${(task.relevant_files || []).join(', ')}

WORKFLOW:
1. Read .loopos/lessons.jsonl (if exists)
2. Read relevant files
3. Implement the task
4. Run existing tests if any
5. Write report to .loopos/reports/dev_${task.id}.json:
   { "task_id": "${task.id}", "model_used": "${modelKey}", "summary": "...", "files_changed": [...] }
6. Git commit with message: "[${task.id}] ${task.title}"
7. Run: git branch --show-current
8. Return { path: "<report path>", branch: "<current branch>" }`

    let devReport
    if (isClaude(modelKey)) {
      devReport = await agent(devPrompt, {
        label: `dev:${task.id}`,
        phase: 'Dev-Test Loop',
        schema: BRANCH_SCHEMA,
        isolation: 'worktree',
        model: toShorthand(modelKey),
      })
    } else {
      devReport = await executeWithExternal(task, modelKey, devPrompt, {
        phase: 'Dev-Test Loop',
        isolation: 'worktree',
      })
    }

    if (!devReport || !devReport.path) {
      log(`[${task.id}] Dev failed, skipping tests`)
      layerResults.push({ task, status: 'dev_failed', worktreeBranch: null, model_used: modelKey })
      continue
    }

    let currentDevReport = devReport.path
    let currentBranch = devReport.branch
    let lastBuildOk = true
    // C2: dev 完成即 merge 回 featureBranch + go build 验证；fix worktree(base=head) 能看到 dev 改动
    const devMerge = await mergeBranchToFeature(currentBranch, task.id, 'dev')
    if (devMerge && devMerge.build_ok === false) lastBuildOk = false

    // ---- Stage 2: 并行 test + review + 修复循环 ----
    let allPassed = false

    for (let attempt = 0; attempt <= MAX_FIX_RETRIES; attempt++) {
      if (attempt > 0) log(`[${task.id}] Fix ${attempt}/${MAX_FIX_RETRIES}`)

      // 并行: Logic Test + Quality Test + Code Review
      const results = await parallel([
        () => routeAgent(
          `Logic test. DEV REPORT: ${currentDevReport}
Read dev report → read changed files → check logic/edge cases/error handling for task ${task.id}.
Write to .loopos/reports/test_logic_${task.id}.json. Return path + passed.`,
          {
            label: `test-logic:${task.id}:${attempt}`,
            phase: 'Dev-Test Loop',
            schema: TEST_RESULT_SCHEMA,
            agentType: 'tester-logic',
            model: resolveModel('tester-logic'),
          }
        ),
        () => routeAgent(
          `Quality test. DEV REPORT: ${currentDevReport}
Read dev report → read changed files → check naming/security/performance/consistency.
Read .loopos/decisions.json if exists.
Write to .loopos/reports/test_quality_${task.id}.json. Return path + passed.`,
          {
            label: `test-quality:${task.id}:${attempt}`,
            phase: 'Dev-Test Loop',
            schema: TEST_RESULT_SCHEMA,
            agentType: 'tester-quality',
            model: resolveModel('tester-quality'),
          }
        ),
        () => routeAgent(
          `Code review. DEV REPORT: ${currentDevReport}
Read dev report → read changed files → check spec compliance, SOLID, security, performance.
Read .loopos/current_plan.json for acceptance criteria.
Read .loopos/decisions.json if exists.
Write to .loopos/reports/review_${task.id}.json. Return path + verdict.`,
          {
            label: `review:${task.id}:${attempt}`,
            phase: 'Dev-Test Loop',
            schema: REVIEW_SCHEMA,
            agentType: 'code-reviewer',
            model: resolveModel('code-reviewer'),
          }
        ),
      ])

      const [logicResult, qualityResult, reviewResult] = results

      const testsOk = [logicResult, qualityResult].filter(Boolean).every(t => t.passed)
      const reviewOk = reviewResult && reviewResult.verdict === 'APPROVE'
      allPassed = testsOk && reviewOk

      if (allPassed) {
        log(`[${task.id}] Passed${attempt > 0 ? ` (${attempt} fixes)` : ''} [${modelKey}]`)
        break
      }

      if (attempt >= MAX_FIX_RETRIES) {
        log(`[${task.id}] Max retries, needs manual review`)
        break
      }

      // 收集失败报告
      const failedReports = []
      if (logicResult && !logicResult.passed) failedReports.push(logicResult.path)
      if (qualityResult && !qualityResult.passed) failedReports.push(qualityResult.path)
      if (reviewResult && reviewResult.verdict !== 'APPROVE') failedReports.push(reviewResult.path)

      log(`[${task.id}] Issues found, fixing... (${failedReports.length} reports)`)

      // 用 debugger agent 修复
      const fixPrompt = `Fix issues in task ${task.id}: ${task.title}

PREVIOUS DEV REPORT: ${currentDevReport}
FAILED REPORTS: ${failedReports.join(', ')}

1. Read all failed test/review reports to understand issues
2. Read .loopos/lessons.jsonl for similar past issues
3. Fix each issue with minimal diff
4. Run tests to verify
5. Append lesson: bash .loopos/state.sh add-lesson '{"issue":"<what went wrong>","fix":"<the fix>"}'
6. Update .loopos/reports/dev_${task.id}.json
7. Git commit: "[${task.id}] fix: ..."
8. Run: git branch --show-current
9. Return { path, branch }`

      let fixReport
      const debugModel = resolveModel('debugger', modelKey)

      if (isClaude(debugModel)) {
        fixReport = await agent(fixPrompt, {
          label: `fix:${task.id}:${attempt + 1}`,
          phase: 'Dev-Test Loop',
          schema: BRANCH_SCHEMA,
          isolation: 'worktree',
          model: toShorthand(debugModel),
          agentType: 'debugger',
        })
      } else {
        fixReport = await executeWithExternal(task, debugModel, fixPrompt, {
          label: `fix:${task.id}:${attempt + 1}`,
          phase: 'Dev-Test Loop',
          isolation: 'worktree',
        })
      }

      if (fixReport) {
        currentDevReport = fixReport.path
        currentBranch = fixReport.branch
        // C2: fix 完成即 merge 回 featureBranch + go build 验证
        const fixMerge = await mergeBranchToFeature(currentBranch, task.id, `fix${attempt + 1}`)
        if (fixMerge && fixMerge.build_ok === false) lastBuildOk = false
      }
    }

    const finalStatus = !allPassed ? 'needs_manual_review' : (lastBuildOk ? 'passed' : 'build_failed')
    if (!allPassed || !lastBuildOk) {
      log(`[LOOPLOG] {"event":"task_result","task":"${task.id}","status":"${finalStatus}","build_ok":${lastBuildOk}}`)
    }
    layerResults.push({
      task,
      status: finalStatus,
      devReport: currentDevReport,
      worktreeBranch: currentBranch,
      model_used: modelKey,
    })
  }

  // C1 运行时门控：本层未通过的任务加入 failed 集合，下游将被 blocked
  for (const r of layerResults.filter(Boolean)) {
    if (r.status !== 'passed') {
      failedTaskIds.add(r.task.id)
      log(`[LOOPLOG] {"event":"task_failed","task":"${r.task.id}","status":"${r.status}"}`)
    } else {
      log(`[LOOPLOG] {"event":"task_passed","task":"${r.task.id}","model":"${r.model_used || ''}"}`)
    }
  }

  // C2: 层内任务已在 dev/fix 完成时逐个 merge 回 featureBranch，此处无需批量 merge

  allResults.push(...layerResults.filter(Boolean))
}

// ============================================================
// Phase 4: Verify — 全局验证
// ============================================================
phase('Verify')

let passed = allResults.filter(r => r && r.status === 'passed')
let failed = allResults.filter(r => r && r.status !== 'passed')

if (passed.length > 0) {
  const verifyResult = await routeAgent(
    `Verify completion of all passed tasks on branch ${featureBranch}.

PASSED TASKS:
${passed.map(r => `- ${r.task.id}: ${r.task.title} (report: ${r.devReport})`).join('\n')}

PLAN: .loopos/current_plan.json

INSTRUCTIONS:
1. Checkout ${featureBranch}
2. Read the plan's acceptance criteria for each passed task
3. Run the full test suite
4. Run type check if applicable
5. Run build if applicable
6. Check for debug artifacts (console.log, TODO, HACK)
7. For each task, verify acceptance criteria are met
8. Write comprehensive verification report to .loopos/reports/verify_final.json
9. Return path + verdict`,
    { label: 'verifier:final', schema: VERIFY_SCHEMA, agentType: 'verifier', model: resolveModel('verifier') }
  )

  log(`[LOOPLOG] {"event":"verify","verdict":"${verifyResult.verdict}","gaps":${verifyResult.gaps || 0}}`)
  log(`Verification: ${verifyResult.verdict} (gaps: ${verifyResult.gaps || 0})`)

  if (verifyResult.verdict === 'FAIL') {
    // C3: 验证失败不放过 — 降级 passed 任务为 verify_failed，重算，后续 Persist 写入 manual_review
    log(`[LOOPLOG] {"event":"verify_fail","demoted":${JSON.stringify(passed.map(r => r.task.id))}}`)
    log(`Verification FAILED — demoting ${passed.length} passed task(s) to verify_failed`)
    for (const r of passed) {
      r.status = 'verify_failed'
    }
    passed = allResults.filter(r => r && r.status === 'passed')
    failed = allResults.filter(r => r && r.status !== 'passed')
  }
}

// ============================================================
// Phase 5: Persist
// ============================================================
phase('Persist')

log(`[LOOPLOG] {"event":"persist_start","passed":${passed.length},"failed":${failed.length}}`)

const modelStats = {}
allResults.forEach(r => {
  if (r && r.model_used) {
    modelStats[r.model_used] = (modelStats[r.model_used] || 0) + 1
  }
})

log(`\nResults: ${passed.length} passed, ${failed.length} need review`)
log(`Models: ${JSON.stringify(modelStats)}`)
log(`Branch: ${featureBranch}`)

await agent(
  `Update project state on branch ${featureBranch}.

RESULTS:
- Passed: ${passed.map(r => r.task.id + ': ' + r.task.title + ' [' + (r.model_used || '?') + ']').join('; ')}
- Failed: ${failed.map(r => r.task.id + ': ' + r.task.title + ' [' + (r.model_used || '?') + ']').join('; ')}

DO:
1. Ensure you are on branch: ${featureBranch}
   Run: git checkout ${featureBranch}

2. Run these deterministic state updates (do NOT edit .loopos/*.json by hand — use state.sh):
   ${passed.map(r => `bash .loopos/state.sh complete-task ${r.task.id} ${r.model_used || ''}`).join('\n   ')}
   ${failed.map(r => `bash .loopos/state.sh fail-task ${r.task.id} ${r.status || 'needs_manual_review'}`).join('\n   ')}
   bash .loopos/state.sh set-branch ${featureBranch}
   bash .loopos/state.sh event workflow_run branch=${featureBranch} passed=${passed.length} failed=${failed.length}

3. Update .loopos/current_plan.json: mark completed tasks (plan structure varies, edit by hand)

4. Clean up .loopos/workers/ session files (keep prompts for reference)

5. Git commit: "[loopos] update state after workflow run"

6. Run: git branch --show-current

Return state path.`,
  { label: 'persister', schema: PATH_SCHEMA }
)

log(`\nDone on branch: ${featureBranch}`)

if (failed.length > 0) {
  log(`Manual review: ${failed.map(r => r.task.id).join(', ')}`)
  log(`See: .loopos/manual_review_needed.json`)
}

log(`\nNext: git diff main...${featureBranch} to review, then create PR`)

return {
  branch: featureBranch,
  total: allResults.length,
  passed: passed.length,
  failed: failed.length,
  model_stats: modelStats,
  tasks: allResults.map(r => ({
    id: r.task.id,
    title: r.task.title,
    status: r.status,
    model: r.model_used,
  })),
}
