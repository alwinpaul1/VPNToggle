#!/bin/sh
# Removes the acnvmagent watchdog. Run with sudo.
launchctl bootout system/local.nvm-watchdog 2>/dev/null || true
rm -f /Library/LaunchDaemons/local.nvm-watchdog.plist /usr/local/sbin/nvm-watchdog.sh /var/db/nvm-watchdog.day /var/log/nvm-watchdog.log
echo "removed"
