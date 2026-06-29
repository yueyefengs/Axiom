#!/usr/bin/env bash
# .loopos/state.sh — 确定性状态层（H4 修复：状态写入下沉 shell）
#
# JSON + jsonl 由 python3 原子操作（读-改-写临时文件 + os.replace），agent 只执行固定命令。
# 解决 H4 的写入风险：格式写坏 / 覆盖非 append / 漏字段 / state 与 event 不一致 / 半写损坏。
#
# 用法:
#   state.sh init
#   state.sh event <type> [k=v ...]                # append events.jsonl（自动加 ts）
#   state.sh complete-task <id> [model]            # state.json + event task_completed
#   state.sh fail-task <id> [reason]               # manual_review_needed.json + event task_failed
#   state.sh set-branch <branch>                   # state.json current_branch
#   state.sh set-summary <text...>                 # state.json project_summary
#   state.sh add-lesson '<json>'                   # append lessons.jsonl（自动加 ts）
#   state.sh add-decision '<json>'                 # decisions.json append
#   state.sh get <field>                           # 读 state.json 字段
#   state.sh get-completed                         # 读 completed_tasks（空格分隔）

set -euo pipefail

STATE_DIR="${LOOPOS_STATE_DIR:-.loopos}"
STATE_FILE="$STATE_DIR/state.json"
EVENTS_FILE="$STATE_DIR/events.jsonl"
DECISIONS_FILE="$STATE_DIR/decisions.json"
LESSONS_FILE="$STATE_DIR/lessons.jsonl"
MANUAL_REVIEW_FILE="$STATE_DIR/manual_review_needed.json"

mkdir -p "$STATE_DIR"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown"; }

# 原子写 JSON：python3 读-改-写，临时文件 + os.replace（不会半写损坏）
ju() {
  local file="$1" code="$2"
  python3 - "$file" <<PYEOF
import json, os, sys, tempfile
f = sys.argv[1]
try:
    d = json.load(open(f))
except Exception:
    d = {}
$code
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(f) or '.')
with os.fdopen(fd, 'w') as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
os.replace(tmp, f)
PYEOF
}

cmd_init() {
  [ -f "$STATE_FILE" ] || printf '%s\n' '{ "completed_tasks": [], "total_tasks_run": 0, "project_summary": "", "last_updated": "" }' > "$STATE_FILE"
  [ -f "$DECISIONS_FILE" ] || printf '%s\n' '{ "decisions": [] }' > "$DECISIONS_FILE"
  [ -f "$MANUAL_REVIEW_FILE" ] || printf '%s\n' '{ "tasks": [] }' > "$MANUAL_REVIEW_FILE"
  touch "$EVENTS_FILE" "$LESSONS_FILE"
  echo "initialized: $STATE_DIR"
}

cmd_event() {
  local type="${1:?event: type required}"; shift
  TYPE="$type" ARGS="$*" EVENTS_FILE="$EVENTS_FILE" python3 <<'PYEOF'
import json, os
from datetime import datetime, timezone
e = {"type": os.environ["TYPE"], "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
for kv in os.environ.get("ARGS", "").split():
    if "=" in kv:
        k, v = kv.split("=", 1)
        if v in ("true", "false"):
            e[k] = (v == "true")
        else:
            try:
                e[k] = int(v)
            except ValueError:
                e[k] = v
with open(os.environ["EVENTS_FILE"], "a") as fh:
    fh.write(json.dumps(e, ensure_ascii=False) + "\n")
PYEOF
  echo "event: $type"
}

cmd_complete_task() {
  local tid="${1:?complete-task: task_id required}" model="${2:-}"
  TID="$tid" ju "$STATE_FILE" "
tid = os.environ['TID']
d.setdefault('completed_tasks', [])
if tid not in d['completed_tasks']:
    d['completed_tasks'].append(tid)
    d['total_tasks_run'] = d.get('total_tasks_run', 0) + 1
d['last_updated'] = '$(ts)'
"
  cmd_event task_completed "task_id=$tid" ${model:+model=$model}
  echo "completed: $tid"
}

cmd_fail_task() {
  local tid="${1:?fail-task: task_id required}" reason="${2:-needs_manual_review}"
  TID="$tid" REASON="$reason" ju "$MANUAL_REVIEW_FILE" "
tid = os.environ['TID']
d.setdefault('tasks', [])
d['tasks'].append({'task_id': tid, 'reason': os.environ['REASON'], 'ts': '$(ts)'})
"
  cmd_event task_failed "task_id=$tid" "reason=$reason"
  echo "failed: $tid"
}

cmd_set_branch() {
  local branch="${1:?set-branch: branch required}"
  BRANCH="$branch" ju "$STATE_FILE" "
d['current_branch'] = os.environ['BRANCH']
d['last_updated'] = '$(ts)'
"
  echo "branch: $branch"
}

cmd_set_summary() {
  local summary="$*"
  SUMMARY="$summary" ju "$STATE_FILE" "
d['project_summary'] = os.environ['SUMMARY']
d['last_updated'] = '$(ts)'
"
  echo "summary set"
}

cmd_add_lesson() {
  local json_str="${1:?add-lesson: json required}"
  JSON_STR="$json_str" LESSONS_FILE="$LESSONS_FILE" python3 <<'PYEOF'
import json, os
from datetime import datetime, timezone
try:
    obj = json.loads(os.environ["JSON_STR"])
except Exception:
    obj = {"raw": os.environ["JSON_STR"]}
obj["ts"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(os.environ["LESSONS_FILE"], "a") as fh:
    fh.write(json.dumps(obj, ensure_ascii=False) + "\n")
PYEOF
  echo "lesson added"
}

cmd_add_decision() {
  local json_str="${1:?add-decision: json required}"
  JSON_STR="$json_str" ju "$DECISIONS_FILE" "
dec = json.loads(os.environ['JSON_STR'])
dec['ts'] = '$(ts)'
d.setdefault('decisions', []).append(dec)
"
  echo "decision added"
}

cmd_get() {
  local field="${1:?get: field required}"
  python3 -c "import json; print(json.load(open('$STATE_FILE')).get('$field',''))" 2>/dev/null || echo ""
}

cmd_get_completed() {
  python3 -c "import json; print(' '.join(json.load(open('$STATE_FILE')).get('completed_tasks',[])))" 2>/dev/null || echo ""
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  event) shift; cmd_event "$@" ;;
  complete-task) shift; cmd_complete_task "$@" ;;
  fail-task) shift; cmd_fail_task "$@" ;;
  set-branch) shift; cmd_set_branch "$@" ;;
  set-summary) shift; cmd_set_summary "$@" ;;
  add-lesson) shift; cmd_add_lesson "$@" ;;
  add-decision) shift; cmd_add_decision "$@" ;;
  get) shift; cmd_get "$@" ;;
  get-completed) shift; cmd_get_completed "$@" ;;
  *) echo "Usage: state.sh <init|event|complete-task|fail-task|set-branch|set-summary|add-lesson|add-decision|get|get-completed> ..." >&2; exit 1 ;;
esac
