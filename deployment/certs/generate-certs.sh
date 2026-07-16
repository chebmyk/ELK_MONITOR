#!/usr/bin/env bash
# generate-certs.sh — create self-signed CA + ES/Kibana server certs for the ELK stack.
#
# Output layout (under ${ELK_CERTS_DIR}):
#
#   ca/ca.crt              ← public CA cert, mounted into ES, Kibana, Logstash, beats
#   ca/ca.key              ← CA private key, only needed to (re)issue leaf certs
#   elasticsearch/elasticsearch.crt
#   elasticsearch/elasticsearch.key
#   kibana/kibana.crt
#   kibana/kibana.key
#
# Both ELK_MONITOR run_monitor.sh wrappers (Docker + Podman) bind-mount this
# directory read-only into the containers at <APP>/config/certs.
#
# Usage:
#   ./deployment/certs/generate-certs.sh           # generate if missing
#   ./deployment/certs/generate-certs.sh --force   # regenerate everything
#
# Override target dir / SANs via .env or env vars:
#   ELK_CERTS_DIR    target host directory  (default: <repo>/certs)
#   CERT_DAYS        validity in days       (default: 3650)
#   ES_SAN_DNS       comma-list of DNS SANs (default: elasticsearch,elasticsearch-pod,localhost)
#   ES_SAN_IP        comma-list of IP SANs  (default: 127.0.0.1)
#   KIBANA_SAN_DNS   default: kibana,kibana-pod,localhost
#   KIBANA_SAN_IP    default: 127.0.0.1
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── load .env if present (for ELK_CERTS_DIR + SAN overrides) ─────────────────
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
  set +a
fi

CERTS_DIR="${ELK_CERTS_DIR:-${PROJECT_DIR}/certs}"
DAYS="${CERT_DAYS:-3650}"

ES_SAN_DNS="${ES_SAN_DNS:-elasticsearch,elasticsearch-pod,localhost}"
ES_SAN_IP="${ES_SAN_IP:-127.0.0.1}"
KIBANA_SAN_DNS="${KIBANA_SAN_DNS:-kibana,kibana-pod,localhost}"
KIBANA_SAN_IP="${KIBANA_SAN_IP:-127.0.0.1}"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then FORCE=1; fi

command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required" >&2; exit 1; }

log() { echo "[certs] $*"; }

mkdir -p "${CERTS_DIR}/ca" "${CERTS_DIR}/elasticsearch" "${CERTS_DIR}/kibana"
chmod 755 "${CERTS_DIR}" "${CERTS_DIR}/ca" "${CERTS_DIR}/elasticsearch" "${CERTS_DIR}/kibana"

# ── Build SAN extension blocks ───────────────────────────────────────────────
build_san_ext() {
  local dns="$1" ips="$2"
  local i=1
  {
    echo "subjectAltName = @alt_names"
    echo
    echo "[alt_names]"
    IFS=',' read -ra arr <<< "$dns"
    for d in "${arr[@]}"; do
      [[ -n "$d" ]] && echo "DNS.${i} = ${d}" && i=$((i+1))
    done
    i=1
    IFS=',' read -ra arr <<< "$ips"
    for ip in "${arr[@]}"; do
      [[ -n "$ip" ]] && echo "IP.${i} = ${ip}" && i=$((i+1))
    done
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Root CA
# ─────────────────────────────────────────────────────────────────────────────
CA_KEY="${CERTS_DIR}/ca/ca.key"
CA_CRT="${CERTS_DIR}/ca/ca.crt"

if [[ ! -s "$CA_CRT" || ! -s "$CA_KEY" || $FORCE -eq 1 ]]; then
  log "Generating CA (${CA_CRT})"
  openssl genrsa -out "$CA_KEY" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$DAYS" \
    -subj "/CN=ELK Monitor Root CA/O=ELK Monitor" \
    -out "$CA_CRT"
else
  log "CA already exists, skipping (use --force to regenerate)"
fi
chmod 600 "$CA_KEY"
chmod 644 "$CA_CRT"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Leaf cert helper
# ─────────────────────────────────────────────────────────────────────────────
issue_leaf() {
  local name="$1" san_dns="$2" san_ip="$3"
  local dir="${CERTS_DIR}/${name}"
  local key="${dir}/${name}.key"
  local crt="${dir}/${name}.crt"
  local csr="${dir}/${name}.csr"
  local ext="${dir}/${name}.ext"

  if [[ -s "$crt" && -s "$key" && $FORCE -eq 0 ]]; then
    log "${name} cert exists, skipping"
    return
  fi

  log "Generating ${name} certificate (DNS: ${san_dns}; IP: ${san_ip})"
  openssl genrsa -out "$key" 2048 2>/dev/null
  openssl req -new -key "$key" -subj "/CN=${name}/O=ELK Monitor" -out "$csr"
  build_san_ext "$san_dns" "$san_ip" > "$ext"
  openssl x509 -req -in "$csr" \
    -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$crt" -days "$DAYS" -sha256 -extfile "$ext"

  rm -f "$csr" "$ext"
  chmod 600 "$key"
  chmod 644 "$crt"
}

issue_leaf "elasticsearch" "$ES_SAN_DNS" "$ES_SAN_IP"
issue_leaf "kibana"        "$KIBANA_SAN_DNS" "$KIBANA_SAN_IP"

# Containers run as UID 1000 (elasticsearch / kibana / logstash). On Linux,
# make the dir readable by them. On macOS / WSL, default mount semantics handle it.
if [[ "$(uname -s)" == "Linux" ]]; then
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    log "Relabeling certs dir for rootless Podman (UID 1000)"
    podman unshare chown -R 1000:1000 "$CERTS_DIR" || true
  fi
  if command -v getenforce >/dev/null 2>&1 && getenforce 2>/dev/null | grep -q Enforcing; then
    log "SELinux is enforcing — applying container_file_t to ${CERTS_DIR}"
    chcon -Rt container_file_t "$CERTS_DIR" || true
  fi
fi

log "Done. Certs are in ${CERTS_DIR}"
