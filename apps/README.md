# App Mock — Guide

Mock application servers that simulate monitored environments. Each instance runs as an independent container and ships logs and config files into the ELK cluster via a Filebeat sidecar.

> **Prerequisite:** The ELK cluster must be running first (`deployment/docker/monitor.sh` or `deployment/podman/podman-run.sh` from the project root).

---

## Directory Structure

```
apps/
├── Dockerfile                   # Shared image: Python 3.11 + Filebeat sidecar
├── filebeat.yml                 # Shared Filebeat config (mounted into every container)
├── deployment/
│   ├── docker/
│   │   ├── docker-compose.app-mock.yml  # Compose template for Docker-based environments
│   │   └── run_app_server.sh            # CLI for Docker environments
│   └── podman/
│       ├── podman-kube-app-mock.yml     # Kube manifest template for Podman-based environments
│       └── podman-add-server.sh         # CLI for Podman / RHEL environments
├── app_mock_v1/                 # Built-in environment: staging
│   ├── app.py
│   └── config/
│       ├── app.xml
│       ├── cache.xml
│       ├── messaging.xml
│       ├── server.xml
│       └── db/datasource.xml
└── app_mock_v2/                 # Built-in environment: production
    └── ...

deployment/
├── docker/
│   ├── docker-compose.yml           # ELK cluster (Elasticsearch, Logstash, Kibana)
│   └── monitor.sh                   # CLI for the Docker ELK cluster
└── podman/
    ├── podman-kube.yml              # Kube manifest for the ELK cluster
    └── podman-run.sh                # CLI for the Podman ELK cluster
```

When you start a new named environment (e.g. `uat`), the script scaffolds `apps/app_mock_uat/` automatically from the `app_mock_v1` template.

---

## Docker — `run_app_server.sh`

Run from **anywhere** in the project. The script locates the project root automatically.

### Start an environment

```bash
./apps/deployment/docker/run_app_server.sh start <env_name>
```

Examples:
```bash
./apps/deployment/docker/run_app_server.sh start staging
./apps/deployment/docker/run_app_server.sh start uat
./apps/deployment/docker/run_app_server.sh start prod
```

On first run for a new `env_name`, the script:
1. Creates `apps/app_mock_<env_name>/` from the `app_mock_v1` template
2. Patches `config/app.xml` and `config/db/datasource.xml` with the new name
3. Builds the `app-mock:latest` image (if not already built)
4. Starts the container joined to the `elk-monitor` network

### Stop an environment

```bash
./apps/deployment/docker/run_app_server.sh stop <env_name>
```

### List environments

```bash
./apps/deployment/docker/run_app_server.sh list
```

Output shows both **running containers** and **available config directories**.

### Tail logs

```bash
./apps/deployment/docker/run_app_server.sh logs <env_name>
```

### Rebuild the image

Required after any change to `Dockerfile`, `filebeat.yml`, or `app.py`:

```bash
./apps/deployment/docker/run_app_server.sh build
```

---

## Podman / RHEL — `podman-add-server.sh`

Identical commands to `run_app_server.sh`, but uses `podman play kube` instead of Docker Compose.

### Prerequisites

```bash
sudo dnf install -y gettext   # provides envsubst
```

### Commands

```bash
./apps/deployment/podman/podman-add-server.sh start <env_name>
./apps/deployment/podman/podman-add-server.sh stop  <env_name>
./apps/deployment/podman/podman-add-server.sh list
./apps/deployment/podman/podman-add-server.sh logs  <env_name>
./apps/deployment/podman/podman-add-server.sh build
```

---

## Customising an Environment

Each environment directory contains the full XML config set:

| File | Purpose |
|---|---|
| `config/app.xml` | Application name, version, environment label |
| `config/cache.xml` | Cache settings |
| `config/messaging.xml` | Messaging/queue settings |
| `config/server.xml` | Server/port settings |
| `config/db/datasource.xml` | Database connection settings |

Edit these files while the container is running — Filebeat polls them every 15 seconds and ships any changes to Elasticsearch (`app-configs-current` and `app-configs-history` indices).

---

## How It Works

```
app_mock_<env_name>/
  app.py          — spawns 3 service threads (main, worker, scheduler)
                    writing weighted-random log lines (70% INFO / 20% WARN / 10% ERROR)
  config/*.xml    — shipped by Filebeat as app_config events
  config/db/*.xml — shipped as app_db_config events
  logs/*.log      — shipped as app_log events → daily index logs-app-{host}-{date}
```

The container hostname is set to `app_mock_<env_name>`, which becomes `host.name` in all Elasticsearch documents — used as the grouping key in Kibana dashboards.
