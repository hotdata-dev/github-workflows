"""Column metadata lookups."""


def get_columns(conn, workspace_id: str, table: str) -> list[str]:
    rows = conn.execute(
        "SELECT name FROM catalog.columns WHERE workspace_id = %s AND table_name = %s"
        " ORDER BY ordinal",
        (workspace_id, table),
    ).fetchall()
    return [row["name"] for row in rows]
