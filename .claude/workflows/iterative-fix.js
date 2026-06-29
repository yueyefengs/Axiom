export const meta = {
  name: 'iterative-fix',
  description: 'Iterative bug fix: same opencode worker resumes across rounds with verify-feedback, escalates to manual review after N rounds',
  whenToUse: 'Fix a single bug while reusing one external opencode worker\'s context across rounds. Caller supplies verify_cmd. Escalates to human after max_rounds.',
  phases: [
    { title: 'Round 1', detail: 'spawn opencode worker → collect → verify_cmd' },
    { title: 'Resume', detail: 'rounds 2..N: resume with verify feedback → verify_cmd' },
    { title: 'Manual Review', detail: 'exhausted → write manual_review report with opencode_session_id for handoff' },
  ],
}

// ============================================================
// Schemas
// ============================================================

const ROUND_SCHEMA = {
  type: 'object',
  properties: {
    sid: { type: 'string' },
    round: { type: 'number' },
    opencode_session_id: { type: 'string' },
    verify_passed: { type: 'boolean' },
    verify_output: { type: 'string' },
    worker_summary: { type: 'string' },
  },
  required: ['round', 'verify_passed', 'verify_output'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    report_path: { type: 'string' },
    opencode_session_id: { type: 'string' },
  },
  required: ['report_path'],
}

// ============================================================
// Helpers (pure JS — no Date.now / Math.random in workflow scripts)
// ============================================================

function slugify(s, fallback) {
  const out = String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24)
  return out || fallback
}

function buildRoundPrompt(ctx) {
  const { round, isFirst, sid, bug_description, feedback, workdir, opencode_model, verify_cmd, label } = ctx
  const promptFile = `.loopos/workers/prompt_${label}${isFirst ? '' : `.r${round}`}.txt`

  const head = isFirst
    ? `You are a bridge agent. Execute ROUND 1 of an iterative bug fix via the opencode tmux worker.`
    : `You are a bridge agent. Execute ROUND ${round} of an iterative bug fix by RESUMING the existing opencode worker (it remembers rounds 1..${round - 1}).`

  const feedbackBlock = isFirst
    ? ''
    : `\nPREVIOUS ROUND FAILED VERIFICATION.\nVerification command: ${verify_cmd}\nVerification output (feedback to feed back to the worker):\n${feedback}\n`

  const spawnStep = isFirst
    ? `2. Run: bash .loopos/tmux-worker.sh spawn opencode ${opencode_model} ${promptFile} ${workdir}\n   Parse session_id (loopos-...) from the JSON output → that is <sid>.`
    : `2. Run: bash .loopos/tmux-worker.sh resume ${sid} ${promptFile} ${round}\n   (resume reuses the opencode session from round 1; <sid> stays the same)`

  const promptContent = isFirst
    ? `Write a coding instruction to fix this bug in workdir ${workdir}. Include the bug description verbatim, instruct minimal diff, no rewrite.`
    : `Write this feedback prompt for the worker: "上轮修改未通过验证。验证命令: ${verify_cmd}。验证输出见下。请基于你之前的修改继续修复，做最小改动，不要重做已完成的部分。\\n\\n${feedback}"`

  const collectStep = isFirst
    ? `5. Run: bash .loopos/tmux-worker.sh collect <sid>   (this backfills opencode_session_id into the meta file)`
    : `5. Run: bash .loopos/tmux-worker.sh collect <sid> ${round}`

  return `${head}

BUG:
${bug_description}

WORKDIR: ${workdir}
OPENCODE MODEL: ${opencode_model}
VERIFY CMD: ${verify_cmd}
${feedbackBlock}
STEPS:
1. ${promptContent} Write it to ${promptFile}.
${spawnStep}
3. Run: bash .loopos/tmux-worker.sh wait <sid>${isFirst ? '' : ` ${round}`} — it blocks at the shell level until a terminal state (completed/failed/timeout/crashed) and returns the status JSON. If it returns "running" (internal wait timed out), run \`wait\` again until status is NOT "running".
${collectStep}
6. Read .loopos/workers/<sid>.meta.json and extract the opencode_session_id field (ses_...). On resume rounds it should already be present.
7. Run verification: cd ${workdir} && ${verify_cmd} 2>&1 ; capture combined output and note exit code (0 = pass).
8. Summarize what the worker changed this round in 1-2 sentences (worker_summary).

Return JSON: { "sid": <sid or "">, "round": ${round}, "opencode_session_id": <ses_... or "">, "verify_passed": <true iff verify exit 0>, "verify_output": <full verify output if under 3000 chars; otherwise first 500 chars + any lines matching error/failed/undefined/panic + last 1500 chars>, "worker_summary": <string> }`
}

function buildManualReviewPrompt(ctx) {
  const { bug_description, workdir, verify_cmd, label, sid, rounds } = ctx
  const ocSes = (rounds[rounds.length - 1] && rounds[rounds.length - 1].opencode_session_id) || ''
  const roundsDigest = rounds.map(r => `  - round ${r.round}: verify_passed=${r.verify_passed}, summary=${r.worker_summary || ''}, verify_output=${(r.verify_output || '').slice(0, 500)}`).join('\n')

  return `Write a manual-review handoff report for an iterative fix that exhausted its rounds.

BUG:
${bug_description}

WORKDIR: ${workdir}
VERIFY CMD: ${verify_cmd}
OPENCODE SESSION ID (human can resume with: opencode run -s ${ocSes}): ${ocSes}
LOOPOS SID: ${sid}

ROUNDS DIGEST:
${roundsDigest}

STEPS:
1. mkdir -p .loopos/reports
2. Write .loopos/reports/manual_review_${label}.json with this shape:
   {
     "verdict": "needs_manual_review",
     "bug_description": <the bug>,
     "workdir": <workdir>,
     "opencode_session_id": "${ocSes}",
     "loopos_sid": "${sid}",
     "resume_hint": "opencode run -s ${ocSes}  (in ${workdir}) to continue this worker by hand",
     "rounds": [ { "round": N, "verify_passed": bool, "worker_summary": "...", "verify_output": "..." }, ... ]
   }
3. Return JSON: { "report_path": ".loopos/reports/manual_review_${label}.json", "opencode_session_id": "${ocSes}" }`
}

// ============================================================
// Workflow body
// ============================================================

const args0 = args || {}
const bug_description = args0.bug_description
const workdir = args0.workdir || '.'
const opencode_model = args0.opencode_model
const verify_cmd = args0.verify_cmd
const max_rounds = args0.max_rounds || 3
const label = slugify(args0.label || bug_description, 'iterative-fix')

if (!bug_description) throw new Error('iterative-fix: args.bug_description required')
if (!opencode_model) throw new Error('iterative-fix: args.opencode_model required (e.g. anthropic/claude-haiku-4-5)')
if (!verify_cmd) throw new Error('iterative-fix: args.verify_cmd required (the command that defines "fixed")')

const rounds = []
let sid = null
let passed = false
let lastOcSes = ''

for (let round = 1; round <= max_rounds; round++) {
  phase(round === 1 ? 'Round 1 — Initial Fix' : `Round ${round} — Resume with Feedback`)
  const isFirst = round === 1
  const feedback = isFirst ? '' : ((rounds[rounds.length - 1] && rounds[rounds.length - 1].verify_output) || '')

  const result = await agent(
    buildRoundPrompt({ round, isFirst, sid, bug_description, feedback, workdir, opencode_model, verify_cmd, label }),
    { schema: ROUND_SCHEMA, label: `round-${round}` }
  )

  if (!result) {
    log(`Round ${round}: bridge agent returned nothing, stopping`)
    break
  }
  if (result.sid) sid = result.sid
  if (result.opencode_session_id) lastOcSes = result.opencode_session_id
  rounds.push(result)

  if (result.verify_passed) {
    passed = true
    log(`Round ${round} PASSED verification [${opencode_model}]`)
    break
  }
  log(`Round ${round} failed verification${round < max_rounds ? ` — resuming with feedback` : ` — rounds exhausted`}`)
}

if (passed) {
  return {
    verdict: 'fixed',
    rounds,
    sid,
    opencode_session_id: lastOcSes,
    rounds_used: rounds.length,
  }
}

phase('Manual Review')
log(`All ${rounds.length} round(s) failed — writing manual-review handoff`)
const review = await agent(
  buildManualReviewPrompt({ bug_description, workdir, verify_cmd, label, sid, rounds }),
  { schema: REVIEW_SCHEMA, label: 'manual-review' }
)

return {
  verdict: 'needs_manual_review',
  report_path: review ? review.report_path : null,
  opencode_session_id: lastOcSes,
  sid,
  rounds,
}
