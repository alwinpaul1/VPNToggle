#!/bin/sh
set -e
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL nvm-pause: $*"; exit 1; }

mkdir "$work/bin"
cat > "$work/bin/pgrep" <<'STUB'
#!/bin/sh
[ "$1" = "-x" ] && [ "$2" = "acnvmagent" ] || exit 3
printf '101\n102\n103\n'
STUB
cat > "$work/bin/ps" <<'STUB'
#!/bin/sh
case "$2:$4" in
  comm=:101) echo "/opt/cisco/secureclient/NVM/bin/acnvmagent.app/Contents/MacOS/acnvmagent" ;;
  comm=:102) echo "/tmp/some dir/acnvmagent" ;;
  comm=:103) echo "/opt/cisco/secureclient/bin/acnvmagent-helper" ;;
  stat=:101) echo "T<" ;;
  stat=:102) echo "S" ;;
  stat=:103) echo "S" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/pgrep" "$work/bin/ps"

listed=$(PATH="$work/bin:$PATH" sh nvm-pause/vpn-toggle-watch.sh --list)
expected="101 stopped none
102 running stop"
[ "$listed" = "$expected" ] || fail "list selected: $listed"
sh nvm-pause/vpn-toggle-watch.sh --bogus 2>/dev/null && fail "unknown option accepted"

for name in vpnagentd acumbrellaagent csc_iseagentd csc_iseposture csc_zta_agent ciscod acsockext csc_vpnagent; do
  grep -q "$name" nvm-pause/vpn-toggle-watch.sh && fail "script names $name"
done
[ "$(grep -c 'kill -STOP' nvm-pause/vpn-toggle-watch.sh)" = 1 ] || fail "more than one place stops a process"

root="$work/root"
VPNTOGGLE_ROOT="$root" VPNTOGGLE_SKIP_LAUNCHCTL=1 sh nvm-pause/install.sh > /dev/null
[ -x "$root/usr/local/sbin/vpn-toggle-watch.sh" ] || fail "script not installed"
cmp -s nvm-pause/vpn-toggle-watch.sh "$root/usr/local/sbin/vpn-toggle-watch.sh" || fail "installed script differs"
cmp -s nvm-pause/local.vpn-toggle.plist "$root/Library/LaunchDaemons/local.vpn-toggle.plist" || fail "installed plist differs"
plutil -lint "$root/Library/LaunchDaemons/local.vpn-toggle.plist" > /dev/null || fail "plist invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$root/Library/LaunchDaemons/local.vpn-toggle.plist")" = "/usr/local/sbin/vpn-toggle-watch.sh" ] || fail "plist runs another path"
[ "$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive' "$root/Library/LaunchDaemons/local.vpn-toggle.plist")" = "true" ] || fail "plist is not kept alive"
VPNTOGGLE_ROOT="$root" VPNTOGGLE_SKIP_LAUNCHCTL=1 sh nvm-pause/uninstall.sh > /dev/null
[ -z "$(find "$root" -type f)" ] || fail "files left after uninstall"
mkdir "$work/ctl"
cat > "$work/ctl/pgrep" <<'STUB'
#!/bin/sh
exit 1
STUB
cat > "$work/ctl/launchctl" <<'STUB'
#!/bin/sh
echo "$*" >> "$CTL_LOG"
case "$1" in
  print)
    [ "$2" = "system/local.vpn-toggle" ] || exit 113
    left=$(cat "$CTL_LEFT")
    [ "$left" -gt 0 ] || exit 113
    grep -q "^bootout" "$CTL_LOG" && echo $((left - 1)) > "$CTL_LEFT"
    exit 0
    ;;
  bootstrap) echo 1000000 > "$CTL_LEFT" ;;
esac
exit 0
STUB
chmod +x "$work/ctl/pgrep" "$work/ctl/launchctl"
export CTL_LOG="$work/ctl.log" CTL_LEFT="$work/ctl.left"
ctl() { PATH="$work/ctl:$PATH" VPNTOGGLE_ROOT="$root" VPNTOGGLE_UNLOAD_TRIES=10 sh "nvm-pause/$1" 2>&1; }

: > "$CTL_LOG"; echo 0 > "$CTL_LEFT"
ctl install.sh > /dev/null || fail "install with launchctl failed"
grep -q "^bootout" "$CTL_LOG" && fail "install booted out a daemon that was not loaded"
grep -q "^bootstrap system $root/Library/LaunchDaemons/local.vpn-toggle.plist" "$CTL_LOG" || fail "install did not bootstrap"

: > "$CTL_LOG"; echo 4 > "$CTL_LEFT"
ctl install.sh > /dev/null || fail "reinstall over a loaded daemon failed"
[ "$(grep -n -E "^(bootout|bootstrap)" "$CTL_LOG" | cut -d: -f2 | cut -d" " -f1 | tr '\n' ' ')" = "bootout bootstrap " ] || fail "reinstall order wrong"
[ "$(sed -n "/^bootout/,/^bootstrap/p" "$CTL_LOG" | grep -c "^print")" -ge 4 ] || fail "reinstall did not wait for the old daemon to go"

: > "$CTL_LOG"; echo 4 > "$CTL_LEFT"
out=$(ctl uninstall.sh) || fail "uninstall of a slowly stopping daemon failed: $out"
[ "$out" = "removed" ] || fail "uninstall said: $out"
[ "$(sed -n "/^bootout/,\$p" "$CTL_LOG" | grep -c "^print")" -ge 4 ] || fail "uninstall did not wait for the daemon to go"
[ -z "$(find "$root" -type f)" ] || fail "files left after uninstall with launchctl"

: > "$CTL_LOG"; echo 0 > "$CTL_LEFT"
ctl install.sh > /dev/null
: > "$CTL_LOG"; echo 1000000 > "$CTL_LEFT"
if out=$(ctl uninstall.sh); then fail "uninstall reported success with the daemon still loaded"; fi
echo "$out" | grep -q "still loaded" || fail "stuck uninstall said: $out"
echo "$out" | grep -qx "removed" && fail "stuck uninstall printed removed"
[ -f "$root/Library/LaunchDaemons/local.vpn-toggle.plist" ] || fail "stuck uninstall removed the plist"
if out=$(ctl install.sh); then fail "install reported success over a daemon that would not unload"; fi
echo 0 > "$CTL_LEFT"
ctl uninstall.sh > /dev/null

PATH="$work/ctl:$PATH" sh nvm-pause/vpn-toggle-watch.sh 2>/dev/null &
watcher=$!
sleep 1.3
kill -TERM "$watcher"
i=0
while kill -0 "$watcher" 2>/dev/null && [ $i -lt 5 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$watcher" 2>/dev/null; then
  kill -KILL "$watcher"
  fail "watcher did not stop within 0.5 s of TERM"
fi

if [ "$(id -u)" != 0 ]; then
  sh nvm-pause/install.sh > /dev/null 2>&1 && fail "install ran without root"
  sh nvm-pause/uninstall.sh > /dev/null 2>&1 && fail "uninstall ran without root"
fi
echo "nvm-pause: passed"
