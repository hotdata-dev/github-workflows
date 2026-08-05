"""Column metadata lookups."""

_CACHE: dict[tuple[str, str], list[str]] = {}


def get_columns(conn, workspace_id: str, table: str) -> list[str]:
    key = (workspace_id, table)
    cached = _CACHE.get(key)
    if cached is not None:
        return cached

    rows = conn.execute(
        "SELECT name FROM catalog.columns WHERE workspace_id = %s AND table_name = %s"
        " ORDER BY ordinal",
        (workspace_id, table),
    ).fetchall()
    columns = [row["name"] for row in rows]
    _CACHE[key] = columns
    return columns
