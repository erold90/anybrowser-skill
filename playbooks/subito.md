# Subito.it (web, in Safari or Chrome)

Verified on 13/09/2026, signed out, in Safari.

## The fast way: search by URL

The home page's search box is a motors widget; the plain search is easiest by address:

```
anybrowser.sh do 'go subito.it' 'click "Continua senza accettare"'   # cookies, privacy-preserving
anybrowser.sh go "subito.it/annunci-italia/vendita/usato/?q=rtx+3080"
anybrowser.sh text --max 3000        # titles and prices are both in the tree
```

- All Italy, used: `subito.it/annunci-italia/vendita/usato/?q=<query>` (spaces as `+`).
- The computing category: `subito.it/annunci-italia/vendita/informatica/?q=<query>`.
- A result is a [Link] titled like `PC i9 11900k - 64gb RAM - Rtx 3080 OC` → an ad page
  `subito.it/informatica/<slug>-<city>-<id>.htm`.
- **Prices are in the accessibility tree** — `text` shows the title then the price (`620 €`, `550 €`,
  `1.099 €`), so a whole results page reads in one call. Good for the `/affari` flipping work.

## Where things are

| What | Name and role |
|---|---|
| Cookies | `Continua senza accettare` [Button] (or `Personalizza`, `Accetta`) |
| A result | the ad's title [Link] → `…-<id>.htm`; its price is the next line in `text` |
| Related searches | links like `rtx 3050` → `…/?q=rtx+3050` |

## Notes

- Prices come through cleanly, so median/quartile work over `text` needs no screenshot.
- `subito.it` answered without a bot wall; if a run hits one, the report shows `⚠` — hand it over.
- Contacting a seller or buying is the user's — anybrowser reads the market, it doesn't message or pay.
