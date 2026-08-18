Column metadata lookups were hitting the catalog on every request. This memoises them per table.

Entries are keyed by workspace and table name.
