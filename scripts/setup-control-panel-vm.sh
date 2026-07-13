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

echo "==> [1/5] Base CLI tools"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq curl tmux btop vim bat jq >/dev/null
echo "    apt tools ready (curl, tmux, btop, vim, jq)"
if command -v lazydocker >/dev/null 2>&1; then
  echo "    lazydocker already installed — skipping"
else
  curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh \
    | $SUDO env DIR=/usr/local/bin bash
  echo "    lazydocker installed"
fi

echo "==> [2/5] Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  echo "    tailscale already installed — skipping"
else
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
  echo "    tailscale installed"
fi

echo "==> [3/5] Dokploy (official installer)"
if $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -q dokploy; then
  echo "    Dokploy already running — skipping install"
else
  curl -sSL https://dokploy.com/install.sh | $SUDO sh
  echo "    Dokploy installed"
fi

# Self-heal: the official installer creates postgres → redis → dokploy →
# traefik in sequence. If one step fails (e.g. a `redis:7` image pull dies on
# broken MagicDNS — the very thing step 4 fixes, but which bites DURING install),
# the stack ends up missing a service and the UI reports e.g.
#   "(HTTP code 404) no such service - service dokploy-redis not found".
# The guard above only checks that *some* dokploy* container runs, so a re-run
# won't notice. Reconcile the Swarm services the installer owns.
if $SUDO docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
  # Redis is stateless (cache/queue) and its create command is stable across
  # Dokploy versions, so recreating it when missing is safe and self-healing.
  if $SUDO docker service inspect dokploy-redis >/dev/null 2>&1; then
    echo "    dokploy-redis service present — skipping"
  else
    echo "    dokploy-redis service missing — recreating"
    $SUDO docker service create \
      --name dokploy-redis \
      --constraint 'node.role==manager' \
      --network dokploy-network \
      --mount type=volume,source=redis-data-volume,destination=/data \
      redis:7
  fi
  # Postgres holds real state and its spec (password via env vs. Docker secret)
  # varies by Dokploy version — don't recreate it with guessed credentials.
  # Just flag it for a human, who can restore from a backup if the volume is gone.
  if ! $SUDO docker service inspect dokploy-postgres >/dev/null 2>&1; then
    echo "    ⚠️  dokploy-postgres service MISSING — restore it manually (holds DB state)."
  fi
fi

echo "==> [4/5] Docker daemon DNS (fixes container lookups on a Tailscale host)"
# Tailscale MagicDNS rewrites the host /etc/resolv.conf to nameserver
# 100.100.100.100. Docker's embedded resolver (127.0.0.11) forwards there, but
# containers often can't reach it — so outbound lookups fail with
# "server misbehaving". This is exactly what breaks the Dokploy S3 Destination
# test (rclone can't resolve *.r2.cloudflarestorage.com), since that test runs
# on THIS panel host. Give the daemon a real public resolver instead.
DAEMON_JSON="/etc/docker/daemon.json"
$SUDO mkdir -p /etc/docker
if [[ ! -f "$DAEMON_JSON" ]]; then
  echo '{ "dns": ["1.1.1.1", "8.8.8.8"] }' | $SUDO tee "$DAEMON_JSON" >/dev/null
  RESTART_DOCKER=1
elif $SUDO jq -e '.dns' "$DAEMON_JSON" >/dev/null 2>&1; then
  echo "    daemon.json already sets \"dns\" — skipping"
  RESTART_DOCKER=0
else
  # Merge the dns key in without clobbering existing settings (e.g. log-opts).
  TMP="$($SUDO mktemp)"
  $SUDO jq '. + { "dns": ["1.1.1.1", "8.8.8.8"] }' "$DAEMON_JSON" | $SUDO tee "$TMP" >/dev/null
  $SUDO mv "$TMP" "$DAEMON_JSON"
  RESTART_DOCKER=1
fi
if [[ "${RESTART_DOCKER:-0}" == "1" ]]; then
  echo "    Wrote DNS to $DAEMON_JSON — restarting Docker (briefly bounces Dokploy)"
  $SUDO systemctl restart docker 2>/dev/null || $SUDO service docker restart 2>/dev/null || \
    echo "    ⚠️  Could not restart Docker automatically — restart it manually."
fi

echo "==> [5/5] Docker socket access (add login user to 'docker' group)"
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
  $SUDO tailscale set --accept-dns=false 2>/dev/null || true
elif [[ -n "${TS_AUTHKEY:-}" ]]; then
  $SUDO tailscale up --authkey "$TS_AUTHKEY" --ssh --accept-dns=false
  echo -n "   Tailscale joined — IP: "; $SUDO tailscale ip -4
else
  echo "   NEXT — join the tailnet manually (interactive login):"
  echo "     sudo tailscale up --accept-dns=false"
  echo "     # follow the printed https://login.tailscale.com/... URL to authenticate"
fi
# --accept-dns=false: don't let Tailscale MagicDNS take over /etc/resolv.conf.
# A misbehaving MagicDNS breaks HOST-level DNS (docker image pulls, apt, etc.) —
# and unlike daemon.json "dns", the host resolver is what `docker pull` uses.
# We reach other nodes by Tailscale IP, not MagicDNS name, so this is safe.

# Belt-and-suspenders: --accept-dns=false flips the pref but on OrbStack does NOT
# always restore a working /etc/resolv.conf (it can leave the dead MagicDNS entry
# behind). If a host-level lookup still fails, pin public resolvers directly so
# `docker pull` / apt work. Idempotent: only rewrites when DNS is actually broken.
if ! getent hosts registry-1.docker.io >/dev/null 2>&1; then
  echo "   Host DNS still broken after Tailscale — pinning public resolvers in /etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | $SUDO tee /etc/resolv.conf >/dev/null
  $SUDO systemctl restart docker 2>/dev/null || $SUDO service docker restart 2>/dev/null || true
  getent hosts registry-1.docker.io >/dev/null 2>&1 \
    && echo "   Host DNS repaired." \
    || echo "   ⚠️  Host DNS still failing — check 'cat /etc/resolv.conf' (is it an immutable/symlink?)."
fi
echo
echo "   Then open the Dokploy UI at  http://<this-host-ip>:3000"
echo "   and create the admin account."
