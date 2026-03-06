# shellphone

A Slack ↔ tmux relay for interactive CLI tools (Claude Code, Kiro, etc.).
Send commands from Slack, get structured updates back in threads, and attach to the session manually at any time.

---

## How it works

Two independent processes communicate only through the filesystem — no shared runtime, no sockets between them.

```
Slack  ──►  relay bot  ──► tmux send-keys  ──►  CLI tool  (inside tmux)
                                                    │
                                              hook scripts
                                                    │
                                            curl Slack API  ──►  Slack
```

**Process 1 — Relay bot** (`shellphone/bot.py`, systemd service)

A Slack Bolt app running in Socket Mode.  For each inbound message it:
1. Validates the sender against `ALLOWED_USERS`
2. Looks up the tmux session mapped to that Slack channel
3. Waits for the session semaphore (idle signal)
4. Delivers the text via `tmux send-keys`
5. Starts a watchdog timer; if no stop-hook fires within `WATCHDOG_TIMEOUT_MINUTES`, it posts a warning

**Process 2 — CLI tool** (running inside a named tmux session)

Configured with hook scripts that fire at lifecycle points and `curl` the Slack API directly.  The relay bot never reads terminal output.

**Hook scripts** (`hooks/`)

| Hook | Event | Action |
|------|-------|--------|
| `on-session-start.sh` | session created | creates Slack channel, writes channel-map entry, writes semaphore |
| `on-prompt-submit.sh` | prompt submitted | removes semaphore, posts prompt to Slack as thread parent |
| `on-tool-use.sh` | after each tool call | creates/updates a single "working…" thread message |
| `on-stop.sh` | turn finished | captures pane, posts response, deletes working message, writes semaphore |

**Shared state** (`~/.shellphone/data/`)

```
~/.shellphone/
├── .env                         # tokens and config
└── data/
    ├── channel-map.json         # session-name → Slack channel ID
    └── {session}/
        ├── semaphore            # present = idle, absent = busy
        ├── thread-ts            # current thread parent timestamp
        └── working-ts           # "working…" message timestamp
```

---

## Slack app setup

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**
2. **Socket Mode** → enable it → create an App-Level Token with `connections:write` → copy the `xapp-…` token
3. **OAuth & Permissions** → add Bot Token Scopes:
   - `channels:manage` `channels:read` `chat:write` `groups:write` `im:write`
4. **Event Subscriptions** → enable → Subscribe to bot events: `message.channels` `message.groups` `app_mention`
5. **Install to workspace** → copy the `xoxb-…` Bot User OAuth Token

---

## Installation

```bash
git clone https://github.com/your-org/shellphone
cd shellphone
bash scripts/install.sh
```

Edit `~/.shellphone/.env`:

```bash
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
ALLOWED_USERS=U12345678   # your Slack user ID
```

---

## Starting a session

```bash
# Start relay bot (once, as a background service)
systemctl --user start shellphone

# Create a new session and launch Claude Code inside it
./scripts/new-session.sh my-project claude

# Or Kiro
./scripts/new-session.sh kiro-work kiro
```

The script creates the tmux session, calls `on-session-start.sh` which
creates the Slack channel `#shellphone-my-project` and posts a welcome
message, then starts the CLI tool.

---

## Hook configuration (Claude Code)

Copy `examples/claude-code-settings.json` into your project:

```bash
mkdir -p .claude
cp /path/to/shellphone/examples/claude-code-settings.json .claude/settings.json
```

The `$SHELLPHONE_HOOKS_DIR` variable is set automatically by `new-session.sh`
in the tmux environment, so hook paths resolve without hardcoding.

For other CLI tools, point their equivalent hook events at the same scripts.

---

## Slack usage

Send messages to the `#shellphone-{session}` channel.  They are queued and
delivered to the CLI tool in order, waiting for each turn to finish.

**Control commands** (prefix `!`):

| Command | Effect |
|---------|--------|
| `!help` | show command list |
| `!status` | session state and queue depth |
| `!stop` | send Ctrl-C to the session |
| `!attach` | print the `tmux attach` command |
| `!clear` | drain the pending message queue |

---

## Manual access

Attach to any session at any time — hooks still fire on manual interactions:

```bash
tmux attach -t my-project
```

---

## Project layout

```
shellphone/
├── shellphone/
│   └── bot.py              # Slack Bolt relay (Process 1)
├── hooks/
│   ├── on-session-start.sh # agentSpawn
│   ├── on-prompt-submit.sh # userPromptSubmit
│   ├── on-tool-use.sh      # postToolUse
│   └── on-stop.sh          # stop
├── scripts/
│   ├── new-session.sh      # create a session
│   └── install.sh          # one-shot setup
├── systemd/
│   └── shellphone.service  # systemd user unit template
├── examples/
│   └── claude-code-settings.json
├── requirements.txt
└── .env.example
```

---

## Requirements

- Python 3.11+, `pip`
- `tmux` ≥ 3.0
- `curl`, `jq`, `flock` (standard on Linux)
