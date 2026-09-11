#!/usr/bin/env bash
# Installs the anybrowser skill and builds its native binary.
#
#   ./install.sh            for Claude Code  (~/.claude/skills/anybrowser)
#   ./install.sh --codex    for Codex        (~/.codex/skills/anybrowser)
#   ./install.sh --all      for both
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
targets=()
case "${1:-}" in
  --codex) targets+=("${CODEX_HOME:-$HOME/.codex}/skills/anybrowser") ;;
  --all)   targets+=("${CLAUDE_SKILLS:-$HOME/.claude/skills}/anybrowser" "${CODEX_HOME:-$HOME/.codex}/skills/anybrowser") ;;
  "")      targets+=("${CLAUDE_SKILLS:-$HOME/.claude/skills}/anybrowser") ;;
  *)       echo "usage: ./install.sh [--codex | --all]" >&2; exit 2 ;;
esac

for DEST in "${targets[@]}"; do
  # Replace scripts and playbooks whole, so nothing lingers from an older version.
  rm -rf "$DEST/scripts" "$DEST/sites"
  mkdir -p "$DEST/scripts/src"
  cp "$HERE/SKILL.md" "$DEST/SKILL.md"
  cp "$HERE/scripts/anybrowser.sh" "$DEST/scripts/"
  cp "$HERE"/scripts/src/*.swift "$DEST/scripts/src/"
  chmod +x "$DEST/scripts/anybrowser.sh"
  # Playbooks: what an agent should know before driving a specific browser or site.
  cp -R "$HERE/sites" "$DEST/sites"
  "$DEST/scripts/anybrowser.sh" version >/dev/null      # builds the binary (~30 s the first time)
  echo "installed -> $DEST"
done

echo
"${targets[0]}/scripts/anybrowser.sh" check
