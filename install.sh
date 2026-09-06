#!/usr/bin/env bash
# Installs the macuse skill for Claude Code.
set -euo pipefail

DEST="${CLAUDE_SKILLS:-$HOME/.claude/skills}/macuse"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$DEST/scripts"
cp "$HERE/SKILL.md" "$DEST/SKILL.md"
cp "$HERE/scripts/mac.sh" "$DEST/scripts/mac.sh"
chmod +x "$DEST/scripts/mac.sh"

echo "installed -> $DEST"
echo
"$DEST/scripts/mac.sh" check
