#!/usr/bin/env bash
# scripts/new-session.sh
#
# Creates a new shellphone tmux session, registers it with Slack, and
# optionally launches a CLI tool inside it.
#
# Usage:
#   new-session.sh <session-name> [command [args...]]
#
# Examples:
#   new-session.sh mywork claude        # start claude CLI
#   new-session.sh kiro-session kiro    # start kiro CLI
#   new-session.sh scratch              # bare shell, attach manually

set -euo pipefail

SHELLPHONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$SHELLPHONE_ROOT/hooks"
SHELLPHONE_DIR="${SHELLPHONE_DIR:-$HOME/.shellphone}"

# Source .env for SLACK_BOT_TOKEN etc.
if [ -f "$SHELLPHONE_DIR/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "$SHELLPHONE_DIR/.env"; set +a
fi

SESSION="${1:?Usage: new-session.sh <session-name> [command]}"
shift || true
CMD="${*:-}"   # remainder of args is the command; empty = bare shell

# Validate session name (tmux rules: no dot, colon, or leading digit)
if [[ "$SESSION" =~ [.:]  ]]; then
  echo "Error: session name must not contain '.' or ':'" >&2
  exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Error: tmux session '$SESSION' already exists." >&2
  echo "  Attach:  tmux attach -t $SESSION" >&2
  echo "  Kill:    tmux kill-session -t $SESSION" >&2
  exit 1
fi

# Ensure data directory exists
mkdir -p "$SHELLPHONE_DIR/data/$SESSION"

# Start detached tmux session with shellphone env exported
tmux new-session -d -s "$SESSION" \
  -e "SHELLPHONE_SESSION=$SESSION" \
  -e "SHELLPHONE_DIR=$SHELLPHONE_DIR" \
  -e "SHELLPHONE_HOOKS_DIR=$HOOKS_DIR" \
  -e "SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN:-}" \
  -e "CAPTURE_LINES=${CAPTURE_LINES:-100}"

# Register with Slack (creates channel, writes channel-map, writes semaphore)
SHELLPHONE_SESSION="$SESSION" \
SHELLPHONE_DIR="$SHELLPHONE_DIR" \
  "$HOOKS_DIR/on-session-start.sh"

# Optionally start the CLI tool inside the session
if [ -n "$CMD" ]; then
  tmux send-keys -t "$SESSION" "$CMD" Enter
fi

echo ""
echo "shellphone: session '$SESSION' is ready."
echo "  Attach:  tmux attach -t $SESSION"
echo "  Kill:    tmux kill-session -t $SESSION && rm -rf $SHELLPHONE_DIR/data/$SESSION"
