# Lint rules for the PowerShell scripts (CI runs Invoke-ScriptAnalyzer with this file).
@{
    # The scripts talk to the person running them, so Write-Host is intended.
    ExcludeRules = @('PSAvoidUsingWriteHost')
    Rules        = @{
        # Windows PowerShell 5.1 ships with Windows; PowerShell 7 is the current version.
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
    }
}
