# shellphone

Slack ↔ tmux relay for interactive CLI tools.
Send prompts from Slack, get structured updates back in threads, attach to the session anytime.

Works with [Kiro CLI](https://kiro.dev/docs/cli/), Claude Code, or anything with lifecycle hooks.

## Setup

### 1. Create a Slack app

Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**.

| Step | What to do |
|------|-----------|
| **Socket Mode** | Enable → create App-Level Token with `connections:write` → copy `xapp-…` |
| **OAuth & Permissions** | Add scopes: `channels:manage` `channels:read` `chat:write` `groups:write` |
| **Event Subscriptions** | Enable → subscribe to bot events: `message.channels` `app_mention` |
| **Install** | Install to workspace → copy Bot Token `xoxb-…` |

### 2. Install shellphone

```bash
git clone <this-repo> ~/shellphone
cd ~/shellphone
bash scripts/install.sh
```

### 3. Configure tokens

Edit `~/.shellphone/.env`:

```bash
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
ALLOWED_USERS=U12345678    # your Slack member ID (Profile → ⋯ → Copy member ID)
```

## Usage

```bash
# Start the relay bot (once — runs as a systemd user service)
systemctl --user start shellphone

# Create a session and launch Kiro
./scripts/new-session.sh mywork kiro-cli --agent ~/shellphone/examples/kiro-agent.json

# Or Claude Code
./scripts/new-session.sh mywork claude

# Attach to the terminal anytime (hooks still fire)
tmux attach -t mywork

# Tear down when done (--archive archives the Slack channel)
./scripts/kill-session.sh mywork --archive
```

`new-session.sh` creates the tmux session, registers a Slack channel (`#sp-mywork`),
and launches the CLI tool.  From there, send messages in Slack — they queue and
deliver one at a time, waiting for each turn to finish.

### Kiro hook config

The `kiro-agent.json` wires Kiro's hook events to shellphone.
`$SHELLPHONE_HOOKS_DIR` is set automatically in the tmux environment.

See `examples/kiro-agent.json`.  For Claude Code, see `examples/claude-code-settings.json`.

### Slack commands

| Command | Effect |
|---------|--------|
| `!status` | idle/busy + queue depth |
| `!stop` | send Ctrl-C |
| `!clear` | drain message queue |
| `!attach` | show tmux attach command |
| `!help` | list commands |

## How it works

Two independent processes coordinate through the filesystem.  No shared runtime.

```
 Slack
  │
  ▼
 relay bot ──── tmux send-keys ────► CLI tool (in tmux)
 (bot.py)                               │
                                    hook scripts
                                         │
                                    curl Slack API
                                         │
                                         ▼
                                       Slack
```

### Turn lifecycle

Each prompt-response cycle follows this state machine:

```
IDLE ──► bot dispatches queued msg via tmux send-keys
     ──► on-prompt-submit.sh removes semaphore, posts prompt    ──► BUSY
BUSY ──► on-tool-use.sh updates "working…" message              ──► BUSY
     ──► on-stop.sh captures pane, posts response, writes semaphore ──► IDLE
```

The relay bot polls for the semaphore file before sending the next message.
If no stop hook fires within `WATCHDOG_TIMEOUT_MINUTES`, the bot posts a warning.

### Shared state

```
~/.shellphone/
├── .env                         # tokens and config
└── data/
    ├── channel-map.json         # {session-name: channel-id}  (file-locked)
    └── {session}/
        ├── semaphore            # present = idle, absent = busy
        ├── thread-ts            # current Slack thread parent
        └── working-ts           # ephemeral "working…" message
```

### Files

```
hooks/
  lib.sh              # shared: env setup, Slack API helpers, state reads
  setup-channel.sh    # called by new-session.sh: creates Slack channel + mapping
  on-prompt-submit.sh # hook: marks busy, posts prompt as thread parent
  on-tool-use.sh      # hook: creates/updates "working…" message
  on-stop.sh          # hook: captures output, posts response, marks idle

shellphone/
  bot.py              # relay bot (Slack Bolt, Socket Mode)

scripts/
  new-session.sh      # create tmux session + register with Slack
  kill-session.sh     # tear down session + clean state + optional archive
  install.sh          # one-shot setup (deps, dirs, systemd)
```

## Requirements

- Python 3.11+, tmux >= 3.0, curl, jq, flock
