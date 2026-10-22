#!/usr/bin/env bash
# Choose from your Google Workspace directory instead of typing emails, and save the choice on the
# deployed job. Run inside this folder (~/bw-gws-scim-sync with the installer), after README Steps 2-3:
#   bash select-groups.sh                     Google groups to sync (GOOGLE_GROUPS)
#   bash select-groups.sh --protected-users   users never revoked, deleted or adopted (PROTECTED_EMAILS)
#   bash select-groups.sh --adopt-users       existing members the sync may adopt (ADOPT_USERS)
set -euo pipefail

JOB=bw-scim-sync
SECRET=bw-scim-api-key
VAR=GOOGLE_GROUPS KIND=groups TITLE="Google groups to sync"
case "${1:-}" in
  ""|--groups) ;;
  --protected-users) VAR=PROTECTED_EMAILS KIND=users TITLE="Users the sync must never revoke, delete or adopt" ;;
  --adopt-users) VAR=ADOPT_USERS KIND=users TITLE="Existing Bitwarden members the sync may adopt" ;;
  *) echo "Usage: bash select-groups.sh [--groups | --protected-users | --adopt-users]" >&2; exit 1 ;;
esac

ask() {  # ask VAR "Prompt" [default]
  local var=$1 prompt=$2 default=${3:-} value
  if [[ -n "${!var:-}" ]]; then return; fi
  read -r -p "$prompt${default:+ [$default]}: " value
  printf -v "$var" '%s' "${value:-$default}"
  [[ -n "${!var}" ]] || { echo "A value is required."; exit 1; }
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
list_op() {  # list_op minus|plus "a,b" "c,d": comma-separated email lists, compared case-insensitively
  python3 -c 'import sys
op, a, b = sys.argv[1:4]
split = lambda s: list(dict.fromkeys(e.strip().lower() for e in s.split(",") if e.strip()))
a, b = split(a), split(b)
print(",".join([e for e in a if e not in b] if op == "minus" else a + [e for e in b if e not in a]))' "$@"
}

ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
[[ -n "$ACCOUNT" ]] || { echo "No gcloud account is signed in. Run: gcloud auth login"; exit 1; }
ask PROJECT_ID "Google Cloud project ID" "$(gcloud config get-value project 2>/dev/null || true)"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null 2>&1
if [[ -z "${REGION:-}" ]]; then
  # Find the job's region, so it doesn't need typing.
  REGIONS=()
  while IFS= read -r r; do [[ -n "$r" ]] && REGIONS+=("$r"); done < <(gcloud run jobs list \
    --filter "metadata.name=$JOB" --format 'value(region)' 2>/dev/null || true)
  if (( ${#REGIONS[@]} == 1 )); then
    REGION=${REGIONS[0]}
    echo "Found the $JOB job in $REGION."
  elif (( ${#REGIONS[@]} > 1 )); then
    echo "The $JOB job exists in more than one region:"
    for i in "${!REGIONS[@]}"; do echo "  $((i + 1))) ${REGIONS[$i]}"; done
    read -r -p "Number of the region to use [1]: " choice
    choice=${choice:-1}
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#REGIONS[@]} )); then
      echo "Choose a number from the list." >&2
      exit 1
    fi
    REGION=${REGIONS[$((choice - 1))]}
  else
    echo "Couldn't find the $JOB job in project $PROJECT_ID. Check the project, or run setup.sh first (README Step 2)." >&2
    exit 1
  fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if ! gcloud run jobs describe "$JOB" --region "$REGION" --format json > "$WORK/job.json" 2>"$WORK/err"; then
  cat "$WORK/err" >&2
  echo "Couldn't find the $JOB job in $REGION. Check the region, or run setup.sh first (README Step 2)." >&2
  exit 1
fi
# The job's plain environment variables, as shell assignments (the secret is read separately).
python3 - "$WORK/job.json" > "$WORK/env.sh" <<'PY'
import json, shlex, sys
job = json.load(open(sys.argv[1]))
for e in job["spec"]["template"]["spec"]["template"]["spec"]["containers"][0].get("env", []):
    if "value" in e:
        print(f"export {e['name']}={shlex.quote(e['value'])}")
PY
# shellcheck disable=SC1091
source "$WORK/env.sh"
SA_EMAIL=${GOOGLE_SA_EMAIL:?The job has no GOOGLE_SA_EMAIL; run setup.sh again}
: "${GOOGLE_ADMIN_EMAIL:?The job has no GOOGLE_ADMIN_EMAIL; run setup.sh again}"
CURRENT=${!VAR:-}
if [[ "$VAR" == ADOPT_USERS && "$(lower "$CURRENT")" =~ ^(true|1|yes|on|false|0|no|off)$ ]]; then
  echo "ADOPT_USERS is currently '$CURRENT'. Saving a selection replaces it with a list of emails."
  CURRENT=""
fi

# Lets you read the directory with the sync's read-only access (keyless, as the job does).
MEMBER="user:$ACCOUNT"
[[ "$ACCOUNT" == *.gserviceaccount.com ]] && MEMBER="serviceAccount:$ACCOUNT"
if ! gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --member "$MEMBER" \
  --role roles/iam.serviceAccountTokenCreator >/dev/null 2>"$WORK/err"; then
  cat "$WORK/err" >&2
  exit 1
fi

if [[ ! -x .venv/bin/python ]]; then
  echo "Installing the tool's Python dependencies (first run only)..."
  python3 -m venv .venv
fi
.venv/bin/pip install -q --disable-pip-version-check -r requirements.txt

status=0
.venv/bin/python -m src.picker "$KIND" --current "$CURRENT" --title "$TITLE" --output "$WORK/chosen" || status=$?
case $status in
  0) ;;
  3|4) exit 0 ;;  # Nothing changed, or cancelled: the picker already said so.
  *) exit "$status" ;;
esac
CHOSEN=$(cat "$WORK/chosen")

# Unticked groups keep their Bitwarden group unless it's listed in DELETE_GROUPS.
OLD_DELETE=${DELETE_GROUPS:-}
NEW_DELETE=$OLD_DELETE
if [[ "$VAR" == GOOGLE_GROUPS ]]; then
  REMOVED=$(list_op minus "$CURRENT" "$CHOSEN")
  if [[ -n "$REMOVED" ]]; then
    echo
    echo "Bitwarden keeps the groups of the Google groups you removed, unless you delete them."
    echo "Deleting removes each group and its collection access. Its members stay in the organization,"
    echo "but anyone left in no synced group is revoked."
    read -r -p "Also delete the Bitwarden groups of the groups you removed? [y/N] " answer
    [[ "$(lower "$answer")" == y* ]] && NEW_DELETE=$(list_op plus "$NEW_DELETE" "$REMOVED")
  fi
  NEW_DELETE=$(list_op minus "$NEW_DELETE" "$CHOSEN")  # a group ticked again is never deleted
  if [[ -z "$CHOSEN" && -z "$NEW_DELETE" ]]; then
    echo "Select at least one group, or delete the groups you removed. Nothing was saved." >&2
    exit 1
  fi
  if [[ -z "$CHOSEN" ]]; then
    echo "No groups are left: the sync will revoke every member it manages (MAX_REMOVALS still applies)."
  fi
fi

SET=() UNSET=()
if [[ -n "$CHOSEN" ]]; then SET+=("$VAR=$CHOSEN"); else UNSET+=("$VAR"); fi
if [[ "$NEW_DELETE" != "$OLD_DELETE" ]]; then
  if [[ -n "$NEW_DELETE" ]]; then SET+=("DELETE_GROUPS=$NEW_DELETE"); else UNSET+=(DELETE_GROUPS); fi
fi
echo
echo "To save on the $JOB job:"
for item in "${SET[@]}"; do echo "  $item"; done
for item in "${UNSET[@]}"; do echo "  remove $item"; done
read -r -p "Save? [y/N] " answer
[[ "$(lower "$answer")" == y* ]] || { echo "Nothing was saved."; exit 0; }
if (( ${#SET[@]} )); then
  gcloud run jobs update "$JOB" --region "$REGION" --update-env-vars "^;^$(IFS=';'; echo "${SET[*]}")" \
    --quiet >/dev/null
fi
if (( ${#UNSET[@]} )); then
  gcloud run jobs update "$JOB" --region "$REGION" --remove-env-vars "$(IFS=,; echo "${UNSET[*]}")" \
    --quiet >/dev/null
fi
echo "Saved. The next run uses it."
export "$VAR=$CHOSEN" DELETE_GROUPS="$NEW_DELETE"

read -r -p "Run a dry run now to see what the sync would do? Nothing changes in Bitwarden. [Y/n] " answer
[[ "$(lower "$answer")" == n* ]] && exit 0
if [[ -z "${GOOGLE_GROUPS:-}" && -z "${DELETE_GROUPS:-}" ]]; then
  echo "No groups are selected yet. Run: bash select-groups.sh"
  exit 0
fi
BW_SCIM_API_KEY=$(gcloud secrets versions access latest --secret "$SECRET")
export BW_SCIM_API_KEY DRY_RUN=true
.venv/bin/python -m src.main | .venv/bin/python -c "$(cat <<'PY'
import json, sys
for line in sys.stdin:
    entry = json.loads(line)
    if "plan" in entry:
        print("\nPlanned changes (dry run):")
        labels = {"create_users": "Invite", "reactivate": "Restore", "revoke": "Revoke",
                  "delete": "Remove", "adopt_users": "Adopt"}
        changes = 0
        for key, label in labels.items():
            for change in entry["plan"][key]:
                print(f"  {label:8} {change['email']}: {change['reason']}")
                changes += 1
        for group in entry["plan"]["groups"]:
            print(f"  Group    {group['group']}: {group['action']}, {group['members']} member(s); {group['reason']}")
            changes += 1
        for group in entry["plan"]["delete_groups"]:
            print(f"  Delete   group {group['group']}: {group['reason']}")
            changes += 1
        if not changes:
            print("  Nothing to change.")
    elif entry.get("severity") in ("WARNING", "ERROR"):
        print(f"{entry['severity']}: {entry['message']}")
PY
)"
