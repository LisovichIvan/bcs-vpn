#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
SERVER_SOURCE_FILE="$PROJECT_DIRECTORY/fallback-proxy/FallbackProxyServer.swift"
MAIN_SOURCE_FILE="$PROJECT_DIRECTORY/fallback-proxy/main.swift"
UPSTREAM_STUB="$PROJECT_DIRECTORY/fallback-proxy/test-upstream.py"
TEST_CLIENT="$PROJECT_DIRECTORY/fallback-proxy/test-client.py"
TEST_DIRECTORY="$PROJECT_DIRECTORY/run/fallback-test"
TEST_BINARY="$TEST_DIRECTORY/cisco-vpn-fallback-proxy"

rm -rf "$TEST_DIRECTORY"
mkdir -p "$TEST_DIRECTORY"
swiftc -warnings-as-errors -O "$MAIN_SOURCE_FILE" "$SERVER_SOURCE_FILE" -o "$TEST_BINARY"

python3 -m http.server 18080 --bind 127.0.0.1 > "$TEST_DIRECTORY/http.log" 2>&1 &
http_server_process_id=$!
"$TEST_BINARY" --listen-port 18890 --upstream-port 18891 > "$TEST_DIRECTORY/inner.log" 2>&1 &
inner_proxy_process_id=$!
"$TEST_BINARY" --listen-port 18889 --upstream-port 18890 > "$TEST_DIRECTORY/outer.log" 2>&1 &
outer_proxy_process_id=$!
python3 "$UPSTREAM_STUB" close-after-greeting 18892 > "$TEST_DIRECTORY/close-upstream.log" 2>&1 &
close_upstream_process_id=$!
"$TEST_BINARY" \
  --listen-port 18888 \
  --upstream-port 18892 \
  --upstream-timeout-milliseconds 300 \
  > "$TEST_DIRECTORY/close-fallback.log" 2>&1 &
close_fallback_process_id=$!
python3 "$UPSTREAM_STUB" hang-after-request 18893 > "$TEST_DIRECTORY/hang-upstream.log" 2>&1 &
hang_upstream_process_id=$!
"$TEST_BINARY" \
  --listen-port 18887 \
  --upstream-port 18893 \
  --upstream-timeout-milliseconds 300 \
  > "$TEST_DIRECTORY/hang-fallback.log" 2>&1 &
hang_fallback_process_id=$!
python3 "$UPSTREAM_STUB" malformed-replies 18894 > "$TEST_DIRECTORY/malformed-upstream.log" 2>&1 &
malformed_upstream_process_id=$!
"$TEST_BINARY" --listen-port 18886 --upstream-port 18894 \
  > "$TEST_DIRECTORY/malformed-fallback.log" 2>&1 &
malformed_fallback_process_id=$!
python3 "$UPSTREAM_STUB" reject-request 18895 > "$TEST_DIRECTORY/reject-upstream.log" 2>&1 &
reject_upstream_process_id=$!
"$TEST_BINARY" --listen-port 18885 --upstream-port 18895 \
  > "$TEST_DIRECTORY/reject-fallback.log" 2>&1 &
reject_fallback_process_id=$!

cleanup() {
  kill \
    "$outer_proxy_process_id" \
    "$inner_proxy_process_id" \
    "$close_fallback_process_id" \
    "$close_upstream_process_id" \
    "$hang_fallback_process_id" \
    "$hang_upstream_process_id" \
    "$malformed_fallback_process_id" \
    "$malformed_upstream_process_id" \
    "$reject_fallback_process_id" \
    "$reject_upstream_process_id" \
    "$http_server_process_id" \
    2>/dev/null || true
  wait \
    "$outer_proxy_process_id" \
    "$inner_proxy_process_id" \
    "$close_fallback_process_id" \
    "$close_upstream_process_id" \
    "$hang_fallback_process_id" \
    "$hang_upstream_process_id" \
    "$malformed_fallback_process_id" \
    "$malformed_upstream_process_id" \
    "$reject_fallback_process_id" \
    "$reject_upstream_process_id" \
    "$http_server_process_id" \
    2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sleep 2

socks_greeting_response="$(
  printf '\x05\x01\x00' \
    | nc -w 1 127.0.0.1 18890 \
    | od -An -tx1 \
    | tr -d '[:space:]'
)"
if [[ "$socks_greeting_response" != "0500" ]]; then
  echo "Некорректный ответ SOCKS5 greeting: $socks_greeting_response" >&2
  exit 1
fi

python3 "$TEST_CLIENT" 18890 18080 success
for _ in 1 2 3 4; do
  python3 "$TEST_CLIENT" 18886 18080 rejected
done
python3 "$TEST_CLIENT" 18885 18080 rejected
python3 "$TEST_CLIENT" 18888 18080 rejected
python3 "$TEST_CLIENT" 18887 18080 rejected

curl \
  -fsS \
  --max-time 10 \
  --noproxy '' \
  --socks5-hostname 127.0.0.1:18890 \
  -o /dev/null \
  http://localhost:18080/

curl \
  -fsS \
  --max-time 10 \
  --noproxy '' \
  --socks5-hostname 127.0.0.1:18889 \
  -o /dev/null \
  http://localhost:18080/

grep -q 'mode=direct destination=localhost:18080' "$TEST_DIRECTORY/inner.log"
grep -q 'mode=vpn destination=localhost:18080' "$TEST_DIRECTORY/outer.log"
if grep -q 'mode=direct' \
  "$TEST_DIRECTORY/close-fallback.log" \
  "$TEST_DIRECTORY/hang-fallback.log" \
  "$TEST_DIRECTORY/malformed-fallback.log"; then
  echo "Fallback обошёл доступный upstream после ошибки протокола." >&2
  exit 1
fi

echo "Fallback SOCKS5: direct, vpn и отказы upstream обработаны корректно."

cleanup
trap - EXIT INT TERM
rm -rf "$TEST_DIRECTORY"
