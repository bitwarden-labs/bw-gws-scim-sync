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
    link: bool = False  # existing group has no externalId yet; set it so later runs match by id
    reason: str = ""


@dataclass
class Plan:
    create_users: list[GoogleUser] = field(default_factory=list)
    reactivate: list[BwUser] = field(default_factory=list)
    revoke: list[BwUser] = field(default_factory=list)
    delete: list[BwUser] = field(default_factory=list)
    groups: list[GroupChange] = field(default_factory=list)
    adopt_users: list[tuple[str, BwUser]] = field(default_factory=list)  # (google user id, member)
    id_map: dict[str, str] = field(default_factory=dict)  # google user id -> bitwarden member id
    warnings: list[str] = field(default_factory=list)
    reasons: dict[str, str] = field(default_factory=dict)  # lowercased email -> why it changes

    @property
    def removal_count(self) -> int:
        return len(self.revoke) + len(self.delete)

    def _why(self, email: str) -> dict:
        return {"email": email, "reason": self.reasons.get(email.lower(), "")}

    def summary(self) -> dict:
        return {
            "create_users": [self._why(u.email) for u in self.create_users],
            "reactivate": [self._why(u.email) for u in self.reactivate],
            "revoke": [self._why(u.email) for u in self.revoke],
            "delete": [self._why(u.email) for u in self.delete],
            "adopt_users": [self._why(bw.email) for _, bw in self.adopt_users],
            "groups": [
                {
                    "group": c.google_group.name,
                    "action": "create" if c.bw_group_id is None else "update",
                    "members": len(c.google_group.member_ids),
                    "reason": c.reason,
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
    adopt_groups: set[str] | None = None,
    adopt_all_users: bool = False,
    adopt_user_emails: set[str] | None = None,
) -> Plan:
    protected = {e.lower() for e in (protected_emails or set())}
    adopt = {e.lower() for e in (adopt_groups or set())}
    adopt_emails = {e.lower() for e in (adopt_user_emails or set())}
    plan = Plan()

    # Scope = every non-suspended user in any synced group (nested membership already flattened).
    scope: set[str] = set()
    for group in google_groups:
        eligible = {
            gid for gid in group.member_ids
            if gid in google_users and not google_users[gid].suspended
        }
        skipped = len(group.member_ids) - len(eligible)
        if skipped:
            plan.warnings.append(
                f"{group.email}: skipped {skipped} member(s) that are suspended or not users of "
                "this Workspace (e.g. external addresses)."
            )
        group.member_ids = eligible
        scope |= group.member_ids

    groups_of: dict[str, list[str]] = {}  # google user id -> names of the synced groups it's in
    for group in google_groups:
        for gid in group.member_ids:
            groups_of.setdefault(gid, []).append(group.name)

    def in_groups(gid: str) -> str:
        return "in " + ", ".join(sorted(groups_of[gid]))

    bw_by_ext = {u.external_id: u for u in bw_users if u.external_id}
    bw_by_email = {u.email.lower(): u for u in bw_users if u.email}

    for gid in sorted(scope, key=lambda i: google_users[i].email):
        guser = google_users[gid]
        if gid in bw_by_ext:
            bw = bw_by_ext[gid]
            plan.id_map[gid] = bw.id
            if not bw.active:
                plan.reactivate.append(bw)
                plan.reasons[bw.email.lower()] = f"back {in_groups(gid)}"
        elif guser.email.lower() in bw_by_email:
            bw = bw_by_email[guser.email.lower()]
            plan.id_map[gid] = bw.id
            email = guser.email.lower()
            wants_adopt = (adopt_all_users or email in adopt_emails) and email not in protected
            if wants_adopt and bw.external_id:
                plan.warnings.append(
                    f"{guser.email} already has externalId {bw.external_id!r} from another tool; "
                    "not adopting it."
                )
            elif wants_adopt:
                # Link it to the Google user so later runs manage it, revocation included.
                plan.adopt_users.append((gid, bw))
                plan.reasons[bw.email.lower()] = (
                    f"matches a Google user by email and ADOPT_USERS allows it; {in_groups(gid)}"
                )
                if not bw.active:
                    plan.reactivate.append(bw)
            elif not bw.active:
                plan.warnings.append(
                    f"{guser.email} exists in Bitwarden but is revoked and was not provisioned "
                    "by this sync; leaving it for an admin to restore."
                )
        else:
            plan.create_users.append(guser)
            plan.reasons[guser.email.lower()] = in_groups(gid)

    if removal_action != "none":
        for bw in bw_users:
            if not _is_managed(bw, google_users) or bw.external_id in scope:
                continue
            if bw.email.lower() in protected:
                plan.warnings.append(f"{bw.email} is out of scope but protected; skipping removal.")
                continue
            guser = google_users.get(bw.external_id)
            if guser is None:
                why = "no longer in this Google Workspace (deleted, or moved out)"
            elif guser.suspended:
                why = "suspended or archived in Google"
            else:
                why = "no longer in any synced group"
            if removal_action == "delete":
                plan.delete.append(bw)
                plan.reasons[bw.email.lower()] = why
            elif bw.active:
                plan.revoke.append(bw)
                plan.reasons[bw.email.lower()] = why

    bw_groups_by_ext = {g.external_id: g for g in bw_groups if g.external_id}
    bw_groups_by_name = {g.display_name.lower(): g for g in bw_groups}
    for group in google_groups:
        existing = bw_groups_by_ext.get(group.id)
        if existing is not None:
            plan.groups.append(GroupChange(group, existing.id, existing.external_id,
                                           reason="linked to this Google group"))
            continue
        same_name = bw_groups_by_name.get(group.name.lower())
        if same_name is None:
            plan.groups.append(GroupChange(group, None, group.id, reason="no Bitwarden group yet"))
        elif group.email.lower() in adopt:
            # Explicitly adopted: keep its externalId if it has one, to avoid fighting other tools.
            plan.groups.append(GroupChange(group, same_name.id, same_name.external_id or group.id,
                                           link=not same_name.external_id,
                                           reason="same name, taken over through ADOPT_GROUPS"))
        else:
            # Updating would replace the members of a group this sync didn't create.
            plan.warnings.append(
                f'{group.email}: Bitwarden already has a group named "{same_name.display_name}" '
                "that this sync didn't create; skipping it. Add the Google group to ADOPT_GROUPS "
                "to let the sync take it over (its members will be replaced)."
            )

    return plan
