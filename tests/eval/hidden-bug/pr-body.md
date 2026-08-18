The nightly catalog sync was doing a full refresh of every table, which is now the slowest job we
run. This switches it to an incremental read keyed on `updated_at`.

The watermark is stored per table in `sync_state` and advanced to the newest row we saw.
