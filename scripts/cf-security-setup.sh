#!/usr/bin/env bash
# Harden Cloudflare zones against scanner bots with the `cf` CLI (Free plan limits).
# Run on a machine where `cf` is logged in. Do not run on the headless dev box.
# Needs bash 4.4+ (macOS: brew install bash), jq 1.6+, pnpm.
#
#   bash scripts/cf-security-setup.sh              # dry run (default): prints the plan
#   bash scripts/cf-security-setup.sh --dry-run    # same, explicit
#   bash scripts/cf-security-setup.sh --apply      # sends the changes
#
# The script asks for one account, then one active zone in that account. It lists the
# proxied DNS hosts of the zone and asks which of them are API hosts (server clients)
# and which are WordPress sites. Then it asks if the zone gets the geo rule. Say no for
# a zone with real visitors outside Bangladesh, such as a portfolio. Run it again for
# the next zone.
#
#   API hosts        no empty user agent block, no hosting network rule, no geo rule
#   WordPress hosts  no blanket .php or /wp- block; the hosting network and geo rules
#                    exempt the origin IPs of their A/AAAA records, so wp-cron loopback
#                    calls still work
#
# WARNING: `phases update` REPLACES every rule in the phase. Custom rules made by
# hand in the dashboard are deleted. In --apply mode the script saves the affected
# phases and zone settings to cf-backup/<zone>-<UTC time>/ before it sends changes.
# It asks for confirmation per zone. Redirect rules keep existing rules and update
# only the two rules owned by this script. Redirects are optional per zone.
#
# Bot Fight Mode and Browser Integrity Check are zone-wide and cannot be scoped to a
# host. Bot Fight Mode requires JavaScript detections. The script enables both only
# for zones with no API or WordPress host. The script enables Browser Integrity Check
# only for zones with no API host. Otherwise the script leaves
# your manual choice as it is.
#
# Env: RL_REQUESTS=<n>       rate limit per 10 s per IP and colo (default 300).
#      HOSTING_ASNS="<n> ..."  hosting networks to challenge (default: the list below).
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "Needs bash 4.4 or newer (this is ${BASH_VERSION}). On macOS: brew install bash, then run it with that bash." >&2
  exit 1
fi

CF_VERSION="1.0.0-beta.12"
GEO_ACTION="managed_challenge"
RL_REQUESTS="${RL_REQUESTS:-300}"   # Free plan: period 10 s, timeout 10 s
# Hosting networks that sent 97% of the mitigated requests on mimukit.com (2026-10-13):
# Microsoft 8075, Amazon 16509 14618, Google Cloud 396982, Oracle 31898, DigitalOcean 14061,
# Hetzner 24940, OVH 16276, Linode 63949, Vultr 20473, Tencent 132203 45090,
# Alibaba 37963 45102, TECHOFF 48090.
HOSTING_ASNS="${HOSTING_ASNS:-8075 16509 14618 396982 31898 14061 24940 16276 63949 20473 132203 45090 37963 45102 48090}"
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
[[ "$HOSTING_ASNS" =~ ^[0-9]+( +[0-9]+)*$ ]] || { echo "HOSTING_ASNS must be numbers separated by spaces." >&2; exit 1; }

# stdin from /dev/null, so pnpm or cf cannot eat the answers typed for the next prompt.
# --quiet hides the version banner; errors and the --dry-run request still print.
cf() { pnpm --silent dlx "cf@${CF_VERSION}" "$@" --quiet </dev/null; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- rule builders -----------------------------------------------------------

json_list() { jq -n '$ARGS.positional' --args "$@"; }

custom_rules() { # custom_rules <api-hosts-json> <wordpress-hosts-json> <origin-ips-json> <geo: 0|1>
  jq -n --argjson api "$1" --argjson wp "$2" --argjson ips "$3" --argjson geo_on "$4" \
        --arg geo "$GEO_ACTION" --arg asns "$HOSTING_ASNS" '
    def hostset: "{" + (map("\"" + . + "\"") | join(" ")) + "}";
    def unless_host($hosts): if ($hosts | length) > 0 then " and not http.host in " + ($hosts | hostset) else "" end;
    "lower(http.request.uri.path)" as $p
    | ("(http.user_agent eq \"\"" + unless_host($api) + ")") as $ua
    # Scanner paths that no Worker and no WordPress site serves. %25 is a double-encoded
    # path such as /%252fsysadmin%252f.env; Cloudflare does not decode it.
    | ([ "(\($p) contains \".env\")", "(\($p) contains \"/.git\")", "(\($p) contains \"/.aws/\")",
         "(\($p) contains \"/.svn\")", "(\($p) contains \"/.ds_store\")", "(\($p) contains \"/.vscode\")",
         "(\($p) contains \"%25\")", "(\($p) contains \"phpinfo\")", "(\($p) contains \"wp-config.php\")",
         "(\($p) contains \"/phpmyadmin\")", "(\($p) contains \"/actuator\")", "(\($p) contains \"/server-status\")",
         "(\($p) contains \"laravel-filemanager\")",
         "(ends_with(\($p), \".ini\"))", "(ends_with(\($p), \".sql\"))", "(ends_with(\($p), \".bak\"))",
         "(ends_with(\($p), \".sh\"))", "(ends_with(\($p), \".cgi\"))", "(ends_with(\($p), \".jsp\"))",
         "(ends_with(\($p), \".yml\"))", "(ends_with(\($p), \".yaml\"))",
         "(ends_with(\($p), \".tar.gz\"))", "(ends_with(\($p), \".tgz\"))",
         "(ends_with(\($p), \"/xmlrpc.php\"))",
         "(starts_with(\($p), \"/vendor/\"))", "(starts_with(\($p), \"/cgi-bin/\"))",
         "(starts_with(\($p), \"/venv/\"))" ] | join(" or ")) as $common
    # A Worker has no PHP, so every .php or /wp- path is a probe. WordPress hosts need both.
    | ("((ends_with(\($p), \".php\") or starts_with(\($p), \"/wp-\"))" + unless_host($wp) + ")") as $php
    # Shared by the hosting network and geo rules.
    | (" and not cf.client.bot"
       + " and not starts_with(http.request.uri.path, \"/.well-known/acme-challenge/\")"
       + unless_host($api)
       + (if ($ips | length) > 0 then " and not ip.src in {" + ($ips | join(" ")) + "}" else "" end)
       + ")") as $exempt
    | ($asns | split(" ") | map(select(. != "")) | join(" ")) as $asn_set
    | [
        { action: "block", description: "Block non-standard ports",
          expression: "(cf.edge.server_port ne 443 and cf.edge.server_port ne 80)" },
        { action: "block", description: "Block scanner probes",
          expression: ($ua + " or " + $common + " or " + $php) },
        { action: "managed_challenge", description: "Hosting networks (verified bots, API hosts, origins allowed)",
          expression: ("(ip.src.asnum in {" + $asn_set + "}" + $exempt) }
      ]
    + (if $geo_on == 1 then
        [ { action: $geo, description: "Non-BD traffic (verified bots, API hosts, origins allowed)",
            expression: ("(ip.src.country ne \"BD\"" + $exempt) } ]
       else [] end)'
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

# Stable refs identify only the redirect rules that this script owns.
redirect_rules() { # redirect_rules <zone> <root|www|https> <current-phase-file>
  jq --arg zone "$1" --arg mode "$2" '
    def rules:
      if type == "array" then . else (.rules // .result.rules // []) end;
    def redirect($ref; $description; $match; $target):
      {ref: $ref, description: $description, action: "redirect", enabled: true,
       expression: $match,
       action_parameters: {from_value: {status_code: 301, preserve_query_string: true,
                                       target_url: {expression: $target}}}};
    [redirect("cf_security_https"; "Security setup: HTTP to HTTPS";
              "(not ssl)";
              "concat(\"https://\", http.host, http.request.uri.path)")]
    + (rules | map(select(.ref != "cf_security_canonical_host" and .ref != "cf_security_https")
      | {id, ref, action, expression, description, enabled, action_parameters}
      | with_entries(select(.value != null))))
    + (if $mode == "https" then [] else
        (if $mode == "www" then $zone else "www." + $zone end) as $source
        | (if $mode == "www" then "www." + $zone else $zone end) as $target
        | (if $mode == "www" then "Security setup: non-www to www"
           else "Security setup: www to non-www" end) as $description
        | [redirect("cf_security_canonical_host"; $description;
                    ("(http.host eq " + ($source | tojson) + ")");
                    ("concat(" + ("https://" + $target | tojson) + ", http.request.uri.path)"))]
       end)
    | if length > 10 then error("Redirect rules exceed the Free plan limit of 10; no changes sent") else . end
  ' "$3"
}

redirect_shape() { # Preserve order: the first matching redirect wins.
  jq -S 'if type == "array" then . else (.rules // .result.rules // []) end
    | map({action, description, expression, enabled: (if .enabled == null then true else .enabled end), action_parameters})' "$1"
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

# --- account and zone selection ---------------------------------------------

pick_one() { # pick_one <what> <items...>; sets PICKED_INDEX (0-based index), exits on "q"
  local what="$1" n i; shift
  if [[ $# -eq 1 ]]; then PICKED_INDEX=0; echo "Only one ${what}: $1"; return 0; fi
  for ((i = 1; i <= $#; i++)); do printf '  %2d) %s\n' "$i" "${!i}"; done
  printf 'Pick one %s by number, or "q": ' "$what"
  read -r n
  [[ "$n" == "q" || -z "$n" ]] && exit 0
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= $# )) || { echo "Bad choice: $n" >&2; exit 1; }
  PICKED_INDEX=$((n - 1))
}

echo "==> Listing accounts"
cf accounts list > "$TMP/accounts.json"
jq_accounts='if type=="array" then . else (.result // .accounts // []) end | .[]'
mapfile -t ACCOUNT_NAMES < <(jq -r "$jq_accounts | .name" "$TMP/accounts.json")
mapfile -t ACCOUNT_IDS < <(jq -r "$jq_accounts | .id" "$TMP/accounts.json")
[[ ${#ACCOUNT_IDS[@]} -gt 0 ]] || { echo "No accounts found. Run 'cf auth login' first." >&2; exit 1; }
pick_one account "${ACCOUNT_NAMES[@]}"
# With more than one account, cf cannot find a zone by name until it knows the account.
export CLOUDFLARE_ACCOUNT_ID="${ACCOUNT_IDS[$PICKED_INDEX]}"
echo "Account: ${ACCOUNT_NAMES[$PICKED_INDEX]} (${CLOUDFLARE_ACCOUNT_ID})"

echo "==> Listing active zones"
cf zones list --account-id "$CLOUDFLARE_ACCOUNT_ID" --status active --per-page 50 > "$TMP/zones.json"
mapfile -t ZONES < <(jq -r 'if type=="array" then . else (.result // .zones // []) end | .[].name' "$TMP/zones.json")
[[ ${#ZONES[@]} -gt 0 ]] || { echo "No active zones in this account." >&2; exit 1; }
pick_one zone "${ZONES[@]}"
SELECTED=("${ZONES[$PICKED_INDEX]}")

# --- per-zone work -----------------------------------------------------------

DRY=(); [[ $APPLY -eq 0 ]] && DRY=(--dry-run)
[[ $APPLY -eq 1 ]] && echo "==> APPLY mode: changes go to Cloudflare." || echo "==> DRY RUN: reads are real, writes are only printed."

harden_zone() { # harden_zone <zone>; returns 3 when the owner skips the zone, other non-zero on failure
  local zone="$1" dir="$TMP/$1" api=() wp=() h s geo_on=1 answer redirects=skip
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
  # Say no for a zone whose real visitors are outside BD, such as a portfolio.
  printf 'Challenge traffic from outside BD on %s? [Y/n]: ' "$zone"
  read -r answer
  case "$answer" in
    ""|y|Y) geo_on=1; echo "Geo rule: on" ;;
    n|N) geo_on=0; echo "Geo rule: off (hosting networks are still challenged)" ;;
    *) echo "Bad choice: $answer" >&2; return 1 ;;
  esac

  echo "--- redirect rules for ${zone}"
  echo "  1) HTTP to HTTPS and WWW to root (default)"
  echo "  2) HTTP to HTTPS and root to WWW"
  echo "  3) HTTP to HTTPS only (remove this script's hostname redirect)"
  echo "  0) Leave Redirect Rules unchanged"
  printf 'Pick redirect rules [1]: '
  read -r answer
  case "$answer" in
    ""|1) redirects=root ;;
    2) redirects=www ;;
    3) redirects=https ;;
    0) redirects=skip ;;
    *) echo "Bad choice: $answer" >&2; return 1 ;;
  esac
  if [[ "$redirects" != skip ]]; then
    echo "Redirects use status 301 and keep the path and query string."
    echo "HTTP to HTTPS is rule 1. Other existing rules keep their order."
    echo "The source host needs proxied DNS. The target host needs DNS and HTTPS."
  fi

  local api_json wp_json ips_json
  api_json="$(json_list "${api[@]}")"
  wp_json="$(json_list "${wp[@]}")"
  ips_json="$(jq --argjson wp "$wp_json" '[ (if type=="array" then . else (.result // []) end)[]
    | select(.proxied == true and (.type == "A" or .type == "AAAA") and (.name as $n | any($wp[]; . == $n)))
    | .content ] | unique' "$dir/dns.json")"
  if [[ ${#wp[@]} -gt 0 ]]; then
    if [[ "$(jq length <<<"$ips_json")" -gt 0 ]]; then
      echo "Hosting network and geo rules exempt WordPress origin IPs: $(jq -r 'join(" ")' <<<"$ips_json")"
    else
      echo "WARNING: no A or AAAA record for the WordPress sites. Their loopback calls (wp-cron) will hit the hosting network challenge." >&2
    fi
  fi

  echo "--- reading current state"
  get_phase http_request_firewall_custom "$zone" "$dir/before/http_request_firewall_custom.json"
  get_phase http_ratelimit "$zone" "$dir/before/http_ratelimit.json"
  for s in always_use_https browser_check; do
    cf zones settings get "$s" --zone "$zone" > "$dir/before/${s}.json"
  done
  cf bot-management get --zone "$zone" > "$dir/before/bot_management.json"

  if [[ "$redirects" != skip ]]; then
    get_phase http_request_dynamic_redirect "$zone" "$dir/before/http_request_dynamic_redirect.json"
    redirect_rules "$zone" "$redirects" "$dir/before/http_request_dynamic_redirect.json" > "$dir/redirect.json"
    echo "--- proposed redirect rules (HTTP to HTTPS is first)"
    jq . "$dir/redirect.json"
  fi

  echo "--- current custom rules (they will be replaced)"
  jq -r 'if type=="array" then . else (.rules // .result.rules // []) end | .[] | "  - " + (.description // .expression)' \
    "$dir/before/http_request_firewall_custom.json"

  if [[ $APPLY -eq 1 ]]; then
    local ok backup
    printf 'Replace custom and rate limiting rules and apply the selected redirects on %s? [y/N]: ' "$zone"
    read -r ok; [[ "$ok" == "y" ]] || { echo "Skipped."; return 3; }
    backup="${BACKUP_DIR}/${zone}-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$backup"
    cp "$dir/before/"*.json "$backup/"
    echo "Backup saved: ${backup}/"
  fi

  custom_rules "$api_json" "$wp_json" "$ips_json" "$geo_on" > "$dir/custom.json"
  rate_rules > "$dir/rate.json"

  cf rulesets account-rulesets phases update http_request_firewall_custom --zone "$zone" --rules "@$dir/custom.json" "${DRY[@]}"
  cf rulesets account-rulesets phases update http_ratelimit --zone "$zone" --rules "@$dir/rate.json" "${DRY[@]}"
  cf zones settings edit always_use_https --zone "$zone" --body '{"value":"on"}' "${DRY[@]}"
  if [[ ${#api[@]} -eq 0 ]]; then
    cf zones settings edit browser_check --zone "$zone" --body '{"value":"on"}' "${DRY[@]}"
  else
    echo "Browser Integrity Check: skipped (zone has API hosts; it cannot be scoped to a host)."
  fi
  if [[ "$redirects" != skip ]]; then
    cf rulesets account-rulesets phases update http_request_dynamic_redirect --zone "$zone" --rules "@$dir/redirect.json" "${DRY[@]}"
    if [[ $APPLY -eq 1 ]]; then
      get_phase http_request_dynamic_redirect "$zone" "$dir/redirect-after.json"
      if [[ "$(redirect_shape "$dir/redirect-after.json")" == "$(redirect_shape "$dir/redirect.json")" ]]; then
        echo "Read-back http_request_dynamic_redirect: OK"
      else
        echo "Read-back http_request_dynamic_redirect: MISMATCH" >&2; return 1
      fi
    fi
  fi
  if [[ ${#api[@]} -eq 0 && ${#wp[@]} -eq 0 ]]; then
    # Cloudflare rejects fight_mode=true when JavaScript detections are disabled.
    cf bot-management update --zone "$zone" --enable-js --fight-mode "${DRY[@]}"
    if [[ $APPLY -eq 1 ]]; then
      cf bot-management get --zone "$zone" > "$dir/bot-after.json"
      if jq -e '(.result // .) | .fight_mode == true and .enable_js == true' "$dir/bot-after.json" >/dev/null; then
        echo "Read-back Bot Fight Mode and JavaScript detections: OK"
      else
        echo "Read-back Bot Fight Mode and JavaScript detections: MISMATCH" >&2; return 1
      fi
    fi
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
