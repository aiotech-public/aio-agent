# IPv6 on the agent host

Goal: an agent host can accept IPv6 connections natively (Cloudflare reaching the origin over IPv6), while the agent
keeps talking to the backend over IPv4. Nothing changes for hosts without a public IPv6 address.

## How it works
- `docker-compose.yml`: the compose network has `enable_ipv6: ${AIO_ENABLE_IPV6:-false}`; nginx mounts
  `${AIO_STREAM_DIR:-volumes/nginx/stream.d}` (listeners on `[::]`) and `volumes/nginx/stream-v4.d` is the IPv4-only
  fallback. Both values live in the per-host `.env` (not in git).
- `ipv6-prepare.sh` writes `.env` and `state/ipv6.prom` (node-exporter textfile metrics):
  - `prepare`: on a first install (new hosts get it as `ExecStartPre` in `aio.service`) picks IPv6 on/off before the
    first `up`, after a dry-run `docker network create --ipv6`; on a kernel without IPv6 switches nginx to the IPv4-only
    listeners. Existing hosts run it from `autopull.sh`.
  - `run` (from `autopull.sh` every minute): `prepare` + metrics + the one-off migration below.
  - `selfhelp` (from `autopull.sh` when the stack is down, before `systemctl restart aio.service`): `prepare`, and if the
    restart loop repeats with IPv6 on, switches the host back to IPv4 and marks it failed.
- Migration of an already running host = recreate the compose network with IPv6 (`down`, `up -d --pull never`,
  a few seconds of downtime). It only happens while the file `ipv6-migration.flag` exists in the repo (remove the file to stop
  pending migrations), and only on eligible hosts: kernel IPv6, Docker >= 27, ip6tables, compose v2.
  The health check waits up to 60 s for the agent to answer (and starts `proxy-nginx` again if it lost the upstream
  race on the fresh network); if it fails the host rolls back to IPv4 and writes `state/ipv6-migration.failed` with
  the reason.
- Start grace (`autopull.sh`, `START_GRACE=90`): a failed health check within 90 s of the agent container start is
  not treated as an outage - the run is skipped (`STACK STARTING` in `/var/log/git.log`). Without it the cron minute
  after any restart produced a second selfhelp, which the breaker counted as a restart loop.
- Retry: while `ipv6-migration.retry` exists in the repo, `run` clears a `restart loop` failure once per host
  (`state/ipv6-retry.done`) and migrates again. Other failure reasons are never retried automatically.

## Metrics (node-exporter, `aio_agent_ipv6_*`)
`state{pending|ineligible|switched|migrated|failed}`, `eligible`, `network`, `host_global{addr}`, `dnat`, `ready`
(= network IPv6 and a global IPv6 address on the host), `aio_agent_host_info{docker,compose,kernel_ipv6,ip6tables}`.

## Manual use
- Migrate now: `./ipv6-prepare.sh migrate --force`
- Back to IPv4: set `AIO_ENABLE_IPV6=false` in `.env`, then `docker-compose --profile '*' down && docker-compose --profile main up -d`
- Retry after a failed migration: remove `state/ipv6-migration.failed`
- Log: `/var/log/aio-ipv6.log`
