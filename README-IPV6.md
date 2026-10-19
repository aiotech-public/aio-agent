# IPv6 on the agent host

Goal: an agent host can accept IPv6 connections natively (Cloudflare reaching the origin over IPv6), while the agent
keeps talking to the backend over IPv4. Nothing changes for hosts without a public IPv6 address.

## How it works
- `docker-compose.yml`: the compose network has `enable_ipv6: ${AIO_ENABLE_IPV6:-false}`; nginx mounts
  `${AIO_STREAM_DIR:-volumes/nginx/stream.d}` (listeners on `[::]`) and `volumes/nginx/stream-v4.d` is the IPv4-only
  fallback. Both values live in the per-host `.env` (not in git).
- `ipv6-prepare.sh` writes `.env` and `state/ipv6.prom` (node-exporter textfile metrics):
  - `prepare` (from `aio.service` on every start): on a first install picks IPv6 on/off before the first `up`;
    on a kernel without IPv6 switches nginx to the IPv4-only listeners.
  - `run` (from `autopull.sh` every minute): `prepare` + metrics + the one-off migration below.
- Migration of an already running host = recreate the compose network with IPv6 (`down`, `up -d --pull never`,
  a few seconds of downtime). It only happens while the file `ipv6-migration.flag` exists in the repo, once per host
  in its own minute of the day (spread by hostname), and only on eligible hosts: kernel IPv6, Docker >= 27, ip6tables.
  If the health check fails afterwards the host rolls back to IPv4 and writes `state/ipv6-migration.failed`
  (never retried automatically).

## Metrics (node-exporter, `aio_agent_ipv6_*`)
`state{pending|ineligible|switched|migrated|failed}`, `eligible`, `network`, `host_global{addr}`, `dnat`, `ready`
(= network IPv6 and a global IPv6 address on the host), `aio_agent_host_info{docker,compose,kernel_ipv6,ip6tables}`.

## Manual use
- Migrate now: `./ipv6-prepare.sh migrate --force`
- Back to IPv4: set `AIO_ENABLE_IPV6=false` in `.env`, then `docker-compose --profile '*' down && docker-compose --profile main up -d`
- Retry after a failed migration: remove `state/ipv6-migration.failed`
- Log: `/var/log/aio-ipv6.log`
