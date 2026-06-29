export const meta = {
  name: 'supervisor-resume',
  description: 'Resume interrupted work: read .loopos state, continue pending tasks',
  whenToUse: 'When a previous workflow was interrupted or tasks marked for manual review',
  phases: [
    { title: 'Assess', detail: 'Read state and determine what needs to be done' },
    { title: 'Resume', detail: 'Continue pending or failed tasks' },
    { title: 'Persist', detail: 'Update state' },
  ],
}

const PATH_SCHEMA = {
  type: 'object',
  properties: { path: { type: 'string' } },
  required: ['path'],
}

const TEST_RESULT_SCHEMA = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    passed: { type: 'boolean' },
  },
  required: ['path', 'passed'],
}

// ============================================================
// Phase 1: Assess current state
// ============================================================
phase('Assess')

const assessment = await agent(
  `Assess the current project state to determine what work remains.

Read these files:
1. .loopos/state.json - completed tasks
2. .loopos/current_plan.json - full task plan
3. .loopos/manual_review_needed.json - tasks that failed (if exists)
4. .loopos/events.jsonl - last 20 events (if exists)
5. .loopos/lessons.jsonl - lessons learned (if exists)

Determine:
- Which tasks in current_plan are still "pending"?
- Which tasks need manual review / re-attempt?
- Are there dependency issues?

Return assessment.`,
  {
    label: 'assessor',
    schema: {
      type: 'object',
      properties: {
        pending_tasks: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              id: { type: 'string' },
              title: { type: 'string' },
              description: { type: 'string' },
              relevant_files: { type: 'array', items: { type: 'string' } },
              acceptance_criteria: { type: 'string' },
            },
            required: ['id', 'title'],
          },
        },
        retry_tasks: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              id: { type: 'string' },
              title: { type: 'string' },
              previous_failure: { type: 'string' },
            },
            required: ['id', 'title'],
          },
        },
        total_completed: { type: 'number' },
        total_remaining: { type: 'number' },
      },
      required: ['pending_tasks', 'retry_tasks', 'total_completed', 'total_remaining'],
    },
  }
)

log(`State: ${assessment.total_completed} done, ${assessment.total_remaining} remaining`)
log(`  Pending: ${assessment.pending_tasks.map(t => t.id).join(', ') || 'none'}`)
log(`  Retry: ${assessment.retry_tasks.map(t => t.id).join(', ') || 'none'}`)

const allTasks = [
  ...assessment.retry_tasks.map(t => ({ ...t, is_retry: true })),
  ...assessment.pending_tasks.map(t => ({ ...t, is_retry: false })),
]

if (allTasks.length === 0) {
  log('All tasks completed! Nothing to resume.')
  return { status: 'all_done', completed: assessment.total_completed }
}

// ============================================================
// Phase 2: Resume - execute remaining tasks
// ============================================================
phase('Resume')

const MAX_FIX_RETRIES = 3
const results = []

for (const task of allTasks) {
  log(`\n--- ${task.is_retry ? 'Retrying' : 'Starting'}: ${task.id} - ${task.title} ---`)

  const extraContext = task.is_retry
    ? `\nPREVIOUS FAILURE: ${task.previous_failure}\nRead .loopos/lessons.jsonl for related lessons.`
    : ''

  // Develop
  const devReport = await agent(
    `Execute this task:

TASK ID: ${task.id}
TITLE: ${task.title}
DESCRIPTION: ${task.description || ''}
ACCEPTANCE CRITERIA: ${task.acceptance_criteria || 'Correct implementation'}
RELEVANT FILES: ${(task.relevant_files || []).join(', ')}
${extraContext}

WORKFLOW:
1. Read .loopos/lessons.jsonl for past mistakes
2. Read relevant files
3. Implement
4. Write report to .loopos/reports/dev_${task.id}.json
5. Git commit
6. Return report path`,
    { label: `dev:${task.id}`, schema: PATH_SCHEMA, isolation: 'worktree' }
  )

  if (!devReport) {
    log(`[${task.id}] Dev failed`)
    results.push({ task, status: 'dev_failed' })
    continue
  }

  // Test + fix loop
  let currentReport = devReport.path
  let passed = false

  for (let attempt = 0; attempt <= MAX_FIX_RETRIES; attempt++) {
    const tests = await parallel([
      () => agent(
        `Test logic correctness. Dev report: ${currentReport}
Read the dev report, then read changed files, check for bugs.
Write to .loopos/reports/test_logic_${task.id}.json. Return path + passed.`,
        { label: `test:${task.id}:${attempt}`, schema: TEST_RESULT_SCHEMA }
      ),
      () => agent(
        `Test code quality. Dev report: ${currentReport}
Read the dev report, then read changed files, check quality.
Write to .loopos/reports/test_quality_${task.id}.json. Return path + passed.`,
        { label: `quality:${task.id}:${attempt}`, schema: TEST_RESULT_SCHEMA }
      ),
    ])

    const valid = tests.filter(Boolean)
    passed = valid.length > 0 && valid.every(t => t.passed)

    if (passed) {
      log(`[${task.id}] Passed${attempt > 0 ? ` after ${attempt} fixes` : ''}`)
      break
    }

    if (attempt >= MAX_FIX_RETRIES) break

    const failPaths = valid.filter(t => !t.passed).map(t => t.path).join(', ')
    log(`[${task.id}] Fix attempt ${attempt + 1}...`)

    const fix = await agent(
      `Fix bugs. Task: ${task.title}. Dev report: ${currentReport}. Failed tests: ${failPaths}
Read all reports, fix issues, update dev report, append lesson to .loopos/lessons.jsonl, commit.`,
      { label: `fix:${task.id}:${attempt}`, schema: PATH_SCHEMA, isolation: 'worktree' }
    )

    if (fix) currentReport = fix.path
  }

  results.push({ task, status: passed ? 'passed' : 'needs_review' })
}

// ============================================================
// Phase 3: Persist
// ============================================================
phase('Persist')

const passedTasks = results.filter(r => r.status === 'passed')
const failedTasks = results.filter(r => r.status !== 'passed')

await agent(
  `Update .loopos state files:
- Add to state.json completed_tasks: ${passedTasks.map(r => r.task.id).join(', ')}
- Append events to events.jsonl
- Mark tasks in current_plan.json as completed
- Update manual_review_needed.json with: ${failedTasks.map(r => r.task.id).join(', ') || 'none'}`,
  { label: 'persist', schema: PATH_SCHEMA }
)

log(`\nDone: ${passedTasks.length} passed, ${failedTasks.length} need review`)

return {
  resumed: results.length,
  passed: passedTasks.length,
  failed: failedTasks.length,
}
