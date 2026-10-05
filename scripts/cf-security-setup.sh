#!/usr/bin/env bash
# Harden Cloudflare zones against scanner bots with the `cf` CLI (Free plan limits).
# Run on a machine where `cf` is logged in. Do not run on the headless dev box.
# Needs bash 4.4+ (macOS: brew install bash), jq 1.6+, pnpm.
#
#   bash scripts/cf-security-setup.sh              # dry run (default): prints the plan
#   bash scripts/cf-security-setup.sh --dry-run    # same, explicit
#   bash scripts/cf-security-setup.sh --apply      # sends the changes
#
# The script lists your zones and lets you pick one by one or all. For each zone it
# lists the proxied DNS hosts and asks which of them are API hosts (server clients)
# and which are WordPress sites.
#
#   API hosts        no empty user agent block, no geo rule
#   WordPress hosts  no blanket .php or /wp- block; the geo rule exempts the origin IPs
#                    of their A/AAAA records, so wp-cron loopback calls still work
#
# WARNING: `phases update` REPLACES every rule in the phase. Custom rules made by
# hand in the dashboard are deleted. In --apply mode the script saves both phases and
# the zone settings it touches to cf-backup/<zone>-<UTC time>/ first, and asks for
# confirmation per zone.
#
# Bot Fight Mode and Browser Integrity Check are zone-wide and cannot be scoped to a
# host. Bot Fight Mode is turned on only for zones with no API or WordPress host, and
# Browser Integrity Check only for zones with no API host. Otherwise the script leaves
# your manual choice as it is.
#
# Env: RL_REQUESTS=<n>  rate limit per 10 s per IP and colo (default 300).
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "Needs bash 4.4 or newer (this is ${BASH_VERSION}). On macOS: brew install bash, then run it with that bash." >&2
  exit 1
fi

CF_VERSION="1.0.0-beta.12"
GEO_ACTION="managed_challenge"
RL_REQUESTS="${RL_REQUESTS:-300}"   # Free plan: period 10 s, timeout 10 s
BACKUP_DIR="cf-backup"
APPLY=0

case "${1:-}" in
  --apply) APPLY=1 ;;
  --dry-run) APPLY=0 ;;
  "") ;;
  *) echo "Usage: $0 [--dry-run|--apply]" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
command -v pnpm >/dev/null || { echo "pnpm is required." >&2; exit 1; }
[[ "$RL_REQUESTS" =~ ^[0-9]+$ ]] || { echo "RL_REQUESTS must be a number." >&2; exit 1; }

# stdin from /dev/null, so pnpm or cf cannot eat the answers typed for the next prompt.
cf() { pnpm --silent dlx "cf@${CF_VERSION}" "$@" </dev/null; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- rule builders -----------------------------------------------------------

json_list() { jq -n '$ARGS.positional' --args "$@"; }

custom_rules() { # custom_rules <api-hosts-json> <wordpress-hosts-json> <origin-ips-json>
  jq -n --argjson api "$1" --argjson wp "$2" --argjson ips "$3" --arg geo "$GEO_ACTION" '
    def hostset: "{" + (map("\"" + . + "\"") | join(" ")) + "}";
    def unless_host($hosts): if ($hosts | length) > 0 then " and not http.host in " + ($hosts | hostset) else "" end;
    "lower(http.request.uri.path)" as $p
    | ("(http.user_agent eq \"\"" + unless_host($api) + ")") as $ua
    # Scanner paths that no Worker and no WordPress site serves.
    | ([ "(\($p) contains \"/.env\")", "(\($p) contains \"/.git\")", "(\($p) contains \"/.aws/\")",
         "(\($p) contains \"wp-config.php\")", "(\($p) contains \"/phpmyadmin\")",
         "(ends_with(\($p), \".ini\"))", "(ends_with(\($p), \".sql\"))", "(ends_with(\($p), \".bak\"))",
         "(ends_with(\($p), \"/xmlrpc.php\"))",
         "(starts_with(\($p), \"/vendor/\"))", "(starts_with(\($p), \"/cgi-bin/\"))" ] | join(" or ")) as $common
    # A Worker has no PHP, so every .php or /wp- path is a probe. WordPress hosts need both.
    | ("((ends_with(\($p), \".php\") or starts_with(\($p), \"/wp-\"))" + unless_host($wp) + ")") as $php
    | ("(ip.src.country ne \"BD\" and not cf.client.bot"
       + " and not starts_with(http.request.uri.path, \"/.well-known/acme-challenge/\")"
       + unless_host($api)
       + (if ($ips | length) > 0 then " and not ip.src in {" + ($ips | join(" ")) + "}" else "" end)
       + ")") as $geo_expr
    | [
        { action: "block", description: "Block non-standard ports",
          expression: "(cf.edge.server_port ne 443 and cf.edge.server_port ne 80)" },
        { action: "block", description: "Block scanner probes",
          expression: ($ua + " or " + $common + " or " + $php) },
        { action: $geo, description: "Non-BD traffic (verified bots, API hosts, origins allowed)",
          expression: $geo_expr }
      ]'
}

rate_rules() {
  # The Free plan allows only the path and verified bot fields here, so match every path.
  jq -n --argjson n "$RL_REQUESTS" '[
    { action: "block", description: "Rate limit per IP",
      expression: "(starts_with(http.request.uri.path, \"/\"))",
      ratelimit: { characteristics: ["cf.colo.id", "ip.src"], period: 10,
                   requests_per_period: $n, mitigation_timeout: 10 } }
  ]'
}

rule_shape() { # rule_shape <file>: the fields we send, from a phase get or a rules array, in a stable order
  jq -S 'if type=="array" then . else (.rules // .result.rules // []) end
    | map({action, expression,
           ratelimit: (.ratelimit | if . then {characteristics: (.characteristics | sort), period,
                                               requests_per_period, mitigation_timeout} else null end)})
    | sort_by(.expression)' "$1"
}

# --- reads -------------------------------------------------------------------

get_phase() { # get_phase <phase> <zone> <out>; writes {} when the zone has no ruleset in the phase yet
  if cf rulesets account-rulesets phases get "$1" --zone "$2" > "$3" 2> "$TMP/err"; then return 0; fi
  if grep -qiE '404|not found|could not find' "$TMP/err"; then echo '{}' > "$3"; return 0; fi
  echo "Cannot read phase $1 on $2:" >&2; cat "$TMP/err" >&2; return 1
}

pick_hosts() { # pick_hosts <question>; sets PICKED from HOSTS
  local line n
  PICKED=()
  printf '%s Numbers, or empty for none: ' "$1"
  read -r line
  for n in $line; do
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#HOSTS[@]} )) || { echo "Bad choice: $n" >&2; return 1; }
    PICKED+=("${HOSTS[$((n-1))]}")
  done
}

# --- zone selection ----------------------------------------------------------

echo "==> Listing zones"
cf zones list --per-page 50 > "$TMP/zones.json"
mapfile -t ZONES < <(jq -r 'if type=="array" then . else (.result // .zones // []) end | .[].name' "$TMP/zones.json")
[[ ${#ZONES[@]} -gt 0 ]] || { echo "No zones found. Run 'cf auth login' first." >&2; exit 1; }

for i in "${!ZONES[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${ZONES[$i]}"; done
printf 'Pick numbers (space separated), "all", or "q": '
read -r PICK
[[ "$PICK" == "q" || -z "$PICK" ]] && exit 0

SELECTED=()
if [[ "$PICK" == "all" ]]; then
  SELECTED=("${ZONES[@]}")
else
  for n in $PICK; do
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#ZONES[@]} )) || { echo "Bad choice: $n" >&2; exit 1; }
    SELECTED+=("${ZONES[$((n-1))]}")
  done
fi

# --- per-zone work -----------------------------------------------------------

DRY=(); [[ $APPLY -eq 0 ]] && DRY=(--dry-run)
[[ $APPLY -eq 1 ]] && echo "==> APPLY mode: changes go to Cloudflare." || echo "==> DRY RUN: reads are real, writes are only printed."

harden_zone() { # harden_zone <zone>; returns 3 when the owner skips the zone, other non-zero on failure
  local zone="$1" dir="$TMP/$1" api=() wp=() h s
  mkdir -p "$dir/before"
  echo; echo "=== ${zone}"

  echo "--- proxied hosts"
  cf dns records list --zone "$zone" --per-page 500 > "$dir/dns.json"
  mapfile -t HOSTS < <(jq -r 'if type=="array" then . else (.result // []) end | [.[] | select(.proxied == true) | .name] | unique | .[]' "$dir/dns.json")
  for i in "${!HOSTS[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${HOSTS[$i]}"; done
  if [[ ${#HOSTS[@]} -gt 0 ]]; then
    pick_hosts "Which are API hosts?"; api=("${PICKED[@]}")
    pick_hosts "Which are WordPress sites?"; wp=("${PICKED[@]}")
    for h in "${wp[@]}"; do
      [[ " ${api[*]} " == *" $h "* ]] && { echo "$h cannot be both an API host and a WordPress site." >&2; return 1; }
    done
  else
    echo "  (none found; treating the zone as having no API or WordPress host)"
  fi

  local api_json wp_json ips_json
  api_json="$(json_list "${api[@]}")"
  wp_json="$(json_list "${wp[@]}")"
  ips_json="$(jq --argjson wp "$wp_json" '[ (if type=="array" then . else (.result // []) end)[]
    | select(.proxied == true and (.type == "A" or .type == "AAAA") and (.name as $n | any($wp[]; . == $n)))
    | .content ] | unique' "$dir/dns.json")"
  if [[ ${#wp[@]} -gt 0 ]]; then
    if [[ "$(jq length <<<"$ips_json")" -gt 0 ]]; then
      echo "Geo rule exempts WordPress origin IPs: $(jq -r 'join(" ")' <<<"$ips_json")"
    else
      echo "WARNING: no A or AAAA record for the WordPress sites. Their loopback calls (wp-cron) will hit the geo challenge." >&2
    fi
  fi

  echo "--- reading current state"
  get_phase http_request_firewall_custom "$zone" "$dir/before/http_request_firewall_custom.json"
  get_phase http_ratelimit "$zone" "$dir/before/http_ratelimit.json"
  for s in always_use_https browser_check; do
    cf zones settings get "$s" --zone "$zone" > "$dir/before/${s}.json"
  done
  cf bot-management get --zone "$zone" > "$dir/before/bot_management.json"

  echo "--- current custom rules (they will be replaced)"
  jq -r 'if type=="array" then . else (.rules // .result.rules // []) end | .[] | "  - " + (.description // .expression)' \
    "$dir/before/http_request_firewall_custom.json"

  if [[ $APPLY -eq 1 ]]; then
    local ok backup
    printf 'Replace all custom and rate limiting rules on %s? [y/N]: ' "$zone"
    read -r ok; [[ "$ok" == "y" ]] || { echo "Skipped."; return 3; }
    backup="${BACKUP_DIR}/${zone}-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$backup"
    cp "$dir/before/"*.json "$backup/"
    echo "Backup saved: ${backup}/"
  fi

  custom_rules "$api_json" "$wp_json" "$ips_json" > "$dir/custom.json"
  rate_rules > "$dir/rate.json"

  cf rulesets account-rulesets phases update http_request_firewall_custom --zone "$zone" --rules "@$dir/custom.json" "${DRY[@]}"
  cf rulesets account-rulesets phases update http_ratelimit --zone "$zone" --rules "@$dir/rate.json" "${DRY[@]}"
  cf zones settings edit always_use_https --zone "$zone" --body '{"value":"on"}' "${DRY[@]}"
  if [[ ${#api[@]} -eq 0 ]]; then
    cf zones settings edit browser_check --zone "$zone" --body '{"value":"on"}' "${DRY[@]}"
  else
    echo "Browser Integrity Check: skipped (zone has API hosts; it cannot be scoped to a host)."
  fi
  if [[ ${#api[@]} -eq 0 && ${#wp[@]} -eq 0 ]]; then
    cf bot-management update --zone "$zone" --fight-mode "${DRY[@]}"
  else
    echo "Bot Fight Mode: skipped (zone has API or WordPress hosts; it cannot be scoped to a host)."
  fi

  if [[ $APPLY -eq 1 ]]; then
    local phase file
    for phase in http_request_firewall_custom:custom http_ratelimit:rate; do
      file="$dir/${phase#*:}.json"
      get_phase "${phase%%:*}" "$zone" "$dir/after.json"
      if [[ "$(rule_shape "$dir/after.json")" == "$(rule_shape "$file")" ]]; then
        echo "Read-back ${phase%%:*}: OK"
      else
        echo "Read-back ${phase%%:*}: MISMATCH" >&2; return 1
      fi
    done
  fi
}

OK_ZONES=(); SKIPPED_ZONES=(); FAILED_ZONES=()
for zone in "${SELECTED[@]}"; do
  # A subshell that `if` tests ignores set -e, so a failed cf call would count as OK.
  # Run it bare with errexit on inside and read the exit code.
  set +e; ( set -e; harden_zone "$zone" ); rc=$?; set -e
  case $rc in
    0) OK_ZONES+=("$zone") ;;
    3) SKIPPED_ZONES+=("$zone") ;;
    *) FAILED_ZONES+=("$zone") ;;
  esac
done

echo
echo "==> Summary"
for z in "${OK_ZONES[@]}"; do echo "  OK       $z"; done
for z in "${SKIPPED_ZONES[@]}"; do echo "  SKIPPED  $z"; done
for z in "${FAILED_ZONES[@]}"; do echo "  FAILED   $z"; done
echo "After --apply, watch Security > Events on each zone for one hour."
echo "Set workers_dev: false and preview_urls: false in each Worker's wrangler.jsonc,"
echo "except brainaloy-vps-cf-tunnel: its callers use the workers.dev URL."
[[ ${#FAILED_ZONES[@]} -eq 0 ]]
