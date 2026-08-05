#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string]$Mode = 'Preview',

    [string]$OutputDirectory,

    [Parameter(DontShow = $true)]
    [AllowNull()]
    [object]$InputSnapshot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptVersion = '1.0.0'
$collectorName = 'WindowsUpdateReadiness'
$nowUtc = [DateTime]::UtcNow
$historyLimit = 200

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
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'Output path has no valid drive root.'
    }

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

    if (-not $inside) {
        throw 'Output must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.'
    }

    return $fullPath
}

function Convert-ToHtmlText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Add-SectionFailure {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Failures,

        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][System.Exception]$Exception
    )

    $Failures.Add([pscustomobject]@{
        Section = $Section
        ErrorType = $Exception.GetType().Name
    })
}

function Get-OperatingSystemMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Failures
    )

    $baseKey = $null
    $currentVersionKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $currentVersionKey = $baseKey.OpenSubKey(
            'SOFTWARE\Microsoft\Windows NT\CurrentVersion',
            $false
        )
        if ($null -eq $currentVersionKey) {
            throw 'Windows current-version registry key is unavailable.'
        }

        $ubrValue = $currentVersionKey.GetValue(
            'UBR',
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )

        return [pscustomobject]@{
            ProductName = [string]$currentVersionKey.GetValue(
                'ProductName',
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            DisplayVersion = [string]$currentVersionKey.GetValue(
                'DisplayVersion',
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            EditionId = [string]$currentVersionKey.GetValue(
                'EditionID',
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            InstallationType = [string]$currentVersionKey.GetValue(
                'InstallationType',
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            CurrentBuild = [string]$currentVersionKey.GetValue(
                'CurrentBuildNumber',
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            UpdateBuildRevision = if ($null -eq $ubrValue) { $null } else { [int64]$ubrValue }
        }
    }
    catch {
        Add-SectionFailure -Failures $Failures -Section 'OperatingSystemMetadata' -Exception $_.Exception
        return $null
    }
    finally {
        if ($null -ne $currentVersionKey) { $currentVersionKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Test-RegistryKeyExists {
    param(
        [Parameter(Mandatory = $true)][string]$SubKeyPath,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Failures,
        [Parameter(Mandatory = $true)][string]$Section
    )

    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $key = $baseKey.OpenSubKey($SubKeyPath, $false)
        return [bool]($null -ne $key)
    }
    catch {
        Add-SectionFailure -Failures $Failures -Section $Section -Exception $_.Exception
        return $false
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Test-RegistryValueNameExists {
    param(
        [Parameter(Mandatory = $true)][string]$SubKeyPath,
        [Parameter(Mandatory = $true)][string]$ValueName,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Failures,
        [Parameter(Mandatory = $true)][string]$Section
    )

    $baseKey = $null
    $key = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $key = $baseKey.OpenSubKey($SubKeyPath, $false)
        if ($null -eq $key) { return $false }
        return [bool](@($key.GetValueNames()) -contains $ValueName)
    }
    catch {
        Add-SectionFailure -Failures $Failures -Section $Section -Exception $_.Exception
        return $false
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Get-PendingRebootIndicators {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Failures
    )

    return @(
        [pscustomobject]@{
            Name = 'ComponentBasedServicing'
            Present = Test-RegistryKeyExists `
                -SubKeyPath 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' `
                -Failures $Failures `
                -Section 'PendingRebootComponentBasedServicing'
        },
        [pscustomobject]@{
            Name = 'WindowsUpdateRebootRequired'
            Present = Test-RegistryKeyExists `
                -SubKeyPath 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' `
                -Failures $Failures `
                -Section 'PendingRebootWindowsUpdate'
        },
        [pscustomobject]@{
            Name = 'PendingFileRenameOperations'
            Present = Test-RegistryValueNameExists `
                -SubKeyPath 'SYSTEM\CurrentControlSet\Control\Session Manager' `
                -ValueName 'PendingFileRenameOperations' `
                -Failures $Failures `
                -Section 'PendingRebootFileRename'
        }
    )
}

function Convert-UpdateResultCode {
    param([int]$ResultCode)

    switch ($ResultCode) {
        0 { return 'NotStarted' }
        1 { return 'InProgress' }
        2 { return 'Succeeded' }
        3 { return 'SucceededWithErrors' }
        4 { return 'Failed' }
        5 { return 'Aborted' }
        default { return 'Unknown' }
    }
}

function Convert-UpdateOperation {
    param([int]$Operation)

    switch ($Operation) {
        1 { return 'Installation' }
        2 { return 'Uninstallation' }
        default { return 'Unknown' }
    }
}

function Get-LocalUpdateHistory {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Failures,
        [Parameter(Mandatory = $true)][int]$MaximumEntries
    )

    $session = $null
    $searcher = $null
    $history = $null
    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $session.ClientApplicationID = 'KARV Laptop Diagnostics'
        $searcher = $session.CreateUpdateSearcher()
        $totalHistoryCount = [int]$searcher.GetTotalHistoryCount()
        $queryCount = [Math]::Min($totalHistoryCount, $MaximumEntries)
        if ($queryCount -le 0) { return @() }

        $history = $searcher.QueryHistory(0, $queryCount)
        $records = New-Object System.Collections.Generic.List[object]
        foreach ($entry in @($history)) {
            if ($null -eq $entry) { continue }
            $dateUtc = $null
            try {
                $dateUtc = ([DateTime]$entry.Date).ToUniversalTime().ToString('o')
            }
            catch {
                $dateUtc = $null
            }

            $records.Add([pscustomobject]@{
                DateUtc = $dateUtc
                Title = [string]$entry.Title
                ResultCode = [int]$entry.ResultCode
                Result = Convert-UpdateResultCode -ResultCode ([int]$entry.ResultCode)
                OperationCode = [int]$entry.Operation
                Operation = Convert-UpdateOperation -Operation ([int]$entry.Operation)
                HResult = [int64]$entry.HResult
            })
        }

        return $records.ToArray()
    }
    catch {
        Add-SectionFailure -Failures $Failures -Section 'UpdateHistory' -Exception $_.Exception
        return @()
    }
    finally {
        foreach ($comObject in @($history, $searcher, $session)) {
            if ($null -ne $comObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
                try {
                    [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
                }
                catch {
                }
            }
        }
    }
}

function Get-AgeInDays {
    param(
        [AllowNull()][string]$DateUtc,
        [Parameter(Mandatory = $true)][DateTime]$ReferenceUtc
    )

    if ([string]::IsNullOrWhiteSpace($DateUtc)) { return $null }
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse(
        $DateUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )) {
        return $null
    }

    $age = [Math]::Floor(($ReferenceUtc - $parsed.ToUniversalTime()).TotalDays)
    if ($age -lt 0) { return 0L }
    return [int64]$age
}

if ($Mode -ne 'Preview') { throw 'Only Preview mode is permitted in Fase 4B.' }
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
if ($allowedDrive -ne 'C:') { throw 'LOCALAPPDATA diagnostics root must be on drive C:.' }

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = $allowedRoot }
$validatedOutput = Get-ValidatedOutputPath -Path $OutputDirectory -AllowedRoot $allowedRoot
[System.IO.Directory]::CreateDirectory($validatedOutput) | Out-Null

$sectionFailures = New-Object System.Collections.Generic.List[object]
$operatingSystem = $null
$pendingIndicators = @()
$updateHistory = @()

if ($PSBoundParameters.ContainsKey('InputSnapshot')) {
    if ($null -eq $InputSnapshot) { throw 'InputSnapshot cannot be null when supplied.' }
    $operatingSystem = Get-OptionalPropertyValue -Object $InputSnapshot -Name 'OperatingSystem'
    $pendingIndicators = @(
        Get-OptionalPropertyValue -Object $InputSnapshot -Name 'PendingRebootIndicators'
    )
    $updateHistory = @(
        Get-OptionalPropertyValue -Object $InputSnapshot -Name 'UpdateHistory'
    )
}
else {
    $operatingSystem = Get-OperatingSystemMetadata -Failures $sectionFailures
    $pendingIndicators = @(Get-PendingRebootIndicators -Failures $sectionFailures)
    $updateHistory = @(
        Get-LocalUpdateHistory -Failures $sectionFailures -MaximumEntries $historyLimit
    )
}

$normalizedHistory = New-Object System.Collections.Generic.List[object]
foreach ($entry in @($updateHistory)) {
    if ($null -eq $entry) { continue }
    $dateUtc = [string](Get-OptionalPropertyValue -Object $entry -Name 'DateUtc')
    $resultCodeValue = Get-OptionalPropertyValue -Object $entry -Name 'ResultCode'
    $operationCodeValue = Get-OptionalPropertyValue -Object $entry -Name 'OperationCode'
    $resultCode = if ($null -eq $resultCodeValue) { -1 } else { [int]$resultCodeValue }
    $operationCode = if ($null -eq $operationCodeValue) { -1 } else { [int]$operationCodeValue }
    $ageDays = Get-AgeInDays -DateUtc $dateUtc -ReferenceUtc $nowUtc

    $normalizedHistory.Add([pscustomobject]@{
        DateUtc = $dateUtc
        AgeDays = $ageDays
        Title = [string](Get-OptionalPropertyValue -Object $entry -Name 'Title')
        ResultCode = $resultCode
        Result = Convert-UpdateResultCode -ResultCode $resultCode
        OperationCode = $operationCode
        Operation = Convert-UpdateOperation -Operation $operationCode
        HResult = Get-OptionalPropertyValue -Object $entry -Name 'HResult'
    })
}

$orderedHistory = @(
    $normalizedHistory.ToArray() |
        Sort-Object @{ Expression = {
            if ([string]::IsNullOrWhiteSpace($_.DateUtc)) { [DateTime]::MinValue }
            else { [DateTime]$_.DateUtc }
        }; Descending = $true }
)

$pendingIndicatorCount = [int64]@($pendingIndicators | Where-Object {
    (Get-OptionalPropertyValue -Object $_ -Name 'Present') -eq $true
}).Count
$pendingReboot = [bool]($pendingIndicatorCount -gt 0)

$succeeded = [int64]@($orderedHistory | Where-Object { $_.ResultCode -eq 2 }).Count
$succeededWithErrors = [int64]@($orderedHistory | Where-Object { $_.ResultCode -eq 3 }).Count
$failed = [int64]@($orderedHistory | Where-Object { $_.ResultCode -eq 4 }).Count
$aborted = [int64]@($orderedHistory | Where-Object { $_.ResultCode -eq 5 }).Count
$other = [int64]($orderedHistory.Count - $succeeded - $succeededWithErrors - $failed - $aborted)

$historyLast30Days = [int64]@($orderedHistory | Where-Object {
    $null -ne $_.AgeDays -and $_.AgeDays -le 30
}).Count
$history31To90Days = [int64]@($orderedHistory | Where-Object {
    $null -ne $_.AgeDays -and $_.AgeDays -ge 31 -and $_.AgeDays -le 90
}).Count
$history91To180Days = [int64]@($orderedHistory | Where-Object {
    $null -ne $_.AgeDays -and $_.AgeDays -ge 91 -and $_.AgeDays -le 180
}).Count
$historyOlderThan180Days = [int64]@($orderedHistory | Where-Object {
    $null -ne $_.AgeDays -and $_.AgeDays -gt 180
}).Count
$historyUnknownAge = [int64]@($orderedHistory | Where-Object { $null -eq $_.AgeDays }).Count

$successfulAges = @($orderedHistory | Where-Object {
    $_.ResultCode -eq 2 -and $null -ne $_.AgeDays
} | ForEach-Object { [int64]$_.AgeDays })
$failedAges = @($orderedHistory | Where-Object {
    $_.ResultCode -eq 4 -and $null -ne $_.AgeDays
} | ForEach-Object { [int64]$_.AgeDays })
$lastSuccessfulUpdateAgeDays = if ($successfulAges.Count -eq 0) { $null } else {
    [int64]($successfulAges | Measure-Object -Minimum).Minimum
}
$lastFailedUpdateAgeDays = if ($failedAges.Count -eq 0) { $null } else {
    [int64]($failedAges | Measure-Object -Minimum).Minimum
}

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine('<!doctype html>')
[void]$builder.AppendLine('<html lang="pt-BR"><head><meta charset="utf-8">')
[void]$builder.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
[void]$builder.AppendLine('<title>KARV — Atualizações e reinicialização</title>')
[void]$builder.AppendLine('<style>')
[void]$builder.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f4f6f8;color:#17212b}main{max-width:1500px;margin:0 auto;padding:28px}header,section{background:#fff;border:1px solid #d9e0e7;border-radius:10px;padding:20px;margin-bottom:18px}h1{margin:0 0 8px;font-size:26px}h2{margin:0 0 14px;font-size:20px}.warning{background:#fff4d6;border-left:5px solid #c78a00;padding:12px;margin-top:14px}.metrics{display:flex;gap:12px;flex-wrap:wrap;margin-top:16px}.metric{background:#edf2f7;border-radius:8px;padding:10px 14px}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid #dfe5eb;padding:9px;word-break:break-word}th{background:#edf2f7;position:sticky;top:0}.pending{font-weight:700;color:#8a3d00}.clear{font-weight:700;color:#226b36}.footer{font-size:12px;color:#5b6773}</style>')
[void]$builder.AppendLine('</head><body><main>')
[void]$builder.AppendLine('<header><h1>KARV — Estado local de atualização do Windows</h1>')
[void]$builder.AppendLine('<p>Consulta somente ao histórico local e a metadados de Registro. Nenhuma atualização foi procurada, baixada ou instalada.</p>')
[void]$builder.AppendLine('<div class="warning"><strong>Dados locais sensíveis.</strong> Não compartilhe este HTML, capturas, build, datas ou títulos de atualização.</div>')
[void]$builder.AppendLine('<div class="metrics">')
[void]$builder.AppendLine('<div class="metric"><strong>Histórico:</strong> ' + $orderedHistory.Count + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Sucesso:</strong> ' + $succeeded + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Falha:</strong> ' + $failed + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Reinício pendente:</strong> ' + $pendingReboot + '</div>')
[void]$builder.AppendLine('</div></header>')

[void]$builder.AppendLine('<section><h2>Windows local</h2><div class="table-wrap"><table><tbody>')
foreach ($pair in @(
    @('Produto', (Get-OptionalPropertyValue -Object $operatingSystem -Name 'ProductName')),
    @('Versão de exibição', (Get-OptionalPropertyValue -Object $operatingSystem -Name 'DisplayVersion')),
    @('Edição', (Get-OptionalPropertyValue -Object $operatingSystem -Name 'EditionId')),
    @('Tipo de instalação', (Get-OptionalPropertyValue -Object $operatingSystem -Name 'InstallationType')),
    @('Build', (Get-OptionalPropertyValue -Object $operatingSystem -Name 'CurrentBuild')),
    @('UBR', (Get-OptionalPropertyValue -Object $operatingSystem -Name 'UpdateBuildRevision'))
)) {
    [void]$builder.AppendLine('<tr><th>' + (Convert-ToHtmlText $pair[0]) + '</th><td>' + (Convert-ToHtmlText $pair[1]) + '</td></tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')

[void]$builder.AppendLine('<section><h2>Indicadores de reinicialização pendente</h2><div class="table-wrap"><table><thead><tr><th>Indicador</th><th>Presente</th></tr></thead><tbody>')
foreach ($indicator in @($pendingIndicators)) {
    $present = [bool](Get-OptionalPropertyValue -Object $indicator -Name 'Present')
    $className = if ($present) { 'pending' } else { 'clear' }
    [void]$builder.AppendLine('<tr><td>' + (Convert-ToHtmlText (Get-OptionalPropertyValue -Object $indicator -Name 'Name')) + '</td><td class="' + $className + '">' + $present + '</td></tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')

[void]$builder.AppendLine('<section><h2>Histórico local de atualizações</h2><div class="table-wrap"><table><thead><tr><th>Data UTC</th><th>Título</th><th>Resultado</th><th>Operação</th><th>HResult</th></tr></thead><tbody>')
foreach ($entry in $orderedHistory) {
    [void]$builder.AppendLine('<tr>')
    foreach ($value in @($entry.DateUtc, $entry.Title, $entry.Result, $entry.Operation, $entry.HResult)) {
        [void]$builder.AppendLine('<td>' + (Convert-ToHtmlText $value) + '</td>')
    }
    [void]$builder.AppendLine('</tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')
[void]$builder.AppendLine('<section class="footer">Este painel não procura atualizações e não autoriza instalação, reparo ou reinicialização.</section>')
[void]$builder.AppendLine('</main></body></html>')

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$manifestPath = Join-Path $validatedOutput ('karv-windows-update-readiness-local-manifest-' + $timestamp + '.json')
$summaryPath = Join-Path $validatedOutput ('karv-windows-update-readiness-sanitized-summary-' + $timestamp + '.json')
$htmlPath = Join-Path $validatedOutput ('karv-windows-update-readiness-panel-' + $timestamp + '.html')

$manifest = [pscustomobject]@{
    Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    SensitiveLocalData = $true
    LocalOnly = $true
    OperatingSystem = $operatingSystem
    PendingRebootIndicators = @($pendingIndicators)
    UpdateHistory = $orderedHistory
    SectionFailures = $sectionFailures.ToArray()
}

$summary = [pscustomobject]@{
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    Privacy = [pscustomobject]@{
        SummarySanitized = $true
        SummaryContainsUpdateTitles = $false
        SummaryContainsExactDates = $false
        SummaryContainsOperatingSystemEdition = $false
        SummaryContainsOperatingSystemBuild = $false
        DetailedManifestContainsSensitiveLocalData = $true
        DetailedManifestLocalOnly = $true
        HtmlContainsSensitiveLocalData = $true
        HtmlLocalOnly = $true
        ExcludedDriveEAccessed = $false
        PendingPathValuesRead = $false
    }
    Scope = [pscustomobject]@{
        RegistryReadOnly = $true
        OperatingSystemMetadataRead = $true
        PendingRebootIndicatorsChecked = [int64]@($pendingIndicators).Count
        UpdateHistoryReadOnly = $true
        QueryHistoryOnly = $true
        HistoryLimit = [int64]$historyLimit
        UpdateSearchPerformed = $false
        UpdatesDownloaded = $false
        UpdatesInstalled = $false
        RebootTriggered = $false
        DismExecuted = $false
        SfcExecuted = $false
        NetworkCollected = $false
        ActionsAvailable = $false
    }
    Summary = [pscustomobject]@{
        OperatingSystemMetadataCollected = [bool]($null -ne $operatingSystem)
        UpdateHistoryEntries = [int64]$orderedHistory.Count
        Succeeded = $succeeded
        SucceededWithErrors = $succeededWithErrors
        Failed = $failed
        Aborted = $aborted
        OtherResults = $other
        HistoryLast30Days = $historyLast30Days
        History31To90Days = $history31To90Days
        History91To180Days = $history91To180Days
        HistoryOlderThan180Days = $historyOlderThan180Days
        HistoryUnknownAge = $historyUnknownAge
        LastSuccessfulUpdateAgeDays = $lastSuccessfulUpdateAgeDays
        LastFailedUpdateAgeDays = $lastFailedUpdateAgeDays
        PendingReboot = $pendingReboot
        PendingRebootIndicators = $pendingIndicatorCount
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
    UpdateHistoryEntries = [int64]$orderedHistory.Count
    Succeeded = $succeeded
    SucceededWithErrors = $succeededWithErrors
    Failed = $failed
    Aborted = $aborted
    OtherResults = $other
    PendingReboot = $pendingReboot
    PendingRebootIndicators = $pendingIndicatorCount
    SectionFailures = [int64]$sectionFailures.Count
    ReportsCreated = 3
}
