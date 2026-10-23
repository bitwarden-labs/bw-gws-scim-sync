# Directory picker and Cloud Run dry run for select-groups.ps1, without Python.
# Reads the directory with the same read-only, keyless access as the sync: the bw-scim-sync service
# account signs a domain-wide delegation token through the IAM Credentials API. The picker is the
# numbered list of src/picker.py (pick_plain). The dry run is one Cloud Run execution with
# DRY_RUN=true for that run only, read back from Cloud Logging. Needs powershell/common.ps1.

$script:DirectoryScopes = @(
    'https://www.googleapis.com/auth/admin.directory.user.readonly'
    'https://www.googleapis.com/auth/admin.directory.group.readonly'
    'https://www.googleapis.com/auth/admin.directory.group.member.readonly'
) -join ' '

function Get-GoogleApiUrl {
    # BW_SYNC_API_ROOT points every Google API at a local fake (tests only).
    param([Parameter(Mandatory)][string]$Url)
    $root = Get-EnvValue 'BW_SYNC_API_ROOT'
    if (-not $root) { return $Url }
    $root.TrimEnd('/') + '/' + ($Url -replace '^https://', '')
}

function Invoke-GoogleApi {
    # Invoke-RestMethod with a bearer token. Errors carry the HTTP status and body in Exception.Data.
    param([string]$Method = 'Get', [Parameter(Mandatory)][string]$Url, [string]$Token, $Body, [hashtable]$Form)
    $params = @{ Method = $Method; Uri = (Get-GoogleApiUrl $Url); UseBasicParsing = $true; Headers = @{} }
    if ($Token) { $params.Headers['Authorization'] = "Bearer $Token" }
    if ($null -ne $Body) {
        $json = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $params.ContentType = 'application/json; charset=utf-8'
    }
    if ($Form) {
        $params.Body = $Form
        $params.ContentType = 'application/x-www-form-urlencoded'
    }
    try {
        Invoke-RestMethod @params
    } catch {
        $status = 0
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        $detail = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        $failure = New-Object System.Exception ("$Method $Url failed: $status $detail".Trim())
        $failure.Data['Status'] = $status
        $failure.Data['Detail'] = $detail
        throw $failure
    }
}

function Get-DirectoryToken {
    # A read-only Directory API token for the admin, signed by the sync's service account.
    param([Parameter(Mandatory)][string]$SaEmail, [Parameter(Mandatory)][string]$AdminEmail,
        [Parameter(Mandatory)][string]$UserToken, [int]$Attempts = 12, [int]$WaitSeconds = 15)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $claims = ConvertTo-Json -Compress -InputObject ([ordered]@{
            iss = $SaEmail; sub = $AdminEmail; scope = $script:DirectoryScopes
            aud = 'https://oauth2.googleapis.com/token'; iat = $now; exp = $now + 3600
        })
    $signUrl = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${SaEmail}:signJwt"
    $signed = $null
    for ($attempt = 1; $null -eq $signed; $attempt++) {
        try {
            $signed = Invoke-GoogleApi -Method Post -Url $signUrl -Token $UserToken -Body @{ payload = $claims }
        } catch {
            # Permission to sign was just granted (select-groups does that first); it takes a while.
            if ($_.Exception.Data['Status'] -ne 403 -or $attempt -ge $Attempts) { throw }
            [Console]::Error.WriteLine("  Waiting for permission to sign as the service account ($attempt/$Attempts)...")
            Start-Sleep -Seconds $WaitSeconds
        }
    }
    try {
        $token = Invoke-GoogleApi -Method Post -Url 'https://oauth2.googleapis.com/token' -Form @{
            grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer'; assertion = $signed.signedJwt
        }
    } catch {
        if ("$($_.Exception.Data['Detail'])" -match 'unauthorized_client') {
            throw ("Google rejected the directory access: domain-wide delegation isn't set up or isn't " +
                'active yet (README Step 3). Check the Client ID and scopes, wait a few minutes, and try again.')
        }
        throw
    }
    $token.access_token
}

function Get-DirectoryItem {
    # Every group (with its direct member count) or every active user, sorted by name, like src/picker.py.
    param([Parameter(Mandatory)][ValidateSet('groups', 'users')][string]$Kind, [Parameter(Mandatory)][string]$Token)
    $base = 'https://admin.googleapis.com/admin/directory/v1'
    $items = New-Object System.Collections.Generic.List[object]
    $pageToken = ''
    do {
        if ($Kind -eq 'groups') { $url = "$base/groups?customer=my_customer&maxResults=200" }
        else { $url = "$base/users?customer=my_customer&maxResults=500" }
        if ($pageToken) { $url += '&pageToken=' + [Uri]::EscapeDataString($pageToken) }
        $page = Invoke-GoogleApi -Url $url -Token $Token
        $entries = @()
        if ($page.PSObject.Properties[$Kind]) { $entries = @($page.$Kind) }
        foreach ($entry in $entries) {
            if ($Kind -eq 'groups') {
                $count = 0
                if ($entry.PSObject.Properties['directMembersCount']) { $count = [int]$entry.directMembersCount }
                $label = $entry.email
                if ($entry.PSObject.Properties['name'] -and $entry.name) { $label = $entry.name }
                $detail = "$count member"
                if ($count -ne 1) { $detail += 's' }
                $items.Add([pscustomobject]@{ Key = $entry.email.ToLowerInvariant(); Label = [string]$label; Detail = $detail })
            } else {
                $inactive = ($entry.PSObject.Properties['suspended'] -and $entry.suspended) -or
                ($entry.PSObject.Properties['archived'] -and $entry.archived)
                if ($inactive) { continue }
                $label = $entry.primaryEmail
                if ($entry.PSObject.Properties['name'] -and $entry.name.PSObject.Properties['fullName']) { $label = $entry.name.fullName }
                $items.Add([pscustomobject]@{ Key = $entry.primaryEmail.ToLowerInvariant(); Label = [string]$label; Detail = '' })
            }
        }
        $pageToken = ''
        if ($page.PSObject.Properties['nextPageToken']) { $pageToken = $page.nextPageToken }
    } while ($pageToken)
    , @($items | Sort-Object -Property @{ Expression = { $_.Label.ToLowerInvariant() } }, Key)
}

function Add-MissingCurrent {
    # Keeps saved emails that the directory no longer has, so they can be seen and unselected.
    param([object[]]$Items, [string[]]$Current)
    $known = @($Items | ForEach-Object { $_.Key })
    $missing = @($Current | Where-Object { $known -notcontains $_ } |
            ForEach-Object { [pscustomobject]@{ Key = $_; Label = $_; Detail = 'not found in the directory' } })
    , (@($missing) + @($Items))
}

function Format-PickerRow {
    param($Item, [System.Collections.Generic.HashSet[string]]$Chosen, [int]$KeyWidth)
    $mark = ' '
    if ($Chosen.Contains($Item.Key)) { $mark = 'x' }
    $label = $Item.Label
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
    ('[{0}] {1}  {2}  {3}' -f $mark, $label.PadRight(32), $Item.Key.PadRight($KeyWidth), $Item.Detail).TrimEnd()
}

function Select-PickerItem {
    # The items whose email or name contains the filter text.
    param([object[]]$Items, [string]$Text)
    $needle = $Text.Trim().ToLowerInvariant()
    if (-not $needle) { return , @($Items) }
    , @($Items | Where-Object { $_.Key.ToLowerInvariant().Contains($needle) -or $_.Label.ToLowerInvariant().Contains($needle) })
}

function ConvertFrom-PickerSelection {
    # "1,3,5-7" -> 0-based indexes 0, 2, 4, 5, 6. Throws when a part is out of range or not a number.
    param([string]$Text, [int]$Count)
    $chosen = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($Text -replace ' ', '') -split ',') {
        if (-not $part) { continue }
        $low, $high = $part -split '-', 2
        $start = 0
        $end = 0
        if (-not [int]::TryParse($low, [ref]$start) -or ($null -ne $high -and -not [int]::TryParse($high, [ref]$end))) {
            throw "'$part' isn't a number or a range like 5-7"
        }
        if ($null -eq $high) { $end = $start }
        if ($start -lt 1 -or $end -lt $start -or $end -gt $Count) { throw "$part isn't between 1 and $Count" }
        for ($i = $start; $i -le $end; $i++) { if (-not $chosen.Contains($i - 1)) { $chosen.Add($i - 1) } }
    }
    , $chosen.ToArray()
}

function Show-Picker {
    # Numbered-list picker, like src/picker.py's pick_plain. Returns the chosen emails, or $null if cancelled.
    param([string]$Title, [object[]]$Items, [string[]]$Selected)
    $chosen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($email in $Selected) { [void]$chosen.Add($email) }
    $text = ''
    $empty = 0
    while ($true) {
        $shown = Select-PickerItem -Items $Items -Text $text
        $heading = "`n$Title"
        if ($text) { $heading += "   (filter: $text)" }
        Write-Host $heading
        if ($shown.Count -eq 0) { Write-Host '  No matches.' }
        $keyWidth = 0
        foreach ($item in $shown) { if ($item.Key.Length -gt $keyWidth) { $keyWidth = $item.Key.Length } }
        for ($n = 0; $n -lt $shown.Count; $n++) {
            Write-Host ('  {0,3}  {1}' -f ($n + 1), (Format-PickerRow -Item $shown[$n] -Chosen $chosen -KeyWidth $keyWidth))
        }
        Write-Host ("$($chosen.Count) selected. Type numbers to select or unselect (for example 1,3,5-7), " +
            '/text to filter, / to clear the filter, s to save, q to cancel.')
        $answer = Read-Host '>'
        if ($null -eq $answer) { return $null }  # end of input
        $answer = $answer.Trim()
        if (-not $answer -and [Console]::IsInputRedirected) {
            $empty++
            if ($empty -ge 20) { return $null }  # input ran out (Windows PowerShell returns '' there)
        }
        if ($answer -eq 's') { return , @($Items | Where-Object { $chosen.Contains($_.Key) } | ForEach-Object { $_.Key }) }
        if ($answer -eq 'q') { return $null }
        if ($answer.StartsWith('/')) {
            $text = $answer.Substring(1)
            continue
        }
        try {
            foreach ($index in (ConvertFrom-PickerSelection -Text $answer -Count $shown.Count)) {
                $key = $shown[$index].Key
                if (-not $chosen.Remove($key)) { [void]$chosen.Add($key) }
            }
        } catch {
            Write-Host "  $($_.Exception.Message)"
        }
    }
}

function Write-DryRunPlan {
    # Same output as select-groups.sh: one line per planned change, plus warnings and errors.
    # Each entry has severity and message, and the plan entry has plan.
    param([object[]]$Entries)
    $labels = [ordered]@{ create_users = 'Invite'; reactivate = 'Restore'; revoke = 'Revoke'; delete = 'Remove'; adopt_users = 'Adopt' }
    foreach ($entry in $Entries) {
        if ($null -eq $entry) { continue }
        if ($entry.PSObject.Properties['plan']) {
            Write-Host ''
            Write-Host 'Planned changes (dry run):'
            $changes = 0
            foreach ($key in $labels.Keys) {
                if (-not $entry.plan.PSObject.Properties[$key]) { continue }
                foreach ($change in @($entry.plan.$key)) {
                    if ($null -eq $change) { continue }
                    Write-Host ('  {0,-8} {1}: {2}' -f $labels[$key], $change.email, $change.reason)
                    $changes++
                }
            }
            if ($entry.plan.PSObject.Properties['groups']) {
                foreach ($group in @($entry.plan.groups)) {
                    if ($null -eq $group) { continue }
                    Write-Host ('  Group    {0}: {1}, {2} member(s); {3}' -f $group.group, $group.action, $group.members, $group.reason)
                    $changes++
                }
            }
            if ($entry.plan.PSObject.Properties['delete_groups']) {
                foreach ($group in @($entry.plan.delete_groups)) {
                    if ($null -eq $group) { continue }
                    Write-Host ('  Delete   group {0}: {1}' -f $group.group, $group.reason)
                    $changes++
                }
            }
            if (-not $changes) { Write-Host '  Nothing to change.' }
        } elseif ($entry.PSObject.Properties['severity'] -and $entry.severity -in @('WARNING', 'ERROR', 'CRITICAL')) {
            Write-Host "$($entry.severity): $($entry.message)"
        }
    }
}

function Invoke-CloudDryRun {
    # Runs the deployed job once with DRY_RUN=true (only for that run) and prints its plan.
    param([Parameter(Mandatory)][string]$ProjectId, [Parameter(Mandatory)][string]$Region, [Parameter(Mandatory)][string]$Job,
        [int]$Attempts = 12, [int]$WaitSeconds = 5)
    Write-Host 'Running a dry run on Cloud Run (usually under a minute). Nothing changes in Bitwarden.'
    $run = Invoke-Gcloud -Words @('run', 'jobs', 'execute', $Job) -Switches @('--wait') -AllowFailure -Options ([ordered]@{
            '--region' = $Region; '--update-env-vars' = [ordered]@{ DRY_RUN = 'true' }; '--format' = 'value(metadata.name)'
        })
    $execution = @($run.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    if (-not $execution) { throw "The dry run couldn't start. $($run.ErrorText)" }
    $execution = $execution[0].Trim()
    $token = Get-GcloudValue -Words @('auth', 'print-access-token')
    $filter = 'resource.type="cloud_run_job" AND resource.labels.job_name="' + $Job +
    '" AND labels."run.googleapis.com/execution_name"="' + $execution + '"'
    $entries = @()
    $complete = $false
    for ($attempt = 1; $attempt -le $Attempts -and -not $complete; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds $WaitSeconds }  # logs arrive a few seconds after the run
        $response = Invoke-GoogleApi -Method Post -Url 'https://logging.googleapis.com/v2/entries:list' -Token $token -Body ([ordered]@{
                resourceNames = @("projects/$ProjectId"); filter = $filter; orderBy = 'timestamp asc'; pageSize = 1000
            })
        $entries = @()
        if ($response.PSObject.Properties['entries']) { $entries = @($response.entries) }
        foreach ($entry in $entries) {
            if ($entry.PSObject.Properties['textPayload'] -and $entry.textPayload -like 'Container called exit*') { $complete = $true }
        }
    }
    $lines = foreach ($entry in $entries) {
        $severity = 'DEFAULT'
        if ($entry.PSObject.Properties['severity']) { $severity = $entry.severity }
        if ($entry.PSObject.Properties['jsonPayload']) {
            $payload = $entry.jsonPayload
            $payload | Add-Member -NotePropertyName severity -NotePropertyValue $severity -Force
            $payload
        } elseif ($entry.PSObject.Properties['textPayload'] -and $severity -in @('ERROR', 'CRITICAL')) {
            [pscustomobject]@{ severity = 'ERROR'; message = $entry.textPayload }
        }
    }
    Write-DryRunPlan -Entries @($lines)
    if ($run.ExitCode -ne 0) {
        Write-Host "The dry run stopped with an error (see above). Its full log: Cloud Run > Jobs > $Job > Logs, execution $execution."
    } elseif (-not $complete) {
        Write-Host "The dry run's log isn't complete yet. See Cloud Run > Jobs > $Job > Logs, execution $execution."
    }
}
