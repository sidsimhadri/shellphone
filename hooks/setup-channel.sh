#!/usr/bin/env bash
# hooks/setup-channel.sh
#
# Called once by scripts/new-session.sh before the CLI tool starts.
# Creates or reuses a Slack channel, registers the mapping, writes the
# idle semaphore, and posts a welcome banner.
#
# This is a setup script, not a CLI hook — it runs before the tool launches.

# Source lib (reads stdin, sets SESSION, SESSION_DIR, etc.)
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# ── Slack channel name (lowercase, max 80 chars, a-z0-9_-) ──────────────────

CHANNEL_NAME="$(printf '%s' "sp-$SESSION" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -cs 'a-z0-9_-' '-' \
  | cut -c1-80 \
  | sed 's/-$//')"

# ── Create or resolve channel ────────────────────────────────────────────────

response=$(curl -sf --max-time 10 -X POST https://slack.com/api/conversations.create \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg name "$CHANNEL_NAME" '{name: $name}')")

ok=$(printf '%s' "$response" | jq -r '.ok')

if [ "$ok" = "true" ]; then
  CHANNEL_ID=$(printf '%s' "$response" | jq -r '.channel.id')
else
  error=$(printf '%s' "$response" | jq -r '.error')
  if [ "$error" = "name_taken" ]; then
    CHANNEL_ID=$(curl -sf --max-time 10 \
      "https://slack.com/api/conversations.list?limit=1000&exclude_archived=true" \
      -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
      | jq -r --arg name "$CHANNEL_NAME" '.channels[] | select(.name == $name) | .id')
    if [ -z "$CHANNEL_ID" ]; then
      echo "shellphone: channel '$CHANNEL_NAME' exists but cannot be resolved (check bot scopes)" >&2
      exit 1
    fi
  else
    echo "shellphone: failed to create channel: $error" >&2
    exit 1
  fi
fi

# ── Update channel-map.json (file-locked) ────────────────────────────────────

(
  flock -x 9
  current=$(cat "$CHANNEL_MAP" 2>/dev/null || echo '{}')
  printf '%s' "$current" \
    | jq --arg s "$SESSION" --arg c "$CHANNEL_ID" '. + {($s): $c}' \
    > "$CHANNEL_MAP.tmp"
  mv "$CHANNEL_MAP.tmp" "$CHANNEL_MAP"
) 9>"$CHANNEL_MAP.lock"

# ── Write idle semaphore ─────────────────────────────────────────────────────

touch "$SESSION_DIR/semaphore"

# ── Invite bot to channel (idempotent) ───────────────────────────────────────

BOT_USER_ID=$(curl -sf --max-time 10 https://slack.com/api/auth.test \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" | jq -r '.user_id')
curl -sf --max-time 10 -X POST https://slack.com/api/conversations.invite \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg channel "$CHANNEL_ID" --arg user "$BOT_USER_ID" \
       '{channel: $channel, users: $user}')" > /dev/null 2>&1 || true

# ── Welcome banner ───────────────────────────────────────────────────────────

slack_post "$CHANNEL_ID" \
  ":telephone_receiver: *shellphone session \`$SESSION\` started*

Send messages here to relay them to the CLI tool.
Type \`!help\` for control commands, or attach manually:
\`\`\`tmux attach -t $SESSION\`\`\`" > /dev/null

echo "shellphone: session '$SESSION' → #$CHANNEL_NAME ($CHANNEL_ID)"
