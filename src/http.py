"""Small retry helper shared by both API clients (429 and 5xx with backoff)."""
import time

import requests

from .log import log

RETRY_STATUSES = {429, 500, 502, 503, 504}


def request_with_retry(session: requests.Session, method: str, url: str, attempts: int = 5, **kwargs):
    delay = 1.0
    for attempt in range(1, attempts + 1):
        resp = session.request(method, url, timeout=60, **kwargs)
        if resp.status_code not in RETRY_STATUSES or attempt == attempts:
            return resp
        retry_after = resp.headers.get("Retry-After")
        wait = float(retry_after) if retry_after and retry_after.isdigit() else delay
        log("WARNING", "Retrying request", method=method, url=url, status=resp.status_code, wait_s=wait)
        time.sleep(wait)
        delay = min(delay * 2, 30)
    return resp
