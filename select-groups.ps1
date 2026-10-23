# Choose from your Google Workspace directory instead of typing emails, and save the choice on the
# deployed job. The PowerShell version of select-groups.sh, for Windows PowerShell 5.1 or 7:
#   powershell -ExecutionPolicy Bypass -File select-groups.ps1                     groups to sync (GOOGLE_GROUPS)
#   powershell -ExecutionPolicy Bypass -File select-groups.ps1 --protected-users   never revoked (PROTECTED_EMAILS)
#   powershell -ExecutionPolicy Bypass -File select-groups.ps1 --adopt-users       may be adopted (ADOPT_USERS)
# Run after README Steps 2-3. Needs only PowerShell and gcloud: the directory is read with REST calls
# and the dry run runs on Cloud Run. Keep it in step with select-groups.sh.

. (Join-Path $PSScriptRoot 'powershell/common.ps1')
. (Join-Path $PSScriptRoot 'powershell/picker.ps1')

$JOB = 'bw-scim-sync'

function Test-Yes {
    param([AllowEmptyString()][string]$Answer, [switch]$DefaultYes)
    if (-not $Answer) { return [bool]$DefaultYes }
    $Answer.Trim().ToLowerInvariant().StartsWith('y')
}

function Invoke-GroupSelection {
    param([string[]]$Arguments)
    Initialize-Console
    $root = $PSScriptRoot
    Set-Location -LiteralPath $root

    $var = 'GOOGLE_GROUPS'; $kind = 'groups'; $title = 'Google groups to sync'
    $mode = ''
    if ($Arguments) { $mode = $Arguments[0] }
    switch ($mode) {
        { $_ -in @('', '--groups') } { break }
        '--protected-users' { $var = 'PROTECTED_EMAILS'; $kind = 'users'; $title = 'Users the sync must never revoke, delete or adopt'; break }
        '--adopt-users' { $var = 'ADOPT_USERS'; $kind = 'users'; $title = 'Existing Bitwarden members the sync may adopt'; break }
        default { throw 'Usage: select-groups.ps1 [--groups | --protected-users | --adopt-users]' }
    }

    $account = Assert-GcloudSignedIn
    $projectId = Read-Answer -Name 'PROJECT_ID' -Prompt 'Google Cloud project ID' `
        -Default (Get-GcloudValue -Words @('config', 'get-value', 'project'))
    Invoke-Gcloud -Words @('config', 'set', 'project', $projectId) -Switches @('--quiet') -AllowFailure | Out-Null
    $region = Get-EnvValue 'REGION'
    if (-not $region) {
        # Find the job's region, so it doesn't need typing.
        $listed = Get-GcloudValue -Words @('run', 'jobs', 'list') `
            -Options ([ordered]@{ '--filter' = "metadata.name=$JOB"; '--format' = 'value(region)' })
        $regions = @($listed -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
        if ($regions.Count -eq 1) {
            $region = $regions[0]
            Write-Host "Found the $JOB job in $region."
        } elseif ($regions.Count -gt 1) {
            Write-Host "The $JOB job exists in more than one region:"
            $region = Select-FromList -Items $regions -Prompt 'Number of the region to use'
        } else {
            throw "Couldn't find the $JOB job in project $projectId. Check the project, or run setup.ps1 first (README Step 2)."
        }
    }

    $described = Invoke-Gcloud -Words @('run', 'jobs', 'describe', $JOB) -Options ([ordered]@{ '--region' = $region; '--format' = 'json' }) -AllowFailure
    if ($described.ExitCode -ne 0) {
        if ($described.ErrorText) { [Console]::Error.WriteLine($described.ErrorText) }
        throw "Couldn't find the $JOB job in $region. Check the region, or run setup.ps1 first (README Step 2)."
    }
    $vars = Get-JobEnvironment -Json $described.Output
    $saEmail = [string]$vars['GOOGLE_SA_EMAIL']
    if (-not $saEmail) { throw 'The job has no GOOGLE_SA_EMAIL; run setup.ps1 again' }
    if (-not $vars['GOOGLE_ADMIN_EMAIL']) { throw 'The job has no GOOGLE_ADMIN_EMAIL; run setup.ps1 again' }
    $current = [string]$vars[$var]
    if ($var -eq 'ADOPT_USERS' -and $current.ToLowerInvariant() -in @('true', '1', 'yes', 'on', 'false', '0', 'no', 'off')) {
        Write-Host "ADOPT_USERS is currently '$current'. Saving a selection replaces it with a list of emails."
        $current = ''
    }

    # Lets you read the directory with the sync's read-only access (keyless, as the job does).
    $member = "user:$account"
    if ($account -like '*.gserviceaccount.com') { $member = "serviceAccount:$account" }
    $grant = Invoke-Gcloud -Words @('iam', 'service-accounts', 'add-iam-policy-binding', $saEmail) `
        -Options ([ordered]@{ '--member' = $member; '--role' = 'roles/iam.serviceAccountTokenCreator' }) -AllowFailure
    if ($grant.ExitCode -ne 0) { throw $grant.ErrorText }

    Write-Host "Reading $kind from your Google Workspace directory..."
    $token = Get-DirectoryToken -SaEmail $saEmail -AdminEmail ([string]$vars['GOOGLE_ADMIN_EMAIL']) `
        -UserToken (Get-GcloudValue -Words @('auth', 'print-access-token'))
    $currentList = Split-EmailList $current
    $items = Add-MissingCurrent -Items (Get-DirectoryItem -Kind $kind -Token $token) -Current $currentList
    $result = Show-Picker -Title $title -Items $items -Selected $currentList
    if ($null -eq $result) {
        Write-Host 'Cancelled. Nothing was changed.'
        return
    }
    $added = @($result | Where-Object { $currentList -notcontains $_ })
    $removedNow = @($currentList | Where-Object { $result -notcontains $_ })
    Write-Host "Selected $(@($result).Count)."
    foreach ($email in $added) { Write-Host "  + $email" }
    foreach ($email in $removedNow) { Write-Host "  - $email" }
    if (-not $added -and -not $removedNow) {
        Write-Host '  No changes.'
        return
    }
    $chosen = @($result) -join ','

    # Unticked groups keep their Bitwarden group unless it's listed in DELETE_GROUPS.
    $oldDelete = [string]$vars['DELETE_GROUPS']
    $newDelete = $oldDelete
    if ($var -eq 'GOOGLE_GROUPS') {
        $removed = Merge-EmailList -Op minus -A $current -B $chosen
        if ($removed) {
            Write-Host ''
            Write-Host 'Bitwarden keeps the groups of the Google groups you removed, unless you delete them.'
            Write-Host 'Deleting removes each group and its collection access. Its members stay in the organization,'
            Write-Host 'but anyone left in no synced group is revoked.'
            if (Test-Yes (Read-Host 'Also delete the Bitwarden groups of the groups you removed? [y/N]')) {
                $newDelete = Merge-EmailList -Op plus -A $newDelete -B $removed
            }
        }
        $newDelete = Merge-EmailList -Op minus -A $newDelete -B $chosen  # a group ticked again is never deleted
        if (-not $chosen -and -not $newDelete) {
            throw 'Select at least one group, or delete the groups you removed. Nothing was saved.'
        }
        if (-not $chosen) {
            Write-Host 'No groups are left: the sync will revoke every member it manages (MAX_REMOVALS still applies).'
        }
    }

    $set = [ordered]@{}
    $unset = New-Object System.Collections.Generic.List[string]
    if ($chosen) { $set[$var] = $chosen } else { $unset.Add($var) }
    if ($newDelete -ne $oldDelete) {
        if ($newDelete) { $set['DELETE_GROUPS'] = $newDelete } else { $unset.Add('DELETE_GROUPS') }
    }
    Write-Host ''
    Write-Host "To save on the $JOB job:"
    foreach ($name in $set.Keys) { Write-Host "  $name=$($set[$name])" }
    foreach ($name in $unset) { Write-Host "  remove $name" }
    if (-not (Test-Yes (Read-Host 'Save? [y/N]'))) {
        Write-Host 'Nothing was saved.'
        return
    }
    if ($set.Count -gt 0) {
        Invoke-Gcloud -Words @('run', 'jobs', 'update', $JOB) -Switches @('--quiet') `
            -Options ([ordered]@{ '--region' = $region; '--update-env-vars' = $set }) | Out-Null
    }
    if ($unset.Count -gt 0) {
        Invoke-Gcloud -Words @('run', 'jobs', 'update', $JOB) -Switches @('--quiet') `
            -Options ([ordered]@{ '--region' = $region; '--remove-env-vars' = [string[]]$unset.ToArray() }) | Out-Null
    }
    Write-Host 'Saved. The next run uses it.'
    $savedGroups = [string]$vars['GOOGLE_GROUPS']
    if ($var -eq 'GOOGLE_GROUPS') { $savedGroups = $chosen }

    if (-not (Test-Yes (Read-Host 'Run a dry run now to see what the sync would do? Nothing changes in Bitwarden. [Y/n]') -DefaultYes)) {
        return
    }
    if (-not $savedGroups -and -not $newDelete) {
        Write-Host 'No groups are selected yet. Run: select-groups.ps1'
        return
    }
    Invoke-CloudDryRun -ProjectId $projectId -Region $region -Job $JOB
}

try {
    Invoke-GroupSelection -Arguments $args
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
