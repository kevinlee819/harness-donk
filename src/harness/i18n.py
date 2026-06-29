"""Lightweight i18n — t(key, **kwargs) returns a localized string.

HARNESS_LANG env selects locale (default: "en"). Falls back to English if
the requested locale file is missing.

Catalog files live at <harness_home>/i18n/{lang}.json.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional

_catalog: Optional[dict] = None
_loaded_lang: Optional[str] = None


def _harness_home() -> Path:
    env = os.environ.get("HARNESS_HOME")
    if env:
        return Path(env)
    # Module is at <home>/src/harness/i18n.py
    return Path(__file__).resolve().parent.parent.parent


def _load() -> dict:
    global _catalog, _loaded_lang
    lang = os.environ.get("HARNESS_LANG", "en").lower().strip()
    if _catalog is not None and _loaded_lang == lang:
        return _catalog
    i18n_dir = _harness_home() / "i18n"
    path = i18n_dir / f"{lang}.json"
    if not path.exists() and lang != "en":
        path = i18n_dir / "en.json"
    try:
        _catalog = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        _catalog = {}
    _loaded_lang = lang
    return _catalog


def t(key: str, **kwargs: object) -> str:
    """Return localized string for key, formatted with kwargs if provided.

    Falls back to the key itself if the key is not found in the catalog.
    """
    template = _load().get(key, key)
    if kwargs:
        try:
            return template.format(**kwargs)
        except (KeyError, ValueError):
            return template
    return template
