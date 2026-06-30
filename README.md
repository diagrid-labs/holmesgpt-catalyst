<!--
Copyright 2026 The Dapr Authors
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Durable SRE Investigator

A Chainlit chat UI that runs [HolmesGPT](https://holmesgpt.dev) as a durable workflow on [Diagrid Catalyst](https://www.diagrid.io/catalyst) via Diagrid's `DaprWorkflowHolmesRunner`. A single investigator service replaces the previous fleet of per-domain agents — HolmesGPT decides which tools to call (Kubernetes, ArgoCD, Grafana, Prometheus, GitHub, YugabyteDB, Pulsar, Bash, …) and Catalyst makes every LLM call and tool invocation a durable workflow activity. Catalyst is a managed service — the workflow engine and state stores live in the Catalyst cloud, not in your cluster.

All application code lives in [`holmes-app/`](./holmes-app/). The migration rationale is documented in [`docs/holmesgpt-migration-tradeoffs.md`](./docs/holmesgpt-migration-tradeoffs.md).

## How it works

- `holmes-app/app_holmes.py` is the Chainlit handler. It instantiates a single `DaprWorkflowHolmesRunner` at startup and streams events from the workflow's event tape into the UI as Chainlit steps.
- `holmes-app/holmes_config.yaml` configures HolmesGPT's toolsets, MCP servers, and custom skill paths.
- `holmes-app/skills/` holds per-incident runbooks as `SKILL.md` files. HolmesGPT matches incoming questions to a skill by description, fetches the body via the `fetch_skill` tool, and follows the workflow it prescribes.
- Workflow state, conversation memory, and the event tape are all persisted via Catalyst managed state stores (`agent-workflow`, `agent-memory`, `agent-registry`, type `state.diagrid`) — provisioned in the Catalyst project, not in-cluster.
- LLM access goes directly through LiteLLM (env-var credentials). The `llm-provider` Catalyst conversation component is retained for non-investigation LLM flows (e.g. the planned post-investigation summary in Phase 5).

## Prerequisites

- Python ≥ 3.11 ([python.org](https://www.python.org/downloads/))
- Docker ([docs.docker.com](https://docs.docker.com/get-docker/))
- A Diagrid Catalyst account [catalyst.diagrid.io/](https://catalyst.r1.diagrid.io/)
- Diagrid CLI ([docs.diagrid.io](https://docs.diagrid.io/catalyst/)) + `diagrid login`
- `uv` package manager ([docs.astral.sh](https://docs.astral.sh/uv/getting-started/installation/))
- An OpenAI API key (or any LiteLLM-supported provider)

For the Kubernetes deployment path you also need: a cluster + `kubectl`, `helm ≥ 3`, `make`, and `jq`.

## Run locally

```bash
cd holmes-app
uv sync                        # creates a dedicated venv with diagrid[holmesgpt]

export OPENAI_API_KEY=sk-...
export MODEL=gpt-4o-mini        # optional, this is the default

# Get these values from: diagrid appid get holmes-investigator --project <project>
export DAPR_GRPC_ENDPOINT="https://grpc-<project>.<region>.diagrid.io:443"
export DAPR_HTTP_ENDPOINT="https://http-<project>.<region>.diagrid.io:443"
export DAPR_API_TOKEN="diagrid://..."

uv run chainlit run app_holmes.py --port 8000 --host 0.0.0.0
```

> The App ID + managed components must exist in your Catalyst project first.
> Run `make bootstrap` (or `diagrid appid create holmes-investigator --project <project>`)
> once — the same App ID works for local dev and in-cluster.

Open <http://localhost:8000>.

### Optional: enable the GitHub toolset

`holmes-app/holmes_config.yaml` is pre-configured to reach a local GitHub MCP server at `http://localhost:8765/mcp`. Start one with:

```bash
export GITHUB_TOKEN=ghp_...     # PAT with repo + workflow read scopes

docker run -d --name github-mcp --rm -p 8765:8000 \
  -e GITHUB_PERSONAL_ACCESS_TOKEN=$GITHUB_TOKEN \
  ghcr.io/github/github-mcp-server \
  --read-only --toolsets=actions,pull_requests,repos http --port=8000
```

If you skip this, the GitHub toolset stays disabled at startup and Holmes uses only its other built-in toolsets.

## Skills

Each `SKILL.md` under `holmes-app/skills/<name>/` is a procedural runbook keyed by `description` in the YAML frontmatter. HolmesGPT lists them in the system prompt and fetches the matching one when a user asks an aligned question. The format is documented in [`holmes-app/.venv/lib/.../holmes/plugins/skills/README.md`](https://github.com/robusta-dev/holmesgpt/tree/master/holmes/plugins/skills) and the authoring template lives in that plugin's `CLAUDE.md`. Two ship in this repo:

| Skill | Triggers on |
| --- | --- |
| `api-gateway-latency-spike` | "api-gateway p99 latency", SLO breaches, HTTP 504s, upstream timeouts |
| `auth-service-crashloopbackoff` | "auth-service crashing", CrashLoopBackOff, OOMKilled, cascading 401 errors |

Add a new skill by creating `holmes-app/skills/<name>/SKILL.md` — Holmes picks it up on next start. No registration required.

## Deploy to Kubernetes

One command brings up the whole demo. Each namespace stands in for a **cluster
boundary** — `holmes` is the agent side; `yugabyte` / `pulsar` / `monitoring` /
`argocd` / `production` are the workload side Holmes investigates. The workflow
engine and state stores are managed by **Diagrid Catalyst**, so nothing additional needs to be installed on the cluster.

**You need:** `kubectl` (pointed at any cluster), `helm ≥ 3`, the Diagrid CLI
(`diagrid login`), and `jq`. The container images are prebuilt on Docker Hub —
nothing to build.

```bash
export OPENAI_API_KEY=sk-...
export GITHUB_TOKEN=ghp_...        # optional — enables the GitHub toolset

make all
```

`make all` runs, in order:

1. **`make bootstrap`** — creates the Catalyst project + `holmes-investigator` App ID and writes the `sre-agent-secrets` Secret into the `holmes` and `yugabyte` namespaces.
2. **`make infra`** — installs ArgoCD, Prometheus/Grafana, and YugabyteDB (upstream charts).
3. **`make yb` / `make pulsar`** — `yugabytedb-mcp` and Pulsar + `snmcp`, each next to the data it fronts.
4. **`make app`** — the investigator + `github-mcp`.
5. **`make targets` / `make dashboards`** — the apps Holmes investigates + Grafana dashboards.
6. **`make argocd-token`** — mints the ArgoCD API token and restarts the app.

Then open it:

```bash
make url    # kubectl port-forward -n holmes svc/holmes-investigator 8000:8000  → http://localhost:8000
```

### Upgrade one piece (without redeploying everything)

Each component is its own Helm release:

```bash
make app                          # just the investigator + github-mcp
make yb                           # just yugabytedb-mcp + seed
make pulsar                       # just Pulsar + snmcp
helm rollback holmes-app 1 -n holmes
```

### Per-cluster settings

Override as `make` variables (or edit the Makefile defaults):

```bash
make all CATALYST_GRPC=… CATALYST_HTTP=… DNS_LABEL=my-holmes \
         IMAGE_REPO=docker.io/you/holmes-investigator
```

`make help` lists every target. Chart layout, MCP placement, swapping clusters,
and building your own images are documented in [`charts/README.md`](charts/README.md).


## What's where

| Path | Contents |
| --- | --- |
| `Makefile` | **The deploy interface** — `make all`, `make app/yb/pulsar`, `make help` |
| `charts/holmes-app/` | Helm chart: investigator + `github-mcp` (the `holmes` namespace) |
| `charts/holmes-yugabyte/` | Helm chart: `yugabytedb-mcp` + seed (the `yugabyte` namespace) |
| `charts/holmes-pulsar/` | Helm chart: Pulsar + `snmcp` + seed (the `pulsar` namespace) |
| `charts/README.md` | Chart layout, MCP placement, per-cluster knobs |
| `deploy/bootstrap.sh` | Non-K8s pre-flight: Catalyst App ID + secrets + ArgoCD token |
| `deploy/values/` | Infra subchart overrides (Yugabyte 10Gi) |
| `holmes-app/app_holmes.py` | Chainlit handler + `DaprWorkflowHolmesRunner` setup |
| `holmes-app/holmes_config.yaml` | Base HolmesGPT config (the chart mounts a templated copy in-cluster) |
| `holmes-app/skills/` | Per-incident `SKILL.md` runbooks |
| `holmes-app/pyproject.toml` | Holmes venv: pinned `diagrid[holmesgpt]` + uv overrides |
| `scripts/build-yugabytedb-mcp.sh` | Builds the `yugabytedb-mcp` image (adds `psycopg[binary]`; pushes / `kind load`s) |
| `docker/agents/holmes-investigator/` | Dockerfile for the investigator image |
| `k8s/`, `setup/argocd-apps.yaml` | Raw manifests the charts/Makefile supersede |
| `docs/holmesgpt-migration-tradeoffs.md` | Architecture decisions, phase plan, tradeoffs |

## Troubleshooting

- **`uv sync` reports a dependency conflict.** `holmes-app/pyproject.toml` carries `[tool.uv] override-dependencies` for `fastapi`, `uvicorn`, `cachetools`, `mcp`. Make sure you're running `uv sync` from inside `holmes-app/`, not from the repo root. The Holmes venv must stay isolated.
- **The app hangs at startup / `durabletask-worker` can't connect.** It can't reach Catalyst. Check `DAPR_GRPC_ENDPOINT` / `DAPR_HTTP_ENDPOINT` point at your project's URLs (`diagrid appid get …`) and `DAPR_API_TOKEN` is the App ID's `diagrid://…` token. The managed components must be `ready` (`diagrid component list`), which requires the App ID to exist (run `make bootstrap`).
- **Chainlit reports `Too many packets in payload` on UI open.** Stale Socket.IO session. Hard-refresh the browser (Cmd+Shift+R) or delete `holmes-app/.files/` and restart.
- **`fetch_skill` succeeds but `bash` calls hit "Command requires approval".** The command isn't on HolmesGPT's bash allowlist. Add it under `toolsets.bash.config.allow` in `holmes-app/holmes_config.yaml`. The repo already allows the common read-only `argocd app *` commands.
- **HolmesGPT decides nothing matches an incident.** Check that the SKILL.md's `description:` frontmatter explicitly mentions the symptom terms your users will use ("p99 latency spike", "CrashLoopBackOff"). The description is the only signal it has for matching.
- **`argocd/core` toolset fails with `too many colons in address`.** `ARGOCD_SERVER` (a `holmes-app` value, default set by `make app`) has an `https://` scheme prefix. It must be `host:port` only — the argocd CLI prepends its own scheme.
- **`argocd/core` toolset fails with `x509: certificate signed by unknown authority`.** In-cluster ArgoCD uses a self-signed cert; the chart sets `ARGOCD_OPTS="--grpc-web --insecure"` (`toolsets.argocd.opts`) to handle it.
- **Pulsar pod crashloops with `BookKeeper death watcher`-triggered shutdowns.** The latest Pulsar image (4.x) is unstable under tight I/O — the `holmes-pulsar` chart pins `apachepulsar/pulsar:3.3.7` (`pulsarImage`).
- **YugabyteDB writes rejected with "insufficient disk space".** YugabyteDB's disk-full guard rejects writes when free space is under ~1GiB, so a 1Gi PVC never works — the chart provisions 10Gi (`deploy/values/yugabyte.yaml`).
- **YugabyteDB `summarize_database` returns no info.** The seed (run by `make yb`) creates the demo tables — if it didn't complete, the `yugabyte` database is empty. If you point `YUGABYTEDB_URL` at a different database, re-apply `GRANT SELECT` for `holmes_ro` there (schema-level grants don't cross databases).
- **GitHub MCP rejects calls with `parameter X is not of type string, is <nil>`.** The github-mcp-server's parameter validation rejects null values for optional string fields, and the LLM (even `gpt-4o`) tends to serialize optional params as `null` defaults. `app_holmes.py` ships a `SYSTEM_PROMPT_ADDITIONS` block nudging the LLM to omit unset optional params — this **partially mitigates** the problem but doesn't fully solve it. The real fix is upstream (either HolmesGPT scrubbing nulls before MCP forwarding, or the MCP server accepting nulls). See `docs/holmesgpt-migration-tradeoffs.md` for full context.
