#!/bin/sh
root=${VPNTOGGLE_ROOT:-}
if [ -z "$root" ] && [ "$(id -u)" != 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi
tries=${VPNTOGGLE_UNLOAD_TRIES:-75}

loaded() { launchctl print system/local.vpn-toggle > /dev/null 2>&1; }

if [ -z "${VPNTOGGLE_SKIP_LAUNCHCTL:-}" ]; then
  if loaded; then
    launchctl bootout system/local.vpn-toggle 2>/dev/null || true
    i=0
    while loaded && [ $i -lt "$tries" ]; do sleep 0.2; i=$((i + 1)); done
    if loaded; then
      echo "local.vpn-toggle is still loaded nothing removed" >&2
      exit 1
    fi
  fi
  [ -f "$root/usr/local/sbin/vpn-toggle-watch.sh" ] && sh "$root/usr/local/sbin/vpn-toggle-watch.sh" --resume
fi
rm -f "$root/Library/LaunchDaemons/local.vpn-toggle.plist" "$root/usr/local/sbin/vpn-toggle-watch.sh" "$root/var/log/vpn-toggle.log"
echo "removed"
