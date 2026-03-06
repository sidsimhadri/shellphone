#!/usr/bin/env bash
# hooks/lib.sh — shared helpers sourced by every hook script.
#
# Usage (at top of each hook):
#   SHELLPHONE_HOOK="on-prompt-submit"
#   source "$(dirname "$0")/lib.sh"
#
# After sourcing, the following are available:
#   SESSION         tmux session name
#   SESSION_DIR     ~/.shellphone/data/{session}/
#   CHANNEL_ID      Slack channel for this session (exits 0 if unset)
#   THREAD_TS       current thread parent timestamp (may be empty)
#   WORKING_TS      working-message timestamp (may be empty)
#   STDIN_JSON      raw stdin JSON (captured once for the caller)
#
#   slack_post      channel text [thread_ts]  — chat.postMessage
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
  curl -sf -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

slack_update() {
  # slack_update <channel> <ts> <text>
  curl -sf -X POST https://slack.com/api/chat.update \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg channel "$1" \
      --arg ts "$2" \
      --arg text "$3" \
      '{channel: $channel, ts: $ts, text: $text}')" > /dev/null
}

slack_delete() {
  # slack_delete <channel> <ts>
  curl -sf -X POST https://slack.com/api/chat.delete \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg channel "$1" \
      --arg ts "$2" \
      '{channel: $channel, ts: $ts}')" > /dev/null 2>&1 || true
}
