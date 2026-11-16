#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library ConnectPolicy.swift UpdatePolicy.swift StatusPolicy.swift StatusSession.swift NVMPause.swift EventLog.swift SelfUpdate.swift tests/ConnectPolicyTests.swift tests/StatusPolicyTests.swift tests/StatusSessionTests.swift tests/NVMPauseTests.swift tests/EventLogTests.swift tests/SelfUpdateTests.swift -o "$OUT/tests"
"$OUT/tests"
sh tests/nvm-pause-test.sh
