#!/usr/bin/env bash
# Pre-flight for the multi-namespace deploy — the bits Helm can't do: the
# Catalyst App ID, the secrets (in two namespaces), and the ArgoCD token.
#
#   ./deploy/bootstrap.sh pre            # App ID + namespaces + secrets  (BEFORE the helm installs)
#   ./deploy/bootstrap.sh argocd-token   # ArgoCD token -> secret + restart (AFTER infra is up)
#
# Required env:  OPENAI_API_KEY
# Optional env:  PROJECT (holmesgpt-sre-agent)  APPID (holmes-investigator)
#                NS_HOLMES (holmes)  NS_YB (yugabyte)  NS_ARGOCD (argocd)
#                SECRET (sre-agent-secrets)  GITHUB_TOKEN
set -euo pipefail

PROJECT="${PROJECT:-holmesgpt-sre-agent}"
APPID="${APPID:-holmes-investigator}"
NS_HOLMES="${NS_HOLMES:-holmes}"
NS_YB="${NS_YB:-yugabyte}"
NS_ARGOCD="${NS_ARGOCD:-argocd}"
SECRET="${SECRET:-sre-agent-secrets}"
PHASE="${1:-pre}"

ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - ; }

pre() {
  : "${OPENAI_API_KEY:?OPENAI_API_KEY is required}"
  echo ">> Catalyst project + App ID ($PROJECT / $APPID)"
  diagrid project get "$PROJECT" >/dev/null 2>&1 || diagrid project create "$PROJECT" --wait
  diagrid appid get "$APPID" --project "$PROJECT" >/dev/null 2>&1 || diagrid appid create "$APPID" --project "$PROJECT" --wait
  TOKEN=$(diagrid appid get "$APPID" --project "$PROJECT" -o json | jq -r .status.apiToken)

  echo ">> Secret in $NS_HOLMES (app + github-mcp)"
  ns "$NS_HOLMES"
  kubectl create secret generic "$SECRET" -n "$NS_HOLMES" \
    --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
    --from-literal=DAPR_API_TOKEN="$TOKEN" \
    ${GITHUB_TOKEN:+--from-literal=GITHUB_TOKEN="$GITHUB_TOKEN"} \
    --dry-run=client -o yaml | kubectl apply -f -

  echo ">> Secret in $NS_YB (yugabytedb-mcp + seed)"
  ns "$NS_YB"
  RO_PW="holmesro_$(openssl rand -hex 8)"
  YB_URL="host=yb-tserver-0.yb-tservers port=5433 dbname=yugabyte user=holmes_ro password=${RO_PW}"
  kubectl create secret generic "$SECRET" -n "$NS_YB" \
    --from-literal=YUGABYTEDB_RO_PASSWORD="$RO_PW" \
    --from-literal=YUGABYTEDB_URL="$YB_URL" \
    --dry-run=client -o yaml | kubectl apply -f -

  GRPC=$(diagrid project get "$PROJECT" -o json | jq -r '.status.endpoints.grpc.url // .spec.endpoints.grpc.url')
  HTTP=$(diagrid project get "$PROJECT" -o json | jq -r '.status.endpoints.http.url // .spec.endpoints.http.url')
  echo ">> Done. App ID endpoints for the app install:"
  echo "   CATALYST_GRPC=${GRPC}"
  echo "   CATALYST_HTTP=${HTTP}"
}

argocd_token() {
  echo ">> Waiting for ArgoCD (argocd-server in $NS_ARGOCD)"
  kubectl -n "$NS_ARGOCD" rollout status deploy/argocd-server --timeout=180s
  kubectl -n "$NS_ARGOCD" patch configmap argocd-cm --type merge -p '{"data":{"accounts.admin":"apiKey,login"}}'
  kubectl -n "$NS_ARGOCD" rollout restart deploy/argocd-server
  kubectl -n "$NS_ARGOCD" rollout status deploy/argocd-server --timeout=120s

  PW=$(kubectl -n "$NS_ARGOCD" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  kubectl -n "$NS_ARGOCD" port-forward svc/argocd-server 18080:443 >/tmp/pf-argocd.log 2>&1 &
  PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
  for i in $(seq 1 20); do curl -sk https://localhost:18080/healthz >/dev/null 2>&1 && break; sleep 1; done
  SESSION=$(curl -sk -H 'Content-Type: application/json' https://localhost:18080/api/v1/session \
    -d "{\"username\":\"admin\",\"password\":\"${PW}\"}" | jq -r .token)
  TOKEN=$(curl -sk -H 'Content-Type: application/json' -H "Authorization: Bearer ${SESSION}" \
    https://localhost:18080/api/v1/account/admin/token -d '{}' | jq -r .token)

  echo ">> Writing ARGOCD_TOKEN into $SECRET ($NS_HOLMES) + restarting the app"
  kubectl -n "$NS_HOLMES" patch secret "$SECRET" --type merge -p "{\"stringData\":{\"ARGOCD_TOKEN\":\"${TOKEN}\"}}"
  kubectl -n "$NS_HOLMES" rollout restart deploy/holmes-investigator
}

case "$PHASE" in
  pre) pre ;;
  argocd-token) argocd_token ;;
  *) echo "usage: $0 [pre|argocd-token]" >&2; exit 1 ;;
esac
