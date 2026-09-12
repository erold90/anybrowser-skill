# Gmail (web, in Safari or Chrome)

Verified on 11/09/2026 with an Italian account, driving the real mail.google.com.
Names below are the Italian ones that were read off the page; the English ones in
brackets are what Gmail shows in English and have not been verified — confirm
with `where` before relying on them.

## Where things are

| What | Name and role |
|---|---|
| Compose | `Scrivi` [Button] (Compose) |
| Search | `Cerca nella posta` [ComboBox/TextField] (Search mail) |
| A message in a list | a [Row] `da leggere, <sender>, <subject>, <time>, <snippet>` and a [Link] `<subject> - <snippet>` |
| Back to the list | `Torna a Posta in arrivo` [Button] (Back to Inbox) |
| Message toolbar | `Archivia` · `Segnala come spam` · `Elimina` · `Segna come Da leggere` · `Sposta in` (Archive · Report spam · Delete · Mark as unread · Move to) |
| Reply, forward | `Rispondi` [Button] at the top of the message, `Rispondi` / `Inoltra` [Link] under it (Reply · Forward) |
| Compose fields | `Destinatari diretti` [ComboBox] (To recipients) · `Oggetto` [TextField] (Subject) · `Corpo del messaggio` [TextArea] (Message Body) |
| Reply fields | `Corpo del messaggio` [TextArea] · `Tipo di risposta` [PopUpButton] (Type of response); the recipient is implied and not shown |
| Send | `Invia ‪(⌘Enter)‬` [Button] — the name carries invisible direction marks |
| Discard / close a draft | `Elimina bozza ‪(⌘⇧D)‬` [Button] (Discard draft) · `Salva e chiudi` [Button] (Save & close) |
| Sent | `Messaggio inviato` [StaticText] (Message sent), bottom left, for a few seconds |

## Recipes

**Send an email**
```
anybrowser.sh do 'click Scrivi' 'fill "Destinatari diretti" "someone@example.com"' \
          'fill Oggetto "Subject"' 'fill "Corpo del messaggio" "Text"'
anybrowser.sh shot --window          # check the recipient chip before sending — see below
anybrowser.sh do 'hotkey cmd return' 'waitfor "Messaggio inviato" 5'
```

**Find and read a message**
```
anybrowser.sh do 'fill "Cerca nella posta" "subject:(Invoice March)"' 'key return' \
          'waitfor "Invoice March" 8' 'click "Invoice March"' 'read'
```
The message text comes after the sidebar and the toolbar in `read`; the sender
and date sit just above it (`<name> <address>`, `11 set 2026, 18:25`).

**Reply**
```
anybrowser.sh do 'click Rispondi' 'fill "Corpo del messaggio" "Thanks!"' 'hotkey cmd return' \
          'waitfor "Messaggio inviato" 5'
```

**Open a link inside a message**: `click "https://…"` or the link's text. Gmail
opens it in a new tab in front; the report says `new tab: "…"`. `raise` or
`click "<tab title>"` goes back, `hotkey cmd w` closes the tab.

## Traps, each one met for real

- **Send with `hotkey cmd return`, not `click Invia`.** The button's name has
  invisible marks around `(⌘Enter)`, and the Sent folder link `Inviati` starts
  the same way. anybrowser now ranks a whole first word ahead of a longer word, but the
  shortcut can't be confused with anything.
- **The recipient becomes a chip.** After `fill "Destinatari diretti"` the report
  says `it shows ""`: the typed address turned into a chip, which accessibility
  names only by the contact's display name (`Daniele LR`). Don't send on faith:
  `where <address>` finds the chip — `<name> <address>  [PopUpButton]` — and
  `shot --window` shows it under the title bar (a `shot --element` of the field came back blank).
- **Counting a list without reading it**: Gmail's own counter is in `text` (`1–4 di 4`);
  `find row --count` counts rows without printing a subject or a sender.
- **An empty body field reports its hint as its value** (`Premi / per scrivere
  usando Gmail e Drive`). Don't read that as text already there.
- **`ui --all` stops at 200 lines, all inbox rows.** The compose panel comes after
  them: find its fields with `where`, which searches the whole page.
- **Discard a draft you opened by mistake** with `click "Elimina bozza"`; the
  shortcut ⌘⇧D only works while the cursor is inside the draft.
- **Plan an email you actually send.** Sending is consequential: fill everything,
  check the chip, and confirm with the user before `hotkey cmd return` unless they
  asked for exactly that message.
