"""Paginated reads over the catalog tables."""

from dataclasses import dataclass

DEFAULT_PER_PAGE = 50
MAX_PER_PAGE = 500


@dataclass(frozen=True)
class Page:
    items: list
    total: int
    page: int
    per_page: int

    @property
    def has_more(self) -> bool:
        return self.page * self.per_page < self.total


def list_tables(conn, workspace_id: str, page: int = 1, per_page: int = DEFAULT_PER_PAGE) -> Page:
    per_page = min(max(per_page, 1), MAX_PER_PAGE)
    offset = (max(page, 1) - 1) * per_page
    rows = conn.execute(
        "SELECT name, row_count FROM catalog.tables WHERE workspace_id = %s"
        " ORDER BY name LIMIT %s OFFSET %s",
        (workspace_id, per_page, offset),
    ).fetchall()
    total = conn.execute(
        "SELECT count(*) FROM catalog.tables WHERE workspace_id = %s", (workspace_id,)
    ).scalar()
    return Page(items=rows, total=total, page=max(page, 1), per_page=per_page)


def list_columns(conn, table_id: str, page: int = 1, per_page: int = DEFAULT_PER_PAGE) -> Page:
    per_page = min(max(per_page, 1), MAX_PER_PAGE)
    offset = (max(page, 1) - 1) * per_page
    rows = conn.execute(
        "SELECT name, data_type FROM catalog.columns WHERE table_id = %s"
        " ORDER BY ordinal LIMIT %s OFFSET %s",
        (table_id, per_page, offset),
    ).fetchall()
    total = conn.execute(
        "SELECT count(*) FROM catalog.columns WHERE table_id = %s", (table_id,)
    ).scalar()
    return Page(items=rows, total=total, page=max(page, 1), per_page=per_page)
