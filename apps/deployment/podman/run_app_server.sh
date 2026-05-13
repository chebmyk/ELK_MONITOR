#!/usr/bin/env bash
# podman-add-server.sh — manage on-demand app_mock pods via podman play kube
#
# Each environment runs as an independent pod connected to the elk-monitor
# network. app_server.py is baked into the image; the selected
# app_config_* directory is mounted as /app at runtime.
#
# Usage (run from anywhere):
#   apps/deployment/podman/run_app_server.sh start <env_name> [config_name]
#   apps/deployment/podman/run_app_server.sh stop  <env_name>
#   apps/deployment/podman/run_app_server.sh list
#   apps/deployment/podman/run_app_server.sh logs  <env_name>
#   apps/deployment/podman/run_app_server.sh build
set -euo pipefail

# ── Locate project root ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"
cd "$PROJECT_DIR"

KUBE_TEMPLATE="${SCRIPT_DIR}/podman-kube-app-mock.yml"
APPS_DIR="${PROJECT_DIR}/apps"
STATE_FILE="${APPS_DIR}/.env_configs"   # persists env_name → config_name mappings
NETWORK="elk-monitor"

log() { echo "[$(date '+%H:%M:%S')] ==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v podman   &>/dev/null || die "podman is not installed"
command -v envsubst &>/dev/null || die "envsubst not found — install gettext: sudo dnf install -y gettext"

usage() {
  cat <<EOF
Usage: $0 <command> [env_name] [config_name]

Commands:
  start  <env_name> [config]  Start a mock pod; prompts for config if omitted
  stop   <env_name>           Stop and remove the mock pod
  list                        List running pods and available configs
  logs   <env_name>           Tail container logs for a running mock pod
  build                       Build (or rebuild) the shared localhost/app-mock:latest image

Available configs:
$(for d in "${APPS_DIR}"/app_config_*/; do [[ -d "$d" ]] && echo "  $(basename "$d")"; done 2>/dev/null || echo "  (none found)")

Examples:
  $0 start staging
  $0 start staging app_config_v1
  $0 stop  staging
  $0 list
EOF
  exit 1
}

# ── List available app_config_* directories ───────────────────────────────────
list_configs() {
  local configs=()
  for d in "${APPS_DIR}"/app_config_*/; do
    [[ -d "$d" ]] && configs+=("$(basename "$d")")
  done
  echo "${configs[@]:-}"
}

# ── Prompt user to select a config ────────────────────────────────────────────
select_config() {
  local configs
  read -ra configs <<< "$(list_configs)"
  [[ ${#configs[@]} -eq 0 ]] && die "No app_config_* directories found under ${APPS_DIR}"

  if [[ ${#configs[@]} -eq 1 ]]; then
    log "Using only available config: ${configs[0]}"
    echo "${configs[0]}"
    return
  fi

  echo "" >&2
  echo "Select a config to mount:" >&2
  select cfg in "${configs[@]}"; do
    [[ -n "$cfg" ]] && echo "$cfg" && return
    echo "Invalid selection, try again." >&2
  done
}

# ── Persist / retrieve env → config mapping ───────────────────────────────────
save_mapping() {
  local env_name="$1" config_name="$2"
  touch "$STATE_FILE"
  grep -v "^${env_name}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  echo "${env_name}=${config_name}" >> "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

load_mapping() {
  local env_name="$1"
  grep "^${env_name}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true
}

remove_mapping() {
  local env_name="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  grep -v "^${env_name}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# ── Ensure the app-mock image is built ────────────────────────────────────────
ensure_image() {
  if ! podman image exists localhost/app-mock:latest; then
    log "localhost/app-mock:latest not found — building..."
    podman build -t localhost/app-mock:latest -f apps/deployment/Dockerfile apps/
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
CMD="${1:-}"
ENV_NAME="${2:-}"

[[ -n "$CMD" ]] || usage

case "$CMD" in

  start)
    [[ -n "$ENV_NAME" ]] || die "env_name required"

    # Resolve config: use 3rd arg if provided, otherwise prompt
    if [[ -n "${3:-}" ]]; then
      CONFIG_NAME="$3"
    else
      CONFIG_NAME="$(select_config)"
    fi

    APP_DIR="${APPS_DIR}/${CONFIG_NAME}"
    [[ -d "$APP_DIR" ]] || die "Config directory not found: ${APP_DIR}"
    mkdir -p "${APP_DIR}/logs"

    ensure_image
    save_mapping "$ENV_NAME" "$CONFIG_NAME"

    export ENV_NAME APP_DIR

    log "Starting pod app-mock-${ENV_NAME} with config '${CONFIG_NAME}'..."
    envsubst < "$KUBE_TEMPLATE" | podman play kube --network "$NETWORK" -
    log "Pod app-mock-${ENV_NAME} is up (config: ${CONFIG_NAME})"
    ;;

  stop)
    [[ -n "$ENV_NAME" ]] || die "env_name required"

    # Resolve config from state file for envsubst interpolation
    CONFIG_NAME="$(load_mapping "$ENV_NAME")"
    if [[ -z "$CONFIG_NAME" ]]; then
      read -ra _cfgs <<< "$(list_configs)"
      CONFIG_NAME="${_cfgs[0]:-app_config_v1}"
    fi
    APP_DIR="${APPS_DIR}/${CONFIG_NAME}"

    export ENV_NAME APP_DIR

    log "Stopping pod app-mock-${ENV_NAME}..."
    envsubst < "$KUBE_TEMPLATE" | podman play kube --down -
    remove_mapping "$ENV_NAME"
    log "Done"
    ;;

  list)
    echo ""
    echo "Running app-mock pods:"
    echo "────────────────────────────────────────"
    podman pod ps --filter label=component=app-mock \
      --format "  {{.Name}}\t{{.Status}}"
    echo ""
    echo "Available config directories:"
    for d in "${APPS_DIR}"/app_config_*/; do
      [[ -d "$d" ]] && echo "  $(basename "$d")"
    done
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
      echo ""
      echo "Active env → config mappings:"
      sed 's/^/  /' "$STATE_FILE"
    fi
    echo ""
    ;;

  logs)
    [[ -n "$ENV_NAME" ]] || die "env_name required"
    # Podman container name pattern: <pod-name>-<container-name>
    podman logs -f "app-mock-${ENV_NAME}-app-mock-${ENV_NAME}"
    ;;

  build)
    log "Building localhost/app-mock:latest..."
    podman build -t localhost/app-mock:latest -f apps/deployment/Dockerfile apps/
    log "Build complete"
    ;;

  *)
    usage
    ;;
esac