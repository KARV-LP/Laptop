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
    'Start-Process',
    'Invoke-Item',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'Set-ItemProperty',
    'New-ItemProperty',
    'Remove-ItemProperty',
    'Set-Service',
    'Start-Service',
    'Stop-Service',
    'Restart-Service',
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
Assert-Condition -Condition ($scriptText.Contains('QueryHistory')) `
    -Message 'Production script does not contain the expected local QueryHistory call.'

foreach ($pattern in @(
    '(?i)CreateUpdateDownloader',
    '(?i)CreateUpdateInstaller',
    '(?i)\.Search\s*\(',
    '(?i)\.Download\s*\(',
    '(?i)\.Install\s*\(',
    '(?i)AcceptEula',
    '(?i)UsoClient',
    '(?i)wuauclt',
    '(?i)dism\.exe',
    '(?i)sfc\.exe',
    '(?i)shutdown\.exe',
    '(?i)<script',
    '(?i)<form',
    '(?i)<button',
    '(?i)<a\s'
)) {
    Assert-Condition -Condition (-not [regex]::IsMatch($scriptText, $pattern)) `
        -Message ('Forbidden production pattern found: ' + $pattern)
}

Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) `
    -Message 'LOCALAPPDATA is unavailable for the synthetic test.'

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
Assert-Condition -Condition ($allowedDrive -eq 'C:') `
    -Message 'Synthetic diagnostics root must be on drive C:.'

$testDirectory = Join-Path $allowedRoot ('test-windows-update-readiness-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null

try {
    $referenceUtc = [DateTime]::UtcNow
    $snapshot = [pscustomobject]@{
        OperatingSystem = [pscustomobject]@{
            ProductName = 'Synthetic Windows Enterprise'
            DisplayVersion = '99H9'
            EditionId = 'SyntheticEdition'
            InstallationType = 'Client'
            CurrentBuild = '99999'
            UpdateBuildRevision = 321
        }
        PendingRebootIndicators = @(
            [pscustomobject]@{ Name = 'ComponentBasedServicing'; Present = $false },
            [pscustomobject]@{ Name = 'WindowsUpdateRebootRequired'; Present = $true },
            [pscustomobject]@{ Name = 'PendingFileRenameOperations'; Present = $false }
        )
        UpdateHistory = @(
            [pscustomobject]@{
                DateUtc = $referenceUtc.AddDays(-2).ToString('o')
                Title = 'Synthetic Update <One>'
                ResultCode = 2
                OperationCode = 1
                HResult = 0
            },
            [pscustomobject]@{
                DateUtc = $referenceUtc.AddDays(-20).ToString('o')
                Title = 'Synthetic Update Two'
                ResultCode = 2
                OperationCode = 1
                HResult = 0
            },
            [pscustomobject]@{
                DateUtc = $referenceUtc.AddDays(-50).ToString('o')
                Title = 'Synthetic Update Three'
                ResultCode = 3
                OperationCode = 1
                HResult = 1
            },
            [pscustomobject]@{
                DateUtc = $referenceUtc.AddDays(-120).ToString('o')
                Title = 'Synthetic Failed Update'
                ResultCode = 4
                OperationCode = 1
                HResult = -1
            },
            [pscustomobject]@{
                DateUtc = $referenceUtc.AddDays(-220).ToString('o')
                Title = 'Synthetic Aborted Update'
                ResultCode = 5
                OperationCode = 1
                HResult = -2
            },
            [pscustomobject]@{
                DateUtc = $null
                Title = 'Synthetic Unknown Update'
                ResultCode = 0
                OperationCode = 2
                HResult = 0
            }
        )
    }

    $result = & $resolvedScriptPath `
        -Mode Preview `
        -OutputDirectory $testDirectory `
        -InputSnapshot $snapshot

    Assert-Condition -Condition ($result.Status -eq 'Passed') -Message 'Synthetic inventory did not pass.'
    Assert-Condition -Condition ([int64]$result.UpdateHistoryEntries -eq 6) -Message 'Unexpected history count.'
    Assert-Condition -Condition ([int64]$result.Succeeded -eq 2) -Message 'Unexpected succeeded count.'
    Assert-Condition -Condition ([int64]$result.SucceededWithErrors -eq 1) -Message 'Unexpected succeeded-with-errors count.'
    Assert-Condition -Condition ([int64]$result.Failed -eq 1) -Message 'Unexpected failed count.'
    Assert-Condition -Condition ([int64]$result.Aborted -eq 1) -Message 'Unexpected aborted count.'
    Assert-Condition -Condition ([int64]$result.OtherResults -eq 1) -Message 'Unexpected other-result count.'
    Assert-Condition -Condition ($result.PendingReboot -eq $true) -Message 'Pending reboot was not detected.'
    Assert-Condition -Condition ([int64]$result.PendingRebootIndicators -eq 1) `
        -Message 'Unexpected pending-reboot indicator count.'
    Assert-Condition -Condition ([int64]$result.SectionFailures -eq 0) -Message 'Unexpected section failures.'
    Assert-Condition -Condition ([int64]$result.ReportsCreated -eq 3) -Message 'Unexpected report count.'

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

    Assert-Condition -Condition ($null -ne $manifestFile) -Message 'Detailed manifest was not created.'
    Assert-Condition -Condition ($null -ne $summaryFile) -Message 'Sanitized summary was not created.'
    Assert-Condition -Condition ($null -ne $htmlFile) -Message 'Local HTML panel was not created.'

    $manifestText = [System.IO.File]::ReadAllText($manifestFile.FullName)
    $summaryText = [System.IO.File]::ReadAllText($summaryFile.FullName)
    $html = [System.IO.File]::ReadAllText($htmlFile.FullName)
    $manifest = $manifestText | ConvertFrom-Json
    $summary = $summaryText | ConvertFrom-Json
    $manifestTitles = @($manifest.UpdateHistory | ForEach-Object { [string]$_.Title })

    Assert-Condition -Condition ($manifestTitles -contains 'Synthetic Update <One>') `
        -Message 'Detailed manifest does not contain local update details.'
    Assert-Condition -Condition ($html.Contains('Synthetic Update &lt;One&gt;')) `
        -Message 'HTML escaping was not applied.'

    foreach ($sensitiveValue in @(
        'Synthetic Update',
        'Synthetic Windows Enterprise',
        'SyntheticEdition',
        '99999',
        '99H9'
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
        -Message 'Summary incorrectly reports pending path-value reads.'
    Assert-Condition -Condition ($summary.Scope.UpdateSearchPerformed -eq $false) `
        -Message 'Summary incorrectly reports an update search.'
    Assert-Condition -Condition ($summary.Scope.UpdatesDownloaded -eq $false) `
        -Message 'Summary incorrectly reports downloads.'
    Assert-Condition -Condition ($summary.Scope.UpdatesInstalled -eq $false) `
        -Message 'Summary incorrectly reports installations.'
    Assert-Condition -Condition ($summary.Scope.RebootTriggered -eq $false) `
        -Message 'Summary incorrectly reports a reboot.'
    Assert-Condition -Condition ([int64]$summary.Summary.HistoryLast30Days -eq 2) `
        -Message 'Unexpected 30-day history bucket.'
    Assert-Condition -Condition ([int64]$summary.Summary.History31To90Days -eq 1) `
        -Message 'Unexpected 31-90 day history bucket.'
    Assert-Condition -Condition ([int64]$summary.Summary.History91To180Days -eq 1) `
        -Message 'Unexpected 91-180 day history bucket.'
    Assert-Condition -Condition ([int64]$summary.Summary.HistoryOlderThan180Days -eq 1) `
        -Message 'Unexpected older history bucket.'
    Assert-Condition -Condition ([int64]$summary.Summary.HistoryUnknownAge -eq 1) `
        -Message 'Unexpected unknown-age history bucket.'

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
