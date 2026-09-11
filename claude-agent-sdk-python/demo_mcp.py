#!/usr/bin/env python3
"""pendnt + Claude Agent SDK (Python) -- wiring the hosted pendnt MCP server directly
into query(), so the model can call request_approval/notify/wait_for_event/
schedule_wakeup/kv_* itself instead of (or in addition to) can_use_tool intercepting
its own tool prompts. See /root/work/app/README.md's "Remote MCP server" section for
the full tool list and /root/product/INTEGRATIONS.md section 2 ("MCP with auth
headers").

Run:
    PENDNT_API_KEY=aio_... python3 demo_mcp.py "call the pendnt whoami tool and report what it returns"
"""

from __future__ import annotations

import asyncio
import os
import sys

from claude_agent_sdk import ClaudeAgentOptions, query

PENDNT_URL = os.environ.get("PENDNT_URL", "https://api.pendnt.dev").rstrip("/")


async def main() -> None:
    prompt = " ".join(sys.argv[1:]) or "call the pendnt whoami tool and report what it returns"

    options = ClaudeAgentOptions(
        mcp_servers={
            "pendnt": {
                "type": "http",
                "url": f"{PENDNT_URL}/mcp",
                "headers": {"Authorization": f"Bearer {os.environ.get('PENDNT_API_KEY', '')}"},
            }
        },
        # Only expose pendnt's own tools (request_approval, check_request, notify,
        # create_endpoint, list_endpoints, wait_for_event, schedule_wakeup,
        # list_wakeups, cancel_wakeup, kv_get, kv_set, kv_delete, whoami) -- see
        # /root/work/app/README.md's "Tools" table for the full list.
        allowed_tools=["mcp__pendnt__*"],
    )

    async for message in query(prompt=prompt, options=options):
        print(message)


if __name__ == "__main__":
    asyncio.run(main())
