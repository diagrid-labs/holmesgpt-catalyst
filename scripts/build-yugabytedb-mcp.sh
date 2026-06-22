#!/usr/bin/env bash
# Build (and optionally push) the YugabyteDB MCP server image with the
# FastMCP DNS-rebinding-protection patch applied.
#
# Why this script exists: the upstream `yugabytedb-mcp-server` source
# initializes FastMCP without overriding its DNS-rebinding protection.
# That blocks every in-cluster request with `421 Misdirected Request`
# because FastMCP's default `allowed_hosts` only accepts localhost-style
# Host headers. We patch two lines of `src/server.py` to disable the
# protection (safe for in-cluster traffic, not internet-exposed).
#
# Usage:
#   IMAGE_REPO=tezizzm ./scripts/build-yugabytedb-mcp.sh           # build only
#   IMAGE_REPO=tezizzm PUSH=1 ./scripts/build-yugabytedb-mcp.sh    # build + push
#   IMAGE_REPO=tezizzm KIND_CLUSTER=kind ./scripts/build-yugabytedb-mcp.sh
#                                                                    # build + kind load
#
# Env vars:
#   IMAGE_REPO     (required) Docker registry namespace, e.g. "tezizzm"
#   IMAGE_TAG      (optional) defaults to "latest"
#   PUSH           (optional) "1" to docker push after build
#   KIND_CLUSTER   (optional) name of a kind cluster; if set, `kind load`
#                  the built image into it (skips push)
#   UPSTREAM_REPO  (optional) git URL; defaults to upstream
#   UPSTREAM_REF   (optional) branch/tag/SHA to check out; defaults to main
#   WORK_DIR       (optional) clone destination; defaults to /tmp/yugabytedb-mcp

set -euo pipefail

: "${IMAGE_REPO:?IMAGE_REPO is required (e.g. IMAGE_REPO=tezizzm)}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/yugabyte/yugabytedb-mcp-server.git}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
WORK_DIR="${WORK_DIR:-/tmp/yugabytedb-mcp}"
IMAGE="${IMAGE_REPO}/yugabytedb-mcp:${IMAGE_TAG}"

echo ">> Cloning $UPSTREAM_REPO ($UPSTREAM_REF) into $WORK_DIR"
if [ -d "$WORK_DIR/.git" ]; then
  git -C "$WORK_DIR" fetch --quiet origin "$UPSTREAM_REF"
  git -C "$WORK_DIR" reset --hard "origin/$UPSTREAM_REF" --quiet
else
  rm -rf "$WORK_DIR"
  git clone --quiet --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" "$WORK_DIR"
fi

SRC="$WORK_DIR/src/server.py"
echo ">> Patching $SRC"

# Patch 1: add the TransportSecuritySettings import next to FastMCP's import.
if ! grep -q 'from mcp.server.transport_security import TransportSecuritySettings' "$SRC"; then
  sed -i.bak \
    's|from mcp.server.fastmcp import FastMCP, Context|from mcp.server.fastmcp import FastMCP, Context\nfrom mcp.server.transport_security import TransportSecuritySettings|' \
    "$SRC"
fi

# Patch 2: pass transport_security to FastMCP() so it accepts cluster-DNS
# Host headers. Idempotent — skip if the constructor already has it.
if ! grep -q 'transport_security=TransportSecuritySettings' "$SRC"; then
  sed -i.bak2 \
    's|stateless_http=CONFIG.stateless_http,|stateless_http=CONFIG.stateless_http,\n            transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),|' \
    "$SRC"
fi

echo ">> Verifying patch landed:"
grep -A 6 'self.mcp = FastMCP' "$SRC"

echo ">> Building $IMAGE"
docker build -t "$IMAGE" "$WORK_DIR"

if [ -n "${KIND_CLUSTER:-}" ]; then
  echo ">> kind load $IMAGE into cluster $KIND_CLUSTER"
  kind load docker-image "$IMAGE" --name "$KIND_CLUSTER"
elif [ "${PUSH:-}" = "1" ]; then
  echo ">> docker push $IMAGE"
  docker push "$IMAGE"
else
  echo ">> Done. Image $IMAGE is local. Set PUSH=1 or KIND_CLUSTER=<name> to publish."
fi
