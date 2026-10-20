"""Pure diff logic: Google Workspace state + Bitwarden SCIM state -> a plan. No I/O here."""
import re
from dataclasses import dataclass, field

from .models import BwGroup, BwUser, GoogleGroup, GoogleUser

# Google Workspace user ids are long numeric strings. Directory Connector also uses them as
# externalId, so orgs migrating from DC are picked up as "managed" automatically.
GOOGLE_USER_ID = re.compile(r"^\d{15,25}$")


@dataclass
class GroupChange:
    google_group: GoogleGroup
    bw_group_id: str | None  # None means create
    external_id: str


@dataclass
class Plan:
    create_users: list[GoogleUser] = field(default_factory=list)
    reactivate: list[BwUser] = field(default_factory=list)
    revoke: list[BwUser] = field(default_factory=list)
    delete: list[BwUser] = field(default_factory=list)
    groups: list[GroupChange] = field(default_factory=list)
    id_map: dict[str, str] = field(default_factory=dict)  # google user id -> bitwarden member id
    warnings: list[str] = field(default_factory=list)

    @property
    def removal_count(self) -> int:
        return len(self.revoke) + len(self.delete)

    def summary(self) -> dict:
        return {
            "create_users": [u.email for u in self.create_users],
            "reactivate": [u.email for u in self.reactivate],
            "revoke": [u.email for u in self.revoke],
            "delete": [u.email for u in self.delete],
            "groups": [
                {
                    "group": c.google_group.name,
                    "action": "create" if c.bw_group_id is None else "update",
                    "members": len(c.google_group.member_ids),
                }
                for c in self.groups
            ],
            "warnings": self.warnings,
        }


def _is_managed(bw: BwUser, google_users: dict[str, GoogleUser]) -> bool:
    """A Bitwarden member is managed by this sync only if its externalId is a Google user id."""
    ext = bw.external_id
    return bool(ext) and (ext in google_users or bool(GOOGLE_USER_ID.match(ext)))


def build_plan(
    google_users: dict[str, GoogleUser],
    google_groups: list[GoogleGroup],
    bw_users: list[BwUser],
    bw_groups: list[BwGroup],
    removal_action: str = "revoke",
    protected_emails: set[str] | None = None,
) -> Plan:
    protected = {e.lower() for e in (protected_emails or set())}
    plan = Plan()

    # Scope = every non-suspended user in any synced group (nested membership already flattened).
    scope: set[str] = set()
    for group in google_groups:
        group.member_ids = {
            gid for gid in group.member_ids
            if gid in google_users and not google_users[gid].suspended
        }
        scope |= group.member_ids

    bw_by_ext = {u.external_id: u for u in bw_users if u.external_id}
    bw_by_email = {u.email.lower(): u for u in bw_users if u.email}

    for gid in sorted(scope, key=lambda i: google_users[i].email):
        guser = google_users[gid]
        if gid in bw_by_ext:
            bw = bw_by_ext[gid]
            plan.id_map[gid] = bw.id
            if not bw.active:
                plan.reactivate.append(bw)
        elif guser.email.lower() in bw_by_email:
            bw = bw_by_email[guser.email.lower()]
            plan.id_map[gid] = bw.id
            if not bw.active:
                plan.warnings.append(
                    f"{guser.email} exists in Bitwarden but is revoked and was not provisioned "
                    "by this sync; leaving it for an admin to restore."
                )
        else:
            plan.create_users.append(guser)

    if removal_action != "none":
        for bw in bw_users:
            if not _is_managed(bw, google_users) or bw.external_id in scope:
                continue
            if bw.email.lower() in protected:
                plan.warnings.append(f"{bw.email} is out of scope but protected; skipping removal.")
                continue
            if removal_action == "delete":
                plan.delete.append(bw)
            elif bw.active:
                plan.revoke.append(bw)

    bw_groups_by_ext = {g.external_id: g for g in bw_groups if g.external_id}
    bw_groups_by_name = {g.display_name.lower(): g for g in bw_groups}
    for group in google_groups:
        existing = bw_groups_by_ext.get(group.id) or bw_groups_by_name.get(group.name.lower())
        if existing is None:
            plan.groups.append(GroupChange(group, None, group.id))
        else:
            # Keep whatever externalId the Bitwarden group already has, to avoid fighting other tools.
            plan.groups.append(GroupChange(group, existing.id, existing.external_id or group.id))

    return plan
