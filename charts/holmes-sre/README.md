# holmes-sre Helm chart

Umbrella chart for the **Durable SRE Investigator** (HolmesGPT on Diagrid
Catalyst) and its demo stack. One `helm install` brings up the investigator,
its MCP servers (GitHub, YugabyteDB, Pulsar/snmcp), the demo data services, the
ArgoCD target apps, and — as optional subcharts — ArgoCD, kube-prometheus-stack,
and YugabyteDB.

> **Single namespace.** A Helm umbrella installs every subchart into the release
> namespace, so the whole demo lives in one namespace (default `holmes-sre`).
> `holmes_config.yaml` is mounted from a templated ConfigMap so the Prometheus /
> ArgoCD service URLs track that namespace.

## What Helm can't do (the pre-flight)

Catalyst App ID creation, the `sre-agent-secrets` Secret, and the ArgoCD API
token aren't Kubernetes resources — `bootstrap.sh` handles them.

## Deploy (≈ 3 commands)

```bash
# 1. Pre-flight: Catalyst App ID + namespace + secret
export OPENAI_API_KEY=sk-...
export GITHUB_TOKEN=ghp_...           # optional, enables the github toolset
./charts/holmes-sre/bootstrap.sh pre  # prints the catalyst.* endpoints to use

# 2. Install (pass the endpoints the bootstrap printed)
helm dependency update charts/holmes-sre
helm install holmes charts/holmes-sre -n holmes-sre --create-namespace \
  --set catalyst.grpcEndpoint=<grpc-url> --set catalyst.httpEndpoint=<http-url>

# 3. Once ArgoCD is up, mint + wire its token
RELEASE=holmes NAMESPACE=holmes-sre ./charts/holmes-sre/bootstrap.sh argocd-token
```

The investigator's public URL comes from the LoadBalancer Service + Azure DNS
label (`investigator.service.dnsLabel`).

## Swapping clusters

Only a handful of values change per cluster — keep them in a `values-<cluster>.yaml`:

| Value | What it controls |
| --- | --- |
| `catalyst.grpcEndpoint` / `httpEndpoint` | the Catalyst project the app connects to |
| `nodeSelector` | node-pool pinning (default `agentpool: control`) |
| `investigator.service.dnsLabel` | the public cloudapp FQDN (Azure) |
| `investigator.image.repo` / `tag` | where the image is pulled from |
| `mcp.*.enabled`, `toolsets.*.enabled` | which toolsets/MCP servers to deploy |
| `argo-cd.enabled` / `kube-prometheus-stack.enabled` / `yugabyte.enabled` | skip infra you already run |

## Notes baked in from the reference deployment

- **Yugabyte storage is 10Gi** (`yugabyte.storage.*`) — YB's disk-full guard
  rejects writes under ~1GiB free, so don't go lower.
- Everything is pinned to the `control` pool (`nodeSelector`) because the
  `agents` pool is used by a separate AZ-failure chaos demo.
- The `yugabytedb-mcp` image is custom-built — see `scripts/build-yugabytedb-mcp.sh`.
