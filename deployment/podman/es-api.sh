#!/usr/bin/env bash
# es-api.sh — Elasticsearch REST API helper for ELK Monitor bootstrap
#
# Usage: es-api.sh [--url URL] [--auth USER:PASS] [--cacert FILE] <command> [args...]
#
# Commands:
#   set-password  <username> <password>
#   create-role   <role-name> <json>
#   create-user   <username>  <json>
#   delete-user   <username>
#   delete-role   <role-name>
#   health        [yellow|green]    check cluster health (default: yellow)
#   get-user      <username>
#   get-role      <role-name>
#
# Env vars (overridden by flags):
#   ES_URL    — Elasticsearch base URL  (default: http://localhost:9200)
#   ES_AUTH   — user:password           (default: elastic:changeme)
#   ES_CACERT — path to CA cert         (used when ES_URL is https://; falls back to -k)
#
# Exit codes:
#   0  — success
#   1  — usage / argument error
#   2  — connection failed (curl returned 000)
#   3  — Elasticsearch returned a non-2xx HTTP status

set -euo pipefail

die()  { echo "ERROR: $*" >&2; exit 1; }
die2() { echo "ERROR: $*" >&2; exit 2; }
die3() { echo "ERROR: $*" >&2; exit 3; }

# ── parse global flags ────────────────────────────────────────────────────────
_url="${ES_URL:-http://localhost:9200}"
_auth="${ES_AUTH:-elastic:changeme}"
_cacert="${ES_CACERT:-}"

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --url)    _url="$2";    shift 2 ;;
    --auth)   _auth="$2";   shift 2 ;;
    --cacert) _cacert="$2"; shift 2 ;;
    --help)   grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)        die "Unknown flag: $1" ;;
  esac
done

# Build the TLS curl args. When the URL is https and a CA file is provided
# (and readable), use --cacert; otherwise fall back to -k for self-signed
# bootstrap. For http URLs the args are empty.
_tls=()
if [[ "$_url" == https://* ]]; then
  if [[ -n "$_cacert" && -r "$_cacert" ]]; then
    _tls=(--cacert "$_cacert")
  else
    _tls=(-k)
  fi
fi

[[ $# -ge 1 ]] || { grep '^# Usage' "$0" | sed 's/^# //'; exit 1; }

COMMAND="$1"; shift

# ── HTTP helper ───────────────────────────────────────────────────────────────
# _request <description> [curl-args...]
# Prints the response body on success; exits with error on failure.
_request() {
  local desc="$1"; shift
  local tmp http_code
  tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN

  http_code=$(curl -s -o "$tmp" -w '%{http_code}' "$@") || true

  if [[ "$http_code" == "000" ]]; then
    die2 "${desc}: cannot connect to ${_url} — is Elasticsearch up and is the port mapped?"
  fi

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "FAILED (HTTP ${http_code}):" >&2
    cat "$tmp" >&2
    die3 "${desc} returned HTTP ${http_code}"
  fi

  cat "$tmp"
}

# ── commands ──────────────────────────────────────────────────────────────────
case "$COMMAND" in

  set-password)
    [[ $# -eq 2 ]] || die "Usage: set-password <username> <password>"
    _request "set-password(${1})" \
      "${_tls[@]}" \
      -X POST -u "$_auth" \
      -H "Content-Type: application/json" \
      "${_url}/_security/user/${1}/_password" \
      -d "{\"password\":\"${2}\"}"
    ;;

  create-role)
    [[ $# -eq 2 ]] || die "Usage: create-role <role-name> <json>"
    _request "create-role(${1})" \
      "${_tls[@]}" \
      -X PUT -u "$_auth" \
      -H "Content-Type: application/json" \
      "${_url}/_security/role/${1}" \
      -d "$2"
    ;;

  create-user)
    [[ $# -eq 2 ]] || die "Usage: create-user <username> <json>"
    _request "create-user(${1})" \
      "${_tls[@]}" \
      -X PUT -u "$_auth" \
      -H "Content-Type: application/json" \
      "${_url}/_security/user/${1}" \
      -d "$2"
    ;;

  delete-user)
    [[ $# -eq 1 ]] || die "Usage: delete-user <username>"
    _request "delete-user(${1})" \
      "${_tls[@]}" \
      -X DELETE -u "$_auth" \
      "${_url}/_security/user/${1}"
    ;;

  delete-role)
    [[ $# -eq 1 ]] || die "Usage: delete-role <role-name>"
    _request "delete-role(${1})" \
      "${_tls[@]}" \
      -X DELETE -u "$_auth" \
      "${_url}/_security/role/${1}"
    ;;

  get-user)
    [[ $# -eq 1 ]] || die "Usage: get-user <username>"
    _request "get-user(${1})" \
      "${_tls[@]}" \
      -u "$_auth" \
      "${_url}/_security/user/${1}"
    ;;

  get-role)
    [[ $# -eq 1 ]] || die "Usage: get-role <role-name>"
    _request "get-role(${1})" \
      "${_tls[@]}" \
      -u "$_auth" \
      "${_url}/_security/role/${1}"
    ;;

  health)
    status="${1:-yellow}"
    _request "health" \
      "${_tls[@]}" \
      -u "$_auth" \
      "${_url}/_cluster/health?wait_for_status=${status}&timeout=5s"
    ;;

  *)
    die "Unknown command: ${COMMAND}
Commands: set-password, create-role, create-user, delete-user, delete-role, get-user, get-role, health"
    ;;

esac
