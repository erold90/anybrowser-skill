#!/usr/bin/env bash
#
# macuse — entry point. Builds the native binary from macuse.swift the first
# time (and whenever the source is newer), then hands every call over to it.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/macuse"
SRC="$HERE/macuse.swift"

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  if ! command -v swiftc >/dev/null 2>&1; then
    echo "macuse needs the Swift compiler, part of the Command Line Tools: xcode-select --install" >&2
    exit 1
  fi
  echo "building macuse (once, ~20 s)…" >&2
  if ! swiftc -O "$SRC" -o "$BIN.$$" 2>"$BIN.$$.log"; then
    grep -v "warning:" "$BIN.$$.log" >&2 || true
    rm -f "$BIN.$$" "$BIN.$$.log"
    exit 1
  fi
  mv -f "$BIN.$$" "$BIN"
  rm -f "$BIN.$$.log"
fi

exec "$BIN" "$@"
