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
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $resolvedScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
Assert-Condition -Condition ($parseErrors.Count -eq 0) -Message 'Production script has PowerShell parse errors.'

$commands = @(
    $ast.FindAll(
        {
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        },
        $true
    ) | ForEach-Object { $_.GetCommandName() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

$forbiddenCommands = @(
    'Restart-Computer',
    'Stop-Computer',
    'Start-Service',
    'Stop-Service',
    'Restart-Service',
    'Set-Service',
    'New-Service',
    'Remove-Service',
    'Start-Process',
    'Invoke-Item',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'Set-ItemProperty',
    'New-ItemProperty',
    'Remove-ItemProperty',
    'Register-ScheduledTask',
    'Unregister-ScheduledTask',
    'Enable-ScheduledTask',
    'Disable-ScheduledTask',
    'Remove-Item',
    'Move-Item',
    'Rename-Item',
    'Copy-Item'
)
$forbiddenFound = @($commands | Where-Object { $forbiddenCommands -contains $_ } | Sort-Object -Unique)
Assert-Condition -Condition ($forbiddenFound.Count -eq 0) `
    -Message ('Forbidden commands found: ' + ($forbiddenFound -join ', '))

$scriptText = [System.IO.File]::ReadAllText($resolvedScriptPath)
foreach ($pattern in @(
    '(?i)CreateUpdateSearcher',
    '(?i)CreateUpdateDownloader',
    '(?i)CreateUpdateInstaller',
    '(?i)\.Search\s*\(',
    '(?i)\.Download\s*\(',
    '(?i)\.Install\s*\(',
    '(?i)UsoClient',
    '(?i)wuauclt',
    '(?i)dism\.exe',
    '(?i)sfc\.exe',
    '(?i)shutdown\.exe',
    '(?i)sc\.exe',
    '(?i)net\s+(start|stop)',
    '(?i)\.GetValue\s*\(',
    '(?i)<script',
    '(?i)<form',
    '(?i)<button',
    '(?i)<a\s'
)) {
    Assert-Condition -Condition (-not [regex]::IsMatch($scriptText, $pattern)) `
        -Message ('Forbidden production pattern found: ' + $pattern)
}

Assert-Condition -Condition ($scriptText.Contains('GetValueNames')) `
    -Message 'Production script does not verify pending value existence without reading content.'
Assert-Condition -Condition ($scriptText.Contains('Get-CimInstance')) `
    -Message 'Production script does not contain the expected read-only service metadata query.'
Assert-Condition -Condition ($scriptText.Contains('Get-WinEvent')) `
    -Message 'Production script does not contain the expected local event metadata query.'

Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) `
    -Message 'LOCALAPPDATA is unavailable for the synthetic test.'

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
Assert-Condition -Condition ($allowedDrive -eq 'C:') `
    -Message 'Synthetic diagnostics root must be on drive C:.'

$testDirectory = Join-Path $allowedRoot ('test-windows-update-operational-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null

try {
    $referenceUtc = [DateTime]::UtcNow
    $snapshot = [pscustomobject]@{
        PendingIndicators = @(
            [pscustomobject]@{
                Name = 'SyntheticIndicatorOne'
                Present = $false
                EvidenceType = 'RegistryKeyExistence'
            },
            [pscustomobject]@{
                Name = 'SyntheticIndicator<Two>'
                Present = $true
                EvidenceType = 'RegistryValueNameExistence'
            },
            [pscustomobject]@{
                Name = 'SyntheticIndicatorThree'
                Present = $false
                EvidenceType = 'RegistryKeyExistence'
            }
        )
        Services = @(
            [pscustomobject]@{ Name = 'SyntheticUpdate'; DisplayName = 'Synthetic Update'; Found = $true; State = 'Running'; StartMode = 'Auto' },
            [pscustomobject]@{ Name = 'SyntheticBits'; DisplayName = 'Synthetic BITS'; Found = $true; State = 'Stopped'; StartMode = 'Manual' },
            [pscustomobject]@{ Name = 'SyntheticUso'; DisplayName = 'Synthetic Orchestrator'; Found = $true; State = 'Running'; StartMode = 'Manual' },
            [pscustomobject]@{ Name = 'SyntheticInstaller'; DisplayName = 'Synthetic Installer'; Found = $true; State = 'Stopped'; StartMode = 'Manual' },
            [pscustomobject]@{ Name = 'SyntheticCrypto'; DisplayName = 'Synthetic Crypto'; Found = $true; State = 'Running'; StartMode = 'Auto' }
        )
        Events = @(
            [pscustomobject]@{ Id = 1001; Level = 4; LevelDisplayName = 'Information'; ProviderName = 'Synthetic Provider'; TimeCreatedUtc = $referenceUtc.AddDays(-1).ToString('o') },
            [pscustomobject]@{ Id = 1002; Level = 2; LevelDisplayName = 'Error'; ProviderName = 'Synthetic Provider'; TimeCreatedUtc = $referenceUtc.AddDays(-5).ToString('o') },
            [pscustomobject]@{ Id = 1003; Level = 3; LevelDisplayName = 'Warning'; ProviderName = 'Synthetic Provider'; TimeCreatedUtc = $referenceUtc.AddDays(-20).ToString('o') },
            [pscustomobject]@{ Id = 1004; Level = 4; LevelDisplayName = 'Information'; ProviderName = 'Synthetic Provider'; TimeCreatedUtc = $referenceUtc.AddDays(-60).ToString('o') },
            [pscustomobject]@{ Id = 1005; Level = 1; LevelDisplayName = 'Critical'; ProviderName = 'Synthetic Provider'; TimeCreatedUtc = $referenceUtc.AddDays(-120).ToString('o') },
            [pscustomobject]@{ Id = 1006; Level = 0; LevelDisplayName = ''; ProviderName = 'Synthetic Provider'; TimeCreatedUtc = $null }
        )
        SectionFailures = @()
    }

    $result = & $resolvedScriptPath `
        -Mode Preview `
        -OutputDirectory $testDirectory `
        -InputSnapshot $snapshot

    Assert-Condition -Condition ($result.Status -eq 'Passed') -Message 'Synthetic diagnostic did not pass.'
    Assert-Condition -Condition ($result.DiagnosticClassification -eq 'RebootPendingReview') `
        -Message 'Unexpected synthetic diagnostic classification.'
    Assert-Condition -Condition ($result.PendingReboot -eq $true) -Message 'Pending reboot was not detected.'
    Assert-Condition -Condition ([int64]$result.PendingRebootIndicators -eq 1) `
        -Message 'Unexpected pending indicator count.'
    Assert-Condition -Condition ([int64]$result.ComponentsExpected -eq 5) `
        -Message 'Unexpected expected component count.'
    Assert-Condition -Condition ([int64]$result.ComponentsFound -eq 5) `
        -Message 'Unexpected found component count.'
    Assert-Condition -Condition ([int64]$result.ComponentsRunning -eq 3) `
        -Message 'Unexpected running component count.'
    Assert-Condition -Condition ([int64]$result.ComponentsStopped -eq 2) `
        -Message 'Unexpected stopped component count.'
    Assert-Condition -Condition ([int64]$result.ComponentsDisabled -eq 0) `
        -Message 'Unexpected disabled component count.'
    Assert-Condition -Condition ([int64]$result.ComponentsMissing -eq 0) `
        -Message 'Unexpected missing component count.'
    Assert-Condition -Condition ([int64]$result.ServiceQueryFailures -eq 0) `
        -Message 'Unexpected service query failure count.'
    Assert-Condition -Condition ([int64]$result.EventEntries -eq 6) `
        -Message 'Unexpected event count.'
    Assert-Condition -Condition ([int64]$result.EventErrors -eq 1) `
        -Message 'Unexpected event error count.'
    Assert-Condition -Condition ([int64]$result.EventWarnings -eq 1) `
        -Message 'Unexpected event warning count.'
    Assert-Condition -Condition ([int64]$result.SectionFailures -eq 0) `
        -Message 'Unexpected section failures.'
    Assert-Condition -Condition ([int64]$result.ReportsCreated -eq 3) `
        -Message 'Unexpected report count.'

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

    Assert-Condition -Condition ($null -ne $manifestFile) -Message 'Detailed manifest was not created.'
    Assert-Condition -Condition ($null -ne $summaryFile) -Message 'Sanitized summary was not created.'
    Assert-Condition -Condition ($null -ne $htmlFile) -Message 'Local HTML panel was not created.'

    $manifestText = [System.IO.File]::ReadAllText($manifestFile.FullName)
    $summaryText = [System.IO.File]::ReadAllText($summaryFile.FullName)
    $html = [System.IO.File]::ReadAllText($htmlFile.FullName)
    $manifest = $manifestText | ConvertFrom-Json
    $summary = $summaryText | ConvertFrom-Json

    Assert-Condition -Condition (@($manifest.PendingIndicators | Where-Object { $_.Name -eq 'SyntheticIndicator<Two>' }).Count -eq 1) `
        -Message 'Detailed manifest does not contain local indicator details.'
    Assert-Condition -Condition (@($manifest.Services | Where-Object { $_.Name -eq 'SyntheticUpdate' }).Count -eq 1) `
        -Message 'Detailed manifest does not contain local service details.'
    Assert-Condition -Condition (@($manifest.Events | Where-Object { $_.Id -eq 1002 }).Count -eq 1) `
        -Message 'Detailed manifest does not contain local event details.'
    Assert-Condition -Condition ($html.Contains('SyntheticIndicator&lt;Two&gt;')) `
        -Message 'HTML escaping was not applied.'

    foreach ($sensitiveValue in @(
        'SyntheticIndicator',
        'SyntheticUpdate',
        'Synthetic Provider',
        '1001',
        '1002'
    )) {
        Assert-Condition -Condition (-not $summaryText.Contains($sensitiveValue)) `
            -Message ('Sensitive value leaked into sanitized summary: ' + $sensitiveValue)
    }

    foreach ($interactiveToken in @('<script', '<form', '<button', '<a ', 'javascript:')) {
        Assert-Condition -Condition (-not $html.ToLowerInvariant().Contains($interactiveToken)) `
            -Message ('Interactive HTML token found: ' + $interactiveToken)
    }

    Assert-Condition -Condition ($summary.Privacy.SummarySanitized -eq $true) `
        -Message 'Summary is not marked sanitized.'
    Assert-Condition -Condition ($summary.Privacy.PendingPathValuesRead -eq $false) `
        -Message 'Summary incorrectly reports path-value reads.'
    Assert-Condition -Condition ($summary.Scope.ServicesChanged -eq $false) `
        -Message 'Summary incorrectly reports service changes.'
    Assert-Condition -Condition ($summary.Scope.UpdateSearchPerformed -eq $false) `
        -Message 'Summary incorrectly reports update search.'
    Assert-Condition -Condition ($summary.Scope.RebootTriggered -eq $false) `
        -Message 'Summary incorrectly reports reboot.'
    Assert-Condition -Condition ([int64]$summary.Summary.EventCritical -eq 1) `
        -Message 'Unexpected critical event count.'
    Assert-Condition -Condition ([int64]$summary.Summary.EventInformation -eq 2) `
        -Message 'Unexpected informational event count.'
    Assert-Condition -Condition ([int64]$summary.Summary.EventsLast7Days -eq 2) `
        -Message 'Unexpected seven-day event count.'
    Assert-Condition -Condition ([int64]$summary.Summary.EventsLast30Days -eq 3) `
        -Message 'Unexpected thirty-day event count.'
    Assert-Condition -Condition ([int64]$summary.Summary.Events31To90Days -eq 1) `
        -Message 'Unexpected 31-90-day event count.'
    Assert-Condition -Condition ([int64]$summary.Summary.EventsOlderThan90Days -eq 1) `
        -Message 'Unexpected older event count.'
    Assert-Condition -Condition ([int64]$summary.Summary.EventsUnknownAge -eq 1) `
        -Message 'Unexpected unknown-age event count.'

    $outsideRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Preview `
            -OutputDirectory ('C:\KARV-Outside-' + [Guid]::NewGuid().ToString('N')) `
            -InputSnapshot $snapshot | Out-Null
    }
    catch {
        $outsideRejected = $true
    }
    Assert-Condition -Condition $outsideRejected -Message 'Output outside approved root was not rejected.'

    $excludedDriveRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Preview `
            -OutputDirectory 'E:\KARV-Never-Access' `
            -InputSnapshot $snapshot | Out-Null
    }
    catch {
        $excludedDriveRejected = $true
    }
    Assert-Condition -Condition $excludedDriveRejected -Message 'Output on drive E: was not rejected.'

    $applyRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Apply `
            -OutputDirectory $testDirectory `
            -InputSnapshot $snapshot | Out-Null
    }
    catch {
        $applyRejected = $true
    }
    Assert-Condition -Condition $applyRejected -Message 'Apply mode was not rejected.'

    [pscustomobject]@{
        Status = 'Passed'
        ParsedCommands = [int64]$commands.Count
        ForbiddenFound = [int64]$forbiddenFound.Count
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
