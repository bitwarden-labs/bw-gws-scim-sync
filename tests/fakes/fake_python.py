"""Stand-in for the tool's Python in the select-groups tests (BW_SYNC_PYTHON).

-m src.picker  answers with FAKE_PICKER_CHOICE (exit 3, "No changes.", if that's the current list)
-m src.main    records the settings the dry run sees and prints a fixed plan
anything else  runs the real Python (select-groups.sh formats the plan with "python -c")
Calls are recorded in FAKE_PYTHON_LOG as JSON lines.
"""
import json
import os
import subprocess
import sys

PLAN = {
    "create_users": [{"email": "new@acme.com", "reason": "in Engineering"}],
    "reactivate": [], "delete": [], "adopt_users": [],
    "revoke": [{"email": "gone@acme.com", "reason": "no longer in any synced group"}],
    "groups": [{"group": "Engineering", "action": "update", "members": 3, "reason": "linked to this Google group"}],
    "delete_groups": [{"group": "Finance", "reason": "removed from GOOGLE_GROUPS and listed in DELETE_GROUPS"}],
}
SEEN = ("GOOGLE_GROUPS", "DELETE_GROUPS", "PROTECTED_EMAILS", "BW_SCIM_API_KEY", "BW_SCIM_URL", "DRY_RUN")


def record(entry: dict) -> None:
    with open(os.environ["FAKE_PYTHON_LOG"], "a", encoding="utf-8") as log:
        log.write(json.dumps(entry) + "\n")


def option(args: list[str], name: str) -> str:
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return ""


def emails(text: str) -> list[str]:
    return [e.strip().lower() for e in text.split(",") if e.strip()]


def main(argv: list[str]) -> int:
    if argv[:2] == ["-m", "src.picker"]:
        rest = argv[2:]
        current, choice = option(rest, "--current"), os.environ.get("FAKE_PICKER_CHOICE", "")
        record({"picker": {"kind": rest[0], "current": current, "title": option(rest, "--title")}})
        if emails(choice) == emails(current):
            print("  No changes.")
            return 3
        with open(option(rest, "--output"), "w", encoding="utf-8") as f:
            f.write(choice)
        return 0
    if argv[:2] == ["-m", "src.main"]:
        record({"main": {k: os.environ.get(k, "") for k in SEEN}})
        print(json.dumps({"severity": "WARNING", "message": "fin@acme.com: example warning"}))
        print(json.dumps({"severity": "INFO", "message": "Sync plan", "dry_run": True, "plan": PLAN}))
        return 0
    return subprocess.call([sys.executable] + argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
