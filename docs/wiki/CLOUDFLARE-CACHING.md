# Cloudflare Caching — WordPress Brochure Sites

Aggressive full-page CDN caching for the WordPress sites, configured entirely in
the Cloudflare dashboard (no plugin). These are largely static brochure sites, so
we cache **all HTML** at the edge, bypass only the dynamic paths, and let
Cloudflare keep serving pages even when the origin VPS is down.

> Do this **per zone** (per site domain). Repeat the whole checklist for each site.

Legend: `[ ]` todo · 🖐 manual dashboard step · ⛔ verification gate

---

## What this achieves

- HTML pages cached at Cloudflare's edge → most requests never hit the VPS.
- `wp-admin`, login, previews, and logged-in visitors always bypass the cache.
- **Always Online** serves the last cached copy of a page if the origin is down.

Trade-off you are accepting: because HTML is cached for days, **edits will not
appear until you purge**. See [Purging after you edit](#purging-after-you-edit).

---

## Prerequisite — the record must be proxied (orange cloud)

The runbook creates the DNS A record as **DNS-only (grey cloud)**. Cloudflare
cannot cache or protect a grey-cloud record — traffic goes straight to the VPS.

- [ ] 🖐 Cloudflare → **DNS → Records** → edit the `A` record for the domain (and `www` if present) → toggle the cloud to **Proxied (orange)**
- [ ] ⛔ `dig +short DOMAIN` returns **Cloudflare IPs** (104.x / 172.x), not the VPS IP
- [ ] ⛔ Site still loads over HTTPS with a valid cert (Let's Encrypt on origin + Cloudflare edge cert). If you hit a redirect loop, set **SSL/TLS → Overview → Full (strict)**, not Flexible.

---

## Step 1 — Bypass cache for dynamic paths (create this rule FIRST)

**Caching → Cache Rules → Create rule.** Name it `WP bypass dynamic`.

Rules are evaluated in order and the **first match wins**, so this bypass rule
must sit **above** the cache-everything rule (Step 2). Give it the higher
priority (lower number / drag to top).

**When incoming requests match** — use the expression editor and paste:

```
(http.request.uri.path contains "/wp-admin/") or
(http.request.uri.path contains "wp-login.php") or
(http.request.uri.path contains "/wp-json/") or
(http.request.uri.path contains "xmlrpc.php") or
(http.request.uri.path contains "/wp-cron.php") or
(http.request.uri.query contains "preview=true") or
(http.cookie contains "wordpress_logged_in") or
(http.cookie contains "wp-postpass") or
(http.cookie contains "comment_author")
```

**Then:**

- [ ] 🖐 Cache eligibility → **Bypass cache**
- [ ] 🖐 Save

Why each matters:

- `wp-admin` / `wp-login.php` / `xmlrpc.php` / `wp-cron.php` — never cache the admin surface or cron.
- `/wp-json/` — REST API responses are dynamic (forms, blocks).
- `preview=true` — draft previews must never be cached.
- `wordpress_logged_in` cookie — a logged-in editor must see the live site + admin bar, never a cached copy.
- `wp-postpass` / `comment_author` — password-protected posts and comment authors.

---

## Step 2 — Cache everything else

**Caching → Cache Rules → Create rule.** Name it `WP cache all HTML`. Place it
**below** the bypass rule.

**When incoming requests match:**

```
(http.host eq "DOMAIN")
```

Replace `DOMAIN` (e.g. `southheavenproperties.com`). Add `or (http.host eq "www.DOMAIN")`
if the site serves `www`.

**Then:**

- [ ] 🖐 Cache eligibility → **Eligible for cache**
- [ ] 🖐 Edge TTL → **Override origin** → **7 days** (`604800` seconds) — drop to 1 day if a site changes more often
- [ ] 🖐 Edge TTL → **Add status code TTL** to keep error responses out of cache (see warning below):
  - `200`–`299` → **7 days** · `301`/`302` → **7 days**
  - `404` → **No-store** (or 1 minute) · `500`–`599` → **No-store**
- [ ] 🖐 Browser TTL → **Override origin** → **4 hours** — keep short so returning visitors re-check the edge and pick up purges quickly
- [ ] 🖐 Save

> ⚠️ **Do not skip the status-code TTL.** A blanket "Override origin" caches
> *every* status code, including errors. If the origin is down during a deploy
> or an Always Online drill, the Dokploy/Traefik router returns a plain-text
> `404 page not found`, and Cloudflare will pin **that 404 for the full 7-day
> Edge TTL** — the page stays broken long after the origin recovers. Restricting
> long TTLs to `2xx`/`3xx` and never-caching `404`/`5xx` prevents this.

> Do **not** use the legacy "Page Rules" — Cache Rules are the current, more
> granular replacement and take precedence.

---

## Step 3 — Always Online (serve cached pages when the origin is down)

- [ ] 🖐 **Caching → Configuration → Always Online → ON**

When the origin returns 5xx or is unreachable, Cloudflare serves the last cached
version of each page. It only covers pages Cloudflare has already cached, so it
pairs directly with Steps 1–2. This is what keeps the site up if the Dokploy
container or VPS goes down.

---

## Step 4 — Tiered Cache (better hit ratio, free)

- [ ] 🖐 **Caching → Tiered Cache → Smart Tiered Caching → ON**

Lets Cloudflare POPs pull from an upper-tier cache instead of all hitting the
origin, improving hit ratio and reducing origin load. Free on all plans.

---

## Verify

Run logged out / in a fresh incognito window.

- [ ] ⛔ Public page caches — `curl -sI https://DOMAIN/ | grep -i cf-cache-status`. First request → `cf-cache-status: MISS`; reload → **`HIT`**.
- [ ] ⛔ Admin bypasses — `curl -sI https://DOMAIN/wp-admin/ | grep -i cf-cache-status` → **`BYPASS`** or **`DYNAMIC`** (never `HIT`).
- [ ] ⛔ Logged in (real browser): you see the admin bar and live content, never a stale cached page.
- [ ] ⛔ Always Online: (optional drill) stop the WordPress container in Dokploy, load a previously-visited page → it still renders from cache.

---

## Purging after you edit

Heavy caching means **your edits will not show up until the cache is cleared** —
there is no plugin auto-purge in this setup. After changing content:

- [ ] 🖐 **Caching → Configuration → Purge Cache → Purge Everything** (fine for these small sites), or **Custom Purge** by the specific URL(s) you changed.

Tip: if a site's editor updates content frequently and forgets to purge, lower
that zone's Edge TTL (Step 2) to **1 day** or a few hours as a safety net.

---

## Troubleshooting — one page 404s while the rest work

Symptom: a single URL (e.g. `/about-us/`) returns **404** for everyone, but
loads fine everywhere else.

- [ ] Confirm it's a **cached** error, not the origin:
      - `http GET https://DOMAIN/about-us/` → `cf-cache-status: HIT`, body `404 page not found` (plain text = the Traefik router, not WordPress).
      - `http GET "https://DOMAIN/about-us/?cb=123"` (cache-busting query) → `200` with the real page = origin is healthy, the cache is stale.
- [ ] **Fix:** Custom Purge that exact URL (**Caching → Purge Cache → Custom Purge**).
- [ ] **Root cause / prevention:** a `404`/`5xx` got cached while the container
      was down (deploy, restart, or an Always Online drill). Make sure the
      **status-code TTL** from Step 2 is set so errors are never stored.

---

## Caveats for these sites

- **Contact forms:** POST submissions are never cached. If a form embeds a nonce in the HTML, a multi-day Edge TTL can serve a stale nonce and the submit fails. If a site has a form, either keep that zone's Edge TTL to ~1 day, or add the form page's path to the Step 1 bypass expression.
- **No cart / login / member areas** on brochure sites → this simple setup is safe. If a site later adds WooCommerce, extend the Step 1 bypass with `/cart/`, `/checkout/`, `/my-account/` and the `woocommerce_*` cookies.
- Keep **SSL/TLS mode = Full (strict)** so the proxied edge trusts the origin's Let's Encrypt cert.

---

## Per-site checklist (quick copy)

- [ ] DNS record flipped to **Proxied (orange)**
- [ ] Rule 1 `WP bypass dynamic` created (top priority)
- [ ] Rule 2 `WP cache all HTML` created (below rule 1), Edge TTL set
- [ ] Status-code TTL set so `404`/`5xx` are **not** cached
- [ ] Always Online **ON**
- [ ] Smart Tiered Caching **ON**
- [ ] Verified `MISS → HIT` on a public page, `BYPASS` on `/wp-admin/`
