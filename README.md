# anybrowser

**Your real browser, driven by an AI agent — Safari, Chrome and the rest, no extension.**
An agent skill for Claude Code and Codex on macOS.

```bash
anybrowser.sh go github.com/notifications          # current tab, waits for the load
anybrowser.sh text                                 # the whole page, line by line, in one call
anybrowser.sh do 'fill Email "ada@example.com"' 'click "Sign in"' 'expect "Dashboard" 15'
anybrowser.sh tabs                                 # every tab of every browser, with addresses
anybrowser.sh history invoice --days 7             # from the browser's own files
anybrowser.sh upload ~/Desktop/logo.png            # the native file picker
```

It works in the browser the user already has open — signed in, with their tabs —
and keeps working when a browser extension isn't installed, isn't connected, or
the browser isn't Chrome. The same binary drives any other Mac app.

## How

Each thing comes from wherever the browser answers fastest and most exactly:

| What | Where it comes from |
|---|---|
| Tabs, addresses, navigation, private windows | the browser's scripting dictionary (Apple Events, run in-process — no `osascript`) |
| History, bookmarks, download folder | the browser's own files: Chrome's `History` (SQLite) and `Bookmarks` (JSON); Safari's views when Full Disk Access is off |
| Finding an element | the browser's accessibility search index — what VoiceOver's rotor uses: 1–50 ms even on Gmail |
| Page text | accessibility text markers: the whole page in one call |
| Clicks and typing | real CoreGraphics events: pages see `isTrusted` input |
| Downloads' origin | the address macOS records on every downloaded file |

Every action waits for the page to react and **reports what changed** — `page:
"status: sent"`, `dialog: "…" — buttons: Ok`, `new tab: "…"` — so the agent
doesn't need a screenshot to know a step worked. `do` runs a sequence in one call.
Listings number elements (`@1`, `@2`) that later commands can target exactly.

No debugging port: since Chrome 136, remote debugging doesn't work on the default
profile anyway. JavaScript in pages (`js`) is there for users who turn on "Allow
JavaScript from Apple Events", and nothing else needs it.

## Measured against Claude in Chrome

Same page, same Chrome, same Mac (macOS 15.7, Intel), 11 September 2026. Times are
the agent's tool call, start to result, as the session recorded them — model
thinking time not included.

| Action | Claude in Chrome | anybrowser |
|---|---|---|
| Open a page | 2385 ms | **630 ms** |
| Read the page's text | 490–1014 ms | **227 ms** |
| Find the Send button | 1706 ms (`find`) · 523 ms (`read_page`) | **233 ms** |
| Fill a text field | 1880 ms — a scripted value (`isTrusted: false`) | **738 ms** — real typing, value read back |
| Pick a `<select>` option | 1827 ms | **~400 ms** (1032 ms before the type-ahead path) |
| Click Send | 486–614 ms — "Clicked", effect unknown | **438 ms** — report shows `status: sent` |
| Screenshot | 570–665 ms | 613 ms |
| List tabs | 4209 ms (first call) | **312 ms** |
| New tab | 1545 ms | **505 ms** |
| Close tab | **175–195 ms** | 514 ms |
| Whole form: open, 2 fields, select, send, verify | 2 calls, 4681 ms — and the send never reached the page | **1 call, 2508 ms**, confirmed |
| JavaScript alert | the click never reached the page | opened, answered, checked: 1554 ms |
| Safari · no extension · native file picker | no | yes |

What went wrong on the other side, in this run: two clicks by element ref reported
"Clicked on element" and the page registered no click at all; one of three clicks
by coordinates didn't land either. Tools that answer "done" without the effect
make an agent re-check — another call, more seconds of model time.

## Install

```bash
git clone https://github.com/erold90/anybrowser-skill.git
cd anybrowser-skill && ./install.sh          # Claude Code: ~/.claude/skills/anybrowser
./install.sh --codex                         # Codex:       ~/.codex/skills/anybrowser
./install.sh --all                           # both
```

Needs the Swift compiler from the Command Line Tools (`xcode-select --install`).
The installer builds the binary (~30 s) and runs `check`, which says what's
missing:

- **Accessibility** for your terminal app — everything needs it.
- **Screen Recording** — only for `shot`.
- **Automation** per browser — macOS asks the first time `tabs` or `go` talks to it.
- **Full Disk Access** — optional: Safari's history and bookmarks are read from its
  files instead of its windows.
- **Allow JavaScript from Apple Events** — optional, only for `js`. It lets any app
  allowed to control the browser run code in your signed-in pages; leave it off
  unless you need it.

## Commands

| Browser | |
|---|---|
| `tabs` · `tab <n\|text>` · `tab new [address] [--window]` · `tab close [n\|text]` · `private [address]` | Tabs and windows |
| `go <address>` · `back` · `forward` · `reload` · `waitload [secs]` · `url` | Navigation, each waiting for the load |
| `text [--max N]` · `links [text]` · `find <kind> [text]` · `table [n]` | Read: whole-page text, links with addresses, elements by kind, a table's rows |
| `js "<code>"` · `source [--save file]` | JavaScript (opt-in) · the HTML (Safari) |
| `history [text] [--days N]` · `bookmarks [text]` · `bookmark ["title"]` · `readinglist` | History and bookmarks |
| `downloads [n]` · `settings [text]` · `use <browser>` | Downloads with their origin · settings · which browser |

| Page and desktop | |
|---|---|
| `click` · `dclick` · `rclick` `X Y` · `<name>` · `@ref` | Real clicks |
| `fill <field> "text"` · `select <menu> <option>` · `type` · `keys` · `key` · `hotkey` | Typing and forms |
| `where <text>` · `ui` · `read` · `waitfor` · `waitgone` · `expect` | Look and wait |
| `upload <file>` · `press <name>` · `hover` · `drag` · `scroll` | The rest of the hands |
| `shot [--window\|--element <name>\|--region …]` | Screenshots scaled so a pixel is a point |
| `menu <app> …` · `menus <app>` · `focus` · `quit` · `windows` · `raise` · `window …` | Native apps and windows |
| `do "<cmd>" …` · `do -` | A sequence in one call, stopping at the first failure |
| `check` · `version` | Permissions and what each browser allows |

## Playbooks

`playbooks/*.md` hold what an agent needs to know before driving a browser or a
site — control names, recipes, traps already met — so it doesn't rediscover them:
`safari.md`, `chrome.md`, `gmail.md`. Contributions welcome: drive it, write down
only what you verified.

## Tests

- `tests/check.sh` — build, install, validation, and that no argument ever runs as
  code (including through the browser scripts). Doesn't drive your apps.
- `tests/web.sh` — opens `tests/page.html` in a new Safari window and a throwaway
  Chromium profile; runs a whole form flow (fields, select, alert, file dialog,
  submit) and the browser commands (go, back, forward, reload, text, refs, tabs),
  each as one `do`, and checks the page's own record — real inputs, real clicks.
  Never touches your own tabs.
- The test that matters most isn't a script: a fresh agent, given only `SKILL.md`
  and a real task, reporting where it got stuck. Most of SKILL.md came from those reports.

## What it can't do

- **Console and network logs** need DevTools; without `js` they aren't available.
- **Firefox** has no scripting dictionary: its pages work (click, fill, text), its tabs by title only.
- **Arc, Brave, Edge, Vivaldi, Opera** share Chrome's paths but weren't run.
- **`click`, `fill` and `keys` borrow the mouse and keyboard** while they run. `press` doesn't.
- **It sees what apps expose.** Canvas apps and games expose nothing: `shot` and coordinates.

## When something doesn't work

- **Clicks and keys do nothing, silently** — Accessibility isn't granted to the app
  running the agent. `check` measures it.
- **"refuses to be controlled"** — Automation for that browser was denied: System
  Settings → Privacy & Security → Automation.
- **An element isn't found** — list first: `find button`, `where <part>`; names follow the page's language.
- **The first command on Chrome takes ~2 s** — Chrome builds a page's tree only when asked.
- **Anything else** — `ANYBROWSER_DEBUG=1 anybrowser.sh <command>` shows where the
  time goes; open an issue with that and `anybrowser.sh version`.

Uninstall: `rm -rf ~/.claude/skills/anybrowser ~/.codex/skills/anybrowser`.

## Licence

MIT
