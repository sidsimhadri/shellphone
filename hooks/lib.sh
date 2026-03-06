#!/usr/bin/env bash
# hooks/lib.sh — shared helpers sourced by every hook script.
#
# After sourcing, the following are available:
#   SESSION         tmux session name
#   SESSION_DIR     ~/.shellphone/data/{session}/
#   CHANNEL_ID      Slack channel for this session (may be empty)
#   THREAD_TS       current thread parent timestamp (may be empty)
#   WORKING_TS      working-message timestamp (may be empty)
#   STDIN_JSON      raw stdin JSON (captured once for the caller)
#
#   slack_post      channel text [thread_ts]  — chat.postMessage, prints response JSON
#   slack_update    channel ts text           — chat.update
#   slack_delete    channel ts                — chat.delete

set -euo pipefail

# ── Core paths ───────────────────────────────────────────────────────────────

SESSION="${SHELLPHONE_SESSION:?SHELLPHONE_SESSION not set}"
SHELLPHONE_DIR="${SHELLPHONE_DIR:-$HOME/.shellphone}"
DATA_DIR="$SHELLPHONE_DIR/data"
SESSION_DIR="$DATA_DIR/$SESSION"
CHANNEL_MAP="$DATA_DIR/channel-map.json"
CAPTURE_LINES="${CAPTURE_LINES:-100}"

mkdir -p "$SESSION_DIR"

# ── Validate token ───────────────────────────────────────────────────────────

if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
  echo "shellphone: SLACK_BOT_TOKEN is not set" >&2
  exit 0  # exit cleanly so the CLI tool is not disrupted
fi

# ── Read stdin once ──────────────────────────────────────────────────────────

STDIN_JSON=$(cat 2>/dev/null || true)

# ── Resolve channel ──────────────────────────────────────────────────────────

CHANNEL_ID=$(jq -r --arg s "$SESSION" '.[$s] // empty' "$CHANNEL_MAP" 2>/dev/null || true)

# ── Read state files ─────────────────────────────────────────────────────────

read_state() {
  local f="$SESSION_DIR/$1"
  [ -f "$f" ] && cat "$f" || true
}

THREAD_TS=$(read_state thread-ts)
WORKING_TS=$(read_state working-ts)

# ── Slack helpers ────────────────────────────────────────────────────────────

_slack_call() {
  # _slack_call <method> <json-payload>
  # Prints response JSON.  Logs errors to stderr but does not exit.
  local method="$1" payload="$2"
  local response
  response=$(curl -sS --max-time 10 -X POST "https://slack.com/api/$method" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1) || {
    echo "shellphone: curl failed for $method" >&2
    return 0
  }
  local ok
  ok=$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null || echo false)
  if [ "$ok" != "true" ]; then
    local err
    err=$(printf '%s' "$response" | jq -r '.error // "unknown"' 2>/dev/null || echo "unknown")
    echo "shellphone: Slack $method failed: $err" >&2
  fi
  printf '%s' "$response"
}

slack_post() {
  # slack_post <channel> <text> [thread_ts]
  local channel="$1" text="$2" thread_ts="${3:-}"
  local payload
  payload=$(jq -n \
    --arg channel "$channel" \
    --arg text "$text" \
    --arg thread_ts "$thread_ts" \
    'if $thread_ts != "" then {channel: $channel, text: $text, thread_ts: $thread_ts}
     else {channel: $channel, text: $text} end')
  _slack_call chat.postMessage "$payload"
}

slack_update() {
  # slack_update <channel> <ts> <text>
  local payload
  payload=$(jq -n \
    --arg channel "$1" \
    --arg ts "$2" \
    --arg text "$3" \
    '{channel: $channel, ts: $ts, text: $text}')
  _slack_call chat.update "$payload" > /dev/null
}

slack_delete() {
  # slack_delete <channel> <ts>
  local payload
  payload=$(jq -n \
    --arg channel "$1" \
    --arg ts "$2" \
    '{channel: $channel, ts: $ts}')
  _slack_call chat.delete "$payload" > /dev/null 2>&1 || true
}
