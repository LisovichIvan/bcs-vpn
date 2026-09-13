#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
DATA_DIRECTORY="${BCS_VPN_DATA_DIRECTORY:-$PROJECT_DIRECTORY}"
RUN_DIRECTORY="$DATA_DIRECTORY/run"
TEST_HOST="${1:-confluence.bcs.ru}"
FALLBACK_PROXY_EXECUTABLE="$HOME/Applications/BCS VPN.app/Contents/MacOS/bcs-vpn"

if [[ "$("$SCRIPT_DIRECTORY/status.sh")" != "connected" ]]; then
  echo "Нативный VPN не подключён." >&2
  [[ -f "$RUN_DIRECTORY/openconnect.log" ]] && /usr/bin/tail -n 30 "$RUN_DIRECTORY/openconnect.log" >&2
  exit 1
fi

for proxy_port in 8889 8890; do
  if ! lsof -nP -iTCP:"$proxy_port" -sTCP:LISTEN | grep -q "127.0.0.1:${proxy_port}"; then
    echo "Прокси не слушает 127.0.0.1:${proxy_port}." >&2
    exit 1
  fi
done

fallback_process_id="$(
  { lsof -nP -iTCP@127.0.0.1:8889 -sTCP:LISTEN -Fp 2>/dev/null || true; } \
    | /usr/bin/sed -n 's/^p//p' \
    | /usr/bin/sed -n '1p'
)"
fallback_process_executable="$(
  ps -ww -p "$fallback_process_id" -o comm= 2>/dev/null \
    | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
)"
if [[ "$fallback_process_executable" != "$FALLBACK_PROXY_EXECUTABLE" ]]; then
  echo "Порт 127.0.0.1:8889 принадлежит неизвестному процессу." >&2
  exit 1
fi

socks_greeting_response="$(
  printf '\x05\x01\x00' \
    | nc -w 1 127.0.0.1 8889 \
    | od -An -tx1 \
    | tr -d '[:space:]'
)"
if [[ "$socks_greeting_response" != "0500" ]]; then
  echo "Fallback-прокси вернул некорректный ответ SOCKS5." >&2
  exit 1
fi

direct_ip="$(curl -fsS --max-time 10 --proxy '' --noproxy '*' https://ifconfig.me/ip)"
http_status="$(curl -sS --max-time 20 --socks5-hostname 127.0.0.1:8890 -o /dev/null -w '%{http_code}' "https://${TEST_HOST}/")"

if [[ "$http_status" == "000" ]]; then
  echo "Нет доступа к https://${TEST_HOST}/ через SOCKS5." >&2
  exit 1
fi

/sbin/ifconfig > "$RUN_DIRECTORY/network-interfaces.after"
netstat -rn -f inet > "$RUN_DIRECTORY/network-routes-ipv4.after"
netstat -rn -f inet6 > "$RUN_DIRECTORY/network-routes-ipv6.after"
scutil --dns > "$RUN_DIRECTORY/network-dns.after"

network_changed=false
for network_state in interfaces routes-ipv4 routes-ipv6 dns; do
  before_file="$RUN_DIRECTORY/network-${network_state}.before"
  after_file="$RUN_DIRECTORY/network-${network_state}.after"
  if [[ ! -f "$before_file" ]] || ! cmp -s "$before_file" "$after_file"; then
    echo "Сетевое состояние macOS изменилось: $network_state" >&2
    if [[ -f "$before_file" ]]; then
      diff -u "$before_file" "$after_file" >&2 || true
    fi
    network_changed=true
  fi
done

if [[ "$network_changed" == true ]]; then
  exit 1
fi

echo "OpenConnect: запущен в пользовательском режиме"
echo "Fallback SOCKS5: 127.0.0.1:8889"
echo "VPN SOCKS5: 127.0.0.1:8890"
echo "Прямой внешний IP: $direct_ip"
echo "https://${TEST_HOST}/ через SOCKS5: HTTP $http_status"
echo "Интерфейсы, маршруты и DNS macOS не изменились."
