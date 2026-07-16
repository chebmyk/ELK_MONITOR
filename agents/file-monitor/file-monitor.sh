#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
DEFAULT_CONFIG="${SCRIPT_DIR}/file-monitor.config.json"
PID_FILE="${SCRIPT_DIR}/file-monitor.pid"
STATE_FILE="${SCRIPT_DIR}/file-monitor.state"
LOG_FILE="${SCRIPT_DIR}/file-monitor.log"

declare -A SNAPSHOT_VALUES=()
declare -A SOURCE_PATHS=()
declare -A SOURCE_TYPES=()
declare -A SOURCE_STATUS=()
declare -A SOURCE_MTIME=()
declare -A SOURCE_ERRORS=()
declare -A SOURCE_FIELDS=()
declare -A SOURCE_FIELD_NAMES=()

SNAPSHOT_KEYS=""
SOURCE_IDS=""
CONFIG_DIR=""
CONFIG_PATH=""
CONFIG_EXPANDED=""   # temp file holding env-expanded config

# ---------------------------------------------------------------------------
# Usage / logging
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") <start|stop|status|run-once> [-c config.json]

Commands:
  start      Start the file monitor in the background
  stop       Stop a running file monitor
  status     Show monitor status
  run-once   Build one consolidated snapshot immediately

Options:
  -c, --config PATH   JSON config path (default: ${DEFAULT_CONFIG})

Environment variable expansion:
  Any string value in the config may contain \${VAR_NAME} references.
  They are substituted from the process environment before parsing.
  Unset variables are preserved as-is so validation can report them clearly.

JSON config shape:
  {
    "schedule": { "mode": "interval", "seconds": "\${MONITOR_INTERVAL}" },
    "output": {
      "format": "json",
      "path": "\${OUTPUT_DIR}/env-config-snapshot.json"
    },
    "files": [
      {
        "id": "release_info",
        "type": "xml",
        "path": "\${APP_HOME}/conf/release.xml",
        "fields": {
          "server_version": {
            "xpath": "/root/node/text()",
            "target": "release.server_version"
          }
        }
      },
      {
        "id": "web_client",
        "type": "properties",
        "path": "\${APP_HOME}/conf/web.properties",
        "fields": {
          "frontend_protocol": {
            "regex": "^frontend\\.protocol=(.+)$",
            "target": "web.frontend.protocol"
          }
        }
      }
    ]
  }
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_deps() {
  local missing=()
  command -v jq      >/dev/null 2>&1 || missing+=(jq)
  command -v xmllint >/dev/null 2>&1 || missing+=(xmllint)
  (( ${#missing[@]} == 0 )) || die "Missing required tools: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# Cleanup — remove temp expanded-config file on every exit path
# ---------------------------------------------------------------------------

cleanup() {
  [[ -n "$CONFIG_EXPANDED" && -f "$CONFIG_EXPANDED" ]] && rm -f "$CONFIG_EXPANDED"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Process / state helpers
# ---------------------------------------------------------------------------

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE")"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

read_state() {
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE"
}

append_unique_line() {
  local current="$1"
  local value="$2"
  case $'\n'"$current"$'\n' in
    *$'\n'"$value"$'\n'*) printf '%s' "$current" ;;
    *) printf '%s\n%s' "$current" "$value" ;;
  esac
}

# ---------------------------------------------------------------------------
# Config loading — validate raw JSON then expand ${VAR} references via jq
# ---------------------------------------------------------------------------

load_config() {
  local config_path="$1"
  [[ -f "$config_path" ]] || die "Config file not found: $config_path"
  jq empty "$config_path" 2>/dev/null || die "Config is not valid JSON: $config_path"

  CONFIG_PATH="$(cd "$(dirname "$config_path")" && pwd)/$(basename "$config_path")"
  CONFIG_DIR="$(dirname "$CONFIG_PATH")"

  # Reuse the same temp file across reloads (e.g. run-loop with reload).
  if [[ -z "$CONFIG_EXPANDED" ]]; then
    CONFIG_EXPANDED="$(mktemp)"
  fi

  # Expand ${VAR_NAME} in every JSON string value using jq's env object.
  # - Only the ${VAR} form is expanded; bare $VAR is intentionally ignored
  #   to avoid corrupting regex fields that contain $ anchors.
  # - Unset variables are left as-is so downstream validation reports them
  #   clearly rather than silently producing empty strings.
  jq '
    walk(
      if type == "string"
      then gsub(
             "\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)\\}";
             if env[.v] != null then env[.v]
             else "${" + .v + "}"
             end
           )
      else .
      end
    )
  ' "$CONFIG_PATH" > "$CONFIG_EXPANDED" \
    || die "Failed to expand environment variables in config"
}

# ---------------------------------------------------------------------------
# Config accessors — all reads target the expanded copy
# ---------------------------------------------------------------------------

config_value() {
  local key="$1"
  local default="${2-}"
  jq -r --arg d "$default" ".${key} // \$d" "$CONFIG_EXPANDED" 2>/dev/null
}

get_file_indices() {
  jq -r '.files | keys[]' "$CONFIG_EXPANDED"
}

get_field_names() {
  local file_index="$1"
  jq -r ".files[${file_index}].fields | keys[]" "$CONFIG_EXPANDED"
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

expand_vars() {
  local raw="$1"
  eval "printf '%s' \"$raw\""
}

resolve_path() {
  local raw="$1"
  raw="$(expand_vars "$raw")"
  case "$raw" in
    /*) printf '%s' "$raw" ;;
    [A-Za-z]:[\\/]*) printf '%s' "$raw" ;;
    *) printf '%s/%s' "$CONFIG_DIR" "$raw" ;;
  esac
}

file_mtime() {
  local file="$1"
  if stat -c '%y' "$file" >/dev/null 2>&1; then
    stat -c '%y' "$file"
  else
    date -r "$file" '+%Y-%m-%d %H:%M:%S'
  fi
}

# ---------------------------------------------------------------------------
# XML extraction — xmllint
#
# Notes:
#   • Requires libxml2 >= 2.9 for --xpath.
#   • Use /text() suffix in XPath expressions to get raw text content.
#   • Namespace-prefixed documents may need --novalid or explicit ns binding.
# ---------------------------------------------------------------------------

xml_extract_text() {
  local file="$1"
  local xpath="$2"
  xmllint --xpath "$xpath" "$file" 2>/dev/null \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# Properties extraction
# ---------------------------------------------------------------------------

properties_extract() {
  local file="$1"
  local regex="$2"
  local group="${3:-1}"
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $regex ]]; then
      printf '%s' "${BASH_REMATCH[$group]}"
      return 0
    fi
  done < "$file"

  return 1
}

# ---------------------------------------------------------------------------
# Snapshot / source accumulators
# ---------------------------------------------------------------------------

add_snapshot_value() {
  local key="$1"
  local value="$2"
  SNAPSHOT_VALUES["$key"]="$value"
  SNAPSHOT_KEYS="$(append_unique_line "$SNAPSHOT_KEYS" "$key")"
}

register_source() {
  local source_id="$1"
  SOURCE_IDS="$(append_unique_line "$SOURCE_IDS" "$source_id")"
}

add_source_error() {
  local source_id="$1"
  local message="$2"
  SOURCE_ERRORS["$source_id"]+="$message"$'\n'
  if [[ "${SOURCE_STATUS[$source_id]}" == "ok" ]]; then
    SOURCE_STATUS["$source_id"]="partial"
  fi
}

add_source_field() {
  local source_id="$1"
  local field_name="$2"
  local value="$3"
  SOURCE_FIELDS["$source_id|$field_name"]="$value"
  SOURCE_FIELD_NAMES["$source_id"]="$(append_unique_line \
    "${SOURCE_FIELD_NAMES[$source_id]-}" "$field_name")"
}

# ---------------------------------------------------------------------------
# JSON output — jq owns all serialisation; no manual escaping needed
# ---------------------------------------------------------------------------

# jq program that converts a flat positional args list [k, v, k, v, ...]
# into a JSON object.
_kv_args_to_object='
  reduce range(0; ($ARGS.positional | length); 2) as $i (
    {};
    . + { ($ARGS.positional[$i]): $ARGS.positional[$i+1] }
  )
'

write_json_output() {
  local output_path="$1"
  mkdir -p "$(dirname "$output_path")"

  # --- snapshot object -------------------------------------------------------
  local -a snap_args=()
  local key
  while IFS= read -r key; do
    echo "Processing snapshot key: $key"
    [[ -n "$key" ]] || continue
    snap_args+=("$key" "${SNAPSHOT_VALUES[$key]}")
  done < <(printf '%s' "$SNAPSHOT_KEYS" | sed '/^$/d' | sort)

  local snapshot_json
  snapshot_json="$(jq -n "$_kv_args_to_object" \
    --args ${snap_args[@]+"${snap_args[@]}"})"

  # --- sources object --------------------------------------------------------
  local sources_json="{}"
  local source_id

  while IFS= read -r source_id; do
    [[ -n "$source_id" ]] || continue

    # fields object
    local -a field_args=()
    local field_name
    while IFS= read -r field_name; do
      [[ -n "$field_name" ]] || continue
      field_args+=("$field_name" "${SOURCE_FIELDS[$source_id|$field_name]-}")
    done < <(printf '%s' "${SOURCE_FIELD_NAMES[$source_id]-}" | sed '/^$/d' | sort)

    local fields_json
    fields_json="$(jq -n "$_kv_args_to_object" \
      --args ${field_args[@]+"${field_args[@]}"})"

    # errors array
    local errors_json
    errors_json="$(printf '%s' "${SOURCE_ERRORS[$source_id]-}" \
      | sed '/^$/d' \
      | jq -Rn '[inputs]')"

    # per-source object
    local source_obj
    source_obj="$(jq -n \
      --arg  path   "${SOURCE_PATHS[$source_id]-}" \
      --arg  type   "${SOURCE_TYPES[$source_id]-}" \
      --arg  status "${SOURCE_STATUS[$source_id]-unknown}" \
      --arg  mtime  "${SOURCE_MTIME[$source_id]-}" \
      --argjson fields "$fields_json" \
      --argjson errors "$errors_json" \
      '{path: $path, type: $type, status: $status,
        last_modified: $mtime, fields: $fields, errors: $errors}')"

    sources_json="$(jq -n \
      --argjson sources "$sources_json" \
      --arg     id      "$source_id" \
      --argjson src     "$source_obj" \
      '$sources + {($id): $src}')"

  done < <(printf '%s' "$SOURCE_IDS" | sed '/^$/d' | sort)

  # --- final document --------------------------------------------------------
  jq -n \
    --arg     ts       "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --argjson snapshot "$snapshot_json" \
    --argjson sources  "$sources_json" \
    '{generated_at: $ts, snapshot: $snapshot, sources: $sources}' \
    > "$output_path"
}

# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------

validate_config() {
  local config_path="$1"
  load_config "$config_path"

  local output_format
  output_format="$(config_value output.format json)"
  [[ "$output_format" == "json" ]] || die "Only output.format=json is supported"

  local schedule_mode
  schedule_mode="$(config_value schedule.mode interval)"
  [[ "$schedule_mode" == "interval" || "$schedule_mode" == "cron" ]] \
    || die "schedule.mode must be interval or cron"

  local file_count
  file_count="$(jq '.files | length' "$CONFIG_EXPANDED")"
  (( file_count > 0 )) || die "Config must include at least one files entry"

  local file_index source_type source_path
  while IFS= read -r file_index; do
    source_type="$(jq -r ".files[${file_index}].type // empty" "$CONFIG_EXPANDED")"
    source_path="$(jq -r ".files[${file_index}].path // empty" "$CONFIG_EXPANDED")"
    [[ -n "$source_type" ]] || die "files[$file_index].type is required"
    [[ -n "$source_path" ]] || die "files[$file_index].path is required"
    [[ "$source_type" == "xml" || "$source_type" == "properties" ]] \
      || die "files[$file_index].type must be xml or properties"
  done < <(get_file_indices)
}

# ---------------------------------------------------------------------------
# Cron helpers
# ---------------------------------------------------------------------------

cron_field_matches_token() {
  local token="$1" value="$2" minimum="$3" maximum="$4"
  local base step start end

  [[ "$token" == "*" ]] && return 0

  step=1; base="$token"
  if [[ "$token" == */* ]]; then
    base="${token%/*}"; step="${token#*/}"
  fi

  if   [[ "$base" == "*"  ]]; then start="$minimum"; end="$maximum"
  elif [[ "$base" == *-*  ]]; then start="${base%-*}"; end="${base#*-}"
  else start="$base"; end="$base"
  fi

  (( value >= start && value <= end )) || return 1
  (( (value - start) % step == 0 ))
}

cron_field_matches() {
  local expr="$1" value="$2" minimum="$3" maximum="$4"
  local token
  IFS=',' read -r -a cron_tokens <<< "$expr"
  for token in "${cron_tokens[@]}"; do
    cron_field_matches_token "$token" "$value" "$minimum" "$maximum" && return 0
  done
  return 1
}

cron_due_now() {
  local expression
  expression="$(config_value schedule.expression '*/5 * * * *')"
  read -r minute_expr hour_expr day_expr month_expr weekday_expr <<< "$expression"
  [[ -n "${weekday_expr-}" ]] || die "Cron expression must contain 5 fields"

  cron_field_matches "$minute_expr"  "$((10#$(date '+%M')))" 0 59 && \
  cron_field_matches "$hour_expr"    "$((10#$(date '+%H')))" 0 23 && \
  cron_field_matches "$day_expr"     "$((10#$(date '+%d')))" 1 31 && \
  cron_field_matches "$month_expr"   "$((10#$(date '+%m')))" 1 12 && \
  cron_field_matches "$weekday_expr" "$((10#$(date '+%w')))" 0 6
}

# ---------------------------------------------------------------------------
# Snapshot builder
# ---------------------------------------------------------------------------

build_snapshot_data() {
  local config_path="$1"
  load_config "$config_path"

  SNAPSHOT_VALUES=(); SOURCE_PATHS=(); SOURCE_TYPES=(); SOURCE_STATUS=()
  SOURCE_MTIME=();    SOURCE_ERRORS=(); SOURCE_FIELDS=(); SOURCE_FIELD_NAMES=()
  SNAPSHOT_KEYS="";   SOURCE_IDS=""

  local file_index source_id source_type raw_path source_path
  while IFS= read -r file_index; do
    [[ -n "$file_index" ]] || continue

    source_id="$(jq -r --argjson i "$file_index" \
      '.files[$i].id // "source_\($i)"' "$CONFIG_EXPANDED")"
    source_type="$(jq -r --argjson i "$file_index" \
      '.files[$i].type' "$CONFIG_EXPANDED")"
    raw_path="$(jq -r --argjson i "$file_index" \
      '.files[$i].path' "$CONFIG_EXPANDED")"
    source_path="$(resolve_path "$raw_path")"

    register_source "$source_id"
    SOURCE_PATHS["$source_id"]="$source_path"
    SOURCE_TYPES["$source_id"]="$source_type"
    SOURCE_STATUS["$source_id"]="ok"

    if [[ ! -f "$source_path" ]]; then
      SOURCE_STATUS["$source_id"]="missing"
      add_source_error "$source_id" "Source file not found"
      continue
    fi

    SOURCE_MTIME["$source_id"]="$(file_mtime "$source_path")"

    local field_name field_value target xpath regex group
    while IFS= read -r field_name; do
      [[ -n "$field_name" ]] || continue

      target="$(jq -r --argjson i "$file_index" --arg fn "$field_name" \
        '.files[$i].fields[$fn].target // empty' "$CONFIG_EXPANDED")"
      [[ -n "$target" ]] || target="${source_id}.${field_name}"

      if [[ "$source_type" == "xml" ]]; then
        xpath="$(jq -r --argjson i "$file_index" --arg fn "$field_name" \
          '.files[$i].fields[$fn].xpath // empty' "$CONFIG_EXPANDED")"
        if [[ -z "$xpath" ]]; then
          add_source_error "$source_id" "Field $field_name is missing xpath"
          continue
        fi
        field_value="$(xml_extract_text "$source_path" "$xpath" || true)"
      else
        regex="$(jq -r --argjson i "$file_index" --arg fn "$field_name" \
          '.files[$i].fields[$fn].regex // empty' "$CONFIG_EXPANDED")"
        group="$(jq -r --argjson i "$file_index" --arg fn "$field_name" \
          '.files[$i].fields[$fn].group // 1' "$CONFIG_EXPANDED")"
        if [[ -z "$regex" ]]; then
          add_source_error "$source_id" "Field $field_name is missing regex"
          continue
        fi
        field_value="$(properties_extract "$source_path" "$regex" "$group" || true)"
      fi

      if [[ -z "$field_value" ]]; then
        add_source_error "$source_id" "Field $field_name produced no value"
        continue
      fi

      add_source_field "$source_id" "$field_name" "$field_value"
      add_snapshot_value "$target" "$field_value"

    done < <(get_field_names "$file_index")
  done < <(get_file_indices)

  local output_path
  output_path="$(resolve_path "$(config_value output.path \
    './output/env-config-snapshot.json')")"
  write_json_output "$output_path"
  printf '{"output_path":"%s"}\n' "$output_path"
}

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------

write_state() {
  local config_path="$1"
  local mode="$2"
  local output_path
  output_path="$(resolve_path "$(config_value output.path \
    './output/env-config-snapshot.json')")"
  cat > "$STATE_FILE" <<EOF
CONFIG_PATH=${config_path}
SCHEDULE_MODE=${mode}
OUTPUT_PATH=${output_path}
STARTED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_start() {
  local config_path="$1"
  validate_config "$config_path"

  if is_running; then
    log "file-monitor is already running with PID $(cat "$PID_FILE")"
    exit 0
  fi

  local mode
  mode="$(config_value schedule.mode interval)"
  write_state "$config_path" "$mode"

  nohup bash "$SCRIPT_PATH" run-loop -c "$config_path" >> "$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"
  sleep 1

  if kill -0 "$pid" 2>/dev/null; then
    log "file-monitor started (PID ${pid})"
  else
    rm -f "$PID_FILE"
    die "file-monitor exited immediately, check ${LOG_FILE}"
  fi
}

cmd_stop() {
  if ! is_running; then
    log "file-monitor is not running"
    rm -f "$PID_FILE" "$STATE_FILE"
    exit 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null || true

  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 15 )); do
    sleep 1
    waited=$(( waited + 1 ))
  done

  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$PID_FILE" "$STATE_FILE"
  log "file-monitor stopped"
}

cmd_status() {
  if is_running; then
    echo "file-monitor: RUNNING"
    echo "pid: $(cat "$PID_FILE")"
    read_state
  else
    echo "file-monitor: STOPPED"
    [[ -f "$STATE_FILE" ]] && read_state
    exit 1
  fi
}

cmd_run_once() {
  local config_path="$1"
  validate_config "$config_path"
  build_snapshot_data "$config_path"
}

cmd_run_loop() {
  local config_path="$1"
  validate_config "$config_path"

  trap 'rm -f "$PID_FILE" "$STATE_FILE"; cleanup; exit 0' INT TERM

  local mode
  mode="$(config_value schedule.mode interval)"
  log "file-monitor loop started in ${mode} mode"

  if [[ "$mode" == "interval" ]]; then
    local seconds
    seconds="$(config_value schedule.seconds 300)"
    while true; do
      build_snapshot_data "$config_path"
      sleep "$seconds"
    done
  fi

  # cron mode
  local last_minute=""
  while true; do
    local current_minute
    current_minute="$(date '+%Y-%m-%d %H:%M')"
    if [[ "$current_minute" != "$last_minute" ]] && cron_due_now; then
      build_snapshot_data "$config_path"
      last_minute="$current_minute"
    fi
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }

  check_deps

  local command="$1"
  shift
  local config_path="$DEFAULT_CONFIG"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        config_path="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  case "$command" in
    start)    cmd_start    "$config_path" ;;
    stop)     cmd_stop ;;
    status)   cmd_status ;;
    run-once) cmd_run_once "$config_path" ;;
    run-loop) cmd_run_loop "$config_path" ;;
    *)        usage; exit 1 ;;
  esac
}

main "$@"
