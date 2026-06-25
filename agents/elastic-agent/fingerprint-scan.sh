#!/usr/bin/env bash
# fingerprint-scan.sh — compute filestream-compatible SHA256 fingerprints
# Usage: ./fingerprint-scan.sh <scan_dir> [patterns_file] [output_file]
#
# Scans <scan_dir> for files matching glob patterns read from <patterns_file>
# and writes each file's fingerprint (sha256 of the first N bytes) to the output file.
# Patterns file: one glob pattern per line, blank lines and # comments are ignored.
# Patterns may contain environment variables, e.g. ${WB_MUREX_HOME}/logs/*.mxres.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SCAN_DIR="${1:?Usage: $0 <scan_dir> [patterns_file] [output_file]}"
PATTERNS_FILE="${2:-${SCRIPT_DIR}/fingerprint-patterns.txt}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="${3:-fingerprints-${TIMESTAMP}.tsv}"
FINGERPRINT_BYTES=1024

if [[ ! -d "$SCAN_DIR" ]]; then
  echo "Error: directory '$SCAN_DIR' does not exist." >&2
  exit 1
fi

if [[ ! -f "$PATTERNS_FILE" ]]; then
  echo "Error: patterns file '$PATTERNS_FILE' not found." >&2
  exit 1
fi

# Read patterns (skip blank lines and comments, expand env vars)
PATTERNS=()
while IFS= read -r line; do
  line="${line%%#*}"      # strip inline comments
  line="${line%"${line##*[! ]}"}"
  [[ -z "$line" ]] && continue
  expanded=$(echo "$line" | envsubst)
  PATTERNS+=("$expanded")
done < "$PATTERNS_FILE"

if [[ ${#PATTERNS[@]} -eq 0 ]]; then
  echo "Error: no patterns found in '$PATTERNS_FILE'." >&2
  exit 1
fi

# Header
printf "fingerprint\tfile\n" > "$OUTPUT_FILE"

count=0
for pattern in "${PATTERNS[@]}"; do
  if [[ "$pattern" == /* ]]; then
    # Absolute path pattern — glob directly
    shopt -s nullglob
    for filepath in $pattern; do
      [[ -f "$filepath" ]] || continue
      hash=$(head -c "$FINGERPRINT_BYTES" "$filepath" | sha256sum | awk '{print $1}')
      printf "%s\t%s\n" "$hash" "$filepath" >> "$OUTPUT_FILE"
      ((count++))
    done
    shopt -u nullglob
  else
    # Simple filename glob — find under SCAN_DIR
    while IFS= read -r -d '' filepath; do
      hash=$(head -c "$FINGERPRINT_BYTES" "$filepath" | sha256sum | awk '{print $1}')
      printf "%s\t%s\n" "$hash" "$filepath" >> "$OUTPUT_FILE"
      ((count++))
    done < <(find "$SCAN_DIR" -type f -name "$pattern" -print0 | sort -z)
  fi
done

echo "Scanned $count file(s). Results saved to $OUTPUT_FILE"
