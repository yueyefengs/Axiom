#!/usr/bin/env bash
# .loopos/adapter.sh - 统一模型路由适配器
# 用法: ./adapter.sh <provider> <model_id> <prompt_file> <workdir>
#
# 功能: 接收任务 prompt，路由到对应的 LLM CLI 执行，返回标准化结果
# 支持: claude / codex / deepseek / glm / 任意 OpenAI 兼容 API

set -euo pipefail

PROVIDER="${1:?Usage: adapter.sh <provider> <model_id> <prompt_file> <workdir>}"
MODEL_ID="${2:?}"
PROMPT_FILE="${3:?}"
WORKDIR="${4:-.}"

PROMPT=$(cat "$PROMPT_FILE")
RESULT_FILE="${WORKDIR}/.loopos/reports/adapter_result_$$.json"

mkdir -p "$(dirname "$RESULT_FILE")"

case "$PROVIDER" in

  claude)
    # Claude Code CLI: 原生支持，直接执行
    cd "$WORKDIR"
    OUTPUT=$(claude -p "$PROMPT" --model "$MODEL_ID" --output-format json 2>/dev/null) || OUTPUT=""

    echo "{\"provider\":\"claude\",\"model\":\"$MODEL_ID\",\"status\":\"completed\",\"output_file\":\"$RESULT_FILE\"}" > "$RESULT_FILE"
    echo "$OUTPUT" > "${RESULT_FILE%.json}.output.txt"
    ;;

  codex)
    # Codex CLI: 使用 exec 非交互模式
    cd "$WORKDIR"
    OUTPUT=$(codex exec -m "$MODEL_ID" --full-auto "$PROMPT" 2>/dev/null) || OUTPUT=""

    echo "{\"provider\":\"codex\",\"model\":\"$MODEL_ID\",\"status\":\"completed\",\"output_file\":\"$RESULT_FILE\"}" > "$RESULT_FILE"
    echo "$OUTPUT" > "${RESULT_FILE%.json}.output.txt"
    ;;

  deepseek)
    # DeepSeek API: 通过 OpenAI 兼容接口
    API_KEY="${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY not set}"
    API_BASE="${DEEPSEEK_API_BASE:-https://api.deepseek.com}"

    RESPONSE=$(curl -s "$API_BASE/v1/chat/completions" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"$MODEL_ID\",
        \"messages\": [{\"role\": \"user\", \"content\": $(echo "$PROMPT" | jq -Rs .)}],
        \"max_tokens\": 8192
      }") || RESPONSE=""

    # 提取 content
    OUTPUT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "ERROR: no response"')

    echo "{\"provider\":\"deepseek\",\"model\":\"$MODEL_ID\",\"status\":\"completed\",\"output_file\":\"$RESULT_FILE\"}" > "$RESULT_FILE"
    echo "$OUTPUT" > "${RESULT_FILE%.json}.output.txt"
    ;;

  glm|zhipu)
    # 智谱 GLM API
    API_KEY="${GLM_API_KEY:?GLM_API_KEY not set}"
    API_BASE="${GLM_API_BASE:-https://open.bigmodel.cn/api/paas/v4}"

    RESPONSE=$(curl -s "$API_BASE/chat/completions" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"$MODEL_ID\",
        \"messages\": [{\"role\": \"user\", \"content\": $(echo "$PROMPT" | jq -Rs .)}],
        \"max_tokens\": 8192
      }") || RESPONSE=""

    OUTPUT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "ERROR: no response"')

    echo "{\"provider\":\"glm\",\"model\":\"$MODEL_ID\",\"status\":\"completed\",\"output_file\":\"$RESULT_FILE\"}" > "$RESULT_FILE"
    echo "$OUTPUT" > "${RESULT_FILE%.json}.output.txt"
    ;;

  openai-compat)
    # 任意 OpenAI 兼容 API (ollama, vllm, openrouter 等)
    API_KEY="${OPENAI_COMPAT_API_KEY:-sk-none}"
    API_BASE="${OPENAI_COMPAT_API_BASE:?OPENAI_COMPAT_API_BASE not set}"

    RESPONSE=$(curl -s "$API_BASE/v1/chat/completions" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"$MODEL_ID\",
        \"messages\": [{\"role\": \"user\", \"content\": $(echo "$PROMPT" | jq -Rs .)}],
        \"max_tokens\": 8192
      }") || RESPONSE=""

    OUTPUT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "ERROR: no response"')

    echo "{\"provider\":\"openai-compat\",\"model\":\"$MODEL_ID\",\"status\":\"completed\",\"output_file\":\"$RESULT_FILE\"}" > "$RESULT_FILE"
    echo "$OUTPUT" > "${RESULT_FILE%.json}.output.txt"
    ;;

  *)
    echo "ERROR: Unknown provider: $PROVIDER" >&2
    echo "{\"provider\":\"$PROVIDER\",\"model\":\"$MODEL_ID\",\"status\":\"error\",\"error\":\"Unknown provider\"}" > "$RESULT_FILE"
    exit 1
    ;;
esac

echo "$RESULT_FILE"
