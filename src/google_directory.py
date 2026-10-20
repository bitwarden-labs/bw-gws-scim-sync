"""Read-only Google Workspace Directory API client using domain-wide delegation.

Default auth is keyless: the Cloud Run job's own service account signs the delegation JWT through
the IAM Credentials API, so no service-account key file is needed. (New Google Cloud organizations
block key creation by default.) A key JSON can still be supplied via GOOGLE_SA_KEY_JSON.
"""
import json

from .http import request_with_retry
from .models import GoogleGroup, GoogleUser

SCOPES = [
    "https://www.googleapis.com/auth/admin.directory.user.readonly",
    "https://www.googleapis.com/auth/admin.directory.group.readonly",
    "https://www.googleapis.com/auth/admin.directory.group.member.readonly",
]
TOKEN_URI = "https://oauth2.googleapis.com/token"
BASE = "https://admin.googleapis.com/admin/directory/v1"


def build_credentials(sa_email: str, admin_email: str, sa_key_json: str | None = None):
    from google.oauth2 import service_account

    if sa_key_json:
        info = json.loads(sa_key_json)
        return service_account.Credentials.from_service_account_info(
            info, scopes=SCOPES, subject=admin_email
        )

    import google.auth
    from google.auth import iam
    from google.auth.transport.requests import Request

    if not sa_email:
        raise SystemExit("GOOGLE_SA_EMAIL is required for keyless domain-wide delegation")
    source, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    signer = iam.Signer(Request(), source, sa_email)
    return service_account.Credentials(
        signer, sa_email, TOKEN_URI, scopes=SCOPES, subject=admin_email
    )


class GoogleDirectory:
    def __init__(self, credentials):
        from google.auth.transport.requests import AuthorizedSession

        self.session = AuthorizedSession(credentials)

    def _get(self, path: str, params: dict) -> dict:
        resp = request_with_retry(self.session, "GET", f"{BASE}{path}", params=params)
        if resp.status_code >= 400:
            raise RuntimeError(f"Google Directory API {path} failed: {resp.status_code} {resp.text[:500]}")
        return resp.json()

    def _paged(self, path: str, params: dict, key: str):
        token = None
        while True:
            page = self._get(path, {**params, **({"pageToken": token} if token else {})})
            yield from page.get(key, [])
            token = page.get("nextPageToken")
            if not token:
                return

    def list_users(self) -> dict[str, GoogleUser]:
        users = {}
        for u in self._paged("/users", {"customer": "my_customer", "maxResults": 500}, "users"):
            name = u.get("name", {})
            users[u["id"]] = GoogleUser(
                id=u["id"],
                email=u["primaryEmail"],
                given_name=name.get("givenName", ""),
                family_name=name.get("familyName", ""),
                full_name=name.get("fullName", u["primaryEmail"]),
                suspended=bool(u.get("suspended")) or bool(u.get("archived")),
            )
        return users

    def get_group(self, group_email: str) -> GoogleGroup:
        g = self._get(f"/groups/{group_email}", {})
        members = {
            m["id"]
            for m in self._paged(
                f"/groups/{g['id']}/members",
                {"maxResults": 200, "includeDerivedMembership": "true"},
                "members",
            )
            if m.get("type") == "USER" and m.get("id")
        }
        return GoogleGroup(id=g["id"], email=g["email"], name=g.get("name") or g["email"], member_ids=members)
