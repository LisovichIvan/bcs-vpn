#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
RUN_DIRECTORY="$PROJECT_DIRECTORY/run"
mkdir -p "$RUN_DIRECTORY"
TEST_DIRECTORY="$(mktemp -d "$RUN_DIRECTORY/settings-tests.XXXXXX")"
SETTINGS_STORE_TEST_BINARY="$TEST_DIRECTORY/vpn-settings-store-tests"
VPN_COMMAND_HELPER="$TEST_DIRECTORY/bcs-vpn-helper"
TEST_PROJECT_DIRECTORY="$TEST_DIRECTORY/project"

cleanup() {
  rm -rf "$TEST_DIRECTORY"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

swiftc -warnings-as-errors \
  "$PROJECT_DIRECTORY/app/VPNSettingsStore.swift" \
  "$SCRIPT_DIRECTORY/VPNSettingsStoreTests.swift" \
  -o "$SETTINGS_STORE_TEST_BINARY"
swiftc -warnings-as-errors -D CERTIFICATE_SELECTION_TESTS \
  "$PROJECT_DIRECTORY/app/VPNSettingsStore.swift" \
  "$PROJECT_DIRECTORY/app/VPNCommandHelper.swift" \
  -o "$VPN_COMMAND_HELPER"

mkdir -p "$TEST_PROJECT_DIRECTORY"
cp "$PROJECT_DIRECTORY/vpn-settings.example.plist" \
  "$TEST_PROJECT_DIRECTORY/vpn-settings.plist"
chmod 600 "$TEST_PROJECT_DIRECTORY/vpn-settings.plist"
plutil -replace serverURL -string 'https://fw2.bcs.ru' \
  "$TEST_PROJECT_DIRECTORY/vpn-settings.plist"
plutil -replace username -string 'test-user' \
  "$TEST_PROJECT_DIRECTORY/vpn-settings.plist"
plutil -replace rsaPIN -string '1234' \
  "$TEST_PROJECT_DIRECTORY/vpn-settings.plist"
plutil -replace certificateSHA1 -string 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
  "$TEST_PROJECT_DIRECTORY/vpn-settings.plist"
plutil -replace serverCertificatePin \
  -string 'pin-sha256:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=' \
  "$TEST_PROJECT_DIRECTORY/vpn-settings.plist"

settings_output="$("$VPN_COMMAND_HELPER" read-settings "$TEST_PROJECT_DIRECTORY")"
if [[ "$settings_output" != *$'OPENCONNECT_URL\thttps://fw2.bcs.ru'* ]] || \
  [[ "$settings_output" != *$'OPENCONNECT_RSA_PIN\t1234'* ]]; then
  echo "bcs-vpn-helper вернул некорректные настройки." >&2
  exit 1
fi
printf '5678' | "$VPN_COMMAND_HELPER" set-rsa-pin "$TEST_PROJECT_DIRECTORY"
if [[ "$(plutil -extract rsaPIN raw "$TEST_PROJECT_DIRECTORY/vpn-settings.plist")" != '5678' ]]; then
  echo "bcs-vpn-helper не обновил PIN." >&2
  exit 1
fi

(
  cd "$PROJECT_DIRECTORY"
  "$SETTINGS_STORE_TEST_BINARY"
  python3 "$SCRIPT_DIRECTORY/test-certificate-selection.py" "$VPN_COMMAND_HELPER"
  "$SCRIPT_DIRECTORY/test-signal-reset.sh" "$VPN_COMMAND_HELPER"
)

echo "bcs-vpn-helper: настройки, identity и сигналы работают."
