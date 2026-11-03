#!/bin/zsh
# Compiles the metrics code with the tests and runs them.
set -euo pipefail
cd "${0:A:h}/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -O -swift-version 5 -target arm64-apple-macos13 -o "$OUT/tests" Sources/Metrics.swift Tests/main.swift
"$OUT/tests"
