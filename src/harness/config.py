"""Read ~/.config/harness/config (key=value lines).

Ports orchestrator.sh `_conf_value`. The file is line-based with `key = value`
or `key=value`; whitespace stripped from both sides.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional


def _config_path() -> Path:
    base = os.environ.get("HARNESS_CONFIG_DIR") or os.path.expanduser("~/.config/harness")
    return Path(base) / "config"


def read_config(key: str, default: Optional[str] = None) -> Optional[str]:
    p = _config_path()
    if not p.is_file():
        return default
    for line in p.read_text().splitlines():
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        if k.strip() == key:
            return v.strip()
    return default
