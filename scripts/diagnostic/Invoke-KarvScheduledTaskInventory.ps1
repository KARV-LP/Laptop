#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string]$Mode = 'Preview',

    [string]$OutputDirectory,

    [string]$SyntheticInputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'ScheduledTaskInventory'
$targetDrive = 'C:'
$excludedDrive = 'E:'
$nowUtc = [DateTime]::UtcNow

function Get-ValidatedCDrivePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw ($Purpose + ' does not have a valid drive root.')
    }

    $pathDrive = $root.TrimEnd('\').ToUpperInvariant()
    if ($pathDrive -eq $excludedDrive) {
        throw ($Purpose + ' cannot use the permanently excluded drive E:.')
    }
    if ($pathDrive -ne $targetDrive) {
        throw ($Purpose + ' must remain on drive C:.')
    }

    return $fullPath
}

function Test-IsPathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')

    if ([string]::Equals($normalizedPath, $normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $normalizedPath.StartsWith(
        $normalizedRoot + '\',
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-ExcludedDriveReference {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return $Text.ToUpperInvariant().Contains('E:\')
}

function Get-TriggerCategory {
    param([AllowNull()]$Trigger)

    $typeName = [string](Get-OptionalPropertyValue -Object $Trigger -Name 'Type')
    if ([string]::IsNullOrWhiteSpace($typeName)) {
        $cimClass = Get-OptionalPropertyValue -Object $Trigger -Name 'CimClass'
        if ($null -ne $cimClass) {
            $typeName = [string](Get-OptionalPropertyValue -Object $cimClass -Name 'CimClassName')
        }
    }

    $normalized = $typeName.ToLowerInvariant()
    if ($normalized.Contains('boot')) { return 'Boot' }
    if ($normalized.Contains('logon')) { return 'Logon' }
    if ($normalized.Contains('event')) { return 'Event' }
    if ($normalized.Contains('idle')) { return 'Idle' }
    if ($normalized.Contains('registration')) { return 'Registration' }
    if ($normalized.Contains('sessionstatechange')) { return 'SessionStateChange' }
    if (
        $normalized.Contains('time') -or
        $normalized.Contains('daily') -or
        $normalized.Contains('weekly') -or
        $normalized.Contains('monthly')
    ) { return 'Time' }
    return 'Other'
}

function Get-TaskClassification {
    param(
        [AllowNull()][string]$TaskName,
        [AllowNull()][string]$TaskPath,
        [AllowNull()][string]$Author,
        [AllowNull()][string]$UserId,
        [AllowNull()][string]$ActionText,
        [bool]$HasExcludedDriveReference
    )

    if ($HasExcludedDriveReference) {
        return 'ExcludedDriveReferencePreserve'
    }

    $text = (
        ([string]$TaskName) + ' ' +
        ([string]$TaskPath) + ' ' +
        ([string]$Author) + ' ' +
        ([string]$UserId) + ' ' +
        ([string]$ActionText)
    ).ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'UnresolvedPreserve'
    }

    foreach ($pattern in @(
        'karv', 'blender', 'rhino', 'substance', 'adobe', 'canon',
        'github', 'cloudflare', 'node', 'python'
    )) {
        if ($text.Contains($pattern)) { return 'KarvApplicationPreserve' }
    }

    foreach ($pattern in @(
        '\microsoft\windows\', 'microsoft', 'windows', 'defender',
        'security', 'intel', 'nvidia', 'realtek', 'synaptics', 'driver'
    )) {
        if ($text.Contains($pattern)) { return 'SystemSecurityPreserve' }
    }

    return 'ThirdPartyReview'
}

function Convert-TaskRecord {
    param([Parameter(Mandatory = $true)]$Task)

    $taskName = [string](Get-OptionalPropertyValue -Object $Task -Name 'TaskName')
    $taskPath = [string](Get-OptionalPropertyValue -Object $Task -Name 'TaskPath')
    $state = [string](Get-OptionalPropertyValue -Object $Task -Name 'State')
    $author = [string](Get-OptionalPropertyValue -Object $Task -Name 'Author')

    $principal = Get-OptionalPropertyValue -Object $Task -Name 'Principal'
    $userId = [string](Get-OptionalPropertyValue -Object $principal -Name 'UserId')
    if ([string]::IsNullOrWhiteSpace($userId)) {
        $userId = [string](Get-OptionalPropertyValue -Object $Task -Name 'UserId')
    }

    $settings = Get-OptionalPropertyValue -Object $Task -Name 'Settings'
    $enabledValue = Get-OptionalPropertyValue -Object $settings -Name 'Enabled'
    if ($null -eq $enabledValue) {
        $enabledValue = Get-OptionalPropertyValue -Object $Task -Name 'Enabled'
    }

    $normalizedActions = New-Object System.Collections.Generic.List[object]
    $actionTextParts = New-Object System.Collections.Generic.List[string]
    $hasExcludedDriveReference = $false

    foreach ($action in @(Get-OptionalPropertyValue -Object $Task -Name 'Actions')) {
        if ($null -eq $action) { continue }

        $execute = [string](Get-OptionalPropertyValue -Object $action -Name 'Execute')
        $arguments = [string](Get-OptionalPropertyValue -Object $action -Name 'Arguments')
        $workingDirectory = [string](Get-OptionalPropertyValue -Object $action -Name 'WorkingDirectory')
        $actionType = [string](Get-OptionalPropertyValue -Object $action -Name 'Type')
        if ([string]::IsNullOrWhiteSpace($actionType)) {
            $cimClass = Get-OptionalPropertyValue -Object $action -Name 'CimClass'
            if ($null -ne $cimClass) {
                $actionType = [string](Get-OptionalPropertyValue -Object $cimClass -Name 'CimClassName')
            }
        }

        $combined = $execute + ' ' + $arguments + ' ' + $workingDirectory
        $actionTextParts.Add($combined)
        $actionHasExcludedReference = Test-ExcludedDriveReference -Text $combined
        if ($actionHasExcludedReference) { $hasExcludedDriveReference = $true }

        $normalizedActions.Add([pscustomobject]@{
            Type = $actionType
            Execute = if ($actionHasExcludedReference) { '[REDACTED_EXCLUDED_DRIVE]' } else { $execute }
            Arguments = if ($actionHasExcludedReference) { '[REDACTED_EXCLUDED_DRIVE]' } else { $arguments }
            WorkingDirectory = if ($actionHasExcludedReference) { '[REDACTED_EXCLUDED_DRIVE]' } else { $workingDirectory }
        })
    }

    $triggerCategories = New-Object System.Collections.Generic.List[string]
    foreach ($trigger in @(Get-OptionalPropertyValue -Object $Task -Name 'Triggers')) {
        if ($null -eq $trigger) { continue }
        $triggerCategories.Add((Get-TriggerCategory -Trigger $trigger))
    }
    if ($triggerCategories.Count -eq 0) { $triggerCategories.Add('Other') }

    $classification = Get-TaskClassification `
        -TaskName $taskName `
        -TaskPath $taskPath `
        -Author $author `
        -UserId $userId `
        -ActionText ($actionTextParts -join ' ') `
        -HasExcludedDriveReference $hasExcludedDriveReference

    [pscustomobject]@{
        TaskName = $taskName
        TaskPath = $taskPath
        State = $state
        Enabled = $enabledValue
        Author = $author
        UserId = $userId
        Actions = $normalizedActions.ToArray()
        TriggerCategories = @($triggerCategories.ToArray() | Sort-Object -Unique)
        Classification = $classification
        ExcludedDriveReference = $hasExcludedDriveReference
        Protected = $true
    }
}

if ($Mode -ne 'Preview') {
    throw 'Only Preview mode is permitted in Fase 3C.'
}
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is unavailable.'
}

$allowedOutputRoot = Get-ValidatedCDrivePath `
    -Path (Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics') `
    -Purpose 'AllowedOutputRoot'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = $allowedOutputRoot
}
$validatedOutputDirectory = Get-ValidatedCDrivePath -Path $OutputDirectory -Purpose 'OutputDirectory'
if (-not (Test-IsPathInsideRoot -Path $validatedOutputDirectory -Root $allowedOutputRoot)) {
    throw 'OutputDirectory must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.'
}

$validatedSyntheticInputPath = $null
if (-not [string]::IsNullOrWhiteSpace($SyntheticInputPath)) {
    $validatedSyntheticInputPath = Get-ValidatedCDrivePath `
        -Path $SyntheticInputPath `
        -Purpose 'SyntheticInputPath'
    if (-not (Test-IsPathInsideRoot -Path $validatedSyntheticInputPath -Root $allowedOutputRoot)) {
        throw 'SyntheticInputPath must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.'
    }
}

[System.IO.Directory]::CreateDirectory($validatedOutputDirectory) | Out-Null

$rawTasks = @()
$sectionFailures = New-Object System.Collections.Generic.List[object]
try {
    if ($null -ne $validatedSyntheticInputPath) {
        $parsedTasks = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($validatedSyntheticInputPath))
        $rawTasks = @($parsedTasks | ForEach-Object { $_ })
    }
    else {
        $command = Get-Command -Name 'Get-ScheduledTask' -ErrorAction Stop
        if ($null -eq $command) { throw 'Get-ScheduledTask is unavailable.' }
        $rawTasks = @(Get-ScheduledTask -ErrorAction Stop)
    }
}
catch {
    $sectionFailures.Add([pscustomobject]@{
        Section = 'ScheduledTasks'
        ErrorType = $_.Exception.GetType().Name
    })
}

$classNames = @(
    'KarvApplicationPreserve',
    'SystemSecurityPreserve',
    'ThirdPartyReview',
    'ExcludedDriveReferencePreserve',
    'UnresolvedPreserve'
)
$classMetrics = @{}
foreach ($className in $classNames) { $classMetrics[$className] = 0L }

$triggerNames = @('Boot', 'Logon', 'Time', 'Event', 'Idle', 'Registration', 'SessionStateChange', 'Other')
$triggerMetrics = @{}
foreach ($triggerName in $triggerNames) { $triggerMetrics[$triggerName] = 0L }

$stateMetrics = @{}
$enabledTasks = New-Object System.Collections.Generic.List[object]
foreach ($rawTask in $rawTasks) {
    try {
        $record = Convert-TaskRecord -Task $rawTask
        $isDisabled = [string]::Equals($record.State, 'Disabled', [System.StringComparison]::OrdinalIgnoreCase)
        $isEnabledSetting = -not ($record.Enabled -is [bool] -and $record.Enabled -eq $false)
        if ($isDisabled -or -not $isEnabledSetting) { continue }

        $enabledTasks.Add($record)
        $classMetrics[$record.Classification]++

        $stateName = if ([string]::IsNullOrWhiteSpace($record.State)) { 'Unknown' } else { $record.State }
        if (-not $stateMetrics.ContainsKey($stateName)) { $stateMetrics[$stateName] = 0L }
        $stateMetrics[$stateName]++

        foreach ($triggerCategory in $record.TriggerCategories) {
            if (-not $triggerMetrics.ContainsKey($triggerCategory)) { $triggerMetrics[$triggerCategory] = 0L }
            $triggerMetrics[$triggerCategory]++
        }
    }
    catch {
        $sectionFailures.Add([pscustomobject]@{
            Section = 'TaskRecord'
            ErrorType = $_.Exception.GetType().Name
        })
    }
}

$orderedTasks = @(
    $enabledTasks.ToArray() |
        Sort-Object Classification, TaskPath, TaskName
)

$completedClasses = @(
    $classNames | ForEach-Object {
        [pscustomobject]@{ Name = $_; Tasks = [int64]$classMetrics[$_] }
    }
)
$completedTriggers = @(
    $triggerNames | ForEach-Object {
        [pscustomobject]@{ Name = $_; Tasks = [int64]$triggerMetrics[$_] }
    }
)
$completedStates = @(
    $stateMetrics.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Tasks = [int64]$_.Value } }
)

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$manifestPath = Join-Path $validatedOutputDirectory ('karv-scheduled-task-local-manifest-' + $timestamp + '.json')
$summaryPath = Join-Path $validatedOutputDirectory ('karv-scheduled-task-sanitized-summary-' + $timestamp + '.json')

$manifest = [pscustomobject]@{
    Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    SensitiveLocalData = $true
    LocalOnly = $true
    Scope = [pscustomobject]@{
        EnabledScheduledTasks = $true
        TaskHistoryCollected = $false
        ExecutableContentRead = $false
        ServicesCollected = $false
    }
    Tasks = $orderedTasks
}

$summary = [pscustomobject]@{
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    Privacy = [pscustomobject]@{
        SummarySanitized = $true
        SummaryContainsTaskNames = $false
        SummaryContainsAuthors = $false
        SummaryContainsAccounts = $false
        SummaryContainsCommands = $false
        SummaryContainsPaths = $false
        DetailedManifestContainsSensitiveLocalData = $true
        DetailedManifestLocalOnly = $true
        TasksModified = $false
        TasksExecuted = $false
        FilesOpened = $false
        NetworkCollected = $false
        ExcludedDriveE = $true
        ExcludedDriveReferencesRedacted = $true
    }
    Scope = [pscustomobject]@{
        EnabledScheduledTasks = $true
        TaskHistoryCollected = $false
        ExecutableContentRead = $false
        ServicesCollected = $false
    }
    Summary = [pscustomobject]@{
        TasksEnumerated = [int64]$rawTasks.Count
        EnabledTasks = [int64]$orderedTasks.Count
    }
    Classifications = $completedClasses
    TriggerCategories = $completedTriggers
    States = $completedStates
    SectionFailures = $sectionFailures.ToArray()
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), $utf8NoBom)
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 12), $utf8NoBom)

[pscustomobject]@{
    Status = if ($sectionFailures.Count -eq 0) { 'Passed' } else { 'Partial' }
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    Mode = $Mode
    TasksEnumerated = [int64]$rawTasks.Count
    EnabledTasks = [int64]$orderedTasks.Count
    KarvApplicationPreserve = [int64]$classMetrics['KarvApplicationPreserve']
    SystemSecurityPreserve = [int64]$classMetrics['SystemSecurityPreserve']
    ThirdPartyReview = [int64]$classMetrics['ThirdPartyReview']
    ExcludedDriveReferencePreserve = [int64]$classMetrics['ExcludedDriveReferencePreserve']
    UnresolvedPreserve = [int64]$classMetrics['UnresolvedPreserve']
    SectionFailures = [int64]$sectionFailures.Count
    ReportsCreated = 2
}
