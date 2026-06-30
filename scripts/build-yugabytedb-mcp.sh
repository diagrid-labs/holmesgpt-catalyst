#!/usr/bin/env bash
# Build (and optionally push) the YugabyteDB MCP server image.
#
# Why this script exists: the upstream `yugabytedb-mcp-server` doesn't publish
# an image, and its `python:3.11-slim` base ships no libpq while the project
# depends on plain `psycopg` (no binary impl) — so a straight build crashes at
# import with "no pq wrapper available". We append a `psycopg[binary]` install
# (bundles libpq, no system package) to the upstream Dockerfile before building.
#
# NOTE: the old FastMCP DNS-rebinding `sed` patch was removed. Upstream
# restructured onto the standalone `fastmcp` package, which no longer rejects
# cluster-DNS Host headers (its OriginValidationMiddleware only enforces when
# MCP_ALLOWED_ORIGINS/MCP_BASE_URL is set, and non-browser clients send no
# Origin), so no source patch is needed anymore.
#
# Usage:
#   IMAGE_REPO=tezizzm ./scripts/build-yugabytedb-mcp.sh           # build (load locally)
#   IMAGE_REPO=tezizzm PUSH=1 ./scripts/build-yugabytedb-mcp.sh    # build + push
#   IMAGE_REPO=tezizzm KIND_CLUSTER=kind ./scripts/build-yugabytedb-mcp.sh
#                                                                    # build + kind load
#
# Env vars:
#   IMAGE_REPO     (required) Docker registry namespace, e.g. "tezizzm"
#   IMAGE_TAG      (optional) defaults to "latest"
#   PLATFORM       (optional) target platform, defaults to "linux/amd64"
#                  (the reference cluster is amd64; override for arm nodes)
#   PUSH           (optional) "1" to push to the registry after build
#   KIND_CLUSTER   (optional) name of a kind cluster; if set, `kind load` the
#                  built image into it (implies a local build, skips push)
#   UPSTREAM_REPO  (optional) git URL; defaults to upstream
#   UPSTREAM_REF   (optional) branch/tag/SHA to check out; defaults to main
#   WORK_DIR       (optional) clone destination; defaults to /tmp/yugabytedb-mcp

set -euo pipefail

: "${IMAGE_REPO:?IMAGE_REPO is required (e.g. IMAGE_REPO=tezizzm)}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
PLATFORM="${PLATFORM:-linux/amd64}"
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

DOCKERFILE="$WORK_DIR/Dockerfile"
[ -f "$DOCKERFILE" ] || { echo "!! upstream Dockerfile not found at $DOCKERFILE" >&2; exit 1; }

# Ensure libpq is available. Appending a RUN at the end of the Dockerfile is
# structure-independent (a trailing RUN still executes at build time; the
# upstream ENTRYPOINT/CMD remain in effect). Idempotent.
if ! grep -q 'psycopg\[binary\]' "$DOCKERFILE"; then
  echo ">> Appending psycopg[binary] install to $DOCKERFILE"
  cat >> "$DOCKERFILE" <<'EOF'

# Added by build-yugabytedb-mcp.sh: the slim base has no libpq and upstream
# depends on plain `psycopg`, so install the binary build (bundles libpq).
RUN pip install --no-cache-dir "psycopg[binary]"
EOF
else
  echo ">> psycopg[binary] already present in Dockerfile, skipping append"
fi

if [ -n "${KIND_CLUSTER:-}" ]; then
  echo ">> Building $IMAGE ($PLATFORM, local) for kind"
  docker buildx build --platform "$PLATFORM" -t "$IMAGE" --load "$WORK_DIR"
  echo ">> kind load $IMAGE into cluster $KIND_CLUSTER"
  kind load docker-image "$IMAGE" --name "$KIND_CLUSTER"
elif [ "${PUSH:-}" = "1" ]; then
  echo ">> Building + pushing $IMAGE ($PLATFORM)"
  docker buildx build --platform "$PLATFORM" -t "$IMAGE" --push "$WORK_DIR"
else
  echo ">> Building $IMAGE ($PLATFORM, local)"
  docker buildx build --platform "$PLATFORM" -t "$IMAGE" --load "$WORK_DIR"
  echo ">> Done. Image $IMAGE is loaded locally. Set PUSH=1 or KIND_CLUSTER=<name> to publish."
fi
