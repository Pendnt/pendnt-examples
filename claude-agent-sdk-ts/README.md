# pendnt + Claude Agent SDK (TypeScript)

Two small scripts against
[`@anthropic-ai/claude-agent-sdk`](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk),
showing the two ways to wire a headless `query()` up to pendnt (see
`/root/product/INTEGRATIONS.md` §2):

1. **`src/demo.ts`** — implements `canUseTool` by creating a pendnt approval request
   and long-polling it, so every tool-use permission prompt the SDK would otherwise
   have nobody to show becomes a durable, answerable-from-your-phone approval.
2. **`src/demo-mcp.ts`** — wires the hosted pendnt **MCP server** directly into
   `options.mcpServers`, exposing all of pendnt's tools (`request_approval`, `notify`,
   `wait_for_event`, `schedule_wakeup`, `kv_*`, ...) to the model itself via
   `allowedTools: ["mcp__pendnt__*"]`.

These are independent — use `canUseTool` when you want *your own code* to decide how a
permission prompt resolves (and pendnt is just the notification/answer channel); use
the MCP server when you want *the model itself* to be able to ask for approval, send a
notification, or wait on an inbound webhook as part of its own reasoning.

## Setup

```bash
npm install
export PENDNT_API_KEY=aio_...
export PENDNT_URL=https://api.pendnt.dev   # optional, this is the default
```

Get a key at [pendnt.dev](https://pendnt.dev), or locally against `wrangler dev` (see
`/root/work/app/README.md`):

```bash
curl -s -X POST http://localhost:8787/dev/bootstrap -d '{}' | jq -r .api_key
```

## Run

```bash
npm run demo -- "delete the file /tmp/scratch.txt"
npm run demo:mcp -- "call the pendnt whoami tool and report what it returns"
```

`npm run typecheck` (`npx tsc --noEmit`) type-checks both scripts against the SDK's
published `.d.ts` files.

## `src/pendnt.ts` — the shared helper

A minimal `fetch`-based client for the pieces of the REST API this example needs:
`createRequest`/`getRequest` (`POST /v1/requests`, `GET /v1/requests/:id?wait_s=N`),
`notify` (`POST /v1/notify`), plus `requestApprovalAndWait` (create + poll to a
terminal state within a total timeout budget) and `isApproved` (maps a request row to
allow/deny, treating a free-text answer starting with yes/y/allow/approve/ok as
approval — the operator answer page always shows a free-text box, even for
approval-kind requests). Same conventions as the Claude Code plugin's
`PermissionRequest` hook (`/root/work/plugin/hooks/permission-request.mjs`) and
`../curl/approve.sh`.

## `src/demo.ts` — `canUseTool` via pendnt

```ts
const canUseTool: CanUseTool = async (toolName, input, options) => {
  const title = `Approve tool call: ${toolName}`;
  const details = `input:\n${JSON.stringify(input, null, 2)}`;
  const row = await requestApprovalAndWait(title, details, TOTAL_TIMEOUT_S, options.signal);
  return isApproved(row)
    ? { behavior: "allow", updatedInput: input }
    : { behavior: "deny", message: `pendnt: ${row.status}` };
};

for await (const message of query({ prompt, options: { canUseTool } })) {
  console.log(message);
}
```

`canUseTool` fires only when the SDK's permission flow (hooks → deny rules → ask rules
→ mode → allow rules) falls through to an actual prompt — auto-approved calls never
reach it (`/root/product/INTEGRATIONS.md` §2). `PENDNT_APPROVAL_TIMEOUT_TOTAL_S` (env,
default `600`) is the total wall-clock budget spent re-polling
`GET /v1/requests/:id?wait_s=25` before giving up and denying.

**On not blocking a long-running process**: the SDK docs recommend against holding
`canUseTool` open indefinitely for something that might take hours or days to answer —
prefer a `PreToolUse` hook returning `defer` and resuming the session later (see
`/root/product/INTEGRATIONS.md` §2 and `/root/work/plugin/README.md`'s `defer`
discussion) if your approvals can take that long. This demo's `canUseTool` is fine for
prompts you expect answered within `PENDNT_APPROVAL_TIMEOUT_TOTAL_S`.

## `src/demo-mcp.ts` — the pendnt MCP server directly

```ts
options: {
  mcpServers: {
    pendnt: {
      type: "http",
      url: `${PENDNT_URL}/mcp`,
      headers: { Authorization: `Bearer ${process.env.PENDNT_API_KEY}` },
    },
  },
  allowedTools: ["mcp__pendnt__*"],
}
```

This is the exact shape documented in `/root/work/app/README.md`'s "Client config
snippets" → "Claude Agent SDK — TypeScript". With this wired up, the model can call any
of pendnt's 13 MCP tools directly (see `/root/work/app/README.md`'s "Tools" table) —
useful when you want the agent's own reasoning to decide when to ask a human, notify,
or wait for an event, rather than intercepting every tool permission prompt.

## Versions

`package.json` pins `@anthropic-ai/claude-agent-sdk@0.3.251`, `typescript@5.7.3`,
`@types/node@22.10.5`, `tsx@4.19.2` — all verified to exist on npm (`npm view <pkg>
version`) as of 2026-08-29. `npm install` and `npx tsc --noEmit` were both run against
this exact directory to confirm they pass cleanly.
