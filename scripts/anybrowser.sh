#!/usr/bin/env bash
#
# anybrowser — entry point. Builds the native binary from src/*.swift the first
# time (and whenever a source file is newer), then hands every call over to it.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/anybrowser"
SRC="$HERE/src"

if [ ! -x "$BIN" ] || [ -n "$(find "$SRC" -name '*.swift' -newer "$BIN" 2>/dev/null)" ]; then
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "anybrowser needs the Swift compiler, part of the Command Line Tools: xcode-select --install" >&2
    exit 1
  fi
  echo "building anybrowser (once, ~30 s)…" >&2
  if ! swiftc -O "$SRC"/*.swift -o "$BIN.$$" 2>"$BIN.$$.log"; then
    grep -v "warning:" "$BIN.$$.log" >&2 || true
    rm -f "$BIN.$$" "$BIN.$$.log"
    exit 1
  fi
  mv -f "$BIN.$$" "$BIN"
  rm -f "$BIN.$$.log"
fi

exec "$BIN" "$@"
