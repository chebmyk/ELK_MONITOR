---
name: logstash-config-validator
description: Validate the Logstash configuration of this ELK Monitor repo. Checks that every pipeline file referenced from `pipelines.yml` and `routing.yml` exists, that naming conventions are consistent, that there are no typos in `fields.type` keys / pipeline ids / `pipeline { send_to / address }` references, and that all Filebeat / Elastic Agent inputs route to a known `fields.type`. USE FOR: "validate logstash config", "check pipelines", "are there any broken pipeline references", "lint logstash". DO NOT USE FOR: running Logstash itself, grok pattern testing, or Elasticsearch index validation.
---

# Logstash Config Validator

A read-only review workflow. Output a single Markdown report with sections **Errors**, **Warnings**, **Info**, then a one-line verdict (`PASS` / `FAIL`). Do not modify any files unless the user explicitly asks for fixes.

## Scope of files

Inspect only:
- `logstash/pipeline/**`


## Checks

Run all checks. Use `grep_search` and `read_file` in parallel where independent. Do not skip a category just because the previous one had errors.

### 1. File existence
For every `path.config:` entry in `pipelines.yml`, strip the `/usr/share/logstash/` prefix and verify the file exists under `logstash/`. Report each missing file as an **Error**.

### 2. Naming conventions
- Every `pipeline.id` in `pipelines.yml` must end with `_pipeline`.
- Every `.conf` filename under `logstash/pipeline/<category>/` must use kebab-case (`mrx-service.conf`), not snake_case.
- Every category directory under `logstash/pipeline/` must be snake_case.
- The `fields.type` keys in `routing.yml` must be snake_case and end with `_log`, `_config`, `_change`, or `heartbeat`.

Report violations as **Warnings** (existing legacy names allowed but flagged).

### 3. Cross-reference integrity
- Every right-hand-side value in `routing.yml` must match a `pipeline.id` in `pipelines.yml`. Mismatch → **Error**.
- Every `pipeline.id` in `pipelines.yml` (except `main_pipeline`) should be referenced by at least one row in `routing.yml`. Orphan → **Warning** (commented-out routes count as "disabled", not orphan — note as **Info**).
- In every `*.conf`, every `pipeline { send_to => [...] }` and `pipeline { address => "..." }` must round-trip: every `send_to` target must exist as an `address` somewhere; every `address` must be a `send_to` target somewhere or be a downstream pipeline started by `pipelines.yml`. Mismatch → **Error**.
- `main.conf` must use `translate` against `routing.yml` (or equivalent) — never hardcode `if [fields][type] == "..."` routing. Hardcoded routing → **Error**.

### 4. fields.type coverage
Collect every `fields.type` value set in:
- `apps/filebeat.yml`, `apps/elastic-agent.yml`
- `logstash/filebeat-elk-infra.yml`, `logstash/filebeat-mrx.yml`
- `elastic-agent/elastic-agent-mrx.yml`, `elastic-agent/inputs.d/*.yml`

Each value must appear as a key in `routing.yml`. Missing key → **Error** ("input emits `X` but no route defined").
Each `routing.yml` key should be emitted by at least one input. Unused key → **Warning**.

### 5. Typo heuristics
For every `fields.type` and `pipeline.id` token, flag any pair whose Levenshtein distance is 1–2 and which differ only by a likely typo (e.g. `mrx_servic_log` vs `mrx_service_log`, `app_config_pipline` vs `app_config_pipeline`). Report as **Warnings**.

### 6. Hard rules from `.github/copilot-instructions.md`
- No secrets (`password:`, `ELASTIC_PASSWORD=...` literal) in any `.conf` or `.yml` under `logstash/`. Violation → **Error**.
- `app-configs-current` writes must use `action => "update"` with `doc_as_upsert => true`. Any plain `index` action targeting `app-configs-current` → **Error**.

## Report format

```
# Logstash Config Validation Report

## Errors (N)
- [path/to/file.conf#L12](path/to/file.conf#L12) — short description

## Warnings (N)
- ...

## Info (N)
- ...

## Verdict
PASS  (or FAIL if any Errors)
```

Always render file references using the [linkified path](path#Lline) format from the project instructions. Do not paraphrase counts — print the literal numbers.

## Out of scope

- Do not run Logstash, `logstash --config.test_and_exit`, or any container.
- Do not validate grok patterns, mutate field semantics, or test against sample events.
- Do not edit files. If the user asks for fixes after the report, treat that as a new task.
