#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

$resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) `
    -Message 'LOCALAPPDATA is unavailable.'

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
Assert-Condition -Condition ($allowedDrive -eq 'C:') `
    -Message 'Runtime test diagnostics root must be on drive C:.'

$testDirectory = Join-Path $allowedRoot ('test-protected-app-registry-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null

try {
    $result = & $resolvedScriptPath -Mode Preview -OutputDirectory $testDirectory

    Assert-Condition -Condition (@('Passed', 'Partial') -contains [string]$result.Status) `
        -Message 'Real registry inventory did not complete.'
    Assert-Condition -Condition ([string]$result.Collector -eq 'ProtectedApplicationInventory') `
        -Message 'Unexpected collector.'
    Assert-Condition -Condition ([string]$result.ScriptVersion -eq '1.0.1') `
        -Message 'Corrected script version was not executed.'
    Assert-Condition -Condition ([string]$result.Mode -eq 'Preview') `
        -Message 'Runtime inventory did not remain in Preview mode.'
    Assert-Condition -Condition ([int64]$result.ReportsCreated -eq 3) `
        -Message 'Runtime inventory did not create three local reports.'

    $manifest = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-protected-applications-local-manifest-*.json' `
        -File | Select-Object -First 1
    $summaryFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-protected-applications-sanitized-summary-*.json' `
        -File | Select-Object -First 1
    $panel = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-protected-applications-panel-*.html' `
        -File | Select-Object -First 1

    Assert-Condition -Condition ($null -ne $manifest) -Message 'Local manifest was not created.'
    Assert-Condition -Condition ($null -ne $summaryFile) -Message 'Sanitized summary was not created.'
    Assert-Condition -Condition ($null -ne $panel) -Message 'Local HTML panel was not created.'

    $summary = [System.IO.File]::ReadAllText($summaryFile.FullName) | ConvertFrom-Json
    Assert-Condition -Condition ($summary.Privacy.SummarySanitized -eq $true) `
        -Message 'Summary is not marked sanitized.'
    Assert-Condition -Condition ($summary.Privacy.ExcludedDriveEAccessed -eq $false) `
        -Message 'Summary incorrectly reports access to drive E:.'
    Assert-Condition -Condition ($summary.Scope.ApplicationsExecuted -eq $false) `
        -Message 'Summary incorrectly reports application execution.'
    Assert-Condition -Condition ($summary.Scope.UpdatesChecked -eq $false) `
        -Message 'Summary incorrectly reports update checks.'

    [pscustomobject]@{
        Status = 'Passed'
        Collector = [string]$result.Collector
        ScriptVersion = [string]$result.ScriptVersion
        ApplicationsEnumerated = [int64]$result.ApplicationsEnumerated
        ProtectedRecords = [int64]$result.ProtectedRecords
        SectionFailures = [int64]$result.SectionFailures
        ReportsCreated = [int64]$result.ReportsCreated
    }
}
finally {
    if ([System.IO.Directory]::Exists($testDirectory)) {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}
