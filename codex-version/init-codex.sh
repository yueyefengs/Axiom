#!/usr/bin/env bash
# init-loopos-codex.sh — 将 Codex 版 LoopOS 初始化到目标项目
#
# 用法:
#   cd ~/code/my-project && bash ~/code/Axiom/codex-version/init-codex.sh
#   bash ~/code/Axiom/codex-version/init-codex.sh ~/code/my-project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.}"

echo "LoopOS (Codex 版) 初始化 → $TARGET"
echo ""

# 创建目录
mkdir -p "$TARGET/.codex/agents" \
         "$TARGET/.codex/scripts" \
         "$TARGET/.loopos/reports" \
         "$TARGET/.loopos/workers" \
         "$TARGET/.loopos/specs"

# 复制 agents
echo "📋 Agents:"
for f in "$SCRIPT_DIR/agents"/*.md; do
  name=$(basename "$f")
  cp "$f" "$TARGET/.codex/agents/$name"
  echo "  ✓ $name"
done

# 复制 scripts
echo ""
echo "⚙️  Scripts:"
cp "$SCRIPT_DIR/scripts/supervisor.sh" "$TARGET/.codex/scripts/"
chmod +x "$TARGET/.codex/scripts/supervisor.sh"
echo "  ✓ supervisor.sh"

# 复制 codex.md
cp "$SCRIPT_DIR/codex.md" "$TARGET/codex.md"
echo "  ✓ codex.md"

# 复制 .loopos 配置
echo ""
echo "📁 Config:"
cp "$SCRIPT_DIR/loopos/models.json" "$TARGET/.loopos/models.json"
echo "  ✓ models.json"

# 复制 tmux-worker / state / dashboard（从 Claude 版 .loopos/ 共享）
for f in tmux-worker.sh state.sh dashboard.sh; do
  if [ -f "$SCRIPT_DIR/../.loopos/$f" ]; then
    cp "$SCRIPT_DIR/../.loopos/$f" "$TARGET/.loopos/$f"
    chmod +x "$TARGET/.loopos/$f"
    echo "  ✓ $f"
  fi
done

# 初始化状态
if [ ! -f "$TARGET/.loopos/state.json" ]; then
  echo '{ "completed_tasks": [], "total_tasks_run": 0, "project_summary": "" }' > "$TARGET/.loopos/state.json"
  echo "  ✓ state.json (新建)"
fi
if [ ! -f "$TARGET/.loopos/decisions.json" ]; then
  echo '{ "decisions": [] }' > "$TARGET/.loopos/decisions.json"
  echo "  ✓ decisions.json (新建)"
fi

# .gitignore
echo ""
if [ -f "$TARGET/.gitignore" ]; then
  if ! grep -q "LoopOS" "$TARGET/.gitignore" 2>/dev/null; then
    cat >> "$TARGET/.gitignore" <<'IGNORE'

# LoopOS
.loopos/reports/
.loopos/workers/
.loopos/specs/
IGNORE
    echo "📝 .gitignore 已更新"
  fi
else
  cat > "$TARGET/.gitignore" <<'IGNORE'
# LoopOS
.loopos/reports/
.loopos/workers/
.loopos/specs/
IGNORE
  echo "📝 .gitignore 已创建"
fi

# 统计
AGENT_COUNT=$(ls "$TARGET/.codex/agents"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "✅ 完成: ${AGENT_COUNT} agents, 1 orchestrator, codex.md"
echo ""
echo "使用方式:"
echo "  cd $TARGET"
echo "  bash .codex/scripts/supervisor.sh \"你的需求\""
echo ""
echo "主模型: gpt-5.4-pro"
echo "快速模型: gpt-5.4-mini"
