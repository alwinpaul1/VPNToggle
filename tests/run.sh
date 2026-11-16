#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library ConnectPolicy.swift tests/ConnectPolicyTests.swift -o "$OUT/tests"
"$OUT/tests"
