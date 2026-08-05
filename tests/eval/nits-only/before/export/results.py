"""Render query results for download."""

import json
from typing import Any, Iterable

DEFAULT_DELIMITER = ","


def to_json(columns: list[str], rows: Iterable[Iterable[Any]]) -> str:
    return json.dumps([dict(zip(columns, row)) for row in rows], default=str)
