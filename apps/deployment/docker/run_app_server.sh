#!/usr/bin/env bash
# run_app_server.sh — manage on-demand app_mock environments
#
# Each environment runs as an independent container connected to the elk-monitor
# cluster network. app_server.py is baked into the image; the selected
# app_config_* directory is mounted as /app at runtime.
#
# Usage (run from anywhere):
#   apps/deployment/docker/run_app_server.sh start <env_name> [config_name]
#   apps/deployment/docker/run_app_server.sh stop  <env_name>
#   apps/deployment/docker/run_app_server.sh list
#   apps/deployment/docker/run_app_server.sh logs  <env_name>
#   apps/deployment/docker/run_app_server.sh build
set -euo pipefail

# ── Locate project root ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"
cd "$PROJECT_DIR"

APPS_DIR="${PROJECT_DIR}/apps"
STATE_FILE="${APPS_DIR}/.env_configs"   # persists env_name → config_name mappings

# ── Parse flags (--agent, --all) before positional arguments ─────────────────
USE_AGENT=false
BUILD_ALL=false
_PARSED_ARGS=()
for _arg in "$@"; do
  case "$_arg" in
    --agent) USE_AGENT=true ;;
    --all)   BUILD_ALL=true ;;
    *)       _PARSED_ARGS+=("$_arg") ;;
  esac
done
set -- "${_PARSED_ARGS[@]+"${_PARSED_ARGS[@]}"}"

# ── Select tool variant (Filebeat default / Elastic Agent with --agent) ───────
if [[ "$USE_AGENT" == "true" ]]; then
  COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.app-mock-agent.yml"
  IMAGE_TAG="app-mock-agent:latest"
  DOCKERFILE="apps/deployment/Dockerfile.elastic-agent"
else
  COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.app-mock.yml"
  IMAGE_TAG="app-mock:latest"
  DOCKERFILE="apps/deployment/Dockerfile"
fi

log() { echo "[$(date '+%H:%M:%S')] ==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f .env ]] || die ".env not found"
set -a; source .env; set +a

usage() {
  cat <<EOF
Usage: $0 <command> [env_name] [config_name] [--agent]

Flags:
  --agent   Use Elastic Agent sidecar instead of Filebeat (default: Filebeat)
  --all     (build only) Build both the Filebeat and Elastic Agent images

Commands:
  start  <env_name> [config] [--agent]  Start a mock container; prompts for config if omitted
  stop   <env_name>                     Stop and remove the mock container (auto-detects variant)
  list                                  List running environments and available configs
  logs   <env_name>                     Tail logs of a running mock environment
  build  [--agent] [--all]              Build mock image(s)

Available configs:
$(for d in "${APPS_DIR}"/app_config_*/; do [[ -d "$d" ]] && echo "  $(basename "$d")"; done 2>/dev/null || echo "  (none found)")

Examples:
  $0 start staging
  $0 start staging app_config_v1
  $0 start staging app_config_v1 --agent
  $0 stop  staging
  $0 list
  $0 build --all
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

# ── Ensure the correct mock image is built ───────────────────────────────────
ensure_image() {
  if ! docker image inspect "${IMAGE_TAG}" &>/dev/null; then
    log "Building ${IMAGE_TAG}..."
    docker build -t "${IMAGE_TAG}" -f "${DOCKERFILE}" apps/
  fi
}

# ── Detect which compose file was used for a running container ────────────────
detect_compose_file() {
  local env_name="$1"
  local img
  img=$(docker inspect "app_mock_${env_name}" --format '{{.Config.Image}}' 2>/dev/null || true)
  if [[ "$img" == *"agent"* ]]; then
    echo "${SCRIPT_DIR}/docker-compose.app-mock-agent.yml"
  else
    echo "${SCRIPT_DIR}/docker-compose.app-mock.yml"
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

    log "Starting mock environment '${ENV_NAME}' with config '${CONFIG_NAME}'..."
    docker compose \
      -f "$COMPOSE_FILE" \
      -p "mock_${ENV_NAME}" \
      up -d

    log "Container app_mock_${ENV_NAME} is up (config: ${CONFIG_NAME})"
    ;;

  stop)
    [[ -n "$ENV_NAME" ]] || die "env_name required"

    # Resolve config from state file for compose interpolation
    CONFIG_NAME="$(load_mapping "$ENV_NAME")"
    if [[ -z "$CONFIG_NAME" ]]; then
      read -ra _cfgs <<< "$(list_configs)"
      CONFIG_NAME="${_cfgs[0]:-app_config_v1}"
    fi
    APP_DIR="${APPS_DIR}/${CONFIG_NAME}"

    export ENV_NAME APP_DIR

    log "Stopping mock environment '${ENV_NAME}'..."
    docker compose \
      -f "$(detect_compose_file "${ENV_NAME}")" \
      -p "mock_${ENV_NAME}" \
      down

    remove_mapping "$ENV_NAME"
    log "Done"
    ;;

  list)
    echo ""
    echo "Running mock environments:"
    echo "────────────────────────────────────────"
    docker ps \
      --filter "name=app_mock_" \
      --format "  {{.Names}}\t{{.Status}}\t{{.Image}}"
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
    docker logs -f "app_mock_${ENV_NAME}"
    ;;

  build)
    if [[ "$BUILD_ALL" == "true" ]]; then
      log "Building app-mock:latest (Filebeat)..."
      docker build -t app-mock:latest -f apps/deployment/Dockerfile apps/
      log "Building app-mock-agent:latest (Elastic Agent)..."
      docker build -t app-mock-agent:latest -f apps/deployment/Dockerfile.elastic-agent apps/
    else
      log "Building ${IMAGE_TAG}..."
      docker build -t "${IMAGE_TAG}" -f "${DOCKERFILE}" apps/
    fi
    log "Build complete"
    ;;

  *)
    usage
    ;;
esac