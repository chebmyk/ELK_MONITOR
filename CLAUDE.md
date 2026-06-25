# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the Stack

```bash
# Start all services
monitor.sh

Service endpoints when running locally:
- Elasticsearch: `http://localhost:9200`
- Kibana: `http://localhost:5601`
- Logstash Beats input: `localhost:5050`

## Architecture

### Data Flow

```
app_mock_v1 / app_mock_v2
  ├── app.py        — generates logs + reads XML configs at startup
  ├── config/*.xml  — app config (app_config type)
  ├── config/db/*.xml — datasource config (app_db_config type)
  └── logs/*.log    — structured log lines + heartbeat JSON

Filebeat (sidecar in same container)
  └── ships to Logstash :5050

Logstash — two-tier routing (pipelines.yml):
  main_pipeline (main.conf)   ← routes by fields.type prefix to a category dispatcher
     ├── app_dispatch (_dispatch.conf in pipeline/app/)
     ├── elk_dispatch (_dispatch.conf in pipeline/elk/)
     └── mrx_dispatch (_dispatch.conf in pipeline/mrx/)
          ├── mrx_logs_dispatch   (pipeline/mrx/logs/)
          └── mrx_config_dispatch (pipeline/mrx/config/)
  ├── app category (pipeline/app/)
  │   ├── app_config    → Elasticsearch: app-main-config-current  (upsert by host.name)
  │   │                 → (partial update so config.app / config.db never overwrite each other)
  │   ├── app_db_config → same dual-write as app_config
  │   ├── app_log       → Elasticsearch: app-logs-{host}-{date}
  │   └── heartbeat     → Elasticsearch: health-status (upsert)  [disabled]
  ├── elk category (pipeline/elk/)
  │   └── elk_infra_log → Elasticsearch: logs-elk-{component}-{date}
  └── mrx category (pipeline/mrx/)
      ├── mrx_service_log / mrx_server_log / … → mrx-log-{host}-{date}
      ├── mrx_service_events_log              → mrx-events-{host}-{date}
      └── mrx_service_access_log              → mrx-access-{host}-{date}
```

### Elasticsearch Indices

| Index | Key Field | Write Strategy |
|---|---|---|
| `health-status` | `{environment}-{service_name}` | upsert (one doc per env+service) |
| `app-configs-current` | `{host.name}` | upsert (one doc per host, partial update so `config.app` and `config.db` sub-keys never overwrite each other) |
| `app-configs-history` | auto | append (new doc on every ingest; Filebeat only re-ships when file mtime changes, preventing duplicates) |
| `logs-app-{hostname}-{YYYY.MM.dd}` | — | append, daily rolling |

### Field Taxonomy

Filebeat tags each input with `fields.type` which controls all routing in Logstash:
- `heartbeat` — JSON lines, one per service per cycle
- `app_config` — full XML document from `config/*.xml`
- `app_db_config` — full XML document from `config/db/*.xml`
- `app_log` — multi-line log entries from `*.log`

XML config events are collected as a single document via Filebeat multiline (anchored on `<?xml`).

### Mock Applications

`app_mock_v1` and `app_mock_v2` are identical in structure but carry different XML configs (different name, version, environment, datasource). They exist to simulate multiple environments visible in Kibana simultaneously. `app.py` spawns three service threads (`main`, `worker`, `scheduler`) each writing to their own log file at weighted random log levels (70% INFO / 20% WARN / 10% ERROR).

### Kibana Data Views

Defined in `kibana/setup.sh` and provisioned by the commented-out `kibana-setup` service in `docker-compose.yml`. Run it manually after `kibana` is healthy.
