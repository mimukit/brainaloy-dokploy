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
- [ ] Create the VM: `scripts/orb-create-vm.sh` (or manually: `orb create ubuntu:24.04 dokploy`)
- [ ] Provision it: `orb -m dokploy sudo bash -s < scripts/setup-control-panel-vm.sh`
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

> **If "S3 Destination" test fails with `dial tcp: lookup ...r2.cloudflarestorage.com
> on 127.0.0.11:53: server misbehaving`** — that's a DNS failure, not bad
> credentials. This test runs on the **panel host** (the OrbStack VM), whose
> Docker embedded resolver forwards to Tailscale MagicDNS, which containers
> can't reach. Fix: give the Docker daemon a real resolver (pre-seeded by
> `setup-control-panel-vm.sh`). See [Troubleshooting → Docker DNS](#troubleshooting) below.

---

## Phase 3 — Provision the DO droplet
- [ ] 🖐 Create droplet: **latest Ubuntu LTS**, **2 GB / 1 vCPU**, plain image, your root SSH key
- [ ] 🖐 (Recommended) Assign a **Reserved IP** to the droplet
- [ ] Record droplet **public IP**: `__________`
- [ ] Copy bootstrap up: `scp scripts/setup-remote-vps.sh root@<public-ip>:/root/`
- [ ] Run it: `ssh root@<public-ip> 'bash /root/setup-remote-vps.sh'`
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
- [ ] 🖐 Create Compose service (type: Docker Compose), server = the DO VPS, **Isolated Deployments ON**
- [ ] 🖐 Paste `templates/wordpress.compose.yml` (no env vars to set — Dokploy generates the `SERVICE_*` DB credentials)
- [ ] 🖐 Deploy; site comes up on its Dokploy-assigned URL (no domain yet)
- [ ] 🖐 (Optional) Restore a backup with **UpdraftPlus** while still on the temporary URL
- [ ] 🖐 Go live: Domain tab → host=`<domain>`, service=`wordpress`, port `80`, HTTPS + Let's Encrypt
- [ ] 🖐 DNS: **A record** `<domain>` → droplet **public IP** (DNS-only / grey cloud)
- [ ] ⛔ Site loads over **HTTPS** on the public internet; valid Let's Encrypt cert; no redirect loop
- [ ] 🖐 Finish WP install (fresh sites); install **UpdraftPlus** and point it at its remote
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
- [ ] 🖐 New Compose service on the VPS → paste `templates/wordpress.compose.yml` → deploy → (restore) → Domain tab → DNS A record
- [ ] 🖐 Manual System Backup → R2
- [ ] If RAM tight (~3 sites on 2 GB): spin a new droplet (Phase 3–5) and add as another Dokploy server

## After ANY panel change (habit)
- [ ] 🖐 Run a manual Dokploy **System Backup → R2**

## Recovery drill (do once)
- [ ] Fresh orb machine → install Dokploy → point at same R2 → **restore System Backup**
- [ ] ⛔ Servers + sites reappear in the UI

---

## Troubleshooting

### Docker DNS — container lookups fail (`server misbehaving`)

Symptom (e.g. testing an S3 Destination, an image pull, or any outbound call from a container):

```
dial tcp: lookup <host> on 127.0.0.11:53: server misbehaving
```

Root cause: Tailscale MagicDNS takes over `/etc/resolv.conf` (`nameserver
100.100.100.100`, or the IPv6 `fd7a:115c:a1e0::53`). When that MagicDNS
misbehaves, DNS fails. It's **DNS, not credentials.** Two layers are affected:

| Layer | Uses | Symptom |
|-------|------|---------|
| **Host** (`docker pull`, `apt`, host `curl`) | host `/etc/resolv.conf` | `lookup registry-1.docker.io ... server misbehaving` |
| **Container** (rclone/R2 test, app egress) | Docker embedded `127.0.0.11` → forwards to host resolvers | `lookup ...r2.cloudflarestorage.com on 127.0.0.11:53: server misbehaving` |

This affects **both hosts** (panel VM + remote VPS), since both run Tailscale + Docker.

**Fix — stop Tailscale hijacking host DNS** (fixes both layers):

```bash
sudo tailscale set --accept-dns=false     # flip the pref off
sudo systemctl restart docker
cat /etc/resolv.conf                       # check: is the 100.100.100.100 / fd7a:...::53 line gone?
docker run --rm alpine nslookup registry-1.docker.io
```

⚠️ **On OrbStack, `--accept-dns=false` often does NOT restore `/etc/resolv.conf`** —
Tailscale leaves the dead MagicDNS entry behind, so the pull still fails. When that
happens, pin public resolvers directly (this is what actually unblocks it):

```bash
sudo sh -c 'printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf'
sudo systemctl restart docker
docker run --rm alpine nslookup registry-1.docker.io   # resolves now
# Optional — stop anything rewriting it on reboot (regular file only, not a symlink):
sudo chattr +i /etc/resolv.conf            # undo later with: sudo chattr -i /etc/resolv.conf
```

Safe here because nodes are reached by **Tailscale IP**, not MagicDNS name.
(Tailnet-wide alternative: admin console → **DNS** → add global nameserver `1.1.1.1`.)

Fresh installs are already covered — `setup-control-panel-vm.sh` and
`setup-remote-vps.sh` pass `--accept-dns=false` on join, **and** seed
`"dns": ["1.1.1.1","8.8.8.8"]` into `/etc/docker/daemon.json` as container-DNS
defense-in-depth. Re-running either script (idempotent) applies the fix to an
existing host:

```bash
# Existing OrbStack panel:
orb -m dokploy sudo bash -s < scripts/setup-control-panel-vm.sh
```
