# Runbook — Build Checklist

Ordered, tick-through checklist for standing up the whole setup. Prose/reasoning
lives in `../README.md`; this is just the do-it list. **Do phases in order** — the
firewall lockdown (Phase 5) is intentionally last to avoid SSH lockout.

Legend: `[ ]` todo · 🖐 manual UI/auth step · ⛔ verification gate (don't proceed until it passes)

---

## Phase 0 — Accounts & prerequisites
- [ ] OrbStack installed on the Mac (`orb version`)
- [ ] Tailscale account / tailnet ready
- [ ] DigitalOcean account ready
- [ ] Cloudflare account with an **R2 bucket** + **S3 API token** (Access Key + Secret + endpoint)
- [ ] DNS access for each site domain

---

## Phase 1 — Local Dokploy panel (OrbStack)
- [ ] Run `scripts/orb-panel-setup.sh`
- [ ] 🖐 Complete `tailscale up` auth in the browser when prompted
- [ ] Note the **panel Tailscale IP** (`orb -m dokploy sudo tailscale ip -4`): `__________`
- [ ] Note the **orb machine IP** (`orb list`): `__________`
- [ ] 🖐 Open `http://<orb-machine-ip>:3000` and create the **admin account**
- [ ] ⛔ Panel loads and you're logged in

---

## Phase 2 — R2 backup destination
- [ ] 🖐 Dokploy → Settings → **S3 Destinations** → add R2 (endpoint, region `auto`, key, secret, bucket)
- [ ] 🖐 Run one **manual System Backup** now as a smoke test
- [ ] ⛔ Backup object appears in the R2 bucket

---

## Phase 3 — Provision the DO droplet
- [ ] 🖐 Create droplet: **latest Ubuntu LTS**, **2 GB / 1 vCPU**, plain image, your root SSH key
- [ ] 🖐 (Recommended) Assign a **Reserved IP** to the droplet
- [ ] Record droplet **public IP**: `__________`
- [ ] Copy bootstrap up: `scp scripts/vps-bootstrap.sh root@<public-ip>:/root/`
- [ ] Run it: `ssh root@<public-ip> 'bash /root/vps-bootstrap.sh'`
- [ ] 🖐 If not using `TS_AUTHKEY`: `ssh root@<public-ip> tailscale up` and auth
- [ ] Record droplet **Tailscale IP**: `__________`
- [ ] 🖐 Tailscale admin console → **disable key expiry** for panel + VPS nodes; tag them (e.g. `tag:prod`)
- [ ] ⛔ `ping`/`ssh` the droplet over its **Tailscale IP** works from the orb machine

---

## Phase 4 — Add server to Dokploy + first site (public 22 still open)
- [ ] 🖐 Dokploy → **Servers → Create Server** → host = **VPS Tailscale IP**, port 22
- [ ] 🖐 Add Dokploy's generated **SSH public key** to droplet `~/.ssh/authorized_keys`
- [ ] 🖐 Run **provisioning**; wait for green/connected
  - [ ] If it fails on Ubuntu 26.04 → rebuild droplet on **24.04 LTS**, redo Phase 3
- [ ] ⛔ Server shows **connected** in Dokploy
- [ ] Generate a site: `scripts/new-wordpress-site.sh <domain>`
- [ ] 🖐 Create Compose service (type: Docker Compose), server = the DO VPS, **Isolated Deployments ON**
- [ ] 🖐 Paste `sites/<domain>/docker-compose.yml`; paste `sites/<domain>/dokploy.env` into Environment
- [ ] 🖐 Domain tab → host=`<domain>`, service=`wordpress`, port `80`, HTTPS + Let's Encrypt
- [ ] 🖐 DNS: **A record** `<domain>` → droplet **public IP** (DNS-only / grey cloud)
- [ ] 🖐 Deploy
- [ ] ⛔ Site loads over **HTTPS** on the public internet; valid Let's Encrypt cert; no redirect loop
- [ ] 🖐 Finish WP install; install **UpdraftPlus** and point it at its remote
- [ ] 🖐 Manual Dokploy **System Backup → R2**

---

## Phase 5 — Lock down the firewall (LAST)
- [ ] Copy up: `scp scripts/vps-firewall-lockdown.sh root@<public-ip>:/root/`
- [ ] Run it: `ssh root@<public-ip> 'bash /root/vps-firewall-lockdown.sh'` → confirm the prompt
- [ ] ⛔ From a **second terminal**: SSH over **Tailscale IP** still works
- [ ] ⛔ Public `ssh root@<public-ip>` now **times out**
- [ ] ⛔ Site still serves over HTTPS (80/443 unaffected)
- [ ] 🖐 Confirm **DO web console** opens (break-glass path)

---

## Add another site later
- [ ] `scripts/new-wordpress-site.sh <domain2>`
- [ ] 🖐 New Compose service on the VPS → paste compose + env → Domain tab → DNS A record → deploy
- [ ] 🖐 Manual System Backup → R2
- [ ] If RAM tight (~3 sites on 2 GB): spin a new droplet (Phase 3–5) and add as another Dokploy server

## After ANY panel change (habit)
- [ ] 🖐 Run a manual Dokploy **System Backup → R2**

## Recovery drill (do once)
- [ ] Fresh orb machine → install Dokploy → point at same R2 → **restore System Backup**
- [ ] ⛔ Servers + sites reappear in the UI
