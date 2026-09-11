#!/usr/bin/env bash
# scripts/pendnt.sh — single helper the pendnt OpenClaw skill's SKILL.md tells the
# agent to invoke (via its exec/shell tool) for every pendnt operation. Consolidates
# what examples/curl/*.sh do into one script with subcommands, since OpenClaw skills
# gate on `requires.bins` (here: curl, jq) rather than declaring individual HTTP calls
# as a primitive — see /root/product/INTEGRATIONS.md §3.
#
# Usage:
#   pendnt.sh approve <title> [details] [timeout_s]
#   pendnt.sh notify <message> [level]
#   pendnt.sh wait-event [endpoint_id] [since_seq] [wait_s]
#   pendnt.sh wakeup <in_seconds> [payload_json]
#   pendnt.sh check <request_id>
#
# Env:
#   PENDNT_API_KEY   required — Bearer token. In a real OpenClaw config this is
#                    injected via openclaw.json's SecretRef indirection (see
#                    ../SKILL.md's "Secrets" section) rather than a literal value in
#                    config — from the skill's point of view it's still just an env var.
#   PENDNT_URL        optional — REST API base URL, default https://api.pendnt.dev
#
# Every subcommand prints one JSON object to stdout and exits 0 on success. `approve`
# additionally exits 1 if the request resolves to anything other than approved (so it
# can gate a following command the way examples/curl/approve.sh does), and 2 if it
# times out still pending.

set -euo pipefail

: "${PENDNT_API_KEY:?PENDNT_API_KEY is not set}"
BASE="${PENDNT_URL:-https://api.pendnt.dev}"
BASE="${BASE%/}"
POLL_WAIT_S=25 # server clamps wait_s to 0-25 regardless of what's sent

command -v curl >/dev/null 2>&1 || { echo '{"error":"curl is required"}' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo '{"error":"jq is required"}' >&2; exit 1; }

api() { # method path [body]
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$BASE$path" -H "authorization: Bearer $PENDNT_API_KEY" -H "content-type: application/json" -d "$body"
  else
    curl -sS -X "$method" "$BASE$path" -H "authorization: Bearer $PENDNT_API_KEY"
  fi
}

cmd_approve() {
  local title="${1:?usage: pendnt.sh approve <title> [details] [timeout_s]}"
  local details="${2:-}"
  local timeout_s="${3:-86400}"

  local body created id status row start now elapsed remaining wait_s
  body=$(jq -n --arg title "$title" --arg details "$details" --argjson timeout "$timeout_s" \
    '{kind: "approval", title: $title, details: $details, timeout_s: $timeout, wait_s: 25}')
  created=$(api POST /v1/requests "$body")
  id=$(echo "$created" | jq -r '.id // empty')
  [[ -z "$id" ]] && { echo "$created" >&2; exit 1; }

  row="$created"
  status=$(echo "$row" | jq -r '.status')
  start=$(date +%s)
  while [[ "$status" == "pending" ]]; do
    now=$(date +%s); elapsed=$((now - start))
    if (( elapsed >= timeout_s )); then
      echo "$row" | jq .
      exit 2
    fi
    remaining=$((timeout_s - elapsed)); wait_s=$POLL_WAIT_S
    (( remaining < wait_s )) && wait_s=$remaining
    (( wait_s < 1 )) && wait_s=1
    row=$(api GET "/v1/requests/$id?wait_s=$wait_s")
    status=$(echo "$row" | jq -r '.status // "pending"')
  done

  echo "$row" | jq .
  case "$status" in
    approved) exit 0 ;;
    answered)
      local answer
      answer=$(echo "$row" | jq -r '.answer // ""' | tr '[:upper:]' '[:lower:]')
      [[ "$answer" =~ ^(yes|y|allow|approve|approved|ok|okay)\b ]] && exit 0
      exit 1 ;;
    *) exit 1 ;;
  esac
}

cmd_notify() {
  local message="${1:?usage: pendnt.sh notify <message> [level]}"
  local level="${2:-info}"
  local body
  body=$(jq -n --arg message "$message" --arg level "$level" '{message: $message, level: $level}')
  api POST /v1/notify "$body" | jq .
}

cmd_wait_event() {
  local endpoint_id="${1:-}"
  local since_seq="${2:-0}"
  local wait_s="${3:-25}"
  local qs="since_seq=$since_seq&wait_s=$wait_s"
  [[ -n "$endpoint_id" ]] && qs="endpoint_id=$endpoint_id&$qs"
  api GET "/v1/events?$qs" | jq .
}

cmd_wakeup() {
  local in_s="${1:?usage: pendnt.sh wakeup <in_seconds> [payload_json]}"
  local payload="${2:-{\}}"
  echo "$payload" | jq . >/dev/null
  local body
  body=$(jq -n --argjson in_s "$in_s" --argjson payload "$payload" '{in_s: $in_s, payload: $payload}')
  api POST /v1/wakeups "$body" | jq .
}

cmd_check() {
  local id="${1:?usage: pendnt.sh check <request_id>}"
  api GET "/v1/requests/$id?wait_s=0" | jq .
}

case "${1:-}" in
  approve) shift; cmd_approve "$@" ;;
  notify) shift; cmd_notify "$@" ;;
  wait-event) shift; cmd_wait_event "$@" ;;
  wakeup) shift; cmd_wakeup "$@" ;;
  check) shift; cmd_check "$@" ;;
  *)
    echo "usage: pendnt.sh {approve|notify|wait-event|wakeup|check} ..." >&2
    exit 1
    ;;
esac
