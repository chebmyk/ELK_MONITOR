#!/usr/bin/env bash
# podman-run.sh — manage the ELK Monitor stack via podman play kube
set -euo pipefail

# ─── locate project root ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # deployment/podman/ → deployment/ → root
ES_KUBE_MANIFEST="${SCRIPT_DIR}/podman-kube-es.yml"
LOGSTASH_KUBE_MANIFEST="${SCRIPT_DIR}/podman-kube-logstash.yml"
KUBE_MANIFEST="${SCRIPT_DIR}/podman-kube-kibana.yml"
cd "$PROJECT_DIR"

# ─── helpers ──────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] ==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [command] [service]

Commands:
  up       Start Elasticsearch, wait for healthy, bootstrap security, start Logstash+Kibana (default)
  down     Stop and remove all pods
  status   Show pod status
  logs     Tail logs: $0 logs [elasticsearch|logstash|kibana|filebeat-elk-infra]

  App mock environments are managed separately by apps/deployment/podman/run_app_server.sh.
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

NETWORK="elk-monitor"
# run_monitor.sh runs on the host, not inside the Podman network.
# ${ELASTIC_HOST} (e.g. elasticsearch-pod) is only a DNS name inside the network.
# Use localhost here because the ES pod maps hostPort:${ELASTIC_PORT}.
ES_URL="http://localhost:${ELASTIC_PORT}"
ES_AUTH="elastic:${ELASTIC_PASSWORD}"

CMD="${1:-up}"
SERVICE="${2:-}"

case "$CMD" in

  up)
    # ── 1. Directories ──────────────────────────────────────────────────────────
    log "Creating required directories..."
    mkdir -p "${ES_DATA_DIR}"
    # mkdir -p "${PROJECT_DIR}/data/filebeat-elk-infra"
    # mkdir -p "${PROJECT_DIR}/data/elk-logs/elasticsearch"
    # mkdir -p "${PROJECT_DIR}/data/elk-logs/logstash"
    # mkdir -p "${PROJECT_DIR}/data/elk-logs/kibana"

    # ── 2. Fix Elasticsearch data dir permissions ──────────────────────────────
    # ES container writes as UID 1000 (elasticsearch). Use podman unshare so
    # the chown runs inside the rootless user namespace where UID 1000 is valid.
    log "Fixing ${ES_DATA_DIR} ownership for Elasticsearch (UID 1000)..."
    podman unshare chown -R 1000:1000 "${ES_DATA_DIR}"
    if command -v getenforce &>/dev/null && getenforce 2>/dev/null | grep -q Enforcing; then
      log "SELinux is enforcing — relabeling ${ES_DATA_DIR} with container_file_t..."
      chcon -Rt container_file_t "${ES_DATA_DIR}"
    fi


    # # ── 3. Fix Filebeat registry dir permissions ───────────────────────────────
    # # Filebeat runs as UID 1000 and must write its registry to this hostPath dir.
    # log "Fixing ${PROJECT_DIR}/data/filebeat-elk-infra ownership for Filebeat (UID 1000)..."
    # podman unshare chown -R 1000:1000 "${PROJECT_DIR}/data/filebeat-elk-infra"
    # if command -v getenforce &>/dev/null && getenforce 2>/dev/null | grep -q Enforcing; then
    #   log "SELinux is enforcing — relabeling data/filebeat-elk-infra with container_file_t..."
    #   chcon -Rt container_file_t "${PROJECT_DIR}/data/filebeat-elk-infra"
    # fi
    # # ── 4. Fix ELK shared log dir permissions ────────────────────────────────
    # # ES, Logstash, and Kibana all write logs as UID 1000. These dirs are
    # # hostPath volumes (see podman-kube.yml) and must be pre-chowned.
    # log "Fixing ${PROJECT_DIR}/data/elk-logs ownership for ELK containers (UID 1000)..."
    # podman unshare chown -R 1000:1000 "${PROJECT_DIR}/data/elk-logs"
    # if command -v getenforce &>/dev/null && getenforce 2>/dev/null | grep -q Enforcing; then
    #   log "SELinux is enforcing — relabeling data/elk-logs with container_file_t..."
    #   chcon -Rt container_file_t "${PROJECT_DIR}/data/elk-logs"
    # fi


    # ── 5. Fix logstash config file permissions ──────────────────────────────
    # Logstash only needs read access; o+rX is sufficient.
    log "Setting permissions on logstash config files..."
    chmod -R o+rX logstash/
    if command -v getenforce &>/dev/null && getenforce 2>/dev/null | grep -q Enforcing; then
      log "SELinux is enforcing — relabeling logstash/ with container_file_t..."
      chcon -Rt container_file_t logstash/
    fi

    # ── 6. Podman network ───────────────────────────────────────────────────────
    if ! podman network exists "$NETWORK"; then
      log "Creating Podman network '${NETWORK}'..."
      podman network create "$NETWORK"
    else
      log "Network '${NETWORK}' already exists — skipping."
    fi

    # ── 7. Start Elasticsearch pod ──────────────────────────────────────────────
    log "Starting Elasticsearch pod..."
    envsubst < "$ES_KUBE_MANIFEST" | podman play kube --network "$NETWORK" -

    # ── 8. Wait for Elasticsearch livenessProbe to pass ─────────────────────────
    # The livenessProbe in podman-kube-es.yml authenticates as the elastic superuser
    # and hits /_cluster/health. Once it passes, Podman marks the container healthy.
    # Only then is it safe to bootstrap security and start the apps pod.
    ES_CONTAINER="elasticsearch-pod-elasticsearch"
    log "Waiting for Elasticsearch container to become healthy..."
    max_wait=300
    elapsed=0
    until [ "$(podman inspect --format='{{.State.Health.Status}}' "$ES_CONTAINER" 2>/dev/null)" = "healthy" ]; do
      if [ "$elapsed" -ge "$max_wait" ]; then
        die "Elasticsearch did not become healthy after ${max_wait}s"
      fi
      printf '.'; sleep 5
      elapsed=$((elapsed + 5))
    done
    echo " healthy"

    # ── 9. Bootstrap ES security (idempotent) ───────────────────────────────────
    ES_API="${SCRIPT_DIR}/es-api.sh"
    [[ -x "$ES_API" ]] || chmod +x "$ES_API"

    log "Setting kibana_system password..."
    "$ES_API" --url "$ES_URL" --auth "$ES_AUTH" \
      set-password kibana_system "${KIBANA_SYSTEM_PASSWORD}"

    log "Creating logstash_writer role..."
    "$ES_API" --url "$ES_URL" --auth "$ES_AUTH" \
      create-role logstash_writer \
      '{"cluster":["monitor","manage_ilm","manage_index_templates"],"indices":[{"names":["*"],"privileges":["create_index","write","read","manage"]}]}'

    log "Creating logstash_writer user..."
    "$ES_API" --url "$ES_URL" --auth "$ES_AUTH" \
      create-user logstash_writer \
      "{\"password\":\"${LOGSTASH_PASSWORD}\",\"roles\":[\"logstash_writer\"],\"full_name\":\"Logstash Writer\"}"

    # ── 10. Start Logstash pod ───────────────────────────────────────────────────
    # ES is healthy and logstash_writer is provisioned — safe to start.
    log "Starting Logstash pod..."
    envsubst < "$LOGSTASH_KUBE_MANIFEST" | podman play kube --network "$NETWORK" -

    # ── 11. Start Kibana pod ─────────────────────────────────────────────────────
    # kibana_system password is provisioned — safe to start.
    log "Starting Kibana pod..."
    envsubst < "$KUBE_MANIFEST" | podman play kube --network "$NETWORK" -

    echo ""
    echo "────────────────────────────────────────"
    echo "  Stack is up"
    echo "  Elasticsearch : ${ES_URL}           (user: elastic)"
    echo "  Kibana        : http://localhost:${KIBANA_PORT}  (user: elastic)"
    echo "  Logstash beats: localhost:${LOGSTASH_PORT}"
    echo "────────────────────────────────────────"
    ;;

  down)
    log "Stopping and removing Kibana pod..."
    envsubst < "$KUBE_MANIFEST" | podman play kube --down - 2>/dev/null || true
    log "Stopping and removing Logstash pod..."
    envsubst < "$LOGSTASH_KUBE_MANIFEST" | podman play kube --down - 2>/dev/null || true
    log "Stopping and removing Elasticsearch pod..."
    envsubst < "$ES_KUBE_MANIFEST" | podman play kube --down - 2>/dev/null || true
    ;;

  status)
    podman pod ps --filter label=app=elk-monitor
    ;;

  logs)
    # Pod name → Podman container name: {pod-name}-{container-name}
    declare -A POD_CONTAINERS=(
      [elasticsearch]="elasticsearch-pod-elasticsearch"
      [logstash]="logstash-pod-logstash"
      [kibana]="kibana-pod-kibana"
      [filebeat-elk-infra]="kibana-pod-filebeat-elk-infra"
    )
    if [[ -n "$SERVICE" ]]; then
      CONTAINER="${POD_CONTAINERS[$SERVICE]:-$SERVICE}"
      podman logs -f "$CONTAINER"
    else
      for svc in elasticsearch logstash kibana filebeat-elk-infra; do
        echo "=== ${svc} ==="
        podman logs "${POD_CONTAINERS[$svc]}" 2>/dev/null || true
      done
    fi
    ;;

  *)
    usage
    ;;
esac
