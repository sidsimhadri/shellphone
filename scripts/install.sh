#!/usr/bin/env bash
# scripts/install.sh
#
# One-shot setup: installs Python deps, creates ~/.shellphone/, optionally
# installs a systemd user service.

set -euo pipefail

SHELLPHONE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHELLPHONE_DIR="${SHELLPHONE_DIR:-$HOME/.shellphone}"

echo "=== shellphone installer ==="
echo "SHELLPHONE_ROOT: $SHELLPHONE_ROOT"
echo "SHELLPHONE_DIR:  $SHELLPHONE_DIR"
echo ""

# --- Directories ---
mkdir -p "$SHELLPHONE_DIR/data"
chmod 700 "$SHELLPHONE_DIR"

# --- Python dependencies ---
if ! command -v python3 &>/dev/null; then
  echo "Error: python3 not found. Install Python 3.11+." >&2
  exit 1
fi

echo "Installing Python dependencies…"
python3 -m pip install -q -r "$SHELLPHONE_ROOT/requirements.txt"

# --- Required external tools ---
missing=()
for cmd in tmux curl jq flock; do
  command -v "$cmd" &>/dev/null || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Warning: missing tools: ${missing[*]}" >&2
  echo "  Install with your package manager, e.g.:"
  echo "    sudo apt install ${missing[*]}" >&2
fi

# --- .env file ---
if [ ! -f "$SHELLPHONE_DIR/.env" ]; then
  cp "$SHELLPHONE_ROOT/.env.example" "$SHELLPHONE_DIR/.env"
  echo ""
  echo "Created $SHELLPHONE_DIR/.env — fill in your Slack tokens before starting."
else
  echo ".env already exists at $SHELLPHONE_DIR/.env"
fi

# --- Executable bits ---
chmod +x "$SHELLPHONE_ROOT/hooks/"*.sh
chmod +x "$SHELLPHONE_ROOT/scripts/"*.sh

# --- Systemd user service (optional) ---
if command -v systemctl &>/dev/null; then
  SERVICE_DIR="$HOME/.config/systemd/user"
  mkdir -p "$SERVICE_DIR"
  sed \
    -e "s|{SHELLPHONE_ROOT}|$SHELLPHONE_ROOT|g" \
    -e "s|{SHELLPHONE_DIR}|$SHELLPHONE_DIR|g" \
    "$SHELLPHONE_ROOT/systemd/shellphone.service" \
    > "$SERVICE_DIR/shellphone.service"
  systemctl --user daemon-reload
  echo ""
  echo "Systemd service installed. Enable and start with:"
  echo "  systemctl --user enable --now shellphone"
else
  echo ""
  echo "systemctl not available. Start the bot manually:"
  echo "  python3 -m shellphone.bot"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit $SHELLPHONE_DIR/.env with your Slack tokens"
echo "  2. Start the relay bot:"
echo "       systemctl --user start shellphone"
echo "     or:"
echo "       cd $SHELLPHONE_ROOT && python3 -m shellphone.bot"
echo "  3. Create a session:"
echo "       $SHELLPHONE_ROOT/scripts/new-session.sh my-session claude"
