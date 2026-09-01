# Brainaloy Dokploy — Documentation

Cheap single-purpose DigitalOcean VPS servers run production WordPress sites. A local Dokploy panel on macOS (OrbStack) manages them over Tailscale. The full architecture, decisions, and reference live in the repo [README](https://github.com/mimukit/brainaloy-dokploy/blob/main/README.md).

## Pages

- [RUNBOOK](RUNBOOK.md) — the ordered tick-through checklist that stands up the whole setup, from OrbStack VM to firewall lockdown. Start here to build.
- [WORDPRESS-STACK-TUNING](WORDPRESS-STACK-TUNING.md) — every tunable in the canonical WordPress compose stack, its default, the sizing formulas, and the troubleshooting table.
- [CLOUDFLARE-CACHING](CLOUDFLARE-CACHING.md) — per-zone Cloudflare full-page caching for the brochure sites, with the bypass rules and the purge procedure.
- [BESZEL-MONITORING](BESZEL-MONITORING.md) — the Beszel hub behind a Tailscale sidecar, the host-binary agent install for each VM, and the optional custom domain for the hub UI.
- [RESTORE](RESTORE.md) — recovery procedures for a dead panel, broken site content, a lost droplet, and break-glass access.

## Key files in the repo

- [templates/wordpress.compose.yml](https://github.com/mimukit/brainaloy-dokploy/blob/main/templates/wordpress.compose.yml) — the canonical stack pasted into the Dokploy Compose editor, identical for every site.
- [templates/wordpress.env.example](https://github.com/mimukit/brainaloy-dokploy/blob/main/templates/wordpress.env.example) — every tunable with its default; an empty Environment tab deploys the defaults.
- [scripts/](https://github.com/mimukit/brainaloy-dokploy/tree/main/scripts) — provisioning scripts for the panel VM and the VPS, plus the firewall lockdown and the post-lockdown audit.

_Verified against `main`@`7625573` on 2026-08-27._
