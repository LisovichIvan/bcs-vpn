#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
mkdir -p "$PROJECT_DIRECTORY/run"
TEST_DIRECTORY="$(mktemp -d "$PROJECT_DIRECTORY/run/vpn-session-time-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT

swiftc -warnings-as-errors -parse-as-library \
  "$PROJECT_DIRECTORY/app/VPNSessionTime.swift" \
  "$SCRIPT_DIRECTORY/VPNSessionTimeTests.swift" \
  -o "$TEST_DIRECTORY/vpn-session-time-tests"
"$TEST_DIRECTORY/vpn-session-time-tests" "$TEST_DIRECTORY" "$SCRIPT_DIRECTORY/run-ocproxy.sh"
