#!/usr/bin/env bash
# Tests that don't drive your apps: build and install, argument validation, and
# that text handed to the commands can never run as code. (`check`, run by the
# installer, nudges the pointer one point and puts it back.)
#
# For the full run against real windows, see tests/web.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$HERE/scripts/anybrowser.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

t() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $name"; pass=$((pass + 1))
  else echo "FAIL  $name"; fail=$((fail + 1)); fi
}
refuses() { ! "$@"; }
# Checks the message, not just the exit code (pipefail would hide a grep match).
says() { local want="$1" out; shift; out=$("$@" 2>&1); grep -q -- "$want" <<<"$out"; }

# The app being worked on is remembered in TMPDIR: these tests keep their own. By default
# no terminal and nothing worked on, so commands take the app in front as they always did.
# STOP: the app worked on is the Dock, which is never in front — every action stops before
# touching anything, so a payload is never typed into whatever app happens to be in front.
S="$TMP/state"; mkdir -p "$S/quiet" "$S/stop" "$S/host"
export TMPDIR="$S/quiet/" ANYBROWSER_HOST=none
printf '{"pid":%s,"name":"Dock","at":%s,"posted":0}' "$(pgrep -x Dock | head -1)" "$(( $(date +%s) - 978307200 ))" > "$S/stop/anybrowser-front.json"
STOP=(env TMPDIR="$S/stop/")
# A text no window shows — not even the terminal, which may be showing this very file.
ABSENT="zz-$(date +%s)-$$-absent"

"$M" pos >/dev/null 2>&1   # builds the binary if needed

CLAUDE_SKILLS="$TMP/skills" "$HERE/install.sh" >/dev/null 2>&1
t "install builds a working binary" test -x "$TMP/skills/anybrowser/scripts/anybrowser" -a -f "$TMP/skills/anybrowser/scripts/src/main.swift" -a -d "$TMP/skills/anybrowser/playbooks"

# Each payload would create a file if it were ever interpreted as code.
"$M" menus "Finder\" to return (do shell script \"touch $TMP/p1\") --" >/dev/null 2>&1
"$M" focus "Finder\" to activate
do shell script \"touch $TMP/p2\"" >/dev/null 2>&1
"${STOP[@]}" "$M" click "1}; do shell script \"touch $TMP/p3\"; {1" 2 >/dev/null 2>&1
"$M" menu "NoSuchApp\" of menu bar 1 --" "File" "x\"); do shell script \"touch $TMP/p4\" --" >/dev/null 2>&1
"${STOP[@]}" "$M" scroll "0, 0)); \$.system('touch $TMP/p5'); ((0" >/dev/null 2>&1
"${STOP[@]}" "$M" do "keys \$(touch $TMP/p6)" "nosuchcommand" >/dev/null 2>&1
# Browser arguments reach the browser script as values, never as its source.
ANYBROWSER_BROWSER="zz-no-such-browser" "$M" go "x\"); Application.currentApplication().doShellScript(\"touch $TMP/p7\"); (\"" >/dev/null 2>&1
ANYBROWSER_BROWSER="zz-no-such-browser" "$M" tab "\"); do shell script \"touch $TMP/p8\" --" >/dev/null 2>&1
t "no argument runs as code" bash -c "! ls $TMP/p? 2>/dev/null | grep -q ."

t "where exits 1 when nothing matches"  refuses "$M" where "$ABSENT"
t "unknown key name fails"              says "unknown key" "$M" key nope
t "unknown modifier fails"              says "unknown modifier" "$M" hotkey "cmd banana" s
t "hotkey without a key fails"          refuses "$M" hotkey cmd
t "pos prints two numbers"              bash -c "\"$M\" pos | grep -Eq '^-?[0-9]+ -?[0-9]+$'"
# A lone pointer event used to be dropped when the process exited right after it.
read -r X Y <<<"$("$M" pos)"
t "move lands, jumping"                 bash -c "ANYBROWSER_GLIDE=0 \"$M\" move $((X+9)) $((Y+7)) && [ \"\$(\"$M\" pos)\" = '$((X+9)) $((Y+7))' ]"
t "move lands, gliding"                 bash -c "\"$M\" move $((X+40)) $((Y+30)) && [ \"\$(\"$M\" pos)\" = '$((X+40)) $((Y+30))' ]"
ANYBROWSER_GLIDE=0 "$M" move "$X" "$Y" >/dev/null 2>&1
t "fill needs a field and a text"       refuses "$M" fill Email
t "open refuses non-web URLs"           says "http(s) URLs only" "$M" open "file:///etc/hosts"
t "shot refuses a relative path"        refuses "$M" shot ../../x
t "shot refuses a non-png absolute path" says "absolute and end in .png" "$M" shot /tmp/x.jpg
t "upload refuses a missing file"       says "no such file" "$M" upload "$TMP/nope.txt"
touch "$TMP/real.txt"
t "upload types nothing without a dialog" says "no file dialog in front" "$M" upload "$TMP/real.txt"
t "do rejects an unclosed quote"        says "unclosed quote" "$M" do 'keys "abc'
t "do stops at the first failure"       says "stopped at step 1 of 2" "$M" do "nosuchcommand" "pos"
t "do runs every step when all pass"    says "\[2\] pos" "$M" do "pos" "pos"
t "do - reads steps from stdin"         bash -c "printf '# comment\npos\n\npos\n' | \"$M\" do - | grep -q '\[2\] pos'"
t "select needs a menu and an option"   says "select needs a menu and an option" "$M" select Plan
t "waitgone returns when absent"        says "gone from .*: $ABSENT" "$M" waitgone "$ABSENT" 1
t "drag needs coordinates or two names"  says "drag takes X1 Y1 X2 Y2, or two names" "$M" drag onlyone
t "window needs an action"              says "window needs an action" "$M" window
t "window move needs two numbers"       says "needs two numbers" "$M" window move 10
t "window rejects unknown actions"      says "unknown window action" "$M" window wiggle
t "quit says when an app isn't running" says "isn't running" "$M" quit "zz-no-such-app"
# A shortcut used to leave Cmd "held" for the whole system: every later click became a Cmd-click.
ANYBROWSER_SETTLE=0 "$M" hotkey "cmd shift" f19 >/dev/null 2>&1
t "a shortcut leaves no modifier held"  says "modifier keys     none held" "$M" check
t "menus lists a menu's items"          bash -c "\"$M\" menus Finder \"\$(\"$M\" menus Finder | sed -n 3p)\" | grep -q ."

# Staying on the app being worked on. FRONT, the app in front right now, plays the
# terminal these commands run in.
FRONT=$(lsappinfo info -only bundleid "$(lsappinfo front)" | sed -E 's/.*="(.*)"/\1/')
HOST=(env TMPDIR="$S/host/" ANYBROWSER_HOST="$FRONT")
t "terminal in front: a lookup does nothing"   says "the app this command runs in" "${HOST[@]}" "$M" where "$ABSENT"
t "terminal in front: no key is sent"          says "so nothing was done there" "${HOST[@]}" "$M" key f19
t "terminal in front: a do stops at once"      says "stopped at step 1 of 2" "${HOST[@]}" "$M" do "key f19" "pos"
t "terminal in front: bad arguments said first" says "unknown modifier" "${HOST[@]}" "$M" hotkey "cmd banana" s
t "another app took the front: an action stops" says "someone brought it forward, so nothing was done" "${STOP[@]}" "$M" key f19
t "check says what it works in"                says "working in        Dock" "${STOP[@]}" "$M" check
t "a screenshot says the work isn't in front"  says "is in front, not Dock where the work is" "${STOP[@]}" "$M" shot "$TMP/look.png"

# Browser commands: validation that needs no browser window.
t "go refuses javascript: addresses"    says "doesn't run javascript:" "$M" go "javascript:alert(1)"
t "go needs an address"                 says "go needs an address" "$M" go
t "go refuses words that aren't an address" says "takes an address" "$M" go "hello world"
t "tab needs something to do"           says "tab needs a number" "$M" tab
t "find needs a known kind"             says "find needs a kind" "$M" find wibble
t "use says when a browser isn't running" says "isn't running" "$M" use "zz-no-such-browser"
t "a named browser that isn't running"  says "isn't running" env ANYBROWSER_BROWSER="zz-no-such-browser" "$M" tabs
rm -f "${TMPDIR:-/tmp}/anybrowser-refs.json"
t "a ref needs a listing first"         says "refs come from the last" "$M" click @3
t "expect fails when the text is absent" says "expected" "$M" expect "$ABSENT" 0.3
t "shot --element needs a target"       says "needs a name or a ref" "$M" shot x --element

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
