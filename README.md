# Sync Google Workspace users and groups to Bitwarden (SCIM)

This tool keeps your Bitwarden organization in step with Google Workspace. On a schedule, it reads
the Google groups you choose and uses Bitwarden's SCIM endpoint to:

- invite new group members to your Bitwarden organization,
- revoke members who leave those groups or are suspended or deleted in Google,
- restore members who return, and
- create a matching Bitwarden group for each Google group and keep its membership current. Members of nested groups are included.

It runs in your own Google Cloud project as a small scheduled job. You don't need a server.
Setup takes about 15 minutes.

## Before you start

You need:

- A Bitwarden organization on a plan that includes SCIM, and Owner or Admin access to it.
- A Google Workspace super admin account, for one step in the Admin console.
- A Google Cloud project with billing enabled. The job uses a few seconds of compute per run, which
  normally fits inside the free tier.
- The emails of the Google groups whose members should get Bitwarden access.

Use only one sync tool per Bitwarden organization. If you already use Bitwarden Directory Connector
or another SCIM integration for this organization, turn it off first.

## Step 1: Enable SCIM in Bitwarden

1. In the Bitwarden web app, open the **Admin Console** for your organization.
2. Go to **Settings → SCIM provisioning**.
3. Turn on **Enable SCIM** and save.
4. Copy the **SCIM URL** and **SCIM API key**. You'll paste them in Step 2.

Treat the API key like a password. Anyone who has it can add and remove members of your organization.

## Step 2: Run the setup script in Google Cloud Shell

1. Open [Google Cloud Shell](https://shell.cloud.google.com) and select your project.
2. Upload this folder as a `.zip` using the **⋮ → Upload** menu, then unzip it and enter the folder:
   ```
   unzip bw-gws-scim-sync.zip && cd bw-gws-scim-sync
   ```
3. Run:
   ```
   bash setup.sh
   ```
4. Answer the prompts:

| Prompt | What to enter |
|---|---|
| Google Cloud project ID | Your project. It is usually filled in for you. |
| Region | Where the job runs, for example `europe-west1` or `us-central1`. |
| Bitwarden SCIM URL | The URL from Step 1. |
| Bitwarden SCIM API key | The key from Step 1. Your typing is hidden. |
| Google Workspace admin email | An admin account the sync reads your directory as. Its access is read-only. |
| Google group email(s) | For example `engineering@acme.com,finance@acme.com`. |
| Schedule | How often to sync. The default `0 * * * *` runs hourly. |

The script enables the Google Cloud services the job needs and creates a dedicated service account.
It stores the SCIM key in Secret Manager, then deploys the job and its schedule. **The job starts in
dry-run mode, so it doesn't change anything in Bitwarden yet.**

When the script finishes, it prints a **Client ID** and a list of **OAuth scopes**. Keep them for Step 3.

## Step 3: Allow the sync to read your directory

1. Sign in to the [Google Admin console](https://admin.google.com) as a super admin.
2. Go to **Security → Access and data control → API controls → Manage domain-wide delegation**.
3. Click **Add new**, paste the **Client ID** and **OAuth scopes** that the script printed, and click **Authorize**.

The scopes are read-only. The sync can't change anything in Google Workspace.

## Step 4: Test with a dry run

In Cloud Shell, run:

```
gcloud run jobs execute bw-scim-sync --region YOUR_REGION --wait
```

To see the result, open **Cloud Run → Jobs → bw-scim-sync → Logs** in the Google Cloud console.
Look for the **Sync plan** entry. It lists every user who would be invited, restored or revoked, and every group that would be created or updated. If the delegation change from Step 3 hasn't taken
effect yet, wait a few minutes and run the job again.

## Step 5: Turn on syncing

When the plan looks right, run:

```
gcloud run jobs update bw-scim-sync --region YOUR_REGION --update-env-vars DRY_RUN=false
```

From now on, the schedule applies changes automatically. You can also start a sync immediately with the
`execute` command from Step 4.

## What your users and admins will see

- **New members get an email invitation** from Bitwarden. Each person accepts the invitation and creates or signs in to their
  account, and then an admin confirms them in the Admin Console. Organizations that use SSO with
  trusted devices or automatic confirmation may skip some of these steps.
- **Groups appear in Bitwarden with the same names as in Google.** To give a group access to collections,
  assign the collections to the group in the Admin Console. The sync manages group membership only, not
  collection access.
- **People who leave a synced group, or who are suspended in Google, are revoked**, not deleted.
  Revoked members lose access, but an admin can restore them. A member who returns to a synced group is
  restored automatically.
- **Members you invited manually are never revoked by the sync.** This includes the organization's owners.
  The sync changes only members that it or Directory Connector provisioned from Google.

## Settings

To change a setting later, run:
`gcloud run jobs update bw-scim-sync --region YOUR_REGION --update-env-vars NAME=value`.
Group lists contain commas, so set them with a different delimiter:
`--update-env-vars "^@^GOOGLE_GROUPS=a@acme.com,b@acme.com"`.

| Setting | Default | Meaning |
|---|---|---|
| `GOOGLE_GROUPS` | (set at setup) | Google groups whose members get Bitwarden access. |
| `DRY_RUN` | `true` | When `true`, the job only logs what it would do. |
| `REMOVAL_ACTION` | `revoke` | `revoke`, `delete` (remove from the organization), or `none`. |
| `PROTECTED_EMAILS` | (empty) | Comma-separated emails that are never removed. |
| `ADOPT_GROUPS` | (empty) | Comma-separated Google group emails whose same-named Bitwarden group the sync may take over. By default, a Bitwarden group with the same name that the sync didn't create is skipped with a warning, because taking it over replaces its members. |
| `ADOPT_USERS` | `false` | Lets the sync take over existing Bitwarden members that match a Google user by email and have no externalId (for example, manually invited members). `true` adopts all of them; a comma-separated list adopts only those emails. Adopted members are linked to their Google user and from then on are revoked and restored like members the sync invited. Members in `PROTECTED_EMAILS` are never adopted. |
| `GROUP_UPDATE_MODE` | `put` | How group membership is updated: `put` replaces the whole group each run; `patch` sends only the changes. Leave the default unless Bitwarden support advises otherwise. |
| `MAX_REMOVALS` | `10` | If a run would remove more members than this, it stops without changing anything. This protects against mistakes such as a mistyped group name. Raise it for a planned bulk change. |

To pause syncing, run `gcloud scheduler jobs pause bw-scim-sync-schedule --location YOUR_REGION`.

## Self-hosted Bitwarden

SCIM must be enabled on your server (`enable_scim: true` in `config.yml`, then rebuild). The SCIM URL must also
be reachable from Google Cloud, either through your reverse proxy or a private connection such as a VPN.
If you can't expose it, you can run the same container on your own infrastructure on a schedule, with
the same environment variables. Ask Bitwarden support for help with that setup.

## Troubleshooting

| Log message | Fix |
|---|---|
| `unauthorized_client` or `Client is unauthorized` | Step 3 is missing or not active yet. Check the Client ID and scopes, then wait 10–15 minutes. |
| `Google Directory API ... 403` | The admin email isn't a Google Workspace admin, or the Admin SDK API is disabled. |
| `SCIM request failed: 401` | The SCIM API key is wrong or was rotated. Rerun `bash setup.sh` to store the new key. |
| `Planned removals exceed MAX_REMOVALS` | Read the plan in the log. If the removals are intended, raise `MAX_REMOVALS` for one run. |
| `Synced groups have no active members` | Check the spelling of the group emails in `GOOGLE_GROUPS`. |
| The deploy step fails with a Cloud Build permission error | Your organization may restrict the default build account. Ask your Google Cloud admin to allow Cloud Build in this project. |
