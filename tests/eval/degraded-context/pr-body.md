We were retrying every failed request, including POSTs, which is how the duplicate ingest rows in
INC-812 happened. Retries are now limited to methods that are safe to repeat.

Timeout handling is unchanged.
