#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string]$Mode = 'Preview',

    [string]$ManifestPath,
    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'BlendMediumRiskTriage'
$sourceCollector = 'BlendAutosaveReview'
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

function ConvertTo-HtmlEncodedText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text.Replace('&', '&amp;')
    $text = $text.Replace('<', '&lt;')
    $text = $text.Replace('>', '&gt;')
    $text = $text.Replace('"', '&quot;')
    $text = $text.Replace("'", '&#39;')
    return $text
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

function Get-SizeBucketName {
    param([Parameter(Mandatory = $true)][int64]$Length)

    if ($Length -lt 100MB) { return 'Under100MB' }
    if ($Length -lt 250MB) { return 'From100MBTo250MB' }
    if ($Length -lt 500MB) { return 'From250MBTo500MB' }
    return 'Over500MB'
}

function Get-AgeBucketName {
    param([Parameter(Mandatory = $true)][int]$AgeDays)

    if ($AgeDays -le 365) { return 'Days181To365' }
    if ($AgeDays -le 730) { return 'Days366To730' }
    return 'DaysOver730'
}

if ($Mode -ne 'Preview') {
    throw 'Only Preview mode is permitted in Fase 2F.'
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

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    if (-not [System.IO.Directory]::Exists($allowedOutputRoot)) {
        throw 'The approved diagnostics directory does not exist.'
    }

    $manifestCandidates = @(
        ([System.IO.DirectoryInfo]$allowedOutputRoot).GetFiles('karv-blend-autosave-local-manifest-*.json') |
            Sort-Object LastWriteTimeUtc -Descending
    )
    if ($manifestCandidates.Count -eq 0) {
        throw 'No approved Fase 2E local manifest was found.'
    }
    $ManifestPath = $manifestCandidates[0].FullName
}

$validatedManifestPath = Get-ValidatedCDrivePath -Path $ManifestPath -Purpose 'ManifestPath'
if (-not (Test-IsPathInsideRoot -Path $validatedManifestPath -Root $allowedOutputRoot)) {
    throw 'ManifestPath must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.'
}
if (-not [System.IO.File]::Exists($validatedManifestPath)) {
    throw 'ManifestPath does not exist.'
}

$manifestFileName = [System.IO.Path]::GetFileName($validatedManifestPath)
if ($manifestFileName -notmatch '^karv-blend-autosave-local-manifest-\d{8}-\d{6}\.json$') {
    throw 'ManifestPath is not an approved Fase 2E local manifest name.'
}

$manifestText = [System.IO.File]::ReadAllText($validatedManifestPath)
$manifest = $manifestText | ConvertFrom-Json

if ($manifest.Collector -ne $sourceCollector -or
    $manifest.Mode -ne 'Preview' -or
    $manifest.SensitiveLocalData -ne $true -or
    $manifest.LocalOnly -ne $true) {
    throw 'Manifest identity, mode, or local-only sensitivity markers are invalid.'
}

$validatedSourceRoot = Get-ValidatedCDrivePath -Path ([string]$manifest.SourceRoot) -Purpose 'ManifestSourceRoot'
$mediumRiskItems = New-Object System.Collections.Generic.List[object]

foreach ($item in @($manifest.Items)) {
    if ($item.RiskClass -ne 'MediumRiskReview') { continue }
    if ($item.Protected -ne $true) {
        throw 'A MediumRiskReview item is not marked as protected.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.ReviewId) -or
        [string]::IsNullOrWhiteSpace([string]$item.FileName) -or
        [string]::IsNullOrWhiteSpace([string]$item.FullPath)) {
        throw 'A MediumRiskReview item is missing required local metadata.'
    }

    $validatedItemPath = Get-ValidatedCDrivePath -Path ([string]$item.FullPath) -Purpose 'ManifestItemPath'
    if (-not (Test-IsPathInsideRoot -Path $validatedItemPath -Root $validatedSourceRoot)) {
        throw 'A MediumRiskReview item is outside the manifest source root.'
    }
    if (-not [string]::Equals(
        [System.IO.Path]::GetExtension([string]$item.FileName),
        '.blend',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'A MediumRiskReview item is not a .blend metadata record.'
    }

    $length = [int64]$item.LengthBytes
    $ageDays = [int]$item.AgeDays
    if ($length -lt 0 -or $ageDays -lt 0) {
        throw 'A MediumRiskReview item contains invalid size or age metadata.'
    }

    $mediumRiskItems.Add([pscustomobject]@{
        ReviewId = [string]$item.ReviewId
        FileName = [string]$item.FileName
        FullPath = $validatedItemPath
        LengthBytes = $length
        SizeMB = [Math]::Round(([double]$length / 1MB), 3)
        AgeDays = $ageDays
        LastWriteUtc = [string]$item.LastWriteUtc
        Protected = $true
    })
}

$orderedItems = @(
    $mediumRiskItems.ToArray() |
        Sort-Object `
            @{ Expression = { $_.LengthBytes }; Descending = $true },
            @{ Expression = { $_.AgeDays }; Descending = $true },
            @{ Expression = { $_.ReviewId }; Descending = $false }
)

$totalMetric = New-Metric
$sizeBuckets = [ordered]@{
    Under100MB = New-Metric
    From100MBTo250MB = New-Metric
    From250MBTo500MB = New-Metric
    Over500MB = New-Metric
}
$ageBuckets = [ordered]@{
    Days181To365 = New-Metric
    Days366To730 = New-Metric
    DaysOver730 = New-Metric
}
$largestItemBytes = 0L

foreach ($item in $orderedItems) {
    Add-ToMetric -Metric $totalMetric -Length $item.LengthBytes
    Add-ToMetric -Metric $sizeBuckets[(Get-SizeBucketName -Length $item.LengthBytes)] -Length $item.LengthBytes
    Add-ToMetric -Metric $ageBuckets[(Get-AgeBucketName -AgeDays $item.AgeDays)] -Length $item.LengthBytes
    if ($item.LengthBytes -gt $largestItemBytes) { $largestItemBytes = $item.LengthBytes }
}

$totalMetric = Complete-Metric -Metric $totalMetric
$completedSizeBuckets = [ordered]@{}
foreach ($bucketName in $sizeBuckets.Keys) {
    $completedSizeBuckets[$bucketName] = Complete-Metric -Metric $sizeBuckets[$bucketName]
}
$completedAgeBuckets = [ordered]@{}
foreach ($bucketName in $ageBuckets.Keys) {
    $completedAgeBuckets[$bucketName] = Complete-Metric -Metric $ageBuckets[$bucketName]
}

$tableRows = New-Object System.Collections.Generic.List[string]
for ($index = 0; $index -lt $orderedItems.Count; $index++) {
    $item = $orderedItems[$index]
    $priority = $index + 1
    $tableRows.Add(
        '<tr>' +
        '<td class="priority">' + $priority + '</td>' +
        '<td>' + (ConvertTo-HtmlEncodedText $item.ReviewId) + '</td>' +
        '<td>' + (ConvertTo-HtmlEncodedText $item.FileName) + '</td>' +
        '<td class="path">' + (ConvertTo-HtmlEncodedText $item.FullPath) + '</td>' +
        '<td class="number">' + (ConvertTo-HtmlEncodedText $item.SizeMB) + '</td>' +
        '<td class="number">' + (ConvertTo-HtmlEncodedText $item.AgeDays) + '</td>' +
        '<td>' + (ConvertTo-HtmlEncodedText $item.LastWriteUtc) + '</td>' +
        '<td>Protected</td>' +
        '</tr>'
    )
}

if ($tableRows.Count -eq 0) {
    $tableRows.Add('<tr><td colspan="8">No MediumRiskReview items were found in the approved manifest.</td></tr>')
}

$generatedAtText = $nowUtc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
$html = @"
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>KARV - Triagem local MediumRiskReview</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #18202a; background: #f3f5f7; }
main { max-width: 1600px; margin: 0 auto; background: #ffffff; padding: 24px; border: 1px solid #d8dee5; border-radius: 10px; }
h1 { margin: 0 0 8px 0; font-size: 26px; }
.warning { border: 2px solid #9b2c2c; background: #fff5f5; padding: 14px; margin: 18px 0; font-weight: 700; }
.summary { display: grid; grid-template-columns: repeat(3, minmax(180px, 1fr)); gap: 12px; margin: 18px 0; }
.card { border: 1px solid #d8dee5; border-radius: 8px; padding: 12px; background: #f8fafc; }
.card strong { display: block; font-size: 20px; margin-top: 4px; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th, td { border: 1px solid #d8dee5; padding: 8px; text-align: left; vertical-align: top; }
th { background: #e9eef3; position: sticky; top: 0; }
tr:nth-child(even) { background: #f8fafc; }
.priority { font-weight: 700; text-align: center; }
.number { text-align: right; white-space: nowrap; }
.path { overflow-wrap: anywhere; font-family: Consolas, monospace; }
.note { margin-top: 18px; font-size: 13px; color: #4a5568; }
</style>
</head>
<body>
<main>
<h1>Fase 2F - Triagem local assistida</h1>
<div>Classe exibida: <strong>MediumRiskReview</strong> | Ordem: maior tamanho primeiro | Gerado em: $(ConvertTo-HtmlEncodedText $generatedAtText)</div>
<div class="warning">DADOS LOCAIS SENSIVEIS. NAO COMPARTILHAR, NAO ENVIAR AO CHAT E NAO COMMITAR. ESTE PAINEL NAO AUTORIZA ABERTURA, MOVIMENTACAO, RENOMEACAO OU EXCLUSAO.</div>
<section class="summary">
<div class="card">Arquivos priorizados<strong>$(ConvertTo-HtmlEncodedText $totalMetric.Files)</strong></div>
<div class="card">Volume total (GB)<strong>$(ConvertTo-HtmlEncodedText $totalMetric.GB)</strong></div>
<div class="card">Maior item (MB)<strong>$(ConvertTo-HtmlEncodedText ([Math]::Round(([double]$largestItemBytes / 1MB), 3)))</strong></div>
</section>
<table>
<thead>
<tr><th>Prioridade</th><th>ReviewId</th><th>Nome</th><th>Caminho local</th><th>Tamanho MB</th><th>Idade dias</th><th>Modificado UTC</th><th>Estado</th></tr>
</thead>
<tbody>
$($tableRows -join [Environment]::NewLine)
</tbody>
</table>
<div class="note">Relatorio estatico e somente informativo. Sem links, botoes, formularios, JavaScript ou comandos sobre arquivos.</div>
</main>
</body>
</html>
"@

$sectionFailures = @()
$summary = [pscustomobject]@{
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    SourceCollector = $sourceCollector
    Selection = [pscustomobject]@{
        RiskClass = 'MediumRiskReview'
        OrderBy = 'LengthBytesDescendingThenAgeDaysDescending'
        SourceManifestAutoDetected = [string]::IsNullOrWhiteSpace($PSBoundParameters['ManifestPath'])
    }
    Privacy = [pscustomobject]@{
        SummarySanitized = $true
        SummaryContainsFileNames = $false
        SummaryContainsFullPaths = $false
        SummaryContainsReviewIds = $false
        SummaryContainsManifestPath = $false
        HtmlContainsSensitiveLocalData = $true
        HtmlLocalOnly = $true
        BlendFilesEnumerated = $false
        FileContentRead = $false
        HashesCalculated = $false
        NetworkCollected = $false
        ExcludedDriveE = $true
        ActionsAvailable = $false
    }
    Summary = [pscustomobject]@{
        Files = $totalMetric.Files
        Bytes = $totalMetric.Bytes
        GB = $totalMetric.GB
        LargestItemMB = [Math]::Round(([double]$largestItemBytes / 1MB), 3)
    }
    SizeBuckets = [pscustomobject]$completedSizeBuckets
    AgeBuckets = [pscustomobject]$completedAgeBuckets
    SectionFailures = $sectionFailures
}

[System.IO.Directory]::CreateDirectory($validatedOutputDirectory) | Out-Null
$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$htmlPath = Join-Path $validatedOutputDirectory ('karv-blend-medium-risk-triage-' + $timestamp + '.html')
$summaryPath = Join-Path $validatedOutputDirectory ('karv-blend-medium-risk-triage-sanitized-summary-' + $timestamp + '.json')
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($htmlPath, $html, $utf8NoBom)
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 10), $utf8NoBom)

[pscustomobject]@{
    Status = 'Passed'
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    Mode = $Mode
    MediumRiskFiles = $totalMetric.Files
    TotalGB = $totalMetric.GB
    LargestItemMB = [Math]::Round(([double]$largestItemBytes / 1MB), 3)
    SectionFailures = 0
    ReportsCreated = 2
}
