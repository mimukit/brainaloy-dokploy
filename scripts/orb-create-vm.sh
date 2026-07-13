#!/usr/bin/env bash
# OPTIONAL macOS helper: create the OrbStack Ubuntu machine for the Dokploy panel.
# You can also do this by hand:  orb create ubuntu:24.04 dokploy
#
# This script ONLY provisions the empty VM. Installing apps inside it is a
# separate, machine-agnostic step — see scripts/setup-control-panel-vm.sh.
#
# Idempotent: re-running reuses an existing machine.
#
#   scripts/orb-create-vm.sh
set -euo pipefail

MACHINE="${MACHINE:-dokploy}"
# Pin to 24.04 LTS: newer releases (e.g. 26.04 "resolute") aren't in Docker's
# apt repo yet, which breaks Dokploy's Docker install. Override with UBUNTU_IMAGE.
UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"

if ! command -v orb >/dev/null 2>&1; then
  echo "OrbStack 'orb' CLI not found. Install OrbStack first: https://orbstack.dev" >&2
  exit 1
fi

echo "==> Create OrbStack machine '$MACHINE' ($UBUNTU_IMAGE)"
if orb list 2>/dev/null | awk '{print $1}' | grep -qx "$MACHINE"; then
  echo "    machine '$MACHINE' already exists — reusing"
else
  orb create "$UBUNTU_IMAGE" "$MACHINE"
  echo "    created '$MACHINE'"
fi

echo
echo "✅ VM ready. Next — provision apps inside it (Tailscale, Dokploy, CLI tools):"
echo "     orb -m $MACHINE sudo bash -s < scripts/setup-control-panel-vm.sh"
echo
echo "   Or open a shell and run it there:  orb -m $MACHINE"
