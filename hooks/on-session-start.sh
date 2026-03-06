#!/usr/bin/env bash
# hooks/on-session-start.sh  — agentSpawn equivalent
#
# Called once when a shellphone session is created (by scripts/new-session.sh).
# Creates (or reuses) a Slack channel named after the session, registers the
# mapping in channel-map.json, and writes the initial semaphore so the relay
# bot knows the session is idle.
#
# Required env:
#   SHELLPHONE_SESSION   tmux session name
#   SLACK_BOT_TOKEN      Slack bot token (xoxb-...)
#
# Optional env:
#   SHELLPHONE_DIR       default: ~/.shellphone

set -euo pipefail

SESSION="${SHELLPHONE_SESSION:?SHELLPHONE_SESSION not set}"
SHELLPHONE_DIR="${SHELLPHONE_DIR:-$HOME/.shellphone}"
DATA_DIR="$SHELLPHONE_DIR/data"
SESSION_DIR="$DATA_DIR/$SESSION"
CHANNEL_MAP="$DATA_DIR/channel-map.json"
LOCK_FILE="$CHANNEL_MAP.lock"

mkdir -p "$SESSION_DIR"

# Slack channel names: lowercase, max 80 chars, only a-z0-9_-
CHANNEL_NAME="$(printf '%s' "shellphone-$SESSION" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -cs 'a-z0-9_-' '-' \
  | cut -c1-80 \
  | sed 's/-$//')"

# --- Create or resolve channel ---
response=$(curl -sf -X POST https://slack.com/api/conversations.create \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg name "$CHANNEL_NAME" '{name: $name}')")

ok=$(printf '%s' "$response" | jq -r '.ok')

if [ "$ok" = "true" ]; then
  CHANNEL_ID=$(printf '%s' "$response" | jq -r '.channel.id')
else
  error=$(printf '%s' "$response" | jq -r '.error')
  if [ "$error" = "name_taken" ]; then
    # Channel already exists — fetch its ID
    CHANNEL_ID=$(curl -sf \
      "https://slack.com/api/conversations.list?limit=1000&exclude_archived=true" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      | jq -r --arg name "$CHANNEL_NAME" '.channels[] | select(.name == $name) | .id')
    if [ -z "$CHANNEL_ID" ]; then
      echo "shellphone: channel '$CHANNEL_NAME' exists but could not be found (check bot scopes)" >&2
      exit 1
    fi
  else
    echo "shellphone: failed to create Slack channel: $error" >&2
    exit 1
  fi
fi

# --- Update channel-map.json (file-locked) ---
(
  flock -x 9
  current=$(cat "$CHANNEL_MAP" 2>/dev/null || echo '{}')
  printf '%s' "$current" \
    | jq --arg s "$SESSION" --arg c "$CHANNEL_ID" '. + {($s): $c}' \
    > "$CHANNEL_MAP.tmp"
  mv "$CHANNEL_MAP.tmp" "$CHANNEL_MAP"
) 9>"$LOCK_FILE"

# --- Write initial semaphore (session is idle) ---
touch "$SESSION_DIR/semaphore"

# --- Invite bot to channel (idempotent) ---
BOT_USER_ID=$(curl -sf https://slack.com/api/auth.test \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  | jq -r '.user_id')
curl -sf -X POST https://slack.com/api/conversations.invite \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg channel "$CHANNEL_ID" --arg user "$BOT_USER_ID" \
       '{channel: $channel, users: $user}')" > /dev/null 2>&1 || true

# --- Post welcome banner ---
curl -sf -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg channel "$CHANNEL_ID" \
    --arg session "$SESSION" \
    '{
       channel: $channel,
       text: (":telephone_receiver: *shellphone session `" + $session + "` started*\n\nSend messages here to relay them to the CLI tool running in this session.\n\n*Tip:* Type `!help` for control commands, or attach manually:\n```tmux attach -t " + $session + "```")
     }')" > /dev/null

echo "shellphone: session '$SESSION' → Slack channel $CHANNEL_ID (#$CHANNEL_NAME)"
