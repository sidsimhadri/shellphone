#!/usr/bin/env bash
# scripts/test-full.sh — full closed-loop test, no Slack or Kiro required
#
# Uses the tmux-test skill pattern (tmux wait-for) for deterministic
# synchronization instead of sleep or polling.
#
# What this tests that test-local.sh does not:
#   - tmux send-keys → pane reads prompt → hooks fire → semaphore written
#   - bot.py-style dispatch: message sent via tmux, hooks triggered by fake Kiro
#   - Multiple sequential prompts without races
#
# Usage:
#   bash scripts/test-full.sh

set -euo pipefail

SESSION="shellphone-full-$$"
SIGNAL="shellphone-done-$$"
WORK_DIR="$(mktemp -d)"
SLACK_LOG="$WORK_DIR/slack-calls.log"
HOOKS_DIR="$(cd "$(dirname "$0")/../hooks" && pwd)"

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Fake curl ────────────────────────────────────────────────────────────────

FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_BIN"
export SLACK_LOG

cat > "$FAKE_BIN/curl" << 'EOF'
#!/usr/bin/env bash
method="" payload=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    *slack.com/api/*) method="${1##*/api/}" ;;
    -d) payload="$2"; shift ;;
  esac
  shift
done
printf '[Slack] %-20s %s\n' "$method" "$payload" >> "$SLACK_LOG"
printf '{"ok":true,"ts":"1700000001.000001","channel":"C_TEST"}'
EOF
chmod +x "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:$PATH"

# ── Shared env ────────────────────────────────────────────────────────────────

export SHELLPHONE_SESSION="$SESSION"
export SHELLPHONE_DIR="$WORK_DIR"
export SLACK_BOT_TOKEN="xoxb-fake"
export SHELLPHONE_TEST_SIGNAL="$SIGNAL"   # tmux-test skill: enables wait-for sync
export CAPTURE_LINES=30

DATA_DIR="$WORK_DIR/data"
SESSION_DIR="$DATA_DIR/$SESSION"
mkdir -p "$SESSION_DIR"
echo "{\"$SESSION\": \"C_TEST_CHANNEL\"}" > "$DATA_DIR/channel-map.json"

# ── Fake Kiro: runs in the tmux pane ─────────────────────────────────────────
#
# A shell function that simulates one Kiro turn:
#   fake-kiro "your prompt"
#   → fires on-prompt-submit, on-tool-use (×2), on-stop
#   → on-stop signals the tmux wait-for channel

FAKE_KIRO_SCRIPT="$WORK_DIR/fake-kiro-init.sh"
cat > "$FAKE_KIRO_SCRIPT" << INIT
export PATH="$FAKE_BIN:\$PATH"
export SHELLPHONE_SESSION="$SESSION"
export SHELLPHONE_DIR="$WORK_DIR"
export SLACK_BOT_TOKEN="xoxb-fake"
export SHELLPHONE_TEST_SIGNAL="$SIGNAL"
export SLACK_LOG="$SLACK_LOG"
export CAPTURE_LINES=30

fake-kiro() {
  local prompt="\$1"
  jq -n --arg p "\$prompt" '{"prompt":\$p}' | bash "$HOOKS_DIR/on-prompt-submit.sh"
  echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.py"}}' | bash "$HOOKS_DIR/on-tool-use.sh"
  echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.py","content":"done"}}' | bash "$HOOKS_DIR/on-tool-use.sh"
  echo '{"stop_hook_active":false}' | bash "$HOOKS_DIR/on-stop.sh"
}

echo "fake-kiro ready"
INIT

# ── Start tmux session with fake Kiro sourced ────────────────────────────────

echo "==> Starting tmux session: $SESSION"
tmux new-session -d -s "$SESSION" -x 220 -y 50
tmux send-keys -t "$SESSION" "source $FAKE_KIRO_SCRIPT" Enter
sleep 0.5   # one-time startup wait (skill pattern: sleep only for init)

touch "$SESSION_DIR/semaphore"  # start idle

# ── Run prompts — tmux wait-for blocks until on-stop.sh signals done ─────────

PROMPTS=(
  "Write a hello world function in Python"
  "Add type hints to that function"
)

for i in "${!PROMPTS[@]}"; do
  prompt="${PROMPTS[$i]}"
  num=$((i + 1))
  echo ""
  echo "==> [Prompt $num/${#PROMPTS[@]}] Sending: \"$prompt\""

  # Send via tmux send-keys (same path bot.py uses)
  tmux send-keys -t "$SESSION" "fake-kiro \"$prompt\"" Enter

  # Block until on-stop.sh fires tmux wait-for -S $SIGNAL (no polling, no sleep)
  tmux wait-for "$SIGNAL"

  echo "    done (signal received)"
  echo "    semaphore idle: $(test -f "$SESSION_DIR/semaphore" && echo YES || echo NO)"
done

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Slack calls across both prompts:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$SLACK_LOG"

echo ""
CALL_COUNT=$(grep -c '^\[Slack\]' "$SLACK_LOG" || true)
EXPECTED=8   # 4 Slack calls per prompt × 2 prompts (no final response: pane is empty)
echo "Slack calls: $CALL_COUNT (expected $EXPECTED)"

if [[ "$CALL_COUNT" -eq "$EXPECTED" ]]; then
  echo ""
  echo "  All checks passed. PASS"
else
  echo ""
  echo "  FAIL: expected $EXPECTED calls, got $CALL_COUNT"
  exit 1
fi
