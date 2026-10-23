"""Stand-in for gcloud in the script tests: records each call and answers from a scenario file.

FAKE_GCLOUD_STATE  JSON scenario (see tests/test_scripts.py)
FAKE_GCLOUD_LOG    JSON-lines file that receives one record per call: the arguments, the contents
                   of any --flags-file, and the data of any --data-file (stdin or a file).
"""
import json
import os
import sys


def main(argv: list[str]) -> int:
    with open(os.environ["FAKE_GCLOUD_STATE"], encoding="utf-8") as f:
        state = json.load(f)
    record = {"args": argv}
    for i, arg in enumerate(argv):
        path = arg.split("=", 1)[1] if arg.startswith("--flags-file=") else (
            argv[i + 1] if arg == "--flags-file" and i + 1 < len(argv) else None)
        if path:
            with open(path, encoding="utf-8-sig") as f:
                record["flags"] = json.load(f)
        if arg.startswith("--data-file="):
            source = arg.split("=", 1)[1]
            if source == "-":
                record["data"] = sys.stdin.read()
            else:
                with open(source, encoding="utf-8", newline="") as f:
                    record["data"] = f.read()
    data_file = record.get("flags", {}).get("--data-file")
    if data_file:
        with open(data_file, encoding="utf-8", newline="") as f:
            record["data"] = f.read()
    with open(os.environ["FAKE_GCLOUD_LOG"], "a", encoding="utf-8") as log:
        log.write(json.dumps(record) + "\n")
    return respond(state, argv, record.get("flags", {}))


def opt(args: list[str], name: str, flags: dict | None = None) -> str | None:
    if flags and name in flags:  # the PowerShell scripts pass options in a --flags-file
        return str(flags[name])
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return None


def respond(state: dict, args: list[str], flags: dict) -> int:
    words = [a for a in args if not a.startswith("-")]
    cmd = " ".join(words[:4])
    jobs = state.get("jobs", {})  # region -> plain environment variables of the job there
    fmt = opt(args, "--format", flags) or ""

    if cmd.startswith("config get-value"):
        print({"account": state.get("account", ""), "project": state.get("project", "")}.get(words[2], ""))
        return 0
    if cmd.startswith("auth application-default print-access-token"):
        return 0 if state.get("adc_ok", True) else 1
    if cmd.startswith("auth print-access-token"):
        if not state.get("token_ok", True):
            return 1
        print("user-token")
        return 0
    if cmd.startswith("run jobs execute"):
        if "metadata.name" in fmt:
            print("bw-scim-sync-ab12c")
        return state.get("execute_exit", 0)
    if cmd.startswith("projects describe"):
        if not state.get("project_access", True):
            return 1
        print(words[2])
        return 0
    if cmd.startswith("billing projects describe"):
        print(state.get("billing", "True"))
        return 0
    if cmd.startswith("run jobs list"):
        regions = sorted(jobs)
        if opt(args, "--limit", flags) == "1":
            regions = regions[:1]
        print("\n".join(regions))
        return 0
    if cmd.startswith("run jobs describe"):
        env = jobs.get(opt(args, "--region", flags) or "")
        if env is None:
            return 1
        entries = [{"name": k, "value": v} for k, v in env.items()]
        entries.append({"name": "BW_SCIM_API_KEY",
                        "valueFrom": {"secretKeyRef": {"name": "bw-scim-api-key", "key": "latest"}}})
        print(json.dumps({"spec": {"template": {"spec": {"template": {"spec": {
            "containers": [{"env": entries}]}}}}}}))
        return 0
    if cmd.startswith("scheduler jobs describe"):
        sched = state.get("scheduler")
        if sched is None:
            return 1
        if "schedule" in fmt:
            print(f"{sched['schedule']}\t{sched['timeZone']}")
        return 0
    if cmd.startswith("secrets versions access"):
        print("fake-scim-key", end="")
        return 0
    if cmd.startswith("secrets describe"):
        return 0 if state.get("secret_exists", False) else 1
    if cmd.startswith("iam service-accounts describe"):
        if "oauth2ClientId" in fmt:
            print("123456789012345678901")
            return 0
        return 0 if state.get("sa_exists", False) else 1
    return 0  # every change (create, deploy, update, bindings, enable) succeeds


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
