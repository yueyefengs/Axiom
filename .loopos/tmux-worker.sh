#!/usr/bin/env bash
# .loopos/tmux-worker.sh — tmux-based CLI worker for opencode/codex/gemini/cursor + API fallback
#
# 用法:
#   ./tmux-worker.sh spawn <provider> <model> <prompt_file> <workdir>
#   ./tmux-worker.sh status <session_id>
#   ./tmux-worker.sh collect <session_id>
#   ./tmux-worker.sh kill <session_id>
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

# ============================================================
# spawn — 启动 worker
# ============================================================

do_spawn() {
  local provider="${1:?spawn: provider required}"
  local model="${2:?spawn: model required}"
  local prompt_file="${3:?spawn: prompt_file required}"
  local workdir="${4:-.}"
  local sid
  sid=$(generate_session_id)

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
      ) &

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
      ) &

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
      ) &

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
      ) &

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
      ) &

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
  local meta="$WORKER_DIR/$sid.meta.json"

  if [ ! -f "$meta" ]; then
    echo "{\"session_id\":\"$sid\",\"status\":\"not_found\"}"
    return 1
  fi

  local exit_code_file="$WORKER_DIR/$sid.exit_code"

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
# collect — 收集结果 + 清理
# ============================================================

do_collect() {
  local sid="${1:?collect: session_id required}"
  local stdout_file="$WORKER_DIR/$sid.stdout"
  local stderr_file="$WORKER_DIR/$sid.stderr"
  local result_file="$WORKER_DIR/$sid.result.json"

  # Get final status
  local status_json
  status_json=$(do_status "$sid" 2>/dev/null || true)
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

  # Kill tmux session if still alive
  tmux kill-session -t "$sid" 2>/dev/null || true

  echo "$result_file"
}

# ============================================================
# kill — 强制终止
# ============================================================

do_kill() {
  local sid="${1:?kill: session_id required}"
  tmux kill-session -t "$sid" 2>/dev/null || true
  echo "killed" > "$WORKER_DIR/$sid.exit_code"
  update_status "$sid" "killed"
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
# Dispatch
# ============================================================

case "$ACTION" in
  spawn)   shift; do_spawn "$@" ;;
  status)  shift; do_status "$@" ;;
  collect) shift; do_collect "$@" ;;
  kill)    shift; do_kill "$@" ;;
  list)    do_list ;;
  *)       echo "Unknown action: $ACTION"; exit 1 ;;
esac
