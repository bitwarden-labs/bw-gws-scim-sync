from dataclasses import dataclass, field


@dataclass(frozen=True)
class GoogleUser:
    id: str
    email: str
    given_name: str
    family_name: str
    full_name: str
    suspended: bool


@dataclass
class GoogleGroup:
    id: str
    email: str
    name: str
    member_ids: set[str] = field(default_factory=set)  # Google user ids, nested groups flattened


@dataclass(frozen=True)
class BwUser:
    id: str
    external_id: str | None
    email: str
    active: bool


@dataclass(frozen=True)
class BwGroup:
    id: str
    external_id: str | None
    display_name: str
