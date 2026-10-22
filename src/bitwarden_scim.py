"""Client for a Bitwarden organization's SCIM 2.0 endpoint (cloud or self-hosted)."""
import requests

from .http import request_with_retry
from .models import BwGroup, BwUser

USER_SCHEMA = "urn:ietf:params:scim:schemas:core:2.0:User"
GROUP_SCHEMA = "urn:ietf:params:scim:schemas:core:2.0:Group"
PATCH_SCHEMA = "urn:ietf:params:scim:api:messages:2.0:PatchOp"
PAGE_SIZE = 100


class ScimError(RuntimeError):
    def __init__(self, status: int, body: str):
        super().__init__(f"SCIM request failed: {status} {body[:500]}")
        self.status = status


class BitwardenScim:
    def __init__(self, base_url: str, api_key: str):
        self.base = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/scim+json",
            "Accept": "application/scim+json, application/json",
            "User-Agent": "bw-gws-scim-sync/0.1",
        })

    def _call(self, method: str, path: str, **kwargs) -> dict:
        resp = request_with_retry(self.session, method, f"{self.base}{path}", **kwargs)
        if resp.status_code >= 400:
            raise ScimError(resp.status_code, resp.text)
        return resp.json() if resp.content else {}

    def _list(self, path: str):
        start = 1
        while True:
            page = self._call("GET", path, params={"startIndex": start, "count": PAGE_SIZE})
            resources = page.get("Resources") or page.get("resources") or []
            yield from resources
            total = page.get("totalResults", 0)
            start += len(resources)
            if not resources or start > total:
                return

    @staticmethod
    def _user_email(r: dict) -> str:
        emails = r.get("emails") or []
        primary = next((e.get("value") for e in emails if e.get("primary")), None)
        return (primary or (emails[0].get("value") if emails else None) or r.get("userName") or "").lower()

    def list_users(self) -> list[BwUser]:
        return [
            BwUser(id=r["id"], external_id=r.get("externalId") or None,
                   email=self._user_email(r), active=bool(r.get("active", True)))
            for r in self._list("/Users")
        ]

    def list_groups(self) -> list[BwGroup]:
        return [
            BwGroup(id=r["id"], external_id=r.get("externalId") or None,
                    display_name=r.get("displayName", ""))
            for r in self._list("/Groups")
        ]

    def create_user(self, external_id: str, email: str, given: str, family: str, display: str) -> str:
        body = {
            "schemas": [USER_SCHEMA],
            "externalId": external_id,
            "userName": email,
            "displayName": display,
            "name": {"givenName": given, "familyName": family},
            "emails": [{"value": email, "primary": True, "type": "work"}],
            "active": True,
        }
        data = self._call("POST", "/Users", json=body)
        if not data.get("id"):
            raise ScimError(201, f"no member id returned for {email}")
        return data["id"]

    def set_active(self, member_id: str, active: bool) -> None:
        body = {"schemas": [PATCH_SCHEMA],
                "Operations": [{"op": "replace", "path": "active", "value": active}]}
        self._call("PATCH", f"/Users/{member_id}", json=body)

    def set_user_external_id(self, member_id: str, external_id: str) -> None:
        # Bitwarden only handles "replace" for a member's externalId; "add" is silently ignored.
        body = {"schemas": [PATCH_SCHEMA],
                "Operations": [{"op": "replace", "path": "externalId", "value": external_id}]}
        self._call("PATCH", f"/Users/{member_id}", json=body)

    def delete_user(self, member_id: str) -> None:
        self._call("DELETE", f"/Users/{member_id}")

    def _group_body(self, name: str, external_id: str, member_ids: list[str]) -> dict:
        return {"schemas": [GROUP_SCHEMA], "displayName": name, "externalId": external_id,
                "members": [{"value": m} for m in member_ids]}

    def create_group(self, name: str, external_id: str, member_ids: list[str]) -> str:
        return self._call("POST", "/Groups", json=self._group_body(name, external_id, member_ids))["id"]

    def replace_group(self, group_id: str, name: str, external_id: str, member_ids: list[str]) -> None:
        self._call("PUT", f"/Groups/{group_id}", json=self._group_body(name, external_id, member_ids))

    def patch_group(self, group_id: str, name: str, member_ids: list[str]) -> dict:
        """Update a group with PATCH operations instead of PUT.

        Bitwarden's GET /Groups never returns members, so membership is always set with a single
        replace on "members". Returns a small summary for logging.
        """
        ops = [
            {"op": "replace", "path": "displayName", "value": name},
            {"op": "replace", "path": "members", "value": [{"value": m} for m in sorted(set(member_ids))]},
        ]
        self._call("PATCH", f"/Groups/{group_id}", json={"schemas": [PATCH_SCHEMA], "Operations": ops})
        return {"strategy": "patch"}

    def delete_group(self, group_id: str) -> None:
        self._call("DELETE", f"/Groups/{group_id}")

    def set_group_external_id(self, group_id: str, external_id: str) -> None:
        """Bitwarden ignores externalId on PUT /Groups, so linking an existing group needs PATCH."""
        body = {"schemas": [PATCH_SCHEMA],
                "Operations": [{"op": "replace", "path": "externalId", "value": external_id}]}
        self._call("PATCH", f"/Groups/{group_id}", json=body)
