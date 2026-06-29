export const meta = {
  name: 'deep-interview',
  description: 'Socratic requirements clarification — turns vague ideas into crystal-clear specs before any code is written',
  whenToUse: 'Before supervisor-worker. When requirements are vague, ambiguous, or complex. Produces a spec that feeds into the main workflow.',
  phases: [
    { title: 'Initialize', detail: 'Detect brownfield/greenfield, load context' },
    { title: 'Interview', detail: 'Socratic Q&A loop — one question at a time, targeting weakest clarity dimension' },
    { title: 'Crystallize', detail: 'Produce crystal-clear spec from interview answers' },
  ],
}

// ============================================================
// Schemas
// ============================================================

const INIT_SCHEMA = {
  type: 'object',
  properties: {
    project_type: { type: 'string' },
    existing_files: { type: 'array', items: { type: 'string' } },
    tech_stack: { type: 'array', items: { type: 'string' } },
    context_summary: { type: 'string' },
  },
  required: ['project_type', 'context_summary'],
}

const QUESTION_SCHEMA = {
  type: 'object',
  properties: {
    round: { type: 'number' },
    target_component: { type: 'string' },
    target_dimension: { type: 'string' },
    dimension_score: { type: 'number' },
    question: { type: 'string' },
    rationale: { type: 'string' },
    options: { type: 'array', items: { type: 'string' } },
  },
  required: ['round', 'target_dimension', 'question'],
}

const SCORE_SCHEMA = {
  type: 'object',
  properties: {
    ambiguity: { type: 'number' },
    goal_clarity: { type: 'number' },
    constraint_clarity: { type: 'number' },
    criteria_clarity: { type: 'number' },
    context_clarity: { type: 'number' },
    weakest_dimension: { type: 'string' },
    components: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          status: { type: 'string' },
          coverage: { type: 'number' },
        },
      },
    },
    should_continue: { type: 'boolean' },
    reason: { type: 'string' },
  },
  required: ['ambiguity', 'weakest_dimension', 'should_continue'],
}

const SPEC_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    ambiguity_score: { type: 'number' },
    total_rounds: { type: 'number' },
    components: { type: 'number' },
  },
  required: ['path', 'ambiguity_score', 'total_rounds'],
}

// ============================================================
// Config
// ============================================================

const AMBIGUITY_THRESHOLD = args.threshold || 0.2
const MAX_ROUNDS = args.max_rounds || 15
const SOFT_EXIT_ROUND = 3

log(`Deep Interview — threshold: ${AMBIGUITY_THRESHOLD * 100}%, max rounds: ${MAX_ROUNDS}`)

// ============================================================
// Phase 1: Initialize — 探测项目上下文
// ============================================================
phase('Initialize')

const projectContext = await agent(
  `Analyze the current project to prepare for a deep interview.

USER'S IDEA: ${args.request}

DO:
1. Run: find . -type f \\( -name '*.ts' -o -name '*.tsx' -o -name '*.py' -o -name '*.go' -o -name '*.js' -o -name '*.jsx' \\) -not -path '*/node_modules/*' -not -path '*/.next/*' -not -path '*/dist/*' | head -40
2. Check for existing configs: package.json, tsconfig.json, go.mod, pyproject.toml, etc.
3. Read .loopos/state.json if exists for prior work
4. Read .loopos/decisions.json if exists for past decisions
5. Determine:
   - project_type: "brownfield" (existing code) or "greenfield" (new project)
   - existing_files: relevant files for this request
   - tech_stack: detected technologies
   - context_summary: 1-2 sentence project overview

Return the structured analysis.`,
  { label: 'init:context', schema: INIT_SCHEMA, model: 'haiku' }
)

const isBrownfield = projectContext.project_type === 'brownfield'
log(`Project: ${projectContext.project_type} | Stack: ${(projectContext.tech_stack || []).join(', ')}`)

// ============================================================
// Phase 2: Interview Loop — 苏格拉底式提问
// ============================================================
phase('Interview')

const transcript = []
let currentAmbiguity = 1.0
let round = 0

// Round 0: Topology — enumerate top-level components
const topology = await agent(
  `Based on this request, enumerate the top-level components (1-6) that need to be built or modified.

REQUEST: ${args.request}
PROJECT TYPE: ${projectContext.project_type}
CONTEXT: ${projectContext.context_summary}
${isBrownfield ? `EXISTING FILES: ${(projectContext.existing_files || []).join(', ')}` : ''}

For each component:
- name: short identifier
- description: what it does
- status: "new" or "existing" (brownfield only)

Return as a question asking the user to confirm this component list.
Target dimension: "scope"
Round: 0`,
  { label: 'interview:topology', schema: QUESTION_SCHEMA, model: 'opus' }
)

log(`Round 0: Topology — ${topology.question}`)
transcript.push({ round: 0, dimension: 'scope', question: topology.question, answer: '[topology confirmed by proceeding]' })

// Main interview loop
while (round < MAX_ROUNDS && currentAmbiguity > AMBIGUITY_THRESHOLD) {
  round++

  // Generate next question targeting weakest dimension
  const nextQ = await agent(
    `Generate the next interview question for round ${round}.

REQUEST: ${args.request}
PROJECT: ${projectContext.project_type} | ${projectContext.context_summary}
${isBrownfield ? `EXISTING CODE CONTEXT: ${(projectContext.existing_files || []).join(', ')}` : ''}

TRANSCRIPT SO FAR:
${transcript.map(t => `[R${t.round}] (${t.dimension}) Q: ${t.question}\nA: ${t.answer}`).join('\n\n')}

CURRENT AMBIGUITY: ${(currentAmbiguity * 100).toFixed(1)}%
THRESHOLD: ${(AMBIGUITY_THRESHOLD * 100)}%

RULES:
- Ask ONE question targeting the WEAKEST clarity dimension
- Dimensions: goal_clarity, constraint_clarity, criteria_clarity${isBrownfield ? ', context_clarity' : ''}
- For brownfield: cite repo evidence that triggered the question
- Question styles per dimension:
  * goal: "What exactly happens when...?"
  * constraint: "What are the limits/boundaries?"
  * criteria: "How do we verify it works?"
  * context: "How does this integrate with existing code at [file:line]?"
- Provide 2-4 suggested options when applicable
${round >= 4 ? '- CONTRARIAN mode available: "What if the opposite were true?"' : ''}
${round >= 6 ? '- SIMPLIFIER mode available: "What is the simplest version?"' : ''}

Return structured question.`,
    { label: `interview:r${round}`, schema: QUESTION_SCHEMA, model: 'opus' }
  )

  log(`Round ${round} | ${nextQ.target_dimension} (${((nextQ.dimension_score || 0) * 100).toFixed(0)}%) | ${nextQ.question}`)

  // Record (in real usage, user answers via AskUserQuestion in the main session;
  // here we store the question — the answer comes from args.answers or is auto-proceeded)
  const answer = (args.answers && args.answers[round])
    ? args.answers[round]
    : `[Pending user answer for round ${round}]`

  transcript.push({
    round,
    dimension: nextQ.target_dimension,
    question: nextQ.question,
    answer,
    options: nextQ.options,
  })

  // Score ambiguity after this round
  const score = await agent(
    `Score the current ambiguity level after round ${round}.

REQUEST: ${args.request}
TRANSCRIPT:
${transcript.map(t => `[R${t.round}] (${t.dimension}) Q: ${t.question}\nA: ${t.answer}`).join('\n\n')}

SCORING FORMULA:
${isBrownfield
  ? 'ambiguity = 1 - (goal × 0.35 + constraints × 0.25 + criteria × 0.25 + context × 0.15)'
  : 'ambiguity = 1 - (goal × 0.40 + constraints × 0.30 + criteria × 0.30)'}

Score each dimension 0.0 to 1.0 based on how clearly defined it is from the transcript.
${round >= SOFT_EXIT_ROUND ? `\nSOFT EXIT: Round ${round} ≥ ${SOFT_EXIT_ROUND}. If ambiguity is low enough or diminishing returns, set should_continue=false.` : ''}

Return scores + overall ambiguity + weakest dimension + should_continue.`,
    { label: `score:r${round}`, schema: SCORE_SCHEMA, model: 'opus' }
  )

  currentAmbiguity = score.ambiguity
  log(`  → Ambiguity: ${(currentAmbiguity * 100).toFixed(1)}% | Weakest: ${score.weakest_dimension}`)

  if (!score.should_continue) {
    log(`  → ${score.reason || 'Sufficient clarity reached'}`)
    break
  }
}

log(`\nInterview complete: ${round} rounds, ambiguity ${(currentAmbiguity * 100).toFixed(1)}%`)

// ============================================================
// Phase 3: Crystallize — 生成规格说明
// ============================================================
phase('Crystallize')

const slug = args.request
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, '-')
  .replace(/^-|-$/g, '')
  .slice(0, 40)

const spec = await agent(
  `Crystallize the interview results into a clear, implementable specification.

REQUEST: ${args.request}
PROJECT: ${projectContext.project_type}
TECH STACK: ${(projectContext.tech_stack || []).join(', ')}
CONTEXT: ${projectContext.context_summary}
${isBrownfield ? `EXISTING FILES: ${(projectContext.existing_files || []).join(', ')}` : ''}

INTERVIEW TRANSCRIPT (${round} rounds, ambiguity ${(currentAmbiguity * 100).toFixed(1)}%):
${transcript.map(t => `[R${t.round}] (${t.dimension}) Q: ${t.question}\nA: ${t.answer}`).join('\n\n')}

WRITE a spec to .loopos/specs/deep-interview-${slug}.md with this structure:

---
interview_id: di-${slug}
rounds: ${round}
ambiguity: ${currentAmbiguity.toFixed(3)}
type: ${projectContext.project_type}
status: crystallized
---

## Goal
[Crystal-clear statement of what needs to be built]

## Components
| Component | Type | Description | Priority |
|-----------|------|-------------|----------|

## Constraints
[Hard limits, non-negotiable rules]

## Non-Goals
[Explicitly out of scope]

## Acceptance Criteria
[Testable, measurable criteria]

## Technical Context
[Relevant existing code, integration points]

## Edge Cases
[Unusual scenarios that need handling]

## Assumptions
[Assumptions made during the interview]

## Interview Summary
[Key decisions and their rationale]

Return { path, ambiguity_score, total_rounds, components }.`,
  { label: 'crystallize', schema: SPEC_SCHEMA, model: 'opus' }
)

log(`\nSpec: ${spec.path}`)
log(`Ambiguity: ${(spec.ambiguity_score * 100).toFixed(1)}% | Rounds: ${spec.total_rounds} | Components: ${spec.components}`)

if (currentAmbiguity <= AMBIGUITY_THRESHOLD) {
  log(`\n✓ Ambiguity below threshold. Spec ready for execution.`)
  log(`Next: Workflow({ name: 'supervisor-worker', args: { request: '...', spec: '${spec.path}' } })`)
} else {
  log(`\n⚠ Ambiguity still at ${(currentAmbiguity * 100).toFixed(1)}% (threshold: ${(AMBIGUITY_THRESHOLD * 100)}%)`)
  log(`Consider running another interview round or proceeding with caution.`)
}

return {
  spec_path: spec.path,
  ambiguity: currentAmbiguity,
  rounds: round,
  components: spec.components,
  threshold: AMBIGUITY_THRESHOLD,
  passed_threshold: currentAmbiguity <= AMBIGUITY_THRESHOLD,
}
