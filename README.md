# ELK Monitor

ELK Stack environment monitor — ships application logs and XML configs from mock app servers into Elasticsearch, with Kibana dashboards for visibility across environments.

---

## Architecture

```
app_mock_<env>  (Python app + Filebeat sidecar)
      │
      │  Beats (port 5050)
      ▼
   Logstash  ──►  Elasticsearch  ◄──  Kibana
```

Each mock app writes structured logs and XML config files. Filebeat ships them to Logstash, which routes them into typed Elasticsearch indices. See [CLAUDE.md](CLAUDE.md) for full architecture details.

---

## Prerequisites

- Docker with Compose v2 (`docker compose version`)
- `curl`
- `/Data/elasticsearch` directory writable on the host (created automatically by `monitor.sh`)

> **RHEL / Podman users:** see the [Podman section](#rhel--podman) below.

---

## 1. Create `.env`

Create a `.env` file in the project root with three passwords:

```bash
ELASTIC_PASSWORD=changeme
KIBANA_SYSTEM_PASSWORD=changeme
LOGSTASH_PASSWORD=changeme
```

> These are the only mandatory variables. Choose strong passwords for any non-local deployment.

---

## 2. Start the ELK Cluster

```bash
./monitor.sh
```

This single command:
1. Creates `/Data/elasticsearch` and fixes ownership for the ES container
2. Starts **Elasticsearch** and waits until healthy
3. Bootstraps security — sets `kibana_system` password, creates the `logstash_writer` role and user
4. Starts **Logstash** and **Kibana**

### Service endpoints

| Service | URL | Credentials |
|---|---|---|
| Elasticsearch | http://localhost:9200 | `elastic` / `$ELASTIC_PASSWORD` |
| Kibana | http://localhost:5601 | `elastic` / `$ELASTIC_PASSWORD` |
| Logstash Beats | localhost:5050 | — |

---

## 3. Create Kibana Data Views (once)

Run after the cluster is up and Kibana is healthy:

```bash
docker compose run --rm kibana-setup
```

Or manually from the project root:

```bash
bash kibana/setup.sh
```

This creates data views for all indices: `health-status`, `app-configs-current`, `app-configs-history`, `logs-app-*`, `app-configs-monitor`.

---

## 4. Start App Mock Environments

App servers are launched **on demand**, independently of the cluster:

```bash
./apps/run_app_server.sh start staging
./apps/run_app_server.sh start prod
./apps/run_app_server.sh start uat
```

Each environment gets its own config directory under `apps/` and joins the `elk-monitor` network automatically. See [apps/README.md](apps/README.md) for the full guide.

---

## Cluster Management

```bash
./monitor.sh             # start (default)
./monitor.sh down        # stop and remove containers
./monitor.sh restart     # restart all services
./monitor.sh restart logstash   # restart a single service
./monitor.sh logs kibana        # tail logs for a service
./monitor.sh status      # show container status
```

---

## RHEL / Podman

Use the Podman equivalents instead:

```bash
# Start the cluster
./podman-run.sh

# Add mock environments
./apps/podman-add-server.sh start staging
./apps/podman-add-server.sh start uat

# Stop the cluster
./podman-run.sh down
```

> The Dockerfile in `apps/` downloads a **linux-arm64** Filebeat binary by default. On x86_64 hosts, change `arm64` to `x86_64` in [apps/Dockerfile](apps/Dockerfile) before building.

---

## Project Structure

```
monitor.sh                        # cluster lifecycle (Docker)
podman-run.sh                     # cluster lifecycle (Podman)
docker-compose.yml                # ELK cluster services
podman-kube.yml                   # ELK cluster pod manifests (Podman)
apps/
  run_app_server.sh               # app server lifecycle (Docker)
  podman-add-server.sh            # app server lifecycle (Podman)
  docker-compose.app-mock.yml     # app server compose template
  podman-kube-app-mock.yml        # app server pod manifest template
  Dockerfile                      # shared app + Filebeat image
  filebeat.yml                    # shared Filebeat config
  app_mock_v1/                    # built-in staging environment
  app_mock_v2/                    # built-in production environment
logstash/
  pipelines.yml
  pipeline/app.conf               # main routing pipeline
  pipeline/log.conf               # log grok parsing pipeline
kibana/
  setup.sh                        # creates Kibana data views
  dashboards/                     # exported .ndjson dashboards
```
