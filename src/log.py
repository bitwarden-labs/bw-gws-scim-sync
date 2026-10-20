"""Structured JSON logging that Cloud Logging parses (severity + message)."""
import json
import sys


def log(severity: str, message: str, **fields) -> None:
    entry = {"severity": severity, "message": message, **fields}
    print(json.dumps(entry, default=str), file=sys.stdout, flush=True)
