#!/usr/bin/env bash
# Installs the macuse skill for Claude Code.
set -euo pipefail

DEST="${CLAUDE_SKILLS:-$HOME/.claude/skills}/macuse"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Replace the scripts folder whole, so a file dropped in a new version
# doesn't linger from the old one.
rm -rf "$DEST/scripts"
mkdir -p "$DEST/scripts"
cp "$HERE/SKILL.md" "$DEST/SKILL.md"
cp "$HERE"/scripts/* "$DEST/scripts/"
chmod +x "$DEST/scripts/mac.sh"

echo "installed -> $DEST"
echo
"$DEST/scripts/mac.sh" check
