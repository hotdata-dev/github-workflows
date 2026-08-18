"""Render query results for download."""

import io
import json
from typing import Any, Iterable

DEFAULT_DELIMITER = ","


def to_json(columns: list[str], rows: Iterable[Iterable[Any]]) -> str:
    return json.dumps([dict(zip(columns, row)) for row in rows], default=str)


def _needs_quoting(field: str, sep: str) -> bool:
    return sep in field or '"' in field or "\n" in field or "\r" in field


def _render_field(value: Any, sep: str) -> str:
    field = "" if value is None else str(value)
    if not _needs_quoting(field, sep):
        return field
    return '"' + field.replace('"', '""') + '"'


def to_csv(
    columns: list[str],
    rows: Iterable[Iterable[Any]],
    sep: str = DEFAULT_DELIMITER,
    header: bool = True,
) -> str:
    """Render rows as RFC 4180 CSV. Always emits a header row."""
    out = io.StringIO()
    if header:
        out.write(sep.join(_render_field(name, sep) for name in columns))
        out.write("\r\n")
    for row in rows:
        out.write(sep.join(_render_field(value, sep) for value in row))
        out.write("\r\n")
    return out.getvalue()
