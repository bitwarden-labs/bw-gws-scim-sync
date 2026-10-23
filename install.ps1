# One-line installer for Windows: downloads a pinned release of the sync and runs setup.ps1.
#   irm https://raw.githubusercontent.com/bitwarden-labs/bw-gws-scim-sync/v1.1.0/install.ps1 | iex
# Works in Windows PowerShell 5.1 and PowerShell 7, with the Google Cloud CLI installed.
# Options (environment variables): BW_SYNC_REF (tag, branch or commit; default below),
# BW_SYNC_DIR (default ~\bw-gws-scim-sync), BW_SYNC_SKIP_SETUP=1 (download only).
# Everything is inside Install-BwScimSync, which runs only once the whole file has been read.
# It never calls exit: with "irm ... | iex" that would close your PowerShell window.

function Install-BwScimSync {
    $ErrorActionPreference = 'Stop'
    $version = 'v1.1.0'
    $repo = 'bitwarden-labs/bw-gws-scim-sync'
    $ref = $env:BW_SYNC_REF
    if (-not $ref) { $ref = $version }
    $dir = $env:BW_SYNC_DIR
    if (-not $dir) { $dir = Join-Path $HOME 'bw-gws-scim-sync' }
    $dir = $dir.TrimEnd('\', '/')

    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
        throw 'The Google Cloud CLI (gcloud) is missing. Install it from https://cloud.google.com/sdk/docs/install, then open a new PowerShell window and run this again.'
    }
    # Only ever replace a folder that holds an earlier copy of this tool.
    if ((Test-Path -LiteralPath $dir) -and -not ((Test-Path -LiteralPath (Join-Path $dir 'setup.sh')) -and
            (Test-Path -LiteralPath (Join-Path $dir 'select-groups.sh')))) {
        throw "$dir exists and isn't a copy of this tool. Move it, or set BW_SYNC_DIR to another folder."
    }

    # Windows PowerShell 5.1 doesn't use TLS 1.2 by default; GitHub requires it.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $parent = Split-Path -Parent $dir
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    $tmp = Join-Path $parent ('.bw-gws-scim-sync.' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'src.zip'
        Write-Host "Downloading $repo ($ref)..."
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "https://codeload.github.com/$repo/zip/$ref" -OutFile $zip
        } catch {
            $token = Get-GitHubToken
            if (-not $token) {
                throw "Couldn't download $repo at `"$ref`".`n  - Check that the version exists: https://github.com/$repo/tags`n  - If the repository isn't public, sign in to GitHub first and run this again:  gh auth login"
            }
            Write-Host 'Public download failed; using your GitHub sign-in (gh).'
            try {
                Invoke-WebRequest -UseBasicParsing -Uri "https://api.github.com/repos/$repo/zipball/$ref" -OutFile $zip `
                    -Headers @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json' }
            } catch {
                throw "Couldn't download $repo at `"$ref`" ($($_.Exception.Message)).`n  - Check that the version exists: https://github.com/$repo/tags"
            }
        }
        $extracted = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $extracted
        $source = @(Get-ChildItem -LiteralPath $extracted -Directory)[0].FullName
        if (-not (Test-Path -LiteralPath (Join-Path $source 'setup.sh'))) { throw "The download doesn't contain the tool." }
        if (-not (Test-Path -LiteralPath (Join-Path $source 'setup.ps1'))) {
            throw "Version $ref has no PowerShell scripts. Use v1.1.0 or later, or Google Cloud Shell (README Step 2)."
        }

        if (Test-Path -LiteralPath $dir) {
            # Keep the Python libraries select-groups.ps1 installed, so it doesn't reinstall them.
            $venv = Join-Path $dir '.venv'
            if (Test-Path -LiteralPath $venv) { Move-Item -LiteralPath $venv -Destination (Join-Path $source '.venv') }
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-Host "Updated $dir to $ref."
        } else {
            Write-Host "Installed in $dir."
        }
        Move-Item -LiteralPath $source -Destination $dir
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $shell = (Get-Process -Id $PID).Path
    $setup = Join-Path $dir 'setup.ps1'
    if ($env:BW_SYNC_SKIP_SETUP -eq '1') {
        Write-Host "Next: & `"$shell`" -ExecutionPolicy Bypass -File `"$setup`""
        return
    }
    Write-Host ''
    # A separate process with -ExecutionPolicy Bypass, so Windows' default script policy doesn't
    # block setup.ps1 (or gcloud's own gcloud.ps1).
    & $shell -NoProfile -ExecutionPolicy Bypass -File $setup
    if ($LASTEXITCODE -ne 0) { throw "setup.ps1 stopped (exit code $LASTEXITCODE). Fix the message above, then run: & `"$shell`" -ExecutionPolicy Bypass -File `"$setup`"" }
}

function Get-GitHubToken {
    # A token for the GitHub API: GH_TOKEN or GITHUB_TOKEN, else the GitHub CLI's sign-in.
    foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return '' }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $token = (& gh auth token 2>$null | Out-String).Trim() } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { return '' }
    $token
}

try {
    Install-BwScimSync
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($PSCommandPath) { exit 1 }  # run as a file (tests, CI); never exit an interactive window
}
