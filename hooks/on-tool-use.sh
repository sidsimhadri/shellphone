#!/usr/bin/env bash
# hooks/on-tool-use.sh  — postToolUse equivalent
#
# Called after each tool invocation.  Creates (on first call per turn) or
# updates a single "working…" thread message, overwriting it with the latest
# tool action so the thread stays compact.
#
# Input (stdin): JSON — {"tool_name": "Read", "tool_input": {...}, "tool_response": ...}
#                       (Claude Code PostToolUse format)

set -euo pipefail

SESSION="${SHELLPHONE_SESSION:?SHELLPHONE_SESSION not set}"
SHELLPHONE_DIR="${SHELLPHONE_DIR:-$HOME/.shellphone}"
DATA_DIR="$SHELLPHONE_DIR/data"
SESSION_DIR="$DATA_DIR/$SESSION"
CHANNEL_MAP="$DATA_DIR/channel-map.json"

# --- Parse input ---
input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // "tool"' 2>/dev/null || echo "tool")

# Build a short summary from tool_input fields (first 60 chars of each value)
tool_summary=$(printf '%s' "$input" | jq -r '
  .tool_input // {} |
  to_entries |
  map(
    .key + ": " +
    (.value | if type == "string"
              then (.[0:60] + if length > 60 then "…" else "" end)
              else (tostring | .[0:60])
              end)
  ) |
  join("  ")
' 2>/dev/null || true)

if [ -n "$tool_summary" ]; then
  display_text=":gear: \`$tool_name\` — $tool_summary"
else
  display_text=":gear: \`$tool_name\`"
fi

# --- Resolve channel and thread ---
CHANNEL_ID=$(jq -r --arg s "$SESSION" '.[$s] // empty' "$CHANNEL_MAP" 2>/dev/null || true)
[ -z "$CHANNEL_ID" ] && exit 0

thread_ts=$(cat "$SESSION_DIR/thread-ts" 2>/dev/null || true)
working_ts=$(cat "$SESSION_DIR/working-ts" 2>/dev/null || true)

if [ -z "$working_ts" ]; then
  # First tool use this turn — create the working message
  response=$(curl -sf -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg channel "$CHANNEL_ID" \
      --arg thread_ts "$thread_ts" \
      --arg text "$display_text" \
      '{channel: $channel, thread_ts: $thread_ts, text: $text}')")
  new_ts=$(printf '%s' "$response" | jq -r '.ts // empty')
  [ -n "$new_ts" ] && printf '%s' "$new_ts" > "$SESSION_DIR/working-ts"
else
  # Subsequent tool uses — update in place
  curl -sf -X POST https://slack.com/api/chat.update \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg channel "$CHANNEL_ID" \
      --arg ts "$working_ts" \
      --arg text "$display_text" \
      '{channel: $channel, ts: $ts, text: $text}')" > /dev/null
fi

exit 0
