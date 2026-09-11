# pendnt + curl

Four small, dependency-light (`bash` + `curl` + `jq`) scripts against the pendnt REST API
(`https://api.pendnt.dev`, or a local `wrangler dev` at `http://localhost:8787`). No SDKs,
no MCP — just the raw HTTP endpoints documented in `/app/README.md`'s "API reference".
Good starting point for wiring pendnt into anything that can shell out to `curl` — CI
jobs, cron, any language without an SDK yet.

## Requirements

- `bash`, `curl`, `jq` (each script checks for these and fails fast with a clear message
  if missing).
- A pendnt API key. Get one at [pendnt.dev](https://pendnt.dev) (signup → magic link →
  dashboard shows your key once), or locally against `wrangler dev`:
  ```bash
  curl -s -X POST http://localhost:8787/dev/bootstrap -d '{}' | jq -r .api_key
  ```

## Env vars

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `PENDNT_API_KEY` | yes | — | `Authorization: Bearer <key>` for every call. |
| `PENDNT_URL` | no | `https://api.pendnt.dev` | REST API base URL (no trailing slash, no `/mcp`). Point at `http://localhost:8787` for local dev. |
| `PENDNT_TIMEOUT_S` | no | `600` | `approve.sh` only — total wall-clock budget to wait for an answer before giving up (exit 1). |

```bash
export PENDNT_API_KEY=aio_...
export PENDNT_URL=https://api.pendnt.dev   # or http://localhost:8787 locally
```

## Scripts

### `approve.sh` — create an approval and block until answered

```bash
./approve.sh "Deploy to prod?" "release v1.2.3"
echo "exit code: $?"   # 0 = approved, 1 = denied/expired/cancelled/timed out
```

`POST /v1/requests` with `kind: "approval"`, then long-polls `GET
/v1/requests/:id?wait_s=25` in a loop (the server clamps `wait_s` to 0–25 seconds per
call, so a longer wait is just more polls) until the request resolves or
`PENDNT_TIMEOUT_S` (default 600s) elapses. Prints the final request row as JSON and
exits `0` for `approved` (or a free-text answer starting with yes/y/allow/approve/ok —
the operator answer page always shows a free-text box, even for approval-kind
requests), `1` for anything else. Use this as the guard in a shell pipeline:

```bash
if ./approve.sh "Delete the staging DB?"; then
  ./actually-delete-staging-db.sh
else
  echo "not approved, skipping" >&2
fi
```

### `notify.sh` — fire-and-forget notification

```bash
./notify.sh "nightly build finished" info
./notify.sh "disk usage over 90%" warning
```

`POST /v1/notify` — creates a `kind: "notification"` request that's immediately
`status: "answered"` and pushed to every verified channel on the workspace. Doesn't
block; exits 0 on any 2xx response.

### `inbox.sh` — create an inbound webhook endpoint and watch it

```bash
./inbox.sh gh-webhook
```

`POST /v1/endpoints` to create a fresh `https://api.pendnt.dev/in/<slug>` URL, prints
it, then long-polls `GET /v1/events?endpoint_id=...&wait_s=25` in a loop and prints each
event as it arrives. Point any webhook sender (GitHub, Stripe, a manual `curl -X POST
<printed-url> -d '{"hello":"world"}'`) at the printed URL from another terminal.
Ctrl-C to stop.

### `wakeup.sh` — schedule a wakeup, optionally wait for it to fire

```bash
./wakeup.sh 60                                   # fire in 60s, don't wait
./wakeup.sh 60 '{"check":"status"}' --wait       # fire in 60s, block until it does
```

`POST /v1/wakeups` (`in_s` + optional JSON `payload`), then with `--wait`, long-polls
`GET /v1/events` looking for the matching `kind: "wakeup"` event
(`payload.wakeup_id == <id>`).

## Notes

- Every script uses `jq -n --arg`/`--argjson` to build request bodies, never raw shell
  string interpolation into JSON — safe against special characters in titles/messages.
- Long-polls use `wait_s=25` per call (the server-enforced max) and loop rather than
  requesting one giant wait — this matches how `/app/README.md` describes `wait_s`
  being clamped everywhere it's accepted.
- These scripts talk to the API directly. If you want pendnt wired into an actual
  Claude Code session's permission prompts, see `../../plugin` (the Claude Code
  plugin) or `../cron-claude-code` (a `claude -p` + MCP config example) instead.
