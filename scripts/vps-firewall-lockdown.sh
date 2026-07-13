#!/usr/bin/env bash
# Close public SSH (port 22); allow only 80/443 publicly and all mgmt over Tailscale.
# RUN THIS LAST — only after Dokploy shows the server connected AND a test site
# serves over HTTPS. Has a guard that refuses to run if Tailscale is down
# (which would lock you out). DO web console remains the break-glass fallback.
#
#   ssh root@<droplet-ip> 'bash /root/vps-firewall-lockdown.sh'   # while 22 still open
#   ...or run it over the Tailscale IP.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then echo "Run as root." >&2; exit 1; fi

echo "==> Safety checks (avoiding SSH lockout)"
if ! command -v tailscale >/dev/null 2>&1 || ! tailscale status >/dev/null 2>&1; then
  echo "❌ Tailscale is not up. Aborting — closing 22 now would lock you out." >&2
  exit 1
fi
if ! ip link show tailscale0 >/dev/null 2>&1; then
  echo "❌ tailscale0 interface missing. Aborting." >&2
  exit 1
fi
echo "    Tailscale OK: $(tailscale ip -4)"

read -r -p "Close PUBLIC port 22 and allow SSH only over Tailscale? [y/N] " ans
[[ "${ans,,}" == "y" ]] || { echo "Aborted."; exit 0; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp                 # public web
ufw allow 443/tcp                # public web
ufw allow in on tailscale0       # SSH + all mgmt only over the tailnet
ufw --force enable
ufw status verbose

echo
echo "✅ Firewall locked down. Verify NOW from another terminal:"
echo "   - SSH over Tailscale still works."
echo "   - Public 'ssh root@<public-ip>' now times out."
echo "   - DO web console still opens (break-glass)."
