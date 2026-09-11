# macuse

A [Claude Code](https://claude.com/claude-code) skill that gives the agent eyes and hands
on the macOS desktop — for the apps that have no CLI and no API.

Claude already reads your files and drives your browser. This covers the rest:
Finder, Preview, Xcode, System Settings, installers, the native file picker,
that one legacy app your workflow still depends on.

![macuse driving TextEdit](docs/demo.gif)

```bash
scripts/mac.sh click "Save"                     # by name, real pointer
scripts/mac.sh fill "Email" "ada@example.com"   # real keystrokes into a named field
scripts/mac.sh menu TextEdit Format Font "Show Fonts"
scripts/mac.sh upload ~/Desktop/logo.png        # the file dialog a browser can't script
scripts/mac.sh do 'fill Name "Ada"' 'click "Show alert"' 'key return' 'click Send' 'read'
```

## What makes it different

**Every action reports what it changed.** macuse listens to the app's
accessibility notifications while it acts, waits for the app to settle, and
answers on the same line:

```
clicked Upload file  [StaticText] at 96 439 → window: "" (sheet, file dialog) · focus: [List]
filled Email  [TextField] → focus: Email  [TextField] · value: "ada@example.com"
clicked Show alert  [Button] at 128 404 → new window: "127.0.0.1:8765 says"
```

An exit code of 0 only means an event was sent. The report is what tells the
agent it landed — without a screenshot, which costs a second and ~1,700 tokens.

**A whole flow in one call.** The slow part of an agent driving a GUI isn't the
click, it's the round trip to the model between clicks. `do` runs a sequence in
one process, and each step waits for what the previous one started: elements
looked up by name are waited for, and a click right after a dialog opens is held
back the half second Chrome ignores input for. In `tests/web.sh`, an alert, two
fields, the native file dialog and a submit run as a single call: 6.8 s in
Safari, 10.5 s in a Chrome launched cold.

**Native, and fast.** One Swift file, compiled on your Mac at install. It talks
to the Accessibility API and posts CoreGraphics events in-process — no
AppleScript, no helper apps, no daemon. On a 2018 Intel MacBook Pro, a click by
name reaches the web page's `mousedown` handler 150–190 ms after the command
starts, lookup and pointer travel included; reading a window's element tree
dropped from ~1 s (JavaScript for Automation) to ~0.1 s.

**Real input.** Clicks and keystrokes are OS events, so pages see `isTrusted`
events: on the test page every click and keystroke counts as real, none as
synthetic, in Safari and Chrome. `keys` sends each character as the key that
produces it on the current layout — SwiftUI apps like Calculator ignore anything
else — and falls back to a Unicode keystroke for what the layout lacks (emoji);
`hotkey` looks keys up the same way.
`press` triggers a control through accessibility without moving the pointer, so
you can keep using your mouse.

**Things that used to break quietly:**
- Retina: `shot` scales to points, so a pixel read off the image is where `click` lands.
- Permissions: without Accessibility, posted events vanish silently. `check`
  moves the pointer one point and reads it back.
- Chrome builds its page tree only when an assistive app asks; macuse asks the
  way VoiceOver does, once, and waits for it.
- The system Open panel: `upload` checks it's really in front (identifier
  `open-panel`, the same in every language) before typing a path, waits for the
  Open button to enable, and confirms the dialog closed.
- `type` pastes, then restores whatever was on the clipboard — images and rich
  text included — and marks the pasted text transient for clipboard managers.

## Install

```bash
git clone https://github.com/erold90/macuse.git
cd macuse && ./install.sh
```

Needs the Swift compiler from the Command Line Tools (`xcode-select --install`;
if you have `git`, you likely have them). The installer copies the skill to
`~/.claude/skills/macuse/`, builds the binary (~20 s) and runs `check`. Grant
what it reports in System Settings → Privacy & Security — Accessibility for
everything, Screen Recording for `shot` — then restart your terminal.

## Commands

| | |
|---|---|
| `shot [name]` | Capture the main display, scaled so pixels equal click points |
| `where <text>` | Elements matching `<text>`, exact name first, with centre points |
| `waitfor` · `waitgone` `<text> [secs]` | Return as soon as an element appears · disappears |
| `read` · `ui` `[--all]` | Visible text in order (the page, on a web page) · named elements; `--all` includes off screen |
| `apps` · `menus <app>` · `pos` | Running apps · an app's menu bar · the pointer |
| `click` · `dclick` · `rclick` `X Y` or `<name>` | Real clicks, at a point or on the best enabled match |
| `press <name>` | Trigger a control through accessibility, pointer untouched |
| `fill <field> "text"` | Focus a text field by name and replace its content, then read it back |
| `select <menu> <option>` | Pick an option in a pop-up menu or `<select>`; restores the old value if it can't |
| `type "text"` · `keys "text"` | Paste · real keystrokes, any characters |
| `key <name>` · `hotkey "cmd shift" s` | Named keys · shortcuts on the current layout |
| `menu <app> <menu> [<submenu>…] <item>` | A menu item by name, at any depth |
| `focus <app>` · `open <url> [app]` · `upload <file>` | Front an app by its localized name, bundle name or id · a web page · answer the Open dialog |
| `hover X Y` or `<name>` | Rest the pointer on something: hover menus, tooltips |
| `move X Y` · `drag X1 Y1 X2 Y2` · `scroll N [dx]` | The pointer |
| `do "<cmd>" "<cmd>" …` · `do -` | A sequence in one call, stopping at the first failure · the same from stdin |
| `check` | Which permissions are missing |

The pointer travels instead of jumping: an eased path at ~240 events a second,
25 ms for a short hop up to ~110 ms across the screen — a click by name still
reaches the page in under 200 ms. `MACUSE_GLIDE=0` jumps, `MACUSE_GLIDE=<ms>`
fixes the travel time. `MACUSE_SETTLE=0` skips the wait and report (fire and
forget), `MACUSE_WAIT` sets how long a lookup by name waits (seconds, default 2),
`MACUSE_DEBUG=1` prints where a slow step spends its time.

## On the web

A browser extension works inside the page — it reads the DOM, runs JavaScript
and leaves your mouse alone. Use one when you have it. macuse covers what an
extension can't reach: the native file picker, JavaScript alerts, pages that
ignore scripted values, browsers other than Chrome.

## Tests

- `tests/check.sh` — build, install, validation, and that no argument ever runs as code. Doesn't drive your apps.
- `tests/web.sh` — opens `tests/page.html` in a new Safari window and a throwaway
  Chrome profile, runs the whole flow as one `do`, and checks the page's own
  record: the submitted values, real inputs, real clicks. Takes over the mouse
  and keyboard for about a minute.

## What it can't do

- **It sees what apps expose.** AppKit apps (TextEdit, Finder, Mail) expose a
  rich tree; many SwiftUI apps expose unnamed buttons; apps that draw their own
  UI (games, canvases) expose nothing. There: `shot` and coordinates. Some
  Chromium-based desktop apps expose no page at all — in our test, the ChatGPT
  app showed its window frame and nothing inside.
- **Names follow the system language.** On an Italian Mac it's
  `menu TextEdit Formato Font "Mostra font"`. Read `menus` or `ui` first.
- **Not every change has a name.** In our tests neither Safari nor Chrome
  announced text changing inside a page, so a report can say the app reacted
  without saying how; add a `read` step when the result matters.
- **`click`, `fill` and `keys` borrow your mouse and keyboard** while they run.
  `press` doesn't.
- **`shot` captures the main display only.**

## Requirements

macOS with the Swift compiler (Command Line Tools). Tested on macOS Sequoia 15.7,
Intel, with an Italian system: Safari, Chrome, TextEdit, Finder, System Settings
and Calculator. The GIF above predates the native engine.

## Licence

MIT
