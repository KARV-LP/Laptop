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
Assert-Condition -Condition ([System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant() -eq 'C:') `
    -Message 'Runtime diagnostics root must be on drive C:.'

$testDirectory = Join-Path $allowedRoot ('test-windows-update-operational-runtime-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null

try {
    $result = & $resolvedScriptPath -Mode Preview -OutputDirectory $testDirectory

    Assert-Condition -Condition ($result.Status -in @('Passed', 'Partial')) `
        -Message 'Real read-only diagnostic returned an invalid status.'
    Assert-Condition -Condition ($result.DiagnosticClassification -in @(
        'Operational',
        'RebootPendingReview',
        'DegradedReview',
        'InsufficientDataReview'
    )) -Message 'Real read-only diagnostic returned an invalid classification.'
    Assert-Condition -Condition ([int64]$result.ComponentsExpected -eq 5) `
        -Message 'Unexpected expected component count.'
    Assert-Condition -Condition ([int64]$result.ComponentsFound -ge 0 -and [int64]$result.ComponentsFound -le 5) `
        -Message 'Invalid found component count.'
    Assert-Condition -Condition ([int64]$result.PendingRebootIndicators -ge 0 -and [int64]$result.PendingRebootIndicators -le 3) `
        -Message 'Invalid pending indicator count.'
    Assert-Condition -Condition ([int64]$result.EventEntries -ge 0 -and [int64]$result.EventEntries -le 200) `
        -Message 'Invalid event count.'
    Assert-Condition -Condition ([int64]$result.ReportsCreated -eq 3) `
        -Message 'Real read-only diagnostic did not create three reports.'

    $manifestFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-windows-update-operational-local-manifest-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $summaryFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-windows-update-operational-sanitized-summary-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $htmlFile = Get-ChildItem -LiteralPath $testDirectory `
        -Filter 'karv-windows-update-operational-panel-*.html' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    Assert-Condition -Condition ($null -ne $manifestFile) -Message 'Runtime manifest was not created.'
    Assert-Condition -Condition ($null -ne $summaryFile) -Message 'Runtime summary was not created.'
    Assert-Condition -Condition ($null -ne $htmlFile) -Message 'Runtime HTML was not created.'

    $manifest = [System.IO.File]::ReadAllText($manifestFile.FullName) | ConvertFrom-Json
    $summary = [System.IO.File]::ReadAllText($summaryFile.FullName) | ConvertFrom-Json

    Assert-Condition -Condition ($manifest.SensitiveLocalData -eq $true) `
        -Message 'Runtime manifest is not marked sensitive.'
    Assert-Condition -Condition ($manifest.LocalOnly -eq $true) `
        -Message 'Runtime manifest is not marked local-only.'
    Assert-Condition -Condition ($summary.Privacy.SummarySanitized -eq $true) `
        -Message 'Runtime summary is not marked sanitized.'
    Assert-Condition -Condition ($summary.Privacy.PendingPathValuesRead -eq $false) `
        -Message 'Runtime summary incorrectly reports path-value reads.'
    Assert-Condition -Condition ($summary.Privacy.ExcludedDriveEAccessed -eq $false) `
        -Message 'Runtime summary incorrectly reports access to drive E:.'
    Assert-Condition -Condition ($summary.Scope.EventMessagesRead -eq $false) `
        -Message 'Runtime summary incorrectly reports event message reads.'
    Assert-Condition -Condition ($summary.Scope.ServicesChanged -eq $false) `
        -Message 'Runtime summary incorrectly reports service changes.'
    Assert-Condition -Condition ($summary.Scope.UpdateSearchPerformed -eq $false) `
        -Message 'Runtime summary incorrectly reports update search.'
    Assert-Condition -Condition ($summary.Scope.RebootTriggered -eq $false) `
        -Message 'Runtime summary incorrectly reports reboot.'

    [pscustomobject]@{
        Status = 'Passed'
        RuntimeCollectorStatus = [string]$result.Status
        DiagnosticClassification = [string]$result.DiagnosticClassification
        PendingRebootIndicators = [int64]$result.PendingRebootIndicators
        ComponentsFound = [int64]$result.ComponentsFound
        EventEntries = [int64]$result.EventEntries
        ReportsCreated = [int64]$result.ReportsCreated
        SectionFailures = [int64]$result.SectionFailures
    }
}
finally {
    if ([System.IO.Directory]::Exists($testDirectory)) {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}
