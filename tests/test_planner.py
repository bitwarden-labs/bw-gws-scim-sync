import unittest

from src.models import BwGroup, BwUser, GoogleGroup, GoogleUser
from src.planner import build_plan

ALICE, BOB, CAROL, DAN = "100000000000000000001", "100000000000000000002", "100000000000000000003", "100000000000000000004"


def gu(uid, email, suspended=False):
    return GoogleUser(uid, email, "G", "F", email.split("@")[0], suspended)


def google_users():
    return {
        ALICE: gu(ALICE, "alice@acme.com"),
        BOB: gu(BOB, "bob@acme.com"),
        CAROL: gu(CAROL, "carol@acme.com", suspended=True),
        DAN: gu(DAN, "dan@acme.com"),
    }


def group(*ids):
    return GoogleGroup("grp1", "eng@acme.com", "Engineering", set(ids))


class PlannerTests(unittest.TestCase):
    def test_new_users_are_created_and_suspended_users_skipped(self):
        plan = build_plan(google_users(), [group(ALICE, BOB, CAROL)], [], [])
        self.assertEqual([u.email for u in plan.create_users], ["alice@acme.com", "bob@acme.com"])
        self.assertEqual(plan.groups[0].bw_group_id, None)
        self.assertNotIn(CAROL, plan.groups[0].google_group.member_ids)

    def test_existing_user_matched_by_external_id_or_email(self):
        bw = [BwUser("bw-a", ALICE, "alice@acme.com", True), BwUser("bw-b", None, "BOB@acme.com", True)]
        plan = build_plan(google_users(), [group(ALICE, BOB)], bw, [])
        self.assertEqual(plan.create_users, [])
        self.assertEqual(plan.id_map, {ALICE: "bw-a", BOB: "bw-b"})

    def test_managed_revoked_user_back_in_scope_is_restored(self):
        bw = [BwUser("bw-a", ALICE, "alice@acme.com", False)]
        plan = build_plan(google_users(), [group(ALICE)], bw, [])
        self.assertEqual([u.id for u in plan.reactivate], ["bw-a"])

    def test_unmanaged_revoked_user_is_left_alone(self):
        bw = [BwUser("bw-a", None, "alice@acme.com", False)]
        plan = build_plan(google_users(), [group(ALICE)], bw, [])
        self.assertEqual(plan.reactivate, [])
        self.assertEqual(len(plan.warnings), 1)

    def test_out_of_scope_suspended_and_deleted_users_are_revoked(self):
        bw = [
            BwUser("bw-a", ALICE, "alice@acme.com", True),
            BwUser("bw-c", CAROL, "carol@acme.com", True),          # suspended in Google
            BwUser("bw-x", "100000000000000000099", "gone@acme.com", True),  # deleted from Google
            BwUser("bw-owner", None, "owner@acme.com", True),       # invited manually: never touched
            BwUser("bw-okta", "00u1abcdEFGH", "okta@acme.com", True),  # other IdP id: never touched
        ]
        plan = build_plan(google_users(), [group(ALICE)], bw, [])
        self.assertEqual(sorted(u.id for u in plan.revoke), ["bw-c", "bw-x"])

    def test_protected_emails_and_removal_modes(self):
        bw = [BwUser("bw-d", DAN, "dan@acme.com", True), BwUser("bw-b", BOB, "bob@acme.com", False)]
        plan = build_plan(google_users(), [group(ALICE)], bw, [], protected_emails={"DAN@acme.com"})
        self.assertEqual(plan.revoke, [])  # Dan protected; Bob already revoked
        plan = build_plan(google_users(), [group(ALICE)], bw, [], removal_action="delete")
        self.assertEqual(sorted(u.id for u in plan.delete), ["bw-b", "bw-d"])
        plan = build_plan(google_users(), [group(ALICE)], bw, [], removal_action="none")
        self.assertEqual(plan.removal_count, 0)

    def test_groups_match_by_external_id(self):
        plan = build_plan(google_users(), [group(ALICE)], [], [BwGroup("bwg", "grp1", "Old name")])
        self.assertEqual((plan.groups[0].bw_group_id, plan.groups[0].external_id), ("bwg", "grp1"))

    def test_same_named_unmanaged_group_is_skipped_unless_adopted(self):
        existing = [BwGroup("bwg2", "dc-ext", "engineering")]
        plan = build_plan(google_users(), [group(ALICE)], [], existing)
        self.assertEqual(plan.groups, [])
        self.assertIn("ADOPT_GROUPS", plan.warnings[0])
        plan = build_plan(google_users(), [group(ALICE)], [], existing, adopt_groups={"ENG@acme.com"})
        self.assertEqual((plan.groups[0].bw_group_id, plan.groups[0].external_id), ("bwg2", "dc-ext"))
        plan = build_plan(google_users(), [group(ALICE)], [], [BwGroup("bwg3", None, "Engineering")],
                          adopt_groups={"eng@acme.com"})
        self.assertEqual((plan.groups[0].bw_group_id, plan.groups[0].external_id), ("bwg3", "grp1"))

    def test_warns_about_skipped_group_members(self):
        plan = build_plan(google_users(), [group(ALICE, CAROL, "999999999999999999999")], [], [])
        self.assertTrue(any("skipped 2 member(s)" in w for w in plan.warnings))

    def test_adopt_users(self):
        manual = [BwUser("bw-a", None, "alice@acme.com", True), BwUser("bw-b", None, "bob@acme.com", False)]
        plan = build_plan(google_users(), [group(ALICE, BOB)], manual, [])
        self.assertEqual((plan.adopt_users, plan.reactivate), ([], []))  # off by default
        self.assertEqual(plan.id_map, {ALICE: "bw-a", BOB: "bw-b"})

        plan = build_plan(google_users(), [group(ALICE, BOB)], manual, [], adopt_all_users=True)
        self.assertEqual([(g, u.id) for g, u in plan.adopt_users], [(ALICE, "bw-a"), (BOB, "bw-b")])
        self.assertEqual([u.id for u in plan.reactivate], ["bw-b"])

        plan = build_plan(google_users(), [group(ALICE, BOB)], manual, [], adopt_user_emails={"BOB@acme.com"})
        self.assertEqual([u.id for _, u in plan.adopt_users], ["bw-b"])

        plan = build_plan(google_users(), [group(ALICE)], manual, [], adopt_all_users=True,
                          protected_emails={"alice@acme.com"})
        self.assertEqual(plan.adopt_users, [])

    def test_adopt_users_skips_members_owned_by_another_tool(self):
        ldap = [BwUser("bw-a", "cn=Alice,dc=acme,dc=com", "alice@acme.com", True)]
        plan = build_plan(google_users(), [group(ALICE)], ldap, [], adopt_all_users=True)
        self.assertEqual(plan.adopt_users, [])
        self.assertTrue(any("another tool" in w for w in plan.warnings))

    def test_every_change_has_a_reason(self):
        finance = GoogleGroup("grp2", "fin@acme.com", "Finance", {ALICE})
        bw = [
            BwUser("bw-b", BOB, "bob@acme.com", False),  # managed, revoked, back in a group
            BwUser("bw-c", CAROL, "carol@acme.com", True),  # suspended in Google
            BwUser("bw-d", DAN, "dan@acme.com", True),  # in Google, but in no synced group
            BwUser("bw-x", "100000000000000000099", "gone@acme.com", True),  # deleted from Google
        ]
        plan = build_plan(google_users(), [group(ALICE, BOB), finance], bw,
                          [BwGroup("bwg", "grp1", "Engineering")])
        summary = plan.summary()
        reasons = {c["email"]: c["reason"] for key in ("create_users", "reactivate", "revoke")
                   for c in summary[key]}
        self.assertEqual(reasons, {
            "alice@acme.com": "in Engineering, Finance",
            "bob@acme.com": "back in Engineering",
            "carol@acme.com": "suspended or archived in Google",
            "dan@acme.com": "no longer in any synced group",
            "gone@acme.com": "no longer in this Google Workspace (deleted, or moved out)",
        })
        self.assertEqual([(g["group"], g["reason"]) for g in summary["groups"]],
                         [("Engineering", "linked to this Google group"), ("Finance", "no Bitwarden group yet")])

    def test_adopted_user_reason(self):
        plan = build_plan(google_users(), [group(ALICE)], [BwUser("bw-a", None, "alice@acme.com", True)], [],
                          adopt_all_users=True)
        self.assertIn("ADOPT_USERS", plan.summary()["adopt_users"][0]["reason"])

    def test_removed_group_linked_to_google_is_deleted(self):
        bw_groups = [BwGroup("bwg", "grp1", "Engineering"), BwGroup("bwf", "grp2", "Finance")]
        finance = GoogleGroup("grp2", "fin@acme.com", "Finance", {ALICE})
        plan = build_plan(google_users(), [finance], [], bw_groups,
                          removed_groups=[GoogleGroup("grp1", "eng@acme.com", "Engineering")])
        self.assertEqual([g.id for g in plan.delete_groups], ["bwg"])
        self.assertEqual(plan.summary()["delete_groups"][0]["group"], "Engineering")
        self.assertIn("DELETE_GROUPS", plan.summary()["delete_groups"][0]["reason"])

    def test_removed_group_still_synced_or_not_linked_is_kept(self):
        bw_groups = [BwGroup("bwg", "grp1", "Engineering"), BwGroup("bwm", "other-tool-id", "Marketing")]
        plan = build_plan(google_users(), [group(ALICE)], [], bw_groups, removed_groups=[
            GoogleGroup("grp1", "eng@acme.com", "Engineering"),  # still in GOOGLE_GROUPS
            GoogleGroup("grp3", "mkt@acme.com", "Marketing"),  # same name, not created by the sync
            GoogleGroup("grp4", "ops@acme.com", "Ops"),  # no Bitwarden group: already deleted
        ])
        self.assertEqual(plan.delete_groups, [])
        self.assertEqual(len(plan.warnings), 1)
        self.assertIn("Marketing", plan.warnings[0])

    def test_no_groups_left_revokes_every_managed_member(self):
        bw = [BwUser("bw-a", ALICE, "alice@acme.com", True), BwUser("bw-h", None, "hand@acme.com", True)]
        plan = build_plan(google_users(), [], bw, [BwGroup("bwg", "grp1", "Engineering")],
                          removed_groups=[GoogleGroup("grp1", "eng@acme.com", "Engineering")])
        self.assertEqual([u.email for u in plan.revoke], ["alice@acme.com"])
        self.assertEqual([g.id for g in plan.delete_groups], ["bwg"])


if __name__ == "__main__":
    unittest.main()
