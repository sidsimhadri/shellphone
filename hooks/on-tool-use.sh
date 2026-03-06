#!/usr/bin/env bash
# hooks/on-tool-use.sh  — postToolUse
#
# Fired after each tool invocation.  Creates (first call) or updates
# a single "working…" thread message showing the latest tool action.
#
# Stdin (Kiro):        {"hook_event_name":"postToolUse","tool_name":"fs_read","tool_input":{...},...}
# Stdin (Claude Code): {"tool_name":"Read","tool_input":{...},...}

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
[ -z "$CHANNEL_ID" ] && exit 0

# ── Parse tool info ──────────────────────────────────────────────────────────

tool_name=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_name // "tool"' 2>/dev/null || echo "tool")

tool_summary=$(printf '%s' "$STDIN_JSON" | jq -r '
  .tool_input // {} | to_entries |
  map(.key + ": " + (.value |
    if type == "string" then (.[0:60] + if length > 60 then "…" else "" end)
    else (tostring | .[0:60]) end)) |
  join("  ")
' 2>/dev/null || true)

if [ -n "$tool_summary" ]; then
  display=":gear: \`$tool_name\` — $tool_summary"
else
  display=":gear: \`$tool_name\`"
fi

# ── Create or update working message ────────────────────────────────────────

if [ -z "$WORKING_TS" ]; then
  response=$(slack_post "$CHANNEL_ID" "$display" "$THREAD_TS")
  new_ts=$(printf '%s' "$response" | jq -r '.ts // empty')
  [ -n "$new_ts" ] && printf '%s' "$new_ts" > "$SESSION_DIR/working-ts"
else
  slack_update "$CHANNEL_ID" "$WORKING_TS" "$display"
fi

exit 0
