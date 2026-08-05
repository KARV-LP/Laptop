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
$collectorName = 'WindowsUpdateOperationalDiagnostic'
$nowUtc = [DateTime]::UtcNow
$eventLimit = 200
$essentialServices = @(
    [pscustomobject]@{ Name = 'wuauserv'; DisplayName = 'Windows Update' },
    [pscustomobject]@{ Name = 'BITS'; DisplayName = 'Background Intelligent Transfer Service' },
    [pscustomobject]@{ Name = 'UsoSvc'; DisplayName = 'Update Orchestrator Service' },
    [pscustomobject]@{ Name = 'TrustedInstaller'; DisplayName = 'Windows Modules Installer' },
    [pscustomobject]@{ Name = 'CryptSvc'; DisplayName = 'Cryptographic Services' }
)

function Get-OptionalPropertyValue {
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
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
    $inside = [string]::Equals($normalizedRoot, $normalizedPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $normalizedPath.StartsWith($normalizedRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { throw 'Output must remain inside LOCALAPPDATA\KARV\LaptopDiagnostics.' }
    return $fullPath
}

function Convert-ToHtmlText {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Test-RegistrySubKeyExists {
    param([Parameter(Mandatory = $true)][string]$SubKeyPath)
    $baseKey = $null
    $subKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $subKey = $baseKey.OpenSubKey($SubKeyPath, $false)
        return $null -ne $subKey
    }
    finally {
        if ($null -ne $subKey) { $subKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Test-RegistryValueExistsWithoutReading {
    param(
        [Parameter(Mandatory = $true)][string]$SubKeyPath,
        [Parameter(Mandatory = $true)][string]$ValueName
    )
    $baseKey = $null
    $subKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $subKey = $baseKey.OpenSubKey($SubKeyPath, $false)
        if ($null -eq $subKey) { return $false }
        return @($subKey.GetValueNames()) -contains $ValueName
    }
    finally {
        if ($null -ne $subKey) { $subKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

function Read-PendingIndicators {
    return @(
        [pscustomobject]@{
            Name = 'ComponentBasedServicingRebootPending'
            Present = [bool](Test-RegistrySubKeyExists -SubKeyPath 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
            EvidenceType = 'RegistryKeyExistence'
            ValueContentRead = $false
        },
        [pscustomobject]@{
            Name = 'WindowsUpdateRebootRequired'
            Present = [bool](Test-RegistrySubKeyExists -SubKeyPath 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
            EvidenceType = 'RegistryKeyExistence'
            ValueContentRead = $false
        },
        [pscustomobject]@{
            Name = 'PendingFileRenameOperations'
            Present = [bool](Test-RegistryValueExistsWithoutReading `
                -SubKeyPath 'SYSTEM\CurrentControlSet\Control\Session Manager' `
                -ValueName 'PendingFileRenameOperations')
            EvidenceType = 'RegistryValueNameExistence'
            ValueContentRead = $false
        }
    )
}

function Read-ServiceSnapshots {
    $items = New-Object System.Collections.Generic.List[object]
    $failures = New-Object System.Collections.Generic.List[object]
    foreach ($expected in $essentialServices) {
        try {
            $escapedName = $expected.Name.Replace("'", "''")
            $service = Get-CimInstance -ClassName Win32_Service `
                -Filter ("Name='" + $escapedName + "'") -ErrorAction Stop |
                Select-Object -First 1
            if ($null -eq $service) {
                $items.Add([pscustomobject]@{
                    Name = $expected.Name; DisplayName = $expected.DisplayName; Found = $false
                    State = 'Missing'; StartMode = 'Unknown'
                })
            }
            else {
                $items.Add([pscustomobject]@{
                    Name = [string]$service.Name; DisplayName = [string]$service.DisplayName; Found = $true
                    State = [string]$service.State; StartMode = [string]$service.StartMode
                })
            }
        }
        catch {
            $failures.Add([pscustomobject]@{ Section = 'ServiceMetadata'; ErrorType = $_.Exception.GetType().Name })
            $items.Add([pscustomobject]@{
                Name = $expected.Name; DisplayName = $expected.DisplayName; Found = $false
                State = 'QueryFailed'; StartMode = 'Unknown'
            })
        }
    }
    return [pscustomobject]@{ Items = @($items.ToArray()); Failures = @($failures.ToArray()) }
}

function Read-UpdateEvents {
    $items = New-Object System.Collections.Generic.List[object]
    $failures = New-Object System.Collections.Generic.List[object]
    try {
        $events = @(Get-WinEvent `
            -FilterHashtable @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational' } `
            -MaxEvents $eventLimit -ErrorAction Stop)
        foreach ($event in $events) {
            $timeUtc = $null
            if ($null -ne $event.TimeCreated) { $timeUtc = $event.TimeCreated.ToUniversalTime().ToString('o') }
            $items.Add([pscustomobject]@{
                Id = [int64]$event.Id
                Level = [int64]$event.Level
                LevelDisplayName = [string]$event.LevelDisplayName
                ProviderName = [string]$event.ProviderName
                TimeCreatedUtc = $timeUtc
                MessageRead = $false
            })
        }
    }
    catch {
        $failures.Add([pscustomobject]@{
            Section = 'WindowsUpdateOperationalEvents'
            ErrorType = $_.Exception.GetType().Name
        })
    }
    return [pscustomobject]@{ Items = @($items.ToArray()); Failures = @($failures.ToArray()) }
}

function Get-LevelCategory {
    param([int64]$Level)
    switch ($Level) {
        1 { return 'Critical' }
        2 { return 'Error' }
        3 { return 'Warning' }
        4 { return 'Information' }
        5 { return 'Verbose' }
        default { return 'Other' }
    }
}

function Get-AgeDays {
    param([AllowNull()][string]$UtcText, [Parameter(Mandatory = $true)][DateTime]$ReferenceUtc)
    if ([string]::IsNullOrWhiteSpace($UtcText)) { return $null }
    $parsed = [DateTime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
        [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [DateTime]::TryParse(
        $UtcText,
        [System.Globalization.CultureInfo]::InvariantCulture,
        $styles,
        [ref]$parsed
    )) { return $null }
    $age = [math]::Floor(($ReferenceUtc - $parsed.ToUniversalTime()).TotalDays)
    if ($age -lt 0) { return 0L }
    return [int64]$age
}

if ($Mode -ne 'Preview') { throw 'Only Preview mode is permitted in Fase 4C.' }
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
if ([System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant() -ne 'C:') {
    throw 'LOCALAPPDATA diagnostics root must be on drive C:.'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = $allowedRoot }
$validatedOutput = Get-ValidatedOutputPath -Path $OutputDirectory -AllowedRoot $allowedRoot
[System.IO.Directory]::CreateDirectory($validatedOutput) | Out-Null

$sectionFailures = New-Object System.Collections.Generic.List[object]
$pendingIndicators = @()
$serviceSnapshots = @()
$updateEvents = @()

if ($PSBoundParameters.ContainsKey('InputSnapshot')) {
    $pendingIndicators = @((Get-OptionalPropertyValue -Object $InputSnapshot -Name 'PendingIndicators'))
    $serviceSnapshots = @((Get-OptionalPropertyValue -Object $InputSnapshot -Name 'Services'))
    $updateEvents = @((Get-OptionalPropertyValue -Object $InputSnapshot -Name 'Events'))
    foreach ($failure in @((Get-OptionalPropertyValue -Object $InputSnapshot -Name 'SectionFailures'))) {
        if ($null -ne $failure) { $sectionFailures.Add($failure) }
    }
}
else {
    try { $pendingIndicators = @(Read-PendingIndicators) }
    catch {
        $sectionFailures.Add([pscustomobject]@{
            Section = 'PendingRebootIndicators'; ErrorType = $_.Exception.GetType().Name
        })
    }

    $serviceResult = Read-ServiceSnapshots
    $serviceSnapshots = @($serviceResult.Items)
    foreach ($failure in @($serviceResult.Failures)) { $sectionFailures.Add($failure) }

    $eventResult = Read-UpdateEvents
    $updateEvents = @($eventResult.Items)
    foreach ($failure in @($eventResult.Failures)) { $sectionFailures.Add($failure) }
}

$indicatorArray = @($pendingIndicators | Where-Object { $null -ne $_ } | ForEach-Object {
    [pscustomobject]@{
        Name = [string](Get-OptionalPropertyValue -Object $_ -Name 'Name')
        Present = [bool](Get-OptionalPropertyValue -Object $_ -Name 'Present')
        EvidenceType = [string](Get-OptionalPropertyValue -Object $_ -Name 'EvidenceType')
        ValueContentRead = $false
    }
})
$serviceArray = @($serviceSnapshots | Where-Object { $null -ne $_ } | ForEach-Object {
    [pscustomobject]@{
        Name = [string](Get-OptionalPropertyValue -Object $_ -Name 'Name')
        DisplayName = [string](Get-OptionalPropertyValue -Object $_ -Name 'DisplayName')
        Found = [bool](Get-OptionalPropertyValue -Object $_ -Name 'Found')
        State = [string](Get-OptionalPropertyValue -Object $_ -Name 'State')
        StartMode = [string](Get-OptionalPropertyValue -Object $_ -Name 'StartMode')
    }
})
$eventArray = @($updateEvents | Where-Object { $null -ne $_ } | ForEach-Object {
    $level = [int64](Get-OptionalPropertyValue -Object $_ -Name 'Level')
    [pscustomobject]@{
        Id = [int64](Get-OptionalPropertyValue -Object $_ -Name 'Id')
        Level = $level
        LevelCategory = Get-LevelCategory -Level $level
        LevelDisplayName = [string](Get-OptionalPropertyValue -Object $_ -Name 'LevelDisplayName')
        ProviderName = [string](Get-OptionalPropertyValue -Object $_ -Name 'ProviderName')
        TimeCreatedUtc = [string](Get-OptionalPropertyValue -Object $_ -Name 'TimeCreatedUtc')
        MessageRead = $false
    }
} | Sort-Object TimeCreatedUtc -Descending)

$pendingIndicatorCount = [int64]@($indicatorArray | Where-Object { $_.Present }).Count
$pendingReboot = [bool]($pendingIndicatorCount -gt 0)
$componentsExpected = [int64]$essentialServices.Count
$componentsFound = [int64]@($serviceArray | Where-Object { $_.Found }).Count
$componentsRunning = [int64]@($serviceArray | Where-Object { $_.Found -and $_.State -eq 'Running' }).Count
$componentsStopped = [int64]@($serviceArray | Where-Object { $_.Found -and $_.State -eq 'Stopped' }).Count
$componentsDisabled = [int64]@($serviceArray | Where-Object { $_.Found -and $_.StartMode -eq 'Disabled' }).Count
$componentsMissing = [int64]@($serviceArray | Where-Object { -not $_.Found -and $_.State -eq 'Missing' }).Count
$serviceQueryFailures = [int64]@($serviceArray | Where-Object { $_.State -eq 'QueryFailed' }).Count

$eventCritical = [int64]@($eventArray | Where-Object { $_.LevelCategory -eq 'Critical' }).Count
$eventErrors = [int64]@($eventArray | Where-Object { $_.LevelCategory -eq 'Error' }).Count
$eventWarnings = [int64]@($eventArray | Where-Object { $_.LevelCategory -eq 'Warning' }).Count
$eventInformation = [int64]@($eventArray | Where-Object { $_.LevelCategory -eq 'Information' }).Count
$eventOther = [int64]($eventArray.Count - $eventCritical - $eventErrors - $eventWarnings - $eventInformation)

$eventsLast7Days = 0L
$eventsLast30Days = 0L
$events31To90Days = 0L
$eventsOlderThan90Days = 0L
$eventsUnknownAge = 0L
$lastEventAgeDays = $null
$lastErrorAgeDays = $null
foreach ($event in $eventArray) {
    $ageDays = Get-AgeDays -UtcText $event.TimeCreatedUtc -ReferenceUtc $nowUtc
    if ($null -eq $ageDays) { $eventsUnknownAge++; continue }
    if ($null -eq $lastEventAgeDays -or $ageDays -lt $lastEventAgeDays) { $lastEventAgeDays = [int64]$ageDays }
    if (($event.LevelCategory -in @('Critical', 'Error')) -and
        ($null -eq $lastErrorAgeDays -or $ageDays -lt $lastErrorAgeDays)) {
        $lastErrorAgeDays = [int64]$ageDays
    }
    if ($ageDays -le 7) { $eventsLast7Days++; $eventsLast30Days++ }
    elseif ($ageDays -le 30) { $eventsLast30Days++ }
    elseif ($ageDays -le 90) { $events31To90Days++ }
    else { $eventsOlderThan90Days++ }
}

$diagnosticClassification = 'Operational'
if ($componentsDisabled -gt 0 -or $componentsMissing -gt 0 -or $serviceQueryFailures -gt 0) {
    $diagnosticClassification = 'DegradedReview'
}
elseif ($sectionFailures.Count -gt 0) { $diagnosticClassification = 'InsufficientDataReview' }
elseif ($pendingReboot) { $diagnosticClassification = 'RebootPendingReview' }

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine('<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
[void]$builder.AppendLine('<title>KARV — Diagnóstico operacional do Windows Update</title><style>body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f4f6f8;color:#17212b}main{max-width:1500px;margin:auto;padding:28px}header,section{background:#fff;border:1px solid #d9e0e7;border-radius:10px;padding:20px;margin-bottom:18px}.metrics{display:flex;gap:12px;flex-wrap:wrap}.metric{background:#edf2f7;border-radius:8px;padding:10px 14px}.warning{background:#fff4d6;border-left:5px solid #c78a00;padding:12px}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid #dfe5eb;padding:9px;word-break:break-word}th{background:#edf2f7}.footer{font-size:12px;color:#5b6773}</style></head><body><main>')
[void]$builder.AppendLine('<header><h1>KARV — Diagnóstico operacional do Windows Update</h1><p>Somente leitura. Serviços parados não são considerados defeito automaticamente porque alguns componentes operam sob demanda.</p><div class="warning"><strong>Sem ações.</strong> Nenhuma correção ou reinicialização está disponível.</div><div class="metrics">')
[void]$builder.AppendLine('<div class="metric"><strong>Classificação:</strong> ' + (Convert-ToHtmlText $diagnosticClassification) + '</div><div class="metric"><strong>Indicadores:</strong> ' + $pendingIndicatorCount + '</div><div class="metric"><strong>Componentes:</strong> ' + $componentsFound + ' / ' + $componentsExpected + '</div><div class="metric"><strong>Eventos:</strong> ' + $eventArray.Count + '</div></div></header>')

[void]$builder.AppendLine('<section><h2>Indicadores de reinicialização pendente</h2><div class="table-wrap"><table><thead><tr><th>Indicador</th><th>Presente</th><th>Evidência</th><th>Conteúdo lido</th></tr></thead><tbody>')
foreach ($item in $indicatorArray) {
    [void]$builder.AppendLine('<tr><td>' + (Convert-ToHtmlText $item.Name) + '</td><td>' + $item.Present + '</td><td>' + (Convert-ToHtmlText $item.EvidenceType) + '</td><td>false</td></tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')

[void]$builder.AppendLine('<section><h2>Componentes essenciais</h2><div class="table-wrap"><table><thead><tr><th>Componente</th><th>Nome técnico</th><th>Encontrado</th><th>Estado</th><th>Inicialização</th></tr></thead><tbody>')
foreach ($item in $serviceArray) {
    [void]$builder.AppendLine('<tr><td>' + (Convert-ToHtmlText $item.DisplayName) + '</td><td>' + (Convert-ToHtmlText $item.Name) + '</td><td>' + $item.Found + '</td><td>' + (Convert-ToHtmlText $item.State) + '</td><td>' + (Convert-ToHtmlText $item.StartMode) + '</td></tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')

[void]$builder.AppendLine('<section><h2>Eventos operacionais locais</h2><div class="table-wrap"><table><thead><tr><th>Data UTC</th><th>Nível</th><th>ID</th><th>Provedor</th><th>Mensagem lida</th></tr></thead><tbody>')
foreach ($item in $eventArray) {
    [void]$builder.AppendLine('<tr><td>' + (Convert-ToHtmlText $item.TimeCreatedUtc) + '</td><td>' + (Convert-ToHtmlText $item.LevelCategory) + '</td><td>' + $item.Id + '</td><td>' + (Convert-ToHtmlText $item.ProviderName) + '</td><td>false</td></tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section><section class="footer">Nenhum serviço, atualização, política ou reinicialização foi alterado.</section></main></body></html>')

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$manifestPath = Join-Path $validatedOutput ('karv-windows-update-operational-local-manifest-' + $timestamp + '.json')
$summaryPath = Join-Path $validatedOutput ('karv-windows-update-operational-sanitized-summary-' + $timestamp + '.json')
$htmlPath = Join-Path $validatedOutput ('karv-windows-update-operational-panel-' + $timestamp + '.html')

$manifest = [pscustomobject]@{
    Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
    Collector = $collectorName; ScriptVersion = $scriptVersion; GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode; SensitiveLocalData = $true; LocalOnly = $true
    DiagnosticClassification = $diagnosticClassification
    PendingIndicators = $indicatorArray; Services = $serviceArray; Events = $eventArray
    SectionFailures = $sectionFailures.ToArray()
}
$summary = [pscustomobject]@{
    Collector = $collectorName; ScriptVersion = $scriptVersion; GeneratedAtUtc = $nowUtc.ToString('o'); Mode = $Mode
    Privacy = [pscustomobject]@{
        SummarySanitized = $true; SummaryContainsIndicatorNames = $false; SummaryContainsServiceNames = $false
        SummaryContainsEventIds = $false; SummaryContainsEventProviders = $false; SummaryContainsEventMessages = $false
        SummaryContainsExactDates = $false; SummaryContainsPaths = $false
        DetailedManifestContainsSensitiveLocalData = $true; DetailedManifestLocalOnly = $true
        HtmlContainsSensitiveLocalData = $true; HtmlLocalOnly = $true
        PendingPathValuesRead = $false; ExcludedDriveEAccessed = $false
    }
    Scope = [pscustomobject]@{
        RegistryReadOnly = $true; PendingIndicatorsExpected = 3
        ServiceMetadataReadOnly = $true; EssentialComponentsExpected = $componentsExpected
        EventMetadataReadOnly = $true; EventLimit = $eventLimit; EventMessagesRead = $false
        UpdateSearchPerformed = $false; UpdatesDownloaded = $false; UpdatesInstalled = $false
        ServicesChanged = $false; RebootTriggered = $false; DismExecuted = $false; SfcExecuted = $false
        NetworkCollected = $false; ActionsAvailable = $false
    }
    Summary = [pscustomobject]@{
        DiagnosticClassification = $diagnosticClassification
        PendingReboot = $pendingReboot; PendingRebootIndicators = $pendingIndicatorCount
        ComponentsExpected = $componentsExpected; ComponentsFound = $componentsFound
        ComponentsRunning = $componentsRunning; ComponentsStopped = $componentsStopped
        ComponentsDisabled = $componentsDisabled; ComponentsMissing = $componentsMissing
        ServiceQueryFailures = $serviceQueryFailures
        EventEntries = [int64]$eventArray.Count; EventCritical = $eventCritical; EventErrors = $eventErrors
        EventWarnings = $eventWarnings; EventInformation = $eventInformation; EventOther = $eventOther
        EventsLast7Days = [int64]$eventsLast7Days; EventsLast30Days = [int64]$eventsLast30Days
        Events31To90Days = [int64]$events31To90Days; EventsOlderThan90Days = [int64]$eventsOlderThan90Days
        EventsUnknownAge = [int64]$eventsUnknownAge; LastEventAgeDays = $lastEventAgeDays; LastErrorAgeDays = $lastErrorAgeDays
    }
    SectionFailures = $sectionFailures.ToArray()
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), $utf8NoBom)
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 10), $utf8NoBom)
[System.IO.File]::WriteAllText($htmlPath, $builder.ToString(), $utf8NoBom)

[pscustomobject]@{
    Status = if ($sectionFailures.Count -eq 0) { 'Passed' } else { 'Partial' }
    Collector = $collectorName; ScriptVersion = $scriptVersion; Mode = $Mode
    DiagnosticClassification = $diagnosticClassification
    PendingReboot = $pendingReboot; PendingRebootIndicators = $pendingIndicatorCount
    ComponentsExpected = $componentsExpected; ComponentsFound = $componentsFound
    ComponentsRunning = $componentsRunning; ComponentsStopped = $componentsStopped
    ComponentsDisabled = $componentsDisabled; ComponentsMissing = $componentsMissing
    ServiceQueryFailures = $serviceQueryFailures; EventEntries = [int64]$eventArray.Count
    EventErrors = $eventErrors; EventWarnings = $eventWarnings
    SectionFailures = [int64]$sectionFailures.Count; ReportsCreated = 3
}
