# Architecture Decision Record — holmesgpt-catalyst

## Status
Accepted — initial ADR generated 2026-05-14 from repository state on branch `github-agent` (HEAD c5aac3a).

## Context
This repository is an SRE incident-triage demo built on **Dapr Agents** with a Chainlit front-end. It was split from a previously monolithic SRE app into per-agent services (commit b839a92), each backed by its own MCP server. The platform demonstrates multi-agent orchestration where a top-level `SreAgent` decomposes user requests into delegated tool calls against specialist agents.

Key constraints shaping the design:
- Python 3.11–3.13, managed by `uv` (`uv.lock` checked in).
- Single dependency surface: `chainlit>=2.0.0`, `dapr-agents>=1.0.1`, `pymongo>=4.0.0`, `python-dotenv>=1.2.1` (`pyproject.toml`).
- Target deploy is Kubernetes; manifests live under `k8s/` and are GitOps-managed via ArgoCD (`setup/argocd-apps.yaml`, `setup/grafana-dashboards-app.yaml`).

## Decisions

### 1. Per-agent service topology
Each domain capability is a separate process / container / k8s deployment:
- `app_chat.py` — orchestrator (`SreAgent`) that delegates via `agent_to_tool` to four specialists.
- `app_mongodb.py` — incident-data specialist (queries `sredb.incidents`).
- `app_grafana.py` — observability specialist (alerts / dashboards).
- `app_argocd.py` — deployment-health specialist.
- `app_github.py` — read-only source/CI specialist.

Rationale: isolate failure domains, allow independent scaling, and let each agent own its MCP client connection. Docker images live under `docker/agents/<name>/`; k8s manifests under `k8s/agents/<name>-agent.yaml`.

### 2. MCP servers as the tool layer
Each specialist (except the orchestrator) connects to a dedicated MCP server over streamable HTTP:
- `docker/mcps/{argocd,grafana,mongodb}` + `k8s/mcp-servers/{argocd,github,grafana,mongodb}-mcp.yaml`.
- GitHub uses the official upstream GitHub MCP server (`GITHUB_MCP_URL`, bearer token from `GITHUB_TOKEN`); see `app_github.py:33-40`.

Rationale: decouple tool implementations from agent logic; let new tools be added by deploying an MCP server without changing agent code.

### 3. Cross-agent invocation via Dapr workflow tool calls
The orchestrator wires specialists with `agent_to_tool(name, description, target_app_id=...)` (`app_chat.py:54-75`). Specialist app IDs are environment-driven (`MONGODB_AGENT_APP_ID`, `GRAFANA_AGENT_APP_ID`, `ARGOCD_AGENT_APP_ID`, `GITHUB_AGENT_APP_ID`) and resolve to other Dapr apps in the mesh.

Rationale: leverages Dapr's service-invocation/workflow plane for retries, observability, and decoupling — avoids hard-coding HTTP endpoints between agents.

### 4. State, memory, and registry on Dapr state stores
All agents share three Dapr state-store components (`k8s/components/*.yaml`, `resources/*.yaml`):
- `agent-registry` — team membership / discovery (`team_name="sre-team"`).
- `agent-memory` — conversation memory (orchestrator only; `ConversationDaprStateMemory`).
- `agent-workflow` — durable workflow state for `DurableAgent`.
- `llm-provider` — LLM component referenced by `DaprChatClient(component_name="llm-provider")`.

Rationale: portable across local (`k8s/components/local`) and cloud backends; agents do not bind to a specific DB driver.

### 5. Chainlit as the only human-facing surface
`app_chat.py` is a Chainlit app exposing starters and an `on_message` handler that calls `AgentRunner.run(...)` with a 300 s timeout. The other `app_*.py` services run headless event loops (`await asyncio.Event().wait()`) and are reached only via cross-app workflow invocation.

### 6. Orchestrator runbook is prompt-encoded
The five-step triage sequence (incident → ArgoCD → Grafana → GitHub → summary) is encoded in `SreAgent` instructions (`app_chat.py:42-50`). Step 4 (GitHub) is mandatory even when the user does not mention GitHub.

Rationale: keeps domain logic out of code where it can iterate fast; trades determinism for flexibility. Worth revisiting if reliability of step ordering becomes a problem.

## Consequences

Positive:
- Independent deploy/rollback per capability; new specialists can be added without touching existing ones.
- MCP layer makes tool surface swappable.
- Dapr provides the cross-cutting plumbing (state, invocation, observability) so the app code stays small (~70–140 LOC per agent).

Negative / open risks:
- Prompt-encoded runbook is brittle — a model regression can silently skip GitHub step.
- Five Dapr apps + four MCP servers + state stores is a lot of moving parts for local dev; `k8s/components/local` exists to mitigate but onboarding cost is real.
- `GITHUB_TOKEN` is required in the GitHub agent's environment; secret distribution is out of scope of this repo and must be provided by the cluster operator.
- No automated tests in-tree; correctness relies on manual Chainlit interaction plus Grafana dashboards (`k8s/grafana-dashboards/`).

## References
- Recent commits shaping this design: `b839a92` (split monolith into per-agent services), `c5aac3a` (add GitHubAgent + ArgoCD-synced Grafana dashboards).
- Entry points: `app_chat.py`, `app_argocd.py`, `app_grafana.py`, `app_mongodb.py`, `app_github.py`.
- Deployment: `k8s/agents/`, `k8s/mcp-servers/`, `k8s/components/`, `setup/argocd-apps.yaml`.
