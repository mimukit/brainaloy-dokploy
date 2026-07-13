#!/usr/bin/env bash
# Stand up the local Dokploy control plane inside an OrbStack Ubuntu machine.
# Run on macOS (host) with OrbStack installed. Automates the deterministic parts;
# Tailscale auth and the Dokploy admin account are interactive (by design).
#
#   scripts/orb-panel-setup.sh
set -euo pipefail

MACHINE="${MACHINE:-dokploy}"

if ! command -v orb >/dev/null 2>&1; then
  echo "OrbStack 'orb' CLI not found. Install OrbStack first: https://orbstack.dev" >&2
  exit 1
fi

echo "==> [1/4] Create OrbStack Ubuntu machine '$MACHINE' (latest LTS)"
if orb list 2>/dev/null | awk '{print $1}' | grep -qx "$MACHINE"; then
  echo "    machine '$MACHINE' already exists — reusing"
else
  orb create ubuntu "$MACHINE"
fi

run() { orb -m "$MACHINE" sudo bash -lc "$*"; }

echo "==> [2/4] Install Tailscale inside the machine"
run 'command -v tailscale >/dev/null 2>&1 || (curl -fsSL https://tailscale.com/install.sh | sh)'

echo "==> [3/4] Join tailnet (interactive — follow the URL if prompted)"
if run 'tailscale status >/dev/null 2>&1'; then
  echo "    already connected"
else
  orb -m "$MACHINE" sudo tailscale up || true
fi
echo -n "    Panel Tailscale IP: "; run 'tailscale ip -4 || echo "(not connected yet)"'

echo "==> [4/4] Install Dokploy (official installer)"
if run 'docker ps --format "{{.Names}}" 2>/dev/null | grep -q dokploy'; then
  echo "    Dokploy already running — skipping install"
else
  run 'curl -sSL https://dokploy.com/install.sh | sh'
fi

echo
echo "✅ Panel setup done."
echo "   Open the UI:   orb list   # find the '$MACHINE' IP, then http://<ip>:3000"
echo "   Create the admin account, add S3 (R2) destination, then add your DO server."
