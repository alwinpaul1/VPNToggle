#!/bin/sh
# Installs the acnvmagent watchdog. Run with sudo.
set -e
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p /usr/local/sbin
install -o root -g wheel -m 755 "$here/nvm-watchdog.sh" /usr/local/sbin/nvm-watchdog.sh
install -o root -g wheel -m 644 "$here/local.nvm-watchdog.plist" /Library/LaunchDaemons/local.nvm-watchdog.plist
launchctl bootout system/local.nvm-watchdog 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/local.nvm-watchdog.plist
echo "installed; first check runs now, log: /var/log/nvm-watchdog.log"
