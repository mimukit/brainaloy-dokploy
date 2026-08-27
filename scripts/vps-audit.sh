#!/usr/bin/env bash
# Read-only audit: verifies the end state promised by setup-remote-vps.sh and
# vps-firewall-lockdown.sh. Changes nothing. Run as root on the droplet:
#
#   scp scripts/vps-audit.sh root@<tailscale-ip>:/root/
#   ssh root@<tailscale-ip> 'bash /root/vps-audit.sh'
#
# Exit code: 0 = no FAIL (WARNs allowed), 1 = at least one FAIL.
# NOTE: before the Phase 5 firewall lockdown, the ufw checks FAIL by design.
set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then echo "Run as root." >&2; exit 1; fi

RED=$'\033[0;31m'; YEL=$'\033[0;33m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
PASS=0; WARN=0; FAIL=0

check() { # check <PASS|WARN|FAIL> <name> <detail>
  local st="$1" name="$2" detail="${3:-}"
  case "$st" in
    PASS) PASS=$((PASS+1)); printf '%s[PASS]%s %s\n' "$GRN" "$NC" "$name" ;;
    WARN) WARN=$((WARN+1)); printf '%s[WARN]%s %s — %s\n' "$YEL" "$NC" "$name" "$detail" ;;
    FAIL) FAIL=$((FAIL+1)); printf '%s[FAIL]%s %s — %s\n' "$RED" "$NC" "$name" "$detail" ;;
  esac
}

echo "==> VPS audit ($(hostname), $(date -u +%Y-%m-%dT%H:%MZ))"
echo "    Note: before firewall lockdown (Phase 5), the ufw checks FAIL by design."

echo "==> Setup invariants (setup-remote-vps.sh)"

# 1. Swapfile active + persistent
if swapon --show | grep -q '/swapfile'; then
  if grep -q '^/swapfile' /etc/fstab; then
    check PASS "swapfile active and in fstab"
  else
    check WARN "swapfile" "active but missing from /etc/fstab (won't survive reboot)"
  fi
else
  check FAIL "swapfile" "/swapfile not active"
fi

# 2. Swappiness
sw="$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
if [[ "$sw" == "10" ]]; then
  check PASS "vm.swappiness=10"
else
  check WARN "vm.swappiness" "is $sw, expected 10"
fi

# 3. Docker daemon.json (log rotation + dns)
if ! command -v docker >/dev/null 2>&1; then
  check WARN "docker daemon.json" "Docker not installed yet (Dokploy installs it)"
elif [[ -f /etc/docker/daemon.json ]] \
    && grep -q '"max-size"' /etc/docker/daemon.json \
    && grep -q '"dns"' /etc/docker/daemon.json; then
  check PASS "docker daemon.json has log rotation + dns"
else
  check FAIL "docker daemon.json" "missing, or lacks \"max-size\"/\"dns\" entries"
fi

# 4. Unattended upgrades installed + timer active
if dpkg -s unattended-upgrades >/dev/null 2>&1; then
  if systemctl is-active --quiet apt-daily-upgrade.timer; then
    check PASS "unattended-upgrades installed, timer active"
  else
    check WARN "unattended-upgrades" "installed but apt-daily-upgrade.timer inactive"
  fi
else
  check FAIL "unattended-upgrades" "package not installed"
fi

# 5. Tailscale up with an IP
ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
if tailscale status >/dev/null 2>&1 && [[ -n "$ts_ip" ]]; then
  check PASS "tailscale up ($ts_ip)"
else
  check FAIL "tailscale" "not connected (tailscale status / ip -4 failed)"
fi

# 6. Host DNS resolves (MagicDNS regression guard)
if getent hosts registry-1.docker.io >/dev/null 2>&1; then
  check PASS "host DNS resolves registry-1.docker.io"
else
  check FAIL "host DNS" "cannot resolve registry-1.docker.io (broken resolv.conf?)"
fi

# 7. SSH effective config (sshd -T catches later overrides)
if sshd_eff="$(sshd -T 2>/dev/null)"; then
  ssh_get() { awk -v k="$1" '$1==k {print $2; exit}' <<<"$sshd_eff"; }
  [[ "$(ssh_get passwordauthentication)" == "no" ]] \
    && check PASS "sshd: passwordauthentication no" \
    || check FAIL "sshd passwordauthentication" "is $(ssh_get passwordauthentication), expected no"
  [[ "$(ssh_get pubkeyauthentication)" == "yes" ]] \
    && check PASS "sshd: pubkeyauthentication yes" \
    || check FAIL "sshd pubkeyauthentication" "is $(ssh_get pubkeyauthentication), expected yes"
  [[ "$(ssh_get usepam)" == "no" ]] \
    && check PASS "sshd: usepam no" \
    || check FAIL "sshd usepam" "is $(ssh_get usepam), expected no"
  [[ "$(ssh_get permitrootlogin)" != "yes" ]] \
    && check PASS "sshd: permitrootlogin $(ssh_get permitrootlogin) (not password-yes)" \
    || check FAIL "sshd permitrootlogin" "is yes, expected prohibit-password or no"
else
  check FAIL "sshd -T" "could not read effective sshd config"
fi

echo "==> Lockdown invariants (vps-firewall-lockdown.sh)"

# 8 + 9 + 10. ufw active, default deny incoming, exact allow set
if ! command -v ufw >/dev/null 2>&1; then
  check FAIL "ufw" "not installed (lockdown not run yet?)"
elif ! ufw status | grep -q '^Status: active'; then
  check FAIL "ufw" "installed but inactive"
else
  check PASS "ufw active"
  if ufw status verbose | grep -q 'deny (incoming)'; then
    check PASS "ufw default deny incoming"
  else
    check FAIL "ufw default policy" "incoming is not deny"
  fi
  # Strict allow set: 80/tcp, 443/tcp, anything in on tailscale0. Nothing else.
  bad_rules="$(ufw status | awk '/ALLOW/ {print}' \
    | grep -vE '^(80/tcp|443/tcp)( \(v6\))?[[:space:]]' \
    | grep -v 'on tailscale0' || true)"
  if [[ -z "$bad_rules" ]]; then
    check PASS "ufw allows exactly 80/tcp, 443/tcp, tailscale0"
  else
    check FAIL "ufw extra allow rules" "$(tr '\n' ';' <<<"$bad_rules")"
  fi
  if ufw status | grep -E '^22(/tcp)?[[:space:]]' | grep -q ALLOW; then
    check FAIL "public SSH" "ufw still allows port 22"
  else
    check PASS "public port 22 closed"
  fi
fi

echo "==> General health"

# 11. Reboot required
if [[ -f /var/run/reboot-required ]]; then
  check WARN "reboot required" "$(cat /var/run/reboot-required 2>/dev/null || echo 'pending')"
else
  check PASS "no reboot required"
fi

# 12. Disk usage on /
disk_pct="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if   (( disk_pct < 80 )); then check PASS "disk / at ${disk_pct}%"
elif (( disk_pct < 90 )); then check WARN "disk /" "${disk_pct}% used (>=80%)"
else                           check FAIL "disk /" "${disk_pct}% used (>=90%)"
fi

# 13. Memory availability + swap pressure
mem_total="$(awk '/^MemTotal/ {print $2}' /proc/meminfo)"
mem_avail="$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)"
avail_pct=$(( mem_avail * 100 / mem_total ))
if (( avail_pct >= 15 )); then
  check PASS "memory: ${avail_pct}% available"
else
  check WARN "memory" "only ${avail_pct}% available (<15%)"
fi
swap_total="$(awk '/^SwapTotal/ {print $2}' /proc/meminfo)"
swap_free="$(awk '/^SwapFree/ {print $2}' /proc/meminfo)"
if (( swap_total > 0 )); then
  swap_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
  if (( swap_pct < 75 )); then
    check PASS "swap: ${swap_pct}% used"
  else
    check WARN "swap" "${swap_pct}% used (>=75%)"
  fi
fi

echo
echo "==> Summary: ${PASS} pass, ${WARN} warn, ${FAIL} fail"
(( FAIL == 0 )) || exit 1
