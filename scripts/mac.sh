#!/usr/bin/env bash
#
# macuse — eyes and hands for the macOS desktop.
#
# Coordinates are always in logical points: the ones you read off a screenshot
# taken with `shot` are exactly the ones you pass to `click`. No scaling math.
#
# Nothing to install beyond macOS itself. Arguments are handed to the helper
# scripts as argv, never pasted into AppleScript source, so text copied off the
# screen can't run as code.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOTS="${MACUSE_SHOTS:-${TMPDIR:-/tmp}}"
TIMEOUT="${MACUSE_TIMEOUT:-20}"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || TIMEOUT=20

# An app showing a popover (an autocorrect suggestion, an open menu) stops
# answering Apple Events, and osascript would wait two minutes in silence.
# Cut it short and say what usually fixes it.
js() {
  local secs="$1" rc=0; shift
  perl -e 'alarm shift; exec @ARGV' "$secs" osascript -l JavaScript "$@" || rc=$?
  if [ "$rc" -eq 142 ]; then
    echo "timed out after ${secs}s — the app may be held by a popup; try: mac.sh key esc" >&2
  fi
  return "$rc"
}
act()  { js "$TIMEOUT" "$HERE/act.js" "$@"; }
# The slow tree walk (no Accessibility) can legitimately take a while.
tree() { js "$((TIMEOUT * 3))" "$HERE/tree.js" "$@"; }

usage() {
  cat <<'USAGE'
macuse — eyes and hands for the macOS desktop

LOOK
  shot [name]              capture the screen, scaled so pixels = click points
  where <text>             centre of the elements matching <text>, best first
  waitfor <text> [secs]    poll until <text> appears (default 10 s)
  ui                       named elements of the frontmost window
  read                     the front window's text, in order — cheaper than a shot
  apps                     applications with open windows
  menus <app>              menu bar titles of an app

ACT
  click X Y · dclick X Y · rclick X Y
  click <name>             the same, on the best enabled match by name
  fill <field> "text"      focus a text field by name, replace its content
  open <url> [app]         open a web page, in the default browser or <app>
  upload <file>            answer an open file dialog with a path
  drag X1 Y1 X2 Y2         press, glide, release
  move X Y · pos           move the pointer · print where it is
  scroll N [dx]            N lines: positive up, negative down
  menu <app> <menu> [<submenu>...] <item>
                           pick a menu item by name — steadier than pixels
  type "text"              paste via the clipboard: keeps accents and emoji
  keys "text"              type key by key (ASCII only, for picky fields)
  key <name>               return esc tab space delete up down left right ...
  hotkey "cmd shift" s     modifiers in quotes, then the key
  focus <app>              bring an application to the front

  check                    report which permissions are missing
USAGE
}

cmd="${1:-}"; shift || true
case "$cmd" in

shot)
  name="${1:-shot}"
  case "$name" in */*|.*) echo "shot name must be a plain file name" >&2; exit 2 ;; esac
  raw="$SHOTS/${name}_raw.png"; out="$SHOTS/${name}.png"
  screencapture -x -m "$raw"
  # Retina screens capture at 2x. Downscale to the main display's width in
  # points, so one pixel in the image is one point for the mouse.
  sips --resampleWidth "$(act width)" "$raw" --out "$out" >/dev/null
  rm -f "$raw"; echo "$out"
  ;;

where)
  [ -n "${1:-}" ] || { echo "where needs the text to look for" >&2; exit 2; }
  out=$(tree "$1"); echo "$out"
  case "$out" in "no element matching:"*|"the frontmost app has no window") exit 1 ;; esac
  ;;

waitfor)
  [ -n "${1:-}" ] || { echo "waitfor needs the text to look for" >&2; exit 2; }
  secs="${2:-10}"
  [[ "$secs" =~ ^[0-9]+$ ]] || { echo "seconds must be a whole number" >&2; exit 2; }
  deadline=$((SECONDS + secs))
  while :; do
    out=$(tree "$1")
    case "$out" in
      "no element matching:"*|"the frontmost app has no window") ;;
      *) echo "$out"; exit 0 ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || { echo "not found after ${secs}s: $1" >&2; exit 1; }
    sleep 0.5
  done
  ;;

ui)    tree ;;
apps)  act apps ;;
menus) act menus "${1:?need an app name}" ;;
focus) act focus "${1:?need an app name}" ;;

click|dclick|rclick)
  # "812 604" passed as one quoted argument is still a pair of coordinates.
  if [ $# -eq 1 ] && [[ "$1" =~ ^(-?[0-9]+)[[:space:]]+(-?[0-9]+)$ ]]; then
    set -- "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
  if [ $# -eq 1 ]; then
    # By name: the best enabled match in the front window, then a real click.
    hit=$(tree "$1" pick)
    case "$hit" in "no element matching:"*|"the frontmost app has no window") echo "$hit" >&2; exit 1 ;; esac
    pt="${hit%%$'\t'*}"
    act "$cmd" "${pt% *}" "${pt#* }"
    echo "${cmd}ed ${hit#*$'\t'} at $pt"
  else
    act "$cmd" "$@"
  fi
  ;;

fill)
  [ $# -eq 2 ] || { echo 'fill needs a field name and the text: fill "Email" "me@example.com"' >&2; exit 2; }
  hit=$(tree "$1" field)
  case "$hit" in "no element matching:"*|"the frontmost app has no window") echo "$hit" >&2; exit 1 ;; esac
  pt="${hit%%$'\t'*}"
  # Focus it like a person would, replace what's there, paste: the page gets
  # real input events, not a value set behind its back.
  act click "${pt% *}" "${pt#* }"
  act hotkey cmd a
  act type "$2"
  echo "filled ${hit#*$'\t'}"
  ;;

read) tree "" text ;;

open)
  url="${1:?need a URL}"
  [[ "$url" =~ ^https?:// ]] || { echo "open takes http(s) URLs only" >&2; exit 2; }
  if [ -n "${2:-}" ]; then open -a "$2" "$url"; else open "$url"; fi
  ;;

upload)
  # Answers the system Open dialog a browser can't script. Refuses to type
  # anywhere unless that dialog is really in front.
  f="${1:?need a file path}"
  [ -e "$f" ] || { echo "no such file: $f" >&2; exit 1; }
  act upload "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  ;;

move|drag|scroll|pos|type|keys|key|hotkey|menu)
  act "$cmd" "$@"
  ;;

check)
  printf '%-18s' 'screen recording'
  if screencapture -x -m "$SHOTS/_probe.png" 2>/dev/null && [ -s "$SHOTS/_probe.png" ]; then
    echo 'ok'
  else
    echo 'MISSING — System Settings > Privacy & Security > Screen Recording'
  fi
  rm -f "$SHOTS/_probe.png"

  printf '%-18s' 'automation'
  if act automation >/dev/null 2>&1; then
    echo 'ok'
  else
    echo 'MISSING — System Settings > Privacy & Security > Automation > System Events'
  fi

  # The pointer can report success and not move at all, so measure it.
  printf '%-18s' 'accessibility'
  if [ "$(act probe 2>/dev/null)" = moved ]; then
    echo 'ok'
  else
    echo 'MISSING — clicks, pointer and scroll will do nothing, silently;'
    echo '                  `where` falls back to a slow walk (10+ s).'
    echo '                  System Settings > Privacy & Security > Accessibility,'
    echo '                  add your terminal app, then restart it'
  fi
  ;;

''|-h|--help|help) usage ;;
*) echo "unknown command: $cmd" >&2; echo >&2; usage >&2; exit 1 ;;
esac
