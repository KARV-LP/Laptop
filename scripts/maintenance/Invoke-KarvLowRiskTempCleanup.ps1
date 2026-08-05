#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply')]
    [string]$Mode = 'Preview',
    [string]$ConfirmationToken,
    [switch]$ApplicationsClosed,
    [string]$OutputDirectory,
    [string]$TargetDrive = 'C:',
    [string]$UserTempPath,
    [int]$MinimumAgeDays = 90
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$collectorName = 'LowRiskTempCleanup'
$scriptVersion = '1.0.0'
$excludedDrive = 'E:'
$requiredConfirmationToken = 'KARV-LOW-RISK-CLEANUP-AUTHORIZED'
$bytesPerGb = 1GB
$nowUtc = [DateTime]::UtcNow
$allowedExtensions = @('.tmp', '.log', '.etl', '.dmp')

function Normalize-DriveName {
    param([Parameter(Mandatory = $true)][string]$DriveName)

    $value = $DriveName.Trim().TrimEnd('\')
    if ($value -match '^[A-Za-z]$') {
        $value += ':'
    }
    if ($value -notmatch '^[A-Za-z]:$') {
        throw 'TargetDrive must use the format C:.'
    }
    return $value.ToUpperInvariant()
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

function New-ExtensionSummary {
    param([Parameter(Mandatory = $true)][string]$Extension)

    $disposition = 'CandidateAfterApplicationClosure'
    if ($Extension -eq '.dmp') {
        $disposition = 'ReviewThenDelete'
    }

    return [ordered]@{
        Extension   = $Extension
        Disposition = $disposition
        Candidates  = 0L
        CandidateBytes = 0L
        Removed     = 0L
        RemovedBytes = 0L
        Failures    = 0L
    }
}

function Add-Failure {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$FailureMap,
        [Parameter(Mandatory = $true)][string]$ErrorType
    )

    if (-not $FailureMap.Contains($ErrorType)) {
        $FailureMap[$ErrorType] = 0L
    }
    $FailureMap[$ErrorType]++
}

$normalizedTargetDrive = Normalize-DriveName -DriveName $TargetDrive
if ($normalizedTargetDrive -eq $excludedDrive) {
    throw 'Drive E: is permanently excluded from KARV laptop maintenance.'
}

if ($MinimumAgeDays -lt 90) {
    throw 'MinimumAgeDays cannot be lower than 90 for this cleanup class.'
}

if ($Mode -eq 'Apply') {
    if (-not $ApplicationsClosed.IsPresent) {
        throw 'Apply mode requires -ApplicationsClosed after closing active applications.'
    }
    if ($ConfirmationToken -cne $requiredConfirmationToken) {
        throw 'Apply mode requires the exact confirmation token.'
    }
}

if ([string]::IsNullOrWhiteSpace($UserTempPath)) {
    $UserTempPath = [System.IO.Path]::GetTempPath()
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable. Provide OutputDirectory explicitly.'
    }
    $OutputDirectory = Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'
}

$validatedUserTempPath = Get-ValidatedLocalPath -Path $UserTempPath -AllowedDrive $normalizedTargetDrive -Purpose 'UserTempPath'
$validatedOutputDirectory = Get-ValidatedLocalPath -Path $OutputDirectory -AllowedDrive $normalizedTargetDrive -Purpose 'OutputDirectory'
[System.IO.Directory]::CreateDirectory($validatedOutputDirectory) | Out-Null

$extensionSummaries = [ordered]@{}
foreach ($extension in $allowedExtensions) {
    $extensionSummaries[$extension] = New-ExtensionSummary -Extension $extension
}

$totalScannedFiles = 0L
$totalCandidateFiles = 0L
$totalCandidateBytes = 0L
$totalRemovedFiles = 0L
$totalRemovedBytes = 0L
$scanErrors = 0L
$deleteFailures = 0L
$skippedReparsePoints = 0L
$failureTypes = [ordered]@{}

if ([System.IO.Directory]::Exists($validatedUserTempPath)) {
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
            Add-Failure -FailureMap $failureTypes -ErrorType $_.Exception.GetType().Name
            $files = @()
        }

        foreach ($file in $files) {
            $totalScannedFiles++
            try {
                if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $skippedReparsePoints++
                    continue
                }

                $extension = $file.Extension.ToLowerInvariant()
                if ($allowedExtensions -notcontains $extension) {
                    continue
                }

                $ageDays = [Math]::Floor(($nowUtc - $file.LastWriteTimeUtc).TotalDays)
                if ($ageDays -le $MinimumAgeDays) {
                    continue
                }

                $length = [int64]$file.Length
                $summary = $extensionSummaries[$extension]
                $summary.Candidates++
                $summary.CandidateBytes += $length
                $totalCandidateFiles++
                $totalCandidateBytes += $length

                if ($Mode -eq 'Apply') {
                    try {
                        [System.IO.File]::Delete($file.FullName)
                        $summary.Removed++
                        $summary.RemovedBytes += $length
                        $totalRemovedFiles++
                        $totalRemovedBytes += $length
                    }
                    catch {
                        $summary.Failures++
                        $deleteFailures++
                        Add-Failure -FailureMap $failureTypes -ErrorType $_.Exception.GetType().Name
                    }
                }
            }
            catch {
                $scanErrors++
                Add-Failure -FailureMap $failureTypes -ErrorType $_.Exception.GetType().Name
            }
        }

        try {
            $childDirectories = @($currentDirectory.GetDirectories())
        }
        catch {
            $scanErrors++
            Add-Failure -FailureMap $failureTypes -ErrorType $_.Exception.GetType().Name
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
                Add-Failure -FailureMap $failureTypes -ErrorType $_.Exception.GetType().Name
            }
        }
    }
}

$extensionResults = New-Object System.Collections.Generic.List[object]
foreach ($extension in $allowedExtensions) {
    $item = $extensionSummaries[$extension]
    $extensionResults.Add([pscustomobject]@{
        Extension       = $item.Extension
        Disposition     = $item.Disposition
        Candidates      = $item.Candidates
        CandidateGB     = [Math]::Round(([double]$item.CandidateBytes / $bytesPerGb), 3)
        Removed         = $item.Removed
        RemovedGB       = [Math]::Round(([double]$item.RemovedBytes / $bytesPerGb), 3)
        Failures        = $item.Failures
    })
}

$failureResults = New-Object System.Collections.Generic.List[object]
foreach ($errorType in $failureTypes.Keys) {
    $failureResults.Add([pscustomobject]@{
        ErrorType = $errorType
        Count     = $failureTypes[$errorType]
    })
}

$privacy = [pscustomobject]@{
    Sanitized              = $true
    FileNamesCollected     = $false
    FullPathsCollected     = $false
    FileContentsCollected  = $false
    UserIdentityCollected  = $false
    NetworkCollected       = $false
    ExcludedDriveE         = $true
}

$report = [pscustomobject]@{
    Collector         = $collectorName
    ScriptVersion     = $scriptVersion
    CollectedAtUtc    = $nowUtc.ToString('o')
    Mode              = $Mode
    TargetDrive       = $normalizedTargetDrive
    MinimumAgeDays    = $MinimumAgeDays
    AllowedExtensions = $allowedExtensions
    CleanupExecuted   = ($Mode -eq 'Apply')
    Privacy           = $privacy
    Summary           = [pscustomobject]@{
        ScannedFiles         = $totalScannedFiles
        CandidateFiles       = $totalCandidateFiles
        CandidateGB          = [Math]::Round(([double]$totalCandidateBytes / $bytesPerGb), 3)
        RemovedFiles         = $totalRemovedFiles
        RemovedGB            = [Math]::Round(([double]$totalRemovedBytes / $bytesPerGb), 3)
        ScanErrors           = $scanErrors
        DeleteFailures       = $deleteFailures
        SkippedReparsePoints = $skippedReparsePoints
    }
    Extensions        = $extensionResults.ToArray()
    FailureTypes      = $failureResults.ToArray()
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $validatedOutputDirectory ('karv-low-risk-temp-cleanup-' + $Mode.ToLowerInvariant() + '-' + $timestamp + '.json')
$markdownPath = Join-Path $validatedOutputDirectory ('karv-low-risk-temp-cleanup-' + $Mode.ToLowerInvariant() + '-summary-' + $timestamp + '.md')
$utf8 = New-Object System.Text.UTF8Encoding($true)

$json = $report | ConvertTo-Json -Depth 7
[System.IO.File]::WriteAllText($jsonPath, $json, $utf8)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# KARV - limpeza controlada de temporarios de baixo risco')
$lines.Add('')
$lines.Add('- Modo: `' + $Mode + '`')
$lines.Add('- Unidade analisada: `' + $normalizedTargetDrive + '`')
$lines.Add('- Unidade E: excluida permanentemente: `sim`')
$lines.Add('- Idade minima: `acima de ' + [string]$MinimumAgeDays + ' dias`')
$lines.Add('- Extensoes permitidas: `.tmp`, `.log`, `.etl`, `.dmp`')
$lines.Add('- Nomes de arquivos registrados: `nao`')
$lines.Add('- Caminhos completos registrados: `nao`')
$lines.Add('- Limpeza executada: `' + $(if ($Mode -eq 'Apply') { 'sim' } else { 'nao' }) + '`')
$lines.Add('')
$lines.Add('## Resumo')
$lines.Add('')
$lines.Add('- Arquivos candidatos: `' + [string]$totalCandidateFiles + '`')
$lines.Add('- Volume candidato: `' + [string]([Math]::Round(([double]$totalCandidateBytes / $bytesPerGb), 3)) + ' GB`')
$lines.Add('- Arquivos removidos: `' + [string]$totalRemovedFiles + '`')
$lines.Add('- Volume removido: `' + [string]([Math]::Round(([double]$totalRemovedBytes / $bytesPerGb), 3)) + ' GB`')
$lines.Add('- Erros de leitura: `' + [string]$scanErrors + '`')
$lines.Add('- Falhas de exclusao: `' + [string]$deleteFailures + '`')
$lines.Add('- Pontos de nova analise ignorados: `' + [string]$skippedReparsePoints + '`')
$lines.Add('')
$lines.Add('## Extensoes')
$lines.Add('')
foreach ($item in $extensionResults) {
    $lines.Add('### ' + $item.Extension)
    $lines.Add('')
    $lines.Add('- Disposicao: `' + $item.Disposition + '`')
    $lines.Add('- Candidatos: `' + [string]$item.Candidates + ' arquivos / ' + [string]$item.CandidateGB + ' GB`')
    $lines.Add('- Removidos: `' + [string]$item.Removed + ' arquivos / ' + [string]$item.RemovedGB + ' GB`')
    $lines.Add('- Falhas: `' + [string]$item.Failures + '`')
    $lines.Add('')
}
$lines.Add('## Observacao operacional')
$lines.Add('')
$lines.Add('O modo Apply exige fechamento previo dos aplicativos, parametro explicito e token de confirmacao. Ativos tecnicos e extensoes nao autorizadas nunca entram nesta selecao.')

[System.IO.File]::WriteAllLines($markdownPath, $lines.ToArray(), $utf8)

[pscustomobject]@{
    Status          = 'Completed'
    Collector       = $collectorName
    ScriptVersion   = $scriptVersion
    Mode            = $Mode
    TargetDrive     = $normalizedTargetDrive
    ExcludedDriveE  = $true
    CandidateFiles  = $totalCandidateFiles
    CandidateGB     = [Math]::Round(([double]$totalCandidateBytes / $bytesPerGb), 3)
    RemovedFiles    = $totalRemovedFiles
    RemovedGB       = [Math]::Round(([double]$totalRemovedBytes / $bytesPerGb), 3)
    ScanErrors      = $scanErrors
    DeleteFailures  = $deleteFailures
    JsonReport      = $jsonPath
    MarkdownReport  = $markdownPath
}
