"""harness-db CLI — thin bridge for bash callers (orchestrator.sh, bin/harness).

Each subcommand is a short DB op. stdout = result (TSV or single value).
stderr = errors. Exit 0 success, non-zero on error.

See docs/interfaces.md §5.1 for function contracts.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .. import db


def _schema_path() -> Path:
    home = os.environ.get("HARNESS_HOME")
    if not home:
        print("HARNESS_HOME not set", file=sys.stderr)
        sys.exit(2)
    return Path(home) / "schema" / "harness.sql"


def cmd_init(_args: argparse.Namespace) -> int:
    db.init(_schema_path())
    return 0


def cmd_claim(args: argparse.Namespace) -> int:
    row = db.claim(args.worker_id)
    if row:
        print(f"{row[0]}|{row[1]}")
    return 0


def cmd_transition(args: argparse.Namespace) -> int:
    db.transition(args.task_id, args.to_state, args.reason)
    return 0


def cmd_set_branch(args: argparse.Namespace) -> int:
    db.set_branch(args.task_id, args.branch)
    return 0


def cmd_inc_retries(args: argparse.Namespace) -> int:
    db.inc_retries(args.task_id)
    return 0


def cmd_get_retries(args: argparse.Namespace) -> int:
    print(db.get_retries(args.task_id))
    return 0


def cmd_register_session(args: argparse.Namespace) -> int:
    db.register_session(args.task_id, args.backend, args.session_id)
    return 0


def cmd_get_session(args: argparse.Namespace) -> int:
    s = db.get_session(args.task_id, args.backend)
    if s is not None:
        print(s)
    return 0


def _parse_optional_num(s: str, cast):
    if s == "" or s.lower() == "null" or s.lower() == "none":
        return None
    try:
        return cast(s)
    except ValueError:
        return None


def cmd_log_call(args: argparse.Namespace) -> int:
    db.log_call(
        task_id=args.task_id,
        worker_id=args.worker_id,
        backend=args.backend,
        session_id=args.session_id or None,
        exit_code=int(args.exit_code),
        cost_usd=_parse_optional_num(args.cost_usd, float),
        num_turns=_parse_optional_num(args.num_turns, int),
        duration_ms=_parse_optional_num(args.duration_ms, int),
        files_changed=int(args.files_changed),
    )
    return 0


def cmd_today_cost(_args: argparse.Namespace) -> int:
    print(db.today_cost())
    return 0


def _tsv_join(row: tuple) -> str:
    """Join row by tab, substituting '-' for empty strings.

    Reason: bash `IFS=$'\\t' read` collapses consecutive tabs (because tab is
    a whitespace IFS char), so empty middle fields shift downstream columns.
    Emit '-' as a sentinel; bash callers treat '-' as 'no value'.
    """
    return "\t".join("-" if x == "" else str(x) for x in row)


def cmd_query_status(args: argparse.Namespace) -> int:
    rows = db.query_status(args.task_id)
    for r in rows:
        print(_tsv_join(r))
    return 0


def cmd_query_by_status(args: argparse.Namespace) -> int:
    rows = db.query_by_status(args.status)
    for r in rows:
        print(_tsv_join(r))
    return 0


def cmd_query_history(args: argparse.Namespace) -> int:
    rows = db.query_history(args.task_id)
    for r in rows:
        print("\t".join(str(x) for x in r))
    return 0


def cmd_gen_task_id(_args: argparse.Namespace) -> int:
    print(db.gen_task_id())
    return 0


def cmd_event_write(args: argparse.Namespace) -> int:
    """Write event row. Payload JSON comes from --payload or stdin."""
    if args.payload:
        payload = json.loads(args.payload)
    else:
        data = sys.stdin.read().strip()
        payload = json.loads(data) if data else {}
    eid = db.event_write(args.event_type, args.task_id or None, payload)
    print(eid)
    return 0


def cmd_event_pending(_args: argparse.Namespace) -> int:
    rows = db.event_query_pending()
    for r in rows:
        # id ts event_type task_id payload(escaped JSON one line)
        print("\t".join(str(x) for x in r))
    return 0


def cmd_event_ack(args: argparse.Namespace) -> int:
    db.event_mark_delivered(int(args.event_id))
    return 0


def cmd_session_touch(args: argparse.Namespace) -> int:
    db.session_touch(args.task_id, args.backend)
    return 0


def cmd_inc_redispatches(args: argparse.Namespace) -> int:
    db.inc_redispatches(args.task_id)
    return 0


def cmd_query_orphans(args: argparse.Namespace) -> int:
    rows = db.query_orphans(int(args.threshold_minutes))
    for r in rows:
        print(_tsv_join(r))
    return 0


def cmd_query_blocked_overdue(args: argparse.Namespace) -> int:
    rows = db.query_blocked_overdue(int(args.threshold_hours))
    for r in rows:
        print(_tsv_join(r))
    return 0


def cmd_stuck_queued(_args: argparse.Namespace) -> int:
    for tid in db.query_stuck_queued():
        print(tid)
    return 0


def cmd_blocking_failed(_args: argparse.Namespace) -> int:
    """Print the first failed task that is blocking at least one queued task."""
    tids = db.query_blocking_failed()
    for tid in tids:
        print(tid)
    return 0


def cmd_get_spec(args: argparse.Namespace) -> int:
    p = db.get_spec_path(args.task_id)
    if p is not None:
        print(p)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="harness-db")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init").set_defaults(func=cmd_init)

    s = sub.add_parser("claim")
    s.add_argument("worker_id")
    s.set_defaults(func=cmd_claim)

    s = sub.add_parser("transition")
    s.add_argument("task_id")
    s.add_argument("to_state")
    s.add_argument("reason", nargs="?", default="")
    s.set_defaults(func=cmd_transition)

    s = sub.add_parser("set-branch")
    s.add_argument("task_id")
    s.add_argument("branch")
    s.set_defaults(func=cmd_set_branch)

    s = sub.add_parser("inc-retries")
    s.add_argument("task_id")
    s.set_defaults(func=cmd_inc_retries)

    s = sub.add_parser("get-retries")
    s.add_argument("task_id")
    s.set_defaults(func=cmd_get_retries)

    s = sub.add_parser("register-session")
    s.add_argument("task_id")
    s.add_argument("backend")
    s.add_argument("session_id")
    s.set_defaults(func=cmd_register_session)

    s = sub.add_parser("get-session")
    s.add_argument("task_id")
    s.add_argument("backend")
    s.set_defaults(func=cmd_get_session)

    s = sub.add_parser("log-call")
    s.add_argument("task_id")
    s.add_argument("worker_id")
    s.add_argument("backend")
    s.add_argument("session_id")
    s.add_argument("exit_code")
    s.add_argument("cost_usd")
    s.add_argument("num_turns")
    s.add_argument("duration_ms")
    s.add_argument("files_changed")
    s.set_defaults(func=cmd_log_call)

    sub.add_parser("today-cost").set_defaults(func=cmd_today_cost)

    s = sub.add_parser("query-status")
    s.add_argument("task_id", nargs="?", default=None)
    s.set_defaults(func=cmd_query_status)

    s = sub.add_parser("query-by-status")
    s.add_argument("status")
    s.set_defaults(func=cmd_query_by_status)

    s = sub.add_parser("query-history")
    s.add_argument("task_id")
    s.set_defaults(func=cmd_query_history)

    sub.add_parser("gen-task-id").set_defaults(func=cmd_gen_task_id)

    s = sub.add_parser("event-write")
    s.add_argument("event_type",
                   choices=["needs_decision", "task_completed",
                            "task_failed", "budget_exceeded"])
    s.add_argument("--task", dest="task_id", default=None)
    s.add_argument("--payload", default=None,
                   help="JSON string; if omitted reads stdin")
    s.set_defaults(func=cmd_event_write)

    sub.add_parser("event-pending").set_defaults(func=cmd_event_pending)
    sub.add_parser("stuck-queued").set_defaults(func=cmd_stuck_queued)
    sub.add_parser("blocking-failed").set_defaults(func=cmd_blocking_failed)

    s = sub.add_parser("event-ack")
    s.add_argument("event_id")
    s.set_defaults(func=cmd_event_ack)

    s = sub.add_parser("session-touch")
    s.add_argument("task_id")
    s.add_argument("backend")
    s.set_defaults(func=cmd_session_touch)

    s = sub.add_parser("inc-redispatches")
    s.add_argument("task_id")
    s.set_defaults(func=cmd_inc_redispatches)

    s = sub.add_parser("query-orphans")
    s.add_argument("threshold_minutes")
    s.set_defaults(func=cmd_query_orphans)

    s = sub.add_parser("query-blocked-overdue")
    s.add_argument("threshold_hours")
    s.set_defaults(func=cmd_query_blocked_overdue)

    s = sub.add_parser("get-spec")
    s.add_argument("task_id")
    s.set_defaults(func=cmd_get_spec)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
