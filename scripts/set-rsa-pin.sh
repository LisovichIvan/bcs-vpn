#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
CONFIGURATION_FILE="$PROJECT_DIRECTORY/.env"

if [[ ! -f "$CONFIGURATION_FILE" ]]; then
  echo "Не найден файл $CONFIGURATION_FILE." >&2
  exit 1
fi

if [[ -t 0 ]]; then
  echo -n "Постоянный PIN RSA SecurID, затем Enter: "
  read -r -s rsa_pin
  echo
else
  rsa_pin="$(osascript -e 'text returned of (display dialog "Введите постоянный PIN RSA SecurID. Значение будет сохранено в локальном .env." default answer "" with hidden answer buttons {"Отмена", "Сохранить"} default button "Сохранить" cancel button "Отмена")')"
fi

if [[ ! "$rsa_pin" =~ ^[0-9]+$ ]]; then
  echo "PIN RSA должен содержать только цифры." >&2
  exit 1
fi

umask 077
temporary_configuration_file="$(mktemp "$PROJECT_DIRECTORY/.env.XXXXXX")"
trap 'rm -f "$temporary_configuration_file"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
pin_was_replaced=false

while IFS= read -r configuration_line || [[ -n "$configuration_line" ]]; do
  if [[ "$configuration_line" == OPENCONNECT_RSA_PIN=* ]]; then
    if [[ "$pin_was_replaced" == false ]]; then
      printf 'OPENCONNECT_RSA_PIN=%s\n' "$rsa_pin" >> "$temporary_configuration_file"
      pin_was_replaced=true
    fi
  else
    printf '%s\n' "$configuration_line" >> "$temporary_configuration_file"
  fi
done < "$CONFIGURATION_FILE"

if [[ "$pin_was_replaced" == false ]]; then
  printf 'OPENCONNECT_RSA_PIN=%s\n' "$rsa_pin" >> "$temporary_configuration_file"
fi

chmod 600 "$temporary_configuration_file"
mv "$temporary_configuration_file" "$CONFIGURATION_FILE"
trap - EXIT INT TERM
unset rsa_pin

echo "Постоянный PIN RSA сохранён в локальном .env."
