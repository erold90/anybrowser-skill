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
# The app being worked on, refs and the windows opened are remembered in TMPDIR: keep the tests' apart.
export TMPDIR="$TMP/state/"; mkdir -p "$TMPDIR" "$TMP/fresh"
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
    'fill "Delivery time" "19:30"' \
    'fill "Delivery date" "2026-09-12"' \
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
  t "$browser: date and time fields take their parts" "picked: time=19:30 date=2026-09-12" "$out"
  t "$browser: fill says what a date field shows"  "filled Delivery date .* with 12/09/2026" "$out"
  t "$browser: clicks are real clicks"      "real clicks: [1-9][0-9]* · synthetic: 0" "$out"

  start=$(ms)
  "$M" click Target >/dev/null 2>&1
  page=$("$M" read 2>/dev/null | grep -Eo 'last mousedown: [0-9]+' | grep -Eo '[0-9]+$')
  echo "      $browser: command → mousedown in the page: $(( page - start )) ms (click by name, one process)"

  # Below the fold: scrolled into view (smoothly), then clicked for real — not pressed as "covered".
  out=$("$M" click "Far button" 2>&1)
  t "$browser: a button below the fold is scrolled to and clicked" "clicked Far button" "$out"
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
    'links --count' \
    'tabs' 2>&1)
  echo "      $browser: browser commands in $(( $(ms) - start )) ms"
  [ -n "${VERBOSE:-}" ] && grep -E '^\[[0-9]+\]' <<<"$out" | sed 's/^/        /'
  t "$browser: go loads and reports"        "loaded \"anybrowser test\" — $(re "$URL2")" "$out"
  t "$browser: back returns"                "back to \"anybrowser test\" — $(re "$URL")" "$out"
  t "$browser: forward returns"             "forward to \"anybrowser test\" — $(re "$URL2")" "$out"
  t "$browser: reload reloads"              "reloaded \"anybrowser test\"" "$out"
  t "$browser: text has the page, line by line" "^    Name$" "$out"
  t "$browser: refs click the listed element" "clicked Send  \[Button\]" "$out"
  t "$browser: expect passes, saying where" "ok: \"status: sent\" is on the page in $browser" "$out"
  t "$browser: tabs lists the page"         "anybrowser test — $(re "$URL2")" "$out"
}

# --- Safari, in a window of its own -----------------------------------------------
ANYBROWSER_BROWSER=safari "$M" tab new "$URL" --window >/dev/null
export ANYBROWSER_BROWSER=safari
flow Safari
commands Safari

# The user brings forward the terminal these tests run in, as when typing to the agent.
HOST_APP=$("$M" check 2>/dev/null | sed -n 's/^runs in  *\(.*\) — never acted on.*/\1/p')
if [ -n "$HOST_APP" ]; then
  open -a "$HOST_APP"; sleep 1
  out=$("$M" expect "anybrowser test page" 2>&1)
  t "Safari: a check reads the page from behind the terminal" "reading Safari — $HOST_APP is in front" "$out"
  t "Safari: ... and says which app it read"  "is on the page in Safari" "$out"
  open -a "$HOST_APP"; sleep 1
  out=$("$M" click Target 2>&1)
  t "Safari: an action brings the page back first" "brought Safari back to the front" "$out"
  t "Safari: ... then acts there"             "clicked Target" "$out"
  open -a "$HOST_APP"; sleep 1
  out=$(TMPDIR="$TMP/fresh/" "$M" read 2>&1)
  t "nothing worked on, terminal in front: nothing is done" "the app this command runs in" "$out"
else
  echo "skip  the terminal taking the front: no app found running these tests"
fi
out=$("$M" tabs --mine 2>&1)
t "Safari: tabs --mine shows the test window" "opened by anybrowser" "$out"
out=$("$M" tab close --mine 2>&1)
t "Safari: tab close --mine closes the test window" "closed 1 window opened by anybrowser" "$out"
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
  "$M" focus "$APP" >/dev/null               # opened from the shell: name it as the app worked on
  export ANYBROWSER_BROWSER=$NAME
  FIRST_STEP='click Target' flow "$APP"     # a click as the very first command must wake the page too
  commands "$APP"
  unset ANYBROWSER_BROWSER
else
  echo "skip  Chromium/Chrome: install Chromium, or quit Chrome, to test the Chromium side"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
