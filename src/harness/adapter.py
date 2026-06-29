"""Adapter subprocess wrapper.

Calls `adapters/<backend>.sh` with ADAPTER_* env vars and parses the
single-line JSON on stdout. The adapter contract is in
docs/adapter-contract.md.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Optional

DEFAULT_MAX_TURNS = 20


class AdapterError(Exception):
    pass


def _spec_max_turns(task_file: Path) -> Optional[int]:
    """Extract max_turns from YAML frontmatter (--- ... ---) of the spec file.

    Coordinators can override the default for large tasks:
      ---
      max_turns: 30
      ---
    """
    try:
        lines = task_file.read_text(encoding="utf-8").splitlines()
        in_fm = False
        for line in lines:
            stripped = line.strip()
            if stripped == "---":
                if not in_fm:
                    in_fm = True
                else:
                    break
            elif in_fm and stripped.startswith("max_turns:"):
                val = stripped.split(":", 1)[1].strip()
                return int(val)
    except Exception:
        pass
    return None


def call(
    backend: str,
    task_file: Path,
    worktree: Path,
    log_dir: Path,
    task_id: str,
    worker_id: str,
    worker_dir: Path,
    session_id: str = "",
    model: str = "",
    mock: bool = False,
    harness_home: Optional[Path] = None,
) -> dict:
    """Invoke the adapter and return parsed JSON dict.

    On failure to spawn / parse, returns the canonical adapter-error shape
    (`{ok:false, error:...}`) instead of raising — matches bash behavior.
    """
    home = harness_home or Path(os.environ["HARNESS_HOME"])
    sh = home / "adapters" / f"{backend}.sh"
    if not sh.is_file():
        return {"ok": False, "error": f"unknown_backend:{backend}"}

    # max_turns priority: spec frontmatter > ADAPTER_MAX_TURNS env > DEFAULT_MAX_TURNS
    max_turns = _spec_max_turns(task_file)
    if max_turns is None:
        env_val = os.environ.get("ADAPTER_MAX_TURNS")
        max_turns = int(env_val) if env_val else DEFAULT_MAX_TURNS

    env = os.environ.copy()
    env["ADAPTER_TASK_FILE"] = str(task_file)
    env["ADAPTER_WORKTREE"] = str(worktree)
    env["ADAPTER_SESSION_ID"] = session_id
    env["ADAPTER_LOG_DIR"] = str(log_dir)
    env["ADAPTER_TASK_ID"] = task_id
    env["ADAPTER_WORKER_ID"] = worker_id
    env["ADAPTER_WORKER_DIR"] = str(worker_dir)
    env["ADAPTER_MODEL"] = model
    env["ADAPTER_MAX_TURNS"] = str(max_turns)
    if mock:
        env["HARNESS_MOCK_ADAPTER"] = "1"

    try:
        proc = subprocess.run(
            ["bash", str(sh)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as e:
        return {"ok": False, "error": f"spawn_failed:{e}"}

    out = proc.stdout.strip()
    if not out:
        return {"ok": False, "error": f"empty_stdout:exit={proc.returncode}"}

    try:
        return json.loads(out.splitlines()[-1])
    except json.JSONDecodeError as e:
        return {"ok": False, "error": f"json_parse:{e}:{out[:200]}"}
