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

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), $utf8NoBom)
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
    'Get-ScheduledTask',
    'Get-ScheduledTaskInfo',
    'Get-CimInstance',
    'Get-WmiObject',
    'Get-Service',
    'Start-ScheduledTask',
    'Stop-ScheduledTask',
    'Enable-ScheduledTask',
    'Disable-ScheduledTask',
    'Register-ScheduledTask',
    'Unregister-ScheduledTask',
    'Set-ScheduledTask',
    'Start-Service',
    'Stop-Service',
    'Restart-Service',
    'Set-Service',
    'New-Service',
    'Remove-Service',
    'Get-ItemProperty',
    'Set-ItemProperty',
    'New-ItemProperty',
    'Remove-ItemProperty',
    'Start-Process',
    'Invoke-Item',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'Copy-Item',
    'Move-Item',
    'Rename-Item',
    'Remove-Item'
)
$forbiddenFound = @($commands | Where-Object { $forbiddenCommands -contains $_ } | Sort-Object -Unique)
Assert-Condition -Condition ($forbiddenFound.Count -eq 0) `
    -Message ('Forbidden commands found: ' + ($forbiddenFound -join ', '))

$scriptText = [System.IO.File]::ReadAllText($resolvedScriptPath)
foreach ($forbiddenText in @(
    'SafeToDisable',
    'schtasks.exe',
    'javascript:',
    '<script',
    '<form',
    '<button',
    '<a '
)) {
    Assert-Condition -Condition (-not $scriptText.Contains($forbiddenText)) `
        -Message ('Forbidden production text found: ' + $forbiddenText)
}

Assert-Condition -Condition (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) `
    -Message 'LOCALAPPDATA is unavailable for the synthetic test.'

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
Assert-Condition -Condition ($allowedDrive -eq 'C:') -Message 'Synthetic test diagnostics root must be on drive C:.'

$testDirectory = Join-Path $allowedRoot ('test-persistence-triage-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null

try {
    $startupManifestPath = Join-Path $testDirectory 'karv-startup-local-manifest-20990101-010101.json'
    $servicesManifestPath = Join-Path $testDirectory 'karv-persistent-services-local-manifest-20990101-010102.json'
    $tasksManifestPath = Join-Path $testDirectory 'karv-scheduled-task-local-manifest-20990101-010103.json'

    $startupManifest = [pscustomobject]@{
        Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
        Collector = 'WindowsStartupInventory'
        ScriptVersion = '1.0.0'
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Mode = 'Preview'
        SensitiveLocalData = $true
        LocalOnly = $true
        Items = @(
            [pscustomobject]@{
                Source = 'RegistryCurrentUser64'
                Scope = 'CurrentUser'
                Location = 'Synthetic'
                EntryName = 'Vendor <One>'
                CommandOrPath = 'C:\Synthetic\vendor-one.exe --start'
                Classification = 'ThirdPartyReview'
                Protected = $true
            },
            [pscustomobject]@{
                Source = 'StartupCurrentUser'
                Scope = 'CurrentUser'
                Location = 'Synthetic'
                EntryName = 'Vendor Two'
                CommandOrPath = 'C:\Synthetic\vendor-two.lnk'
                Classification = 'ThirdPartyReview'
                Protected = $true
            },
            [pscustomobject]@{
                Source = 'RegistryLocalMachine64'
                Scope = 'LocalMachine'
                Location = 'Synthetic'
                EntryName = 'Windows Synthetic'
                CommandOrPath = 'C:\Windows\synthetic.exe'
                Classification = 'SystemSecurityPreserve'
                Protected = $true
            },
            [pscustomobject]@{
                Source = 'RegistryCurrentUser64'
                Scope = 'CurrentUser'
                Location = 'Synthetic'
                EntryName = 'Excluded Synthetic'
                CommandOrPath = 'E:\Excluded\never-read.exe'
                Classification = 'ThirdPartyReview'
                Protected = $true
            }
        )
    }

    $servicesManifest = [pscustomobject]@{
        Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
        Collector = 'PersistentServiceInventory'
        ScriptVersion = '1.0.0'
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Mode = 'Preview'
        SensitiveLocalData = $true
        LocalOnly = $true
        Items = @(
            [pscustomobject]@{
                Name = 'VendorService'
                DisplayName = 'Vendor Service'
                StartMode = 'Auto'
                State = 'Running'
                StartName = 'SyntheticAccount'
                PathName = 'C:\Synthetic\vendor-service.exe'
                Classification = 'ThirdPartyReview'
                Protected = $true
            },
            [pscustomobject]@{
                Name = 'ProtectedService'
                DisplayName = 'Protected Service'
                StartMode = 'Auto'
                State = 'Running'
                StartName = 'LocalSystem'
                PathName = 'C:\Windows\protected.exe'
                Classification = 'SystemSecurityPreserve'
                Protected = $true
            },
            [pscustomobject]@{
                Name = 'UnprotectedVendor'
                DisplayName = 'Unprotected Vendor'
                StartMode = 'Auto'
                State = 'Stopped'
                StartName = 'SyntheticAccount'
                PathName = 'C:\Synthetic\unprotected.exe'
                Classification = 'ThirdPartyReview'
                Protected = $false
            }
        )
    }

    $tasksManifest = [pscustomobject]@{
        Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
        Collector = 'ScheduledTaskInventory'
        ScriptVersion = '1.0.0'
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Mode = 'Preview'
        SensitiveLocalData = $true
        LocalOnly = $true
        Tasks = @(
            [pscustomobject]@{
                TaskName = 'Vendor Task One'
                TaskPath = '\Synthetic\'
                State = 'Ready'
                Author = 'Synthetic Author'
                UserId = 'SyntheticUser'
                Actions = @(
                    [pscustomobject]@{
                        Type = 'Exec'
                        Execute = 'C:\Synthetic\task-one.exe'
                        Arguments = '--run'
                        WorkingDirectory = 'C:\Synthetic'
                    }
                )
                TriggerCategories = @('Logon')
                Classification = 'ThirdPartyReview'
                Protected = $true
            },
            [pscustomobject]@{
                TaskName = 'Vendor Task Two'
                TaskPath = '\Synthetic\'
                State = 'Ready'
                Author = 'Synthetic Author'
                UserId = 'SyntheticUser'
                Actions = @(
                    [pscustomobject]@{
                        Type = 'Exec'
                        Execute = 'C:\Synthetic\task-two.exe'
                        Arguments = '--run'
                        WorkingDirectory = 'C:\Synthetic'
                    }
                )
                TriggerCategories = @('Time', 'Event')
                Classification = 'ThirdPartyReview'
                Protected = $true
            },
            [pscustomobject]@{
                TaskName = 'KARV Protected Task'
                TaskPath = '\KARV\'
                State = 'Ready'
                Author = 'KARV'
                UserId = 'SyntheticUser'
                Actions = @()
                TriggerCategories = @('Logon')
                Classification = 'KarvApplicationPreserve'
                Protected = $true
            }
        )
    }

    Write-JsonFile -Path $startupManifestPath -Value $startupManifest
    Write-JsonFile -Path $servicesManifestPath -Value $servicesManifest
    Write-JsonFile -Path $tasksManifestPath -Value $tasksManifest

    $result = & $resolvedScriptPath `
        -Mode Preview `
        -InputDirectory $testDirectory `
        -OutputDirectory $testDirectory

    Assert-Condition -Condition ($result.Status -eq 'Passed') -Message 'Synthetic panel did not pass.'
    Assert-Condition -Condition ([int64]$result.ReviewItems -eq 5) -Message 'Unexpected review item count.'
    Assert-Condition -Condition ([int64]$result.StartupItems -eq 2) -Message 'Unexpected startup review count.'
    Assert-Condition -Condition ([int64]$result.ServiceItems -eq 1) -Message 'Unexpected service review count.'
    Assert-Condition -Condition ([int64]$result.ScheduledTaskItems -eq 2) -Message 'Unexpected task review count.'
    Assert-Condition -Condition ([int64]$result.ExcludedDriveReferencesSkipped -eq 1) `
        -Message 'Unexpected excluded-drive skip count.'
    Assert-Condition -Condition ([int64]$result.SectionFailures -eq 0) -Message 'Unexpected section failures.'
    Assert-Condition -Condition ([int64]$result.ReportsCreated -eq 2) -Message 'Unexpected report count.'

    $htmlFile = Get-ChildItem -LiteralPath $testDirectory -Filter 'karv-persistence-triage-panel-*.html' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $summaryFile = Get-ChildItem -LiteralPath $testDirectory -Filter 'karv-persistence-triage-sanitized-summary-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    Assert-Condition -Condition ($null -ne $htmlFile) -Message 'Local HTML panel was not created.'
    Assert-Condition -Condition ($null -ne $summaryFile) -Message 'Sanitized summary was not created.'

    $html = [System.IO.File]::ReadAllText($htmlFile.FullName)
    $summaryText = [System.IO.File]::ReadAllText($summaryFile.FullName)
    $summary = $summaryText | ConvertFrom-Json

    Assert-Condition -Condition ($html.Contains('Vendor &lt;One&gt;')) -Message 'HTML escaping was not applied.'
    Assert-Condition -Condition ($html.Contains('Vendor Service')) -Message 'Service review data is absent from local HTML.'
    Assert-Condition -Condition ($html.Contains('Vendor Task One')) -Message 'Task review data is absent from local HTML.'
    Assert-Condition -Condition (-not $html.Contains('Excluded Synthetic')) `
        -Message 'Excluded-drive item leaked into local HTML.'
    Assert-Condition -Condition (-not $html.Contains('E:\Excluded')) `
        -Message 'Excluded-drive path leaked into local HTML.'

    foreach ($interactiveToken in @('<script', '<form', '<button', '<a ', 'javascript:')) {
        Assert-Condition -Condition (-not $html.ToLowerInvariant().Contains($interactiveToken)) `
            -Message ('Interactive HTML token found: ' + $interactiveToken)
    }

    foreach ($sensitiveValue in @(
        'Vendor <One>',
        'Vendor Service',
        'Vendor Task One',
        'SyntheticAccount',
        'C:\Synthetic',
        $startupManifestPath,
        $servicesManifestPath,
        $tasksManifestPath
    )) {
        Assert-Condition -Condition (-not $summaryText.Contains($sensitiveValue)) `
            -Message ('Sensitive value leaked into sanitized summary: ' + $sensitiveValue)
    }

    Assert-Condition -Condition ($summary.Privacy.SummarySanitized -eq $true) `
        -Message 'Summary is not marked sanitized.'
    Assert-Condition -Condition ([int64]$summary.Privacy.ExcludedDriveReferencesSkipped -eq 1) `
        -Message 'Sanitized summary excluded-drive count is incorrect.'
    Assert-Condition -Condition ($summary.Scope.SourceManifestsAutoDetected -eq $true) `
        -Message 'Automatic source manifest detection was not recorded.'
    Assert-Condition -Condition ($summary.Scope.WindowsReenumerated -eq $false) `
        -Message 'Summary incorrectly reports Windows reenumeration.'
    Assert-Condition -Condition ($summary.Scope.ActionsAvailable -eq $false) `
        -Message 'Summary incorrectly exposes actions.'

    $outsideRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Preview `
            -InputDirectory $testDirectory `
            -OutputDirectory ('C:\KARV-Outside-' + [Guid]::NewGuid().ToString('N')) | Out-Null
    }
    catch {
        $outsideRejected = $true
    }
    Assert-Condition -Condition $outsideRejected -Message 'Output outside approved diagnostics root was not rejected.'

    $excludedDriveRejected = $false
    try {
        & $resolvedScriptPath `
            -Mode Preview `
            -InputDirectory 'E:\KARV-Never-Access' `
            -OutputDirectory $testDirectory | Out-Null
    }
    catch {
        $excludedDriveRejected = $true
    }
    Assert-Condition -Condition $excludedDriveRejected -Message 'Input on drive E: was not rejected.'

    [pscustomobject]@{
        Status = 'Passed'
        ParsedCommands = [int64]$commands.Count
        ForbiddenFound = [int64]$forbiddenFound.Count
        ReviewItems = [int64]$result.ReviewItems
        StartupItems = [int64]$result.StartupItems
        ServiceItems = [int64]$result.ServiceItems
        ScheduledTaskItems = [int64]$result.ScheduledTaskItems
        ExcludedDriveReferencesSkipped = [int64]$result.ExcludedDriveReferencesSkipped
        ReportsCreated = [int64]$result.ReportsCreated
        SectionFailures = [int64]$result.SectionFailures
    }
}
finally {
    if ([System.IO.Directory]::Exists($testDirectory)) {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}
