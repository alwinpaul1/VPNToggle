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
if [ "$(id -u)" != 0 ]; then
  sh nvm-pause/install.sh > /dev/null 2>&1 && fail "install ran without root"
  sh nvm-pause/uninstall.sh > /dev/null 2>&1 && fail "uninstall ran without root"
fi
echo "nvm-pause: passed"
