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
gcloud config set project "$PROJECT_ID" --quiet >/dev/null 2>&1
ask REGION "Region" "europe-west1"

# On a rerun, read what's deployed so its current values become the defaults (Enter keeps them).
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
EXISTING_JOB=false
if gcloud run jobs describe "$JOB" --region "$REGION" --format json > "$WORK/job.json" 2>/dev/null; then
  EXISTING_JOB=true
  python3 - "$WORK/job.json" > "$WORK/current.sh" <<'PY'
import json, shlex, sys
job = json.load(open(sys.argv[1]))
env = {e["name"]: e["value"] for e in job["spec"]["template"]["spec"]["template"]["spec"]["containers"][0].get("env", []) if "value" in e}
for name in ("BW_SCIM_URL", "GOOGLE_ADMIN_EMAIL", "GOOGLE_GROUPS"):
    print(f"CURRENT_{name}={shlex.quote(env.get(name, ''))}")
PY
  # shellcheck disable=SC1091
  source "$WORK/current.sh"
  IFS=$'\t' read -r CURRENT_SCHEDULE CURRENT_TIME_ZONE < <(gcloud scheduler jobs describe "$SCHEDULER_JOB" \
    --location "$REGION" --format 'value(schedule,timeZone)' 2>/dev/null || true) || true
  echo "Found the deployed $JOB job. Its current values are shown in [brackets]; press Enter to keep them."
fi
SECRET_EXISTS=false
gcloud secrets describe "$SECRET" >/dev/null 2>&1 && SECRET_EXISTS=true

ask BW_SCIM_URL "Bitwarden SCIM URL (from Admin Console > Settings > SCIM provisioning)" "${CURRENT_BW_SCIM_URL:-}"
if [[ -z "${BW_SCIM_API_KEY:-}" ]]; then
  if [[ "$SECRET_EXISTS" == true ]]; then
    read -r -s -p "Bitwarden SCIM API key (input hidden; press Enter to keep the stored key): " BW_SCIM_API_KEY; echo
  else
    read -r -s -p "Bitwarden SCIM API key (input hidden): " BW_SCIM_API_KEY; echo
    [[ -n "$BW_SCIM_API_KEY" ]] || { echo "A value is required."; exit 1; }
  fi
fi
ask GOOGLE_ADMIN_EMAIL "Google Workspace admin email the sync reads the directory as" "${CURRENT_GOOGLE_ADMIN_EMAIL:-}"
if [[ -z "${GOOGLE_GROUPS+set}" ]]; then  # Optional: groups can be picked later with select-groups.sh.
  if [[ -n "${CURRENT_GOOGLE_GROUPS:-}" ]]; then
    read -r -p "Google group email(s) to sync, comma-separated [$CURRENT_GOOGLE_GROUPS]: " GOOGLE_GROUPS
    GOOGLE_GROUPS=${GOOGLE_GROUPS:-$CURRENT_GOOGLE_GROUPS}
  else
    read -r -p "Google group email(s) to sync, comma-separated (or press Enter to pick them from your directory after Step 3): " GOOGLE_GROUPS
  fi
fi
ask SCHEDULE "Sync schedule (cron)" "${CURRENT_SCHEDULE:-0 * * * *}"
ask TIME_ZONE "Schedule time zone" "${CURRENT_TIME_ZONE:-Etc/UTC}"

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
if [[ -n "$BW_SCIM_API_KEY" ]]; then
  printf '%s' "$BW_SCIM_API_KEY" | gcloud secrets versions add "$SECRET" --data-file=- >/dev/null
else
  echo "    Keeping the stored key."
fi
retry_iam "let the service account read the secret" \
  gcloud secrets add-iam-policy-binding "$SECRET" \
  --member "serviceAccount:$SA_EMAIL" --role roles/secretmanager.secretAccessor

# Only the values asked above are updated, so a rerun (new key, new version) keeps settings changed
# later, such as DRY_RUN=false or PROTECTED_EMAILS. "^;^" makes ";" the separator, because the
# values contain "," "@" and ":".
for value in "$BW_SCIM_URL" "$GOOGLE_ADMIN_EMAIL" "$GOOGLE_GROUPS"; do
  [[ "$value" != *";"* ]] || { echo "Values can't contain ';': $value"; exit 1; }
done
ENV_VARS="^;^BW_SCIM_URL=$BW_SCIM_URL;GOOGLE_ADMIN_EMAIL=$GOOGLE_ADMIN_EMAIL;GOOGLE_SA_EMAIL=$SA_EMAIL"
[[ -z "$GOOGLE_GROUPS" ]] || ENV_VARS="$ENV_VARS;GOOGLE_GROUPS=$GOOGLE_GROUPS"
if [[ "$EXISTING_JOB" == true ]]; then
  echo "==> Building and updating the Cloud Run job (your other settings, including DRY_RUN, are kept)"
else
  echo "==> Building and deploying the Cloud Run job (DRY_RUN=true: nothing changes yet)"
  ENV_VARS="$ENV_VARS;DRY_RUN=true"
fi
gcloud run jobs deploy "$JOB" --source . --region "$REGION" \
  --service-account "$SA_EMAIL" \
  --set-secrets "BW_SCIM_API_KEY=$SECRET:latest" \
  --update-env-vars "$ENV_VARS" \
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

Done. Next steps (README Steps 3-6):

3. In the Google Admin console, open Security > Access and data control > API controls >
   Manage domain-wide delegation (https://admin.google.com/ac/owl/domainwidedelegation),
   select Add new, and enter:
     Client ID:    $CLIENT_ID
     OAuth scopes: https://www.googleapis.com/auth/admin.directory.user.readonly,https://www.googleapis.com/auth/admin.directory.group.readonly,https://www.googleapis.com/auth/admin.directory.group.member.readonly

4. Choose the Google groups to sync from your directory, and run a dry run (Step 5):
     bash select-groups.sh

6. When the dry-run plan looks right, turn on real syncing:
     gcloud run jobs update $JOB --region $REGION --update-env-vars DRY_RUN=false
MSG
