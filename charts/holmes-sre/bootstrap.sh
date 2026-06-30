#!/usr/bin/env bash
# Pre-flight for the holmes-sre umbrella chart — the bits Helm can't do:
# create the Catalyst App ID, build the sre-agent-secrets Secret, and (after
# install) mint the ArgoCD API token.
#
# Phases:
#   ./bootstrap.sh pre            # Catalyst App ID + namespace + secret  (run BEFORE helm install)
#   ./bootstrap.sh argocd-token   # ArgoCD token -> secret + restart      (run AFTER helm install, once ArgoCD is up)
#
# Required env:
#   OPENAI_API_KEY      LLM key for HolmesGPT (LiteLLM)
# Optional env:
#   PROJECT             Catalyst project    (default: holmesgpt-sre-agent)
#   APPID               Catalyst App ID     (default: holmes-investigator)
#   NAMESPACE           release namespace   (default: holmes-sre)
#   SECRET              secret name         (default: sre-agent-secrets)
#   RELEASE             helm release name   (default: holmes) — used for argocd svc DNS
#   GITHUB_TOKEN        enables the github toolset
set -euo pipefail

PROJECT="${PROJECT:-holmesgpt-sre-agent}"
APPID="${APPID:-holmes-investigator}"
NAMESPACE="${NAMESPACE:-holmes-sre}"
SECRET="${SECRET:-sre-agent-secrets}"
RELEASE="${RELEASE:-holmes}"
PHASE="${1:-pre}"

pre() {
  : "${OPENAI_API_KEY:?OPENAI_API_KEY is required}"
  echo ">> Ensuring Catalyst project + App ID ($PROJECT / $APPID)"
  diagrid project get "$PROJECT" >/dev/null 2>&1 || diagrid project create "$PROJECT" --wait
  diagrid appid get "$APPID" --project "$PROJECT" >/dev/null 2>&1 || diagrid appid create "$APPID" --project "$PROJECT" --wait

  TOKEN=$(diagrid appid get "$APPID" --project "$PROJECT" -o json | jq -r .status.apiToken)
  GRPC=$(diagrid project get "$PROJECT" -o json | jq -r '.status.endpoints.grpc.url // .spec.endpoints.grpc.url')
  HTTP=$(diagrid project get "$PROJECT" -o json | jq -r '.status.endpoints.http.url // .spec.endpoints.http.url')

  echo ">> Creating namespace + secret ($SECRET in $NAMESPACE)"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  RO_PW="holmesro_$(openssl rand -hex 8)"
  YB_URL="host=yb-tserver-0.yb-tservers.${NAMESPACE}.svc.cluster.local port=5433 dbname=yugabyte user=holmes_ro password=${RO_PW}"
  kubectl create secret generic "$SECRET" -n "$NAMESPACE" \
    --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
    --from-literal=DAPR_API_TOKEN="$TOKEN" \
    --from-literal=YUGABYTEDB_RO_PASSWORD="$RO_PW" \
    --from-literal=YUGABYTEDB_URL="$YB_URL" \
    ${GITHUB_TOKEN:+--from-literal=GITHUB_TOKEN="$GITHUB_TOKEN"} \
    --dry-run=client -o yaml | kubectl apply -f -

  cat <<EOF

>> Done. Use these in your helm values (or --set):
   catalyst.grpcEndpoint=${GRPC}
   catalyst.httpEndpoint=${HTTP}

   helm dependency update charts/holmes-sre
   helm install ${RELEASE} charts/holmes-sre -n ${NAMESPACE} \\
     --set catalyst.grpcEndpoint=${GRPC} --set catalyst.httpEndpoint=${HTTP}

   Then once ArgoCD is up:  RELEASE=${RELEASE} NAMESPACE=${NAMESPACE} ./bootstrap.sh argocd-token
EOF
}

argocd_token() {
  # Service/configmap names differ by install mode: per-release (Makefile) =
  # "argocd-server"/"argocd-cm"; umbrella subchart = "<release>-argocd-server".
  ARGOCD_SVC="${ARGOCD_SVC:-${RELEASE}-argocd-server}"
  ARGOCD_CM="${ARGOCD_CM:-${ARGOCD_SVC%-server}-cm}"
  echo ">> Waiting for ArgoCD server ($ARGOCD_SVC in $NAMESPACE)"
  kubectl -n "$NAMESPACE" rollout status deploy/"$ARGOCD_SVC" --timeout=180s
  kubectl -n "$NAMESPACE" patch configmap "$ARGOCD_CM" --type merge -p '{"data":{"accounts.admin":"apiKey,login"}}'
  kubectl -n "$NAMESPACE" rollout restart deploy/"$ARGOCD_SVC"
  kubectl -n "$NAMESPACE" rollout status deploy/"$ARGOCD_SVC" --timeout=120s

  PW=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  kubectl -n "$NAMESPACE" port-forward svc/"$ARGOCD_SVC" 18080:443 >/tmp/pf-argocd.log 2>&1 &
  PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
  for i in $(seq 1 20); do curl -sk https://localhost:18080/healthz >/dev/null 2>&1 && break; sleep 1; done
  SESSION=$(curl -sk -H 'Content-Type: application/json' https://localhost:18080/api/v1/session \
    -d "{\"username\":\"admin\",\"password\":\"${PW}\"}" | jq -r .token)
  TOKEN=$(curl -sk -H 'Content-Type: application/json' -H "Authorization: Bearer ${SESSION}" \
    https://localhost:18080/api/v1/account/admin/token -d '{}' | jq -r .token)

  kubectl -n "$NAMESPACE" patch secret "$SECRET" --type merge \
    -p "{\"stringData\":{\"ARGOCD_TOKEN\":\"${TOKEN}\"}}"
  kubectl -n "$NAMESPACE" rollout restart deploy/holmes-investigator
  echo ">> ArgoCD token set; investigator restarted."
}

case "$PHASE" in
  pre) pre ;;
  argocd-token) argocd_token ;;
  *) echo "usage: $0 [pre|argocd-token]" >&2; exit 1 ;;
esac
