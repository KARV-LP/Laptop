#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($resolvedScript, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    throw ('PowerShell parse errors: ' + ((@($parseErrors) | ForEach-Object { $_.Message }) -join '; '))
}

$commands = @(
    $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$forbiddenCommands = @(
    'Start-Service', 'Stop-Service', 'Restart-Service', 'Set-Service', 'Remove-Service',
    'New-Service', 'Suspend-Service', 'Resume-Service', 'sc.exe', 'net.exe',
    'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Remove-Item',
    'Start-Process', 'Invoke-Command', 'Invoke-WebRequest', 'Invoke-RestMethod'
)
$forbiddenFound = @($commands | Where-Object { $forbiddenCommands -contains $_ } | Select-Object -Unique)
if ($forbiddenFound.Count -ne 0) {
    throw ('Forbidden commands found: ' + ($forbiddenFound -join '; '))
}
if ($commands -notcontains 'Get-CimInstance') { throw 'Expected Get-CimInstance read-only collection command was not found.' }

$sourceText = [System.IO.File]::ReadAllText($resolvedScript)
$requiredMarkers = @(
    "ValidateSet('Preview')",
    "AutomaticServicesOnly = `$true",
    "ServicesModified = `$false",
    "ServicesStartedOrStopped = `$false",
    "ExcludedDriveEAccessed = `$false",
    "ExecutableFilesAccessed = `$false",
    "ExcludedDrivePathsDiscarded = `$true"
)
foreach ($marker in $requiredMarkers) {
    if (-not $sourceText.Contains($marker)) { throw ('Required safety marker missing: ' + $marker) }
}

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA unavailable for test.' }
$testRoot = Join-Path $env:LOCALAPPDATA ('KARV\LaptopDiagnostics\Test-PersistentServices-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

$syntheticServices = @(
    [pscustomobject]@{
        Name = 'WindowsSyntheticService'
        DisplayName = 'Microsoft Windows Synthetic Service'
        PathName = 'C:\Windows\System32\svchost.exe -k synthetic'
        StartMode = 'Auto'
        State = 'Running'
        StartName = 'LocalSystem'
    },
    [pscustomobject]@{
        Name = 'KarvSyntheticService'
        DisplayName = 'Cloudflare KARV Connector'
        PathName = 'C:\Program Files\Cloudflare\karv-agent.exe'
        StartMode = 'Auto'
        State = 'Running'
        StartName = 'NT SERVICE\KarvSynthetic'
    },
    [pscustomobject]@{
        Name = 'VendorSyntheticService'
        DisplayName = 'Vendor Background Agent'
        PathName = 'C:\Program Files\Vendor\agent.exe'
        StartMode = 'Auto'
        State = 'Stopped'
        StartName = '.\VendorAccount'
    },
    [pscustomobject]@{
        Name = 'ExcludedSyntheticService'
        DisplayName = 'Excluded Drive Synthetic Service'
        PathName = 'E:\Legacy\service.exe'
        StartMode = 'Auto'
        State = 'Stopped'
        StartName = 'LocalSystem'
    },
    [pscustomobject]@{
        Name = ''
        DisplayName = ''
        PathName = ''
        StartMode = 'Auto'
        State = ''
        StartName = ''
    },
    [pscustomobject]@{
        Name = 'ManualSyntheticService'
        DisplayName = 'Manual Synthetic Service'
        PathName = 'C:\Program Files\Manual\manual.exe'
        StartMode = 'Manual'
        State = 'Running'
        StartName = 'LocalSystem'
    }
)

try {
    $result = & $resolvedScript -Mode Preview -OutputDirectory $testRoot -InputServices $syntheticServices
    if ($result.Status -ne 'Passed') { throw 'Synthetic execution did not pass.' }
    if ([int64]$result.ServicesEnumerated -ne 6) { throw 'Unexpected enumerated service count.' }
    if ([int64]$result.PersistentServices -ne 5) { throw 'Manual services were not excluded correctly.' }
    if ([int64]$result.SystemSecurityPreserve -ne 1) { throw 'System classification count mismatch.' }
    if ([int64]$result.KarvApplicationPreserve -ne 1) { throw 'KARV classification count mismatch.' }
    if ([int64]$result.ThirdPartyReview -ne 1) { throw 'Third-party classification count mismatch.' }
    if ([int64]$result.ExcludedDriveReferencePreserve -ne 1) { throw 'Excluded-drive classification count mismatch.' }
    if ([int64]$result.UnresolvedPreserve -ne 1) { throw 'Unresolved classification count mismatch.' }
    if ([int64]$result.SectionFailures -ne 0) { throw 'Synthetic execution reported section failures.' }

    $manifestFile = @(Get-ChildItem -LiteralPath $testRoot -Filter 'karv-persistent-services-local-manifest-*.json' -File)
    $summaryFile = @(Get-ChildItem -LiteralPath $testRoot -Filter 'karv-persistent-services-sanitized-summary-*.json' -File)
    if ($manifestFile.Count -ne 1) { throw 'Expected exactly one detailed manifest.' }
    if ($summaryFile.Count -ne 1) { throw 'Expected exactly one sanitized summary.' }

    $manifestText = [System.IO.File]::ReadAllText($manifestFile[0].FullName)
    $summaryText = [System.IO.File]::ReadAllText($summaryFile[0].FullName)
    $manifest = $manifestText | ConvertFrom-Json
    $summary = $summaryText | ConvertFrom-Json

    if (@($manifest.Items).Count -ne 5) { throw 'Detailed manifest must contain only automatic services.' }
    if ($manifestText.Contains('E:\Legacy\service.exe')) { throw 'Excluded drive path leaked into detailed manifest.' }
    $excludedItem = @($manifest.Items | Where-Object { $_.Classification -eq 'ExcludedDriveReferencePreserve' })
    if ($excludedItem.Count -ne 1) { throw 'Excluded-drive item missing.' }
    if ($null -ne $excludedItem[0].PathName) { throw 'Excluded-drive path was not discarded.' }
    if (-not [bool]$excludedItem[0].ReferencesExcludedDriveE) { throw 'Excluded-drive marker missing.' }

    $sensitiveValues = @(
        'WindowsSyntheticService', 'KarvSyntheticService', 'VendorSyntheticService',
        'ExcludedSyntheticService', 'C:\Program Files\Vendor\agent.exe', '.\VendorAccount'
    )
    foreach ($value in $sensitiveValues) {
        if ($summaryText.Contains($value)) { throw ('Sanitized summary leaked sensitive value: ' + $value) }
    }

    if (-not [bool]$summary.Privacy.SummarySanitized) { throw 'Sanitized summary marker missing.' }
    if ([bool]$summary.Privacy.SummaryContainsServiceNames) { throw 'Summary claims to contain service names.' }
    if ([bool]$summary.Privacy.SummaryContainsAccounts) { throw 'Summary claims to contain accounts.' }
    if ([bool]$summary.Privacy.SummaryContainsPaths) { throw 'Summary claims to contain paths.' }
    if ([bool]$summary.Privacy.ServicesModified) { throw 'Summary reports service modification.' }
    if ([bool]$summary.Privacy.ServicesStartedOrStopped) { throw 'Summary reports service state change.' }
    if ([bool]$summary.Privacy.ExcludedDriveEAccessed) { throw 'Summary reports access to excluded drive.' }
    if ([int64]$summary.Summary.PersistentServices -ne 5) { throw 'Sanitized persistent service count mismatch.' }
    if (@($summary.SectionFailures).Count -ne 0) { throw 'Sanitized summary contains section failures.' }

    $rejectedE = $false
    try {
        & $resolvedScript -Mode Preview -OutputDirectory 'E:\KARV-Test' -InputServices $syntheticServices | Out-Null
    }
    catch {
        $rejectedE = $true
    }
    if (-not $rejectedE) { throw 'Drive E output was not rejected.' }

    $rejectedOutsideRoot = $false
    try {
        & $resolvedScript -Mode Preview -OutputDirectory 'C:\KARV-Outside-Test' -InputServices $syntheticServices | Out-Null
    }
    catch {
        $rejectedOutsideRoot = $true
    }
    if (-not $rejectedOutsideRoot) { throw 'Output outside diagnostics root was not rejected.' }

    [pscustomobject]@{
        Status = 'Passed'
        ParsedCommands = [int64]$commands.Count
        ForbiddenFound = [int64]$forbiddenFound.Count
        ServicesEnumerated = 6
        PersistentServices = 5
        ReportsCreated = 2
        SectionFailures = 0
    }
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
