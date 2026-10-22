import os
import unittest
from unittest import mock

from src.config import Config

BASE = {"BW_SCIM_URL": "https://scim.example/v2/org", "BW_SCIM_API_KEY": "k", "GOOGLE_ADMIN_EMAIL": "a@acme.com"}


class ConfigTests(unittest.TestCase):
    def load(self, **env):
        with mock.patch.dict(os.environ, {**BASE, **env}, clear=True):
            return Config.from_env()

    def test_groups_are_required_unless_deleting(self):
        with self.assertRaises(SystemExit):
            self.load()
        cfg = self.load(DELETE_GROUPS="Eng@acme.com")
        self.assertEqual((cfg.google_groups, cfg.delete_groups), ([], ["eng@acme.com"]))

    def test_synced_group_is_never_deleted(self):
        cfg = self.load(GOOGLE_GROUPS="eng@acme.com", DELETE_GROUPS="ENG@acme.com,fin@acme.com")
        self.assertEqual(cfg.delete_groups, ["fin@acme.com"])


if __name__ == "__main__":
    unittest.main()
