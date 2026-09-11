#!/usr/bin/env bash
# inbox.sh — create an inbound webhook endpoint, print its public URL, then wait for
# events to arrive on it (long-polling GET /v1/events).
#
# Usage:
#   ./inbox.sh [name]
#
# Point any third-party webhook sender (GitHub, Stripe, an OAuth callback, ...) at the
# printed URL, then watch this script print each event as it arrives. Ctrl-C to stop.
#
# See /root/work/app/README.md's "API reference" → "Endpoints (inbound webhooks)" and
# "Events": POST /v1/endpoints, ANY /in/:slug (no API key, that's the point), and
# GET /v1/events?endpoint_id=&since_seq=0&wait_s=N (long-poll, clamped to 0-25s/call).

set -euo pipefail

NAME="${1:-inbox-example}"

: "${PENDNT_API_KEY:?PENDNT_API_KEY is not set}"
BASE="${PENDNT_URL:-https://api.pendnt.dev}"
BASE="${BASE%/}"

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

BODY=$(jq -n --arg name "$NAME" '{name: $name}')

EP=$(curl -sS -X POST "$BASE/v1/endpoints" \
  -H "authorization: Bearer $PENDNT_API_KEY" \
  -H "content-type: application/json" \
  -d "$BODY")

ENDPOINT_ID=$(echo "$EP" | jq -r '.id // empty')
if [[ -z "$ENDPOINT_ID" ]]; then
  echo "error: failed to create endpoint: $EP" >&2
  exit 1
fi
URL=$(echo "$EP" | jq -r '.url')

echo "endpoint created:"
echo "$EP" | jq .
echo ""
echo "send anything to this URL and it'll show up below:"
echo "  $URL"
echo ""
echo "waiting for events... (Ctrl-C to stop)"

SINCE_SEQ=0
while true; do
  RESP=$(curl -sS "$BASE/v1/events?endpoint_id=$ENDPOINT_ID&since_seq=$SINCE_SEQ&wait_s=25" \
    -H "authorization: Bearer $PENDNT_API_KEY")

  COUNT=$(echo "$RESP" | jq '.events | length')
  if [[ "$COUNT" -gt 0 ]]; then
    echo "$RESP" | jq -c '.events[]' | while IFS= read -r event; do
      echo "--- event ---"
      echo "$event" | jq .
    done
    # Advance the seq floor past every event we just saw so the next long-poll only
    # returns events newer than these.
    NEW_SEQ=$(echo "$RESP" | jq '[.events[].seq] | max')
    SINCE_SEQ="$NEW_SEQ"
  fi
  # No sleep needed: with wait_s=25 the server itself blocks up to 25s when there's
  # nothing new, so this loop is a long-poll, not a busy-poll.
done
