# Testing guide

This guide is for whoever validates the sync before it goes to customers. The end-user guides are
[README.md](../README.md) (setup) and [ADMIN_GUIDE.md](ADMIN_GUIDE.md) (running it). Diagrams of the
code and the GitHub workflows are in [ARCHITECTURE.md](ARCHITECTURE.md).

**Never point a test run at a production Bitwarden organization or a production Google tenant.**

## 1. Unit tests

These need no network access and no accounts.

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover -s tests -t . -v
```

- `tests/test_planner.py` covers the decision logic: who gets invited, restored, revoked or deleted;
  how suspended Google users, protected emails and other identity providers' members are handled;
  how groups are matched; and `ADOPT_GROUPS` / `ADOPT_USERS`.
- `tests/test_picker.py` covers the directory picker used by `select-groups.sh`: selection parsing
  (`1,3,5-7`), filtering, the numbered-list flow, keeping saved emails missing from the directory,
  and how groups and users are listed.
- `tests/test_scim_client.py` runs the SCIM client and the full apply step against an in-process fake
  SCIM server. It covers pagination, invites, revoke, group create, group PUT and PATCH, linking
  adopted groups and users, and an idempotent second run.

The fake server mirrors the bitwarden/server behaviors listed in section 5 (for example, group
responses never include members, and PUT ignores `externalId`). A passing run proves the code is
consistent with those behaviors, not that a live Bitwarden org behaves the same way.

GitHub Actions runs these on every push and pull request (`.github/workflows/ci.yml`), together with
`ruff`, `shellcheck setup.sh`, and a `docker build` that checks the image runs as a non-root user.
A weekly workflow (`.github/workflows/scim-drift.yml`) opens an issue when Bitwarden's SCIM code
changes after the commit section 5 was verified against.

A daily workflow (`.github/workflows/live-dry-run.yml`) runs the real sync against the test Workspace
and Bitwarden org with `DRY_RUN` forced on, and writes the planned changes to the job summary. Its
settings live in the `live-test` GitHub environment (limited to `main`): secrets `BW_SCIM_URL` and
`BW_SCIM_API_KEY`, variables `GOOGLE_ADMIN_EMAIL`, `GOOGLE_SA_EMAIL`, `GOOGLE_GROUPS` and
`GCP_WIF_PROVIDER`. Google access uses Workload Identity Federation, so no Google key is stored in
GitHub. After rotating the SCIM key, update it with
`gh secret set BW_SCIM_API_KEY --env live-test`.

## 2. Test environment

You need:

- **A Google Workspace test tenant**, with a super admin account.
- **A Google Cloud project** for the service account. In section 4, it also hosts the Cloud Run job.
- **A Bitwarden test organization** with SCIM enabled (Admin Console → Settings → SCIM
  provisioning). Use cloud, or a local or self-hosted server built from `bitwarden/server`. Make
  sure your own owner account isn't in any Google group you sync.

Create these test fixtures in Google:

| Fixture | Purpose |
|---|---|
| `bw-sync-test@` group containing user **T1** | Basic invite and group sync |
| `bw-sync-parent@` group whose only member is the group `bw-sync-child@`, which contains user **T2** | Nested-group flattening |
| User **T3**, initially in `bw-sync-test@` | Suspend and revoke tests |
| User **T4** invited to Bitwarden by hand, not in any synced group | Must never be touched |
| User **T6** invited to Bitwarden by hand **and** in `bw-sync-test@` | Email matching and `ADOPT_USERS` |
| `bw-sync-legacy@` group containing T1, plus a Bitwarden group named `bw-sync-legacy` created by hand with T4 as its member | Same-name protection and `ADOPT_GROUPS` |
| User **T7** in `bw-sync-test@` | Deleted from Google in step 29 |
| `bw-sync-grandchild@` group containing user **T8**, not yet inside any other group | Deeper nesting, step 31 |

## 3. Running locally

Run `setup.sh` once against the test project, or create the service account and domain-wide
delegation by hand as [MANUAL_SETUP.md](MANUAL_SETUP.md) and README Step 3 describe. Then allow your own Google account to sign as that
service account:

```bash
gcloud auth application-default login
gcloud iam service-accounts add-iam-policy-binding bw-scim-sync@PROJECT.iam.gserviceaccount.com \
  --member user:you@yourdomain.com --role roles/iam.serviceAccountTokenCreator
```

A new IAM grant can take a few minutes to apply. Until it does, runs fail with
`Error calling the IAM signBlob API ... 403`; wait and retry. If they keep failing, check that
`gcloud auth application-default login` used the account you granted.

Put the settings in a `.env.test` file. `.gitignore` already excludes `.env*` files, so don't commit them.

```bash
BW_SCIM_URL=https://scim.bitwarden.com/v2/<test-org-id>
BW_SCIM_API_KEY=...
GOOGLE_ADMIN_EMAIL=admin@test-tenant.com
GOOGLE_SA_EMAIL=bw-scim-sync@PROJECT.iam.gserviceaccount.com
GOOGLE_GROUPS=bw-sync-test@test-tenant.com,bw-sync-parent@test-tenant.com
DRY_RUN=true
```

Load the file and run:

```bash
set -a; source .env.test; set +a
python -m src.main | jq .
```

To use a service-account key instead of keyless signing, set `GOOGLE_SA_KEY_JSON` to the key file's
contents. This only works if the project's organization policy allows key creation.

The script exits with one of these codes:

| Code | Meaning |
|---|---|
| `0` | Success, or a dry run that completed |
| `1` | One or more SCIM calls failed. The run continues past individual failures. |
| `2` | The synced groups have no active members, so the run refused to start |
| `3` | The planned removals exceed `MAX_REMOVALS`, so the run refused to start |

Any other crash, such as a Google 404 for a mistyped group, exits non-zero with a traceback before
changing anything.

## 4. Test sequence

### How to check each step

Every step has three places to check. Check all three: a step passes only when the plan, the log and
Bitwarden agree.

| Where | Local run | Cloud Run |
|---|---|---|
| **Plan** | The `Sync plan` line in the output (`python -m src.main \| jq 'select(.plan)'`), or the plan `select-groups.sh` prints | **Cloud Run → Jobs → bw-scim-sync**, latest execution, task `0` logs, `Sync plan` entry, **jsonPayload → plan** |
| **Log** | The lines after the plan: `Invited user`, `Revoked user`, `Created group`, `Sync finished` and so on, and the exit code (`echo $?`) | The same entries in the task logs, and **Last exit code** on the **Tasks** tab |
| **Bitwarden** | Admin Console of the test org: **Members** (tabs **All**, **Invited**, **Needs confirmation**, **Revoked**) and **Groups → group → Members** | Same |

[Check that a sync worked](ADMIN_GUIDE.md#check-that-a-sync-worked) in the admin guide walks through
the Cloud Run console and lists every log entry. [Read the sync plan](ADMIN_GUIDE.md#read-the-sync-plan)
lists the reasons. Section 6 below has the `gcloud logging read` command.

Run the steps in order. Start every step with `DRY_RUN=true`, check that the plan and its reasons
match the step, and then rerun with `DRY_RUN=false`. This tests the dry-run plan as well as the real
changes. Check T4 after every step: it must never be touched.

Reasons name the Google group by its display name. The steps assume each test group's name matches
its address, for example `bw-sync-test`.

### Sync behavior

| # | Do this | Plan and log show | Bitwarden shows |
|---|---|---|---|
| 1 | First dry run | Plan: T1, T2 and T3 in `create_users` (reason `in bw-sync-test` or `in bw-sync-parent`), both groups with reason `no Bitwarden group yet`. No removals. Log ends with `DRY_RUN is on`. | No change. |
| 2 | Same with `DRY_RUN=false` | `Invited user` ×3, `Created group` ×2, `Sync finished` with `errors: 0`. Exit code 0. | T1, T2 and T3 on **Invited**, and they get invitation emails. **Groups**: `bw-sync-test` and `bw-sync-parent`; the parent contains T2 (nested through `bw-sync-child@`). |
| 3 | Run again with no changes in Google | Empty `create_users`, `reactivate` and `revoke`. One `Updated group` per group (`put`, or `patch` in `patch` mode). | No change. |
| 4 | Add a new user T5 to `bw-sync-child@` | T5 in `create_users`, reason `in bw-sync-parent`. `Invited user`. | T5 on **Invited**, and in `bw-sync-parent`. |
| 5 | Remove T1 from `bw-sync-test@` | T1 in `revoke`, reason `no longer in any synced group`. `Revoked user`. | T1 on **Revoked**, not deleted, and no longer in `bw-sync-test`. |
| 6 | Add T1 back | T1 in `reactivate`, reason `back in bw-sync-test`. `Restored user`. | T1 no longer revoked, and back in the group. |
| 7 | Suspend T3 in Google | T3 in `revoke`, reason `suspended or archived in Google`, and a `skipped 1 member(s)` warning. `Revoked user`. | T3 on **Revoked**. |
| 8 | Check T4 after every step | T4 never appears in the plan. | T4 unchanged. |
| 9 | Set `MAX_REMOVALS=0`, then remove someone from a group | `Planned removals exceed MAX_REMOVALS` at `ERROR`. Exit code 3. | No change. |
| 10 | Set `PROTECTED_EMAILS` to include T5, then remove T5 from the group | Warning `... is out of scope but protected; skipping removal.` T5 not in `revoke`. | T5 unchanged. |
| 11 | Set `GOOGLE_GROUPS` to a group that doesn't exist | Google 404 traceback, no plan. Non-zero exit code. | No change. |
| 12 | Set `REMOVAL_ACTION=delete` and remove T5 (optional) | T5 in `delete`. `Removed user`. | T5 no longer listed in **Members**. |
| 13 | Rotate the SCIM API key in Bitwarden without updating the job | `SCIM request failed: 401`. Storing the new key ([Rotate the SCIM API key](ADMIN_GUIDE.md#everyday-tasks)) fixes it. | No change. |
| 14 | Add `bw-sync-legacy@` to `GOOGLE_GROUPS` | Warning `Bitwarden already has a group named "bw-sync-legacy"`. The group isn't in `groups`. | `bw-sync-legacy` still has T4 as its only member. |
| 15 | Set `ADOPT_GROUPS=bw-sync-legacy@...` | The group in `groups` with reason `same name, taken over through ADOPT_GROUPS`. `Linked group`. The next run without `ADOPT_GROUPS` shows reason `linked to this Google group`. | `bw-sync-legacy` members are now T1 only. |
| 16 | T6 in `bw-sync-test@`, default settings | T6 not in `create_users`. Removing T6 from the Google group doesn't put T6 in `revoke`. | T6 added to `bw-sync-test`, not invited again, never revoked. |
| 17 | Set `ADOPT_USERS=<T6 email>` with T6 in the group | T6 in `adopt_users`, reason `matches a Google user by email and ADOPT_USERS allows it`. `Adopted user`. Removing T6 from the group then revokes T6. | T6 on **Revoked** after the removal. |
| 29 | Delete T7 in the Google Admin console | T7 in `revoke`, reason `no longer in this Google Workspace (deleted, or moved out)`. `Revoked user`. | T7 on **Revoked**. |
| 30 | Remove the group `bw-sync-child@` from `bw-sync-parent@` | T2 (and T5, if still a member) in `revoke`, reason `no longer in any synced group`. `bw-sync-parent` in `groups` with 0 members. | T2 (and T5) on **Revoked**, and `bw-sync-parent` has no members. Add the child group back afterwards: they're restored. |
| 31 | Add `bw-sync-grandchild@` inside `bw-sync-child@` | T8 in `create_users`, reason `in bw-sync-parent`. No `bw-sync-grandchild` group in `groups`. | T8 on **Invited**, and in `bw-sync-parent`. No `bw-sync-grandchild` group. |

### Cloud Run deployment

Test these in a fresh project.

| # | Do this | Expected result |
|---|---|---|
| 18 | `bash setup.sh` in Cloud Shell | Completes and prints the Client ID and scopes. Rerunning it also succeeds. |
| 19 | `gcloud run jobs execute bw-scim-sync --region R --wait` | Completes. The execution shows **1 Succeeded** and exit code 0, and the dry-run plan appears in the task logs. |
| 20 | `gcloud scheduler jobs run bw-scim-sync-schedule --location R` | Starts a new job execution. |
| 21 | Set `DRY_RUN=false` and `PROTECTED_EMAILS=x@...` on the job, then rerun `bash setup.sh` | Both settings are unchanged afterwards (`gcloud run jobs describe bw-scim-sync --region R`). |
| 22 | Repeat 18–20 following MANUAL_SETUP.md instead of `setup.sh`, in another fresh project | Same results. Note any console labels that differ from the guide and fix the guide. |
| 27 | Rerun `bash setup.sh` on a deployed job | It says it found the job, and every prompt shows the current value in brackets (SCIM URL, admin email, groups, schedule, time zone). Enter keeps each one. Enter at the key prompt prints `Keeping the stored key`, and `gcloud secrets versions list bw-scim-api-key` shows no new version. |
| 28 | Rerun `bash setup.sh` and change only the schedule | The scheduler job has the new schedule. The job's environment variables are unchanged. |

### select-groups.sh

| # | Do this | Expected result |
|---|---|---|
| 23 | Run `setup.sh` pressing Enter at the group prompt, finish Step 3, then `bash select-groups.sh` | The job deploys without `GOOGLE_GROUPS`. The picker lists every Workspace group with its direct member count (`bw-sync-parent@` shows 1: the child group). Arrow keys, Space, `/` filter and Enter work. After saving, `gcloud run jobs describe` shows the chosen `GOOGLE_GROUPS`, and the offered dry run prints one line per change with its reason, or `Nothing to change.` |
| 24 | Run `select-groups.sh` again, change nothing, press Enter | It says `No changes.` and doesn't offer to save. `q` cancels without changes. |
| 25 | `select-groups.sh --protected-users`, pick T4; then `--adopt-users`, pick T6 | `PROTECTED_EMAILS` and `ADOPT_USERS` hold those emails. Unselecting everyone removes the variable. |
| 26 | Run `select-groups.sh` from an account that has never used it | It grants that account Token Creator on the service account, waits through the `signBlob` delay, then lists groups. |

Step numbers are kept stable so earlier results stay comparable; new steps get the next free number.

## 5. Bitwarden SCIM behavior to confirm

These behaviors were checked against `bitwarden_license/src/Scim/` in `bitwarden/server`
(`main`, commit 4aa2373b, 2026-10-20). The weekly drift workflow reports later changes to that code.
**Status:** *source* = confirmed in the server code; *live* = observed against a real org;
*open* = still to confirm.

| Behavior | Status | How to check |
|---|---|---|
| `PUT /Groups/{id}` with `members` replaces membership; omitting `members` leaves it alone (`Groups/PutGroupCommand.cs`) | source | Step 2 |
| `PUT /Groups/{id}` ignores `externalId`, so adopted groups are linked with PATCH `replace externalId` (`Groups/PatchGroupCommand.cs`) | source | Step 15 |
| `GET /Groups` and `GET /Groups/{id}` never return `members` (`Models/ScimGroupResponseModel.cs`) | source | — |
| PATCH `replace` on `members` and `displayName` is accepted | source | Steps 3–6 in `patch` mode |
| PATCH `replace` on a member's `externalId` is accepted; `add` is ignored (`Users/PatchUserCommand.cs`) | source | Step 17 |
| `POST /Users` returns 409 if the email or `externalId` already exists, and sends an invite unless the org disabled it (`Users/PostUserCommand.cs`) | source | Step 2 |
| PATCH `{"op":"replace","path":"active","value":false}` revokes a member and `true` restores one | source | Steps 5–7 |
| `Content-Type: application/scim+json` is accepted | source | Any write |
| `GET /Users` and `GET /Groups` paginate with `startIndex` (1-based) and `count` (no maximum); the list key is lowercase `resources` | source, live | Step 1 |
| `GET /Users` lists every member, including owners and manually invited members, with `externalId` and `emails` | live (29 members, 2026-10-20) | Step 1 plan and T4 |
| Bitwarden rejects revoking or deleting the last confirmed owner with 400 | source | — |
| Directory Connector (Google Workspace source) stores the Google user ID as `externalId` | open | Sync a test org with Directory Connector first, then run this tool. Users should match without new invites. |

Known limits, which are expected behavior rather than bugs:

- Name and email changes in Google aren't pushed to Bitwarden.
- Removing a group from `GOOGLE_GROUPS` leaves its Bitwarden group in place.
- Collection access is never managed.

## 6. Reading logs

Local runs print JSON lines to stdout. Cloud Run sends the same lines to Cloud Logging:

```bash
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="bw-scim-sync"' \
  --freshness 1h --limit 100 --format 'value(jsonPayload)'
```

Things skipped on purpose are logged as `WARNING` before the plan. Failures are logged at `ERROR`
severity with the SCIM status code. The full list of entries, in order, is in
[Read the log](ADMIN_GUIDE.md#3-read-the-log).

## 7. Recording results

Copy this table into the ticket or PR for each test round.

| Date | Tester | Bitwarden env (US / EU / self-hosted + version) | GROUP_UPDATE_MODE | Steps passed | Issues |
|---|---|---|---|---|---|
| 2026-10-20 | Bitwarden team (local runs) | US cloud | put | 1 (dry runs only), 11 (Google 404), 14 | Test Workspace has one user, so most steps need more fixtures. Found and fixed: same-named groups were overwritten; PUT ignores `externalId`. No writes yet. |
| 2026-10-22 | Bitwarden team (Cloud Run, test project) | cloud | put | 19 with `DRY_RUN=false` (invite, `Created group` with 2 members), 29 (deleted user revoked) | None. First live writes. |
