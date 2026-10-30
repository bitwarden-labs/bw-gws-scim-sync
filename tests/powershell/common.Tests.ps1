# Pester 5 tests for powershell/common.ps1. Run:  Invoke-Pester tests/powershell
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The gcloud mock records calls globally')]
param()
BeforeAll {
    . (Join-Path $PSScriptRoot '../../powershell/common.ps1')
}

Describe 'Merge-EmailList' {
    It 'removes, case-insensitively' {
        Merge-EmailList -Op minus -A 'Eng@acme.com, fin@acme.com' -B 'ENG@acme.com' | Should -Be 'fin@acme.com'
    }
    It 'adds without duplicates, keeping order' {
        Merge-EmailList -Op plus -A 'a@x.com' -B 'A@x.com,c@x.com' | Should -Be 'a@x.com,c@x.com'
    }
    It 'handles empty lists' {
        Merge-EmailList -Op minus -A '' -B 'a@x.com' | Should -Be ''
        Merge-EmailList -Op plus -A '' -B 'b@x.com' | Should -Be 'b@x.com'
        Merge-EmailList -Op minus -A 'a@x.com' -B '' | Should -Be 'a@x.com'
    }
}

Describe 'Split-EmailList' {
    It 'lowercases, trims and drops duplicates and blanks' {
        $emails = Split-EmailList ' A@x.com,,a@x.com , b@x.com '
        $emails | Should -Be @('a@x.com', 'b@x.com')
        $none = Split-EmailList ''
        $none.Count | Should -Be 0
    }
}

Describe 'Get-JobEnvironment' {
    It 'returns plain variables and skips the secret' {
        $json = '{"spec":{"template":{"spec":{"template":{"spec":{"containers":[{"env":[' +
        '{"name":"GOOGLE_GROUPS","value":"a@x.com,b@x.com"},' +
        '{"name":"BW_SCIM_API_KEY","valueFrom":{"secretKeyRef":{"name":"s","key":"latest"}}}]}]}}}}}}'
        $vars = Get-JobEnvironment -Json $json
        $vars['GOOGLE_GROUPS'] | Should -Be 'a@x.com,b@x.com'
        $vars.Contains('BW_SCIM_API_KEY') | Should -BeFalse
    }
    It 'copes with a job without variables' {
        $vars = Get-JobEnvironment -Json '{"spec":{"template":{"spec":{"template":{"spec":{"containers":[{}]}}}}}}'
        $vars.Count | Should -Be 0
    }
}

Describe 'Read-Answer' {
    AfterEach { Remove-Item Env:\BW_TEST_ANSWER -ErrorAction SilentlyContinue }
    It 'uses the environment variable without asking' {
        $env:BW_TEST_ANSWER = 'from-env'
        Mock Read-Host { throw 'should not ask' }
        Read-Answer -Name 'BW_TEST_ANSWER' -Prompt 'Q' -Default 'd' | Should -Be 'from-env'
    }
    It 'takes the default on Enter' {
        Mock Read-Host { '' }
        Read-Answer -Name 'BW_TEST_ANSWER' -Prompt 'Q' -Default 'd' | Should -Be 'd'
    }
    It 'requires a value' {
        Mock Read-Host { '' }
        { Read-Answer -Name 'BW_TEST_ANSWER' -Prompt 'Q' } | Should -Throw 'A value is required.'
    }
}

Describe 'Select-FromList' {
    It 'picks by number, Enter picks the first' {
        Mock Write-Host {}
        Mock Read-Host { '2' }
        Select-FromList -Items @('europe-west1', 'us-central1') | Should -Be 'us-central1'
        Mock Read-Host { '' }
        Select-FromList -Items @('europe-west1', 'us-central1') | Should -Be 'europe-west1'
    }
    It 'rejects numbers outside the list' {
        Mock Write-Host {}
        Mock Read-Host { '3' }
        { Select-FromList -Items @('a', 'b') } | Should -Throw 'Choose a number from the list.'
        Mock Read-Host { 'x' }
        { Select-FromList -Items @('a', 'b') } | Should -Throw 'Choose a number from the list.'
    }
}

Describe 'Invoke-Gcloud' {
    BeforeEach {
        # A function named gcloud wins over the real command, so the tests see what would be run.
        $global:GcloudCalls = New-Object System.Collections.Generic.List[object]
        function global:gcloud {
            $flags = $null
            $path = $null
            $i = [array]::IndexOf($args, '--flags-file')
            if ($i -ge 0) {
                $path = $args[$i + 1]
                $flags = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
            }
            $global:GcloudCalls.Add([pscustomobject]@{ Args = @($args); Flags = $flags; Path = $path })
            if ($args[0] -eq 'fail') { Write-Error 'boom on stderr'; $global:LASTEXITCODE = 2; return }
            'line one'
            $global:LASTEXITCODE = 0
        }
    }
    AfterEach {
        Remove-Item Function:\gcloud -ErrorAction SilentlyContinue
        Remove-Variable GcloudCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'puts option values in a flags file, keeping commas and spaces' {
        $result = Invoke-Gcloud -Words @('run', 'jobs', 'update', 'bw-scim-sync') -Switches @('--quiet') -Options ([ordered]@{
                '--region'          = 'europe-west1'
                '--update-env-vars' = [ordered]@{ GOOGLE_GROUPS = 'a@x.com,b@x.com' }
                '--schedule'        = '0 * * * *'
            })
        $result.Output | Should -Be 'line one'
        $call = $global:GcloudCalls[0]
        $call.Args[0..4] | Should -Be @('run', 'jobs', 'update', 'bw-scim-sync', '--quiet')
        $call.Flags.'--update-env-vars'.GOOGLE_GROUPS | Should -Be 'a@x.com,b@x.com'
        $call.Flags.'--schedule' | Should -Be '0 * * * *'
        Test-Path -LiteralPath $call.Path | Should -BeFalse  # cleaned up
    }
    It 'keeps a one-item list as a list' {
        Invoke-Gcloud -Words @('run', 'jobs', 'update', 'j') -Options @{ '--remove-env-vars' = [string[]]@('DELETE_GROUPS') } | Out-Null
        $global:GcloudCalls[0].Flags.'--remove-env-vars' | Should -Be @('DELETE_GROUPS')
        , $global:GcloudCalls[0].Flags.'--remove-env-vars' | Should -BeOfType [object[]]
    }
    It 'refuses words that a shell could reinterpret' {
        { Invoke-Gcloud -Words @('run', '^;^A=1') } | Should -Throw 'Unsafe gcloud argument*'
        { Invoke-Gcloud -Words @('a b') } | Should -Throw 'Unsafe gcloud argument*'
        { Invoke-Gcloud -Words @('run') -Switches @('--format=json') } | Should -Throw 'Unknown gcloud switch*'
    }
    It 'fails on a non-zero exit code, unless allowed' {
        { Invoke-Gcloud -Words @('fail') 2>$null } | Should -Throw '*exit code 2*'
        $result = Invoke-Gcloud -Words @('fail') -AllowFailure
        $result.ExitCode | Should -Be 2
        $result.ErrorText | Should -BeLike '*boom on stderr*'
    }
}

Describe 'Picker' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '../../powershell/picker.ps1')
        $script:items = @(
            [pscustomobject]@{ Key = 'eng@acme.com'; Label = 'Engineering'; Detail = '3 members' }
            [pscustomobject]@{ Key = 'fin@acme.com'; Label = 'Finance'; Detail = '1 member' }
            [pscustomobject]@{ Key = 'mkt@acme.com'; Label = 'Marketing'; Detail = '0 members' }
        )
    }

    It 'parses numbers and ranges like src/picker.py' {
        $picked = ConvertFrom-PickerSelection -Text '1, 3' -Count 3
        $picked | Should -Be @(0, 2)
        $picked = ConvertFrom-PickerSelection -Text '2-3' -Count 3
        $picked | Should -Be @(1, 2)
        { ConvertFrom-PickerSelection -Text '4' -Count 3 } | Should -Throw "4 isn't between 1 and 3"
        { ConvertFrom-PickerSelection -Text 'x' -Count 3 } | Should -Throw "'x' isn't a number or a range like 5-7"
        { ConvertFrom-PickerSelection -Text '3-1' -Count 3 } | Should -Throw "3-1 isn't between 1 and 3"
    }
    It 'filters by email or name' {
        (Select-PickerItem -Items $script:items -Text 'FIN').Key | Should -Be 'fin@acme.com'
        (Select-PickerItem -Items $script:items -Text 'mkt@').Key | Should -Be 'mkt@acme.com'
        (Select-PickerItem -Items $script:items -Text '').Count | Should -Be 3
    }
    It 'formats rows like src/picker.py' {
        $chosen = New-Object 'System.Collections.Generic.HashSet[string]'
        [void]$chosen.Add('eng@acme.com')
        Format-PickerRow -Item $script:items[0] -Chosen $chosen -KeyWidth 12 |
            Should -Be ('[x] ' + 'Engineering'.PadRight(32) + '  eng@acme.com  3 members')
    }
    It 'keeps saved emails the directory no longer has' {
        $all = Add-MissingCurrent -Items $script:items -Current @('old@acme.com', 'eng@acme.com')
        $all[0].Key | Should -Be 'old@acme.com'
        $all[0].Detail | Should -Be 'not found in the directory'
        $all.Count | Should -Be 4
    }
    It 'toggles, filters and saves in directory order' {
        Mock Write-Host {}
        $script:answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('1', '/mark', '1', '/', 's'))
        Mock Read-Host { $script:answers.Dequeue() }
        $result = Show-Picker -Title 'T' -Items $script:items -Selected @('eng@acme.com', 'fin@acme.com')
        $result | Should -Be @('fin@acme.com', 'mkt@acme.com')
    }
    It 'asks again on an empty line without printing the list again' {
        Mock Write-Host {}
        $script:answers = [System.Collections.Generic.Queue[string]]::new([string[]]@('', '  ', 'q'))
        Mock Read-Host { $script:answers.Dequeue() }
        Show-Picker -Title 'T' -Items $script:items -Selected @() | Should -BeNullOrEmpty
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq "`nT" }
        Should -Invoke Read-Host -Times 3 -Exactly
    }
    It 'returns $null when cancelled or when input runs out' {
        Mock Write-Host {}
        Mock Read-Host { 'q' }
        Show-Picker -Title 'T' -Items $script:items -Selected @() | Should -BeNullOrEmpty
        Mock Read-Host { $null }
        $null -eq (Show-Picker -Title 'T' -Items $script:items -Selected @()) | Should -BeTrue
    }
    It 'saving with nothing selected returns an empty list, not $null' {
        Mock Write-Host {}
        Mock Read-Host { 's' }
        $result = Show-Picker -Title 'T' -Items $script:items -Selected @()
        $null -eq $result | Should -BeFalse
        @($result).Count | Should -Be 0
    }
    It 'reads every page of groups, sorted by name' {
        Mock Invoke-GoogleApi {
            if ($Url -like '*pageToken=p2*') { return [pscustomobject]@{ groups = @([pscustomobject]@{ email = 'A@x.com'; name = 'Alpha'; directMembersCount = '1' }) } }
            [pscustomobject]@{ groups = @([pscustomobject]@{ email = 'z@x.com'; name = 'Zulu'; directMembersCount = '2' }); nextPageToken = 'p2' }
        }
        $groups = Get-DirectoryItem -Kind groups -Token 't'
        $groups.Key | Should -Be @('a@x.com', 'z@x.com')
        $groups.Detail | Should -Be @('1 member', '2 members')
    }
    It 'lists only active users' {
        Mock Invoke-GoogleApi {
            [pscustomobject]@{ users = @(
                    [pscustomobject]@{ primaryEmail = 'b@x.com'; name = [pscustomobject]@{ fullName = 'Bea' } }
                    [pscustomobject]@{ primaryEmail = 's@x.com'; name = [pscustomobject]@{ fullName = 'Sus' }; suspended = $true }
                    [pscustomobject]@{ primaryEmail = 'r@x.com'; name = [pscustomobject]@{ fullName = 'Arch' }; archived = $true }) }
        }
        (Get-DirectoryItem -Kind users -Token 't').Key | Should -Be @('b@x.com')
    }
    It 'prints the dry-run plan like select-groups.sh' {
        $script:printed = New-Object System.Collections.Generic.List[string]
        Mock Write-Host { $script:printed.Add([string]$Object) }
        $plan = [pscustomobject]@{ create_users = @([pscustomobject]@{ email = 'n@x.com'; reason = 'in Eng' }); reactivate = @(); revoke = @()
            delete = @(); adopt_users = @(); groups = @(); delete_groups = @([pscustomobject]@{ group = 'Fin'; reason = 'r' }) }
        Write-DryRunPlan -Entries @([pscustomobject]@{ severity = 'WARNING'; message = 'careful' },
            [pscustomobject]@{ severity = 'INFO'; message = 'Sync plan'; plan = $plan })
        $script:printed | Should -Contain 'WARNING: careful'
        $script:printed | Should -Contain '  Invite   n@x.com: in Eng'
        $script:printed | Should -Contain '  Delete   group Fin: r'
    }
}
