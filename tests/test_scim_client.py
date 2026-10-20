"""Exercises the SCIM client and apply() against an in-process fake SCIM server."""
import json
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

from src.bitwarden_scim import BitwardenScim
from src.main import apply
from src.models import BwUser, GoogleGroup, GoogleUser
from src.planner import build_plan

STATE = {"users": {}, "groups": {}, "requests": [], "hide_group_members": False}


class FakeScim(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/scim+json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n)) if n else None

    def _route(self):
        assert self.headers["Authorization"] == "Bearer test-key"
        p = urlparse(self.path)
        parts = p.path.split("/")[3:]  # /v2/org/<Resource>/<id>
        return p, parts[0], parts[1] if len(parts) > 1 else None

    def do_GET(self):
        p, res, rid = self._route()
        if rid:
            item = dict(STATE[res.lower()][rid])
            if res == "Groups" and STATE["hide_group_members"]:
                item.pop("members", None)
            return self._send(200, item)
        q = parse_qs(p.query)
        start, count = int(q["startIndex"][0]), int(q["count"][0])
        items = list(STATE[res.lower()].values())
        self._send(200, {"totalResults": len(items), "startIndex": start,
                         "Resources": items[start - 1:start - 1 + count]})

    def do_POST(self):
        _, res, _ = self._route()
        body = self._body()
        body["id"] = str(uuid.uuid4())
        STATE[res.lower()][body["id"]] = body
        STATE["requests"].append(("POST", res, body))
        self._send(201, body)

    def do_PUT(self):
        _, res, rid = self._route()
        body = self._body()
        body["id"] = rid
        STATE[res.lower()][rid] = body
        STATE["requests"].append(("PUT", res, body))
        self._send(200, body)

    def do_PATCH(self):
        _, res, rid = self._route()
        body = self._body()
        item = STATE[res.lower()][rid]
        for op in body["Operations"]:
            path = op.get("path", "")
            if path == "active":
                item["active"] = op["value"]
            elif path == "displayName":
                item["displayName"] = op["value"]
            elif path == "members" and op["op"] == "replace":
                item["members"] = op["value"]
            elif path == "members" and op["op"] == "add":
                item.setdefault("members", []).extend(op["value"])
            elif path.startswith("members[value eq ") and op["op"] == "remove":
                gone = path.split('"')[1]
                item["members"] = [m for m in item.get("members", []) if m["value"] != gone]
            else:
                return self._send(400, {"detail": f"unsupported op {op}"})
        STATE["requests"].append(("PATCH", res, body))
        self._send(204)


class ScimClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), FakeScim)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/v2/org-123"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_pagination_and_full_apply(self):
        # 150 pre-existing unmanaged members forces two pages at PAGE_SIZE=100.
        for i in range(150):
            uid = str(uuid.uuid4())
            STATE["users"][uid] = {"id": uid, "userName": f"m{i}@acme.com", "active": True,
                                   "emails": [{"value": f"m{i}@acme.com", "primary": True}]}
        gone = str(uuid.uuid4())
        STATE["users"][gone] = {"id": gone, "externalId": "100000000000000000099",
                                "userName": "gone@acme.com", "active": True}

        scim = BitwardenScim(self.url, "test-key")
        bw_users = scim.list_users()
        self.assertEqual(len(bw_users), 151)

        alice = GoogleUser("100000000000000000001", "alice@acme.com", "Alice", "A", "Alice A", False)
        plan = build_plan({alice.id: alice}, [GoogleGroup("g1", "eng@acme.com", "Engineering", {alice.id})],
                          bw_users, scim.list_groups())
        self.assertEqual(apply(plan, scim), 0)

        self.assertFalse(STATE["users"][gone]["active"])
        group = next(iter(STATE["groups"].values()))
        alice_bw = next(u for u in STATE["users"].values() if u.get("externalId") == alice.id)
        self.assertEqual(group["members"], [{"value": alice_bw["id"]}])
        self.assertEqual(group["externalId"], "g1")

        # Second run is idempotent for users and updates the group in place.
        STATE["requests"].clear()
        plan = build_plan({alice.id: alice}, [GoogleGroup("g1", "eng@acme.com", "Engineering", {alice.id})],
                          scim.list_users(), scim.list_groups())
        self.assertEqual((plan.create_users, plan.revoke), ([], []))
        apply(plan, scim)
        self.assertEqual([(m, r) for m, r, _ in STATE["requests"]], [("PUT", "Groups")])


    def test_patch_group_diff_and_replace(self):
        scim = BitwardenScim(self.url, "test-key")
        gid = scim.create_group("Finance", "g2", ["m1", "m2", "m3"])

        STATE["requests"].clear()
        result = scim.patch_group(gid, "Finance Team", ["m2", "m3", "m4"])
        self.assertEqual(result, {"strategy": "diff", "added": 1, "removed": 1, "operations": 3})
        self.assertEqual(sorted(m["value"] for m in STATE["groups"][gid]["members"]), ["m2", "m3", "m4"])
        self.assertEqual(STATE["groups"][gid]["displayName"], "Finance Team")

        result = scim.patch_group(gid, "Finance Team", ["m2", "m3", "m4"])
        self.assertEqual(result["operations"], 0)  # already in sync: nothing sent
        self.assertEqual([r for r, *_ in STATE["requests"]].count("PATCH"), 1)

        STATE["hide_group_members"] = True
        try:
            result = scim.patch_group(gid, "Finance Team", ["m9"])
        finally:
            STATE["hide_group_members"] = False
        self.assertEqual(result, {"strategy": "replace", "members": 1, "operations": 1})
        self.assertEqual(STATE["groups"][gid]["members"], [{"value": "m9"}])


if __name__ == "__main__":
    unittest.main()
