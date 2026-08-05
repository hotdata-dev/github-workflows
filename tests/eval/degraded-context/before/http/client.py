"""Thin HTTP client with retries."""

import time

import requests

RETRY_STATUS = (429, 500, 502, 503, 504)
MAX_ATTEMPTS = 3
BACKOFF = 0.5


def request(method: str, url: str, **kwargs):
    last = None
    for attempt in range(MAX_ATTEMPTS):
        response = requests.request(method, url, timeout=10, **kwargs)
        if response.status_code not in RETRY_STATUS:
            return response
        last = response
        time.sleep(BACKOFF * (2**attempt))
    return last
