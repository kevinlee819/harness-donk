"""harness-task — coordinator-facing task management CLI.

Replaces the bash version at coordinator/tools/harness-task.

See docs/interfaces.md §2.1.

Commands:
  add [--id ID] [--priority N] [--depends-on T-A,T-B] [--spec PATH]
        With no --spec, reads spec body from stdin and writes specs/<id>.md
  query [--task ID | --status STATE]
  history TASK_ID
  cancel TASK_ID
  answer TASK_ID ANSWER_TEXT
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from pathlib import Path

from .. import db


def _project_db() -> Path:
    """Locate .harness/harness.db relative to cwd (or via HARNESS_DB env)."""
    env = os.environ.get("HARNESS_DB")
    if env:
        return Path(env)
    return Path.cwd() / ".harness" / "harness.db"


def _ensure_initialized() -> None:
    p = _project_db()
    if not p.exists():
        json.dump({"ok": False, "error": "harness not initialized"}, sys.stderr)
        sys.stderr.write("\n")
        sys.exit(2)
    os.environ["HARNESS_DB"] = str(p)


def _atomic_write(path: Path, content: str) -> None:
    """Write `*.tmp` then rename. Matches bash atomic_write_text behavior."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(content)
    os.replace(tmp, path)


def _now_iso() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def cmd_add(args: argparse.Namespace) -> int:
    task_id = args.id or db.gen_task_id()
    deps: list[str] | None = None
    if args.depends_on:
        deps = [s.strip() for s in args.depends_on.split(",") if s.strip()]

    if args.spec:
        spec_path = args.spec
        full = Path.cwd() / spec_path
        if not full.exists():
            json.dump(
                {"ok": False, "error": f"spec not found: {spec_path}"},
                sys.stdout,
            )
            sys.stdout.write("\n")
            return 1
    else:
        # Read from stdin
        body = sys.stdin.read()
        spec_path = f"specs/{task_id}.md"
        (Path.cwd() / "specs").mkdir(parents=True, exist_ok=True)
        (Path.cwd() / spec_path).write_text(body)

    try:
        db.add_task(task_id, spec_path, args.priority, deps)
    except Exception as e:
        json.dump(
            {"ok": False, "error": "db_add_task_failed", "detail": str(e), "task_id": task_id},
            sys.stdout,
        )
        sys.stdout.write("\n")
        return 1

    json.dump({"ok": True, "task_id": task_id, "spec": spec_path}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_query(args: argparse.Namespace) -> int:
    if args.task:
        rows = db.query_status(args.task)
    elif args.status:
        rows = db.query_by_status(args.status)
    else:
        rows = db.query_status()
    for r in rows:
        print("\t".join(str(x) for x in r))
    return 0


def cmd_history(args: argparse.Namespace) -> int:
    rows = db.query_history(args.task_id)
    for r in rows:
        print("\t".join(str(x) for x in r))
    return 0


def cmd_cancel(args: argparse.Namespace) -> int:
    db.transition(args.task_id, "failed", "user_cancelled")
    json.dump({"ok": True, "task_id": args.task_id, "cancelled": True}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def cmd_answer(args: argparse.Namespace) -> int:
    payload = {
        "schema_version": 1,
        "task_id": args.task_id,
        "answer": args.answer,
        "decided_by": "coordinator",
        "ts": _now_iso(),
    }
    inbox = Path.cwd() / ".harness" / "inbox" / f"{args.task_id}.answer"
    _atomic_write(inbox, json.dumps(payload))
    json.dump({"ok": True, "task_id": args.task_id, "answered": True}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="harness-task")
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("add")
    a.add_argument("--id")
    a.add_argument("--priority", type=int, default=100)
    a.add_argument("--depends-on", default=None)
    a.add_argument("--spec", default=None)
    a.set_defaults(func=cmd_add)

    q = sub.add_parser("query")
    q.add_argument("--task")
    q.add_argument("--status")
    q.set_defaults(func=cmd_query)

    h = sub.add_parser("history")
    h.add_argument("task_id")
    h.set_defaults(func=cmd_history)

    c = sub.add_parser("cancel")
    c.add_argument("task_id")
    c.set_defaults(func=cmd_cancel)

    ans = sub.add_parser("answer")
    ans.add_argument("task_id")
    ans.add_argument("answer", nargs="+")
    ans.set_defaults(func=cmd_answer)

    return p


def main(argv: list[str] | None = None) -> int:
    _ensure_initialized()
    parser = build_parser()
    args = parser.parse_args(argv)
    # answer takes nargs="+" so we join into single string
    if getattr(args, "cmd", None) == "answer":
        args.answer = " ".join(args.answer)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
