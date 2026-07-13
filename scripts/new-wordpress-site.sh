#!/usr/bin/env bash
# Generate a per-site env block (strong random passwords) to paste into Dokploy.
# The compose file itself is identical for every site (templates/wordpress.compose.yml).
#
# Usage:  scripts/new-wordpress-site.sh example.com
# Output: sites/<domain>/dokploy.env   (gitignored — contains secrets)
#         sites/<domain>/docker-compose.yml  (copy of the canonical stack)
set -euo pipefail

domain="${1:-}"
if [[ -z "$domain" ]]; then
  echo "Usage: $0 <domain>   e.g. $0 example.com" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_root/templates/wordpress.compose.yml"
out_dir="$repo_root/sites/$domain"
mkdir -p "$out_dir"

gen_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }

db_pass="$(gen_secret)"
root_pass="$(gen_secret)"

cat > "$out_dir/dokploy.env" <<EOF
SITE_DOMAIN=$domain
WP_DB_PASSWORD=$db_pass
WP_DB_ROOT_PASSWORD=$root_pass
EOF
chmod 600 "$out_dir/dokploy.env"
cp "$template" "$out_dir/docker-compose.yml"

cat <<EOF

✅ Generated site scaffold for: $domain
   $out_dir/dokploy.env            (secrets — keep private, gitignored)
   $out_dir/docker-compose.yml     (paste into Dokploy Compose editor)

Next steps in Dokploy:
  1. Create → Compose service (type: Docker Compose), server = your DO VPS.
  2. Enable "Isolated Deployments".
  3. Paste docker-compose.yml into the editor.
  4. Environment tab → paste the contents of dokploy.env.
  5. Domain tab → host=$domain, service=wordpress, port=80, HTTPS + Let's Encrypt.
  6. Point DNS A record for $domain → VPS public IP (DNS-only / grey cloud).
  7. Deploy, finish WP install, then set up UpdraftPlus for site backups.
  8. Run a manual Dokploy System Backup → R2 afterward.
EOF
