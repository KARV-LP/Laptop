#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string]$Mode = 'Preview',

    [string]$OutputDirectory,
    [string]$UserTempPath,

    [ValidateRange(90, 3650)]
    [int]$MinimumAgeDays = 90
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'BlendAutosaveReview'
$targetDrive = 'C:'
$excludedDrive = 'E:'
$bytesPerGb = 1GB
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

function Test-IsAutosaveOrRecoveryName {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $normalized = $FileName.ToLowerInvariant()
    return $normalized -match '(^|[._\- ])(quit|autosave|auto[_\- ]?save|recover|recovery|crash|session)([._\- ]|$)'
}

function New-Metric {
    return [pscustomobject]@{ Files = 0L; Bytes = 0L; GB = 0.0 }
}

function Add-ToMetric {
    param(
        [Parameter(Mandatory = $true)]$Metric,
        [Parameter(Mandatory = $true)][int64]$Length
    )

    $Metric.Files++
    if ($Length -gt 0) { $Metric.Bytes += $Length }
}

function Complete-Metric {
    param([Parameter(Mandatory = $true)]$Metric)

    $Metric.GB = [Math]::Round(([double]$Metric.Bytes / $bytesPerGb), 3)
    return $Metric
}

function Get-AgeBucketName {
    param([Parameter(Mandatory = $true)][int]$AgeDays)

    if ($AgeDays -le 180) { return 'Days91To180' }
    if ($AgeDays -le 365) { return 'Days181To365' }
    if ($AgeDays -le 730) { return 'Days366To730' }
    return 'DaysOver730'
}

function Get-SizeBucketName {
    param([Parameter(Mandatory = $true)][int64]$Length)

    if ($Length -lt 10MB) { return 'Under10MB' }
    if ($Length -lt 100MB) { return 'From10MBTo100MB' }
    if ($Length -lt 500MB) { return 'From100MBTo500MB' }
    return 'Over500MB'
}

function Get-RiskClass {
    param(
        [Parameter(Mandatory = $true)][int64]$Length,
        [Parameter(Mandatory = $true)][int]$AgeDays,
        [Parameter(Mandatory = $true)][System.IO.FileAttributes]$Attributes,
        [Parameter(Mandatory = $true)][bool]$BlenderProcessDetected
    )

    $specialMask = [System.IO.FileAttributes]::ReadOnly -bor
        [System.IO.FileAttributes]::Hidden -bor
        [System.IO.FileAttributes]::System -bor
        [System.IO.FileAttributes]::ReparsePoint
    $hasSpecialAttributes = (($Attributes -band $specialMask) -ne 0)

    if ($BlenderProcessDetected -or
        $hasSpecialAttributes -or
        $Length -ge 500MB -or
        $AgeDays -le 180) {
        return 'HighRiskPreserve'
    }

    if ($Length -ge 100MB -or $AgeDays -le 365) {
        return 'MediumRiskReview'
    }

    return 'LowerRiskReview'
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
    throw 'Only Preview mode is permitted in Fase 2E.'
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
if ([string]::IsNullOrWhiteSpace($UserTempPath)) {
    $UserTempPath = [System.IO.Path]::GetTempPath()
}

$validatedOutputDirectory = Get-ValidatedCDrivePath -Path $OutputDirectory -Purpose 'OutputDirectory'
$validatedUserTempPath = Get-ValidatedCDrivePath -Path $UserTempPath -Purpose 'UserTempPath'

if (-not (Test-IsPathInsideRoot -Path $validatedOutputDirectory -Root $allowedOutputRoot)) {
    throw 'OutputDirectory must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.'
}
if (-not [System.IO.Directory]::Exists($validatedUserTempPath)) {
    throw 'UserTempPath does not exist.'
}

[System.IO.Directory]::CreateDirectory($validatedOutputDirectory) | Out-Null

$riskNames = @(
    'HighRiskPreserve',
    'MediumRiskReview',
    'LowerRiskReview',
    'ReadErrorProtected'
)
$riskMetrics = @{}
foreach ($riskName in $riskNames) { $riskMetrics[$riskName] = New-Metric }

$ageBuckets = [ordered]@{
    Days91To180 = New-Metric
    Days181To365 = New-Metric
    Days366To730 = New-Metric
    DaysOver730 = New-Metric
}
$sizeBuckets = [ordered]@{
    Under10MB = New-Metric
    From10MBTo100MB = New-Metric
    From100MBTo500MB = New-Metric
    Over500MB = New-Metric
}

$totalMetric = New-Metric
$manifestItems = New-Object System.Collections.Generic.List[object]
$errorTypes = @{}
$sectionFailures = New-Object System.Collections.Generic.List[object]
$skippedDirectoryReparsePoints = 0L

$blenderProcessDetected = $false
try {
    $blenderProcessDetected = @(Get-Process -Name 'blender' -ErrorAction SilentlyContinue).Count -gt 0
}
catch {
    $blenderProcessDetected = $false
}

try {
    $rootDirectory = Get-Item -LiteralPath $validatedUserTempPath -Force
    $directoryStack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $directoryStack.Push($rootDirectory)

    while ($directoryStack.Count -gt 0) {
        $currentDirectory = $directoryStack.Pop()

        try {
            $files = @($currentDirectory.GetFiles())
        }
        catch {
            Add-SanitizedError -ErrorTable $errorTypes -ErrorType $_.Exception.GetType().Name
            $files = @()
        }

        foreach ($file in $files) {
            if (-not [string]::Equals($file.Extension, '.blend', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-IsAutosaveOrRecoveryName -FileName $file.Name)) { continue }

            try {
                $length = [int64]$file.Length
                $lastWriteUtc = $file.LastWriteTimeUtc
                $ageDays = [int][Math]::Floor(($nowUtc - $lastWriteUtc).TotalDays)
                if ($ageDays -lt 0) { $ageDays = 0 }
                if ($ageDays -le $MinimumAgeDays) { continue }

                $attributes = $file.Attributes
                $riskClass = Get-RiskClass `
                    -Length $length `
                    -AgeDays $ageDays `
                    -Attributes $attributes `
                    -BlenderProcessDetected $blenderProcessDetected

                Add-ToMetric -Metric $totalMetric -Length $length
                Add-ToMetric -Metric $riskMetrics[$riskClass] -Length $length
                Add-ToMetric -Metric $ageBuckets[(Get-AgeBucketName -AgeDays $ageDays)] -Length $length
                Add-ToMetric -Metric $sizeBuckets[(Get-SizeBucketName -Length $length)] -Length $length

                $manifestItems.Add([pscustomobject]@{
                    ReviewId = $null
                    FileName = $file.Name
                    FullPath = $file.FullName
                    LengthBytes = $length
                    SizeMB = [Math]::Round(([double]$length / 1MB), 3)
                    AgeDays = $ageDays
                    LastWriteUtc = $lastWriteUtc.ToString('o')
                    Attributes = $attributes.ToString()
                    RiskClass = $riskClass
                    MetadataError = $null
                    Protected = $true
                })
            }
            catch {
                $errorType = $_.Exception.GetType().Name
                Add-SanitizedError -ErrorTable $errorTypes -ErrorType $errorType
                Add-ToMetric -Metric $totalMetric -Length 0
                Add-ToMetric -Metric $riskMetrics['ReadErrorProtected'] -Length 0

                $manifestItems.Add([pscustomobject]@{
                    ReviewId = $null
                    FileName = $file.Name
                    FullPath = $file.FullName
                    LengthBytes = $null
                    SizeMB = $null
                    AgeDays = $null
                    LastWriteUtc = $null
                    Attributes = $null
                    RiskClass = 'ReadErrorProtected'
                    MetadataError = $errorType
                    Protected = $true
                })
            }
        }

        try {
            $childDirectories = @($currentDirectory.GetDirectories())
        }
        catch {
            Add-SanitizedError -ErrorTable $errorTypes -ErrorType $_.Exception.GetType().Name
            $childDirectories = @()
        }

        foreach ($childDirectory in $childDirectories) {
            if (($childDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $skippedDirectoryReparsePoints++
                continue
            }
            $directoryStack.Push($childDirectory)
        }
    }
}
catch {
    $sectionFailures.Add([pscustomobject]@{
        Section = 'BlendAutosaveReview'
        ErrorType = $_.Exception.GetType().Name
    })
}

$orderedItems = @(
    $manifestItems.ToArray() |
        Sort-Object `
            @{ Expression = {
                switch ($_.RiskClass) {
                    'HighRiskPreserve' { 1 }
                    'ReadErrorProtected' { 2 }
                    'MediumRiskReview' { 3 }
                    default { 4 }
                }
            } },
            @{ Expression = { if ($null -eq $_.LengthBytes) { -1 } else { $_.LengthBytes } }; Descending = $true },
            @{ Expression = { $_.AgeDays }; Descending = $false }
)

for ($index = 0; $index -lt $orderedItems.Count; $index++) {
    $orderedItems[$index].ReviewId = 'R' + ($index + 1).ToString('D6')
}

$totalMetric = Complete-Metric -Metric $totalMetric
$completedRisks = @(
    $riskNames | ForEach-Object {
        $metric = Complete-Metric -Metric $riskMetrics[$_]
        [pscustomobject]@{ Name = $_; Files = $metric.Files; Bytes = $metric.Bytes; GB = $metric.GB }
    }
)

$completedAgeBuckets = [ordered]@{}
foreach ($bucketName in $ageBuckets.Keys) {
    $completedAgeBuckets[$bucketName] = Complete-Metric -Metric $ageBuckets[$bucketName]
}
$completedSizeBuckets = [ordered]@{}
foreach ($bucketName in $sizeBuckets.Keys) {
    $completedSizeBuckets[$bucketName] = Complete-Metric -Metric $sizeBuckets[$bucketName]
}

$sanitizedErrors = @(
    $errorTypes.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ ErrorType = $_.Name; Count = $_.Value } }
)

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$manifestPath = Join-Path $validatedOutputDirectory ('karv-blend-autosave-local-manifest-' + $timestamp + '.json')
$summaryPath = Join-Path $validatedOutputDirectory ('karv-blend-autosave-sanitized-summary-' + $timestamp + '.json')

$manifest = [pscustomobject]@{
    Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    SensitiveLocalData = $true
    LocalOnly = $true
    SourceRoot = $validatedUserTempPath
    Selection = [pscustomobject]@{
        Extension = '.blend'
        Pattern = 'AutosaveOrRecovery'
        MinimumAgeDaysExclusive = $MinimumAgeDays
    }
    Items = $orderedItems
}

$summary = [pscustomobject]@{
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    Scope = [pscustomobject]@{
        Source = 'UserTemp'
        TargetDrive = $targetDrive
        Extension = '.blend'
        Pattern = 'AutosaveOrRecovery'
        MinimumAgeDaysExclusive = $MinimumAgeDays
        Recursive = $true
    }
    Privacy = [pscustomobject]@{
        SummarySanitized = $true
        SummaryContainsFileNames = $false
        SummaryContainsFullPaths = $false
        SummaryContainsReviewIds = $false
        DetailedManifestContainsSensitiveLocalData = $true
        DetailedManifestLocalOnly = $true
        FileContentRead = $false
        HashesCalculated = $false
        NetworkCollected = $false
        ExcludedDriveE = $true
    }
    BlenderState = [pscustomobject]@{
        ProcessDetected = $blenderProcessDetected
        ProcessDetailsCollected = $false
    }
    Summary = $totalMetric
    Risks = $completedRisks
    AgeBuckets = [pscustomobject]$completedAgeBuckets
    SizeBuckets = [pscustomobject]$completedSizeBuckets
    ProtectedReparsePoints = [pscustomobject]@{
        DirectoryReparsePointsSkipped = $skippedDirectoryReparsePoints
    }
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
    SelectedFiles = $totalMetric.Files
    TotalGB = $totalMetric.GB
    HighRiskPreserve = $riskMetrics['HighRiskPreserve'].Files
    MediumRiskReview = $riskMetrics['MediumRiskReview'].Files
    LowerRiskReview = $riskMetrics['LowerRiskReview'].Files
    ReadErrorProtected = $riskMetrics['ReadErrorProtected'].Files
    BlenderProcessDetected = $blenderProcessDetected
    SectionFailures = $sectionFailures.Count
    ReportsCreated = 2
}
