# How the sync is built

Diagrams of what runs where, how settings flow, and how the code fits together. You don't need this
page to set up or run the sync; see [README.md](../README.md) and the
[admin guide](ADMIN_GUIDE.md).

## Components

```mermaid
flowchart LR
    ADMIN["You, in Cloud Shell<br/>setup.sh · select-groups.sh"]
    subgraph GCP["Your Google Cloud project"]
        SCHED["Cloud Scheduler<br/>bw-scim-sync-schedule"]
        JOB["Cloud Run job<br/>bw-scim-sync"]
        SA(["Service account<br/>bw-scim-sync<br/>no key file"])
        SECRET[("Secret Manager<br/>bw-scim-api-key")]
        IAMC["IAM Credentials API"]
        LOGS[("Cloud Logging")]
    end
    subgraph GWS["Google Workspace"]
        DWD["Domain-wide delegation<br/>3 read-only scopes"]
        DIR["Directory API<br/>users and groups"]
    end
    subgraph BWD["Bitwarden"]
        SCIM["SCIM endpoint"]
        ORG["Your organization<br/>members and groups"]
    end
    ADMIN -- "deploys, reads and<br/>updates settings" --> JOB
    SCHED -- "starts on schedule" --> JOB
    JOB -. "runs as" .-> SA
    SECRET -- "SCIM API key" --> JOB
    JOB -- "signs its own token" --> IAMC
    JOB -- "reads, read-only" --> DIR
    DWD -. "allows" .-> DIR
    JOB -- "invites, revokes,<br/>updates groups" --> SCIM
    SCIM --> ORG
    JOB -- "plan and results" --> LOGS
```

## Where the settings live

The job's settings are environment variables on the Cloud Run job. See
[Settings](ADMIN_GUIDE.md#settings) for what each one does.

```mermaid
flowchart TB
    subgraph TOOLS["How you change them"]
        direction LR
        SETUP["setup.sh<br/>1 reads what's deployed<br/>2 asks, current values as defaults<br/>3 creates or updates in place"]
        PICK["select-groups.sh<br/>reads the job's settings,<br/>checklist from your directory,<br/>saves one list"]
        CON["Console, or<br/>gcloud run jobs update"]
    end
    subgraph ENV["Environment variables on the Cloud Run job bw-scim-sync"]
        direction LR
        E1["Asked by setup.sh<br/>BW_SCIM_URL<br/>GOOGLE_ADMIN_EMAIL<br/>GOOGLE_SA_EMAIL<br/>GOOGLE_GROUPS<br/>DRY_RUN=true, first deploy only"]
        E2["Picked from your directory<br/>GOOGLE_GROUPS<br/>PROTECTED_EMAILS<br/>ADOPT_USERS"]
        E3["Optional<br/>DRY_RUN · REMOVAL_ACTION<br/>MAX_REMOVALS · ADOPT_GROUPS<br/>GROUP_UPDATE_MODE"]
        E4["BW_SCIM_API_KEY<br/>linked to the secret"]
    end
    SECRET[("Secret Manager<br/>bw-scim-api-key")]
    SCHED["Cloud Scheduler<br/>schedule and time zone"]
    SETUP <-- "reads and writes" --> E1
    PICK <-- "reads and writes" --> E2
    CON <-- "reads and writes any" --> E3
    SETUP <-- "reads and writes" --> SCHED
    SETUP -- "new key, if entered" --> SECRET
    SECRET --> E4
```

## One sync run

```mermaid
sequenceDiagram
    autonumber
    participant S as Cloud Scheduler
    participant J as Cloud Run job
    participant I as IAM Credentials API
    participant O as Google sign-in
    participant G as Directory API
    participant B as Bitwarden SCIM
    S->>J: Start the job
    Note over J: SCIM API key is read from Secret Manager at start
    J->>I: Sign a delegation token as bw-scim-sync
    I-->>J: Signed token
    J->>O: Exchange it for read-only directory access
    O-->>J: Access token
    J->>G: Read users, and each chosen group's members at every nesting level
    G-->>J: Users and flattened group members
    J->>B: Read members and groups
    B-->>J: Members and groups
    Note over J: Compare and build the plan.<br/>Safety checks: MAX_REMOVALS, protected users, same-named groups
    alt DRY_RUN is true
        Note over J: Log the plan only
    else DRY_RUN is false
        J->>B: Invite, restore, update groups, revoke
    end
    Note over J: Every step is logged to Cloud Logging
```

## Nested groups

Only the groups in `GOOGLE_GROUPS` become Bitwarden groups. For each one, the sync asks Google for
its members at every level of nesting and keeps only people. A group inside it is not created in
Bitwarden; its people are added to the parent's Bitwarden group instead.

```mermaid
flowchart LR
    subgraph G["Google Workspace"]
        ENG["engineering@<br/>synced"]
        BE["backend@<br/>not synced"]
        ANA(["Ana"])
        BEN(["Ben"])
        CHO(["Cho"])
        EXT(["pat@gmail.com<br/>outside address"])
        ENG --> ANA
        ENG --> BE
        ENG --> EXT
        BE --> BEN
        BE --> CHO
    end
    subgraph B["Bitwarden"]
        BENG["Group Engineering<br/>Ana, Ben, Cho"]
    end
    ENG -- "sync" --> BENG
```

`pat@gmail.com` is skipped because only users of your Google Workspace are synced. `backend@` gets
no Bitwarden group of its own unless you also pick it.

## select-groups.sh

```mermaid
sequenceDiagram
    actor A as You in Cloud Shell
    participant S as select-groups.sh
    participant R as Cloud Run job settings
    participant G as Directory API
    A->>S: bash select-groups.sh
    S->>R: Read GOOGLE_ADMIN_EMAIL, GOOGLE_SA_EMAIL<br/>and the current list
    S->>G: List groups, with the sync's read-only access
    G-->>S: All groups and direct member counts
    S->>A: Checklist, current groups ticked
    A->>S: Tick, untick, Enter
    S->>A: Groups added and removed
    A->>S: y to save
    S->>R: Save GOOGLE_GROUPS, or PROTECTED_EMAILS<br/>or ADOPT_USERS with the options
    opt Dry run
        S->>A: Planned changes. Nothing changes in Bitwarden
    end
```

## Code (maintainers)

```mermaid
flowchart TB
    SEL["select-groups.sh"] --> PICK["src/picker.py<br/>directory picker"]
    SEL -- "dry run" --> MAIN
    PICK --> GD
    MAIN["src/main.py<br/>run and apply"] --> CONFIG["src/config.py<br/>settings from environment variables"]
    MAIN --> GD["src/google_directory.py<br/>Directory API, keyless delegation"]
    MAIN --> SCIMC["src/bitwarden_scim.py<br/>Bitwarden SCIM client"]
    MAIN --> PLAN["src/planner.py<br/>pure diff, no I/O"]
    MAIN --> LOG["src/log.py<br/>JSON log lines"]
    GD --> HTTP["src/http.py<br/>retries"]
    SCIMC --> HTTP
    HTTP --> LOG
    GD --> MODELS["src/models.py"]
    SCIMC --> MODELS
    PLAN --> MODELS
```

Nested membership is flattened by Google, not by this code: `get_group` in
`src/google_directory.py` lists members with `includeDerivedMembership=true` and keeps entries of
type `USER`.

## GitHub workflows and the test environment (maintainers)

```mermaid
flowchart LR
    subgraph GH["GitHub repository"]
        PUSH["Push or pull request"] --> CI["ci.yml<br/>ruff · unit tests · shellcheck · docker build"]
        WEEK["Weekly"] --> DRIFT["scim-drift.yml"]
        DAY["Daily"] --> LIVE["live-dry-run.yml<br/>environment live-test"]
        ISSUE["Drift issue"]
    end
    DRIFT -- "SCIM commits since the baseline" --> BWS["bitwarden/server<br/>SCIM source"]
    DRIFT -- "opens or updates" --> ISSUE
    LIVE -- "GitHub OIDC token" --> WIF["Workload Identity pool<br/>in the test project"]
    WIF -- "acts as" --> SA(["bw-scim-sync<br/>service account"])
    SA -- "read-only delegation" --> DIR["Directory API<br/>test Workspace"]
    LIVE -- "SCIM URL and key from<br/>environment secrets, read only" --> SCIM["Bitwarden SCIM<br/>test organization"]
```
