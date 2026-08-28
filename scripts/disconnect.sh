#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
RUN_DIRECTORY="$PROJECT_DIRECTORY/run"
INSTALLATION_DIRECTORY="$HOME/Library/Application Support/BCS VPN"
OPENCONNECT_EXECUTABLE="$INSTALLATION_DIRECTORY/runtime-macos-arm64/bin/openconnect"
OCPROXY_EXECUTABLE="$INSTALLATION_DIRECTORY/runtime-macos-arm64/bin/ocproxy"
OPENCONNECT_PROCESS_ID_FILE="$RUN_DIRECTORY/openconnect.pid"
OPENCONNECT_START_TIME_FILE="$RUN_DIRECTORY/openconnect.start-time"
OCPROXY_PROCESS_ID_FILE="$RUN_DIRECTORY/ocproxy.pid"
OCPROXY_START_TIME_FILE="$RUN_DIRECTORY/ocproxy.start-time"
LIFECYCLE_LOCK_FILE="$INSTALLATION_DIRECTORY/lifecycle.lock"

umask 077
mkdir -p "$RUN_DIRECTORY" "$INSTALLATION_DIRECTORY"
chmod 700 "$INSTALLATION_DIRECTORY"
if ! /usr/bin/shlock -f "$LIFECYCLE_LOCK_FILE" -p $$; then
  echo "Другая операция подключения или отключения ещё выполняется." >&2
  exit 1
fi
trap 'rm -f "$LIFECYCLE_LOCK_FILE"' EXIT

process_executable_path() {
  local process_id="$1"
  ps -ww -p "$process_id" -o comm= 2>/dev/null \
    | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

process_start_time() {
  local process_id="$1"
  ps -p "$process_id" -o lstart= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

running_installed_openconnect_process_ids() {
  [[ -f "$OPENCONNECT_EXECUTABLE" ]] || return 0
  lsof -a -d txt -t "$OPENCONNECT_EXECUTABLE" 2>/dev/null \
    | /usr/bin/sort -u || true
}

stop_ocproxy() {
  [[ -f "$OCPROXY_PROCESS_ID_FILE" && -f "$OCPROXY_START_TIME_FILE" ]] || return 0
  local process_id
  local expected_start_time
  process_id="$(< "$OCPROXY_PROCESS_ID_FILE")"
  expected_start_time="$(< "$OCPROXY_START_TIME_FILE")"
  [[ "$process_id" =~ ^[0-9]+$ ]] || return 0
  [[ "$(process_executable_path "$process_id")" == "$OCPROXY_EXECUTABLE" ]] || return 0
  [[ "$(process_start_time "$process_id")" == "$expected_start_time" ]] || return 0

  kill -TERM "$process_id" 2>/dev/null || true
  for _ in $(seq 1 10); do
    kill -0 "$process_id" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$process_id" 2>/dev/null && \
    [[ "$(process_executable_path "$process_id")" == "$OCPROXY_EXECUTABLE" ]] && \
    [[ "$(process_start_time "$process_id")" == "$expected_start_time" ]]; then
    kill -KILL "$process_id" 2>/dev/null || true
  fi
}

cleanup_temporary_files() {
  rm -f \
    "$RUN_DIRECTORY/keychain-client.p12" \
    "$RUN_DIRECTORY/client-identity.pem" \
    "$RUN_DIRECTORY/selected-client-identity.pem" \
    "$RUN_DIRECTORY/certificate-password" \
    "$RUN_DIRECTORY/vpn-passcode"
}

if [[ ! -f "$OPENCONNECT_PROCESS_ID_FILE" ]]; then
  if [[ -n "$(running_installed_openconnect_process_ids)" ]]; then
    echo "OpenConnect запущен без файла процесса; автоматическая остановка небезопасна." >&2
    exit 1
  fi
  stop_ocproxy
  if [[ -n "$(lsof -nP -iTCP:8890 -sTCP:LISTEN -t 2>/dev/null || true)" ]]; then
    echo "Порт 127.0.0.1:8890 занят неизвестным процессом; остановка не подтверждена." >&2
    exit 1
  fi
  rm -f "$OPENCONNECT_START_TIME_FILE" "$OCPROXY_PROCESS_ID_FILE" "$OCPROXY_START_TIME_FILE"
  cleanup_temporary_files
  echo "VPN уже остановлен. SOCKS5 127.0.0.1:8889 работает в режиме Direct."
  exit 0
fi

openconnect_process_id="$(< "$OPENCONNECT_PROCESS_ID_FILE")"
if [[ ! "$openconnect_process_id" =~ ^[0-9]+$ ]]; then
  if [[ -n "$(running_installed_openconnect_process_ids)" ]]; then
    echo "OpenConnect запущен, но файл процесса повреждён; автоматическая остановка небезопасна." >&2
    exit 1
  fi
  stop_ocproxy
  if [[ -n "$(lsof -nP -iTCP:8890 -sTCP:LISTEN -t 2>/dev/null || true)" ]]; then
    echo "Файл процесса OpenConnect повреждён, а порт 127.0.0.1:8890 занят." >&2
    exit 1
  fi
  rm -f "$OPENCONNECT_PROCESS_ID_FILE"
  rm -f "$OPENCONNECT_START_TIME_FILE"
  stop_ocproxy
  rm -f "$OCPROXY_PROCESS_ID_FILE" "$OCPROXY_START_TIME_FILE"
  cleanup_temporary_files
  echo "Повреждённый файл процесса удалён; VPN остановлен."
  exit 0
fi

process_executable="$(process_executable_path "$openconnect_process_id")"
if [[ -z "$process_executable" && -n "$(running_installed_openconnect_process_ids)" ]]; then
  echo "Запущен OpenConnect, не совпадающий с сохранённым процессом; остановка отменена." >&2
  exit 1
fi
if [[ -n "$process_executable" && ! -f "$OPENCONNECT_START_TIME_FILE" ]]; then
  echo "Нет времени запуска OpenConnect; безопасная остановка по идентификатору невозможна." >&2
  exit 1
fi
openconnect_start_time=""
if [[ -f "$OPENCONNECT_START_TIME_FILE" ]]; then
  openconnect_start_time="$(< "$OPENCONNECT_START_TIME_FILE")"
fi
if [[ -n "$process_executable" && "$process_executable" != "$OPENCONNECT_EXECUTABLE" ]]; then
  echo "Идентификатор $openconnect_process_id принадлежит другому процессу; остановка отменена." >&2
  exit 1
fi

if [[ "$process_executable" == "$OPENCONNECT_EXECUTABLE" ]] && \
  [[ "$(process_start_time "$openconnect_process_id")" == "$openconnect_start_time" ]]; then
  kill -TERM "$openconnect_process_id"
  for _ in $(seq 1 30); do
    if ! kill -0 "$openconnect_process_id" 2>/dev/null; then
      break
    fi
    sleep 1
  done
fi

if kill -0 "$openconnect_process_id" 2>/dev/null && \
  [[ "$(process_executable_path "$openconnect_process_id")" == "$OPENCONNECT_EXECUTABLE" ]] && \
  [[ "$(process_start_time "$openconnect_process_id")" == "$openconnect_start_time" ]]; then
  kill -KILL "$openconnect_process_id"
fi

if kill -0 "$openconnect_process_id" 2>/dev/null; then
  echo "OpenConnect не завершился за 30 секунд." >&2
  exit 1
fi

stop_ocproxy

rm -f "$OPENCONNECT_PROCESS_ID_FILE" "$OPENCONNECT_START_TIME_FILE"
cleanup_temporary_files

for _ in $(seq 1 10); do
  if [[ -z "$(lsof -nP -iTCP:8890 -sTCP:LISTEN -t 2>/dev/null || true)" ]]; then
    rm -f "$OCPROXY_PROCESS_ID_FILE" "$OCPROXY_START_TIME_FILE"
    echo "VPN остановлен, временные секреты удалены."
    echo "SOCKS5 127.0.0.1:8889 продолжает работу в режиме Direct."
    exit 0
  fi
  sleep 1
done

echo "OpenConnect остановлен, но порт 127.0.0.1:8890 ещё занят." >&2
exit 1
