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
| `issue GenericIssue: FormLabelForNameError` and similar | form fields Chrome can't tie to a label | a `<label for>` or `aria-label` |
| `LCP 3.2 s (slow)` | the largest image or text block comes late | preload the hero image, serve it smaller, avoid render-blocking CSS and JS |
| `CLS 0.16 (high)` | things move while loading | give images, embeds and ads a width and height (or `aspect-ratio`) |
| `no meta description` · `no canonical` · `2 h1` | search basics missing | one description per page, one canonical, one h1 |
| `Open Graph: no og:image` | shared links show no picture | `og:title`, `og:description`, `og:image` |
| `missing headers: strict-transport-security, content-security-policy, x-frame-options` | the host sends no hardening headers | on Cloudflare Pages and Netlify, a `_headers` file; on nginx, `add_header` |
| `tells the world server: nginx/1.18.0` | a version helps attackers pick exploits | `server_tokens off` (nginx), hide `x-powered-by` |
| `cookies … readable by scripts` | a session cookie without HttpOnly | set HttpOnly (and Secure, SameSite) where the server sets it |

## Limits, and how to get past them

- **Not signed in by default.** The audit browser is a fresh visitor. Use `--profile` after
  `audit signin` for private pages.
- **Bot protection.** A site behind Cloudflare's challenge may answer the audit with a challenge
  page, and links with `403`. A `403` in `links` may be a refusal, not a broken link: open it in
  the user's browser before calling it broken.
- **One visit.** The numbers are one load, on this Mac's connection. Run it twice before quoting a
  speed. `--slow` stands in for a phone on a bad network.
- **Lighthouse scores.** Not what `audit` gives. When the user wants the 0–100 scores for a
  report, run Lighthouse itself (`npx lighthouse <url>`). It isn't installed here, and it loads
  the page several times.
- **Be gentle.**
  - `--crawl` stops at 50 pages; links are checked 8 at a time, HEAD first.
  - Don't crawl sites the user doesn't own.
