#!/usr/bin/env bash
# .codex/scripts/supervisor.sh — LoopOS Codex 版主编排器
#
# 用法:
#   bash .codex/scripts/supervisor.sh "新增微信支付功能"
#   bash .codex/scripts/supervisor.sh "需求" --branch feat/add-wechat-pay
#   bash .codex/scripts/supervisor.sh --spec .loopos/specs/deep-interview-xxx.md
#
# 流水线: Init → Analyst → Planner → Critic → Dev-Test Loop → Verify → Persist

set -euo pipefail

# ============================================================
# 配置
# ============================================================

MAIN_MODEL="${LOOPOS_MODEL:-gpt-5.4}"
FAST_MODEL="${LOOPOS_FAST_MODEL:-gpt-5.4}"
MAX_FIX_RETRIES=3
CODEX_FLAGS="--dangerously-bypass-approvals-and-sandbox --skip-git-repo-check"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[LoopOS]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

# ============================================================
# 参数解析
# ============================================================

REQUEST=""
BRANCH=""
SPEC_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2 ;;
    --spec)   SPEC_FILE="$2"; shift 2 ;;
    --model)  MAIN_MODEL="$2"; shift 2 ;;
    *)        REQUEST="$1"; shift ;;
  esac
done

if [ -z "$REQUEST" ] && [ -z "$SPEC_FILE" ]; then
  echo "用法: bash .codex/scripts/supervisor.sh \"需求描述\" [--branch NAME] [--spec FILE]"
  exit 1
fi

# 如果有 spec 但没有 request，从 spec 提取
if [ -z "$REQUEST" ] && [ -n "$SPEC_FILE" ]; then
  REQUEST="See spec: $SPEC_FILE"
fi

# ============================================================
# 工具函数
# ============================================================

run_agent() {
  local agent_name="$1"
  local model="$2"
  local prompt="$3"
  local instructions=".codex/agents/${agent_name}.md"

  if [ ! -f "$instructions" ]; then
    err "Agent 文件不存在: $instructions"
    return 1
  fi

  log "Running ${agent_name} (${model})..."

  local err_file=".loopos/workers/${agent_name}.stderr"
  mkdir -p .loopos/workers 2>/dev/null || true
  codex exec -m "$model" \
    --instructions "$instructions" \
    $CODEX_FLAGS \
    "$prompt" 2>"$err_file" || {
    warn "${agent_name} 执行失败，返回码: $?"
    warn "stderr 末尾（完整见 $err_file）:"
    tail -25 "$err_file" >&2 2>/dev/null || true
    return 1
  }
}

extract_json_field() {
  local file="$1"
  local field="$2"
  python3 -c "import json; print(json.load(open('$file'))$field)" 2>/dev/null || echo ""
}

# ============================================================
# Phase 1: Init
# ============================================================

log "========== Phase: Init =========="

mkdir -p .loopos/reports .loopos/workers .loopos/specs

# 初始化状态文件（H4：优先用 state.sh 确定性初始化，fallback 到原逻辑）
if [ -f .loopos/state.sh ]; then
  bash .loopos/state.sh init 2>/dev/null || { echo '{ "completed_tasks": [], "total_tasks_run": 0, "project_summary": "" }' > .loopos/state.json; echo '{ "decisions": [] }' > .loopos/decisions.json; }
else
  [ -f .loopos/state.json ] || echo '{ "completed_tasks": [], "total_tasks_run": 0, "project_summary": "" }' > .loopos/state.json
  [ -f .loopos/decisions.json ] || echo '{ "decisions": [] }' > .loopos/decisions.json
fi

# 创建 feature 分支
if [ -z "$BRANCH" ]; then
  BRANCH="feat/$(echo "$REQUEST" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)"
fi

git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH" 2>/dev/null || {
  err "无法创建/切换到分支: $BRANCH"
  exit 1
}

ok "Feature branch: $BRANCH"

# ============================================================
# Phase 2: Analyst 预检
# ============================================================

log "========== Phase: Analyst =========="

ANALYST_PROMPT="分析以下需求的可实现性缺口:
REQUEST: $REQUEST"

if [ -n "$SPEC_FILE" ]; then
  ANALYST_PROMPT="读取 spec 文件 $SPEC_FILE 并分析实现缺口。
也读取 .loopos/state.json 了解项目上下文。
写分析到 .loopos/reports/analyst_pre_plan.json，只返回路径。"
fi

run_agent "analyst" "$MAIN_MODEL" "$ANALYST_PROMPT"
ok "Analyst report: .loopos/reports/analyst_pre_plan.json"

# ============================================================
# Phase 3: Planner 拆解任务
# ============================================================

log "========== Phase: Planner =========="

PLANNER_PROMPT="拆解以下需求为任务 DAG 并分配模型。
REQUEST: $REQUEST
ANALYST REPORT: .loopos/reports/analyst_pre_plan.json
${SPEC_FILE:+SPEC FILE: $SPEC_FILE}

读取 .loopos/models.json，读取 analyst 报告，拆解为任务。
写计划到 .loopos/current_plan.json，只返回路径。"

run_agent "planner" "$MAIN_MODEL" "$PLANNER_PROMPT"
ok "Plan: .loopos/current_plan.json"

# 读取任务列表
if [ ! -f .loopos/current_plan.json ]; then
  err "计划文件未生成"
  exit 1
fi

TASK_COUNT=$(python3 -c "import json; print(len(json.load(open('.loopos/current_plan.json')).get('tasks',[])))" 2>/dev/null || echo "0")
TASK_IDS=$(python3 -c "import json; print(' '.join(t['id'] for t in json.load(open('.loopos/current_plan.json')).get('tasks',[])))" 2>/dev/null || echo "")

log "Plan: $TASK_COUNT tasks → $TASK_IDS"

# ============================================================
# Phase 4: Critic 审查（≥3 tasks 时）
# ============================================================

if [ "$TASK_COUNT" -ge 3 ] 2>/dev/null; then
  log "========== Phase: Critic =========="

  run_agent "critic" "$MAIN_MODEL" \
    "审查 .loopos/current_plan.json 的工作计划。
ORIGINAL REQUEST: $REQUEST
ANALYST REPORT: .loopos/reports/analyst_pre_plan.json

检查任务范围、依赖关系、模型分配、缺失任务。
写报告到 .loopos/reports/critic_plan.json，只返回路径。"

  # 检查 critic 结论
  VERDICT=$(extract_json_field ".loopos/reports/critic_plan.json" "['verdict']")

  if [ "$VERDICT" = "REJECT" ]; then
    warn "Critic REJECTED plan, replanning..."
    run_agent "planner" "$MAIN_MODEL" \
      "计划被 critic 拒绝。
CRITIC REPORT: .loopos/reports/critic_plan.json
读取 critic 发现，修订计划。
写修订后的计划到 .loopos/current_plan.json。"
    ok "Plan revised"
  else
    ok "Critic: $VERDICT"
  fi
fi

# ============================================================
# Phase 5: Dev-Test Loop
# ============================================================

log "========== Phase: Dev-Test Loop =========="

# 提取任务列表
TASKS_JSON=$(python3 -c "
import json
plan = json.load(open('.loopos/current_plan.json'))
for t in plan.get('tasks', []):
    deps = ','.join(t.get('depends_on', []))
    model = t.get('assigned_model', '$MAIN_MODEL')
    print(f\"{t['id']}|{t.get('title','')}|{deps}|{model}\")
" 2>/dev/null)

# DAG 分层执行
COMPLETED=""
LAYER=0

while true; do
  LAYER=$((LAYER + 1))

  # 找出本层可执行的任务（依赖已完成）
  READY_TASKS=""
  while IFS='|' read -r tid title deps model; do
    [ -z "$tid" ] && continue

    # 检查是否已完成
    echo "$COMPLETED" | grep -qw "$tid" && continue

    # 检查依赖是否都已完成
    all_deps_done=true
    if [ -n "$deps" ]; then
      IFS=',' read -ra DEP_ARR <<< "$deps"
      for dep in "${DEP_ARR[@]}"; do
        echo "$COMPLETED" | grep -qw "$dep" || { all_deps_done=false; break; }
      done
    fi

    $all_deps_done && READY_TASKS="${READY_TASKS}${tid}|${title}|${deps}|${model}\n"
  done <<< "$TASKS_JSON"

  # 没有可执行任务 → 退出
  [ -z "$READY_TASKS" ] && break

  log "--- Layer $LAYER ---"

  LAYER_PASSED=""

  while IFS='|' read -r tid title deps model; do
    [ -z "$tid" ] && continue

    log "[$tid] Dev: $title → $model"

    # 开发
    run_agent "developer" "$model" \
      "TASK ID: $tid
TITLE: $title
读取 .loopos/current_plan.json 获取完整任务描述。
读取 .loopos/lessons.jsonl 了解过去教训。
实现任务，运行测试，写报告到 .loopos/reports/dev_${tid}.json。
Git commit: [$tid] $title"

    if [ ! -f ".loopos/reports/dev_${tid}.json" ]; then
      warn "[$tid] Dev report not generated, skipping"
      continue
    fi

    # 测试 + 审查 + 修复循环
    PASSED=false
    for attempt in $(seq 0 $MAX_FIX_RETRIES); do
      [ "$attempt" -gt 0 ] && log "[$tid] Fix attempt $attempt/$MAX_FIX_RETRIES"

      # Tester-Logic
      run_agent "tester-logic" "$FAST_MODEL" \
        "DEV REPORT: .loopos/reports/dev_${tid}.json
读取开发报告和变更文件，检查逻辑/边界/错误处理。
写报告到 .loopos/reports/test_logic_${tid}.json。"

      # Tester-Quality
      run_agent "tester-quality" "$FAST_MODEL" \
        "DEV REPORT: .loopos/reports/dev_${tid}.json
读取开发报告和变更文件，检查质量/安全/性能。
写报告到 .loopos/reports/test_quality_${tid}.json。"

      # Code-Reviewer
      run_agent "code-reviewer" "$MAIN_MODEL" \
        "DEV REPORT: .loopos/reports/dev_${tid}.json
读取开发报告和变更文件，做代码审查。
写报告到 .loopos/reports/review_${tid}.json。"

      # 检查结果
      LOGIC_PASS=$(extract_json_field ".loopos/reports/test_logic_${tid}.json" "['passed']")
      QUALITY_PASS=$(extract_json_field ".loopos/reports/test_quality_${tid}.json" "['passed']")
      REVIEW_VERDICT=$(extract_json_field ".loopos/reports/review_${tid}.json" "['verdict']")

      if [ "$LOGIC_PASS" = "True" ] && [ "$QUALITY_PASS" = "True" ] && [ "$REVIEW_VERDICT" = "APPROVE" ]; then
        PASSED=true
        ok "[$tid] Passed${attempt:+ (${attempt} fixes)} [$model]"
        break
      fi

      [ "$attempt" -ge "$MAX_FIX_RETRIES" ] && break

      # 修复
      log "[$tid] Issues found, fixing..."
      run_agent "debugger" "$model" \
        "修复任务 $tid 的问题。
DEV REPORT: .loopos/reports/dev_${tid}.json
LOGIC TEST: .loopos/reports/test_logic_${tid}.json
QUALITY TEST: .loopos/reports/test_quality_${tid}.json
CODE REVIEW: .loopos/reports/review_${tid}.json

读取所有报告，修复问题，更新 dev report。
Git commit: [$tid] fix: ..."
    done

    if $PASSED; then
      COMPLETED="${COMPLETED} ${tid}"
      LAYER_PASSED="${LAYER_PASSED} ${tid}"
    else
      warn "[$tid] Max retries reached, needs manual review"
    fi

  done < <(echo -e "$READY_TASKS")

  ok "Layer $LAYER complete: passed =${LAYER_PASSED:-none}"
done

# ============================================================
# Phase 6: Verify
# ============================================================

log "========== Phase: Verify =========="

run_agent "verifier" "$MAIN_MODEL" \
  "验证分支 $BRANCH 上所有已完成任务。
PLAN: .loopos/current_plan.json
COMPLETED TASKS: $COMPLETED

运行完整测试套件、类型检查、构建。
对照验收标准验证每个任务。
写报告到 .loopos/reports/verify_final.json。"

VERIFY_VERDICT=$(extract_json_field ".loopos/reports/verify_final.json" "['verdict']")
if [ "$VERIFY_VERDICT" = "PASS" ]; then
  ok "Verification: PASS"
else
  warn "Verification: ${VERIFY_VERDICT:-UNKNOWN}"
fi

# ============================================================
# Phase 7: Persist
# ============================================================

log "========== Phase: Persist =========="

# 更新 state（H4：优先用 state.sh 确定性写入，fallback 到原 python3）
if [ -f .loopos/state.sh ]; then
  for tid in $COMPLETED; do
    bash .loopos/state.sh complete-task "$tid" 2>/dev/null || true
  done
  bash .loopos/state.sh set-branch "$BRANCH" 2>/dev/null || true
else
  python3 -c "
import json
state = json.load(open('.loopos/state.json'))
completed = '${COMPLETED}'.split()
state['completed_tasks'].extend(completed)
state['total_tasks_run'] += len(completed)
state['current_branch'] = '$BRANCH'
json.dump(state, open('.loopos/state.json', 'w'), indent=2)
" 2>/dev/null || warn "Failed to update state.json"
fi

git add .loopos/
git commit -m "[loopos] update state after workflow run" --allow-empty 2>/dev/null || true

# ============================================================
# 完成报告
# ============================================================

PASSED_COUNT=$(echo "$COMPLETED" | wc -w | tr -d ' ')
TOTAL_COUNT="$TASK_COUNT"

echo ""
log "=========================================="
ok "Done on branch: $BRANCH"
log "Results: $PASSED_COUNT/$TOTAL_COUNT passed"
log "Model: $MAIN_MODEL"
echo ""
log "Next:"
log "  git diff main...$BRANCH     # 查看变更"
log "  git log main...$BRANCH      # 查看提交"
log "  gh pr create                 # 创建 PR"
log "=========================================="
