# Cloudflare dashboard (web, in Safari or Chrome)

Partly verified on 13/09/2026 in Safari: the dashboard requires the user's login (and usually 2FA),
which anybrowser cannot do. The interior element names below are **not yet verified** — `find`/`where`
for the real names once the user is signed in, and update this file with what you see.

Why the browser and not the API: the user's `wrangler` OAuth token has no DNS permission
(`api.cloudflare.com` answers `Authentication error` on `/zones/*/dns_records`), so DNS records are
managed from the dashboard by hand. That is the main reason to drive Cloudflare in the browser.

## Sign-in (the user's)

```
anybrowser.sh do 'go dash.cloudflare.com' 'waitfor "Sign in" 8'
```

Verified: `dash.cloudflare.com/` redirects to `/login`, the account's email prefilled
(`Last used`). **The user types the password and passes 2FA** — never a password from anybrowser.
After they're in, tell them to say so, then continue.

## After login — navigate by URL

Cloudflare's URLs are stable; go straight to the page instead of clicking through:

- Account home: `dash.cloudflare.com`
- A zone's overview: `dash.cloudflare.com/<account_id>/<domain>`
- **DNS records** (the common task): `dash.cloudflare.com/<account_id>/<domain>/dns/records`
- SSL/TLS: `.../<domain>/ssl-tls` · Rules/Redirects: `.../<domain>/rules` · Analytics: `.../<domain>/analytics`

The account id and the zone are known per project (e.g. Codename's zone id is in its memory note). If you
don't have the account id, open `dash.cloudflare.com` and read the account/zone links with `find link`.

## DNS records page — how to work it (verify the names on first use)

- Read the current records with `text` or `table` — each row is type · name · content · proxy status · TTL.
- Adding/editing a record is **consequential** (it changes what resolves): find the add/edit control with
  `find button` / `where`, fill by the field names you read, and **confirm the exact record with the user
  before saving**. A wrong DNS record takes a site or its email offline.
- Don't touch MX / SPF / DKIM records unless that is exactly the task — they carry the mail.

## Never

- Never read, copy or record an **API token or key** (Manage Account › API Tokens). If a task seems to
  need one, stop and ask the user.
- Never change security, firewall or SSL settings without the user's explicit go-ahead.
