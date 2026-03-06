# shellphone

Slack ↔ tmux relay for interactive CLI tools.
Send commands from Slack, get structured updates back in threads, attach to the session anytime.

Built for [Kiro CLI](https://kiro.dev/docs/cli/) and Claude Code — works with anything that supports lifecycle hooks.

---

## Architecture

Two independent processes.  No shared runtime — only the filesystem.

```
Slack  ──►  relay bot  ──► tmux send-keys  ──►  CLI tool (in tmux)
                                                    │
                                              hook scripts
                                                    │
                                            curl Slack API  ──►  Slack
```

**Relay bot** (`shellphone/bot.py`) — Slack Bolt app in Socket Mode.
Validates senders, queues messages per session, waits for the idle semaphore,
dispatches via `tmux send-keys`.  Includes a watchdog timer and control commands.

**Hook scripts** (`hooks/`) — stateless shell scripts invoked by the CLI tool
at lifecycle points.  Each one curls Slack directly.  The relay bot never reads
terminal output.

| Script | CLI event | What it does |
|--------|-----------|-------------|
| `on-session-start.sh` | *(setup)* | creates Slack channel, writes channel-map, writes semaphore |
| `on-prompt-submit.sh` | `userPromptSubmit` | removes semaphore, posts prompt as thread parent |
| `on-tool-use.sh` | `postToolUse` | creates/updates a single "working…" message in the thread |
| `on-stop.sh` | `stop` | captures pane, posts response, deletes working msg, writes semaphore |

All hooks source `hooks/lib.sh` which provides Slack helpers and resolves
session state (channel ID, thread-ts, working-ts) from the filesystem.

**Shared state** (`~/.shellphone/data/`):

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

1. [Create a Slack app](https://api.slack.com/apps) → **From scratch**
2. **Socket Mode** → enable → create App-Level Token (`connections:write`) → copy `xapp-…`
3. **OAuth & Permissions** → Bot Token Scopes:
   `channels:manage` `channels:read` `chat:write` `groups:write`
4. **Event Subscriptions** → enable → subscribe to: `message.channels` `app_mention`
5. **Install to workspace** → copy `xoxb-…` Bot Token

---

## Install

```bash
git clone <this-repo> ~/shellphone
cd ~/shellphone
bash scripts/install.sh
```

Edit `~/.shellphone/.env`:

```bash
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
ALLOWED_USERS=U12345678    # your Slack member ID
```

---

## Quick start (Kiro CLI)

```bash
# 1. Start relay bot (once, runs as systemd user service)
systemctl --user start shellphone

# 2. Create session and launch Kiro with shellphone hooks
./scripts/new-session.sh mywork kiro-cli --agent ~/shellphone/examples/kiro-agent.json

# 3. Attach anytime
tmux attach -t mywork

# 4. Tear down when done
./scripts/kill-session.sh mywork --archive
```

The `kiro-agent.json` wires Kiro's `userPromptSubmit`, `postToolUse`, and `stop`
events to the shellphone hook scripts.  `$SHELLPHONE_HOOKS_DIR` is set
automatically in the tmux environment by `new-session.sh`.

### Kiro agent config

`examples/kiro-agent.json`:
```json
{
  "name": "shellphone",
  "hooks": {
    "userPromptSubmit": [{ "command": "$SHELLPHONE_HOOKS_DIR/on-prompt-submit.sh" }],
    "postToolUse":      [{ "command": "$SHELLPHONE_HOOKS_DIR/on-tool-use.sh" }],
    "stop":             [{ "command": "$SHELLPHONE_HOOKS_DIR/on-stop.sh" }]
  }
}
```

---

## Quick start (Claude Code)

```bash
# 1. Start relay bot
systemctl --user start shellphone

# 2. Create session
./scripts/new-session.sh mywork claude
```

Add hooks to your project's `.claude/settings.json` — see
`examples/claude-code-settings.json`.

---

## Slack usage

Send messages to `#sp-{session}`.  They queue and deliver in order,
one per turn, waiting for each stop-hook before sending the next.

**Control commands** (prefix with `!`):

| Command | Effect |
|---------|--------|
| `!help` | list commands |
| `!status` | session state + queue depth |
| `!stop` | send Ctrl-C |
| `!attach` | print the tmux attach command |
| `!clear` | drain the pending queue |

Attach manually at any time — hooks still fire:

```bash
tmux attach -t mywork
```

---

## Project layout

```
shellphone/
├── shellphone/
│   └── bot.py              # relay bot
├── hooks/
│   ├── lib.sh              # shared helpers (sourced by all hooks)
│   ├── on-session-start.sh # setup: create channel + map
│   ├── on-prompt-submit.sh # mark busy, post prompt
│   ├── on-tool-use.sh      # update working message
│   └── on-stop.sh          # capture + post response, mark idle
├── scripts/
│   ├── new-session.sh      # create a session
│   ├── kill-session.sh     # tear down a session
│   └── install.sh          # one-shot setup
├── systemd/
│   └── shellphone.service  # systemd user unit
├── examples/
│   ├── kiro-agent.json     # Kiro CLI hook config
│   └── claude-code-settings.json
├── requirements.txt
└── .env.example
```

---

## Requirements

- Python 3.11+
- `tmux` >= 3.0
- `curl`, `jq`, `flock`
