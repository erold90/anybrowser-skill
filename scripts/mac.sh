#!/usr/bin/env bash
#
# macuse — eyes and hands for the macOS desktop.
#
# Coordinates are always in logical points: the ones you read off a screenshot
# taken with `shot` are exactly the ones you pass to `click`. No scaling math.
#
# Clicks and typing go through System Events (Automation permission, usually
# already granted). Pointer, drag, right-click and scroll wheel additionally
# need Accessibility — run `check` to see where you stand.
#
set -euo pipefail

SHOTS="${MACUSE_SHOTS:-${TMPDIR:-/tmp}}"

se() { osascript -e "tell application \"System Events\" $1"; }

# Named keys -> macOS virtual key codes.
key_code() {
  case "$1" in
    return|enter) echo 36 ;;   numpad-enter) echo 76 ;;  tab) echo 48 ;;
    space) echo 49 ;;          delete|backspace) echo 51 ;;
    esc|escape) echo 53 ;;     forward-delete) echo 117 ;;
    left) echo 123 ;;          right) echo 124 ;;
    down) echo 125 ;;          up) echo 126 ;;
    page-up) echo 116 ;;       page-down) echo 121 ;;
    home) echo 115 ;;          end) echo 119 ;;
    f1) echo 122 ;; f2) echo 120 ;; f3) echo 99 ;; f4) echo 118 ;;
    f5) echo 96 ;;  f6) echo 97 ;;  f7) echo 98 ;; f8) echo 100 ;;
    *) return 1 ;;
  esac
}

need_cliclick() {
  command -v cliclick >/dev/null 2>&1 && return 0
  echo "This command needs cliclick:  brew install cliclick" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
macuse — eyes and hands for the macOS desktop

LOOK
  shot [name]              capture the screen, scaled so pixels = click points
  where <text>             centre coordinates of the element matching <text>
  ui                       elements of the frontmost window
  apps                     applications with open windows
  menus <app>              menu bar titles of an app

ACT
  click X Y                click at a point
  menu <app> <menu> <item> pick a menu item by name — steadier than pixels
  type "text"              type via the clipboard: keeps accents and emoji
  keys "text"              type key by key (ASCII only, for picky fields)
  key <name>               return esc tab space delete up down left right ...
  hotkey "cmd shift" s     modifiers in quotes, then the key
  focus <app>              bring an application to the front

NEEDS ACCESSIBILITY
  move X Y · drag X1 Y1 X2 Y2 · rclick X Y · scroll N [dx] · pos

  check                    report which permissions are missing
USAGE
}

cmd="${1:-}"; shift || true
case "$cmd" in

shot)
  name="${1:-shot}"; raw="$SHOTS/${name}_raw.png"; out="$SHOTS/${name}.png"
  screencapture -x "$raw"
  # Retina screens capture at 2x. Downscale to the logical width so that one
  # pixel in the image equals one point for the mouse.
  w=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | tr -d ' ' | cut -d, -f3)
  sips --resampleWidth "$w" "$raw" --out "$out" >/dev/null
  rm -f "$raw"; echo "$out"
  ;;

where)
  osascript -l JavaScript "$(dirname "$0")/tree.js" "${1:?need the text to look for}"
  ;;

ui)
  osascript -l JavaScript "$(dirname "$0")/tree.js"
  ;;

apps)
  se 'to return name of every process whose background only is false' \
    | tr ',' '\n' | sed 's/^ *//' | sort
  ;;

menus)
  se "to tell process \"${1:?need an app name}\" to return name of every menu bar item of menu bar 1" \
    | tr ',' '\n' | sed 's/^ *//'
  ;;

menu)
  app="${1:?app}"; m="${2:?menu}"; item="${3:?item}"
  osascript -e "tell application \"$app\" to activate" \
            -e "delay 0.3" \
            -e "tell application \"System Events\" to tell process \"$app\" to click menu item \"$item\" of menu 1 of menu bar item \"$m\" of menu bar 1"
  ;;

focus) osascript -e "tell application \"${1:?need an app name}\" to activate" ;;
click) se "to click at {${1:?x}, ${2:?y}}" >/dev/null ;;

type)
  txt="${1?need the text}"
  # keystroke mangles non-ASCII (accents come out as bare vowels), so paste it.
  old=$(pbpaste 2>/dev/null || true)
  printf '%s' "$txt" | pbcopy
  se 'to keystroke "v" using command down' >/dev/null
  sleep 0.25
  printf '%s' "$old" | pbcopy
  ;;

keys) se "to keystroke \"${1?need the text}\"" >/dev/null ;;
key)
  k="${1:?need a key name}"
  code=$(key_code "$k") || { echo "unknown key: $k" >&2; exit 1; }
  se "to key code $code" >/dev/null
  ;;

hotkey)
  mods="${1:?modifiers, e.g. \"cmd shift\"}"; k="${2:?key}"
  down=""
  for m in $mods; do
    case "$m" in
      cmd|command) down="${down}command down, " ;;
      shift)       down="${down}shift down, " ;;
      alt|opt|option) down="${down}option down, " ;;
      ctrl|control)   down="${down}control down, " ;;
      *) echo "unknown modifier: $m" >&2; exit 1 ;;
    esac
  done
  down="${down%, }"
  if code=$(key_code "$k"); then
    se "to key code $code using {$down}" >/dev/null
  else
    se "to keystroke \"$k\" using {$down}" >/dev/null
  fi
  ;;

move)   need_cliclick; cliclick "m:${1:?x},${2:?y}" ;;
rclick) need_cliclick; cliclick "rc:${1:?x},${2:?y}" ;;
pos)    need_cliclick; cliclick p:. ;;
drag)   need_cliclick; cliclick -e 40 "dd:${1:?x1},${2:?y1}" "m:${3:?x2},${4:?y2}" "du:${3},${4}" ;;

scroll)
  n="${1:?lines: positive scrolls up, negative down}"; dx="${2:-0}"
  osascript -l JavaScript -e "ObjC.import('CoreGraphics'); \$.CGEventPost(\$.kCGHIDEventTap, \$.CGEventCreateScrollWheelEvent(\$(), \$.kCGScrollEventUnitLine, 2, $n, $dx));" >/dev/null
  ;;

check)
  printf '%-18s' 'screen recording'
  if screencapture -x "$SHOTS/_probe.png" 2>/dev/null && [ -s "$SHOTS/_probe.png" ]; then
    echo 'ok'
  else
    echo 'MISSING — System Settings > Privacy & Security > Screen Recording'
  fi
  rm -f "$SHOTS/_probe.png"

  printf '%-18s' 'automation'
  if se 'to return name of first process whose frontmost is true' >/dev/null 2>&1; then
    echo 'ok'
  else
    echo 'MISSING — System Settings > Privacy & Security > Automation'
  fi

  printf '%-18s' 'accessibility'
  if ! command -v cliclick >/dev/null 2>&1; then
    echo 'unknown — brew install cliclick to test it'
  else
    before=$(cliclick p:. 2>/dev/null || echo '?')
    cliclick m:+7,+0 >/dev/null 2>&1 || true
    after=$(cliclick p:. 2>/dev/null || echo '!')
    if [ "$before" != "$after" ]; then
      cliclick "m:$before" >/dev/null 2>&1 || true
      echo 'ok'
    else
      echo 'MISSING — pointer, drag, right-click and scroll will not work'
      echo '                  System Settings > Privacy & Security > Accessibility,'
      echo '                  then add your terminal app and restart it'
    fi
  fi
  ;;

''|-h|--help|help) usage ;;
*) echo "unknown command: $cmd" >&2; echo >&2; usage >&2; exit 1 ;;
esac
