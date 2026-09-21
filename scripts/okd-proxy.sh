#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
DATA_DIRECTORY="${BCS_VPN_DATA_DIRECTORY:-$PROJECT_DIRECTORY}"
RUN_DIRECTORY="$DATA_DIRECTORY/run"
STATUS_FILE="$RUN_DIRECTORY/okd-proxy.status"
CONFIG_FILE="${1:-}"
KUBECONFIG_FILE="$RUN_DIRECTORY/okd-proxy-kubeconfig"
CHILD_PID=""
STOP_REQUESTED=false

umask 077
mkdir -p "$RUN_DIRECTORY"

write_status() {
  printf '%s\n' "$1" > "$STATUS_FILE"
  chmod 600 "$STATUS_FILE"
}

cleanup() {
  STOP_REQUESTED=true
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  rm -f "$KUBECONFIG_FILE"
  write_status stopped
}
trap cleanup EXIT
trap 'exit 143' INT TERM

if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
  write_status failed
  echo "Не найдена конфигурация OKD Proxy." >&2
  exit 1
fi

read_config() {
  OKD_SERVER_URL="$(plutil -extract serverURL raw -o - "$CONFIG_FILE")"
  OKD_TOKEN="$(plutil -extract token raw -o - "$CONFIG_FILE" 2>/dev/null || true)"
  OKD_USERNAME="$(plutil -extract username raw -o - "$CONFIG_FILE" 2>/dev/null || true)"
  OKD_PASSWORD="$(plutil -extract password raw -o - "$CONFIG_FILE" 2>/dev/null || true)"
  OKD_NAMESPACE="$(plutil -extract namespace raw -o - "$CONFIG_FILE")"
  OKD_SELECTOR="$(plutil -extract podSelector raw -o - "$CONFIG_FILE")"
  OKD_PORTS="$(plutil -extract ports raw -o - "$CONFIG_FILE")"
  [[ -n "$OKD_SERVER_URL" && -n "$OKD_NAMESPACE" && -n "$OKD_SELECTOR" && -n "$OKD_PORTS" ]] || return 1
  [[ -n "$OKD_TOKEN" || ( -n "$OKD_USERNAME" && -n "$OKD_PASSWORD" ) ]] || return 1
  [[ -z "$OKD_USERNAME" && -z "$OKD_PASSWORD" || -n "$OKD_USERNAME" && -n "$OKD_PASSWORD" ]] || return 1
  [[ "$OKD_TOKEN" != *$'\n'* && "$OKD_TOKEN" != *$'\r'* && "$OKD_USERNAME" != *$'\n'* && "$OKD_USERNAME" != *$'\r'* && "$OKD_PASSWORD" != *$'\n'* && "$OKD_PASSWORD" != *$'\r'* ]] || return 1
  read -r -a FORWARD_PORTS <<< "$OKD_PORTS"
  [[ "${#FORWARD_PORTS[@]}" -gt 0 ]] || return 1
  for port in "${FORWARD_PORTS[@]}"; do
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
  done
}

if ! read_config; then
  write_status failed
  echo "Некорректная конфигурация OKD Proxy." >&2
  exit 1
fi

OC_EXECUTABLE="$(command -v oc || true)"
if [[ -z "$OC_EXECUTABLE" || ! -x "$OC_EXECUTABLE" ]]; then
  write_status failed
  echo "Не найден исполняемый файл oc." >&2
  exit 1
fi

yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

SERVER_YAML="$(yaml_quote "$OKD_SERVER_URL")"
NAMESPACE_YAML="$(yaml_quote "$OKD_NAMESPACE")"
if [[ -n "$OKD_USERNAME" && -n "$OKD_PASSWORD" ]]; then
  USER_CREDENTIALS="    username: $(yaml_quote "$OKD_USERNAME")\n    password: $(yaml_quote "$OKD_PASSWORD")"
else
  USER_CREDENTIALS="    token: $(yaml_quote "$OKD_TOKEN")"
fi

# Build a short-lived kubeconfig instead of putting credentials in the oc
# command line. The credentials are only present in this 0600 file while
# port-forward runs.
cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: bcs-okd
  cluster:
    server: $SERVER_YAML
contexts:
- name: bcs-okd
  context:
    cluster: bcs-okd
    namespace: $NAMESPACE_YAML
    user: bcs-okd
current-context: bcs-okd
users:
- name: bcs-okd
  user:
$(printf '%b\n' "$USER_CREDENTIALS")
EOF
chmod 600 "$KUBECONFIG_FILE"

while true; do
  write_status starting
  pod="$($OC_EXECUTABLE --kubeconfig="$KUBECONFIG_FILE" get pods \
    --namespace "$OKD_NAMESPACE" \
    --selector "$OKD_SELECTOR" \
    --field-selector=status.phase=Running \
    --output 'custom-columns=POD:.metadata.name' \
    --no-headers 2>>"$RUN_DIRECTORY/okd-proxy.log" \
    | awk 'NF { print $1; exit }' || true)"

  if [[ -z "$pod" ]]; then
    echo "Running pod не найден; повтор через 5 секунд." >&2
    sleep 5
    continue
  fi

  echo "Port-forward к pod $pod: ${FORWARD_PORTS[*]}"
  write_status connected
  set +e
  "$OC_EXECUTABLE" --kubeconfig="$KUBECONFIG_FILE" port-forward \
    --address 127.0.0.1 --namespace "$OKD_NAMESPACE" "$pod" "${FORWARD_PORTS[@]}" &
  CHILD_PID=$!
  wait "$CHILD_PID"
  child_status=$?
  CHILD_PID=""
  set -e

  $STOP_REQUESTED && exit 0
  echo "oc port-forward завершился (код $child_status); повтор через 2 секунды." >&2
  sleep 2
done
