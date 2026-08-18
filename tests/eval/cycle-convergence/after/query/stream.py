"""Write query results to a sink."""

from typing import Any, Iterable, Iterator

CHUNK_ROWS = 5_000
CHUNK_BYTES = 8 * 1024 * 1024


def _chunks(rows: Iterable[Iterable[Any]], size: int) -> Iterator[list]:
    batch: list = []
    for row in rows:
        batch.append(row)
        if len(batch) >= size:
            yield batch
            batch = []
    if batch:
        yield batch


def write_results(sink, columns: list[str], rows: Iterable[Iterable[Any]]) -> int:
    """Stream rows to the sink in chunks of at most CHUNK_ROWS."""
    written = 0
    sink.write_header(columns)
    for batch in _chunks(rows, CHUNK_ROWS):
        if sink.cancelled:
            break
        sink.write_rows(batch)
        written += len(batch)
        sink.flush()
    return written
