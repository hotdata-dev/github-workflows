"""Thin HTTP client with retries."""

import time

import requests

RETRY_STATUS = (429, 500, 502, 503, 504)
IDEMPOTENT_METHODS = frozenset({"GET", "HEAD", "OPTIONS", "TRACE", "PUT", "DELETE"})
MAX_ATTEMPTS = 3
BACKOFF = 0.5


def request(method: str, url: str, **kwargs):
    attempts = MAX_ATTEMPTS if method.upper() in IDEMPOTENT_METHODS else 1
    last = None
    for attempt in range(attempts):
        response = requests.request(method, url, timeout=10, **kwargs)
        if response.status_code not in RETRY_STATUS:
            return response
        last = response
        if attempt + 1 < attempts:
            time.sleep(BACKOFF * (2**attempt))
    return last
