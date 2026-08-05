#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string]$Mode = 'Preview',

    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'WindowsStartupInventory'
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

function Get-StartupClassification {
    param(
        [AllowNull()][string]$EntryName,
        [AllowNull()][string]$CommandOrPath
    )

    $text = (([string]$EntryName) + ' ' + ([string]$CommandOrPath)).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'UnresolvedPreserve'
    }

    $karvPatterns = @(
        'karv', 'blender', 'rhino', 'substance', 'adobe', 'canon',
        'github', 'cloudflare', 'node', 'python'
    )
    foreach ($pattern in $karvPatterns) {
        if ($text.Contains($pattern)) { return 'KarvApplicationPreserve' }
    }

    $systemPatterns = @(
        'microsoft', 'windows', 'securityhealth', 'defender', 'antimalware',
        'onedrive', 'intel', 'nvidia', 'realtek', 'synaptics', 'driver', 'audio'
    )
    foreach ($pattern in $systemPatterns) {
        if ($text.Contains($pattern)) { return 'SystemSecurityPreserve' }
    }

    return 'ThirdPartyReview'
}

function New-Metric {
    return [pscustomobject]@{ Entries = 0L }
}

function Add-ToMetric {
    param([Parameter(Mandatory = $true)]$Metric)
    $Metric.Entries++
}

function Add-SanitizedError {
    param(
        [Parameter(Mandatory = $true)]$ErrorTable,
        [Parameter(Mandatory = $true)][string]$ErrorType
    )

    if (-not $ErrorTable.ContainsKey($ErrorType)) { $ErrorTable[$ErrorType] = 0L }
    $ErrorTable[$ErrorType]++
}

if ($Mode -ne 'Preview') {
    throw 'Only Preview mode is permitted in Fase 3A.'
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

[System.IO.Directory]::CreateDirectory($validatedOutputDirectory) | Out-Null

$classNames = @(
    'KarvApplicationPreserve',
    'SystemSecurityPreserve',
    'ThirdPartyReview',
    'UnresolvedPreserve'
)
$classMetrics = @{}
foreach ($className in $classNames) { $classMetrics[$className] = New-Metric }

$sourceNames = @(
    'RegistryCurrentUser64',
    'RegistryCurrentUser32',
    'RegistryLocalMachine64',
    'RegistryLocalMachine32',
    'StartupCurrentUser',
    'StartupCommon'
)
$sourceMetrics = @{}
foreach ($sourceName in $sourceNames) { $sourceMetrics[$sourceName] = New-Metric }

$manifestItems = New-Object System.Collections.Generic.List[object]
$errorTypes = @{}
$sectionFailures = New-Object System.Collections.Generic.List[object]

function Add-ManifestItem {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Location,
        [AllowNull()][string]$EntryName,
        [AllowNull()][string]$CommandOrPath,
        [AllowNull()][string]$ValueKind,
        [AllowNull()][string]$LastWriteUtc,
        [AllowNull()][string]$ErrorType
    )

    $classification = if ([string]::IsNullOrWhiteSpace($ErrorType)) {
        Get-StartupClassification -EntryName $EntryName -CommandOrPath $CommandOrPath
    }
    else {
        'UnresolvedPreserve'
    }

    $manifestItems.Add([pscustomobject]@{
        Source = $Source
        Scope = $Scope
        Location = $Location
        EntryName = $EntryName
        CommandOrPath = $CommandOrPath
        ValueKind = $ValueKind
        LastWriteUtc = $LastWriteUtc
        Classification = $classification
        ErrorType = $ErrorType
        Protected = $true
    })

    Add-ToMetric -Metric $sourceMetrics[$Source]
    Add-ToMetric -Metric $classMetrics[$classification]
    if (-not [string]::IsNullOrWhiteSpace($ErrorType)) {
        Add-SanitizedError -ErrorTable $errorTypes -ErrorType $ErrorType
    }
}

function Read-RegistryLocation {
    param(
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryHive]$Hive,
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryView]$View,
        [Parameter(Mandatory = $true)][string]$SubKeyPath,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
        $key = $baseKey.OpenSubKey($SubKeyPath, $false)
        if ($null -eq $key) { return }

        foreach ($valueName in @($key.GetValueNames())) {
            try {
                $value = $key.GetValue(
                    $valueName,
                    $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                )
                $valueKind = $key.GetValueKind($valueName).ToString()
                $command = if ($null -eq $value) { '' } else { [string]$value }

                Add-ManifestItem `
                    -Source $Source `
                    -Scope $Scope `
                    -Location $SubKeyPath `
                    -EntryName $valueName `
                    -CommandOrPath $command `
                    -ValueKind $valueKind `
                    -LastWriteUtc $null `
                    -ErrorType $null
            }
            catch {
                Add-ManifestItem `
                    -Source $Source `
                    -Scope $Scope `
                    -Location $SubKeyPath `
                    -EntryName $valueName `
                    -CommandOrPath $null `
                    -ValueKind $null `
                    -LastWriteUtc $null `
                    -ErrorType $_.Exception.GetType().Name
            }
        }
    }
    catch {
        $sectionFailures.Add([pscustomobject]@{
            Section = $Source
            ErrorType = $_.Exception.GetType().Name
        })
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

$registryLocations = @(
    [pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Registry64; Source = 'RegistryCurrentUser64'; Scope = 'CurrentUser' },
    [pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Registry32; Source = 'RegistryCurrentUser32'; Scope = 'CurrentUser' },
    [pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64; Source = 'RegistryLocalMachine64'; Scope = 'LocalMachine' },
    [pscustomobject]@{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32; Source = 'RegistryLocalMachine32'; Scope = 'LocalMachine' }
)
$registrySubKeys = @(
    'Software\Microsoft\Windows\CurrentVersion\Run',
    'Software\Microsoft\Windows\CurrentVersion\RunOnce'
)

foreach ($location in $registryLocations) {
    foreach ($subKey in $registrySubKeys) {
        Read-RegistryLocation `
            -Hive $location.Hive `
            -View $location.View `
            -SubKeyPath $subKey `
            -Source $location.Source `
            -Scope $location.Scope
    }
}

function Read-StartupFolder {
    param(
        [AllowNull()][string]$FolderPath,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Scope
    )

    if ([string]::IsNullOrWhiteSpace($FolderPath)) {
        $sectionFailures.Add([pscustomobject]@{ Section = $Source; ErrorType = 'FolderUnavailable' })
        return
    }

    try {
        $validatedFolderPath = Get-ValidatedCDrivePath -Path $FolderPath -Purpose $Source
        if (-not [System.IO.Directory]::Exists($validatedFolderPath)) { return }

        $directory = [System.IO.DirectoryInfo]$validatedFolderPath
        foreach ($file in @($directory.GetFiles())) {
            try {
                Add-ManifestItem `
                    -Source $Source `
                    -Scope $Scope `
                    -Location $validatedFolderPath `
                    -EntryName $file.Name `
                    -CommandOrPath $file.FullName `
                    -ValueKind $file.Extension `
                    -LastWriteUtc $file.LastWriteTimeUtc.ToString('o') `
                    -ErrorType $null
            }
            catch {
                Add-ManifestItem `
                    -Source $Source `
                    -Scope $Scope `
                    -Location $validatedFolderPath `
                    -EntryName $file.Name `
                    -CommandOrPath $file.FullName `
                    -ValueKind $null `
                    -LastWriteUtc $null `
                    -ErrorType $_.Exception.GetType().Name
            }
        }
    }
    catch {
        $sectionFailures.Add([pscustomobject]@{
            Section = $Source
            ErrorType = $_.Exception.GetType().Name
        })
    }
}

Read-StartupFolder `
    -FolderPath ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) `
    -Source 'StartupCurrentUser' `
    -Scope 'CurrentUser'

Read-StartupFolder `
    -FolderPath ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonStartup)) `
    -Source 'StartupCommon' `
    -Scope 'AllUsers'

$orderedItems = @(
    $manifestItems.ToArray() |
        Sort-Object Classification, Source, EntryName
)

$completedClasses = @(
    $classNames | ForEach-Object {
        [pscustomobject]@{ Name = $_; Entries = $classMetrics[$_].Entries }
    }
)
$completedSources = @(
    $sourceNames | ForEach-Object {
        [pscustomobject]@{ Name = $_; Entries = $sourceMetrics[$_].Entries }
    }
)
$sanitizedErrors = @(
    $errorTypes.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ ErrorType = $_.Name; Count = $_.Value } }
)

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$manifestPath = Join-Path $validatedOutputDirectory ('karv-startup-local-manifest-' + $timestamp + '.json')
$summaryPath = Join-Path $validatedOutputDirectory ('karv-startup-sanitized-summary-' + $timestamp + '.json')

$manifest = [pscustomobject]@{
    Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    SensitiveLocalData = $true
    LocalOnly = $true
    Scope = [pscustomobject]@{
        RegistryRunAndRunOnce = $true
        StartupFolders = $true
        ServicesCollected = $false
        ScheduledTasksCollected = $false
    }
    Items = $orderedItems
}

$summary = [pscustomobject]@{
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    Privacy = [pscustomobject]@{
        SummarySanitized = $true
        SummaryContainsEntryNames = $false
        SummaryContainsCommands = $false
        SummaryContainsPaths = $false
        DetailedManifestContainsSensitiveLocalData = $true
        DetailedManifestLocalOnly = $true
        RegistryModified = $false
        StartupFilesModified = $false
        ProcessesChanged = $false
        NetworkCollected = $false
        ExcludedDriveE = $true
    }
    Scope = [pscustomobject]@{
        RegistryRunAndRunOnce = $true
        StartupFolders = $true
        ServicesCollected = $false
        ScheduledTasksCollected = $false
    }
    Summary = [pscustomobject]@{
        Entries = [int64]$orderedItems.Count
    }
    Classifications = $completedClasses
    Sources = $completedSources
    Errors = $sanitizedErrors
    SectionFailures = $sectionFailures.ToArray()
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10), $utf8NoBom)
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 10), $utf8NoBom)

[pscustomobject]@{
    Status = if ($sectionFailures.Count -eq 0) { 'Passed' } else { 'Partial' }
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    Mode = $Mode
    Entries = [int64]$orderedItems.Count
    KarvApplicationPreserve = $classMetrics['KarvApplicationPreserve'].Entries
    SystemSecurityPreserve = $classMetrics['SystemSecurityPreserve'].Entries
    ThirdPartyReview = $classMetrics['ThirdPartyReview'].Entries
    UnresolvedPreserve = $classMetrics['UnresolvedPreserve'].Entries
    SectionFailures = $sectionFailures.Count
    ReportsCreated = 2
}
