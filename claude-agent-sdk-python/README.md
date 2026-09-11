# pendnt + Claude Agent SDK (Python)

Two small scripts against
[`claude-agent-sdk`](https://pypi.org/project/claude-agent-sdk/), showing the two ways
to wire a headless `query()` up to pendnt (see `/root/product/INTEGRATIONS.md` §2):

1. **`demo.py`** — implements `can_use_tool` by creating a pendnt approval request and
   long-polling it, so every tool-use permission prompt the SDK would otherwise have
   nobody to show becomes a durable, answerable-from-your-phone approval.
2. **`demo_mcp.py`** — wires the hosted pendnt **MCP server** directly into
   `ClaudeAgentOptions.mcp_servers`, exposing all of pendnt's tools (`request_approval`,
   `notify`, `wait_for_event`, `schedule_wakeup`, `kv_*`, ...) to the model itself via
   `allowed_tools=["mcp__pendnt__*"]`.

These are independent — use `can_use_tool` when you want *your own code* to decide how
a permission prompt resolves (pendnt is just the notification/answer channel); use the
MCP server when you want *the model itself* to be able to ask for approval, send a
notification, or wait on an inbound webhook as part of its own reasoning.

## Setup

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export PENDNT_API_KEY=aio_...
export PENDNT_URL=https://api.pendnt.dev   # optional, this is the default
```

Get a key at [pendnt.dev](https://pendnt.dev), or locally against `wrangler dev` (see
`/root/work/app/README.md`):

```bash
curl -s -X POST http://localhost:8787/dev/bootstrap -d '{}' | python3 -c "import json,sys; print(json.load(sys.stdin)['api_key'])"
```

## Run

```bash
python3 demo.py "delete the file /tmp/scratch.txt"
python3 demo_mcp.py "call the pendnt whoami tool and report what it returns"
```

`python3 -m py_compile pendnt.py demo.py demo_mcp.py` syntax-checks all three files
(also run against this exact directory to confirm it passes cleanly).

## `pendnt.py` — the shared helper module

A minimal `urllib`-based client (stdlib only — no extra dependency beyond the Agent SDK
itself) for the pieces of the REST API this example needs: `create_request`/
`get_request` (`POST /v1/requests`, `GET /v1/requests/:id?wait_s=N`), `notify`
(`POST /v1/notify`), plus `request_approval_and_wait` (create + poll to a terminal
state within a total timeout budget) and `is_approved` (maps a request row to
allow/deny, treating a free-text answer starting with yes/y/allow/approve/ok as
approval — the operator answer page always shows a free-text box, even for
approval-kind requests). Same conventions as the Claude Code plugin's
`PermissionRequest` hook (`/root/work/plugin/hooks/permission-request.mjs`) and
`../curl/approve.sh`.

## `demo.py` — `can_use_tool` via pendnt

```python
async def can_use_tool(tool_name, input_data, context):
    title = f"Approve tool call: {tool_name}"
    details = f"input:\n{json.dumps(input_data, indent=2)}"
    row = await asyncio.to_thread(pendnt.request_approval_and_wait, title, details, TOTAL_TIMEOUT_S)
    if pendnt.is_approved(row):
        return PermissionResultAllow(updated_input=input_data)
    return PermissionResultDeny(message=f"pendnt: {row.status}")

async for message in query(prompt=prompt, options=ClaudeAgentOptions(can_use_tool=can_use_tool)):
    print(message)
```

`can_use_tool` fires only when the SDK's permission flow (hooks → deny rules → ask
rules → mode → allow rules) falls through to an actual prompt — auto-approved calls
never reach it (`/root/product/INTEGRATIONS.md` §2). `pendnt.py`'s HTTP calls are
blocking (`urllib`), so `demo.py` runs them via `asyncio.to_thread` to stay
non-blocking inside the async callback. `PENDNT_APPROVAL_TIMEOUT_TOTAL_S` (env,
default `600`) is the total wall-clock budget spent re-polling
`GET /v1/requests/:id?wait_s=25` before giving up and denying.

**On not blocking a long-running process**: the SDK docs recommend against holding
`can_use_tool` open indefinitely for something that might take hours or days to
answer — prefer a `PreToolUse` hook returning `defer` and resuming the session later
(see `/root/product/INTEGRATIONS.md` §2 and `/root/work/plugin/README.md`'s `defer`
discussion) if your approvals can take that long. This demo's `can_use_tool` is fine
for prompts you expect answered within `PENDNT_APPROVAL_TIMEOUT_TOTAL_S`.

## `demo_mcp.py` — the pendnt MCP server directly

```python
options = ClaudeAgentOptions(
    mcp_servers={
        "pendnt": {
            "type": "http",
            "url": f"{PENDNT_URL}/mcp",
            "headers": {"Authorization": f"Bearer {os.environ['PENDNT_API_KEY']}"},
        }
    },
    allowed_tools=["mcp__pendnt__*"],
)
```

This is the exact shape documented in `/root/work/app/README.md`'s "Client config
snippets" → "Claude Agent SDK — Python". With this wired up, the model can call any of
pendnt's 13 MCP tools directly (see `/root/work/app/README.md`'s "Tools" table) —
useful when you want the agent's own reasoning to decide when to ask a human, notify,
or wait for an event, rather than intercepting every tool permission prompt.

## Versions

`requirements.txt` pins `claude-agent-sdk==0.2.148`, verified to exist on PyPI
(`pypi.org/pypi/claude-agent-sdk/json`) as of 2026-08-29. All three `.py` files here
were checked with `python3 -m py_compile` against this exact directory.
