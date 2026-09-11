#!/usr/bin/env bash
# Installs the macuse skill for Claude Code and builds its native binary.
set -euo pipefail

DEST="${CLAUDE_SKILLS:-$HOME/.claude/skills}/macuse"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Replace the scripts folder whole, so nothing lingers from an older version.
rm -rf "$DEST/scripts"
mkdir -p "$DEST/scripts"
cp "$HERE/SKILL.md" "$DEST/SKILL.md"
cp "$HERE/scripts/macuse.swift" "$HERE/scripts/mac.sh" "$DEST/scripts/"
chmod +x "$DEST/scripts/mac.sh"
# App playbooks: what an agent should know before driving a specific app.
rm -rf "$DEST/apps"
cp -R "$HERE/apps" "$DEST/apps"

echo "installed -> $DEST"
echo
"$DEST/scripts/mac.sh" check
