#!/usr/bin/env bash
# approve.sh — create a pendnt approval request and block until a human answers it.
#
# Usage:
#   ./approve.sh "Deploy to prod?" ["release v1.2.3 details go here"]
#
# Exit code: 0 if approved, 1 if denied/expired/cancelled/timed out/errored.
# Prints the final request JSON (from GET /v1/requests/:id) to stdout.
#
# Env:
#   PENDNT_API_KEY        required — Bearer token (aio_...)
#   PENDNT_URL             optional — REST API base URL, default https://api.pendnt.dev
#   PENDNT_TIMEOUT_S        optional — total wall-clock budget to wait for an answer, default 600 (10 min)
#
# See /root/work/app/README.md's "API reference" and "curl walkthrough" for the exact
# request/response shapes this script relies on: POST /v1/requests and
# GET /v1/requests/:id?wait_s=N (long-poll, clamped server-side to 0-25s per call).

set -euo pipefail

TITLE="${1:?usage: approve.sh <title> [details]}"
DETAILS="${2:-}"

: "${PENDNT_API_KEY:?PENDNT_API_KEY is not set — get one from https://pendnt.dev or POST /dev/bootstrap locally}"
BASE="${PENDNT_URL:-https://api.pendnt.dev}"
BASE="${BASE%/}"
TOTAL_TIMEOUT_S="${PENDNT_TIMEOUT_S:-600}"
POLL_WAIT_S=25 # server clamps wait_s to 0-25 regardless of what's sent

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need curl
need jq

# jq -n with --arg keeps title/details as plain strings, JSON-escaped safely (no shell
# interpolation into the JSON body).
BODY=$(jq -n --arg title "$TITLE" --arg details "$DETAILS" --arg timeout "86400" \
  '{kind: "approval", title: $title, details: $details, timeout_s: ($timeout | tonumber)}')

echo "creating approval request..." >&2
CREATED=$(curl -sS -X POST "$BASE/v1/requests" \
  -H "authorization: Bearer $PENDNT_API_KEY" \
  -H "content-type: application/json" \
  -d "$BODY")

ID=$(echo "$CREATED" | jq -r '.id // empty')
if [[ -z "$ID" ]]; then
  echo "error: failed to create request: $CREATED" >&2
  exit 1
fi
HINT=$(echo "$CREATED" | jq -r '.hint // empty')
[[ -n "$HINT" ]] && echo "hint: $HINT" >&2
echo "request id: $ID  (answer at $BASE/dashboard, or via a configured channel)" >&2

STATUS=$(echo "$CREATED" | jq -r '.status')
ROW="$CREATED"
START=$(date +%s)

while [[ "$STATUS" == "pending" ]]; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  if (( ELAPSED >= TOTAL_TIMEOUT_S )); then
    echo "error: timed out after ${TOTAL_TIMEOUT_S}s waiting for an answer" >&2
    exit 1
  fi
  REMAINING=$((TOTAL_TIMEOUT_S - ELAPSED))
  WAIT_S=$POLL_WAIT_S
  (( REMAINING < WAIT_S )) && WAIT_S=$REMAINING
  (( WAIT_S < 1 )) && WAIT_S=1

  ROW=$(curl -sS "$BASE/v1/requests/$ID?wait_s=$WAIT_S" \
    -H "authorization: Bearer $PENDNT_API_KEY")
  STATUS=$(echo "$ROW" | jq -r '.status // "pending"')
done

echo "$ROW" | jq .

case "$STATUS" in
  approved)
    exit 0
    ;;
  answered)
    # kind:"approval" requests are only ever approved/denied by the answer page's
    # buttons, but the free-text box is always shown too — treat a yes/allow/approve
    # style free-text answer as approval, same convention as the plugin's
    # PermissionRequest hook (see /root/work/plugin/hooks/permission-request.mjs).
    ANSWER=$(echo "$ROW" | jq -r '.answer // ""' | tr '[:upper:]' '[:lower:]')
    if [[ "$ANSWER" =~ ^(yes|y|allow|approve|approved|ok|okay)\b ]]; then
      exit 0
    fi
    exit 1
    ;;
  denied|expired|cancelled)
    exit 1
    ;;
  *)
    echo "error: unexpected status '$STATUS'" >&2
    exit 1
    ;;
esac
