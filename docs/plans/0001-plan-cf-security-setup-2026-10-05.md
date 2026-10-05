# Plan: Cloudflare zone hardening script (`cf-security-setup.sh`)

Grilled: 2026-10-05 (two rounds)

This plan records what the script does after the grilling session. It started from the handoff at `360engineering/docs/handoffs/0001-handoff-cloudflare-bot-hardening-script-2026-10-05.md`.

## Context

The owner's Workers-backed domains on Cloudflare take thousands of scanner hits a day. The scanners probe `.env`, `.php`, `/wp-*`, `/vendor/composer/installed.json`, `credentials.ini`, and non-standard proxied ports (8443, 8080, 8880, 2082, 2086, 2087, 2096). Most traffic comes from Azure ranges with an empty user agent, and from outside Bangladesh. The services target Bangladeshi users only.

The probes find nothing, because a Worker has no files on disk. The goal is to cut noise and paid Worker invocations. WAF custom rules run before the Worker, so a blocked request never starts it. Success means one script that the owner runs on their own machine, where `cf` is logged in, to apply the same protection set to chosen zones, and that a dry run shows exactly what it would send.

The same account also holds the WordPress brochure sites from this repo. `docs/wiki/CLOUDFLARE-CACHING.md` sets their records to Proxied, so the WAF rules reach them too. They need PHP and `/wp-` paths, so they get a narrower probe rule.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Script location | `scripts/cf-security-setup.sh` in this repo, beside the other operator scripts. |
| Language | Bash 4.4 or newer with `jq` 1.6 or newer. No build step. The script stops with a clear message on an older bash, such as the macOS bash 3.2. |
| CLI call | `pnpm dlx cf@1.0.0-beta.12`, pinned, because the CLI is a beta. No `npm` or `npx`. Every call reads stdin from `/dev/null`, so the CLI cannot take the answers typed for a prompt. |
| Run mode | Dry run is the default. `--dry-run` is an explicit alias. `--apply` sends changes and asks `y/N` per zone. Dry run passes `--dry-run` to every write command. Reads are real in both modes. |
| Zone selection | The script runs `cf zones list`, prints a numbered list, and takes numbers or `all`. No config file. |
| Host roles | There is no per-zone mode. For each zone the script lists proxied DNS hosts (`cf dns records list`). The owner picks the API hosts, then the WordPress hosts. A host cannot be both. |
| Empty user agent rule | Applies to every host except the API hosts, through `not http.host in {...}`. |
| PHP and `/wp-` block | Applies to every host except the WordPress hosts. |
| Common scanner paths | Blocked on every host, WordPress included: `/.env`, `/.git`, `/.aws/`, `wp-config.php`, `/phpmyadmin`, `.ini`, `.sql`, `.bak`, `/xmlrpc.php`, `/vendor/`, `/cgi-bin/`. Path matches use `lower()`, so `/.ENV` does not pass. |
| Geo rule action | Managed Challenge, so Bangladeshi users on a foreign VPN can pass. |
| Geo rule exceptions | Verified bots (`cf.client.bot`), the API hosts, the origin IPs of the WordPress hosts, and `/.well-known/acme-challenge/`. A server client cannot solve a challenge, so a challenge on an API host is a block. WordPress sends `wp-cron` loopback calls from its VPS, which is outside Bangladesh. Let's Encrypt validates from outside Bangladesh. |
| WordPress origin IPs | The script takes them from the `content` of the A and AAAA records of the WordPress hosts. It prints them, and warns when a WordPress host has no such record. |
| Bot Fight Mode | It is zone-wide and Cloudflare cannot scope it to a host. The script turns it on only for a zone with no API host and no WordPress host. It would challenge the WordPress loopback calls from the VPS. Otherwise the script skips it, prints that it skipped, and never turns it off. |
| Browser Integrity Check | Also zone-wide. The script turns it on only for a zone with no API host, because it can block non-browser API clients. Otherwise it skips the setting. |
| Cross-zone Worker calls | None. The owner confirmed that no Worker calls a host on another of the owner's zones. |
| Webhook exceptions | None. The owner confirmed that `bot.karigorai.com` is not a Telegram webhook and that no host takes calls from outside Bangladesh. |
| Rule ownership | The script owns the whole custom rule phase and the whole rate limiting phase. `phases update` replaces every rule. |
| Backup | Before the confirmation prompt, the script reads both phases, `always_use_https`, `browser_check`, and the Bot Management config. A read error stops the zone. A 404 on a phase counts as "no rules yet". In `--apply` mode the script copies the reads to `cf-backup/<zone>-<UTC timestamp>/`, one file each. `cf-backup/` is in `.gitignore`. |
| Failure handling | Each zone runs in its own subshell with `set -e` on. The script runs the subshell outside an `if`, because bash turns off `set -e` in a subshell that an `if` tests. A failure does not stop the other zones. The summary lists OK, SKIPPED, and FAILED zones. The script exits 1 if any zone failed. A skipped zone does not fail the run. |
| Read-back | After `--apply` the script runs `phases get` for both phases. It compares `action`, `expression`, and the rate limit values with what it sent, and ignores fields that the API adds. It prints OK or MISMATCH. |
| Rate limit | Default 300 requests per 10 s per IP and colo. `RL_REQUESTS` overrides it. The Free plan fixes the period at 10 s. Many Bangladeshi users share one mobile IP, so 100 was too tight. The expression is `starts_with(http.request.uri.path, "/")`, because the Free plan allows only the path and verified bot fields in a rate limiting rule. |
| `workers_dev` reminder | The summary tells the owner to set `workers_dev: false` in each Worker, except `brainaloy-vps-cf-tunnel`. Its callers use its `workers.dev` URL. |
| Non-interactive mode | A non-goal. The script has prompts and no skip flags. |
| Probe path match | `ends_with`, `contains`, `starts_with`. The `matches` regex operator needs a Business plan. |
| Country field | `ip.src.country`. `ip.geoip.country` is deprecated. |
| Login | Never on the dev box. The owner runs the script locally. |

## Approach

One bash script with these parts. It reuses the `scripts/` convention and the header style of `scripts/vps-audit.sh`.

1. Parse the flag (`--dry-run`, `--apply`, or none). Check bash 4.4, `jq`, and `pnpm`.
2. List zones with `cf zones list` and ask the owner to pick.
3. For each chosen zone, in its own subshell: list proxied hosts, ask for API hosts and WordPress hosts, read the current state, show the current custom rules, and in apply mode ask for confirmation and save the backup.
4. Build the rule JSON with `jq`, send it with `cf`, and in apply mode read it back and compare.
5. Print a summary and set the exit code.

The protection set per zone, within Free plan limits (5 custom rules, 1 rate limiting rule):

- Custom rule 1: block when `cf.edge.server_port` is not 443 or 80.
- Custom rule 2: block probes. It blocks the common scanner paths on every host. It blocks paths ending `.php` or starting `/wp-` on every host except the WordPress hosts. It blocks an empty user agent on every host except the API hosts.
- Custom rule 3: Managed Challenge when `ip.src.country ne "BD"`, with the exceptions in the table above.
- Rate limit: `RL_REQUESTS` (default 300) per 10 s, mitigation timeout 10 s, characteristics `cf.colo.id` and `ip.src`, action block.
- Zone setting `always_use_https` set to `on`.
- Zone setting `browser_check` set to `on`, only when the zone has no API host.
- Bot Fight Mode on, only when the zone has no API host and no WordPress host.

Commands used:

| Step | Command |
|------|---------|
| List zones | `cf zones list --per-page 50` |
| List hosts | `cf dns records list --zone <domain> --per-page 500` |
| Read rules | `cf rulesets account-rulesets phases get <phase> --zone <domain>` |
| Read setting | `cf zones settings get <setting> --zone <domain>` |
| Read Bot Management | `cf bot-management get --zone <domain>` |
| Custom rules | `cf rulesets account-rulesets phases update http_request_firewall_custom --zone <domain> --rules @file` |
| Rate limit | same command, phase `http_ratelimit` |
| Zone setting | `cf zones settings edit <setting> --zone <domain> --body '{"value":"on"}'` |
| Bot Fight Mode | `cf bot-management update --zone <domain> --fight-mode` |

### Restore from a backup

1. Find the backup directory, for example `cf-backup/example.com-20261005T120000Z/`.
2. Extract the rules of one phase: `jq '.rules // .result.rules // []' <dir>/http_request_firewall_custom.json > /tmp/rules.json`.
3. Send them: `cf rulesets account-rulesets phases update http_request_firewall_custom --zone <domain> --rules @/tmp/rules.json`.
4. Do steps 2 and 3 again for `http_ratelimit`.
5. Set each zone setting back to the `value` in its file with `cf zones settings edit`.
6. If `bot_management.json` shows Bot Fight Mode off, turn it off in the dashboard.

Rejected alternatives, one line each:

- A `security.config.json` file with one entry per domain. The owner chose an interactive picker.
- One `site` or `api` mode per zone. A zone can hold both kinds of host, so the script asks per host.
- Merge with hand-made dashboard rules. The result would depend on dashboard state.
- TypeScript on Node. It needs a runner, and the script only calls a CLI.
- Keep WordPress zones out of the script. The owner wants the geo rule and the scanner path block on them too.
- Block every `.php` path on WordPress hosts. It takes the site and `wp-admin` down.

### Phase 1: Script with dry run, backup, and read-back

Write `scripts/cf-security-setup.sh` as described above. Add the row to the `scripts/` table in `README.md`. Add `cf-backup/` to `.gitignore`. The code exists in the working tree, uncommitted.

Done when: `bash -n scripts/cf-security-setup.sh` exits 0, the rule builders print the expected expressions with and without API and WordPress hosts, an offline run against a fake `cf` shows a failed read as FAILED, and the read-back ignores added API fields but catches a changed value. All four passed on 2026-10-05.

### Phase 2: Dry run against the real account

The owner runs `bash scripts/cf-security-setup.sh` on their machine, logged in to `cf`, and reads the output.

Done when: the zone list shows the owner's real zones, the host list shows proxied hosts, the WordPress origin IPs match the VPS, every read succeeds, and each write command prints a request body.

A dry run does not send the write requests, so it cannot show that the API accepts them. Phase 3 is the first real check.

### Phase 3: Apply and watch

The owner runs `--apply` on a test zone first. A test zone is a domain with no real users. Then the owner runs it on one WordPress zone and one Worker zone, and then the rest.

Done when: each applied zone prints `Read-back ... OK` for both phases, a `cf-backup/` directory exists for each, Security → Events shows blocked scanner hits for one hour with no real user blocked, a second `--apply` prints `OK` again, and on each WordPress zone `wp-admin` loads and Tools → Site Health shows no loopback error.

## Open questions

- The JSON shape of `cf zones list`, `cf dns records list`, and `cf ... phases get` is a guess. The script accepts a bare array, `.result`, or `.zones`. A real dry run settles it.
- `cf zones settings get` and `cf bot-management get` are guesses based on the `edit` and `update` commands. A real dry run settles it.
- The error text for a missing phase is a guess. The script treats `404`, `not found`, or `could not find` as "no rules yet". A real dry run on a zone with no custom rules settles it.
- OAuth scopes for `cf auth login` are unknown. A 403 means the owner needs `--scopes` or an API token with Zone WAF Edit, Zone Settings Edit, Bot Management Edit, and DNS Read.
- The `--fight-mode` flag, the `phases update` body, `lower()` inside `ends_with()`, and the path-only rate limit expression were checked offline only. The first apply on the test zone settles them.
- The WordPress origin IP comes from the DNS record. If the VPS sends from another IP, for example when the record points to a DigitalOcean reserved IP, the loopback calls still hit the geo challenge. The Site Health check in Phase 3 shows it.
- `/xmlrpc.php` is blocked on WordPress hosts. Jetpack and the WordPress mobile app need it. Remove it from the common list if a site uses either.
- A Worker custom domain may exist only as a route, not as a DNS record. Such a host does not appear in the picker.
- The geo rule has no per-zone override. A zone that serves foreign users needs a way out. Deferred until such a zone exists.

## Non-goals

- Turning off the `workers.dev` address. No `cf` command does it. Each repo's `wrangler.jsonc` sets `workers_dev: false` and `preview_urls: false`, except `brainaloy-vps-cf-tunnel`. The `karigorai` repos are not checked.
- Account-level WAF rules. They need the Enterprise add-on.
- Logging in to Cloudflare from the dev box.
- A config file for per-domain settings.
- Webhook or path exceptions to the geo rule, other than the ACME challenge path.
- A non-interactive mode with flags for cron or CI.
- Per-host Bot Fight Mode. It needs Super Bot Fight Mode (Pro plan and above), or a separate zone for API hosts.
- A `--restore` flag. The restore steps above are manual.
