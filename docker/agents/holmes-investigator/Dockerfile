FROM python:3.12-slim

WORKDIR /app

# kubectl + argocd CLI: HolmesGPT's `kubernetes/core` and `argocd/core`
# toolsets are scripted wrappers around these binaries, not python-client
# native. Without them Holmes falls back to bash and hits "command not found".
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates jq \
    && ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$ARCH/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-$ARCH" \
        -o /usr/local/bin/argocd \
    && chmod +x /usr/local/bin/argocd \
    && rm -rf /var/lib/apt/lists/*

# uv (not pip) — pip can't override transitive dep pins, which we still need
# for uvicorn/cachetools/mcp (see the overrides file below).
RUN pip install --no-cache-dir uv

# Overrides file mirrors the local holmes-app/pyproject.toml's
# [tool.uv] override-dependencies. uv applies these across the entire
# dependency tree, regardless of declared pins.
# holmesgpt 0.33.0 already pins fastapi>=0.136.3 (above diagrid[agent-core]'s
# >=0.129 floor), so no fastapi override is needed here (matches the local
# pyproject). uvicorn/cachetools/mcp overrides remain to satisfy diagrid floors.
RUN printf 'uvicorn>=0.41.0\ncachetools>=6.1.0,<8.0.0\nmcp==1.26.0\n' \
    > /tmp/overrides.txt

# --prerelease=allow: one of holmesgpt's azure-mgmt-sql deps only ships
# a pre-release on PyPI.
# diagrid 0.4.2's registry calls ToolExecutor.get_all_tools_openai_format(
# include_restricted=...). That kwarg exists through holmesgpt 0.33.0 but was
# REMOVED in 0.34.0 — so uv.lock's floor-resolved 0.34.0 crashes runner.start()
# with a TypeError. Pin to 0.33.0: the newest holmesgpt compatible with diagrid
# 0.4.2's registry call. Re-check this kwarg before bumping holmesgpt past 0.33.0.
RUN uv pip install --system --prerelease=allow --overrides /tmp/overrides.txt \
    'diagrid[holmesgpt]==0.4.2' \
    'holmesgpt==0.33.0' \
    'chainlit>=2.11.1'

# Build context is holmes-app/ — see image build command in
# k8s/agents/holmes-investigator.yaml or the project README.
COPY app_holmes.py holmes_config.yaml ./
COPY skills/ ./skills/
COPY public/ ./public/
COPY .chainlit/config.toml ./.chainlit/config.toml

EXPOSE 8000

CMD ["chainlit", "run", "app_holmes.py", "--host", "0.0.0.0", "--port", "8000"]
