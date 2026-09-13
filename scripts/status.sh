#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
DATA_DIRECTORY="${BCS_VPN_DATA_DIRECTORY:-$PROJECT_DIRECTORY}"
APPLICATION_BUNDLE="${BCS_VPN_APP_BUNDLE:-$HOME/Applications/BCS VPN.app}"
RUNTIME_DIRECTORY="$APPLICATION_BUNDLE/Contents/Resources/runtime-macos-arm64"
OPENCONNECT_EXECUTABLE="$RUNTIME_DIRECTORY/bin/openconnect"
OCPROXY_EXECUTABLE="$RUNTIME_DIRECTORY/bin/ocproxy"
OPENCONNECT_PROCESS_ID_FILE="$DATA_DIRECTORY/run/openconnect.pid"
OPENCONNECT_START_TIME_FILE="$DATA_DIRECTORY/run/openconnect.start-time"
OCPROXY_PROCESS_ID_FILE="$DATA_DIRECTORY/run/ocproxy.pid"
OCPROXY_START_TIME_FILE="$DATA_DIRECTORY/run/ocproxy.start-time"

process_executable_path() {
  local process_id="$1"
  ps -ww -p "$process_id" -o comm= 2>/dev/null \
    | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

process_start_time() {
  local process_id="$1"
  ps -p "$process_id" -o lstart= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
}

if [[ "$(uname -m)" != "arm64" || ! -x "$OPENCONNECT_EXECUTABLE" ]]; then
  echo "unavailable"
  exit 0
fi

proxy_process_id=""
if [[ -f "$OCPROXY_PROCESS_ID_FILE" && -f "$OCPROXY_START_TIME_FILE" ]]; then
  proxy_process_id="$(< "$OCPROXY_PROCESS_ID_FILE")"
  [[ "$proxy_process_id" =~ ^[0-9]+$ ]] || proxy_process_id=""
fi
proxy_port_is_occupied=false
if [[ -n "$(lsof -nP -iTCP:8890 -sTCP:LISTEN -t 2>/dev/null || true)" ]]; then
  proxy_port_is_occupied=true
fi

if [[ ! -f "$OPENCONNECT_PROCESS_ID_FILE" ]]; then
  if [[ "$proxy_port_is_occupied" == true ]]; then
    echo "failed"
  else
    echo "disconnected"
  fi
  exit 0
fi

openconnect_process_id="$(< "$OPENCONNECT_PROCESS_ID_FILE")"
if [[ ! "$openconnect_process_id" =~ ^[0-9]+$ ]]; then
  if [[ "$proxy_port_is_occupied" == true ]]; then
    echo "failed"
  else
    echo "disconnected"
  fi
  exit 0
fi

openconnect_process_executable="$(process_executable_path "$openconnect_process_id")"
if [[ "$openconnect_process_executable" == "$OPENCONNECT_EXECUTABLE" ]] && \
  [[ ! -f "$OPENCONNECT_START_TIME_FILE" ]]; then
  echo "failed"
  exit 0
fi

openconnect_start_time=""
if [[ -f "$OPENCONNECT_START_TIME_FILE" ]]; then
  openconnect_start_time="$(< "$OPENCONNECT_START_TIME_FILE")"
fi
if [[ "$openconnect_process_executable" == "$OPENCONNECT_EXECUTABLE" ]] && \
  { [[ -z "$openconnect_start_time" ]] || \
    [[ "$(process_start_time "$openconnect_process_id")" != "$openconnect_start_time" ]]; }; then
  echo "failed"
  exit 0
fi

if [[ "$openconnect_process_executable" != "$OPENCONNECT_EXECUTABLE" ]]; then
  if [[ "$proxy_port_is_occupied" == true ]]; then
    echo "failed"
  else
    echo "disconnected"
  fi
  exit 0
fi

if [[ -n "$proxy_process_id" ]] && \
  [[ "$(process_executable_path "$proxy_process_id")" == "$OCPROXY_EXECUTABLE" ]] && \
  [[ "$(process_start_time "$proxy_process_id")" == "$(< "$OCPROXY_START_TIME_FILE")" ]] && \
  lsof -nP -a -p "$proxy_process_id" -iTCP:8890 -sTCP:LISTEN 2>/dev/null \
    | grep -q '127.0.0.1:8890'; then
  echo "connected"
elif [[ "$proxy_port_is_occupied" == true ]]; then
  echo "failed"
else
  echo "connecting"
fi
