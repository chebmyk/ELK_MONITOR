#!/usr/bin/env bash
# podman-add-server.sh — manage on-demand app_mock pods via podman play kube
#
# Usage (run from anywhere):
#   apps/podman-add-server.sh start <env_name>
#   apps/podman-add-server.sh stop  <env_name>
#   apps/podman-add-server.sh list
#   apps/podman-add-server.sh logs  <env_name>
#   apps/podman-add-server.sh build
set -euo pipefail

# ── Locate project root (parent of this script's directory) ──────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

KUBE_TEMPLATE="apps/podman-kube-app-mock.yml"
APPS_DIR="$SCRIPT_DIR"
TEMPLATE_DIR="${APPS_DIR}/app_mock_v1"
NETWORK="elk-monitor"

log() { echo "[$(date '+%H:%M:%S')] ==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v podman   &>/dev/null || die "podman is not installed"
command -v envsubst &>/dev/null || die "envsubst not found — install gettext: sudo dnf install -y gettext"

usage() {
  cat <<EOF
Usage: $0 <command> [env_name]

Commands:
  start  <env_name>   Scaffold config dir (if needed), build image, and start pod
  stop   <env_name>   Stop and remove the mock pod
  list                List running app-mock pods
  logs   <env_name>   Tail container logs for a running mock pod
  build               Build (or rebuild) the shared localhost/app-mock:latest image

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
  if ! podman image exists localhost/app-mock:latest; then
    log "localhost/app-mock:latest not found — building..."
    podman build -t localhost/app-mock:latest -f apps/Dockerfile .
  fi
}

# ── Scaffold a new environment directory from the template ────────────────────
scaffold_env() {
  local env_name="$1"
  local env_dir="${APPS_DIR}/app_mock_${env_name}"

  if [[ -d "$env_dir" ]]; then
    return 0
  fi

  log "Scaffolding new environment '${env_name}' from template..."
  cp -r "$TEMPLATE_DIR" "$env_dir"

  sed -i \
    -e "s|<name>.*</name>|<name>app_mock_${env_name}</name>|" \
    -e "s|<environment>.*</environment>|<environment>${env_name}</environment>|" \
    -e "s|<appfolder>.*</appfolder>|<appfolder>/opt/apps/app_mock_${env_name}</appfolder>|" \
    "${env_dir}/config/app.xml"

  sed -i "s|app_mock_v1|app_mock_${env_name}|g" \
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

    export ENV_NAME
    export APP_DIR="${APPS_DIR}/app_mock_${ENV_NAME}"

    log "Starting pod app-mock-${ENV_NAME}..."
    envsubst < "$KUBE_TEMPLATE" | podman play kube --network "$NETWORK" -
    log "Pod app-mock-${ENV_NAME} is up"
    ;;

  stop)
    [[ -n "$ENV_NAME" ]] || die "env_name required"
    export ENV_NAME
    export APP_DIR="${APPS_DIR}/app_mock_${ENV_NAME}"

    log "Stopping pod app-mock-${ENV_NAME}..."
    envsubst < "$KUBE_TEMPLATE" | podman play kube --down -
    log "Done"
    ;;

  list)
    echo ""
    echo "Running app-mock pods:"
    echo "────────────────────────────────────────"
    podman pod ps --filter label=component=app-mock \
      --format "  {{.Name}}\t{{.Status}}"
    echo ""
    echo "Available environment directories:"
    for d in "${APPS_DIR}"/app_mock_*/; do
      echo "  $(basename "$d")"
    done
    echo ""
    ;;

  logs)
    [[ -n "$ENV_NAME" ]] || die "env_name required"
    # Podman container name pattern: <pod-name>-<container-name>
    podman logs -f "app-mock-${ENV_NAME}-app-mock-${ENV_NAME}"
    ;;

  build)
    log "Building localhost/app-mock:latest..."
    podman build -t localhost/app-mock:latest -f apps/Dockerfile .
    log "Build complete"
    ;;

  *)
    usage
    ;;
esac
