"""Nightly sync of source tables into the catalog."""

import logging

log = logging.getLogger(__name__)


def sync_table(source, target, table: str) -> int:
    """Full refresh: read every row and replace the target."""
    rows = source.execute(
        "SELECT id, name, updated_at FROM {} ORDER BY id".format(table)
    ).fetchall()
    target.execute("TRUNCATE TABLE catalog.{}".format(table))
    target.insert_many("catalog.{}".format(table), rows)
    log.info("synced %s rows into %s", len(rows), table)
    return len(rows)


def sync_all(source, target, tables: list[str]) -> dict[str, int]:
    return {table: sync_table(source, target, table) for table in tables}
