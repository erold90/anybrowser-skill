#!/usr/bin/env bash
# Tests that don't drive your apps: install, input validation, and that text
# handed to the commands can never run as code. (`check`, run by the installer,
# nudges the pointer one point and puts it back.)
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

CLAUDE_SKILLS="$TMP/skills" "$HERE/install.sh" >/dev/null 2>&1
t "install copies every script" test -f "$TMP/skills/macuse/scripts/act.js" -a -f "$TMP/skills/macuse/scripts/tree.js" -a -x "$TMP/skills/macuse/scripts/mac.sh"

# Each payload would create a file if it were ever spliced into script source.
"$M" menus "Finder\" to return (do shell script \"touch $TMP/p1\") --" >/dev/null 2>&1
"$M" focus "Finder\" to activate
do shell script \"touch $TMP/p2\"
tell application \"Finder" >/dev/null 2>&1
"$M" click "1}; do shell script \"touch $TMP/p3\"; {1" 2 >/dev/null 2>&1
"$M" menu "NoSuchApp\" of menu bar 1 --" "File" "x\"); do shell script \"touch $TMP/p4\" --" >/dev/null 2>&1
"$M" scroll "0, 0)); \$.system('touch $TMP/p5'); ((0" >/dev/null 2>&1
t "no argument runs as code" bash -c "! ls $TMP/p? 2>/dev/null | grep -q ."

t "click refuses a non-number"        refuses "$M" click abc 10
t "shot refuses a path as its name"   refuses "$M" shot ../../x
t "waitfor refuses a non-integer"    refuses "$M" waitfor x '1;rm'
t "where exits 1 when nothing matches" refuses "$M" where "zz-no-such-element-zz"
t "hotkey without a key fails"        refuses "$M" hotkey cmd
t "unknown key name fails"            refuses "$M" key nope
t "pos prints two numbers"            bash -c "\"$M\" pos | grep -Eq '^-?[0-9]+ -?[0-9]+$'"
t "fill needs a field and a text"     refuses "$M" fill Email
t "open refuses non-web URLs"         refuses "$M" open "file:///etc/hosts"
t "upload refuses a missing file"     refuses "$M" upload "$TMP/nope.txt"
touch "$TMP/real.txt"
t "upload types nothing without a dialog" bash -c "\"$M\" upload \"$TMP/real.txt\" 2>&1 | grep -q 'no file dialog in front'"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
