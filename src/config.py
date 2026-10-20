"""Configuration from environment variables (set by setup.sh on the Cloud Run job)."""
import os
from dataclasses import dataclass

REMOVAL_ACTIONS = ("revoke", "delete", "none")
GROUP_UPDATE_MODES = ("put", "patch")


def _bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _list(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    return [item.strip() for item in raw.split(",") if item.strip()]


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


@dataclass(frozen=True)
class Config:
    bw_scim_url: str
    bw_scim_api_key: str
    google_admin_email: str
    google_sa_email: str
    google_sa_key_json: str | None
    google_groups: list[str]
    dry_run: bool
    removal_action: str
    protected_emails: set[str]
    max_removals: int
    group_update_mode: str

    @staticmethod
    def from_env() -> "Config":
        action = os.environ.get("REMOVAL_ACTION", "revoke").strip().lower()
        if action not in REMOVAL_ACTIONS:
            raise SystemExit(f"REMOVAL_ACTION must be one of {REMOVAL_ACTIONS}, got {action!r}")
        group_mode = os.environ.get("GROUP_UPDATE_MODE", "put").strip().lower()
        if group_mode not in GROUP_UPDATE_MODES:
            raise SystemExit(f"GROUP_UPDATE_MODE must be one of {GROUP_UPDATE_MODES}, got {group_mode!r}")
        groups = _list("GOOGLE_GROUPS")
        if not groups:
            raise SystemExit("GOOGLE_GROUPS must list at least one Google group email")
        return Config(
            bw_scim_url=_required("BW_SCIM_URL").rstrip("/"),
            bw_scim_api_key=_required("BW_SCIM_API_KEY"),
            google_admin_email=_required("GOOGLE_ADMIN_EMAIL"),
            google_sa_email=os.environ.get("GOOGLE_SA_EMAIL", "").strip(),
            google_sa_key_json=os.environ.get("GOOGLE_SA_KEY_JSON") or None,
            google_groups=groups,
            dry_run=_bool("DRY_RUN", True),
            removal_action=action,
            protected_emails={e.lower() for e in _list("PROTECTED_EMAILS")},
            max_removals=int(os.environ.get("MAX_REMOVALS", "10")),
            group_update_mode=group_mode,
        )
