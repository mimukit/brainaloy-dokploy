# Postgres with a Cloudflare Tunnel

`templates/postgres-cf-tunnel.compose.yml` runs production Postgres 18 and a `cloudflared` connector on one private Docker network. Hyperdrive reaches the database through the tunnel at `pg-production:5432`. The database publishes no public port.

```
API Worker ──env.HYPERDRIVE──▶ Hyperdrive ──VPC Service (tcp)──▶ cloudflared ──db network──▶ pg-production:5432
Mac ──Tailscale──▶ 100.120.15.77:5434 ──▶ postgres:5432
```

## Deploy

### 1. Create a new tunnel

1. Open `https://dash.cloudflare.com/?to=/:account/workers/vpc/tunnels`.
2. Create a tunnel named `brainaloy-postgres-production`. Do not reuse `brainaloy-vps-cf-tunnel`, because Cloudflare spreads traffic across every connector of a tunnel, and the egress connectors cannot resolve `pg-production`.
3. Copy the tunnel ID and the `eyJ...` token.

### 2. Run the stack in Dokploy

1. Create a Compose app, and paste the template.
2. In the environment tab, set the values below.
3. Add no domain.
4. Deploy the app.
5. Check the `cloudflared` logs for `Registered tunnel connection`.

| Variable | Value |
|---|---|
| `POSTGRES_PASSWORD` | A long random value, for example from `openssl rand -hex 32`. Required. |
| `TUNNEL_TOKEN` | The `eyJ...` token. Required. |
| `POSTGRES_DB` | Database name. Default `app`. |
| `POSTGRES_USER` | Superuser name. Default `postgres`. |
| `PG_BIND` | `100.120.15.77` for Mac access over Tailscale. Default `127.0.0.1`. Never `0.0.0.0`. |
| `PG_HOST_PORT` | Host port. Default `5434`. |

The current `infra-postgres-production` app already holds host port `5434`. Stop it or set another `PG_HOST_PORT` before you deploy. Move the data with `pg_dump` and `pg_restore`, because the old volume uses another Postgres version layout.

A bind to `100.120.15.77` fails if `tailscaled` is not up when Docker starts the container. After a reboot, check that Postgres is running, and redeploy if the port bind failed.

### 3. Create the VPC Service and Hyperdrive

Run these on your Mac after `npx wrangler login`:

```sh
npx wrangler@4.132.0 vpc service create db-postgres-production \
  --type tcp --tunnel-id <tunnel id> \
  --hostname pg-production --tcp-port 5432 --app-protocol postgresql

npx wrangler@4.132.0 hyperdrive create brainaloy-postgres-production \
  --service-id <vpc service id> \
  --database <db> --user <api role> --password '<api role password>'
```

`cloudflared` resolves `pg-production` with Docker DNS on the `db` network. This path is not tested yet. If the Hyperdrive create fails with a connection error, check the `cloudflared` logs first.

### 4. Bind it in the API Worker

```jsonc
"compatibility_flags": ["nodejs_compat"],
"hyperdrive": [
  { "binding": "HYPERDRIVE", "id": "<hyperdrive id>" }
]
```

Add the entry to every named environment. In code, connect with `env.HYPERDRIVE.connectionString`. For `wrangler dev`, set `CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_HYPERDRIVE=postgres://<user>:<password>@100.120.15.77:5434/<db>` in a git-ignored file.

## Database role for the API

Do not give Hyperdrive the superuser. Create a role with only the rights the API needs:

```sql
CREATE ROLE api LOGIN PASSWORD '<password>';
GRANT CONNECT ON DATABASE app TO api;
GRANT USAGE ON SCHEMA public TO api;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO api;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO api;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO api;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO api;
```

Run `CREATE EXTENSION pg_stat_statements;` once as the superuser to read query statistics.

## Tuning

The defaults fit a 2 GB container on the VPS: 6 vCPU, 12 GB RAM, SSD storage. On 2026-09-17 the host had about 2.6 GB available, so do not raise `PG_MEM_LIMIT` without freeing memory first.

| Setting | Value | Reason |
|---|---|---|
| `shared_buffers` | 512MB | About 25% of the container memory. |
| `effective_cache_size` | 1536MB | About 75% of the container memory. It is a planner hint and allocates nothing. |
| `work_mem` | 8MB | Per sort or hash node. 100 connections with several nodes each must stay under the limit. |
| `maintenance_work_mem` | 128MB | Faster `VACUUM` and index builds. |
| `random_page_cost`, `effective_io_concurrency` | 1.1, 200 | SSD storage. |
| `io_method`, `io_workers` | worker, 3 | Postgres 18 async I/O. `io_uring` is often blocked by the Docker seccomp profile. |
| `wal_compression` | zstd | Smaller WAL for less disk write. |
| `max_wal_size` | 2GB | Fewer forced checkpoints under write load. |
| autovacuum scale factors | 0.05, 0.02 | Vacuum and analyze large tables sooner. |
| `idle_in_transaction_session_timeout` | 5min | Stop a stuck transaction from holding locks and blocking vacuum. |
| `log_min_duration_statement` | 500 ms | Log slow queries. Change it with `PG_LOG_SLOW_MS`. |

To change the memory size, set `PG_MEM_LIMIT`, `PG_SHARED_BUFFERS` (25%) and `PG_EFFECTIVE_CACHE_SIZE` (75%) together, then redeploy.

Hyperdrive pools connections, so the API does not need a large `max_connections`. Hyperdrive caches `SELECT` results for 60 s by default. Add `--caching-disabled` to the create command if the API needs fresh reads.

## Backups

This stack does not back up the database. Configure a backup for the `pg_data` volume, or schedule `pg_dump` in Dokploy, before you put production data in it. See [RESTORE.md](RESTORE.md).
