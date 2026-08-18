"""Write query results to a sink."""

from typing import Any, Iterable


def write_results(sink, columns: list[str], rows: Iterable[Iterable[Any]]) -> int:
    """Buffer every row, then write once."""
    buffered = list(rows)
    sink.write_header(columns)
    sink.write_rows(buffered)
    return len(buffered)
