#!/usr/bin/env bash
# scripts/test-local.sh — smoke test without Slack or Kiro
#
# Emulates a full prompt lifecycle:
#   userPromptSubmit → postToolUse (×2) → stop
#
# Slack API calls are intercepted via a fake `curl` on PATH and logged to
# a local file.  A real tmux session is created and torn down.
#
# Usage:
#   bash scripts/test-local.sh
#   CAPTURE_LINES=50 bash scripts/test-local.sh

set -euo pipefail

SESSION="shellphone-test-$$"
WORK_DIR="$(mktemp -d)"
SLACK_LOG="$WORK_DIR/slack-calls.log"
HOOKS_DIR="$(cd "$(dirname "$0")/../hooks" && pwd)"

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Fake curl (intercepts Slack API calls) ────────────────────────────────────
#
# Parsed args written to SLACK_LOG; returns a minimal ok response with a
# stable ts so subsequent hooks can read working-ts / thread-ts correctly.

FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_BIN"

# Use a log path that doesn't contain spaces so the here-doc is safe.
export SLACK_LOG

cat > "$FAKE_BIN/curl" << 'EOF'
#!/usr/bin/env bash
method="" payload="" ts="1700000001.000001"
while [[ $# -gt 0 ]]; do
  case "$1" in
    *slack.com/api/*) method="${1##*/api/}" ;;
    -d) payload="$2"; shift ;;
  esac
  shift
done
printf '[Slack] %-20s %s\n' "$method" "$payload" >> "$SLACK_LOG"
printf '{"ok":true,"ts":"%s","channel":"C_TEST"}' "$ts"
EOF
chmod +x "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:$PATH"

# ── Shared env for all hooks ──────────────────────────────────────────────────

export SHELLPHONE_SESSION="$SESSION"
export SHELLPHONE_DIR="$WORK_DIR"
export SLACK_BOT_TOKEN="xoxb-fake-token-for-testing"
export CAPTURE_LINES="${CAPTURE_LINES:-50}"

DATA_DIR="$WORK_DIR/data"
SESSION_DIR="$DATA_DIR/$SESSION"
mkdir -p "$SESSION_DIR"

# channel-map: session → channel
echo "{\"$SESSION\": \"C_TEST_CHANNEL\"}" > "$DATA_DIR/channel-map.json"

# ── Start tmux session ────────────────────────────────────────────────────────

echo "==> [1/6] Starting tmux session: $SESSION"
tmux new-session -d -s "$SESSION" -x 220 -y 50

# Mark idle so bot.py (if running) would accept messages
touch "$SESSION_DIR/semaphore"

# ── Hook: userPromptSubmit ────────────────────────────────────────────────────

echo "==> [2/6] Hook: on-prompt-submit"
echo '{"hook_event_name":"userPromptSubmit","prompt":"Write a hello world function in Python","cwd":"/tmp"}' \
  | bash "$HOOKS_DIR/on-prompt-submit.sh"

echo "    semaphore removed (busy): $(test ! -f "$SESSION_DIR/semaphore" && echo "YES" || echo "NO")"
echo "    thread-ts written:        $(test -f "$SESSION_DIR/thread-ts" && cat "$SESSION_DIR/thread-ts" || echo "(missing)")"

# ── Hook: postToolUse (first call) ────────────────────────────────────────────

echo "==> [3/6] Hook: on-tool-use (first call — creates working msg)"
echo '{"hook_event_name":"postToolUse","tool_name":"Read","tool_input":{"file_path":"/home/user/project/main.py"}}' \
  | bash "$HOOKS_DIR/on-tool-use.sh"

echo "    working-ts written: $(test -f "$SESSION_DIR/working-ts" && cat "$SESSION_DIR/working-ts" || echo "(missing)")"

# ── Hook: postToolUse (second call) ──────────────────────────────────────────

echo "==> [4/6] Hook: on-tool-use (second call — updates working msg)"
echo '{"hook_event_name":"postToolUse","tool_name":"Write","tool_input":{"file_path":"/home/user/project/main.py","content":"def hello():\n    print(\"hello\")"}}' \
  | bash "$HOOKS_DIR/on-tool-use.sh"

# ── Simulate Kiro writing output to the tmux pane ─────────────────────────────

echo "==> [5/6] Writing simulated Kiro output to tmux pane"
tmux send-keys -t "$SESSION" "printf '%s\\n' '> def hello():' '>     print(\"hello world\")' '' 'Done! Created hello() in main.py.'" Enter
sleep 0.4   # let tmux render

# ── Hook: stop ────────────────────────────────────────────────────────────────

echo "==> [6/6] Hook: on-stop"
echo '{"hook_event_name":"stop","stop_hook_active":false}' \
  | bash "$HOOKS_DIR/on-stop.sh"

echo "    semaphore restored (idle): $(test -f "$SESSION_DIR/semaphore" && echo "YES" || echo "NO")"

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Slack calls (would have been sent to real Slack):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ -f "$SLACK_LOG" ]]; then
  cat "$SLACK_LOG"
else
  echo "  (none — something went wrong)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Final session state:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ls -la "$SESSION_DIR/"
echo ""
echo "  All checks passed. PASS"
