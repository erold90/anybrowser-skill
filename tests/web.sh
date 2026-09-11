#!/usr/bin/env bash
# Drives real windows. Opens tests/page.html in a new Safari window and in a
# throwaway Chrome profile, runs a whole form flow — alert, two fields, native
# file dialog, submit — as ONE `do` call, and checks the page's own record of
# what happened. Takes over the mouse and keyboard for about a minute.
set -uo pipefail
zmodload zsh/datetime 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$HERE/scripts/mac.sh"
PORT="${PORT:-8765}"
URL="http://127.0.0.1:$PORT/page.html?v=$(date +%s)"   # no stale copy from the browser cache
TMP="$(mktemp -d)"
FILE="$TMP/logo.txt"; echo test > "$FILE"
pass=0; fail=0

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HERE/tests" >/dev/null 2>&1 &
SERVER=$!
cleanup() {
  pkill -f "user-data-dir=$TMP/chrome" 2>/dev/null && sleep 1.5
  kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null
  rm -rf "$TMP" 2>/dev/null
}
trap cleanup EXIT
sleep 1

t() {
  local name="$1" want="$2" got="$3"
  if grep -Eq -- "$want" <<<"$got"; then echo "ok    $name"; pass=$((pass + 1))
  else echo "FAIL  $name"; echo "      wanted /$want/ in:"; sed 's/^/      /' <<<"$got" | tail -15; fail=$((fail + 1)); fi
}

ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

flow() {
  local browser="$1" out start page
  start=$(ms)
  out=$("$M" do \
    'waitfor "macuse test page" 15' \
    'fill Name "Ada Lovelace"' \
    'fill Email "ada@example.com"' \
    'select Plan Pro' \
    'click "Show alert"' \
    'key return' \
    'click "Upload file"' \
    "upload $FILE" \
    'click Send' \
    'read' 2>&1)
  echo "      $browser: whole flow in $(( $(ms) - start )) ms"
  [ -n "${VERBOSE:-}" ] && grep -E '^\[[0-9]+\]' <<<"$out" | sed 's/^/        /'
  t "$browser: flow completes"              "status: sent name=Ada Lovelace email=ada@example.com plan=Pro file=logo.txt" "$out"
  t "$browser: typing is real input"        "real inputs: [1-9][0-9]* · synthetic: 0" "$out"
  t "$browser: clicks are real clicks"      "real clicks: [1-9][0-9]* · synthetic: 0" "$out"

  start=$(ms)
  "$M" click Target >/dev/null 2>&1
  page=$("$M" read 2>/dev/null | grep -Eo 'last mousedown: [0-9]+' | grep -Eo '[0-9]+$')
  echo "      $browser: command → mousedown in the page: $(( page - start )) ms (click by name, one process)"
}

# --- Safari -----------------------------------------------------------------
osascript -e "tell application \"Safari\" to make new document with properties {URL:\"$URL\"}" -e 'tell application "Safari" to activate' >/dev/null
flow Safari
osascript -e 'tell application "Safari" to close (every window whose name is "macuse test")' >/dev/null 2>&1

# --- Chrome, a throwaway profile starting cold --------------------------------
if [ -d "/Applications/Google Chrome.app" ]; then
  open -na "Google Chrome" --args --user-data-dir="$TMP/chrome" --no-first-run --no-default-browser-check --new-window "$URL"
  sleep 4
  flow Chrome
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
