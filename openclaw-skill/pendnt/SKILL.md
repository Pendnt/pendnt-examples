---
name: pendnt
description: Ask a human for approval, send a notification, wait for an inbound webhook event, or schedule a wake-up, via the pendnt hosted API — the one way a cron/isolated OpenClaw session (where ask_user is unavailable) can still get a human in the loop.
version: 0.1.0
user-invocable: true
metadata:
  openclaw:
    requires:
      env: [PENDNT_API_KEY]
      bins: [curl, jq]
      config: []
---

# pendnt

[pendnt](https://pendnt.dev) is a hosted service that gives an agent durable I/O it
doesn't otherwise have: human approvals that can be answered from a phone hours or
days later, fire-and-forget notifications, inbound webhook endpoints, and scheduled
wake-ups. This skill exists specifically for the case OpenClaw's own docs call out:
**`ask_user` is documented as main-session-only — a cron'd or `--session isolated` job
cannot block on a human through it** (see `/root/product/INTEGRATIONS.md` §3). When
you're running as a cron job and need a human decision, notification, or a way to
resume later, use this skill instead of `ask_user`.

## When to use this

- You're in a scheduled/cron/isolated session (no interactive human attached) and you
  need to **pause for a yes/no or free-text decision** before continuing (e.g. "should
  I actually delete this?", "which of these two candidates should I merge?").
- You want to **notify** a human of something without blocking (a run finished, an
  error occurred, a threshold was crossed).
- You need an **inbound webhook URL** to hand to a third party (GitHub, Stripe, an
  OAuth callback) and a way to check what arrived on it.
- You want to **schedule a wake-up** so a future cron tick (or a long poll) can pick up
  where you left off.

## How to call it

Two paths, depending on what this OpenClaw runtime supports — check whether remote MCP
servers are configured/available to you before picking one:

### Path A — hosted MCP server (preferred, if this runtime supports remote MCP)

pendnt exposes all of its operations as MCP tools at `https://api.pendnt.dev/mcp`
(Streamable HTTP, `Authorization: Bearer $PENDNT_API_KEY`). If your OpenClaw
configuration has this server wired up (see `mcp.example.json` in this skill directory
for the shape — `transport: streamable-http`, `headers`), call its tools directly:
`request_approval`, `check_request`, `notify`, `create_endpoint`, `list_endpoints`,
`wait_for_event`, `schedule_wakeup`, `list_wakeups`, `cancel_wakeup`, `kv_get`,
`kv_set`, `kv_delete`, `whoami`. See `/root/work/app/README.md`'s "Tools" table for
each one's exact input/output shape — they mirror the REST routes below 1:1.

### Path B — REST via `exec` (curl), always available

If remote MCP isn't wired up in this runtime, or you're not sure, fall back to the
`scripts/pendnt.sh` helper in this skill directory via your `exec` tool. It wraps the
same REST API with `curl`/`jq` (this skill's `requires.bins`):

```bash
scripts/pendnt.sh approve "<title>" ["<details>"] [timeout_s]   # -> exit 0/1/2, prints the final request JSON
scripts/pendnt.sh notify "<message>" [info|warning|error]        # fire-and-forget
scripts/pendnt.sh wait-event [endpoint_id] [since_seq] [wait_s]  # one long-poll call, prints events JSON
scripts/pendnt.sh wakeup <in_seconds> ['<json payload>']         # schedules a wakeup
scripts/pendnt.sh check <request_id>                             # re-check a request without waiting
```

Or call the REST API directly with `curl` if you'd rather not go through the script —
see `/root/work/app/README.md`'s "API reference" for the full shape of every route.
The core ones this skill uses:

- `POST /v1/requests` — create an approval/question (`{kind, title, details, timeout_s, wait_s}`).
- `GET /v1/requests/:id?wait_s=N` — poll a request (`wait_s` clamped to 0–25s per call server-side).
- `POST /v1/notify` — fire-and-forget notification.
- `GET /v1/events?endpoint_id=&since_seq=&wait_s=` — poll for inbound webhook/wakeup events.
- `POST /v1/wakeups` — schedule a wake-up (`{in_s` or `at`, `payload?}`).

## The cron pattern: `request_approval` without blocking the whole job

A cron job typically has a bounded timeout (OpenClaw's default is 60 minutes per
run — see `/root/product/INTEGRATIONS.md` §3). Don't just call `approve` and block for
longer than that. Two patterns, pick based on how long you expect the human to take:

1. **Short wait, same run** (you expect an answer within minutes): call
   `scripts/pendnt.sh approve "<title>" "<details>" <timeout_s>` with a `timeout_s`
   comfortably under your cron job's own timeout. It blocks internally via repeated
   25-second long-polls (the server clamps `wait_s` to 0–25 regardless of what you
   send) until answered or `timeout_s` elapses, then exits `0` (approved), `1`
   (denied/answered-no), or `2` (still pending — you decide what "no answer" means for
   your task, e.g. skip the risky step).

2. **Long wait, separate run** (hours/days — a human might not see it for a while):
   call `POST /v1/requests` with `wait_s: 0` (returns immediately with the request id,
   don't block), remember the returned `id` (e.g. via `kv_set`/`scripts/pendnt.sh` or
   whatever this agent's own state mechanism is), and end the run. Schedule a
   **separate** cron tick (or a `schedule_wakeup` call) to come back later and check
   `GET /v1/requests/:id?wait_s=25` (or `scripts/pendnt.sh check <id>`) — this is
   pendnt's own "poll-by-id" recipe, not something OpenClaw's docs spell out, but it's
   the natural fit for `ask_user`-unavailable cron sessions per
   `/root/product/INTEGRATIONS.md` §3.

Either way: **fail closed**. If `PENDNT_API_KEY` is unset, the API call errors, or the
request times out still pending, treat that as "not approved" — do not proceed with a
risky action just because you couldn't reach a human. `scripts/pendnt.sh approve`
already encodes this (non-zero exit on anything but a clear approval).

## Secrets

This skill requires `PENDNT_API_KEY` (an `aio_...` token from
[pendnt.dev](https://pendnt.dev) or `POST /dev/bootstrap` against a local `wrangler
dev`, see `/root/work/app/README.md`) as an environment variable — declared in this
skill's frontmatter under `metadata.openclaw.requires.env`. In `openclaw.json`, wire it
via the `SecretRef` indirection form rather than a literal value
(`/root/product/INTEGRATIONS.md` §3):

```json
{
  "skills": {
    "entries": {
      "pendnt": {
        "apiKey": { "source": "env", "provider": "default", "id": "PENDNT_API_KEY" }
      }
    }
  }
}
```

(Host-process runs only — a Docker sandbox needs `sandbox.docker.env` instead per the
same doc section.) `PENDNT_URL` is optional (defaults to `https://api.pendnt.dev`;
point it at `http://localhost:8787` for local dev against `wrangler dev`).

## Before publishing this to ClawHub

This skill has **not** been published — do not run `clawhub skill publish` against it
without doing the following first (`/root/product/INTEGRATIONS.md` §3):

- **Pick a real slug and owner** — `clawhub skill publish ./pendnt --slug
  <your-slug> --owner <owner> --categories automation,agents` (max 3 categories from
  ClawHub's fixed list, max 5 free-form topics). `pendnt` alone may already be taken;
  don't assume it.
- **Confirm the version** — new skills start at `1.0.0` per ClawHub convention; this
  directory's frontmatter says `0.1.0` deliberately, as a pre-publish placeholder.
- **Expect automated security review** — ClawHub runs one before the skill is visible
  in the install surface; a skill whose only external call is `curl` to a fixed host
  (`api.pendnt.dev`) plus one required secret should be a straightforward review, but
  budget time for it.
- **Re-verify the MCP path (§ Path A above)** against whatever MCP-serving mechanism
  the OpenClaw runtime you're publishing for actually supports — this doc describes
  the REST fallback (Path B) as always-available and the MCP path as conditional
  because remote-MCP support in OpenClaw skills wasn't independently confirmed at the
  time this example was written; test it against a real install before telling users
  to rely on it.
- **Decide on `sandbox.docker.env` guidance** if you expect this skill to run inside a
  Docker-sandboxed OpenClaw agent rather than the host process — the `SecretRef`
  shape above is documented for host-process runs only.
- **Read `/root/work/app/README.md`'s "Plan limits" section** before recommending this
  skill for high-frequency cron use — the Free plan caps at 100 requests+notifications/
  month; a tight polling loop across many cron ticks can burn through that fast.
