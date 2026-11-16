#!/bin/sh
root=${VPNTOGGLE_ROOT:-}
if [ -z "$root" ] && [ "$(id -u)" != 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi
if [ -z "${VPNTOGGLE_SKIP_LAUNCHCTL:-}" ]; then
  launchctl bootout system/local.vpn-toggle 2>/dev/null || true
  [ -f "$root/usr/local/sbin/vpn-toggle-watch.sh" ] && sh "$root/usr/local/sbin/vpn-toggle-watch.sh" --resume
fi
rm -f "$root/Library/LaunchDaemons/local.vpn-toggle.plist" "$root/usr/local/sbin/vpn-toggle-watch.sh" "$root/var/log/vpn-toggle.log"
echo "removed"
