#!/usr/bin/env bash
# elastic-agent-runner.sh — manage a standalone Elastic Agent instance
# Usage: elastic-agent-runner.sh {start|stop|restart|status|clean-registry} [options]
set -uo pipefail

# ─── defaults (override via environment or .env) ─────────────────────────────
AGENT_HOME="${AGENT_HOME:-/elastic-agent}"
AGENT_CONFIG="${AGENT_CONFIG:-${AGENT_HOME}/elastic-agent.yml}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/elastic-agent}"
AGENT_LOG_FILE="${AGENT_LOG_DIR}/elastic-agent.log"
AGENT_PID_FILE="${AGENT_LOG_DIR}/elastic-agent.pid"

# Rolling log defaults
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-50}"       # rotate when file exceeds this size
LOG_KEEP_FILES="${LOG_KEEP_FILES:-5}"          # number of rotated files to keep

# ─── helpers ─────────────────────────────────────────────────────────────────
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(ts)] $*"; }
die()  { echo "[$(ts)] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  start           Start Elastic Agent in the background (with rolling log)
  stop            Stop a running Elastic Agent
  restart         Stop then start
  status          Show whether the agent is running
  clean-registry  Stop the agent and delete its registry/state data

Environment variables (all optional):
  AGENT_HOME        Path to extracted elastic-agent dir  (default: /elastic-agent)
  AGENT_CONFIG      Path to elastic-agent.yml            (default: \$AGENT_HOME/elastic-agent.yml)
  AGENT_LOG_DIR     Directory for log + pid files        (default: /var/log/elastic-agent)
  LOG_MAX_SIZE_MB   Rotate log when it exceeds this MB   (default: 50)
  LOG_KEEP_FILES    Number of rotated logs to retain      (default: 5)

EOF
  exit 1
}

# ─── load .env if present ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a; source "${SCRIPT_DIR}/.env"; set +a
elif [[ -f "$(dirname "$SCRIPT_DIR")/.env" ]]; then
  set -a; source "$(dirname "$SCRIPT_DIR")/.env"; set +a
fi

# ─── log rotation ────────────────────────────────────────────────────────────
rotate_log() {
  [[ -f "$AGENT_LOG_FILE" ]] || return 0

  local size_bytes
  size_bytes=$(stat -c%s "$AGENT_LOG_FILE" 2>/dev/null || stat -f%z "$AGENT_LOG_FILE" 2>/dev/null || echo 0)
  local max_bytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))

  if (( size_bytes >= max_bytes )); then
    log "Log file reached ${LOG_MAX_SIZE_MB} MB — rotating..."

    # Shift existing rotated files: .4 → delete, .3 → .4, .2 → .3, etc.
    local i=$LOG_KEEP_FILES
    while (( i > 0 )); do
      local prev=$(( i - 1 ))
      local src="${AGENT_LOG_FILE}.$( (( prev == 0 )) && echo '' || echo "$prev")"
      [[ $prev -eq 0 ]] && src="$AGENT_LOG_FILE"
      local dst="${AGENT_LOG_FILE}.${i}"
      if (( i == LOG_KEEP_FILES )); then
        rm -f "$dst"
      fi
      [[ -f "$src" ]] && mv "$src" "$dst"
      (( i-- ))
    done
  fi
}

# ─── pid helpers ─────────────────────────────────────────────────────────────
read_pid() {
  [[ -f "$AGENT_PID_FILE" ]] && cat "$AGENT_PID_FILE" || echo ""
}

is_running() {
  local pid
  pid=$(read_pid)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ─── commands ────────────────────────────────────────────────────────────────
cmd_start() {
  if is_running; then
    log "Elastic Agent is already running (PID $(read_pid))"
    return 0
  fi

  [[ -x "${AGENT_HOME}/elastic-agent" ]] || die "Binary not found: ${AGENT_HOME}/elastic-agent"
  [[ -f "$AGENT_CONFIG" ]]               || die "Config not found: ${AGENT_CONFIG}"

  mkdir -p "$AGENT_LOG_DIR"

  # Rotate before starting
  rotate_log

  log "Starting Elastic Agent..."
  log "  binary : ${AGENT_HOME}/elastic-agent"
  log "  config : ${AGENT_CONFIG}"
  log "  log    : ${AGENT_LOG_FILE}"

  nohup "${AGENT_HOME}/elastic-agent" run \
    -c "$AGENT_CONFIG" \
    -e \
    >> "$AGENT_LOG_FILE" 2>&1 &

  local pid=$!
  echo "$pid" > "$AGENT_PID_FILE"

  # Brief wait to verify the process didn't exit immediately
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    log "Elastic Agent started (PID ${pid})"
  else
    rm -f "$AGENT_PID_FILE"
    die "Elastic Agent exited immediately — check ${AGENT_LOG_FILE}"
  fi

  # Start background log rotator (checks every 60 s while agent is alive)
  _start_log_rotator "$pid" &
}

_start_log_rotator() {
  local agent_pid=$1
  while kill -0 "$agent_pid" 2>/dev/null; do
    sleep 60
    rotate_log
  done
}

cmd_stop() {
  if ! is_running; then
    log "Elastic Agent is not running"
    rm -f "$AGENT_PID_FILE"
    return 0
  fi

  local pid
  pid=$(read_pid)
  log "Stopping Elastic Agent (PID ${pid})..."

  kill "$pid" 2>/dev/null

  # Wait up to 30 s for graceful shutdown
  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 30 )); do
    sleep 1
    (( waited++ ))
  done

  if kill -0 "$pid" 2>/dev/null; then
    log "Agent did not stop gracefully — sending SIGKILL"
    kill -9 "$pid" 2>/dev/null
    sleep 1
  fi

  rm -f "$AGENT_PID_FILE"
  log "Elastic Agent stopped"
}

cmd_restart() {
  cmd_stop
  cmd_start
}

cmd_status() {
  if is_running; then
    local pid
    pid=$(read_pid)
    local uptime_info
    uptime_info=$(ps -o etime= -p "$pid" 2>/dev/null || echo "unknown")

    echo "────────────────────────────────────────"
    echo "  Elastic Agent : RUNNING"
    echo "  PID           : ${pid}"
    echo "  Uptime        : ${uptime_info}"
    echo "  Config        : ${AGENT_CONFIG}"
    echo "  Log file      : ${AGENT_LOG_FILE}"
    echo "────────────────────────────────────────"

    # Show log file sizes
    if [[ -d "$AGENT_LOG_DIR" ]]; then
      echo ""
      echo "  Log files:"
      ls -lh "${AGENT_LOG_DIR}"/elastic-agent.log* 2>/dev/null | \
        awk '{printf "    %-40s %s\n", $NF, $5}'
    fi
  else
    echo "────────────────────────────────────────"
    echo "  Elastic Agent : STOPPED"
    echo "────────────────────────────────────────"
    rm -f "$AGENT_PID_FILE"
    return 1
  fi
}

cmd_clean_registry() {
  local data_dir="${AGENT_HOME}/data"
  local targets=("beat" "filestream-default" "filestream-monitoring" "http")

  if is_running; then
    log "Agent is running — stopping first..."
    cmd_stop
  fi

  # Discover the agent hash directory
  local agent_dir
  agent_dir=$(find "${data_dir}" -maxdepth 1 -type d -name 'elastic-agent-*' | head -1)
  if [[ -z "$agent_dir" ]]; then
    log "No elastic-agent data directory found under ${data_dir} — nothing to clean"
    return 0
  fi

  local run_dir="${agent_dir}/run"
  if [[ ! -d "$run_dir" ]]; then
    log "No run directory found at ${run_dir} — nothing to clean"
    return 0
  fi

  echo ""
  echo "Select registries to clean under ${run_dir}:"
  echo ""

  local i=1
  local available=()
  for t in "${targets[@]}"; do
    local reg="${run_dir}/${t}/registry"
    if [[ -d "$reg" ]]; then
      echo "  ${i}) ${t}  ✓ (registry exists)"
      available+=("$t")
    else
      echo "  ${i}) ${t}  ✗ (not found)"
    fi
    (( i++ ))
  done
  echo "  ${i}) all"
  echo ""

  read -rp "Enter choices (comma-separated numbers, or 'all'): " choices

  local selected=()
  if [[ "$choices" == "all" || "$choices" == "$i" ]]; then
    selected=("${targets[@]}")
  else
    IFS=',' read -ra nums <<< "$choices"
    for n in "${nums[@]}"; do
      n=$(echo "$n" | tr -d ' ')
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#targets[@]} )); then
        selected+=("${targets[$((n-1))]}")
      else
        log "Skipping invalid selection: ${n}"
      fi
    done
  fi

  if [[ ${#selected[@]} -eq 0 ]]; then
    log "No valid selections — nothing to clean"
    return 0
  fi

  local cleaned=0
  for t in "${selected[@]}"; do
    local reg="${run_dir}/${t}/registry"
    if [[ -d "$reg" ]]; then
      log "Removing registry: ${reg}"
      rm -rf "$reg"
      (( cleaned++ ))
    else
      log "Registry not found for ${t} — skipping"
    fi
  done

  if (( cleaned )); then
    log "Cleaned ${cleaned} registry directory(ies)"
  fi
}

# ─── main ────────────────────────────────────────────────────────────────────
CMD="${1:-}"
case "$CMD" in
  start)          cmd_start          ;;
  stop)           cmd_stop           ;;
  restart)        cmd_restart        ;;
  status)         cmd_status         ;;
  clean-registry) cmd_clean_registry ;;
  *)              usage              ;;
esac