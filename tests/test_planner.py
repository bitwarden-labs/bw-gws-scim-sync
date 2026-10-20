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

    def test_groups_match_by_external_id_then_name(self):
        plan = build_plan(google_users(), [group(ALICE)], [], [BwGroup("bwg", "grp1", "Old name")])
        self.assertEqual((plan.groups[0].bw_group_id, plan.groups[0].external_id), ("bwg", "grp1"))
        plan = build_plan(google_users(), [group(ALICE)], [], [BwGroup("bwg2", "dc-ext", "engineering")])
        self.assertEqual((plan.groups[0].bw_group_id, plan.groups[0].external_id), ("bwg2", "dc-ext"))


if __name__ == "__main__":
    unittest.main()
