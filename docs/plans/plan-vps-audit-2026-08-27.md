# Plan: scripts/vps-audit.sh — verify the promised VPS end state
Grilled: 2026-08-27

## Context
`setup-remote-vps.sh` and `vps-firewall-lockdown.sh` change state, but nothing verifies that state afterwards or re-verifies it months later. The runbook ends Phase 5 with manual "verify NOW" checks a human runs by hand, and configuration can drift (a later sshd drop-in, a ufw rule added ad hoc, Tailscale down, daemon.json replaced). The idea comes from reviewing [nuver-labs/vps-audit](https://github.com/nuver-labs/vps-audit): keep its `sshd -T` effective-config technique, its reboot-required and unattended-upgrades checks, and its PASS/WARN/FAIL report shape; drop its generic heuristics (fail2ban, port counts, SUID scan, password policy) that are wrong for this key-only, Tailscale-gated, Docker-heavy architecture. Success: one read-only script that a human runs after lockdown (and any time later) and that prints all PASS when the box matches what the setup scripts promise.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Vendor vs write our own | Write our own (~100-line) script. The upstream script is generic; half its checks are noise here. Borrow techniques, not code. |
| Scope of checks | Assert only the invariants our own scripts create, plus reboot-required. No monitoring-style checks (CPU, load, public IP). |
| Read-only | The script changes nothing. It never installs packages, never restarts services. |
| Report shape | Color PASS/WARN/FAIL lines to stdout, summary count at the end. No report file — the runbook step is interactive, and scp'ing reports off a locked-down box adds friction for no reader. |
| Exit code | Nonzero when any FAIL. Lets `ssh root@<ip> 'bash /root/vps-audit.sh'` work in scripts and cron later. |
| Error model | No `set -e` for the check body (a failing probe is a finding, not a crash). `set -u -o pipefail` plus a `check` helper that records the result and continues. |
| When it runs | After Phase 5 lockdown. Pre-lockdown runs are allowed; the ufw checks then FAIL by design and the script header prints a note saying so. No `--pre-lockdown` flag. |
| ufw matching | Strict. Allows are exactly 80/tcp, 443/tcp, `in on tailscale0`; any other rule FAILs. A future extra port forces a script edit, which documents it. No ignore list. |
| Thresholds | Disk 80% WARN / 90% FAIL; available memory <15% WARN; swap use ≥75% WARN. Tune later with real data. |
| Pending-upgrades count | Out. Check 4 verifies the mechanism; check 11 (reboot-required) catches the case that matters. |
| Exit code on WARN | 0. The contract is binary: only FAIL exits nonzero. WARN lines stay on screen. |
| Style | Match the two existing scripts: `#!/usr/bin/env bash`, root guard, `==>` section echoes, plain bash, no dependencies beyond what the setup scripts already assume. |

## Approach

Reuses: the root-guard and echo conventions from `scripts/setup-remote-vps.sh`, the exact ufw policy from `scripts/vps-firewall-lockdown.sh` (deny incoming, allow 80/tcp, 443/tcp, in on tailscale0), the exact sshd drop-in body from `setup-remote-vps.sh` step 6, and the daemon.json/DNS invariants from steps 2 and 5. From upstream vps-audit: `sshd -T` for effective config, `/var/run/reboot-required`, the unattended-upgrades presence check, and the PASS/WARN/FAIL vocabulary.

### Phase 1: the script (built 2026-08-27)

One task: write `scripts/vps-audit.sh` with a `check <name> <status> <detail>` helper and these checks, grouped to mirror the setup scripts.

Setup invariants (from `setup-remote-vps.sh`):
1. **Swap** — `swapon --show` lists `/swapfile`; `/etc/fstab` has the entry. FAIL otherwise.
2. **Swappiness** — `sysctl -n vm.swappiness` is 10. WARN otherwise.
3. **Docker daemon.json** — file exists, contains `"max-size"` and a `"dns"` array (grep, no jq dependency). WARN if Docker not yet installed; FAIL if installed and config missing.
4. **Unattended upgrades** — package installed AND `apt-daily-upgrade.timer` active. FAIL if missing, WARN if installed but timer inactive.
5. **Tailscale** — `tailscale status` succeeds and `tailscale ip -4` returns an address. FAIL otherwise.
6. **Host DNS** — `getent hosts registry-1.docker.io` resolves. FAIL otherwise (this is the MagicDNS regression the setup script guards against).
7. **SSH effective config** — `sshd -T` reports `passwordauthentication no`, `permitrootlogin` not `yes` with password, `pubkeyauthentication yes`, `usepam no`. Effective config, not our drop-in file, so a later override is caught. FAIL per divergent key.

Lockdown invariants (from `vps-firewall-lockdown.sh`):
8. **ufw active** — `ufw status` says active, default deny incoming. FAIL otherwise.
9. **ufw rules exact** — allows are exactly 80/tcp, 443/tcp, and `in on tailscale0`; any extra allow (especially 22) is FAIL.
10. **Public 22 closed** — no ufw allow rule for 22. (No self-connect probe; from the box itself a port test is meaningless.)

General health (from upstream):
11. **Reboot required** — `/var/run/reboot-required` absent → PASS, present → WARN.
12. **Disk** — root filesystem <80% PASS, 80–89% WARN, ≥90% FAIL.
13. **Memory + swap pressure** — available memory ≥15% PASS, else WARN; swap use ≥75% WARN.

End: summary line (`N pass, N warn, N fail`), exit 1 if any FAIL.

### Phase 2: runbook wiring (built 2026-08-27)

1. Add to `docs/wiki/RUNBOOK.md` Phase 5: copy up and run `vps-audit.sh`, expect all PASS, as the ⛔ verification step after lockdown.
2. Mention the script in `README.md` where the two setup scripts are described, and in `docs/wiki/index.md` if scripts are listed there.

## Open questions
None. All four draft questions were settled in the grill on 2026-08-27; see the decisions table.

## Non-goals
- No fixing. The script reports; the setup scripts remediate.
- No fail2ban, SUID scan, password policy, port-count or service-count heuristics from upstream.
- No monitoring (CPU, load, uptime alerts) and no report files or scheduling; cron/alerting is a later, separate decision.
- No checks on the OrbStack control-plane VM; this script targets the DO droplet only.
