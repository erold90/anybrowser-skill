# Safari

Verified on 11/09/2026 with Safari 26.5 on macOS 15.7, Italian system language.
Italian names are the ones read off the screen; English ones in brackets are the
usual translations, not verified — `where <part>` confirms.

## What comes from where

| Want | Route | Needs |
|---|---|---|
| tabs, addresses, open/close/switch, `go`, `reload` | scripting (Apple Events) | the Automation prompt, once |
| `source` (the page's HTML) | scripting | nothing more |
| `text`, `links`, `find`, `click`, `fill` | accessibility | Accessibility |
| `back` / `forward` | toolbar buttons by identifier | — |
| `history`, `bookmarks` | the files; without Full Disk Access, Safari's own views | optional Full Disk Access |
| `js` | `do JavaScript` | Develop › Allow JavaScript from Apple Events — ask the user |
| `readinglist` | scripting | — |

`check` says which of these are on.

## Fixed identifiers (any language)

Toolbar: `BackButton` · `ForwardButton` · `ReloadButton` · `WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD` ·
`SidebarButton` · `DownloadsButton` · `ShareButton` · `OneStepBookmarkingButton` (add to Reading List) ·
`AssistantButton` (page menu) · `TranslationButton` · `TabGroupPickerButton`.
The page's container is `BrowserView?IsPageLoaded=true&WebViewProcessID=…`, the
window `SafariWindow?IsSecure=true&UUID=…`. The toolbar buttons' enabled state is
live; the History menu's Back/Forward state goes stale until the menu is shown —
which is why `back` presses the toolbar button.

## Menus (Italian)

`Safari · File · Modifica · Vista · Cronologia · Segnalibri · Finestra · Aiuto`

- **Cronologia** [History]: Mostra/Nascondi cronologia ⌘Y · Indietro · Avanti · Pagina iniziale ·
  Chiusi di recente ▸ · Riapri l'ultima finestra chiusa · Riapri tutte le finestre dall'ultima sessione
- **Segnalibri** [Bookmarks]: Mostra segnalibri · Modifica segnalibri ⌥⌘B · Aggiungi segnalibro… ⌘D ·
  Aggiungi cartella segnalibri · Aggiungi a "Elenco lettura" · Preferiti ▸

Commands found by shortcut (`settings` ⌘, · `bookmark` ⌘D · `history --ui` ⌘Y ·
`bookmarks --ui` ⌥⌘B · `private` ⇧⌘N) work in any language.

## Settings

`settings <pane>` opens Settings on that pane; `read` then lists every option with
`on`/`off`. Panes: Generali · Pannelli · Inserimento automatico · Password · Cerca ·
Sicurezza · Privacy · Siti web · Profili · Estensioni · Avanzate
[General · Tabs · AutoFill · Passwords · Search · Security · Privacy · Websites ·
Profiles · Extensions · Advanced]. Close with `hotkey cmd w`.

Advanced has "Mostra funzionalità per sviluppatori web" [Show features for web
developers] — it adds the Develop menu, where "Allow JavaScript from Apple Events"
lives. Changing either is the user's decision.

## History and bookmarks without Full Disk Access

`history [text]` opens the history view (⌘Y), reads its list — day, title,
address — and closes it again. `bookmarks [text]` does the same with Modifica
segnalibri (⌥⌘B), opening the collapsed folders so their bookmarks are listed,
with the folder path above them. Visit times aren't in the view; with Full Disk
Access both come from `~/Library/Safari/History.db` and `Bookmarks.plist` instead.

## Traps, each one met for real

- **A new window shows "Pagina di apertura"** (`favorites://`), which is not a web
  page: `text`/`find` say there's no page until you `go` somewhere.
- **The JavaScript alert** reads `dialog: "Da "http://…": — <message>" — buttons: Chiudi`;
  `key return` closes it.
- **`<select>` menus are invisible to accessibility**; `select` handles it (types
  the option into the open menu, checks the value, restores it on failure).
- **AutoFill can swallow the first paste** into a field named like a contact field
  (Name): `fill` re-reads and fills once more.
- **`text` right after a click** can miss the newest line for a moment: `expect`.
- **A `file://` page opened by script** asks to confirm the file; serve local test
  pages over `http://127.0.0.1` instead.
- **Closing a window with several tabs** through the red button asks for
  confirmation; `tab close` closes one tab at a time and never asks.
