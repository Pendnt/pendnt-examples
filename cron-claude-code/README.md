# pendnt + Claude Code on a cron schedule

A headless `claude -p` invocation, wired to pendnt for permission prompts via
`--permission-prompt-tool`, run from cron, with a curl-based "run finished/failed"
notification that doesn't depend on the Claude Code plugin's `Stop` hook being
installed in the cron environment.

## Files

- **`mcp.json`** — the exact `.mcp.json` shape from `/root/work/app/README.md`'s
  "Client config snippets" and `/root/work/plugin/.mcp.json`: an HTTP-transport MCP
  server pointed at pendnt, with the Bearer token coming from `$PENDNT_API_KEY` via
  Claude Code's own `${VAR}` env expansion in config files
  (`/root/product/INTEGRATIONS.md` §1e).
- **`run.sh`** — the wrapper: runs `claude -p "<task>" --mcp-config mcp.json
  --permission-prompt-tool mcp__pendnt__permission_prompt`, then — regardless of how
  that exits — `curl`s `POST /v1/notify` with a pass/fail summary. Also exports
  `MCP_TOOL_TIMEOUT` (default `600000`ms) if not already set — see below for why.
- **`crontab.example`** — two example crontab lines using `run.sh`, each wrapped in
  `flock -n /tmp/pendnt-job.lock` (see "Install on cron" below for why).

## Setup

```bash
export PENDNT_API_KEY=aio_...
export PENDNT_URL=https://api.pendnt.dev   # optional, this is the default
```

Get a key at [pendnt.dev](https://pendnt.dev), or locally against `wrangler dev` (see
`/root/work/app/README.md`).

## Run once, by hand

```bash
./run.sh "review open PRs and merge the ones that pass CI"
```

Whenever `claude` hits a tool-use permission prompt, it calls the `permission_prompt`
MCP tool this repo's `mcp.json` wires up — that creates a durable pendnt approval
request (answerable from `https://pendnt.dev/dashboard`, or a configured email/
Telegram channel), blocks server-side until it's answered, and returns Claude Code's
exact `{behavior, updatedInput}`/`{behavior:"deny", message}` contract, instead of
blocking on a terminal that doesn't exist. Things worth knowing before relying on
`--permission-prompt-tool mcp__pendnt__permission_prompt` specifically (from
`/root/product/INTEGRATIONS.md` §1a, also covered in `/root/work/plugin/README.md`):

- Claude Code blocks the first turn until the `pendnt` MCP server connects, capped by
  `MCP_TIMEOUT` (default 30000ms) — bump it (`export MCP_TIMEOUT=60000`) if your
  network is slow.
- `permission_prompt` waits server-side for up to `PERMISSION_PROMPT_WAIT_S` seconds
  (env var on the pendnt server, default 540 = 9 min) for the operator to answer —
  much longer than Claude Code's default per-tool-call timeout. **`run.sh` sets
  `MCP_TOOL_TIMEOUT=600000` (10 min) for exactly this reason** — set your own higher
  value if you configure a longer `PERMISSION_PROMPT_WAIT_S` on the server, or the CLI
  will time out the call before `permission_prompt` gets to return its own
  deny-by-timeout response.

## Install on cron

```bash
crontab -e
# paste a line from crontab.example, editing the path/task/env as needed
```

**cron runs with a minimal environment** — `PENDNT_API_KEY` won't be inherited from
your interactive shell. `crontab.example` sets it inline on the crontab line itself;
alternatively, source a file with `export PENDNT_API_KEY=...` at the top of `run.sh`,
or set it in `/etc/environment` / a systemd-timer `Environment=` line if you're using
systemd timers instead of cron.

**Each `crontab.example` line is also wrapped in `flock -n /tmp/pendnt-job.lock`.** A
run that's still blocked waiting on an operator's `permission_prompt` answer holds its
cron slot — it doesn't free it up just because cron thinks the tick is "due" again —
so without the lock a slow approval on a `*/15 * * * *` job could pile up a second
`claude -p` invocation on top of a still-running one; `-n` makes the newer tick skip
instead of queueing.

## The "Stop-hook-free fallback"

`/root/work/plugin`'s Claude Code plugin wires a `Stop` hook
(`hooks/stop.mjs`) that `POST`s `/v1/notify` automatically at the end of every turn —
but that only fires if the plugin is installed in whatever Claude Code
config/`settings.json` the cron job's `claude` invocation picks up, which a bare cron
environment might not have. `run.sh` doesn't assume the plugin is present: it does the
equivalent itself with one plain `curl -X POST $BASE/v1/notify` after the `claude`
process exits, using `$?` to report success/failure — belt-and-suspenders if you *do*
have the plugin installed too (you'd get two notifications), and a full substitute if
you don't. Set `-e` is deliberately **not** used in `run.sh` so this fallback still
runs even when `claude` itself exits non-zero or crashes.

## Notes

- `run.sh` uses `claude -p ... --output-format text` for simplicity; switch to
  `--output-format stream-json` if you want to parse the run's messages
  programmatically instead of just logging text (see
  `/root/product/INTEGRATIONS.md` §1c for other useful `-p` flags: `--max-turns`,
  `--max-budget-usd`, `--resume <session-id>`).
- For approvals you expect might take longer than your cron job's own timeout to
  answer, consider the plugin's `defer`-based `PreToolUse` hook path instead (see
  `/root/work/plugin/README.md` and `/root/product/INTEGRATIONS.md` §1b) — this
  example's `--permission-prompt-tool` path holds the MCP tool call open rather than
  suspending the whole process.
