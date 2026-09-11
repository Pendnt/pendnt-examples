#!/usr/bin/env bash
# wakeup.sh — schedule a pendnt wakeup and (optionally) wait for it to fire.
#
# Usage:
#   ./wakeup.sh <in_seconds> ['{"json":"payload"}'] [--wait]
#
# Examples:
#   ./wakeup.sh 60                          # schedule, print the wakeup row, exit
#   ./wakeup.sh 60 '{"check":"status"}' --wait   # schedule and block until it fires
#
# See /root/work/app/README.md's "API reference" → "Wakeups": POST /v1/wakeups
# ({"in_s"|"at", "payload"?}), and "Events": when a wakeup fires, a kind:"wakeup"
# event is written and visible via GET /v1/events (long-poll, clamped to 0-25s/call).

set -euo pipefail

IN_S="${1:?usage: wakeup.sh <in_seconds> [payload_json] [--wait]}"
PAYLOAD_ARG="${2:-{\}}"
WAIT_FLAG="${3:-}"

: "${PENDNT_API_KEY:?PENDNT_API_KEY is not set}"
BASE="${PENDNT_URL:-https://api.pendnt.dev}"
BASE="${BASE%/}"

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# Validate the payload arg is actually JSON before sending it on.
echo "$PAYLOAD_ARG" | jq . >/dev/null || { echo "error: payload must be valid JSON" >&2; exit 1; }

BODY=$(jq -n --argjson in_s "$IN_S" --argjson payload "$PAYLOAD_ARG" '{in_s: $in_s, payload: $payload}')

CREATED=$(curl -sS -X POST "$BASE/v1/wakeups" \
  -H "authorization: Bearer $PENDNT_API_KEY" \
  -H "content-type: application/json" \
  -d "$BODY")

WAKEUP_ID=$(echo "$CREATED" | jq -r '.id // empty')
if [[ -z "$WAKEUP_ID" ]]; then
  echo "error: failed to schedule wakeup: $CREATED" >&2
  exit 1
fi

echo "wakeup scheduled:"
echo "$CREATED" | jq .

if [[ "$WAIT_FLAG" != "--wait" ]]; then
  exit 0
fi

echo "" >&2
echo "waiting for it to fire (long-polling /v1/events)..." >&2

SINCE_SEQ=0
DEADLINE_S=$((IN_S + 60)) # a little slack past the scheduled fire time
START=$(date +%s)

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  if (( ELAPSED >= DEADLINE_S )); then
    echo "error: wakeup did not fire within ${DEADLINE_S}s" >&2
    exit 1
  fi

  RESP=$(curl -sS "$BASE/v1/events?since_seq=$SINCE_SEQ&wait_s=25" \
    -H "authorization: Bearer $PENDNT_API_KEY")

  # Look for a kind:"wakeup" event whose payload.wakeup_id matches ours.
  MATCH=$(echo "$RESP" | jq -c --arg wid "$WAKEUP_ID" \
    '[.events[] | select(.kind == "wakeup" and .payload.wakeup_id == $wid)] | first // empty')

  if [[ -n "$MATCH" ]]; then
    echo "wakeup fired:"
    echo "$MATCH" | jq .
    exit 0
  fi

  COUNT=$(echo "$RESP" | jq '.events | length')
  if [[ "$COUNT" -gt 0 ]]; then
    NEW_SEQ=$(echo "$RESP" | jq '[.events[].seq] | max')
    SINCE_SEQ="$NEW_SEQ"
  fi
done
