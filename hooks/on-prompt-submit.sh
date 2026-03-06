#!/usr/bin/env bash
# hooks/on-prompt-submit.sh  — userPromptSubmit equivalent
#
# Called by the CLI tool just before it processes a user prompt.
# Removes the semaphore (marks session busy), posts the prompt to Slack as
# a new thread parent, and stores the thread timestamp for subsequent hooks.
#
# Input (stdin): JSON — {"prompt": "..."}   (Claude Code format)
#                Falls back to raw text if JSON parsing fails.
#
# Exit 0 always so the CLI tool proceeds normally.

set -euo pipefail

SESSION="${SHELLPHONE_SESSION:?SHELLPHONE_SESSION not set}"
SHELLPHONE_DIR="${SHELLPHONE_DIR:-$HOME/.shellphone}"
DATA_DIR="$SHELLPHONE_DIR/data"
SESSION_DIR="$DATA_DIR/$SESSION"
CHANNEL_MAP="$DATA_DIR/channel-map.json"

# --- Read stdin ---
input=$(cat)
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)
[ -z "$prompt" ] && prompt="$input"   # fallback: treat whole stdin as the prompt

# --- Resolve channel ---
CHANNEL_ID=$(jq -r --arg s "$SESSION" '.[$s] // empty' "$CHANNEL_MAP" 2>/dev/null || true)
[ -z "$CHANNEL_ID" ] && exit 0

# --- Mark session busy (remove semaphore) ---
rm -f "$SESSION_DIR/semaphore"

# --- Clear previous working-ts (new turn) ---
rm -f "$SESSION_DIR/working-ts"

# --- Post prompt as new thread parent ---
response=$(curl -sf -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg channel "$CHANNEL_ID" \
    --arg prompt "$prompt" \
    '{channel: $channel, text: (":speech_balloon: *Prompt:*\n> " + $prompt)}')")

thread_ts=$(printf '%s' "$response" | jq -r '.ts // empty')
[ -n "$thread_ts" ] && printf '%s' "$thread_ts" > "$SESSION_DIR/thread-ts"

exit 0
