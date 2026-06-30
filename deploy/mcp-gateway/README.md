# Exposing in-cluster MCP servers to (cloud) Catalyst

Catalyst's MCP gateway connects *out* to each MCP server's URL, so in-cluster
`ClusterIP` MCP servers (`yugabytedb-mcp`, `snmcp`) must be reachable. This sets
up a TLS ingress with basic-auth and registers them as Catalyst MCP servers.
(`github` needs none of this — it's registered from the catalog against GitHub's
hosted MCP; see below.)

Single ingress host (one Azure cloudapp label per IP), path-routed:
- `https://<host>/mcp`            → yugabytedb-mcp (streamable-http)
- `https://<host>/snmcp/mcp/sse`  → snmcp (SSE)

snmcp is configured to serve at `--http-path=/snmcp/mcp` (chart value
`snmcpHttpPath`) so its SSE `endpoint` event stays under `/snmcp` and routes back
through the same ingress without path rewriting (rewriting breaks SSE).

## 1. Ingress controller + cert-manager

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=holmes-mcp-demo \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --wait
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true --wait
```

> **Gotcha:** without `…health-probe-request-path=/healthz`, Azure health-probes
> the LB at `/` which nginx answers `404` → the LB marks the backend unhealthy
> and silently drops ALL traffic (connection timeouts, including the ACME
> HTTP-01 challenge). This annotation is mandatory on AKS.

## 2. Issuer + basic-auth + ingresses

```bash
kubectl apply -f deploy/mcp-gateway/clusterissuer.yaml

# basic-auth credential (bcrypt) in each MCP namespace
PASS="cat_$(openssl rand -hex 12)"
HT=$(kubectl run htpw --rm -i --restart=Never --image=httpd:alpine --command -- \
       htpasswd -nbB catalyst "$PASS" | grep '^catalyst:')
for ns in yugabyte pulsar; do
  kubectl create secret generic mcp-basic-auth -n $ns --from-literal=auth="$HT" \
    --dry-run=client -o yaml | kubectl apply -f -
done

kubectl apply -f deploy/mcp-gateway/ingress-yugabytedb.yaml \
              -f deploy/mcp-gateway/ingress-snmcp.yaml
# wait for the cert: kubectl get cert mcp-tls -n yugabyte
```

## 3. Register in Catalyst

```bash
HOST=holmes-mcp-demo.westeurope.cloudapp.azure.com
B64=$(printf 'catalyst:%s' "$PASS" | base64)

# github — hosted, from the catalog (no ingress needed):
diagrid mcpserver create github --project holmesgpt-sre-agent \
  --from-catalog github-mcpserver --auth-profile bearer-header \
  --header "Authorization:Bearer <github-PAT>" --scope holmes-investigator

diagrid mcpserver create yugabytedb --project holmesgpt-sre-agent \
  --url "https://$HOST/mcp" --transport streamable-http \
  --header "Authorization:Basic $B64" --scope holmes-investigator

diagrid mcpserver create snmcp --project holmesgpt-sre-agent \
  --url "https://$HOST/snmcp/mcp/sse" --transport sse \
  --header "Authorization:Basic $B64" --scope holmes-investigator
```

## Notes

- These registrations make the MCP servers **Catalyst-managed** (catalog, scopes,
  per-tool access). The current `DaprWorkflowHolmesRunner` still calls MCP servers
  via `holmes_config.yaml`'s in-cluster URLs — registering here does not (yet)
  reroute Holmes through Catalyst.
- Requires a **cloud** Catalyst region (the self-hosted region's control plane
  can't reach a public ingress). This project is in `diagrid-aws-eu-west`.
- Harden further by adding `nginx.ingress.kubernetes.io/whitelist-source-range`
  with Catalyst's egress CIDR once known.
