#!/usr/bin/env bash
# run_app_server.sh — manage on-demand app_mock environments
#
# Each environment is a self-contained directory under apps/ and runs as an
# independent container connected to the elk-monitor cluster network.
#
# Usage (run from anywhere):
#   apps/run_app_server.sh start <env_name>
#   apps/run_app_server.sh stop  <env_name>
#   apps/run_app_server.sh list
#   apps/run_app_server.sh logs  <env_name>
#   apps/run_app_server.sh build
set -euo pipefail

# ── Locate project root (parent of this script's directory) ──────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

COMPOSE_FILE="apps/docker-compose.app-mock.yml"
APPS_DIR="$SCRIPT_DIR"
TEMPLATE_DIR="${APPS_DIR}/app_mock_v1"   # used as the scaffold for new envs

log() { echo "[$(date '+%H:%M:%S')] ==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f .env ]] || die ".env not found"
set -a; source .env; set +a

usage() {
  cat <<EOF
Usage: $0 <command> [env_name]

Commands:
  start  <env_name>   Create config dir (if needed) and start the mock container
  stop   <env_name>   Stop and remove the mock container
  list                List running mock environments
  logs   <env_name>   Tail logs of a running mock environment
  build               Build (or rebuild) the shared app-mock image

Examples:
  $0 start staging
  $0 start uat
  $0 stop  uat
  $0 list
EOF
  exit 1
}

# ── Ensure the app-mock image is built ────────────────────────────────────────
ensure_image() {
  if ! docker image inspect app-mock:latest &>/dev/null; then
    log "app-mock:latest not found — building..."
    docker build -t app-mock:latest -f apps/Dockerfile .
  fi
}

# ── Scaffold a new environment directory from the template ────────────────────
scaffold_env() {
  local env_name="$1"
  local env_dir="${APPS_DIR}/app_mock_${env_name}"

  if [[ -d "$env_dir" ]]; then
    return 0   # already exists
  fi

  log "Scaffolding new environment '${env_name}' from template..."
  cp -r "$TEMPLATE_DIR" "$env_dir"

  # Patch app.xml with the new env name
  sed -i \
    -e "s|<name>.*</name>|<name>app_mock_${env_name}</name>|" \
    -e "s|<environment>.*</environment>|<environment>${env_name}</environment>|" \
    -e "s|<appfolder>.*</appfolder>|<appfolder>/opt/apps/app_mock_${env_name}</appfolder>|" \
    "${env_dir}/config/app.xml"

  # Patch datasource.xml with the new env name
  sed -i \
    -e "s|app_mock_v1|app_mock_${env_name}|g" \
    "${env_dir}/config/db/datasource.xml"

  mkdir -p "${env_dir}/logs"
  log "Created ${env_dir}"
}

# ─────────────────────────────────────────────────────────────────────────────
CMD="${1:-}"
ENV_NAME="${2:-}"

[[ -n "$CMD" ]] || usage

case "$CMD" in

  start)
    [[ -n "$ENV_NAME" ]] || die "env_name required"
    scaffold_env "$ENV_NAME"
    ensure_image

    APP_DIR="${APPS_DIR}/app_mock_${ENV_NAME}"
    export ENV_NAME APP_DIR

    log "Starting mock environment '${ENV_NAME}'..."
    docker compose \
      -f "$COMPOSE_FILE" \
      -p "mock_${ENV_NAME}" \
      up -d

    log "Container app_mock_${ENV_NAME} is up"
    ;;

  stop)
    [[ -n "$ENV_NAME" ]] || die "env_name required"
    APP_DIR="${APPS_DIR}/app_mock_${ENV_NAME}"
    export ENV_NAME APP_DIR

    log "Stopping mock environment '${ENV_NAME}'..."
    docker compose \
      -f "$COMPOSE_FILE" \
      -p "mock_${ENV_NAME}" \
      down

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
    echo "Available environment directories:"
    for d in "${APPS_DIR}"/app_mock_*/; do
      echo "  $(basename "$d")"
    done
    echo ""
    ;;

  logs)
    [[ -n "$ENV_NAME" ]] || die "env_name required"
    docker logs -f "app_mock_${ENV_NAME}"
    ;;

  build)
    log "Building app-mock:latest..."
    docker build -t app-mock:latest -f apps/Dockerfile .
    log "Build complete"
    ;;

  *)
    usage
    ;;
esac
