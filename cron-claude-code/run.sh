#!/usr/bin/env bash
# run.sh — cron wrapper around `claude -p` wired to pendnt for headless permission
# prompts, with a curl-to-/v1/notify fallback for "the run finished" that doesn't
# depend on Claude Code's own Stop hook (useful if you're not running the
# /root/work/plugin plugin in this cron environment, or just want a guaranteed
# notification regardless of how the claude process exits — killed, crashed, etc.).
#
# Usage (see crontab.example for wiring this into cron itself):
#   PENDNT_API_KEY=aio_... ./run.sh "review open PRs and merge the ones that pass CI"
#
# Env:
#   PENDNT_API_KEY   required — see /root/work/app/README.md for how to get one.
#   PENDNT_URL        optional — REST/MCP API base URL, default https://api.pendnt.dev.
#                      mcp.json's ${PENDNT_URL:-https://api.pendnt.dev} expansion and
#                      this script's own $BASE both read the same env var.
#   MCP_TIMEOUT        optional — passed through to `claude`; bump this (milliseconds)
#                      if your network is slow to connect to the pendnt MCP server —
#                      Claude Code blocks the first turn on that connection, capped by
#                      MCP_TIMEOUT (default 30000ms). See /root/product/INTEGRATIONS.md §1a.
#   MCP_TOOL_TIMEOUT   optional but important — passed through to `claude`; this is its
#                      per-tool-call timeout (milliseconds), and it must exceed how long
#                      the pendnt server's permission_prompt tool waits for an operator
#                      answer (PERMISSION_PROMPT_WAIT_S on the server, default 540s), or
#                      the CLI gives up on the call before permission_prompt itself
#                      returns its deny-by-timeout response. This script sets it to
#                      600000 (10 min) below if you haven't already exported one.
#
# Note: this script does NOT lock against overlapping invocations itself — a run
# that's still blocked on an operator's permission_prompt answer holds its cron slot,
# so crontab.example wraps each crontab line in `flock -n /tmp/pendnt-job.lock` so the
# next tick skips instead of piling another `claude -p` on top of a still-running one.

set -uo pipefail  # deliberately not -e: we want the notify-on-exit fallback to run
                   # even if `claude` itself exits non-zero.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK="${1:?usage: run.sh \"<task prompt>\"}"

: "${PENDNT_API_KEY:?PENDNT_API_KEY is not set}"
BASE="${PENDNT_URL:-https://api.pendnt.dev}"
BASE="${BASE%/}"
export MCP_TOOL_TIMEOUT="${MCP_TOOL_TIMEOUT:-600000}"  # see the env-var note above

# --- the actual headless run ---------------------------------------------------
claude -p "$TASK" \
  --mcp-config "$SCRIPT_DIR/mcp.json" \
  --permission-prompt-tool mcp__pendnt__permission_prompt \
  --output-format text
CLAUDE_EXIT=$?

# --- Stop-hook-free notify-on-exit fallback -------------------------------------
# The Claude Code plugin in /root/work/plugin wires a Stop hook that POSTs
# /v1/notify automatically at the end of every turn (see hooks/stop.mjs there). This
# wrapper doesn't assume that plugin is installed in the cron environment it runs in,
# so it does the equivalent itself with a plain curl call — belt-and-suspenders if you
# *do* have the plugin installed too, and a full substitute if you don't.
if [[ $CLAUDE_EXIT -eq 0 ]]; then
  MESSAGE="cron run finished: ${TASK:0:200}"
  LEVEL="info"
else
  MESSAGE="cron run FAILED (exit $CLAUDE_EXIT): ${TASK:0:200}"
  LEVEL="error"
fi

curl -sS -X POST "$BASE/v1/notify" \
  -H "authorization: Bearer $PENDNT_API_KEY" \
  -H "content-type: application/json" \
  -d "$(jq -n --arg message "$MESSAGE" --arg level "$LEVEL" '{message: $message, level: $level}')" \
  >/dev/null || echo "warning: failed to notify pendnt of run completion" >&2

exit $CLAUDE_EXIT
