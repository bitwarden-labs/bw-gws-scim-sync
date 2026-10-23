"""Runs setup and select-groups (bash and PowerShell) against a fake gcloud and compares what they do.

Each scenario's gcloud calls are normalized (option order, flags files, the ^;^ separator) and
compared with tests/golden/<scenario>.json, recorded from the bash scripts. So the PowerShell
versions must make the same calls, with the same values, as the bash ones. On Windows the fake
gcloud is a .cmd file, like the real one, so it sees exactly what Windows passes to gcloud.

select-groups differs on purpose in two places. bash reads the directory and runs the dry run with
the tool's Python (faked by tests/fakes/fake_python.py); PowerShell needs no Python, so it calls
Google's APIs directly (faked here by FakeGoogle) and runs the dry run on Cloud Run. Those calls
are checked separately; every other call must match the golden file.

Shells that aren't installed are skipped. To re-record the golden files after an intended change
to the bash scripts:  UPDATE_GOLDEN=1 python -m unittest tests.test_scripts
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent.parent
FAKES = ROOT / "tests" / "fakes"
GOLDEN = ROOT / "tests" / "golden"
WINDOWS = os.name == "nt"
sys.path.insert(0, str(FAKES))
from fake_python import PLAN

# Variables the scripts read as answers or settings; cleared so the developer's own don't leak in.
ANSWER_VARS = ("PROJECT_ID", "REGION", "BW_SCIM_URL", "BW_SCIM_API_KEY", "GOOGLE_ADMIN_EMAIL", "GOOGLE_GROUPS",
               "SCHEDULE", "TIME_ZONE", "DELETE_GROUPS", "PROTECTED_EMAILS", "ADOPT_USERS", "BW_SYNC_PYTHON",
               "GOOGLE_SA_EMAIL", "DRY_RUN", "CLOUDSDK_CORE_PROJECT", "BW_SYNC_API_ROOT")
SA = "bw-scim-sync@test-proj.iam.gserviceaccount.com"
DEPLOYED = {
    "BW_SCIM_URL": "https://scim.bitwarden.eu/v2/org-1", "GOOGLE_ADMIN_EMAIL": "admin@acme.com",
    "GOOGLE_SA_EMAIL": SA, "GOOGLE_GROUPS": "eng@acme.com,fin@acme.com", "DRY_RUN": "false",
}
FRESH = {"account": "admin@acme.com", "project": "test-proj", "jobs": {}, "scheduler": None,
         "secret_exists": False, "sa_exists": False}
EXISTING = {"account": "admin@acme.com", "project": "test-proj", "jobs": {"europe-west1": DEPLOYED},
            "scheduler": {"schedule": "0 */4 * * *", "timeZone": "Europe/Madrid"},
            "secret_exists": True, "sa_exists": True}
ANSWERS = {"PROJECT_ID": "test-proj", "REGION": "europe-west1", "BW_SCIM_URL": "https://scim.bitwarden.com/v2/org-2",
           "BW_SCIM_API_KEY": "key-123", "GOOGLE_ADMIN_EMAIL": "admin@acme.com",
           "GOOGLE_GROUPS": "eng@acme.com,fin@acme.com", "SCHEDULE": "0 * * * *", "TIME_ZONE": "Etc/UTC"}
# The fake directory, as the PowerShell picker lists it (sorted by name): groups 1 Engineering,
# 2 Finance, 3 Marketing; users 1 Ana, 2 T Four (the suspended user isn't listed).
GROUP_PAGES = [
    {"groups": [{"email": "eng@acme.com", "name": "Engineering", "directMembersCount": "3"},
                {"email": "Fin@acme.com", "name": "Finance", "directMembersCount": "1"}], "nextPageToken": "page-2"},
    {"groups": [{"email": "mkt@acme.com", "name": "Marketing", "directMembersCount": "0"}]},
]
USERS = {"users": [{"primaryEmail": "t4@acme.com", "name": {"fullName": "T Four"}},
                   {"primaryEmail": "ana@acme.com", "name": {"fullName": "Ana"}},
                   {"primaryEmail": "sus@acme.com", "name": {"fullName": "Sus"}, "suspended": True}]}
LOG_ENTRIES = [
    {"severity": "WARNING", "jsonPayload": {"message": "fin@acme.com: example warning"}},
    {"severity": "INFO", "jsonPayload": {"message": "Sync plan", "dry_run": True, "plan": PLAN}},
    {"severity": "NOTICE", "jsonPayload": {"message": "DRY_RUN is on: no changes were made."}},
    {"severity": "INFO", "textPayload": "Container called exit(0)."},
]
PS_ONLY = ("pwsh", "powershell")

# stdin: answers for bash; ps_stdin: for PowerShell, which also types into its picker.
# choice: what bash's (fake Python) picker returns. dry_run: the dry run is expected to run.
SCENARIOS = {
    "setup_fresh": {"script": "setup", "state": FRESH, "answers": ANSWERS, "expect": ["DRY_RUN=true: nothing changes yet"]},
    "setup_rerun_keeps_values": {"script": "setup", "state": EXISTING, "stdin": [""] * 8,
                                     "expect": ["Found the deployed bw-scim-sync job", "Keeping the stored key."]},
    "setup_expired_sign_in": {"script": "setup", "state": {**FRESH, "token_ok": False}, "answers": ANSWERS, "exit": 1,
                                  "expect": ["has expired. Run: gcloud auth login"]},
    "setup_no_project_access": {"script": "setup", "state": {**FRESH, "project_access": False}, "answers": ANSWERS, "exit": 1,
                                    "expect": ["can't access project \"test-proj\""]},
    "groups_untick_and_delete": {
        "script": "select-groups", "state": EXISTING, "choice": "eng@acme.com", "dry_run": True,
        "stdin": ["", "y", "y", ""], "ps_stdin": ["", "2", "s", "y", "y", ""],
        "expect": ["Found the bw-scim-sync job in europe-west1.", "DELETE_GROUPS=fin@acme.com",
                "Saved. The next run uses it.", "Delete   group Finance",
                "Revoke   gone@acme.com: no longer in any synced group", "WARNING: fin@acme.com: example warning"]},
    "groups_untick_last": {"script": "select-groups", "state": EXISTING, "choice": "", "stdin": ["", "y", "y", "n"],
                               "ps_stdin": ["", "1-2", "s", "y", "y", "n"], "expect": ["No groups are left", "remove GOOGLE_GROUPS"]},
    "groups_untick_last_keep": {"script": "select-groups", "state": EXISTING, "choice": "", "exit": 1, "stdin": ["", "n"],
                                    "ps_stdin": ["", "1,2", "s", "n"],
                                    "expect": ["Select at least one group, or delete the groups you removed."]},
    "groups_untick_keep_group": {"script": "select-groups", "state": EXISTING, "choice": "eng@acme.com",
                                     "stdin": ["", "n", "y", "n"], "ps_stdin": ["", "2", "s", "n", "y", "n"],
                                     "expect": ["GOOGLE_GROUPS=eng@acme.com"]},
    "groups_two_regions": {"script": "select-groups", "choice": "eng@acme.com,fin@acme.com",
                               "state": {**EXISTING, "jobs": {"europe-west1": DEPLOYED, "us-central1": DEPLOYED}},
                               "stdin": ["", "2"], "ps_stdin": ["", "2", "s"], "expect": ["more than one region", "No changes."]},
    "protected_users": {"script": "select-groups", "args": ["--protected-users"], "state": EXISTING, "choice": "t4@acme.com",
                            "stdin": ["", "y", "n"], "ps_stdin": ["", "2", "s", "y", "n"],
                            "expect": ["PROTECTED_EMAILS=t4@acme.com"]},
    "groups_no_job": {"script": "select-groups", "state": FRESH, "exit": 1, "stdin": [""],
                          "expect": ["Couldn't find the bw-scim-sync job"]},
    "groups_adc_expired": {"script": "select-groups", "state": {**EXISTING, "adc_ok": False}, "exit": 1, "shells": ("bash",),
                               "expect": ["Application Default Credentials are missing or expired"]},
    # PowerShell only: its own picker and directory access.
    "ps_picker_filter_and_cancel": {"script": "select-groups", "state": EXISTING, "shells": PS_ONLY,
                                        "stdin": ["", "/mark", "9", "1", "q"],
                                        "expect": ["(filter: mark)", "9 isn't between 1 and 1", "3 selected",
                                                "Cancelled. Nothing was changed."]},
    "ps_delegation_not_ready": {"script": "select-groups", "state": EXISTING, "shells": PS_ONLY, "exit": 1, "stdin": [""],
                                    "google": {"token_error": "unauthorized_client"},
                                    "expect": ["Google rejected the directory access", "README Step 3"]},
}


class FakeGoogle(BaseHTTPRequestHandler):
    """Google's IAM Credentials, OAuth token, Directory and Logging APIs, at http://host/<api host>/<path>."""
    calls: ClassVar[list] = []
    options: ClassVar[dict] = {}

    def log_message(self, *a):
        pass

    def reply(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_call(self, method: str) -> None:
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode() if length else ""
        body = json.loads(raw) if raw.startswith("{") else {k: v[0] for k, v in parse_qs(raw).items()}
        call = {"method": method, "path": url.path, "query": {k: v[0] for k, v in parse_qs(url.query).items()},
                "auth": self.headers.get("Authorization", ""), "body": body}
        FakeGoogle.calls.append(call)
        if url.path.endswith(":signJwt"):
            return self.reply(200, {"keyId": "k1", "signedJwt": "header.claims.signature"})
        if url.path == "/oauth2.googleapis.com/token":
            if FakeGoogle.options.get("token_error"):
                return self.reply(401, {"error": FakeGoogle.options["token_error"], "error_description": "Client is unauthorized"})
            return self.reply(200, {"access_token": "directory-token", "expires_in": 3600, "token_type": "Bearer"})
        if url.path == "/admin.googleapis.com/admin/directory/v1/groups":
            return self.reply(200, GROUP_PAGES[1] if call["query"].get("pageToken") == "page-2" else GROUP_PAGES[0])
        if url.path == "/admin.googleapis.com/admin/directory/v1/users":
            return self.reply(200, USERS)
        if url.path == "/logging.googleapis.com/v2/entries:list":
            return self.reply(200, {"entries": LOG_ENTRIES})
        return self.reply(404, {"error": f"unexpected {url.path}"})

    def do_GET(self):
        self.handle_call("GET")

    def do_POST(self):
        self.handle_call("POST")


def shells() -> list[str]:
    found = []
    if not WINDOWS and shutil.which("bash"):
        found.append("bash")
    if shutil.which("pwsh"):
        found.append("pwsh")
    if WINDOWS and shutil.which("powershell"):
        found.append("powershell")
    return found


def make_shim(folder: Path, name: str, target: Path) -> Path:
    if WINDOWS:
        shim = folder / f"{name}.cmd"
        shim.write_text(f'@"{sys.executable}" "{target}" %*\r\n', encoding="ascii")
    else:
        shim = folder / name
        shim.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{target}" "$@"\n', encoding="ascii")
        shim.chmod(0o755)
    return shim


def env_dict(value) -> dict:
    """--update-env-vars as given by bash ("^;^A=1;B=2" or "A=1,B=2") or in a flags file (a dict)."""
    if isinstance(value, dict):
        return {k: str(v) for k, v in value.items()}
    sep = ","
    if value.startswith("^"):
        sep, value = value[1:].split("^", 1)
    return dict(item.split("=", 1) for item in value.split(sep) if item)


def normalize(record: dict) -> dict:
    args, words, opts = record["args"], [], {}
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            if "=" in a:
                key, value = a.split("=", 1)
            elif i + 1 < len(args) and not args[i + 1].startswith("--"):
                key, value = a, args[i + 1]
                i += 1
            else:
                key, value = a, True
            opts[key] = value
        else:
            words.append(a)
        i += 1
    opts.update(record.get("flags", {}))
    for drop in ("--quiet", "--flags-file", "--data-file"):
        opts.pop(drop, None)
    for key in ("--update-env-vars", "--set-env-vars", "--set-secrets"):
        if key in opts:
            opts[key] = env_dict(opts[key])
    if "--remove-env-vars" in opts:
        value = opts["--remove-env-vars"]
        opts["--remove-env-vars"] = sorted(value if isinstance(value, list) else value.split(","))
    out = {"words": words,
           "options": {k: (v if isinstance(v, (dict, list, bool)) else str(v)) for k, v in sorted(opts.items())}}
    if "data" in record:
        out["data"] = record["data"]
    return out


# Calls only one of the two select-groups versions makes: bash's Python sign-in check and key
# read for the local dry run; PowerShell's sign-in token for the APIs and its Cloud Run dry run.
OWN_WAY = (["auth", "application-default", "print-access-token"], ["auth", "print-access-token"],
           ["secrets", "versions", "access"], ["run", "jobs", "execute"])


def shared(calls: list[dict]) -> list[dict]:
    return [c for c in calls if not any(c["words"][:len(w)] == w for w in OWN_WAY)]


def run(shell: str, name: str) -> dict:
    sc = SCENARIOS[name]
    stdin = sc.get("ps_stdin", sc.get("stdin", [])) if shell != "bash" else sc.get("stdin", [])
    FakeGoogle.calls, FakeGoogle.options = [], sc.get("google", {})
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeGoogle)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            make_shim(bin_dir, "gcloud", FAKES / "fake_gcloud.py")
            python_shim = make_shim(bin_dir, "fake-python", FAKES / "fake_python.py")
            (tmp / "state.json").write_text(json.dumps(sc["state"]), encoding="utf-8")
            env = {k: v for k, v in os.environ.items() if k not in ANSWER_VARS}
            env.update(sc.get("answers", {}))
            env.update({
                "PATH": str(bin_dir) + os.pathsep + os.environ.get("PATH", ""),
                "FAKE_GCLOUD_STATE": str(tmp / "state.json"), "FAKE_GCLOUD_LOG": str(tmp / "gcloud.jsonl"),
                "FAKE_PYTHON_LOG": str(tmp / "python.jsonl"), "BW_SYNC_PYTHON": str(python_shim),
                "FAKE_PICKER_CHOICE": sc.get("choice") or "",
                "BW_SYNC_API_ROOT": f"http://127.0.0.1:{server.server_port}",
            })
            script = sc["script"]
            if shell == "bash":
                command = ["bash", str(ROOT / f"{script}.sh")]
            elif shell == "pwsh":
                command = ["pwsh", "-NoProfile", "-File", str(ROOT / f"{script}.ps1")]
            else:
                command = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / f"{script}.ps1")]
            proc = subprocess.run(command + sc.get("args", []), check=False, cwd=ROOT, env=env,
                                  input="".join(line + "\n" for line in stdin), capture_output=True, text=True,
                                  encoding="utf-8", errors="replace", timeout=180)

            def lines(file: str) -> list[dict]:
                path = tmp / file
                return [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []

            return {"exit": proc.returncode, "output": proc.stdout + proc.stderr,
                    "calls": [normalize(r) for r in lines("gcloud.jsonl")], "python": lines("python.jsonl"),
                    "google": list(FakeGoogle.calls)}
    finally:
        server.shutdown()
        server.server_close()


class ScriptTests(unittest.TestCase):
    maxDiff = None

    def check(self, name: str) -> None:
        sc = SCENARIOS[name]
        available = [s for s in shells() if s in sc.get("shells", ("bash", "pwsh", "powershell"))]
        if not available:
            self.skipTest("the shells this scenario needs aren't installed")
        golden_file = GOLDEN / f"{name}.json"
        if os.environ.get("UPDATE_GOLDEN") and "bash" in available:
            result = run("bash", name)
            golden_file.write_text(json.dumps({"calls": result["calls"], "python": result["python"]}, indent=1) + "\n",
                                   encoding="utf-8")
        golden = json.loads(golden_file.read_text(encoding="utf-8")) if golden_file.exists() else None
        for shell in available:
            with self.subTest(shell=shell):
                result = run(shell, name)
                out = result["output"]
                self.assertEqual(result["exit"], sc.get("exit", 0), out)
                for snippet in sc.get("expect", []):
                    self.assertIn(snippet, out)
                if sc["script"] == "setup":
                    self.assertEqual(result["calls"], golden["calls"], out)
                    continue
                if golden is not None:
                    self.assertEqual(shared(result["calls"]), shared(golden["calls"]), out)
                if shell == "bash":
                    self.assertEqual(result["python"], golden["python"], out)
                else:
                    self.check_powershell_way(sc, result)

    def check_powershell_way(self, sc: dict, result: dict) -> None:
        """PowerShell reads the directory through Google's APIs and dry-runs on Cloud Run, with no Python."""
        out = result["output"]
        self.assertEqual(result["python"], [], "PowerShell must not run Python")
        google = result["google"]
        signs = [c for c in google if c["path"].endswith(":signJwt")]
        if signs:
            self.assertEqual(signs[0]["path"], f"/iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{SA}:signJwt")
            self.assertEqual(signs[0]["auth"], "Bearer user-token")
            claims = json.loads(signs[0]["body"]["payload"])
            self.assertEqual((claims["iss"], claims["sub"], claims["aud"]),
                             (SA, "admin@acme.com", "https://oauth2.googleapis.com/token"))
            self.assertIn("admin.directory.group.readonly", claims["scope"])
            self.assertEqual(claims["exp"] - claims["iat"], 3600)
            token = next(c for c in google if c["path"] == "/oauth2.googleapis.com/token")
            self.assertEqual(token["body"], {"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                             "assertion": "header.claims.signature"})
        listing = [c for c in google if "/admin/directory/v1/" in c["path"]]
        for call in listing:
            self.assertEqual((call["auth"], call["query"]["customer"]), ("Bearer directory-token", "my_customer"))
        if any(c["path"].endswith("/groups") for c in listing):  # both pages were read
            self.assertEqual([c["query"].get("pageToken") for c in listing], [None, "page-2"])
        executions = [c for c in result["calls"] if c["words"][:3] == ["run", "jobs", "execute"]]
        if sc.get("dry_run"):
            self.assertEqual(len(executions), 1, out)
            self.assertEqual(executions[0]["options"]["--update-env-vars"], {"DRY_RUN": "true"})
            self.assertEqual(executions[0]["options"]["--region"], "europe-west1")
            logs = [c for c in google if c["path"] == "/logging.googleapis.com/v2/entries:list"]
            self.assertIn('"run.googleapis.com/execution_name"="bw-scim-sync-ab12c"', logs[0]["body"]["filter"])
            self.assertEqual(logs[0]["body"]["resourceNames"], ["projects/test-proj"])
        else:
            self.assertEqual(executions, [], out)


for _name in SCENARIOS:
    setattr(ScriptTests, f"test_{_name}", lambda self, n=_name: self.check(n))


if __name__ == "__main__":
    unittest.main()
