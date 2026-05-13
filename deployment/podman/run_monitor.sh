#!/usr/bin/env bash
# podman-run.sh — manage the ELK Monitor stack via podman play kube
set -euo pipefail

# ─── locate project root ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # deployment/podman/ → deployment/ → root
KUBE_MANIFEST="${SCRIPT_DIR}/podman-kube.yml"
cd "$PROJECT_DIR"

# ─── helpers ──────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] ==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [command] [service]

Commands:
  up       Create cluster pods and bootstrap ES security (default)
  down     Stop and remove cluster pods (elasticsearch, logstash, kibana)
  status   Show cluster pod status
  logs     Tail logs: $0 logs [elasticsearch|logstash|kibana]

  App mock environments are managed separately by deployment/podman/podman-add-server.sh.
EOF
  exit 1
}

# ─── prerequisites ─────────────────────────────────────────────────────────────
command -v podman    &>/dev/null || die "podman is not installed"
command -v envsubst  &>/dev/null || die "envsubst not found — install gettext: sudo dnf install -y gettext"
command -v curl      &>/dev/null || die "curl is not installed"

# ─── load .env ─────────────────────────────────────────────────────────────────
[[ -f .env ]] || die ".env not found in $(pwd)"

set -a; source .env; set +a

: "${ELASTIC_PASSWORD:?must be set in .env}"
: "${KIBANA_SYSTEM_PASSWORD:?must be set in .env}"
: "${LOGSTASH_PASSWORD:?must be set in .env}"

export PROJECT_DIR
export ES_DATA_DIR="${ES_DATA_DIR:-/Data/elk/elasticsearch}"
NETWORK="elk-monitor"
ES_URL="http://localhost:9200"
ES_AUTH="elastic:${ELASTIC_PASSWORD}"

CMD="${1:-up}"
SERVICE="${2:-}"

case "$CMD" in

  up)
    # ── 1. Directories ──────────────────────────────────────────────────────────
    log "Creating required directories..."
    mkdir -p "${ES_DATA_DIR}"

    # ── 2. Fix Elasticsearch data dir permissions ──────────────────────────────
    # ES container writes as UID 1000 (elasticsearch). Use podman unshare so
    # the chown runs inside the rootless user namespace where UID 1000 is valid.
    log "Fixing ${ES_DATA_DIR} ownership for Elasticsearch (UID 1000)..."
    podman unshare chown -R 1000:1000 "${ES_DATA_DIR}"
    if command -v getenforce &>/dev/null && getenforce 2>/dev/null | grep -q Enforcing; then
      log "SELinux is enforcing — relabeling ${ES_DATA_DIR} with container_file_t..."
      chcon -Rt container_file_t "${ES_DATA_DIR}"
    fi

    # ── 3. Fix logstash config file permissions ──────────────────────────────
    # Logstash only needs read access; o+rX is sufficient.
    log "Setting permissions on logstash config files..."
    chmod -R o+rX logstash/
    if command -v getenforce &>/dev/null && getenforce 2>/dev/null | grep -q Enforcing; then
      log "SELinux is enforcing — relabeling logstash/ with container_file_t..."
      chcon -Rt container_file_t logstash/
    fi

    # ── 4. Podman network ───────────────────────────────────────────────────────
    if ! podman network exists "$NETWORK"; then
      log "Creating Podman network '${NETWORK}'..."
      podman network create "$NETWORK"
    else
      log "Network '${NETWORK}' already exists — skipping."
    fi

    log "Launching cluster pods via podman play kube..."
    envsubst < "$KUBE_MANIFEST" | podman play kube --network "$NETWORK" -

    # ── 5. Wait for Elasticsearch ───────────────────────────────────────────────
    log "Waiting for Elasticsearch to be healthy..."
    until curl -sf -u "$ES_AUTH" "${ES_URL}/_cluster/health" &>/dev/null; do
      printf '.'; sleep 3
    done
    echo " ready"

    # ── 6. Bootstrap ES security (idempotent) ───────────────────────────────────
    log "Setting kibana_system password..."
    curl -sf -X POST -u "$ES_AUTH" \
      -H "Content-Type: application/json" \
      "${ES_URL}/_security/user/kibana_system/_password" \
      -d "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}" >/dev/null
    echo " done"

    log "Creating logstash_writer role..."
    curl -sf -X PUT -u "$ES_AUTH" \
      -H "Content-Type: application/json" \
      "${ES_URL}/_security/role/logstash_writer" \
      -d '{
        "cluster": ["monitor","manage_ilm","manage_index_templates"],
        "indices": [{"names":["*"],"privileges":["create_index","write","read","manage"]}]
      }' >/dev/null
    echo " done"

    log "Creating logstash_writer user..."
    curl -sf -X PUT -u "$ES_AUTH" \
      -H "Content-Type: application/json" \
      "${ES_URL}/_security/user/logstash_writer" \
      -d "{\"password\":\"${LOGSTASH_PASSWORD}\",\"roles\":[\"logstash_writer\"],\"full_name\":\"Logstash Writer\"}" >/dev/null
    echo " done"

    echo ""
    echo "────────────────────────────────────────"
    echo "  Stack is up"
    echo "  Elasticsearch : ${ES_URL}           (user: elastic)"
    echo "  Kibana        : http://localhost:5601  (user: elastic)"
    echo "  Logstash beats: localhost:5050"
    echo "  App mocks      : ./deployment/podman/podman-add-server.sh start <env_name>"
    echo "────────────────────────────────────────"
    ;;

  down)
    log "Stopping and removing cluster pods..."
    envsubst < "$KUBE_MANIFEST" | podman play kube --down -
    ;;

  status)
    podman pod ps --filter label=app=elk-monitor
    ;;

  logs)
    # Container names follow the pattern: <pod-name>-<container-name>
    declare -A POD_CONTAINERS=(
      [elasticsearch]="elasticsearch-elasticsearch"
      [logstash]="logstash-logstash"
      [kibana]="kibana-kibana"
    )
    if [[ -n "$SERVICE" ]]; then
      CONTAINER="${POD_CONTAINERS[$SERVICE]:-$SERVICE}"
      podman logs -f "$CONTAINER"
    else
      for svc in elasticsearch logstash kibana; do
        echo "=== ${svc} ==="
        podman logs "${POD_CONTAINERS[$svc]}" 2>/dev/null || true
      done
    fi
    ;;

  *)
    usage
    ;;
esac
