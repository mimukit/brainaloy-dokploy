#!/usr/bin/env bash
# Provision the Dokploy control-plane apps INSIDE an Ubuntu machine.
# Machine-agnostic: works on any Ubuntu LTS host (OrbStack VM, bare metal, a
# droplet, WSL, ...). Installs CLI tools, Tailscale, and Dokploy.
#
# Idempotent: safe to re-run; already-done steps print a skip message.
# Runs privileged steps via sudo when not already root.
#
# Run directly on the machine:
#   bash setup-control-panel-vm.sh
#
# Or pipe it in from a host (e.g. an OrbStack VM named 'dokploy'):
#   orb -m dokploy sudo bash -s < scripts/setup-control-panel-vm.sh
#
# Optional non-interactive Tailscale join:
#   TS_AUTHKEY=tskey-auth-xxxx bash setup-control-panel-vm.sh
set -euo pipefail

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "Run as root or install sudo." >&2
    exit 1
  fi
fi

echo "==> [1/4] Base CLI tools"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq curl tmux btop vim bat >/dev/null
echo "    apt tools ready (curl, tmux, btop, vim)"
if command -v lazydocker >/dev/null 2>&1; then
  echo "    lazydocker already installed — skipping"
else
  curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh \
    | $SUDO env DIR=/usr/local/bin bash
  echo "    lazydocker installed"
fi

echo "==> [2/4] Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  echo "    tailscale already installed — skipping"
else
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
  echo "    tailscale installed"
fi

echo "==> [3/4] Dokploy (official installer)"
if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -q dokploy; then
  echo "    Dokploy already running — skipping install"
else
  curl -sSL https://dokploy.com/install.sh | $SUDO sh
  echo "    Dokploy installed"
fi

echo "==> [4/4] Docker socket access (add login user to 'docker' group)"
# Without this, non-root `docker ...` fails with:
#   permission denied ... /var/run/docker.sock: connect: permission denied
# The 'docker' group is created by the Docker install above; adding the login
# user to it lets them talk to the daemon without sudo.
DOCKER_USER="${SUDO_USER:-$(id -un)}"
if [[ "$DOCKER_USER" == "root" ]]; then
  echo "    Running as root with no login user — nothing to add, skipping"
elif ! getent group docker >/dev/null 2>&1; then
  echo "    'docker' group not present yet — skipping"
elif id -nG "$DOCKER_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  echo "    $DOCKER_USER already in 'docker' group — skipping"
else
  $SUDO usermod -aG docker "$DOCKER_USER"
  echo "    Added $DOCKER_USER to 'docker' group"
  echo "    NOTE: log out/in (or run 'newgrp docker') for it to take effect"
fi

echo
echo "✅ Provisioning done."
echo
if $SUDO tailscale status >/dev/null 2>&1; then
  echo -n "   Tailscale: already connected — IP: "; $SUDO tailscale ip -4
elif [[ -n "${TS_AUTHKEY:-}" ]]; then
  $SUDO tailscale up --authkey "$TS_AUTHKEY" --ssh
  echo -n "   Tailscale joined — IP: "; $SUDO tailscale ip -4
else
  echo "   NEXT — join the tailnet manually (interactive login):"
  echo "     sudo tailscale up"
  echo "     # follow the printed https://login.tailscale.com/... URL to authenticate"
fi
echo
echo "   Then open the Dokploy UI at  http://<this-host-ip>:3000"
echo "   and create the admin account."
