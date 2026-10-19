#!/bin/bash
# IPv6 readiness for the agent host (see README-IPV6.md).
#   prepare  - per-host switches in .env (first install / kernel without IPv6) + metrics   [aio.service ExecStartPre]
#   run      - prepare + one-off network migration (only while ipv6-migration.flag exists) + metrics   [autopull.sh]
#   metrics  - metrics only
#   migrate --force - migrate this host now, ignoring the flag and the time slot (manual use)
# Never fails the caller: always exits 0. Migration runs as soon as the flag is present (no time slots).
set -u
# cron jobs may run with a minimal PATH (Debian: /usr/bin:/bin); ip6tables lives in /usr/sbin
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
cd "$(dirname "$0")" || exit 0

ENV_FILE=.env
STATE_DIR=state
PROM="$STATE_DIR/ipv6.prom"
FAILED_MARK="$STATE_DIR/ipv6-migration.failed"
FLAG=ipv6-migration.flag
LOG=/var/log/aio-ipv6.log
V4_DIR=volumes/nginx/stream-v4.d
mkdir -p "$STATE_DIR"

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }
env_set() {
  touch "$ENV_FILE"
  if grep -qE "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}

collect() {
  kernel_v6=0; [ -e /proc/net/if_inet6 ] && kernel_v6=1
  docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 0)
  docker_major=${docker_ver%%.*}; [[ "$docker_major" =~ ^[0-9]+$ ]] || docker_major=0
  compose_ver=$(docker-compose version --short 2>/dev/null || echo unknown)
  ip6t=0; ip6tables -S >/dev/null 2>&1 && ip6t=1
  host_v6_addr=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/temporary|deprecated/ {print $2; exit}' | cut -d/ -f1)
  host_v6_route=0; [ -n "$(ip -6 route show default 2>/dev/null)" ] && host_v6_route=1
  host_global=0; [ -n "$host_v6_addr" ] && [ "$host_v6_route" = 1 ] && host_global=1
  net_v6=$(docker network inspect aio-agent_default --format '{{.EnableIPv6}}' 2>/dev/null || echo missing)
  net_exists=1; [ "$net_v6" = missing ] && net_exists=0
  # published :80 mapped to a container IPv6 by the kernel (no userland proxy)
  dnat_v6=0; ip6tables -t nat -S DOCKER 2>/dev/null | grep -q -- '--dport 80 .*-j DNAT' && dnat_v6=1
  compose_major=${compose_ver%%.*}; [[ "$compose_major" =~ ^[0-9]+$ ]] || compose_major=0
  eligible=0; [ "$kernel_v6" = 1 ] && [ "$docker_major" -ge 27 ] && [ "$ip6t" = 1 ] && [ "$compose_major" -ge 2 ] && eligible=1
  sw=$(env_get AIO_ENABLE_IPV6)
  state=pending
  if [ -f "$FAILED_MARK" ]; then state=failed
  elif [ "$sw" = true ] && [ "$net_v6" = true ]; then state=migrated
  elif [ "$sw" = true ]; then state=switched          # .env says yes, network not recreated yet
  elif [ "$eligible" = 0 ]; then state=ineligible
  fi
  ready=0; [ "$net_v6" = true ] && [ "$host_global" = 1 ] && ready=1
}

write_metrics() {
  collect
  local tmp="$PROM.tmp" s v
  {
    echo "# HELP aio_agent_ipv6_state IPv6 migration state of this host (1 for the active state)."
    echo "# TYPE aio_agent_ipv6_state gauge"
    for s in pending ineligible switched migrated failed; do v=0; [ "$s" = "$state" ] && v=1; echo "aio_agent_ipv6_state{state=\"$s\"} $v"; done
    echo "# HELP aio_agent_ipv6_eligible Host can run an IPv6-enabled compose network (kernel IPv6, Docker >= 27, ip6tables, compose v2)."
    echo "# TYPE aio_agent_ipv6_eligible gauge"; echo "aio_agent_ipv6_eligible $eligible"
    echo "# HELP aio_agent_ipv6_network Compose network has IPv6 enabled."
    echo "# TYPE aio_agent_ipv6_network gauge"; v=0; [ "$net_v6" = true ] && v=1; echo "aio_agent_ipv6_network $v"
    echo "# HELP aio_agent_ipv6_host_global Host has a global IPv6 address and a default IPv6 route."
    echo "# TYPE aio_agent_ipv6_host_global gauge"; echo "aio_agent_ipv6_host_global{addr=\"$host_v6_addr\"} $host_global"
    echo "# HELP aio_agent_ipv6_dnat Published port 80 is mapped to a container IPv6 address by ip6tables."
    echo "# TYPE aio_agent_ipv6_dnat gauge"; echo "aio_agent_ipv6_dnat $dnat_v6"
    echo "# HELP aio_agent_ipv6_ready Host can serve IPv6 traffic natively (network IPv6 + global address)."
    echo "# TYPE aio_agent_ipv6_ready gauge"; echo "aio_agent_ipv6_ready $ready"
    echo "# HELP aio_agent_host_info Docker / compose versions and IPv6 facts of the host."
    echo "# TYPE aio_agent_host_info gauge"; echo "aio_agent_host_info{docker=\"$docker_ver\",compose=\"$compose_ver\",kernel_ipv6=\"$kernel_v6\",ip6tables=\"$ip6t\"} 1"
    echo "# TYPE aio_agent_ipv6_last_run_timestamp_seconds gauge"; echo "aio_agent_ipv6_last_run_timestamp_seconds $(date +%s)"
  } > "$tmp" && mv -f "$tmp" "$PROM"
}

healthcheck() {
  local st; st=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://localhost/healthcheck.yml 2>/dev/null)
  [ -n "$st" ] && [ "$st" != 000 ] && [ "$(docker inspect -f '{{.State.Running}}' aio-agent 2>/dev/null)" = true ]
}

prepare() {
  collect
  # kernel without IPv6: keep IPv4-only nginx listeners (takes effect when the nginx container is recreated)
  if [ "$kernel_v6" = 0 ] && [ "$(env_get AIO_STREAM_DIR)" != "$V4_DIR" ]; then
    env_set AIO_STREAM_DIR "$V4_DIR"; env_set AIO_ENABLE_IPV6 false
    log "kernel without IPv6: AIO_STREAM_DIR=$V4_DIR"
    [ "$net_exists" = 1 ] && docker-compose --profile main up -d --pull never >> "$LOG" 2>&1
  fi
  # first install (no network yet): decide once, before the first 'up'
  if [ "$net_exists" = 0 ] && [ -z "$sw" ]; then
    if [ "$eligible" = 1 ]; then env_set AIO_ENABLE_IPV6 true; log "first install, eligible: AIO_ENABLE_IPV6=true"
    else env_set AIO_ENABLE_IPV6 false; log "first install, not eligible (kernel_ipv6=$kernel_v6 docker=$docker_ver ip6tables=$ip6t)"; fi
  fi
}

migrate() {
  local force=${1:-}
  collect
  [ "$force" = --force ] || [ -f "$FLAG" ] || return 0
  [ "$state" = pending ] || return 0
  log "migration start (docker=$docker_ver compose=$compose_ver host_global=$host_global)"
  env_set AIO_ENABLE_IPV6 true
  docker-compose --profile '*' down >> "$LOG" 2>&1
  if docker-compose --profile main up -d --pull never >> "$LOG" 2>&1 && sleep 5 && healthcheck \
     && [ "$(docker network inspect aio-agent_default --format '{{.EnableIPv6}}' 2>/dev/null)" = true ]; then
    log "migration OK"; echo "IPV6 MIGRATED $(date)" >> /var/log/git.log
  else
    log "migration FAILED, rolling back to IPv4"
    env_set AIO_ENABLE_IPV6 false
    docker-compose --profile '*' down >> "$LOG" 2>&1
    docker-compose --profile main up -d --pull never >> "$LOG" 2>&1 || docker-compose --profile main up -d >> "$LOG" 2>&1
    date -u +%FT%TZ > "$FAILED_MARK"
    echo "IPV6 MIGRATION FAILED $(date)" >> /var/log/git.log
  fi
}

case "${1:-prepare}" in
  prepare) prepare ;;
  run)     prepare; migrate ;;
  migrate) migrate "${2:-}" ;;
  metrics) ;;
esac
write_metrics
exit 0
