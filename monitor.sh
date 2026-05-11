#!/usr/bin/env bash
# start.sh — wrapper to manage the ELK Monitor stack with security enabled
set -euo pipefail

# ─── helpers ─────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] ==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [command] [service]

Commands:
  up           Start the full stack (default)
  down         Stop and remove containers
  restart      Restart all services, or a single one: $0 restart logstash
  logs         Tail logs for all services, or one:    $0 logs kibana
  status       Show container status

EOF
  exit 1
}

# ─── load .env ────────────────────────────────────────────────────────────────
[[ -f .env ]] || die ".env not found"
set -a; source .env; set +a

: "${ELASTIC_PASSWORD:?must be set in .env}"
: "${KIBANA_SYSTEM_PASSWORD:?must be set in .env}"
: "${LOGSTASH_PASSWORD:?must be set in .env}"

ES_URL="http://localhost:9200"
ES_AUTH="elastic:${ELASTIC_PASSWORD}"

# ─── subcommands ──────────────────────────────────────────────────────────────
CMD="${1:-up}"
SERVICE="${2:-}"

case "$CMD" in

  up)
    # Prepare bind-mount directory
    mkdir -p /Data/elasticsearch

    # On Linux the ES container runs as UID 1000; fix ownership so it can write
    if [[ "$(uname -s)" == "Linux" ]]; then
      log "Setting /Data/elasticsearch ownership to UID 1000 (elasticsearch)..."
      chown -R 1000:1000 /Data/elasticsearch
    fi

    # ── Step 1: Elasticsearch ──────────────────────────────────────────────────
    log "Starting Elasticsearch..."
    docker compose up -d elasticsearch

    log "Waiting for Elasticsearch to be healthy..."
    until curl -sf -u "$ES_AUTH" "${ES_URL}/_cluster/health" &>/dev/null; do
      printf '.'; sleep 3
    done
    echo " ready"

    # ── Step 2: Bootstrap users / roles (idempotent) ───────────────────────────
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
        "cluster": ["monitor", "manage_ilm", "manage_index_templates"],
        "indices": [{
          "names": ["*"],
          "privileges": ["create_index", "write", "read", "manage"]
        }]
      }' >/dev/null
    echo " done"

    log "Creating logstash_writer user..."
    curl -sf -X PUT -u "$ES_AUTH" \
      -H "Content-Type: application/json" \
      "${ES_URL}/_security/user/logstash_writer" \
      -d "{
        \"password\": \"${LOGSTASH_PASSWORD}\",
        \"roles\": [\"logstash_writer\"],
        \"full_name\": \"Logstash Writer\"
      }" >/dev/null
    echo " done"

    # ── Step 3: Start everything else ─────────────────────────────────────────
    log "Starting remaining services..."
    docker compose up -d

    echo ""
    echo "────────────────────────────────────────"
    echo "  Stack is up"
    echo "  Elasticsearch : ${ES_URL}           (user: elastic)"
    echo "  Kibana        : http://localhost:5601  (user: elastic)"
    echo "  Logstash beats: localhost:5050"
    echo "────────────────────────────────────────"
    ;;

  down)
    log "Stopping stack..."
    docker compose down
    ;;

  restart)
    if [[ -n "$SERVICE" ]]; then
      log "Restarting ${SERVICE}..."
      docker compose restart "$SERVICE"
    else
      log "Restarting all services..."
      docker compose restart
    fi
    ;;

  logs)
    if [[ -n "$SERVICE" ]]; then
      docker compose logs -f "$SERVICE"
    else
      docker compose logs -f
    fi
    ;;

  status)
    docker compose ps
    ;;

  *)
    usage
    ;;
esac
