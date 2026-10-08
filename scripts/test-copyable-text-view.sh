#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
TEST_DIRECTORY="$PROJECT_DIRECTORY/run/copyable-text-view-tests"
TEST_BINARY="$TEST_DIRECTORY/copyable-text-view-tests"

rm -rf "$TEST_DIRECTORY"
mkdir -p "$TEST_DIRECTORY"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT

swiftc -warnings-as-errors -parse-as-library \
  "$PROJECT_DIRECTORY/app/CopyableTextView.swift" \
  "$PROJECT_DIRECTORY/app/VPNSettingsStore.swift" \
  "$PROJECT_DIRECTORY/app/SettingsWindowController.swift" \
  "$SCRIPT_DIRECTORY/CopyableTextViewTests.swift" \
  -o "$TEST_BINARY"
"$TEST_BINARY" "$TEST_DIRECTORY"
