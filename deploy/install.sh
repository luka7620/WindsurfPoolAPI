#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-windsurfpool}"
DEPLOY_DIR="${DEPLOY_DIR:-$(pwd)}"
STATE_DIR="${STATE_DIR:-}"
ENV_FILE="${ENV_FILE:-}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DEFAULT_IMAGE="${WINDSURFPOOL_IMAGE:-luka762/windsurfpool:latest}"
APP_UID="${APP_UID:-10001}"
APP_GID="${APP_GID:-10001}"
DOCKER_BIN="${DOCKER_BIN:-}"
YES=0
PURGE=0
ACTION="install"

usage() {
  cat <<USAGE
Usage: install.sh [install|uninstall] [-y] [--purge]

Environment overrides:
  SERVICE_NAME=windsurfpool
  DEPLOY_DIR=$(pwd)
  STATE_DIR=\${DEPLOY_DIR}/state
  WINDSURFPOOL_IMAGE=${DEFAULT_IMAGE}
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    install) ACTION="install" ;;
    uninstall) ACTION="uninstall" ;;
    -y|--yes) YES=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root, for example: curl -sSL URL | sudo bash" >&2
    exit 1
  fi
}

confirm() {
  if [ "$YES" -eq 1 ]; then
    return 0
  fi
  printf "%s [y/N] " "$1"
  read -r ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

detect_ls_binary() {
  case "$(uname -m)" in
    aarch64|arm64) echo "/opt/windsurf/language_server_linux_arm" ;;
    x86_64|amd64) echo "/opt/windsurf/language_server_linux_x64" ;;
    *) echo "/opt/windsurf/language_server_linux_x64" ;;
  esac
}

ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}

normalize_paths() {
  install -d -m 0755 "$DEPLOY_DIR"
  DEPLOY_DIR="$(cd "$DEPLOY_DIR" && pwd)"

  if [ -z "$STATE_DIR" ]; then
    STATE_DIR="${DEPLOY_DIR}/state"
  elif [ "${STATE_DIR#/}" = "$STATE_DIR" ]; then
    STATE_DIR="${DEPLOY_DIR}/${STATE_DIR}"
  fi

  if [ -z "$ENV_FILE" ]; then
    ENV_FILE="${DEPLOY_DIR}/.env"
  elif [ "${ENV_FILE#/}" = "$ENV_FILE" ]; then
    ENV_FILE="${DEPLOY_DIR}/${ENV_FILE}"
  fi
}

write_env_file() {
  local ls_path="$1"
  if [ -f "$ENV_FILE" ]; then
    echo "Keeping existing env file: $ENV_FILE"
    return
  fi

  install -d -m 0755 "$DEPLOY_DIR"
  cat > "$ENV_FILE" <<EOF
WINDSURFPOOL_IMAGE=${DEFAULT_IMAGE}
HOST_PORT=3003
PORT=3003

API_KEY=
DASHBOARD_PASSWORD=change-me

CODEIUM_API_KEY=
CODEIUM_AUTH_TOKEN=

LS_BINARY_PATH=${ls_path}
LS_PORT=42100
LS_DATA_DIR=/app/data

CODEIUM_API_URL=https://server.self-serve.windsurf.com
DEFAULT_MODEL=claude-4.5-sonnet-thinking
MAX_TOKENS=8192
LOG_LEVEL=info
LOG_DIR=/app/logs

CASCADE_MAX_HISTORY_BYTES=200000
EOF
  chmod 0600 "$ENV_FILE"
  echo "Created env file: $ENV_FILE"
}

ensure_data_files() {
  install -d -m 0755 "$STATE_DIR" "$STATE_DIR/logs" "$STATE_DIR/ls-data"
  [ -f "$STATE_DIR/accounts.json" ] || printf '[]\n' > "$STATE_DIR/accounts.json"
  [ -f "$STATE_DIR/stats.json" ] || printf '{}\n' > "$STATE_DIR/stats.json"
  [ -f "$STATE_DIR/runtime-config.json" ] || printf '{}\n' > "$STATE_DIR/runtime-config.json"
  [ -f "$STATE_DIR/proxy.json" ] || printf '{"global":null,"perAccount":{}}\n' > "$STATE_DIR/proxy.json"
  [ -f "$STATE_DIR/model-access.json" ] || printf '{"mode":"all","list":[]}\n' > "$STATE_DIR/model-access.json"
  chown -R "${APP_UID}:${APP_GID}" "$STATE_DIR"
}

write_service() {
  local docker_bin="$1"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=WindsurfPoolAPI Docker service
Documentation=https://github.com/luka7620/WindsurfPoolAPI
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${DEPLOY_DIR}
EnvironmentFile=${ENV_FILE}
ExecStartPre=-${docker_bin} rm -f ${SERVICE_NAME}
ExecStartPre=${docker_bin} pull \${WINDSURFPOOL_IMAGE}
ExecStart=${docker_bin} run --name ${SERVICE_NAME} --rm \\
  --env-file ${ENV_FILE} \\
  --publish \${HOST_PORT}:\${PORT} \\
  --mount type=bind,source=/opt/windsurf,target=/opt/windsurf,readonly \\
  --mount type=bind,source=${STATE_DIR}/accounts.json,target=/app/accounts.json \\
  --mount type=bind,source=${STATE_DIR}/stats.json,target=/app/stats.json \\
  --mount type=bind,source=${STATE_DIR}/runtime-config.json,target=/app/runtime-config.json \\
  --mount type=bind,source=${STATE_DIR}/proxy.json,target=/app/proxy.json \\
  --mount type=bind,source=${STATE_DIR}/model-access.json,target=/app/model-access.json \\
  --mount type=bind,source=${STATE_DIR}/logs,target=/app/logs \\
  --mount type=bind,source=${STATE_DIR}/ls-data,target=/app/data \\
  \${WINDSURFPOOL_IMAGE}
ExecStop=${docker_bin} stop ${SERVICE_NAME}
Restart=always
RestartSec=5
TimeoutStartSec=0
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

install_service() {
  require_root
  ensure_command docker
  ensure_command systemctl

  local ls_path
  local docker_bin
  normalize_paths
  ls_path="$(detect_ls_binary)"
  docker_bin="${DOCKER_BIN:-$(command -v docker)}"
  write_env_file "$ls_path"
  ensure_data_files
  write_service "$docker_bin"

  if [ ! -x "$ls_path" ]; then
    echo "Warning: Windsurf language server was not found or is not executable:"
    echo "  $ls_path"
    echo "Place it under /opt/windsurf and run: chmod +x $ls_path"
  fi

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"

  echo "Installed ${SERVICE_NAME}."
  echo "Edit config: ${ENV_FILE}"
  echo "Deploy dir: ${DEPLOY_DIR}"
  echo "State dir: ${STATE_DIR}"
  echo "Status: sudo systemctl status ${SERVICE_NAME}"
  echo "Logs: sudo journalctl -u ${SERVICE_NAME} -f"
}

uninstall_service() {
  require_root
  normalize_paths
  if ! confirm "Uninstall ${SERVICE_NAME}?"; then
    echo "Cancelled."
    exit 0
  fi

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  docker rm -f "$SERVICE_NAME" >/dev/null 2>&1 || true

  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$DEPLOY_DIR"
    echo "Removed ${DEPLOY_DIR}."
  else
    echo "Kept deploy directory:"
    echo "  ${DEPLOY_DIR}"
  fi
  echo "Uninstalled ${SERVICE_NAME}."
}

case "$ACTION" in
  install) install_service ;;
  uninstall) uninstall_service ;;
  *) usage; exit 1 ;;
esac
