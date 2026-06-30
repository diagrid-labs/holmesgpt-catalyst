# SRE Investigator — Helm charts + Makefile

Three charts plus a `Makefile` (at the repo root) that drives them.

```
charts/holmes-app/   investigator + config + RBAC + service + target apps + dashboards   (one release)
charts/holmes-mcp/   github / yugabytedb / snmcp MCP servers + Pulsar + seed jobs         (one release)
charts/holmes-sre/   umbrella: file:// deps on the two above + ArgoCD/Prometheus/Yugabyte (one release, greenfield)
```

Everything installs into **one namespace** (default `holmes-sre`) so bare-name
service DNS resolves. The non-K8s pre-flight (Catalyst App ID, the
`sre-agent-secrets` Secret, the ArgoCD token) is in `charts/holmes-sre/bootstrap.sh`,
wrapped by the Makefile.

## Two deployment modes

**Per-release (default — debugging-friendly).** Each component is its own Helm
release, so you can upgrade/rollback one without touching the rest:

```bash
export OPENAI_API_KEY=sk-...   GITHUB_TOKEN=ghp_...   # GITHUB_TOKEN optional
make all                        # bootstrap → infra → app → mcp → argocd-token

make app                        # later: upgrade ONLY the investigator
make mcp                        # or ONLY the MCP servers/Pulsar
helm rollback holmes-app 1 -n holmes-sre   # roll back just the app
```

**Umbrella (greenfield — one release).** Whole demo in a single `helm install`,
but no per-component upgrade/rollback:

```bash
make bootstrap && make umbrella
```

`make help` lists every target. Override knobs inline, e.g.
`make app NS=holmes CATALYST_GRPC=… DNS_LABEL=… IMAGE_REPO=…`.

## Swapping clusters

Per cluster, only a few values change — pass them to `make` (or edit the Makefile
defaults / `deploy/values/*.yaml`):

| Knob | Make variable / file |
| --- | --- |
| Catalyst project endpoints | `CATALYST_GRPC`, `CATALYST_HTTP` |
| Public DNS label (Azure) | `DNS_LABEL` |
| Image | `IMAGE_REPO`, `IMAGE_TAG` |
| Namespace | `NS` |
| Node pinning / infra sizing | `deploy/values/{argocd,monitoring,yugabyte}.yaml` |
| Toolset / MCP toggles | `--set` on `make app` / `make mcp`, or chart `values.yaml` |

## Baked-in lessons

- **Yugabyte storage 10Gi** — YB's disk-full guard rejects writes under ~1GiB free.
- **Control-pool pinning** everywhere (`nodeSelector: {agentpool: control}`) — the
  `agents` pool is used by a separate AZ-failure chaos demo.
- `holmes_config.yaml` is mounted from a templated ConfigMap so Prometheus/ArgoCD
  URLs track the namespace; per-release mode points them at the in-namespace
  service names (set by the Makefile).
- The `yugabytedb-mcp` image is custom-built — see `scripts/build-yugabytedb-mcp.sh`.
