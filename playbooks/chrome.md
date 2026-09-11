# Chrome, Chromium and the other Chromium browsers

Verified on 11/09/2026 with Google Chrome 152 and Chromium 146 on macOS 15.7,
Italian. Brave, Edge, Vivaldi and Opera share the scripting dictionary and the
accessibility behaviour; they weren't run. Arc has its own dictionary: expect gaps.

## What comes from where

| Want | Route | Needs |
|---|---|---|
| tabs, addresses, switch/close, `go`, `back`, `forward`, `reload`, `private` | scripting (Apple Events) | the Automation prompt, once |
| `text`, `links`, `find`, `click`, `fill` | accessibility | Accessibility |
| `history`, `downloads` folder | the profile's `History` (SQLite, read in place) and `Preferences` | nothing — no Full Disk Access |
| `bookmarks` | the profile's `Bookmarks` (JSON) | nothing |
| `bookmark` (add) | the ⌘D bubble | — |
| `settings <text>` | a tab on `chrome://settings/?search=<text>` | — |
| `js` | `execute javascript` | View › Developer › Allow JavaScript from Apple Events — ask the user |

## Profiles and files

Profile folder: `~/Library/Application Support/Google/Chrome/<Default|Profile N>`
(Chromium: `Chromium/`, Brave: `BraveSoftware/Brave-Browser/`, Edge: `Microsoft Edge/`).
The profile in use is `--profile-directory` or `--user-data-dir` from the browser's
command line if given, else `profile.last_used` in `Local State`. The names people
see ("Daniele", "deltaquota@gmail.com") are in `Local State` › `profile.info_cache`.

## The page tree wakes on request

Chromium builds the accessibility tree of a page only when an assistive app asks
(`AXEnhancedUserInterface`). The first command on a Chrome that hasn't been asked
waits ~2 s; after that lookups take milliseconds. While the tree is on, Chrome
animates window moves slowly — `window move/resize` switches it off around the change.

Chrome's page text comes without line breaks between blocks ("NameEmail");
`text` reads it line by line instead, and reports compare the changed lines only.

## Window titles

A Chrome window's title carries the group and the profile:
`Nuova scheda - Parte del gruppo Claude - Google Chrome - Daniele`. For the page's
own title use `url` or `tabs`.

## Traps, each one met for real

- **Adding a bookmark through scripting crashed Chromium** ("Impossibile caricare il
  modello Preferiti", then the app quit). `bookmark` uses the ⌘D bubble instead: the
  name field has the focus, Return is Done, it lands in "Altri Preferiti" [Other
  bookmarks], and the `Bookmarks` file catches up within ~10 s.
- **The JavaScript alert** is a small window: `new window: "127.0.0.1:8811 dice" ·
  dialog: "… — Test alert" — buttons: Ok`. Chrome ignores input on it for ~0.5 s;
  anybrowser waits that out. `key return` closes it.
- **`tab close` on a window's last tab closes the window.** A closed New Tab page
  can't be brought back: ⌘⇧T reopens the tab closed before it instead.
- **A second Chrome for tests** (`--user-data-dir`) shares the app id with the
  user's Chrome, so scripting may reach the wrong one. Use Chromium for throwaway
  profiles.
- **Remote debugging is not an option on the user's profile**: since Chrome 136
  `--remote-debugging-port` is ignored on the default data directory. anybrowser
  doesn't need it.
- **The new tab page** (`chrome://new-tab-page/`) is a page: `find`, `links`, `text` work on it.
