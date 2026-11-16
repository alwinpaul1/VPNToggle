#!/bin/sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=${VPNTOGGLE_ROOT:-}
if [ -z "$root" ] && [ "$(id -u)" != 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi
owner=""
[ "$(id -u)" = 0 ] && owner="-o root -g wheel"
mkdir -p "$root/usr/local/sbin" "$root/Library/LaunchDaemons"
install $owner -m 755 "$here/vpn-toggle-watch.sh" "$root/usr/local/sbin/vpn-toggle-watch.sh"
install $owner -m 644 "$here/local.vpn-toggle.plist" "$root/Library/LaunchDaemons/local.vpn-toggle.plist"
if [ -z "${VPNTOGGLE_SKIP_LAUNCHCTL:-}" ]; then
  launchctl bootout system/local.nvm-watchdog 2>/dev/null || true
  launchctl bootout system/local.vpn-toggle 2>/dev/null || true
  launchctl bootstrap system "$root/Library/LaunchDaemons/local.vpn-toggle.plist"
fi
rm -f "$root/Library/LaunchDaemons/local.nvm-watchdog.plist" "$root/usr/local/sbin/nvm-watchdog.sh" "$root/var/db/nvm-watchdog.day" "$root/var/log/nvm-watchdog.log"
echo "installed"
