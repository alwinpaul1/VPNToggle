#!/bin/sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=${VPNTOGGLE_ROOT:-}
if [ -z "$root" ] && [ "$(id -u)" != 0 ]; then
  echo "run with sudo" >&2
  exit 1
fi
tries=${VPNTOGGLE_UNLOAD_TRIES:-75}

loaded() { launchctl print "system/$1" > /dev/null 2>&1; }

unload() {
  loaded "$1" || return 0
  launchctl bootout "system/$1" 2>/dev/null || true
  i=0
  while loaded "$1" && [ $i -lt "$tries" ]; do sleep 0.2; i=$((i + 1)); done
  if loaded "$1"; then
    echo "$1 is still loaded nothing installed" >&2
    exit 1
  fi
}

if [ -z "${VPNTOGGLE_SKIP_LAUNCHCTL:-}" ]; then
  unload local.nvm-watchdog
  unload local.vpn-toggle
fi
owner=""
[ "$(id -u)" = 0 ] && owner="-o root -g wheel"
mkdir -p "$root/usr/local/sbin" "$root/Library/LaunchDaemons"
install $owner -m 755 "$here/vpn-toggle-watch.sh" "$root/usr/local/sbin/vpn-toggle-watch.sh"
install $owner -m 644 "$here/local.vpn-toggle.plist" "$root/Library/LaunchDaemons/local.vpn-toggle.plist"
rm -f "$root/Library/LaunchDaemons/local.nvm-watchdog.plist" "$root/usr/local/sbin/nvm-watchdog.sh" "$root/var/db/nvm-watchdog.day" "$root/var/log/nvm-watchdog.log"
if [ -z "${VPNTOGGLE_SKIP_LAUNCHCTL:-}" ]; then
  launchctl bootstrap system "$root/Library/LaunchDaemons/local.vpn-toggle.plist"
  if ! loaded local.vpn-toggle; then
    echo "local.vpn-toggle did not load" >&2
    exit 1
  fi
fi
echo "installed"
