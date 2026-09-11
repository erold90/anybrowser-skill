#!/usr/bin/env bash
# Drives real windows. Opens tests/page.html in a new Safari window and in a
# throwaway Chromium (or Chrome) profile, and in each runs:
#   1. a whole form flow — two fields, a <select>, an alert, the native file
#      dialog, submit — as ONE `do` call, checked against the page's own record;
#   2. the browser commands — go, back, forward, reload, url, text, find, refs,
#      tabs, tab close — again as one `do`.
# Never touches your own tabs. Takes over the mouse and keyboard for about a minute.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$HERE/scripts/anybrowser.sh"
PORT="${PORT:-8765}"
V="$(date +%s)"
URL="http://127.0.0.1:$PORT/page.html?v=$V"          # no stale copy from the browser cache
URL2="http://127.0.0.1:$PORT/page.html?second=$V"
re() { printf '%s' "$1" | sed 's/[.?]/\\&/g'; }          # an address as a literal in a pattern
TMP="$(mktemp -d)"
FILE="$TMP/logo.txt"; echo test > "$FILE"
pass=0; fail=0

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HERE/tests" >/dev/null 2>&1 &
SERVER=$!
cleanup() {
  pkill -f "user-data-dir=$TMP/profile" 2>/dev/null && sleep 1.5
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
    "${FIRST_STEP:-waitfor \"anybrowser test page\" 15}" \
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

commands() {
  local browser="$1" out start
  start=$(ms)
  out=$("$M" do \
    "go $URL2" \
    'back' \
    'forward' \
    'reload' \
    'url' \
    'expect "anybrowser test page"' \
    'text' \
    'find field' \
    'fill @2 "grace@example.com"' \
    'find button Send' \
    'click @2' \
    'expect "status: sent"' \
    'tabs' 2>&1)
  echo "      $browser: browser commands in $(( $(ms) - start )) ms"
  [ -n "${VERBOSE:-}" ] && grep -E '^\[[0-9]+\]' <<<"$out" | sed 's/^/        /'
  t "$browser: go loads and reports"        "loaded \"anybrowser test\" — $(re "$URL2")" "$out"
  t "$browser: back returns"                "back to \"anybrowser test\" — $(re "$URL")" "$out"
  t "$browser: forward returns"             "forward to \"anybrowser test\" — $(re "$URL2")" "$out"
  t "$browser: reload reloads"              "reloaded \"anybrowser test\"" "$out"
  t "$browser: text has the page, line by line" "^    Name$" "$out"
  t "$browser: refs click the listed element" "clicked Send  \[Button\]" "$out"
  t "$browser: expect passes"               "ok: \"status: sent\"" "$out"
  t "$browser: tabs lists the page"         "anybrowser test — $(re "$URL2")" "$out"
}

# --- Safari, in a window of its own -----------------------------------------------
ANYBROWSER_BROWSER=safari "$M" tab new "$URL" --window >/dev/null
export ANYBROWSER_BROWSER=safari
flow Safari
commands Safari
"$M" tab close >/dev/null 2>&1
unset ANYBROWSER_BROWSER

# --- Chromium (or Chrome), a throwaway profile starting cold ------------------------
# Chromium first: a second Chrome would share the bundle id with yours, and browser
# scripting addresses a browser by bundle id.
if [ -d "/Applications/Chromium.app" ]; then APP=Chromium; NAME=chromium
elif [ -d "/Applications/Google Chrome.app" ] && ! pgrep -xq "Google Chrome"; then APP="Google Chrome"; NAME=chrome
else APP=""; fi
if [ -n "$APP" ]; then
  open -na "$APP" --args --user-data-dir="$TMP/profile" --no-first-run --no-default-browser-check --new-window "$URL"
  sleep 4
  export ANYBROWSER_BROWSER=$NAME
  FIRST_STEP='click Target' flow "$APP"     # a click as the very first command must wake the page too
  commands "$APP"
  unset ANYBROWSER_BROWSER
else
  echo "skip  Chromium/Chrome: install Chromium, or quit Chrome, to test the Chromium side"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
