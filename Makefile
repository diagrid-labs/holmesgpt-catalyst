# Durable SRE Investigator — Kubernetes deploy orchestration.
#
# Each component is its own Helm release, so `make app` / `make yb` / `make pulsar`
# upgrade ONE thing independently; `make all` does a full bring-up. In-cluster
# service URLs (Prometheus / ArgoCD / MCP) are chart defaults in
# charts/holmes-app/values.yaml — the Makefile only sets what varies per deploy.
# Override any var inline, e.g.  make app IMAGE_TAG=v2  |  make all NODE_POOL=control

# ── namespaces ───────────────────────────────────────────────────────────────
NS_HOLMES ?= holmes
NS_YB     ?= yugabyte
NS_PULSAR ?= pulsar
NS_MON    ?= monitoring
NS_ARGOCD ?= argocd

# ── per-deploy config ────────────────────────────────────────────────────────
PROJECT    ?= holmesgpt-sre-agent
APPID      ?= holmes-investigator
IMAGE_REPO ?= docker.io/tezizzm/holmes-investigator
IMAGE_TAG  ?= latest
DNS_LABEL  ?= demo-holmes-investigator
NODE_POOL  ?=            # empty = schedule anywhere; e.g. NODE_POOL=control to pin
BOOTSTRAP  := deploy/bootstrap.sh

# Catalyst endpoints are derived from the project at deploy time (not hardcoded).
# Override for CI: make app CATALYST_GRPC=… CATALYST_HTTP=…
CATALYST_GRPC ?= $(shell diagrid project get $(PROJECT) -o json 2>/dev/null | jq -r '.status.endpoints.grpc.url // empty')
CATALYST_HTTP ?= $(shell diagrid project get $(PROJECT) -o json 2>/dev/null | jq -r '.status.endpoints.http.url // empty')

NODE_SEL := $(if $(NODE_POOL),--set nodeSelector.agentpool=$(NODE_POOL),)

.DEFAULT_GOAL := help
.PHONY: help repos bootstrap infra app yb pulsar targets dashboards argocd-token all url uninstall ingress-infra mcp-gateway

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

repos: ## Add/update upstream Helm repos
	@helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
	@helm repo add yugabytedb https://charts.yugabyte.com >/dev/null 2>&1 || true
	@helm repo update >/dev/null

bootstrap: ## Pre-flight: Catalyst App ID + namespaces + secrets (needs OPENAI_API_KEY)
	NS_HOLMES=$(NS_HOLMES) NS_YB=$(NS_YB) NS_ARGOCD=$(NS_ARGOCD) PROJECT=$(PROJECT) APPID=$(APPID) $(BOOTSTRAP) pre

infra: repos ## Install/upgrade ArgoCD, Prometheus, YugabyteDB (each in its namespace)
	helm upgrade --install argocd argo/argo-cd -n $(NS_ARGOCD) --create-namespace -f deploy/values/argocd.yaml --wait
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n $(NS_MON) --create-namespace -f deploy/values/monitoring.yaml --wait
	helm upgrade --install yugabyte yugabytedb/yugabyte -n $(NS_YB) --create-namespace -f deploy/values/yugabyte.yaml --wait

app: ## Upgrade ONLY the investigator + github-mcp (holmes ns)
	@test -n "$(CATALYST_GRPC)" || { echo "ERROR: CATALYST_GRPC empty — run 'diagrid login' (project $(PROJECT)) or pass CATALYST_GRPC=… CATALYST_HTTP=…"; exit 1; }
	helm upgrade --install holmes-app charts/holmes-app -n $(NS_HOLMES) --create-namespace \
	  --set investigator.image.repo=$(IMAGE_REPO) --set investigator.image.tag=$(IMAGE_TAG) \
	  --set investigator.service.dnsLabel=$(DNS_LABEL) \
	  --set catalyst.grpcEndpoint=$(CATALYST_GRPC) --set catalyst.httpEndpoint=$(CATALYST_HTTP) $(NODE_SEL)

yb: ## Upgrade ONLY yugabytedb-mcp + seed (yugabyte ns)
	helm upgrade --install holmes-yugabyte charts/holmes-yugabyte -n $(NS_YB) --create-namespace $(NODE_SEL)

pulsar: ## Upgrade ONLY Pulsar + snmcp + seed (pulsar ns)
	helm upgrade --install holmes-pulsar charts/holmes-pulsar -n $(NS_PULSAR) --create-namespace $(NODE_SEL)

targets: ## Deploy the ArgoCD target apps (api-gateway / auth-service / checkout-api)
	kubectl apply -f setup/argocd-apps.yaml

dashboards: ## Deploy the Grafana dashboards (monitoring ns)
	kubectl apply -f k8s/grafana-dashboards/

argocd-token: ## Mint the ArgoCD API token into the holmes secret + restart the app
	NS_HOLMES=$(NS_HOLMES) NS_ARGOCD=$(NS_ARGOCD) $(BOOTSTRAP) argocd-token

all: bootstrap infra yb pulsar app targets dashboards argocd-token ## Full bring-up

url: ## Print the investigator's LoadBalancer endpoint
	@kubectl get svc holmes-investigator -n $(NS_HOLMES) -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}' 2>/dev/null || echo "(not ready)"

uninstall: ## Remove the Holmes releases (keeps infra + namespaces)
	-helm uninstall holmes-app -n $(NS_HOLMES)
	-helm uninstall holmes-yugabyte -n $(NS_YB)
	-helm uninstall holmes-pulsar -n $(NS_PULSAR)

# ── Catalyst MCP-gateway exposure (optional; cloud region only) ───────────────
MCP_DNS_LABEL ?= holmes-mcp-demo

ingress-infra: ## Install ingress-nginx (+health-probe fix) + cert-manager for MCP exposure
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
	helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
	helm repo update >/dev/null
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
	  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$(MCP_DNS_LABEL) \
	  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
	  --wait
	helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true --wait

mcp-gateway: ## Apply ClusterIssuer + MCP ingresses (needs mcp-basic-auth secrets — see deploy/mcp-gateway/README.md)
	kubectl apply -f deploy/mcp-gateway/clusterissuer.yaml
	kubectl apply -f deploy/mcp-gateway/ingress-yugabytedb.yaml -f deploy/mcp-gateway/ingress-snmcp.yaml
