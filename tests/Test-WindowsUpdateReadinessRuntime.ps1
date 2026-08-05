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
    -Message 'LOCALAPPDATA is unavailable for the runtime test.'

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
Assert-Condition -Condition ($allowedDrive -eq 'C:') `
    -Message 'Runtime diagnostics root must be on drive C:.'

$testDirectory = Join-Path $allowedRoot ('test-windows-update-runtime-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null

try {
    $result = & $resolvedScriptPath -Mode Preview -OutputDirectory $testDirectory

    Assert-Condition -Condition (@('Passed', 'Partial') -contains [string]$result.Status) `
        -Message 'Real Windows update path returned an invalid status.'
    Assert-Condition -Condition ($result.Collector -eq 'WindowsUpdateReadiness') `
        -Message 'Unexpected collector name.'
    Assert-Condition -Condition ($result.ScriptVersion -eq '1.0.0') `
        -Message 'Unexpected script version.'
    Assert-Condition -Condition ($result.Mode -eq 'Preview') `
        -Message 'Unexpected runtime mode.'
    Assert-Condition -Condition ([int64]$result.UpdateHistoryEntries -ge 0) `
        -Message 'Update history count is invalid.'
    Assert-Condition -Condition ([int64]$result.PendingRebootIndicators -ge 0) `
        -Message 'Pending reboot count is invalid.'
    Assert-Condition -Condition ([int64]$result.ReportsCreated -eq 3) `
        -Message 'Real path did not create all reports.'

    $manifestFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-windows-update-readiness-local-manifest-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $summaryFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-windows-update-readiness-sanitized-summary-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $htmlFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-windows-update-readiness-panel-*.html' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    Assert-Condition -Condition ($null -ne $manifestFile) -Message 'Runtime manifest was not created.'
    Assert-Condition -Condition ($null -ne $summaryFile) -Message 'Runtime summary was not created.'
    Assert-Condition -Condition ($null -ne $htmlFile) -Message 'Runtime HTML was not created.'

    $summary = [System.IO.File]::ReadAllText($summaryFile.FullName) | ConvertFrom-Json
    Assert-Condition -Condition ($summary.Privacy.SummarySanitized -eq $true) `
        -Message 'Runtime summary is not marked sanitized.'
    Assert-Condition -Condition ($summary.Privacy.ExcludedDriveEAccessed -eq $false) `
        -Message 'Runtime summary incorrectly reports access to drive E:.'
    Assert-Condition -Condition ($summary.Privacy.PendingPathValuesRead -eq $false) `
        -Message 'Runtime summary incorrectly reports reading pending paths.'
    Assert-Condition -Condition ($summary.Scope.QueryHistoryOnly -eq $true) `
        -Message 'Runtime summary does not confirm QueryHistory-only behavior.'
    Assert-Condition -Condition ($summary.Scope.UpdateSearchPerformed -eq $false) `
        -Message 'Runtime summary incorrectly reports an update search.'
    Assert-Condition -Condition ($summary.Scope.UpdatesDownloaded -eq $false) `
        -Message 'Runtime summary incorrectly reports update downloads.'
    Assert-Condition -Condition ($summary.Scope.UpdatesInstalled -eq $false) `
        -Message 'Runtime summary incorrectly reports update installation.'
    Assert-Condition -Condition ($summary.Scope.RebootTriggered -eq $false) `
        -Message 'Runtime summary incorrectly reports a reboot.'
    Assert-Condition -Condition ($summary.Scope.NetworkCollected -eq $false) `
        -Message 'Runtime summary incorrectly reports network collection.'

    [pscustomobject]@{
        Status = 'Passed'
        CollectorStatus = [string]$result.Status
        UpdateHistoryEntries = [int64]$result.UpdateHistoryEntries
        PendingRebootIndicators = [int64]$result.PendingRebootIndicators
        ReportsCreated = [int64]$result.ReportsCreated
        SectionFailures = [int64]$result.SectionFailures
    }
}
finally {
    if ([System.IO.Directory]::Exists($testDirectory)) {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}
