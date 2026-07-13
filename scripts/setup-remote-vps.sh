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

echo "==> [1/6] Swapfile ($SWAP_SIZE) + swappiness"
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

echo "==> [2/6] Docker daemon config (log rotation + DNS)"
# Pre-seed daemon.json so container logs are capped once Dokploy installs Docker,
# and so the embedded DNS resolver (127.0.0.11) forwards to a real public resolver.
# Without "dns", Tailscale MagicDNS rewrites the host /etc/resolv.conf to
# nameserver 100.100.100.100, which containers often can't reach — outbound
# lookups then fail with "server misbehaving" (e.g. rclone can't resolve R2).
mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "dns": ["1.1.1.1", "8.8.8.8"]
}
JSON
  # If Docker somehow already exists, apply now; otherwise it applies on install.
  systemctl is-active --quiet docker && systemctl restart docker || true
else
  echo "    /etc/docker/daemon.json exists — leaving it alone (merge log-opts + dns manually if needed)"
fi

echo "==> [3/6] Unattended security upgrades"
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
else
  echo "    unattended-upgrades already installed — skipping"
fi

echo "==> [4/6] Install Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "==> [5/6] Join tailnet"
# --accept-dns=false: don't let Tailscale MagicDNS take over /etc/resolv.conf.
# A misbehaving MagicDNS breaks HOST-level DNS (docker image pulls, apt, etc.);
# the host resolver — not daemon.json "dns" — is what `docker pull` uses. We
# address nodes by Tailscale IP, not MagicDNS name, so disabling it is safe.
if tailscale status >/dev/null 2>&1; then
  echo "    already connected: $(tailscale ip -4 2>/dev/null || true)"
  tailscale set --accept-dns=false 2>/dev/null || true
elif [[ -n "${TS_AUTHKEY:-}" ]]; then
  tailscale up --authkey "$TS_AUTHKEY" --ssh --accept-dns=false
  echo "    joined. Tailscale IP: $(tailscale ip -4)"
else
  echo "    No TS_AUTHKEY provided. Run interactively:  tailscale up --accept-dns=false"
  echo "    Then note the IP with:  tailscale ip -4"
fi

# Belt-and-suspenders: --accept-dns=false flips the pref but does NOT always
# restore a working /etc/resolv.conf (Tailscale can leave the dead MagicDNS
# entry behind). If a host-level lookup still fails, pin public resolvers so
# `docker pull` / apt work. Idempotent: only rewrites when DNS is actually broken.
if tailscale status >/dev/null 2>&1 && ! getent hosts registry-1.docker.io >/dev/null 2>&1; then
  echo "    Host DNS still broken after Tailscale — pinning public resolvers in /etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
  systemctl is-active --quiet docker && systemctl restart docker || true
fi

echo "==> [6/6] Enforce key-only SSH (disable password + PAM auth)"
# GUARD: refuse to disable password auth unless a usable public key already
# exists — otherwise a keyless box would lock everyone out. Safe to re-run:
# add Dokploy's key to ~/.ssh/authorized_keys, then run this script again.
AUTH_KEYS="${HOME}/.ssh/authorized_keys"
HARDEN_CONF="/etc/ssh/sshd_config.d/99-hardening.conf"
read -r -d '' HARDEN_BODY <<'CONF' || true
# Managed by setup-remote-vps.sh — key-only SSH.
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PubkeyAuthentication yes
CONF
if [[ -f "$HARDEN_CONF" ]] && [[ "$(cat "$HARDEN_CONF")" == "$HARDEN_BODY" ]]; then
  echo "    key-only SSH already enforced — skipping"
elif [[ -s "$AUTH_KEYS" ]] && grep -qE '^(ssh-(rsa|ed25519|dss)|ecdsa-)' "$AUTH_KEYS"; then
  mkdir -p /etc/ssh/sshd_config.d
  printf '%s\n' "$HARDEN_BODY" > "$HARDEN_CONF"
  # Validate before reloading so a bad config never breaks the SSH service.
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    echo "    Password + PAM auth disabled; key-only SSH is now enforced."
  else
    rm -f "$HARDEN_CONF"
    echo "    ⚠️  sshd config test failed — reverted, leaving SSH unchanged." >&2
  fi
else
  echo "    ⚠️  No public key found in $AUTH_KEYS — SKIPPING (would lock you out)."
  echo "        Add Dokploy's SSH public key there, then re-run this script."
fi

echo
echo "✅ Bootstrap done. Next:"
echo "   - Ensure Tailscale is up (tailscale ip -4)."
echo "   - Add this server to Dokploy using its TAILSCALE IP (not public IP)."
echo "   - Add Dokploy's SSH public key to ~/.ssh/authorized_keys."
echo "   - Verify provisioning + a test site, THEN run vps-firewall-lockdown.sh."
