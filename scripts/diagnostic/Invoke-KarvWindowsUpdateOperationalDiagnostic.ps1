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

function Test-RegistrySubKeyExists {
    param(
        [Parameter(Mandatory = $true)][string]$SubKeyPath
    )

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

function Get-LocalPendingIndicators {
    $items = New-Object System.Collections.Generic.List[object]

    $items.Add([pscustomobject]@{
        Name = 'ComponentBasedServicingRebootPending'
        Present = [bool](Test-RegistrySubKeyExists -SubKeyPath 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        EvidenceType = 'RegistryKeyExistence'
        ValueContentRead = $false
    })

    $items.Add([pscustomobject]@{
        Name = 'WindowsUpdateRebootRequired'
        Present = [bool](Test-RegistrySubKeyExists -SubKeyPath 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        EvidenceType = 'RegistryKeyExistence'
        ValueContentRead = $false
    })

    $items.Add([pscustomobject]@{
        Name = 'PendingFileRenameOperations'
        Present = [bool](Test-RegistryValueExistsWithoutReading `
            -SubKeyPath 'SYSTEM\CurrentControlSet\Control\Session Manager' `
            -ValueName 'PendingFileRenameOperations')
        EvidenceType = 'RegistryValueNameExistence'
        ValueContentRead = $false
    })

    return @($items.ToArray())
}

function Get-LocalServiceSnapshots {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Failures
    )

    $items = New-Object System.Collections.Generic.List[object]

    foreach ($expected in $essentialServices) {
        try {
            $escapedName = $expected.Name.Replace("'", "''")
            $service = Get-CimInstance `
                -ClassName Win32_Service `
                -Filter ("Name='" + $escapedName + "'") `
                -ErrorAction Stop |
                Select-Object -First 1

            if ($null -eq $service) {
                $items.Add([pscustomobject]@{
                    Name = $expected.Name
                    DisplayName = $expected.DisplayName
                    Found = $false
                    State = 'Missing'
                    StartMode = 'Unknown'
                })
                continue
            }

            $items.Add([pscustomobject]@{
                Name = [string]$service.Name
                DisplayName = [string]$service.DisplayName
                Found = $true
                State = [string]$service.State
                StartMode = [string]$service.StartMode
            })
        }
        catch {
            $Failures.Add([pscustomobject]@{
                Section = 'ServiceMetadata'
                ErrorType = $_.Exception.GetType().Name
            })
            $items.Add([pscustomobject]@{
                Name = $expected.Name
                DisplayName = $expected.DisplayName
                Found = $false
                State = 'QueryFailed'
                StartMode = 'Unknown'
            })
        }
    }

    return @($items.ToArray())
}

function Get-LocalUpdateEvents {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Failures
    )

    $items = New-Object System.Collections.Generic.List[object]
    try {
        $events = @(Get-WinEvent `
            -FilterHashtable @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational' } `
            -MaxEvents $eventLimit `
            -ErrorAction Stop)

        foreach ($event in $events) {
            $timeUtc = $null
            if ($null -ne $event.TimeCreated) {
                $timeUtc = $event.TimeCreated.ToUniversalTime().ToString('o')
            }

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
        $Failures.Add([pscustomobject]@{
            Section = 'WindowsUpdateOperationalEvents'
            ErrorType = $_.Exception.GetType().Name
        })
    }

    return @($items.ToArray())
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
    param(
        [AllowNull()][string]$UtcText,
        [Parameter(Mandatory = $true)][DateTime]$ReferenceUtc
    )

    if ([string]::IsNullOrWhiteSpace($UtcText)) { return $null }
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse(
        $UtcText,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsed
    )) {
        return $null
    }

    $age = [math]::Floor(($ReferenceUtc - $parsed.ToUniversalTime()).TotalDays)
    if ($age -lt 0) { return 0L }
    return [int64]$age
}

if ($Mode -ne 'Preview') { throw 'Only Preview mode is permitted in Fase 4C.' }
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }

$allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'KARV\LaptopDiagnostics'))
$allowedDrive = [System.IO.Path]::GetPathRoot($allowedRoot).TrimEnd('\').ToUpperInvariant()
if ($allowedDrive -ne 'C:') { throw 'LOCALAPPDATA diagnostics root must be on drive C:.' }

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
    try {
        $pendingIndicators = @(Get-LocalPendingIndicators)
    }
    catch {
        $sectionFailures.Add([pscustomobject]@{
            Section = 'PendingRebootIndicators'
            ErrorType = $_.Exception.GetType().Name
        })
    }

    $serviceSnapshots = @(Get-LocalServiceSnapshots -Failures $sectionFailures)
    $updateEvents = @(Get-LocalUpdateEvents -Failures $sectionFailures)
}

$normalizedIndicators = New-Object System.Collections.Generic.List[object]
foreach ($indicator in $pendingIndicators) {
    if ($null -eq $indicator) { continue }
    $normalizedIndicators.Add([pscustomobject]@{
        Name = [string](Get-OptionalPropertyValue -Object $indicator -Name 'Name')
        Present = [bool](Get-OptionalPropertyValue -Object $indicator -Name 'Present')
        EvidenceType = [string](Get-OptionalPropertyValue -Object $indicator -Name 'EvidenceType')
        ValueContentRead = $false
    })
}

$normalizedServices = New-Object System.Collections.Generic.List[object]
foreach ($service in $serviceSnapshots) {
    if ($null -eq $service) { continue }
    $normalizedServices.Add([pscustomobject]@{
        Name = [string](Get-OptionalPropertyValue -Object $service -Name 'Name')
        DisplayName = [string](Get-OptionalPropertyValue -Object $service -Name 'DisplayName')
        Found = [bool](Get-OptionalPropertyValue -Object $service -Name 'Found')
        State = [string](Get-OptionalPropertyValue -Object $service -Name 'State')
        StartMode = [string](Get-OptionalPropertyValue -Object $service -Name 'StartMode')
    })
}

$normalizedEvents = New-Object System.Collections.Generic.List[object]
foreach ($event in $updateEvents) {
    if ($null -eq $event) { continue }
    $level = [int64](Get-OptionalPropertyValue -Object $event -Name 'Level')
    $normalizedEvents.Add([pscustomobject]@{
        Id = [int64](Get-OptionalPropertyValue -Object $event -Name 'Id')
        Level = $level
        LevelCategory = Get-LevelCategory -Level $level
        LevelDisplayName = [string](Get-OptionalPropertyValue -Object $event -Name 'LevelDisplayName')
        ProviderName = [string](Get-OptionalPropertyValue -Object $event -Name 'ProviderName')
        TimeCreatedUtc = [string](Get-OptionalPropertyValue -Object $event -Name 'TimeCreatedUtc')
        MessageRead = $false
    })
}

$indicatorArray = @($normalizedIndicators.ToArray())
$serviceArray = @($normalizedServices.ToArray())
$eventArray = @($normalizedEvents.ToArray() | Sort-Object TimeCreatedUtc -Descending)

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
    if ($null -eq $ageDays) {
        $eventsUnknownAge++
        continue
    }

    if ($null -eq $lastEventAgeDays -or $ageDays -lt $lastEventAgeDays) {
        $lastEventAgeDays = [int64]$ageDays
    }
    if (($event.LevelCategory -eq 'Critical' -or $event.LevelCategory -eq 'Error') -and
        ($null -eq $lastErrorAgeDays -or $ageDays -lt $lastErrorAgeDays)) {
        $lastErrorAgeDays = [int64]$ageDays
    }

    if ($ageDays -le 7) {
        $eventsLast7Days++
        $eventsLast30Days++
    }
    elseif ($ageDays -le 30) {
        $eventsLast30Days++
    }
    elseif ($ageDays -le 90) {
        $events31To90Days++
    }
    else {
        $eventsOlderThan90Days++
    }
}

$diagnosticClassification = 'Operational'
if ($componentsDisabled -gt 0 -or $componentsMissing -gt 0 -or $serviceQueryFailures -gt 0) {
    $diagnosticClassification = 'DegradedReview'
}
elseif ($sectionFailures.Count -gt 0) {
    $diagnosticClassification = 'InsufficientDataReview'
}
elseif ($pendingReboot) {
    $diagnosticClassification = 'RebootPendingReview'
}

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine('<!doctype html>')
[void]$builder.AppendLine('<html lang="pt-BR"><head><meta charset="utf-8">')
[void]$builder.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
[void]$builder.AppendLine('<title>KARV — Diagnóstico operacional do Windows Update</title>')
[void]$builder.AppendLine('<style>')
[void]$builder.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f4f6f8;color:#17212b}main{max-width:1500px;margin:0 auto;padding:28px}header,section{background:#fff;border:1px solid #d9e0e7;border-radius:10px;padding:20px;margin-bottom:18px}h1{margin:0 0 8px;font-size:26px}h2{margin:0 0 14px;font-size:20px}.warning{background:#fff4d6;border-left:5px solid #c78a00;padding:12px;margin-top:14px}.metrics{display:flex;gap:12px;flex-wrap:wrap;margin-top:16px}.metric{background:#edf2f7;border-radius:8px;padding:10px 14px}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid #dfe5eb;padding:9px;word-break:break-word}th{background:#edf2f7;position:sticky;top:0}.footer{font-size:12px;color:#5b6773}</style>')
[void]$builder.AppendLine('</head><body><main>')
[void]$builder.AppendLine('<header><h1>KARV — Diagnóstico operacional do Windows Update</h1>')
[void]$builder.AppendLine('<p>Diagnóstico local e somente leitura. Serviços parados não são considerados defeito automaticamente, pois alguns componentes operam sob demanda.</p>')
[void]$builder.AppendLine('<div class="warning"><strong>Sem ações.</strong> Este painel não reinicia, atualiza, repara ou reconfigura o Windows.</div>')
[void]$builder.AppendLine('<div class="metrics">')
[void]$builder.AppendLine('<div class="metric"><strong>Classificação:</strong> ' + (Convert-ToHtmlText $diagnosticClassification) + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Indicadores pendentes:</strong> ' + $pendingIndicatorCount + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Componentes encontrados:</strong> ' + $componentsFound + ' / ' + $componentsExpected + '</div>')
[void]$builder.AppendLine('<div class="metric"><strong>Eventos locais:</strong> ' + $eventArray.Count + '</div>')
[void]$builder.AppendLine('</div></header>')

[void]$builder.AppendLine('<section><h2>Indicadores de reinicialização pendente</h2><div class="table-wrap"><table><thead><tr><th>Indicador</th><th>Presente</th><th>Evidência</th><th>Conteúdo lido</th></tr></thead><tbody>')
foreach ($indicator in $indicatorArray) {
    [void]$builder.AppendLine('<tr><td>' + (Convert-ToHtmlText $indicator.Name) + '</td><td>' + (Convert-ToHtmlText $indicator.Present) + '</td><td>' + (Convert-ToHtmlText $indicator.EvidenceType) + '</td><td>' + (Convert-ToHtmlText $indicator.ValueContentRead) + '</td></tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')

[void]$builder.AppendLine('<section><h2>Componentes essenciais</h2><div class="table-wrap"><table><thead><tr><th>Componente</th><th>Nome técnico</th><th>Encontrado</th><th>Estado</th><th>Inicialização</th></tr></thead><tbody>')
foreach ($service in $serviceArray) {
    [void]$builder.AppendLine('<tr><td>' + (Convert-ToHtmlText $service.DisplayName) + '</td><td>' + (Convert-ToHtmlText $service.Name) + '</td><td>' + (Convert-ToHtmlText $service.Found) + '</td><td>' + (Convert-ToHtmlText $service.State) + '</td><td>' + (Convert-ToHtmlText $service.StartMode) + '</td></tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')

[void]$builder.AppendLine('<section><h2>Eventos operacionais locais</h2><div class="table-wrap"><table><thead><tr><th>Data UTC</th><th>Nível</th><th>ID</th><th>Provedor</th><th>Mensagem lida</th></tr></thead><tbody>')
foreach ($event in $eventArray) {
    [void]$builder.AppendLine('<tr><td>' + (Convert-ToHtmlText $event.TimeCreatedUtc) + '</td><td>' + (Convert-ToHtmlText $event.LevelCategory) + '</td><td>' + (Convert-ToHtmlText $event.Id) + '</td><td>' + (Convert-ToHtmlText $event.ProviderName) + '</td><td>' + (Convert-ToHtmlText $event.MessageRead) + '</td></tr>')
}
[void]$builder.AppendLine('</tbody></table></div></section>')
[void]$builder.AppendLine('<section class="footer">Nenhum serviço foi iniciado, parado, reiniciado ou reconfigurado. Nenhuma atualização, correção ou reinicialização foi executada.</section>')
[void]$builder.AppendLine('</main></body></html>')

$timestamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
$manifestPath = Join-Path $validatedOutput ('karv-windows-update-operational-local-manifest-' + $timestamp + '.json')
$summaryPath = Join-Path $validatedOutput ('karv-windows-update-operational-sanitized-summary-' + $timestamp + '.json')
$htmlPath = Join-Path $validatedOutput ('karv-windows-update-operational-panel-' + $timestamp + '.html')

$manifest = [pscustomobject]@{
    Warning = 'SENSITIVE LOCAL DATA - DO NOT SHARE OR COMMIT'
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    SensitiveLocalData = $true
    LocalOnly = $true
    DiagnosticClassification = $diagnosticClassification
    PendingIndicators = $indicatorArray
    Services = $serviceArray
    Events = $eventArray
    SectionFailures = $sectionFailures.ToArray()
}

$summary = [pscustomobject]@{
    Collector = $collectorName
    ScriptVersion = $scriptVersion
    GeneratedAtUtc = $nowUtc.ToString('o')
    Mode = $Mode
    Privacy = [pscustomobject]@{
        SummarySanitized = $true
        SummaryContainsIndicatorNames = $false
        SummaryContainsServiceNames = $false
        SummaryContainsEventIds = $false
        SummaryContainsEventProviders = $false
        SummaryContainsEventMessages = $false
        SummaryContainsExactDates = $false
        SummaryContainsPaths = $false
        DetailedManifestContainsSensitiveLocalData = $true
        DetailedManifestLocalOnly = $true
        HtmlContainsSensitiveLocalData = $true
        HtmlLocalOnly = $true
        PendingPathValuesRead = $false
        ExcludedDriveEAccessed = $false
    }
    Scope = [pscustomobject]@{
        RegistryReadOnly = $true
        PendingIndicatorsExpected = 3
        ServiceMetadataReadOnly = $true
        EssentialComponentsExpected = $componentsExpected
        EventMetadataReadOnly = $true
        EventLimit = $eventLimit
        EventMessagesRead = $false
        UpdateSearchPerformed = $false
        UpdatesDownloaded = $false
        UpdatesInstalled = $false
        ServicesChanged = $false
        RebootTriggered = $false
        DismExecuted = $false
        SfcExecuted = $false
        NetworkCollected = $false
        ActionsAvailable = $false
    }
    Summary = [pscustomobject]@{
        DiagnosticClassification = $diagnosticClassification
        PendingReboot = $pendingReboot
        PendingRebootIndicators = $pendingIndicatorCount
        ComponentsExpected = $componentsExpected
        ComponentsFound = $componentsFound
        ComponentsRunning = $componentsRunning
        ComponentsStopped = $componentsStopped
        ComponentsDisabled = $componentsDisabled
        ComponentsMissing = $componentsMissing
        ServiceQueryFailures = $serviceQueryFailures
        EventEntries = [int64]$eventArray.Count
        EventCritical = $eventCritical
        EventErrors = $eventErrors
        EventWarnings = $eventWarnings
        EventInformation = $eventInformation
        EventOther = $eventOther
        EventsLast7Days = [int64]$eventsLast7Days
        EventsLast30Days = [int64]$eventsLast30Days
        Events31To90Days = [int64]$events31To90Days
        EventsOlderThan90Days = [int64]$eventsOlderThan90Days
        EventsUnknownAge = [int64]$eventsUnknownAge
        LastEventAgeDays = $lastEventAgeDays
        LastErrorAgeDays = $lastErrorAgeDays
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
    DiagnosticClassification = $diagnosticClassification
    PendingReboot = $pendingReboot
    PendingRebootIndicators = $pendingIndicatorCount
    ComponentsExpected = $componentsExpected
    ComponentsFound = $componentsFound
    ComponentsRunning = $componentsRunning
    ComponentsStopped = $componentsStopped
    ComponentsDisabled = $componentsDisabled
    ComponentsMissing = $componentsMissing
    ServiceQueryFailures = $serviceQueryFailures
    EventEntries = [int64]$eventArray.Count
    EventErrors = $eventErrors
    EventWarnings = $eventWarnings
    SectionFailures = [int64]$sectionFailures.Count
    ReportsCreated = 3
}
