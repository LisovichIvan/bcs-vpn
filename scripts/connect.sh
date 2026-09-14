#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
DATA_DIRECTORY="${BCS_VPN_DATA_DIRECTORY:-$PROJECT_DIRECTORY}"
RUN_DIRECTORY="$DATA_DIRECTORY/run"
INSTALLATION_DIRECTORY="$HOME/Library/Application Support/BCS VPN"
APPLICATION_BUNDLE="${BCS_VPN_APP_BUNDLE:-$HOME/Applications/BCS VPN.app}"
RUNTIME_DIRECTORY="$APPLICATION_BUNDLE/Contents/Resources/runtime-macos-arm64"
OPENCONNECT_EXECUTABLE="$RUNTIME_DIRECTORY/bin/openconnect"
OCPROXY_SCRIPT="$SCRIPT_DIRECTORY/run-ocproxy.sh"
# OpenConnect invokes --script through /bin/sh without quoting the path.
# Keep a controlled copy at a path without spaces because the app bundle path
# contains "BCS VPN.app".
OCPROXY_LAUNCH_SCRIPT="/tmp/bcs-vpn-ocproxy-${UID}.sh"
OPENCONNECT_PROCESS_ID_FILE="$RUN_DIRECTORY/openconnect.pid"
OPENCONNECT_START_TIME_FILE="$RUN_DIRECTORY/openconnect.start-time"
OCPROXY_PROCESS_ID_FILE="$RUN_DIRECTORY/ocproxy.pid"
OCPROXY_START_TIME_FILE="$RUN_DIRECTORY/ocproxy.start-time"
OPENCONNECT_LOG_FILE="$RUN_DIRECTORY/openconnect.log"
OCPROXY_LOG_FILE="$RUN_DIRECTORY/ocproxy.log"
LIFECYCLE_LOCK_FILE="$INSTALLATION_DIRECTORY/lifecycle.lock"
VPN_COMMAND_HELPER="$APPLICATION_BUNDLE/Contents/MacOS/bcs-vpn-helper"
IDENTITY_PEM_FILE="$RUN_DIRECTORY/client-identity.pem"
CERTIFICATE_PASSWORD_FILE="$RUN_DIRECTORY/certificate-password"
VPN_PASSCODE_FILE="$RUN_DIRECTORY/vpn-passcode"

cd "$PROJECT_DIRECTORY"

umask 077
mkdir -p "$RUN_DIRECTORY" "$INSTALLATION_DIRECTORY"
chmod 700 "$INSTALLATION_DIRECTORY"
if ! /usr/bin/shlock -f "$LIFECYCLE_LOCK_FILE" -p $$; then
  echo "Другая операция подключения или отключения ещё выполняется." >&2
  exit 1
fi

openconnect_started=false
openconnect_process_id=""

process_executable_path() {
  local process_id="$1"
  ps -ww -p "$process_id" -o comm= 2>/dev/null \
    | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

process_start_time() {
  local process_id="$1"
  ps -p "$process_id" -o lstart= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

process_matches() {
  local process_id="$1"
  local expected_executable="$2"
  local expected_start_time="$3"
  [[ "$(process_executable_path "$process_id")" == "$expected_executable" ]] && \
    [[ "$(process_start_time "$process_id")" == "$expected_start_time" ]]
}

stop_ocproxy() {
  [[ -f "$OCPROXY_PROCESS_ID_FILE" && -f "$OCPROXY_START_TIME_FILE" ]] || return 0
  local process_id
  local expected_start_time
  process_id="$(< "$OCPROXY_PROCESS_ID_FILE")"
  expected_start_time="$(< "$OCPROXY_START_TIME_FILE")"
  [[ "$process_id" =~ ^[0-9]+$ ]] || return 0
  process_matches "$process_id" "$RUNTIME_DIRECTORY/bin/ocproxy" "$expected_start_time" || return 0

  kill -TERM "$process_id" 2>/dev/null || true
  for _ in $(seq 1 10); do
    kill -0 "$process_id" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$process_id" 2>/dev/null && \
    process_matches "$process_id" "$RUNTIME_DIRECTORY/bin/ocproxy" "$expected_start_time"; then
    kill -KILL "$process_id" 2>/dev/null || true
  fi
  if ! kill -0 "$process_id" 2>/dev/null; then
    rm -f "$OCPROXY_PROCESS_ID_FILE" "$OCPROXY_START_TIME_FILE"
  fi
}

stop_started_openconnect() {
  local process_id
  local expected_start_time
  process_id="$openconnect_process_id"
  if [[ -z "$process_id" && -f "$OPENCONNECT_PROCESS_ID_FILE" ]]; then
    process_id="$(< "$OPENCONNECT_PROCESS_ID_FILE")"
  fi
  [[ "$process_id" =~ ^[0-9]+$ ]] || return 0
  [[ "$(process_executable_path "$process_id")" == "$OPENCONNECT_EXECUTABLE" ]] || return 0
  expected_start_time="${openconnect_start_time:-}"
  if [[ -z "$expected_start_time" && -f "$OPENCONNECT_START_TIME_FILE" ]]; then
    expected_start_time="$(< "$OPENCONNECT_START_TIME_FILE")"
  fi
  if [[ -n "$expected_start_time" ]] && \
    [[ "$(process_start_time "$process_id")" != "$expected_start_time" ]]; then
    return 0
  fi

  kill -TERM "$process_id" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$process_id" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$process_id" 2>/dev/null && \
    [[ "$(process_executable_path "$process_id")" == "$OPENCONNECT_EXECUTABLE" ]] && \
    { [[ -z "$expected_start_time" ]] || \
      [[ "$(process_start_time "$process_id")" == "$expected_start_time" ]]; }; then
    kill -KILL "$process_id" 2>/dev/null || true
  fi
  if ! kill -0 "$process_id" 2>/dev/null; then
    rm -f "$OPENCONNECT_PROCESS_ID_FILE" "$OPENCONNECT_START_TIME_FILE"
  fi
  stop_ocproxy
}

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [[ "$exit_status" -ne 0 && "$openconnect_started" == true ]]; then
    stop_started_openconnect
  fi
  rm -f \
    "$IDENTITY_PEM_FILE" \
    "$CERTIFICATE_PASSWORD_FILE" \
    "$VPN_PASSCODE_FILE" \
    "$LIFECYCLE_LOCK_FILE"
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Переносимый VPN runtime поддерживает только Mac с Apple Silicon." >&2
  exit 1
fi

if [[ ! -x "$OPENCONNECT_EXECUTABLE" || ! -x "$RUNTIME_DIRECTORY/bin/ocproxy" || \
  ! -x "$VPN_COMMAND_HELPER" ]]; then
  echo "Не найден VPN runtime внутри $APPLICATION_BUNDLE." >&2
  echo "Переустановите BCS VPN.app командой ./scripts/install-app.sh --activate." >&2
  exit 1
fi

if ! (cd "$RUNTIME_DIRECTORY" && shasum -a 256 -c CHECKSUMS.sha256 >/dev/null); then
  echo "Контрольные суммы переносимого VPN runtime не совпадают." >&2
  exit 1
fi

unset OPENCONNECT_URL OPENCONNECT_USER OPENCONNECT_RSA_PIN OPENCONNECT_CERTIFICATE_SHA1 OPENCONNECT_SERVER_CERTIFICATE_PIN
settings_output="$("$VPN_COMMAND_HELPER" read-settings "$DATA_DIRECTORY")"
while IFS=$'\t' read -r setting_key setting_value; do
  case "$setting_key" in
    OPENCONNECT_URL) OPENCONNECT_URL="$setting_value" ;;
    OPENCONNECT_USER) OPENCONNECT_USER="$setting_value" ;;
    OPENCONNECT_RSA_PIN) OPENCONNECT_RSA_PIN="$setting_value" ;;
    OPENCONNECT_CERTIFICATE_SHA1) OPENCONNECT_CERTIFICATE_SHA1="$setting_value" ;;
    OPENCONNECT_SERVER_CERTIFICATE_PIN) OPENCONNECT_SERVER_CERTIFICATE_PIN="$setting_value" ;;
    *)
      echo "Получен неизвестный параметр настроек: $setting_key" >&2
      exit 1
      ;;
  esac
done <<< "$settings_output"
unset settings_output setting_key setting_value

for required_variable in OPENCONNECT_URL OPENCONNECT_USER OPENCONNECT_RSA_PIN OPENCONNECT_CERTIFICATE_SHA1 OPENCONNECT_SERVER_CERTIFICATE_PIN; do
  if [[ -z "${!required_variable:-}" ]]; then
    echo "Не задан параметр $required_variable в vpn-settings.plist." >&2
    exit 1
  fi
done

current_status="$("$SCRIPT_DIRECTORY/status.sh")"
if [[ "$current_status" == "connected" || "$current_status" == "connecting" ]]; then
  echo "VPN уже запущен, состояние: $current_status."
  exit 0
fi
if [[ "$current_status" == "failed" ]]; then
  echo "Состояние VPN требует безопасной остановки или проверки порта 8890." >&2
  exit 1
fi
if [[ -n "$(lsof -a -d txt -t "$OPENCONNECT_EXECUTABLE" 2>/dev/null || true)" ]]; then
  echo "Установленный OpenConnect уже запущен из другой копии проекта." >&2
  exit 1
fi

for cisco_vpn_executable in \
  /opt/cisco/secureclient/bin/vpn \
  /opt/cisco/anyconnect/bin/vpn; do
  if [[ -x "$cisco_vpn_executable" ]] && \
    printf 'state\nexit\n' | "$cisco_vpn_executable" -s 2>/dev/null | grep -q 'state: Connected'; then
    echo "Штатный Cisco Secure Client ещё подключён." >&2
    echo "Отключите его перед нативным VPN, чтобы проверка изоляции была достоверной." >&2
    exit 1
  fi
done

if [[ -t 0 ]]; then
  echo "Откройте приложение RSA SecurID и возьмите новый код."
  echo -n "Только 6 цифр, затем Enter: "
  read -r rsa_code
else
  rsa_code="$(osascript -e 'text returned of (display dialog "Введите только новый шестизначный код из приложения RSA SecurID." default answer "" with hidden answer buttons {"Отмена", "Продолжить"} default button "Продолжить" cancel button "Отмена")')"
fi

if [[ ! "$rsa_code" =~ ^[0-9]{6}$ ]]; then
  echo "Код RSA должен содержать 6 цифр." >&2
  exit 1
fi

rm -f \
  "$IDENTITY_PEM_FILE" \
  "$CERTIFICATE_PASSWORD_FILE" \
  "$VPN_PASSCODE_FILE" \
  "$OCPROXY_PROCESS_ID_FILE" \
  "$OCPROXY_START_TIME_FILE" \
  "$OPENCONNECT_PROCESS_ID_FILE" \
  "$OPENCONNECT_START_TIME_FILE"

certificate_password="$(/usr/bin/openssl rand -hex 24)"
printf '%s\n' "$certificate_password" > "$CERTIFICATE_PASSWORD_FILE"
"$VPN_COMMAND_HELPER" export-identity \
  "$OPENCONNECT_CERTIFICATE_SHA1" \
  "$IDENTITY_PEM_FILE" \
  "$CERTIFICATE_PASSWORD_FILE"
chmod 600 "$IDENTITY_PEM_FILE"

rm -f "$CERTIFICATE_PASSWORD_FILE"
printf '%s%s\n' "$OPENCONNECT_RSA_PIN" "$rsa_code" > "$VPN_PASSCODE_FILE"
unset certificate_password rsa_code OPENCONNECT_RSA_PIN

/sbin/ifconfig > "$RUN_DIRECTORY/network-interfaces.before"
netstat -rn -f inet > "$RUN_DIRECTORY/network-routes-ipv4.before"
netstat -rn -f inet6 > "$RUN_DIRECTORY/network-routes-ipv6.before"
scutil --dns > "$RUN_DIRECTORY/network-dns.before"

: > "$OPENCONNECT_LOG_FILE"
: > "$OCPROXY_LOG_FILE"
chmod 600 "$OPENCONNECT_LOG_FILE"
chmod 600 "$OCPROXY_LOG_FILE"
rm -f "$OCPROXY_LAUNCH_SCRIPT"
cp "$OCPROXY_SCRIPT" "$OCPROXY_LAUNCH_SCRIPT"
chmod 700 "$OCPROXY_LAUNCH_SCRIPT"

echo "Запуск OpenConnect в пользовательском режиме. Маршруты и DNS macOS не изменяются."
trap '' INT TERM
"$VPN_COMMAND_HELPER" exec-with-default-signals \
  /usr/bin/nohup /usr/bin/env \
  -u http_proxy \
  -u https_proxy \
  -u all_proxy \
  -u no_proxy \
  -u HTTP_PROXY \
  -u HTTPS_PROXY \
  -u ALL_PROXY \
  -u NO_PROXY \
  BCS_VPN_RUNTIME_DIRECTORY="$RUNTIME_DIRECTORY" \
  BCS_VPN_RUN_DIRECTORY="$RUN_DIRECTORY" \
  "$OPENCONNECT_EXECUTABLE" \
  --protocol=anyconnect \
  --os=mac-intel \
  --user="$OPENCONNECT_USER" \
  --servercert="$OPENCONNECT_SERVER_CERTIFICATE_PIN" \
  --no-proxy \
  --certificate="$IDENTITY_PEM_FILE" \
  --script-tun \
  --script="$OCPROXY_LAUNCH_SCRIPT" \
  --reconnect-timeout=86400 \
  --passwd-on-stdin \
  "$OPENCONNECT_URL" \
  < "$VPN_PASSCODE_FILE" >> "$OPENCONNECT_LOG_FILE" 2>&1 &
openconnect_process_id=$!
openconnect_started=true
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$openconnect_process_id" > "$OPENCONNECT_PROCESS_ID_FILE"
for _ in $(seq 1 20); do
  openconnect_start_time="$(process_start_time "$openconnect_process_id")"
  [[ -n "$openconnect_start_time" ]] && break
  sleep 0.1
done
if [[ -z "${openconnect_start_time:-}" ]]; then
  echo "Не удалось определить время запуска OpenConnect." >&2
  exit 1
fi
printf '%s\n' "$openconnect_start_time" > "$OPENCONNECT_START_TIME_FILE"

for _ in $(seq 1 60); do
  if [[ "$("$SCRIPT_DIRECTORY/status.sh")" == "connected" ]]; then
    openconnect_started=false
    echo "VPN подключён, SOCKS5 доступен на 127.0.0.1:8890."
    exit 0
  fi
  if ! kill -0 "$openconnect_process_id" 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "SOCKS5 не запустился. Последние сообщения:" >&2
/usr/bin/tail -n 40 "$OPENCONNECT_LOG_FILE" >&2
if [[ -f "$OCPROXY_PROCESS_ID_FILE" ]]; then
  ocproxy_process_id="$(< "$OCPROXY_PROCESS_ID_FILE")"
  echo "Диагностика процесса ocproxy $ocproxy_process_id:" >&2
  ps -p "$ocproxy_process_id" -o pid=,ppid=,state=,command= 2>/dev/null >&2 || true
  lsof -a -p "$ocproxy_process_id" -d txt -Fn 2>/dev/null >&2 || true
  lsof -nP -a -p "$ocproxy_process_id" -iTCP:8890 -sTCP:LISTEN 2>/dev/null >&2 || true
fi
if [[ -s "$OCPROXY_LOG_FILE" ]]; then
  echo "Журнал ocproxy:" >&2
  /usr/bin/tail -n 20 "$OCPROXY_LOG_FILE" >&2
fi
exit 1
