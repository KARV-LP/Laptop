#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string]$Mode = 'Preview',

    [string]$OutputDirectory,

    [Parameter(DontShow = $true)]
    [object[]]$InputApplications
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.1'
$collectorName = 'ProtectedApplicationInventory'
$nowUtc = [DateTime]::UtcNow

$protectedFamilies = @(
    'Blender',
    'Rhino',
    'AdobeSubstance',
    'Canon',
    'GitHubDesktop',
    'Git',
    'CloudflareWrangler',
    'NodeJs',
    'Python'
)

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
    $inside = [string]::Equals(
        $normalizedRoot,
        $normalizedPath,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or $normalizedPath.StartsWith(
        $normalizedRoot + '\',
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if (-not $inside) { throw 'Output must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.' }
    return $fullPath
}

function Test-ExcludedDriveReference {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch($Text, '(?i)(^|[\s"''=])E:\\')
}

function Convert-ToHtmlText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-ProtectedFamily {
    param(
        [AllowNull()][string]$DisplayName,
        [AllowNull()][string]$Publisher
    )

    $text = (([string]$DisplayName) + ' ' + ([string]$Publisher).Trim()).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    if ($text.Contains('substance 3d') -or $text.Contains('adobe substance')) {
        return 'AdobeSubstance'
    }
    if ($text.Contains('github desktop')) {
        return 'GitHubDesktop'
    }
    if ($text.Contains('cloudflare') -or $text.Contains('wrangler')) {
        return 'CloudflareWrangler'
    }
    if ($text.Contains('node.js') -or $text.Contains('nodejs')) {
        return 'NodeJs'
    }
    if ($text.Contains('python')) {
        return 'Python'
    }
    if ($text.Contains('rhinoceros') -or $text.Contains('rhino')) {
        return 'Rhino'
    }
    if ($text.Contains('blender')) {
        return 'Blender'
    }
    if ($text.Contains('canon')) {
        return 'Canon'
    }
    if (-not $text.Contains('github') -and $text -match '(^|\s)git(\s|$)') {
        return 'Git'
    }

    return $null
}

function Read-RegistryApplications {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Destination,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Failures
    )

    $locations = @(
        [pscustomobject]@{
            Hive = [Microsoft.Win32.RegistryHive]::LocalMachine
            View = [Microsoft.Win32.RegistryView]::Registry64
            Scope = 'LocalMachine'
            Architecture = 'Registry64'
        },
        [pscustomobject]@{
            Hive = [Microsoft.Win32.RegistryHive]::LocalMachine
            View = [Microsoft.Win32.RegistryView]::Registry32
            Scope = 'LocalMachine'
            Architecture = 'Registry32'
        },
        [pscustomobject]@{
            Hive = [Microsoft.Win32.RegistryHive]::CurrentUser
            View = [Microsoft.Win32.RegistryView]::Registry64
            Scope = 'CurrentUser'
            Architecture = 'Registry64'
        },
        [pscustomobject]@{
            Hive = [Microsoft.Win32.RegistryHive]::CurrentUser
            View = [Microsoft.Win32.RegistryView]::Registry32
            Scope = 'CurrentUser'
            Architecture = 'Registry32'
        }
    )

    $uninstallPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'

    foreach ($location in $locations) {
        $baseKey = $null
        $uninstallKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($location.Hive, $location.View)
            $uninstallKey = $baseKey.OpenSubKey($uninstallPath, $false)
            if ($null -eq $uninstallKey) { continue }

            foreach ($subKeyName in @($uninstallKey.GetSubKeyNames())) {
                $appKey = $null
                try {
                    $appKey = $uninstallKey.OpenSubKey($subKeyName, $false)
                    if ($null -eq $appKey) { continue }

                    $displayName = [string]$appKey.GetValue(
                        'DisplayName',
                        $null,
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                    )
                    if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

                    $Destination.Add([pscustomobject]@{
                        DisplayName = $displayName
                        DisplayVersion = [string]$appKey.GetValue(
                            'DisplayVersion',
                            $null,
                            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                        )
                        Publisher = [string]$appKey.GetValue(
                            'Publisher',
                            $null,
                            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                        )
                        InstallDate = [string]$appKey.GetValue(
                            'InstallDate',
                            $null,
                            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                        )
                        InstallLocation = [string]$appKey.GetValue(
                            'InstallLocation',
                            $null,
                            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                        )
                        DisplayIcon = [string]$appKey.GetValue(
                            'DisplayIcon',
                            $null,
                            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                        )
                        Scope = $location.Scope
                        Architecture = $location.Architecture
                        RegistryKeyName = $subKeyName
                    })
                }
                catch {
                    $Failures.Add([pscustomobject]@{
                        Section = 'ApplicationRecord'
                        ErrorType = $_.Exception.GetType().Name
                    })
                }
                finally {
                    if ($null -ne $appKey) { $appKey.Dispose() }
                }
            }
        }
        catch {
            $Failures.Add([pscustomobject]@{
                Section = 'RegistryLocation'
                ErrorType = $_.Exception.GetType().Name
            })
        }
        finally {
            if ($null -ne $uninstallKey) { $uninstallKey.Dispose() }
            if ($null -ne $baseKey) { $baseKey.Dispose() }
        }
    }
}

if ($Mode -ne 'Preview') { throw 'Only Preview mode is permitted in Fase 4A.' }
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
if ($allowedDrive -ne 'C:') { throw 'LOCALAPPDATA diagnostics root must be on drive C:.' }

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = $allowedRoot }
$validatedOutput = Get-ValidatedOutputPath -Path $OutputDirectory -AllowedRoot $allowedRoot
[System.IO.Directory]::CreateDirectory($validatedOutput) | Out-Null

$sectionFailures = New-Object System.Collections.Generic.List[object]
$rawApplications = New-Object System.Collections.Generic.List[object]

if ($PSBoundParameters.ContainsKey('InputApplications')) {
    foreach ($application in @($InputApplications)) {
        if ($null -ne $application) { $rawApplications.Add($application) }
    }
}
else {
    Read-RegistryApplications -Destination $rawApplications -Failures $sectionFailures
}

$familyCounts = @{}
foreach ($family in $protectedFamilies) { $familyCounts[$family] = 0L }

$protectedRecords = New-Object System.Collections.Generic.List[object]
$unknownVersionRecords = 0L
$excludedDriveReferenceRecords = 0L

foreach ($application in $rawApplications.ToArray()) {
    try {
        $displayName = [string](Get-OptionalPropertyValue -Object $application -Name 'DisplayName')
        $displayVersion = [string](Get-OptionalPropertyValue -Object $application -Name 'DisplayVersion')
        $publisher = [string](Get-OptionalPropertyValue -Object $application -Name 'Publisher')
        $installDate = [string](Get-OptionalPropertyValue -Object $application -Name 'InstallDate')
        $installLocation = [string](Get-OptionalPropertyValue -Object $application -Name 'InstallLocation')
        $displayIcon = [string](Get-OptionalPropertyValue -Object $application -Name 'DisplayIcon')
        $scope = [string](Get-OptionalPropertyValue -Object $application -Name 'Scope')
        $architecture = [string](Get-OptionalPropertyValue -Object $application -Name 'Architecture')
        $registryKeyName = [string](Get-OptionalPropertyValue -Object $application -Name 'RegistryKeyName')

        $family = Get-ProtectedFamily -DisplayName $displayName -Publisher $publisher
        if ([string]::IsNullOrWhiteSpace($family)) { continue }

        $hasExcludedDriveReference = Test-ExcludedDriveReference -Text (
            $installLocation + ' ' + $displayIcon
        )
        if ($hasExcludedDriveReference) { $excludedDriveReferenceRecords++ }
        if ([string]::IsNullOrWhiteSpace($displayVersion)) { $unknownVersionRecords++ }

        $familyCounts[$family]++
        $protectedRecords.Add([pscustomobject]@{
            Family = $family
            DisplayName = $displayName
            DisplayVersion = $displayVersion
            Publisher = $publisher
            InstallDate = $installDate
            InstallLocation = if ($hasExcludedDriveReference) {
                '[REDACTED_EXCLUDED_DRIVE]'
            }
            else {
                $installLocation
            }
            DisplayIcon = if ($hasExcludedDriveReference) {
                '[REDACTED_EXCLUDED_DRIVE]'
            }
            else {
                $displayIcon
            }
            Scope = $scope
            Architecture = $architecture
            RegistryKeyName = $registryKeyName
            ReferencesExcludedDriveE = $hasExcludedDriveReference
            Protected = $true
        })
    }
    catch {
        $sectionFailures.Add([pscustomobject]@{
            Section = 'ProtectedApplicationRecord'
            ErrorType = $_.Exception.GetType().Name
        })
    }
}

$orderedRecords = @(
    $protectedRecords.ToArray() |
        Sort-Object Family, DisplayName, DisplayVersion, Scope, Architecture
)

$familyCoverage = @(
    $protectedFamilies | ForEach-Object {
        [pscustomobject]@{
            Family = $_
            Records = [int64]$familyCounts[$_]
            Present = [bool]($familyCounts[$_] -gt 0)
        }
    }
)

$familiesFound = [int64]@($familyCoverage | Where-Object { $_.Present }).Count
$familiesMissing = [int64]($protectedFamilies.Count - $familiesFound)
$familiesWithMultipleRecords = [int64]@(
    $familyCoverage | Where-Object { $_.Records -gt 1 }
).Count

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine('<!doctype html>')
[void]$builder.AppendLine('<html lang="pt-BR"><head><meta charset="utf-8">')
[void]$builder.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
[void]$builder.AppendLine('<title>KARV — Aplicativos protegidos</title>')
[void]$builder.AppendLine('<style>')
[void]$builder.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f4f6f8;color:#17212b}main{max-width:1500px;margin:0 auto;padding:28px}header,section{background:#fff;border:1px solid #d9e0e7;border-radius:10px;padding:20px;margin-bottom:18px}h1{margin:0 0 8px;font-size:26px}h2{margin:0 0 14px;font-size:20px}.warning{background:#fff4d6;border-left:5px solid #c78a00;padding:12px;margin-top:14px}.metrics{display:flex;gap:12px;flex-wrap:wrap;margin-top:16px}.metric{background:#edf2f7;border-radius:8px;padding:10px 14px}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid #dfe5eb;padding:9px;word-break:break-word}th{background:#edf2f7;position:sticky;top:0}.present{font-weight:600}.missing{color:#8a3d00;font-weight:600}.footer{font-size:12px;color:#5b6773}</style>')
[void]$builder.AppendLine('</head><body><main>')
[void]$builder.AppendLine('<header><h1>KARV — Inventário local de aplicativos protegidos</h1>')
[void]$builder.AppendLine('<p>Metadados de instalação coletados somente do Registro. Nenhum aplicativo ou arquivo instalado foi aberto ou executado.</p>')
[void]$builder.AppendLine('<div class="warning"><strong>Dados locais sensíveis.</strong> Não compartilhe este HTML, capturas, versões, fornecedores ou caminhos.</div>')
[void]$builder.AppendLine('<div class="metrics">')
[void]$builder.AppendLine('<div class="metric"><strong>Registros protegidos:</strong> ' + $orderedRecords.Count + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Famílias encontradas:</strong> ' + $familiesFound + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Famílias ausentes:</strong> ' + $familiesMissing + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Versões desconhecidas:</strong> ' + $unknownVersionRecords + '</div>')
[void]$builder.AppendLine('</div></header>')

[void]$builder.AppendLine('<section><h2>Cobertura das famílias protegidas</h2><div class="table-wrap"><table><thead><tr><th>Família</th><th>Registros</th><th>Estado local</th></tr></thead><tbody>')
foreach ($coverage in $familyCoverage) {
    $statusText = if ($coverage.Present) { 'Encontrada' } else { 'Não identificada no Registro' }
    $statusClass = if ($coverage.Present) { 'present' } else { 'missing' }
    [void]$builder.AppendLine('<tr><td>' + (Convert-ToHtmlText $coverage.Family) + '</td><td>' + $coverage.Records + '</td><td class="' + $statusClass + '">' + $statusText + '</td></tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')

[void]$builder.AppendLine('<section><h2>Registros locais protegidos</h2><div class="table-wrap"><table><thead><tr>')
foreach ($header in @('Família', 'Aplicativo', 'Versão', 'Fornecedor', 'Escopo', 'Arquitetura', 'Data', 'Local', 'Referência E:')) {
    [void]$builder.AppendLine('<th>' + (Convert-ToHtmlText $header) + '</th>')
}
[void]$builder.AppendLine('</tr></thead><tbody>')
foreach ($record in $orderedRecords) {
    [void]$builder.AppendLine('<tr>')
    foreach ($value in @(
        $record.Family,
        $record.DisplayName,
        $record.DisplayVersion,
        $record.Publisher,
        $record.Scope,
        $record.Architecture,
        $record.InstallDate,
        $record.InstallLocation,
        $record.ReferencesExcludedDriveE
    )) {
        [void]$builder.AppendLine('<td>' + (Convert-ToHtmlText $value) + '</td>')
    }
    [void]$builder.AppendLine('</tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')
[void]$builder.AppendLine('<section class="footer">Este painel não consulta atualizações e não autoriza atualizar, reparar ou desinstalar qualquer aplicativo.</section>')
[void]$builder.AppendLine('</main></body></html>')

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$manifestPath = Join-Path $validatedOutput ('karv-protected-applications-local-manifest-' + $timestamp + '.json')
$summaryPath = Join-Path $validatedOutput ('karv-protected-applications-sanitized-summary-' + $timestamp + '.json')
$htmlPath = Join-Path $validatedOutput ('karv-protected-applications-panel-' + $timestamp + '.html')

$manifest = [pscustomobject]@{
    Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    SensitiveLocalData = $true
    LocalOnly = $true
    Scope = [pscustomobject]@{
        RegistryUninstallMetadata = $true
        RegistryViews = 4
        ProtectedFamiliesOnly = $true
        ApplicationsExecuted = $false
        InstalledFilesOpened = $false
        UpdatesChecked = $false
        NetworkCollected = $false
    }
    FamilyCoverage = $familyCoverage
    Applications = $orderedRecords
}

$summary = [pscustomobject]@{
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    Privacy = [pscustomobject]@{
        SummarySanitized = $true
        SummaryContainsApplicationNames = $false
        SummaryContainsVersions = $false
        SummaryContainsPublishers = $false
        SummaryContainsPaths = $false
        DetailedManifestContainsSensitiveLocalData = $true
        DetailedManifestLocalOnly = $true
        HtmlContainsSensitiveLocalData = $true
        HtmlLocalOnly = $true
        ExcludedDriveEAccessed = $false
        ExcludedDriveReferencesRedacted = $true
    }
    Scope = [pscustomobject]@{
        ApplicationsEnumerated = [int64]$rawApplications.Count
        RegistryUninstallMetadata = $true
        RegistryViews = 4
        ProtectedFamiliesExpected = [int64]$protectedFamilies.Count
        ProtectedFamiliesOnly = $true
        ApplicationsExecuted = $false
        InstalledFilesOpened = $false
        HashesCalculated = $false
        SignaturesRead = $false
        UpdatesChecked = $false
        NetworkCollected = $false
        ActionsAvailable = $false
    }
    Summary = [pscustomobject]@{
        ProtectedRecords = [int64]$orderedRecords.Count
        ProtectedFamiliesFound = $familiesFound
        ProtectedFamiliesMissing = $familiesMissing
        FamiliesWithMultipleRecords = $familiesWithMultipleRecords
        UnknownVersionRecords = [int64]$unknownVersionRecords
        ExcludedDriveReferenceRecords = [int64]$excludedDriveReferenceRecords
    }
    SectionFailures = $sectionFailures.ToArray()
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), $utf8NoBom)
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 10), $utf8NoBom)
[System.IO.File]::WriteAllText($htmlPath, $builder.ToString(), $utf8NoBom)

[pscustomobject]@{
    Status = if ($sectionFailures.Count -eq 0) { 'Passed' } else { 'Partial' }
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    Mode = $Mode
    ApplicationsEnumerated = [int64]$rawApplications.Count
    ProtectedRecords = [int64]$orderedRecords.Count
    ProtectedFamiliesExpected = [int64]$protectedFamilies.Count
    ProtectedFamiliesFound = $familiesFound
    ProtectedFamiliesMissing = $familiesMissing
    FamiliesWithMultipleRecords = $familiesWithMultipleRecords
    UnknownVersionRecords = [int64]$unknownVersionRecords
    ExcludedDriveReferenceRecords = [int64]$excludedDriveReferenceRecords
    SectionFailures = [int64]$sectionFailures.Count
    ReportsCreated = 3
}
