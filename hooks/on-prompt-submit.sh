#!/usr/bin/env bash
# hooks/on-prompt-submit.sh  — userPromptSubmit
#
# Fired by the CLI tool when the user submits a prompt.
# Marks the session busy (removes semaphore), posts the prompt to Slack
# as a new thread parent, and stores the thread timestamp.
#
# Stdin (Kiro):       {"hook_event_name":"userPromptSubmit","cwd":"...","prompt":"..."}
# Stdin (Claude Code): {"prompt":"..."}
#
# Always exits 0 so the CLI tool proceeds normally.

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
[ -z "$CHANNEL_ID" ] && exit 0

# ── Extract prompt ───────────────────────────────────────────────────────────

prompt=$(printf '%s' "$STDIN_JSON" | jq -r '.prompt // empty' 2>/dev/null || true)
[ -z "$prompt" ] && prompt="$STDIN_JSON"

# ── Mark session busy ────────────────────────────────────────────────────────

rm -f "$SESSION_DIR/semaphore"
rm -f "$SESSION_DIR/working-ts"

# ── Post prompt as new thread ────────────────────────────────────────────────

response=$(slack_post "$CHANNEL_ID" ":speech_balloon: *Prompt:*
> $prompt")

thread_ts=$(printf '%s' "$response" | jq -r '.ts // empty')
[ -n "$thread_ts" ] && printf '%s' "$thread_ts" > "$SESSION_DIR/thread-ts"

exit 0
