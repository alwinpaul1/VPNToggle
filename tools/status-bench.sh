#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -O -parse-as-library StatusPolicy.swift StatusSession.swift tools/status-bench.swift -o "$OUT/bench"
"$OUT/bench" "${1:-5}"
