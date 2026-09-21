#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(dirname "$SCRIPT_DIRECTORY")"
APPLICATION_SOURCE_FILE="$PROJECT_DIRECTORY/app/main.swift"
APPLICATION_SETTINGS_STORE_SOURCE_FILE="$PROJECT_DIRECTORY/app/VPNSettingsStore.swift"
APPLICATION_OKD_SETTINGS_SOURCE_FILE="$PROJECT_DIRECTORY/app/OKDProxySettings.swift"
APPLICATION_OKD_MANAGER_SOURCE_FILE="$PROJECT_DIRECTORY/app/OKDProxyManager.swift"
APPLICATION_OKD_SETTINGS_WINDOW_SOURCE_FILE="$PROJECT_DIRECTORY/app/OKDProxySettingsWindowController.swift"
APPLICATION_SETTINGS_WINDOW_SOURCE_FILE="$PROJECT_DIRECTORY/app/SettingsWindowController.swift"
APPLICATION_COMMAND_HELPER_SOURCE_FILE="$PROJECT_DIRECTORY/app/VPNCommandHelper.swift"
APPLICATION_DIAGNOSTIC_LOGGER_SOURCE_FILE="$PROJECT_DIRECTORY/app/DiagnosticLogger.swift"
APPLICATION_COPYABLE_TEXT_VIEW_SOURCE_FILE="$PROJECT_DIRECTORY/app/CopyableTextView.swift"
FALLBACK_PROXY_SOURCE_FILE="$PROJECT_DIRECTORY/fallback-proxy/FallbackProxyServer.swift"
APPLICATION_INFO_TEMPLATE="$PROJECT_DIRECTORY/app/Info.plist"
APPLICATION_ICON_FILE="$PROJECT_DIRECTORY/app/BCSVPN.icns"
APPLICATION_SCRIPTS_DIRECTORY="$PROJECT_DIRECTORY/scripts"
APPLICATIONS_DIRECTORY="$HOME/Applications"
APPLICATION_BUNDLE="$APPLICATIONS_DIRECTORY/BCS VPN.app"
STAGING_APPLICATION_BUNDLE="$APPLICATIONS_DIRECTORY/.BCS VPN.app.staging.$$"
PREVIOUS_APPLICATION_BUNDLE="$APPLICATIONS_DIRECTORY/.BCS VPN.app.previous.$$"
APPLICATION_EXECUTABLE="$APPLICATION_BUNDLE/Contents/MacOS/bcs-vpn"
STAGING_APPLICATION_EXECUTABLE="$STAGING_APPLICATION_BUNDLE/Contents/MacOS/bcs-vpn"
STAGING_APPLICATION_COMMAND_HELPER_EXECUTABLE="$STAGING_APPLICATION_BUNDLE/Contents/MacOS/bcs-vpn-helper"
SOURCE_RUNTIME_DIRECTORY="$PROJECT_DIRECTORY/vendor/macos-arm64"
STAGING_RUNTIME_DIRECTORY="$STAGING_APPLICATION_BUNDLE/Contents/Resources/runtime-macos-arm64"
INSTALLATION_DIRECTORY="$HOME/Library/Application Support/BCS VPN"
LEGACY_SETTINGS_FILE="$PROJECT_DIRECTORY/vpn-settings.plist"
RUNTIME_DIRECTORY="$APPLICATION_BUNDLE/Contents/Resources/runtime-macos-arm64"
RUN_DIRECTORY="$PROJECT_DIRECTORY/run"
BACKUP_DIRECTORY="$RUN_DIRECTORY/app-install-backup.$$"
LOG_FILE="$INSTALLATION_DIRECTORY/bcs-vpn.log"
INSTALLED_PLIST="$HOME/Library/LaunchAgents/com.bcs.vpn.plist"
LAUNCH_AGENT_DOMAIN="gui/$(id -u)"
LAUNCH_AGENT_LABEL="com.bcs.vpn"
OLD_MENU_LABEL="com.bcs.cisco-vpn-menu-bar"
OLD_FALLBACK_LABEL="com.bcs.cisco-vpn-fallback-proxy"
OLD_MENU_PLIST="$HOME/Library/LaunchAgents/com.bcs.cisco-vpn-menu-bar.plist"
OLD_FALLBACK_PLIST="$HOME/Library/LaunchAgents/com.bcs.cisco-vpn-fallback-proxy.plist"
LIFECYCLE_LOCK_FILE="$INSTALLATION_DIRECTORY/lifecycle.lock"
APPLICATION_INSTALL_LOCK_FILE="$INSTALLATION_DIRECTORY/app-install.lock"
installation_mode="${1:---prepare}"
application_replaced=false
agents_stopped=false
installation_succeeded=false
new_plist_existed=false
old_menu_plist_existed=false
old_fallback_plist_existed=false
new_agent_was_loaded=false
old_menu_was_loaded=false
old_fallback_was_loaded=false
lifecycle_lock_acquired=false
application_install_lock_acquired=false

if [[ "$#" -gt 1 || "$installation_mode" != "--prepare" ]]; then
  echo "Использование: $0" >&2
  exit 1
fi

escape_xml_for_sed_replacement() {
  printf '%s' "$1" \
    | /usr/bin/sed \
      -e 's/&/\&amp;/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/[&|\\]/\\&/g'
}

launch_agent_is_loaded() {
  launchctl print "$LAUNCH_AGENT_DOMAIN/$1" >/dev/null 2>&1
}

backup_launch_agent_files() {
  mkdir -p "$BACKUP_DIRECTORY"
  if [[ -f "$INSTALLED_PLIST" ]]; then
    cp "$INSTALLED_PLIST" "$BACKUP_DIRECTORY/com.bcs.vpn.plist"
    new_plist_existed=true
  fi
  if [[ -f "$OLD_MENU_PLIST" ]]; then
    cp "$OLD_MENU_PLIST" "$BACKUP_DIRECTORY/com.bcs.cisco-vpn-menu-bar.plist"
    old_menu_plist_existed=true
  fi
  if [[ -f "$OLD_FALLBACK_PLIST" ]]; then
    cp "$OLD_FALLBACK_PLIST" "$BACKUP_DIRECTORY/com.bcs.cisco-vpn-fallback-proxy.plist"
    old_fallback_plist_existed=true
  fi
}

restore_launch_agent_file() {
  local file_existed="$1"
  local backup_file="$2"
  local destination_file="$3"
  if [[ "$file_existed" == true ]]; then
    cp "$backup_file" "$destination_file"
  else
    rm -f "$destination_file"
  fi
}

restore_loaded_launch_agents() {
  local launch_agent_restoration_failed=false
  if [[ "$new_agent_was_loaded" == true && -f "$INSTALLED_PLIST" ]]; then
    launchctl bootstrap "$LAUNCH_AGENT_DOMAIN" "$INSTALLED_PLIST" || \
      launch_agent_restoration_failed=true
  fi
  if [[ "$old_menu_was_loaded" == true && -f "$OLD_MENU_PLIST" ]]; then
    launchctl bootstrap "$LAUNCH_AGENT_DOMAIN" "$OLD_MENU_PLIST" || \
      launch_agent_restoration_failed=true
  fi
  if [[ "$old_fallback_was_loaded" == true && -f "$OLD_FALLBACK_PLIST" ]]; then
    launchctl bootstrap "$LAUNCH_AGENT_DOMAIN" "$OLD_FALLBACK_PLIST" || \
      launch_agent_restoration_failed=true
  fi
  [[ "$launch_agent_restoration_failed" == false ]]
}

cleanup() {
  local exit_status=$?
  local restoration_failed=false
  trap - EXIT INT TERM
  set +e

  rm -rf "$STAGING_APPLICATION_BUNDLE"
  if [[ "$installation_succeeded" != true ]]; then
    if [[ "$agents_stopped" == true ]]; then
      launchctl bootout "$LAUNCH_AGENT_DOMAIN/$LAUNCH_AGENT_LABEL" 2>/dev/null
      launchctl bootout "$LAUNCH_AGENT_DOMAIN/$OLD_MENU_LABEL" 2>/dev/null
      launchctl bootout "$LAUNCH_AGENT_DOMAIN/$OLD_FALLBACK_LABEL" 2>/dev/null
    fi
    if [[ -d "$PREVIOUS_APPLICATION_BUNDLE" ]]; then
      rm -rf "$APPLICATION_BUNDLE" || restoration_failed=true
      mv "$PREVIOUS_APPLICATION_BUNDLE" "$APPLICATION_BUNDLE" || restoration_failed=true
    elif [[ "$application_replaced" == true ]]; then
      rm -rf "$APPLICATION_BUNDLE" || restoration_failed=true
    fi
    if [[ "$agents_stopped" == true ]]; then
      restore_launch_agent_file \
        "$new_plist_existed" \
        "$BACKUP_DIRECTORY/com.bcs.vpn.plist" \
        "$INSTALLED_PLIST" || restoration_failed=true
      restore_launch_agent_file \
        "$old_menu_plist_existed" \
        "$BACKUP_DIRECTORY/com.bcs.cisco-vpn-menu-bar.plist" \
        "$OLD_MENU_PLIST" || restoration_failed=true
      restore_launch_agent_file \
        "$old_fallback_plist_existed" \
        "$BACKUP_DIRECTORY/com.bcs.cisco-vpn-fallback-proxy.plist" \
        "$OLD_FALLBACK_PLIST" || restoration_failed=true
      restore_loaded_launch_agents || restoration_failed=true
    fi
  fi

  if [[ "$restoration_failed" == false ]]; then
    rm -rf "$PREVIOUS_APPLICATION_BUNDLE" "$BACKUP_DIRECTORY"
  else
    echo "Не удалось полностью восстановить предыдущую установку. Резервная копия: $BACKUP_DIRECTORY" >&2
    exit_status=1
  fi
  if [[ "$lifecycle_lock_acquired" == true ]]; then
    rm -f "$LIFECYCLE_LOCK_FILE"
  fi
  if [[ "$application_install_lock_acquired" == true ]]; then
    rm -f "$APPLICATION_INSTALL_LOCK_FILE"
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "BCS VPN.app поддерживает только Mac с Apple Silicon." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1 || ! swiftc --version >/dev/null 2>&1; then
  echo "Не найден компилятор Swift. Установите Xcode Command Line Tools." >&2
  exit 1
fi

mkdir -p \
  "$APPLICATIONS_DIRECTORY" \
  "$INSTALLATION_DIRECTORY" \
  "$RUN_DIRECTORY" \
  "$HOME/Library/LaunchAgents"
chmod 700 "$INSTALLATION_DIRECTORY"
if [[ -f "$LEGACY_SETTINGS_FILE" && ! -e "$INSTALLATION_DIRECTORY/vpn-settings.plist" ]]; then
  cp "$LEGACY_SETTINGS_FILE" "$INSTALLATION_DIRECTORY/vpn-settings.plist"
  chmod 600 "$INSTALLATION_DIRECTORY/vpn-settings.plist"
  echo "Настройки перенесены в $INSTALLATION_DIRECTORY/vpn-settings.plist."
fi
if [[ -L "$LOG_FILE" || ( -e "$LOG_FILE" && ! -f "$LOG_FILE" ) ]]; then
  echo "Путь журнала приложения должен указывать на обычный файл: $LOG_FILE" >&2
  exit 1
fi
if [[ ! -e "$LOG_FILE" ]]; then
  umask 077
  : > "$LOG_FILE"
fi
chmod 600 "$LOG_FILE"
if ! /usr/bin/shlock -f "$APPLICATION_INSTALL_LOCK_FILE" -p $$; then
  echo "Другая установка BCS VPN.app ещё выполняется." >&2
  exit 1
fi
application_install_lock_acquired=true

current_status="$("$SCRIPT_DIRECTORY/status.sh")"

if [[ "$current_status" != "disconnected" && "$current_status" != "unavailable" ]]; then
  if [[ ! -x "$RUNTIME_DIRECTORY/bin/openconnect" || ! -x "$RUNTIME_DIRECTORY/bin/ocproxy" ]]; then
    echo "Активное подключение использует повреждённый или неполный VPN runtime." >&2
    exit 1
  fi
fi
if ! (cd "$SOURCE_RUNTIME_DIRECTORY" && shasum -a 256 -c CHECKSUMS.sha256 >/dev/null); then
  echo "Контрольные суммы исходного VPN runtime не совпадают." >&2
  exit 1
fi

if launch_agent_is_loaded "$LAUNCH_AGENT_LABEL"; then
  echo "Приложение уже активно через LaunchAgent. Отключите автозапуск в настройках перед обновлением." >&2
  exit 1
fi

rm -rf "$STAGING_APPLICATION_BUNDLE" "$PREVIOUS_APPLICATION_BUNDLE" "$BACKUP_DIRECTORY"
mkdir -p "$STAGING_APPLICATION_BUNDLE/Contents/MacOS" "$STAGING_APPLICATION_BUNDLE/Contents/Resources"
if [[ ! -d "$APPLICATION_SCRIPTS_DIRECTORY" ]]; then
  echo "Не найден каталог скриптов приложения: $APPLICATION_SCRIPTS_DIRECTORY" >&2
  exit 1
fi
/usr/bin/ditto "$APPLICATION_SCRIPTS_DIRECTORY" "$STAGING_APPLICATION_BUNDLE/Contents/Resources/scripts"
chmod 755 "$STAGING_APPLICATION_BUNDLE/Contents/Resources/scripts"/*.sh
if [[ ! -f "$APPLICATION_ICON_FILE" ]]; then
  echo "Не найден файл иконки приложения: $APPLICATION_ICON_FILE" >&2
  exit 1
fi
cp "$APPLICATION_ICON_FILE" "$STAGING_APPLICATION_BUNDLE/Contents/Resources/BCSVPN.icns"
chmod 644 "$STAGING_APPLICATION_BUNDLE/Contents/Resources/BCSVPN.icns"
if ! (cd "$SOURCE_RUNTIME_DIRECTORY" && shasum -a 256 -c CHECKSUMS.sha256 >/dev/null); then
  echo "Контрольные суммы исходного VPN runtime не совпадают." >&2
  exit 1
fi
/usr/bin/ditto "$SOURCE_RUNTIME_DIRECTORY" "$STAGING_RUNTIME_DIRECTORY"
chmod 700 "$STAGING_RUNTIME_DIRECTORY/bin/openconnect" "$STAGING_RUNTIME_DIRECTORY/bin/ocproxy"
for library_file in "$STAGING_RUNTIME_DIRECTORY"/lib/*.dylib; do
  chmod 700 "$library_file"
done
if ! (cd "$STAGING_RUNTIME_DIRECTORY" && shasum -a 256 -c CHECKSUMS.sha256 >/dev/null); then
  echo "Контрольные суммы встроенного VPN runtime не совпадают." >&2
  exit 1
fi
cp "$APPLICATION_INFO_TEMPLATE" "$STAGING_APPLICATION_BUNDLE/Contents/Info.plist"
chmod 644 "$STAGING_APPLICATION_BUNDLE/Contents/Info.plist"
swiftc -warnings-as-errors -O \
  "$APPLICATION_SOURCE_FILE" \
  "$APPLICATION_SETTINGS_STORE_SOURCE_FILE" \
  "$APPLICATION_OKD_SETTINGS_SOURCE_FILE" \
  "$APPLICATION_OKD_MANAGER_SOURCE_FILE" \
  "$APPLICATION_OKD_SETTINGS_WINDOW_SOURCE_FILE" \
  "$APPLICATION_SETTINGS_WINDOW_SOURCE_FILE" \
  "$APPLICATION_DIAGNOSTIC_LOGGER_SOURCE_FILE" \
  "$APPLICATION_COPYABLE_TEXT_VIEW_SOURCE_FILE" \
  "$FALLBACK_PROXY_SOURCE_FILE" \
  -o "$STAGING_APPLICATION_EXECUTABLE"
chmod 755 "$STAGING_APPLICATION_EXECUTABLE"
swiftc -warnings-as-errors -O \
  "$APPLICATION_SETTINGS_STORE_SOURCE_FILE" \
  "$APPLICATION_COMMAND_HELPER_SOURCE_FILE" \
  -o "$STAGING_APPLICATION_COMMAND_HELPER_EXECUTABLE"
chmod 755 "$STAGING_APPLICATION_COMMAND_HELPER_EXECUTABLE"
plutil -lint "$STAGING_APPLICATION_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$STAGING_APPLICATION_BUNDLE"
codesign --verify --deep --strict "$STAGING_APPLICATION_BUNDLE"

if [[ -d "$APPLICATION_BUNDLE" ]]; then
  mv "$APPLICATION_BUNDLE" "$PREVIOUS_APPLICATION_BUNDLE"
fi
application_replaced=true
mv "$STAGING_APPLICATION_BUNDLE" "$APPLICATION_BUNDLE"

if [[ "$installation_mode" == "--prepare" ]]; then
  rm -rf "$PREVIOUS_APPLICATION_BUNDLE"
  installation_succeeded=true
  rm -f "$APPLICATION_INSTALL_LOCK_FILE"
  application_install_lock_acquired=false
  trap - EXIT INT TERM
  echo "BCS VPN.app подготовлен в $APPLICATION_BUNDLE."
  echo "Добавьте BCS VPN.app в прямое правило Proxifier, затем откройте приложение."
  exit 0
fi

launch_agent_is_loaded "$LAUNCH_AGENT_LABEL" && new_agent_was_loaded=true
launch_agent_is_loaded "$OLD_MENU_LABEL" && old_menu_was_loaded=true
launch_agent_is_loaded "$OLD_FALLBACK_LABEL" && old_fallback_was_loaded=true
backup_launch_agent_files

if ! /usr/bin/shlock -f "$LIFECYCLE_LOCK_FILE" -p $$; then
  echo "Другая операция подключения, отключения или установки ещё выполняется." >&2
  exit 1
fi
lifecycle_lock_acquired=true
if [[ "$("$SCRIPT_DIRECTORY/status.sh")" != "disconnected" ]]; then
  echo "Состояние VPN изменилось во время подготовки; активация отменена." >&2
  exit 1
fi

agents_stopped=true
launchctl bootout "$LAUNCH_AGENT_DOMAIN/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
launchctl bootout "$LAUNCH_AGENT_DOMAIN/$OLD_MENU_LABEL" 2>/dev/null || true
launchctl bootout "$LAUNCH_AGENT_DOMAIN/$OLD_FALLBACK_LABEL" 2>/dev/null || true

cp "$GENERATED_PLIST" "$INSTALLED_PLIST"
chmod 644 "$INSTALLED_PLIST"
if ! launchctl bootstrap "$LAUNCH_AGENT_DOMAIN" "$INSTALLED_PLIST"; then
  echo "Не удалось зарегистрировать единый LaunchAgent BCS VPN." >&2
  exit 1
fi
launchctl enable "$LAUNCH_AGENT_DOMAIN/$LAUNCH_AGENT_LABEL"
launchctl kickstart -k "$LAUNCH_AGENT_DOMAIN/$LAUNCH_AGENT_LABEL"

application_is_ready=false
for _ in $(seq 1 30); do
  launch_agent_process_id="$(
    launchctl print "$LAUNCH_AGENT_DOMAIN/$LAUNCH_AGENT_LABEL" 2>/dev/null \
      | /usr/bin/sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p'
  )"
  if [[ -n "$launch_agent_process_id" ]] && \
    [[ "$(ps -ww -p "$launch_agent_process_id" -o comm= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" == "$APPLICATION_EXECUTABLE" ]] && \
    lsof -nP -a -p "$launch_agent_process_id" -iTCP@127.0.0.1:8889 -sTCP:LISTEN \
      2>/dev/null | grep -q '127.0.0.1:8889'; then
    socks_response="$(
      printf '\x05\x01\x00' \
        | nc -w 1 127.0.0.1 8889 \
        | od -An -tx1 \
        | tr -d '[:space:]'
    )"
    if [[ "$socks_response" == "0500" ]]; then
      application_is_ready=true
      break
    fi
  fi
  sleep 1
done

if [[ "$application_is_ready" != true ]]; then
  echo "BCS VPN.app не запустил меню или fallback SOCKS5. Проверьте $LOG_FILE." >&2
  exit 1
fi

rm -f "$OLD_MENU_PLIST" "$OLD_FALLBACK_PLIST"
if [[ ! -f "$INSTALLED_PLIST" || -e "$OLD_MENU_PLIST" || -e "$OLD_FALLBACK_PLIST" ]]; then
  echo "Не удалось заменить файлы LaunchAgent." >&2
  exit 1
fi

installation_succeeded=true
rm -f "$LIFECYCLE_LOCK_FILE"
lifecycle_lock_acquired=false
rm -f "$APPLICATION_INSTALL_LOCK_FILE"
application_install_lock_acquired=false
trap - EXIT INT TERM
rm -rf "$PREVIOUS_APPLICATION_BUNDLE" "$BACKUP_DIRECTORY"
rm -f \
  "$INSTALLATION_DIRECTORY/cisco-vpn-menu-bar" \
  "$INSTALLATION_DIRECTORY/cisco-vpn-fallback-proxy" \
  "$RUN_DIRECTORY/com.bcs.cisco-vpn-menu-bar.plist" \
  "$RUN_DIRECTORY/com.bcs.cisco-vpn-fallback-proxy.plist"

echo "BCS VPN.app активирован. Меню и fallback SOCKS5 работают в одном процессе."
