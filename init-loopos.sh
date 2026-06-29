#!/usr/bin/env bash
# LoopOS 初始化脚本
# 用法: bash /path/to/init-loopos.sh [目标项目目录]
#
# 示例:
#   cd ~/code/my-new-project && bash ~/code/Axiom/init-loopos.sh
#   bash ~/code/Axiom/init-loopos.sh ~/code/my-new-project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.}"

# 源文件目录（Axiom 项目）
AGENTS_SRC="$SCRIPT_DIR/.claude/agents"
WORKFLOWS_SRC="$SCRIPT_DIR/.claude/workflows"
LOOPOS_SRC="$SCRIPT_DIR/.loopos"

# 检查源文件存在
if [ ! -d "$AGENTS_SRC" ]; then
  echo "ERROR: 找不到 $AGENTS_SRC" >&2
  echo "请确保从 Axiom 项目根目录运行此脚本" >&2
  exit 1
fi

echo "LoopOS 初始化 → $TARGET"
echo ""

# 创建目录
mkdir -p "$TARGET/.claude/agents" \
         "$TARGET/.claude/workflows" \
         "$TARGET/.loopos/reports" \
         "$TARGET/.loopos/workers" \
         "$TARGET/.loopos/specs"

# 复制 agents (11 个)
echo "📋 Agents:"
for f in "$AGENTS_SRC"/*.md; do
  name=$(basename "$f")
  cp "$f" "$TARGET/.claude/agents/$name"
  echo "  ✓ $name"
done

# 复制 workflows (3 个)
echo ""
echo "⚙️  Workflows:"
for f in supervisor-worker-demo.js deep-interview.js PROTOCOL.md; do
  if [ -f "$WORKFLOWS_SRC/$f" ]; then
    cp "$WORKFLOWS_SRC/$f" "$TARGET/.claude/workflows/$f"
    echo "  ✓ $f"
  fi
done

# 复制 .loopos 配置
echo ""
echo "📁 Config:"
for f in models.json agent-models.json tmux-worker.sh; do
  if [ -f "$LOOPOS_SRC/$f" ]; then
    cp "$LOOPOS_SRC/$f" "$TARGET/.loopos/$f"
    echo "  ✓ $f"
  fi
done

# 初始化状态文件（不覆盖已有的）
if [ ! -f "$TARGET/.loopos/state.json" ]; then
  echo '{ "completed_tasks": [], "total_tasks_run": 0, "project_summary": "" }' > "$TARGET/.loopos/state.json"
  echo "  ✓ state.json (新建)"
else
  echo "  ⏭ state.json (已存在，跳过)"
fi

if [ ! -f "$TARGET/.loopos/decisions.json" ]; then
  echo '{ "decisions": [] }' > "$TARGET/.loopos/decisions.json"
  echo "  ✓ decisions.json (新建)"
else
  echo "  ⏭ decisions.json (已存在，跳过)"
fi

# 设置可执行权限
chmod +x "$TARGET/.loopos/tmux-worker.sh" 2>/dev/null || true

# 追加 .gitignore
echo ""
if [ -f "$TARGET/.gitignore" ]; then
  if ! grep -q "LoopOS" "$TARGET/.gitignore" 2>/dev/null; then
    cat >> "$TARGET/.gitignore" <<'IGNORE'

# LoopOS
.loopos/reports/
.loopos/workers/
.loopos/specs/
.loopos/logs/
IGNORE
    echo "📝 .gitignore 已更新"
  else
    echo "📝 .gitignore 已包含 LoopOS 规则"
  fi
else
  cat > "$TARGET/.gitignore" <<'IGNORE'
# LoopOS
.loopos/reports/
.loopos/workers/
.loopos/specs/
.loopos/logs/
IGNORE
  echo "📝 .gitignore 已创建"
fi

# 统计
echo ""
AGENT_COUNT=$(ls "$TARGET/.claude/agents"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo "✅ 完成: ${AGENT_COUNT} agents, 2 workflows, 3 configs"
echo ""
echo "使用方式:"
echo "  cd $TARGET"
echo "  # 需求明确时:"
echo "  Workflow({ name: 'supervisor-worker', args: { request: '你的需求' } })"
echo ""
echo "  # 需求模糊时:"
echo "  Workflow({ name: 'deep-interview', args: { request: '你的想法' } })"
