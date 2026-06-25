#!/usr/bin/env bash
# fingerprint-audit.sh — scan elastic-agent input configs and hash matched files
#
# Reads all *.yml files in a config directory, extracts path patterns and
# fingerprint length from each stream, resolves matching files, and outputs:
#   file_pattern|filename|file_size|hash_size|hash_value
#
# Usage: ./fingerprint-audit.sh [config_dir] [output_file]
#   config_dir  — directory containing *.yml input configs (default: ./inputs.d)
#   output_file — results file (default: fingerprint-audit-<timestamp>.csv)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${1:-${SCRIPT_DIR}/inputs.d}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="${2:-fingerprint-audit-${TIMESTAMP}.csv}"
DEFAULT_HASH_SIZE=1024

if [[ ! -d "$CONFIG_DIR" ]]; then
  echo "Error: config directory '$CONFIG_DIR' does not exist." >&2
  exit 1
fi

# ── Parse a single yml file ─────────────────────────────────────────────────
# Extracts pairs of (path_pattern, fingerprint_length) per stream.
# Emits lines: <hash_size>|<path_pattern>
parse_config() {
  local file="$1"
  local current_hash_size="$DEFAULT_HASH_SIZE"
  local in_paths=false
  local pending_paths=()

  while IFS= read -r line; do
    # Detect fingerprint length (block or dotted style)
    #   prospector.scanner.fingerprint.length: 2048
    #   or indented:  length: 2048  (under prospector.scanner.fingerprint:)
    if [[ "$line" =~ fingerprint\.length:[[:space:]]*([0-9]+) ]]; then
      current_hash_size="${BASH_REMATCH[1]}"
      continue
    fi
    # Block-style fingerprint length (indented under fingerprint:)
    if [[ "$line" =~ ^[[:space:]]+length:[[:space:]]*([0-9]+) ]] && [[ "$in_paths" == false ]]; then
      current_hash_size="${BASH_REMATCH[1]}"
      continue
    fi

    # Detect start of a new stream (resets fingerprint to default)
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id: ]]; then
      # Flush any pending paths from previous stream
      for p in "${pending_paths[@]}"; do
        echo "${current_hash_size}|${p}"
      done
      pending_paths=()
      current_hash_size="$DEFAULT_HASH_SIZE"
      in_paths=false
      continue
    fi

    # Detect paths: key
    if [[ "$line" =~ ^[[:space:]]*paths:[[:space:]]*$ ]]; then
      in_paths=true
      continue
    fi

    # Collect path entries (lines starting with "- ")
    if [[ "$in_paths" == true ]]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
        local raw_path="${BASH_REMATCH[1]}"
        # Strip surrounding quotes
        raw_path="${raw_path#\"}"
        raw_path="${raw_path%\"}"
        raw_path="${raw_path#\'}"
        raw_path="${raw_path%\'}"
        pending_paths+=("$raw_path")
      else
        # End of paths block
        in_paths=false
      fi
    fi
  done < "$file"

  # Flush remaining paths
  for p in "${pending_paths[@]}"; do
    echo "${current_hash_size}|${p}"
  done
}

# ── Main ─────────────────────────────────────────────────────────────────────
# Header
printf "file_pattern|filename|file_size|hash_size|hash_value\n" > "$OUTPUT_FILE"

total_files=0
total_configs=0

shopt -s nullglob
config_files=("$CONFIG_DIR"/*.yml)
shopt -u nullglob

if [[ ${#config_files[@]} -eq 0 ]]; then
  echo "No *.yml files found in '$CONFIG_DIR'." >&2
  exit 1
fi

for cfg in "${config_files[@]}"; do
  total_configs=$((total_configs + 1))
  cfg_name="$(basename "$cfg")"
  echo "Reading: $cfg"
  while IFS='|' read -r hash_size raw_pattern; do
    echo "  path: $raw_pattern (hash: ${hash_size}B)"

    # Expand environment variables in the pattern
    expanded=$(echo "$raw_pattern" | envsubst)

    # Glob the expanded pattern (enable globstar for ** support)
    shopt -s nullglob globstar
    matches=($expanded)
    shopt -u nullglob globstar

    for filepath in "${matches[@]}"; do
      [[ -f "$filepath" ]] || continue
      file_size=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath" 2>/dev/null)
      hash_value=$(head -c "$hash_size" "$filepath" | sha256sum | awk '{print $1}')
      printf "%s|%s|%s|%s|%s\n" "$raw_pattern" "$filepath" "$file_size" "$hash_size" "$hash_value" >> "$OUTPUT_FILE"
      total_files=$((total_files + 1))
    done
  done < <(parse_config "$cfg")
done

echo "Scanned $total_configs config(s), matched $total_files file(s). Results saved to $OUTPUT_FILE"
