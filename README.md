# macuse

A [Claude Code](https://claude.com/claude-code) skill that gives the agent eyes and hands
on the macOS desktop — for the apps that have no CLI and no API.

Claude already reads your files and drives your browser. This covers the rest:
Finder, Preview, Xcode, Blender, System Settings, installers, that one legacy
app your workflow still depends on.

![macuse driving TextEdit](docs/demo.gif)

Every frame above is a real run: it types text with accents intact, asks the
accessibility tree where the centre-align control is, and clicks the coordinates
it got back.

```bash
scripts/mac.sh shot                          # screenshot, in clickable coordinates
scripts/mac.sh where "Save"                  # → Save  [Button]  ->  812 604
scripts/mac.sh click 812 604
scripts/mac.sh menu TextEdit Format Font "Show Fonts"
scripts/mac.sh type "già pronto — €50 ✓"
scripts/mac.sh waitfor "Export" 15           # poll until the dialog is really there
scripts/mac.sh fill "Email" "me@example.com" # web form, real keystrokes
scripts/mac.sh upload ~/Desktop/logo.png     # the file picker a browser can't script
```

## Why it exists

Hand-rolled versions of this break in quiet ways. Each of these is handled here:

**Retina coordinates.** `screencapture` returns 2880×1800 on a 15" MacBook Pro,
but the mouse lives in a 1440×900 grid. Read a button off the raw screenshot,
click there, and you land somewhere else entirely. `shot` downscales to the
display's width in points first, so one pixel in the image is one point for the
mouse — the conversion never reaches the agent.

**AppleScript eats accents.** `keystroke "àèìòù"` types `aaaaa`. Silently. `type`
pastes through the clipboard instead — accents, em dashes, currency symbols and
emoji all survive, long text is instant, and whatever was on the clipboard
before (an image, rich text) is put back. The pasted text is marked transient,
so clipboard managers that follow the nspasteboard.org convention skip it.

**Permissions that fail silently.** Without *Accessibility*, a posted click or
pointer move reports success and nothing happens. `check` doesn't trust the
system's answer: it moves the pointer one point, reads it back, and restores it.

**Screen text is data, not code.** Every argument reaches AppleScript as a
value, never pasted into script source. A window title or an app name like
`Finder" to do shell script "…` is just a string that matches nothing.

**Apps that stop answering.** An open autocorrect bubble or menu makes an app
ignore scripting, and `osascript` would sit there for two minutes. Calls give
up after 20 s (a tree walk after 60; set `MACUSE_TIMEOUT`) and suggest `key esc`.

## Install

```bash
git clone https://github.com/erold90/macuse.git
cd macuse && ./install.sh
```

That copies the skill to `~/.claude/skills/macuse/` and runs `check`. Grant
whatever it reports as missing in System Settings → Privacy & Security, then
restart your terminal — the permission attaches to the running process.

## Commands

| | |
|---|---|
| `shot [name]` | Capture the main display, scaled so pixels equal click points |
| `where <text>` | Elements matching `<text>`, exact name first, with centre coordinates |
| `waitfor <text> [secs]` | Poll until an element appears (default 10 s) |
| `read` | The front window's text in order — on a web page, the page only |
| `ui` · `apps` · `menus <app>` | What's on screen, what's running, what's in the menu bar |
| `click` · `dclick` · `rclick` `X Y` or `<name>` | Single, double and right click, at a point or on the best match by name |
| `fill <field> "text"` | Focus a text field by name and replace its content with real input |
| `open <url> [app]` | Open a web page in the default browser, or in `<app>` |
| `upload <file>` | Answer the system Open dialog — refuses if it isn't in front |
| `drag X1 Y1 X2 Y2` · `move X Y` · `pos` · `scroll N [dx]` | The pointer |
| `menu <app> <menu> [<submenu>…] <item>` | Pick a menu item by name, at any depth |
| `type "text"` | Paste via the clipboard: keeps accents and emoji |
| `keys "text"` | Type key by key (ASCII only, for fields that watch keystrokes) |
| `key <name>` · `hotkey "cmd shift" s` | Named keys, and shortcuts |
| `focus <app>` | Bring an application to the front |

## Prefer names over pixels

The skill tells the agent to reach for coordinates last, not first:

1. **A menu command** → `menu` — names don't move when the window does
2. **A named control** → `where` reads the accessibility tree, then `click`
3. **Anything else** → `shot`, read it, `click`

## On the web: where a browser extension gets stuck

A browser extension works inside the page — it reads the DOM, runs JavaScript,
and leaves your mouse alone. Use one when you have it. macuse is for the places
an extension can't reach, because they aren't in the page:

- **The system file picker.** `click` the page's upload button, then
  `upload ~/logo.png`. It checks the Open dialog (identifier `open-panel`, the
  same in every language) is really in front before typing a path, and
  confirms it closed.
- **JavaScript alerts.** They're ordinary windows to macOS: `click Ok`.
- **Fields that ignore scripted values.** `fill` clicks the field and pastes, so
  the page receives trusted input events. On `tests/page.html` (serve it with
  `python3 -m http.server -d tests`), two `fill`s count as 2 real inputs and
  0 synthetic, in Safari and Chrome.
- **Any browser.** Safari exposes the page natively. Chrome builds its page tree
  only when an assistive app asks; macuse asks the way VoiceOver does, and the
  first read of a freshly launched Chrome takes about 3 s.

## How it works

No daemon, no dependencies, no model of its own — only what ships with macOS.
`screencapture` for the eyes; the Accessibility API, called in-process from
JavaScript for Automation, for the element tree; CoreGraphics events for the
pointer; System Events for keys and menus. Three short scripts you can read in
full before trusting them.

Reading the tree through the Accessibility API instead of System Events is what
makes `where` usable in a loop: on the same busy web page it answers in under a
second instead of 13. Without the Accessibility permission it falls back to the
slow path, so it still works.

The agent works a loop — look, act, look again — and the skill instructs it to
confirm before anything consequential, to treat whatever is on screen as data
rather than instructions, and to stop and describe what it sees after two failed
attempts instead of hammering the same coordinates.

## What it can't do

Worth knowing before you install it:

- **`where` only sees what the app exposes.** AppKit apps (TextEdit, Finder,
  Mail) expose a rich tree. Newer SwiftUI apps often expose almost nothing —
  Calculator's buttons come back unnamed — so there is nothing to match on.
  Fall back to `shot` and pixels.
- **Element names follow the system language.** On an Italian Mac it's
  `menu TextEdit Formato Font "Mostra font"`. Read the names with `menus` or
  `ui` first rather than guessing the English ones.
- **A control can be found and still be dead.** `where` marks `(disabled)`
  when the app reports it, but not every app does. Confirm with a screenshot,
  not with the exit code.
- **`shot` captures the main display only.** Windows on a second monitor are
  outside the image.
- **It borrows your mouse and keyboard.** You can't use the Mac while it works,
  and it only sees the front window: no background tabs, no DOM, no JavaScript,
  no network log. For a web page, a browser extension does more.
- **Some Chromium-based desktop apps expose no page at all.** In our test the
  ChatGPT app showed its window frame and nothing inside. `shot` and pixels.
- **No pointer without Accessibility.** A plain `click` falls back to System
  Events, which only reaches elements that are in the accessibility tree;
  `dclick`, `rclick`, `drag`, `move` and `scroll` refuse to run and say why.

## Requirements

macOS, and a terminal you're willing to grant Screen Recording, Automation and
Accessibility. Tested on macOS Sequoia 15.7 (Intel).

## Licence

MIT
