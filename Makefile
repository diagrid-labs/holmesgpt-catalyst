# Durable SRE Investigator — multi-namespace deploy orchestration.
#
# Each namespace stands in for a cluster boundary: `holmes` is the SRE/agent
# side; the rest is the observed "workload" side. Each component is its own
# Helm release, so `make app` / `make yb` / `make pulsar` upgrade ONE thing
# independently; `make all` does a full bring-up. Override any var inline,
# e.g.  make app CATALYST_GRPC=… DNS_LABEL=… IMAGE_REPO=…

# ── namespaces (≈ clusters) ──────────────────────────────────────────────────
NS_HOLMES   ?= holmes
NS_YB       ?= yugabyte
NS_PULSAR   ?= pulsar
NS_MON      ?= monitoring
NS_ARGOCD   ?= argocd
NS_PROD     ?= production

# ── per-deploy config ────────────────────────────────────────────────────────
PROJECT       ?= holmesgpt-sre-agent
APPID         ?= holmes-investigator
CATALYST_GRPC ?= https://grpc-prj6342098.3jsqkq3nmjg2jxixwk5z3dbjrszhrhvg.r1.privatediagrid.net:443
CATALYST_HTTP ?= https://http-prj6342098.3jsqkq3nmjg2jxixwk5z3dbjrszhrhvg.r1.privatediagrid.net:443
DNS_LABEL     ?= demo-holmes-investigator
IMAGE_REPO    ?= docker.io/tezizzm/holmes-investigator
IMAGE_TAG     ?= latest
BOOTSTRAP     := deploy/bootstrap.sh

# Cross-boundary endpoints derived from the namespace vars (kept consistent if
# you change a namespace).
PROM_URL  := http://kube-prometheus-stack-prometheus.$(NS_MON).svc.cluster.local:9090
ARGO_SVR  := argocd-server.$(NS_ARGOCD).svc.cluster.local:443
YB_MCP    := http://yugabytedb-mcp.$(NS_YB).svc.cluster.local:8000/mcp
SN_MCP    := http://snmcp.$(NS_PULSAR).svc.cluster.local:9090/mcp

.DEFAULT_GOAL := help
.PHONY: help repos bootstrap infra app yb pulsar targets dashboards argocd-token all url uninstall

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
	helm upgrade --install holmes-app charts/holmes-app -n $(NS_HOLMES) --create-namespace \
	  --set investigator.image.repo=$(IMAGE_REPO) --set investigator.image.tag=$(IMAGE_TAG) \
	  --set investigator.service.dnsLabel=$(DNS_LABEL) \
	  --set catalyst.grpcEndpoint=$(CATALYST_GRPC) --set catalyst.httpEndpoint=$(CATALYST_HTTP) \
	  --set toolsets.prometheus.url=$(PROM_URL) --set toolsets.argocd.server=$(ARGO_SVR) \
	  --set mcp.yugabytedb.url=$(YB_MCP) --set mcp.pulsar.url=$(SN_MCP)

yb: ## Upgrade ONLY yugabytedb-mcp + seed (yugabyte ns)
	helm upgrade --install holmes-yugabyte charts/holmes-yugabyte -n $(NS_YB) --create-namespace

pulsar: ## Upgrade ONLY Pulsar + snmcp + seed (pulsar ns)
	helm upgrade --install holmes-pulsar charts/holmes-pulsar -n $(NS_PULSAR) --create-namespace

targets: ## Deploy the ArgoCD target apps (api-gateway / auth-service)
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
