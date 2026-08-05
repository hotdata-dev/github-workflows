"""Command table for the CLI.

Unchanged by this pull request; here so the reviewer has surrounding context to read.
"""


def _query(args: list[str]) -> int:
    print("query: {}".format(" ".join(args)))
    return 0


def _tables(args: list[str]) -> int:
    print("tables: {}".format(" ".join(args)))
    return 0


def _login(args: list[str]) -> int:
    print("login: {}".format(" ".join(args)))
    return 0


COMMANDS = {
    "query": _query,
    "tables": _tables,
    "login": _login,
}
