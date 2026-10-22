"""Exercises the SCIM client and apply() against an in-process fake SCIM server."""
import json
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

from src.bitwarden_scim import BitwardenScim
from src.main import apply
from src.models import GoogleGroup, GoogleUser
from src.planner import build_plan

STATE = {"users": {}, "groups": {}, "requests": []}


class FakeScim(BaseHTTPRequestHandler):
    """Mirrors bitwarden/server: group responses never include members, PUT /Groups ignores
    externalId, and PATCH can set externalId."""

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
        public = (lambda i: {k: v for k, v in i.items() if k != "members"}) if res == "Groups" else dict
        if rid:
            return self._send(200, public(STATE[res.lower()][rid]))
        q = parse_qs(p.query)
        start, count = int(q["startIndex"][0]), int(q["count"][0])
        items = [public(i) for i in STATE[res.lower()].values()]
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
        if res == "Groups":
            body["externalId"] = STATE["groups"][rid].get("externalId")
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
            elif path in ("displayName", "externalId"):
                item[path] = op["value"]
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

    def do_DELETE(self):
        _, res, rid = self._route()
        del STATE[res.lower()][rid]
        STATE["requests"].append(("DELETE", res, None))
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

    def setUp(self):
        for value in STATE.values():
            value.clear()

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


    def test_removed_group_is_deleted_only_when_linked(self):
        scim = BitwardenScim(self.url, "test-key")
        alice = GoogleUser("100000000000000000001", "alice@acme.com", "Alice", "A", "Alice A", False)
        eng = GoogleGroup("g1", "eng@acme.com", "Engineering", {alice.id})
        apply(build_plan({alice.id: alice}, [eng], [], []), scim)  # creates Engineering, linked to g1
        scim.create_group("Finance", "", [])  # same name as a Google group, made by hand

        removed = [GoogleGroup("g1", "eng@acme.com", "Engineering"), GoogleGroup("g2", "fin@acme.com", "Finance")]
        plan = build_plan({alice.id: alice}, [], scim.list_users(), scim.list_groups(), removed_groups=removed)
        self.assertEqual([g.display_name for g in plan.delete_groups], ["Engineering"])
        self.assertTrue(any("Finance" in w and "not deleting" in w for w in plan.warnings))
        self.assertEqual(apply(plan, scim), 0)
        self.assertEqual([g["displayName"] for g in STATE["groups"].values()], ["Finance"])
        # Alice was only in Engineering, so she's revoked in the same run.
        self.assertFalse(next(iter(STATE["users"].values()))["active"])

    def test_patch_group_replaces_name_and_members(self):
        scim = BitwardenScim(self.url, "test-key")
        gid = scim.create_group("Finance", "g2", ["m1", "m2", "m3"])
        self.assertEqual(scim.patch_group(gid, "Finance Team", ["m3", "m4"]), {"strategy": "patch"})
        self.assertEqual(STATE["groups"][gid]["members"], [{"value": "m3"}, {"value": "m4"}])
        self.assertEqual(STATE["groups"][gid]["displayName"], "Finance Team")

    def test_adopted_group_gets_linked_by_external_id(self):
        scim = BitwardenScim(self.url, "test-key")
        STATE["groups"]["legacy"] = {"id": "legacy", "displayName": "Sales", "members": [{"value": "x"}]}
        bob = GoogleUser("100000000000000000002", "bob@acme.com", "Bob", "B", "Bob B", False)
        sales = lambda: GoogleGroup("g3", "sales@acme.com", "Sales", {bob.id})

        plan = build_plan({bob.id: bob}, [sales()], scim.list_users(), scim.list_groups(),
                          adopt_groups={"sales@acme.com"})
        self.assertEqual(apply(plan, scim), 0)
        self.assertEqual(STATE["groups"]["legacy"]["externalId"], "g3")  # PUT alone would not store it
        self.assertEqual(len(STATE["groups"]["legacy"]["members"]), 1)

        # Later runs match by externalId and no longer need ADOPT_GROUPS.
        plan = build_plan({bob.id: bob}, [sales()], scim.list_users(), scim.list_groups())
        self.assertEqual([(c.bw_group_id, c.link) for c in plan.groups], [("legacy", False)])

    def test_adopted_user_is_linked_then_revoked_when_removed(self):
        scim = BitwardenScim(self.url, "test-key")
        STATE["users"]["manual"] = {"id": "manual", "userName": "bob@acme.com", "active": True,
                                    "emails": [{"value": "bob@acme.com", "primary": True}]}
        bob = GoogleUser("100000000000000000002", "bob@acme.com", "Bob", "B", "Bob B", False)
        users = {bob.id: bob}

        plan = build_plan(users, [GoogleGroup("g4", "ops@acme.com", "Ops", {bob.id})],
                          scim.list_users(), scim.list_groups(), adopt_all_users=True)
        self.assertEqual(apply(plan, scim), 0)
        self.assertEqual(STATE["users"]["manual"]["externalId"], bob.id)

        # Removed from the Google group: now revoked, even with ADOPT_USERS off.
        plan = build_plan(users, [GoogleGroup("g4", "ops@acme.com", "Ops", set())],
                          scim.list_users(), scim.list_groups())
        self.assertEqual([u.id for u in plan.revoke], ["manual"])
        apply(plan, scim)
        self.assertFalse(STATE["users"]["manual"]["active"])


if __name__ == "__main__":
    unittest.main()
