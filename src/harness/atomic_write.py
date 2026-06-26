"""Atomic file write — write to .tmp then rename. Crash-safe.

Ports lib/atomic_write.sh. The rename is atomic on POSIX file systems.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Union


def write_json(path: Union[str, Path], obj: Any) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(obj, separators=(",", ":"), ensure_ascii=False) + "\n")
    os.replace(tmp, p)


def write_text(path: Union[str, Path], content: str) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(content)
    os.replace(tmp, p)
