# Auditing a site

For sites the user owns or is allowed to test. `audit` reads what Chrome's DevTools
panels show — Console, Network, Issues, Performance, Security — straight from the
DevTools Protocol of a headless Chromium of its own. It never opens a DevTools window,
never touches the user's browser or its settings, and needs no extension or permission.

Measured on 12/09/2026 on this Mac (MacBook Pro 2018, Chromium 146), browser start included:

| Audit | Time |
|---|---|
| danielelore.com, one page | 2.5 s |
| codename.cc, `--crawl 5` (2 pages found) and `--links` | 6.0 s |
| danielelore.com, `--mobile --slow` | 3.4 s |

## The options that go deeper

- **`--a11y`** runs **axe-core** (Deque's engine, the one behind most accessibility tools) inside the
  page: about 90 WCAG rules, each violation with its element and impact (critical/serious/moderate/minor).
  It adds ~1 s. The plain audit already flags contrast, missing labels and nameless buttons; `--a11y`
  adds the rest (ARIA misuse, heading order, landmarks, name-role-value, and so on). Run it for a real
  accessibility report; skip it for a quick check.
- **`--save`** records the run for that address and, from the second time on, prints a `change` line:
  what got better or worse (errors, warnings, a11y) per page. Good before and after a fix, and for a
  weekly check that tells you if a live site has regressed.
- **`--fullshot file.png`** captures the whole page top to bottom, not just the first screen.
- The plain audit now also reports, in `errors` and `to fix`: **exposed files** (`/.env`,
  `/.git/config`, config backups that answer 200 with real content), **oversized images** (source
  pixels far larger than the box they're shown in), and **structured data that isn't valid JSON**.

## The order of work

1. **Overview**: `audit https://site --crawl 20 --links`. It gives one line per page, then errors and
   warnings with the page they're on, the problems per page, and speed, weight and security
   for the first page.
2. **Each page with errors**: `audit https://site/page --json`. The JSON lists every request with its
   status, bytes and wait, the response headers, and the page's facts.
3. **Phones**: `audit https://site --mobile --slow` on the home page and the pages that earn money
   (contact, booking, checkout). Google judges the mobile page.
4. **Signed-in pages** (an admin panel, a customer area):
   - Run `audit signin https://site/login` once. The user signs in themselves in the window that
     opens, then quits that browser.
   - From then on, `audit https://site/area --profile` is signed in.
   - Never type a password for them.
5. **Only when something needs to be seen**, reproduce it in the user's browser: `go`, `read`,
   `shot --window`.

Report to the user by impact: broken things first (errors, broken links, 404s), then what costs
visitors (LCP, CLS, weight on phones), then search (title, description, canonical, h1), then
hardening (headers, cookies). Quote the finding lines as they are; they're already short.

## What a finding usually means

| Finding | Usual cause | Usual fix |
|---|---|---|
| `exception … — /app.js:12:5` | a script error at that line; later scripts may not run | fix the code there; check the page again |
| `404 /img/x.webp (Image)` | a file renamed or never uploaded | upload it, or correct the path in the page |
| `404 /favicon.ico` (warning) | no favicon at the root | add `/favicon.ico` or a `<link rel="icon">` |
| `failed … net::ERR_NAME_NOT_RESOLVED` | a domain that doesn't exist (an old API, a typo) | remove it or fix the address |
| `failed … blocked: csp` · `issue ContentSecurityPolicy` | the site's CSP forbids that resource | add its origin to the right directive, or drop the resource |
| `issue Cors …` | an API that doesn't allow this origin | `Access-Control-Allow-Origin` on the API |
| `mixed … loaded over http` | an `http://` address inside an https page | use https (or a relative address) |
| `slow … the server took 1.8 s` | a slow backend or cold serverless function | cache it, or move it off the page's first load |
| `heavy /hero.png — 1.4 MB` | an image far bigger than shown | resize, then WebP/AVIF |
| `uncompressed /app.js — 300 KB` | the server doesn't gzip or brotli | turn on compression at the host or CDN |
| `issue LowTextContrast: 11 elements, worst 1.20 where 3.0 is needed — h2.h2, …` | text too light on its background, the worst first | darken the text or its background for those selectors; a ratio near 1.0 is often text over an image or a gradient, which Chrome can't measure: look at it before reporting |
| `CLS 0.16 (high: div.hero, img.logo moved)` | those elements move while the page loads | give them a width and height (or `aspect-ratio`), reserve room for what loads late |
| `the viewport blocks zooming (width=device-width, user-scalable=no)` | people with poor sight can't pinch to zoom | drop `user-scalable=no` and `maximum-scale=1` |
| `search   no robots.txt · no sitemap` | search engines get no map of the site | add `/robots.txt` naming `Sitemap: https://site/sitemap.xml`, and the sitemap itself |
| `search   robots.txt BLOCKS every search engine from every page` | a `Disallow: /` left from development | remove it, unless the site really must stay out of search |
| `search   … missing pages answer 200 instead of 404 (a soft 404: add a 404 page)` | Cloudflare Pages without a `404.html` answers every address with the home page (found on all three of the user's sites) | add a short `404.html` with a link home |
| `exposed  /.env is public — environment file with secrets` | a secrets file, a `.git` folder or a config backup is served to anyone | remove it from what's deployed; rotate any secret that was in it |
| `<factor>× oversized image: /hero.jpg 4000×3000→400×300` | the file is far bigger than it's shown, so phones waste data | export it near the display size (times the screen density), then WebP/AVIF |
| `a11y  serious  label: Form elements must have labels — 3 elements` (with `--a11y`) | axe-core's WCAG rules; the kind and the element are in the line | fix per the rule id (`label`, `color-contrast`, `aria-*`, `heading-order`…); deque.com/rules has each |
| `<n> structured-data blocks isn't valid JSON` | a JSON-LD block has a syntax error, so search engines drop it | fix the JSON (a trailing comma, a smart quote) |
| `issue GenericIssue: FormLabelForNameError` and similar | form fields Chrome can't tie to a label | a `<label for>` or `aria-label` |
| `LCP 3.2 s (slow)` | the largest image or text block comes late | preload the hero image, serve it smaller, avoid render-blocking CSS and JS |
| `CLS 0.16 (high)` | things move while loading | give images, embeds and ads a width and height (or `aspect-ratio`) |
| `no meta description` · `no canonical` · `2 h1` | search basics missing | one description per page, one canonical, one h1 |
| `Open Graph: no og:image` | shared links show no picture | `og:title`, `og:description`, `og:image` |
| `missing headers: strict-transport-security, content-security-policy, x-frame-options` | the host sends no hardening headers | on Cloudflare Pages and Netlify, a `_headers` file; on nginx, `add_header` |
| `tells the world server: nginx/1.18.0` | a version helps attackers pick exploits | `server_tokens off` (nginx), hide `x-powered-by` |
| `cookies … readable by scripts` | a session cookie without HttpOnly | set HttpOnly (and Secure, SameSite) where the server sets it |

## Fixing a site, verified on danielelore.com, codename.cc and salentofood.pages.dev (12/09/2026)

1. **Keep a copy first.** None of the three sites was a git repository.
2. **Compare the live page with the local source before editing** (`curl` against the file). On
   danielelore.com the only difference was Cloudflare's email obfuscation, which rewrites
   `mailto:` links on the fly.
3. **Serve the fix locally the way the host does.** `wrangler pages dev <dir> --port N` applies
   `_headers` and `404.html`, and runs the Functions. Audit it there.
   - Start one `wrangler pages dev` at a time, since two collide on the inspector port 9229.
   - `upgrade-insecure-requests` in the CSP did no harm on `http://127.0.0.1`.
4. **Deploy to a preview branch** (`--branch anteprima`), audit `https://anteprima.<project>.pages.dev`,
   then deploy production. Production reuses the uploaded files ("0 files uploaded").
5. **Audit the real domain again.** Cloudflare injects scripts there that the preview doesn't have:
   - email obfuscation, from `/cdn-cgi` (same origin);
   - Web Analytics (`static.cloudflareinsights.com`, beacon to `cloudflareinsights.com`).

   A CSP that forgets them breaks the page; with them listed, the audit shows `errors 0`.

Traps met along the way:

- **`wrangler pages deploy <dir>` publishes every file in the folder.** Design notes and a zip sat
  next to codename.cc's pages. Deploy from a copy that holds only the site's files.
- **In `_headers`, `/` matches only the home page.** Headers for every address go under `/*`. The
  same header under both is sent twice.
- **Low contrast:**
  - Compute the passing colour; don't guess it. Darken the same hue in OKLCH until the ratio
    reaches 4.5 on the lightest background it sits on (a white card over the page counts).
  - Keep a separate, darker token for coloured *text* than for filled buttons.
- **CLS from web fonts:** a fallback `@font-face` with `size-adjust`, `ascent-override` and
  `descent-override` measured from the font files. Measure with fontTools, weighting average glyph
  width by letter frequency. It took codename.cc from 0.16 to 0.
- **CLS from content drawn by script:** reserve the space the text will take (`min-height`), and
  keep an empty footer hidden until it's filled (`:empty { display: none }`).

## Limits, and how to get past them

- **Contrast is measured on what's visible.** Hidden elements, and text scrolled out of a scrolling
  panel, are left out, because Chrome measures them against whatever lies under that spot. A site
  with a dark theme has colours of its own: audit it again with `--dark`.

- **Not signed in by default.** The audit browser is a fresh visitor. Use `--profile` after
  `audit signin` for private pages.
- **Bot protection.** A site behind Cloudflare's challenge may answer the audit with a challenge
  page, and links with `403`. A `403` in `links` may be a refusal, not a broken link: open it in
  the user's browser before calling it broken.
- **One visit.** The numbers are one load, on this Mac's connection. Run it twice before quoting a
  speed. `--slow` stands in for a phone on a bad network.
- **Counts drift between visits.** A cookie banner, a fundraising or campaign banner, an A/B test or a
  rotating ad brings its own errors, warnings and a11y findings, so two runs of the same page can differ
  (a Wikipedia mobile run swung between 2 and 4 a11y findings on its fundraising banner). Cookie
  *deprecation* notices (SameSite, third-party phase-out) are already grouped into one `deprecation`
  line, apart from real errors — they're browser-wide and usually not the site's to fix. Treat a small
  `--save` delta as noise unless the finding names something you changed.
- **A contrast ratio near 1.0** is almost always text over an image or a gradient, which Chrome reads
  as one flat colour — the line says so. Look at the element before reporting it; `--a11y`'s
  `color-contrast` rule skips those.
- **Lighthouse scores.** Not what `audit` gives. When the user wants the 0–100 scores for a
  report, run Lighthouse itself (`npx lighthouse <url>`). It isn't installed here, and it loads
  the page several times.
- **Be gentle.**
  - `--crawl` stops at 50 pages; links are checked 8 at a time, HEAD first.
  - Don't crawl sites the user doesn't own.
