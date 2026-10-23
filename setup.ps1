# Deploys the Google Workspace -> Bitwarden SCIM sync as a scheduled Cloud Run job.
# The PowerShell version of setup.sh, for Windows PowerShell 5.1 or PowerShell 7:
#   powershell -ExecutionPolicy Bypass -File setup.ps1
# Safe to re-run: it updates existing resources instead of failing. Keep it in step with setup.sh.

. (Join-Path $PSScriptRoot 'powershell/common.ps1')

$JOB = 'bw-scim-sync'
$SA_NAME = 'bw-scim-sync'
$SECRET = 'bw-scim-api-key'
$SCHEDULER_JOB = 'bw-scim-sync-schedule'

function Invoke-IamWithRetry {
    # New service accounts take a while to propagate, so retry "not found" and "permission denied".
    param([string]$What, [string[]]$Words, [System.Collections.IDictionary]$Options, [string]$ProjectId)
    $result = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $result = Invoke-Gcloud -Words $Words -Options $Options -AllowFailure
        if ($result.ExitCode -eq 0) { return }
        if ($result.ErrorText -notmatch 'PERMISSION_DENIED|NOT_FOUND|does not exist') { break }
        Write-Host "    $What not ready yet (attempt $attempt/6), waiting 15s..."
        Start-Sleep -Seconds 15
    }
    [Console]::Error.WriteLine($result.ErrorText)
    throw @"

Could not $What. If the service account exists in the console, your account lacks permission
to change IAM policy. Ask a project owner to grant you roles/iam.serviceAccountAdmin and
roles/secretmanager.admin on project $ProjectId (or roles/owner on a test project), then rerun.
"@
}

function Invoke-Setup {
    Initialize-Console
    $root = $PSScriptRoot
    Set-Location -LiteralPath $root  # the job is built from this folder

    $account = Assert-GcloudSignedIn
    Write-Host "Signed in to gcloud as: $account"
    $projectId = Get-EnvValue 'PROJECT_ID'
    if (-not $projectId) {
        $projectId = Read-Answer -Name 'PROJECT_ID' -Prompt 'Google Cloud project ID' `
            -Default (Get-GcloudValue -Words @('config', 'get-value', 'project'))
    }
    if (-not (Test-Gcloud -Words @('projects', 'describe', $projectId) -Options @{ '--format' = 'value(projectId)' })) {
        throw @"
$account can't access project "$projectId" (or it doesn't exist).
  - List the projects this account can use:   gcloud projects list
  - Or switch to another account:              gcloud config set account OTHER_ACCOUNT
  - Or create a new project for the sync:      gcloud projects create PROJECT_ID
    (then link billing in the console: Billing > Account management > Link a project)
"@
    }
    Invoke-Gcloud -Words @('config', 'set', 'project', $projectId) -Switches @('--quiet') -AllowFailure | Out-Null

    # On a rerun, default to the deployed job's region.
    $defaultRegion = Get-GcloudValue -Words @('run', 'jobs', 'list') `
        -Options ([ordered]@{ '--filter' = "metadata.name=$JOB"; '--format' = 'value(region)'; '--limit' = '1' })
    if (-not $defaultRegion) { $defaultRegion = Get-GcloudValue -Words @('config', 'get-value', 'run/region') }
    if (-not $defaultRegion) { $defaultRegion = 'europe-west1' }
    $region = Read-Answer -Name 'REGION' -Prompt 'Region' -Default $defaultRegion

    # On a rerun, read what's deployed so its current values become the defaults (Enter keeps them).
    $existingJob = $false
    $current = @{}
    $currentSchedule = ''
    $currentTimeZone = ''
    $described = Invoke-Gcloud -Words @('run', 'jobs', 'describe', $JOB) `
        -Options ([ordered]@{ '--region' = $region; '--format' = 'json' }) -AllowFailure
    if ($described.ExitCode -eq 0) {
        $existingJob = $true
        $current = Get-JobEnvironment -Json $described.Output
        $schedule = Get-GcloudValue -Words @('scheduler', 'jobs', 'describe', $SCHEDULER_JOB) `
            -Options ([ordered]@{ '--location' = $region; '--format' = 'value(schedule,timeZone)' })
        if ($schedule) { $currentSchedule, $currentTimeZone = $schedule -split "`t", 2 }
        Write-Host "Found the deployed $JOB job. Its current values are shown in [brackets]; press Enter to keep them."
    }
    $secretExists = Test-Gcloud -Words @('secrets', 'describe', $SECRET)

    $bwScimUrl = Read-Answer -Name 'BW_SCIM_URL' -Prompt 'Bitwarden SCIM URL (from Admin Console > Settings > SCIM provisioning)' `
        -Default ([string]$current['BW_SCIM_URL'])
    $apiKey = Get-EnvValue 'BW_SCIM_API_KEY'
    if (-not $apiKey) {
        if ($secretExists) {
            $apiKey = Read-Secret 'Bitwarden SCIM API key (input hidden; press Enter to keep the stored key)'
        } else {
            $apiKey = Read-Secret 'Bitwarden SCIM API key (input hidden)'
            if (-not $apiKey) { throw 'A value is required.' }
        }
    }
    $adminEmail = Read-Answer -Name 'GOOGLE_ADMIN_EMAIL' -Prompt 'Google Workspace admin email the sync reads the directory as' `
        -Default ([string]$current['GOOGLE_ADMIN_EMAIL'])
    if (Test-EnvSet 'GOOGLE_GROUPS') {
        $groups = Get-EnvValue 'GOOGLE_GROUPS'
    } elseif ($current['GOOGLE_GROUPS']) {  # optional: groups can be picked later with select-groups.ps1
        $groups = Read-Host "Google group email(s) to sync, comma-separated [$($current['GOOGLE_GROUPS'])]"
        if (-not $groups) { $groups = [string]$current['GOOGLE_GROUPS'] }
    } else {
        $groups = Read-Host 'Google group email(s) to sync, comma-separated (or press Enter to pick them from your directory after Step 3)'
    }
    $defaultSchedule = '0 * * * *'
    if ($currentSchedule) { $defaultSchedule = $currentSchedule }
    $schedule = Read-Answer -Name 'SCHEDULE' -Prompt 'Sync schedule (cron)' -Default $defaultSchedule
    $defaultTimeZone = 'Etc/UTC'
    if ($currentTimeZone) { $defaultTimeZone = $currentTimeZone }
    $timeZone = Read-Answer -Name 'TIME_ZONE' -Prompt 'Schedule time zone' -Default $defaultTimeZone

    $saEmail = "$SA_NAME@$projectId.iam.gserviceaccount.com"

    $billing = Get-GcloudValue -Words @('billing', 'projects', 'describe', $projectId) -Options @{ '--format' = 'value(billingEnabled)' }
    if ($billing -eq 'False') {
        throw @"
Project "$projectId" has no billing account linked. Cloud Run, Cloud Build and Cloud Scheduler need one.
  1. List the billing accounts you can use:  gcloud billing accounts list
  2. Link one:  gcloud billing projects link $projectId --billing-account XXXXXX-XXXXXX-XXXXXX
  If the list is empty, ask a billing admin to link the project (or grant you Billing Account User).
Then rerun this script.
"@
    }

    Write-Host '==> Enabling APIs (this can take a minute)'
    Invoke-Gcloud -PassThru -Words @('services', 'enable', 'run.googleapis.com', 'cloudbuild.googleapis.com',
        'artifactregistry.googleapis.com', 'cloudscheduler.googleapis.com', 'secretmanager.googleapis.com',
        'iamcredentials.googleapis.com', 'admin.googleapis.com') | Out-Null

    Write-Host '==> Service account'
    if (-not (Test-Gcloud -Words @('iam', 'service-accounts', 'describe', $saEmail))) {
        Invoke-Gcloud -PassThru -Words @('iam', 'service-accounts', 'create', $SA_NAME) `
            -Options @{ '--display-name' = 'Bitwarden SCIM sync' } | Out-Null
    }
    # Lets the job sign its own domain-wide-delegation token, so no key file is ever created.
    Invoke-IamWithRetry -What 'grant the service account permission to sign its own tokens' -ProjectId $projectId `
        -Words @('iam', 'service-accounts', 'add-iam-policy-binding', $saEmail) `
        -Options ([ordered]@{ '--member' = "serviceAccount:$saEmail"; '--role' = 'roles/iam.serviceAccountTokenCreator' })

    Write-Host '==> Storing the SCIM API key in Secret Manager'
    if (-not (Test-Gcloud -Words @('secrets', 'describe', $SECRET))) {
        Invoke-Gcloud -Words @('secrets', 'create', $SECRET) -Options @{ '--replication-policy' = 'automatic' } | Out-Null
    }
    if ($apiKey) {
        # A file, not a pipe: Windows PowerShell adds a line break when piping to a program.
        $keyFile = Get-TempFilePath
        try {
            Write-Utf8File -Path $keyFile -Text $apiKey
            Invoke-Gcloud -Words @('secrets', 'versions', 'add', $SECRET) -Options @{ '--data-file' = $keyFile } | Out-Null
        } finally {
            Remove-Item -LiteralPath $keyFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host '    Keeping the stored key.'
    }
    Invoke-IamWithRetry -What 'let the service account read the secret' -ProjectId $projectId `
        -Words @('secrets', 'add-iam-policy-binding', $SECRET) `
        -Options ([ordered]@{ '--member' = "serviceAccount:$saEmail"; '--role' = 'roles/secretmanager.secretAccessor' })

    # Only the values asked above are updated, so a rerun (new key, new version) keeps settings changed
    # later, such as DRY_RUN=false or PROTECTED_EMAILS.
    foreach ($value in @($bwScimUrl, $adminEmail, $groups)) {
        if ($value -like '*;*') { throw "Values can't contain ';': $value" }
    }
    $envVars = [ordered]@{ BW_SCIM_URL = $bwScimUrl; GOOGLE_ADMIN_EMAIL = $adminEmail; GOOGLE_SA_EMAIL = $saEmail }
    if ($groups) { $envVars['GOOGLE_GROUPS'] = $groups }
    if ($existingJob) {
        Write-Host '==> Building and updating the Cloud Run job (your other settings, including DRY_RUN, are kept)'
    } else {
        Write-Host '==> Building and deploying the Cloud Run job (DRY_RUN=true: nothing changes yet)'
        $envVars['DRY_RUN'] = 'true'
    }
    Invoke-Gcloud -PassThru -Words @('run', 'jobs', 'deploy', $JOB) -Options ([ordered]@{
            '--source'          = '.'
            '--region'          = $region
            '--service-account' = $saEmail
            '--set-secrets'     = [ordered]@{ BW_SCIM_API_KEY = "${SECRET}:latest" }
            '--update-env-vars' = $envVars
            '--max-retries'     = '0'
            '--task-timeout'    = '30m'
        }) | Out-Null

    Write-Host '==> Schedule'
    Invoke-Gcloud -Words @('run', 'jobs', 'add-iam-policy-binding', $JOB) -Options ([ordered]@{
            '--region' = $region; '--member' = "serviceAccount:$saEmail"; '--role' = 'roles/run.invoker'
        }) | Out-Null
    $runUri = "https://run.googleapis.com/v2/projects/$projectId/locations/$region/jobs/${JOB}:run"
    $scheduleOptions = [ordered]@{
        '--location' = $region; '--schedule' = $schedule; '--time-zone' = $timeZone; '--uri' = $runUri
        '--http-method' = 'POST'; '--oauth-service-account-email' = $saEmail
    }
    if (Test-Gcloud -Words @('scheduler', 'jobs', 'describe', $SCHEDULER_JOB) -Options @{ '--location' = $region }) {
        Invoke-Gcloud -Words @('scheduler', 'jobs', 'update', 'http', $SCHEDULER_JOB) -Options $scheduleOptions | Out-Null
    } else {
        Invoke-Gcloud -Words @('scheduler', 'jobs', 'create', 'http', $SCHEDULER_JOB) -Options $scheduleOptions | Out-Null
    }

    $clientId = (Invoke-Gcloud -Words @('iam', 'service-accounts', 'describe', $saEmail) `
            -Options @{ '--format' = 'value(oauth2ClientId)' }).Output
    $shell = (Get-Process -Id $PID).ProcessName
    Write-Host @"

Done. Next steps (README Steps 3-6):

3. In the Google Admin console, open Security > Access and data control > API controls >
   Manage domain-wide delegation (https://admin.google.com/ac/owl/domainwidedelegation),
   select Add new, and enter:
     Client ID:    $clientId
     OAuth scopes: https://www.googleapis.com/auth/admin.directory.user.readonly,https://www.googleapis.com/auth/admin.directory.group.readonly,https://www.googleapis.com/auth/admin.directory.group.member.readonly

4. Choose the Google groups to sync from your directory, and run a dry run (Step 5):
     $shell -ExecutionPolicy Bypass -File "$(Join-Path $root 'select-groups.ps1')"

6. When the dry-run plan looks right, turn on real syncing:
     gcloud run jobs update $JOB --region $region --update-env-vars DRY_RUN=false
"@
}

try {
    Invoke-Setup
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
