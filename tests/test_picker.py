import unittest

from src.models import GoogleUser
from src.picker import (
    Item,
    filter_items,
    load_items,
    merge_current,
    parse_selection,
    pick_plain,
    split_emails,
)

ITEMS = [
    Item("eng@acme.com", "Engineering", "4 members"),
    Item("eng-leads@acme.com", "Engineering Leads", "2 members"),
    Item("fin@acme.com", "Finance", "3 members"),
]


def scripted(*answers):
    queue = list(answers)
    return lambda _prompt: queue.pop(0)


class PickerTests(unittest.TestCase):
    def test_parse_selection(self):
        self.assertEqual(parse_selection("1, 3,5-7", 7), {0, 2, 4, 5, 6})
        self.assertEqual(parse_selection("", 3), set())
        for bad in ("0", "4", "3-2", "x", "1-"):
            with self.assertRaises(ValueError):
                parse_selection(bad, 3)

    def test_filter_matches_name_or_email(self):
        self.assertEqual([i.key for i in filter_items(ITEMS, "LEADS")], ["eng-leads@acme.com"])
        self.assertEqual(len(filter_items(ITEMS, "acme")), 3)
        self.assertEqual(filter_items(ITEMS, "  "), ITEMS)

    def test_split_and_merge_current(self):
        self.assertEqual(split_emails(" Eng@acme.com,,eng@acme.com, gone@acme.com"), ["eng@acme.com", "gone@acme.com"])
        merged = merge_current(ITEMS, ["eng@acme.com", "gone@acme.com"])
        self.assertEqual(merged[0], Item("gone@acme.com", "gone@acme.com", "not found in the directory"))
        self.assertEqual(len(merged), 4)

    def test_pick_plain_toggle_filter_save(self):
        out = []
        # Toggle 1 (eng) off, filter to "fin", select it, clear filter, save.
        result = pick_plain("t", ITEMS, {"eng@acme.com"}, read=scripted("1", "/fin", "1", "/", "s"), write=out.append)
        self.assertEqual(result, {"fin@acme.com"})
        self.assertTrue(any("(filter: fin)" in line for line in out))

    def test_pick_plain_rejects_bad_input_and_cancels(self):
        out = []
        self.assertIsNone(pick_plain("t", ITEMS, set(), read=scripted("9", "q"), write=out.append))
        self.assertTrue(any("isn't between 1 and 3" in line for line in out))

        def eof(_prompt):
            raise EOFError
        self.assertIsNone(pick_plain("t", ITEMS, set(), read=eof, write=out.append))

    def test_load_items_sorts_and_skips_suspended_users(self):
        class FakeDirectory:
            def list_groups(self):
                return [{"email": "Zeta@acme.com", "name": "Zeta", "members": 1},
                        {"email": "alpha@acme.com", "name": "alpha", "members": 0}]

            def list_users(self):
                return {"1": GoogleUser("1", "a@acme.com", "A", "A", "Ann", False),
                        "2": GoogleUser("2", "s@acme.com", "S", "S", "Sue", True)}

        self.assertEqual([i.key for i in load_items("groups", FakeDirectory())], ["alpha@acme.com", "zeta@acme.com"])
        self.assertEqual([i.key for i in load_items("users", FakeDirectory())], ["a@acme.com"])


if __name__ == "__main__":
    unittest.main()
