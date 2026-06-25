# ELK Monitor — TLS certificates

This directory holds the helper that produces the TLS material consumed by
Elasticsearch, Kibana, and Logstash. The certs themselves live on the host at
`${ELK_CERTS_DIR}` (default: `/Data/elastic/certs`, see [.env](../../.env)) and
are bind-mounted **read-only** into each container at `<APP>/config/certs`.

## Expected layout

The deployment configs reference these exact file paths. Whatever method you
use to obtain certs, the result on disk **must** match this layout:

```
${ELK_CERTS_DIR}/
├── ca/
│   └── ca.crt                      # trust chain (root + intermediates) in PEM
├── elasticsearch/
│   ├── elasticsearch.crt           # server cert (leaf, optionally + chain)
│   └── elasticsearch.key           # server private key, PEM, unencrypted
└── kibana/
    ├── kibana.crt
    └── kibana.key
```

`run_monitor.sh` (Docker and Podman) auto-runs [generate-certs.sh](generate-certs.sh)
only when these files are missing — drop-in replacements are not overwritten.

## Mode A — self-signed (default, dev/POC)

```bash
./deployment/certs/generate-certs.sh           # generate if missing
./deployment/certs/generate-certs.sh --force   # regenerate everything
```

Creates a self-signed root CA and leaf certs for `elasticsearch` and `kibana`
with the SANs needed inside the elk-monitor pod/network:

| Leaf            | DNS SANs                                       | IP SANs       |
|-----------------|------------------------------------------------|---------------|
| `elasticsearch` | `elasticsearch`, `elasticsearch-pod`, `localhost` | `127.0.0.1` |
| `kibana`        | `kibana`, `kibana-pod`, `localhost`            | `127.0.0.1` |

Override via env vars (in `.env` or shell):

```bash
ELK_CERTS_DIR=/var/data/elk-certs        # target directory
CERT_DAYS=3650                            # validity in days
ES_SAN_DNS=elasticsearch,es.example.com   # comma-separated DNS SANs
ES_SAN_IP=127.0.0.1,10.0.0.5
KIBANA_SAN_DNS=kibana,kibana.example.com
KIBANA_SAN_IP=127.0.0.1
```

## Mode B — corporate / public CA (bring your own)

If you already have certs signed by an internal CA or a public issuer, place
the files directly using the layout above and skip the generator entirely.

Two important rules:

1. **`ca/ca.crt` must contain the full trust chain.** Concatenate root +
   every intermediate, in any order, in PEM:
   ```
   -----BEGIN CERTIFICATE-----
   ...intermediate-1...
   -----END CERTIFICATE-----
   -----BEGIN CERTIFICATE-----
   ...root...
   -----END CERTIFICATE-----
   ```
   Logstash, Kibana, and Elasticsearch all reference this single file as their
   trust store (`ssl_certificate_authorities` / `elasticsearch.ssl.certificateAuthorities`
   / `xpack.security.http.ssl.certificate_authorities`).

2. **`elasticsearch.crt` / `kibana.crt`** can be either the leaf alone or
   the leaf followed by the intermediates (leaf first). The leaf-plus-chain
   form is preferred — clients that don't pre-trust your CA still receive
   the full chain during the TLS handshake.

3. The `.key` files must be **unencrypted** PEM. If yours are encrypted,
   strip the passphrase first:
   ```bash
   openssl rsa -in encrypted.key -out elasticsearch.key
   ```

4. The leaf cert SANs must include the hostnames each container is reached
   by. At minimum:
   - Elasticsearch: `localhost`, `127.0.0.1`, plus the in-network name
     (`elasticsearch-pod` for Podman, `elasticsearch` for Docker).
   - Kibana: `localhost`, `127.0.0.1`, plus `kibana-pod` (Podman) /
     `kibana` (Docker), plus any external hostname browsers use.

### Example: split a corporate `.p12` bundle into the expected layout

```bash
# Extract leaf + intermediates + key from a PKCS#12 bundle
openssl pkcs12 -in corp-elasticsearch.p12 -nocerts -nodes \
  -out ${ELK_CERTS_DIR}/elasticsearch/elasticsearch.key
openssl pkcs12 -in corp-elasticsearch.p12 -clcerts -nokeys \
  -out ${ELK_CERTS_DIR}/elasticsearch/elasticsearch.crt
openssl pkcs12 -in corp-elasticsearch.p12 -cacerts -nokeys -chain \
  -out ${ELK_CERTS_DIR}/ca/ca.crt
chmod 600 ${ELK_CERTS_DIR}/elasticsearch/elasticsearch.key
```

Repeat for `kibana`.

## Container UID / SELinux notes

- All three Elastic container images run as **UID 1000**. The Podman
  `run_monitor.sh` automatically `podman unshare chown -R 1000:1000` the
  certs directory and applies the `container_file_t` label when SELinux is
  enforcing.
- `*.key` files are mode `0600`; `*.crt` files are `0644`.
- The certs directory is mounted **read-only** into every container, so
  rotation only requires updating the host files and restarting the
  containers (no `--down` needed for cert refresh, but containers must
  reread the files — `docker compose restart` / `podman pod restart` is
  enough).

## Rotating certs

```bash
# 1. Replace the files under ${ELK_CERTS_DIR} with the new chain
# 2. Restart the stack to pick up the new material
./deployment/docker/run_monitor.sh   restart elasticsearch
./deployment/docker/run_monitor.sh   restart kibana
./deployment/docker/run_monitor.sh   restart logstash
# Podman:
./deployment/podman/run_monitor.sh   down && ./deployment/podman/run_monitor.sh   up
```

`run_monitor.sh up` will **not** overwrite existing cert files, so you can
re-run it idempotently after dropping in new certs.

## Disabling TLS (HTTP-only mode)

Set the following in `.env` and remove the SSL settings from
[elastic/elasticsearch.yml](../../elastic/elasticsearch.yml) and
[kibana/kibana.yml](../../kibana/kibana.yml):

```
ELASTIC_SCHEME=http
KIBANA_SCHEME=http
```

This is intended for local debugging only — never run the stack on HTTP
in any shared environment.
