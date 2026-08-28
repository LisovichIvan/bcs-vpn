#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
VPN_COMMAND_HELPER="$HOME/Applications/BCS VPN.app/Contents/MacOS/bcs-vpn-helper"

if [[ ! -x "$VPN_COMMAND_HELPER" ]]; then
  echo "Не найден $VPN_COMMAND_HELPER. Переустановите BCS VPN.app." >&2
  exit 1
fi

if [[ -t 0 ]]; then
  echo -n "Постоянный PIN RSA SecurID, затем Enter: "
  read -r -s rsa_pin
  echo
else
  rsa_pin="$(osascript -e 'text returned of (display dialog "Введите постоянный PIN RSA SecurID. Значение будет сохранено в локальном vpn-settings.plist." default answer "" with hidden answer buttons {"Отмена", "Сохранить"} default button "Сохранить" cancel button "Отмена")')"
fi

if [[ ! "$rsa_pin" =~ ^[0-9]+$ ]]; then
  echo "PIN RSA должен содержать только цифры." >&2
  exit 1
fi

trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s' "$rsa_pin" \
  | "$VPN_COMMAND_HELPER" set-rsa-pin "$PROJECT_DIRECTORY"
trap - EXIT INT TERM
unset rsa_pin

echo "Постоянный PIN RSA сохранён в локальном vpn-settings.plist."
