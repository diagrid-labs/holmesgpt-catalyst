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
- Diagrid CLI ([docs.diagrid.io](https://docs.diagrid.io/catalyst/)) + a Diagrid Catalyst account (`diagrid login`)
- `uv` package manager ([docs.astral.sh](https://docs.astral.sh/uv/getting-started/installation/))
- An OpenAI API key (or any LiteLLM-supported provider)

For the Kubernetes deployment path you also need: `kind` (or any cluster), `kubectl`, and `helm ≥ 3`.

## Run locally

```bash
cd holmes-app
uv sync                        # creates a dedicated venv with diagrid[holmesgpt]

export OPENAI_API_KEY=sk-...
export MODEL=gpt-4o-mini        # optional, this is the default

# Point the app at your Catalyst project — no local Dapr runtime to install.
# The Dapr SDK / DaprWorkflowHolmesRunner connect to Catalyst over these.
# Get the values from: diagrid appid get holmes-investigator --project <project>
export DAPR_GRPC_ENDPOINT="https://grpc-<project>.<region>.diagrid.io:443"
export DAPR_HTTP_ENDPOINT="https://http-<project>.<region>.diagrid.io:443"
export DAPR_API_TOKEN="diagrid://..."

uv run chainlit run app_holmes.py --port 8000 --host 0.0.0.0
```

> The App ID + managed components must exist in your Catalyst project first —
> see step 1 of the Kubernetes deploy below (`diagrid appid create …`). The
> same App ID works for local dev and in-cluster. `diagrid dev` is the managed
> alternative if you'd rather scaffold the env wiring automatically.

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

This deploys Holmes alongside the target services it investigates (`api-gateway` and `auth-service` nginx stand-ins managed by ArgoCD). The in-cluster infrastructure (ArgoCD, Grafana/Prometheus, demo data services) runs in your cluster; the **workflow engine, state stores, and Dapr runtime are provided by Diagrid Catalyst** — nothing Dapr is installed in the cluster, and there's no MongoDB to run.

### 1. Create the Catalyst project + App ID

Create (or select) a Catalyst project, then create the `holmes-investigator` App ID. The managed state stores the runner expects (`agent-workflow`, `agent-memory`, `agent-registry`, type `state.diagrid`) live in the project and become `ready` once the App ID connects.

```bash
diagrid login
diagrid project create holmesgpt-sre-agent --wait      # or use an existing project
diagrid appid create holmes-investigator --project holmesgpt-sre-agent --wait

# The App ID's token + the project endpoints are what the app uses to reach
# Catalyst (DAPR_API_TOKEN / DAPR_GRPC_ENDPOINT / DAPR_HTTP_ENDPOINT):
diagrid appid get holmes-investigator --project holmesgpt-sre-agent
```

> Components are managed in the Catalyst project (`diagrid component list`),
> not applied as in-cluster Dapr CRDs. The legacy self-hosted Dapr manifests
> under `k8s/components/` are kept only for a non-Catalyst deployment.

### 2. Bring up a Kubernetes cluster

Any cluster works (the investigator only needs outbound HTTPS to Catalyst + RBAC to read cluster state). The reference deployment runs on AKS.

```bash
kind create cluster      # or use an existing cluster
```

### 3. Deploy ArgoCD (so Holmes has real apps to investigate)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set applicationSet.enabled=true --wait
kubectl wait --for=condition=available deploy/argocd-server -n argocd --timeout=120s
```

### 4. Deploy Grafana + Prometheus (for the Grafana toolset, optional)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace --wait
```

### 4a. Deploy YugabyteDB (for the YugabyteDB MCP toolset, optional)

```bash
helm repo add yugabytedb https://charts.yugabyte.com
helm install yugabyte yugabytedb/yugabyte \
  --set replicas.master=1 --set replicas.tserver=1 \
  --set storage.master.size=1Gi --set storage.tserver.size=1Gi \
  --set resource.master.requests.cpu=0.5,resource.master.requests.memory=1Gi \
  --set resource.tserver.requests.cpu=0.5,resource.tserver.requests.memory=1Gi \
  --wait
```

Set the read-only role's password and the matching connection string in `sre-agent-secrets` (pick any password — make sure both keys carry the same value):

```bash
RO_PW="<pick-one>"
kubectl patch secret sre-agent-secrets --type='merge' -p "$(cat <<EOF
{"stringData": {
  "YUGABYTEDB_RO_PASSWORD": "${RO_PW}",
  "YUGABYTEDB_URL": "host=yb-tserver-0.yb-tservers port=5433 dbname=yugabyte user=holmes_ro password=${RO_PW}"
}}
EOF
)"
```

Then run the seed Job. It creates the `holmes_ro` role, grants SELECT on public, creates `services` + `incidents` demo tables, and inserts sample rows. Idempotent — safe to re-run:

```bash
kubectl apply -f k8s/jobs/yugabytedb-seed.yaml
kubectl wait --for=condition=complete job/yugabytedb-seed --timeout=120s
kubectl logs -l app=yugabytedb-seed --tail=20    # ends with "Seed complete."
```

### 4b. Deploy Apache Pulsar + StreamNative MCP (for the Pulsar toolset, optional)

A minimal single-pod standalone Pulsar is enough for the demo. Not production-grade — no auth, no persistence, no replication. Swap for the apachepulsar/pulsar Helm chart in real environments.

```bash
kubectl apply -f k8s/infra/pulsar.yaml
kubectl wait --for=condition=ready pod -l app=pulsar --timeout=180s
```

Seed some demo topics (`incidents.alerts`, `services.events`, `audit.log`) and a couple of messages:

```bash
kubectl apply -f k8s/jobs/pulsar-seed.yaml
kubectl wait --for=condition=complete job/pulsar-seed --timeout=120s
kubectl logs -l app=pulsar-seed --tail=20    # ends with the topic list
```

The MCP server itself is deployed alongside the others in step 8 (`k8s/mcp-servers/snmcp.yaml`). It runs StreamNative's official image (`streamnative/snmcp:latest`) — no source patches needed, unlike yugabytedb-mcp.

### 5. Deploy target apps + dashboards

```bash
kubectl apply -f setup/argocd-apps.yaml         # api-gateway / auth-service / ... (nginx stand-ins)
kubectl apply -f k8s/grafana-dashboards/         # api-gateway-overview / auth-service-overview ConfigMaps
```

### 6. Create the `sre-agent-secrets` Secret

The investigator's own namespace holds a regular K8s Secret with the Catalyst connection token and the LLM key:

```bash
kubectl create namespace holmes-investigator
kubectl create secret generic sre-agent-secrets -n holmes-investigator \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
  --from-literal=DAPR_API_TOKEN="$(diagrid appid get holmes-investigator \
      --project holmesgpt-sre-agent -o json | jq -r .status.apiToken)"
```

`DAPR_API_TOKEN` is the App ID's Catalyst token (the `diagrid://…` value from step 1) — it's how the pod authenticates to the managed workflow/state APIs. Add the following additional keys when wiring up the matching toolsets in `holmes-app/holmes_config.yaml`:

| Key | Used by | Notes |
| --- | --- | --- |
| `GITHUB_TOKEN` | github-mcp | Read-only PAT, scopes: `actions`, `pull_requests`, `repos` |
| `ARGOCD_TOKEN` | argocd/core | Surfaced as `ARGOCD_AUTH_TOKEN` env via the Holmes manifest |
| `ARGOCD_SERVER` | argocd/core | **host:port only — no `https://` scheme** (the argocd CLI prepends its own; including the scheme produces "too many colons in address") |
| `ARGOCD_OPTS` | argocd/core | Set to `"--grpc-web --insecure"` — required because in-cluster ArgoCD uses a self-signed cert |
| `GRAFANA_API_KEY` | (future grafana toolset) | Service account token from the Grafana UI |
| `YUGABYTEDB_URL` | yugabytedb-mcp | libpq-style connection string; see step 4a |
| `YUGABYTEDB_RO_PASSWORD` | yugabytedb-seed Job | Read by the seed Job to create the `holmes_ro` role; must match the password embedded in `YUGABYTEDB_URL` |

### 7. Build and push the images

```bash
export IMAGE_REPO="<your-docker-username>"
docker build -f docker/agents/holmes-investigator/Dockerfile holmes-app/ \
  -t "$IMAGE_REPO/holmes-investigator:latest"
docker push "$IMAGE_REPO/holmes-investigator:latest"
```

If you're enabling the YugabyteDB MCP toolset, also build the MCP server image (the upstream repo doesn't publish one). The build is scripted because the upstream `src/server.py` needs a two-line patch to disable FastMCP's DNS-rebinding protection — without it, every in-cluster request fails with `421 Misdirected Request`. See [`scripts/build-yugabytedb-mcp.sh`](scripts/build-yugabytedb-mcp.sh) for the patch detail.

For a kind cluster (loads the image directly into the cluster):

```bash
IMAGE_REPO=$IMAGE_REPO KIND_CLUSTER=kind ./scripts/build-yugabytedb-mcp.sh
```

For a registry-backed cluster (pushes to Docker Hub or another registry):

```bash
IMAGE_REPO=$IMAGE_REPO PUSH=1 ./scripts/build-yugabytedb-mcp.sh
```

Once upstream accepts a configurable `transport_security` (or makes the default less restrictive), drop the script and use the unmodified source.

### 8. Deploy the MCP servers and the investigator

No Dapr components are applied to the cluster — they're managed in the Catalyst project (step 1). The investigator reaches Catalyst over `DAPR_GRPC_ENDPOINT` / `DAPR_HTTP_ENDPOINT` / `DAPR_API_TOKEN`. Deploy everything into the `holmes-investigator` namespace so the bare-name MCP Service DNS resolves:

```bash
kubectl apply -n holmes-investigator -f k8s/mcp-servers/github-mcp.yaml   # public ghcr.io image
kubectl apply -n holmes-investigator -f k8s/mcp-servers/snmcp.yaml        # public streamnative/snmcp
IMAGE_REPO=$IMAGE_REPO envsubst < k8s/mcp-servers/yugabytedb-mcp.yaml | kubectl apply -n holmes-investigator -f -

# The Catalyst deployment manifest — set DAPR_*_ENDPOINT to your project's
# gRPC/HTTP URLs (from `diagrid appid get`) and the image to your $IMAGE_REPO first.
kubectl apply -f k8s/agents/holmes-investigator-catalyst.yaml
kubectl rollout status deploy/holmes-investigator -n holmes-investigator --timeout=150s
```

`k8s/agents/holmes-investigator-catalyst.yaml` is the Catalyst variant (own namespace, no Dapr sidecar/annotations, remote endpoints + token, `LoadBalancer` Service for a public FQDN). The legacy self-hosted Dapr manifest (`k8s/agents/holmes-investigator.yaml`, sidecar + MongoDB components) is kept only for non-Catalyst use.

Holmes consumes MCP servers at their in-cluster Service DNS (`http://github-mcp:8000/mcp`, `http://yugabytedb-mcp:8000/mcp`), configured in `holmes-app/holmes_config.yaml`. Skipping an MCP manifest just disables that toolset — Holmes continues without it.

### 9. Use it

```bash
kubectl port-forward svc/holmes-investigator 8000:8000
```

Open <http://localhost:8000>.

## What's where

| Path | Contents |
| --- | --- |
| `holmes-app/app_holmes.py` | Chainlit handler + `DaprWorkflowHolmesRunner` setup |
| `holmes-app/holmes_config.yaml` | HolmesGPT config (toolsets, MCP servers, skill paths, bash allowlist) |
| `holmes-app/skills/` | Per-incident `SKILL.md` runbooks |
| `holmes-app/.chainlit/config.toml` | UI branding + Chainlit features |
| `holmes-app/pyproject.toml` | Holmes venv: pinned `diagrid[holmesgpt]` + uv overrides |
| `k8s/agents/holmes-investigator-catalyst.yaml` | **Catalyst** Deployment + LoadBalancer Service (remote endpoints + token, own namespace) — the one to use |
| `k8s/agents/holmes-investigator.yaml` | Legacy self-hosted Dapr manifest (sidecar + in-cluster components); non-Catalyst only |
| `k8s/mcp-servers/github-mcp.yaml` | GitHub MCP server (upstream image, public) |
| `k8s/mcp-servers/yugabytedb-mcp.yaml` | YugabyteDB MCP server (custom-built image with FastMCP DNS-rebinding patch — see deploy step 7) |
| `k8s/jobs/yugabytedb-seed.yaml` | One-shot Job: creates `holmes_ro`, seeds demo tables, grants SELECT |
| `scripts/build-yugabytedb-mcp.sh` | Clones upstream, applies the FastMCP patch, builds (and optionally pushes or `kind load`s) the image |
| `k8s/infra/pulsar.yaml` | Standalone single-pod Apache Pulsar for the kind demo (admin HTTP on :8080, binary on :6650) |
| `k8s/mcp-servers/snmcp.yaml` | StreamNative MCP server (`streamnative/snmcp:latest`) pointed at the in-cluster Pulsar; SSE transport |
| `k8s/jobs/pulsar-seed.yaml` | One-shot Job: creates demo topics + produces sample messages |
| `k8s/components/` | Legacy self-hosted Dapr state store + LLM provider components; **not used on Catalyst** (managed in the project instead) |
| `k8s/grafana-dashboards/` | api-gateway / auth-service Grafana dashboard ConfigMaps |
| `docker/agents/holmes-investigator/` | Dockerfile for the investigator image |
| `docs/holmesgpt-migration-tradeoffs.md` | Architecture decisions, phase plan, tradeoffs |
| `setup/argocd-apps.yaml` | Target-app ArgoCD Applications (nginx stand-ins) |

## Troubleshooting

- **`uv sync` reports a dependency conflict.** `holmes-app/pyproject.toml` carries `[tool.uv] override-dependencies` for `fastapi`, `uvicorn`, `cachetools`, `mcp`. Make sure you're running `uv sync` from inside `holmes-app/`, not from the repo root. The Holmes venv must stay isolated.
- **The app hangs at startup / `durabletask-worker` can't connect.** It can't reach Catalyst. Check `DAPR_GRPC_ENDPOINT` / `DAPR_HTTP_ENDPOINT` point at your project's URLs (`diagrid appid get …`) and `DAPR_API_TOKEN` is the App ID's `diagrid://…` token. The managed components must be `ready` (`diagrid component list`), which requires the App ID to exist (step 1).
- **Chainlit reports `Too many packets in payload` on UI open.** Stale Socket.IO session. Hard-refresh the browser (Cmd+Shift+R) or delete `holmes-app/.files/` and restart.
- **`fetch_skill` succeeds but `bash` calls hit "Command requires approval".** The command isn't on HolmesGPT's bash allowlist. Add it under `toolsets.bash.config.allow` in `holmes-app/holmes_config.yaml`. The repo already allows the common read-only `argocd app *` commands.
- **HolmesGPT decides nothing matches an incident.** Check that the SKILL.md's `description:` frontmatter explicitly mentions the symptom terms your users will use ("p99 latency spike", "CrashLoopBackOff"). The description is the only signal it has for matching.
- **`argocd/core` toolset fails with `too many colons in address`.** The `ARGOCD_SERVER` value in `sre-agent-secrets` has an `https://` scheme prefix. The argocd CLI wants just `host:port` and prepends its own scheme. Patch the secret to drop the prefix, then bounce the Holmes pod.
- **`argocd/core` toolset fails with `x509: certificate signed by unknown authority`.** In-cluster ArgoCD uses a self-signed cert. Set `ARGOCD_OPTS="--grpc-web --insecure"` in `sre-agent-secrets` so every `argocd` invocation gets those flags automatically.
- **Pulsar pod crashloops with `BookKeeper death watcher`-triggered shutdowns.** The latest Pulsar image (4.x) has stability issues in kind's I/O profile — the embedded BookKeeper sometimes shuts itself down and takes the broker with it. Use `apachepulsar/pulsar:3.3.7` instead (LTS, more forgiving in resource-tight envs). Configured in `k8s/infra/pulsar.yaml`.
- **YugabyteDB MCP returns `421 Misdirected Request` on every call.** FastMCP's DNS-rebinding protection rejects any `Host` header outside `localhost:*`/`127.0.0.1:*`/`[::1]:*`, so cluster-DNS requests get bounced. Holmes-side `Host` header override doesn't help — httpx clobbers it from the URL. The fix is server-side: patch `src/server.py` to pass `transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False)` to `FastMCP(...)`. See deploy step 7 for the `sed` patches.
- **YugabyteDB `summarize_database` returns no info.** Step 4a's `k8s/jobs/yugabytedb-seed.yaml` creates the demo tables — if you skipped it, the `yugabyte` database is empty and Holmes has nothing to summarize. If you're pointing `YUGABYTEDB_URL` at a different database, the `holmes_ro` role needs `GRANT SELECT` re-applied there (schema-level grants don't cross databases).
- **GitHub MCP rejects calls with `parameter X is not of type string, is <nil>`.** The github-mcp-server's parameter validation rejects null values for optional string fields, and the LLM (even `gpt-4o`) tends to serialize optional params as `null` defaults. `app_holmes.py` ships a `SYSTEM_PROMPT_ADDITIONS` block nudging the LLM to omit unset optional params — this **partially mitigates** the problem but doesn't fully solve it. The real fix is upstream (either HolmesGPT scrubbing nulls before MCP forwarding, or the MCP server accepting nulls). See `docs/holmesgpt-migration-tradeoffs.md` for full context.
