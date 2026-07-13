#!/usr/bin/env bash
# One-time DigitalOcean droplet prep, BEFORE adding it to Dokploy.
# Idempotent: safe to re-run. Run as root on a fresh Ubuntu LTS droplet.
#
#   scp scripts/setup-remote-vps.sh root@<droplet-ip>:/root/
#   ssh root@<droplet-ip> 'bash /root/setup-remote-vps.sh'
#
# Optional non-interactive Tailscale join:
#   TS_AUTHKEY=tskey-auth-xxxx bash /root/setup-remote-vps.sh
#
# Does NOT install Docker — Dokploy installs Docker/Traefik during provisioning.
# Does NOT close the firewall — that is a separate, later step (vps-firewall-lockdown.sh).
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then echo "Run as root." >&2; exit 1; fi

SWAP_SIZE="${SWAP_SIZE:-4G}"

echo "==> [1/5] Swapfile ($SWAP_SIZE) + swappiness"
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  echo "    swapfile already active — skipping"
fi
echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
sysctl --system >/dev/null

echo "==> [2/5] Docker log rotation (prevents logs filling a small disk)"
# Pre-seed daemon.json so container logs are capped once Dokploy installs Docker.
mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
  # If Docker somehow already exists, apply now; otherwise it applies on install.
  systemctl is-active --quiet docker && systemctl restart docker || true
else
  echo "    /etc/docker/daemon.json exists — leaving it alone (merge log-opts manually if needed)"
fi

echo "==> [3/5] Unattended security upgrades"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades || true

echo "==> [4/5] Install Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "==> [5/5] Join tailnet"
if tailscale status >/dev/null 2>&1; then
  echo "    already connected: $(tailscale ip -4 2>/dev/null || true)"
elif [[ -n "${TS_AUTHKEY:-}" ]]; then
  tailscale up --authkey "$TS_AUTHKEY" --ssh
  echo "    joined. Tailscale IP: $(tailscale ip -4)"
else
  echo "    No TS_AUTHKEY provided. Run interactively:  tailscale up"
  echo "    Then note the IP with:  tailscale ip -4"
fi

echo
echo "✅ Bootstrap done. Next:"
echo "   - Ensure Tailscale is up (tailscale ip -4)."
echo "   - Add this server to Dokploy using its TAILSCALE IP (not public IP)."
echo "   - Add Dokploy's SSH public key to ~/.ssh/authorized_keys."
echo "   - Verify provisioning + a test site, THEN run vps-firewall-lockdown.sh."
