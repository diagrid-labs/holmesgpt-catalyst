# SRE Investigator — charts + Makefile (multi-namespace)

Each **namespace stands in for a cluster boundary**: `holmes` is the SRE/agent
side; everything else is the observed "workload" side that Holmes investigates.

```
holmes      holmes-app chart  → investigator + github-mcp (external-SaaS connector)
yugabyte    holmes-yugabyte   → yugabytedb-mcp + seed   (next to the DB it fronts)
pulsar      holmes-pulsar     → Pulsar + snmcp + seed   (next to the broker it fronts)
monitoring  kube-prometheus-stack   (upstream chart, via make)
argocd      ArgoCD                  (upstream chart, via make)
production  api-gateway / auth-service target apps (ArgoCD Applications)
```

MCP placement follows ownership: `github-mcp` is an external connector so it
lives with Holmes; `yugabytedb-mcp` / `snmcp` are "service offerings" that sit
next to the services they expose. Holmes reaches the cross-namespace ones by
FQDN (`yugabytedb-mcp.yugabyte.svc…`, `snmcp.pulsar.svc…`) — the same way it'd
reach another cluster.

## Deploy — the Makefile is the interface (repo root)

```bash
export OPENAI_API_KEY=sk-...  GITHUB_TOKEN=ghp_...   # GITHUB_TOKEN optional
make all          # bootstrap → infra → yb → pulsar → app → targets → dashboards → argocd-token
```

Each component is its own Helm release, so you upgrade/roll back one at a time:

```bash
make app                                   # just the investigator + github-mcp
make yb                                    # just yugabytedb-mcp + seed
make pulsar                                # just Pulsar + snmcp
helm rollback holmes-app 1 -n holmes       # roll back only the app
```

`make help` lists everything. Per-cluster knobs are make variables:
`CATALYST_GRPC/HTTP`, `DNS_LABEL`, `IMAGE_REPO/TAG`, and the `NS_*` namespaces.
In-cluster service URLs (Prometheus / ArgoCD / MCP) live as defaults in
`charts/holmes-app/values.yaml` — override there if you rename a namespace.

### Deploy without Helm (raw YAML)

There's no hand-maintained plain manifest — generate one from the chart (the
single source of truth) when you need it:

```bash
helm template holmes-app charts/holmes-app -n holmes \
  --set catalyst.grpcEndpoint=<grpc-url> --set catalyst.httpEndpoint=<http-url> \
  > holmes-app.yaml
kubectl apply -n holmes -f holmes-app.yaml   # secret must already exist (see pre-flight)
```

## Pre-flight (`deploy/bootstrap.sh`, wrapped by `make bootstrap` / `make argocd-token`)

The non-K8s bits: creates the Catalyst App ID, the `sre-agent-secrets` Secret in
**both** the `holmes` and `yugabyte` namespaces (each with the keys that side
needs), and — after ArgoCD is up — mints the ArgoCD API token into the holmes
secret and restarts the app.

## Baked-in lessons

- **Yugabyte 10Gi** (`deploy/values/yugabyte.yaml`) — YB's disk-full guard rejects
  writes under ~1GiB free.
- **Control-pool pinning** — pin workloads to a specific node pool via `make … NODE_POOL=<pool>`.
- `holmes_config.yaml` is mounted from a templated ConfigMap; toolset/MCP URLs
  are values (FQDNs across the namespace boundary).
- The `yugabytedb-mcp` image is custom-built — see `scripts/build-yugabytedb-mcp.sh`.
