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
# OpenConnect exports server time limits in seconds, without enabling verbose
# logging (which could expose authentication data). Zero means no time limit.
session_timeout_seconds=""
while IFS='=' read -r option_name option_value; do
  case "$option_name" in
    X-CSTP-Session-Timeout|X-CSTP-Session-Timeout-Remaining|X-CSTP-Lease-Duration)
      if [[ "$option_value" =~ ^[0-9]{1,10}$ ]]; then
        option_seconds=$((10#$option_value))
        if [[ "$option_seconds" -gt 0 && "$option_seconds" -le 2147483647 ]] && \
          { [[ -z "$session_timeout_seconds" ]] || [[ "$option_seconds" -lt "$session_timeout_seconds" ]]; }; then
          session_timeout_seconds="$option_seconds"
        fi
      fi
      ;;
  esac
done <<< "${CISCO_CSTP_OPTIONS:-}"

session_expiration_file="$BCS_VPN_RUN_DIRECTORY/vpn-session-expiration"
rm -f "$session_expiration_file"
if [[ -n "$session_timeout_seconds" ]]; then
  session_expiration_timestamp=$(($(date +%s) + session_timeout_seconds))
  session_expiration_temporary_file="$(mktemp "$session_expiration_file.XXXXXX")"
  trap 'rm -f "$session_expiration_temporary_file"' EXIT
  chmod 600 "$session_expiration_temporary_file"
  printf '%s\n' "$session_expiration_timestamp" > "$session_expiration_temporary_file"
  mv -f "$session_expiration_temporary_file" "$session_expiration_file"
  trap - EXIT
fi

exec "$OCPROXY_EXECUTABLE" -D 8890 -k 30
