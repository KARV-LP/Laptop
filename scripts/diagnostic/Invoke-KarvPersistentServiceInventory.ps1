#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string]$Mode = 'Preview',

    [string]$OutputDirectory,

    [Parameter(DontShow = $true)]
    [object[]]$InputServices
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'PersistentServiceInventory'
$nowUtc = [DateTime]::UtcNow

function Get-ValidatedOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedRoot
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'Output path has no valid drive root.' }

    $drive = $root.TrimEnd('\').ToUpperInvariant()
    if ($drive -eq 'E:') { throw 'Drive E: is permanently excluded.' }
    if ($drive -ne 'C:') { throw 'Output must remain on drive C:.' }

    $normalizedRoot = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    $normalizedPath = $fullPath.TrimEnd('\')
    $inside = [string]::Equals($normalizedRoot, $normalizedPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.StartsWith($normalizedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { throw 'Output must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.' }

    return $fullPath
}

function Test-ExcludedDriveReference {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch($Text, '(?i)(^|[\s"''])E:\\')
}

function Get-ServiceClassification {
    param(
        [AllowNull()][string]$Name,
        [AllowNull()][string]$DisplayName,
        [AllowNull()][string]$PathName
    )

    if (Test-ExcludedDriveReference -Text $PathName) {
        return 'ExcludedDriveReferencePreserve'
    }

    $text = (([string]$Name) + ' ' + ([string]$DisplayName) + ' ' + ([string]$PathName)).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) { return 'UnresolvedPreserve' }

    $karvPatterns = @('karv', 'blender', 'rhino', 'substance', 'adobe', 'canon', 'github', 'cloudflare')
    foreach ($pattern in $karvPatterns) {
        if ($text.Contains($pattern)) { return 'KarvApplicationPreserve' }
    }

    $systemPatterns = @(
        '\windows\', 'microsoft', 'windows', 'defender', 'security', 'antimalware',
        'intel', 'nvidia', 'realtek', 'synaptics', 'driver', 'audio', 'wlan', 'bluetooth'
    )
    foreach ($pattern in $systemPatterns) {
        if ($text.Contains($pattern)) { return 'SystemSecurityPreserve' }
    }

    return 'ThirdPartyReview'
}

function New-CounterTable {
    param([string[]]$Names)
    $table = @{}
    foreach ($name in $Names) { $table[$name] = 0L }
    return $table
}

if ($Mode -ne 'Preview') { throw 'Only Preview mode is permitted in Fase 3B.' }
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedRootDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
if ($allowedRootDrive -ne 'C:') { throw 'LOCALAPPDATA diagnostics root must be on drive C:.' }

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = $allowedRoot }
$validatedOutput = Get-ValidatedOutputPath -Path $OutputDirectory -AllowedRoot $allowedRoot
[System.IO.Directory]::CreateDirectory($validatedOutput) | Out-Null

$services = if ($PSBoundParameters.ContainsKey('InputServices')) {
    @($InputServices)
}
else {
    @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
}

$classNames = @(
    'KarvApplicationPreserve',
    'SystemSecurityPreserve',
    'ThirdPartyReview',
    'ExcludedDriveReferencePreserve',
    'UnresolvedPreserve'
)
$classCounts = New-CounterTable -Names $classNames
$stateCounts = @{}
$accountCounts = @{}
$items = New-Object System.Collections.Generic.List[object]
$sectionFailures = New-Object System.Collections.Generic.List[object]

foreach ($service in $services) {
    try {
        $startMode = [string]$service.StartMode
        if (-not [string]::Equals($startMode, 'Auto', [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        $name = [string]$service.Name
        $displayName = [string]$service.DisplayName
        $pathName = [string]$service.PathName
        $state = [string]$service.State
        $startName = [string]$service.StartName
        $classification = Get-ServiceClassification -Name $name -DisplayName $displayName -PathName $pathName
        $referencesExcludedDrive = Test-ExcludedDriveReference -Text $pathName

        $storedPath = if ($referencesExcludedDrive) { $null } else { $pathName }
        $storedName = if ([string]::IsNullOrWhiteSpace($name)) { $null } else { $name }
        $storedDisplayName = if ([string]::IsNullOrWhiteSpace($displayName)) { $null } else { $displayName }
        $storedAccount = if ([string]::IsNullOrWhiteSpace($startName)) { $null } else { $startName }

        $items.Add([pscustomobject]@{
            Name = $storedName
            DisplayName = $storedDisplayName
            StartMode = 'Auto'
            State = $state
            StartName = $storedAccount
            PathName = $storedPath
            Classification = $classification
            ReferencesExcludedDriveE = $referencesExcludedDrive
            Protected = $true
        })

        $classCounts[$classification]++
        $stateKey = if ([string]::IsNullOrWhiteSpace($state)) { 'Unknown' } else { $state }
        if (-not $stateCounts.ContainsKey($stateKey)) { $stateCounts[$stateKey] = 0L }
        $stateCounts[$stateKey]++

        $accountCategory = if ([string]::IsNullOrWhiteSpace($startName)) {
            'Unknown'
        }
        elseif ($startName -match '^(?i)(LocalSystem|NT AUTHORITY\\LocalService|NT AUTHORITY\\NetworkService)$') {
            'BuiltIn'
        }
        elseif ($startName -match '^(?i)NT SERVICE\\') {
            'VirtualServiceAccount'
        }
        else {
            'OtherAccount'
        }
        if (-not $accountCounts.ContainsKey($accountCategory)) { $accountCounts[$accountCategory] = 0L }
        $accountCounts[$accountCategory]++
    }
    catch {
        $sectionFailures.Add([pscustomobject]@{
            Section = 'ServiceItem'
            ErrorType = $_.Exception.GetType().Name
        })
    }
}

$orderedItems = @($items.ToArray() | Sort-Object Classification, State, Name)
$orderedClasses = @($classNames | ForEach-Object { [pscustomobject]@{ Name = $_; Services = [int64]$classCounts[$_] } })
$orderedStates = @($stateCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Services = [int64]$_.Value } })
$orderedAccounts = @($accountCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Services = [int64]$_.Value } })

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$manifestPath = Join-Path $validatedOutput ('karv-persistent-services-local-manifest-' + $timestamp + '.json')
$summaryPath = Join-Path $validatedOutput ('karv-persistent-services-sanitized-summary-' + $timestamp + '.json')

$manifest = [pscustomobject]@{
    Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    SensitiveLocalData = $true
    LocalOnly = $true
    Scope = [pscustomobject]@{
        Win32ServiceMetadata = $true
        AutomaticServicesOnly = $true
        ExecutableFilesAccessed = $false
        DriversCollected = $false
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
        SummaryContainsServiceNames = $false
        SummaryContainsDisplayNames = $false
        SummaryContainsAccounts = $false
        SummaryContainsPaths = $false
        DetailedManifestContainsSensitiveLocalData = $true
        DetailedManifestLocalOnly = $true
        ExcludedDrivePathsDiscarded = $true
        ServicesModified = $false
        ServicesStartedOrStopped = $false
        ExecutableFilesAccessed = $false
        NetworkCollected = $false
        ExcludedDriveEAccessed = $false
    }
    Scope = [pscustomobject]@{
        ServicesEnumerated = [int64]$services.Count
        AutomaticServicesOnly = $true
        DriversCollected = $false
        ScheduledTasksCollected = $false
    }
    Summary = [pscustomobject]@{
        PersistentServices = [int64]$orderedItems.Count
    }
    Classifications = $orderedClasses
    States = $orderedStates
    AccountCategories = $orderedAccounts
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
    ServicesEnumerated = [int64]$services.Count
    PersistentServices = [int64]$orderedItems.Count
    KarvApplicationPreserve = [int64]$classCounts['KarvApplicationPreserve']
    SystemSecurityPreserve = [int64]$classCounts['SystemSecurityPreserve']
    ThirdPartyReview = [int64]$classCounts['ThirdPartyReview']
    ExcludedDriveReferencePreserve = [int64]$classCounts['ExcludedDriveReferencePreserve']
    UnresolvedPreserve = [int64]$classCounts['UnresolvedPreserve']
    SectionFailures = [int64]$sectionFailures.Count
    ReportsCreated = 2
}
