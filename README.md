# pendnt integration examples
> **Try it in 10 seconds — no account:** `curl https://api.pendnt.dev/try?plain=1` returns a 72-hour trial key (20 requests) with a quickstart.

Runnable examples for integrating [pendnt](https://pendnt.dev) — durable human
approvals, notifications, inbound webhook endpoints, scheduled wake-ups, and a small
per-workspace KV scratchpad, for agents that have no terminal — into a handful of
common agent runtimes. Every example matches the real API documented in
`/root/work/app/README.md` (REST + MCP reference); implemented capabilities only —
no policies, no Slack/Discord delivery (those are stubs today, see that README's
"Channels (delivery)" section).

## Shared env vars

Every example reads these two:

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `PENDNT_API_KEY` | yes | — | `Authorization: Bearer <key>` for every API/MCP call (`aio_...`). Get one at [pendnt.dev](https://pendnt.dev) (signup → magic link → dashboard shows it once), or locally against a `wrangler dev` instance via `POST /dev/bootstrap` (see `/root/work/app/README.md`). |
| `PENDNT_URL` | no | `https://api.pendnt.dev` | REST API base URL (no trailing slash, no `/mcp`). Point at `http://localhost:8787` for local dev. The MCP endpoint is always `$PENDNT_URL/mcp`. |

Some examples add their own timeout-budget env var on top of these — see each one's
own README.

## Examples

### [`curl/`](curl/)

Four dependency-light (`bash` + `curl` + `jq`) scripts: `approve.sh` (create an
approval and block until answered, exit 0/1 by the answer), `notify.sh`
(fire-and-forget), `inbox.sh` (create an inbound webhook endpoint, print its URL, watch
it for events), and `wakeup.sh` (schedule a wake-up, optionally wait for it to fire).
The lowest-dependency starting point — good for CI jobs or any language without an SDK
yet.

### [`claude-agent-sdk-ts/`](claude-agent-sdk-ts/)

TypeScript, `@anthropic-ai/claude-agent-sdk`. `src/demo.ts` implements `canUseTool` by
routing every tool-use permission prompt through a pendnt approval request
(create + long-poll); `src/demo-mcp.ts` instead wires the hosted pendnt MCP server
directly into `options.mcpServers` with `allowedTools: ["mcp__pendnt__*"]`, so the
model can call pendnt's tools itself. `npm install` and `npx tsc --noEmit` both verified
clean against pinned dependency versions.

### [`claude-agent-sdk-python/`](claude-agent-sdk-python/)

The same pair of patterns in Python (`claude-agent-sdk`): `demo.py`'s `can_use_tool`
(returning `PermissionResultAllow`/`PermissionResultDeny`) and `demo_mcp.py`'s
`mcp_servers` config, both built on the stdlib-only `pendnt.py` helper module. Verified
with `python3 -m py_compile` and by importing all three modules against a real
`claude-agent-sdk` install.

### [`openclaw-skill/pendnt/`](openclaw-skill/pendnt/)

An [OpenClaw](https://docs.openclaw.ai) skill (`SKILL.md` + `scripts/pendnt.sh`),
purpose-built for the case OpenClaw's own docs call out: a cron/isolated session has no
`ask_user` available. Covers calling pendnt via its hosted MCP server (if the runtime
supports remote MCP) or via `curl` (always available), and the "poll-by-id" pattern for
approvals that might take longer than one cron run's timeout to answer. Not published
to ClawHub — see the SKILL.md's own "Before publishing" checklist.

### [`langgraph-python/`](langgraph-python/)

A minimal [LangGraph](https://pypi.org/project/langgraph/) graph
(`prepare -> human_approval -> act|stop`) whose `human_approval` node is an
`interrupt()`-style human gate implemented by pendnt: create an approval request, block
on it inside the node via long-polling, route on the answer. Verified by installing
`langgraph` into a real virtualenv and building the compiled graph, in addition to
`py_compile`.

### [`cron-claude-code/`](cron-claude-code/)

A `crontab` line + `run.sh` wrapper that runs `claude -p "<task>"
--permission-prompt-tool mcp__pendnt__permission_prompt --mcp-config mcp.json`
(sample `mcp.json` included — HTTP transport, Bearer header from `$PENDNT_API_KEY`),
plus a curl-to-`/v1/notify` fallback on exit for environments where the Claude Code
plugin's `Stop` hook isn't installed.

## Also see

- `/root/work/app/README.md` — the full REST + MCP API reference these examples all
  target.
- `/root/work/plugin/` — the maintained Claude Code plugin (MCP config +
  `PermissionRequest`/`Notification`/`Stop` hooks bundled together, installable via
  `/plugin install`), which `cron-claude-code/` and the SDK examples' `canUseTool`
  patterns are hand-rolled, lighter-weight cousins of.
- `/root/product/INTEGRATIONS.md` — the research doc behind the mechanics referenced
  throughout these examples (`--permission-prompt-tool`, hooks, the Agent SDK's
  `canUseTool`, OpenClaw skills/cron, and the MCP transport itself).

## License

MIT — see [`LICENSE`](LICENSE).

## Guides

Practical writeups on running agents unattended, at [pendnt.dev/guides](https://pendnt.dev/guides/):
[--dangerously-skip-permissions alternatives](https://pendnt.dev/guides/dangerously-skip-permissions) ·
[claude -p on cron](https://pendnt.dev/guides/claude-p-cron) ·
[the --permission-prompt-tool contract](https://pendnt.dev/guides/permission-prompt-tool) ·
[hooks for unattended runs](https://pendnt.dev/guides/claude-code-hooks) ·
[exit codes: retry vs stay dead](https://pendnt.dev/guides/agent-exit-codes)
