#!/usr/bin/env python3
"""
Chess: Claude Opus 4.6 (White) vs Stockfish (Black)

Requirements:
    pip install anthropic
    chess/  directory must be present (python-chess 1.11.2)
    stockfish binary on PATH or set STOCKFISH_PATH

Usage:
    python chess_game.py [--skill 0-20] [--time SECONDS] [--verbose]

Environment:
    ANTHROPIC_API_KEY  - Anthropic API key (required)
    STOCKFISH_PATH     - path to stockfish binary (default: /usr/games/stockfish)
"""

import argparse
import os
import random
import re
import sys

import anthropic
import chess
import chess.engine

MODEL = "claude-opus-4-6"
STOCKFISH_PATH = os.environ.get("STOCKFISH_PATH", "/usr/games/stockfish")

SYSTEM_PROMPT = """\
You are playing chess as White against Stockfish. Your goal is to win the game.

Each turn you receive:
- The current board position (ASCII diagram)
- The FEN notation
- The move history
- ALL legal moves in UCI format

You MUST respond with EXACTLY one UCI move from the legal moves list.
Output ONLY the move string (e.g. e2e4, g1f3, e1g1) — no explanation, no punctuation.\
"""


def render_board(board: chess.Board) -> str:
    PIECES = {
        "R": "♖", "N": "♘", "B": "♗", "Q": "♕", "K": "♔", "P": "♙",
        "r": "♜", "n": "♞", "b": "♝", "q": "♛", "k": "♚", "p": "♟",
    }
    lines = ["  a b c d e f g h"]
    for rank in range(7, -1, -1):
        row = f"{rank + 1} "
        for file in range(8):
            piece = board.piece_at(chess.square(file, rank))
            if piece is None:
                row += "· "
            else:
                row += PIECES.get(piece.symbol(), piece.symbol()) + " "
        lines.append(row.rstrip())
    lines.append("  a b c d e f g h")
    return "\n".join(lines)


def get_pgn(board: chess.Board) -> str:
    """Return the full game as a PGN move-text string."""
    try:
        return chess.Board().variation_san(board.move_stack)
    except Exception:
        return "(unavailable)"


def move_history_text(board: chess.Board) -> str:
    """Return move history in readable notation."""
    tmp = chess.Board()
    parts = []
    for i, move in enumerate(board.move_stack):
        if i % 2 == 0:
            parts.append(f"{i // 2 + 1}.")
        parts.append(tmp.san(move))
        tmp.push(move)
    return " ".join(parts) if parts else "(opening position)"


def get_claude_move(
    client: anthropic.Anthropic,
    board: chess.Board,
    verbose: bool,
) -> chess.Move:
    """Ask Claude Opus 4.6 to choose a move. Retries up to 3 times on invalid responses."""
    legal_uci = sorted(board.uci(m) for m in board.legal_moves)

    for attempt in range(3):
        if attempt == 0:
            prompt = (
                f"Board:\n{render_board(board)}\n\n"
                f"FEN: {board.fen()}\n"
                f"History: {move_history_text(board)}\n\n"
                f"Legal moves: {', '.join(legal_uci)}\n\n"
                "Output your UCI move:"
            )
        else:
            prompt = (
                f"FEN: {board.fen()}\n"
                f"You must pick exactly one move from this list: {', '.join(legal_uci)}\n"
                "Output ONLY the move string, nothing else:"
            )

        response = client.messages.create(
            model=MODEL,
            max_tokens=4096,
            thinking={"type": "adaptive"},
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": prompt}],
        )

        move_text = ""
        for block in response.content:
            if block.type == "thinking" and verbose:
                preview = block.thinking[:500].replace("\n", " ")
                ellipsis = "..." if len(block.thinking) > 500 else ""
                print(f"  [thinking] {preview}{ellipsis}")
            elif block.type == "text":
                move_text = block.text.strip().lower()

        # Extract a UCI move pattern from Claude's response
        match = re.search(r"\b([a-h][1-8][a-h][1-8][qrbn]?)\b", move_text)
        if match:
            uci_str = match.group(1)
            try:
                move = chess.Move.from_uci(uci_str)
                if move in board.legal_moves:
                    return move
            except ValueError:
                pass

        if verbose or attempt > 0:
            print(f"  [Claude returned '{move_text}' — not a valid move, retrying ({attempt + 1}/3)]")

    print("  [Warning: Claude failed to provide a valid move after 3 attempts; choosing randomly]")
    return random.choice(list(board.legal_moves))


def play(skill: int, move_time: float, verbose: bool) -> None:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("Error: ANTHROPIC_API_KEY environment variable is not set.")
        sys.exit(1)

    client = anthropic.Anthropic()

    try:
        engine = chess.engine.SimpleEngine.popen_uci(STOCKFISH_PATH)
    except FileNotFoundError:
        print(f"Stockfish not found at '{STOCKFISH_PATH}'.")
        print("Install: sudo apt install stockfish  /  brew install stockfish")
        print("Or set:  export STOCKFISH_PATH=/path/to/stockfish")
        sys.exit(1)

    engine.configure({"Skill Level": skill})
    board = chess.Board()

    print()
    print("=" * 52)
    print("  Claude Opus 4.6 (White)  vs  Stockfish (Black)")
    print(f"  Stockfish skill: {skill}/20  |  {move_time}s/move")
    print("=" * 52)
    print()

    try:
        while not board.is_game_over():
            print(render_board(board))
            print()

            if board.turn == chess.WHITE:
                print(f"  Move {board.fullmove_number} — Claude Opus 4.6 (White) is thinking...")
                move = get_claude_move(client, board, verbose)
                san = board.san(move)
                board.push(move)
                print(f"  ► Claude plays: {san}  ({move.uci()})")
            else:
                print(f"  Move {board.fullmove_number} — Stockfish (Black) is thinking...")
                result = engine.play(board, chess.engine.Limit(time=move_time))
                san = board.san(result.move)
                board.push(result.move)
                print(f"  ► Stockfish plays: {san}  ({result.move.uci()})")

            if board.is_check() and not board.is_checkmate():
                side = "White" if board.turn == chess.WHITE else "Black"
                print(f"  *** {side} is in check! ***")

            print()

    finally:
        engine.quit()

    # Final position
    print(render_board(board))
    print()
    print("=" * 52)
    print("  GAME OVER")

    outcome = board.outcome()
    if outcome is None:
        print("  Result: Game ended (no outcome)")
    elif outcome.winner == chess.WHITE:
        print("  Result: Claude Opus 4.6 (White) wins!   1-0")
    elif outcome.winner == chess.BLACK:
        print("  Result: Stockfish (Black) wins!   0-1")
    else:
        term = outcome.termination.name.replace("_", " ").title()
        print(f"  Result: Draw — {term}   1/2-1/2")

    print(f"  Moves played: {len(board.move_stack)} plies")
    print("=" * 52)
    print()
    print("PGN:")
    print(get_pgn(board))
    print()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Claude Opus 4.6 (White) vs Stockfish (Black)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python chess_game.py\n"
            "  python chess_game.py --skill 5 --time 0.5\n"
            "  python chess_game.py --skill 15 --verbose\n"
        ),
    )
    parser.add_argument(
        "--skill", type=int, default=10, metavar="N",
        help="Stockfish skill level 0–20 (default: 10)",
    )
    parser.add_argument(
        "--time", type=float, default=1.0, metavar="S",
        help="Stockfish seconds per move (default: 1.0)",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Show Claude's thinking excerpts",
    )
    args = parser.parse_args()

    if not 0 <= args.skill <= 20:
        parser.error("--skill must be between 0 and 20")
    if args.time <= 0:
        parser.error("--time must be positive")

    play(args.skill, args.time, args.verbose)


if __name__ == "__main__":
    main()
