#!/usr/bin/env bash
# notify.sh — fire-and-forget notification via pendnt.
#
# Usage:
#   ./notify.sh "build finished" [info|warning|error]
#
# Wraps POST /v1/notify (see /root/work/app/README.md's "API reference" → "Requests"):
# creates a kind:"notification" request that's immediately status:"answered" and
# enqueues delivery to every verified channel on the workspace. Always exits 0 on a
# successful call (2xx); non-zero on a transport/API error.

set -euo pipefail

MESSAGE="${1:?usage: notify.sh <message> [level]}"
LEVEL="${2:-info}"

: "${PENDNT_API_KEY:?PENDNT_API_KEY is not set}"
BASE="${PENDNT_URL:-https://api.pendnt.dev}"
BASE="${BASE%/}"

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

BODY=$(jq -n --arg message "$MESSAGE" --arg level "$LEVEL" '{message: $message, level: $level}')

RESP=$(curl -sS -w '\n%{http_code}' -X POST "$BASE/v1/notify" \
  -H "authorization: Bearer $PENDNT_API_KEY" \
  -H "content-type: application/json" \
  -d "$BODY")

HTTP_CODE=$(echo "$RESP" | tail -n1)
JSON=$(echo "$RESP" | sed '$d')

echo "$JSON" | jq . 2>/dev/null || echo "$JSON"

if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
  echo "error: POST /v1/notify failed with HTTP $HTTP_CODE" >&2
  exit 1
fi

HINT=$(echo "$JSON" | jq -r '.hint // empty' 2>/dev/null || true)
[[ -n "$HINT" ]] && echo "hint: $HINT" >&2

exit 0
