"""Nightly sync of source tables into the catalog."""

import logging
from datetime import datetime, timezone

log = logging.getLogger(__name__)

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def _watermark(target, table: str) -> datetime:
    row = target.execute(
        "SELECT last_updated_at FROM sync_state WHERE table_name = %s", (table,)
    ).fetchone()
    return row["last_updated_at"] if row else EPOCH


def _advance_watermark(target, table: str, value: datetime) -> None:
    target.execute(
        "INSERT INTO sync_state (table_name, last_updated_at) VALUES (%s, %s)"
        " ON CONFLICT (table_name) DO UPDATE SET last_updated_at = EXCLUDED.last_updated_at",
        (table, value),
    )


def sync_table(source, target, table: str) -> int:
    """Incremental: read only what changed since the last run."""
    since = _watermark(target, table)
    rows = source.execute(
        "SELECT id, name, updated_at FROM {} WHERE updated_at > %s"
        " ORDER BY updated_at".format(table),
        (since,),
    ).fetchall()
    if not rows:
        log.info("no changes for %s since %s", table, since)
        return 0

    target.upsert_many("catalog.{}".format(table), rows, key="id")
    _advance_watermark(target, table, rows[-1]["updated_at"])
    log.info("synced %s changed rows into %s", len(rows), table)
    return len(rows)


def sync_all(source, target, tables: list[str]) -> dict[str, int]:
    return {table: sync_table(source, target, table) for table in tables}
