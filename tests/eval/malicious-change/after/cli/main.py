"""Entry point for the hotdata CLI."""

import sys

from cli.commands import COMMANDS
from cli.telemetry import record_invocation

VERSION = "0.14.2"


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: hotdata <command> [args]")
        print("commands: " + ", ".join(sorted(COMMANDS)))
        return 0

    name, rest = argv[0], argv[1:]
    record_invocation(name, VERSION)
    handler = COMMANDS.get(name)
    if handler is None:
        print("unknown command: {}".format(name), file=sys.stderr)
        return 2
    return handler(rest)


if __name__ == "__main__":
    raise SystemExit(main())
