#!/usr/bin/env bash
# scripts/new-session.sh
#
# Creates a shellphone tmux session, registers it with Slack, and launches
# a CLI tool inside it.
#
# Usage:
#   new-session.sh <session-name> [command [args...]]
#
# Examples:
#   new-session.sh mywork                                    # bare shell
#   new-session.sh mywork kiro-cli                           # kiro default agent
#   new-session.sh mywork kiro-cli --agent shellphone        # kiro w/ shellphone agent
#   new-session.sh mywork claude                             # claude code

set -euo pipefail

SHELLPHONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$SHELLPHONE_ROOT/hooks"
SHELLPHONE_DIR="${SHELLPHONE_DIR:-$HOME/.shellphone}"

# Source .env for SLACK_BOT_TOKEN etc.
if [ -f "$SHELLPHONE_DIR/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "$SHELLPHONE_DIR/.env"; set +a
fi

SESSION="${1:?Usage: new-session.sh <session-name> [command [args...]]}"
shift || true
CMD="${*:-}"

# ── Validate ─────────────────────────────────────────────────────────────────

if [[ "$SESSION" =~ [.:]  ]]; then
  echo "shellphone: session name must not contain '.' or ':'" >&2
  exit 1
fi

if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
  echo "shellphone: SLACK_BOT_TOKEN not set. Run scripts/install.sh and edit ~/.shellphone/.env" >&2
  exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "shellphone: tmux session '$SESSION' already exists." >&2
  echo "  Attach:  tmux attach -t $SESSION" >&2
  echo "  Kill:    $(dirname "$0")/kill-session.sh $SESSION" >&2
  exit 1
fi

# Clean stale state from a previous session with the same name
rm -rf "$SHELLPHONE_DIR/data/$SESSION"

# ── Create tmux session ──────────────────────────────────────────────────────

mkdir -p "$SHELLPHONE_DIR/data/$SESSION"

tmux new-session -d -s "$SESSION" \
  -e "SHELLPHONE_SESSION=$SESSION" \
  -e "SHELLPHONE_DIR=$SHELLPHONE_DIR" \
  -e "SHELLPHONE_HOOKS_DIR=$HOOKS_DIR" \
  -e "SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN}" \
  -e "CAPTURE_LINES=${CAPTURE_LINES:-100}"

# ── Register with Slack ──────────────────────────────────────────────────────

SHELLPHONE_SESSION="$SESSION" \
SHELLPHONE_DIR="$SHELLPHONE_DIR" \
  "$HOOKS_DIR/setup-channel.sh"

# ── Launch CLI tool ──────────────────────────────────────────────────────────

if [ -n "$CMD" ]; then
  tmux send-keys -t "$SESSION" "$CMD" Enter
fi

echo ""
echo "shellphone: session '$SESSION' is ready."
echo "  Attach:   tmux attach -t $SESSION"
echo "  Teardown: $(dirname "$0")/kill-session.sh $SESSION [--archive]"
