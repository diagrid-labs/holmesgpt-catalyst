"""Chainlit UI backed by DaprWorkflowHolmesRunner.

Run:
    cd holmes-app
    uv sync
    export OPENAI_API_KEY=...
    export MODEL=gpt-4o-mini
    # Connect to your Catalyst project (no local Dapr runtime). Values from:
    #   diagrid appid get holmes-investigator --project <project>
    export DAPR_GRPC_ENDPOINT=https://grpc-<project>.<region>.diagrid.io:443
    export DAPR_HTTP_ENDPOINT=https://http-<project>.<region>.diagrid.io:443
    export DAPR_API_TOKEN=diagrid://...

    # Optional: start the GitHub MCP server (referenced by holmes_config.yaml).
    # Port 8765 on the host to avoid collision with chainlit's 8000.
    docker run -d --name github-mcp --rm -p 8765:8000 \\
        -e GITHUB_PERSONAL_ACCESS_TOKEN=$GITHUB_TOKEN \\
        ghcr.io/github/github-mcp-server \\
        --read-only --toolsets=actions,pull_requests,repos http --port=8000

    uv run chainlit run app_holmes.py --port 8000 --host 0.0.0.0

Slash commands:
    /replay <instance_id> <seq>
        Re-run a single tool call from a completed investigation by reading
        its inputs off the event tape. Bypasses the LLM and workflow — no
        new agent loop, no token spend. Use the workflow_id printed at the
        top of an investigation and a `#<seq>` from a tool step.

Post-investigation summary:
    After every investigation, a second LLM call (model: $SUMMARY_MODEL,
    default gpt-4o-mini) emits a structured JSON summary — headline, root
    cause hypothesis, affected services, evidence, suggested actions,
    confidence. Disable with SUMMARY_ENABLED=false.
"""

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Any, Dict, List

# --------------------------------------------------------------------------
# durabletask gRPC channel-option patch
#
# The Dapr Python SDK's WorkflowRuntime / DaprWorkflowClient wrap durabletask's
# TaskHubGrpcWorker / TaskHubGrpcClient but do not pass `channel_options`
# through, so the underlying gRPC channels stay at the 4 MiB default for both
# max_send_message_length and max_receive_message_length. With multi-iteration
# investigations the activity-result payloads (tool outputs + LLM history) blow
# past 4 MiB and we get `RESOURCE_EXHAUSTED: trying to send message larger than
# max (X vs 4194304)` from the worker stream.
#
# Until the SDK exposes the kwarg, patch the leaf classes at import time so
# every TaskHubGrpc{Worker,Client} that any downstream code constructs inherits
# our larger limits. Override via HOLMES_GRPC_MAX_MB (default 32 MiB).
#
# This still doesn't change the underlying trajectory — workflow history grows
# with iteration count, so the right durable answer is to keep big tool
# outputs out of workflow state (truncate at the tool boundary). Raising the
# cap buys headroom; the SKILL.md should bound the per-step output.
import durabletask.client as _dt_client  # noqa: E402
import durabletask.worker as _dt_worker  # noqa: E402

_GRPC_MAX_BYTES = int(os.getenv("HOLMES_GRPC_MAX_MB", "32")) * 1024 * 1024
_GRPC_CHANNEL_OPTIONS = [
    ("grpc.max_send_message_length", _GRPC_MAX_BYTES),
    ("grpc.max_receive_message_length", _GRPC_MAX_BYTES),
]


def _inject_channel_options(cls):
    """Monkey-patch a durabletask grpc class's __init__ so its channel_options
    kwarg defaults to our larger send/receive limits when callers don't set one.
    """
    original_init = cls.__init__

    def patched_init(self, *args, _original_init=original_init, **kwargs):
        if kwargs.get("channel_options") is None:
            kwargs["channel_options"] = _GRPC_CHANNEL_OPTIONS
        return _original_init(self, *args, **kwargs)

    cls.__init__ = patched_init


_inject_channel_options(_dt_worker.TaskHubGrpcWorker)
_inject_channel_options(_dt_client.TaskHubGrpcClient)
# --------------------------------------------------------------------------

import chainlit as cl  # noqa: E402
import litellm  # noqa: E402

from diagrid.agent.holmesgpt import DaprWorkflowHolmesRunner  # noqa: E402
from diagrid.agent.holmesgpt import event_log  # noqa: E402
from holmes.core.tools import ToolInvokeContext  # noqa: E402

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

CONFIG_PATH = Path(__file__).parent / "holmes_config.yaml"
MODEL = os.getenv("MODEL", "gpt-4o-mini")
MAX_STEPS = int(os.getenv("HOLMES_MAX_STEPS", "10"))
SUMMARY_MODEL = os.getenv("SUMMARY_MODEL", "gpt-4o-mini")
SUMMARY_ENABLED = os.getenv("SUMMARY_ENABLED", "true").lower() not in ("false", "0", "")

SYSTEM_PROMPT_ADDITIONS = """CRITICAL — MCP TOOL CALL RULES:

1. NEVER include a parameter with a value of null, None, or empty string ("") in your tool call JSON. If you don't have a value for an optional parameter, OMIT THE KEY ENTIRELY.

2. WRONG: {"owner": "x", "repo": "y", "head": null, "base": null, "sort": "created"}
   RIGHT: {"owner": "x", "repo": "y", "sort": "created"}

3. If a tool returns "parameter X is not of type string, is <nil>", the X parameter must be REMOVED from your next call, not set to "" or retried with the same null.

4. For list_pull_requests on the GitHub MCP server specifically: pass only owner, repo, and state. Omit head, base, sort, direction unless you have a specific filter value.
"""

runner = DaprWorkflowHolmesRunner(
    name="sre-investigator",
    config_path=CONFIG_PATH,
    model=MODEL,
    max_steps=MAX_STEPS,
    toolset_tags=["core"],
    enable_all_toolsets_possible=False,
)
runner.start()
logger.info("DaprWorkflowHolmesRunner started (model=%s, max_steps=%d)", MODEL, MAX_STEPS)


def replay_tool(instance_id: str, seq: int) -> Dict[str, Any]:
    """Replay a single tool call from a past investigation.

    Reads the `start_tool_calling` event at the given seq off the Catalyst-backed
    event tape, looks up the named tool in the current registry's executor,
    and invokes it with the recorded params. No LLM call, no workflow.

    Caveats:
      - Tool re-executes against *current* live state, not point-in-time.
      - Skips approval gates (caller invoking /replay is explicit consent).
    """
    events = event_log.read_after(
        instance_id,
        since_seq=seq - 1,
        limit=1,
        store_name=runner._events_store_name,
        key_prefix=runner._events_key_prefix,
    )
    if not events or events[0].get("seq") != seq:
        return {"error": f"no event at instance_id={instance_id!r} seq={seq}"}

    event = events[0]
    if event.get("event") != "start_tool_calling":
        return {
            "error": (
                f"event at seq={seq} is {event.get('event')!r}, not 'start_tool_calling'. "
                f"Pick the seq of the tool's start event (every tool call has a start_tool_calling "
                f"at seq N and a tool_calling_result at seq N+1)."
            )
        }

    data = event.get("data") or {}
    tool_name = data.get("tool_name")
    params = data.get("params") or {}

    registry = runner._registry
    if registry is None:
        return {"error": "runner is not started"}

    tool = registry.tool_executor.get_tool_by_name(tool_name)
    if tool is None:
        return {
            "error": (
                f"tool {tool_name!r} not registered in the current executor. "
                f"It may have been disabled since the original investigation, "
                f"or it came from an MCP server that is no longer reachable."
            )
        }

    ctx = ToolInvokeContext(
        tool_name=tool_name,
        tool_call_id=data.get("tool_call_id") or f"replay-{instance_id}-{seq}",
        llm=registry.ai.llm,
        max_token_count=registry.ai.llm.get_context_window_size(),
        user_approved=True,
    )
    result = tool.invoke(params, ctx)
    output = (
        result.get_stringified_data()
        if hasattr(result, "get_stringified_data")
        else str(result)
    )
    return {
        "tool_name": tool_name,
        "params": params,
        "status": getattr(result, "status", None) and str(result.status),
        "elapsed_seconds": getattr(result, "elapsed_seconds", None),
        "output": output,
    }


_SUMMARY_PROMPT = """You are summarizing an SRE investigation into a structured JSON record. Be specific and concise — the summary will be consumed by humans scanning incident reports.

User question:
{question}

Investigation final answer:
{answer}

Tools invoked during the investigation (name + truncated result preview):
{tools}

Return JSON matching exactly this schema (no extra fields):
{{
  "headline": "<= 140-char one-sentence TL;DR",
  "root_cause_hypothesis": "the most likely cause based on the evidence above, or 'unknown' if insufficient",
  "affected_services": ["service-name", ...],
  "evidence": [{{"tool": "tool_name", "finding": "one-sentence summary of what this tool told us"}}],
  "suggested_actions": ["concrete action 1", "concrete action 2"],
  "confidence": "low|medium|high"
}}

Confidence rubric: high = data confirms the hypothesis; medium = data is consistent but not conclusive; low = data is missing or contradictory."""


def summarize_investigation(
    question: str,
    answer: str,
    tool_calls: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Run a single structured-output LLM call summarizing the investigation.

    Routed through LiteLLM (the same path Holmes uses) but with its own model
    knob — typically a cheaper model than the investigator's. Skips Holmes'
    agent loop entirely: no tools, no durability, just one completion.
    """
    tool_lines = []
    for tc in tool_calls:
        preview = (tc.get("preview") or "").replace("\n", " ")[:240]
        tool_lines.append(f"- {tc.get('name', '?')}: {preview}")
    tools_block = "\n".join(tool_lines) if tool_lines else "(no tools invoked)"

    prompt = _SUMMARY_PROMPT.format(question=question, answer=answer, tools=tools_block)
    response = litellm.completion(
        model=SUMMARY_MODEL,
        messages=[{"role": "user", "content": prompt}],
        response_format={"type": "json_object"},
        temperature=0,
    )
    return json.loads(response.choices[0].message.content)


def render_summary_markdown(summary: Dict[str, Any]) -> str:
    headline = summary.get("headline", "(no headline)")
    cause = summary.get("root_cause_hypothesis", "unknown")
    confidence = summary.get("confidence", "low")
    affected = summary.get("affected_services") or []
    evidence = summary.get("evidence") or []
    actions = summary.get("suggested_actions") or []

    lines = [
        "### TL;DR",
        headline,
        "",
        f"**Root cause hypothesis** _(confidence: {confidence})_: {cause}",
    ]
    if affected:
        lines.append(f"\n**Affected services:** {', '.join(affected)}")
    if evidence:
        lines.append("\n**Evidence:**")
        for e in evidence:
            lines.append(f"- `{e.get('tool', '?')}` — {e.get('finding', '')}")
    if actions:
        lines.append("\n**Suggested actions:**")
        for i, a in enumerate(actions, 1):
            lines.append(f"{i}. {a}")
    return "\n".join(lines)


@cl.set_starters
async def set_starters() -> list[cl.Starter]:
    return [
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


async def _handle_replay(message: cl.Message) -> None:
    parts = message.content.split()
    if len(parts) != 3:
        await cl.Message(
            content="Usage: `/replay <instance_id> <seq>` — get instance_id from the investigation header and seq from a tool step label.",
        ).send()
        return
    _, instance_id, seq_str = parts
    try:
        seq = int(seq_str)
    except ValueError:
        await cl.Message(content=f"Invalid seq: `{seq_str}` (must be an integer).").send()
        return
    result = await asyncio.to_thread(replay_tool, instance_id, seq)
    body = "```json\n" + json.dumps(result, indent=2, default=str) + "\n```"
    await cl.Message(content=body).send()


@cl.on_message
async def on_message(message: cl.Message) -> None:
    if message.content.startswith("/replay"):
        await _handle_replay(message)
        return

    final_text = ""
    tool_calls: List[Dict[str, Any]] = []
    try:
        async for event in runner.ask_async(
            message.content,
            additional_system_prompt=SYSTEM_PROMPT_ADDITIONS,
        ):
            kind = event.get("event") or event.get("type")
            data = event.get("data") or {}
            seq = event.get("seq")

            if kind == "workflow_started":
                wf_id = event.get("workflow_id")
                logger.info("workflow_started: %s", wf_id)
                await cl.Message(
                    content=f"_Investigation `{wf_id}` — tool steps are tagged with their event seq; replay any one with_ `/replay {wf_id} <seq>`",
                ).send()

            elif kind == "start_tool_calling":
                async with cl.Step(name=f"#{seq} tool: {data.get('tool_name', '?')}", type="tool") as step:
                    step.input = data.get("params", {})

            elif kind == "tool_calling_result":
                async with cl.Step(name=f"#{seq} result: {data.get('tool_name', '?')}", type="tool") as step:
                    step.output = data.get("data_preview", "") or data.get("error", "")
                tool_calls.append({
                    "name": data.get("tool_name", "?"),
                    "preview": data.get("data_preview") or data.get("error") or "",
                })

            elif kind == "iteration_started":
                logger.info("iteration %s started", data.get("iteration"))

            elif kind == "ai_answer_end":
                final_text = data.get("content") or final_text

            elif kind == "workflow_completed":
                output = event.get("output") or {}
                final = output.get("final") or {}
                final_text = final.get("content") or final_text

        await cl.Message(content=final_text or "(no answer returned)").send()

        if SUMMARY_ENABLED and final_text:
            try:
                async with cl.Step(name=f"Summary ({SUMMARY_MODEL})", type="run") as step:
                    summary = await asyncio.to_thread(
                        summarize_investigation, message.content, final_text, tool_calls
                    )
                    step.output = json.dumps(summary, indent=2)
                await cl.Message(content=render_summary_markdown(summary)).send()
            except Exception:
                logger.exception("Summary generation failed (non-fatal)")

    except Exception as exc:
        logger.exception("Investigation failed")
        await cl.Message(content=f"Investigation failed: {exc}").send()
