#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply')]
    [string]$Mode = 'Preview',

    [string]$ConfirmationToken,

    [switch]$ApplicationsClosed,

    [string]$OutputDirectory,

    [string]$UserTempPath,

    [ValidateRange(90, 3650)]
    [int]$MinimumAgeDays = 90
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$collectorName = 'AuthorizedLowRiskTempCleanup'
$scriptVersion = '1.0.0'
$requiredConfirmationToken = 'KARV-LOW-RISK-CLEANUP-APPLY-AUTHORIZED'
$allowedExtensions = @('.tmp', '.log', '.etl')
$reviewOnlyExtension = '.dmp'
$nowUtc = [DateTime]::UtcNow
$bytesPerGb = 1GB

function Get-ValidatedPathOnC {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw ($Purpose + ' does not have a valid drive root.')
    }

    $drive = $root.TrimEnd('\').ToUpperInvariant()
    if ($drive -eq 'E:') {
        throw ($Purpose + ' cannot use the permanently excluded drive E:.')
    }
    if ($drive -ne 'C:') {
        throw ($Purpose + ' must remain on drive C:.')
    }

    return $fullPath
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')

    return [string]::Equals(
        $normalizedPath,
        $normalizedRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or $normalizedPath.StartsWith(
        $normalizedRoot + '\',
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Add-Failure {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Map,
        [Parameter(Mandatory = $true)][string]$ErrorType
    )

    if (-not $Map.Contains($ErrorType)) { $Map[$ErrorType] = 0L }
    $Map[$ErrorType]++
}

if ($Mode -eq 'Apply') {
    if (-not $ApplicationsClosed.IsPresent) {
        throw 'Apply requires -ApplicationsClosed after saving and closing active applications.'
    }
    if ($ConfirmationToken -cne $requiredConfirmationToken) {
        throw 'Apply requires the exact authorization token.'
    }
}

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw 'LOCALAPPDATA is unavailable.'
}

$systemTempRoot = Get-ValidatedPathOnC -Path ([System.IO.Path]::GetTempPath()) -Purpose 'SystemTempRoot'
$diagnosticsRoot = Get-ValidatedPathOnC `
    -Path (Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics') `
    -Purpose 'DiagnosticsRoot'

if ([string]::IsNullOrWhiteSpace($UserTempPath)) { $UserTempPath = $systemTempRoot }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = $diagnosticsRoot }

$validatedTempPath = Get-ValidatedPathOnC -Path $UserTempPath -Purpose 'UserTempPath'
$validatedOutputPath = Get-ValidatedPathOnC -Path $OutputDirectory -Purpose 'OutputDirectory'

if (-not (Test-PathInsideRoot -Path $validatedTempPath -Root $systemTempRoot)) {
    throw 'UserTempPath must remain inside the current user Temp directory.'
}
if (-not (Test-PathInsideRoot -Path $validatedOutputPath -Root $diagnosticsRoot)) {
    throw 'OutputDirectory must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.'
}

[System.IO.Directory]::CreateDirectory($validatedOutputPath) | Out-Null

$extensionStats = [ordered]@{}
foreach ($extension in $allowedExtensions) {
    $extensionStats[$extension] = [ordered]@{
        Extension = $extension
        Candidates = 0L
        CandidateBytes = 0L
        Removed = 0L
        RemovedBytes = 0L
        Failures = 0L
    }
}

$scannedFiles = 0L
$candidateFiles = 0L
$candidateBytes = 0L
$removedFiles = 0L
$removedBytes = 0L
$deleteFailures = 0L
$scanFailures = 0L
$skippedReparsePoints = 0L
$preservedDmpFiles = 0L
$preservedDmpBytes = 0L
$failureTypes = [ordered]@{}

if ([System.IO.Directory]::Exists($validatedTempPath)) {
    $rootDirectory = Get-Item -LiteralPath $validatedTempPath -Force
    $directoryStack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $directoryStack.Push($rootDirectory)

    while ($directoryStack.Count -gt 0) {
        $currentDirectory = $directoryStack.Pop()

        try {
            $files = @($currentDirectory.GetFiles())
        }
        catch {
            $scanFailures++
            Add-Failure -Map $failureTypes -ErrorType $_.Exception.GetType().Name
            $files = @()
        }

        foreach ($file in $files) {
            $scannedFiles++
            try {
                if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $skippedReparsePoints++
                    continue
                }

                $extension = $file.Extension.ToLowerInvariant()
                $ageDays = [Math]::Floor(($nowUtc - $file.LastWriteTimeUtc).TotalDays)

                if ($extension -eq $reviewOnlyExtension -and $ageDays -gt $MinimumAgeDays) {
                    $preservedDmpFiles++
                    $preservedDmpBytes += [int64]$file.Length
                    continue
                }

                if ($allowedExtensions -notcontains $extension) { continue }
                if ($ageDays -le $MinimumAgeDays) { continue }

                $length = [int64]$file.Length
                $item = $extensionStats[$extension]
                $item.Candidates++
                $item.CandidateBytes += $length
                $candidateFiles++
                $candidateBytes += $length

                if ($Mode -eq 'Apply') {
                    try {
                        [System.IO.File]::Delete($file.FullName)
                        $item.Removed++
                        $item.RemovedBytes += $length
                        $removedFiles++
                        $removedBytes += $length
                    }
                    catch {
                        $item.Failures++
                        $deleteFailures++
                        Add-Failure -Map $failureTypes -ErrorType $_.Exception.GetType().Name
                    }
                }
            }
            catch {
                $scanFailures++
                Add-Failure -Map $failureTypes -ErrorType $_.Exception.GetType().Name
            }
        }

        try {
            $childDirectories = @($currentDirectory.GetDirectories())
        }
        catch {
            $scanFailures++
            Add-Failure -Map $failureTypes -ErrorType $_.Exception.GetType().Name
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
                $scanFailures++
                Add-Failure -Map $failureTypes -ErrorType $_.Exception.GetType().Name
            }
        }
    }
}

$extensionResults = New-Object System.Collections.Generic.List[object]
foreach ($extension in $allowedExtensions) {
    $item = $extensionStats[$extension]
    $extensionResults.Add([pscustomobject]@{
        Extension = $item.Extension
        Candidates = [int64]$item.Candidates
        CandidateGB = [Math]::Round(([double]$item.CandidateBytes / $bytesPerGb), 3)
        Removed = [int64]$item.Removed
        RemovedGB = [Math]::Round(([double]$item.RemovedBytes / $bytesPerGb), 3)
        Failures = [int64]$item.Failures
    })
}

$failureResults = New-Object System.Collections.Generic.List[object]
foreach ($errorType in $failureTypes.Keys) {
    $failureResults.Add([pscustomobject]@{
        ErrorType = $errorType
        Count = [int64]$failureTypes[$errorType]
    })
}

$report = [pscustomobject]@{
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    CleanupExecuted = [bool]($Mode -eq 'Apply')
    Privacy = [pscustomobject]@{
        SummarySanitized = $true
        FileNamesCollected = $false
        FullPathsCollected = $false
        FileContentsCollected = $false
        UserIdentityCollected = $false
        NetworkCollected = $false
        ExcludedDriveEAccessed = $false
    }
    Scope = [pscustomobject]@{
        TargetDriveCOnly = $true
        UserTempOnly = $true
        MinimumAgeDays = $MinimumAgeDays
        AllowedExtensions = $allowedExtensions
        DiagnosticDumpsPreserved = $true
        BlendFilesPreserved = $true
        DirectoriesRemoved = $false
        ProcessesStopped = $false
        ServicesChanged = $false
        RebootTriggered = $false
    }
    Summary = [pscustomobject]@{
        ScannedFiles = $scannedFiles
        CandidateFiles = $candidateFiles
        CandidateGB = [Math]::Round(([double]$candidateBytes / $bytesPerGb), 3)
        RemovedFiles = $removedFiles
        RemovedGB = [Math]::Round(([double]$removedBytes / $bytesPerGb), 3)
        PreservedDiagnosticDumpFiles = $preservedDmpFiles
        PreservedDiagnosticDumpGB = [Math]::Round(([double]$preservedDmpBytes / $bytesPerGb), 3)
        ScanFailures = $scanFailures
        DeleteFailures = $deleteFailures
        SkippedReparsePoints = $skippedReparsePoints
    }
    Extensions = $extensionResults.ToArray()
    FailureTypes = $failureResults.ToArray()
}

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$jsonPath = Join-Path $validatedOutputPath ('karv-authorized-low-risk-cleanup-' + $Mode.ToLowerInvariant() + '-' + $timestamp + '.json')
$markdownPath = Join-Path $validatedOutputPath ('karv-authorized-low-risk-cleanup-' + $Mode.ToLowerInvariant() + '-summary-' + $timestamp + '.md')
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 10), $utf8NoBom)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# KARV - limpeza autorizada de temporarios de baixo risco')
$lines.Add('')
$lines.Add('- Modo: `' + $Mode + '`')
$lines.Add('- Unidade C exclusiva: `sim`')
$lines.Add('- Unidade E acessada: `nao`')
$lines.Add('- Temp do usuario exclusivo: `sim`')
$lines.Add('- Extensoes removiveis: `.tmp`, `.log`, `.etl`')
$lines.Add('- Dumps `.dmp` preservados: `sim`')
$lines.Add('- Arquivos Blender preservados: `sim`')
$lines.Add('- Pastas removidas: `nao`')
$lines.Add('')
$lines.Add('## Resultado')
$lines.Add('')
$lines.Add('- Candidatos: `' + [string]$candidateFiles + '`')
$lines.Add('- Volume candidato: `' + [string]([Math]::Round(([double]$candidateBytes / $bytesPerGb), 3)) + ' GB`')
$lines.Add('- Removidos: `' + [string]$removedFiles + '`')
$lines.Add('- Volume removido: `' + [string]([Math]::Round(([double]$removedBytes / $bytesPerGb), 3)) + ' GB`')
$lines.Add('- Dumps preservados: `' + [string]$preservedDmpFiles + '`')
$lines.Add('- Falhas de exclusao: `' + [string]$deleteFailures + '`')
$lines.Add('- Falhas de leitura: `' + [string]$scanFailures + '`')
[System.IO.File]::WriteAllLines($markdownPath, $lines.ToArray(), $utf8NoBom)

[pscustomobject]@{
    Status = if ($deleteFailures -eq 0 -and $scanFailures -eq 0) { 'Passed' } else { 'Partial' }
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    Mode = $Mode
    CandidateFiles = $candidateFiles
    CandidateGB = [Math]::Round(([double]$candidateBytes / $bytesPerGb), 3)
    RemovedFiles = $removedFiles
    RemovedGB = [Math]::Round(([double]$removedBytes / $bytesPerGb), 3)
    PreservedDiagnosticDumpFiles = $preservedDmpFiles
    PreservedDiagnosticDumpGB = [Math]::Round(([double]$preservedDmpBytes / $bytesPerGb), 3)
    ScanFailures = $scanFailures
    DeleteFailures = $deleteFailures
    ExcludedDriveEAccessed = $false
    ReportsCreated = 2
}
