#!/usr/bin/env bash
# hooks/on-stop.sh  — Stop equivalent
#
# Called when the CLI tool finishes a turn.
# Captures the terminal pane, strips control codes, posts the response to the
# Slack thread, deletes the ephemeral "working…" message, and writes the
# semaphore so the relay bot knows the session is idle again.
#
# Input (stdin): JSON — {"stop_hook_active": false}  (Claude Code Stop format)
#
# IMPORTANT: always exit 0 so the CLI tool does not loop.

set -euo pipefail

SESSION="${SHELLPHONE_SESSION:?SHELLPHONE_SESSION not set}"
SHELLPHONE_DIR="${SHELLPHONE_DIR:-$HOME/.shellphone}"
DATA_DIR="$SHELLPHONE_DIR/data"
SESSION_DIR="$DATA_DIR/$SESSION"
CHANNEL_MAP="$DATA_DIR/channel-map.json"
CAPTURE_LINES="${CAPTURE_LINES:-100}"

# Guard against recursive stop-hook invocation
input=$(cat 2>/dev/null || true)
stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
if [ "$stop_hook_active" = "true" ]; then
  touch "$SESSION_DIR/semaphore"
  exit 0
fi

# --- Resolve channel / thread ---
CHANNEL_ID=$(jq -r --arg s "$SESSION" '.[$s] // empty' "$CHANNEL_MAP" 2>/dev/null || true)
if [ -z "$CHANNEL_ID" ]; then
  touch "$SESSION_DIR/semaphore"
  exit 0
fi

thread_ts=$(cat "$SESSION_DIR/thread-ts" 2>/dev/null || true)
working_ts=$(cat "$SESSION_DIR/working-ts" 2>/dev/null || true)

# --- Capture terminal output (no ANSI escape codes) ---
# -p: print to stdout  -J: join wrapped lines  (no -e: tmux strips attrs itself)
raw=$(tmux capture-pane -t "$SESSION" -p -J 2>/dev/null | tail -n "$CAPTURE_LINES" || true)

# Remove any residual ANSI sequences and blank lines
clean=$(printf '%s' "$raw" \
  | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b[()]//g; s/\r//g' \
  | sed '/^[[:space:]]*$/d' \
  | tail -n "$CAPTURE_LINES")

# Slack text limit ~4000 chars
if [ ${#clean} -gt 3800 ]; then
  clean="…(output truncated to last $CAPTURE_LINES lines)
$(printf '%s' "$clean" | tail -c 3500)"
fi

# --- Delete the "working…" message ---
if [ -n "$working_ts" ]; then
  curl -sf -X POST https://slack.com/api/chat.delete \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg channel "$CHANNEL_ID" \
      --arg ts "$working_ts" \
      '{channel: $channel, ts: $ts}')" > /dev/null 2>&1 || true
  rm -f "$SESSION_DIR/working-ts"
fi

# --- Post final response ---
if [ -n "$clean" ]; then
  curl -sf -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg channel "$CHANNEL_ID" \
      --arg thread_ts "$thread_ts" \
      --arg text ":white_check_mark: \`\`\`$clean\`\`\`" \
      '{channel: $channel, thread_ts: $thread_ts, text: $text}')" > /dev/null
fi

# --- Write semaphore (session is now idle) ---
touch "$SESSION_DIR/semaphore"

exit 0
