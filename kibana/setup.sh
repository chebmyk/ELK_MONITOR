#!/bin/sh
set -e

KIBANA_URL="http://kibana:5601"

echo "Waiting for Kibana to be available..."
until curl -sf "$KIBANA_URL/api/status" | grep -q '"level":"available"'; do
  echo "  Kibana not ready yet, retrying in 5s..."
  sleep 5
done
echo "Kibana is ready."

create_data_view() {
  local title="$1"
  local time_field="${2:-@timestamp}"
  echo "Creating data view: $title"
  curl -sf -X POST "$KIBANA_URL/api/data_views/data_view" \
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

echo "All data views created. Open Kibana at $KIBANA_URL"
