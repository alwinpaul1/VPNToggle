#!/bin/sh

AGENT=acnvmagent
LOG=/var/log/vpn-toggle.log
LOG_MAX_KB=64

log() {
  if [ -f "$LOG" ] && [ "$(du -k "$LOG" | cut -f1)" -gt "$LOG_MAX_KB" ]; then
    : > "$LOG"
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

agents() {
  for p in $(pgrep -x "$AGENT"); do
    path=$(ps -o comm= -p "$p" 2>/dev/null)
    [ "${path##*/}" = "$AGENT" ] && echo "$p"
  done
}

stopped() {
  [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" = "T" ]
}

resume_all() {
  for p in $(agents); do kill -CONT "$p" 2>/dev/null; done
}

case "${1:-}" in
  --list)
    for p in $(agents); do
      if stopped "$p"; then echo "$p stopped none"; else echo "$p running stop"; fi
    done
    exit 0
    ;;
  --resume)
    resume_all
    exit 0
    ;;
  "")
    ;;
  *)
    echo "usage: vpn-toggle-watch.sh [--list | --resume]" >&2
    exit 2
    ;;
esac

on_exit() {
  resume_all
  log "watcher stopped; agent resumed"
  exit 0
}
trap on_exit TERM INT

log "watcher started; $AGENT kept suspended"

while :; do
  for p in $(agents); do
    if ! stopped "$p"; then
      kill -STOP "$p" 2>/dev/null && log "suspended $AGENT $p"
    fi
  done
  sleep 1
done
