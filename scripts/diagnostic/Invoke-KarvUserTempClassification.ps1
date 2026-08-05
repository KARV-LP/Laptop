#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$TargetDrive = 'C:',
    [string]$UserTempPath,
    [int]$MinimumAgeDays = 90,
    [int]$LargeFileThresholdMB = 100,
    [int]$MaxExtensions = 40
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'UserTempClassification'
$excludedDrive = 'E:'
$bytesPerGb = 1GB
$largeFileThresholdBytes = [int64]$LargeFileThresholdMB * 1MB
$nowUtc = [DateTime]::UtcNow

function Normalize-DriveName {
    param([Parameter(Mandatory = $true)][string]$DriveName)

    $trimmed = $DriveName.Trim().TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]$') {
        $trimmed += ':'
    }

    if ($trimmed -notmatch '^[A-Za-z]:$') {
        throw 'TargetDrive must use the format C:.'
    }

    return $trimmed.ToUpperInvariant()
}

function ConvertTo-SafeText {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $safe = $Value
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        $safe = $safe.Replace($env:COMPUTERNAME, '<COMPUTER>')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        $safe = $safe.Replace($env:USERNAME, '<USER>')
    }

    $safe = [regex]::Replace($safe, '\bS-1-\d+(?:-\d+)+\b', '<SID>')
    return $safe
}

function Get-ValidatedLocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedDrive,
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
    if ($pathDrive -ne $AllowedDrive) {
        throw ($Purpose + ' must remain on the target drive.')
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

function New-AgeBuckets {
    return [pscustomobject]@{
        Days0To7   = New-Metric
        Days8To30  = New-Metric
        Days31To90 = New-Metric
        DaysOver90 = New-Metric
    }
}

function New-SizeBuckets {
    return [pscustomobject]@{
        Under1MB        = New-Metric
        From1MBTo100MB  = New-Metric
        Over100MB       = New-Metric
    }
}

function New-Group {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Disposition
    )

    return [pscustomobject]@{
        Name        = $Name
        Disposition = $Disposition
        Files       = 0L
        Bytes       = 0L
        GB          = 0.0
        OldFiles    = 0L
        OldBytes    = 0L
        OldGB       = 0.0
        LargeFiles  = 0L
        LargeBytes  = 0L
        LargeGB     = 0.0
        OldAndLargeFiles = 0L
        OldAndLargeBytes = 0L
        OldAndLargeGB    = 0.0
        AgeBuckets  = New-AgeBuckets
        SizeBuckets = New-SizeBuckets
    }
}

function Add-ToMetric {
    param(
        [Parameter(Mandatory = $true)]$Metric,
        [Parameter(Mandatory = $true)][int64]$Length
    )

    $Metric.Files++
    $Metric.Bytes += $Length
}

function Add-ToGroup {
    param(
        [Parameter(Mandatory = $true)]$Group,
        [Parameter(Mandatory = $true)][int64]$Length,
        [Parameter(Mandatory = $true)][int]$AgeDays,
        [Parameter(Mandatory = $true)][bool]$IsOld,
        [Parameter(Mandatory = $true)][bool]$IsLarge
    )

    $Group.Files++
    $Group.Bytes += $Length

    if ($IsOld) {
        $Group.OldFiles++
        $Group.OldBytes += $Length
    }
    if ($IsLarge) {
        $Group.LargeFiles++
        $Group.LargeBytes += $Length
    }
    if ($IsOld -and $IsLarge) {
        $Group.OldAndLargeFiles++
        $Group.OldAndLargeBytes += $Length
    }

    if ($AgeDays -le 7) {
        Add-ToMetric -Metric $Group.AgeBuckets.Days0To7 -Length $Length
    }
    elseif ($AgeDays -le 30) {
        Add-ToMetric -Metric $Group.AgeBuckets.Days8To30 -Length $Length
    }
    elseif ($AgeDays -le 90) {
        Add-ToMetric -Metric $Group.AgeBuckets.Days31To90 -Length $Length
    }
    else {
        Add-ToMetric -Metric $Group.AgeBuckets.DaysOver90 -Length $Length
    }

    if ($Length -lt 1MB) {
        Add-ToMetric -Metric $Group.SizeBuckets.Under1MB -Length $Length
    }
    elseif ($Length -le 100MB) {
        Add-ToMetric -Metric $Group.SizeBuckets.From1MBTo100MB -Length $Length
    }
    else {
        Add-ToMetric -Metric $Group.SizeBuckets.Over100MB -Length $Length
    }
}

function Complete-Metric {
    param([Parameter(Mandatory = $true)]$Metric)
    $Metric.GB = [Math]::Round(([double]$Metric.Bytes / $bytesPerGb), 3)
}

function Complete-Group {
    param([Parameter(Mandatory = $true)]$Group)

    $Group.GB = [Math]::Round(([double]$Group.Bytes / $bytesPerGb), 3)
    $Group.OldGB = [Math]::Round(([double]$Group.OldBytes / $bytesPerGb), 3)
    $Group.LargeGB = [Math]::Round(([double]$Group.LargeBytes / $bytesPerGb), 3)
    $Group.OldAndLargeGB = [Math]::Round(([double]$Group.OldAndLargeBytes / $bytesPerGb), 3)

    foreach ($metric in @(
        $Group.AgeBuckets.Days0To7,
        $Group.AgeBuckets.Days8To30,
        $Group.AgeBuckets.Days31To90,
        $Group.AgeBuckets.DaysOver90,
        $Group.SizeBuckets.Under1MB,
        $Group.SizeBuckets.From1MBTo100MB,
        $Group.SizeBuckets.Over100MB
    )) {
        Complete-Metric -Metric $metric
    }

    return $Group
}

function Get-SafeExtension {
    param([AllowNull()][string]$Extension)

    if ([string]::IsNullOrWhiteSpace($Extension)) {
        return '<none>'
    }

    $normalized = $Extension.ToLowerInvariant()
    if ($normalized -match '^\.[a-z0-9]{1,10}$') {
        return $normalized
    }

    return '<other>'
}

function Get-ExtensionClassification {
    param([Parameter(Mandatory = $true)][string]$Extension)

    $temporary = @('.tmp', '.temp', '.part', '.crdownload', '.download', '.chk', '.etl', '.log')
    $cache = @('.cache', '.pyc', '.pyo', '.class', '.map')
    $dump = @('.dmp', '.mdmp', '.hdmp')
    $installerArchive = @('.exe', '.msi', '.msix', '.appx', '.cab', '.zip', '.7z', '.rar', '.tar', '.gz', '.tgz')
    $technicalAsset = @('.blend', '.blend1', '.blend2', '.3dm', '.glb', '.gltf', '.fbx', '.obj', '.stl', '.igs', '.iges', '.step', '.stp', '.sbs', '.sbsar', '.spsm', '.psd', '.ai')
    $renderMedia = @('.exr', '.hdr', '.tif', '.tiff', '.png', '.jpg', '.jpeg', '.webp', '.mp4', '.mov', '.avi', '.mkv', '.wav')
    $documentData = @('.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.md', '.csv', '.json', '.xml')
    $database = @('.mdf', '.ldf', '.db', '.sqlite', '.sqlite3')
    $executableLibrary = @('.dll', '.sys', '.ocx', '.com')

    if ($temporary -contains $Extension) {
        return [pscustomobject]@{ Category = 'TemporaryArtifact'; Disposition = 'CandidateAfterApplicationClosure' }
    }
    if ($cache -contains $Extension) {
        return [pscustomobject]@{ Category = 'RegenerableCache'; Disposition = 'CandidateAfterApplicationClosure' }
    }
    if ($dump -contains $Extension) {
        return [pscustomobject]@{ Category = 'DiagnosticDump'; Disposition = 'ReviewThenDelete' }
    }
    if ($installerArchive -contains $Extension) {
        return [pscustomobject]@{ Category = 'InstallerOrArchive'; Disposition = 'ManualReview' }
    }
    if ($technicalAsset -contains $Extension) {
        return [pscustomobject]@{ Category = 'TechnicalAsset'; Disposition = 'ProtectedManualReview' }
    }
    if ($renderMedia -contains $Extension) {
        return [pscustomobject]@{ Category = 'RenderOrMedia'; Disposition = 'ProtectedManualReview' }
    }
    if ($documentData -contains $Extension) {
        return [pscustomobject]@{ Category = 'DocumentOrData'; Disposition = 'ProtectedManualReview' }
    }
    if ($database -contains $Extension) {
        return [pscustomobject]@{ Category = 'Database'; Disposition = 'ProtectedManualReview' }
    }
    if ($executableLibrary -contains $Extension) {
        return [pscustomobject]@{ Category = 'ExecutableOrLibrary'; Disposition = 'ManualReview' }
    }

    return [pscustomobject]@{ Category = 'Unknown'; Disposition = 'DoNotDeleteAutomatically' }
}

if ($MinimumAgeDays -lt 1) {
    throw 'MinimumAgeDays must be at least 1.'
}
if ($LargeFileThresholdMB -lt 1) {
    throw 'LargeFileThresholdMB must be at least 1.'
}
if ($MaxExtensions -lt 1 -or $MaxExtensions -gt 200) {
    throw 'MaxExtensions must be between 1 and 200.'
}

$normalizedTargetDrive = Normalize-DriveName -DriveName $TargetDrive
if ($normalizedTargetDrive -eq $excludedDrive) {
    throw 'Drive E: is permanently excluded from KARV laptop maintenance.'
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

$validatedOutputDirectory = Get-ValidatedLocalPath -Path $OutputDirectory -AllowedDrive $normalizedTargetDrive -Purpose 'OutputDirectory'
$validatedUserTempPath = Get-ValidatedLocalPath -Path $UserTempPath -AllowedDrive $normalizedTargetDrive -Purpose 'UserTemp'

[System.IO.Directory]::CreateDirectory($validatedOutputDirectory) | Out-Null

$categoryGroups = @{}
$extensionGroups = @{}
$sectionFailures = New-Object System.Collections.Generic.List[object]
$totalGroup = New-Group -Name 'QualifyingTotal' -Disposition 'AnalysisOnly'
$scanErrors = 0L
$skippedReparsePoints = 0L

try {
    if (-not [System.IO.Directory]::Exists($validatedUserTempPath)) {
        throw 'UserTemp directory does not exist.'
    }

    $rootDirectory = Get-Item -LiteralPath $validatedUserTempPath -Force
    $directoryStack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $directoryStack.Push($rootDirectory)

    while ($directoryStack.Count -gt 0) {
        $currentDirectory = $directoryStack.Pop()

        try {
            $files = @($currentDirectory.GetFiles())
        }
        catch {
            $scanErrors++
            $files = @()
        }

        foreach ($file in $files) {
            try {
                $length = [int64]$file.Length
                $ageDays = [int][Math]::Floor(($nowUtc - $file.LastWriteTimeUtc).TotalDays)
                if ($ageDays -lt 0) {
                    $ageDays = 0
                }

                $isOld = $ageDays -gt $MinimumAgeDays
                $isLarge = $length -gt $largeFileThresholdBytes
                if (-not ($isOld -or $isLarge)) {
                    continue
                }

                $extension = Get-SafeExtension -Extension $file.Extension
                $classification = Get-ExtensionClassification -Extension $extension

                if (-not $categoryGroups.ContainsKey($classification.Category)) {
                    $categoryGroups[$classification.Category] = New-Group -Name $classification.Category -Disposition $classification.Disposition
                }
                if (-not $extensionGroups.ContainsKey($extension)) {
                    $extensionGroups[$extension] = New-Group -Name $extension -Disposition $classification.Disposition
                }

                Add-ToGroup -Group $totalGroup -Length $length -AgeDays $ageDays -IsOld $isOld -IsLarge $isLarge
                Add-ToGroup -Group $categoryGroups[$classification.Category] -Length $length -AgeDays $ageDays -IsOld $isOld -IsLarge $isLarge
                Add-ToGroup -Group $extensionGroups[$extension] -Length $length -AgeDays $ageDays -IsOld $isOld -IsLarge $isLarge
            }
            catch {
                $scanErrors++
            }
        }

        try {
            $childDirectories = @($currentDirectory.GetDirectories())
        }
        catch {
            $scanErrors++
            $childDirectories = @()
        }

        foreach ($childDirectory in $childDirectories) {
            try {
                if (($childDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $skippedReparsePoints++
                    continue
                }
                $directoryStack.Push($childDirectory)
            }
            catch {
                $scanErrors++
            }
        }
    }
}
catch {
    $sectionFailures.Add([pscustomobject]@{
        Section   = 'UserTempClassification'
        ErrorType = $_.Exception.GetType().Name
    })
}

$totalGroup = Complete-Group -Group $totalGroup
$completedCategories = @($categoryGroups.Values | ForEach-Object { Complete-Group -Group $_ } | Sort-Object Bytes -Descending)
$completedExtensions = @($extensionGroups.Values | ForEach-Object { Complete-Group -Group $_ } | Sort-Object Bytes -Descending | Select-Object -First $MaxExtensions)

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
    FileContentsCollected  = $false
    ExcludedDriveE         = $true
}

$report = [pscustomobject]@{
    Collector                = $collectorName
    ScriptVersion            = $scriptVersion
    CollectedAtUtc           = $nowUtc.ToString('o')
    TargetDrive              = $normalizedTargetDrive
    PermanentlyExcludedDrive = $excludedDrive
    MinimumAgeDays           = $MinimumAgeDays
    LargeFileThresholdMB     = $LargeFileThresholdMB
    Privacy                  = $privacy
    QualifyingSummary        = $totalGroup
    Categories               = $completedCategories
    TopExtensionsByVolume    = $completedExtensions
    ScanErrors               = $scanErrors
    SkippedReparsePoints     = $skippedReparsePoints
    SectionFailures          = $sectionFailures.ToArray()
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $validatedOutputDirectory ('karv-user-temp-classification-' + $timestamp + '.json')
$markdownPath = Join-Path $validatedOutputDirectory ('karv-user-temp-classification-summary-' + $timestamp + '.md')
$utf8 = New-Object System.Text.UTF8Encoding($true)

$json = $report | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($jsonPath, $json, $utf8)

$markdownLines = New-Object System.Collections.Generic.List[string]
$markdownLines.Add('# KARV - classificacao sanitizada de temporarios antigos e grandes')
$markdownLines.Add('')
$markdownLines.Add('- Coletor: `' + $collectorName + ' ' + $scriptVersion + '`')
$markdownLines.Add('- Unidade analisada: `' + $normalizedTargetDrive + '`')
$markdownLines.Add('- Unidade E: excluida permanentemente: `sim`')
$markdownLines.Add('- Limpeza executada: `nao`')
$markdownLines.Add('- Nomes de arquivos registrados: `nao`')
$markdownLines.Add('- Caminhos completos registrados: `nao`')
$markdownLines.Add('- Criterio de idade: acima de `' + [string]$MinimumAgeDays + ' dias`')
$markdownLines.Add('- Criterio de tamanho: acima de `' + [string]$LargeFileThresholdMB + ' MB`')
$markdownLines.Add('')
$markdownLines.Add('## Resumo qualificado')
$markdownLines.Add('')
$markdownLines.Add('- Arquivos antigos ou grandes: `' + [string]$totalGroup.Files + '`')
$markdownLines.Add('- Volume: `' + [string]$totalGroup.GB + ' GB`')
$markdownLines.Add('- Antigos: `' + [string]$totalGroup.OldFiles + ' arquivos / ' + [string]$totalGroup.OldGB + ' GB`')
$markdownLines.Add('- Grandes: `' + [string]$totalGroup.LargeFiles + ' arquivos / ' + [string]$totalGroup.LargeGB + ' GB`')
$markdownLines.Add('- Antigos e grandes: `' + [string]$totalGroup.OldAndLargeFiles + ' arquivos / ' + [string]$totalGroup.OldAndLargeGB + ' GB`')
$markdownLines.Add('- Erros de leitura: `' + [string]$scanErrors + '`')
$markdownLines.Add('- Pontos de nova analise ignorados: `' + [string]$skippedReparsePoints + '`')
$markdownLines.Add('')
$markdownLines.Add('## Categorias')
$markdownLines.Add('')
foreach ($category in $completedCategories) {
    $markdownLines.Add('### ' + $category.Name)
    $markdownLines.Add('')
    $markdownLines.Add('- Disposicao: `' + $category.Disposition + '`')
    $markdownLines.Add('- Total: `' + [string]$category.Files + ' arquivos / ' + [string]$category.GB + ' GB`')
    $markdownLines.Add('- Antigos: `' + [string]$category.OldFiles + ' arquivos / ' + [string]$category.OldGB + ' GB`')
    $markdownLines.Add('- Grandes: `' + [string]$category.LargeFiles + ' arquivos / ' + [string]$category.LargeGB + ' GB`')
    $markdownLines.Add('- Antigos e grandes: `' + [string]$category.OldAndLargeFiles + ' arquivos / ' + [string]$category.OldAndLargeGB + ' GB`')
    $markdownLines.Add('')
}

$markdownLines.Add('## Extensoes agregadas por volume')
$markdownLines.Add('')
foreach ($extensionGroup in $completedExtensions) {
    $markdownLines.Add('- `' + $extensionGroup.Name + '`: ' + [string]$extensionGroup.Files + ' arquivos / ' + [string]$extensionGroup.GB + ' GB / `' + $extensionGroup.Disposition + '`')
}

$markdownLines.Add('')
$markdownLines.Add('## Falhas de secao')
$markdownLines.Add('')
if ($sectionFailures.Count -eq 0) {
    $markdownLines.Add('- Nenhuma.')
}
else {
    foreach ($failure in $sectionFailures) {
        $markdownLines.Add('- `' + (ConvertTo-SafeText -Value $failure.Section) + '`: `' + (ConvertTo-SafeText -Value $failure.ErrorType) + '`')
    }
}

[System.IO.File]::WriteAllLines($markdownPath, $markdownLines, $utf8)

[pscustomobject]@{
    Status               = 'Completed'
    Collector            = $collectorName
    ScriptVersion        = $scriptVersion
    TargetDrive          = $normalizedTargetDrive
    ExcludedDriveE       = $true
    QualifyingFiles      = $totalGroup.Files
    QualifyingGB         = $totalGroup.GB
    Categories           = $completedCategories.Count
    SectionFailures      = $sectionFailures.Count
    JsonReport           = $jsonPath
    MarkdownReport       = $markdownPath
}
