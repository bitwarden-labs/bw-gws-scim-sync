# Admin guide

How to run the sync, check what it did, and change its settings once it's set up. To set it up,
follow [README.md](../README.md) first.

**Contents:** [Check that a sync worked](#check-that-a-sync-worked) ·
[Read the sync plan](#read-the-sync-plan) · [Which people are synced](#which-people-are-synced) ·
[Existing members and groups](#existing-members-and-groups) ·
[What users and admins see](#what-users-and-admins-see) · [Everyday tasks](#everyday-tasks) ·
[Settings](#settings) · [Self-hosted Bitwarden](#self-hosted-bitwarden) ·
[Troubleshooting](#troubleshooting)

In the commands below, replace `YOUR_REGION` with the region you chose during setup, for example
`us-central1`, and `YOUR_PROJECT` with your Google Cloud project ID.

**On Windows (PowerShell):** the commands are shown for Cloud Shell. If you set up from PowerShell
([README Step 2](../README.md#on-windows-without-cloud-shell)), run the scripts like this instead;
options such as `--protected-users` work the same, and so do the messages:

| Cloud Shell | Windows PowerShell |
|---|---|
| `bash setup.sh` | `powershell -ExecutionPolicy Bypass -File $HOME\bw-gws-scim-sync\setup.ps1` |
| `bash select-groups.sh` | `powershell -ExecutionPolicy Bypass -File $HOME\bw-gws-scim-sync\select-groups.ps1` |

`gcloud` commands work the same in PowerShell. The few that don't have a Windows version below.

## Check that a sync worked

Use these steps after setup, after changing a setting, or whenever you want to confirm that a change
in Google reached Bitwarden.

### 1. Run the sync

The schedule runs it automatically. To run it now instead of waiting:

- **Console:** **Cloud Run → Jobs**, select **bw-scim-sync**, then select **Execute**.
- **Cloud Shell:**
  ```
  gcloud run jobs execute bw-scim-sync --region YOUR_REGION --wait
  ```

A run normally takes a few seconds.

### 2. Check that the run succeeded

1. In the Google Cloud console, open **Cloud Run → Jobs → bw-scim-sync**.
2. Select the latest execution in the job's list of executions. Its name is `bw-scim-sync-` followed
   by five characters, for example `bw-scim-sync-kz5vr`.
3. Check **Tasks overview**: it should show **1 Succeeded**, **0 Failed**. On the **Tasks** tab,
   task `0` should have **Last exit code** `0`.

If the task failed, the exit code tells you why:

| Exit code | Meaning |
|---|---|
| `0` | The run completed. A dry run also ends with `0`. |
| `1` | Some changes failed in Bitwarden. The others were applied. Look for `ERROR` entries in the log. |
| `2` | The synced groups have no active members, so the run didn't change anything. |
| `3` | More removals were planned than `MAX_REMOVALS` allows, so the run didn't change anything. |

Any other failure, such as a mistyped group, stops the run before it changes anything. The log
shows the error; see [Troubleshooting](#troubleshooting).

### 3. Read the log

On the execution page, select task `0` to open **Task 0 logs** (or open **Cloud Run → Jobs →
bw-scim-sync → Logs** for all runs). Select an entry's arrow to expand it, then expand
**jsonPayload** to see its details. The entries of one run appear in this order:

| Entry | What it tells you |
|---|---|
| `WARNING` entries | Things the sync skipped on purpose, for example a same-named group or a member outside your Workspace. Read these. |
| `Sync plan` | Everything the run decided to do, each with a reason. See [Read the sync plan](#read-the-sync-plan). |
| `DRY_RUN is on: no changes were made` | Only in a dry run. Nothing below this happens. |
| `Invited user`, `Restored user`, `Adopted user` | A person was invited, restored or taken over. `email` shows who. |
| `Created group`, `Updated group`, `Linked group` | A Bitwarden group was created or its members replaced. `group` and `members` show which and how many. |
| `Deleted group` | A Bitwarden group was deleted because its Google group is in `DELETE_GROUPS`. `group` shows which. |
| `Revoked user`, `Removed user` | A person lost access. `email` shows who. |
| `ERROR` entries | A change failed. The entry includes the Bitwarden status code. |
| `Sync finished` | `errors: 0` means every change was applied. |
| `Container called exit(0).` | Cloud Run's own entry: the run ended with exit code 0. |

To read the same entries in Cloud Shell:

```
gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="bw-scim-sync"' \
  --freshness 1h --limit 100 --format 'value(jsonPayload)'
```

On Windows, use the console as above: the quotes in this filter don't survive Windows' command line.

### 4. Check Bitwarden

In the Bitwarden web app, open the **Admin Console** for your organization.

| The log shows | Where to look in Bitwarden | What you see |
|---|---|---|
| `Invited user` | **Members**, **Invited** tab | The person, with status **Invited**, until they accept the email invitation. After they accept, they move to **Needs confirmation** until an admin confirms them. |
| `Restored user` | **Members**, **All** tab | The person is no longer revoked. |
| `Revoked user` | **Members**, **Revoked** tab | The person, with status **Revoked**. They can't use the organization's items until restored. |
| `Removed user` | **Members** | The person is no longer listed. |
| `Created group`, `Updated group` | **Groups** | The group, with the same name as in Google. Open it and check the **Members** tab. |
| `Deleted group` | **Groups** | The group is no longer listed. Its former members are still on **Members**, unless they were also revoked. |

## Read the sync plan

Every run logs a `Sync plan` entry before it changes anything. In a dry run, it's all the run
does. Expand it, then **jsonPayload → plan**:

| Field | Meaning |
|---|---|
| `create_users` | People who get a Bitwarden invitation. |
| `reactivate` | Revoked members who are restored. |
| `revoke` / `delete` | Members who lose access. |
| `adopt_users` | Existing members the sync takes over (only with `ADOPT_USERS`). |
| `groups` | Bitwarden groups that are created or updated, with their member counts. |
| `delete_groups` | Bitwarden groups that are deleted (only with `DELETE_GROUPS`). |
| `warnings` | Things the sync skipped on purpose. Read these. |

Every person and group comes with a **reason**, so you can check each change:

| Reason | Meaning |
|---|---|
| `in Engineering, Finance` | Invited because they're in these synced groups, directly or through a nested group. |
| `back in Engineering` | Restored because they returned to a synced group. |
| `no longer in any synced group` | Revoked because they left every synced group. |
| `suspended or archived in Google` | Revoked because their Google account is suspended or archived. |
| `no longer in this Google Workspace (deleted, or moved out)` | Revoked because their Google account is gone. |
| `matches a Google user by email and ADOPT_USERS allows it` | Adopted (see `ADOPT_USERS`). |
| `no Bitwarden group yet` / `linked to this Google group` | A group is created, or updated because the sync manages it. |
| `removed from GOOGLE_GROUPS and listed in DELETE_GROUPS` | A group is deleted (see [Stop syncing a group](#everyday-tasks)). |
| `same name, taken over through ADOPT_GROUPS` | An existing group with the same name is taken over (see `ADOPT_GROUPS`). |

`select-groups.sh` shows the same plan as one line per change, for example:

```
Planned changes (dry run):
  Invite   ana@acme.com: in Engineering
  Revoke   dan@acme.com: no longer in any synced group
  Group    Engineering: update, 3 member(s); linked to this Google group
```

Before turning off dry run, or after changing the groups, check `revoke` especially.

## Which people are synced

A person gets Bitwarden access when they're a member of at least one group in `GOOGLE_GROUPS`, and:

- they're a **user of your Google Workspace**. Members with outside addresses (for example a
  personal Gmail account added to a group) are skipped, and a warning says how many; and
- their Google account is **active**. Suspended and archived users are skipped, and revoked if they
  were synced before.

### Nested groups

A Google group can contain other groups. The sync looks through every level of nesting and
treats everyone it finds as a member of the group you picked.

For example, you pick `engineering@acme.com`. It has one direct member, Ana, and contains the group
`backend@acme.com`, which has Ben and Cho:

```
engineering@acme.com         picked in GOOGLE_GROUPS
├── Ana
└── backend@acme.com         not picked
    ├── Ben
    └── Cho
```

After a sync, Bitwarden has:

- **One group, `Engineering`, with Ana, Ben and Cho as members.** `backend@acme.com` doesn't get a
  Bitwarden group of its own. If you want one, pick `backend@acme.com` too. Ben and Cho are then
  members of both Bitwarden groups.
- **Ana, Ben and Cho invited** to the organization. The plan's reason for each is `in Engineering`.

When the nesting changes in Google, the next run follows it:

| Change in Google | Result in Bitwarden |
|---|---|
| A new user is added to `backend@` | They're invited and added to `Engineering`. |
| Ben is removed from `backend@` | Ben is removed from `Engineering`. If he isn't in any other synced group, directly or nested, he's also revoked. |
| `backend@` is removed from `engineering@` | Ben and Cho are removed from `Engineering`, and revoked unless they're in another synced group. Check the dry run first: this can revoke many people at once. |
| A group is added inside `backend@` | Its users are added too, however deep the nesting goes. |

`select-groups.sh` shows each group's **direct** member count, as Google reports it: a group inside
counts as one member. In the example it shows `engineering@acme.com` with 2 members, while the plan
shows `Engineering` with 3. Use the dry run to see who's actually included.

## Existing members and groups

The sync is careful with what's already in your organization:

| What's already in Bitwarden | What the sync does |
|---|---|
| A member it invited earlier | Manages it fully: keeps group membership current, revokes and restores it. |
| A member provisioned by Directory Connector from Google Workspace | Manages it fully if Directory Connector stored the Google user ID (a long number) as the member's external ID. Otherwise it's treated like a member provisioned by another tool (below): added to synced groups but never revoked. |
| A member with the same email as a Google user, invited by hand | Adds it to the synced groups but **never revokes it**. To let the sync manage it fully, use `ADOPT_USERS`. |
| A member provisioned by another tool (for example, Directory Connector from LDAP or Entra ID) | If its email matches a Google user in a synced group, adds it to the synced groups. Never revokes or adopts it, even with `ADOPT_USERS`. |
| A member who isn't in any synced group, such as an owner | Leaves it alone. |
| A group the sync created earlier | Keeps its name and membership in step with Google. |
| A group with the same name as a synced Google group, which the sync didn't create | **Skips it** and logs a warning, so its current members aren't replaced. To let the sync take it over, use `ADOPT_GROUPS`. |

## What users and admins see

- **New members get an email invitation** from Bitwarden. Each person accepts it and creates or
  signs in to their account, and then an admin confirms them in the Admin Console. Organizations that
  use SSO with trusted devices or automatic confirmation may skip some of these steps.
- **Groups appear in Bitwarden with the same names as in Google**, except where a same-named group
  already existed (see above). To give a group access to collections, assign the collections to the
  group in the Admin Console. The sync manages group membership only, not collection access.
- **People who leave every synced group, or who are suspended or deleted in Google, are revoked**,
  not deleted. They lose access, but an admin can restore them, and the sync restores them
  automatically if they return to a synced group.
- **Name and email changes in Google aren't sent to Bitwarden.**
- **When you stop syncing a Google group, its Bitwarden group stays, unless you choose to delete
  it.** `select-groups.sh` asks when you untick a group. Kept groups are no longer updated. A deleted
  group loses its collection access; its members stay in the organization, but anyone who is in no
  other synced group is revoked.

## Everyday tasks

**Sync now.** See [Run the sync](#1-run-the-sync).

**Change which groups are synced.** In Cloud Shell (or the terminal you set up from), run
`cd ~/bw-gws-scim-sync && bash select-groups.sh`, change the ticks, save, and accept the dry run it
offers. Read the dry run before the next scheduled run: members who are only in groups you removed
get revoked. If the plan isn't what you want, run `select-groups.sh` again, or pause syncing (below)
while you sort it out.

**Stop syncing a group and delete its Bitwarden group.**
1. Run `cd ~/bw-gws-scim-sync && bash select-groups.sh` and untick the group.
2. Answer **y** to `Also delete the Bitwarden groups of the groups you removed?`
3. Check what it will save (`GOOGLE_GROUPS` without the group, and `DELETE_GROUPS` with it), then
   answer **y**.
4. Accept the dry run. It shows `Delete   group NAME`, and `Revoke` for anyone who was only in that
   group.
5. The next run deletes the group (if `DRY_RUN` is `false`). The log shows `Deleted group`, and the
   group disappears from **Groups** in the Admin Console.

You can untick every group this way. The sync then deletes those groups and revokes every member it
manages, so check the dry run, and raise `MAX_REMOVALS` for that run if needed. Only groups the sync
created (linked to the Google group) are deleted; a group made by hand or by another tool is kept,
with a warning. If you tick a group again later, it's taken out of `DELETE_GROUPS` and recreated.

If you answered **n** and change your mind, delete the group in the Admin Console, or add the Google
group's email to `DELETE_GROUPS` (see [Settings](#settings)).

**Choose protected users or users to adopt.** Run `bash select-groups.sh --protected-users` or
`bash select-groups.sh --adopt-users`. Put your organization owners in the protected list if you
use `ADOPT_USERS`.

**Rotate the SCIM API key**
1. In the Bitwarden Admin Console, go to **Settings → SCIM provisioning** and rotate the key. The
   old key stops working immediately.
2. In Cloud Shell, store the new key. What you type is hidden:
   ```
   read -rs -p "New SCIM API key: " KEY; echo
   printf '%s' "$KEY" | gcloud secrets versions add bw-scim-api-key --data-file=-; unset KEY
   ```
   The next run uses the new key. Running `bash setup.sh` again also works.

   On Windows, run `setup.ps1` again (see the table at the top), press **Enter** at every prompt
   except the key, and type the new key there. It's stored as a new secret version; nothing else
   changes.

**Pause and resume syncing**
```
gcloud scheduler jobs pause bw-scim-sync-schedule --location YOUR_REGION
gcloud scheduler jobs resume bw-scim-sync-schedule --location YOUR_REGION
```

**Change the schedule**
```
gcloud scheduler jobs update http bw-scim-sync-schedule --location YOUR_REGION --schedule "0 */4 * * *"
```
Or run `bash setup.sh` again and change only the schedule.

**Go back to dry-run mode**
```
gcloud run jobs update bw-scim-sync --region YOUR_REGION --update-env-vars DRY_RUN=true
```

**Update to a new version.** Run the installer again with the new version number, for example
`v1.1.0`:
```
bash <(curl -fsSL https://raw.githubusercontent.com/bitwarden-labs/bw-gws-scim-sync/v1.1.0/install.sh)
```
It replaces the files in `~/bw-gws-scim-sync` and runs `setup.sh`, which deploys the new version.
Press **Enter** at each prompt to keep your values. Your settings, including `DRY_RUN`, are kept.
If you installed from the zip instead, upload and unzip the new version, then run `bash setup.sh`
from its folder.

On Windows (PowerShell), run the Windows installer with the new version number:
```powershell
irm https://raw.githubusercontent.com/bitwarden-labs/bw-gws-scim-sync/v1.1.0/install.ps1 | iex
```

**Remove the sync completely**
```
gcloud scheduler jobs delete bw-scim-sync-schedule --location YOUR_REGION
gcloud run jobs delete bw-scim-sync --region YOUR_REGION
gcloud secrets delete bw-scim-api-key
gcloud iam service-accounts delete bw-scim-sync@YOUR_PROJECT.iam.gserviceaccount.com
```
Then delete the Client ID entry from domain-wide delegation in the Google Admin console, and turn
off SCIM in Bitwarden if you no longer use it. Container images remain in Artifact Registry under
`cloud-run-source-deploy`; delete them there if you want. Members and groups already in Bitwarden
stay as they are.

## Settings

Change a setting with:

```
gcloud run jobs update bw-scim-sync --region YOUR_REGION --update-env-vars NAME=value
```

For settings that hold a list, start the value with `^;^`. This tells `gcloud` to separate
settings with `;` instead of commas, so the commas in your list are kept:

```
gcloud run jobs update bw-scim-sync --region YOUR_REGION \
  --update-env-vars "^;^GOOGLE_GROUPS=engineering@acme.com,finance@acme.com"
```

On Windows, `^` is a special character on the command line and can get lost. Put the setting in a
small file instead and pass it with `--flags-file`:

```powershell
'{"--update-env-vars": {"GOOGLE_GROUPS": "engineering@acme.com,finance@acme.com"}}' | Set-Content flags.json
gcloud run jobs update bw-scim-sync --region YOUR_REGION --flags-file flags.json
```

You can also change settings in the Google Cloud console: **Cloud Run → Jobs → bw-scim-sync → Edit
→ Variables & Secrets**. Changes apply from the next run.

For the three list settings, `select-groups.sh` lets you pick from your directory instead of typing
(see [README Step 4](../README.md#step-4-choose-the-groups-to-sync)):

| Setting | Command |
|---|---|
| `GOOGLE_GROUPS` | `bash select-groups.sh` |
| `PROTECTED_EMAILS` | `bash select-groups.sh --protected-users` |
| `ADOPT_USERS` | `bash select-groups.sh --adopt-users` |

| Setting | Default | Meaning |
|---|---|---|
| `GOOGLE_GROUPS` | (none) | Comma-separated Google groups whose members get Bitwarden access, including members of groups nested inside them (see [Nested groups](#nested-groups)). Required, unless `DELETE_GROUPS` is set while you remove the last groups; set it with `select-groups.sh` or during setup. |
| `DELETE_GROUPS` | (empty) | Comma-separated Google group emails whose Bitwarden group the sync deletes, if the sync created it. Groups also in `GOOGLE_GROUPS` are never deleted. `select-groups.sh` sets it when you untick a group and choose to delete it. Entries can stay after the group is gone: they then do nothing. |
| `DRY_RUN` | `true` | When `true`, the job only logs what it would do. |
| `REMOVAL_ACTION` | `revoke` | What happens to members who leave: `revoke`, `delete` (remove from the organization), or `none`. |
| `MAX_REMOVALS` | `10` | If a run would remove more members than this, it stops without changing anything. This protects against mistakes such as a mistyped group. Raise it for a planned bulk change. |
| `PROTECTED_EMAILS` | (empty) | Comma-separated emails the sync never revokes, deletes or adopts. **Add your organization owners here if you turn on `ADOPT_USERS`**, because the sync can't see member roles. |
| `ADOPT_USERS` | `false` | Lets the sync take over members who match a Google user by email and weren't provisioned by any tool (for example, invited by hand). `true` adopts all of them; a comma-separated list adopts only those emails. From then on, adopted members are revoked and restored like members the sync invited. |
| `ADOPT_GROUPS` | (empty) | Comma-separated Google group emails whose same-named Bitwarden group the sync may take over. Its current members are replaced with the Google group's members. |
| `GROUP_UPDATE_MODE` | `put` | How group updates are sent to Bitwarden: `put` or `patch`. Both replace the group's full member list. Leave the default unless Bitwarden support advises otherwise. |

Set by setup, and normally never changed: `BW_SCIM_URL`, `GOOGLE_ADMIN_EMAIL`, `GOOGLE_SA_EMAIL`,
and the `BW_SCIM_API_KEY` secret reference.

To see the current settings: **Cloud Run → Jobs → bw-scim-sync → Configuration**, or
`gcloud run jobs describe bw-scim-sync --region YOUR_REGION`.

## Self-hosted Bitwarden

SCIM must be enabled on your server (`enable_scim: true` in `config.yml`, then rebuild). The SCIM
URL must also be reachable from Google Cloud, either through your reverse proxy or a private
connection such as a VPN. If you can't expose it, you can run the same container on your own
infrastructure on a schedule, with the same environment variables. Ask Bitwarden support for help
with that setup.

## Troubleshooting

Find the error in the run's log (see [Read the log](#3-read-the-log)).

| Message | Fix |
|---|---|
| `unauthorized_client` or `Client is unauthorized` | README Step 3 is missing or not active yet. Check the Client ID and that all three scopes are listed, then wait a few minutes. |
| `Google Directory API /groups/... failed: 404` | A group in `GOOGLE_GROUPS` doesn't exist. Check the spelling, and use the group's email address, not its name. |
| `Google Directory API ... 403` | The admin email isn't a Google Workspace admin, or it's in a different Workspace from the groups. |
| `Error calling the IAM signBlob API ... 403` | The service account can't sign its own tokens. Run `bash setup.sh` again. If you just ran it, wait a few minutes: new permissions take time to apply. |
| `SCIM request failed: 401` | The SCIM API key is wrong or was rotated. See **Rotate the SCIM API key** under [Everyday tasks](#everyday-tasks). |
| `GOOGLE_GROUPS must list at least one Google group email` | No groups are chosen yet. Run `bash select-groups.sh` (README Step 4). |
| `select-groups.sh`: `Couldn't find the bw-scim-sync job in project ...` | Check the project you confirmed. If you never ran `setup.sh` (or the manual setup), do README Step 2 first. If you set `REGION` yourself, check it. |
| The installer says `Couldn't download bitwarden-labs/bw-gws-scim-sync` | Check the version in the command exists. If the repository isn't public, run `gh auth login` and try again, or use the zip (README Step 2, **Other ways to get the tool**). |
| The installer says `... exists and isn't a copy of this tool` | Another folder is already at `~/bw-gws-scim-sync`. Move it, or install elsewhere with `BW_SYNC_DIR=~/other-folder` before `bash <(curl ...)`. |
| `select-groups.sh`: `Google rejected the directory access` | README Step 3 is missing or not active yet. Wait a few minutes and run it again. |
| `select-groups.sh`: `Waiting for permission to sign as the service account` | Normal the first time: the script just gave your account access, which takes a minute or two to apply. |
| `Synced groups have no active members` (exit code 2) | The groups are empty, or contain only suspended or outside users. Check `GOOGLE_GROUPS`. |
| `Planned removals exceed MAX_REMOVALS` (exit code 3) | Read the plan in the log. If the removals are intended, raise `MAX_REMOVALS` for one run, then set it back. |
| `Bitwarden already has a group named ...` | A same-named group existed before the sync. See [Existing members and groups](#existing-members-and-groups). |
| `skipped N member(s) that are suspended or not users of this Workspace` | Expected for suspended users and outside addresses, including those in nested groups. No action needed. |
| `... is in DELETE_GROUPS, but the Bitwarden group "..." isn't linked to it` | The same-named Bitwarden group wasn't created by the sync, so it isn't deleted. Delete it in the Admin Console if you no longer need it, then remove the email from `DELETE_GROUPS`. |
| `... is in DELETE_GROUPS but no longer exists in Google Workspace` | The Google group was deleted before the sync could find its Bitwarden group. Delete the Bitwarden group in the Admin Console if it's still there, then remove the email from `DELETE_GROUPS`. |
| `exists in Bitwarden but is revoked and was not provisioned by this sync` | A hand-invited member was revoked by an admin. Restore them in the Admin Console, or use `ADOPT_USERS`. |
| A person you expected isn't in the plan | Check that they're an active user of your Workspace, and that they're in a synced group or a group nested inside one. The picker's member counts only include direct members. |
| `setup.sh` or `select-groups.sh`: `The gcloud sign-in for ... has expired` | Google asks you to sign in again from time to time. Run `gcloud auth login`, then run the script again. |
| `select-groups.sh`: `Application Default Credentials are missing or expired` | Only outside Cloud Shell. Run `gcloud auth application-default login`, then run the script again. (`select-groups.ps1` doesn't need this sign-in.) |
| Windows: `... cannot be loaded because running scripts is disabled on this system` | Start the script with `powershell -ExecutionPolicy Bypass -File ...` (see the table at the top). That allows it for this run only. |
| Windows installer: `The Google Cloud CLI (gcloud) is missing` | Install the [Google Cloud CLI for Windows](https://cloud.google.com/sdk/docs/install#windows), open a new PowerShell window, and run the installer again. |
| Windows installer: `Version ... has no PowerShell scripts` | The version in the command is older than v1.1.0. Use v1.1.0 or later. |
| `select-groups.ps1`: `The dry run stopped with an error` | The Cloud Run run behind the dry run failed. The lines above it show why; the full log is in **Cloud Run → Jobs → bw-scim-sync → Logs**. |
| Setup stops with `has no billing account linked` | Link a billing account to the project, then run the script again. |
| The build or deploy fails with a Cloud Build permission error | Your organization restricts the default build account. Ask your Google Cloud admin to grant **Cloud Run Builder** (`roles/run.builder`) to `PROJECT_NUMBER-compute@developer.gserviceaccount.com`, then run the script again. See [MANUAL_SETUP.md](MANUAL_SETUP.md#5-build-and-deploy-the-job). |
