# Cloudflare Security: Harden Zones Against Scanner Bots

`scripts/cf-security-setup.sh` applies one protection set to the Cloudflare zone you pick. It works on one zone per run. It blocks scanner probes and non-standard ports, puts a Managed Challenge on traffic from hosting networks and (if you choose) from outside Bangladesh, adds a per-IP rate limit, and turns on a few zone settings. Everything stays inside the Free plan limits. The design and the reasons behind each rule are in [the plan](../plans/0001-plan-cf-security-setup-2026-10-05.md).

Do the steps in order. Run a dry run first, then apply to a test zone, then to the real zones.

Legend: `[ ]` todo · 🖐 manual dashboard step · ⛔ verification gate

---

## What the script changes on each zone

| Change | Applies to |
|--------|-----------|
| Block requests on any port other than 80 and 443 | every host |
| Block common scanner paths: any path with `.env`, `/.git`, `/.aws/`, `/.svn`, `/.ds_store`, `/.vscode`, `%25` (double encoding), `phpinfo`, `wp-config.php`, `/phpmyadmin`, `/actuator`, `/server-status`, or `laravel-filemanager`; paths starting `/vendor/`, `/cgi-bin/`, `/venv/`; paths ending `/xmlrpc.php`, `.ini`, `.sql`, `.bak`, `.sh`, `.cgi`, `.jsp`, `.yml`, `.yaml`, `.tar.gz`, `.tgz` | every host, WordPress included |
| Block requests with an empty user agent | every host except API hosts |
| Block every path ending `.php` or starting `/wp-` | every host except WordPress hosts |
| Managed Challenge for traffic from hosting networks (`HOSTING_ASNS`: Microsoft, Amazon, Google Cloud, Oracle, DigitalOcean, Hetzner, OVH, Linode, Vultr, Tencent, Alibaba, TECHOFF) | every host except API hosts. Verified bots, `/.well-known/acme-challenge/`, and the origin IPs of the WordPress hosts pass. |
| Managed Challenge for traffic from outside BD | only when you answer yes to the geo question. Every host except API hosts, with the same exemptions as the hosting network rule. |
| Rate limit: block an IP for 10 s after 300 requests in 10 s on one colo | every host |
| Always Use HTTPS on | the whole zone |
| HTTP to HTTPS Redirect Rule, status 301 | when you select redirect setup |
| WWW to root Redirect Rule, status 301 | default redirect choice; root to WWW and HTTPS only are also available |
| Browser Integrity Check on | only a zone with no API host |
| Bot Fight Mode on | only a zone with no API host and no WordPress host |

> **The script replaces all custom rules and all rate limiting rules on the zone.** Any rule you made by hand in the dashboard is deleted. In `--apply` mode the script saves the old rules first (see [Restore from a backup](#restore-from-a-backup)).

Redirect setup puts `Security setup: HTTP to HTTPS` first, before all existing Redirect Rules. Other existing rules keep their relative order. The hostname rule follows those rules. Its name shows the selected direction as `Security setup: www to non-www` or `Security setup: non-www to www`. Existing rules can override the hostname redirect. The script replaces only rules with refs `cf_security_canonical_host` and `cf_security_https`. A later run can change the direction without adding duplicate rules.

The HTTPS rule uses `(not ssl)` to match unencrypted client connections. Cloudflare documents the [`ssl` field](https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/ssl/) as a boolean.

Both redirects preserve the path and query string. HTTP requests first redirect to HTTPS on the same host. The hostname rule then redirects to the selected host. Other subdomains keep their hostname. The source host needs proxied DNS. The target host needs DNS and HTTPS. The script does not create DNS records.

The script never turns Bot Fight Mode or Browser Integrity Check off. When it skips them, it prints why and leaves your current choice.

---

## Prerequisites

Run the script on your own machine, where you can log in to Cloudflare in a browser. Do not run it on the headless dev box.

- [ ] bash 4.4 or newer. macOS ships bash 3.2, so install a newer one with `brew install bash`. The script stops with a message on an older bash.
- [ ] `jq` 1.6 or newer (`brew install jq`).
- [ ] `pnpm`. The script runs the Cloudflare CLI through `pnpm dlx cf@1.0.0-beta.12`, so you do not install `cf` yourself.
- [ ] Log in to Cloudflare:

  ```bash
  pnpm dlx cf@1.0.0-beta.12 auth login
  ```

- [ ] ⛔ `bash --version` prints 4.4 or newer. On macOS, use the Homebrew bash in every command below:

  ```bash
  "$(brew --prefix)/bin/bash" --version
  ```

- [ ] Know which proxied hosts in each zone are **API hosts** (called by servers, apps, or webhooks, not browsers) and which are **WordPress sites**. The script asks for both. A host cannot be both.

If your login has more than one Cloudflare account, the script asks you to pick one and sets `CLOUDFLARE_ACCOUNT_ID` for the run. You do not set it yourself.

If a later read or write fails with a 403, the login does not have enough scope. Log in with `--scopes`, or use an API token. The token needs Zone WAF Edit, Zone Settings Edit, Bot Management Edit, and DNS Read. Redirect setup also needs Dynamic URL Redirects Edit.

---

## Step 1: Dry run

The dry run reads the real state of your zones and prints every write it would send. It changes nothing.

Run it from the repo root:

```bash
bash scripts/cf-security-setup.sh
```

(`--dry-run` does the same thing.)

1. The script lists the accounts of your `cf` login. Type the number of one account, or `q` to quit. With only one account, the script picks it.
2. The script lists the active zones in that account. Type the number of one zone, or `q` to quit.
3. The script lists the proxied DNS hosts of the zone: the domain and its subdomains. Type the numbers of the API hosts, separated by spaces. Then type the numbers of the WordPress sites. Press Enter on an empty line for none.
4. The script asks `Challenge traffic from outside BD on <zone>? [Y/n]`. Answer `n` for a zone whose real visitors are outside Bangladesh, such as the mimukit.com portfolio. The hosting network rule stays on either way.
5. Select the redirect setup for this zone. Press Enter for HTTP to HTTPS and WWW to root. Select `2` for HTTP to HTTPS and root to WWW. Select `3` for HTTPS only. Select `0` to leave Redirect Rules unchanged. Always Use HTTPS remains enabled with every choice.
6. The script prints the WordPress origin IPs that the hosting network and geo rules exempt. It prints the current custom rules and each write request. It also prints the proposed redirect rules when you select redirect setup.

- [ ] ⛔ The account list shows your accounts, and the zone list shows the active zones of the account you picked.
- [ ] ⛔ The host list shows the proxied hosts you expect.
- [ ] ⛔ `Hosting network and geo rules exempt WordPress origin IPs:` shows the VPS IP of each WordPress site. If you see `WARNING: no A or AAAA record for the WordPress sites`, wp-cron loopback calls will hit the hosting network challenge. Fix the DNS record before you apply.
- [ ] ⛔ Every read succeeds and the summary shows the zone as `OK`.
- [ ] Read the `current custom rules (they will be replaced)` list. Copy any hand-made rule you want to keep, because the apply deletes it.

To change the rate limit, set `RL_REQUESTS` (requests per 10 s per IP and colo, default 300):

```bash
RL_REQUESTS=500 bash scripts/cf-security-setup.sh
```

To change the hosting networks, set `HOSTING_ASNS` to AS numbers separated by spaces. The value replaces the default list:

```bash
HOSTING_ASNS="8075 16509 14618" bash scripts/cf-security-setup.sh
```

---

## Step 2: Apply to a test zone

Pick a zone with no real users first.

```bash
bash scripts/cf-security-setup.sh --apply
```

1. Pick the account and the test zone, and answer the host questions as in Step 1.
2. At `Replace all custom and rate limiting rules on <zone>? [y/N]:` type `y`. Any other answer skips the zone.
3. The script saves the backup, sends the writes, and reads both rule phases back.

- [ ] ⛔ The output shows `Backup saved: cf-backup/<zone>-<UTC time>/`.
- [ ] ⛔ The output shows `Read-back http_request_firewall_custom: OK` and `Read-back http_ratelimit: OK`. A `MISMATCH` marks the zone FAILED.
- [ ] ⛔ The summary shows the zone as `OK` and the script exits 0. It exits 1 when the zone failed.
- [ ] ⛔ Run `--apply` on the same zone again. It prints `OK` again.

`cf-backup/` is in `.gitignore`. Keep the backups outside git until you are sure you no longer need them.

---

## Step 3: Apply to the real zones

Apply to one WordPress zone and one Worker zone first, then to the rest. Run the same command once for each zone, and pick the account and zone each time.

```bash
bash scripts/cf-security-setup.sh --apply
```

- [ ] One WordPress zone applied, read-back `OK`
- [ ] One Worker zone applied, read-back `OK`
- [ ] All remaining zones applied, read-back `OK`

---

## Step 4: Verify each zone

Do these checks on each zone in the hour after you apply.

- [ ] 🖐 Cloudflare → the zone → **Security → Events**. Watch for one hour. Scanner hits show as blocked. No real user from Bangladesh is blocked.
- [ ] ⛔ A probe is blocked:

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' https://DOMAIN/.env
  ```

  Expect `403`.
- [ ] ⛔ On each WordPress site, `/wp-admin/` loads, and **Tools → Site Health** shows no loopback error. A loopback error means the VPS sends from an IP that is not in the A record, for example a DigitalOcean reserved IP.
- [ ] ⛔ On each API host, a real client call still works.

If a WordPress site uses Jetpack or the WordPress mobile app, it needs `/xmlrpc.php`. The script blocks that path on every host. Remove it from the common path list in `custom_rules()` and apply again.

---

## Step 5: Turn off the `workers.dev` address on each Worker

No `cf` command turns off the `workers.dev` and preview URLs, so a scanner can still reach a Worker there and skip the zone rules. Change it in each Worker's repo.

- [ ] In each Worker's `wrangler.jsonc`, set:

  ```jsonc
  "workers_dev": false,
  "preview_urls": false,
  ```

- [ ] Deploy each Worker again so the change takes effect.
- [ ] **Skip `brainaloy-vps-cf-tunnel`.** Its callers use the `workers.dev` URL, so it keeps `"workers_dev": true` in `brainaloy-vps-cf-tunnel/worker/wrangler.jsonc`. It already has `"preview_urls": false`.

---

## Restore from a backup

Each `--apply` saves the state before the change to `cf-backup/<zone>-<UTC time>/`:

| File | Holds |
|------|-------|
| `http_request_firewall_custom.json` | the custom rules |
| `http_ratelimit.json` | the rate limiting rule |
| `always_use_https.json` | the Always Use HTTPS setting |
| `browser_check.json` | the Browser Integrity Check setting |
| `bot_management.json` | the Bot Fight Mode config |

When you select redirect setup, the backup also contains `http_request_dynamic_redirect.json`. An empty object means that the zone has no redirect ruleset before this run. Old backups and runs that skip redirect setup do not contain this file.

The script has no restore flag. Restore by hand:

1. Pick the backup directory, for example `cf-backup/example.com-20261005T120000Z/`. If your login has more than one account, set the account that owns the zone, or the `cf` commands below fail:

   ```bash
   export CLOUDFLARE_ACCOUNT_ID=<account id>
   ```

   `pnpm dlx cf@1.0.0-beta.12 accounts list` shows the IDs.
2. Extract the custom rules:

   ```bash
   jq '.rules // .result.rules // []' cf-backup/<dir>/http_request_firewall_custom.json > /tmp/rules.json
   ```

3. Send them back:

   ```bash
   pnpm dlx cf@1.0.0-beta.12 rulesets account-rulesets phases update http_request_firewall_custom --zone <domain> --rules @/tmp/rules.json
   ```

4. Repeat steps 2 and 3 with `http_ratelimit.json` and the phase `http_ratelimit`.
5. Read the `value` in `always_use_https.json` and `browser_check.json`. Set each setting back if it changed:

   ```bash
   pnpm dlx cf@1.0.0-beta.12 zones settings edit browser_check --zone <domain> --body '{"value":"off"}'
   ```

6. Restore Redirect Rules when the backup contains `http_request_dynamic_redirect.json`:

   ```bash
   jq '.rules // .result.rules // []' cf-backup/<dir>/http_request_dynamic_redirect.json > /tmp/redirect-rules.json
   pnpm dlx cf@1.0.0-beta.12 rulesets account-rulesets phases update http_request_dynamic_redirect --zone <domain> --rules @/tmp/redirect-rules.json
   ```

   An empty backup produces an empty rule list. This removes the new redirects.
7. If `bot_management.json` shows Bot Fight Mode off, turn it off in the dashboard: 🖐 the zone → **Security → Bots**.

---

## Check the redirects

Run these requests after an apply. Replace the domain with your zone.

```bash
curl -I 'http://www.example.com/test?source=check'
curl -I 'https://www.example.com/test?source=check'
curl -I 'http://example.com/test?source=check'
```

For WWW to root, the first request redirects to `https://www.example.com/test?source=check`. The second request redirects to `https://example.com/test?source=check`. For root to WWW, expect the WWW hostname as the target. The target HTTPS hostname must not redirect back to the source hostname. Existing Redirect Rules, Page Rules, or origin redirects can cause conflicts. Check them before you apply the new rules.

The script verifies redirect rules immediately after their update. A later Bot Fight Mode failure can still produce a `FAILED` summary. Earlier changes remain active.

## Offline checks

Run the script checks without Cloudflare credentials:

```bash
python3 -B -m unittest discover -s tests -v
```

The tests use a fake `pnpm` executable. They send no Cloudflare requests. The tests require Bash 4.4 or newer and `jq`.

## Known limits

- The Free plan allows 10 Single Redirect rules. The script stops before any write if the proposed redirect rules exceed this limit.
- The script reads hosts from DNS records. A Worker custom domain that exists only as a route does not appear in the host picker.
- The hosting network rule challenges every server in those networks, including your own servers and uptime monitors. DigitalOcean (14061) is in the list, so a droplet that calls a host on the zone gets a challenge. Mark that host as an API host, or remove the AS number from `HOSTING_ASNS`.
- The probe rule blocks paths ending `.yml` and `.yaml` on every host, API hosts included. An API host that serves an OpenAPI file in YAML needs a change to `custom_rules()` first.
- The export of Security Events shows only mitigated requests. To see the probes that pass every rule, use Analytics → Traffic with a status `404` filter.
- Bot Fight Mode and Browser Integrity Check are zone-wide on the Free plan. Put API hosts on a separate zone if you want both on for the browser hosts.

---

## Checklist

- [ ] Prerequisites met, `cf` logged in
- [ ] Dry run read, hand-made rules copied if needed
- [ ] Test zone applied twice, read-back `OK` both times
- [ ] One WordPress zone and one Worker zone applied
- [ ] All zones applied, backups kept
- [ ] Security Events watched for one hour per zone
- [ ] WordPress Site Health shows no loopback error
- [ ] `workers_dev: false` and `preview_urls: false` deployed on every Worker except `brainaloy-vps-cf-tunnel`

The redirect payload follows the [Cloudflare Single Redirects API](https://developers.cloudflare.com/rules/url-forwarding/single-redirects/create-api/) and [redirect settings](https://developers.cloudflare.com/rules/url-forwarding/single-redirects/settings/).
