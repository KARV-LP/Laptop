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
Assert-Condition -Condition ($parseErrors.Count -eq 0) -Message 'The collector contains PowerShell parse errors.'

$commandAsts = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
$parsedCommands = @($commandAsts | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })

$forbiddenCommands = @(
    'Start-ScheduledTask',
    'Stop-ScheduledTask',
    'Enable-ScheduledTask',
    'Disable-ScheduledTask',
    'Register-ScheduledTask',
    'Unregister-ScheduledTask',
    'Set-ScheduledTask',
    'schtasks.exe',
    'schtasks',
    'Start-Process',
    'Invoke-Expression',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'Remove-Item',
    'Set-Item',
    'New-ItemProperty',
    'Set-ItemProperty',
    'Remove-ItemProperty'
)
$forbiddenFound = @(
    $parsedCommands |
        Where-Object { $forbiddenCommands -contains $_ } |
        Sort-Object -Unique
)
Assert-Condition -Condition ($forbiddenFound.Count -eq 0) `
    -Message ('Forbidden commands found: ' + ($forbiddenFound -join ', '))

$sourceText = [System.IO.File]::ReadAllText($resolvedScriptPath)
Assert-Condition -Condition ($sourceText -match "ValidateSet\('Preview'\)") `
    -Message 'Preview must be the only allowed mode.'
Assert-Condition -Condition ($sourceText -match 'Get-ScheduledTask') `
    -Message 'The collector must use Get-ScheduledTask for real inventory.'
Assert-Condition -Condition ($sourceText -notmatch 'Get-ScheduledTaskInfo') `
    -Message 'Task execution history must remain outside the scope.'

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is unavailable for the safety test.'
}

$diagnosticsRoot = Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'
$testRoot = Join-Path $diagnosticsRoot ('scheduled-task-test-' + [Guid]::NewGuid().ToString('N'))
$inputPath = Join-Path $testRoot 'synthetic-tasks.json'

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

    $syntheticTasks = @(
        [pscustomobject]@{
            TaskName = 'SyntheticWindowsMaintenance'
            TaskPath = '\Microsoft\Windows\Synthetic\'
            State = 'Ready'
            Enabled = $true
            Author = 'Microsoft Corporation'
            UserId = 'SYSTEM'
            Actions = @([pscustomobject]@{ Type = 'Exec'; Execute = 'C:\Windows\System32\synthetic.exe'; Arguments = ''; WorkingDirectory = 'C:\Windows\System32' })
            Triggers = @([pscustomobject]@{ Type = 'MSFT_TaskBootTrigger' })
        },
        [pscustomobject]@{
            TaskName = 'SyntheticKARVBlenderTask'
            TaskPath = '\KARV\'
            State = 'Ready'
            Enabled = $true
            Author = 'KARV'
            UserId = 'SyntheticUser'
            Actions = @([pscustomobject]@{ Type = 'Exec'; Execute = 'C:\Apps\Blender\synthetic.exe'; Arguments = '--safe'; WorkingDirectory = 'C:\Apps\Blender' })
            Triggers = @([pscustomobject]@{ Type = 'MSFT_TaskLogonTrigger' })
        },
        [pscustomobject]@{
            TaskName = 'SyntheticVendorUpdater'
            TaskPath = '\Vendor\'
            State = 'Ready'
            Enabled = $true
            Author = 'Vendor'
            UserId = 'SyntheticUser'
            Actions = @([pscustomobject]@{ Type = 'Exec'; Execute = 'C:\Vendor\synthetic.exe'; Arguments = '/update'; WorkingDirectory = 'C:\Vendor' })
            Triggers = @([pscustomobject]@{ Type = 'MSFT_TaskDailyTrigger' })
        },
        [pscustomobject]@{
            TaskName = 'SyntheticExcludedDriveReference'
            TaskPath = '\Vendor\'
            State = 'Ready'
            Enabled = $true
            Author = 'Vendor'
            UserId = 'SyntheticUser'
            Actions = @([pscustomobject]@{ Type = 'Exec'; Execute = 'E:\Sensitive\synthetic.exe'; Arguments = '--run E:\Sensitive\data'; WorkingDirectory = 'E:\Sensitive' })
            Triggers = @([pscustomobject]@{ Type = 'MSFT_TaskEventTrigger' })
        },
        [pscustomobject]@{
            TaskName = ''
            TaskPath = ''
            State = ''
            Enabled = $true
            Author = ''
            UserId = ''
            Actions = @()
            Triggers = @()
        },
        [pscustomobject]@{
            TaskName = 'SyntheticDisabledTask'
            TaskPath = '\Vendor\'
            State = 'Disabled'
            Enabled = $false
            Author = 'Vendor'
            UserId = 'SyntheticUser'
            Actions = @([pscustomobject]@{ Type = 'Exec'; Execute = 'C:\Vendor\disabled.exe'; Arguments = ''; WorkingDirectory = 'C:\Vendor' })
            Triggers = @([pscustomobject]@{ Type = 'MSFT_TaskDailyTrigger' })
        }
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        $inputPath,
        (ConvertTo-Json -InputObject $syntheticTasks -Depth 10),
        $utf8NoBom
    )

    $result = & $resolvedScriptPath `
        -Mode Preview `
        -OutputDirectory $testRoot `
        -SyntheticInputPath $inputPath

    Assert-Condition -Condition ($result.Status -eq 'Passed') -Message 'Synthetic inventory did not pass.'
    Assert-Condition -Condition ($result.TasksEnumerated -eq 6) `
        -Message ('Unexpected enumerated task count: ' + [string]$result.TasksEnumerated)
    Assert-Condition -Condition ($result.EnabledTasks -eq 5) -Message 'Only five synthetic tasks should be enabled.'
    Assert-Condition -Condition ($result.KarvApplicationPreserve -eq 1) -Message 'Unexpected KARV classification count.'
    Assert-Condition -Condition ($result.SystemSecurityPreserve -eq 1) -Message 'Unexpected system classification count.'
    Assert-Condition -Condition ($result.ThirdPartyReview -eq 1) -Message 'Unexpected third-party classification count.'
    Assert-Condition -Condition ($result.ExcludedDriveReferencePreserve -eq 1) -Message 'Excluded drive reference was not preserved.'
    Assert-Condition -Condition ($result.UnresolvedPreserve -eq 1) -Message 'Unexpected unresolved classification count.'
    Assert-Condition -Condition ($result.SectionFailures -eq 0) -Message 'Synthetic inventory reported section failures.'
    Assert-Condition -Condition ($result.ReportsCreated -eq 2) -Message 'Synthetic inventory must create two reports.'

    $manifestFile = Get-ChildItem -LiteralPath $testRoot -Filter 'karv-scheduled-task-local-manifest-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $summaryFile = Get-ChildItem -LiteralPath $testRoot -Filter 'karv-scheduled-task-sanitized-summary-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    Assert-Condition -Condition ($null -ne $manifestFile) -Message 'Detailed manifest was not created.'
    Assert-Condition -Condition ($null -ne $summaryFile) -Message 'Sanitized summary was not created.'

    $manifestText = [System.IO.File]::ReadAllText($manifestFile.FullName)
    $summaryText = [System.IO.File]::ReadAllText($summaryFile.FullName)
    $manifest = $manifestText | ConvertFrom-Json
    $summary = $summaryText | ConvertFrom-Json

    Assert-Condition -Condition ($manifest.Tasks.Count -eq 5) -Message 'Disabled task appeared in the detailed manifest.'
    Assert-Condition -Condition ($manifestText -notmatch [regex]::Escape('E:\Sensitive')) `
        -Message 'Excluded drive reference leaked into the detailed manifest.'
    Assert-Condition -Condition ($manifestText -match '\[REDACTED_EXCLUDED_DRIVE\]') `
        -Message 'Excluded drive reference was not redacted.'
    Assert-Condition -Condition ($manifestText -notmatch 'SyntheticDisabledTask') `
        -Message 'Disabled task appeared in the detailed manifest.'

    $sensitiveTokens = @(
        'SyntheticWindowsMaintenance',
        'SyntheticKARVBlenderTask',
        'SyntheticVendorUpdater',
        'SyntheticExcludedDriveReference',
        'SyntheticUser',
        'C:\Apps\Blender',
        'C:\Vendor',
        'E:\Sensitive'
    )
    foreach ($token in $sensitiveTokens) {
        Assert-Condition -Condition ($summaryText -notmatch [regex]::Escape($token)) `
            -Message ('Sanitized summary leaked sensitive token: ' + $token)
    }

    Assert-Condition -Condition ($summary.Privacy.SummarySanitized -eq $true) -Message 'Summary sanitization marker is missing.'
    Assert-Condition -Condition ($summary.Privacy.TasksModified -eq $false) -Message 'Task modification marker is incorrect.'
    Assert-Condition -Condition ($summary.Privacy.TasksExecuted -eq $false) -Message 'Task execution marker is incorrect.'
    Assert-Condition -Condition ($summary.Privacy.ExcludedDriveE -eq $true) -Message 'Excluded drive marker is missing.'
    Assert-Condition -Condition ($summary.Privacy.ExcludedDriveReferencesRedacted -eq $true) -Message 'Reference redaction marker is missing.'
    Assert-Condition -Condition ($summary.Summary.TasksEnumerated -eq 6) -Message 'Summary enumerated count is incorrect.'
    Assert-Condition -Condition ($summary.Summary.EnabledTasks -eq 5) -Message 'Summary enabled count is incorrect.'
    Assert-Condition -Condition ($summary.SectionFailures.Count -eq 0) -Message 'Summary contains section failures.'

    $outputRejected = $false
    try {
        & $resolvedScriptPath -Mode Preview -OutputDirectory 'E:\KARV-Test' -SyntheticInputPath $inputPath | Out-Null
    }
    catch {
        $outputRejected = $true
    }
    Assert-Condition -Condition $outputRejected -Message 'Output on drive E: was not rejected.'

    $inputRejected = $false
    try {
        & $resolvedScriptPath -Mode Preview -OutputDirectory $testRoot -SyntheticInputPath 'E:\synthetic-tasks.json' | Out-Null
    }
    catch {
        $inputRejected = $true
    }
    Assert-Condition -Condition $inputRejected -Message 'Synthetic input on drive E: was not rejected.'

    [pscustomobject]@{
        Status = 'Passed'
        ParsedCommands = [int64]$parsedCommands.Count
        ForbiddenFound = [int64]$forbiddenFound.Count
        TasksEnumerated = [int64]$result.TasksEnumerated
        EnabledTasks = [int64]$result.EnabledTasks
        ReportsCreated = [int64]$result.ReportsCreated
        SectionFailures = [int64]$result.SectionFailures
    }
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
