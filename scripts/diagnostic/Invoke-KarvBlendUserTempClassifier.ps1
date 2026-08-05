#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string]$Mode = 'Preview',

    [string]$OutputDirectory,
    [string]$UserTempPath,

    [ValidateRange(1, 365)]
    [int]$RecentThresholdDays = 7,

    [ValidateRange(1, 102400)]
    [int]$LargeFileThresholdMB = 100
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'BlendUserTempClassifier'
$targetDrive = 'C:'
$excludedDrive = 'E:'
$bytesPerGb = 1GB
$largeFileThresholdBytes = [int64]$LargeFileThresholdMB * 1MB
$nowUtc = [DateTime]::UtcNow

function Get-ValidatedLocalPath {
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

function New-Metric {
    return [pscustomobject]@{
        Files = 0L
        Bytes = 0L
        GB    = 0.0
    }
}

function Add-ToMetric {
    param(
        [Parameter(Mandatory = $true)]$Metric,
        [Parameter(Mandatory = $true)][int64]$Length
    )

    $Metric.Files++
    if ($Length -gt 0) {
        $Metric.Bytes += $Length
    }
}

function Complete-Metric {
    param([Parameter(Mandatory = $true)]$Metric)

    $Metric.GB = [Math]::Round(([double]$Metric.Bytes / $bytesPerGb), 3)
    return $Metric
}

function New-Category {
    param([Parameter(Mandatory = $true)][string]$Name)

    return [pscustomobject]@{
        Name  = $Name
        Files = 0L
        Bytes = 0L
        GB    = 0.0
    }
}

function Add-ToCategory {
    param(
        [Parameter(Mandatory = $true)]$Category,
        [Parameter(Mandatory = $true)][int64]$Length
    )

    $Category.Files++
    if ($Length -gt 0) {
        $Category.Bytes += $Length
    }
}

function Complete-Category {
    param([Parameter(Mandatory = $true)]$Category)

    $Category.GB = [Math]::Round(([double]$Category.Bytes / $bytesPerGb), 3)
    return $Category
}

function Get-AgeBucketName {
    param([Parameter(Mandatory = $true)][int]$AgeDays)

    if ($AgeDays -le 1) { return 'Days0To1' }
    if ($AgeDays -le 7) { return 'Days2To7' }
    if ($AgeDays -le 30) { return 'Days8To30' }
    if ($AgeDays -le 90) { return 'Days31To90' }
    return 'DaysOver90'
}

function Get-SizeBucketName {
    param([Parameter(Mandatory = $true)][int64]$Length)

    if ($Length -lt 10MB) { return 'Under10MB' }
    if ($Length -lt 100MB) { return 'From10MBTo100MB' }
    if ($Length -lt 500MB) { return 'From100MBTo500MB' }
    return 'Over500MB'
}

function Get-PatternClass {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $normalized = $FileName.ToLowerInvariant()

    if ($normalized -match '(^|[._\- ])(quit|autosave|auto[_\- ]?save|recover|recovery|crash|session)([._\- ]|$)') {
        return 'AutosaveOrRecovery'
    }

    if ($normalized -match '(^|[._\- ])(backup|bak|copy|old|previous|prev|version|ver|v[0-9]{1,4})([._\- ]|$)' -or
        $normalized -match '\([0-9]{1,4}\)\.blend$' -or
        $normalized -match '[._\-][0-9]{4}[-_][0-9]{2}[-_][0-9]{2}.*\.blend$') {
        return 'BackupOrVersionCopy'
    }

    return 'General'
}

function Get-PrimaryCategoryName {
    param(
        [Parameter(Mandatory = $true)][string]$PatternClass,
        [Parameter(Mandatory = $true)][int64]$Length,
        [Parameter(Mandatory = $true)][int]$AgeDays,
        [Parameter(Mandatory = $true)][bool]$IsReparsePoint
    )

    if ($IsReparsePoint) {
        return 'UnclassifiedProtected'
    }
    if ($AgeDays -le $RecentThresholdDays) {
        return 'PossiblyActiveOrRecentlyModified'
    }
    if ($PatternClass -eq 'AutosaveOrRecovery') {
        return 'PossibleAutosaveOrRecovery'
    }
    if ($PatternClass -eq 'BackupOrVersionCopy') {
        return 'PossibleBackupOrVersionCopy'
    }
    if ($Length -ge $largeFileThresholdBytes) {
        return 'LargeProjectLikeFile'
    }

    return 'UnclassifiedProtected'
}

if ($Mode -ne 'Preview') {
    throw 'Only Preview mode is permitted in Fase 2D.'
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable. Provide OutputDirectory explicitly.'
    }
    $OutputDirectory = Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'
}

if ([string]::IsNullOrWhiteSpace($UserTempPath)) {
    $UserTempPath = [System.IO.Path]::GetTempPath()
}

$validatedOutputDirectory = Get-ValidatedLocalPath -Path $OutputDirectory -Purpose 'OutputDirectory'
$validatedUserTempPath = Get-ValidatedLocalPath -Path $UserTempPath -Purpose 'UserTempPath'

if (-not [System.IO.Directory]::Exists($validatedUserTempPath)) {
    throw 'UserTempPath does not exist.'
}

[System.IO.Directory]::CreateDirectory($validatedOutputDirectory) | Out-Null

$categoryNames = @(
    'PossibleAutosaveOrRecovery',
    'PossibleBackupOrVersionCopy',
    'PossiblyActiveOrRecentlyModified',
    'LargeProjectLikeFile',
    'UnclassifiedProtected',
    'ReadErrorProtected'
)

$categories = @{}
foreach ($categoryName in $categoryNames) {
    $categories[$categoryName] = New-Category -Name $categoryName
}

$ageBuckets = [ordered]@{
    Days0To1   = New-Metric
    Days2To7   = New-Metric
    Days8To30  = New-Metric
    Days31To90 = New-Metric
    DaysOver90 = New-Metric
}

$sizeBuckets = [ordered]@{
    Under10MB       = New-Metric
    From10MBTo100MB = New-Metric
    From100MBTo500MB = New-Metric
    Over500MB       = New-Metric
}

$totalMetric = New-Metric
$duplicateSignatures = @{}
$errorTypes = @{}
$sectionFailures = New-Object System.Collections.Generic.List[object]
$skippedDirectoryReparsePoints = 0L
$fileReparsePointsProtected = 0L

$blenderProcessDetected = $false
try {
    $blenderProcessDetected = @(
        Get-Process -Name 'blender' -ErrorAction SilentlyContinue
    ).Count -gt 0
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
            $errorType = $_.Exception.GetType().Name
            if (-not $errorTypes.ContainsKey($errorType)) { $errorTypes[$errorType] = 0L }
            $errorTypes[$errorType]++
            $files = @()
        }

        foreach ($file in $files) {
            if (-not [string]::Equals($file.Extension, '.blend', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            try {
                $length = [int64]$file.Length
                $lastWriteUtc = $file.LastWriteTimeUtc
                $ageDays = [int][Math]::Floor(($nowUtc - $lastWriteUtc).TotalDays)
                if ($ageDays -lt 0) { $ageDays = 0 }

                $isReparsePoint = (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
                if ($isReparsePoint) { $fileReparsePointsProtected++ }

                $patternClass = Get-PatternClass -FileName $file.Name
                $categoryName = Get-PrimaryCategoryName `
                    -PatternClass $patternClass `
                    -Length $length `
                    -AgeDays $ageDays `
                    -IsReparsePoint $isReparsePoint

                Add-ToMetric -Metric $totalMetric -Length $length
                Add-ToCategory -Category $categories[$categoryName] -Length $length

                $ageBucketName = Get-AgeBucketName -AgeDays $ageDays
                Add-ToMetric -Metric $ageBuckets[$ageBucketName] -Length $length

                $sizeBucketName = Get-SizeBucketName -Length $length
                Add-ToMetric -Metric $sizeBuckets[$sizeBucketName] -Length $length

                $signature = $length.ToString() + '|' + $lastWriteUtc.ToString('yyyyMMdd') + '|' + $patternClass
                if (-not $duplicateSignatures.ContainsKey($signature)) {
                    $duplicateSignatures[$signature] = [pscustomobject]@{
                        Files = 0L
                        Bytes = 0L
                    }
                }
                $duplicateSignatures[$signature].Files++
                $duplicateSignatures[$signature].Bytes += $length
            }
            catch {
                Add-ToMetric -Metric $totalMetric -Length 0
                Add-ToCategory -Category $categories['ReadErrorProtected'] -Length 0

                $errorType = $_.Exception.GetType().Name
                if (-not $errorTypes.ContainsKey($errorType)) { $errorTypes[$errorType] = 0L }
                $errorTypes[$errorType]++
            }
        }

        try {
            $childDirectories = @($currentDirectory.GetDirectories())
        }
        catch {
            $errorType = $_.Exception.GetType().Name
            if (-not $errorTypes.ContainsKey($errorType)) { $errorTypes[$errorType] = 0L }
            $errorTypes[$errorType]++
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
        Section   = 'BlendUserTempClassification'
        ErrorType = $_.Exception.GetType().Name
    })
}

$totalMetric = Complete-Metric -Metric $totalMetric
$completedCategories = @(
    $categoryNames | ForEach-Object { Complete-Category -Category $categories[$_] }
)

$completedAgeBuckets = [ordered]@{}
foreach ($bucketName in $ageBuckets.Keys) {
    $completedAgeBuckets[$bucketName] = Complete-Metric -Metric $ageBuckets[$bucketName]
}

$completedSizeBuckets = [ordered]@{}
foreach ($bucketName in $sizeBuckets.Keys) {
    $completedSizeBuckets[$bucketName] = Complete-Metric -Metric $sizeBuckets[$bucketName]
}

$candidateGroups = @($duplicateSignatures.Values | Where-Object { $_.Files -gt 1 })
$candidateDuplicateFiles = 0L
$candidateDuplicateBytes = 0L
foreach ($candidateGroup in $candidateGroups) {
    $candidateDuplicateFiles += $candidateGroup.Files
    $candidateDuplicateBytes += $candidateGroup.Bytes
}

$sanitizedErrors = @(
    $errorTypes.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                ErrorType = $_.Name
                Count     = $_.Value
            }
        }
)

$privacy = [pscustomobject]@{
    Sanitized              = $true
    ComputerNameCollected  = $false
    UserNameCollected      = $false
    SidCollected           = $false
    SerialCollected        = $false
    NetworkCollected       = $false
    EventMessagesCollected = $false
    FileNamesCollected     = $false
    FullPathsCollected     = $false
    FileContentRead        = $false
    HashesCalculated       = $false
    ExcludedDriveE         = $true
}

$report = [pscustomobject]@{
    Collector     = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode          = $Mode
    Scope         = [pscustomobject]@{
        Source               = 'UserTemp'
        TargetDrive          = $targetDrive
        Extension            = '.blend'
        Recursive            = $true
        RecentThresholdDays  = $RecentThresholdDays
        LargeThresholdMB     = $LargeFileThresholdMB
    }
    Privacy       = $privacy
    BlenderState  = [pscustomobject]@{
        ProcessDetected = $blenderProcessDetected
        ProcessDetailsCollected = $false
    }
    Summary       = $totalMetric
    Categories    = $completedCategories
    AgeBuckets    = [pscustomobject]$completedAgeBuckets
    SizeBuckets   = [pscustomobject]$completedSizeBuckets
    CandidateDuplicateGroups = [pscustomobject]@{
        Method                = 'MetadataSignalsOnly'
        HashesCalculated      = $false
        ConfirmedDuplicates   = 0L
        CandidateGroups       = [int64]$candidateGroups.Count
        FilesInCandidateGroups = $candidateDuplicateFiles
        BytesInCandidateGroups = $candidateDuplicateBytes
        GBInCandidateGroups    = [Math]::Round(([double]$candidateDuplicateBytes / $bytesPerGb), 3)
    }
    ProtectedReparsePoints = [pscustomobject]@{
        FileReparsePoints      = $fileReparsePointsProtected
        DirectoryReparsePointsSkipped = $skippedDirectoryReparsePoints
    }
    Errors          = $sanitizedErrors
    SectionFailures = $sectionFailures.ToArray()
}

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$jsonPath = Join-Path $validatedOutputDirectory ('karv-blend-user-temp-preview-' + $timestamp + '.json')
$markdownPath = Join-Path $validatedOutputDirectory ('karv-blend-user-temp-summary-' + $timestamp + '.md')

$json = $report | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($jsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))

$markdownLines = New-Object System.Collections.Generic.List[string]
$markdownLines.Add('# KARV - classificacao sanitizada dos arquivos Blender em UserTemp')
$markdownLines.Add('')
$markdownLines.Add('- Modo: `Preview`')
$markdownLines.Add('- Extensao analisada: `.blend`')
$markdownLines.Add('- Arquivos: `' + $totalMetric.Files + '`')
$markdownLines.Add('- Volume: `' + $totalMetric.GB.ToString('0.000') + ' GB`')
$markdownLines.Add('- Processo Blender detectado: `' + $blenderProcessDetected + '`')
$markdownLines.Add('- Falhas de secao: `' + $sectionFailures.Count + '`')
$markdownLines.Add('')
$markdownLines.Add('## Categorias protegidas')
$markdownLines.Add('')
$markdownLines.Add('| Categoria | Arquivos | GB |')
$markdownLines.Add('|---|---:|---:|')
foreach ($category in $completedCategories) {
    $markdownLines.Add('| ' + $category.Name + ' | ' + $category.Files + ' | ' + $category.GB.ToString('0.000') + ' |')
}
$markdownLines.Add('')
$markdownLines.Add('## Possiveis duplicatas')
$markdownLines.Add('')
$markdownLines.Add('- Metodo: sinais de metadados; nenhum hash calculado.')
$markdownLines.Add('- Grupos candidatos: `' + $candidateGroups.Count + '`')
$markdownLines.Add('- Arquivos nos grupos candidatos: `' + $candidateDuplicateFiles + '`')
$markdownLines.Add('- Duplicatas confirmadas: `0`')
$markdownLines.Add('')
$markdownLines.Add('Nenhum nome, caminho, conteudo de arquivo ou dado da unidade E: foi registrado.')

[System.IO.File]::WriteAllLines($markdownPath, $markdownLines, (New-Object System.Text.UTF8Encoding($false)))

[pscustomobject]@{
    Status          = if ($sectionFailures.Count -eq 0) { 'Passed' } else { 'CompletedWithSectionFailures' }
    Collector       = $collectorName
    ScriptVersion   = $scriptVersion
    Mode            = $Mode
    BlendFiles      = $totalMetric.Files
    TotalGB         = $totalMetric.GB
    CandidateGroups = [int64]$candidateGroups.Count
    SectionFailures = $sectionFailures.Count
    ReportsCreated  = 2
}
