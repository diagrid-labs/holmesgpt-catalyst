# Durable SRE Investigator — deploy orchestration.
#
# Two modes:
#   • per-release (default): `make all` brings everything up; `make app` /
#     `make mcp` / `make infra` upgrade ONE component independently. This is
#     the debugging-friendly path (separate Helm releases, per-component rollback).
#   • umbrella: `make umbrella` installs the whole demo as a single release
#     (greenfield convenience; no per-component upgrade).
#
# Everything lands in one namespace ($(NS)) so bare-name service DNS resolves.
# Override any variable on the command line, e.g.  make app NS=holmes CATALYST_GRPC=...

NS              ?= holmes-sre
PROJECT         ?= holmesgpt-sre-agent
APPID           ?= holmes-investigator
CATALYST_GRPC   ?= https://grpc-prj6342098.3jsqkq3nmjg2jxixwk5z3dbjrszhrhvg.r1.privatediagrid.net:443
CATALYST_HTTP   ?= https://http-prj6342098.3jsqkq3nmjg2jxixwk5z3dbjrszhrhvg.r1.privatediagrid.net:443
DNS_LABEL       ?= demo-holmes-investigator
IMAGE_REPO      ?= docker.io/tezizzm/holmes-investigator
IMAGE_TAG       ?= latest
BOOTSTRAP       := charts/holmes-sre/bootstrap.sh

# In-namespace service URLs (infra releases are named after their charts).
PROM_URL        := http://kube-prometheus-stack-prometheus.$(NS).svc.cluster.local:9090
ARGOCD_SERVER   := argocd-server.$(NS).svc.cluster.local:443

.DEFAULT_GOAL := help
.PHONY: help repos bootstrap infra app mcp argocd-token all umbrella url uninstall

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

repos: ## Add/update the upstream Helm repos
	helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
	helm repo add yugabytedb https://charts.yugabyte.com >/dev/null 2>&1 || true
	helm repo update >/dev/null

bootstrap: ## Pre-flight: Catalyst App ID + namespace + secret (needs OPENAI_API_KEY)
	PROJECT=$(PROJECT) APPID=$(APPID) NAMESPACE=$(NS) RELEASE=$(APPID) $(BOOTSTRAP) pre

infra: repos ## Install/upgrade ArgoCD + Prometheus + YugabyteDB (into $(NS))
	helm upgrade --install argocd argo/argo-cd -n $(NS) --create-namespace -f deploy/values/argocd.yaml --wait
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n $(NS) --create-namespace -f deploy/values/monitoring.yaml --wait
	helm upgrade --install yugabyte yugabytedb/yugabyte -n $(NS) --create-namespace -f deploy/values/yugabyte.yaml --wait

app: ## Install/upgrade the investigator app only
	helm upgrade --install holmes-app charts/holmes-app -n $(NS) --create-namespace \
	  --set investigator.image.repo=$(IMAGE_REPO) --set investigator.image.tag=$(IMAGE_TAG) \
	  --set investigator.service.dnsLabel=$(DNS_LABEL) \
	  --set catalyst.grpcEndpoint=$(CATALYST_GRPC) --set catalyst.httpEndpoint=$(CATALYST_HTTP) \
	  --set toolsets.prometheus.url=$(PROM_URL) --set toolsets.argocd.server=$(ARGOCD_SERVER)

mcp: ## Install/upgrade the MCP servers + Pulsar + seeds only
	helm upgrade --install holmes-mcp charts/holmes-mcp -n $(NS) --create-namespace

argocd-token: ## Mint the ArgoCD API token into the secret + restart the app
	NAMESPACE=$(NS) RELEASE=$(APPID) ARGOCD_SVC=argocd-server $(BOOTSTRAP) argocd-token

all: bootstrap infra app mcp argocd-token ## Full bring-up (per-release)

umbrella: repos ## Greenfield: install the whole demo as ONE release
	helm dependency update charts/holmes-sre
	helm upgrade --install holmes charts/holmes-sre -n $(NS) --create-namespace \
	  --set holmes-app.catalyst.grpcEndpoint=$(CATALYST_GRPC) \
	  --set holmes-app.catalyst.httpEndpoint=$(CATALYST_HTTP) \
	  --set holmes-app.investigator.service.dnsLabel=$(DNS_LABEL)

url: ## Print the investigator's LoadBalancer endpoint
	@kubectl get svc holmes-investigator -n $(NS) -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}' 2>/dev/null || echo "(service not ready)"

uninstall: ## Remove the per-release installs (keeps the namespace)
	-helm uninstall holmes-app holmes-mcp -n $(NS)
	-helm uninstall argocd kube-prometheus-stack yugabyte -n $(NS)
