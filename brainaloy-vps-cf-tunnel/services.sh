#!/usr/bin/env bash
# Keeps the Cloudflare VPC Services in step with services.conf. Runs on your Mac.
#
#   ./services.sh apply     # create missing services, update existing ones
#   ./services.sh list      # show the services in services.conf and their ids
#   ./services.sh bindings  # print vpc_services entries for a Worker's wrangler.jsonc
#
# Needs: node, `npx wrangler login`, and TUNNEL_ID in the environment or in .env.
# It never deletes a service. Delete by hand: npx wrangler vpc service delete <id>
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/services.conf"
WRANGLER_VERSION="4.132.0"

RED=$'\033[0;31m'; NC=$'\033[0m'
die() { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
wr() { npx --yes "wrangler@$WRANGLER_VERSION" "$@"; }

CMD="${1:-}"
[[ "$CMD" =~ ^(apply|list|bindings)$ ]] || die "usage: ./services.sh apply|list|bindings"
command -v node >/dev/null || die "missing command: node"
[[ -f "$CONF" ]] || die "missing $CONF"
if [[ -z "${TUNNEL_ID:-}" && -f "$DIR/.env" ]]; then
  TUNNEL_ID="$(grep -E '^TUNNEL_ID=' "$DIR/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')"
fi

# conf_lines: prints "name scheme kind host port" per line of services.conf.
conf_lines() {
  grep -vE '^\s*(#|$)' "$CONF" | while read -r name url extra; do
    [[ -z "${extra:-}" ]] || die "services.conf: more than two fields on the line for $name"
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "services.conf: bad name '$name'"
    node -e '
      const net = require("node:net");
      const [name, raw] = process.argv.slice(1);
      let u;
      try { u = new URL(raw); } catch { console.error(`services.conf: bad URL for ${name}`); process.exit(1); }
      if (u.protocol !== "http:" && u.protocol !== "https:") {
        console.error(`services.conf: ${name} must use http or https`); process.exit(1);
      }
      const scheme = u.protocol.slice(0, -1);
      const host = u.hostname.replace(/^\[|\]$/g, "");
      const kind = net.isIPv4(host) ? "ipv4" : net.isIPv6(host) ? "ipv6" : "hostname";
      console.log(name, scheme, kind, host, u.port || (scheme === "https" ? "443" : "80"));
    ' "$name" "$url" || exit 1
  done
}

# remote_id NAME: prints the id of the VPC Service with this name, or nothing.
# wrangler prints a table and no JSON, so read the id and name columns of REMOTE.
REMOTE="$(wr vpc service list 2>/dev/null)" || die "wrangler vpc service list failed. Run: npx wrangler login"
remote_id() {
  awk -F'│' -v n="$1" '{ gsub(/ /, "", $2); gsub(/ /, "", $3); if ($3 == n) print $2 }' <<<"$REMOTE" | head -1
}

# binding_name NAME: egress-khudebarta -> EGRESS_KHUDEBARTA
binding_name() { tr '[:lower:]-' '[:upper:]_' <<<"$1"; }

LINES="$(conf_lines)"
[[ -n "$LINES" ]] || die "services.conf lists no service"

case "$CMD" in
  apply)
    [[ -n "${TUNNEL_ID:-}" ]] || die "set TUNNEL_ID, or put TUNNEL_ID=<uuid> in $DIR/.env"
    while read -r name scheme kind host port; do
      args=(--type http --tunnel-id "$TUNNEL_ID" "--$kind" "$host")
      if [[ "$scheme" == https ]]; then
        args+=(--https-port "$port" --cert-verification-mode verify_full)
      else
        args+=(--http-port "$port")
      fi
      id="$(remote_id "$name")"
      if [[ -n "$id" ]]; then
        info "Update $name ($id) -> $scheme://$host:$port"
        wr vpc service update "$id" --name "$name" "${args[@]}" >/dev/null || die "update failed for $name"
      else
        info "Create $name -> $scheme://$host:$port"
        wr vpc service create "$name" "${args[@]}" >/dev/null || die "create failed for $name"
      fi
    done <<<"$LINES"
    info "Done. Run ./services.sh bindings for the Worker config."
    ;;
  list)
    while read -r name scheme kind host port; do
      printf '%-28s %-40s %s\n' "$name" "$scheme://$host:$port" "$(remote_id "$name")"
    done <<<"$LINES"
    ;;
  bindings)
    entries=()
    while read -r name _; do
      id="$(remote_id "$name")"
      [[ -n "$id" ]] || die "$name does not exist in Cloudflare. Run ./services.sh apply first."
      entries+=("$(printf '  { "binding": "%s", "service_id": "%s", "remote": true }' "$(binding_name "$name")" "$id")")
    done <<<"$LINES"
    echo '"vpc_services": ['
    for i in "${!entries[@]}"; do
      (( i == ${#entries[@]} - 1 )) && echo "${entries[$i]}" || echo "${entries[$i]},"
    done
    echo ']'
    ;;
esac
