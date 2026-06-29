"""harness-watchdog tick — one watchdog cycle. Invoked by bin/harness-watchdog loop.

Stdout: one-line JSON summary (for log tailing / testing).
Stderr: standard logging output.
Exit:   0 always (loop runs forever; ticks should never abort the daemon).
"""

from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path

from harness.watchdog import tick


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="[watchdog %(asctime)s] %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stderr,
    )
    db_path = os.environ.get("HARNESS_DB")
    if not db_path:
        print(json.dumps({"ok": False, "error": "HARNESS_DB not set"}))
        return 0
    project_dir = Path(db_path).parent.parent
    try:
        summary = tick(project_dir)
        print(json.dumps({"ok": True, **summary}, ensure_ascii=False))
    except Exception as e:
        logging.exception("tick crashed")
        print(json.dumps({"ok": False, "error": str(e)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
