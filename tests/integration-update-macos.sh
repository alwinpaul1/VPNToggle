#!/bin/sh
set -u
if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "integration-update-macos.sh adds a keychain and starts the app; it runs on the CI runner only" >&2
  exit 1
fi
cd "$(dirname "$0")/.."
work=$(mktemp -d)
served="$work/served"
inst="$work/Applications/VPNToggle.app"
kc="$work/update-test.keychain-db"
kcpass=$(uuidgen)
before=$(security list-keychains -d user | sed 's/"//g')
server=""
log="$HOME/Library/Logs/VPNToggle.log"
mkdir -p "$served" "$work/Applications"

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
  [ -n "$server" ] && kill "$server" 2>/dev/null
  pkill -f "$inst/Contents/MacOS/VPNToggle" 2>/dev/null
  security list-keychains -d user -s $before > /dev/null 2>&1
  security delete-keychain "$kc" > /dev/null 2>&1
  rm -rf "$work"
}
fail() {
  echo "FAIL update: $*"
  [ -f "$log" ] && cat "$log"
  [ -f "$work/out.txt" ] && cat "$work/out.txt"
  ps -axo pid,stat,etime,comm | grep -E "VPNToggle|http.server|codesign|security" | grep -v grep
  cleanup
  exit 1
}
version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null; }
digest() { shasum -a 256 "$1" | cut -d" " -f1; }
size() { stat -f %z "$1"; }
release() {
  field=""
  [ -n "$3" ] && field="\"digest\": \"sha256:$3\","
  cat > "$served/latest.json" <<JSON
{"tag_name": "$1", "html_url": "https://github.com/alwinpaul1/VPNToggle/releases/tag/$1",
 "assets": [{"name": "VPNToggle-macOS.zip", $field "size": $4, "browser_download_url": "$2"}]}
JSON
}
attempt() {
  bounded 120 env VPNTOGGLE_UPDATE_TEST_API="$api" "$inst/Contents/MacOS/VPNToggle" --self-update-test > "$work/out.txt" 2>&1
  code=$?
  cat "$work/out.txt"
}
refused() {
  attempt
  [ "$code" = 3 ] || fail "$1: exit code $code, expected a refusal"
  grep -q "^refused: $2" "$work/out.txt" || fail "$1: expected refusal $2"
  [ "$(version "$inst")" = "1.0" ] || fail "$1: the installed app changed"
  codesign --verify "$inst" || fail "$1: the installed app is damaged"
  [ "$(ls "$work/Applications")" = "VPNToggle.app" ] || fail "$1: files left next to the app"
  echo "ok: $1 refused ($2), old app intact"
}

cat > "$work/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = VPNToggle Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 3 -config "$work/cert.cnf" 2>/dev/null || fail "could not make a certificate"
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout "pass:$kcpass" -name "VPNToggle Local Signing" || fail "could not pack the identity"
bounded 30 security create-keychain -p "$kcpass" "$kc" || fail "could not create a keychain"
security set-keychain-settings "$kc"
security unlock-keychain -p "$kcpass" "$kc"
bounded 30 security import "$work/id.p12" -k "$kc" -P "$kcpass" -T /usr/bin/codesign > /dev/null || fail "could not import the identity"
bounded 30 security set-key-partition-list -S apple-tool:,apple: -s -k "$kcpass" "$kc" > /dev/null 2>&1
security list-keychains -d user -s "$kc" $before
security find-identity -p codesigning | grep -q "VPNToggle Local Signing" || fail "the signing identity is not visible"

bounded 600 env VPNTOGGLE_VERSION=99.0 ./build.sh --no-install || fail "building the new version failed"
codesign -dvv build/VPNToggle.app 2>&1 | grep -q "Authority=VPNToggle Local Signing" || fail "the new version is not signed with the test certificate"
ditto -c -k --keepParent build/VPNToggle.app "$served/VPNToggle-macOS.zip"
ditto build/VPNToggle.app "$work/adhoc/VPNToggle.app"
bounded 60 codesign --force --sign - "$work/adhoc/VPNToggle.app" 2>/dev/null || fail "could not sign the ad hoc copy"
ditto -c -k --keepParent "$work/adhoc/VPNToggle.app" "$served/adhoc.zip"
ditto build/VPNToggle.app "$work/tampered/VPNToggle.app"
echo "changed" >> "$work/tampered/VPNToggle.app/Contents/Resources/nvm-pause/install.sh"
ditto -c -k --keepParent "$work/tampered/VPNToggle.app" "$served/tampered.zip"

bounded 600 env VPNTOGGLE_VERSION=1.0 ./build.sh --no-install || fail "building the old version failed"
ditto build/VPNToggle.app "$inst"
[ "$(version "$inst")" = "1.0" ] || fail "the old version is not 1.0"
codesign --verify "$inst" || fail "the old version is not validly signed"

port=$((20000 + $$ % 20000))
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$served" > /dev/null 2>&1 &
server=$!
origin="http://127.0.0.1:$port"
api="$origin/latest.json"
i=0
until curl -s --max-time 5 -o /dev/null "$origin/VPNToggle-macOS.zip"; do
  i=$((i + 1))
  [ $i -lt 50 ] || fail "the local server did not start"
  sleep 0.2
done
rm -f "$log"
good=$(digest "$served/VPNToggle-macOS.zip")
bytes=$(size "$served/VPNToggle-macOS.zip")

release v99.0 "$origin/VPNToggle-macOS.zip" "$(digest "$served/adhoc.zip")" "$bytes"
refused "bad digest" digestMismatch
release v99.0 "$origin/VPNToggle-macOS.zip" "" "$bytes"
refused "missing digest" missingDigest
release v99.0 "https://example.org/VPNToggle-macOS.zip" "$good" "$bytes"
refused "disallowed host" urlNotAllowed
release v99.0 "http://127.0.0.1:$((port + 1))/VPNToggle-macOS.zip" "$good" "$bytes"
refused "another local port" urlNotAllowed
release v99.0 "$origin/adhoc.zip" "$(digest "$served/adhoc.zip")" "$(size "$served/adhoc.zip")"
refused "ad hoc signed bundle" signature
release v99.0 "$origin/tampered.zip" "$(digest "$served/tampered.zip")" "$(size "$served/tampered.zip")"
refused "bundle changed after signing" signature
release v1.0 "$origin/VPNToggle-macOS.zip" "$good" "$bytes"
refused "release not newer" notNewer

release v99.0 "$origin/VPNToggle-macOS.zip" "$good" "$bytes"
attempt
[ "$code" = 0 ] || fail "update: exit code $code"
grep -q "^installed" "$work/out.txt" || fail "update: no installed line"
[ "$(version "$inst")" = "99.0" ] || fail "update: version in place is $(version "$inst")"
codesign --verify "$inst" || fail "update: the new app is not validly signed"
[ "$(ls "$work/Applications")" = "VPNToggle.app" ] || fail "update: files left next to the app"
i=0
until pgrep -f "$inst/Contents/MacOS/VPNToggle" > /dev/null; do
  i=$((i + 1))
  [ $i -lt 75 ] || fail "update: the new version was not started"
  sleep 0.2
done
sleep 8
new=$(pgrep -f "$inst/Contents/MacOS/VPNToggle" | head -1)
[ -n "$new" ] || fail "update: the new version did not stay up"
grep -q "update test: installed" "$log" || fail "update: not logged"
[ "$(grep -c "app started" "$log")" = 1 ] || fail "update: expected one app start in the log"
echo "ok: 1.0 replaced by 99.0, new version running as pid $new"

cleanup
echo "update integration: passed"
