#!/usr/bin/env bash
# .loopos/tmux-worker.sh — tmux-based CLI worker for opencode/codex/gemini/cursor + API fallback
#
# 用法:
#   ./tmux-worker.sh spawn <provider> <model> <prompt_file> <workdir>
#   ./tmux-worker.sh resume <session_id> <prompt_file> [round]   # 续接 opencode session（保留上下文）
#   ./tmux-worker.sh status <session_id> [round]
#   ./tmux-worker.sh collect <session_id> [round]                # collect 会回填 opencode_session_id
#   ./tmux-worker.sh kill <session_id>
#   ./tmux-worker.sh wait <session_id> [round] [timeout]   # 阻塞到终态（确定性 shell 轮询，替代 agent 自由 poll）
#   ./tmux-worker.sh list
#
# 支持的 provider:
#   opencode — OpenCode CLI (推荐，统一网关，支持所有模型)
#              模型格式: provider/model (如 anthropic/claude-opus-4-6, openai/gpt-5.4-pro)
#   codex    — OpenAI Codex CLI (codex exec)
#   gemini   — Google Gemini CLI
#   cursor   — Cursor Agent CLI
#   deepseek — DeepSeek (通过 opencode 网关, 模型格式: deepseek/model)
#   glm      — 智谱 GLM (通过 opencode 网关, 模型格式: zhipu/model)
#
# 与 adapter.sh 的区别:
#   - 所有模型统一在 tmux 终端中通过 opencode/codex/gemini/cursor 运行
#   - 支持异步：spawn 立即返回 session_id, 用 status/collect 轮询结果
#   - 支持超时和优雅关闭

set -euo pipefail

ACTION="${1:?Usage: tmux-worker.sh <spawn|status|collect|kill|list> ...}"

WORKER_DIR="${LOOPOS_WORKER_DIR:-.loopos/workers}"
WORKER_TIMEOUT="${LOOPOS_WORKER_TIMEOUT:-600}"  # 10 minutes default

mkdir -p "$WORKER_DIR"

# ============================================================
# Helpers
# ============================================================

# 统一日志：append JSONL 到 .loopos/logs/loopos.jsonl（shell 确定性，覆盖外部 worker 全生命周期）
# extra 形如 `,"provider":"opencode","model":"openai/o3"`（已含前导逗号，值需自行转义）
# 全程 || true —— 日志失败绝不中断主流程
LOOPOS_LOG_FILE="${LOOPOS_LOG_FILE:-.loopos/logs/loopos.jsonl}"

log_event() {
  local event="$1" sid="${2:-}" extra="${3:-}"
  mkdir -p "$(dirname "$LOOPOS_LOG_FILE")" 2>/dev/null || true
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
  printf '{"ts":"%s","event":"%s","sid":"%s"%s}\n' "$ts" "$event" "$sid" "$extra" >> "$LOOPOS_LOG_FILE" 2>/dev/null || true
}

generate_session_id() {
  echo "loopos-$$-$(date +%s)"
}

write_meta() {
  local sid="$1" provider="$2" model="$3" workdir="$4" status="$5"
  cat > "$WORKER_DIR/$sid.meta.json" <<METAEOF
{
  "session_id": "$sid",
  "provider": "$provider",
  "model": "$model",
  "workdir": "$workdir",
  "status": "$status",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pid": "${6:-}"
}
METAEOF
}

update_status() {
  local sid="$1" new_status="$2"
  if [ -f "$WORKER_DIR/$sid.meta.json" ]; then
    # portable: rewrite the file
    local tmp="$WORKER_DIR/$sid.meta.tmp"
    sed "s/\"status\": \"[^\"]*\"/\"status\": \"$new_status\"/" \
      "$WORKER_DIR/$sid.meta.json" > "$tmp" && mv "$tmp" "$WORKER_DIR/$sid.meta.json"
  fi
}

# 从 meta.json 读取单个字段值（手写 JSON，字段格式 "key": "value"）
get_meta_field() {
  local meta="$1" field="$2"
  grep -oE "\"$field\": *\"[^\"]*\"" "$meta" 2>/dev/null | head -1 \
    | sed -E 's/.*"'"$field"'": *"([^"]*)".*/\1/'
}

# 从 opencode 的 --format json 事件流文件中提取 sessionID (ses_xxx)
extract_opencode_session() {
  local file="$1"
  grep -oE 'ses_[A-Za-z0-9]+' "$file" 2>/dev/null | head -1
}

# 把 opencode_session_id 写回 meta（续接凭证）。若已存在则更新，否则在 status 行前插入
# 用 awk 而非 sed i 命令 —— BSD sed (macOS) 的 i\ 语法与 GNU 不兼容
set_opencode_session() {
  local sid="$1" oc_ses="$2"
  local meta="$WORKER_DIR/$sid.meta.json"
  [ -f "$meta" ] || return 0
  [ -n "$oc_ses" ] || return 0
  local tmp="$WORKER_DIR/$sid.meta.tmp"
  if grep -q '"opencode_session_id"' "$meta"; then
    awk -v ses="$oc_ses" '{ sub(/"opencode_session_id": *"[^"]*"/, "\"opencode_session_id\": \"" ses "\""); print }' \
      "$meta" > "$tmp" && mv "$tmp" "$meta"
  else
    awk -v ses="$oc_ses" '/"status":/{ print "  \"opencode_session_id\": \"" ses "\"," } { print }' \
      "$meta" > "$tmp" && mv "$tmp" "$meta"
  fi
}

# 判断 provider 是否走 opencode 网关（其 stdout 含 ses_xxx 可续接）
is_opencode_provider() {
  case "$1" in
    opencode|deepseek|glm|zhipu) return 0 ;;
    *) return 1 ;;
  esac
}

# ============================================================
# spawn — 启动 worker
# ============================================================

do_spawn() {
  local provider="${1:?spawn: provider required}"
  local model="${2:?spawn: model required}"
  local prompt_file="${3:?spawn: prompt_file required}"
  local workdir="${4:-.}"
  # 解析为绝对路径：opencode session 按目录存储，续接(resume)必须回到首轮同目录
  workdir=$(cd "$workdir" 2>/dev/null && pwd || echo "$workdir")
  local sid
  sid=$(generate_session_id)

  log_event "spawn" "$sid" ",\"provider\":\"$provider\",\"model\":\"$model\",\"workdir\":\"$workdir\""

  local prompt
  prompt=$(cat "$prompt_file")

  local stdout_file="$WORKER_DIR/$sid.stdout"
  local stderr_file="$WORKER_DIR/$sid.stderr"
  local result_file="$WORKER_DIR/$sid.result.json"

  case "$provider" in

    opencode)
      # OpenCode CLI — 统一网关，支持所有 provider/model
      # 模型格式: provider/model (如 anthropic/claude-opus-4-6, openai/gpt-5.4-pro)
      if ! command -v tmux &>/dev/null; then
        echo "ERROR: tmux not installed" >&2; exit 1
      fi
      if ! command -v opencode &>/dev/null; then
        echo "ERROR: opencode not installed (see https://opencode.ai)" >&2; exit 1
      fi

      write_meta "$sid" "$provider" "$model" "$workdir" "running"

      tmux new-session -d -s "$sid" -c "$workdir" \
        "opencode run --format json -m '$model' < '$prompt_file' > '$stdout_file' 2> '$stderr_file'; echo \$? > '$WORKER_DIR/$sid.exit_code'; tmux wait-for -S $sid-done" 2>/dev/null

      # Background watchdog for timeout
      (
        sleep "$WORKER_TIMEOUT"
        if tmux has-session -t "$sid" 2>/dev/null; then
          tmux kill-session -t "$sid" 2>/dev/null
          echo "timeout" > "$WORKER_DIR/$sid.exit_code"
          update_status "$sid" "timeout"
        fi
      ) </dev/null >/dev/null 2>&1 &

      echo "{\"session_id\":\"$sid\",\"provider\":\"$provider\",\"model\":\"$model\",\"status\":\"running\"}"
      ;;

    codex)
      # Codex CLI — 在 tmux 中运行，有完整文件系统访问
      if ! command -v tmux &>/dev/null; then
        echo "ERROR: tmux not installed" >&2; exit 1
      fi
      if ! command -v codex &>/dev/null; then
        echo "ERROR: codex CLI not installed (npm i -g @openai/codex)" >&2; exit 1
      fi

      write_meta "$sid" "$provider" "$model" "$workdir" "running"

      tmux new-session -d -s "$sid" -c "$workdir" \
        "codex exec -m $model --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check < '$prompt_file' > '$stdout_file' 2> '$stderr_file'; echo \$? > '$WORKER_DIR/$sid.exit_code'; tmux wait-for -S $sid-done" 2>/dev/null

      # Background watchdog for timeout
      (
        sleep "$WORKER_TIMEOUT"
        if tmux has-session -t "$sid" 2>/dev/null; then
          tmux kill-session -t "$sid" 2>/dev/null
          echo "timeout" > "$WORKER_DIR/$sid.exit_code"
          update_status "$sid" "timeout"
        fi
      ) </dev/null >/dev/null 2>&1 &

      echo "{\"session_id\":\"$sid\",\"provider\":\"$provider\",\"model\":\"$model\",\"status\":\"running\"}"
      ;;

    gemini)
      if ! command -v tmux &>/dev/null; then
        echo "ERROR: tmux not installed" >&2; exit 1
      fi
      if ! command -v gemini &>/dev/null; then
        echo "ERROR: gemini CLI not installed (npm i -g @google/gemini-cli)" >&2; exit 1
      fi

      write_meta "$sid" "$provider" "$model" "$workdir" "running"

      local model_flag=""
      [ -n "$model" ] && [ "$model" != "default" ] && model_flag="--model $model"

      tmux new-session -d -s "$sid" -c "$workdir" \
        "gemini --approval-mode yolo $model_flag < '$prompt_file' > '$stdout_file' 2> '$stderr_file'; echo \$? > '$WORKER_DIR/$sid.exit_code'; tmux wait-for -S $sid-done" 2>/dev/null

      (
        sleep "$WORKER_TIMEOUT"
        if tmux has-session -t "$sid" 2>/dev/null; then
          tmux kill-session -t "$sid" 2>/dev/null
          echo "timeout" > "$WORKER_DIR/$sid.exit_code"
          update_status "$sid" "timeout"
        fi
      ) </dev/null >/dev/null 2>&1 &

      echo "{\"session_id\":\"$sid\",\"provider\":\"$provider\",\"model\":\"$model\",\"status\":\"running\"}"
      ;;

    cursor)
      if ! command -v tmux &>/dev/null; then
        echo "ERROR: tmux not installed" >&2; exit 1
      fi
      if ! command -v cursor-agent &>/dev/null; then
        echo "ERROR: cursor-agent CLI not installed" >&2; exit 1
      fi

      write_meta "$sid" "$provider" "$model" "$workdir" "running"

      tmux new-session -d -s "$sid" -c "$workdir" \
        "cursor-agent '$prompt' > '$stdout_file' 2> '$stderr_file'; echo \$? > '$WORKER_DIR/$sid.exit_code'; tmux wait-for -S $sid-done" 2>/dev/null

      (
        sleep "$WORKER_TIMEOUT"
        if tmux has-session -t "$sid" 2>/dev/null; then
          tmux kill-session -t "$sid" 2>/dev/null
          echo "timeout" > "$WORKER_DIR/$sid.exit_code"
          update_status "$sid" "timeout"
        fi
      ) </dev/null >/dev/null 2>&1 &

      echo "{\"session_id\":\"$sid\",\"provider\":\"$provider\",\"model\":\"$model\",\"status\":\"running\"}"
      ;;

    deepseek|glm|zhipu)
      # 统一走 opencode 网关，模型格式: provider/model
      if ! command -v tmux &>/dev/null; then
        echo "ERROR: tmux not installed" >&2; exit 1
      fi
      if ! command -v opencode &>/dev/null; then
        echo "ERROR: opencode not installed (see https://opencode.ai)" >&2; exit 1
      fi

      # 构造 opencode 模型格式: provider/model
      local oc_model="$provider/$model"

      write_meta "$sid" "$provider" "$model" "$workdir" "running"

      tmux new-session -d -s "$sid" -c "$workdir" \
        "opencode run --format json -m '$oc_model' < '$prompt_file' > '$stdout_file' 2> '$stderr_file'; echo \$? > '$WORKER_DIR/$sid.exit_code'; tmux wait-for -S $sid-done" 2>/dev/null

      # Background watchdog for timeout
      (
        sleep "$WORKER_TIMEOUT"
        if tmux has-session -t "$sid" 2>/dev/null; then
          tmux kill-session -t "$sid" 2>/dev/null
          echo "timeout" > "$WORKER_DIR/$sid.exit_code"
          update_status "$sid" "timeout"
        fi
      ) </dev/null >/dev/null 2>&1 &

      echo "{\"session_id\":\"$sid\",\"provider\":\"$provider\",\"model\":\"$model\",\"status\":\"running\"}"
      ;;

    *)
      echo "ERROR: Unknown provider: $provider" >&2
      exit 1
      ;;
  esac
}

# ============================================================
# status — 检查 worker 状态
# ============================================================

do_status() {
  local sid="${1:?status: session_id required}"
  local round="${2:-}"
  local meta="$WORKER_DIR/$sid.meta.json"

  if [ ! -f "$meta" ]; then
    echo "{\"session_id\":\"$sid\",\"status\":\"not_found\"}"
    return 1
  fi

  local exit_code_file="$WORKER_DIR/$sid.exit_code"
  [ -n "$round" ] && exit_code_file="$WORKER_DIR/$sid.exit_code.r$round"

  if [ -f "$exit_code_file" ]; then
    local code
    code=$(cat "$exit_code_file")
    if [ "$code" = "timeout" ]; then
      update_status "$sid" "timeout"
      echo "{\"session_id\":\"$sid\",\"status\":\"timeout\"}"
    elif [ "$code" = "0" ]; then
      update_status "$sid" "completed"
      echo "{\"session_id\":\"$sid\",\"status\":\"completed\"}"
    else
      update_status "$sid" "failed"
      echo "{\"session_id\":\"$sid\",\"status\":\"failed\",\"exit_code\":$code}"
    fi
  else
    # Still running — check tmux session
    if tmux has-session -t "$sid" 2>/dev/null; then
      echo "{\"session_id\":\"$sid\",\"status\":\"running\"}"
    else
      # tmux session gone but no exit code — crashed
      echo "1" > "$exit_code_file"
      update_status "$sid" "crashed"
      echo "{\"session_id\":\"$sid\",\"status\":\"crashed\"}"
    fi
  fi
}

# ============================================================
# wait — 阻塞轮询直到终态或内部超时，返回最终 status JSON（C4 确定性 shell 轮询）
# 替代 agent 自由 poll：轮询确定性下沉到 shell，调用方只需在返回 running 时再调一次
# 用法: wait <session_id> [round] [timeout_secs]   默认 timeout=110s (< Bash 默认 120s 超时)
# ============================================================
do_wait() {
  local sid="${1:?wait: session_id required}"
  local round="${2:-}"
  local timeout="${3:-${LOOPOS_WAIT_TIMEOUT:-110}}"
  local elapsed=0
  local status_json=""
  while [ "$elapsed" -lt "$timeout" ]; do
    status_json=$(do_status "$sid" "$round" 2>/dev/null || true)
    case "$status_json" in
      *'"status":"running"'*)
        sleep 5
        elapsed=$((elapsed + 5))
        ;;
      *)
        # 终态：completed/failed/timeout/crashed/not_found
        echo "$status_json"
        return 0
        ;;
    esac
  done
  # 内部超时仍 running — 返回当前 status，调用方可再 wait
  echo "${status_json:-{\"session_id\":\"$sid\",\"status\":\"unknown\"}}"
}

# ============================================================
# collect — 收集结果 + 清理
# ============================================================

do_collect() {
  local sid="${1:?collect: session_id required}"
  local round="${2:-}"
  local meta="$WORKER_DIR/$sid.meta.json"
  local stdout_file="$WORKER_DIR/$sid.stdout"
  local stderr_file="$WORKER_DIR/$sid.stderr"
  local result_file="$WORKER_DIR/$sid.result.json"
  if [ -n "$round" ]; then
    stdout_file="$WORKER_DIR/$sid.stdout.r$round"
    stderr_file="$WORKER_DIR/$sid.stderr.r$round"
    result_file="$WORKER_DIR/$sid.result.r$round.json"
  fi

  # Get final status
  local status_json
  status_json=$(do_status "$sid" "$round" 2>/dev/null || true)
  local status
  status=$(echo "$status_json" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

  # Build result
  local output=""
  [ -f "$stdout_file" ] && output=$(cat "$stdout_file")

  local errors=""
  [ -f "$stderr_file" ] && errors=$(cat "$stderr_file")

  cat > "$result_file" <<RESULTEOF
{
  "session_id": "$sid",
  "status": "$status",
  "output_file": "$stdout_file",
  "error_file": "$stderr_file",
  "result_file": "$result_file"
}
RESULTEOF

  # 回填 opencode_session_id：opencode 系 provider 的 stdout 是 json 事件流，含 ses_xxx
  # 首轮跑完后 meta 即拥有续接凭证；后续轮 resume 也会刷新
  if is_opencode_provider "$(get_meta_field "$meta" "provider")"; then
    local oc_ses
    oc_ses=$(extract_opencode_session "$stdout_file")
    set_opencode_session "$sid" "$oc_ses"
  fi

  # Kill tmux session if still alive (resume 复用同名 session，一并清理)
  tmux kill-session -t "$sid" 2>/dev/null || true

  log_event "collect" "$sid" ",\"status\":\"$status\""

  echo "$result_file"
}

# ============================================================
# resume — 续接 opencode session，带新 prompt 继续对话（保留上下文）
# ============================================================
# 用法: ./tmux-worker.sh resume <session_id> <prompt_file> [round]
# 前提: 首轮 spawn+collect 已在 meta 里回填 opencode_session_id
# round: 续接轮次号(>=2)，决定输出文件后缀 .r<round>，默认 2
do_resume() {
  local sid="${1:?resume: session_id required}"
  local prompt_file="${2:?resume: prompt_file required}"
  local round="${3:-2}"
  local meta="$WORKER_DIR/$sid.meta.json"

  [ -f "$meta" ] || { echo "ERROR: no meta for $sid (spawn first)" >&2; exit 1; }
  [ -f "$prompt_file" ] || { echo "ERROR: prompt file not found: $prompt_file" >&2; exit 1; }

  command -v tmux >/dev/null 2>&1 || { echo "ERROR: tmux not installed" >&2; exit 1; }
  command -v opencode >/dev/null 2>&1 || { echo "ERROR: opencode not installed" >&2; exit 1; }

  local oc_ses provider model workdir
  oc_ses=$(get_meta_field "$meta" "opencode_session_id")
  provider=$(get_meta_field "$meta" "provider")
  model=$(get_meta_field "$meta" "model")
  workdir=$(get_meta_field "$meta" "workdir")

  [ -n "$oc_ses" ] || {
    echo "ERROR: no opencode_session_id in meta. Run 'collect' on the first round first." >&2
    exit 1
  }
  [ -n "$workdir" ] || workdir="."

  # deepseek/glm/zhipu 走 opencode 网关需 provider/model 格式
  local oc_model="$model"
  case "$provider" in
    deepseek|glm|zhipu) oc_model="$provider/$model" ;;
  esac

  local stdout_file="$WORKER_DIR/$sid.stdout.r$round"
  local stderr_file="$WORKER_DIR/$sid.stderr.r$round"

  update_status "$sid" "running"

  log_event "resume" "$sid" ",\"round\":$round,\"oc_session\":\"$oc_ses\""

  # 复用同名 tmux session：先清掉可能的残留（首轮正常已自毁），再新建
  tmux kill-session -t "$sid" 2>/dev/null || true
  tmux new-session -d -s "$sid" -c "$workdir" \
    "opencode run -s '$oc_ses' --format json -m '$oc_model' < '$prompt_file' > '$stdout_file' 2> '$stderr_file'; echo \$? > '$WORKER_DIR/$sid.exit_code.r$round'; tmux wait-for -S ${sid}-r${round}-done" 2>/dev/null

  # Background watchdog for timeout
  (
    sleep "$WORKER_TIMEOUT"
    if tmux has-session -t "$sid" 2>/dev/null; then
      tmux kill-session -t "$sid" 2>/dev/null
      echo "timeout" > "$WORKER_DIR/$sid.exit_code.r$round"
      update_status "$sid" "timeout"
    fi
  ) </dev/null >/dev/null 2>&1 &

  echo "{\"session_id\":\"$sid\",\"round\":$round,\"opencode_session_id\":\"$oc_ses\",\"status\":\"running\"}"
}

# ============================================================
# kill — 强制终止
# ============================================================

do_kill() {
  local sid="${1:?kill: session_id required}"
  tmux kill-session -t "$sid" 2>/dev/null || true
  echo "killed" > "$WORKER_DIR/$sid.exit_code"
  update_status "$sid" "killed"
  log_event "kill" "$sid"
  echo "{\"session_id\":\"$sid\",\"status\":\"killed\"}"
}

# ============================================================
# list — 列出所有 worker
# ============================================================

do_list() {
  echo "["
  local first=true
  for meta in "$WORKER_DIR"/*.meta.json; do
    [ -f "$meta" ] || continue
    $first || echo ","
    first=false
    cat "$meta"
  done
  echo "]"
}

# ============================================================
# log — 通用日志入口（供 hook / 外部调用记录会话级事件）
# ============================================================
do_log() {
  local event="${1:?log: event required}"
  local extra="${2:-}"
  log_event "$event" "" "$extra"
}

# ============================================================
# Dispatch
# ============================================================

case "$ACTION" in
  spawn)   shift; do_spawn "$@" ;;
  resume)  shift; do_resume "$@" ;;
  status)  shift; do_status "$@" ;;
  wait)    shift; do_wait "$@" ;;
  collect) shift; do_collect "$@" ;;
  kill)    shift; do_kill "$@" ;;
  log)     shift; do_log "$@" ;;
  list)    do_list ;;
  *)       echo "Unknown action: $ACTION"; exit 1 ;;
esac
