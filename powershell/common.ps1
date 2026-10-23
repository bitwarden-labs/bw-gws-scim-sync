# Helpers shared by setup.ps1 and select-groups.ps1. Works in Windows PowerShell 5.1 and
# PowerShell 7 on Windows, macOS and Linux.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Initialize-Console {
    # gcloud and Python print UTF-8; read it as UTF-8 so names with accents survive.
    $utf8 = New-Object System.Text.UTF8Encoding $false
    try { [Console]::OutputEncoding = $utf8 } catch { Write-Verbose 'No console to set the encoding on.' }
    $global:OutputEncoding = $utf8
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
}

function Write-Utf8File {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-TempFilePath {
    param([string]$Extension = '.tmp')
    Join-Path ([System.IO.Path]::GetTempPath()) ('bw-scim-' + [guid]::NewGuid().ToString('N') + $Extension)
}

function Invoke-Gcloud {
    <#
    Runs gcloud. Words go on the command line and must be plain (letters, digits, @ . _ : / -);
    every option value goes into a temporary --flags-file, so nothing on the command line is
    special to cmd.exe (gcloud.cmd) or PowerShell, such as ^ , ; or spaces.
    Captured calls get no input, so gcloud never waits at a hidden prompt. -PassThru shows the
    output and keeps the console as input instead, for steps that may ask a question (deploy).
    Returns @{ ExitCode; Output; ErrorText }; fails on a non-zero exit code unless -AllowFailure.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Words,
        [System.Collections.IDictionary]$Options = @{},
        [string[]]$Switches = @(),
        [switch]$AllowFailure,
        [switch]$PassThru
    )
    foreach ($word in $Words) {
        if ($word -notmatch '^[A-Za-z0-9@._:/-]+$') { throw "Unsafe gcloud argument: '$word'" }
    }
    foreach ($switch in $Switches) {
        if ($switch -notin @('--quiet', '--wait')) { throw "Unknown gcloud switch: '$switch'" }
    }
    $arguments = @($Words) + @($Switches)
    $flagsFile = $null
    if ($Options.Count -gt 0) {
        $flagsFile = Get-TempFilePath -Extension '.json'
        Write-Utf8File -Path $flagsFile -Text (ConvertTo-Json -InputObject $Options -Depth 5)
        $arguments += @('--flags-file', $flagsFile)
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'  # gcloud's progress messages on stderr aren't errors
    try {
        if ($PassThru) {
            & gcloud @arguments | Out-Host
            $code = $LASTEXITCODE
            $output = ''
            $errorText = ''
        } else {
            $all = @(@() | & gcloud @arguments 2>&1)
            $code = $LASTEXITCODE
            $output = (@($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
            $errorText = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                        ForEach-Object { $_.Exception.Message }) -join "`n").Trim()
        }
    } finally {
        $ErrorActionPreference = $previous
        if ($flagsFile) { Remove-Item -LiteralPath $flagsFile -Force -ErrorAction SilentlyContinue }
    }
    if ($null -eq $code) { $code = 0 }
    if ($code -ne 0 -and -not $AllowFailure) {
        if ($errorText) { [Console]::Error.WriteLine($errorText) }
        throw "gcloud $($Words -join ' ') failed (exit code $code)."
    }
    [pscustomobject]@{ ExitCode = $code; Output = $output; ErrorText = $errorText }
}

function Get-GcloudValue {
    # stdout of a gcloud call, or '' if it fails (like "$(gcloud ... 2>/dev/null || true)").
    param([Parameter(Mandatory)][string[]]$Words, [System.Collections.IDictionary]$Options = @{})
    $result = Invoke-Gcloud -Words $Words -Options $Options -AllowFailure
    if ($result.ExitCode -ne 0) { return '' }
    $result.Output
}

function Test-Gcloud {
    # True if the gcloud call succeeds (like "gcloud ... >/dev/null 2>&1").
    param([Parameter(Mandatory)][string[]]$Words, [System.Collections.IDictionary]$Options = @{})
    (Invoke-Gcloud -Words $Words -Options $Options -AllowFailure).ExitCode -eq 0
}

function Get-EnvValue {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    $value
}

function Test-EnvSet {
    # Set, even to an empty value (like bash "${VAR+set}"). Windows can't hold an empty variable,
    # so there "set to empty" isn't possible; Linux and macOS can.
    param([Parameter(Mandatory)][string]$Name)
    $null -ne [Environment]::GetEnvironmentVariable($Name)
}

function Read-Answer {
    # Like setup.sh's ask(): an environment variable of that name wins; otherwise prompt, with the
    # default in [brackets] for Enter. A value is required.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Prompt, [string]$Default = '')
    $value = Get-EnvValue $Name
    if ($value) { return $value }
    $label = $Prompt
    if ($Default) { $label = "$Prompt [$Default]" }
    $value = Read-Host $label
    if (-not $value) { $value = $Default }
    if (-not $value) { throw 'A value is required.' }
    $value
}

function Read-Secret {
    param([Parameter(Mandatory)][string]$Prompt)
    # Read-Host -AsSecureString silently ends the script when input is redirected (tests, pipes),
    # so only hide the input at a real console.
    if ([Console]::IsInputRedirected) { return (Read-Host $Prompt) }
    $secure = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Split-EmailList {
    param([AllowEmptyString()][string]$Text)
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($Text -split ',')) {
        $email = $part.Trim().ToLowerInvariant()
        if ($email -and -not $seen.Contains($email)) { $seen.Add($email) }
    }
    , $seen.ToArray()
}

function Merge-EmailList {
    # Like select-groups.sh's list_op: comma-separated lists, compared case-insensitively.
    param([Parameter(Mandatory)][ValidateSet('minus', 'plus')][string]$Op,
        [AllowEmptyString()][string]$A, [AllowEmptyString()][string]$B)
    $left = Split-EmailList $A
    $right = Split-EmailList $B
    if ($Op -eq 'minus') {
        $result = @($left | Where-Object { $right -notcontains $_ })
    } else {
        $result = @($left) + @($right | Where-Object { $left -notcontains $_ })
    }
    ($result -join ',')
}

function Select-FromList {
    # Numbered choice, Enter picks the first. Returns the chosen item.
    param([Parameter(Mandatory)][string[]]$Items, [string]$Prompt = 'Number to use')
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $Items[$i]) }
    $choice = Read-Host "$Prompt [1]"
    if (-not $choice) { $choice = '1' }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $Items.Count) {
        throw 'Choose a number from the list.'
    }
    $Items[$number - 1]
}

function Get-JobEnvironment {
    # The job's plain environment variables (not the secret) from "gcloud run jobs describe --format json".
    param([Parameter(Mandatory)][string]$Json)
    $job = $Json | ConvertFrom-Json
    $vars = [ordered]@{}
    $container = $job.spec.template.spec.template.spec.containers[0]
    if (-not $container.PSObject.Properties['env']) { return $vars }  # a job without variables
    foreach ($entry in @($container.env)) {
        if ($null -ne $entry -and $entry.PSObject.Properties['value']) { $vars[$entry.name] = [string]$entry.value }
    }
    $vars
}

function Assert-GcloudSignedIn {
    # Returns the signed-in account. An expired sign-in otherwise shows up later as "can't access project".
    $account = Get-GcloudValue -Words @('config', 'get-value', 'account')
    if (-not $account) { throw 'No gcloud account is signed in. Run: gcloud auth login' }
    if (-not (Test-Gcloud -Words @('auth', 'print-access-token'))) {
        throw "The gcloud sign-in for $account has expired. Run: gcloud auth login"
    }
    $account
}
