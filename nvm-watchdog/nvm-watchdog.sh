#!/bin/sh
# Keeps Cisco's Network Visibility agent (acnvmagent) small.
# Run by launchd as root every 5 minutes. It restarts the agent when
#   - its memory passes CAP_MB, or
#   - this is the first run of a new day (the midnight restart).
# vpnagentd starts the agent again on its own; this script only checks that it did.

CAP_MB=400
STAMP=/var/db/nvm-watchdog.day
LOG=/var/log/nvm-watchdog.log
LOG_MAX_KB=64

log() {
  # Keep our own log from growing: start over once it passes LOG_MAX_KB.
  if [ -f "$LOG" ] && [ "$(du -k "$LOG" | cut -f1)" -gt "$LOG_MAX_KB" ]; then
    : > "$LOG"
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

pid=$(pgrep -x acnvmagent | head -1)
[ -z "$pid" ] && exit 0

rss_mb=$(( $(ps -o rss= -p "$pid" | tr -d ' ') / 1024 ))
today=$(date +%F)
last_day=$(cat "$STAMP" 2>/dev/null)

if [ "$rss_mb" -gt "$CAP_MB" ]; then
  reason="memory ${rss_mb} MB > ${CAP_MB} MB"
elif [ "$today" != "$last_day" ]; then
  reason="daily restart (${rss_mb} MB)"
else
  exit 0
fi

echo "$today" > "$STAMP"

kill -TERM "$pid" 2>/dev/null
i=0
while kill -0 "$pid" 2>/dev/null && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null

sleep 30
new=$(pgrep -x acnvmagent | head -1)
if [ -n "$new" ]; then
  log "restarted: $reason; new pid $new"
else
  log "restarted: $reason; NOT running again after 30 s (vpnagentd did not respawn it)"
fi
