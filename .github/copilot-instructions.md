# ELK Monitor — Copilot Project Instructions

This is an ELK-based environment-monitoring stack: mock apps + Filebeat/Elastic Agent sidecars → Logstash pipelines → Elasticsearch → Kibana.

Always read [AGENTS.md](../AGENTS.md) and [CLAUDE.md](../CLAUDE.md) for full architecture context before making non-trivial changes.

## Per-Entity Settings — Where Things Live

When changing behaviour for a given entity, edit **only** the file(s) below for that entity. Do not duplicate settings across entities.

| Entity | Config location | Notes |
|---|---|---|
| Elasticsearch | [deployment/docker/docker-compose.yml](../deployment/docker/docker-compose.yml), [deployment/podman/podman-kube-es.yml](../deployment/podman/podman-kube-es.yml) | Data dir `/Data/elasticsearch` (host UID 1000). Credentials from `.env`. |
| Kibana | [kibana/kibana.yml](../kibana/kibana.yml), [kibana/setup.sh](../kibana/setup.sh), [kibana/dashboards/](../kibana/dashboards/) | Data Views provisioned via `setup.sh` only — never inline in compose. |
| Logstash (global) | [logstash/logstash.yml](../logstash/logstash.yml), [logstash/pipelines.yml](../logstash/pipelines.yml) | Register every new pipeline in `pipelines.yml` under the right category. |
| Logstash routing | [logstash/pipeline/main.conf](../logstash/pipeline/main.conf), `logstash/pipeline/<category>/_dispatch.conf` | Two-tier: `main.conf` routes by `fields.type` prefix to a category address (`app_in` / `elk_in` / `mrx_in`); each category's `_dispatch.conf` routes `fields.type → leaf pipeline`. |
| App pipelines | [logstash/pipeline/app/](../logstash/pipeline/app/) | `app_config`, `app_db_config`, `app_logs`, `heartbeat`. |
| ELK infra pipelines | [logstash/pipeline/elk/](../logstash/pipeline/elk/) | |
| Murex log pipelines | [logstash/pipeline/mrx/logs/](../logstash/pipeline/mrx/logs/) | One `mrx-log-*.conf` per log family. |
| Murex config pipelines | [logstash/pipeline/mrx/config/](../logstash/pipeline/mrx/config/) | `mrx-config.conf` (and future `mrx-config-*.conf`). |
| Filebeat (apps) | [apps/filebeat.yml](../apps/filebeat.yml) | Single shared config for all `app_config_v*` containers. |
| Filebeat (ELK infra) | [logstash/filebeat-elk-infra.yml](../logstash/filebeat-elk-infra.yml) | |
| Filebeat (Murex) | [logstash/filebeat-mrx.yml](../logstash/filebeat-mrx.yml) | |
| Elastic Agent (apps) | [apps/elastic-agent.yml](../apps/elastic-agent.yml) | |
| Elastic Agent (Murex) | [elastic-agent/elastic-agent-mrx.yml](../elastic-agent/elastic-agent-mrx.yml) + [elastic-agent/inputs.d/](../elastic-agent/inputs.d/) | One YAML per Murex component. |
| Mock app code | [apps/app_server.py](../apps/app_server.py) | Shared by `app_config_v1` and `app_config_v2`. |
| Mock app — staging | [apps/app_config_v1/config/](../apps/app_config_v1/config/) | XML only; do not fork `app_server.py`. |
| Mock app — production | [apps/app_config_v2/config/](../apps/app_config_v2/config/) | XML only; do not fork `app_server.py`. |
| App container image | [apps/deployment/Dockerfile](../apps/deployment/Dockerfile), [apps/deployment/Dockerfile.elastic-agent](../apps/deployment/Dockerfile.elastic-agent) | Filebeat arch is `arm64` by default — switch to `amd64` for x86 hosts. |
| Secrets | `.env` in repo root | Required: `ELASTIC_PASSWORD`, `KIBANA_SYSTEM_PASSWORD`, `LOGSTASH_PASSWORD`. Never commit. Never hardcode in compose/YAML. |

## Deployment Process — Strict Order

ELK cluster and app servers are deployed separately. Do not merge them into one compose file.

**1. ELK cluster (Docker):**
```bash
./deployment/docker/run_monitor.sh           # up
./deployment/docker/run_monitor.sh down|restart <svc>|logs <svc>|status
```
**ELK cluster (Podman):** [deployment/podman/run_monitor.sh](../deployment/podman/run_monitor.sh) with the same verbs.

**2. Kibana Data Views** (run once, after Kibana is healthy — not auto-provisioned):
```bash
./kibana/setup.sh
```

**3. App servers** (on-demand, separate from the ELK stack):
```bash
./apps/deployment/docker/run_app_server.sh           # Docker
./apps/deployment/podman/podman-add-server.sh        # Podman
```

When adding a new deployment step, extend the matching `run_*.sh` wrapper — do not introduce a new top-level script.

## Hard Rules

- **Routing:** Adding a new event type within an existing category: (a) set `fields.type` (matching the category prefix `app_` / `elk_` / `mrx_`) in the Filebeat/Elastic Agent input, (b) add a branch in `pipeline/<category>/_dispatch.conf`, (c) register the leaf pipeline in [pipelines.yml](../logstash/pipelines.yml). Do not edit `main.conf` for new types — only for new categories.
- **`app-configs-current` index:** uses `update` with `doc_as_upsert`. The `config.app` and `config.db` sub-keys come from different inputs and must be written independently — never merged into one write.
- **XML collection:** Filebeat multiline is anchored on `<?xml`. Every collected XML config must start with `<?xml` or it will not be ingested correctly.
- **New environment / app entity:** copy an existing `apps/app_config_vN/` directory, edit only its XML, and add a compose/kube entry. Do not modify `app_server.py` or [apps/filebeat.yml](../apps/filebeat.yml).
- **New pipeline category:** create `logstash/pipeline/<category>/_dispatch.conf` with `input { pipeline { address => "<cat>_in" } }`, add one branch in [main.conf](../logstash/pipeline/main.conf), and register the dispatcher + leaves in `pipelines.yml`.
- **No secrets in code or compose files** — always read from `.env`.
- **No documentation drift:** when changing structure, update [AGENTS.md](../AGENTS.md) (and [CLAUDE.md](../CLAUDE.md) if architecture changes).

## Common Pitfalls

- Filebeat ARM64 binary baked into [apps/deployment/Dockerfile](../apps/deployment/Dockerfile) — switch to `amd64` on x86 hosts.
- `/Data/elasticsearch` must be owned by UID 1000 on Linux (`run_monitor.sh` handles this).
- First Logstash startup updates `logstash-input-beats` (~60 s extra). Don't mistake this for a hang.
- Heartbeat pipeline is currently **disabled** in `pipelines.yml` — leave it disabled unless explicitly requested.
