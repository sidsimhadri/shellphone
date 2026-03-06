"""shellphone relay bot — routes Slack messages to tmux sessions.

All outbound Slack notifications come from hook scripts that the CLI tool
invokes directly.  This process only handles inbound: Slack → tmux.

State machine (driven by hooks on the CLI side):
  IDLE  →  user sends msg  →  bot dispatches via tmux send-keys
        →  userPromptSubmit hook removes semaphore     →  BUSY
  BUSY  →  postToolUse hook updates "working…" msg     →  BUSY
        →  stop hook writes semaphore, posts response  →  IDLE
"""

import json
import logging
import os
import queue
import re
import subprocess
import threading
import time
from pathlib import Path

from dotenv import load_dotenv
from filelock import FileLock
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

load_dotenv(Path.home() / ".shellphone" / ".env")
load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
log = logging.getLogger("shellphone")

SHELLPHONE_DIR = Path(os.getenv("SHELLPHONE_DIR", Path.home() / ".shellphone"))
DATA_DIR = SHELLPHONE_DIR / "data"
CHANNEL_MAP_PATH = DATA_DIR / "channel-map.json"

ALLOWED_USERS: list[str] = [
    u.strip() for u in os.getenv("ALLOWED_USERS", "").split(",") if u.strip()
]
WATCHDOG_TIMEOUT_SECS = int(os.getenv("WATCHDOG_TIMEOUT_MINUTES", "10")) * 60

for _var in ("SLACK_BOT_TOKEN", "SLACK_APP_TOKEN"):
    if not os.environ.get(_var):
        raise SystemExit(f"shellphone: {_var} is not set.  See ~/.shellphone/.env")

app = App(token=os.environ["SLACK_BOT_TOKEN"])

# ---------------------------------------------------------------------------
# Per-session state (all guarded by _lock)
# ---------------------------------------------------------------------------

_queues: dict[str, queue.Queue] = {}
_threads: dict[str, threading.Thread] = {}
_watchdogs: dict[str, threading.Timer] = {}
_lock = threading.Lock()

# ---------------------------------------------------------------------------
# Channel map (file-locked, cached with mtime)
# ---------------------------------------------------------------------------

_chan_to_session: dict[str, str] = {}
_chan_map_mtime: float = 0.0


def _load_channel_map() -> dict[str, str]:
    """Read channel-map.json under file lock."""
    lock = FileLock(str(CHANNEL_MAP_PATH) + ".lock", timeout=5)
    with lock:
        if CHANNEL_MAP_PATH.exists() and CHANNEL_MAP_PATH.stat().st_size > 0:
            return json.loads(CHANNEL_MAP_PATH.read_text())
    return {}


def _session_for_channel(channel_id: str) -> str | None:
    """Resolve channel_id → session name.  Rebuilds cache when file changes."""
    global _chan_to_session, _chan_map_mtime
    try:
        mtime = CHANNEL_MAP_PATH.stat().st_mtime if CHANNEL_MAP_PATH.exists() else 0.0
    except OSError:
        mtime = 0.0

    if mtime != _chan_map_mtime:
        cmap = _load_channel_map()
        _chan_to_session = {cid: sess for sess, cid in cmap.items()}
        _chan_map_mtime = mtime

    return _chan_to_session.get(channel_id)


# ---------------------------------------------------------------------------
# Filesystem state
# ---------------------------------------------------------------------------


def _session_dir(session: str) -> Path:
    return DATA_DIR / session


def _is_idle(session: str) -> bool:
    """Semaphore present = session is idle and ready for the next prompt."""
    return (_session_dir(session) / "semaphore").exists()


# ---------------------------------------------------------------------------
# Watchdog
# ---------------------------------------------------------------------------


def _watchdog_fired(session: str, client) -> None:
    log.warning("Watchdog fired for session=%s", session)
    channel = _load_channel_map().get(session)
    if not channel:
        return
    ts_path = _session_dir(session) / "thread-ts"
    thread_ts = ts_path.read_text().strip() if ts_path.exists() else None
    try:
        client.chat_postMessage(
            channel=channel,
            thread_ts=thread_ts,
            text=(
                f":warning: No response from `{session}` in "
                f"{WATCHDOG_TIMEOUT_SECS // 60} min — session may be stuck.\n"
                "Use `!stop` to send Ctrl-C or `tmux attach` to inspect."
            ),
        )
    except Exception as exc:
        log.error("Watchdog Slack post failed: %s", exc)


def _start_watchdog(session: str, client) -> None:
    """Start (or restart) the watchdog timer.  Caller must hold _lock."""
    _cancel_watchdog(session)
    t = threading.Timer(WATCHDOG_TIMEOUT_SECS, _watchdog_fired, args=(session, client))
    t.daemon = True
    t.start()
    _watchdogs[session] = t


def _cancel_watchdog(session: str) -> None:
    t = _watchdogs.pop(session, None)
    if t:
        t.cancel()


# ---------------------------------------------------------------------------
# Dispatch (one thread per session)
# ---------------------------------------------------------------------------


def _dispatch_loop(session: str, q: queue.Queue, client) -> None:
    log.info("Dispatch thread started for session=%s", session)
    while True:
        text = q.get()

        # Wait for the stop hook to write the semaphore before sending
        while not _is_idle(session):
            time.sleep(0.5)

        log.info("Sending to tmux session=%s  text=%r", session, text[:80])
        try:
            subprocess.run(
                ["tmux", "send-keys", "-t", session, "-l", text],
                check=True, capture_output=True,
            )
            subprocess.run(
                ["tmux", "send-keys", "-t", session, "Enter"],
                check=True, capture_output=True,
            )
        except subprocess.CalledProcessError as exc:
            log.error("tmux send-keys failed session=%s: %s", session, exc.stderr.decode())
            channel = _load_channel_map().get(session)
            if channel:
                try:
                    client.chat_postMessage(
                        channel=channel,
                        text=f":x: Could not relay to `{session}` — is the tmux session alive?",
                    )
                except Exception as e:
                    log.error("Failed to notify Slack: %s", e)
            q.task_done()
            continue

        with _lock:
            _start_watchdog(session, client)
        q.task_done()


def _enqueue(session: str, text: str, client) -> None:
    """Ensure dispatch thread exists and enqueue text — all under _lock."""
    with _lock:
        thread = _threads.get(session)
        if not thread or not thread.is_alive():
            q: queue.Queue = queue.Queue()
            _queues[session] = q
            t = threading.Thread(
                target=_dispatch_loop, args=(session, q, client),
                name=f"dispatch-{session}", daemon=True,
            )
            t.start()
            _threads[session] = t
            log.info("Started dispatch thread for session=%s", session)
        _queues[session].put(text)


# ---------------------------------------------------------------------------
# Control commands
# ---------------------------------------------------------------------------

HELP_TEXT = (
    "*shellphone commands:*\n"
    "`!help` — this message\n"
    "`!status` — idle/busy + queue depth\n"
    "`!stop` — send Ctrl-C\n"
    "`!attach` — show tmux attach command\n"
    "`!clear` — drain message queue"
)


def _handle_control(cmd: str, session: str, channel: str, client) -> None:
    if cmd == "!help":
        client.chat_postMessage(channel=channel, text=HELP_TEXT)

    elif cmd == "!status":
        idle = _is_idle(session)
        with _lock:
            q = _queues.get(session)
            depth = q.qsize() if q else 0
        status = "idle :white_check_mark:" if idle else "busy :hourglass_flowing_sand:"
        client.chat_postMessage(
            channel=channel,
            text=f"*`{session}`:* {status} · {depth} queued",
        )

    elif cmd == "!stop":
        try:
            subprocess.run(["tmux", "send-keys", "-t", session, "C-c"],
                           check=True, capture_output=True)
            _cancel_watchdog(session)
            client.chat_postMessage(channel=channel,
                                    text=f":octagonal_sign: Sent Ctrl-C to `{session}`")
        except subprocess.CalledProcessError:
            client.chat_postMessage(channel=channel,
                                    text=f":x: Could not send Ctrl-C to `{session}`")

    elif cmd == "!attach":
        client.chat_postMessage(
            channel=channel,
            text=f"```tmux attach -t {session}```",
        )

    elif cmd == "!clear":
        with _lock:
            q = _queues.get(session)
            cleared = 0
            if q:
                while not q.empty():
                    try:
                        q.get_nowait()
                        cleared += 1
                    except queue.Empty:
                        break
        client.chat_postMessage(
            channel=channel,
            text=f":wastebasket: Cleared {cleared} queued message(s)",
        )

    else:
        client.chat_postMessage(
            channel=channel, text=f"Unknown command `{cmd}`.  Try `!help`.",
        )


# ---------------------------------------------------------------------------
# Message routing
# ---------------------------------------------------------------------------


def _route_message(event: dict, client) -> None:
    if event.get("subtype") or event.get("bot_id"):
        return

    # Only top-level messages (ts == thread_ts means it's the parent)
    if event.get("thread_ts") and event.get("thread_ts") != event.get("ts"):
        return

    text = event.get("text", "").strip()
    if not text:
        return

    # Strip @-mention prefix from app_mention events
    text = re.sub(r"^<@[A-Z0-9]+>\s*", "", text).strip()
    if not text:
        return

    user = event.get("user", "")
    if ALLOWED_USERS and user not in ALLOWED_USERS:
        return

    channel = event.get("channel", "")
    session = _session_for_channel(channel)
    if not session:
        return

    if text.startswith("!"):
        cmd = text.split()[0].lower()
        _handle_control(cmd, session, channel, client)
    else:
        _enqueue(session, text, client)


@app.event("message")
def handle_message(event, client):
    _route_message(event, client)


@app.event("app_mention")
def handle_mention(event, client):
    _route_message(event, client)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not CHANNEL_MAP_PATH.exists() or CHANNEL_MAP_PATH.stat().st_size == 0:
        CHANNEL_MAP_PATH.write_text("{}")

    log.info("Starting shellphone relay")
    log.info("SHELLPHONE_DIR=%s", SHELLPHONE_DIR)
    log.info("Allowed users: %s", ALLOWED_USERS or ["<all>"])
    log.info("Watchdog timeout: %d min", WATCHDOG_TIMEOUT_SECS // 60)

    handler = SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"])
    handler.start()


if __name__ == "__main__":
    main()
