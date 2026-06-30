"""Chainlit UI backed by DaprWorkflowHolmesRunner.

Run:
    cd holmes-app
    uv sync
    export OPENAI_API_KEY=...
    export MODEL=gpt-4o-mini
    # Connect to your Catalyst project. Values from:
    #   diagrid appid get holmes-investigator --project <project>
    export DAPR_GRPC_ENDPOINT=https://grpc-<project>.<region>.diagrid.io:443
    export DAPR_HTTP_ENDPOINT=https://http-<project>.<region>.diagrid.io:443
    export DAPR_API_TOKEN=diagrid://...

    uv run chainlit run app_holmes.py --port 8000 --host 0.0.0.0
"""

import chainlit as cl


@cl.set_starters
async def set_starters() -> list[cl.Starter]:
    return [
        cl.Starter(
            label="Skill: api-gateway latency",
            message="api-gateway p99 latency is spiking past 2s. What's the runbook?",
        ),
        cl.Starter(
            label="Skill: auth-service crashing",
            message="auth-service pods are in CrashLoopBackOff. How do I triage?",
        ),
        cl.Starter(
            label="GitHub: open PRs",
            message="List the open pull requests on tezizzm/sre-platform-services.",
        ),
        cl.Starter(
            label="YugabyteDB: list tables",
            message="List the tables in our YugabyteDB database, including their schemas and approximate row counts.",
        ),
        cl.Starter(
            label="Pulsar: list topics",
            message="List the Pulsar topics in the public/default namespace and summarize what each one looks like (partition count, recent message count).",
        ),
        cl.Starter(
            label="Smoke test (no tools)",
            message="Briefly: what kinds of investigations can you run?",
        ),
    ]


@cl.on_message
async def on_message(message: cl.Message) -> None:
    await cl.Message(content="Runner not connected — set DAPR_GRPC_ENDPOINT, DAPR_HTTP_ENDPOINT, and DAPR_API_TOKEN then restart.").send()
