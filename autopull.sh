#!/bin/bash
cd $PWD
# One run at a time: cron fires every minute; an update or the IPv6 migration may take longer.
# A run stuck for more than 20 minutes is killed (process group) so that the health check keeps working.
LOCK=/var/lock/aio-autopull.lock
if command -v flock >/dev/null 2>&1 && [ -d /var/lock ] && [ -w /var/lock ]; then
  exec 9>>"$LOCK"
  if ! flock -n 9; then
    holder=$(head -1 "$LOCK" 2>/dev/null)
    age=$(ps -o etimes= -p "$holder" 2>/dev/null | tr -d ' ')
    if [[ "$holder" =~ ^[0-9]+$ ]] && [[ "$age" =~ ^[0-9]+$ ]] && [ "$age" -gt 1200 ]; then
      pgid=$(ps -o pgid= -p "$holder" 2>/dev/null | tr -d ' ')
      echo "STALE AUTOPULL $holder (${age}s) killed `date`" >> /var/log/git.log
      [ -n "$pgid" ] && kill -9 -- "-$pgid" 2>/dev/null; sleep 1
      flock -n 9 || exit 0
    else
      exit 0
    fi
  fi
  echo $$ > "$LOCK"
fi
# per-host switches (.env is also read by docker-compose for interpolation; only known keys are used here)
AIO_STREAM_DIR=$(grep -E '^AIO_STREAM_DIR=' .env 2>/dev/null | tail -1 | cut -d= -f2-)
# Health check: nginx answers on :80 (any HTTP code; 000 = no connection) and the agent container is running.
# Do not depend on a specific path/status code: the agent serves every path as a regular site request.
proxy_status=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://localhost/healthcheck.yml 2>/dev/null)
agent_running=$(docker inspect -f '{{.State.Running}}' aio-agent 2>/dev/null)
conf_path="${AIO_STREAM_DIR:-volumes/nginx/stream.d}"

# Start grace: right after a (re)start of the stack (selfhelp, IPv6 migration, update) nginx and the agent are
# not answering yet. A failed health check within START_GRACE seconds of the agent container start is not an
# outage - skip this run. Otherwise the next cron minute turns one restart into a second selfhelp, and
# ipv6-prepare.sh counts two in a row as a restart loop and switches the host back to IPv4.
START_GRACE=90
if [[ -z "$proxy_status" || "$proxy_status" == "000" || "$agent_running" != "true" ]]; then
  started_at=$(docker inspect -f '{{.State.StartedAt}}' aio-agent 2>/dev/null)
  started_ts=$(date -d "$started_at" +%s 2>/dev/null || echo 0)
  agent_age=$(( $(date +%s) - started_ts ))
  if [ "$started_ts" -gt 0 ] && [ "$agent_age" -ge 0 ] && [ "$agent_age" -lt "$START_GRACE" ]; then
    echo "STACK STARTING (agent up ${agent_age}s, health ${proxy_status:-none}) skip `date`" >> /var/log/git.log
    exit 0
  fi
fi

## selfhelp
if [[ -z "$proxy_status" || "$proxy_status" == "000" || "$agent_running" != "true" ]]; then
  git add . && git stash 
  git pull
  [ -x ./ipv6-prepare.sh ] && ./ipv6-prepare.sh selfhelp
  systemctl restart aio.service
  ## notification
  exit 1
fi

##0-downtime update agent
pull_output=$(git pull 2>/dev/null); pull_rc=$?
pull_result=$(printf '%s\n' "$pull_output" | base64)
local_commit_hash=$(git rev-parse --short HEAD)

if [[ $pull_rc -ne 0 ]]; then
  echo "GIT PULL FAILED `date`" >> /var/log/git.log
elif [[ $pull_result != "QWxyZWFkeSB1cCB0byBkYXRlLgo=" ]]; then
  echo "NEW COMMIT $local_commit_hash `date`" >> /var/log/git.log
  docker-compose --profile spare-agent up -d
  sleep 3 
  mv $conf_path/regular.conf $conf_path/regular && mv $conf_path/spare $conf_path/spare.conf && docker exec proxy-nginx nginx -s reload
  docker-compose --profile main up -d 
  sleep 3
  mv $conf_path/regular $conf_path/regular.conf && mv $conf_path/spare.conf $conf_path/spare && docker exec proxy-nginx nginx -s reload
  sleep 3
  docker-compose --profile spare-agent down
  
  ## old image cleanup
  docker image prune -af --filter "until=168h" >> /var/log/aio-docker-prune.log 2>&1 || true 
  
  echo "APP RESTARTED `date`" >> /var/log/git.log
  echo "SUCCESS UPDATE $local_commit_hash `date`" >> /var/log/git.log
fi

## IPv6 readiness: per-host switches + metrics every run; network migration only while ipv6-migration.flag exists
[ -x ./ipv6-prepare.sh ] && ./ipv6-prepare.sh run
