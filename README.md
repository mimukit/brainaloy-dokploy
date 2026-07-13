# Brainaloy Dokploy — Local Control Plane + Remote WordPress on DigitalOcean

Manage cheap, single-purpose DigitalOcean VPS servers running only production
WordPress sites, controlled from a **local Dokploy panel** running on macOS via
OrbStack. **Tailscale** is the private management bridge; public web traffic
stays on the open internet.

> **Building it?** Follow the tick-through checklist in [`docs/RUNBOOK.md`](docs/RUNBOOK.md).
> This README is the reasoning + reference behind those steps.

---

## 1. Architecture & Decisions

Dokploy is a **control plane**: a UI/API + its own Postgres. It connects **out
over SSH** to each remote server and runs deploys via the remote Docker daemon.
Each remote "deploy" server runs only **Docker + an overlay network + Traefik**
(~250 MB RAM) — that's the cheap-VPS story. Traefik on the VPS terminates SSL
and serves traffic **independently of the panel**.

| Area | Decision |
|------|----------|
| Panel host | **OrbStack Ubuntu machine** (`orb create`) on the Mac + **official Dokploy installer** (supported path). Not raw docker-compose against the engine (unsupported/DIY), not a heavyweight VM. |
| Panel availability | Laptop/panel **off is fine**. Running sites, Traefik, SSL renewal, MySQL keep working while the panel is off. **Manual deploys** (no git webhook auto-deploy). |
| Management bridge | **Tailscale** on both the orb machine and the VPS. Dokploy reaches the VPS by its **Tailscale IP**. |
| Public web traffic | **80/443 stay public** on the VPS; DNS A records → VPS public IP. Tailscale does **not** carry visitor traffic. |
| SSH exposure | **Public port 22 dropped.** SSH allowed only over `tailscale0`. **DO web console** is the break-glass fallback. |
| WordPress model | **Path A — official images only** (`wordpress` + `mariadb`). No build step, no registry. |
| Database | **Per-site MariaDB** inside each site's Compose stack. Fully isolated & portable. |
| Persistence | **Named volumes** for `wp-content` and DB (relative bind mounts get wiped on redeploy). |
| Domains/TLS | Dokploy **Compose Domain UI** → container port 80 → **Let's Encrypt**. DNS-only (grey-cloud). |
| Site definitions | **Pasted in the Dokploy UI** for now (lives in panel Postgres → covered by R2 System Backup). |
| Droplet | **2 GB / 1 vCPU**, **latest Ubuntu LTS flat image**, **4 GB swapfile**, `vm.swappiness=10`. ~2–3 small sites/box. |
| MariaDB tuning | **Automated in the compose file** via `command:` args (`--innodb-buffer-pool-size` etc.). No manual `my.cnf`. |
| Site backups | **UpdraftPlus** WordPress plugin (site content + DB) → its own remote. |
| Panel backups | **Dokploy System Backup → Cloudflare R2**, **manual after any panel change** (config is near-static). No schedule, no lifecycle rules, keep many. |

> **Ubuntu version note:** As of this writing the latest LTS is **26.04**. Dokploy's
> provisioning is best-proven on **24.04**. Use 26.04 as requested, but if Dokploy
> server provisioning fails, fall back to **Ubuntu 24.04 LTS** — the proven target.

### What breaks while the panel is off
Keeps working: deployed sites, Traefik, **SSL auto-renewal**, MariaDB.
Stops working: deploy/redeploy/config changes, UI logs/console, git webhooks.

### Two independent backups (don't conflate them)
1. **WordPress site data** — handled by **UpdraftPlus** inside each site, uploaded
   straight from the VPS to its remote. Protects against VPS loss / bad updates.
2. **Dokploy control-plane** — the panel's Postgres + `/etc/dokploy` (server
   configs, env vars, domains, SSH keys, Traefik/certs). Handled by **Dokploy
   System Backup → R2**. Protects your ability to *manage* the sites if the Mac dies.

---

## 2. Prerequisites

- macOS with **OrbStack** installed.
- A **Tailscale** account (tailnet) + the CLI/app.
- A **DigitalOcean** account (droplet + optional cloud firewall).
- A **Cloudflare R2** bucket + S3 API token (for panel backups).
- DNS control for each site's domain.

---

## 3. Stand Up the Local Dokploy Panel (OrbStack)

1. **Create a lightweight Ubuntu machine in OrbStack** (latest LTS):
   ```bash
   orb create ubuntu dokploy
   orb -m dokploy   # open a shell inside the machine (or: ssh dokploy@orb)
   ```

2. **Install Tailscale inside the orb machine** and join the tailnet:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   tailscale ip -4        # note this panel node's 100.x address
   ```

3. **Install Dokploy (official script)** inside the orb machine (needs root,
   Linux, non-container — the orb machine satisfies all three):
   ```bash
   curl -sSL https://dokploy.com/install.sh | sh
   ```

4. **Open the panel** at `http://<orb-machine-ip>:3000` (OrbStack maps it to your
   Mac; the machine IP is shown by `orb list`). Create the admin account.

> Upgrades: use Dokploy's in-UI updater (supported because we used the official
> installer).

---

## 4. Configure Cloudflare R2 for Panel Backups

1. In Cloudflare: create an **R2 bucket** and an **R2 API token** (Access Key ID +
   Secret). Endpoint: `https://<accountid>.r2.cloudflarestorage.com`.
2. In Dokploy → **Settings → S3 Destinations**, add R2:
   - Endpoint: the R2 S3 endpoint above
   - Region: `auto`
   - Access Key / Secret / Bucket
3. Do **not** schedule backups. Run **System Backup manually after any change**
   (new site, domain, env var). Keep as many copies as you like.

### Restore (new Mac / orb machine / or promote to a VPS)
1. Fresh Dokploy install (§3).
2. Point it at the **same R2 destination**.
3. **Restore the System Backup** — this replaces the panel's Postgres +
   `/etc/dokploy` (server configs + SSH keys come back with it).
4. Re-verify each server shows connected; re-point if IPs changed.

---

## 5. Provision the DigitalOcean VPS

**Do these in order — the firewall lockdown (step 6) comes *last* to avoid lockout.**

1. **Create the droplet:** latest **Ubuntu LTS**, **2 GB / 1 vCPU**, plain/flat
   image (do **not** use a Docker marketplace image — let Dokploy install Docker).
   Add your root SSH key.

2. **Add swap + swappiness** on the droplet:
   ```bash
   sudo fallocate -l 4G /swapfile
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
   echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
   sudo sysctl --system
   ```

3. **Install Tailscale on the droplet** and join the same tailnet:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   tailscale ip -4        # note the VPS 100.x address
   ```

4. **Add the server in Dokploy** → **Servers → Create Server**:
   - IP/Host: the **VPS Tailscale IP** (100.x) — *not* the public IP
   - Port: `22`
   - Copy the **Dokploy-generated SSH public key** and add it to the droplet's
     `~/.ssh/authorized_keys` (root or a sudo user).
   - Run **provisioning** — Dokploy installs Docker, the overlay network, and
     Traefik over SSH. Wait for a green/connected status.

   > If provisioning fails on Ubuntu 26.04, rebuild the droplet on **24.04 LTS**.

5. **Deploy one test site** (§7) and confirm it loads over **HTTPS on the public
   internet** (DNS → public IP, ports 80/443 open by default).

6. **Lock down the firewall — only after steps 4–5 pass.** Use a DigitalOcean
   Cloud Firewall (and/or `ufw` on the box):
   - **Inbound allow:** TCP **80**, TCP **443** from anywhere.
   - **SSH:** allow **only via Tailscale** — drop public **22**.
   - With `ufw` on the droplet:
     ```bash
     sudo ufw default deny incoming
     sudo ufw default allow outgoing
     sudo ufw allow 80/tcp
     sudo ufw allow 443/tcp
     sudo ufw allow in on tailscale0        # SSH + mgmt only over the tailnet
     sudo ufw enable
     ```
     (If using a DO Cloud Firewall, mirror this: 80/443 public, no public 22.)

7. **Verify break-glass:** confirm SSH still works over Tailscale, and that the
   **DO web console** opens (your emergency door if Tailscale is ever down).

---

## 6. DNS per Site

For each site, create an **A record** → **VPS public IP**. Keep it **DNS-only
(grey cloud)** so Traefik can issue/renew Let's Encrypt certs directly. Then add
the domain in Dokploy's Compose **Domain** tab (§7).

---

## 7. Deploy a WordPress Site

1. In Dokploy: **Create → Compose service** (Compose type: **Docker Compose**).
2. Target **server = your DO VPS**. Enable **Isolated Deployments** (each project
   gets its own network; no need to hand-attach `dokploy-network`).
3. Paste the canonical compose (see [`templates/wordpress.compose.yml`](templates/wordpress.compose.yml))
   into the raw editor. **No env vars to set** — the DB credentials are the
   `SERVICE_*` variables Dokploy auto-generates on deploy.
4. **Deploy.** The site comes up on its Dokploy-assigned URL — no domain yet.
5. (Optional) Restore a backup with UpdraftPlus while the site is still on its
   temporary URL.
6. When ready to go live, open the **Domain** tab: add the site domain → service
   **`wordpress`**, container **port 80**, **HTTPS + Let's Encrypt**. WordPress
   picks up the domain from the request — nothing to edit in the compose.
7. Install **UpdraftPlus** and point it at your chosen remote for ongoing backups.

### Per-site `docker-compose.yml`

The stack is **identical for every site** — no per-site edits. It's kept in
[`templates/wordpress.compose.yml`](templates/wordpress.compose.yml): official
`wordpress` + `mariadb` images, tuned DB, the reverse-proxy HTTPS fix, and named
volumes. No domain is baked in, so create → restore → wire the domain all work
without touching the file.

> **Adding more sites:** paste the same compose into a new Compose service and
> deploy — Dokploy generates fresh `SERVICE_*` credentials per service. Budget
> ~300–400 MB RAM per site; at ~2–3 sites on 2 GB, add a second droplet as another
> Dokploy server rather than overloading one box.

> **Restore note (volumes):** if you ever restore a volume, Dokploy names Compose
> volumes `{appName}_{volumeName}` — match that so the restored volume is picked up.

---

## 8. Operational Runbook

- **Deploy/change a site:** panel must be running (start the orb machine) →
  edit/deploy → **run a manual System Backup to R2** afterward.
- **Panel-off is normal:** sites keep serving; you just can't manage them.
- **Site data safety:** UpdraftPlus per site (+ optional DO droplet snapshots as a
  whole-box safety net).
- **Panel data safety:** manual R2 System Backup after each change.
- **Break-glass:** SSH over Tailscale; if Tailscale is down, use the DO web console.
- **Scaling:** more sites → new 2 GB droplet → add as another Dokploy server (repeat §5).

---

## 9. Automation Scripts

The deterministic parts are scripted in `scripts/`; interactive UI/auth steps stay manual.

| Script | Runs on | What it does |
|--------|---------|--------------|
| `scripts/orb-create-vm.sh` | macOS host | **Optional.** Creates the OrbStack Ubuntu 24.04 machine (equivalent to `orb create ubuntu:24.04 dokploy`). VM only — no apps. |
| `scripts/setup-control-panel-vm.sh` | Any Ubuntu LTS host | Installs CLI tools (curl, tmux, btop, vim, lazydocker), Tailscale, and Dokploy. Machine-agnostic; run inside the VM. (Tailscale auth + admin account are interactive.) |
| `scripts/setup-remote-vps.sh` | DO droplet (root) | Swap + swappiness, Docker log rotation, unattended security upgrades, Tailscale. **Does not** install Docker or touch the firewall. |
| `scripts/vps-firewall-lockdown.sh` | DO droplet (root) | Closes public 22, allows 80/443 + `tailscale0` only. Guarded against lockout; run **last**. |
| `templates/wordpress.compose.yml` | — | Canonical WordPress stack to paste into the Dokploy Compose editor. Identical for every site; no env vars needed (Dokploy generates the `SERVICE_*` DB credentials). |

Typical order: `orb-create-vm.sh` (or create the VM by hand) → `setup-control-panel-vm.sh`
inside it → create droplet → `setup-remote-vps.sh` → add server in Dokploy UI →
create the site in the Dokploy dashboard (paste the compose) + deploy + verify →
`vps-firewall-lockdown.sh`.

---

## 10. Recommended Extras (worth doing)

- **DO Reserved IP** for the droplet — so a rebuild/resize keeps the same public IP and your DNS + Let's Encrypt don't churn.
- **Tailscale hardening** — tag the servers (e.g. `tag:prod`), **disable key expiry** on the VPS + panel nodes (so they don't drop off the tailnet), and tighten tailnet ACLs to only what the panel needs.
- **Docker log rotation** — handled by `setup-remote-vps.sh`; re-apply if Dokploy ever rewrites `/etc/docker/daemon.json`.
- **DO droplet snapshots** — cheap whole-box safety net *in addition to* UpdraftPlus (weekly is plenty).
- **Uptime + cert monitoring** — a free external monitor (UptimeRobot/Healthchecks) per site catches outages and cert-renewal failures the offline panel won't tell you about.
- **WordPress hardening per site** — `define('DISALLOW_FILE_EDIT', true);`, limit-login plugin, strong admin creds, keep core/plugins updated.
- **Test a restore before you rely on it** — do one dry-run: restore the R2 System Backup into a throwaway orb machine and confirm your servers/sites reappear.
- **SMTP for WordPress** — sites can't send mail out of the box; add an SMTP plugin per site (e.g. transactional provider) when needed.

## 11. Open Items / Not Covered Yet

- **Git-backed site definitions** (version control + webhook auto-deploy) — deferred;
  currently paste-in-UI. Revisit if you want history/CI or an always-on panel host.
- **Remote server monitoring** — not supported by Dokploy for remote servers; use
  DO metrics or an external monitor instead.
