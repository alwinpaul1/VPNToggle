#!/bin/sh
set -u
if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "integration-macos.sh installs a LaunchDaemon; it runs on the CI runner only" >&2
  exit 1
fi
cd "$(dirname "$0")/.."
work=$(mktemp -d)
pids=""
app=""

bounded() {
  limit=$1
  shift
  "$@" &
  job=$!
  waited=0
  while kill -0 "$job" 2>/dev/null; do
    if [ "$waited" -ge $((limit * 5)) ]; then
      echo "timed out after $limit s: $*"
      kill -KILL "$job" 2>/dev/null || sudo kill -KILL "$job" 2>/dev/null
      wait "$job" 2>/dev/null
      return 124
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  wait "$job"
}

cleanup() {
  bounded 60 sudo sh nvm-pause/uninstall.sh > /dev/null 2>&1
  for p in $pids $app; do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$work"
}
fail() {
  echo "FAIL integration: $*"
  ps -axo pid,stat,etime,comm | grep -E "acnvmagent|vpnagentd|VPNToggle|vpn-toggle-watch|launchctl" | grep -v grep
  sudo cat /var/log/vpn-toggle.log 2>/dev/null
  [ -f "$HOME/Library/Logs/VPNToggle.log" ] && cat "$HOME/Library/Logs/VPNToggle.log"
  cleanup
  exit 1
}
state() { ps -o stat= -p "$1" 2>/dev/null | cut -c1; }
wait_state() {
  i=0
  while [ $i -lt "$3" ]; do
    if [ "$2" = "stopped" ] && [ "$(state "$1")" = "T" ]; then return 0; fi
    if [ "$2" = "running" ] && [ -n "$(state "$1")" ] && [ "$(state "$1")" != "T" ]; then return 0; fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}
spawn() {
  mkdir -p "$work/$1"
  cp /bin/sleep "$work/$1/$2"
  "$work/$1/$2" 900 &
  last=$!
  pids="$pids $last"
}

spawn a acnvmagent; agent=$last
spawn b vpnagentd; decoy1=$last
spawn c acnvmagent2; decoy2=$last
sleep 1
[ -n "$(state "$agent")" ] || fail "the dummy agent did not start"

listed=$(sh nvm-pause/vpn-toggle-watch.sh --list)
[ "$listed" = "$agent running stop" ] || fail "dry run selected: $listed"

bounded 60 sudo sh nvm-pause/install.sh || fail "install script failed"
sudo launchctl print system/local.vpn-toggle > /dev/null || fail "daemon not loaded"
[ -f /Library/LaunchDaemons/local.vpn-toggle.plist ] && [ -x /usr/local/sbin/vpn-toggle-watch.sh ] || fail "files not installed"
wait_state "$agent" stopped 25 || fail "agent not stopped within 5 s"
sleep 2
[ "$(state "$agent")" = "T" ] || fail "agent did not stay stopped"
[ "$(state "$decoy1")" != "T" ] && [ -n "$(state "$decoy1")" ] || fail "decoy vpnagentd was stopped"
[ "$(state "$decoy2")" != "T" ] && [ -n "$(state "$decoy2")" ] || fail "decoy acnvmagent2 was stopped"
echo "ok: agent stopped, decoys untouched"

bounded 60 sudo sh nvm-pause/install.sh || fail "second install over the running daemon failed"
sudo launchctl print system/local.vpn-toggle > /dev/null || fail "daemon not loaded after the second install"
sleep 2
[ "$(state "$agent")" = "T" ] || fail "agent not stopped after the second install"
echo "ok: installing twice works"

kill -KILL "$agent"
spawn d acnvmagent; agent=$last
wait_state "$agent" stopped 15 || fail "respawned agent not stopped within 3 s"
[ "$(state "$decoy1")" != "T" ] || fail "decoy stopped after respawn"
echo "ok: respawned agent stopped"

bounded 60 sudo sh nvm-pause/uninstall.sh || fail "uninstall script failed"
sudo launchctl print system/local.vpn-toggle > /dev/null 2>&1 && fail "daemon still loaded when uninstall returned"
wait_state "$agent" running 15 || fail "agent not resumed after uninstall"
[ ! -e /Library/LaunchDaemons/local.vpn-toggle.plist ] && [ ! -e /usr/local/sbin/vpn-toggle-watch.sh ] || fail "files left behind"
sleep 2
[ "$(state "$agent")" != "T" ] || fail "agent stopped again after uninstall"
echo "ok: uninstall resumed the agent and removed the daemon"

bounded 600 ./build.sh --no-install || fail "build failed"
bundle=build/VPNToggle.app
[ -x "$bundle/Contents/MacOS/VPNToggle" ] || fail "no app binary"
codesign --verify "$bundle" || fail "app signature invalid"
for f in install.sh uninstall.sh vpn-toggle-watch.sh local.vpn-toggle.plist; do
  cmp -s "nvm-pause/$f" "$bundle/Contents/Resources/nvm-pause/$f" || fail "bundle lacks nvm-pause/$f"
done
[ ! -e "$HOME/Applications/VPNToggle.app" ] || fail "--no-install still installed the app"
log="$HOME/Library/Logs/VPNToggle.log"
rm -f "$log"
"$bundle/Contents/MacOS/VPNToggle" > "$work/app.out" 2>&1 &
app=$!
sleep 12
if ! kill -0 "$app" 2>/dev/null; then
  cat "$work/app.out"
  fail "the app exited within 12 s"
fi
grep -q "app started" "$log" || fail "the app did not log its start"
grep -q "fast status check gave no usable reading" "$log" || fail "no fallback from the fast status check without a Cisco CLI"
cat "$log"
kill -TERM "$app"
echo "ok: app built, started, fell back without a Cisco CLI and stayed up"

cleanup
echo "integration: passed"
