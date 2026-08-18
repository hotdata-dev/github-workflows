`list_tables` and `list_columns` computed the same offset from `page` and `per_page`. Pulled it
into `_offset` so the two cannot drift.

No behaviour change — both call sites were already clamping `page` to a minimum of 1.
