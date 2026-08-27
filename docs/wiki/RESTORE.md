# Restore & Recovery

What to do when something is lost: the Mac or panel VM, a site's content, or a whole droplet. The two backup systems are independent, so pick the section that matches what died. Background on the split lives in the [README](../../README.md) ("Two independent backups").

Legend: 🖐 manual UI/auth step · ⛔ verification gate

---

## The panel died (Mac lost, orb machine deleted, panel broken)

Your sites keep serving. Traefik, SSL renewal, and MariaDB on the VPS do not depend on the panel. You only lost the ability to manage them, so this restore has no visitor-facing urgency.

1. Create a fresh panel host: `scripts/orb-create-vm.sh`, then `orb -m dokploy sudo bash -s < scripts/setup-control-panel-vm.sh` (RUNBOOK Phase 1).
2. 🖐 Complete the interactive `tailscale up` auth and create a throwaway admin account in the fresh panel.
3. 🖐 Dokploy → Settings → **S3 Destinations** → add the same R2 destination (endpoint, region `auto`, key, secret, bucket).
4. 🖐 **Restore the System Backup.** This replaces the panel's Postgres and `/etc/dokploy`, so server configs, SSH keys, domains, and env vars all come back.
5. ⛔ Each server shows **connected**. If a VPS Tailscale IP changed, re-point the server entry.
6. ⛔ Deploy nothing yet; open one site's service page and confirm its config looks right.

Do this once as a drill before you need it (RUNBOOK "Recovery drill").

---

## A site's content is broken (bad update, hacked, wrong edit)

1. 🖐 WordPress admin → **UpdraftPlus → Existing backups → Restore**. Choose the components (database, plugins, themes, uploads) the damage covers.
2. ⛔ Site renders correctly on its domain, logged out and logged in.
3. 🖐 If Cloudflare caching is active for the zone, **Purge Everything** so visitors stop seeing the broken cached copy (see [CLOUDFLARE-CACHING](CLOUDFLARE-CACHING.md)).

If the site is unreachable and you are rebuilding it from scratch, deploy a fresh stack first (RUNBOOK Phase 4), restore with UpdraftPlus while the site is still on its temporary Dokploy URL, then wire the domain.

---

## The whole droplet died

1. Build a replacement: RUNBOOK Phases 3 to 5 (droplet, `setup-remote-vps.sh`, add to Dokploy, deploy stacks, lockdown last).
2. If you kept a DO **Reserved IP**, reassign it so DNS and Let's Encrypt do not churn. Otherwise update each site's A record to the new public IP.
3. Redeploy each site's Compose service to the new server, then restore content per site with UpdraftPlus.
4. If you restore from a DO droplet snapshot instead, the containers and volumes come back as-is; verify Tailscale and the firewall still hold (RUNBOOK Phase 5 gates).
5. 🖐 Run a manual Dokploy **System Backup → R2** afterward, because the server entry changed.

---

## Restoring a Docker volume directly

Dokploy names Compose volumes `{appName}_{volumeName}`, for example `mysite-abc123_wp_content` and `mysite-abc123_db_data` for the volumes declared in `templates/wordpress.compose.yml`. A volume you restore by hand must keep that exact name, or the redeployed stack starts empty next to it. Check the real name with `docker volume ls` on the VPS before you copy data in.

---

## Break-glass access

- Normal path: SSH over the VPS **Tailscale IP**. Public port 22 is closed after lockdown.
- Tailscale down: the **DigitalOcean web console** is the only door. Verify it opens during setup (RUNBOOK Phase 5), not during the incident.
- Password SSH is disabled by `setup-remote-vps.sh`, so console login needs the root password reset flow in the DO panel if you never set one.

_Verified against `main`@`7625573` on 2026-08-27._
