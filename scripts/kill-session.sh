#!/usr/bin/env bash
# scripts/kill-session.sh
#
# Tears down a shellphone session: kills the tmux session, removes the
# channel-map entry, cleans up state files, and optionally archives the
# Slack channel.
#
# Usage:
#   kill-session.sh <session-name> [--archive]

set -euo pipefail

SHELLPHONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHELLPHONE_DIR="${SHELLPHONE_DIR:-$HOME/.shellphone}"
DATA_DIR="$SHELLPHONE_DIR/data"
CHANNEL_MAP="$DATA_DIR/channel-map.json"

# Source .env for SLACK_BOT_TOKEN
if [ -f "$SHELLPHONE_DIR/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "$SHELLPHONE_DIR/.env"; set +a
fi

SESSION="${1:?Usage: kill-session.sh <session-name> [--archive]}"
ARCHIVE="${2:-}"

# ── Kill tmux session ────────────────────────────────────────────────────────

if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux kill-session -t "$SESSION"
  echo "shellphone: killed tmux session '$SESSION'"
else
  echo "shellphone: tmux session '$SESSION' not running (already dead)"
fi

# ── Read channel ID before removing from map ─────────────────────────────────

CHANNEL_ID=$(jq -r --arg s "$SESSION" '.[$s] // empty' "$CHANNEL_MAP" 2>/dev/null || true)

# ── Remove from channel-map.json (file-locked) ──────────────────────────────

if [ -f "$CHANNEL_MAP" ]; then
  (
    flock -x 9
    jq --arg s "$SESSION" 'del(.[$s])' "$CHANNEL_MAP" > "$CHANNEL_MAP.tmp"
    mv "$CHANNEL_MAP.tmp" "$CHANNEL_MAP"
  ) 9>"$CHANNEL_MAP.lock"
  echo "shellphone: removed '$SESSION' from channel-map"
fi

# ── Clean up state files ─────────────────────────────────────────────────────

rm -rf "$DATA_DIR/$SESSION"
echo "shellphone: cleaned up $DATA_DIR/$SESSION"

# ── Optionally archive the Slack channel ─────────────────────────────────────

if [ "$ARCHIVE" = "--archive" ] && [ -n "$CHANNEL_ID" ] && [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  curl -sf -X POST https://slack.com/api/conversations.archive \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg channel "$CHANNEL_ID" '{channel: $channel}')" > /dev/null 2>&1 \
    && echo "shellphone: archived Slack channel $CHANNEL_ID" \
    || echo "shellphone: could not archive channel (check bot scopes)"
fi

echo "shellphone: session '$SESSION' torn down."
