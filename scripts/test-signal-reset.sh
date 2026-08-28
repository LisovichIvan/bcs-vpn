#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPN_COMMAND_HELPER="${1:?Usage: test-signal-reset.sh VPN_COMMAND_HELPER}"

test_signal() {
  local signal_name="$1"
  local expected_exit_status="$2"
  local child_process_id
  local child_exit_status

  trap '' INT TERM
  "$VPN_COMMAND_HELPER" exec-with-default-signals \
    /bin/bash -c \
    'trap "exit 42" INT; trap "exit 43" TERM; while true; do sleep 1; done' &
  child_process_id=$!
  trap - INT TERM

  sleep 0.2
  kill -"$signal_name" "$child_process_id"
  for _ in $(seq 1 20); do
    kill -0 "$child_process_id" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$child_process_id" 2>/dev/null; then
    kill -KILL "$child_process_id" 2>/dev/null || true
    wait "$child_process_id" 2>/dev/null || true
    echo "Дочерний процесс унаследовал игнорирование $signal_name." >&2
    exit 1
  fi

  if wait "$child_process_id" 2>/dev/null; then
    child_exit_status=0
  else
    child_exit_status=$?
  fi
  if [[ "$child_exit_status" -ne "$expected_exit_status" ]]; then
    echo "Неожиданный код после $signal_name: $child_exit_status." >&2
    exit 1
  fi
}

test_signal INT 42
test_signal TERM 43
echo "Сброс SIGINT и SIGTERM перед запуском дочернего процесса работает."
