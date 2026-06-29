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

# uv (not pip) — pip can't override transitive dep pins, but
# diagrid[agent-core] needs fastapi>=0.129 while holmesgpt pins <0.122.
RUN pip install --no-cache-dir uv

# Overrides file mirrors the local holmes-app/pyproject.toml's
# [tool.uv] override-dependencies. uv applies these across the entire
# dependency tree, regardless of declared pins.
RUN printf 'fastapi>=0.129.0\nuvicorn>=0.41.0\ncachetools>=6.1.0,<8.0.0\nmcp==1.26.0\n' \
    > /tmp/overrides.txt

# --prerelease=allow: one of holmesgpt's azure-mgmt-sql deps only ships
# a pre-release on PyPI.
# holmesgpt is pinned to match holmes-app/uv.lock. diagrid 0.4.0 only floors
# it (holmesgpt>=0.26.0), so a fresh resolve pulls the latest — but newer
# holmesgpt dropped the `include_restricted` kwarg that diagrid's registry
# still passes to ToolExecutor.get_all_tools_openai_format(), crashing
# runner.start(). Keep this in lockstep with uv.lock on diagrid bumps.
RUN uv pip install --system --prerelease=allow --overrides /tmp/overrides.txt \
    'diagrid[holmesgpt]==0.4.0' \
    'holmesgpt==0.27.0a0' \
    'chainlit>=2.11.1'

# Build context is holmes-app/ — see image build command in
# k8s/agents/holmes-investigator.yaml or the project README.
COPY app_holmes.py holmes_config.yaml ./
COPY skills/ ./skills/
COPY .chainlit/config.toml ./.chainlit/config.toml

EXPOSE 8000

CMD ["chainlit", "run", "app_holmes.py", "--host", "0.0.0.0", "--port", "8000"]
