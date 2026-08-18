Large result sets were buffered whole before being written, which is what OOM-killed the export
worker in INC-830. Results now stream in fixed-size chunks.

Fourth round of this — the fetch-size handling and the cancellation path from earlier reviews are
both addressed.
