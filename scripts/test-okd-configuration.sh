#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
mkdir -p "$PROJECT_DIRECTORY/run"
TEST_DIRECTORY="$(mktemp -d "$PROJECT_DIRECTORY/run/okd-configuration-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIRECTORY"' EXIT

swiftc -warnings-as-errors -parse-as-library \
  "$PROJECT_DIRECTORY/app/OKDProxySettings.swift" \
  "$PROJECT_DIRECTORY/app/OKDProxyConfiguration.swift" \
  "$PROJECT_DIRECTORY/app/OKDProxyManager.swift" \
  "$PROJECT_DIRECTORY/app/OKDProxySettingsWindowController.swift" \
  "$PROJECT_DIRECTORY/app/CopyableTextView.swift" \
  "$SCRIPT_DIRECTORY/OKDProxyConfigurationTests.swift" \
  -o "$TEST_DIRECTORY/okd-configuration-tests"
"$TEST_DIRECTORY/okd-configuration-tests" "$TEST_DIRECTORY"
