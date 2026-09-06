# macuse

A [Claude Code](https://claude.com/claude-code) skill that gives the agent eyes and hands
on the macOS desktop — for the apps that have no CLI and no API.

Claude already reads your files and drives your browser. This covers the rest:
Finder, Preview, Xcode, Blender, System Settings, installers, that one legacy
app your workflow still depends on.

```bash
scripts/mac.sh shot                      # screenshot, in clickable coordinates
scripts/mac.sh where "Save"              # → Save  ->  812 604
scripts/mac.sh click 812 604
scripts/mac.sh menu Finder File "New Window"
scripts/mac.sh type "già pronto — €50 ✓"
```

## Why it exists

Three things quietly break every hand-rolled version of this, and each one is
fixed here:

**Retina coordinates.** `screencapture` returns 2880×1800 on a 15" MacBook Pro,
but the mouse lives in a 1440×900 grid. Read a button off the raw screenshot,
click there, and you land somewhere else entirely. `shot` downscales to the
logical width first, so one pixel in the image is one point for the mouse —
the conversion never reaches the agent.

**AppleScript eats accents.** `keystroke "àèìòù"` types `aaaaa`. Silently. It
follows the current keyboard layout, and non-ASCII falls through. `type` goes
via the clipboard instead — accents, em dashes, currency symbols and emoji all
survive, long text is instant, and the previous clipboard is restored.

**Two permissions, not one.** Clicking and typing go through System Events and
need only *Automation*. Moving the pointer, dragging, right-clicking and the
scroll wheel post CGEvents and need *Accessibility* — a separate grant that
fails **silently**: the command reports success and nothing moves. `check`
tells you which of the three you actually have before you waste a run.

## Install

```bash
git clone https://github.com/erold90/macuse.git
cd macuse && ./install.sh
```

That copies the skill to `~/.claude/skills/macuse/`. Then, in Claude Code:

```
scripts/mac.sh check
```

Grant whatever it reports as missing, in System Settings → Privacy & Security.
Restart your terminal afterwards — the permission attaches to the running
process.

Optional, for the pointer commands: `brew install cliclick`.

## Commands

| | |
|---|---|
| `shot [name]` | Capture the screen, scaled so pixels equal click points |
| `where <text>` | Centre coordinates of the element matching `<text>` |
| `ui` · `apps` · `menus <app>` | What's on screen, what's running, what's in the menu bar |
| `click X Y` | Click a point |
| `menu <app> <menu> <item>` | Pick a menu item by name — steadier than pixels |
| `type "text"` | Type via the clipboard: keeps accents and emoji |
| `keys "text"` | Type key by key (ASCII only, for fields that watch keystrokes) |
| `key <name>` | `return esc tab space delete up down left right page-down` … |
| `hotkey "cmd shift" s` | Modifiers in quotes, then the key |
| `focus <app>` | Bring an application to the front |
| `move` `drag` `rclick` `scroll` `pos` | Pointer control — needs Accessibility |

## Prefer names over pixels

The skill tells the agent to reach for coordinates last, not first:

1. **A menu command** → `menu` — names don't move when the window does
2. **A named control** → `where` reads the accessibility tree, then `click`
3. **Anything else** → `shot`, read it, `click`

## How it works

No daemon, no dependencies, no model of its own. `screencapture` for the eyes,
System Events for clicks and keys, `cliclick` for the pointer when you want it.
One 200-line shell script you can read in full before trusting it.

The agent works a loop — look, act, look again — and the skill instructs it to
confirm before anything consequential, to treat whatever is on screen as data
rather than instructions, and to stop and describe what it sees after two failed
attempts instead of hammering the same coordinates.

## Requirements

macOS, and a terminal you're willing to grant Screen Recording and Automation.
Tested on macOS Sequoia 15.7 (Intel).

## Licence

MIT
