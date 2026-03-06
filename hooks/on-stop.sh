#!/usr/bin/env bash
# hooks/on-stop.sh  — stop
#
# Fired when the CLI tool finishes a turn.
# Captures terminal output via `tmux capture-pane`, posts the response to
# the Slack thread, deletes the working message, and writes the idle semaphore.
#
# Stdin (Kiro):        {"hook_event_name":"stop","cwd":"..."}
# Stdin (Claude Code): {"stop_hook_active":false}
#
# Always exits 0.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Guard: if this is a recursive stop-hook call, just mark idle and bail.
stop_hook_active=$(printf '%s' "$STDIN_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
if [ "$stop_hook_active" = "true" ]; then
  touch "$SESSION_DIR/semaphore"
  exit 0
fi

if [ -z "$CHANNEL_ID" ]; then
  touch "$SESSION_DIR/semaphore"
  exit 0
fi

# ── Capture terminal pane (plain text, no ANSI) ─────────────────────────────

raw=$(tmux capture-pane -t "$SESSION" -p -J 2>/dev/null | tail -n "$CAPTURE_LINES" || true)
clean=$(printf '%s\n' "$raw" | sed '/^[[:space:]]*$/d' | tail -n "$CAPTURE_LINES")

# Slack text limit ~4000 chars — trim lines from the top until it fits
while [ ${#clean} -gt 3800 ] && [ "$(printf '%s' "$clean" | wc -l)" -gt 5 ]; do
  clean="…(truncated)
$(printf '%s' "$clean" | tail -n +3)"
done

# ── Delete working message ──────────────────────────────────────────────────

if [ -n "$WORKING_TS" ]; then
  slack_delete "$CHANNEL_ID" "$WORKING_TS"
  rm -f "$SESSION_DIR/working-ts"
fi

# ── Post final response ─────────────────────────────────────────────────────

if [ -n "$clean" ]; then
  slack_post "$CHANNEL_ID" ":white_check_mark:
\`\`\`
$clean
\`\`\`" "$THREAD_TS" > /dev/null
fi

# ── Mark idle ────────────────────────────────────────────────────────────────

touch "$SESSION_DIR/semaphore"

# Signal test harness if running under tmux-test skill
[ -n "${SHELLPHONE_TEST_SIGNAL:-}" ] && tmux wait-for -S "$SHELLPHONE_TEST_SIGNAL" 2>/dev/null || true

exit 0
