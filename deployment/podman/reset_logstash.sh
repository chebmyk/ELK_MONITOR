#!/usr/bin/env bash
# reset_logstash.sh — tear down and recreate the Logstash pod using the same
# manifest, mounts and env vars as run_monitor.sh. Useful to pick up changes
# in logstash/pipeline/, pipelines.yml or logstash.yml without restarting the
# whole ELK stack.
set -euo pipefail

# ─── locate project root ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # deployment/podman/ → deployment/ → root
LOGSTASH_KUBE_MANIFEST="${SCRIPT_DIR}/podman-kube-logstash.yml"
cd "$PROJECT_DIR"

# ─── helpers ─────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] ==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ─── prerequisites ───────────────────────────────────────────────────────────
command -v podman   &>/dev/null || die "podman is not installed"
command -v envsubst &>/dev/null || die "envsubst not found — install gettext: sudo dnf install -y gettext"

[[ -f "$LOGSTASH_KUBE_MANIFEST" ]] || die "manifest not found: $LOGSTASH_KUBE_MANIFEST"

# ─── load .env ───────────────────────────────────────────────────────────────
[[ -f .env ]] || die ".env not found in $(pwd)"
set -a; source .env; set +a

: "${ELASTIC_PASSWORD:?must be set in .env}"
: "${LOGSTASH_PASSWORD:?must be set in .env}"
: "${ELK_VERSION:?must be set in .env}"
: "${ELASTIC_HOST:?must be set in .env}"
: "${ELASTIC_PORT:?must be set in .env}"
: "${LOGSTASH_PORT:?must be set in .env}"

export PROJECT_DIR

NETWORK="elk-monitor"

# ─── ensure network exists (in case stack was fully down) ────────────────────
if ! podman network exists "$NETWORK"; then
  log "Creating Podman network '${NETWORK}'..."
  podman network create "$NETWORK"
fi

# ─── refresh SELinux labels on logstash config (idempotent) ──────────────────
chmod -R o+rX logstash/
if command -v getenforce &>/dev/null && getenforce 2>/dev/null | grep -q Enforcing; then
  log "SELinux is enforcing — relabeling logstash/ with container_file_t..."
  chcon -Rt container_file_t logstash/
fi

# ─── tear down existing Logstash pod (if any) ────────────────────────────────
log "Stopping and removing Logstash pod..."
envsubst < "$LOGSTASH_KUBE_MANIFEST" | podman play kube --down - 2>/dev/null || true

# Belt-and-braces: force-remove if --down left a stale pod/container behind.
if podman pod exists logstash-pod 2>/dev/null; then
  log "Force-removing leftover logstash-pod..."
  podman pod rm -f logstash-pod >/dev/null 2>&1 || true
fi

# ─── start fresh Logstash pod with same manifest ─────────────────────────────
log "Starting Logstash pod..."
envsubst < "$LOGSTASH_KUBE_MANIFEST" | podman play kube --network "$NETWORK" -

log "Logstash pod recreated. Tail logs with:"
echo "  podman logs -f logstash-pod-logstash"
