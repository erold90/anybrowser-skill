#!/usr/bin/env bash
# Tests that don't drive your apps: build and install, argument validation, and
# that text handed to the commands can never run as code. (`check`, run by the
# installer, nudges the pointer one point and puts it back.)
#
# For the full run against real windows, see tests/web.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$HERE/scripts/mac.sh"
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

"$M" pos >/dev/null 2>&1   # builds the binary if needed

CLAUDE_SKILLS="$TMP/skills" "$HERE/install.sh" >/dev/null 2>&1
t "install builds a working binary" test -x "$TMP/skills/macuse/scripts/macuse" -a -f "$TMP/skills/macuse/scripts/macuse.swift"

# Each payload would create a file if it were ever interpreted as code.
"$M" menus "Finder\" to return (do shell script \"touch $TMP/p1\") --" >/dev/null 2>&1
"$M" focus "Finder\" to activate
do shell script \"touch $TMP/p2\"" >/dev/null 2>&1
"$M" click "1}; do shell script \"touch $TMP/p3\"; {1" 2 >/dev/null 2>&1
"$M" menu "NoSuchApp\" of menu bar 1 --" "File" "x\"); do shell script \"touch $TMP/p4\" --" >/dev/null 2>&1
"$M" scroll "0, 0)); \$.system('touch $TMP/p5'); ((0" >/dev/null 2>&1
"$M" do "keys \$(touch $TMP/p6)" "nosuchcommand" >/dev/null 2>&1
t "no argument runs as code" bash -c "! ls $TMP/p? 2>/dev/null | grep -q ."

t "where exits 1 when nothing matches"  refuses "$M" where "zz-no-such-element-zz"
t "unknown key name fails"              says "unknown key" "$M" key nope
t "unknown modifier fails"              says "unknown modifier" "$M" hotkey "cmd banana" s
t "hotkey without a key fails"          refuses "$M" hotkey cmd
t "pos prints two numbers"              bash -c "\"$M\" pos | grep -Eq '^-?[0-9]+ -?[0-9]+$'"
# A lone pointer event used to be dropped when the process exited right after it.
read -r X Y <<<"$("$M" pos)"
t "move lands, jumping"                 bash -c "MACUSE_GLIDE=0 \"$M\" move $((X+9)) $((Y+7)) && [ \"\$(\"$M\" pos)\" = '$((X+9)) $((Y+7))' ]"
t "move lands, gliding"                 bash -c "\"$M\" move $((X+40)) $((Y+30)) && [ \"\$(\"$M\" pos)\" = '$((X+40)) $((Y+30))' ]"
MACUSE_GLIDE=0 "$M" move "$X" "$Y" >/dev/null 2>&1
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
t "waitgone returns when absent"        says "gone:" "$M" waitgone "zz-no-such-element-zz" 1
t "drag needs coordinates or two names"  says "drag takes X1 Y1 X2 Y2, or two names" "$M" drag onlyone
t "window needs an action"              says "window needs an action" "$M" window
t "window move needs two numbers"       says "needs two numbers" "$M" window move 10
t "window rejects unknown actions"      says "unknown window action" "$M" window wiggle
t "quit says when an app isn't running" says "isn't running" "$M" quit "zz-no-such-app"
t "menus lists a menu's items"          bash -c "\"$M\" menus Finder \"\$(\"$M\" menus Finder | sed -n 3p)\" | grep -q ."

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
