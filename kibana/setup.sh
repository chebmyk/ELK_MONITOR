#!/bin/sh
set -e

# Kibana / ES URL scheme is https by default; override via KIBANA_SCHEME=http if TLS is disabled.
SCHEME="${KIBANA_SCHEME:-https}"
KIBANA_URL="${SCHEME}://${KIBANA_HOST}:${KIBANA_PORT}"

# Optional: trust the project CA so curl validates the server cert. When the
# CA file is missing (e.g. running outside the bind-mount), fall back to -k.
CA_FILE="${KIBANA_CA_CERT:-/kibana/certs/ca/ca.crt}"
if [ -r "$CA_FILE" ]; then
  CURL_TLS="--cacert $CA_FILE"
else
  CURL_TLS="-k"
fi

echo "Waiting for Kibana to be available at $KIBANA_URL ..."
until curl -sf $CURL_TLS "$KIBANA_URL/api/status" | grep -q '"level":"available"'; do
  echo "  Kibana not ready yet, retrying in 5s..."
  sleep 5
done
echo "Kibana is ready."

create_data_view() {
  title="$1"
  time_field="${2:-@timestamp}"
  echo "Creating data view: $title"
  curl -sf $CURL_TLS -X POST "$KIBANA_URL/api/data_views/data_view" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -d "{\"data_view\":{\"title\":\"$title\",\"timeFieldName\":\"$time_field\"}}" \
    | grep -o '"id":"[^"]*"' | head -1
  echo
}

# health-status: current service up/down state (upserted, one doc per env+service)
create_data_view "health-status"

# app-configs-current: latest config values per host
create_data_view "app-configs-current"

# app-configs-history: one doc per config change event
create_data_view "app-configs-history"

# logs-app-*: daily rolling application logs
create_data_view "app-logs-*"

# elk-logs-*: daily rolling ELK internal logs (elastic, logstash, kibana)
create_data_view "elk-logs-*"

echo "All data views created. Open Kibana at $KIBANA_URL"
