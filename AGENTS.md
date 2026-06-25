# ELK Monitor — Agent Instructions

ELK-based environment monitoring stack with mock applications, Filebeat sidecars, Logstash pipelines, and Kibana dashboards. See [CLAUDE.md](CLAUDE.md) for architecture details.

## Starting the Stack

**Docker:**
```bash
./deployment/docker/monitor.sh            # start all services
./deployment/docker/monitor.sh down       # stop and remove containers
./deployment/docker/monitor.sh restart logstash   # restart a single service
./deployment/docker/monitor.sh logs kibana        # tail service logs
./deployment/docker/monitor.sh status             # container status
```

**Podman / RHEL:**
```bash
./deployment/podman/podman-run.sh            # start all services
./deployment/podman/podman-run.sh down       # stop and remove pods
./deployment/podman/podman-run.sh status     # pod status
./deployment/podman/podman-run.sh logs kibana
```

**Kibana Data Views** (run once after `kibana` is healthy — not auto-provisioned):
```bash
docker compose -f deployment/docker/docker-compose.yml run --rm kibana-setup
# or manually: uncomment the kibana-setup service in deployment/docker/docker-compose.yml, then
# docker compose -f deployment/docker/docker-compose.yml up kibana-setup
```

## Required: `.env` File

The stack will not start without a `.env` file in the project root. Three variables are mandatory:

```
ELASTIC_PASSWORD=<your-password>
KIBANA_SYSTEM_PASSWORD=<your-password>
LOGSTASH_PASSWORD=<your-password>
```

`deployment/docker/monitor.sh up` bootstraps the `kibana_system` password and creates the `logstash_writer` role automatically on first run.

## Service Endpoints

| Service | URL |
|---|---|
| Elasticsearch | `http://localhost:9200` (user: `elastic`) |
| Kibana | `http://localhost:5601` |
| Logstash Beats input | `localhost:5050` |

## Key Conventions

### Filebeat `fields.type` → Logstash routing

Every Filebeat input sets `fields.type`; all Logstash routing logic is gated on this value:

| `fields.type` | Source | Target Index |
|---|---|---|
| `heartbeat` | JSON lines from `app.py` | `health-status` (upsert) |
| `app_config` | `config/*.xml` | `app-configs-current` + `app-configs-history` |
| `app_db_config` | `config/db/*.xml` | `app-configs-current` + `app-configs-history` |
| `app_log` | `*.log` | `logs-app-{hostname}-{YYYY.MM.dd}` (via pipeline-to-pipeline) |
| `config_monitor` | all XML under `/app/config` | `app-configs-monitor` (hash-based dedup) |

### Logstash pipelines — two-tier routing

Pipelines are defined in [`logstash/pipelines.yml`](logstash/pipelines.yml), organised by category.

```
beats:5050
  └─ main_pipeline (main.conf)        ← routes by fields.type prefix to a CATEGORY
       ├─ app_in   → app_dispatch     → leaf app_*  pipelines
       ├─ elk_in   → elk_dispatch     → leaf elk_*  pipelines
       └─ mrx_in   → mrx_dispatch     → leaf mrx_*  pipelines
```

[`main.conf`](logstash/pipeline/main.conf) only knows about categories. Each category owns a `_dispatch.conf` that routes `fields.type → leaf pipeline`.

| Category | Directory | Dispatcher input addr | Leaves |
|---|---|---|---|
| **app** | `pipeline/app/` | `app_in` | `app_config_pipeline`, `app_config_audit_pipeline`, `app_logs_pipeline`, `heartbeat_pipeline` (disabled) |
| **elk** | `pipeline/elk/` | `elk_in` | `elk_infra_pipeline` |
| **mrx** | `pipeline/mrx/` | `mrx_in` | Sub-categories: `mrx/logs/` (10 leaf pipelines — service, server, connectivity, integrations, …) and `mrx/config/` (`mrx_config_pipeline`). |

**Adding a new event TYPE inside an existing category:**
1. Add a branch in `pipeline/<category>/_dispatch.conf`.
2. Register the new leaf pipeline in `pipelines.yml`.
  No changes to `main.conf`.

**Adding a new CATEGORY:**
1. Create `pipeline/<category>/_dispatch.conf` with `input { pipeline { address => "<cat>_in" } }`.
2. Add ONE branch in `main.conf`.
3. Register the dispatcher and leaves in `pipelines.yml`.

### `app-configs-current` partial updates

This index uses ES `update` with `doc_as_upsert`. The `config.app` and `config.db` sub-keys are written independently (different Filebeat inputs) and **must never be merged into a single write** or one will overwrite the other.

### Mock apps

`app_mock_v1` (staging) and `app_mock_v2` (production) share the same Dockerfile and `app.py` logic. To add a new environment, copy one of these directories and update the XML configs and the `docker-compose.yml` entry.

## Common Pitfalls

- **ARM64 Filebeat binary** — [`apps/Dockerfile`](apps/Dockerfile) downloads `filebeat-9.4.1-linux-arm64.tar.gz`. On x86/amd64 hosts, change `arm64` to `amd64` in the Dockerfile.
- **ES data directory** — `/Data/elasticsearch` must exist on the host. On Linux, it must be owned by UID 1000 (`chown -R 1000:1000 /Data/elasticsearch`). `monitor.sh` does this automatically on Linux.
- **Slow Logstash cold start** — Logstash updates the `logstash-input-beats` plugin at every startup. This adds ~60 seconds to the first `docker compose up`.
- **XML multiline in Filebeat** — XML configs are collected as one event using multiline anchored on `<?xml`. If an XML file does not start with `<?xml`, the event will not be collected correctly.
- **Kibana Data Views not auto-created** — The `kibana-setup` service in `deployment/docker/docker-compose.yml` is commented out. Run [`kibana/setup.sh`](kibana/setup.sh) manually against a running Kibana.

## Project Structure

```
apps/
  Dockerfile              — shared image for all app_mock_* containers; installs Python + Filebeat sidecar
  filebeat.yml            — shared Filebeat config mounted into both containers
  deployment/
    docker/
      docker-compose.app-mock.yml  — Compose template for on-demand app_mock containers
      run_app_server.sh       — CLI for managing Docker app_mock environments
    podman/
      podman-kube-app-mock.yml     — Kube manifest template for app_mock pods
      podman-add-server.sh    — CLI for managing Podman app_mock environments
  app_mock_v1/            — staging environment mock (app.py + XML configs)
  app_mock_v2/            — production environment mock (app.py + XML configs)
deployment/
  docker/
    docker-compose.yml    — ELK cluster stack (Elasticsearch, Logstash, Kibana)
    monitor.sh            — CLI wrapper for the Docker ELK cluster
  podman/
    podman-kube.yml       — Kube manifest for the ELK cluster
    podman-run.sh         — CLI wrapper for the Podman ELK cluster
logstash/
  pipelines.yml           — declares all pipelines, organised by category
  pipeline/
    main.conf             — top-level router (fields.type prefix → category address)
    app/                  — app monitoring category (_dispatch.conf + leaves)
    elk/                  — ELK infrastructure category (_dispatch.conf + leaves)
    mrx/                  — Murex category: nested dispatch into
                            mrx/logs/   (_dispatch.conf + 10 mrx-log-*.conf leaves)
                            mrx/config/ (_dispatch.conf + mrx-config.conf)
kibana/
  setup.sh                — creates all Kibana Data Views via REST API
  dashboards/             — exported .ndjson dashboard definitions
docs/readme.md            — ES vs SQL concept mapping reference
```
