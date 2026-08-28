#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
SOURCE_RUNTIME_DIRECTORY="$PROJECT_DIRECTORY/vendor/macos-arm64"
INSTALLATION_DIRECTORY="$HOME/Library/Application Support/BCS VPN"
INSTALLED_RUNTIME_DIRECTORY="$INSTALLATION_DIRECTORY/runtime-macos-arm64"
STAGING_RUNTIME_DIRECTORY="$INSTALLATION_DIRECTORY/runtime-macos-arm64.staging.$$"
PREVIOUS_RUNTIME_DIRECTORY="$INSTALLATION_DIRECTORY/runtime-macos-arm64.previous.$$"
LIFECYCLE_LOCK_FILE="$INSTALLATION_DIRECTORY/lifecycle.lock"
lifecycle_lock_acquired=false

cleanup() {
  rm -rf "$STAGING_RUNTIME_DIRECTORY"
  if [[ -d "$PREVIOUS_RUNTIME_DIRECTORY" ]]; then
    if [[ ! -d "$INSTALLED_RUNTIME_DIRECTORY" ]]; then
      mv "$PREVIOUS_RUNTIME_DIRECTORY" "$INSTALLED_RUNTIME_DIRECTORY"
    else
      rm -rf "$PREVIOUS_RUNTIME_DIRECTORY"
    fi
  fi
  if [[ "$lifecycle_lock_acquired" == true ]]; then
    rm -f "$LIFECYCLE_LOCK_FILE"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Переносимый VPN runtime поддерживает только Mac с Apple Silicon." >&2
  exit 1
fi

umask 077
mkdir -p "$INSTALLATION_DIRECTORY"
chmod 700 "$INSTALLATION_DIRECTORY"
if ! /usr/bin/shlock -f "$LIFECYCLE_LOCK_FILE" -p $$; then
  echo "Другая операция подключения, отключения или установки ещё выполняется." >&2
  exit 1
fi
lifecycle_lock_acquired=true

if [[ -x "$INSTALLED_RUNTIME_DIRECTORY/bin/openconnect" ]] && \
  [[ -n "$(lsof -t "$INSTALLED_RUNTIME_DIRECTORY/bin/openconnect" 2>/dev/null || true)" ]]; then
  echo "Нельзя заменять VPN runtime, пока установленный OpenConnect запущен." >&2
  exit 1
fi

current_status="$("$SCRIPT_DIRECTORY/status.sh")"
if [[ "$current_status" == "connected" || "$current_status" == "connecting" || "$current_status" == "failed" ]]; then
  echo "Нельзя заменять VPN runtime во время активного подключения." >&2
  exit 1
fi

if ! (cd "$SOURCE_RUNTIME_DIRECTORY" && shasum -a 256 -c CHECKSUMS.sha256 >/dev/null); then
  echo "Контрольные суммы исходного VPN runtime не совпадают." >&2
  exit 1
fi

mkdir -p "$INSTALLATION_DIRECTORY" "$STAGING_RUNTIME_DIRECTORY"
chmod 700 "$INSTALLATION_DIRECTORY" "$STAGING_RUNTIME_DIRECTORY"
/usr/bin/ditto "$SOURCE_RUNTIME_DIRECTORY" "$STAGING_RUNTIME_DIRECTORY"

if ! (cd "$STAGING_RUNTIME_DIRECTORY" && shasum -a 256 -c CHECKSUMS.sha256 >/dev/null); then
  echo "Контрольные суммы подготовленного VPN runtime не совпадают." >&2
  exit 1
fi

chmod 700 "$STAGING_RUNTIME_DIRECTORY/bin/openconnect" "$STAGING_RUNTIME_DIRECTORY/bin/ocproxy"
for library_file in "$STAGING_RUNTIME_DIRECTORY"/lib/*.dylib; do
  chmod 700 "$library_file"
  codesign --verify --strict "$library_file"
done
codesign --verify --strict "$STAGING_RUNTIME_DIRECTORY/bin/openconnect"
codesign --verify --strict "$STAGING_RUNTIME_DIRECTORY/bin/ocproxy"

if [[ -d "$INSTALLED_RUNTIME_DIRECTORY" ]]; then
  mv "$INSTALLED_RUNTIME_DIRECTORY" "$PREVIOUS_RUNTIME_DIRECTORY"
fi
if ! mv "$STAGING_RUNTIME_DIRECTORY" "$INSTALLED_RUNTIME_DIRECTORY"; then
  [[ -d "$PREVIOUS_RUNTIME_DIRECTORY" ]] && mv "$PREVIOUS_RUNTIME_DIRECTORY" "$INSTALLED_RUNTIME_DIRECTORY"
  echo "Не удалось заменить установленный VPN runtime." >&2
  exit 1
fi
rm -rf "$PREVIOUS_RUNTIME_DIRECTORY"
rm -f "$LIFECYCLE_LOCK_FILE"
lifecycle_lock_acquired=false
trap - EXIT INT TERM

echo "Переносимый VPN runtime установлен в $INSTALLED_RUNTIME_DIRECTORY."
