#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$TargetDrive = 'C:',
    [string]$UserTempPath,
    [string]$WindowsTempPath,
    [string]$NpmCachePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'CTempInventory'
$excludedDrive = 'E:'
$bytesPerGb = 1GB
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

function New-EmptyAgeBuckets {
    return [ordered]@{
        Days0To7 = [ordered]@{ Files = 0L; Bytes = 0L }
        Days8To30 = [ordered]@{ Files = 0L; Bytes = 0L }
        Days31To90 = [ordered]@{ Files = 0L; Bytes = 0L }
        DaysOver90 = [ordered]@{ Files = 0L; Bytes = 0L }
    }
}

function New-EmptySizeBuckets {
    return [ordered]@{
        Under1MB = [ordered]@{ Files = 0L; Bytes = 0L }
        From1MBTo100MB = [ordered]@{ Files = 0L; Bytes = 0L }
        Over100MB = [ordered]@{ Files = 0L; Bytes = 0L }
    }
}

function Convert-BucketBytesToGb {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Buckets)

    foreach ($key in @($Buckets.Keys)) {
        $bucket = $Buckets[$key]
        $bucket.GB = [Math]::Round(([double]$bucket.Bytes / $bytesPerGb), 3)
    }

    return $Buckets
}

function Measure-TempSource {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedDrive
    )

    $ageBuckets = New-EmptyAgeBuckets
    $sizeBuckets = New-EmptySizeBuckets
    $totalFiles = 0L
    $totalBytes = 0L
    $scanErrors = 0L
    $skippedReparsePoints = 0L

    $validatedPath = Get-ValidatedLocalPath -Path $Path -AllowedDrive $AllowedDrive -Purpose $Name

    if (-not [System.IO.Directory]::Exists($validatedPath)) {
        return [pscustomobject]@{
            Name                 = $Name
            Present              = $false
            Files                = 0L
            Bytes                = 0L
            GB                   = 0.0
            ScanErrors           = 0L
            SkippedReparsePoints = 0L
            AgeBuckets           = Convert-BucketBytesToGb -Buckets $ageBuckets
            SizeBuckets          = Convert-BucketBytesToGb -Buckets $sizeBuckets
        }
    }

    $rootDirectory = Get-Item -LiteralPath $validatedPath -Force
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
                $ageDays = [Math]::Floor(($nowUtc - $file.LastWriteTimeUtc).TotalDays)
                if ($ageDays -lt 0) {
                    $ageDays = 0
                }

                $totalFiles++
                $totalBytes += $length

                if ($ageDays -le 7) {
                    $ageBuckets.Days0To7.Files++
                    $ageBuckets.Days0To7.Bytes += $length
                }
                elseif ($ageDays -le 30) {
                    $ageBuckets.Days8To30.Files++
                    $ageBuckets.Days8To30.Bytes += $length
                }
                elseif ($ageDays -le 90) {
                    $ageBuckets.Days31To90.Files++
                    $ageBuckets.Days31To90.Bytes += $length
                }
                else {
                    $ageBuckets.DaysOver90.Files++
                    $ageBuckets.DaysOver90.Bytes += $length
                }

                if ($length -lt 1MB) {
                    $sizeBuckets.Under1MB.Files++
                    $sizeBuckets.Under1MB.Bytes += $length
                }
                elseif ($length -le 100MB) {
                    $sizeBuckets.From1MBTo100MB.Files++
                    $sizeBuckets.From1MBTo100MB.Bytes += $length
                }
                else {
                    $sizeBuckets.Over100MB.Files++
                    $sizeBuckets.Over100MB.Bytes += $length
                }
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

    return [pscustomobject]@{
        Name                 = $Name
        Present              = $true
        Files                = $totalFiles
        Bytes                = $totalBytes
        GB                   = [Math]::Round(([double]$totalBytes / $bytesPerGb), 3)
        ScanErrors           = $scanErrors
        SkippedReparsePoints = $skippedReparsePoints
        AgeBuckets           = Convert-BucketBytesToGb -Buckets $ageBuckets
        SizeBuckets          = Convert-BucketBytesToGb -Buckets $sizeBuckets
    }
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

if ([string]::IsNullOrWhiteSpace($WindowsTempPath)) {
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        throw 'SystemRoot is unavailable. Provide WindowsTempPath explicitly.'
    }

    $WindowsTempPath = Join-Path $env:SystemRoot 'Temp'
}

if ([string]::IsNullOrWhiteSpace($NpmCachePath)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable. Provide NpmCachePath explicitly.'
    }

    $NpmCachePath = Join-Path $env:LOCALAPPDATA 'npm-cache'
}

$validatedOutputDirectory = Get-ValidatedLocalPath `
    -Path $OutputDirectory `
    -AllowedDrive $normalizedTargetDrive `
    -Purpose 'OutputDirectory'

[System.IO.Directory]::CreateDirectory($validatedOutputDirectory) | Out-Null

$sectionFailures = New-Object System.Collections.Generic.List[object]
$sourceSummaries = New-Object System.Collections.Generic.List[object]

$sourceDefinitions = @(
    [pscustomobject]@{ Name = 'UserTemp'; Path = $UserTempPath },
    [pscustomobject]@{ Name = 'WindowsTemp'; Path = $WindowsTempPath },
    [pscustomobject]@{ Name = 'NpmCache'; Path = $NpmCachePath }
)

foreach ($sourceDefinition in $sourceDefinitions) {
    try {
        $sourceSummaries.Add(
            (Measure-TempSource `
                -Name $sourceDefinition.Name `
                -Path $sourceDefinition.Path `
                -AllowedDrive $normalizedTargetDrive)
        )
    }
    catch {
        $sectionFailures.Add([pscustomobject]@{
            Section   = $sourceDefinition.Name
            ErrorType = $_.Exception.GetType().Name
        })

        $sourceSummaries.Add([pscustomobject]@{
            Name                 = $sourceDefinition.Name
            Present              = $false
            Files                = 0L
            Bytes                = 0L
            GB                   = 0.0
            ScanErrors           = 0L
            SkippedReparsePoints = 0L
            AgeBuckets           = Convert-BucketBytesToGb -Buckets (New-EmptyAgeBuckets)
            SizeBuckets          = Convert-BucketBytesToGb -Buckets (New-EmptySizeBuckets)
        })
    }
}

$driveSummary = $null
try {
    $logicalDisk = Get-CimInstance `
        -ClassName Win32_LogicalDisk `
        -Filter ("DeviceID='" + $normalizedTargetDrive + "'")

    if ($null -eq $logicalDisk) {
        throw 'Target drive was not returned by Win32_LogicalDisk.'
    }

    $sizeBytes = [int64]$logicalDisk.Size
    $freeBytes = [int64]$logicalDisk.FreeSpace
    $usedBytes = $sizeBytes - $freeBytes
    $usedPercent = 0.0

    if ($sizeBytes -gt 0) {
        $usedPercent = [Math]::Round((100.0 * $usedBytes / $sizeBytes), 2)
    }

    $driveSummary = [pscustomobject]@{
        Drive       = $normalizedTargetDrive
        SizeGB      = [Math]::Round(([double]$sizeBytes / $bytesPerGb), 2)
        UsedGB      = [Math]::Round(([double]$usedBytes / $bytesPerGb), 2)
        FreeGB      = [Math]::Round(([double]$freeBytes / $bytesPerGb), 2)
        UsedPercent = $usedPercent
    }
}
catch {
    $sectionFailures.Add([pscustomobject]@{
        Section   = 'DriveSummary'
        ErrorType = $_.Exception.GetType().Name
    })

    $driveSummary = [pscustomobject]@{
        Drive       = $normalizedTargetDrive
        SizeGB      = $null
        UsedGB      = $null
        FreeGB      = $null
        UsedPercent = $null
    }
}

$totalTempFiles = 0L
$totalTempBytes = 0L
foreach ($sourceSummary in $sourceSummaries) {
    $totalTempFiles += [int64]$sourceSummary.Files
    $totalTempBytes += [int64]$sourceSummary.Bytes
}

$privacy = [pscustomobject]@{
    Sanitized                 = $true
    ComputerNameCollected     = $false
    UserNameCollected         = $false
    SidCollected              = $false
    SerialCollected           = $false
    NetworkCollected          = $false
    EventMessagesCollected    = $false
    FileNamesCollected        = $false
    FullPathsCollected        = $false
    FileContentsCollected     = $false
    ExcludedDriveE            = $true
}

$report = [pscustomobject]@{
    Collector         = $collectorName
    ScriptVersion     = $scriptVersion
    CollectedAtUtc    = $nowUtc.ToString('o')
    TargetDrive       = $normalizedTargetDrive
    PermanentlyExcludedDrive = $excludedDrive
    Privacy           = $privacy
    DriveSummary      = $driveSummary
    TemporarySummary = [pscustomobject]@{
        Files = $totalTempFiles
        Bytes = $totalTempBytes
        GB    = [Math]::Round(([double]$totalTempBytes / $bytesPerGb), 3)
    }
    Sources           = $sourceSummaries.ToArray()
    SectionFailures   = $sectionFailures.ToArray()
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $validatedOutputDirectory ('karv-c-temp-inventory-' + $timestamp + '.json')
$markdownPath = Join-Path $validatedOutputDirectory ('karv-c-temp-inventory-summary-' + $timestamp + '.md')
$utf8 = New-Object System.Text.UTF8Encoding($true)

$json = $report | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($jsonPath, $json, $utf8)

$markdownLines = New-Object System.Collections.Generic.List[string]
$markdownLines.Add('# KARV - inventario sanitizado da unidade local e temporarios')
$markdownLines.Add('')
$markdownLines.Add('- Coletor: `' + $collectorName + ' ' + $scriptVersion + '`')
$markdownLines.Add('- Unidade analisada: `' + $normalizedTargetDrive + '`')
$markdownLines.Add('- Unidade E: excluida permanentemente: `sim`')
$markdownLines.Add('- Limpeza executada: `nao`')
$markdownLines.Add('- Arquivos identificados por nome: `nao`')
$markdownLines.Add('- Caminhos completos registrados: `nao`')
$markdownLines.Add('')
$markdownLines.Add('## Unidade local')
$markdownLines.Add('')
$markdownLines.Add('- Capacidade: `' + [string]$driveSummary.SizeGB + ' GB`')
$markdownLines.Add('- Utilizado: `' + [string]$driveSummary.UsedGB + ' GB`')
$markdownLines.Add('- Livre: `' + [string]$driveSummary.FreeGB + ' GB`')
$markdownLines.Add('- Percentual utilizado: `' + [string]$driveSummary.UsedPercent + '%`')
$markdownLines.Add('')
$markdownLines.Add('## Temporarios medidos')
$markdownLines.Add('')
$markdownLines.Add('- Arquivos: `' + [string]$totalTempFiles + '`')
$markdownLines.Add('- Volume: `' + [string]([Math]::Round(([double]$totalTempBytes / $bytesPerGb), 3)) + ' GB`')
$markdownLines.Add('')

foreach ($sourceSummary in $sourceSummaries) {
    $markdownLines.Add('### ' + $sourceSummary.Name)
    $markdownLines.Add('')
    $markdownLines.Add('- Presente: `' + [string]$sourceSummary.Present + '`')
    $markdownLines.Add('- Arquivos: `' + [string]$sourceSummary.Files + '`')
    $markdownLines.Add('- Volume: `' + [string]$sourceSummary.GB + ' GB`')
    $markdownLines.Add('- Erros de leitura: `' + [string]$sourceSummary.ScanErrors + '`')
    $markdownLines.Add('- Pontos de nova analise ignorados: `' + [string]$sourceSummary.SkippedReparsePoints + '`')
    $markdownLines.Add('- Idade 0-7 dias: `' + [string]$sourceSummary.AgeBuckets.Days0To7.Files + ' arquivos / ' + [string]$sourceSummary.AgeBuckets.Days0To7.GB + ' GB`')
    $markdownLines.Add('- Idade 8-30 dias: `' + [string]$sourceSummary.AgeBuckets.Days8To30.Files + ' arquivos / ' + [string]$sourceSummary.AgeBuckets.Days8To30.GB + ' GB`')
    $markdownLines.Add('- Idade 31-90 dias: `' + [string]$sourceSummary.AgeBuckets.Days31To90.Files + ' arquivos / ' + [string]$sourceSummary.AgeBuckets.Days31To90.GB + ' GB`')
    $markdownLines.Add('- Idade acima de 90 dias: `' + [string]$sourceSummary.AgeBuckets.DaysOver90.Files + ' arquivos / ' + [string]$sourceSummary.AgeBuckets.DaysOver90.GB + ' GB`')
    $markdownLines.Add('- Tamanho abaixo de 1 MB: `' + [string]$sourceSummary.SizeBuckets.Under1MB.Files + ' arquivos / ' + [string]$sourceSummary.SizeBuckets.Under1MB.GB + ' GB`')
    $markdownLines.Add('- Tamanho de 1 a 100 MB: `' + [string]$sourceSummary.SizeBuckets.From1MBTo100MB.Files + ' arquivos / ' + [string]$sourceSummary.SizeBuckets.From1MBTo100MB.GB + ' GB`')
    $markdownLines.Add('- Tamanho acima de 100 MB: `' + [string]$sourceSummary.SizeBuckets.Over100MB.Files + ' arquivos / ' + [string]$sourceSummary.SizeBuckets.Over100MB.GB + ' GB`')
    $markdownLines.Add('')
}

$markdownLines.Add('## Falhas de secao')
$markdownLines.Add('')
if ($sectionFailures.Count -eq 0) {
    $markdownLines.Add('- Nenhuma.')
}
else {
    foreach ($failure in $sectionFailures) {
        $markdownLines.Add('- `' + (ConvertTo-SafeText $failure.Section) + '`: `' + (ConvertTo-SafeText $failure.ErrorType) + '`')
    }
}

[System.IO.File]::WriteAllLines($markdownPath, $markdownLines.ToArray(), $utf8)

[pscustomobject]@{
    Status          = 'Completed'
    Collector       = $collectorName
    ScriptVersion   = $scriptVersion
    TargetDrive     = $normalizedTargetDrive
    ExcludedDriveE  = $true
    SourcesMeasured = $sourceSummaries.Count
    SectionFailures = $sectionFailures.Count
    JsonReport      = $jsonPath
    MarkdownReport  = $markdownPath
}
