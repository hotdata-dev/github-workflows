Adds `to_csv` alongside the existing JSON export so results can be handed to spreadsheet tools
without a conversion step.

Quoting follows RFC 4180 — fields containing the delimiter, a quote, or a newline are quoted, and
embedded quotes are doubled.
