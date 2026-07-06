#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Hermes iOS Channel"
SERVICE_NAME="hermes-ios-channel"
DEFAULT_INSTALL_DIR="$HOME/.hermes-ios-channel"
DEFAULT_HERMES_API_URL="http://127.0.0.1:8642"
DEFAULT_HERMES_API_HOST="127.0.0.1"
DEFAULT_HERMES_API_PORT="8642"
DEFAULT_BIND_HOST="0.0.0.0"
DEFAULT_PORT="3001"
DEFAULT_APP_STORE_URL="${HERMES_IOS_APP_STORE_URL:-}"
BACKED_UP_ENV_FILES=":"
BACKUP_MANIFEST=""
CREATED_INSTALL_DIR=""
CREATED_SERVICE_FILE=""
INSTALL_COMPLETE="no"

usage() {
  cat <<'USAGE'
Usage:
  ./install-server.sh

Installs the Hermes iOS Channel server for macOS or Linux. The installer copies
the channel server files, keeps a local source copy for the iOS app, creates a
Python virtual environment, writes server/.env, and optionally registers a user
service.

Advanced environment overrides:
  HERMES_AGENT_ENV_FILE       Hermes .env path, default: ~/.hermes/.env
  HERMES_AGENT_CONFIG_PATH    Hermes config path, default: beside .env
  HERMES_AGENT_STATE_DB       Hermes state DB path, default: beside .env
  HERMES_AGENT_MEMORIES_PATH  Hermes memories path, default: beside .env
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

say() {
  printf '%s\n' "$*"
}

prompt() {
  local label="$1"
  local default="$2"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value || value=""
    printf '%s' "${value:-$default}"
  else
    read -r -p "$label: " value || value=""
    printf '%s' "$value"
  fi
}

prompt_secret() {
  local label="$1"
  local value
  read -r -s -p "$label (leave blank if not required): " value || value=""
  printf '\n' >&2
  printf '%s' "$value"
}

prompt_yes_no() {
  local label="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  local value
  if [[ "$default" == "y" ]]; then
    suffix="[Y/n]"
  fi
  read -r -p "$label $suffix: " value || value="$default"
  value="${value:-$default}"
  [[ "$value" == "y" || "$value" == "Y" || "$value" == "yes" || "$value" == "YES" ]]
}

rollback_install() {
  say "Rolling back..."
  if [[ -n "$BACKUP_MANIFEST" ]]; then
    while IFS='|' read -r original backup; do
      if [[ -n "$original" && -f "$backup" ]]; then
        cp -p "$backup" "$original"
        say "Restored $original from $backup"
      fi
    done <<< "$BACKUP_MANIFEST"
  fi
  if [[ -n "$CREATED_SERVICE_FILE" && -f "$CREATED_SERVICE_FILE" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      launchctl bootout "gui/$(id -u)" "$CREATED_SERVICE_FILE" >/dev/null 2>&1 || true
    else
      systemctl --user disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    fi
    rm -f "$CREATED_SERVICE_FILE"
    if [[ "$(uname -s)" != "Darwin" ]] && command -v systemctl >/dev/null 2>&1; then
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    say "Removed service: $CREATED_SERVICE_FILE"
  fi
  if [[ -n "$CREATED_INSTALL_DIR" && -d "$CREATED_INSTALL_DIR" ]]; then
    rm -rf "$CREATED_INSTALL_DIR"
    say "Removed $CREATED_INSTALL_DIR"
  fi
  say "Rollback complete."
}

on_exit() {
  local rc=$?
  if [[ $rc -eq 0 || "$INSTALL_COMPLETE" == "yes" ]]; then
    return
  fi
  say
  say "Install did not complete (exit code $rc)."
  if [[ -z "$BACKUP_MANIFEST" && -z "$CREATED_SERVICE_FILE" && -z "$CREATED_INSTALL_DIR" ]]; then
    say "No changes were made; nothing to roll back."
    return
  fi
  if prompt_yes_no "Roll back the changes made by this run?" "y"; then
    rollback_install
  else
    say "Left partial install in place. Changed files:"
    if [[ -n "$BACKUP_MANIFEST" ]]; then
      while IFS='|' read -r original backup; do
        [[ -n "$original" ]] && say "  $original (backup: $backup)"
      done <<< "$BACKUP_MANIFEST"
    fi
    [[ -n "$CREATED_SERVICE_FILE" ]] && say "  $CREATED_SERVICE_FILE"
    [[ -n "$CREATED_INSTALL_DIR" ]] && say "  $CREATED_INSTALL_DIR"
  fi
}

trap on_exit EXIT
trap 'exit 130' INT TERM

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    say "Missing required command: $1"
    exit 1
  fi
}

generate_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  fi
}

expand_home() {
  local path="$1"
  case "$path" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${path#~/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

copy_server_files() {
  local repo_root="$1"
  local server_dir="$2"
  mkdir -p "$server_dir"
  cp "$repo_root/server/server.py" "$server_dir/server.py"
  cp "$repo_root/server/requirements.txt" "$server_dir/requirements.txt"
  cp "$repo_root/server/readiness_check.py" "$server_dir/readiness_check.py"
  cp "$repo_root/server/README.md" "$server_dir/README.md"
  cp "$repo_root/server/.env.example" "$server_dir/.env.example"
  cp "$repo_root/server/voice-inventory.example.json" "$server_dir/voice-inventory.example.json"
  rm -rf "$server_dir/hermes-plugins"
  cp -R "$repo_root/server/hermes-plugins" "$server_dir/hermes-plugins"
}

copy_source_files() {
  local repo_root="$1"
  local source_dir="$2"
  rm -rf "$source_dir"
  mkdir -p "$source_dir"

  cp -R "$repo_root/hermes-ios" "$source_dir/hermes-ios"
  cp "$repo_root/install-server.sh" "$source_dir/install-server.sh"
  if [[ -f "$repo_root/install.sh" ]]; then
    cp "$repo_root/install.sh" "$source_dir/install.sh"
  fi

  for doc in README.md INFRASTRUCTURE.md LICENSE SECURITY.md PRIVACY.md; do
    if [[ -f "$repo_root/$doc" ]]; then
      cp "$repo_root/$doc" "$source_dir/$doc"
    fi
  done
}

write_env() {
  local env_path="$1"
  local hermes_api_url="$2"
  local hermes_api_key="$3"
  local bind_host="$4"
  local port="$5"
  local interface_key="$6"
  local db_path="$7"
  local state_db="$8"
  local memories_path="$9"
  local config_path="${10}"
  local voice_inventory_path="${11}"

  cat > "$env_path" <<EOF
HERMES_API_URL=$hermes_api_url
HERMES_API_KEY=$hermes_api_key
HERMES_INTERFACE_HOST=$bind_host
HERMES_INTERFACE_PORT=$port
HERMES_INTERFACE_KEY=$interface_key
HERMES_INTERFACE_DB=$db_path
HERMES_STATE_DB=$state_db
HERMES_MEMORIES_PATH=$memories_path
HERMES_CONFIG_PATH=$config_path
HERMES_VOICE_INVENTORY_PATH=$voice_inventory_path
EOF
  chmod 600 "$env_path"
}

write_voice_inventory_template() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]]; then
    return 0
  fi
  cat > "$path" <<'EOF'
{
  "providers": {}
}
EOF
  chmod 600 "$path"
}

first_existing_dir() {
  for candidate in "$@"; do
    if [[ -d "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

env_value() {
  local env_path="$1"
  local key="$2"
  if [[ ! -f "$env_path" ]]; then
    return 1
  fi
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$env_path"
}

backup_file_once() {
  local path="$1"
  if [[ ! -f "$path" || "$BACKED_UP_ENV_FILES" == *":$path:"* ]]; then
    return 0
  fi
  local backup_path="$path.backup.$(date +%Y%m%d%H%M%S)"
  cp -p "$path" "$backup_path"
  BACKED_UP_ENV_FILES="$BACKED_UP_ENV_FILES$path:"
  BACKUP_MANIFEST="${BACKUP_MANIFEST:+$BACKUP_MANIFEST
}$path|$backup_path"
  say "Backed up $path to $backup_path"
}

set_env_value() {
  local env_path="$1"
  local key="$2"
  local value="$3"
  local tmp_path
  mkdir -p "$(dirname "$env_path")"
  backup_file_once "$env_path"
  touch "$env_path"
  chmod 600 "$env_path"
  tmp_path="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ "^" key "=" {
      if (!found) {
        print key "=" value
        found = 1
      }
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" value
      }
    }
  ' "$env_path" > "$tmp_path"
  mv "$tmp_path" "$env_path"
  chmod 600 "$env_path"
}

check_hermes_models() {
  local api_url="$1"
  local api_key="$2"
  python3 - "$api_url" "$api_key" <<'PY'
import json
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

api_url = sys.argv[1].rstrip("/")
api_key = sys.argv[2]
headers = {}
if api_key:
    headers["Authorization"] = f"Bearer {api_key}"
req = Request(f"{api_url}/v1/models", headers=headers, method="GET")
try:
    with urlopen(req, timeout=5) as resp:
        payload = json.loads(resp.read().decode("utf-8", "replace") or "{}")
except HTTPError as exc:
    body = exc.read().decode("utf-8", "replace")
    print(f"HTTP {exc.code}: {body[:200]}", file=sys.stderr)
    sys.exit(2)
except (URLError, TimeoutError) as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(3)

models = payload.get("data") if isinstance(payload, dict) else None
if not isinstance(models, list):
    models = payload.get("models") if isinstance(payload, dict) else None
if not isinstance(models, list) or not models:
    print("Hermes responded, but no models were returned.", file=sys.stderr)
    sys.exit(4)
print(f"{len(models)} model(s)")
PY
}

port_available() {
  local host="$1"
  local port="$2"
  python3 - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind((host, port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}

first_available_port() {
  local host="$1"
  local start_port="$2"
  local port="$start_port"
  while [[ "$port" -lt 65535 ]]; do
    if port_available "$host" "$port"; then
      printf '%s' "$port"
      return 0
    fi
    port=$((port + 1))
  done
  return 1
}

detect_or_configure_hermes_api() {
  local out_file="$1"
  local hermes_env
  hermes_env="$(expand_home "${HERMES_AGENT_ENV_FILE:-$HOME/.hermes/.env}")"
  local default_hermes_env="$HOME/.hermes/.env"
  local hermes_base
  hermes_base="$(dirname "$hermes_env")"
  local hermes_config
  hermes_config="$(expand_home "${HERMES_AGENT_CONFIG_PATH:-$hermes_base/config.yaml}")"
  local hermes_state
  hermes_state="$(expand_home "${HERMES_AGENT_STATE_DB:-$hermes_base/state.db}")"
  local hermes_memories
  hermes_memories="$(expand_home "${HERMES_AGENT_MEMORIES_PATH:-$hermes_base/memories}")"
  local api_host
  local api_port
  local api_url
  local api_key

  if ! prompt_yes_no "Use local Hermes auto-detection?" "y"; then
    api_url="$(prompt "Hermes API URL" "$DEFAULT_HERMES_API_URL")"
    api_key="$(prompt_secret "Hermes API bearer token")"
    {
      printf 'HERMES_API_URL=%s\n' "$api_url"
      printf 'HERMES_API_KEY=%s\n' "$api_key"
      printf 'HERMES_STATE_DB=%s\n' "$hermes_state"
      printf 'HERMES_MEMORIES_PATH=%s\n' "$hermes_memories"
      printf 'HERMES_CONFIG_PATH=%s\n' "$hermes_config"
    } > "$out_file"
    return 0
  fi

  say
  say "Checking local Hermes install..."
  if command -v hermes >/dev/null 2>&1; then
    say "Found Hermes command: $(command -v hermes)"
  else
    say "Hermes command was not found on PATH."
    say "Install Hermes first, then re-run this installer:"
    say "  curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
    exit 1
  fi

  mkdir -p "$hermes_base"
  if [[ ! -f "$hermes_env" ]]; then
    if prompt_yes_no "Create $hermes_env for Hermes API settings?" "y"; then
      touch "$hermes_env"
      chmod 600 "$hermes_env"
    else
      say "Cannot auto-configure Hermes without $hermes_env."
      exit 1
    fi
  fi

  api_host="$(env_value "$hermes_env" "API_SERVER_HOST" || true)"
  api_host="${api_host:-$DEFAULT_HERMES_API_HOST}"
  api_port="$(env_value "$hermes_env" "API_SERVER_PORT" || true)"
  api_port="${api_port:-$DEFAULT_HERMES_API_PORT}"
  case "$api_port" in
    ''|*[!0-9]*)
      say "Hermes API port in $hermes_env is not numeric: $api_port"
      api_port="$(prompt "Hermes API port" "$DEFAULT_HERMES_API_PORT")"
      ;;
  esac
  api_key="$(env_value "$hermes_env" "API_SERVER_KEY" || true)"

  local api_port_was_configured="yes"
  if [[ -z "$(env_value "$hermes_env" "API_SERVER_PORT" || true)" ]]; then
    api_port_was_configured="no"
  fi
  if [[ "$api_port_was_configured" == "no" ]]; then
    if ! port_available "$api_host" "$api_port"; then
      local alternate_port
      alternate_port="$(first_available_port "$api_host" "$((api_port + 1))" || true)"
      say "Port $api_port is already in use on $api_host."
      if [[ -n "$alternate_port" ]] && prompt_yes_no "Use port $alternate_port for this Hermes install?" "y"; then
        api_port="$alternate_port"
      else
        api_port="$(prompt "Hermes API port" "${alternate_port:-$api_port}")"
      fi
    fi
  fi

  local api_enabled
  api_enabled="$(env_value "$hermes_env" "API_SERVER_ENABLED" || true)"
  if [[ "$api_enabled" != "true" && "$api_enabled" != "True" && "$api_enabled" != "1" ]]; then
    if prompt_yes_no "Enable the Hermes API server in $hermes_env?" "y"; then
      set_env_value "$hermes_env" "API_SERVER_ENABLED" "true"
    else
      say "Hermes API server must be enabled for Hermes Mobile."
      exit 1
    fi
  fi

  if [[ -z "$api_key" ]]; then
    if prompt_yes_no "Generate a Hermes API key in $hermes_env?" "y"; then
      api_key="$(generate_key)"
      set_env_value "$hermes_env" "API_SERVER_KEY" "$api_key"
    else
      api_key="$(prompt_secret "Hermes API bearer token")"
    fi
  else
    say "Found Hermes API key in $hermes_env."
  fi

  if [[ -z "$(env_value "$hermes_env" "API_SERVER_HOST" || true)" ]]; then
    set_env_value "$hermes_env" "API_SERVER_HOST" "$api_host"
  fi
  if [[ -z "$(env_value "$hermes_env" "API_SERVER_PORT" || true)" ]]; then
    set_env_value "$hermes_env" "API_SERVER_PORT" "$api_port"
  fi

  api_url="http://$api_host:$api_port"
  say "Hermes API URL: $api_url"

  if check_hermes_models "$api_url" "$api_key" >/tmp/hermes-ios-channel-models.$$ 2>/tmp/hermes-ios-channel-models.err.$$; then
    say "Hermes API check passed: $(cat /tmp/hermes-ios-channel-models.$$)"
  else
    say "Hermes API did not answer with models yet."
    say "Details: $(cat /tmp/hermes-ios-channel-models.err.$$ 2>/dev/null || true)"
    say
    if prompt_yes_no "Start Hermes gateway in the background now?" "y"; then
      if [[ "$hermes_env" != "$default_hermes_env" ]]; then
        say "This installer is using a non-standard Hermes env file:"
        say "  $hermes_env"
        say "To avoid starting the wrong Hermes instance, start your Hermes gateway"
        say "with your custom layout in another terminal, then return here."
        say
        if ! prompt_yes_no "Press y after Hermes gateway is running to retry" "y"; then
          rm -f /tmp/hermes-ios-channel-models.$$ /tmp/hermes-ios-channel-models.err.$$
          exit 1
        fi
      else
        mkdir -p "$hermes_base/logs"
        nohup hermes gateway > "$hermes_base/logs/gateway.log" 2>&1 &
        say "Started Hermes gateway. Log: $hermes_base/logs/gateway.log"
        sleep 3
      fi
    else
      say "Start Hermes in another terminal, then come back here:"
      say "  hermes gateway"
      say
      if ! prompt_yes_no "Press y after Hermes gateway is running to retry" "y"; then
        rm -f /tmp/hermes-ios-channel-models.$$ /tmp/hermes-ios-channel-models.err.$$
        exit 1
      fi
    fi

    if check_hermes_models "$api_url" "$api_key" >/tmp/hermes-ios-channel-models.$$ 2>/tmp/hermes-ios-channel-models.err.$$; then
      say "Hermes API check passed: $(cat /tmp/hermes-ios-channel-models.$$)"
    else
      say "Hermes still did not return models."
      say "Details: $(cat /tmp/hermes-ios-channel-models.err.$$ 2>/dev/null || true)"
      say "You can continue, but the iOS app will not work until Hermes reports a brain model."
      if ! prompt_yes_no "Continue anyway?" "n"; then
        rm -f /tmp/hermes-ios-channel-models.$$ /tmp/hermes-ios-channel-models.err.$$
        exit 1
      fi
    fi
  fi
  rm -f /tmp/hermes-ios-channel-models.$$ /tmp/hermes-ios-channel-models.err.$$

  {
    printf 'HERMES_API_URL=%s\n' "$api_url"
    printf 'HERMES_API_KEY=%s\n' "$api_key"
    printf 'HERMES_STATE_DB=%s\n' "$hermes_state"
    printf 'HERMES_MEMORIES_PATH=%s\n' "$hermes_memories"
    printf 'HERMES_CONFIG_PATH=%s\n' "$hermes_config"
  } > "$out_file"
}

install_plugin_prompt() {
  local server_dir="$1"
  local default_plugin_dir
  default_plugin_dir="$(first_existing_dir \
    "$HOME/.hermes/hermes-agent/plugins" \
    "$HOME/.hermes/plugins" \
    "$HOME/.hermes/profiles/default/plugins" || true)"

  if [[ -z "$default_plugin_dir" ]]; then
    default_plugin_dir="$HOME/.hermes/hermes-agent/plugins"
  fi

  if ! prompt_yes_no "Copy optional Hermes toolset override plugin?" "n"; then
    return 0
  fi

  local plugin_dir
  plugin_dir="$(expand_home "$(prompt "Hermes plugin directory" "$default_plugin_dir")")"
  mkdir -p "$plugin_dir"

  local dest="$plugin_dir/toolset-override"
  if [[ -e "$dest" ]] && ! prompt_yes_no "Replace existing $dest?" "n"; then
    say "Skipped plugin copy."
    return 0
  fi

  rm -rf "$dest"
  cp -R "$server_dir/hermes-plugins/toolset-override" "$dest"
  say "Copied plugin to $dest"
}

write_macos_service() {
  local install_dir="$1"
  local server_dir="$2"
  local venv_python="$3"
  local log_dir="$install_dir/logs"
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist="$plist_dir/com.hermes.ios-channel.plist"
  mkdir -p "$log_dir" "$plist_dir"
  if [[ ! -f "$plist" ]]; then
    CREATED_SERVICE_FILE="$plist"
  fi
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hermes.ios-channel</string>
  <key>ProgramArguments</key>
  <array>
    <string>$venv_python</string>
    <string>$server_dir/server.py</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$server_dir</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/server.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/server.err.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  launchctl enable "gui/$(id -u)/com.hermes.ios-channel" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/com.hermes.ios-channel" >/dev/null 2>&1 || true
  say "Installed LaunchAgent: $plist"
}

write_linux_service() {
  local install_dir="$1"
  local server_dir="$2"
  local venv_python="$3"
  local service_dir="$HOME/.config/systemd/user"
  local unit="$service_dir/$SERVICE_NAME.service"
  mkdir -p "$service_dir" "$install_dir/logs"
  if [[ ! -f "$unit" ]]; then
    CREATED_SERVICE_FILE="$unit"
  fi
  cat > "$unit" <<EOF
[Unit]
Description=Hermes iOS Channel Server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$server_dir
ExecStart=$venv_python $server_dir/server.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$SERVICE_NAME.service"
  say "Installed systemd user service: $unit"
}

choose_ios_client() {
  local source_dir="$1"
  local app_store_url="$2"

  say
  say "iOS app options:"
  say "  1) Download from the Apple App Store"
  say "  2) Build locally with Xcode and an Apple Developer account"
  say "  3) Skip for now"
  say

  local choice
  read -r -p "Choose an iOS app option [3]: " choice
  choice="${choice:-3}"

  case "$choice" in
    1)
      if [[ -n "$app_store_url" ]]; then
        say
        say "Open this link on your iPhone:"
        say "  $app_store_url"
      else
        say
        say "The App Store link is not configured for this build yet."
        say "Set HERMES_IOS_APP_STORE_URL before release to print a direct link."
      fi
      ;;
    2)
      say
      say "The iOS source code is available here:"
      say "  $source_dir/hermes-ios"
      say
      say "First download the bundled speech-to-text model (~147 MB, one time):"
      say "  $source_dir/hermes-ios/fetch-models.sh"
      say
      say "Then open this project in Xcode:"
      say "  $source_dir/hermes-ios/HermesApp.xcodeproj"
      say
      say "Local iOS signing, provisioning, and device deployment require Xcode"
      say "and an Apple Developer account."
      ;;
    3)
      say
      say "Skipped iOS app setup."
      ;;
    *)
      say
      say "Unknown option; skipped iOS app setup."
      ;;
  esac
}

main() {
  require_cmd python3

  local os_name
  os_name="$(uname -s)"
  if [[ "$os_name" != "Darwin" && "$os_name" != "Linux" ]]; then
    say "Unsupported OS: $os_name"
    exit 1
  fi

  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ ! -f "$repo_root/server/server.py" ]]; then
    say "Run this installer from the root of the Hermes iOS Channel repository."
    exit 1
  fi

  say "$APP_NAME server installer"
  say
  say "Hermes keeps provider keys, model defaults, voice config, tools, and memory."
  say "This installer configures only the iOS channel server."
  say

  local install_dir
  install_dir="$(expand_home "$(prompt "Install directory" "$DEFAULT_INSTALL_DIR")")"
  local server_dir="$install_dir/server"
  local source_dir="$install_dir/source"
  local venv_dir="$install_dir/.venv"
  local data_dir="$install_dir/data"
  local env_path="$server_dir/.env"
  local write_channel_env="yes"
  local hermes_api_url
  local hermes_api_key
  local bind_host
  local port
  local interface_key
  local state_db
  local memories_path
  local config_path
  local voice_inventory_path

  if [[ -f "$env_path" ]] && ! prompt_yes_no "Overwrite existing $env_path?" "n"; then
    write_channel_env="no"
    hermes_api_url="$(env_value "$env_path" "HERMES_API_URL" || true)"
    hermes_api_key="$(env_value "$env_path" "HERMES_API_KEY" || true)"
    bind_host="$(env_value "$env_path" "HERMES_INTERFACE_HOST" || true)"
    bind_host="${bind_host:-$DEFAULT_BIND_HOST}"
    port="$(env_value "$env_path" "HERMES_INTERFACE_PORT" || true)"
    port="${port:-$DEFAULT_PORT}"
    interface_key="$(env_value "$env_path" "HERMES_INTERFACE_KEY" || true)"
    state_db="$(env_value "$env_path" "HERMES_STATE_DB" || true)"
    memories_path="$(env_value "$env_path" "HERMES_MEMORIES_PATH" || true)"
    config_path="$(env_value "$env_path" "HERMES_CONFIG_PATH" || true)"
    voice_inventory_path="$(env_value "$env_path" "HERMES_VOICE_INVENTORY_PATH" || true)"
    say "Kept existing $env_path; skipped Hermes auto-configuration."
    if [[ -z "$interface_key" ]] && prompt_yes_no "Existing channel config has no HERMES_INTERFACE_KEY. Generate one now?" "y"; then
      interface_key="$(generate_key)"
      set_env_value "$env_path" "HERMES_INTERFACE_KEY" "$interface_key"
    fi
  else
    local hermes_detect_file
    hermes_detect_file="$(mktemp)"
    detect_or_configure_hermes_api "$hermes_detect_file"
    hermes_api_url="$(env_value "$hermes_detect_file" "HERMES_API_URL" || true)"
    hermes_api_key="$(env_value "$hermes_detect_file" "HERMES_API_KEY" || true)"
    bind_host="$(prompt "Channel bind host" "$DEFAULT_BIND_HOST")"
    port="$(prompt "Channel port" "$DEFAULT_PORT")"
    interface_key="$(generate_key)"
    state_db="$(env_value "$hermes_detect_file" "HERMES_STATE_DB" || true)"
    memories_path="$(env_value "$hermes_detect_file" "HERMES_MEMORIES_PATH" || true)"
    config_path="$(env_value "$hermes_detect_file" "HERMES_CONFIG_PATH" || true)"
    rm -f "$hermes_detect_file"

    if prompt_yes_no "Review or change Hermes storage paths?" "n"; then
      state_db="$(expand_home "$(prompt "Hermes state database" "$state_db")")"
      memories_path="$(expand_home "$(prompt "Hermes memories directory" "$memories_path")")"
      config_path="$(expand_home "$(prompt "Hermes config file" "$config_path")")"
    fi
  fi

  if [[ ! -d "$install_dir" ]]; then
    CREATED_INSTALL_DIR="$install_dir"
  fi
  mkdir -p "$install_dir" "$data_dir"
  voice_inventory_path="${voice_inventory_path:-$data_dir/voice-inventory.json}"
  copy_server_files "$repo_root" "$server_dir"
  copy_source_files "$repo_root" "$source_dir"
  write_voice_inventory_template "$voice_inventory_path"

  if [[ ! -d "$venv_dir" ]]; then
    python3 -m venv "$venv_dir"
  fi
  "$venv_dir/bin/python" -m pip install --upgrade pip
  "$venv_dir/bin/python" -m pip install -r "$server_dir/requirements.txt"

  if [[ "$write_channel_env" == "yes" ]]; then
    write_env "$env_path" "$hermes_api_url" "$hermes_api_key" "$bind_host" "$port" "$interface_key" \
      "$data_dir/chats.db" "$state_db" "$memories_path" "$config_path" "$voice_inventory_path"
  elif [[ -z "$(env_value "$env_path" "HERMES_VOICE_INVENTORY_PATH" || true)" ]]; then
    set_env_value "$env_path" "HERMES_VOICE_INVENTORY_PATH" "$voice_inventory_path"
  fi

  install_plugin_prompt "$server_dir"

  local service_installed="no"
  if prompt_yes_no "Install and start as a background user service?" "n"; then
    if [[ "$os_name" == "Darwin" ]]; then
      write_macos_service "$install_dir" "$server_dir" "$venv_dir/bin/python"
      service_installed="yes"
    elif command -v systemctl >/dev/null 2>&1; then
      write_linux_service "$install_dir" "$server_dir" "$venv_dir/bin/python"
      service_installed="yes"
    else
      say "systemctl not found; skipping service install."
    fi
  fi

  INSTALL_COMPLETE="yes"
  say
  say "Install complete."
  say
  if [[ -n "$interface_key" ]]; then
    say "Channel API key for the iOS app:"
    say "$interface_key"
    say
  else
    say "Channel API key for the iOS app is in:"
    say "  $env_path"
    say
  fi
  say "Use this server URL from the iPhone:"
  say "  http://<this-machine-lan-or-tailscale-address>:$port"
  say
  say "Local source copy:"
  say "  $source_dir"
  say
  say "Readiness check:"
  say "  $venv_dir/bin/python $server_dir/readiness_check.py --server-url http://127.0.0.1:$port --interface-key $interface_key"
  say
  if [[ "$service_installed" != "yes" ]]; then
    say "Start in the foreground:"
    say "  cd $server_dir"
    say "  $venv_dir/bin/python server.py"
  fi

  choose_ios_client "$source_dir" "$DEFAULT_APP_STORE_URL"
}

main "$@"
