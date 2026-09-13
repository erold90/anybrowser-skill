# Booking.com (web, in Safari or Chrome)

Verified on 13/09/2026 on the Italian site (`booking.com/?lang=it`), signed out, in Safari.
Names below are the Italian ones read off the page.

Booking sits behind a bot challenge (the first URL carries `chal_t=…&force_referer=`); a real
Safari or Chrome passes it silently, a headless `audit` would not — drive the user's browser, not `audit`.

## The search flow

```
anybrowser.sh do 'go booking.com/?lang=it' 'click Rifiuto'
anybrowser.sh click "Inserisci la destinazione"
anybrowser.sh keys "Lecce"                       # NOT fill — see the trap below
anybrowser.sh do 'waitfor "Lecce Puglia" 5' 'click "Lecce Puglia, Italia"'
# picking the city opens the date calendar; pick check-in then check-out to close it:
anybrowser.sh do 'click "domenica 20 settembre 2026"' 'click "domenica 27 settembre 2026"'
anybrowser.sh do 'click Cerca' 'waitload'
```

The results page is `booking.com/searchresults.it.html?ss=<place>&…&group_adults=2&no_rooms=1`.

## Where things are

| What | Name and role |
|---|---|
| Reject cookies | `Rifiuto` [Button] (accept: `Accetto`; `Gestisci le impostazioni` for the panel) |
| Google One-Tap overlay | an iframe `Finestra di dialogo Accedi con Google`; dismiss with `Chiudi` [Button], never `Continua` |
| Destination | `Inserisci la destinazione` [ComboBox] |
| A suggestion | a [StaticText] named like `Lecce Puglia, Italia` (city) or a property name |
| Dates | `Seleziona date Data check-in — Data check-out` [Button] opens the calendar; day cells are named in full: `domenica 20 settembre 2026` [Cell] |
| Guests/rooms | `Numero di viaggiatori e camere. Selezione attuale: 2 adulti · 0 bambini · 1 camera` [Button] |
| Search | `Cerca` [Button] |
| A result's name | the card's `Salva <name> in una lista di viaggio` [Button], and the property [Link] `<name>` |
| A result's rooms | `Visualizza tariffe` [Button] on each card → the property page |
| Currency / language | `Prezzi in Euro EUR` · `Lingua: Italiano` [PopUpButton] |

`text` on a results card gives the name, the area, the description and the **review score** (`8,8`).

## Traps, each one met for real

- 🔴 **The destination field ignores `fill`.** It's a React autocomplete: `fill` leaves it empty (`it
  shows ""`) and `Cerca` then says «Inserisci una destinazione per iniziare la ricerca». `click` the
  field, then `keys "<place>"` — the suggestions drop down as you type. Pick one by its name.
- 🔴 **The nightly price is not in the accessibility tree.** There is no `€` element and `text` never
  shows a price — only names, areas and review scores. Read the price from a `shot` of the card
  (`shot --region X Y W H --zoom 2`), or open the property with `Visualizza tariffe`. A hotel's real
  price with taxes and what's included (breakfast, free cancellation) shows on the property page.
- 🔴 **The date calendar covers the results and reopens easily.** After a search with no dates it stays
  open over the cards; clicking the date field reopens it. Set both dates (two day-cell clicks) to close
  it before reading results; `key escape` did **not** close it.
- **Picking a city auto-opens the calendar** — expect the report to say `page: "Calendario"` right after
  the suggestion click.
- **Booking opens a property in a new tab** ("Si apre in una nuova finestra"): the report says `new tab`;
  `raise`/`tab <title>` to it, `hotkey cmd w` to close.
- **Signing in and booking are the user's** — never enter their account or card. Stop at the price and
  confirm with the user.
