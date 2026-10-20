"""Entry point: one sync pass from Google Workspace to a Bitwarden organization via SCIM."""
import sys

from .bitwarden_scim import BitwardenScim, ScimError
from .config import Config
from .google_directory import GoogleDirectory, build_credentials
from .log import log
from .planner import Plan, build_plan


def apply(plan: Plan, scim: BitwardenScim, group_update_mode: str = "put") -> int:
    errors = 0
    id_map = dict(plan.id_map)

    for u in plan.create_users:
        try:
            id_map[u.id] = scim.create_user(u.id, u.email, u.given_name, u.family_name, u.full_name)
            log("INFO", "Invited user", email=u.email)
        except ScimError as e:
            errors += 1
            log("ERROR", "Create user failed", email=u.email, status=e.status, error=str(e))

    for gid, bw in plan.adopt_users:
        try:
            scim.set_user_external_id(bw.id, gid)
            log("INFO", "Adopted user", email=bw.email, external_id=gid)
        except ScimError as e:
            errors += 1
            log("ERROR", "Adopt user failed", email=bw.email, status=e.status, error=str(e))

    for bw in plan.reactivate:
        try:
            scim.set_active(bw.id, True)
            log("INFO", "Restored user", email=bw.email)
        except ScimError as e:
            errors += 1
            log("ERROR", "Restore user failed", email=bw.email, error=str(e))

    for change in plan.groups:
        g = change.google_group
        members = sorted(id_map[gid] for gid in g.member_ids if gid in id_map)
        try:
            if change.bw_group_id is None:
                scim.create_group(g.name, change.external_id, members)
                log("INFO", "Created group", group=g.name, members=len(members))
            elif group_update_mode == "patch":
                result = scim.patch_group(change.bw_group_id, g.name, members)
                log("INFO", "Updated group", group=g.name, members=len(members), **result)
            else:
                scim.replace_group(change.bw_group_id, g.name, change.external_id, members)
                log("INFO", "Updated group", group=g.name, members=len(members), strategy="put")
            if change.link:
                scim.set_group_external_id(change.bw_group_id, change.external_id)
                log("INFO", "Linked group", group=g.name, external_id=change.external_id)
        except ScimError as e:
            errors += 1
            log("ERROR", "Group sync failed", group=g.name, error=str(e))

    for bw in plan.revoke:
        try:
            scim.set_active(bw.id, False)
            log("INFO", "Revoked user", email=bw.email)
        except ScimError as e:
            errors += 1
            log("ERROR", "Revoke user failed", email=bw.email, error=str(e))

    for bw in plan.delete:
        try:
            scim.delete_user(bw.id)
            log("INFO", "Removed user", email=bw.email)
        except ScimError as e:
            errors += 1
            log("ERROR", "Remove user failed", email=bw.email, error=str(e))

    return errors


def run() -> int:
    cfg = Config.from_env()
    creds = build_credentials(cfg.google_sa_email, cfg.google_admin_email, cfg.google_sa_key_json)
    directory = GoogleDirectory(creds)
    scim = BitwardenScim(cfg.bw_scim_url, cfg.bw_scim_api_key)

    google_users = directory.list_users()
    google_groups = [directory.get_group(email) for email in cfg.google_groups]
    plan = build_plan(
        google_users, google_groups, scim.list_users(), scim.list_groups(),
        removal_action=cfg.removal_action, protected_emails=cfg.protected_emails,
        adopt_groups=cfg.adopt_groups,
        adopt_all_users=cfg.adopt_all_users, adopt_user_emails=cfg.adopt_user_emails,
    )

    if not any(g.member_ids for g in google_groups):
        log("ERROR", "Synced groups have no active members; refusing to run (check GOOGLE_GROUPS)")
        return 2
    if plan.removal_count > cfg.max_removals:
        log("ERROR", "Planned removals exceed MAX_REMOVALS; refusing to run",
            planned=plan.removal_count, max_removals=cfg.max_removals, plan=plan.summary())
        return 3

    for w in plan.warnings:
        log("WARNING", w)
    log("INFO", "Sync plan", dry_run=cfg.dry_run, plan=plan.summary())

    if cfg.dry_run:
        log("NOTICE", "DRY_RUN is on: no changes were made. Set DRY_RUN=false to apply.")
        return 0

    errors = apply(plan, scim, cfg.group_update_mode)
    log("INFO" if errors == 0 else "ERROR", "Sync finished", errors=errors)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(run())
