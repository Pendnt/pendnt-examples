#!/usr/bin/env python3
"""pendnt + Claude Agent SDK (Python) -- headless query() whose can_use_tool
implements every permission prompt as a pendnt approval request.

Run:
    PENDNT_API_KEY=aio_... python3 demo.py "delete the file /tmp/scratch.txt"

What happens: the SDK calls can_use_tool only when its own permission flow (hooks ->
deny rules -> ask rules -> mode -> allow rules) falls through to an actual prompt --
see /root/product/INTEGRATIONS.md section 2. When that happens, this script POSTs a
pendnt approval request (title = tool name, details = a JSON preview of the tool
input), long-polls it to a terminal state (bounded by PENDNT_APPROVAL_TIMEOUT_TOTAL_S),
and translates the result into the SDK's PermissionResultAllow/PermissionResultDeny.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys

from claude_agent_sdk import (
    ClaudeAgentOptions,
    PermissionResultAllow,
    PermissionResultDeny,
    ToolPermissionContext,
    query,
)

import pendnt

TOTAL_TIMEOUT_S = float(os.environ.get("PENDNT_APPROVAL_TIMEOUT_TOTAL_S", "600"))  # 10 min default


def _summarize_input(input_data: dict) -> str:
    try:
        text = json.dumps(input_data, indent=2)
    except (TypeError, ValueError):
        return str(input_data)
    return text if len(text) <= 4000 else text[:4000] + "\n...(truncated)"


async def can_use_tool(
    tool_name: str, input_data: dict, context: ToolPermissionContext
) -> PermissionResultAllow | PermissionResultDeny:
    if not pendnt.PENDNT_API_KEY:
        return PermissionResultDeny(message="PENDNT_API_KEY is not set -- denying by default (nobody to ask).")

    title = f"Approve tool call: {tool_name}"
    details_lines = [
        f"tool: {tool_name}",
        f"tool_use_id: {context.tool_use_id}",
    ]
    if context.description:
        details_lines.append(f"description: {context.description}")
    details_lines += ["", "input:", _summarize_input(input_data)]
    details = "\n".join(details_lines)

    try:
        row = await asyncio.to_thread(pendnt.request_approval_and_wait, title, details, TOTAL_TIMEOUT_S)
    except Exception as err:  # noqa: BLE001 - fail closed on any error
        return PermissionResultDeny(message=f"pendnt: failed to get an answer ({err}) -- denying by default.")

    if pendnt.is_approved(row):
        return PermissionResultAllow(updated_input=input_data)

    if row.status == "pending":
        reason = f"no answer within {TOTAL_TIMEOUT_S:.0f}s (request {row.id})"
    elif row.status == "expired":
        reason = "request expired before it was answered"
    elif row.status == "cancelled":
        reason = "request was cancelled"
    elif row.answer:
        reason = f"operator answered: {row.answer}"
    else:
        reason = "denied by operator"

    return PermissionResultDeny(message=f"pendnt: {reason} -- denying by default.")


async def main() -> None:
    prompt = " ".join(sys.argv[1:]) or "list the files in the current directory"

    options = ClaudeAgentOptions(
        can_use_tool=can_use_tool,
        # can_use_tool only fires when the permission flow falls through to a
        # prompt -- "default" mode still auto-approves plenty of read-only tools
        # without asking.
        permission_mode="default",
    )

    async for message in query(prompt=prompt, options=options):
        print(message)


if __name__ == "__main__":
    asyncio.run(main())
