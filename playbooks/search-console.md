# Google Search Console (web, in Safari or Chrome)

Verified on 13/09/2026 in Safari, signed into the user's Google account.
Read-only: the reports are analytics, safe to read; never change a property's settings without asking.

If the browser isn't signed into Google, Search Console shows the Google sign-in — **that's the user's**
(anybrowser flags it; never type a Google password). Once signed in, everything below works.

## Jump straight to a report by URL

Every page takes `?resource_id=sc-domain:<domain>` (a domain property) or `?resource_id=<https://…>`
(a URL-prefix property). So you don't click through the nav — go to the exact report:

| Report | URL (append `?resource_id=sc-domain:<domain>`) |
|---|---|
| Performance / Rendimento | `search.google.com/search-console/performance/search-analytics` |
| Pages / index coverage | `search.google.com/search-console/index` |
| Sitemaps | `search.google.com/search-console/sitemaps` |
| Core Web Vitals | `search.google.com/search-console/core-web-vitals` |
| HTTPS | `search.google.com/search-console/https` |
| Links / Report Link | `search.google.com/search-console/links` |
| Settings / Impostazioni | `search.google.com/search-console/settings` |

Example: `go "search.google.com/search-console/performance/search-analytics?resource_id=sc-domain:example.com"`.

Switch property from the UI with the `Cerca proprietà` [PopUpButton] (top left), or just change the
`resource_id` in the URL.

## Reading the Performance report

The four metric toggles are buttons whose **name already carries the number**, so `find button` reads the
figures without a screenshot:

- `Clic totali <n>` · `Impressioni totali <n>` · `CTR media <n>%` · `Posizione media <n>`

Other controls: `Aggiungi filtro` [PopUpButton] (by query, page, country, device, date), `ESPORTA`
[PopUpButton], and the table tabs `Query più frequenti` / `Pagine` / `Paesi` / `Dispositivi` with
`Ordina Clic` / `Ordina Impressioni` on the columns. The query rows read from `text` or `table`.

## Notes

- Names are the Italian UI. Nav links (`Rendimento`, `Pagine`, `Sitemap`, `Core Web Vitals`, `HTTPS`,
  `Report Link`, `Impostazioni`) match the URLs above.
- Submitting a sitemap or requesting indexing changes Google's view of the site — confirm with the user first.
- This pairs with `audit`: `audit` measures the live page, Search Console shows how Google already sees it.
