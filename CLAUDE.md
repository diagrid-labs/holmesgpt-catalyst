# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Chainlit chat UI ("Durable SRE Investigator") that runs HolmesGPT as a durable workflow on Diagrid Catalyst via Diagrid's `DaprWorkflowHolmesRunner`. A single investigator service replaces what was previously a fleet of per-domain agents (`MongoDBAgent`, `GrafanaAgent`, `ArgoCDAgent`, `GitHubAgent`). HolmesGPT decides which tools to call; Catalyst makes every LLM call and tool invocation a durable workflow activity. The workflow engine and state stores are managed by Catalyst (cloud), not run in-cluster.

All application code lives in `holmes-app/`. Migration rationale and phase plan: `docs/holmesgpt-migration-tradeoffs.md`.

## Local development

The Holmes venv is **isolated** — always run `uv sync` from inside `holmes-app/`, never the repo root. `holmes-app/pyproject.toml` carries `[tool.uv] override-dependencies` for `fastapi`, `uvicorn`, `cachetools`, `mcp`; these overrides only apply when uv resolves with that file as root. It also depends on `diagrid` as an editable path source at `../../python-ai` — that sibling repo must exist for `uv sync` to succeed.

```bash
cd holmes-app
uv sync
export OPENAI_API_KEY=sk-...
export MODEL=gpt-4o-mini                # optional, default
# Point at your Catalyst project (no local Dapr runtime to install).
# Values from: diagrid appid get holmes-investigator --project <project>
export DAPR_GRPC_ENDPOINT=https://grpc-<project>.<region>.diagrid.io:443
export DAPR_HTTP_ENDPOINT=https://http-<project>.<region>.diagrid.io:443
export DAPR_API_TOKEN=diagrid://...
uv run chainlit run app_holmes.py --port 8000 --host 0.0.0.0
```

Optional local GitHub MCP server (referenced by `holmes_config.yaml`):

```bash
docker run -d --name github-mcp --rm -p 8765:8000 \
  -e GITHUB_PERSONAL_ACCESS_TOKEN=$GITHUB_TOKEN \
  ghcr.io/github/github-mcp-server \
  --read-only --toolsets=actions,pull_requests,repos http --port=8000
```

Other MCP toolsets (YugabyteDB, Pulsar/snmcp, Prometheus) target in-cluster DNS — locally they fail prerequisites and Holmes silently continues without them. To exercise them locally, `kubectl port-forward` and patch the URL in `holmes_config.yaml` before starting Chainlit.

There is no test suite, no linter config, and no build step outside the Docker image. Validation is manual: run Chainlit, ask the starter questions, watch the event-tape steps. The dev server *is* the test harness — for any UI/runtime change, exercise the golden path in the browser before declaring done.

## Architecture

**Single entry point** — `holmes-app/app_holmes.py`:
- Patches `durabletask.client.TaskHubGrpcClient` and `durabletask.worker.TaskHubGrpcWorker` at import time to raise gRPC `max_send/receive_message_length` from the 4 MiB default to 32 MiB (override: `HOLMES_GRPC_MAX_MB`). The Dapr Python SDK doesn't forward `channel_options`, so without this patch multi-iteration investigations hit `RESOURCE_EXHAUSTED` when activity payloads grow. **Don't move this patch below the Dapr/durabletask imports** — it must run before the SDK constructs any channels.
- Instantiates a single `DaprWorkflowHolmesRunner` at module load with `toolset_tags=["core"]`, `enable_all_toolsets_possible=False`. Toolsets must be explicitly enabled in `holmes_config.yaml` *and* carry the `core` tag.
- Streams the runner's event tape (`workflow_started`, `start_tool_calling`, `tool_calling_result`, `ai_answer_end`, `workflow_completed`) into Chainlit `cl.Step` blocks tagged with each event's `seq`.
- Appends `SYSTEM_PROMPT_ADDITIONS` to every investigation — a partial mitigation for the GitHub MCP server's null-param rejection (see "Known upstream issues" below).
- Runs a post-investigation summary via a separate LiteLLM call (`SUMMARY_MODEL`, default `gpt-4o-mini`). Disable with `SUMMARY_ENABLED=false`.
- `/replay <instance_id> <seq>` slash command reads a `start_tool_calling` event off the Catalyst-backed event tape and re-invokes the tool via `runner._registry.tool_executor` — no LLM, no workflow. Use it to re-check what a single tool returns against current state.

**HolmesGPT configuration** — `holmes-app/holmes_config.yaml`:
- Built-in toolsets enabled: `kubernetes/core`, `argocd/core`, `prometheus/metrics`, plus a `bash` allowlist for read-only `argocd app *` (the fallback when `ARGOCD_AUTH_TOKEN` isn't exported locally).
- `mcp_servers`: `github` (in-cluster `http://github-mcp:8000/mcp` with Bearer token from env), `yugabytedb` (with a `Host: localhost` header hack — see below), `snmcp` (StreamNative for Pulsar, SSE transport).
- `custom_skill_paths: [./skills]` — resolved relative to the process CWD, so Chainlit must be started from `holmes-app/`.

**Skills** — `holmes-app/skills/<name>/SKILL.md`. Each is a procedural runbook with a `description` in YAML frontmatter; HolmesGPT lists skills in the system prompt and fetches the matching one via `fetch_skill` when a user question aligns. The `description` is the only signal for matching — symptom terms users will actually type ("p99 latency spike", "CrashLoopBackOff") must appear there verbatim. No registration step; drop a new directory and restart.

**Durability layer** — workflow state, conversation memory, and the per-instance event tape are all persisted to Catalyst managed state stores (`agent-workflow`, `agent-memory`, `agent-registry`, type `state.diagrid` — provisioned in the Catalyst project, not in-cluster). The event tape is append-only; `/replay` and the summarizer both read from it.

**LLM credentials are split intentionally.** HolmesGPT itself uses LiteLLM with env-var credentials (`OPENAI_API_KEY`, `MODEL`). The Catalyst `llm-provider` conversation component is kept for non-investigation flows (e.g. the post-investigation summarizer in `app_holmes.py` is on the LiteLLM path today, but future input guards / embeddings will use `DaprChatClient`). Don't unify these — the split is a deliberate decision recorded in `docs/holmesgpt-migration-tradeoffs.md`.

## Kubernetes deployment

Step-by-step is in the README. Notable non-obvious points:

- **No in-cluster Dapr, no MongoDB.** State stores are Catalyst-managed (`state.diagrid`), provisioned in the project and referenced by name (`agent-workflow`/`agent-memory`/`agent-registry`); the cluster only runs the app + demo services. (The legacy self-hosted path under `k8s/components/` used a MongoDB replica set.)
- `sre-agent-secrets` is a regular K8s Secret (not a Catalyst/Dapr secret reference) — the investigator pod consumes it via `envFrom`. Keys: `DAPR_API_TOKEN` (the App ID's `diagrid://…` Catalyst token), `OPENAI_API_KEY`, optionally `GITHUB_TOKEN`, `ARGOCD_TOKEN`, `ARGOCD_SERVER` (host:port only, **no scheme**), `ARGOCD_OPTS` (must include `--grpc-web --insecure` for self-signed cluster ArgoCD), `YUGABYTEDB_URL`, `YUGABYTEDB_RO_PASSWORD`.
- The YugabyteDB MCP image is **custom-built** — `scripts/build-yugabytedb-mcp.sh` clones upstream and applies a two-line `sed` patch to `src/server.py` to disable FastMCP's DNS-rebinding protection. Without it, every in-cluster call returns `421 Misdirected Request`. The patch is fragile; expect it to break on upstream constructor changes.
- Components are provisioned in the Catalyst project (`diagrid appid create` + `diagrid component list`), **not** applied as in-cluster CRDs. Deploy the app with `kubectl apply -f k8s/agents/holmes-investigator-catalyst.yaml` (own namespace, remote `DAPR_*` endpoints + `DAPR_API_TOKEN`, `LoadBalancer` Service for a public FQDN). The legacy `k8s/components/` + `k8s/agents/holmes-investigator.yaml` are self-hosted-Dapr only.

## Known upstream issues (don't try to "fix" these here)

- **FastMCP DNS-rebinding protection.** Any MCP server built on `mcp.server.fastmcp.FastMCP` with unset `host` only accepts `Host: localhost|127.0.0.1|[::1]`. Cluster-DNS requests get rejected with 421. Fix is server-side (`transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False)`). Holmes-side `Host` header overrides don't work — httpx re-derives `Host` from the URL. We patch yugabytedb-mcp at build time; github-mcp isn't FastMCP-based so it doesn't hit this.
- **GitHub MCP null-param rejection.** `github-mcp-server` v1.0.5 rejects null values for optional string fields with `parameter X is not of type string, is <nil>`. The LLM (even `gpt-4o`) tends to serialize unset optionals as null. `SYSTEM_PROMPT_ADDITIONS` in `app_holmes.py` nudges the model to omit them — **this is a partial mitigation, not a fix**. Real fix is upstream (either Holmes scrubbing nulls or the MCP server accepting them). Until then, GitHub-based investigations in-cluster are flaky.
- **Pulsar 4.x instability on kind.** Latest Pulsar images crashloop under kind's I/O profile (BookKeeper death watcher kills the broker). `k8s/infra/pulsar.yaml` pins `apachepulsar/pulsar:3.3.7`.

## Working in this repo

- Treat the README as authoritative for setup procedures — it is kept current and is more detailed than this file.
- Code changes are concentrated in `holmes-app/`. Manifest/infrastructure changes touch `k8s/`, `docker/`, `scripts/`.
- New skills: drop a directory under `holmes-app/skills/` and restart the runner — no code change required.
- New MCP servers: add an entry under `mcp_servers:` in `holmes_config.yaml`; if it's FastMCP-based and runs in-cluster, plan for the DNS-rebinding patch.
- New toolsets: enable in `holmes_config.yaml` *and* ensure it has the `core` tag, otherwise `enable_all_toolsets_possible=False` will silently filter it out.
