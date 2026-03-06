"""shellphone — Slack ↔ tmux relay bot.

Listens for Slack messages in mapped channels and dispatches them to the
corresponding tmux session via `tmux send-keys`.  All outbound Slack
notifications (prompts, tool-use updates, final responses) are sent by the
hook scripts that the CLI tool invokes directly — this process never reads
terminal output.
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
load_dotenv()  # also accept .env in cwd

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

app = App(token=os.environ["SLACK_BOT_TOKEN"])

# ---------------------------------------------------------------------------
# Per-session state
# ---------------------------------------------------------------------------

_session_queues: dict[str, queue.Queue] = {}
_session_threads: dict[str, threading.Thread] = {}
_watchdog_timers: dict[str, threading.Timer] = {}
_state_lock = threading.Lock()

# ---------------------------------------------------------------------------
# Channel-map helpers
# ---------------------------------------------------------------------------


def _load_channel_map() -> dict[str, str]:
    lock = FileLock(str(CHANNEL_MAP_PATH) + ".lock", timeout=5)
    with lock:
        if CHANNEL_MAP_PATH.exists() and CHANNEL_MAP_PATH.stat().st_size > 0:
            return json.loads(CHANNEL_MAP_PATH.read_text())
    return {}


def session_for_channel(channel_id: str) -> str | None:
    """Return the tmux session name mapped to *channel_id*, or None."""
    for session, cid in _load_channel_map().items():
        if cid == channel_id:
            return session
    return None


# ---------------------------------------------------------------------------
# Semaphore / state-file helpers
# ---------------------------------------------------------------------------


def _session_dir(session: str) -> Path:
    return DATA_DIR / session


def is_idle(session: str) -> bool:
    """True when the semaphore file is present (session ready for input)."""
    return (_session_dir(session) / "semaphore").exists()


def _read_file(session: str, name: str) -> str | None:
    p = _session_dir(session) / name
    return p.read_text().strip() if p.exists() else None


# ---------------------------------------------------------------------------
# Watchdog
# ---------------------------------------------------------------------------


def _watchdog_fired(session: str, client) -> None:
    log.warning("Watchdog fired for session %s", session)
    cmap = _load_channel_map()
    channel = cmap.get(session)
    if not channel:
        return
    thread_ts = _read_file(session, "thread-ts")
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
        log.error("Watchdog post failed: %s", exc)


def _start_watchdog(session: str, client) -> None:
    _cancel_watchdog(session)
    t = threading.Timer(WATCHDOG_TIMEOUT_SECS, _watchdog_fired, args=(session, client))
    t.daemon = True
    t.start()
    _watchdog_timers[session] = t


def _cancel_watchdog(session: str) -> None:
    t = _watchdog_timers.pop(session, None)
    if t:
        t.cancel()


# ---------------------------------------------------------------------------
# Dispatch loop (one thread per session)
# ---------------------------------------------------------------------------


def _dispatch_loop(session: str, q: queue.Queue, client) -> None:
    log.info("Dispatch loop started for session=%s", session)
    while True:
        text = q.get()
        log.info("Dispatch: waiting for idle  session=%s  qsize=%d", session, q.qsize())

        # Poll until semaphore appears (session finished previous turn)
        waited = 0
        while not is_idle(session):
            time.sleep(0.5)
            waited += 1
            if waited % 20 == 0:
                log.debug("Still waiting for idle on session=%s (%ds)", session, waited // 2)

        log.info("Dispatch: sending to tmux  session=%s  text=%r", session, text[:80])
        try:
            subprocess.run(
                ["tmux", "send-keys", "-t", session, "-l", text],
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["tmux", "send-keys", "-t", session, "Enter"],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as exc:
            log.error("tmux send-keys failed for session=%s: %s", session, exc.stderr.decode())
            cmap = _load_channel_map()
            channel = cmap.get(session)
            if channel:
                try:
                    client.chat_postMessage(
                        channel=channel,
                        text=f":x: Failed to relay message to `{session}` — is the tmux session still alive?",
                    )
                except Exception:
                    pass
            q.task_done()
            continue

        _start_watchdog(session, client)
        q.task_done()


def _ensure_dispatch_thread(session: str, client) -> None:
    with _state_lock:
        existing = _session_threads.get(session)
        if existing and existing.is_alive():
            return
        q: queue.Queue = queue.Queue()
        _session_queues[session] = q
        t = threading.Thread(
            target=_dispatch_loop,
            args=(session, q, client),
            name=f"dispatch-{session}",
            daemon=True,
        )
        t.start()
        _session_threads[session] = t
        log.info("Started dispatch thread for session=%s", session)


# ---------------------------------------------------------------------------
# Control commands
# ---------------------------------------------------------------------------

HELP_TEXT = (
    "*Shellphone control commands:*\n"
    "`!help` — show this message\n"
    "`!status` — session status and queue depth\n"
    "`!stop` — send Ctrl-C to the session\n"
    "`!attach` — show the tmux attach command\n"
    "`!clear` — drain the pending message queue"
)


def _handle_control(text: str, session: str, channel: str, client) -> None:
    cmd = text.strip().split()[0].lower()

    if cmd == "!help":
        client.chat_postMessage(channel=channel, text=HELP_TEXT)

    elif cmd == "!status":
        status = "idle :white_check_mark:" if is_idle(session) else "busy :hourglass_flowing_sand:"
        q = _session_queues.get(session)
        qsize = q.qsize() if q else 0
        client.chat_postMessage(
            channel=channel,
            text=f"*Session `{session}`:* {status} · {qsize} message(s) queued",
        )

    elif cmd == "!stop":
        try:
            subprocess.run(["tmux", "send-keys", "-t", session, "C-c"], check=True, capture_output=True)
            _cancel_watchdog(session)
            client.chat_postMessage(channel=channel, text=f":octagonal_sign: Sent Ctrl-C to `{session}`")
        except subprocess.CalledProcessError as exc:
            client.chat_postMessage(channel=channel, text=f":x: Could not send Ctrl-C: `{exc}`")

    elif cmd == "!attach":
        client.chat_postMessage(
            channel=channel,
            text=f"Attach to the session:\n```tmux attach -t {session}```",
        )

    elif cmd == "!clear":
        q = _session_queues.get(session)
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
            text=f":wastebasket: Cleared {cleared} queued message(s) for `{session}`",
        )

    else:
        client.chat_postMessage(
            channel=channel,
            text=f":question: Unknown command `{cmd}`. Try `!help`.",
        )


# ---------------------------------------------------------------------------
# Message handler
# ---------------------------------------------------------------------------


def _route_message(event: dict, client) -> None:
    """Core routing logic shared by message and app_mention handlers."""
    # Ignore edits, deletions, and bot-posted messages
    if event.get("subtype") or event.get("bot_id"):
        return

    # Ignore replies inside threads (we only handle top-level messages)
    ts = event.get("ts", "")
    thread_ts = event.get("thread_ts")
    if thread_ts and thread_ts != ts:
        return

    channel = event.get("channel", "")
    user = event.get("user", "")
    text = event.get("text", "").strip()

    if not text:
        return

    # Strip @-mention prefix (present when app_mention fires)
    text = re.sub(r"^<@[A-Z0-9]+>\s*", "", text).strip()
    if not text:
        return

    # Authorization
    if ALLOWED_USERS and user not in ALLOWED_USERS:
        log.debug("Ignoring message from unauthorized user=%s", user)
        return

    # Resolve tmux session for this channel
    session = session_for_channel(channel)
    if not session:
        log.debug("No session mapped to channel=%s", channel)
        return

    # Control commands
    if text.startswith("!"):
        _handle_control(text, session, channel, client)
        return

    # Queue for dispatch
    _ensure_dispatch_thread(session, client)
    _session_queues[session].put(text)
    log.info("Queued for session=%s  qsize=%d  text=%r", session, _session_queues[session].qsize(), text[:60])


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
