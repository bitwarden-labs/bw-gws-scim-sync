#!/usr/bin/env bash
# Deploys the Google Workspace -> Bitwarden SCIM sync as a scheduled Cloud Run job.
# Run from Google Cloud Shell inside this folder:  bash setup.sh
# Safe to re-run: it updates existing resources instead of failing.
set -euo pipefail

JOB=bw-scim-sync
SA_NAME=bw-scim-sync
SECRET=bw-scim-api-key
SCHEDULER_JOB=bw-scim-sync-schedule

ask() {  # ask VAR "Prompt" [default]
  local var=$1 prompt=$2 default=${3:-} value
  if [[ -n "${!var:-}" ]]; then return; fi
  read -r -p "$prompt${default:+ [$default]}: " value
  printf -v "$var" '%s' "${value:-$default}"
  [[ -n "${!var}" ]] || { echo "A value is required."; exit 1; }
}

ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
[[ -n "$ACCOUNT" ]] || { echo "No gcloud account is signed in. Run: gcloud auth login"; exit 1; }
echo "Signed in to gcloud as: $ACCOUNT"
if [[ -z "${PROJECT_ID:-}" ]]; then
  ask PROJECT_ID "Google Cloud project ID" "$(gcloud config get-value project 2>/dev/null || true)"
fi
if ! gcloud projects describe "$PROJECT_ID" --format 'value(projectId)' >/dev/null 2>&1; then
  cat >&2 <<MSG
$ACCOUNT can't access project "$PROJECT_ID" (or it doesn't exist).
  - List the projects this account can use:   gcloud projects list
  - Or switch to another account:              gcloud config set account OTHER_ACCOUNT
  - Or create a new project for the sync:      gcloud projects create PROJECT_ID
    (then link billing in the console: Billing > Account management > Link a project)
MSG
  exit 1
fi
ask REGION "Region" "europe-west1"
ask BW_SCIM_URL "Bitwarden SCIM URL (from Admin Console > Settings > SCIM provisioning)"
if [[ -z "${BW_SCIM_API_KEY:-}" ]]; then
  read -r -s -p "Bitwarden SCIM API key (input hidden): " BW_SCIM_API_KEY; echo
fi
ask GOOGLE_ADMIN_EMAIL "Google Workspace admin email the sync reads the directory as"
ask GOOGLE_GROUPS "Google group email(s) to sync, comma-separated"
ask SCHEDULE "Sync schedule (cron)" "0 * * * *"
ask TIME_ZONE "Schedule time zone" "Etc/UTC"

retry_iam() {  # retry_iam <description> <command...>  (new service accounts take a while to propagate)
  local what=$1; shift
  for attempt in 1 2 3 4 5 6; do
    if "$@" >/dev/null 2>/tmp/bw-scim-iam.err; then return 0; fi
    if ! grep -qE "PERMISSION_DENIED|NOT_FOUND|does not exist" /tmp/bw-scim-iam.err; then break; fi
    echo "    $what not ready yet (attempt $attempt/6), waiting 15s..."
    sleep 15
  done
  cat /tmp/bw-scim-iam.err >&2
  cat >&2 <<MSG

Could not $what. If the service account exists in the console, your account lacks permission
to change IAM policy. Ask a project owner to grant you roles/iam.serviceAccountAdmin and
roles/secretmanager.admin on project $PROJECT_ID (or roles/owner on a test project), then rerun.
MSG
  exit 1
}

gcloud config set project "$PROJECT_ID" --quiet >/dev/null 2>&1
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

BILLING=$(gcloud billing projects describe "$PROJECT_ID" --format 'value(billingEnabled)' 2>/dev/null || true)
if [[ "$BILLING" == "False" ]]; then
  cat >&2 <<MSG
Project "$PROJECT_ID" has no billing account linked. Cloud Run, Cloud Build and Cloud Scheduler need one.
  1. List the billing accounts you can use:  gcloud billing accounts list
  2. Link one:  gcloud billing projects link $PROJECT_ID --billing-account XXXXXX-XXXXXX-XXXXXX
  If the list is empty, ask a billing admin to link the project (or grant you Billing Account User).
Then rerun this script.
MSG
  exit 1
fi

echo "==> Enabling APIs (this can take a minute)"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
  cloudscheduler.googleapis.com secretmanager.googleapis.com iamcredentials.googleapis.com \
  admin.googleapis.com

echo "==> Service account"
gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$SA_NAME" --display-name "Bitwarden SCIM sync"
# Lets the job sign its own domain-wide-delegation token, so no key file is ever created.
retry_iam "grant the service account permission to sign its own tokens" \
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member "serviceAccount:$SA_EMAIL" --role roles/iam.serviceAccountTokenCreator

echo "==> Storing the SCIM API key in Secret Manager"
gcloud secrets describe "$SECRET" >/dev/null 2>&1 || \
  gcloud secrets create "$SECRET" --replication-policy automatic >/dev/null
printf '%s' "$BW_SCIM_API_KEY" | gcloud secrets versions add "$SECRET" --data-file=- >/dev/null
retry_iam "let the service account read the secret" \
  gcloud secrets add-iam-policy-binding "$SECRET" \
  --member "serviceAccount:$SA_EMAIL" --role roles/secretmanager.secretAccessor

echo "==> Building and deploying the Cloud Run job (DRY_RUN=true: nothing changes yet)"
# Env vars go through a YAML file: values contain "@", "," and ":" which break --set-env-vars parsing.
yaml_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
ENV_FILE=$(mktemp)
trap 'rm -f "$ENV_FILE"' EXIT
{
  echo "BW_SCIM_URL: $(yaml_quote "$BW_SCIM_URL")"
  echo "GOOGLE_ADMIN_EMAIL: $(yaml_quote "$GOOGLE_ADMIN_EMAIL")"
  echo "GOOGLE_SA_EMAIL: $(yaml_quote "$SA_EMAIL")"
  echo "GOOGLE_GROUPS: $(yaml_quote "$GOOGLE_GROUPS")"
  echo "DRY_RUN: 'true'"
} > "$ENV_FILE"
gcloud run jobs deploy "$JOB" --source . --region "$REGION" \
  --service-account "$SA_EMAIL" \
  --set-secrets "BW_SCIM_API_KEY=$SECRET:latest" \
  --env-vars-file "$ENV_FILE" \
  --max-retries 0 --task-timeout 30m

echo "==> Schedule"
gcloud run jobs add-iam-policy-binding "$JOB" --region "$REGION" \
  --member "serviceAccount:$SA_EMAIL" --role roles/run.invoker >/dev/null
RUN_URI="https://run.googleapis.com/v2/projects/$PROJECT_ID/locations/$REGION/jobs/$JOB:run"
if gcloud scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "$SCHEDULER_JOB" --location "$REGION" \
    --schedule "$SCHEDULE" --time-zone "$TIME_ZONE" --uri "$RUN_URI" --http-method POST \
    --oauth-service-account-email "$SA_EMAIL" >/dev/null
else
  gcloud scheduler jobs create http "$SCHEDULER_JOB" --location "$REGION" \
    --schedule "$SCHEDULE" --time-zone "$TIME_ZONE" --uri "$RUN_URI" --http-method POST \
    --oauth-service-account-email "$SA_EMAIL" >/dev/null
fi

CLIENT_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" --format 'value(oauth2ClientId)')
cat <<MSG

Done. One manual step remains in the Google Admin console (admin.google.com):
  Security > Access and data control > API controls > Manage domain-wide delegation > Add new

  Client ID:    $CLIENT_ID
  OAuth scopes: https://www.googleapis.com/auth/admin.directory.user.readonly,https://www.googleapis.com/auth/admin.directory.group.readonly,https://www.googleapis.com/auth/admin.directory.group.member.readonly

Then run a test (dry run, nothing changes in Bitwarden):
  gcloud run jobs execute $JOB --region $REGION --wait

Review the planned changes in the logs, then turn on real syncing:
  gcloud run jobs update $JOB --region $REGION --update-env-vars DRY_RUN=false
MSG
