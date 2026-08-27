# WordPress Stack Tuning

Reference for [`templates/wordpress.compose.yml`](../../templates/wordpress.compose.yml).
The compose file carries no comments on purpose. Everything that explains it lives here.

Every site pastes the same compose file. You change a site's resources by setting
environment variables on that one Dokploy service, never by editing the file.

---

## 1. Tunables

All variables have defaults. An empty Environment tab deploys the defaults, so you
only set the ones you want to change.

### WordPress container

| Variable | Default | What it controls |
|---|---|---|
| `WP_MEM_LIMIT` | `384m` | Hard RAM ceiling. The container is killed inside its own cgroup if it exceeds this. |
| `WP_MEMSWAP_LIMIT` | `768m` | RAM **plus** swap combined. The default grants 384m of swap on top of the limit above. |
| `WP_MEM_RESERVATION` | `128m` | Soft floor. The kernel tries to leave this much when the host is under pressure. |
| `WP_CPUS` | `1.0` | CPU ceiling in cores. Fractional values are allowed. |
| `WP_PIDS_LIMIT` | `128` | Maximum processes and threads. Stops a fork loop. |
| `WP_MAX_WORKERS` | `8` | Apache `MaxRequestWorkers` and `ServerLimit`. The concurrency ceiling. |
| `WP_START_SERVERS` | `2` | Workers forked at startup. |
| `WP_MIN_SPARE` | `2` | Idle workers kept ready. |
| `WP_MAX_SPARE` | `4` | Idle workers kept before Apache reaps them. |
| `WP_MAX_REQUESTS_PER_CHILD` | `500` | Requests a worker serves before Apache recycles it. |
| `WP_TIMEOUT` | `60` | Seconds Apache waits on a stalled client. |
| `WP_KEEPALIVE_TIMEOUT` | `5` | Seconds a worker holds an idle keep-alive connection. |

### Database container

| Variable | Default | What it controls |
|---|---|---|
| `DB_MEM_LIMIT` | `288m` | Hard RAM ceiling for MariaDB. |
| `DB_MEMSWAP_LIMIT` | `416m` | RAM plus swap. The default grants a 128m swap cushion. |
| `DB_MEM_RESERVATION` | `96m` | Soft floor. |
| `DB_CPUS` | `0.75` | CPU ceiling in cores. |
| `DB_PIDS_LIMIT` | `128` | Maximum processes and threads. |
| `DB_BUFFER_POOL` | `128M` | InnoDB buffer pool. The largest single consumer of DB memory. |
| `DB_MAX_CONNECTIONS` | `20` | Maximum simultaneous client connections. |

### Both containers

| Variable | Default | What it controls |
|---|---|---|
| `LOG_MAX_SIZE` | `10m` | Size of one JSON log file before rotation. |
| `LOG_MAX_FILE` | `3` | Rotated log files kept per container. |

---

## 2. Setting them in Dokploy

1. Open the Compose service for the site.
2. Go to the **Environment** tab.
3. Add only the variables you want to change, one per line, as `NAME=value`.
4. Redeploy.

Example, for a site that outgrew the defaults:

```
WP_MEM_LIMIT=768m
WP_MEMSWAP_LIMIT=1536m
WP_MEM_RESERVATION=256m
WP_MAX_WORKERS=16
WP_CPUS=2.0
DB_MEM_LIMIT=576m
DB_MEMSWAP_LIMIT=704m
DB_BUFFER_POOL=256M
DB_MAX_CONNECTIONS=40
DB_CPUS=1.5
```

The `SERVICE_*` database credentials are separate. Dokploy generates those per
service and you never set them by hand. See
[`templates/wordpress.env.example`](../../templates/wordpress.env.example).

---

## 3. Rules you must not break

Three relationships hold the stack together. Break one and the site fails in a way
the defaults were designed to prevent.

**`DB_MAX_CONNECTIONS` must stay at or above `WP_MAX_WORKERS`.** Each Apache worker
can hold one database connection. If workers outnumber connections, a traffic burst
returns "Too many connections" instead of queueing. Raise both together.

**`*_MEMSWAP_LIMIT` must stay at or above the matching `*_MEM_LIMIT`.** Docker
rejects the container outright otherwise. Setting them equal disables swap for that
container.

**`DB_MEM_LIMIT` must grow with `DB_BUFFER_POOL`.** The pool is allocated up front.
A pool larger than the limit gets the container killed the first time the pool fills.
Use the formula in section 5.

---

## 4. Why the WordPress limits are what they are

The `wordpress:*-apache` image runs mod_php under Apache's prefork MPM. It is not
php-fpm. Every concurrent request is a full Apache process with a PHP interpreter
inside it, roughly 20 to 30 MB once warm.

Apache ships with `MaxRequestWorkers 150`, sized for a far larger machine. Left
alone, a traffic burst forks toward that number, blows past the memory limit, and
the cgroup OOM killer starts culling workers in a loop. The site stops responding
and does not recover on its own.

Capping the workers turns that failure into a queue. Requests wait a few hundred
milliseconds. The limit still protects the host either way. The cap is what makes
hitting it graceful.

A conservative estimate for the ceiling:

```
WP_MEM_LIMIT ≈ (WP_MAX_WORKERS × 30M) + 128M OPcache + 32M headroom
```

At the defaults that predicts about 400M against a 384m limit. Real use runs far
below it, because workers share copy-on-write pages after forking and OPcache is
never fully resident. A measured load test with 40 concurrent clients held at
48 MiB of the 384m budget. Treat the formula as the safe upper bound and the
measurement as the typical case.

The swap grant matters here. `WP_MEMSWAP_LIMIT` at double the memory limit lets an
idle worker page out under pressure. That costs latency on one request, which beats
being killed part way through serving it.

### Apache config delivery

The tuning ships inside the compose file as a top-level `configs` block with inline
`content`. Docker Compose writes it into the container as a read-only file at
`/etc/apache2/conf-enabled/zz-resource-limits.conf`.

There is nothing to mount by hand and no ordering trap. Earlier revisions of this
stack needed a Dokploy File Mount created before the first deploy, because Docker
creates a directory at a bind-mount path when the source file is missing, and Apache
then refuses to start. The `configs` block removes that failure mode.

Apache reads `mods-enabled/*.conf` before `conf-enabled/*.conf`, so this file
overrides the distro's own MPM config on load order alone. The `zz-` prefix only
keeps it last within `conf-enabled/`.

This requires Docker Compose v2.23 or newer.

---

## 5. Why the database limits are what they are

MariaDB's memory is dominated by the buffer pool, its own baseline, and the
per-connection buffers. Size the limit from the parts:

```
DB_MEM_LIMIT ≈ (DB_BUFFER_POOL × 1.1) + 80M baseline + (DB_MAX_CONNECTIONS × 2.75M)
```

At the defaults that comes to roughly 276M against a 288m limit. The margin is thin
by design, and that thin margin is the reason for the swap cushion described below.

The per-connection figure is the sum of `sort-buffer-size`, `join-buffer-size`,
`read-buffer-size`, and `read-rnd-buffer-size`. Each connection can allocate all of
them. That is why `DB_MAX_CONNECTIONS` stays low. Twenty connections at 2.75M each is
the difference between a predictable ceiling and a surprise.

The buffer pool only has to hold the working set, not the whole database. Compare it
against lifetime block reads before raising it. A pool larger than the dataset spends
RAM you do not have on a problem you do not have.

### The swap cushion

`DB_MEMSWAP_LIMIT` defaults to `416m`, which is the 288m limit plus 128m of swap.

An earlier revision set this equal to `DB_MEM_LIMIT`, which disabled swap entirely.
The reasoning was that swapped InnoDB pages turn every query into a disk seek, and a
database that slow reads as an outage. That reasoning still holds for the buffer
pool. It does not hold for a transient spike.

With swap off, a one-off allocation above the limit kills the database process. A
backup run, a large `mysqldump`, a plugin running an unindexed join, or a slow import
can all produce that spike. Killing the database takes the site down.

The 128m cushion absorbs the spike instead. It is deliberately small. It is not
enough for the buffer pool to live in swap, so normal query performance is unchanged.
On a host with `vm.swappiness=10` the kernel reclaims page cache before it touches
anonymous memory, so the cushion stays unused until something genuinely overruns.

Raise `DB_MEM_LIMIT` if the cushion is in constant use. The cushion is an airbag, not
a seat.

### Settings deliberately not set

`innodb-flush-method` already defaults to `O_DIRECT` on this image, so the kernel
page cache does not hold a second copy of every buffered InnoDB page. The flag is
deprecated on MariaDB 12 and logs a warning. Do not add it back.

`performance-schema` also defaults off, but it is pinned explicitly because turning
it on costs tens of megabytes and this container has none to spare.

`innodb-flush-log-at-trx-commit` stays at the default of `1`. Every commit is flushed
and synced, so a host crash loses nothing. Setting it to `2` cuts disk writes at the
cost of up to one second of transactions on a crash.

---

## 6. Why the rest of the file is there

**`depends_on: condition: service_healthy`** stops WordPress from starting against a
database that is still initialising. Without it the first boot can log connection
errors before it settles.

**`start_period` on both healthchecks** gives each service a grace window on first
boot, so slow initial setup does not count as health failures and trigger a restart.

**`logging` with rotation** bounds disk use per container. The host-level rotation in
`setup-remote-vps.sh` covers this too, but the per-service setting survives a Dokploy
rewrite of `/etc/docker/daemon.json`.

**`pids_limit`** stops a runaway fork from exhausting the host process table, which
is a separate failure mode from running out of memory.

**Named volumes** for `wp_content` and `db_data`. Relative bind mounts get wiped on
redeploy. Dokploy names them `{appName}_{volumeName}`, which matters when restoring.

**Memory limits at all** are the reason a bad site cannot take the host down. A
container that overruns its limit dies inside its own cgroup, restarts, and nothing
else on the box notices. With no limit the kernel picks the victim by `oom_score`
instead, and can kill anything, including the database of an unrelated site.

---

## 7. Verifying a deploy

Run these against a deployed site. Replace the container name with the real one from
`docker ps`.

Confirm the Apache config arrived and the worker cap is live. Expect one master plus
`WP_MAX_WORKERS` workers, so 9 at the defaults:

```bash
docker exec <wordpress-container> ls -l /etc/apache2/conf-enabled/zz-resource-limits.conf
docker exec <wordpress-container> sh -c 'ps -eo comm | grep -c apache2'
```

If that count is closer to 150 than to 9, the `configs` block did not reach the
container. Check the Docker Compose version on the host.

Confirm the cgroup limits applied. The second value is memory plus swap:

```bash
docker exec <wordpress-container> cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max
```

Confirm the database took its settings:

```bash
docker exec <db-container> mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e \
  'SELECT VARIABLE_NAME, VARIABLE_VALUE FROM information_schema.GLOBAL_VARIABLES
   WHERE VARIABLE_NAME IN ("innodb_buffer_pool_size","max_connections");'
```

Watch headroom under real traffic:

```bash
docker stats --no-stream
```

---

## 8. Troubleshooting

**The site returns 503 or hangs under load.** Requests are queueing behind
`WP_MAX_WORKERS`. Confirm with `docker stats` that memory is not the constraint, then
raise `WP_MAX_WORKERS` and `DB_MAX_CONNECTIONS` together, and raise `WP_MEM_LIMIT`
using the formula in section 4.

**The container restarts in a loop.** It is hitting its memory limit. Check
`docker inspect <container> --format '{{.State.OOMKilled}}'`. For the database, work
through the formula in section 5 before raising anything.

**"Too many connections" in the WordPress error log.** `DB_MAX_CONNECTIONS` dropped
below `WP_MAX_WORKERS`. Raise it back.

**The database is slow after a spike.** Check whether it is sitting in swap with
`docker exec <db-container> cat /sys/fs/cgroup/memory.swap.current`. A non-zero value
that stays high means `DB_MEM_LIMIT` is too small for the workload.

**Apache runs 150 workers despite the config.** The `configs` block was stripped or
unsupported. Verify `docker compose version` on the host is 2.23 or newer.
