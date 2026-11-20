#!/usr/bin/env bash
set -euo pipefail

APPLICATION_BUNDLE="${BCS_VPN_APP_BUNDLE:-$HOME/Applications/BCS VPN.app}"
VPN_COMMAND_HELPER="$APPLICATION_BUNDLE/Contents/MacOS/bcs-vpn-helper"

if [[ "$#" -ne 1 ]]; then
  echo "Использование: $0 <hostname>" >&2
  exit 1
fi
if [[ ! -x "$VPN_COMMAND_HELPER" ]]; then
  echo "Сначала установите BCS VPN.app: ./scripts/install-app.sh" >&2
  exit 1
fi

exec "$VPN_COMMAND_HELPER" resolve-host "$1"
