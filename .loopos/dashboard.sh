#!/usr/bin/env bash
# .loopos/dashboard.sh — LoopOS 运行时 dashboard（tmux + watch）
#
# 实时查看外部 worker 状态 + workflow 事件流 + 全局 state；控制停止/续连。
#
# 盲区（harness 限制）：Claude 原生子 agent（opus/sonnet/haiku 的 analyst/planner/dev/...）
# 的实时状态和 token 拿不到——harness 不向 workflow 暴露 subagent 内部。dashboard 只能显示
# 外部 worker 完整状态 + workflow 事件层（[LOOPLOG] 调用点：dev_start/passed/failed）。
#
# 用法:
#   dashboard.sh watch              # 启动 tmux 4-pane 实时 dashboard
#   dashboard.sh agents             # 外部 worker 状态快照
#   dashboard.sh events [N]         # 最近 N 条事件（默认 20）
#   dashboard.sh state              # 全局 state.json
#   dashboard.sh kill <sid>         # 停止外部 worker
#   dashboard.sh resume             # 断点续连提示

set -euo pipefail

LOOPOS_DIR="${LOOPOS_STATE_DIR:-.loopos}"
WORKER_DIR="$LOOPOS_DIR/workers"
LOG_FILE="$LOOPOS_DIR/logs/loopos.jsonl"
STATE_FILE="$LOOPOS_DIR/state.json"
TMUX_WORKER="$LOOPOS_DIR/tmux-worker.sh"

# 从 meta.json 读字段（手写 JSON）
meta_field() {
  local meta="$1" field="$2"
  grep -oE "\"$field\": *\"[^\"]*\"" "$meta" 2>/dev/null | head -1 \
    | sed -E 's/.*"'"$field"'": *"([^"]*)".*/\1/'
}

# 单个 worker 状态行
worker_row() {
  local meta="$1"
  [ -f "$meta" ] || return
  local sid provider model status token
  sid=$(meta_field "$meta" "session_id")
  provider=$(meta_field "$meta" "provider")
  model=$(meta_field "$meta" "model")
  status=$(meta_field "$meta" "status")
  token=$(grep -oE '"token_usage": *[0-9]+' "$meta" 2>/dev/null | head -1 | grep -oE '[0-9]+')
  printf "%-24s %-10s %-20s %-14s %s\n" "${sid:-?}" "${provider:-?}" "${model:-?}" "${status:-?}" "${token:--}"
}

cmd_agents() {
  echo "SID                     PROVIDER   MODEL                STATUS         TOKEN"
  echo "──────────────────────────────────────────────────────────────────────────"
  local found=0
  for meta in "$WORKER_DIR"/*.meta.json; do
    [ -f "$meta" ] || continue
    worker_row "$meta"
    found=1
  done
  [ "$found" = 0 ] && echo "(无 worker)"
}

cmd_events() {
  local n="${1:-20}"
  [ -f "$LOG_FILE" ] || { echo "(无事件日志: $LOG_FILE)"; return; }
  tail -n "$n" "$LOG_FILE" | python3 -c "
import sys, json
for l in sys.stdin:
    try:
        e = json.loads(l)
        extra = ' '.join(f'{k}={v}' for k,v in e.items() if k not in ('ts','event','sid'))
        print(f\"{e.get('ts','')[:19]}  {e.get('event','?'):<18} sid={e.get('sid',''):<22} {extra}\")
    except Exception:
        pass
"
}

cmd_events_follow() {
  [ -f "$LOG_FILE" ] || { echo "(无事件日志: $LOG_FILE，等待...)"; touch "$LOG_FILE"; }
  echo "=== 事件流 (tail -f $LOG_FILE) ==="
  tail -f "$LOG_FILE" 2>/dev/null | python3 -u -c "
import sys, json
for l in sys.stdin:
    try:
        e = json.loads(l)
        extra = ' '.join(f'{k}={v}' for k,v in e.items() if k not in ('ts','event','sid'))
        print(f\"{e.get('ts','')[:19]}  {e.get('event','?'):<18} sid={e.get('sid',''):<22} {extra}\")
        sys.stdout.flush()
    except Exception:
        pass
"
}

cmd_state() {
  [ -f "$STATE_FILE" ] || { echo "(无 state.json)"; return; }
  python3 -c "import json; print(json.dumps(json.load(open('$STATE_FILE')), indent=2, ensure_ascii=False))"
}

cmd_kill() {
  local sid="${1:?kill: session_id required}"
  bash "$TMUX_WORKER" kill "$sid"
}

cmd_resume() {
  cat <<EOF
=== 断点续连 ===

在主会话运行 supervisor-resume workflow：
  Workflow({ name: 'supervisor-resume', args: {} })

它会读 .loopos/state.json + manual_review_needed.json + current_plan.json，
续跑未完成 / 失败 / needs_review 的任务。

当前进度：
EOF
  [ -f "$STATE_FILE" ] && python3 -c "
import json
s = json.load(open('$STATE_FILE'))
print(f\"  completed: {len(s.get('completed_tasks',[]))} tasks\")
print(f\"  total_run: {s.get('total_tasks_run',0)}\")
print(f\"  branch:    {s.get('current_branch','?')}\")
" 2>/dev/null || echo "  (state.json 不可读)"
}

cmd_help_pane() {
  cat <<'EOF'
=== LoopOS Dashboard 控制 ===

在普通终端跑（非此 tmux pane）:
  bash .loopos/dashboard.sh agents          # worker 状态快照
  bash .loopos/dashboard.sh events [N]      # 最近 N 条事件
  bash .loopos/dashboard.sh kill <sid>      # 停止外部 worker
  bash .loopos/dashboard.sh resume          # 断点续连提示

停整个 workflow : /tasks (harness 层，LoopOS 代码层做不到)
退出 dashboard  : Ctrl-b d (detach，后台继续) / Ctrl-b x (杀 session)

盲区: Claude 子 agent 的实时状态/token 拿不到 (harness 限制)；
      只能从事件流看调用点 (dev_start/passed/failed)。
EOF
  sleep 86400
}

cmd_watch() {
  command -v tmux >/dev/null 2>&1 || { echo "ERROR: tmux not installed" >&2; exit 1; }
  local sess="loopos-dashboard"
  tmux kill-session -t "$sess" 2>/dev/null || true

  # 4-pane 布局：事件流 | worker 状态  /  state | 控制
  tmux new-session -d -s "$sess" -n dash "bash '$0' events-follow"
  tmux split-window -h -t "$sess:0.0" "while true; do clear; echo '=== 外部 worker 状态（2s 刷新）==='; bash '$0' agents; sleep 2; done"
  tmux split-window -v -t "$sess:0.0" "bash '$0' help-pane"
  tmux split-window -v -t "$sess:0.1" "while true; do clear; echo '=== 全局 state（3s 刷新）==='; bash '$0' state; sleep 3; done"
  tmux select-layout -t "$sess" tiled

  echo "dashboard 已启动。 attaching..."
  echo "退出: Ctrl-b d (detach) 或 Ctrl-b x (杀)"
  tmux attach -t "$sess"
}

case "${1:-}" in
  watch)    shift; cmd_watch "$@" ;;
  agents)   shift; cmd_agents "$@" ;;
  events)   shift; cmd_events "$@" ;;
  events-follow) shift; cmd_events_follow "$@" ;;
  state)    shift; cmd_state "$@" ;;
  kill)     shift; cmd_kill "$@" ;;
  resume)   shift; cmd_resume "$@" ;;
  help-pane) shift; cmd_help_pane "$@" ;;
  *) cat <<EOF
Usage: dashboard.sh <watch|agents|events|state|kill|resume> ...

  watch              启动 tmux 4-pane 实时 dashboard（事件流 / worker / state / 控制）
  agents             外部 worker 状态快照
  events [N]         最近 N 条事件（默认 20）
  state              全局 state.json
  kill <sid>         停止外部 worker
  resume             断点续连提示（supervisor-resume）

盲区: Claude 子 agent 实时状态/token 拿不到（harness 限制）。
EOF
     ;;
esac
