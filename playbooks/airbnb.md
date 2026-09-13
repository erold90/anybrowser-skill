# Airbnb (web, in Safari or Chrome)

Verified on 13/09/2026 on the Italian site (`airbnb.it`), signed out, in Safari. No bot wall
that run. Names are the Italian ones read off the page.

## The search flow

```
anybrowser.sh do 'go airbnb.it' 'click "Gestisci le preferenze"' 'click Salva'   # cookies: non-essential off
anybrowser.sh click "Dove"
anybrowser.sh keys "Lecce"                        # NOT fill — React field, see the trap
anybrowser.sh do 'waitfor "Lecce, LE" 5' 'click "Lecce, LE"'
# picking the place opens the calendar; read the day cells' exact names, then click check-in and check-out:
anybrowser.sh where "September 2026"              # get the exact cell name incl. the weekday
anybrowser.sh do 'click "20, Sunday, September 2026. Disponibile. Seleziona come data di check-in."' \
                 'click "27, Sunday, September 2026. Disponibile. Seleziona come data di check-out."'
anybrowser.sh do 'click Ricerca' 'waitload'
```

Results: `airbnb.it/s/<place>/homes?…` — a listing is `Casa ⋅ Lecce` / `Appartamento ⋅ Lecce` [Link]
to `airbnb.it/rooms/<id>`, and **the price is in the accessibility tree**: `text` shows `629 € totale`.

## Where things are

| What | Name and role |
|---|---|
| Cookies | `Accetta tutti` [Button], or `Gestisci le preferenze` → the panel's `Salva` (non-essential toggles are off by default, so Salva keeps only essential) |
| Destination | `Dove` [TextField]; after a click it becomes a [ComboBox] that takes `keys` |
| A suggestion | a [StaticText] named like `Lecce, LE` or `Lecce centro storico, Lecce, LE` |
| Dates | `Date Aggiungi date` [Button]; day cells are buttons named in full and in **English**: `20, Sunday, September 2026. Disponibile. Seleziona come data di check-in.` |
| Guests | `Chi Aggiungi ospiti` [Button] |
| Search | `Ricerca` [Button] |
| A result | `Casa ⋅ Lecce` / `Appartamento ⋅ Lecce` [Link] → `/rooms/<id>`; the price and `totale` are in `text` |

## Traps, each one met for real

- 🔴 **The `Dove` field ignores `fill`** — like Booking's, it's a React autocomplete. `click` it, then
  `keys "<place>"`; the suggestions drop down. Pick one by name.
- 🔴 **Day-cell names carry the weekday, in English, and must be exact.** `20 September 2026` is a
  **Sunday**, so the cell is `20, Sunday, …`, not `Saturday`; a wrong weekday makes the click fail with
  `no element matching`. Read the real names with `where "September 2026"` first, then click.
- 🟢 **Prices are in the tree** (`629 € totale`) — read them straight from `text`, no screenshot needed
  (the opposite of Booking).
- **Picking a place auto-opens the calendar** (`page: "Settembre 2026"` in the report).
- **Airbnb is aggressive with bot checks on repeat visits.** If a run hits one, the report shows
  `⚠ a bot check…`/`⚠ a CAPTCHA…` — hand it to the user, don't retry in a loop.
- **Signing in and booking are the user's** — stop at the price, never enter their account or card.
