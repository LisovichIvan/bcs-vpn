#!/usr/bin/env bash
set -euo pipefail

: "${BCS_VPN_RUNTIME_DIRECTORY:?Не задан BCS_VPN_RUNTIME_DIRECTORY}"
: "${BCS_VPN_RUN_DIRECTORY:?Не задан BCS_VPN_RUN_DIRECTORY}"

OCPROXY_EXECUTABLE="$BCS_VPN_RUNTIME_DIRECTORY/bin/ocproxy"
OCPROXY_PROCESS_ID_FILE="$BCS_VPN_RUN_DIRECTORY/ocproxy.pid"
OCPROXY_START_TIME_FILE="$BCS_VPN_RUN_DIRECTORY/ocproxy.start-time"
OCPROXY_LOG_FILE="$BCS_VPN_RUN_DIRECTORY/ocproxy.log"

exec >> "$OCPROXY_LOG_FILE" 2>&1
printf 'ocproxy start: VPNFD=%s, address=%s, MTU=%s\n' \
  "${VPNFD:+set}" \
  "${INTERNAL_IP4_ADDRESS:+set}" \
  "${INTERNAL_IP4_MTU:+set}"

printf '%s\n' "$$" > "$OCPROXY_PROCESS_ID_FILE"
ps -p $$ -o lstart= | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$OCPROXY_START_TIME_FILE"
exec "$OCPROXY_EXECUTABLE" -D 8890 -k 30
